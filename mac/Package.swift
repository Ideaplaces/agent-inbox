// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentInbox",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates. Without this, whoever installs a version keeps it
        // forever, which for a menubar app people forget is running matters
        // more than shaving a step off the install.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentInbox",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AgentInbox"
        ),
        .testTarget(
            name: "AgentInboxTests",
            dependencies: ["AgentInbox"],
            path: "Tests/AgentInboxTests"
        ),
    ]
)
