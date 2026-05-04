// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DroidMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DroidMenuBar", targets: ["DroidMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "DroidMenuBar",
            path: "Sources/DroidMenuBar",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
