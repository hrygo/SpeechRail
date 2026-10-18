// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpeechRailDiarizationCandidate",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "MeetingDiarizationCandidate", targets: ["MeetingDiarizationCandidate"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git",
                            revision: "503b4bd1bbf7220882de39fe8ae6716aae4132da", traits: [])],
    targets: [
        .target(name: "CandidatePacketCodec"),
        .target(name: "CandidateFrames"),
        .testTarget(name: "CandidateFramesTests", dependencies: ["CandidateFrames"]),
        .executableTarget(name: "MeetingDiarizationCandidate", dependencies: [
            "CandidatePacketCodec", "CandidateFrames", .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
    ]
)
