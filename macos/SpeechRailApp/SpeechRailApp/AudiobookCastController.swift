import Foundation

/// T06：人物确认、配声绑定、音色设计往返身份与章节就绪度判定。
public struct AudiobookVoiceReturnContext: Codable, Equatable, Hashable, Sendable {
    public let bookID: UUID
    public let roleID: UUID
    public let castRevisionID: UUID
    public let generation: Int
    public let roleDisplayName: String?
    public let suggestedInstruction: String?
    public let suggestedReferenceText: String?

    public init(
        bookID: UUID,
        roleID: UUID,
        castRevisionID: UUID,
        generation: Int,
        roleDisplayName: String? = nil,
        suggestedInstruction: String? = nil,
        suggestedReferenceText: String? = nil
    ) {
        self.bookID = bookID
        self.roleID = roleID
        self.castRevisionID = castRevisionID
        self.generation = generation
        self.roleDisplayName = roleDisplayName
        self.suggestedInstruction = suggestedInstruction
        self.suggestedReferenceText = suggestedReferenceText
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
    private var undoStacksByBook: [UUID: [AssignmentUndoSnapshot]] = [:]
    private var currentGenerationsByBook: [UUID: Int] = [:]

    public init(store: AudiobookProjectStore) {
        self.store = store
    }

    public func currentGeneration(for bookID: UUID) -> Int {
        currentGenerationsByBook[bookID, default: 1]
    }

    public func bumpGeneration(for bookID: UUID) -> Int {
        let next = currentGenerationsByBook[bookID, default: 1] + 1
        currentGenerationsByBook[bookID] = next
        return next
    }

    // MARK: - Role Assignment & Undo

    public func assignRole(
        bookID: UUID,
        atomIDs: [UUID],
        roleID: UUID
    ) async throws {
        guard !atomIDs.isEmpty else { return }
        let characters = try await store.characters(for: bookID)
        guard characters.contains(where: { $0.id == roleID }) else {
            throw AudiobookCastError.characterNotFound(roleID)
        }

        let allAnnotations = try await store.annotations(for: bookID)
        let targetAtomSet = Set(atomIDs)
        let affectedExisting = allAnnotations.filter { targetAtomSet.contains($0.atomID) }
        guard !affectedExisting.isEmpty else { return }

        undoStacksByBook[bookID, default: []].append(
            AssignmentUndoSnapshot(bookID: bookID, previousAnnotations: affectedExisting)
        )

        let updatedAnnotations = affectedExisting.map { existing -> AudiobookAnnotation in
            var copy = existing
            copy.assignment = .assigned(roleID: roleID)
            copy.userConfirmed = true
            copy.annotationRevision += 1
            return copy
        }
        try await store.saveAnnotations(bookID: bookID, annotations: updatedAnnotations)
    }

    public func undoLastAssignment(bookID: UUID) async throws {
        guard var stack = undoStacksByBook[bookID], let last = stack.popLast() else {
            throw AudiobookCastError.nothingToUndo
        }
        undoStacksByBook[bookID] = stack
        try await store.saveAnnotations(bookID: bookID, annotations: last.previousAnnotations)
    }

    // MARK: - Character Rename, Merge & Split

    public func renameCharacter(
        bookID: UUID,
        roleID: UUID,
        newName: String,
        aliases: [String]? = nil
    ) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let characters = try await store.characters(for: bookID)
        guard var target = characters.first(where: { $0.id == roleID }) else {
            throw AudiobookCastError.characterNotFound(roleID)
        }
        target.displayName = trimmed
        if let aliases {
            target.aliases = aliases
        }
        try await store.upsertCharacter(target)
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

        let allAnnotations = try await store.annotations(for: bookID)
        let reassigned = allAnnotations.compactMap { ann -> AudiobookAnnotation? in
            guard ann.assignment.roleID == sourceRoleID else { return nil }
            var copy = ann
            copy.assignment = .assigned(roleID: intoTargetRoleID)
            copy.userConfirmed = true
            copy.annotationRevision += 1
            return copy
        }

        try await store.saveCharacters(bookID: bookID, characters: characters)
        if !reassigned.isEmpty {
            try await store.saveAnnotations(bookID: bookID, annotations: reassigned)
        }
        _ = bumpGeneration(for: bookID)
        return preview
    }

    public func splitCharacter(
        bookID: UUID,
        sourceRoleID: UUID,
        newDisplayName: String,
        atomIDs: [UUID]
    ) async throws -> AudiobookCharacter {
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
        try await store.saveCharacters(bookID: bookID, characters: characters)
        try await assignRole(bookID: bookID, atomIDs: atomIDs, roleID: newRole.id)
        _ = bumpGeneration(for: bookID)
        return newRole
    }

    // MARK: - Voice Binding, Cast Confirmation & Audition Gate

    public func bindVoice(
        bookID: UUID,
        roleID: UUID,
        binding: AudiobookVoiceBinding
    ) async throws {
        guard binding.isSynthesisReady else {
            throw AudiobookCastError.voiceNotSynthesisReady(voiceID: binding.voiceID)
        }
        let characters = try await store.characters(for: bookID)
        guard let role = characters.first(where: { $0.id == roleID }) else {
            throw AudiobookCastError.characterNotFound(roleID)
        }

        let existingBindings = try await store.voiceBindings(for: bookID)
        if let conflictingEntry = existingBindings.first(where: { $0.key != roleID && $0.value.voiceID == binding.voiceID }) {
            let conflictingRole = characters.first(where: { $0.id == conflictingEntry.key })
            let allowed = (!role.isNarrator && role.allowSharedMinorVoice)
                && (conflictingRole.map { !$0.isNarrator && $0.allowSharedMinorVoice } ?? false)
            if !allowed {
                throw AudiobookCastError.duplicateVoiceRequiresSharedMinorConsent(
                    voiceID: binding.voiceID,
                    conflictingRoleID: conflictingEntry.key
                )
            }
        }

        try await store.saveVoiceBinding(bookID: bookID, binding: binding)

        // Changing a voice binding invalidates previous audition confirmation until re-confirmed
        var book = try await store.book(id: bookID)
        let newDigest = try await currentVoiceSetDigest(for: bookID)
        if book.confirmedAuditionVoiceSetDigest != nil && book.confirmedAuditionVoiceSetDigest != newDigest {
            book.confirmedAuditionVoiceSetDigest = nil
            try await store.updateBook(book)
        }
    }

    public func setAllowSharedMinorVoice(
        bookID: UUID,
        roleID: UUID,
        allowed: Bool
    ) async throws {
        let characters = try await store.characters(for: bookID)
        guard var role = characters.first(where: { $0.id == roleID }) else {
            throw AudiobookCastError.characterNotFound(roleID)
        }
        role.isMajor = !allowed
        role.allowSharedMinorVoice = allowed
        try await store.upsertCharacter(role)
    }

    public func currentCastRevisionID(for bookID: UUID) async throws -> UUID {
        let characters = try await store.characters(for: bookID)
        let sorted = characters.sorted { $0.id.uuidString < $1.id.uuidString }
        let raw = sorted.map { "\($0.id.uuidString):\($0.isNarrator):\($0.allowSharedMinorVoice)" }
            .joined(separator: "|")
        let hex = AudiobookDigest.sha256Hex(Data("cast_rev|\(bookID.uuidString)|\(raw)".utf8))
        let chars = Array(hex.prefix(32))
        let uuidStr = String(chars[0..<8]) + "-"
            + String(chars[8..<12]) + "-"
            + String(chars[12..<16]) + "-"
            + String(chars[16..<20]) + "-"
            + String(chars[20..<32])
        return UUID(uuidString: uuidStr) ?? UUID()
    }

    public func currentVoiceSetDigest(for bookID: UUID) async throws -> String {
        let characters = try await store.characters(for: bookID)
        let bindings = try await store.voiceBindings(for: bookID)
        let parts = characters
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { role -> String in
                let digest = bindings[role.id]?.bindingDigest ?? "unbound"
                return "\(role.id.uuidString):\(digest)"
            }
            .joined(separator: "|")
        return AudiobookDigest.sha256Hex(Data("voice_set|\(bookID.uuidString)|\(parts)".utf8))
    }

    public func confirmCast(
        bookID: UUID,
        revisionID: UUID
    ) async throws {
        var book = try await store.book(id: bookID)
        guard book.analysisState == .allWindowsValidated else {
            throw AudiobookCastError.analysisNotCompleted
        }
        let expectedRevisionID = try await currentCastRevisionID(for: bookID)
        guard revisionID == expectedRevisionID else {
            throw AudiobookCastError.castRevisionMismatch
        }
        let characters = try await store.characters(for: bookID)
        let bindings = try await store.voiceBindings(for: bookID)
        let unbound = characters.filter { bindings[$0.id]?.isSynthesisReady != true }.map(\.displayName)
        guard unbound.isEmpty else {
            throw AudiobookCastError.missingVoiceBindings(unboundRoleNames: unbound)
        }

        book.confirmedCastRevisionID = revisionID
        try await store.updateBook(book)
    }

    public func confirmAudition(
        bookID: UUID,
        voiceSetDigest: String
    ) async throws {
        var book = try await store.book(id: bookID)
        guard book.analysisState == .allWindowsValidated else {
            throw AudiobookCastError.analysisNotCompleted
        }
        let currentDigest = try await currentVoiceSetDigest(for: bookID)
        guard voiceSetDigest == currentDigest else {
            throw AudiobookCastError.auditionDigestMismatch
        }
        book.confirmedAuditionVoiceSetDigest = voiceSetDigest
        try await store.updateBook(book)
    }

    // MARK: - Voice Design / Library Round-Trip Context

    public func makeVoiceReturnContext(
        bookID: UUID,
        roleID: UUID
    ) async throws -> AudiobookVoiceReturnContext {
        let revisionID = try await currentCastRevisionID(for: bookID)
        let generation = currentGeneration(for: bookID)
        let characters = try await store.characters(for: bookID)
        let role = characters.first(where: { $0.id == roleID })
        return AudiobookVoiceReturnContext(
            bookID: bookID,
            roleID: roleID,
            castRevisionID: revisionID,
            generation: generation,
            roleDisplayName: role?.displayName,
            suggestedInstruction: role?.recommendedVoiceDesignInstruction,
            suggestedReferenceText: role?.recommendedVoiceDesignReferenceText
        )
    }

    public func completeVoiceReturn(
        context: AudiobookVoiceReturnContext,
        activeBookID: UUID,
        binding: AudiobookVoiceBinding
    ) async throws {
        let currentRevision = try await currentCastRevisionID(for: activeBookID)
        let currentGen = currentGeneration(for: activeBookID)
        guard context.bookID == activeBookID,
              context.castRevisionID == currentRevision,
              context.generation == currentGen,
              context.roleID == binding.roleID
        else {
            throw AudiobookCastError.staleVoiceReturnContext
        }
        try await bindVoice(bookID: activeBookID, roleID: context.roleID, binding: binding)
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
}
