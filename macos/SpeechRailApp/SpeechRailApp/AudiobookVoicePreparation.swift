import Foundation
import SpeechRailControlKit

public enum AudiobookVoicePreparationScope: Equatable, Sendable {
    case missing, leads
    case role(UUID)
}

enum AudiobookVoiceCreationError: Error, Equatable {
    case rejectedCandidate
    case outputCheckFailed, outputEvidenceNotSaved, outputCheckUnavailable, productionNotReady
}

/// A reviewable recipe, separate from any generated voice or adopted audio.
public struct AudiobookVoiceCreationDraft: Equatable, Sendable, Identifiable {
    public enum Target: Equatable, Sendable {
        case role(UUID)
        case ensemble(AudiobookVoiceArchetype)
    }

    public enum Status: Equatable, Sendable {
        case ready, creating
        case created(voiceID: String)
        case createdPending(voiceID: String, message: String)
        case failed(String)
        public var createdVoiceID: String? {
            switch self {
            case .created(let id), .createdPending(let id, _): id
            default: nil
            }
        }
        public var isCreated: Bool { createdVoiceID != nil }
        public var isComplete: Bool { if case .created = self { true } else { false } }
        public var isFailure: Bool {
            switch self {
            case .failed, .createdPending: true
            default: false
            }
        }
        public var title: String {
            switch self {
            case .ready: "待确认"
            case .creating: "正在创建与检查…"
            case .created: "已创建并通过配音检查"
            case .createdPending(_, let message): message
            case .failed(let message): message
            }
        }
    }

    public let id: UUID
    public let bookID: UUID
    public let target: Target
    public let roles: [AudiobookCharacter]
    public let expectedBindings: [UUID: AudiobookVoiceBinding]
    public let sourceEvidence: [AudiobookCharacterEvidence]
    public let preparedReferenceText: String
    public let preparedReferenceTextSource: String
    public var referenceTextSource: String {
        referenceText == preparedReferenceText ? preparedReferenceTextSource : "创作者编辑的试听文稿"
    }
    public var voiceName: String
    public var instruction: String
    public var referenceText: String
    public var isSelected = true
    public internal(set) var status: Status = .ready
    public internal(set) var generationAttempt = 0

    public var roleIDs: [UUID] { roles.map(\.id) }
    public var roleNames: String { roles.map(\.displayName).joined(separator: "、") }
    public var replacesExistingVoice: Bool { !expectedBindings.isEmpty }

    public var validationMessage: String? {
        let nameCount = voiceName.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        let instructionCount = instruction.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        let textCount = referenceText.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        if !(1...64).contains(nameCount) { return "音色名称需为 1–64 个字。" }
        if !(1...10_000).contains(instructionCount) { return "请填写声音描述，最多 10000 个字。" }
        if !(20...240).contains(textCount) { return "试听文稿需为 20–240 个字。" }
        return nil
    }

    /// Transport retries reuse an attempt; confirmed terminal failures start a new one.
    public var request: AudiobookLeadVoiceCreationRequest {
        let name = voiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = AudiobookCastingDigest.hash(["book": bookID.uuidString, "draft": id.uuidString,
            "name": name, "instruction": description, "text": text, "attempt": String(generationAttempt)])
        return .init(bookID: bookID, roleID: roles.first?.id ?? bookID,
            targetVoiceID: "ab_\(digest.prefix(48))", voiceName: name, instruction: description,
            referenceTextCandidates: [text], seed: Int(digest.prefix(6), radix: 16) ?? 42)
    }
}

enum AudiobookVoicePreparation {
    /// Partial coverage is only for identifying missing recipes, never for committing a partial cast.
    static func existingVoiceCoverage(characters: [AudiobookCharacter], annotations: [AudiobookAnnotation],
                                      bindings: [UUID: AudiobookVoiceBinding], snapshot: EffectiveCapabilitySnapshot,
                                      catalog: VoiceCatalogSnapshot, bookID: UUID,
                                      repairableVoiceIDs: Set<String> = []) throws -> [UUID: String] {
        let speaking = Set(annotations.compactMap(\.assignment.roleID))
        let active = characters.filter { $0.isNarrator || annotations.isEmpty || speaking.contains($0.id) }
        guard snapshot.voices.isEmpty || active.count <= 100_000 / snapshot.voices.count else {
            throw AudiobookCastError.invalidCastingPlan(reason: "preparation_budget_exceeded")
        }
        let groups = Dictionary(grouping: snapshot.voices, by: \.id)
        let voices = snapshot.voices.filter { voice in
            guard groups[voice.id]?.allSatisfy({ $0 == voice }) == true else { return false }
            // A repair projection only reserves existing assets; it never authorizes synthesis.
            if repairableVoiceIDs.contains(voice.id) { return true }
            guard catalog.permits(voice, bookID: bookID), voice.available, voice.productionReady == true,
                  voice.operations["http_speech"] != nil,
                  let revision = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: voice.id, in: snapshot)?.expectedModelRevision else { return false }
            let candidate = AudiobookVoiceBinding(roleID: bookID, voiceID: voice.id, voiceRevision: voice.voiceRevision, modelRevision: revision)
            guard (try? AudiobookCastRegistry.validateRenderBinding(candidate, snapshot: snapshot)) != nil else { return false }
            return true
        }
        let exclusiveExisting = Set(active.filter { bindings[$0.id] != nil && ($0.isNarrator || $0.voicePolicy?.sharingPolicy == .exclusive || !$0.allowSharedMinorVoice) }.compactMap { bindings[$0.id]?.voiceID })
        let sharedExisting = Set(bindings.values.map(\.voiceID)).subtracting(exclusiveExisting)
        let unbound = active.filter { bindings[$0.id] == nil }
        let exclusive = unbound.filter { $0.isNarrator || $0.voicePolicy?.sharingPolicy == .exclusive }
            .sorted { $0.isNarrator != $1.isNarrator ? $0.isNarrator : $0.id.uuidString < $1.id.uuidString }
        var candidates: [UUID: [String]] = [:]
        for role in unbound {
            try Task.checkCancellation()
            candidates[role.id] = voices.filter {
                !exclusiveExisting.contains($0.id) && AudiobookCastRegistry.matchesRequiredTraits(role: role, voice: $0, metadata: catalog.state.metadataByVoiceID[$0.id])
            }.sorted {
                if repairableVoiceIDs.contains($0.id) != repairableVoiceIDs.contains($1.id) {
                    return !repairableVoiceIDs.contains($0.id)
                }
                let left = AudiobookCastRegistry.preferenceScore(role: role, voice: $0, metadata: catalog.state.metadataByVoiceID[$0.id], preferredCollectionID: catalog.state.preferredCollectionIDByBookID[bookID])
                let right = AudiobookCastRegistry.preferenceScore(role: role, voice: $1, metadata: catalog.state.metadataByVoiceID[$1.id], preferredCollectionID: catalog.state.preferredCollectionIDByBookID[bookID])
                return left == right ? $0.id < $1.id : left > right
            }.map(\.id)
        }
        var owners: [String: UUID] = [:]
        var workRemaining = 100_000
        func augment(_ roleID: UUID, seen: inout Set<String>) throws -> Bool {
            for id in candidates[roleID] ?? [] where !sharedExisting.contains(id) && seen.insert(id).inserted {
                try Task.checkCancellation()
                workRemaining -= 1
                guard workRemaining >= 0 else { throw AudiobookCastError.invalidCastingPlan(reason: "preparation_budget_exceeded") }
                if let owner = owners[id], try !augment(owner, seen: &seen) { continue }
                owners[id] = roleID
                return true
            }
            return false
        }
        for role in exclusive { var seen: Set<String> = []; _ = try augment(role.id, seen: &seen) }
        var coverage = bindings.mapValues(\.voiceID)
        for (voiceID, roleID) in owners { coverage[roleID] = voiceID }
        for role in unbound where !role.isNarrator && role.voicePolicy?.sharingPolicy != .exclusive {
            if let id = candidates[role.id]?.first(where: { owners[$0] == nil }) { coverage[role.id] = id }
        }
        return coverage
    }

    static func prepare(
        book: AudiobookBook, characters: [AudiobookCharacter], annotations: [AudiobookAnnotation],
        bindings: [UUID: AudiobookVoiceBinding], source: AudiobookSourceIndex,
        stats: [UUID: AudiobookRoleDialogueStats], scope: AudiobookVoicePreparationScope,
        replacementRoleIDs: Set<UUID> = [], coveredRoleIDs: Set<UUID> = []
    ) -> [AudiobookVoiceCreationDraft] {
        let speaking = Set(annotations.compactMap(\.assignment.roleID))
        let active = characters.filter { $0.isNarrator || annotations.isEmpty || speaking.contains($0.id) }
        let targets: [(AudiobookVoiceCreationDraft.Target, [AudiobookCharacter])]
        switch scope {
        case .role(let id):
            targets = active.filter { $0.id == id }.map { (.role($0.id), [$0]) }
        case .leads:
            targets = active.filter {
                bindings[$0.id] == nil && ($0.isNarrator || stats[$0.id]?.tier == .lead || $0.voicePolicy?.sharingPolicy == .exclusive)
            }.map { (.role($0.id), [$0]) }
        case .missing:
            let missing = active.filter { !coveredRoleIDs.contains($0.id) && (bindings[$0.id] == nil || replacementRoleIDs.contains($0.id)) }
            let exclusive = missing.filter {
                $0.isNarrator || $0.voicePolicy?.sharingPolicy == .exclusive
                    || replacementRoleIDs.contains($0.id)
                    || !traitSummary($0.requiredVoiceTraits).isEmpty || !traitSummary($0.voiceTraitsOverride).isEmpty
            }
            let exclusiveIDs = Set(exclusive.map(\.id))
            let shared = Dictionary(grouping: missing.filter { !exclusiveIDs.contains($0.id) }) {
                stats[$0.id]?.archetype ?? $0.inferredVoiceArchetype(peers: characters)
            }
            targets = exclusive.map { (.role($0.id), [$0]) }
                + AudiobookVoiceArchetype.allCases.compactMap { archetype in
                    shared[archetype].map { (.ensemble(archetype), $0) }
                }
        }

        // Read actual source ranges once, rather than repeatedly loading the whole book per role.
        var evidenceByRole: [UUID: [AudiobookCharacterEvidence]] = [:]
        for annotation in annotations.sorted(by: { $0.sourceRange < $1.sourceRange }) {
            guard let roleID = annotation.assignment.roleID,
                  (evidenceByRole[roleID]?.count ?? 0) < 3,
                  let quote = try? source.text(in: annotation.sourceRange), !quote.isEmpty else { continue }
            evidenceByRole[roleID, default: []].append(.init(chapterID: annotation.chapterID,
                sourceRange: annotation.sourceRange, quoteExcerpt: quote))
        }
        return targets.map { target, roles in
            let representative = roles[0]
            let archetype = stats[representative.id]?.archetype ?? representative.inferredVoiceArchetype(peers: characters)
            var seenEvidence = Set<AudiobookCharacterEvidence>()
            let evidence = Array(roles.prefix(3).flatMap { (evidenceByRole[$0.id] ?? []) + $0.evidences }
                .filter { seenEvidence.insert($0).inserted }.prefix(6))
            let persona = AudiobookVoicePersona.infer(for: representative, peers: characters, recompute: false)
            var instruction: String
            let name: String
            let identity: String
            switch target {
            case .role(let roleID):
                instruction = persona.compiledVoiceDesignInstruction(roleName: representative.displayName, isNarrator: representative.isNarrator)
                name = voiceName(bookTitle: book.title, suffix: representative.displayName)
                identity = "role|\(roleID)"
            case .ensemble(let archetype):
                instruction = archetype.defaultScenarioInstruction(forBookTitle: book.title)
                    + " 角色声音参考：\(persona.timbreAndTexture)。"
                name = voiceName(bookTitle: book.title, suffix: "群像·\(archetype.shortBadgeTitle)")
                identity = "ensemble|\(archetype.rawValue)"
            }
            let preferences = traitSummary(representative.voiceTraitsOverride)
            let requirements = traitSummary(representative.requiredVoiceTraits)
            if !preferences.isEmpty { instruction += " 创作者的声音偏好：\(preferences)。" }
            if !requirements.isEmpty { instruction += " 请优先满足创作者明确要求：\(requirements)。" }
            let selected = AudiobookAuditionScriptSelector.selectCandidates(from: evidence.map(\.quoteExcerpt),
                roleName: representative.displayName, aliases: representative.aliases,
                isNarrator: representative.isNarrator, maxCandidates: 1).first
            let sourceQuote = selected.flatMap { quote in
                // Only call it a source excerpt if the selector did not substitute a default script.
                evidence.contains(where: { $0.quoteExcerpt.contains(quote) }) ? quote : nil
            }
            let reference = sourceQuote ?? archetype.defaultScenarioReferenceText(forBookTitle: book.title)
            let validReference = (20...240).contains(reference.unicodeScalars.count)
                ? reference : archetype.defaultScenarioReferenceText(forBookTitle: book.title)
            let roleIDs = Set(roles.map(\.id))
            return AudiobookVoiceCreationDraft(
                id: AudiobookCastingDigest.uuid("voice-draft|\(book.id)|\(identity)"), bookID: book.id, target: target,
                roles: roles, expectedBindings: bindings.filter { roleIDs.contains($0.key) },
                sourceEvidence: evidence,
                preparedReferenceText: validReference,
                preparedReferenceTextSource: sourceQuote == validReference ? "从原书选取的试听文稿" : "建议试听文稿（原书台词不足时补充，不属于原文）",
                voiceName: name, instruction: instruction,
                referenceText: validReference
            )
        }
    }

    private static func voiceName(bookTitle: String, suffix: String) -> String {
        // The service name limit must not erase the role that distinguishes each recipe.
        let label = String(String.UnicodeScalarView(suffix.unicodeScalars.prefix(64)))
        let title = String(String.UnicodeScalarView(bookTitle.unicodeScalars.prefix(max(0, 63 - label.unicodeScalars.count))))
        return title.isEmpty ? label : "\(title)·\(label)"
    }

    private static func traitSummary(_ traits: AudiobookVoiceTraits?) -> String {
        guard let traits else { return "" }
        let labels = ["male": "男性声线", "female": "女性声线", "neutral": "中性声线",
            "child": "童声", "young": "年轻成年", "middleAged": "中年", "elder": "老年",
            "low": "低音", "medium": "中音", "high": "高音", "slow": "舒缓", "fast": "明快",
            "normal": "适中", "warm": "温暖", "bright": "清亮", "zh-CN": "普通话", "zh": "中文"]
        return [("声线", traits.gender), ("年龄感", traits.age), ("音高", traits.pitch),
            ("质感", traits.texture), ("语言", traits.locale), ("语速", traits.pacing)]
            .filter { !$0.1.value.isEmpty && $0.1.value != "unknown" }
            .map { "\($0.0)：\(labels[$0.1.value] ?? $0.1.value)" }.joined(separator: "，")
    }
}
