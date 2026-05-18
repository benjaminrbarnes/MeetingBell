import AppKit
import Foundation

@MainActor
final class ReminderController: NSObject {
    private static let showOnlyTimeKey = "showOnlyTimeToNextMeeting"
    private static let soundEnabledKey = "soundEnabled"

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
        setStatusAppearance(title: state.title, backgroundColor: state.backgroundColor)
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

    @objc private func acknowledgeAndJoinCurrentEvent() {
        guard let silencedEvent = silenceCurrentEvent() else { return }

        if let joinURL = silencedEvent.joinURL {
            NSWorkspace.shared.open(joinURL)
        }

        refreshAction()
    }

    private func silenceCurrentEvent() -> MeetingEvent? {
        guard soundTimer != nil, let currentEvent else { return nil }

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
            return DisplayState(title: "MeetingBell", backgroundColor: .white, detail: accessMessage, canAcknowledge: false)
        }

        guard let event else {
            return DisplayState(title: "No meetings", backgroundColor: .white, detail: "No upcoming meetings in the next 24 hours.", canAcknowledge: false)
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

        return DisplayState(title: title, backgroundColor: backgroundColor, detail: detail, canAcknowledge: canAcknowledge)
    }

    private func setStatusAppearance(title: String, backgroundColor: NSColor) {
        let maxLength = 20
        let titledWithIcon = "⏰ \(title)"
        let shortened = titledWithIcon.count > maxLength ? "\(titledWithIcon.prefix(maxLength - 3))..." : titledWithIcon
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.black.withAlphaComponent(0.72),
            .font: NSFont.menuBarFont(ofSize: 0)
        ]

        statusItem.button?.attributedTitle = NSAttributedString(string: shortened, attributes: attributes)
        statusItem.button?.layer?.backgroundColor = backgroundColor.withAlphaComponent(0.95).cgColor
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

        let ongoingEvents = activeOngoingEvents()

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

        menu.addItem(sectionHeader("Next Meeting"))

        if let currentEvent {
            addMeetingDetails(for: currentEvent, to: menu, detail: state.detail)
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
}
