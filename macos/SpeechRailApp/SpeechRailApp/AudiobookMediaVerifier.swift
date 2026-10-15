import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation
import CoreMedia
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
            guard expected.profile == .chapterMP3 else {
                throw AudiobookExportError.verificationFailed("整本 M4B 产物必须是单个可播放文件。")
            }
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            let mp3Files = contents.filter { $0.pathExtension.lowercased() == "mp3" }
            let expectedFileNames = Set(expected.exportedChapters.map(mp3FileName(for:)))
            guard mp3Files.count == expected.exportedChapters.count,
                  Set(mp3Files.map(\.lastPathComponent)) == expectedFileNames
            else {
                throw AudiobookExportError.verificationFailed(
                    "分章 MP3 文件名或数量与所选章节不一致。"
                )
            }

            var combinedDigests: [String] = []
            var totalFrames: Int64 = 0
            var durationWeightedFrames: Double = 0
            for chapter in expected.exportedChapters.sorted(by: { $0.ordinal < $1.ordinal }) {
                let fileURL = url.appendingPathComponent(mp3FileName(for: chapter), isDirectory: false)
                try requireRegularFile(fileURL)
                guard let chapterFrames = expected.expectedChapterFrameCounts[chapter.id], chapterFrames > 0 else {
                    throw AudiobookExportError.verificationFailed("缺少章节“\(chapter.title)”的预期时长。")
                }
                let actualDuration = try await inspectPlayableAudio(
                    at: fileURL,
                    expectedFormatID: kAudioFormatMPEGLayer3,
                    codecName: "mp3"
                )
                try verifyDuration(
                    actualDuration,
                    expectedFrameCount: chapterFrames,
                    sampleRate: expected.expectedSampleRate,
                    chapterTitle: chapter.title
                )
                let fileSHA = try sha256File(at: fileURL)
                combinedDigests.append("\(fileURL.lastPathComponent):\(fileSHA)")
                totalFrames += chapterFrames
                durationWeightedFrames += actualDuration * Double(expected.expectedSampleRate)
            }
            let bundleDigest = AudiobookDigest.sha256Hex(Data(combinedDigests.joined(separator: "|").utf8))
            return AudiobookMediaVerification(
                codec: "mp3",
                frameCount: totalFrames,
                durationSeconds: durationWeightedFrames / Double(max(1, expected.expectedSampleRate)),
                chapterTitles: expected.exportedChapters.map(\.title),
                fileSHA256: bundleDigest
            )
        }

        guard expected.profile == .m4b else {
            throw AudiobookExportError.verificationFailed("分章 MP3 产物必须是章节音频包目录。")
        }
        try requireRegularFile(url)
        let actualDuration = try await inspectPlayableAudio(
            at: url,
            expectedFormatID: kAudioFormatMPEG4AAC,
            codecName: "aac"
        )
        try verifyDuration(
            actualDuration,
            expectedFrameCount: expected.expectedFrameCount,
            sampleRate: expected.expectedSampleRate,
            chapterTitle: nil
        )
        let fileSHA = try sha256File(at: url)
        return AudiobookMediaVerification(
            codec: "aac",
            frameCount: expected.expectedFrameCount,
            durationSeconds: actualDuration,
            chapterTitles: expected.exportedChapters.map(\.title),
            fileSHA256: fileSHA
        )
    }

    private static func mp3FileName(for chapter: AudiobookChapter) -> String {
        String(format: "chapter_%04d.mp3", chapter.ordinal + 1)
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0
        else {
            throw AudiobookExportError.verificationFailed("媒体文件不存在、为空或不是普通文件。")
        }
    }

    private static func inspectPlayableAudio(
        at url: URL,
        expectedFormatID: AudioFormatID,
        codecName: String
    ) async throws -> TimeInterval {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.load(.tracks)
            guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else {
                throw AudiobookExportError.verificationFailed("媒体中没有可播放的音频轨道。")
            }
            let descriptions = try await audioTrack.load(.formatDescriptions)
            guard descriptions.contains(where: {
                CMFormatDescriptionGetMediaSubType($0) == expectedFormatID
            }) else {
                throw AudiobookExportError.verificationFailed("媒体编码与预期的 \(codecName) 格式不一致。")
            }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
                throw AudiobookExportError.verificationFailed("媒体时长无效。")
            }
            return duration.seconds
        } catch let error as AudiobookExportError {
            throw error
        } catch {
            // Container/track parse errors are verification failures, never a reason to trust metadata.
            throw AudiobookExportError.verificationFailed("AVFoundation 无法读取可播放的 \(codecName) 媒体。")
        }
    }

    private static func verifyDuration(
        _ actualDuration: TimeInterval,
        expectedFrameCount: Int64,
        sampleRate: Int,
        chapterTitle: String?
    ) throws {
        guard expectedFrameCount > 0, sampleRate > 0 else {
            throw AudiobookExportError.verificationFailed("预期媒体时长无效。")
        }
        let expectedDuration = Double(expectedFrameCount) / Double(sampleRate)
        guard abs(actualDuration - expectedDuration) <= maxDurationToleranceSeconds * 4 else {
            let subject = chapterTitle.map { "章节“\($0)”" } ?? "整本媒体"
            throw AudiobookExportError.verificationFailed(
                "\(subject)实际时长（\(String(format: "%.3f", actualDuration))s）与累计帧时长（\(String(format: "%.3f", expectedDuration))s）偏差超出范围。"
            )
        }
    }

    private static func sha256File(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
