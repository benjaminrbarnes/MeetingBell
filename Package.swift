// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MeetingBell",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MeetingBell",
            path: "Sources/MeetingBell",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("EventKit")
            ]
        )
    ]
)
