import AppKit
import Foundation

@MainActor
final class ReminderController: NSObject {
    private static let showOnlyTimeKey = "showOnlyTimeToNextMeeting"
    private static let soundEnabledKey = "soundEnabled"
    private static let alertHoursEnabledKey = "alertHoursEnabled"
    private static let alertStartMinuteKey = "alertStartMinuteOfDay"
    private static let alertEndMinuteKey = "alertEndMinuteOfDay"
    private static let defaultAlertStartMinute = 9 * 60
    private static let defaultAlertEndMinute = 18 * 60
    private static let minutesPerDay = 24 * 60

    private let statusItem: NSStatusItem
    private let refreshAction: @MainActor () -> Void
    private let createTestMeetingAction: @MainActor () -> Void
    private let sessionStartedAt = Date()

    private var currentEvent: MeetingEvent?
    private var acknowledgedEventKeys = Set<String>()
    private var ongoingEvents: [MeetingEvent] = []
    private var soundTimer: Timer?
    private var showOnlyTime: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showOnlyTimeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showOnlyTimeKey) }
    }
    private var soundEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.soundEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.soundEnabledKey)
        }
    }
    private var alertHoursEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.alertHoursEnabledKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.alertHoursEnabledKey)
        }
    }
    private var alertStartMinute: Int {
        get {
            UserDefaults.standard.object(forKey: Self.alertStartMinuteKey) as? Int ?? Self.defaultAlertStartMinute
        }
        set {
            UserDefaults.standard.set(normalizedMinute(newValue), forKey: Self.alertStartMinuteKey)
        }
    }
    private var alertEndMinute: Int {
        get {
            UserDefaults.standard.object(forKey: Self.alertEndMinuteKey) as? Int ?? Self.defaultAlertEndMinute
        }
        set {
            UserDefaults.standard.set(normalizedMinute(newValue), forKey: Self.alertEndMinuteKey)
        }
    }

    init(
        refreshAction: @escaping @MainActor () -> Void,
        createTestMeetingAction: @escaping @MainActor () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.refreshAction = refreshAction
        self.createTestMeetingAction = createTestMeetingAction

        super.init()

        configureStatusButton()
        update(event: nil, accessMessage: "Starting MeetingBell...")
    }

    func update(
        event: MeetingEvent?,
        ongoingEvents: [MeetingEvent] = [],
        accessMessage: String? = nil,
        now: Date = Date()
    ) {
        currentEvent = event
        self.ongoingEvents = ongoingEvents.filter { $0.endDate > now }

        let state = displayState(for: event, accessMessage: accessMessage, now: now)
        setStatusAppearance(state: state)
        updateSound(for: event, now: now)
        rebuildMenu(state: state)
    }

    func acknowledgedKeys() -> Set<String> {
        acknowledgedEventKeys
    }

    func sessionStartDate() -> Date {
        sessionStartedAt
    }

    @objc private func acknowledgeCurrentEvent() {
        guard silenceCurrentEvent() != nil else { return }

        refreshAction()
    }

    @objc private func skipCurrentEvent() {
        guard silenceCurrentEvent() != nil else { return }

        refreshAction()
    }

    @objc private func acknowledgeAndJoinCurrentEvent() {
        guard let silencedEvent = silenceCurrentEvent() else { return }

        if let joinURL = silencedEvent.joinURL {
            NSWorkspace.shared.open(joinURL)
        }

        refreshAction()
    }

    private func silenceCurrentEvent() -> MeetingEvent? {
        guard let currentEvent else { return nil }

        acknowledgedEventKeys.insert(currentEvent.acknowledgeKey)
        stopSound()
        return currentEvent
    }

    @objc private func refreshNow() {
        refreshAction()
    }

    @objc private func createTestMeeting() {
        createTestMeetingAction()
    }

    @objc private func toggleShowOnlyTime(_ sender: NSMenuItem) {
        showOnlyTime.toggle()
        refreshAction()
    }

    @objc private func toggleSoundEnabled(_ sender: NSMenuItem) {
        soundEnabled.toggle()

        if soundEnabled {
            refreshAction()
        } else {
            stopSound()
            rebuildMenu(state: displayState(for: currentEvent, accessMessage: nil, now: Date()))
        }
    }

    @objc private func toggleAlertHours(_ sender: NSMenuItem) {
        alertHoursEnabled.toggle()
        refreshAction()
    }

    @objc private func editAlertHours(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Set Alert Hours"
        alert.informativeText = "MeetingBell will only play sound notifications for meetings that start during this window."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = alertHoursAccessoryView()

        let controls = alert.accessoryView?.subviews
            .compactMap { $0 as? NSTextField }
            .filter(\.isEditable) ?? []

        guard alert.runModal() == .alertFirstButtonReturn,
              controls.count == 2
        else {
            return
        }

        guard let startMinute = minuteOfDay(from: controls[0].stringValue),
              let endMinute = minuteOfDay(from: controls[1].stringValue)
        else {
            showInvalidAlertHoursMessage()
            return
        }

        alertStartMinute = startMinute
        alertEndMinute = endMinute
        alertHoursEnabled = true
        refreshAction()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            try LaunchAtLoginController.setEnabled(!LaunchAtLoginController.isEnabled)
        } catch {
            NSSound.beep()
        }

        rebuildMenu(state: displayState(for: currentEvent, accessMessage: nil, now: Date()))
    }

    @objc private func quit() {
        stopSound()
        NSApp.terminate(nil)
    }

    private func displayState(for event: MeetingEvent?, accessMessage: String?, now: Date) -> DisplayState {
        if let accessMessage {
            return DisplayState(
                title: "MeetingBell",
                backgroundColor: .white,
                detail: accessMessage,
                canAcknowledge: false,
                isQuietHours: false,
                quietHoursMessage: nil
            )
        }

        let quietHours = isQuietHours(now: now)
        let quietHoursMessage = quietHours ? quietHoursStatusMessage(now: now) : nil

        guard let event else {
            return DisplayState(
                title: quietHours ? "Zz" : "No meetings",
                backgroundColor: .white,
                detail: "No upcoming meetings in the next 24 hours.",
                canAcknowledge: false,
                isQuietHours: quietHours,
                quietHoursMessage: quietHoursMessage
            )
        }

        let secondsUntilStart = event.startDate.timeIntervalSince(now)
        let title: String
        let backgroundColor: NSColor
        let detail: String
        let canAcknowledge: Bool

        if secondsUntilStart > 300 {
            title = formatStatusTitle(prefix: formatCountdown(secondsUntilStart), event: event)
            backgroundColor = .white
            detail = "Starts at \(formatTime(event.startDate))"
            canAcknowledge = false
        } else if secondsUntilStart > 120 {
            title = formatStatusTitle(prefix: formatCountdown(secondsUntilStart), event: event)
            backgroundColor = NSColor(calibratedRed: 0.68, green: 0.87, blue: 1.0, alpha: 1.0)
            detail = "Starts at \(formatTime(event.startDate))"
            canAcknowledge = false
        } else if secondsUntilStart > 0 {
            title = formatStatusTitle(prefix: formatCountdown(secondsUntilStart), event: event)
            backgroundColor = .systemYellow
            detail = "Starts at \(formatTime(event.startDate))"
            canAcknowledge = false
        } else {
            title = formatStatusTitle(prefix: "NOW", event: event)
            backgroundColor = .systemRed
            detail = "Started at \(formatTime(event.startDate))"
            canAcknowledge = true
        }

        return DisplayState(
            title: quietHours ? "Zz" : title,
            backgroundColor: quietHours ? .white : backgroundColor,
            detail: detail,
            canAcknowledge: canAcknowledge,
            isQuietHours: quietHours,
            quietHoursMessage: quietHoursMessage
        )
    }

    private func setStatusAppearance(state: DisplayState) {
        let maxLength = 20
        let titledWithIcon = state.isQuietHours ? state.title : "⏰ \(state.title)"
        let shortened = titledWithIcon.count > maxLength ? "\(titledWithIcon.prefix(maxLength - 3))..." : titledWithIcon
        let foregroundColor = state.isQuietHours ? NSColor.labelColor.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.72)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: foregroundColor,
            .font: NSFont.menuBarFont(ofSize: 0)
        ]

        statusItem.button?.attributedTitle = NSAttributedString(string: shortened, attributes: attributes)
        statusItem.button?.layer?.backgroundColor = state.backgroundColor.withAlphaComponent(0.95).cgColor
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }

        button.toolTip = "MeetingBell"
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        button.layer?.cornerRadius = 4
        button.layer?.masksToBounds = true
    }

    private func rebuildMenu(state: DisplayState) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if soundTimer != nil {
            rebuildDingingMenu(menu: menu, state: state)
            statusItem.menu = menu
            return
        }

        if state.isQuietHours {
            menu.addItem(sectionHeader("Do Not Disturb"))

            if let quietHoursMessage = state.quietHoursMessage {
                menu.addItem(disabledItem(quietHoursMessage))
            }

            menu.addItem(disabledItem("Alert hours: \(formatAlertHoursRange())"))
            menu.addItem(.separator())
        }

        let ongoingEvents = activeOngoingEvents()
            .filter { $0.acknowledgeKey != currentEvent?.acknowledgeKey }

        if !ongoingEvents.isEmpty {
            menu.addItem(sectionHeader("Ongoing"))

            for (index, event) in ongoingEvents.enumerated() {
                if index > 0 {
                    menu.addItem(.separator())
                }

                addMeetingDetails(for: event, to: menu, detail: "Ends at \(formatTime(event.endDate))")
            }

            menu.addItem(.separator())
        }

        menu.addItem(sectionHeader(state.canAcknowledge ? "Current Meeting" : "Next Meeting"))

        if let currentEvent {
            addMeetingDetails(
                for: currentEvent,
                to: menu,
                detail: state.detail,
                includeJoinAction: !state.canAcknowledge
            )

            if state.canAcknowledge {
                addDismissActions(for: currentEvent, to: menu)
            } else {
                addSkipAction(for: currentEvent, to: menu)
            }
        } else {
            menu.addItem(disabledItem(state.detail))
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Settings"))

        let showOnlyTimeItem = NSMenuItem(title: "Show Time Only", action: #selector(toggleShowOnlyTime), keyEquivalent: "")
        showOnlyTimeItem.target = self
        showOnlyTimeItem.state = showOnlyTime ? .on : .off
        menu.addItem(showOnlyTimeItem)

        let soundItem = NSMenuItem(title: "Play Sound Until Silenced", action: #selector(toggleSoundEnabled), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = soundEnabled ? .on : .off
        menu.addItem(soundItem)

        let alertHoursItem = NSMenuItem(title: "Limit Alerts to Hours", action: #selector(toggleAlertHours), keyEquivalent: "")
        alertHoursItem.target = self
        alertHoursItem.state = alertHoursEnabled ? .on : .off
        menu.addItem(alertHoursItem)

        let editAlertHoursItem = NSMenuItem(title: "Alert Hours: \(formatAlertHoursRange())", action: #selector(editAlertHours), keyEquivalent: "")
        editAlertHoursItem.target = self
        menu.addItem(editAlertHoursItem)

        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LaunchAtLoginController.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        if isDevelopmentMode {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Testing"))

            let testMeetingItem = NSMenuItem(title: "Create 1-Minute Test Meeting", action: #selector(createTestMeeting), keyEquivalent: "")
            testMeetingItem.target = self
            menu.addItem(testMeetingItem)
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("App"))

        let refreshItem = NSMenuItem(title: "Check Calendar Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit MeetingBell", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func rebuildDingingMenu(menu: NSMenu, state: DisplayState) {
        menu.addItem(sectionHeader("Meeting Started"))

        if let currentEvent {
            addMeetingDetails(for: currentEvent, to: menu, detail: state.detail, includeJoinAction: false)
        }

        menu.addItem(.separator())

        if currentEvent?.joinURL != nil {
            let joinItem = NSMenuItem(title: "Silence and Join Meeting", action: #selector(acknowledgeAndJoinCurrentEvent), keyEquivalent: "")
            joinItem.target = self
            joinItem.isEnabled = true
            menu.addItem(joinItem)
        }

        let ackItem = NSMenuItem(title: "Silence Meeting", action: #selector(acknowledgeCurrentEvent), keyEquivalent: "")
        ackItem.target = self
        ackItem.isEnabled = true
        menu.addItem(ackItem)
    }

    private func addDismissActions(for event: MeetingEvent, to menu: NSMenu) {
        if event.joinURL != nil {
            let joinItem = NSMenuItem(title: "Dismiss and Join Meeting", action: #selector(acknowledgeAndJoinCurrentEvent), keyEquivalent: "")
            joinItem.target = self
            joinItem.isEnabled = true
            menu.addItem(joinItem)
        }

        let dismissItem = NSMenuItem(title: "Dismiss Meeting", action: #selector(acknowledgeCurrentEvent), keyEquivalent: "")
        dismissItem.target = self
        dismissItem.isEnabled = true
        menu.addItem(dismissItem)
    }

    private func addSkipAction(for event: MeetingEvent, to menu: NSMenu) {
        let skipItem = NSMenuItem(title: "Skip This Meeting", action: #selector(skipCurrentEvent), keyEquivalent: "")
        skipItem.target = self
        skipItem.isEnabled = true
        menu.addItem(skipItem)
    }

    private func addMeetingDetails(
        for event: MeetingEvent,
        to menu: NSMenu,
        detail: String,
        includeJoinAction: Bool = true
    ) {
        menu.addItem(disabledItem(event.title))
        menu.addItem(disabledItem(detail))
        menu.addItem(disabledItem("Calendar: \(event.calendarTitle)"))

        if let location = event.location, !location.isEmpty {
            menu.addItem(disabledItem("Location: \(location)"))
        }

        guard includeJoinAction else { return }

        if let joinURL = event.joinURL {
            let item = NSMenuItem(title: "Join Meeting", action: #selector(openURL), keyEquivalent: "j")
            item.target = self
            item.representedObject = joinURL
            menu.addItem(item)
        }

        if let url = event.url, url != event.joinURL {
            let item = NSMenuItem(title: "Open Event URL", action: #selector(openURL), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
    }

    @objc private func openURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }

        NSWorkspace.shared.open(url)
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = disabledItem(title.uppercased())
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private var isDevelopmentMode: Bool {
        ProcessInfo.processInfo.environment["MEETINGBELL_DEVELOPMENT_MODE"] == "1"
            || Bundle.main.url(forResource: "DevelopmentMode", withExtension: "enabled") != nil
    }

    private func updateSound(for event: MeetingEvent?, now: Date) {
        guard
            soundEnabled,
            let event,
            event.startDate <= now,
            event.startDate >= sessionStartedAt,
            alertHoursAllowSound(for: event, now: now),
            !isAcknowledged(event)
        else {
            stopSound()
            return
        }

        startSound()
    }

    private func startSound() {
        guard soundTimer == nil else { return }

        playSound()
        soundTimer = Timer.scheduledTimer(
            timeInterval: 4,
            target: self,
            selector: #selector(soundTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    private func stopSound() {
        soundTimer?.invalidate()
        soundTimer = nil
    }

    @objc private func soundTimerFired() {
        playSound()
    }

    private func playSound() {
        if let sound = NSSound(named: NSSound.Name("Ping")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func alertHoursAllowSound(for event: MeetingEvent, now: Date) -> Bool {
        guard alertHoursEnabled else { return true }

        return isInAlertHours(event.startDate) && isInAlertHours(now)
    }

    private func isQuietHours(now: Date) -> Bool {
        alertHoursEnabled && !isInAlertHours(now)
    }

    private func isInAlertHours(_ date: Date) -> Bool {
        let minute = minuteOfDay(for: date)
        let startMinute = alertStartMinute
        let endMinute = alertEndMinute

        if startMinute == endMinute {
            return true
        }

        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }

        return minute >= startMinute || minute < endMinute
    }

    private func minuteOfDay(for date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0

        return hour * 60 + minute
    }

    private func normalizedMinute(_ minute: Int) -> Int {
        ((minute % Self.minutesPerDay) + Self.minutesPerDay) % Self.minutesPerDay
    }

    private func isAcknowledged(_ event: MeetingEvent?) -> Bool {
        guard let event else { return false }

        return acknowledgedEventKeys.contains(event.acknowledgeKey)
    }

    private func activeOngoingEvents(now: Date = Date()) -> [MeetingEvent] {
        ongoingEvents
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(seconds / 60)))

        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        let remainder = minutes % 60

        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private func formatStatusTitle(prefix: String, event: MeetingEvent) -> String {
        showOnlyTime ? prefix : "\(prefix) - \(event.title)"
    }

    private func formatAlertHoursRange() -> String {
        "\(formatMinuteOfDay(alertStartMinute)) - \(formatMinuteOfDay(alertEndMinute))"
    }

    private func formatMinuteOfDay(_ minute: Int) -> String {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = minute / 60
        components.minute = minute % 60

        guard let date = Calendar.current.date(from: components) else {
            return "12:00 AM"
        }

        return formatTime(date)
    }

    private func quietHoursStatusMessage(now: Date) -> String {
        "Sound alerts resume at \(formatTime(nextAlertStart(after: now)))"
    }

    private func nextAlertStart(after date: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let hour = alertStartMinute / 60
        let minute = alertStartMinute % 60
        let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? date

        if candidate > date {
            return candidate
        }

        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? date
    }

    private func alertHoursAccessoryView() -> NSView {
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 64))

        let startField = NSTextField(frame: NSRect(x: 80, y: 34, width: 180, height: 24))
        startField.stringValue = formatMinuteOfDay(alertStartMinute)
        startField.placeholderString = "9:00 AM"

        let endField = NSTextField(frame: NSRect(x: 80, y: 4, width: 180, height: 24))
        endField.stringValue = formatMinuteOfDay(alertEndMinute)
        endField.placeholderString = "6:00 PM"

        let startLabel = NSTextField(labelWithString: "Start")
        startLabel.frame = NSRect(x: 0, y: 36, width: 72, height: 20)

        let endLabel = NSTextField(labelWithString: "End")
        endLabel.frame = NSRect(x: 0, y: 6, width: 72, height: 20)

        accessoryView.addSubview(startField)
        accessoryView.addSubview(endField)
        accessoryView.addSubview(startLabel)
        accessoryView.addSubview(endLabel)

        return accessoryView
    }

    private func minuteOfDay(from input: String) -> Int? {
        let text = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: ".", with: "")

        guard !text.isEmpty else { return nil }

        let pattern = #"^(\d{1,2})(?::(\d{2}))?\s*([AP]M)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let hourText = capture(match.range(at: 1), in: text),
              var hour = Int(hourText)
        else {
            return nil
        }

        let minute = capture(match.range(at: 2), in: text).flatMap(Int.init) ?? 0
        let suffix = capture(match.range(at: 3), in: text)

        guard minute >= 0 && minute < 60 else { return nil }

        if let suffix {
            guard hour >= 1 && hour <= 12 else { return nil }

            if suffix == "PM", hour != 12 {
                hour += 12
            } else if suffix == "AM", hour == 12 {
                hour = 0
            }
        } else {
            guard hour >= 0 && hour < 24 else { return nil }
        }

        return hour * 60 + minute
    }

    private func capture(_ range: NSRange, in text: String) -> String? {
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: text)
        else {
            return nil
        }

        return String(text[swiftRange])
    }

    private func showInvalidAlertHoursMessage() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Alert Hours Were Not Saved"
        alert.informativeText = "Use times like 9:00 AM, 6 PM, or 17:30."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

private struct DisplayState {
    let title: String
    let backgroundColor: NSColor
    let detail: String
    let canAcknowledge: Bool
    let isQuietHours: Bool
    let quietHoursMessage: String?
}
