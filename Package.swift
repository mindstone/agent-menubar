// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentMenuBar", targets: ["AgentMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "AgentMenuBar",
            path: "Sources/AgentMenuBar",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
