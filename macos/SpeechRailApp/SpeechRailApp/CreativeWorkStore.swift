import CryptoKit
import Darwin
import Foundation
import SpeechRailControlKit

/// 一份作品被保存时固定下来的制作与追溯事实。
///
/// 只记录服务端真正报告过的内容。老作品没有这些字段时读成
/// `legacyUnknown`，不回填、不猜测，也不因此拒绝读取。
public struct RenderProvenanceSnapshot: Codable, Equatable, Sendable {
    public static let legacyReason = "legacy_record_without_provenance"
    public static let legacyUnknown = RenderProvenanceSnapshot(
        state: .unavailable,
        reason: legacyReason
    )

    public let state: RenderProvenance.State
    /// 稳定原因码，供诊断用；不是面向用户的文案。
    public let reason: String?
    /// plan_id 背后的完整摘要。
    public let planSHA256: String?
    /// 这一次渲染实际执行了什么；服务端没组装就是 nil。
    public let recipe: RenderRecipeSnapshot?
    /// 服务端在 PCM 传输前算出的摘要。它与保存文件的字节摘要不是一回事。
    public let pcmSHA256: String?
    /// 保存下来的音频文件字节摘要，由作品库在提交时计算。
    public let audioFileSHA256: String?

    public init(
        state: RenderProvenance.State,
        reason: String?,
        planSHA256: String? = nil,
        recipe: RenderRecipeSnapshot? = nil,
        pcmSHA256: String? = nil,
        audioFileSHA256: String? = nil
    ) {
        self.state = state
        self.reason = reason
        self.planSHA256 = planSHA256
        self.recipe = recipe
        self.pcmSHA256 = pcmSHA256
        self.audioFileSHA256 = audioFileSHA256
    }

    public func withAudioFileSHA256(_ digest: String?) -> RenderProvenanceSnapshot {
        RenderProvenanceSnapshot(
            state: state,
            reason: reason,
            planSHA256: planSHA256,
            recipe: recipe,
            pcmSHA256: pcmSHA256,
            audioFileSHA256: digest
        )
    }

    /// 这件作品能不能按段落返修。
    ///
    /// 段落返修的前提是「这次重做与原作品是同一制作条件」，而这件事只能靠配方
    /// 摘要证明。老作品读作 `legacyUnknown`、没有摘要，重做必然被拒。
    /// 因此入口本身就不该出现——摆出一个点下去一定失败的动作，比不摆更糟。
    public var supportsSegmentRedo: Bool {
        recipe?.digest != nil
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case reason
        case planSHA256 = "plan_sha256"
        case recipe
        case pcmSHA256 = "pcm_sha256"
        case audioFileSHA256 = "audio_file_sha256"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(
            RenderProvenance.State.self,
            forKey: .state
        ) ?? .unavailable
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        planSHA256 = try container.decodeIfPresent(String.self, forKey: .planSHA256)
        recipe = try container.decodeIfPresent(RenderRecipeSnapshot.self, forKey: .recipe)
        pcmSHA256 = try container.decodeIfPresent(String.self, forKey: .pcmSHA256)
        audioFileSHA256 = try container.decodeIfPresent(String.self, forKey: .audioFileSHA256)
    }
}

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
    /// 保存当时固定下来的制作配方与追溯状态。老作品读成 `legacyUnknown`。
    public let provenance: RenderProvenanceSnapshot

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
        audioFileName: String,
        provenance: RenderProvenanceSnapshot = .legacyUnknown
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
        self.provenance = provenance
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
        provenance = try container.decodeIfPresent(
            RenderProvenanceSnapshot.self,
            forKey: .provenance
        ) ?? .legacyUnknown
    }
}

public extension CreativeWork {
    /// 作品名的长度上限。自动命名与手动重命名共用这一口径（`CreativeWorkStore.rename`）。
    static let titleMaximumLength = 120
    /// 名称被上限截断时的标记。
    static let titleEllipsis = "…"

    /// 自动命名：取文稿首行的**整行**，超过上限才截断。
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
    var displayTitle: String {
        guard title.hasSuffix(Self.titleEllipsis), title.count > 1 else { return title }
        let head = String(title.dropLast())
        let firstLine = (scriptText.split(whereSeparator: \.isNewline).first.map(String.init) ?? scriptText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstLine.count > head.count, firstLine.hasPrefix(head) else { return title }
        return Self.clampedTitle(firstLine)
    }

    /// `mm:ss`, or nil while the duration has not been read from the audio.
    var durationText: String? {
        guard let durationSeconds else { return nil }
        let totalSeconds = max(0, Int(durationSeconds.rounded()))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    /// Returns a copy carrying new provenance. Identity and audio stay put:
    /// a saved work never has its creation facts rewritten.
    func withProvenance(_ provenance: RenderProvenanceSnapshot) -> CreativeWork {
        CreativeWork(
            id: id,
            title: title,
            scriptText: scriptText,
            voiceID: voiceID,
            voiceName: voiceName,
            voiceRevision: voiceRevision,
            planID: planID,
            renderRevision: renderRevision,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            audioFileName: audioFileName,
            provenance: provenance
        )
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
    case workConflict
    case storageUnavailable
    case recoveryRequired
    case audioUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidWorkID:
            "作品标识无效"
        case .invalidTitle:
            "作品名称不能为空"
        case .workConflict:
            "已有另一份作品占用这个标识，未覆盖现有音频"
        case .storageUnavailable:
            "作品存储暂时不可用"
        case .recoveryRequired:
            "作品存储需要恢复，请重新打开作品库"
        case .audioUnavailable:
            "作品音频暂时不可用"
        }
    }
}

@MainActor
public final class CreativeWorkStore {
    private let operations: CreativeWorkFileOperations
    private let directory: URL
    private let indexURL: URL
    private let lockURL: URL
    private let transactionsDirectory: URL
    private let recoveryDirectory: URL

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.operations = CreativeWorkFileOperations(fileManager: fileManager)
        let resolvedDirectory = directory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SpeechRail/Works", isDirectory: true)
        self.directory = resolvedDirectory
        self.indexURL = resolvedDirectory.appendingPathComponent("works.json")
        self.lockURL = resolvedDirectory.appendingPathComponent(".works.lock", isDirectory: false)
        self.transactionsDirectory = resolvedDirectory
            .appendingPathComponent(".transactions", isDirectory: true)
        self.recoveryDirectory = resolvedDirectory
            .appendingPathComponent(".recovery", isDirectory: true)
    }

    init(
        directory: URL,
        fileManager: FileManager = .default,
        fileOperations: CreativeWorkFileOperations
    ) {
        self.operations = fileOperations
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("works.json")
        self.lockURL = directory.appendingPathComponent(".works.lock", isDirectory: false)
        self.transactionsDirectory = directory
            .appendingPathComponent(".transactions", isDirectory: true)
        self.recoveryDirectory = directory
            .appendingPathComponent(".recovery", isDirectory: true)
    }

    public func list() throws -> [CreativeWork] {
        try withRecoveredLibrary {
            try readIndexUnlocked()
        }
    }

    @discardableResult
    public func save(_ work: CreativeWork, audioData: Data) throws -> CreativeWork {
        guard Self.isSafeIdentifier(work.id),
              work.audioFileName == "\(work.id).wav"
        else {
            throw CreativeWorkStoreError.invalidWorkID
        }
        guard !audioData.isEmpty else {
            throw CreativeWorkStoreError.audioUnavailable
        }
        return try withRecoveredLibrary {
            var works = try readIndexUnlocked()
            let audioURL = directory.appendingPathComponent(
                work.audioFileName,
                isDirectory: false
            )
            if let existing = works.first(where: { $0.id == work.id }) {
                guard !operations.isSymbolicLink(at: audioURL) else {
                    throw CreativeWorkStoreError.audioUnavailable
                }
                let existingAudio = try operations.read(from: audioURL)
                guard sameResult(existing, work, existingAudio: existingAudio, audioData: audioData)
                else {
                    throw CreativeWorkStoreError.workConflict
                }
                return existing
            }
            guard !operations.fileExists(at: audioURL) else {
                // No index entry proves ownership. Never overwrite or adopt it.
                throw CreativeWorkStoreError.workConflict
            }

            // The stored bytes are the file, so their digest belongs in the
            // record the library commits — not in what the caller handed over.
            let audioDigest = CreativeWorkTransaction.digest(audioData)
            let committed = work.withProvenance(
                work.provenance.withAudioFileSHA256(audioDigest)
            )
            works.append(committed)
            try commitIndexMutationUnlocked(
                works: works,
                operation: .save,
                work: committed,
                audioSHA256: audioDigest
            ) { transactionDirectory in
                let stagedURL = transactionDirectory
                    .appendingPathComponent("staged.wav", isDirectory: false)
                try self.operations.write(audioData, to: stagedURL)
                try self.operations.synchronize(at: stagedURL)
                try self.operations.move(from: stagedURL, to: audioURL)
                try self.operations.synchronize(at: audioURL)
            }
            return committed
        }
    }

    /// Removes the work from the index first, then moves its audio into a managed
    /// recovery area. An interrupted delete is completed on the next open.
    public func delete(_ work: CreativeWork) throws {
        guard Self.isSafeIdentifier(work.id),
              work.audioFileName == "\(work.id).wav"
        else {
            throw CreativeWorkStoreError.invalidWorkID
        }
        try withRecoveredLibrary {
            var works = try readIndexUnlocked()
            guard let index = works.firstIndex(where: { $0.id == work.id }) else { return }
            let existing = works.remove(at: index)
            let audioURL = directory.appendingPathComponent(
                existing.audioFileName,
                isDirectory: false
            )
            guard !operations.isSymbolicLink(at: audioURL) else {
                throw CreativeWorkStoreError.audioUnavailable
            }
            let audioDigest = operations.fileExists(at: audioURL)
                ? CreativeWorkTransaction.digest(try operations.read(from: audioURL))
                : nil
            try commitIndexMutationUnlocked(
                works: works,
                operation: .delete,
                work: existing,
                audioSHA256: audioDigest
            )
            // The index commit is the user-visible deletion. Quarantine work is
            // recovery work and must never be reported as a failed deletion.
            if let journal = try pendingJournalUnlocked(),
               journal.operation == .delete
            {
                try? completeCommittedDeleteUnlocked(journal)
            }
        }
    }

    /// Renames a work without touching its audio: the file keeps the
    /// identifier-based name, so a rename never moves bytes on disk.
    @discardableResult
    public func rename(_ work: CreativeWork, title: String) throws -> CreativeWork {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CreativeWorkStoreError.invalidTitle
        }
        return try withRecoveredLibrary {
            var works = try readIndexUnlocked()
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
                audioFileName: existing.audioFileName,
                provenance: existing.provenance
            )
            works[index] = updated
            try commitIndexMutationUnlocked(
                works: works,
                operation: .rename,
                work: updated,
                audioSHA256: nil
            )
            return updated
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
        return try withRecoveredLibrary {
            guard !operations.isSymbolicLink(at: audioURL) else {
                throw CreativeWorkStoreError.audioUnavailable
            }
            guard operations.fileExists(at: audioURL) else {
                throw CreativeWorkStoreError.audioUnavailable
            }
            return audioURL
        }
    }

    /// 同一份文稿 + 同一个音色的下一次制作编号。
    public func nextRenderRevision(scriptText: String, voiceID: String) throws -> Int {
        let previous = try withRecoveredLibrary {
            try readIndexUnlocked()
        }
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
        return try withRecoveredLibrary {
            guard !operations.isSymbolicLink(at: audioURL) else {
                throw CreativeWorkStoreError.audioUnavailable
            }
            do {
                let data = try operations.read(from: audioURL)
                guard !data.isEmpty else {
                    throw CreativeWorkStoreError.audioUnavailable
                }
                return data
            } catch let error as CreativeWorkStoreError {
                throw error
            } catch {
                throw CreativeWorkStoreError.audioUnavailable
            }
        }
    }

    private func withRecoveredLibrary<T>(_ body: () throws -> T) throws -> T {
        do {
            try operations.createDirectory(at: directory)
            let lock = try operations.acquireExclusiveLock(at: lockURL)
            defer { operations.releaseExclusiveLock(lock) }
            try recoverPendingTransactionsUnlocked()
            return try body()
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch let error as CreativeWorkTransactionInterruption {
            throw error
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    private func readIndexUnlocked() throws -> [CreativeWork] {
        guard operations.fileExists(at: indexURL) else { return [] }
        guard !operations.isSymbolicLink(at: indexURL) else {
            throw CreativeWorkStoreError.storageUnavailable
        }
        do {
            let data = try operations.read(from: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CreativeWork].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    private func encodedIndex(_ works: [CreativeWork]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(works.sorted { $0.createdAt > $1.createdAt })
    }

    private func indexDataUnlocked() throws -> Data? {
        guard operations.fileExists(at: indexURL) else { return nil }
        guard !operations.isSymbolicLink(at: indexURL) else {
            throw CreativeWorkStoreError.storageUnavailable
        }
        do {
            return try operations.read(from: indexURL)
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    private func indexDigestUnlocked() throws -> String? {
        try indexDataUnlocked().map(CreativeWorkTransaction.digest)
    }

    private func commitIndexMutationUnlocked(
        works: [CreativeWork],
        operation: CreativeWorkTransactionOperation,
        work: CreativeWork,
        audioSHA256: String?,
        preCommit: ((URL) throws -> Void)? = nil
    ) throws {
        let previousData = try indexDataUnlocked()
        let previousDigest = previousData.map(CreativeWorkTransaction.digest)
        let committedData: Data
        do {
            committedData = try encodedIndex(works)
        } catch {
            throw CreativeWorkStoreError.storageUnavailable
        }
        let transactionID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let transactionDirectory = transactionsDirectory
            .appendingPathComponent(transactionID, isDirectory: true)
        let journal = CreativeWorkTransactionJournal(
            transactionID: transactionID,
            operation: operation,
            workID: work.id,
            audioFileName: work.audioFileName,
            audioSHA256: audioSHA256,
            previousIndexSHA256: previousDigest,
            previousIndexData: previousData,
            committedIndexSHA256: CreativeWorkTransaction.digest(committedData)
        )
        do {
            try operations.createDirectory(at: transactionDirectory)
            let journalURL = transactionDirectory
                .appendingPathComponent("journal.json", isDirectory: false)
            try operations.write(
                CreativeWorkTransaction.encodeJournal(journal),
                to: journalURL
            )
            try operations.synchronize(at: journalURL)
            try operations.synchronize(at: transactionDirectory)
            try preCommit?(transactionDirectory)

            do {
                try operations.write(committedData, to: indexURL)
                try operations.synchronize(at: indexURL)
                try operations.synchronize(at: directory)
            } catch {
                if error is CreativeWorkTransactionInterruption {
                    // A real process exit skips every catch block. The journal
                    // stays so the next open decides from the index digest.
                    throw error
                }
                try? rollbackUncommittedMutationUnlocked(
                    journal: journal,
                    transactionDirectory: transactionDirectory
                )
                throw CreativeWorkStoreError.storageUnavailable
            }
            if operation != .delete {
                try? removeTransactionDirectoryUnlocked(transactionDirectory)
            }
        } catch let error as CreativeWorkStoreError {
            throw error
        } catch let error as CreativeWorkTransactionInterruption {
            throw error
        } catch {
            try? removeTransactionDirectoryUnlocked(transactionDirectory)
            throw CreativeWorkStoreError.storageUnavailable
        }
    }

    private func rollbackUncommittedMutationUnlocked(
        journal: CreativeWorkTransactionJournal,
        transactionDirectory: URL
    ) throws {
        if let previousData = journal.previousIndexData {
            // 尽力而为，不能让这一步决定整段回滚的命运。
            //
            // 回滚只发生在索引写入失败之后，而索引用原子写：写失败即代表它没被改动，
            // 所以这里重写旧内容只是兜底。可一旦索引是因为磁盘满、权限变更这类
            // **持续性**原因写不动，重写就必然再次失败——若让它抛出去，
            // 后面删除未提交音频、清掉事务目录这两步仍然做得到的事就全被跳过，
            // 而调用方是 `try?`，失败还会被完全吞掉。
            try? operations.write(previousData, to: indexURL)
            try? operations.synchronize(at: indexURL)
        } else if operations.fileExists(at: indexURL) {
            try operations.remove(at: indexURL)
        }
        if journal.operation == .save,
           let expectedDigest = journal.audioSHA256,
           try indexDigestUnlocked() == journal.previousIndexSHA256
        {
            let audioURL = directory.appendingPathComponent(
                journal.audioFileName,
                isDirectory: false
            )
            if !operations.isSymbolicLink(at: audioURL),
               operations.fileExists(at: audioURL),
               CreativeWorkTransaction.digest(try operations.read(from: audioURL))
                    == expectedDigest
            {
                try operations.remove(at: audioURL)
            }
        }
        try operations.synchronize(at: directory)
        try removeTransactionDirectoryUnlocked(transactionDirectory)
    }

    private func pendingJournalUnlocked() throws -> CreativeWorkTransactionJournal? {
        guard let transactionDirectory = try pendingTransactionDirectoryUnlocked() else {
            return nil
        }
        let journalURL = transactionDirectory
            .appendingPathComponent("journal.json", isDirectory: false)
        guard !operations.isSymbolicLink(at: journalURL),
              operations.fileExists(at: journalURL)
        else {
            throw CreativeWorkStoreError.recoveryRequired
        }
        do {
            return try CreativeWorkTransaction.decodeJournal(
                operations.read(from: journalURL)
            )
        } catch {
            throw CreativeWorkStoreError.recoveryRequired
        }
    }

    private func recoverPendingTransactionsUnlocked() throws {
        guard let journal = try pendingJournalUnlocked() else { return }
        guard let transactionDirectory = try pendingTransactionDirectoryUnlocked(),
              transactionDirectory.lastPathComponent == journal.transactionID
        else {
            throw CreativeWorkStoreError.recoveryRequired
        }
        let currentDigest = try indexDigestUnlocked()
        if currentDigest == journal.committedIndexSHA256 {
            switch journal.operation {
            case .save:
                let audioURL = directory.appendingPathComponent(
                    journal.audioFileName,
                    isDirectory: false
                )
                guard !operations.isSymbolicLink(at: audioURL),
                      operations.fileExists(at: audioURL),
                      let expectedDigest = journal.audioSHA256,
                      CreativeWorkTransaction.digest(
                        try operations.read(from: audioURL)
                      ) == expectedDigest
                else {
                    throw CreativeWorkStoreError.recoveryRequired
                }
                try? removeTransactionDirectoryUnlocked(transactionDirectory)
            case .delete:
                try completeCommittedDeleteUnlocked(journal)
            case .rename:
                try? removeTransactionDirectoryUnlocked(transactionDirectory)
            }
            return
        }
        guard currentDigest == journal.previousIndexSHA256 else {
            throw CreativeWorkStoreError.recoveryRequired
        }
        switch journal.operation {
        case .save:
            let audioURL = directory.appendingPathComponent(
                journal.audioFileName,
                isDirectory: false
            )
            if !operations.isSymbolicLink(at: audioURL),
               operations.fileExists(at: audioURL),
               let expectedDigest = journal.audioSHA256,
               CreativeWorkTransaction.digest(try operations.read(from: audioURL))
                    == expectedDigest
            {
                try operations.remove(at: audioURL)
            }
        case .delete, .rename:
            break
        }
        try? removeTransactionDirectoryUnlocked(transactionDirectory)
    }

    private func pendingTransactionDirectoryUnlocked() throws -> URL? {
        guard operations.fileExists(at: transactionsDirectory) else { return nil }
        let transactionDirectories = try operations
            .contentsOfDirectory(at: transactionsDirectory)
            .filter { $0.lastPathComponent.isValidTransactionIdentifier }
        guard transactionDirectories.count <= 1 else {
            throw CreativeWorkStoreError.recoveryRequired
        }
        return transactionDirectories.first
    }

    private func completeCommittedDeleteUnlocked(
        _ journal: CreativeWorkTransactionJournal
    ) throws {
        guard let transactionDirectory = try pendingTransactionDirectoryUnlocked(),
              transactionDirectory.lastPathComponent == journal.transactionID
        else {
            throw CreativeWorkStoreError.recoveryRequired
        }
        let audioURL = directory.appendingPathComponent(
            journal.audioFileName,
            isDirectory: false
        )
        guard !operations.isSymbolicLink(at: audioURL) else {
            // The journal names a managed path. A link there is not our asset,
            // and moving it would either follow the link or destroy a foreign target.
            throw CreativeWorkStoreError.recoveryRequired
        }
        if operations.fileExists(at: audioURL) {
            let preservedURL = transactionDirectory
                .appendingPathComponent(journal.audioFileName, isDirectory: false)
            if !operations.fileExists(at: preservedURL) {
                try operations.move(from: audioURL, to: preservedURL)
            }
            try operations.synchronize(at: preservedURL)
        }
        try operations.createDirectory(at: recoveryDirectory)
        let destination = recoveryDirectory
            .appendingPathComponent(journal.transactionID, isDirectory: true)
        if operations.fileExists(at: destination) {
            try operations.remove(at: transactionDirectory)
        } else {
            try operations.move(from: transactionDirectory, to: destination)
        }
        try operations.synchronize(at: recoveryDirectory)
    }

    private func removeTransactionDirectoryUnlocked(_ url: URL) throws {
        guard operations.fileExists(at: url) else { return }
        try operations.remove(at: url)
        try operations.synchronize(at: transactionsDirectory)
    }

    private func sameResult(
        _ existing: CreativeWork,
        _ candidate: CreativeWork,
        existingAudio: Data,
        audioData: Data
    ) -> Bool {
        existing.id == candidate.id
            && existing.scriptText == candidate.scriptText
            && existing.voiceID == candidate.voiceID
            && existing.voiceRevision == candidate.voiceRevision
            && existing.planID == candidate.planID
            && existing.renderRevision == candidate.renderRevision
            && CreativeWorkTransaction.digest(existingAudio)
                == CreativeWorkTransaction.digest(audioData)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }
}

private extension String {
    var isValidTransactionIdentifier: Bool {
        range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
    }
}

/// Test-only interruption marker. Production code never creates this value; it
/// lets a deterministic fake model a process exit at an exact persistence step.
enum CreativeWorkTransactionInterruption: Error, Equatable {
    case simulatedProcessExit
}

/// Narrow file boundary for the works library. Tests inject failures at real
/// transaction steps instead of replacing `FileManager` wholesale.
struct CreativeWorkFileOperations {
    typealias WriteInterceptor = (URL, Data) throws -> Void
    typealias MoveInterceptor = (URL, URL) throws -> Void
    typealias SyncInterceptor = (URL) throws -> Void

    private let fileManager: FileManager
    private let writeInterceptor: WriteInterceptor?
    private let moveInterceptor: MoveInterceptor?
    private let syncInterceptor: SyncInterceptor?

    init(
        fileManager: FileManager = .default,
        writeInterceptor: WriteInterceptor? = nil,
        moveInterceptor: MoveInterceptor? = nil,
        syncInterceptor: SyncInterceptor? = nil
    ) {
        self.fileManager = fileManager
        self.writeInterceptor = writeInterceptor
        self.moveInterceptor = moveInterceptor
        self.syncInterceptor = syncInterceptor
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func fileExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    func isSymbolicLink(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try writeInterceptor?(url, data)
        try data.write(to: url, options: [.atomic])
    }

    func move(from source: URL, to destination: URL) throws {
        try moveInterceptor?(source, destination)
        try fileManager.moveItem(at: source, to: destination)
    }

    func remove(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func synchronize(at url: URL) throws {
        try syncInterceptor?(url)
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { Darwin.close(descriptor) }
        if fsync(descriptor) != 0, errno != EINVAL {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func acquireExclusiveLock(at url: URL) throws -> CreativeWorkFileLock {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return CreativeWorkFileLock(descriptor: descriptor)
    }

    func releaseExclusiveLock(_ lock: CreativeWorkFileLock) {
        flock(lock.descriptor, LOCK_UN)
        Darwin.close(lock.descriptor)
    }
}

struct CreativeWorkFileLock {
    fileprivate let descriptor: Int32
}

enum CreativeWorkTransactionOperation: String, Codable {
    case save
    case delete
    case rename
}

struct CreativeWorkTransactionJournal: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let transactionID: String
    let operation: CreativeWorkTransactionOperation
    let workID: String
    let audioFileName: String
    let audioSHA256: String?
    let previousIndexSHA256: String?
    let previousIndexData: Data?
    let committedIndexSHA256: String

    init(
        transactionID: String,
        operation: CreativeWorkTransactionOperation,
        workID: String,
        audioFileName: String,
        audioSHA256: String?,
        previousIndexSHA256: String?,
        previousIndexData: Data?,
        committedIndexSHA256: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.transactionID = transactionID
        self.operation = operation
        self.workID = workID
        self.audioFileName = audioFileName
        self.audioSHA256 = audioSHA256
        self.previousIndexSHA256 = previousIndexSHA256
        self.previousIndexData = previousIndexData
        self.committedIndexSHA256 = committedIndexSHA256
    }
}

enum CreativeWorkTransaction {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encodeJournal(_ journal: CreativeWorkTransactionJournal) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(journal)
    }

    static func decodeJournal(_ data: Data) throws -> CreativeWorkTransactionJournal {
        let journal = try JSONDecoder().decode(CreativeWorkTransactionJournal.self, from: data)
        guard journal.schemaVersion == CreativeWorkTransactionJournal.currentSchemaVersion,
              journal.transactionID.range(
                of: "^[a-f0-9]{32}$",
                options: .regularExpression
              ) != nil,
              journal.workID.range(
                of: "^[A-Za-z0-9_-]{1,80}$",
                options: .regularExpression
              ) != nil,
              journal.audioFileName == "\(journal.workID).wav"
        else {
            throw CocoaError(.coderInvalidValue)
        }
        return journal
    }
}
