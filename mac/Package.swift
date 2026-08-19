// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentInbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentInbox",
            path: "Sources/AgentInbox"
        ),
        .testTarget(
            name: "AgentInboxTests",
            dependencies: ["AgentInbox"],
            path: "Tests/AgentInboxTests"
        ),
    ]
)
