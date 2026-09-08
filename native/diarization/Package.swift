// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpeechRailDiarization",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "5c19d5e12320e22bbfb7a1877b089d2665a69add"
        ),
    ],
    targets: [
        .target(name: "SpeechRailDiarizationProtocol"),
        .executableTarget(
            name: "SpeechRailDiarizationWorker",
            dependencies: [
                "SpeechRailDiarizationProtocol",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "SpeechRailDiarizationProtocolSelfTest",
            dependencies: ["SpeechRailDiarizationProtocol"]
        ),
    ]
)
