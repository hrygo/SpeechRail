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
    public var artworkPresent: Bool

    public init(
        codec: String,
        frameCount: Int64,
        durationSeconds: TimeInterval,
        chapterTitles: [String],
        fileSHA256: String,
        artworkPresent: Bool = false
    ) {
        self.codec = codec
        self.frameCount = frameCount
        self.durationSeconds = durationSeconds
        self.chapterTitles = chapterTitles
        self.fileSHA256 = fileSHA256
        self.artworkPresent = artworkPresent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codec = try container.decode(String.self, forKey: .codec)
        frameCount = try container.decode(Int64.self, forKey: .frameCount)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        chapterTitles = try container.decode([String].self, forKey: .chapterTitles)
        fileSHA256 = try container.decode(String.self, forKey: .fileSHA256)
        artworkPresent = try container.decodeIfPresent(Bool.self, forKey: .artworkPresent) ?? false
    }
}

public enum AudiobookMediaVerifier {
    /// 1 个目标 codec frame（AAC 1024 samples / MP3 1152 samples @ 48 kHz ≈ 0.024s）的时长允许误差。
    public static let maxDurationToleranceSeconds: TimeInterval = 1152.0 / 48_000.0

    public static func verify(
        url: URL,
        expected: AudiobookPreparedExport
    ) async throws -> AudiobookMediaVerification {
        try Task.checkCancellation()
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
        let actualChapterTitles = try await inspectAndVerifyM4BChapters(at: url, expected: expected)
        let artworkPresent = try await hasEmbeddedArtwork(at: url)
        if expected.expectsArtwork, !artworkPresent {
            throw AudiobookExportError.verificationFailed("导出请求要求写入封面，但产物中未检测到封面图。")
        }
        if !expected.expectsArtwork, artworkPresent {
            throw AudiobookExportError.verificationFailed("本次导出未请求封面，但产物中检测到封面图。")
        }
        let fileSHA = try sha256File(at: url)
        return AudiobookMediaVerification(
            codec: "aac",
            frameCount: expected.expectedFrameCount,
            durationSeconds: actualDuration,
            chapterTitles: actualChapterTitles,
            fileSHA256: fileSHA,
            artworkPresent: artworkPresent
        )
    }

    /// F1: AVFoundation does not guarantee that an FFmpeg `attached_pic` stream surfaces as
    /// `commonIdentifierArtwork` metadata, so artwork counts as present when EITHER the common
    /// metadata carries an artwork item OR the asset exposes a non-audio picture track. This
    /// keeps a silently dropped cover failing closed instead of passing as "no artwork".
    private static func hasEmbeddedArtwork(at url: URL) async throws -> Bool {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let artworkItems = AVMetadataItem.metadataItems(
            from: try await asset.load(.commonMetadata),
            filteredByIdentifier: .commonIdentifierArtwork
        )
        if !artworkItems.isEmpty {
            return true
        }
        let videoTracks = try await asset.load(.tracks).filter { $0.mediaType == .video }
        return !videoTracks.isEmpty
    }

    private static func inspectAndVerifyM4BChapters(
        at url: URL,
        expected: AudiobookPreparedExport
    ) async throws -> [String] {
        let chapters = expected.exportedChapters.sorted { $0.ordinal < $1.ordinal }
        let chapterIDs = chapters.map(\.id)
        guard !chapters.isEmpty,
              Set(chapterIDs).count == chapterIDs.count,
              Set(chapters.map(\.ordinal)).count == chapters.count,
              expected.expectedSampleRate > 0,
              expected.expectedChapterFrameCounts.count == chapters.count,
              Set(expected.expectedChapterFrameCounts.keys) == Set(chapterIDs)
        else {
            throw AudiobookExportError.verificationFailed("M4B 预期章节清单或章节时长无效。")
        }

        var expectedRanges: [(title: String, start: TimeInterval, end: TimeInterval)] = []
        var cursorFrames: Int64 = 0
        for chapter in chapters {
            guard let chapterFrames = expected.expectedChapterFrameCounts[chapter.id], chapterFrames > 0 else {
                throw AudiobookExportError.verificationFailed("缺少章节“\(chapter.title)”的预期时长。")
            }
            let (endFrames, overflow) = cursorFrames.addingReportingOverflow(chapterFrames)
            guard !overflow else {
                throw AudiobookExportError.verificationFailed("M4B 预期章节总时长超出范围。")
            }
            expectedRanges.append((
                title: chapter.title,
                start: Double(cursorFrames) / Double(expected.expectedSampleRate),
                end: Double(endFrames) / Double(expected.expectedSampleRate)
            ))
            cursorFrames = endFrames
        }
        guard cursorFrames == expected.expectedFrameCount else {
            throw AudiobookExportError.verificationFailed("M4B 章节累计帧数与预期整本帧数不一致。")
        }

        let asset = AVURLAsset(url: url)
        do {
            let locales = try await asset.load(.availableChapterLocales)
            guard !locales.isEmpty else {
                throw AudiobookExportError.verificationFailed("M4B 中没有可读取的章节标记。")
            }

            var lastMismatch: AudiobookExportError?
            for locale in locales {
                try Task.checkCancellation()
                let groups = try await asset.loadChapterMetadataGroups(
                    withTitleLocale: locale,
                    containingItemsWithCommonKeys: []
                )
                guard !groups.isEmpty else { continue }
                do {
                    return try await verifyChapterMetadataGroups(groups, against: expectedRanges)
                } catch let error as AudiobookExportError {
                    lastMismatch = error
                }
            }
            if let lastMismatch {
                throw lastMismatch
            }
            throw AudiobookExportError.verificationFailed("M4B 中没有可读取的章节标记。")
        } catch let error as CancellationError {
            throw error
        } catch let error as AudiobookExportError {
            throw error
        } catch {
            throw AudiobookExportError.verificationFailed("AVFoundation 无法读取 M4B 章节标记。")
        }
    }

    private static func verifyChapterMetadataGroups(
        _ groups: [AVTimedMetadataGroup],
        against expectedRanges: [(title: String, start: TimeInterval, end: TimeInterval)]
    ) async throws -> [String] {
        guard groups.count == expectedRanges.count else {
            throw AudiobookExportError.verificationFailed("M4B 实际章节数量与所选章节不一致。")
        }

        var actualRanges: [(title: String, start: TimeInterval, end: TimeInterval)] = []
        for group in groups {
            try Task.checkCancellation()
            let range = group.timeRange
            guard range.isValid,
                  range.start.isNumeric,
                  range.duration.isNumeric,
                  range.start.seconds.isFinite,
                  range.duration.seconds.isFinite,
                  range.start.seconds >= 0,
                  range.duration.seconds > 0
            else {
                throw AudiobookExportError.verificationFailed("M4B 包含无效的章节时间范围。")
            }

            let titleItems = AVMetadataItem.metadataItems(
                from: group.items,
                filteredByIdentifier: .commonIdentifierTitle
            )
            guard titleItems.count == 1,
                  let titleItem = titleItems.first,
                  let actualTitle = try await titleItem.load(.stringValue),
                  !actualTitle.isEmpty
            else {
                throw AudiobookExportError.verificationFailed("M4B 章节缺少唯一且可读取的标题。")
            }

            let actualStart = range.start.seconds
            let actualEnd = actualStart + range.duration.seconds
            guard actualEnd.isFinite else {
                throw AudiobookExportError.verificationFailed("M4B 包含无效的章节结束位置。")
            }
            actualRanges.append((title: actualTitle, start: actualStart, end: actualEnd))
        }
        actualRanges.sort { lhs, rhs in
            lhs.start < rhs.start
        }

        var actualTitles: [String] = []
        for (index, actualRange) in actualRanges.enumerated() {
            let expectedRange = expectedRanges[index]
            let isLastChapter = (index == actualRanges.count - 1)
            // AAC 编码器存在前导延迟与帧对齐填充（Priming & Padding），在 MP4 容器中
            // 最后一章的 timeRange 会自动延伸至整段音频轨道的末尾（对应 verifyDuration 中的 4x 容差）。
            let endTolerance = isLastChapter ? (maxDurationToleranceSeconds * 4) : maxDurationToleranceSeconds
            guard actualRange.title == expectedRange.title,
                  abs(actualRange.start - expectedRange.start) <= maxDurationToleranceSeconds,
                  abs(actualRange.end - expectedRange.end) <= endTolerance
            else {
                throw AudiobookExportError.verificationFailed(
                    "M4B 第 \(index + 1) 章的标题或起止位置与所选章节不一致。"
                )
            }
            actualTitles.append(actualRange.title)
        }
        return actualTitles
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
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
                throw AudiobookExportError.verificationFailed("媒体时长无效。")
            }
            return duration.seconds
        } catch let error as CancellationError {
            throw error
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
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
