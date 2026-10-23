import Foundation

/// 章节时间表：把一次已核验的整本导出时间轴投影成可直接粘贴的目录文本。
///
/// 时间轴只来自本次导出实际使用的章节顺序与媒体帧数，不按字数、估算语速或再次识别推算；
/// 每章起点都由累计帧一次换算，避免逐章四舍五入累积误差；超过 24 小时继续按小时累计，不回绕到一天。
public struct AudiobookChapterTimeline: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        /// 1 起的章节序号，只用于显示与标识，不参与时间计算。
        public let position: Int
        public let title: String
        /// 从成品开头到本章起点累计的帧数（导出时使用的采样率）。
        public let startFrame: Int64
        /// 起点秒数：由累计帧一次性向下取整，保证跳转不会越过章节开头。
        public let startSeconds: Int64

        public var id: Int { position }

        public var timecode: String {
            AudiobookChapterTimeline.timecode(seconds: startSeconds)
        }

        public init(position: Int, title: String, startFrame: Int64, startSeconds: Int64) {
            self.position = position
            self.title = title
            self.startFrame = startFrame
            self.startSeconds = startSeconds
        }
    }

    public let entries: [Entry]
    public let sampleRate: Int

    /// 每行 `HH:MM:SS<TAB>标题`，行间以单个换行分隔，末尾不带空行。
    /// 复制到剪贴板与保存为文本文件使用同一份字符串，避免两条输出路径漂移。
    public var text: String {
        entries.map { "\($0.timecode)\t\($0.title)" }.joined(separator: "\n")
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// 以导出顺序与每章实际帧数构建时间表。
    ///
    /// - Parameters:
    ///   - chapters: 已按导出顺序排列的章节标题与帧数；顺序必须与成品章节标记一致。
    ///   - sampleRate: 导出时使用的采样率。
    public init(
        chapters: [(title: String, frameCount: Int64)],
        sampleRate: Int
    ) throws {
        guard sampleRate > 0 else {
            throw AudiobookExportError.verificationFailed("章节时间表的采样率无效。")
        }
        guard !chapters.isEmpty else {
            throw AudiobookExportError.verificationFailed("本次导出没有可用于生成时间表的章节。")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(chapters.count)
        var cursorFrames: Int64 = 0
        for (index, chapter) in chapters.enumerated() {
            guard chapter.frameCount > 0 else {
                throw AudiobookExportError.verificationFailed("章节“\(chapter.title)”的时长无效，无法生成时间表。")
            }
            let startFrame = cursorFrames
            let startSeconds = startFrame / Int64(sampleRate)
            entries.append(
                Entry(
                    position: index + 1,
                    title: Self.singleLineTitle(chapter.title, position: index + 1),
                    startFrame: startFrame,
                    startSeconds: startSeconds
                )
            )
            let (nextCursor, overflow) = cursorFrames.addingReportingOverflow(chapter.frameCount)
            guard !overflow else {
                throw AudiobookExportError.verificationFailed("章节时间表超出可表示范围。")
            }
            cursorFrames = nextCursor
        }
        self.entries = entries
        self.sampleRate = sampleRate
    }

    public init(entries: [Entry], sampleRate: Int) {
        self.entries = entries
        self.sampleRate = sampleRate
    }

    /// `HH:MM:SS`，小时不封顶（超过 24 小时继续累加，不做一天回绕）。
    public static func timecode(seconds: Int64) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let remaining = clamped % 60
        return String(format: "%02lld:%02lld:%02lld", hours, minutes, remaining)
    }

    /// 标题压成单行：制表符、换行和其他控制字符折叠为一个空格，首尾空白去掉。
    public static func singleLineTitle(_ raw: String, position: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            let isBreak = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            if isBreak {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        let normalized = String(scalars)
        return normalized.isEmpty ? "第 \(position) 章" : normalized
    }
}

extension AudiobookPreparedExport {
    /// 本次导出可用的章节时间表；只有整本 M4B 有单文件时间轴，分章 MP3 继续使用目录清单。
    public func makeChapterTimeline() throws -> AudiobookChapterTimeline {
        guard profile == .m4b else {
            throw AudiobookExportError.timelineUnsupportedForProfile
        }
        let ordered = exportedChapters.sorted { $0.ordinal < $1.ordinal }
        let chapters: [(title: String, frameCount: Int64)] = try ordered.map { chapter in
            guard let frames = expectedChapterFrameCounts[chapter.id], frames > 0 else {
                throw AudiobookExportError.verificationFailed("章节“\(chapter.title)”缺少可用于时间表的实际时长。")
            }
            return (title: chapter.title, frameCount: frames)
        }
        return try AudiobookChapterTimeline(chapters: chapters, sampleRate: expectedSampleRate)
    }
}

/// 一次已成功保存的导出结果：音频已经落盘，章节时间表可以单独重试，不重新编码也不影响音频。
public struct AudiobookCompletedExport: Equatable, Sendable {
    public let bookID: UUID
    public let bookTitle: String
    public let profile: AudiobookExportProfile
    public let destinationURL: URL
    public let timeline: AudiobookChapterTimeline?

    public init(
        bookID: UUID,
        bookTitle: String,
        profile: AudiobookExportProfile,
        destinationURL: URL,
        timeline: AudiobookChapterTimeline?
    ) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.profile = profile
        self.destinationURL = destinationURL
        self.timeline = timeline
    }

    public var defaultTimelineFileName: String {
        "\(AudiobookChapterTimeline.singleLineTitle(bookTitle, position: 1))-章节时间表.txt"
    }
}

/// 章节时间表写盘：与音频导出解耦，写失败不影响已经保存的音频。
public enum AudiobookChapterTimelineWriter {
    public static func write(
        _ timeline: AudiobookChapterTimeline,
        to destination: URL,
        overwriteConsent: AudiobookOverwriteConsent? = nil
    ) throws {
        let fm = FileManager.default
        let standardizedDest = destination.standardizedFileURL
        let parentDir = standardizedDest.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            throw AudiobookExportError.timelineSaveFailed(error.localizedDescription)
        }

        if fm.fileExists(atPath: standardizedDest.path) {
            guard let consent = overwriteConsent, consent.destinationURL == standardizedDest else {
                throw AudiobookExportError.overwriteConsentRequired(standardizedDest)
            }
            let current: AudiobookOverwriteConsent
            do {
                current = try AudiobookOverwriteConsent.capture(at: standardizedDest)
            } catch {
                throw AudiobookExportError.timelineSaveFailed(error.localizedDescription)
            }
            guard current.existingFileSize == consent.existingFileSize,
                  consent.existingSHA256 == nil || current.existingSHA256 == consent.existingSHA256
            else {
                throw AudiobookExportError.destinationModifiedAfterConsent(standardizedDest)
            }
        }

        let siblingTemp = parentDir.appendingPathComponent(
            ".\(standardizedDest.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fm.removeItem(at: siblingTemp) }

        do {
            try Data(timeline.text.utf8).write(to: siblingTemp, options: .atomic)
            if fm.fileExists(atPath: standardizedDest.path) {
                guard let consent = overwriteConsent else {
                    throw AudiobookExportError.overwriteConsentRequired(standardizedDest)
                }
                let latest = try AudiobookOverwriteConsent.capture(at: standardizedDest)
                guard latest.existingFileSize == consent.existingFileSize,
                      consent.existingSHA256 == nil || latest.existingSHA256 == consent.existingSHA256
                else {
                    throw AudiobookExportError.destinationModifiedAfterConsent(standardizedDest)
                }
                _ = try fm.replaceItemAt(standardizedDest, withItemAt: siblingTemp)
            } else {
                try fm.moveItem(at: siblingTemp, to: standardizedDest)
            }
        } catch let error as AudiobookExportError {
            throw error
        } catch {
            throw AudiobookExportError.timelineSaveFailed(error.localizedDescription)
        }
    }
}
