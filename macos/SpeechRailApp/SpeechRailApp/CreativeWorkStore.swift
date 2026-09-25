import Foundation

public struct CreativeWork: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let scriptText: String
    public let voiceID: String
    public let voiceName: String
    /// 制作当时实际生效的音色 revision。缺省表示这份记录没有捕捉到身份（老记录）。
    public let voiceRevision: String?
    /// 制作当时服务端固定的 plan 身份；刷新到新 plan 只能由用户显式重做。
    public let planID: String?
    /// 同一份文稿 + 同一个音色的第几次显式制作。老记录按第 1 次读。
    public let renderRevision: Int
    public let createdAt: Date
    public let durationSeconds: Double?
    public let audioFileName: String

    public init(
        id: String,
        title: String,
        scriptText: String,
        voiceID: String,
        voiceName: String,
        voiceRevision: String? = nil,
        planID: String? = nil,
        renderRevision: Int = 1,
        createdAt: Date = Date(),
        durationSeconds: Double? = nil,
        audioFileName: String
    ) {
        self.id = id
        self.title = title
        self.scriptText = scriptText
        self.voiceID = voiceID
        self.voiceName = voiceName
        self.voiceRevision = voiceRevision
        self.planID = planID
        self.renderRevision = max(1, renderRevision)
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.audioFileName = audioFileName
    }

    /// 无损读取：`works.json` 里老记录没有身份字段时必须照样能读出来，
    /// 不补写磁盘、不丢已有项目。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        scriptText = try container.decode(String.self, forKey: .scriptText)
        voiceID = try container.decode(String.self, forKey: .voiceID)
        voiceName = try container.decode(String.self, forKey: .voiceName)
        voiceRevision = try container.decodeIfPresent(String.self, forKey: .voiceRevision)
        planID = try container.decodeIfPresent(String.self, forKey: .planID)
        renderRevision = max(1, try container.decodeIfPresent(Int.self, forKey: .renderRevision) ?? 1)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        audioFileName = try container.decode(String.self, forKey: .audioFileName)
    }
}

public extension CreativeWork {
    /// 作品名的长度上限。自动命名与手动重命名共用同一口径（`CreativeWorkStore.rename`）。
    static let titleMaximumLength = 120
    /// 名称被上限截断时的标记。
    static let titleEllipsis = "…"

    /// 自动命名：取文稿首行的**整行**，超过上限才截断。
    ///
    /// 2026-09-16 之前这里取的是「首行前 24 字 + …」，而 `title` 是持久化字段，
    /// 于是行内永远只能显示那 24 个字——窗口拉宽也不会多显示一个字（用户反馈：
    /// 文本应当随 UI 宽度自然截断、宽度变大时显示更多内容）。名称现在按整行保存，
    /// 显示端的截断交给 `Text` 的 `lineLimit(1)` + 尾部截断按可用宽度处理。
    static func generatedTitle(fromScript text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return clampedTitle(firstLine.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 按上限收敛名称；只有真的超限才补省略号。
    static func clampedTitle(_ text: String) -> String {
        guard text.count > titleMaximumLength else { return text }
        return String(text.prefix(titleMaximumLength)) + titleEllipsis
    }

    /// 面向用户的名称：旧记录里「24 字 + …」的自动名还原成完整首行，不重写磁盘。
    ///
    /// 只有「去掉省略号后的部分确实是这份文稿首行的前缀」时才还原，用户自己改过的
    /// 名字不会被覆盖；对同一份数据反复求值结果一致（已在题内上限的名字仍是它自己）。
    var displayTitle: String {
        guard title.hasSuffix(Self.titleEllipsis), title.count > 1 else { return title }
        let head = String(title.dropLast())
        let firstLine = (scriptText.split(whereSeparator: \.isNewline).first.map(String.init) ?? scriptText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstLine.count > head.count, firstLine.hasPrefix(head) else { return title }
        return Self.clampedTitle(firstLine)
    }

    /// `m:ss`, or nil while the duration has not been read from the audio.
    var durationText: String? {
        guard let durationSeconds else { return nil }
        let totalSeconds = max(0, Int(durationSeconds.rounded()))
        // 稿的时长一律是**零填充的 mm:ss**：`main.js` 里七条作品行的
        // `dur` 是 00:12 / 01:47 / 00:26 / 03:18 / 00:48 / 00:09 / 02:31，
        // 结果条与候选卡也是 00:12；4x 帧 `▸ 我的作品.png` 逐行量到同一形状
        // （分钟两位、冒号、秒两位）。应用此前是 `m:ss`（"0:12"），
        // 在 10 分钟以内与稿不同形（REDESIGN-SPEC §11.6 第四十一轮）。
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    /// Filesystem-safe stem for exporting this work.
    var exportBaseName: String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        let cleaned = displayTitle
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "SpeechRail-作品" : String(cleaned.prefix(80))
    }
}

public enum CreativeWorkStoreError: Error, LocalizedError, Sendable {
    case invalidWorkID
    case invalidTitle
    case storageUnavailable
    case audioUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidWorkID:
            "作品标识无效"
        case .invalidTitle:
            "作品名称不能为空"
        case .storageUnavailable:
            "作品存储暂时不可用"
        case .audioUnavailable:
            "作品音频暂时不可用"
        }
    }
}

@MainActor
public final class CreativeWorkStore {
    private let fileManager: FileManager
    private let directory: URL
    private let indexURL: URL

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let resolvedDirectory = directory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SpeechRail/Works", isDirectory: true)
        self.directory = resolvedDirectory
        self.indexURL = resolvedDirectory.appendingPathComponent("works.json")
    }

    public func list() throws -> [CreativeWork] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CreativeWork].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    public func save(_ work: CreativeWork, audioData: Data) throws {
        guard Self.isSafeIdentifier(work.id),
              work.audioFileName == "\(work.id).wav"
        else {
            throw CreativeWorkStoreError.invalidWorkID
        }
        guard !audioData.isEmpty else {
            throw CreativeWorkStoreError.audioUnavailable
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let audioURL = directory.appendingPathComponent(work.audioFileName, isDirectory: false)
            try audioData.write(to: audioURL, options: [.atomic])

            var works = try list()
            works.removeAll { $0.id == work.id }
            works.append(work)
            try writeIndex(works)
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    /// Removes a work and the audio file it owns. The audio goes first: a
    /// failure then leaves an index entry that still resolves, instead of an
    /// orphaned file no longer reachable from the list (REDESIGN-SPEC §7.4).
    public func delete(_ work: CreativeWork) throws {
        guard Self.isSafeIdentifier(work.id),
              work.audioFileName == "\(work.id).wav"
        else {
            throw CreativeWorkStoreError.invalidWorkID
        }
        do {
            var works = try list()
            guard let index = works.firstIndex(where: { $0.id == work.id }) else { return }
            let audioURL = directory.appendingPathComponent(work.audioFileName, isDirectory: false)
            if fileManager.fileExists(atPath: audioURL.path) {
                try fileManager.removeItem(at: audioURL)
            }
            works.remove(at: index)
            try writeIndex(works)
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    /// Renames a work without touching its audio: the file keeps the
    /// identifier-based name, so a rename never moves bytes on disk
    /// (REDESIGN-SPEC §7.4).
    @discardableResult
    public func rename(_ work: CreativeWork, title: String) throws -> CreativeWork {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CreativeWorkStoreError.invalidTitle
        }
        do {
            var works = try list()
            guard let index = works.firstIndex(where: { $0.id == work.id }) else {
                throw CreativeWorkStoreError.invalidWorkID
            }
            let existing = works[index]
            let updated = CreativeWork(
                id: existing.id,
                title: CreativeWork.clampedTitle(trimmed),
                scriptText: existing.scriptText,
                voiceID: existing.voiceID,
                voiceName: existing.voiceName,
                voiceRevision: existing.voiceRevision,
                planID: existing.planID,
                renderRevision: existing.renderRevision,
                createdAt: existing.createdAt,
                durationSeconds: existing.durationSeconds,
                audioFileName: existing.audioFileName
            )
            works[index] = updated
            try writeIndex(works)
            return updated
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    /// Absolute location of a saved work's audio, without reading it.
    public func audioURL(for work: CreativeWork) throws -> URL {
        guard Self.isSafeIdentifier(work.id),
              work.audioFileName == "\(work.id).wav"
        else {
            throw CreativeWorkStoreError.invalidWorkID
        }
        let audioURL = directory.appendingPathComponent(work.audioFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw CreativeWorkStoreError.audioUnavailable
        }
        return audioURL
    }

    /// 同一份文稿 + 同一个音色的下一次制作编号。
    ///
    /// 作品记录只会追加、不会就地改写：全局默认变了也就不会回头改已有项目，
    /// 只有用户显式重做一次才会产生新的 render revision。
    public func nextRenderRevision(scriptText: String, voiceID: String) throws -> Int {
        let previous = try list()
            .filter { $0.scriptText == scriptText && $0.voiceID == voiceID }
            .map(\.renderRevision)
            .max()
        return (previous ?? 0) + 1
    }

    public func loadAudio(for work: CreativeWork) throws -> Data {
        guard Self.isSafeIdentifier(work.id),
              work.audioFileName == "\(work.id).wav"
        else {
            throw CreativeWorkStoreError.invalidWorkID
        }
        let audioURL = directory.appendingPathComponent(work.audioFileName, isDirectory: false)
        do {
            let data = try Data(contentsOf: audioURL)
            guard !data.isEmpty else { throw CreativeWorkStoreError.audioUnavailable }
            return data
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch {
            throw CreativeWorkStoreError.audioUnavailable
        }
    }

    private func writeIndex(_ works: [CreativeWork]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder
                .encode(works.sorted { $0.createdAt > $1.createdAt })
                .write(to: indexURL, options: [.atomic])
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }
}
