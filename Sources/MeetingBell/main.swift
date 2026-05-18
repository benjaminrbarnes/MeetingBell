import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let calendarWatcher = CalendarWatcher()
    private lazy var reminderController = ReminderController(
        refreshAction: { [weak self] in
            self?.refreshMeeting()
        },
        createTestMeetingAction: { [weak self] in
            self?.createTestMeeting()
        }
    )

    private var refreshTimer: Timer?
    private var hasCalendarAccess = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        _ = reminderController
        requestCalendarAccess()

        refreshTimer = Timer.scheduledTimer(
            timeInterval: 15,
            target: self,
            selector: #selector(refreshTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    @objc private func refreshTimerFired() {
        refreshMeeting()
    }

    private func requestCalendarAccess() {
        calendarWatcher.requestAccess { [weak self] granted, message in
            guard let self else { return }

            self.hasCalendarAccess = granted

            if granted {
                self.refreshMeeting()
            } else {
                self.reminderController.update(event: nil, accessMessage: message ?? "Calendar access was not granted.")
            }
        }
    }

    private func refreshMeeting() {
        guard hasCalendarAccess else {
            requestCalendarAccess()
            return
        }

        let event = calendarWatcher.nextEvent(
            excludingAcknowledged: reminderController.acknowledgedKeys(),
            earliestStartDate: reminderController.sessionStartDate()
        )
        reminderController.update(event: event)
    }

    private func createTestMeeting() {
        guard hasCalendarAccess else {
            requestCalendarAccess()
            return
        }

        do {
            let event = try calendarWatcher.createTestMeeting()
            reminderController.update(event: event)
        } catch {
            NSSound.beep()
            reminderController.update(event: nil, accessMessage: error.localizedDescription)
        }
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()

app.delegate = appDelegate
app.run()
