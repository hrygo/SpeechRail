import Foundation

/// 一个配音项目：整段文稿拆成若干段落，每段可以有多次候选。
///
/// 项目本身持有**完整制作配方**。段落候选只有在配方与文本都没变时才可复用；
/// 任何一项对不上就整体失效——宁可要求重做，也不拼接来历不明的音频。
public struct DubbingProject: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// 用户保存的原始文稿。导出正文以段落为准，这里保留全文供编辑对照。
    public let scriptText: String
    /// 整个项目共享的制作配方。改动配方等于换一次制作，全部候选失效。
    public let recipe: RenderProvenanceSnapshot
    public var segments: [DubbingSegment]
    public let createdAt: Date

    public init(
        id: String,
        title: String,
        scriptText: String,
        recipe: RenderProvenanceSnapshot,
        segments: [DubbingSegment],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.scriptText = scriptText
        self.recipe = recipe
        self.segments = segments
        self.createdAt = createdAt
    }

    /// 导出正文：只包含已采用候选对应的段落文本，按段落顺序拼接。
    ///
    /// 没有采用候选的段落不会被跳过或编造——正文必须与导出的音频一一对应。
    public var adoptedScript: String {
        segments
            .filter { $0.acceptedCandidateID != nil }
            .map(\.text)
            .joined(separator: "\n")
    }

    /// 仍然有效的候选：配方与文本都对得上。
    ///
    /// 没有配方摘要的项目一律判为失效：无法证明两次制作是同一条件。
    public func isValid(_ candidate: DubbingCandidate) -> Bool {
        guard let projectDigest = recipe.recipe?.digest,
              let candidateDigest = candidate.provenance.recipe?.digest,
              projectDigest == candidateDigest
        else { return false }
        guard let segment = segments.first(where: { $0.id == candidate.segmentID }) else {
            return false
        }
        return segment.text == candidate.text
    }
}

/// 项目中的一段。只有显式采用候选才决定这一段最终导出什么。
public struct DubbingSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public var acceptedCandidateID: String?
    /// 采用历史，末尾是当前采用项的上一版。`nil` 表示"此前没有采用任何候选"，
    /// 与"采用过一个候选"是两种不同状态，所以这里必须能存 nil。
    /// 撤销从这里回退，不删除任何音频。
    public var adoptionHistory: [String?]

    public init(
        id: String,
        text: String,
        acceptedCandidateID: String? = nil,
        adoptionHistory: [String?] = []
    ) {
        self.id = id
        self.text = text
        self.acceptedCandidateID = acceptedCandidateID
        self.adoptionHistory = adoptionHistory
    }

    /// 撤销一步采用；没有历史时返回 false，不改变当前采用项。
    public mutating func undoAdoption() -> Bool {
        guard let previous = adoptionHistory.popLast() else { return false }
        acceptedCandidateID = previous
        return true
    }
}

/// 一次段落重做的产物。候选只是资产：保存它不会改变项目当前采用什么。
public struct DubbingCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let segmentID: String
    /// 实际送去合成的文本。与段落文本不一致时不可复用。
    public let text: String
    public let audioFileName: String
    public let provenance: RenderProvenanceSnapshot
    public let createdAt: Date
    public let durationSeconds: Double?

    public init(
        id: String,
        segmentID: String,
        text: String,
        audioFileName: String,
        provenance: RenderProvenanceSnapshot,
        createdAt: Date = Date(),
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.segmentID = segmentID
        self.text = text
        self.audioFileName = audioFileName
        self.provenance = provenance
        // 索引以 ISO8601（秒精度）落盘：这里就收敛到整秒，
        // 让内存里的候选和重启后读回的候选完全一致。
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.durationSeconds = durationSeconds
    }
}

public enum DubbingProjectError: Error, LocalizedError, Sendable {
    case invalidIdentifier
    case segmentNotFound
    case candidateNotFound
    case candidateNotAdoptable
    /// 候选音频不是本项目支持的线性 PCM 剖面（单声道 16 bit）。
    case audioFormatUnsupported
    /// 参与拼接的候选格式互不相同，拼接结果无法标定采样率。
    case audioFormatMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "配音项目标识无效"
        case .segmentNotFound:
            "找不到这一段"
        case .candidateNotFound:
            "找不到这个候选"
        case .candidateNotAdoptable:
            "这个候选的制作条件与当前项目不一致，需要重新生成"
        case .audioFormatUnsupported:
            "候选音频不是单声道 16 bit 线性 PCM，无法与其它段落拼接"
        case .audioFormatMismatch:
            "各段音频的采样率或位深不一致，不能拼成一个成品"
        }
    }
}

/// 把一篇文稿切成可独立重做的段落。
///
/// 切分只用文稿本身：先按换行分段，段落太长时按句末标点累积，仍太长才按字数硬切。
/// 这里**不产生任何时间戳**——没有可靠时序就不给字幕，也不猜每段在音频里的位置。
public enum DubbingSegmentPlanner {
    /// 单段目标上限。与服务端分段器同量级：一段是一次真实请求，段太长不利于局部返修。
    public static let maximumCharactersPerSegment = 180
    /// 句末标点。命中后可以断段，但太短的段落会与下一句合并，避免碎片化。
    private static let sentenceTerminators: Set<Character> = [
        "。", "！", "？", "；", "…",
        ".", "!", "?", ";",
    ]
    private static let minimumCharactersPerSegment = 12

    /// 返回顺序即导出顺序。没有可切分内容时返回空数组。
    public static func segments(from scriptText: String) -> [String] {
        var segments: [String] = []
        for paragraph in scriptText
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            where !paragraph.isEmpty
        {
            segments.append(contentsOf: splitParagraph(paragraph))
        }
        return segments
    }

    private static func splitParagraph(_ paragraph: String) -> [String] {
        guard paragraph.count > maximumCharactersPerSegment else { return [paragraph] }
        var pieces: [String] = []
        var current = ""
        for character in paragraph {
            current.append(character)
            let isTerminator = sentenceTerminators.contains(character)
            if current.count >= maximumCharactersPerSegment {
                pieces.append(current)
                current = ""
            } else if isTerminator, current.count >= minimumCharactersPerSegment {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            // 收尾时并回上一段：宁可略超上限，也不留一个两三个字的碎段。
            if pieces.isEmpty || current.count < minimumCharactersPerSegment {
                pieces[pieces.count - 1] += current
            } else {
                pieces.append(current)
            }
        }
        return pieces
    }
}

/// 一次导出的成品：音频与正文必须一一对应，所以打包在一起交给上层写出。
public struct DubbingExportBundle: Equatable, Sendable {
    public let baseName: String
    public let audio: Data
    public let script: String

    public init(baseName: String, audio: Data, script: String) {
        self.baseName = baseName
        self.audio = audio
        self.script = script
    }

    public var scriptFileName: String { "\(baseName).txt" }
    public var audioFileName: String { "\(baseName).wav" }
}

/// 落盘的一条项目记录：项目本身加上它拥有的全部候选。
///
/// 候选音频存在同目录的 `<candidateID>.wav`。索引是唯一的逻辑提交点：
/// 索引里没有的音频就是没有资产的候选，不会被 UI 当成可试听内容。
struct DubbingProjectRecord: Codable, Equatable, Sendable {
    var project: DubbingProject
    var candidates: [DubbingCandidate]
}

private struct DubbingProjectJournal: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let transactionID: String
    let operation: String
    let previousIndexSHA256: String?
    let previousIndexData: Data?
    let committedIndexSHA256: String
    let publishedAudioFileName: String?
    let publishedAudioSHA256: String?

    init(
        transactionID: String,
        operation: String,
        previousIndexSHA256: String?,
        previousIndexData: Data?,
        committedIndexSHA256: String,
        publishedAudioFileName: String? = nil,
        publishedAudioSHA256: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.transactionID = transactionID
        self.operation = operation
        self.previousIndexSHA256 = previousIndexSHA256
        self.previousIndexData = previousIndexData
        self.committedIndexSHA256 = committedIndexSHA256
        self.publishedAudioFileName = publishedAudioFileName
        self.publishedAudioSHA256 = publishedAudioSHA256
    }
}

/// 配音项目的持久化边界：项目、候选与采用关系只有一份事实。
///
/// 提交规则与作品库一致：`projects.json` 的原子替换是唯一逻辑提交点，
/// journal 只用于重启后判定旧状态还是新状态。
@MainActor
public final class DubbingProjectStore {
    private let operations: CreativeWorkFileOperations
    private let directory: URL
    private let indexURL: URL
    private let lockURL: URL
    private let transactionsDirectory: URL

    public convenience init(directory: URL) {
        self.init(directory: directory, fileOperations: CreativeWorkFileOperations())
    }

    init(
        directory: URL,
        fileOperations: CreativeWorkFileOperations
    ) {
        self.operations = fileOperations
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("projects.json")
        self.lockURL = directory.appendingPathComponent(".projects.lock", isDirectory: false)
        self.transactionsDirectory = directory
            .appendingPathComponent(".transactions", isDirectory: true)
    }

    public func list() throws -> [DubbingProject] {
        try withRecoveredLibrary {
            try readRecordsUnlocked().map(\.project)
        }
    }

    public func candidates(forProject projectID: String) throws -> [DubbingCandidate] {
        try withRecoveredLibrary {
            try recordUnlocked(projectID: projectID).candidates
        }
    }

    @discardableResult
    public func save(_ project: DubbingProject) throws -> DubbingProject {
        guard Self.isSafeIdentifier(project.id) else {
            throw DubbingProjectError.invalidIdentifier
        }
        return try withRecoveredLibrary {
            var records = try readRecordsUnlocked()
            if let index = records.firstIndex(where: { $0.project.id == project.id }) {
                records[index].project = project
            } else {
                records.append(DubbingProjectRecord(project: project, candidates: []))
            }
            try commitUnlocked(records: records, operation: "project")
            return project
        }
    }

    /// 保存一次段落重做的候选。候选不会自动被采用。
    @discardableResult
    public func addCandidate(
        _ candidate: DubbingCandidate,
        audioData: Data,
        toProject projectID: String
    ) throws -> DubbingCandidate {
        guard Self.isSafeIdentifier(candidate.id),
              Self.isSafeIdentifier(candidate.segmentID),
              Self.isSafeIdentifier(projectID),
              candidate.audioFileName == "\(candidate.id).wav",
              !audioData.isEmpty
        else {
            throw DubbingProjectError.invalidIdentifier
        }
        return try withRecoveredLibrary {
            var records = try readRecordsUnlocked()
            guard let index = records.firstIndex(where: { $0.project.id == projectID }) else {
                throw DubbingProjectError.candidateNotFound
            }
            guard records[index].project.segments.contains(
                where: { $0.id == candidate.segmentID }
            ) else {
                throw DubbingProjectError.segmentNotFound
            }
            let audioURL = directory.appendingPathComponent(
                candidate.audioFileName,
                isDirectory: false
            )
            guard !operations.isSymbolicLink(at: audioURL) else {
                throw DubbingProjectError.candidateNotAdoptable
            }
            if let existing = records[index].candidates.first(where: {
                $0.id == candidate.id
            }) {
                // 重试同一次生成：返回原候选，不重写音频或采用关系。
                guard existing.provenance.audioFileSHA256
                    == CreativeWorkTransaction.digest(audioData)
                else {
                    throw DubbingProjectError.candidateNotAdoptable
                }
                return existing
            }
            guard !operations.fileExists(at: audioURL) else {
                // 没有索引能证明归属的文件不认领、不覆盖。
                throw DubbingProjectError.candidateNotAdoptable
            }
            let digest = CreativeWorkTransaction.digest(audioData)
            let committed = DubbingCandidate(
                id: candidate.id,
                segmentID: candidate.segmentID,
                text: candidate.text,
                audioFileName: candidate.audioFileName,
                provenance: candidate.provenance.withAudioFileSHA256(digest),
                createdAt: candidate.createdAt,
                durationSeconds: candidate.durationSeconds
            )
            records[index].candidates.append(committed)
            try commitUnlocked(
                records: records,
                operation: "candidate",
                publishedAudioFileName: committed.audioFileName,
                publishedAudioSHA256: digest
            ) { transactionDirectory in
                let staged = transactionDirectory
                    .appendingPathComponent("staged.wav", isDirectory: false)
                try self.operations.write(audioData, to: staged)
                try self.operations.synchronize(at: staged)
                try self.operations.move(from: staged, to: audioURL)
                try self.operations.synchronize(at: audioURL)
            }
            return committed
        }
    }

    /// 采用一个候选。只改引用，不动任何已有音频；撤销可以回到上一版。
    @discardableResult
    public func adopt(
        candidateID: String,
        inSegment segmentID: String,
        ofProject projectID: String
    ) throws -> DubbingProject {
        try withRecoveredLibrary {
            var records = try readRecordsUnlocked()
            guard let index = records.firstIndex(where: { $0.project.id == projectID }) else {
                throw DubbingProjectError.candidateNotFound
            }
            guard let segmentIndex = records[index].project.segments.firstIndex(where: {
                $0.id == segmentID
            }) else {
                throw DubbingProjectError.segmentNotFound
            }
            guard let candidate = records[index].candidates.first(where: {
                $0.id == candidateID
            }) else {
                throw DubbingProjectError.candidateNotFound
            }
            guard records[index].project.isValid(candidate) else {
                throw DubbingProjectError.candidateNotAdoptable
            }
            var segment = records[index].project.segments[segmentIndex]
            if segment.acceptedCandidateID != candidateID {
                segment.adoptionHistory.append(segment.acceptedCandidateID)
                segment.acceptedCandidateID = candidateID
            }
            records[index].project.segments[segmentIndex] = segment
            try commitUnlocked(records: records, operation: "adopt")
            return records[index].project
        }
    }

    /// 撤销一步采用。没有历史时不动当前采用项。
    @discardableResult
    public func undoAdoption(
        inSegment segmentID: String,
        ofProject projectID: String
    ) throws -> DubbingProject {
        try withRecoveredLibrary {
            var records = try readRecordsUnlocked()
            guard let index = records.firstIndex(where: { $0.project.id == projectID }) else {
                throw DubbingProjectError.candidateNotFound
            }
            guard let segmentIndex = records[index].project.segments.firstIndex(where: {
                $0.id == segmentID
            }) else {
                throw DubbingProjectError.segmentNotFound
            }
            guard records[index].project.segments[segmentIndex].undoAdoption() else {
                return records[index].project
            }
            try commitUnlocked(records: records, operation: "undo_adoption")
            return records[index].project
        }
    }

    public func loadAudio(for candidate: DubbingCandidate) throws -> Data {
        try withRecoveredLibrary {
            // 索引能证明这个候选属于某个项目，否则不读取它的音频。
            let owned = try readRecordsUnlocked().contains { record in
                record.candidates.contains { $0.id == candidate.id }
            }
            guard owned else { throw DubbingProjectError.candidateNotFound }
            let audioURL = directory.appendingPathComponent(
                candidate.audioFileName,
                isDirectory: false
            )
            guard !operations.isSymbolicLink(at: audioURL) else {
                throw DubbingProjectError.candidateNotAdoptable
            }
            let data = try operations.read(from: audioURL)
            guard !data.isEmpty else {
                throw DubbingProjectError.candidateNotAdoptable
            }
            return data
        }
    }

    /// 导出成品：音频只由被采用的候选拼成，正文只由这些候选对应的段落组成。
    ///
    /// 只要有一段没有采用候选，就返回 nil 而不是导出半成品。
    public func export(projectID: String) throws -> (audio: Data, script: String)? {
        try withRecoveredLibrary {
            let record = try recordUnlocked(projectID: projectID)
            var clips: [DubbingAudioClip] = []
            for segment in record.project.segments {
                guard let acceptedID = segment.acceptedCandidateID,
                      let candidate = record.candidates.first(where: { $0.id == acceptedID }),
                      record.project.isValid(candidate)
                else {
                    return nil
                }
                let audioURL = directory.appendingPathComponent(
                    candidate.audioFileName,
                    isDirectory: false
                )
                guard !operations.isSymbolicLink(at: audioURL) else {
                    throw DubbingProjectError.candidateNotAdoptable
                }
                let wav = try operations.read(from: audioURL)
                clips.append(try DubbingAudioExport.clip(fromWAV: wav))
            }
            guard !clips.isEmpty else { return nil }
            return (
                audio: try DubbingAudioExport.makeWAV(from: clips),
                script: record.project.adoptedScript
            )
        }
    }

    // MARK: - 事务

    private func withRecoveredLibrary<T>(_ body: () throws -> T) throws -> T {
        do {
            try operations.createDirectory(at: directory)
            let lock = try operations.acquireExclusiveLock(at: lockURL)
            defer { operations.releaseExclusiveLock(lock) }
            try recoverUnlocked()
            return try body()
        } catch let error as DubbingProjectError {
            throw error
        } catch let error as CreativeWorkTransactionInterruption {
            throw error
        } catch {
            throw DubbingProjectError.invalidIdentifier
        }
    }

    private func recordUnlocked(projectID: String) throws -> DubbingProjectRecord {
        guard let record = try readRecordsUnlocked().first(where: {
            $0.project.id == projectID
        }) else {
            throw DubbingProjectError.candidateNotFound
        }
        return record
    }

    private func readRecordsUnlocked() throws -> [DubbingProjectRecord] {
        guard operations.fileExists(at: indexURL) else { return [] }
        guard !operations.isSymbolicLink(at: indexURL) else {
            throw DubbingProjectError.invalidIdentifier
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(
                [DubbingProjectRecord].self,
                from: operations.read(from: indexURL)
            )
        } catch {
            // 坏索引不能当空库：原文件保留，交给上层报告。
            throw DubbingProjectError.invalidIdentifier
        }
    }

    private func indexDataUnlocked() throws -> Data? {
        guard operations.fileExists(at: indexURL) else { return nil }
        guard !operations.isSymbolicLink(at: indexURL) else {
            throw DubbingProjectError.invalidIdentifier
        }
        do {
            return try operations.read(from: indexURL)
        } catch {
            throw DubbingProjectError.invalidIdentifier
        }
    }

    private func commitUnlocked(
        records: [DubbingProjectRecord],
        operation: String,
        publishedAudioFileName: String? = nil,
        publishedAudioSHA256: String? = nil,
        preCommit: ((URL) throws -> Void)? = nil
    ) throws {
        let previousData = try indexDataUnlocked()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let committedData = try encoder.encode(records)
        let transactionID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let transactionDirectory = transactionsDirectory
            .appendingPathComponent(transactionID, isDirectory: true)
        let journal = DubbingProjectJournal(
            transactionID: transactionID,
            operation: operation,
            previousIndexSHA256: previousData.map(CreativeWorkTransaction.digest),
            previousIndexData: previousData,
            committedIndexSHA256: CreativeWorkTransaction.digest(committedData),
            publishedAudioFileName: publishedAudioFileName,
            publishedAudioSHA256: publishedAudioSHA256
        )
        do {
            try operations.createDirectory(at: transactionDirectory)
            let journalURL = transactionDirectory
                .appendingPathComponent("journal.json", isDirectory: false)
            let journalEncoder = JSONEncoder()
            journalEncoder.outputFormatting = [.sortedKeys]
            try operations.write(journalEncoder.encode(journal), to: journalURL)
            try operations.synchronize(at: journalURL)
            try operations.synchronize(at: transactionDirectory)
            try preCommit?(transactionDirectory)
            do {
                try operations.write(committedData, to: indexURL)
                try operations.synchronize(at: indexURL)
                try operations.synchronize(at: directory)
            } catch {
                if error is CreativeWorkTransactionInterruption {
                    throw error
                }
                try? rollbackUnlocked(journal: journal, transactionDirectory: transactionDirectory)
                throw DubbingProjectError.invalidIdentifier
            }
            try? removeTransactionDirectoryUnlocked(transactionDirectory)
        } catch let error as DubbingProjectError {
            throw error
        } catch let error as CreativeWorkTransactionInterruption {
            throw error
        } catch {
            try? removeTransactionDirectoryUnlocked(transactionDirectory)
            throw DubbingProjectError.invalidIdentifier
        }
    }

    private func rollbackUnlocked(
        journal: DubbingProjectJournal,
        transactionDirectory: URL
    ) throws {
        if let previousData = journal.previousIndexData {
            // 尽力而为，不能让这一步决定整段回滚的命运。
            //
            // 回滚只发生在索引写入失败之后，而索引用原子写：写失败即代表它没被改动，
            // 所以这里重写旧内容只是兜底。可一旦索引是因为磁盘满、权限变更这类
            // **持续性**原因写不动，重写就必然再次失败——若让它抛出去，
            // 后面删除已发布音频、清掉事务目录这两步仍然做得到的事就全被跳过，
            // 而调用方是 `try?`，失败还会被完全吞掉。
            try? operations.write(previousData, to: indexURL)
            try? operations.synchronize(at: indexURL)
        } else if operations.fileExists(at: indexURL) {
            try operations.remove(at: indexURL)
        }
        if let fileName = journal.publishedAudioFileName,
           let expected = journal.publishedAudioSHA256
        {
            let audioURL = directory.appendingPathComponent(fileName, isDirectory: false)
            if !operations.isSymbolicLink(at: audioURL),
               operations.fileExists(at: audioURL),
               CreativeWorkTransaction.digest(try operations.read(from: audioURL))
                   == expected
            {
                try operations.remove(at: audioURL)
            }
        }
        try operations.synchronize(at: directory)
        try removeTransactionDirectoryUnlocked(transactionDirectory)
    }

    private func recoverUnlocked() throws {
        guard operations.fileExists(at: transactionsDirectory) else { return }
        let directories = try operations
            .contentsOfDirectory(at: transactionsDirectory)
            .filter { Self.isTransactionIdentifier($0.lastPathComponent) }
        guard directories.count <= 1 else {
            throw DubbingProjectError.invalidIdentifier
        }
        guard let transactionDirectory = directories.first else { return }
        let journalURL = transactionDirectory
            .appendingPathComponent("journal.json", isDirectory: false)
        guard !operations.isSymbolicLink(at: journalURL),
              operations.fileExists(at: journalURL)
        else {
            throw DubbingProjectError.invalidIdentifier
        }
        let journal: DubbingProjectJournal
        do {
            let decoder = JSONDecoder()
            journal = try decoder.decode(
                DubbingProjectJournal.self,
                from: operations.read(from: journalURL)
            )
        } catch {
            throw DubbingProjectError.invalidIdentifier
        }
        guard journal.schemaVersion == DubbingProjectJournal.currentSchemaVersion,
              journal.transactionID == transactionDirectory.lastPathComponent
        else {
            throw DubbingProjectError.invalidIdentifier
        }
        let currentDigest = try indexDataUnlocked().map(CreativeWorkTransaction.digest)
        if currentDigest == journal.committedIndexSHA256 {
            try? removeTransactionDirectoryUnlocked(transactionDirectory)
            return
        }
        guard currentDigest == journal.previousIndexSHA256 else {
            throw DubbingProjectError.invalidIdentifier
        }
        try? rollbackUnlocked(journal: journal, transactionDirectory: transactionDirectory)
    }

    private func removeTransactionDirectoryUnlocked(_ url: URL) throws {
        guard operations.fileExists(at: url) else { return }
        try operations.remove(at: url)
        try operations.synchronize(at: transactionsDirectory)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }

    private static func isTransactionIdentifier(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
    }
}

/// 一段候选音频自己声明的格式。
///
/// 导出必须按**数据说的**来写 header，而不是按调用方以为的来写：猜错采样率不会
/// 报错，只会让成品语速与音高整体错位——那是更难被发现的一类错误。
public struct DubbingAudioFormat: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int

    public init(sampleRate: Int, channels: Int, bitsPerSample: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    /// 拼接只在这一种剖面下有意义：单声道 16 bit 线性 PCM，且采样率必须为正。
    ///
    /// 采样率也要查：声明 0 Hz 的畸形文件如果照写，导出的是一份播放器会拒绝或
    /// 误读的 header——那正是这次修复要避免的「猜错格式」换了个方向重来。
    var isLinearMono16: Bool {
        channels == 1 && bitsPerSample == 16 && sampleRate > 0
    }
}

/// 一段候选音频的样本与它自己的格式。
public struct DubbingAudioClip: Equatable, Sendable {
    public let pcm: Data
    public let format: DubbingAudioFormat

    public init(pcm: Data, format: DubbingAudioFormat) {
        self.pcm = pcm
        self.format = format
    }
}

/// 把若干段候选音频拼成一个 WAV：按它们**共同的**真实格式重写 header，不改动任何样本字节。
///
/// 不做 crossfade、不用静音补时长。响度与韵律是否自然只能靠听审验证，
/// 这里只保证「导出的音频就是被采用的那些样本，按顺序拼接」。
public enum DubbingAudioExport {
    /// 格式不一致或不受支持时**明确失败**，而不是套用自己的假设去标定。
    public static func makeWAV(from clips: [DubbingAudioClip]) throws -> Data {
        guard let format = clips.first?.format else { return Data() }
        guard format.isLinearMono16 else {
            throw DubbingProjectError.audioFormatUnsupported
        }
        var samples = Data()
        samples.reserveCapacity(clips.reduce(0) { $0 + $1.pcm.count })
        for clip in clips {
            guard clip.format == format else {
                throw DubbingProjectError.audioFormatMismatch
            }
            guard clip.pcm.count % 2 == 0 else {
                throw DubbingProjectError.candidateNotAdoptable
            }
            samples.append(clip.pcm)
        }

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(littleEndian: UInt32(36 + samples.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        header.append(littleEndian: UInt32(16))
        header.append(littleEndian: UInt16(1))
        header.append(littleEndian: UInt16(format.channels))
        header.append(littleEndian: UInt32(format.sampleRate))
        header.append(littleEndian: UInt32(format.sampleRate * format.channels * format.bitsPerSample / 8))
        header.append(littleEndian: UInt16(format.channels * format.bitsPerSample / 8))
        header.append(littleEndian: UInt16(format.bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        header.append(littleEndian: UInt32(samples.count))
        header.append(samples)
        return header
    }

    /// 从完整 WAV 中取出 data chunk 的 PCM 字节，以及 `fmt ` 声明的真实格式。
    ///
    /// 摘要与拼接都以 data chunk 为准，但**格式必须一起读出来**——丢掉 `fmt `
    /// 就只能靠猜，而猜错的代价是导出一份听起来不对却能播放的成品。
    public static func clip(fromWAV wav: Data) throws -> DubbingAudioClip {
        guard wav.count > 12,
              wav.prefix(4) == Data("RIFF".utf8),
              wav.subdata(in: 8..<12) == Data("WAVE".utf8)
        else {
            throw DubbingProjectError.audioFormatUnsupported
        }
        var cursor = 12
        var format: DubbingAudioFormat?
        var pcm: Data?
        while cursor + 8 <= wav.count {
            let identifier = wav.subdata(in: cursor..<(cursor + 4))
            let size = Int(wav.subdata(in: (cursor + 4)..<(cursor + 8)).littleEndianUInt32)
            let body = cursor + 8
            guard body + size <= wav.count else {
                throw DubbingProjectError.audioFormatUnsupported
            }
            if identifier == Data("fmt ".utf8) {
                // 只接受未压缩 PCM（format code 1）；压缩格式的 data 不是裸样本。
                guard size >= 16,
                      wav.subdata(in: body..<(body + 2)).littleEndianUInt16 == 1
                else {
                    throw DubbingProjectError.audioFormatUnsupported
                }
                format = DubbingAudioFormat(
                    sampleRate: Int(wav.subdata(in: (body + 4)..<(body + 8)).littleEndianUInt32),
                    channels: Int(wav.subdata(in: (body + 2)..<(body + 4)).littleEndianUInt16),
                    bitsPerSample: Int(wav.subdata(in: (body + 14)..<(body + 16)).littleEndianUInt16)
                )
            } else if identifier == Data("data".utf8) {
                pcm = wav.subdata(in: body..<(body + size))
            }
            cursor = body + size + (size % 2)
        }
        guard let format, let pcm else {
            throw DubbingProjectError.audioFormatUnsupported
        }
        return DubbingAudioClip(pcm: pcm, format: format)
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
        ])
    }

    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    var littleEndianUInt32: UInt32 {
        guard count >= 4 else { return 0 }
        return UInt32(self[0])
            | UInt32(self[1]) << 8
            | UInt32(self[2]) << 16
            | UInt32(self[3]) << 24
    }

    var littleEndianUInt16: UInt16 {
        guard count >= 2 else { return 0 }
        return UInt16(self[0]) | UInt16(self[1]) << 8
    }
}
