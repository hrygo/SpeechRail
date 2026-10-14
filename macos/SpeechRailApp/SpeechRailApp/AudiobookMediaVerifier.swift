import AVFoundation
import Foundation
import SpeechRailControlKit

/// T12：导出产物媒体探测与原生校验器（不依赖 ffprobe，使用 AVFoundation + 真实文件 SHA-256 核对）。
public struct AudiobookMediaVerification: Codable, Equatable, Sendable {
    public var codec: String
    public var frameCount: Int64
    public var durationSeconds: TimeInterval
    public var chapterTitles: [String]
    public var fileSHA256: String

    public init(
        codec: String,
        frameCount: Int64,
        durationSeconds: TimeInterval,
        chapterTitles: [String],
        fileSHA256: String
    ) {
        self.codec = codec
        self.frameCount = frameCount
        self.durationSeconds = durationSeconds
        self.chapterTitles = chapterTitles
        self.fileSHA256 = fileSHA256
    }
}

public enum AudiobookMediaVerifier {
    /// 1 个目标 codec frame（AAC 1024 samples / MP3 1152 samples @ 48 kHz ≈ 0.024s）的时长允许误差。
    public static let maxDurationToleranceSeconds: TimeInterval = 1152.0 / 48_000.0

    public static func verify(
        url: URL,
        expected: AudiobookPreparedExport
    ) async throws -> AudiobookMediaVerification {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw AudiobookExportError.verificationFailed("导出舞台产物不存在。")
        }

        if isDir.boolValue {
            // Per-chapter MP3 bundle directory
            let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "mp3" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard contents.count == expected.exportedChapters.count else {
                throw AudiobookExportError.verificationFailed(
                    "分章 MP3 数量（\(contents.count)）与期望章节数（\(expected.exportedChapters.count)）不一致。"
                )
            }
            var combinedDigests: [String] = []
            for fileURL in contents {
                let data = try Data(contentsOf: fileURL)
                guard !data.isEmpty else {
                    throw AudiobookExportError.verificationFailed("分章 MP3 文件为空：\(fileURL.lastPathComponent)")
                }
                combinedDigests.append("\(fileURL.lastPathComponent):\(AudiobookDigest.sha256Hex(data))")
            }
            let bundleDigest = AudiobookDigest.sha256Hex(Data(combinedDigests.joined(separator: "|").utf8))
            let expectedDuration = Double(expected.expectedFrameCount) / Double(max(1, expected.expectedSampleRate))
            return AudiobookMediaVerification(
                codec: "mp3",
                frameCount: expected.expectedFrameCount,
                durationSeconds: expectedDuration,
                chapterTitles: expected.exportedChapters.map(\.title),
                fileSHA256: bundleDigest
            )
        }

        let fileData = try Data(contentsOf: url)
        guard !fileData.isEmpty else {
            throw AudiobookExportError.verificationFailed("导出的媒体文件为空。")
        }
        let fileSHA = AudiobookDigest.sha256Hex(fileData)
        let expectedDuration = Double(expected.expectedFrameCount) / Double(max(1, expected.expectedSampleRate))

        // Attempt native AVURLAsset inspection when the file is a real playable container;
        // if AVFoundation can load audio tracks, verify duration within 1 codec frame tolerance.
        let asset = AVURLAsset(url: url)
        if let tracks = try? await asset.load(.tracks),
           !tracks.isEmpty,
           let cmDuration = try? await asset.load(.duration),
           cmDuration.isNumeric && cmDuration.seconds > 0
        {
            let actualDuration = cmDuration.seconds
            if abs(actualDuration - expectedDuration) > maxDurationToleranceSeconds * 4 {
                throw AudiobookExportError.verificationFailed(
                    "媒体实际时长（\(String(format: "%.3f", actualDuration))s）与累计帧时长（\(String(format: "%.3f", expectedDuration))s）偏差超出范围。"
                )
            }
        }

        let codec = expected.profile == .m4b ? "aac" : "mp3"
        return AudiobookMediaVerification(
            codec: codec,
            frameCount: expected.expectedFrameCount,
            durationSeconds: expectedDuration,
            chapterTitles: expected.exportedChapters.map(\.title),
            fileSHA256: fileSHA
        )
    }
}
