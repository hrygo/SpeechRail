import Foundation
import Observation
import SpeechRailControlKit

public enum AudiobookPronunciationError: LocalizedError, Equatable, Sendable {
    case serviceUnavailable
    case blankSurface(index: Int)
    case blankSpoken(index: Int)
    case surfaceTooLong(index: Int)
    case spokenTooLong(index: Int)
    case duplicateRule(surface: String)
    case tooManyRules
    case missingRevision
    case remoteUnavailable

    public var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "本机语音服务不可用，暂时无法保存发音规则。"
        case let .blankSurface(index):
            return "第 \(index + 1) 条规则的原文不能为空。"
        case let .blankSpoken(index):
            return "第 \(index + 1) 条规则的读法不能为空。"
        case let .surfaceTooLong(index):
            return "第 \(index + 1) 条规则的原文超过 256 个字符。"
        case let .spokenTooLong(index):
            return "第 \(index + 1) 条规则的读法超过 256 个字符。"
        case let .duplicateRule(surface):
            return "原文「\(surface)」出现了重复规则，请合并或删除其中一条。"
        case .tooManyRules:
            return "单本书最多保存 500 条发音规则，请精简后再保存。"
        case .missingRevision:
            return "语音服务没有返回规则版本，请重试。"
        case .remoteUnavailable:
            return "服务端找不到当前规则版本，可能已在别处更新。请刷新后重试。"
        }
    }
}

/// 按书维护发音规则：服务端是唯一事实源（不可变 revision），本地只缓存最近一次确认保存的
/// 快照，供制作时固定读音并判断片段是否需要重做。
@MainActor
@Observable
public final class AudiobookPronunciationController {
    public struct Rule: Identifiable, Equatable, Sendable {
        public var id: String
        public var surface: String
        public var spoken: String
        public var language: String
        public var caseSensitive: Bool
        public var wordBoundary: Bool

        public init(
            id: String = UUID().uuidString,
            surface: String = "",
            spoken: String = "",
            language: String = "auto",
            caseSensitive: Bool = true,
            wordBoundary: Bool = false
        ) {
            self.id = id
            self.surface = surface
            self.spoken = spoken
            self.language = language
            self.caseSensitive = caseSensitive
            self.wordBoundary = wordBoundary
        }

        init(entry: PronunciationEntry) {
            id = entry.id
            surface = entry.surface
            spoken = entry.spoken
            language = entry.language
            caseSensitive = entry.caseSensitive
            wordBoundary = entry.wordBoundary
        }

        var entry: PronunciationEntry {
            PronunciationEntry(
                id: id,
                surface: surface,
                spoken: spoken,
                language: language,
                caseSensitive: caseSensitive,
                wordBoundary: wordBoundary
            )
        }
    }

    private let store: AudiobookProjectStore
    private let client: (any AudiobookPronunciationClient)?

    public private(set) var binding: AudiobookPronunciationBinding?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    public private(set) var lastSavedAt: Date?
    /// 保存冲突或远端缺失时置位，引导用户先刷新而不是覆盖别人的新版本。
    public private(set) var needsRefresh = false
    public var draft: [Rule] = []

    public init(
        store: AudiobookProjectStore,
        client: (any AudiobookPronunciationClient)?
    ) {
        self.store = store
        self.client = client
    }

    public var isAvailable: Bool { client != nil }

    public var ruleCount: Int {
        binding?.entries.count ?? 0
    }

    public func load(bookID: UUID) async {
        isLoading = true
        errorMessage = nil
        needsRefresh = false
        defer { isLoading = false }
        do {
            let stored = try await store.pronunciationBinding(for: bookID)
            binding = stored
            draft = stored?.entries.map(Rule.init(entry:)) ?? []
        } catch {
            binding = nil
            draft = []
            errorMessage = "读取已保存的发音规则失败：\(error.localizedDescription)"
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    public func addRule() {
        draft.append(Rule())
    }

    public func removeRule(id: String) {
        draft.removeAll { $0.id == id }
    }

    /// 从服务端拉取当前 revision 的完整词条，用于发现别处更新或恢复本地缓存。
    public func refresh(bookID: UUID) async {
        guard let client else {
            errorMessage = AudiobookPronunciationError.serviceUnavailable.errorDescription
            return
        }
        errorMessage = nil
        do {
            // 先取最新 revision，再按该 revision 拉完整词条；只读本地缓存的 revision
            // 永远看不到别处的新版本，冲突时也无法恢复。
            let setID = binding?.setID ?? AudiobookPronunciationBinding.makeSetID(bookID: bookID)
            let summaries = try await client.fetchPronunciationSetSummaries()
            guard let summary = summaries.first(where: { $0.id == setID }), !summary.revoked else {
                throw AudiobookPronunciationError.remoteUnavailable
            }
            let remote = try await client.fetchPronunciationSet(id: setID, revision: summary.revision)
            if remote.revoked == true {
                throw AudiobookPronunciationError.remoteUnavailable
            }
            let entries = remote.entries
            let updated = AudiobookPronunciationBinding(
                setID: setID,
                revision: remote.revision ?? summary.revision,
                entries: entries
            )
            if updated != binding {
                try await store.savePronunciationBinding(updated, bookID: bookID)
                binding = updated
                draft = entries.map(Rule.init(entry:))
            }
            needsRefresh = false
        } catch {
            needsRefresh = true
            errorMessage = "刷新发音规则失败：\(error.localizedDescription)"
        }
    }

    /// 保存为服务端的新 revision；成功后本地缓存同一份快照。
    public func save(bookID: UUID) async {
        guard !isSaving else { return }
        guard let client else {
            errorMessage = AudiobookPronunciationError.serviceUnavailable.errorDescription
            return
        }
        errorMessage = nil
        do {
            let entries = try validatedEntries()
            isSaving = true
            defer { isSaving = false }
            let setID = binding?.setID ?? AudiobookPronunciationBinding.makeSetID(bookID: bookID)
            let result = try await client.upsertPronunciationSet(
                id: setID,
                expectedRevision: binding?.revision,
                entries: entries
            )
            guard let revision = result.revision else {
                throw AudiobookPronunciationError.missingRevision
            }
            let updated = AudiobookPronunciationBinding(
                setID: setID,
                revision: revision,
                entries: entries
            )
            try await store.savePronunciationBinding(updated, bookID: bookID)
            binding = updated
            draft = entries.map(Rule.init(entry:))
            needsRefresh = false
            lastSavedAt = Date()
        } catch let error as AudiobookPronunciationError {
            errorMessage = error.errorDescription
        } catch {
            if Self.isConflict(error) {
                needsRefresh = true
                errorMessage = "发音规则已在别处更新，请先刷新再保存，以免覆盖新版本。"
            } else {
                errorMessage = "保存发音规则失败：\(error.localizedDescription)"
            }
        }
    }

    public func deleteAll(bookID: UUID) async {
        guard !isSaving else { return }
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            if let binding, let client {
                do {
                    try await client.deletePronunciationSet(id: binding.setID)
                } catch {
                    // 远端已不存在时仍允许清理本地指针。
                    if !Self.isNotFound(error) { throw error }
                }
            }
            try await store.deletePronunciationBinding(bookID: bookID)
            self.binding = nil
            draft = []
            needsRefresh = false
            lastSavedAt = nil
        } catch {
            errorMessage = "清除发音规则失败：\(error.localizedDescription)"
        }
    }

    private func validatedEntries() throws -> [PronunciationEntry] {
        guard draft.count <= 500 else {
            throw AudiobookPronunciationError.tooManyRules
        }
        var seen: Set<String> = []
        var entries: [PronunciationEntry] = []
        entries.reserveCapacity(draft.count)
        for (index, rule) in draft.enumerated() {
            let surface = rule.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = rule.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !surface.isEmpty else {
                throw AudiobookPronunciationError.blankSurface(index: index)
            }
            guard !spoken.isEmpty else {
                throw AudiobookPronunciationError.blankSpoken(index: index)
            }
            guard surface.count <= 256 else {
                throw AudiobookPronunciationError.surfaceTooLong(index: index)
            }
            guard spoken.count <= 256 else {
                throw AudiobookPronunciationError.spokenTooLong(index: index)
            }
            let key = "\(rule.language.lowercased())|\(rule.caseSensitive ? surface : surface.lowercased())|\(rule.wordBoundary)"
            guard seen.insert(key).inserted else {
                throw AudiobookPronunciationError.duplicateRule(surface: surface)
            }
            entries.append(
                PronunciationEntry(
                    id: rule.id,
                    surface: surface,
                    spoken: spoken,
                    language: rule.language.isEmpty ? "auto" : rule.language,
                    caseSensitive: rule.caseSensitive,
                    wordBoundary: rule.wordBoundary
                )
            )
        }
        return entries
    }

    private static func isConflict(_ error: Error) -> Bool {
        if case let ServiceAPIClientError.http(status, _, _, _, _) = error, status == 409 {
            return true
        }
        return false
    }

    private static func isNotFound(_ error: Error) -> Bool {
        if case let ServiceAPIClientError.http(status, _, _, _, _) = error, status == 404 {
            return true
        }
        return false
    }
}
