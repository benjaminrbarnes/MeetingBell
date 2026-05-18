import EventKit
import Foundation

struct MeetingEvent: Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarTitle: String
    let location: String?
    let url: URL?
    let joinURL: URL?

    var acknowledgeKey: String {
        "\(id)|\(Int(startDate.timeIntervalSince1970))"
    }
}

@MainActor
final class CalendarWatcher {
    private let eventStore = EKEventStore()
    private let lookAhead: TimeInterval = 24 * 60 * 60
    private let lookBehind: TimeInterval = 12 * 60 * 60

    func requestAccess(completion: @escaping @MainActor @Sendable (Bool, String?) -> Void) {
        let status = EKEventStore.authorizationStatus(for: .event)

        switch status {
        case .fullAccess, .authorized:
            completion(true, nil)
        case .notDetermined:
            requestFullAccess(completion: completion)
        case .denied, .restricted, .writeOnly:
            completion(false, "Calendar access is not available. Enable it in System Settings > Privacy & Security > Calendars.")
        @unknown default:
            completion(false, "Calendar access is unavailable due to an unknown authorization state.")
        }
    }

    func nextEvent(
        excludingAcknowledged acknowledgedKeys: Set<String> = [],
        earliestStartDate: Date? = nil,
        now: Date = Date()
    ) -> MeetingEvent? {
        let windowStart = now.addingTimeInterval(-lookBehind)
        let windowEnd = now.addingTimeInterval(lookAhead)
        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: calendars)

        return eventStore.events(matching: predicate)
            .filter { isEligible($0, now: now) }
            .map(makeMeetingEvent)
            .filter { event in
                guard let earliestStartDate else { return true }

                return event.startDate >= earliestStartDate
            }
            .filter { !acknowledgedKeys.contains($0.acknowledgeKey) }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    func createTestMeeting(now: Date = Date()) throws -> MeetingEvent {
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw CalendarWatcherError.missingDefaultCalendar
        }

        let startDate = now.addingTimeInterval(60)
        let endDate = startDate.addingTimeInterval(10 * 60)
        let event = EKEvent(eventStore: eventStore)

        event.title = "MeetingBell Test Meeting"
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = calendar
        event.availability = .busy
        event.notes = "Created by MeetingBell development mode.\nJoin: https://meet.google.com/aaa-bbbb-ccc"

        try eventStore.save(event, span: .thisEvent, commit: true)

        return makeMeetingEvent(from: event)
    }

    private func requestFullAccess(completion: @escaping @MainActor @Sendable (Bool, String?) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, error in
                let message = error?.localizedDescription

                Task { @MainActor in
                    completion(granted, message)
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                let message = error?.localizedDescription

                Task { @MainActor in
                    completion(granted, message)
                }
            }
        }
    }

    private func isEligible(_ event: EKEvent, now: Date) -> Bool {
        guard !event.isAllDay else { return false }
        guard event.endDate > now else { return false }
        guard event.availability != .free else { return false }
        guard participantStatus(for: event) != .declined else { return false }

        return true
    }

    private func participantStatus(for event: EKEvent) -> EKParticipantStatus {
        event.attendees?
            .first { $0.isCurrentUser }
            .map(\.participantStatus) ?? .unknown
    }

    private func makeMeetingEvent(from event: EKEvent) -> MeetingEvent {
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)

        return MeetingEvent(
            id: event.eventIdentifier ?? "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
            title: title?.isEmpty == false ? title! : "Untitled meeting",
            startDate: event.startDate,
            endDate: event.endDate,
            calendarTitle: event.calendar.title,
            location: event.location,
            url: event.url,
            joinURL: findJoinURL(in: event)
        )
    }

    private func findJoinURL(in event: EKEvent) -> URL? {
        let candidates = [
            event.url?.absoluteString,
            event.location,
            event.notes
        ]
        .compactMap { $0 }
        .flatMap(extractURLs)

        return candidates.first(where: isJoinURL) ?? candidates.first
    }

    private func extractURLs(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return detector.matches(in: text, options: [], range: range)
            .compactMap(\.url)
    }

    private func isJoinURL(_ url: URL) -> Bool {
        let text = url.absoluteString.lowercased()
        let meetingHosts = [
            "zoom.us",
            "meet.google.com",
            "teams.microsoft.com",
            "chime.aws",
            "bluejeans.com",
            "webex.com"
        ]

        return meetingHosts.contains { text.contains($0) }
    }
}

enum CalendarWatcherError: LocalizedError {
    case missingDefaultCalendar

    var errorDescription: String? {
        switch self {
        case .missingDefaultCalendar:
            return "No default writable calendar is available for creating a test meeting."
        }
    }
}
