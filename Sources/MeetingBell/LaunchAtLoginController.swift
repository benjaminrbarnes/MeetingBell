import Foundation

enum LaunchAtLoginController {
    private static let label = "local.benbarnes.MeetingBell"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private static func install() throws {
        let appPath = Bundle.main.bundleURL.path
        let launchAgentsURL = agentURL.deletingLastPathComponent()

        try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        try plist(appPath: appPath).write(to: agentURL, atomically: true, encoding: .utf8)

        _ = runLaunchctl(arguments: ["bootout", guiDomain, agentURL.path])
        _ = runLaunchctl(arguments: ["bootstrap", guiDomain, agentURL.path])
    }

    private static func uninstall() throws {
        _ = runLaunchctl(arguments: ["bootout", guiDomain, agentURL.path])

        if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }

    private static var guiDomain: String {
        "gui/\(getuid())"
    }

    private static func runLaunchctl(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func plist(appPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>\(escaped(appPath))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
