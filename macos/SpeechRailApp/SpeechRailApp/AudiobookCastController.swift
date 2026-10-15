import Foundation
import SpeechRailControlKit

/// T06：人物确认、配声绑定、音色设计往返身份与章节就绪度判定。
public struct AudiobookVoiceReturnContext: Codable, Equatable, Hashable, Sendable {
    public let bookID: UUID
    public let roleID: UUID
    public let castRevisionID: UUID
    public let generation: Int
    public let voiceSetDigest: String?
    public let bookTitle: String?
    public let roleDisplayName: String?
    public let roleVoiceTraitSummary: String?
    public let suggestedInstruction: String?
    public let suggestedReferenceText: String?
    public let suggestedReferenceTextCandidates: [String]
    public let suggestedAcousticChips: [String]

    public init(
        bookID: UUID,
        roleID: UUID,
        castRevisionID: UUID,
        generation: Int,
        voiceSetDigest: String? = nil,
        bookTitle: String? = nil,
        roleDisplayName: String? = nil,
        roleVoiceTraitSummary: String? = nil,
        suggestedInstruction: String? = nil,
        suggestedReferenceText: String? = nil,
        suggestedReferenceTextCandidates: [String] = [],
        suggestedAcousticChips: [String] = []
    ) {
        self.bookID = bookID
        self.roleID = roleID
        self.castRevisionID = castRevisionID
        self.generation = generation
        self.voiceSetDigest = voiceSetDigest
        self.bookTitle = bookTitle
        self.roleDisplayName = roleDisplayName
        self.roleVoiceTraitSummary = roleVoiceTraitSummary
        self.suggestedInstruction = suggestedInstruction
        self.suggestedReferenceText = suggestedReferenceText
        self.suggestedReferenceTextCandidates = suggestedReferenceTextCandidates
        self.suggestedAcousticChips = suggestedAcousticChips
    }
}

public struct AudiobookCastImpactPreview: Codable, Equatable, Sendable {
    public let affectedChapterIDs: [UUID]
    public let affectedAtomIDs: [UUID]
    public let affectedQuotesCount: Int

    public init(
        affectedChapterIDs: [UUID],
        affectedAtomIDs: [UUID],
        affectedQuotesCount: Int
    ) {
        self.affectedChapterIDs = affectedChapterIDs
        self.affectedAtomIDs = affectedAtomIDs
        self.affectedQuotesCount = affectedQuotesCount
    }
}

public enum AudiobookCastError: LocalizedError, Equatable, Sendable {
    case analysisNotCompleted
    case characterNotFound(UUID)
    case cannotDeleteOrMergeNarrator
    case voiceNotSynthesisReady(voiceID: String)
    case duplicateVoiceRequiresSharedMinorConsent(voiceID: String, conflictingRoleID: UUID)
    case missingVoiceBindings(unboundRoleNames: [String])
    case castRevisionMismatch
    case auditionDigestMismatch
    case staleVoiceReturnContext
    case invalidCastingPlan(reason: String)
    case nothingToUndo

    public var errorDescription: String? {
        switch self {
        case .analysisNotCompleted:
            return "请先完成全书分析，再确认全书角色与配声。"
        case .characterNotFound:
            return "找不到指定的角色。"
        case .cannotDeleteOrMergeNarrator:
            return "旁白是固定朗读角色，不能合并或删除。"
        case .voiceNotSynthesisReady(let voiceID):
            return "音色「\(voiceID)」尚未保存为可用于合成的正式音色。"
        case .duplicateVoiceRequiresSharedMinorConsent:
            return "多个角色共用同一音色时，需显式开启「次要角色共用声线」。"
        case .missingVoiceBindings(let names):
            return "以下角色尚未绑定音色：\(names.joined(separator: "、"))。"
        case .castRevisionMismatch:
            return "角色列表已发生变更，请刷新后重新确认。"
        case .auditionDigestMismatch:
            return "角色配声已发生变更，请先试听更新后的角色声音再确认。"
        case .staleVoiceReturnContext:
            return "当前书籍或角色版本已变更，新音色已保存在音色库中，未自动改动当前角色。"
        case .invalidCastingPlan:
            return "配声方案不可应用，请刷新后处理声音归属、参数或角色冲突。"
        case .nothingToUndo:
            return "没有可撤销的说话人归属修改。"
        }
    }
}

public actor AudiobookCastController {
    private struct AssignmentUndoSnapshot: Sendable {
        let bookID: UUID
        let previousAnnotations: [AudiobookAnnotation]
    }

    private let store: AudiobookProjectStore
    private let capabilityProvider: (@Sendable () async throws -> EffectiveCapabilitySnapshot)?
    private let voiceCatalog: VoiceCatalogStore
    private var undoStacksByBook: [UUID: [AssignmentUndoSnapshot]] = [:]
    private var currentGenerationsByBook: [UUID: Int] = [:]
    private var mutationWaitersByBook: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(store: AudiobookProjectStore,
                capabilityProvider: (@Sendable () async throws -> EffectiveCapabilitySnapshot)? = nil,
                voiceCatalog: VoiceCatalogStore = VoiceCatalogStore()) {
        self.store = store
        self.capabilityProvider = capabilityProvider
        self.voiceCatalog = voiceCatalog
    }

    public func currentGeneration(for bookID: UUID) -> Int {
        currentGenerationsByBook[bookID, default: 1]
    }

    public func bumpGeneration(for bookID: UUID) -> Int {
        let next = currentGenerationsByBook[bookID, default: 1] + 1
        currentGenerationsByBook[bookID] = next
        return next
    }

    // Keep read-modify-write operations and undo history ordered across Store awaits.
    private func acquireMutation(for bookID: UUID) async {
        if mutationWaitersByBook[bookID] == nil {
            mutationWaitersByBook[bookID] = []
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaitersByBook[bookID, default: []].append(continuation)
        }
    }

    private func releaseMutation(for bookID: UUID) {
        guard var waiters = mutationWaitersByBook[bookID], !waiters.isEmpty else {
            mutationWaitersByBook.removeValue(forKey: bookID)
            return
        }
        let next = waiters.removeFirst()
        mutationWaitersByBook[bookID] = waiters
        next.resume()
    }

    // MARK: - Role Assignment & Undo

    public func assignRole(
        bookID: UUID,
        atomIDs: [UUID],
        roleID: UUID
    ) async throws {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        guard !atomIDs.isEmpty else { return }
        let characters = try await store.characters(for: bookID)
        guard characters.contains(where: { $0.id == roleID }) else {
            throw AudiobookCastError.characterNotFound(roleID)
        }

        let allAnnotations = try await store.annotations(for: bookID)
        let targetAtomSet = Set(atomIDs)
        let affectedExisting = allAnnotations.filter { targetAtomSet.contains($0.atomID) }
        guard !affectedExisting.isEmpty else { return }

        let updatedAnnotations = affectedExisting.map { existing -> AudiobookAnnotation in
            var copy = existing
            copy.assignment = .assigned(roleID: roleID)
            copy.userConfirmed = true
            copy.annotationRevision += 1
            return copy
        }
        try await store.saveAnnotations(bookID: bookID, annotations: updatedAnnotations)
        undoStacksByBook[bookID, default: []].append(
            AssignmentUndoSnapshot(bookID: bookID, previousAnnotations: affectedExisting)
        )
    }

    public func undoLastAssignment(bookID: UUID) async throws {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        guard let last = undoStacksByBook[bookID]?.last else {
            throw AudiobookCastError.nothingToUndo
        }
        try await store.saveAnnotations(bookID: bookID, annotations: last.previousAnnotations)
        undoStacksByBook[bookID]?.removeLast()
    }

    // MARK: - Character Rename, Merge & Split

    public func renameCharacter(
        bookID: UUID,
        roleID: UUID,
        newName: String,
        aliases: [String]? = nil
    ) async throws {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var characters = try await store.characters(for: bookID)
        guard let idx = characters.firstIndex(where: { $0.id == roleID }) else {
            throw AudiobookCastError.characterNotFound(roleID)
        }
        characters[idx].displayName = trimmed
        if let aliases {
            characters[idx].aliases = aliases
        }
        characters = AudiobookCastRegistry.enrichCharactersWithVoicePersonas(characters)
        try await store.saveCharacters(bookID: bookID, characters: characters)
    }

    public func previewMergeImpact(
        bookID: UUID,
        sourceRoleID: UUID,
        intoTargetRoleID: UUID
    ) async throws -> AudiobookCastImpactPreview {
        let annotations = try await store.annotations(for: bookID)
        let affected = annotations.filter { $0.assignment.roleID == sourceRoleID }
        let chapterIDs = Array(Set(affected.map(\.chapterID)))
        return AudiobookCastImpactPreview(
            affectedChapterIDs: chapterIDs,
            affectedAtomIDs: affected.map(\.atomID),
            affectedQuotesCount: affected.count
        )
    }

    @discardableResult
    public func mergeCharacters(
        bookID: UUID,
        sourceRoleID: UUID,
        intoTargetRoleID: UUID
    ) async throws -> AudiobookCastImpactPreview {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        guard sourceRoleID != intoTargetRoleID else {
            return AudiobookCastImpactPreview(affectedChapterIDs: [], affectedAtomIDs: [], affectedQuotesCount: 0)
        }
        var characters = try await store.characters(for: bookID)
        guard let sourceChar = characters.first(where: { $0.id == sourceRoleID }),
              let targetIndex = characters.firstIndex(where: { $0.id == intoTargetRoleID })
        else {
            throw AudiobookCastError.characterNotFound(sourceRoleID)
        }
        if sourceChar.isNarrator {
            throw AudiobookCastError.cannotDeleteOrMergeNarrator
        }

        let preview = try await previewMergeImpact(
            bookID: bookID,
            sourceRoleID: sourceRoleID,
            intoTargetRoleID: intoTargetRoleID
        )

        var targetChar = characters[targetIndex]
        let combinedAliases = Set(targetChar.aliases + [sourceChar.displayName] + sourceChar.aliases)
            .subtracting([targetChar.displayName])
        targetChar.aliases = Array(combinedAliases).sorted()
        targetChar.evidences = Array((targetChar.evidences + sourceChar.evidences).prefix(20))
        targetChar.chapterIDs = Array(Set(targetChar.chapterIDs + sourceChar.chapterIDs))
        characters[targetIndex] = targetChar
        characters.removeAll { $0.id == sourceRoleID }
        characters = AudiobookCastRegistry.enrichCharactersWithVoicePersonas(characters)

        let allAnnotations = try await store.annotations(for: bookID)
        let reassigned = allAnnotations.compactMap { ann -> AudiobookAnnotation? in
            guard ann.assignment.roleID == sourceRoleID else { return nil }
            var copy = ann
            copy.assignment = .assigned(roleID: intoTargetRoleID)
            copy.userConfirmed = true
            copy.annotationRevision += 1
            return copy
        }

        try await store.saveCharacters(
            bookID: bookID,
            characters: characters,
            updatingAnnotations: reassigned
        )
        _ = bumpGeneration(for: bookID)
        return preview
    }

    public func splitCharacter(
        bookID: UUID,
        sourceRoleID: UUID,
        newDisplayName: String,
        atomIDs: [UUID]
    ) async throws -> AudiobookCharacter {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        var characters = try await store.characters(for: bookID)
        guard characters.contains(where: { $0.id == sourceRoleID }) else {
            throw AudiobookCastError.characterNotFound(sourceRoleID)
        }
        let allAnnotations = try await store.annotations(for: bookID)
        let targetAtomSet = Set(atomIDs)
        let matchingAnns = allAnnotations.filter { targetAtomSet.contains($0.atomID) }
        let chapterIDs = Array(Set(matchingAnns.map(\.chapterID)))

        let newRole = AudiobookCharacter(
            bookID: bookID,
            displayName: newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
            aliases: [],
            isNarrator: false,
            isMajor: true,
            allowSharedMinorVoice: false,
            evidences: [],
            firstAppearanceRange: matchingAnns.map(\.sourceRange).min(),
            chapterIDs: chapterIDs
        )
        characters.append(newRole)
        characters = AudiobookCastRegistry.enrichCharactersWithVoicePersonas(characters)
        let reassigned = matchingAnns.map { existing -> AudiobookAnnotation in
            var copy = existing
            copy.assignment = .assigned(roleID: newRole.id)
            copy.userConfirmed = true
            copy.annotationRevision += 1
            return copy
        }
        try await store.saveCharacters(
            bookID: bookID,
            characters: characters,
            updatingAnnotations: reassigned
        )
        if !matchingAnns.isEmpty {
            undoStacksByBook[bookID, default: []].append(
                AssignmentUndoSnapshot(bookID: bookID, previousAnnotations: matchingAnns)
            )
        }
        _ = bumpGeneration(for: bookID)
        return characters.first(where: { $0.id == newRole.id }) ?? newRole
    }

    // MARK: - Voice Binding, Cast Confirmation & Audition Gate

    public func bindVoice(
        bookID: UUID,
        roleID: UUID,
        binding: AudiobookVoiceBinding
    ) async throws {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        try await bindVoiceUnderMutation(bookID: bookID, roleID: roleID, binding: binding)
    }

    private func bindVoiceUnderMutation(
        bookID: UUID,
        roleID: UUID,
        binding: AudiobookVoiceBinding,
        onlyIfUnbound: Bool = false,
        expectedVoiceSetDigest: String? = nil
    ) async throws {
        guard binding.roleID == roleID else { throw AudiobookCastError.characterNotFound(roleID) }
        _ = try await bindBatchUnderMutation(bookID: bookID, bindings: [binding], onlyIfUnbound: onlyIfUnbound, expectedVoiceSetDigest: expectedVoiceSetDigest)
    }

    public func applyCastingPlan(bookID: UUID, plan: AudiobookCastingPlan, acknowledgedIssueIDs: Set<UUID>) async throws {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try await applyUnderMutation(bookID: bookID, plan: plan, acknowledgedIssueIDs: acknowledgedIssueIDs)
    }

    private func applyUnderMutation(bookID: UUID, plan: AudiobookCastingPlan, acknowledgedIssueIDs: Set<UUID>) async throws {
        try Task.checkCancellation()
        guard plan.bookID == bookID, plan.isApplicable,
              plan.requiredAcknowledgements.isSubset(of: acknowledgedIssueIDs) else {
            throw AudiobookCastError.invalidCastingPlan(reason: "unacknowledged_or_blocking_issues")
        }
        guard let capabilityProvider else { throw AudiobookCastError.invalidCastingPlan(reason: "capability_unavailable") }
        let current = try await capabilityProvider()
        guard current.snapshotID == plan.snapshotID, voiceCatalog.snapshot().revision == plan.voiceCatalogRevision else {
            throw AudiobookCastError.invalidCastingPlan(reason: "capability_or_catalog_changed")
        }
        for (id, binding) in plan.proposedBindings where plan.affectedRoleIDs.contains(id) {
            try AudiobookCastRegistry.validateRenderBinding(binding, snapshot: current)
            guard let voice = current.voices.first(where: { $0.id == binding.voiceID }), voiceCatalog.snapshot().permits(voice, bookID: bookID) else {
                throw AudiobookCastError.invalidCastingPlan(reason: "voice_scope_changed")
            }
        }
        try Task.checkCancellation()
        try await store.saveCastingPlan(bookID: bookID, plan: plan)
    }

    private func bindBatchUnderMutation(bookID: UUID, bindings: [AudiobookVoiceBinding], onlyIfUnbound: Bool = false, expectedVoiceSetDigest: String? = nil) async throws -> Int {
        guard !bindings.isEmpty else { return 0 }
        if let unready = bindings.first(where: { !$0.isSynthesisReady }) {
            throw AudiobookCastError.voiceNotSynthesisReady(voiceID: unready.voiceID)
        }
        let characters = try await store.characters(for: bookID)
        var proposed = try await store.voiceBindings(for: bookID)
        guard Set(bindings.map(\.roleID)).count == bindings.count else { throw AudiobookCastError.invalidCastingPlan(reason: "duplicate_role") }
        for binding in bindings { proposed[binding.roleID] = binding }
        try AudiobookCastRegistry.validateBindingSet(characters: characters, bindings: proposed,
            requiredRoleIDs: await store.requiredCastingRoleIDs(bookID: bookID))
        guard let capabilityProvider else { throw AudiobookCastError.invalidCastingPlan(reason: "capability_unavailable") }
        let snapshot = try await capabilityProvider()
        let plan = try await store.manualCastingPlan(bookID: bookID, bindings: bindings, snapshot: snapshot, catalog: voiceCatalog.snapshot(), onlyIfUnbound: onlyIfUnbound, expectedVoiceSetDigest: expectedVoiceSetDigest)
        try await applyUnderMutation(bookID: bookID, plan: plan, acknowledgedIssueIDs: [])
        return bindings.count
    }

    public func setAllowSharedMinorVoice(
        bookID: UUID,
        roleID: UUID,
        allowed: Bool
    ) async throws {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        let characters = try await store.characters(for: bookID)
        guard var role = characters.first(where: { $0.id == roleID }) else {
            throw AudiobookCastError.characterNotFound(roleID)
        }
        guard !role.isNarrator || !allowed else {
            throw AudiobookCastError.invalidCastingPlan(reason: "narrator_must_remain_exclusive")
        }
        role.isMajor = !allowed
        role.allowSharedMinorVoice = allowed
        try AudiobookCastRegistry.validateBindingSet(
            characters: characters.map { $0.id == roleID ? role : $0 }, bindings: try await store.voiceBindings(for: bookID),
            requiredRoleIDs: await store.requiredCastingRoleIDs(bookID: bookID)
        )
        try await store.upsertCharacter(role)
    }

    /// Only unbound shared roles participate by default. Existing choices remain protected.
    @discardableResult
    public func batchBindArchetypeVoice(bookID: UUID, archetype: AudiobookVoiceArchetype, voice: SafeVoiceEntry) async throws -> Int {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        let characters = try await store.characters(for: bookID), existing = try await store.voiceBindings(for: bookID)
        let matching = characters.filter { !$0.isNarrator && !$0.isMajor && $0.allowSharedMinorVoice
            && existing[$0.id] == nil && $0.inferredVoiceArchetype(peers: characters) == archetype }
        guard !matching.isEmpty else { return 0 }
        guard let capabilityProvider else { throw AudiobookCastError.invalidCastingPlan(reason: "capability_unavailable") }
        let snapshot = try await capabilityProvider()
        guard let current = snapshot.voices.first(where: { $0.id == voice.id }), current.voiceRevision == voice.voiceRevision, current.mode == voice.mode,
              let options = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: voice.id, in: snapshot),
              let model = options.expectedModelRevision else { throw AudiobookCastError.voiceNotSynthesisReady(voiceID: voice.id) }
        return try await bindBatchUnderMutation(bookID: bookID, bindings: matching.map {
            AudiobookVoiceBinding(roleID: $0.id, voiceID: voice.id, voiceRevision: options.expectedVoiceRevision, modelRevision: model)
        })
    }

    @discardableResult
    public func bindVoicesBatch(bookID: UUID, bindings: [AudiobookVoiceBinding]) async throws -> Int {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        return try await bindBatchUnderMutation(bookID: bookID, bindings: bindings)
    }

    public func currentCastRevisionID(for bookID: UUID) async throws -> UUID {
        let characters = try await store.characters(for: bookID)
        return AudiobookCastRegistry.castRevisionID(bookID: bookID, characters: characters)
    }

    public func currentVoiceSetDigest(for bookID: UUID) async throws -> String {
        let characters = try await store.characters(for: bookID)
        let bindings = try await store.voiceBindings(for: bookID)
        return AudiobookCastRegistry.voiceSetDigest(bookID: bookID, characters: characters, bindings: bindings)
    }

    public func confirmCast(
        bookID: UUID,
        revisionID: UUID
    ) async throws {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        try await store.saveCastConfirmation(bookID: bookID, revisionID: revisionID, voiceSetDigest: nil)
    }

    public func confirmAudition(
        bookID: UUID,
        voiceSetDigest: String
    ) async throws {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        try await store.saveCastConfirmation(bookID: bookID, revisionID: nil, voiceSetDigest: voiceSetDigest)
    }

    func confirmCastAndAudition(
        bookID: UUID,
        revisionID: UUID,
        voiceSetDigest: String
    ) async throws {
        await acquireMutation(for: bookID)
        defer { releaseMutation(for: bookID) }
        try Task.checkCancellation()
        try await store.saveCastConfirmation(
            bookID: bookID, revisionID: revisionID, voiceSetDigest: voiceSetDigest
        )
    }

    // MARK: - Voice Design / Library Round-Trip Context

    public func makeVoiceReturnContext(
        bookID: UUID,
        roleID: UUID
    ) async throws -> AudiobookVoiceReturnContext {
        let revisionID = try await currentCastRevisionID(for: bookID)
        let voiceSetDigest = try await currentVoiceSetDigest(for: bookID)
        let generation = currentGeneration(for: bookID)
        let book = try? await store.book(id: bookID)
        let characters = try await store.characters(for: bookID)
        let role = characters.first(where: { $0.id == roleID })

        var rawDialogueTexts: [String] = []
        if let role,
           let annotations = try? await store.annotations(for: bookID),
           let source = try? await store.sourceIndex(for: bookID)
        {
            let roleAnns = annotations
                .filter { $0.assignment.roleID == role.id }
                .sorted { $0.sourceRange < $1.sourceRange }
            for ann in roleAnns.prefix(24) {
                if let text = try? source.text(in: ann.sourceRange) {
                    rawDialogueTexts.append(text)
                }
            }
        }
        if let role {
            rawDialogueTexts.append(contentsOf: role.evidences.map(\.quoteExcerpt))
        }

        let persona = role.map { AudiobookVoicePersona.infer(for: $0, peers: characters, recompute: true) }
        let compiledInstruction = role.flatMap { r in
            persona?.compiledVoiceDesignInstruction(roleName: r.displayName, isNarrator: r.isNarrator)
        }
        let scriptCandidates: [String] = {
            guard let role else { return [] }
            return AudiobookAuditionScriptSelector.selectCandidates(
                from: rawDialogueTexts,
                roleName: role.displayName,
                aliases: role.aliases,
                isNarrator: role.isNarrator,
                maxCandidates: 3
            )
        }()
        let traitSummary = role.flatMap { r -> String? in
            if let explicit = r.primaryVoiceTraitSummary, !explicit.isEmpty {
                return explicit
            }
            guard let p = persona else { return nil }
            return "\(p.ageGenderAnchor) · \(p.pitchAndRegister)"
        }

        return AudiobookVoiceReturnContext(
            bookID: bookID,
            roleID: roleID,
            castRevisionID: revisionID,
            generation: generation,
            voiceSetDigest: voiceSetDigest,
            bookTitle: book?.title,
            roleDisplayName: role?.displayName,
            roleVoiceTraitSummary: traitSummary,
            suggestedInstruction: compiledInstruction ?? role?.recommendedVoiceDesignInstruction,
            suggestedReferenceText: scriptCandidates.first ?? role?.recommendedVoiceDesignReferenceText,
            suggestedReferenceTextCandidates: scriptCandidates,
            suggestedAcousticChips: persona?.customChips ?? []
        )
    }

    public func completeVoiceReturn(
        context: AudiobookVoiceReturnContext,
        activeBookID: UUID,
        binding: AudiobookVoiceBinding,
        onlyIfUnbound: Bool = false
    ) async throws {
        await acquireMutation(for: activeBookID)
        defer { releaseMutation(for: activeBookID) }
        try Task.checkCancellation()
        let currentRevision = try await currentCastRevisionID(for: activeBookID)
        let currentGen = currentGeneration(for: activeBookID)
        let voiceSetDigest = try await currentVoiceSetDigest(for: activeBookID)
        guard context.bookID == activeBookID,
              context.castRevisionID == currentRevision,
              context.generation == currentGen,
              context.voiceSetDigest == voiceSetDigest,
              context.roleID == binding.roleID
        else {
            throw AudiobookCastError.staleVoiceReturnContext
        }
        try await bindVoiceUnderMutation(bookID: activeBookID, roleID: context.roleID, binding: binding,
            onlyIfUnbound: onlyIfUnbound, expectedVoiceSetDigest: voiceSetDigest)
    }

    // MARK: - Chapter Readiness Evaluation

    public func chapterReadiness(
        bookID: UUID,
        chapterID: UUID
    ) async throws -> AudiobookChapterReadinessState {
        let book = try await store.book(id: bookID)
        guard book.analysisState == .allWindowsValidated else {
            return .awaitingGlobalAnalysis
        }
        let expectedCastRev = try await currentCastRevisionID(for: bookID)
        let expectedVoiceDigest = try await currentVoiceSetDigest(for: bookID)
        guard book.confirmedCastRevisionID == expectedCastRev,
              book.confirmedAuditionVoiceSetDigest == expectedVoiceDigest
        else {
            return .awaitingCastConfirmation
        }

        let chapterAnnotations = try await store.annotations(for: bookID, chapterID: chapterID)
        guard !chapterAnnotations.isEmpty else {
            return .awaitingGlobalAnalysis
        }
        if chapterAnnotations.contains(where: { $0.assignment.isUnknown }) {
            return .blockedByUnknownSpeakers
        }

        let chapters = try await store.chapters(for: bookID)
        if let chapter = chapters.first(where: { $0.id == chapterID }),
           chapter.currentChapterRevisionID != nil
        {
            return .chapterAudioReady
        }
        return .readyForProduction
    }

    /// 一次性计算全书所有章节的就绪状态（避免逐章循环重复解码全书 characters / chapters / voiceBindings 达 2*C 次）。
    public func chapterReadinessMap(
        for bookID: UUID
    ) async throws -> [UUID: AudiobookChapterReadinessState] {
        let book = try await store.book(id: bookID)
        let chapters = try await store.chapters(for: bookID)
        guard !chapters.isEmpty else { return [:] }

        guard book.analysisState == .allWindowsValidated else {
            return Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, AudiobookChapterReadinessState.awaitingGlobalAnalysis) })
        }

        let expectedCastRev = try await currentCastRevisionID(for: bookID)
        let expectedVoiceDigest = try await currentVoiceSetDigest(for: bookID)
        guard book.confirmedCastRevisionID == expectedCastRev,
              book.confirmedAuditionVoiceSetDigest == expectedVoiceDigest
        else {
            return Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, AudiobookChapterReadinessState.awaitingCastConfirmation) })
        }

        let allAnnotations = try await store.annotations(for: bookID)
        let annotationsByChapter = Dictionary(grouping: allAnnotations, by: \.chapterID)

        var map: [UUID: AudiobookChapterReadinessState] = [:]
        map.reserveCapacity(chapters.count)
        for chapter in chapters {
            let chapterAnnotations = annotationsByChapter[chapter.id] ?? []
            if chapterAnnotations.isEmpty {
                map[chapter.id] = .awaitingGlobalAnalysis
            } else if chapterAnnotations.contains(where: { $0.assignment.isUnknown }) {
                map[chapter.id] = .blockedByUnknownSpeakers
            } else if chapter.currentChapterRevisionID != nil {
                map[chapter.id] = .chapterAudioReady
            } else {
                map[chapter.id] = .readyForProduction
            }
        }
        return map
    }
}
