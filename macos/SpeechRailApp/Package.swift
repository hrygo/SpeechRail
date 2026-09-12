// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpeechRailMacControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpeechRailControlKit", targets: ["SpeechRailControlKit"]),
        .library(name: "SpeechRailControlAgentCore", targets: ["SpeechRailControlAgentCore"]),
        .executable(name: "SpeechRailControlAgent", targets: ["SpeechRailControlAgent"]),
    ],
    targets: [
        .target(
            name: "SpeechRailControlKit",
            path: "SpeechRailControlKit"
        ),
        .target(
            name: "SpeechRailControlAgentCore",
            dependencies: ["SpeechRailControlKit"],
            path: "SpeechRailControlAgentCore"
        ),
        .executableTarget(
            name: "SpeechRailControlAgent",
            dependencies: ["SpeechRailControlAgentCore", "SpeechRailControlKit"],
            path: "SpeechRailControlAgent"
        ),
        .testTarget(
            name: "SpeechRailMacControlTests",
            dependencies: ["SpeechRailControlKit", "SpeechRailControlAgentCore"],
            path: "SpeechRailMacControlTests"
        ),
    ]
)
