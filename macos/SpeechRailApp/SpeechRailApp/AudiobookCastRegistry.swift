import Foundation
import SpeechRailControlKit

/// T05：全书角色归并、候选批次筛选（每批最多 32 个候选）、声线特征保留与智能音色推荐匹配。
public enum AudiobookCastRegistry {
    static func castRevisionID(bookID: UUID, characters: [AudiobookCharacter]) -> UUID {
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

    static func voiceSetDigest(
        bookID: UUID,
        characters: [AudiobookCharacter],
        bindings: [UUID: AudiobookVoiceBinding]
    ) -> String {
        let parts = characters
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { role -> String in
                let digest = bindings[role.id]?.bindingDigest ?? "unbound"
                return "\(role.id.uuidString):\(digest)"
            }
            .joined(separator: "|")
        return AudiobookDigest.sha256Hex(Data("voice_set|\(bookID.uuidString)|\(parts)".utf8))
    }

    public struct ConsolidationOutcome: Equatable, Sendable {
        public var characters: [AudiobookCharacter]
        public var unresolvedCollisionNames: Set<String>

        public init(
            characters: [AudiobookCharacter],
            unresolvedCollisionNames: Set<String> = []
        ) {
            self.characters = characters
            self.unresolvedCollisionNames = unresolvedCollisionNames
        }
    }

    /// 将提取阶段得到的 mentions 按最多 32 个一批分批，执行本地确定性别名预聚类与证据摘录注入，并限制单个角色的别称与证据数量防止撑爆单批上下文预算。
    public static func batchMentions(
        _ mentions: [AudiobookExtractionResponse.Mention],
        batchSize: Int = AudiobookLimits.maxCastMergeBatchSize,
        atomsByID: [UUID: AudiobookTextAtom] = [:],
        source: AudiobookSourceIndex? = nil
    ) -> [[AudiobookExtractionResponse.Mention]] {
        let clampedBatchSize = max(1, min(batchSize, AudiobookLimits.maxCastMergeBatchSize))
        var deduplicatedBySurface: [String: AudiobookExtractionResponse.Mention] = [:]
        var orderedKeys: [String] = []

        for mention in mentions {
            let trimmed = mention.surfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "旁白" else { continue }
            let cleanAliases = mention.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != trimmed && $0 != "旁白" }
            if var existing = deduplicatedBySurface[trimmed] {
                existing = mergeMentionPair(primary: existing, secondary: mention, extraAliases: cleanAliases)
                deduplicatedBySurface[trimmed] = existing
            } else {
                var normalized = mention
                normalized.surfaceName = trimmed
                normalized.aliases = Array(Set(cleanAliases).sorted().prefix(12))
                normalized.evidenceAtomIDs = Array(mention.evidenceAtomIDs.prefix(6))
                if let trait = mention.voiceTraitEvidence?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    normalized.voiceTraitEvidence = trait.isEmpty ? nil : trait
                }
                deduplicatedBySurface[trimmed] = normalized
                orderedKeys.append(trimmed)
            }
        }

        // 本地别名预聚类：若候选 B 的 surfaceName 已显式出现在候选 A 的 aliases 中（或反之），在送入大模型前直接本地合并
        var clustered: [AudiobookExtractionResponse.Mention] = []
        for key in orderedKeys {
            guard let candidate = deduplicatedBySurface[key] else { continue }
            if let matchIdx = clustered.firstIndex(where: { existing in
                existing.aliases.contains(candidate.surfaceName)
                    || candidate.aliases.contains(existing.surfaceName)
            }) {
                let mergedAliases = [candidate.surfaceName] + candidate.aliases
                clustered[matchIdx] = mergeMentionPair(
                    primary: clustered[matchIdx],
                    secondary: candidate,
                    extraAliases: mergedAliases
                )
            } else {
                clustered.append(candidate)
            }
        }

        // 注入原文微摘要（每个角色最多 2 条、每条不超过 60 字），让阶段二大模型基于真实语境判别同人或同名碰撞
        if let source, !atomsByID.isEmpty {
            clustered = clustered.map { mention in
                var copy = mention
                if copy.evidenceExcerpts.isEmpty {
                    var excerpts: [String] = []
                    for atomID in copy.evidenceAtomIDs {
                        guard let atom = atomsByID[atomID],
                              let rawText = try? source.text(in: atom.sourceRange)
                        else { continue }
                        let compact = rawText
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !compact.isEmpty else { continue }
                        let clipped = String(compact.prefix(60))
                        if !excerpts.contains(clipped) {
                            excerpts.append(clipped)
                        }
                        if excerpts.count >= 2 { break }
                    }
                    copy.evidenceExcerpts = excerpts
                } else {
                    copy.evidenceExcerpts = Array(copy.evidenceExcerpts.prefix(2))
                }
                return copy
            }
        }

        guard !clustered.isEmpty else { return [] }

        var batches: [[AudiobookExtractionResponse.Mention]] = []
        var index = 0
        while index < clustered.count {
            let end = min(clustered.count, index + clampedBatchSize)
            batches.append(Array(clustered[index..<end]))
            index = end
        }
        return batches
    }

    private static func mergeMentionPair(
        primary: AudiobookExtractionResponse.Mention,
        secondary: AudiobookExtractionResponse.Mention,
        extraAliases: [String]
    ) -> AudiobookExtractionResponse.Mention {
        var updated = primary
        let combinedAliases = Set(primary.aliases + extraAliases)
            .subtracting([primary.surfaceName, "旁白"])
            .filter { !$0.isEmpty }
            .sorted()
        updated.aliases = Array(combinedAliases.prefix(12))

        var mergedAtomIDs = primary.evidenceAtomIDs
        for atomID in secondary.evidenceAtomIDs where !mergedAtomIDs.contains(atomID) {
            if mergedAtomIDs.count >= 6 { break }
            mergedAtomIDs.append(atomID)
        }
        updated.evidenceAtomIDs = mergedAtomIDs

        if updated.voiceTraitEvidence == nil,
           let trait = secondary.voiceTraitEvidence?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trait.isEmpty
        {
            updated.voiceTraitEvidence = trait
        }

        var mergedExcerpts = primary.evidenceExcerpts
        for excerpt in secondary.evidenceExcerpts where !mergedExcerpts.contains(excerpt) {
            if mergedExcerpts.count >= 2 { break }
            mergedExcerpts.append(excerpt)
        }
        updated.evidenceExcerpts = mergedExcerpts
        return updated
    }

    /// 结合已有角色库与本批归并输出，更新全书角色表（保留稳定 role ID、旁白与声线特征摘要）。
    public static func applyMergeBatch(
        bookID: UUID,
        existingCharacters: [AudiobookCharacter],
        batchMentions: [AudiobookExtractionResponse.Mention],
        mergeGroups: [AudiobookMergeResponse.Group],
        atomsByID: [UUID: AudiobookTextAtom],
        source: AudiobookSourceIndex
    ) -> ConsolidationOutcome {
        var result = existingCharacters
        if !result.contains(where: \.isNarrator) {
            result.insert(
                AudiobookCharacter(
                    bookID: bookID,
                    displayName: "旁白",
                    aliases: ["叙述"],
                    isNarrator: true,
                    isMajor: true
                ),
                at: 0
            )
        }

        var unresolvedCollisions = Set<String>()
        var mentionsByName: [String: AudiobookExtractionResponse.Mention] = [:]
        for mention in batchMentions {
            mentionsByName[mention.surfaceName] = mention
            for alias in mention.aliases where mentionsByName[alias] == nil {
                mentionsByName[alias] = mention
            }
        }

        for group in mergeGroups {
            let canonical = group.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { continue }
            if group.isCollisionUnresolved {
                unresolvedCollisions.insert(canonical)
                for member in group.memberSurfaceNames {
                    unresolvedCollisions.insert(member)
                }
            }

            let allNames = Set([canonical] + group.memberSurfaceNames + group.aliases)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "旁白" }

            let groupTrait: String? = {
                if let summary = group.evidenceSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    return summary
                }
                for name in allNames {
                    if let trait = mentionsByName[name]?.voiceTraitEvidence?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !trait.isEmpty
                    {
                        return trait
                    }
                }
                return nil
            }()

            var evidences: [AudiobookCharacterEvidence] = []
            var seenEvidenceAtomIDs = Set<UUID>()
            var chapterIDSet = Set<UUID>()
            var earliestRange: AudiobookSourceRange?

            for name in allNames.sorted() {
                guard let mention = mentionsByName[name] else { continue }
                let mentionTrait = mention.voiceTraitEvidence?.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveTrait = (mentionTrait?.isEmpty == false ? mentionTrait : nil) ?? groupTrait
                for atomID in mention.evidenceAtomIDs where !seenEvidenceAtomIDs.contains(atomID) {
                    guard let atom = atomsByID[atomID] else { continue }
                    seenEvidenceAtomIDs.insert(atomID)
                    chapterIDSet.insert(atom.chapterID)
                    if earliestRange == nil || atom.sourceRange < earliestRange! {
                        earliestRange = atom.sourceRange
                    }
                    let excerpt = (try? source.text(in: atom.sourceRange)) ?? name
                    evidences.append(
                        AudiobookCharacterEvidence(
                            chapterID: atom.chapterID,
                            sourceRange: atom.sourceRange,
                            quoteExcerpt: String(excerpt.prefix(120)),
                            voiceTraitSummary: effectiveTrait
                        )
                    )
                }
            }

            if evidences.isEmpty, let groupTrait, let fallbackAtom = atomsByID.values.min(by: { $0.sourceRange < $1.sourceRange }) {
                evidences.append(
                    AudiobookCharacterEvidence(
                        chapterID: fallbackAtom.chapterID,
                        sourceRange: fallbackAtom.sourceRange,
                        quoteExcerpt: canonical,
                        voiceTraitSummary: groupTrait
                    )
                )
            }

            // 如果发生未决同名碰撞，不强行合并到既有同名角色，保留独立复核条目或仅附加别名提示
            if !group.isCollisionUnresolved,
               let matchIndex = result.firstIndex(where: { character in
                   !character.isNarrator && (
                       character.displayName == canonical
                           || !Set(character.aliases).isDisjoint(with: allNames)
                   )
               })
            {
                var updated = result[matchIndex]
                let combinedAliases = Set(updated.aliases)
                    .union(allNames)
                    .subtracting([updated.displayName])
                updated.aliases = Array(combinedAliases).sorted()
                var combinedEvidences = updated.evidences + evidences
                if let groupTrait, !combinedEvidences.isEmpty, combinedEvidences[0].voiceTraitSummary == nil {
                    combinedEvidences[0].voiceTraitSummary = groupTrait
                }
                updated.evidences = Array(combinedEvidences.prefix(16))
                updated.chapterIDs = Array(Set(updated.chapterIDs).union(chapterIDSet))
                if let earliestRange {
                    if let currentFirst = updated.firstAppearanceRange {
                        updated.firstAppearanceRange = min(currentFirst, earliestRange)
                    } else {
                        updated.firstAppearanceRange = earliestRange
                    }
                }
                result[matchIndex] = updated
            } else {
                let aliases = Array(Set(allNames).subtracting([canonical])).sorted()
                let newCharacter = AudiobookCharacter(
                    bookID: bookID,
                    displayName: canonical,
                    aliases: aliases,
                    isNarrator: false,
                    isMajor: chapterIDSet.count >= 1,
                    allowSharedMinorVoice: false,
                    evidences: Array(evidences.prefix(16)),
                    firstAppearanceRange: earliestRange,
                    chapterIDs: Array(chapterIDSet)
                )
                result.append(newCharacter)
            }
        }

        result = enrichCharactersWithVoicePersonas(result)
        return ConsolidationOutcome(
            characters: result,
            unresolvedCollisionNames: unresolvedCollisions
        )
    }

    /// 为单窗标注筛选候选角色摘要（不把全书庞大的角色库无上限塞入单次 prompt），并分配短代号 R1...Rk。
    public static func selectCandidateSummariesForWindow(
        characters: [AudiobookCharacter],
        chapterID: UUID,
        windowText: String,
        policy: AudiobookAnalysisPolicy = .standard
    ) -> [AudiobookPromptCharacterSummary] {
        selectCandidateSummariesForEvidence(
            characters: characters,
            chapterIDs: [chapterID],
            windowText: windowText,
            policy: policy
        )
    }

    /// 根据当前证据涉及的章节筛选角色，避免全书归并批次被无关章节的角色挤出候选上下文。
    static func selectCandidateSummariesForEvidence(
        characters: [AudiobookCharacter],
        chapterIDs: Set<UUID>,
        windowText: String,
        policy: AudiobookAnalysisPolicy = .standard
    ) -> [AudiobookPromptCharacterSummary] {
        let nonNarrators = characters.filter { !$0.isNarrator }
        let scored = nonNarrators.map { character -> (AudiobookCharacter, Int) in
            var score = 0
            if !Set(character.chapterIDs).isDisjoint(with: chapterIDs) {
                score += 50
            }
            if windowText.contains(character.displayName) {
                score += 100
            }
            for alias in character.aliases where !alias.isEmpty && windowText.contains(alias) {
                score += 80
            }
            if character.isMajor {
                score += 10
            }
            return (character, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.displayName < rhs.0.displayName
        }

        var selected: [AudiobookPromptCharacterSummary] = []
        for (character, _) in scored {
            if selected.count >= policy.maxMergeCandidatesPerBatch {
                break
            }
            let traitPrefix = character.primaryVoiceTraitSummary.map { "[\($0)] " } ?? ""
            let rawExcerpt = character.evidences.first?.quoteExcerpt ?? ""
            let combinedNote = (traitPrefix + rawExcerpt).trimmingCharacters(in: .whitespacesAndNewlines)
            let roleKey = "R\(selected.count + 1)"
            let summary = AudiobookPromptCharacterSummary(
                roleID: character.id,
                canonicalName: character.displayName,
                aliases: Array(character.aliases.prefix(8)),
                evidenceNote: combinedNote.isEmpty ? nil : String(combinedNote.prefix(60)),
                roleKey: roleKey
            )
            let candidateList = selected + [summary]
            if AudiobookPromptCharacterSummary.serializedScalarCount(for: candidateList) <= policy.maxCharacterSummaryScalars {
                selected = candidateList
            } else if summary.evidenceNote != nil {
                // 若仅因线索摘录略微超出预算，降级省略 evidenceNote，优先保全角色名称与别名代号供模型识别
                var compactSummary = summary
                compactSummary.evidenceNote = nil
                let compactList = selected + [compactSummary]
                if AudiobookPromptCharacterSummary.serializedScalarCount(for: compactList) <= policy.maxCharacterSummaryScalars {
                    selected = compactList
                } else {
                    break
                }
            } else {
                break
            }
        }
        return selected
    }

    /// 兜底防线：将任意候选角色摘要列表安全裁剪至策略预算内，确保绝不会因超出标量上限中断流程。
    public static func clampSummariesToBudget(
        _ summaries: [AudiobookPromptCharacterSummary],
        maxScalars: Int = AudiobookLimits.maxCastSummaryScalars,
        maxCandidates: Int = AudiobookLimits.maxCastMergeBatchSize
    ) -> [AudiobookPromptCharacterSummary] {
        var selected: [AudiobookPromptCharacterSummary] = []
        for summary in summaries.prefix(maxCandidates) {
            let candidateList = selected + [summary]
            if AudiobookPromptCharacterSummary.serializedScalarCount(for: candidateList) <= maxScalars {
                selected = candidateList
            } else if summary.evidenceNote != nil {
                var compact = summary
                compact.evidenceNote = nil
                let compactList = selected + [compact]
                if AudiobookPromptCharacterSummary.serializedScalarCount(for: compactList) <= maxScalars {
                    selected = compactList
                } else {
                    break
                }
            } else {
                break
            }
        }
        return selected
    }

    /// 计算全书角色的对白频次、跨章分布、四级分层（旁白/主角/配角/群像）以及同场对话冲突图权重。
    public static func computeRoleDialogueStats(
        characters: [AudiobookCharacter],
        annotations: [AudiobookAnnotation],
        availableVoiceCount: Int = 8
    ) -> (
        updatedCharacters: [AudiobookCharacter],
        statsByRoleID: [UUID: AudiobookRoleDialogueStats],
        conflictWeights: [UUID: [UUID: Int]]
    ) {
        guard !characters.isEmpty else { return ([], [:], [:]) }

        var dialogueCounts: [UUID: Int] = [:]
        var activeChaptersByRole: [UUID: Set<UUID>] = [:]
        var scenePartnersByRole: [UUID: Set<UUID>] = [:]
        var sameChapterByRole: [UUID: Set<UUID>] = [:]
        var conflictWeights: [UUID: [UUID: Int]] = [:]

        let narratorIDs = Set(characters.filter(\.isNarrator).map(\.id))
        let sortedAnnotations = annotations.sorted {
            if $0.chapterID != $1.chapterID {
                return $0.chapterID.uuidString < $1.chapterID.uuidString
            }
            return $0.sourceRange < $1.sourceRange
        }

        for ann in sortedAnnotations {
            if let roleID = ann.assignment.roleID {
                dialogueCounts[roleID, default: 0] += 1
                activeChaptersByRole[roleID, default: []].insert(ann.chapterID)
            }
        }

        // 构建同章与同场（相邻 6 个对白块以内）共现排斥图 G = (V, E)
        let nonNarratorAnns = sortedAnnotations.filter { ann in
            guard let rid = ann.assignment.roleID else { return false }
            return !narratorIDs.contains(rid)
        }
        let annsByChapter = Dictionary(grouping: nonNarratorAnns, by: \.chapterID)

        for (_, chapterAnns) in annsByChapter {
            let uniqueRoles = Array(Set(chapterAnns.compactMap(\.assignment.roleID)))
            for i in 0..<uniqueRoles.count {
                for j in (i + 1)..<uniqueRoles.count {
                    let rA = uniqueRoles[i]
                    let rB = uniqueRoles[j]
                    sameChapterByRole[rA, default: []].insert(rB)
                    sameChapterByRole[rB, default: []].insert(rA)
                    conflictWeights[rA, default: [:]][rB] = max(conflictWeights[rA]?[rB] ?? 0, 180)
                    conflictWeights[rB, default: [:]][rA] = max(conflictWeights[rB]?[rA] ?? 0, 180)
                }
            }

            for i in 0..<chapterAnns.count {
                guard let roleA = chapterAnns[i].assignment.roleID else { continue }
                let upper = min(chapterAnns.count, i + 7)
                for j in (i + 1)..<upper {
                    guard let roleB = chapterAnns[j].assignment.roleID, roleA != roleB else { continue }
                    scenePartnersByRole[roleA, default: []].insert(roleB)
                    scenePartnersByRole[roleB, default: []].insert(roleA)
                    let updatedWeight = min(1800, (conflictWeights[roleA]?[roleB] ?? 0) + 600)
                    conflictWeights[roleA, default: [:]][roleB] = updatedWeight
                    conflictWeights[roleB, default: [:]][roleA] = updatedWeight
                }
            }
        }

        let narrators = characters.filter(\.isNarrator)
        let nonNarrators = characters.filter { !$0.isNarrator }
        let speakingNonNarrators = nonNarrators.filter { (dialogueCounts[$0.id] ?? 0) > 0 }
        let totalNonNarratorDialogue = speakingNonNarrators.reduce(0) { $0 + (dialogueCounts[$1.id] ?? 0) }

        let effectiveVoiceCount = max(0, availableVoiceCount)
        let kLead: Int = {
            if speakingNonNarrators.count <= max(1, effectiveVoiceCount - 1) {
                return speakingNonNarrators.count
            }
            let reservedSharedPool = min(6, max(1, (effectiveVoiceCount - 1) / 2))
            return min(8, max(1, effectiveVoiceCount - 1 - reservedSharedPool))
        }()

        let sortedNonNarrators = nonNarrators.sorted { lhs, rhs in
            let countL = dialogueCounts[lhs.id] ?? 0
            let countR = dialogueCounts[rhs.id] ?? 0
            if countL != countR { return countL > countR }
            let chL = activeChaptersByRole[lhs.id]?.count ?? lhs.chapterIDs.count
            let chR = activeChaptersByRole[rhs.id]?.count ?? rhs.chapterIDs.count
            if chL != chR { return chL > chR }
            return lhs.displayName < rhs.displayName
        }

        var rankByRoleID: [UUID: Int] = [:]
        for (idx, role) in sortedNonNarrators.enumerated() {
            rankByRoleID[role.id] = idx
        }

        var statsByRoleID: [UUID: AudiobookRoleDialogueStats] = [:]
        var updatedNarrators: [AudiobookCharacter] = []

        for var narrator in narrators {
            narrator.isMajor = true
            narrator.allowSharedMinorVoice = false
            updatedNarrators.append(narrator)
            statsByRoleID[narrator.id] = AudiobookRoleDialogueStats(
                roleID: narrator.id,
                dialogueAtomCount: dialogueCounts[narrator.id] ?? 0,
                speakingChapterIDs: activeChaptersByRole[narrator.id] ?? Set(narrator.chapterIDs),
                tier: .narrator,
                archetype: .narrator
            )
        }

        var updatedNonNarrators: [AudiobookCharacter] = []
        for role in sortedNonNarrators {
            var copy = role
            let count = dialogueCounts[role.id] ?? 0
            if let chapters = activeChaptersByRole[role.id], !chapters.isEmpty {
                copy.chapterIDs = Set(copy.chapterIDs).union(chapters).sorted { $0.uuidString < $1.uuidString }
            }
            let effectiveChapterCount = max(activeChaptersByRole[role.id]?.count ?? 0, copy.chapterIDs.count)
            let archetype = copy.inferredVoiceArchetype(peers: characters)

            let tier: AudiobookRoleTier
            if annotations.isEmpty {
                // 若尚未产生对白归属标注，尊重角色当前显式设置的 isMajor / allowSharedMinorVoice
                tier = copy.isMajor ? .lead : (effectiveChapterCount >= 2 ? .supporting : .ensemble)
            } else if nonNarrators.count <= 4 {
                let isMajorRole = count >= 2 || effectiveChapterCount >= 2
                copy.isMajor = isMajorRole
                copy.allowSharedMinorVoice = !isMajorRole
                tier = isMajorRole ? .lead : .ensemble
            } else {
                let rank = rankByRoleID[copy.id] ?? Int.max
                let dialogueShare = Double(count) / Double(max(1, totalNonNarratorDialogue))
                let qualifiesAsLead = count > 0
                    && rank < kLead
                    && (count >= 4 || dialogueShare >= 0.08 || speakingNonNarrators.count <= max(1, effectiveVoiceCount - 1))

                if qualifiesAsLead {
                    tier = .lead
                    copy.isMajor = true
                    copy.allowSharedMinorVoice = false
                } else if count >= 3 || effectiveChapterCount >= 2 {
                    tier = .supporting
                    copy.isMajor = false
                    copy.allowSharedMinorVoice = true
                } else {
                    tier = .ensemble
                    copy.isMajor = false
                    copy.allowSharedMinorVoice = true
                }
            }

            updatedNonNarrators.append(copy)
            statsByRoleID[copy.id] = AudiobookRoleDialogueStats(
                roleID: copy.id,
                dialogueAtomCount: count,
                speakingChapterIDs: activeChaptersByRole[copy.id] ?? Set(copy.chapterIDs),
                tier: tier,
                archetype: archetype,
                scenePartnerRoleIDs: scenePartnersByRole[copy.id] ?? [],
                sameChapterRoleIDs: sameChapterByRole[copy.id] ?? []
            )
        }

        let enriched = enrichCharactersWithVoicePersonas(updatedNarrators + updatedNonNarrators, recompute: false)
        return (enriched, statsByRoleID, conflictWeights)
    }

    /// 全书分析后根据帕累托对白分布与跨章共现更新主次角色标记及排序（旁白置顶，核心主角独占，配角与群像默认允许共享声线池）。
    public static func refreshCharacterMajorStatusAndOrder(
        characters: [AudiobookCharacter],
        annotations: [AudiobookAnnotation],
        availableVoiceCount: Int = 8
    ) -> [AudiobookCharacter] {
        computeRoleDialogueStats(
            characters: characters,
            annotations: annotations,
            availableVoiceCount: availableVoiceCount
        ).updatedCharacters
    }

    /// 为全书角色批量计算并注入对比去重后的六维声学画像（AudiobookVoicePersona）。
    public static func enrichCharactersWithVoicePersonas(
        _ characters: [AudiobookCharacter],
        recompute: Bool = true
    ) -> [AudiobookCharacter] {
        characters.map { role in
            var copy = role
            if !recompute, copy.evidences.first?.voicePersona != nil {
                return copy
            }
            let persona = AudiobookVoicePersona.infer(for: copy, peers: characters, recompute: recompute)
            if copy.evidences.isEmpty {
                copy.evidences = [
                    AudiobookCharacterEvidence(
                        chapterID: copy.chapterIDs.first ?? UUID(),
                        sourceRange: copy.firstAppearanceRange ?? AudiobookSourceRange(lowerBound: 0, upperBound: 0),
                        quoteExcerpt: copy.displayName,
                        voiceTraitSummary: copy.primaryVoiceTraitSummary,
                        voicePersona: persona
                    )
                ]
            } else {
                copy.evidences[0].voicePersona = persona
            }
            return copy
        }
    }

    /// Pure planning: scope, readiness and identity are hard constraints; no writes or global reads.
    public static func recommendVoiceBindings(
        characters: [AudiobookCharacter],
        annotations: [AudiobookAnnotation],
        snapshot: EffectiveCapabilitySnapshot,
        catalog: VoiceCatalogSnapshot,
        bookID: UUID,
        existingBindings: [UUID: AudiobookVoiceBinding]
    ) -> AudiobookCastingPlan {
        makeCastingPlan(characters: characters, annotations: annotations, snapshot: snapshot,
            catalog: catalog, bookID: bookID, existingBindings: existingBindings, requiredRoleIDs: nil)
    }

    /// Store may narrow the required set only after checking complete source annotations.
    static func makeCastingPlan(
        characters: [AudiobookCharacter], annotations: [AudiobookAnnotation], snapshot: EffectiveCapabilitySnapshot,
        catalog: VoiceCatalogSnapshot, bookID: UUID, existingBindings: [UUID: AudiobookVoiceBinding], requiredRoleIDs: Set<UUID>?
    ) -> AudiobookCastingPlan {
        var issues: [AudiobookCastingIssue] = []
        let speaking = Set(annotations.compactMap(\.assignment.roleID))
        let active = characters.filter { role in
            if let requiredRoleIDs { return role.isNarrator || requiredRoleIDs.contains(role.id) }
            return role.isNarrator || existingBindings[role.id] != nil || annotations.isEmpty || speaking.contains(role.id)
        }
        let sortedRoles = active.sorted { $0.id.uuidString < $1.id.uuidString }
        var bindings = existingBindings
        var policies: [UUID: AudiobookRoleVoicePolicy] = [:]
        for role in characters {
            policies[role.id] = .init(
                sharingPolicy: role.isNarrator || role.isMajor ? .exclusive : (existingBindings[role.id] != nil && role.allowSharedMinorVoice ? .sharedMinor : .automatic),
                bindingOrigin: existingBindings[role.id] != nil ? .legacyUnknown : .automatic,
                isLocked: existingBindings[role.id] != nil
            )
        }
        var voices: [SafeVoiceEntry] = []
        if catalog.loadState == .unreadable || catalog.loadState == .unsupportedSchema {
            issues.append(.init(code: .catalogUnavailable, nextAction: "请修复或恢复音色目录后重新推荐。"))
        } else {
            let groups = Dictionary(grouping: snapshot.voices, by: \.id)
            for id in groups.keys.sorted() {
                guard let group = groups[id], let voice = group.first else { continue }
                guard group.allSatisfy({ $0 == voice }) else {
                    issues.append(.init(code: .voiceIdentityUnknown, voiceIDs: [id], isBlocking: false, severity: .info, nextAction: "此声音存在冲突的身份记录，请重新检查声音目录。"))
                    continue
                }
                guard catalog.permits(voice, bookID: bookID) else {
                    let missingOrigin = catalog.state.metadataByVoiceID[id] == nil
                        || (catalog.state.metadataByVoiceID[id]?.scope == .bookExclusive && catalog.state.metadataByVoiceID[id]?.originBookID == nil)
                    issues.append(.init(code: missingOrigin ? .voiceIdentityUnknown : .voiceScopeUnavailable, voiceIDs: [id], isBlocking: false, severity: .info,
                        nextAction: missingOrigin ? "请确认此声音的书籍归属后重新推荐。" : "此声音已归档或属于其他书籍，请选择本书可用的声音。"))
                    continue
                }
                guard voice.available, voice.productionReady == true, voice.operations["http_speech"] != nil else {
                    issues.append(.init(code: .voiceNotProductionReady, voiceIDs: [id], isBlocking: false, severity: .info, nextAction: "此声音尚不能用于正式制作，请检查声音后重新推荐。"))
                    continue
                }
                let proposed = AudiobookVoiceBinding(
                    roleID: bookID, voiceID: voice.id, voiceRevision: voice.voiceRevision,
                    modelRevision: SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: voice.id, in: snapshot)?.expectedModelRevision ?? ""
                )
                do {
                    try validateRenderBinding(proposed, snapshot: snapshot)
                    voices.append(voice)
                } catch {
                    let parameterFailure: Bool
                    if case let ServiceAPIClientError.invalidContract(reason) = error {
                        parameterFailure = reason == "unsupported_render_speed" || reason == "unsupported_caller_seed" || reason == "voice_parameters_require_reconfirmation"
                    } else { parameterFailure = false }
                    issues.append(.init(code: parameterFailure ? .unsupportedRenderParameter : .voiceIdentityUnknown,
                        voiceIDs: [id], isBlocking: false, severity: .info,
                        nextAction: parameterFailure ? "此声音尚未声明支持制作参数，请重新检查后再选择。" : "请重新核实此声音与模型的版本身份。"))
                }
            }
        }
        let eligibleIDs = Set(voices.map(\.id))
        if voices.isEmpty, !active.isEmpty {
            issues.append(.init(code: .noEligibleVoices, roleIDs: active.map(\.id), nextAction: "请确认本书有可用且已通过验收的声音及其归属。"))
        }
        if characters.filter(\.isNarrator).count != 1 || Set(characters.map(\.id)).count != characters.count
            || characters.contains(where: { $0.bookID != bookID }) {
            issues.append(.init(code: .lockedBindingConflict, nextAction: "请保留一位旁白并修正重复或跨书角色。"))
        }
        // Keep work bounded, including the baseline co-occurrence scoring pass.
        let grouped = Dictionary(grouping: annotations, by: \.chapterID)
        let graphCost = grouped.values.reduce(0) { total, rows in
            let n = Set(rows.compactMap(\.assignment.roleID)).count
            return total + n * n + rows.count * 7
        }
        if Task.isCancelled || characters.count > 2_000 || graphCost > 2_000_000 {
            issues.append(.init(code: .searchBudgetExceeded, nextAction: "推荐已停止；请缩小范围后重试，已有配声保持不变。"))
        }
        let duplicateGroups = Dictionary(grouping: sortedRoles.compactMap { role -> (AudiobookCharacter, AudiobookVoiceBinding)? in
            bindings[role.id].map { (role, $0) }
        }, by: { $0.1.voiceID })
        for group in duplicateGroups.values {
            if group.count > 1 && group.contains(where: { $0.0.isNarrator || !$0.0.allowSharedMinorVoice || $0.0.isMajor }) {
                issues.append(.init(code: .lockedBindingConflict, roleIDs: group.map { $0.0.id }, voiceIDs: [group[0].1.voiceID], nextAction: "请明确调整独占声音，现有绑定不会自动降级为共享。"))
            }
        }
        for role in sortedRoles {
            guard let binding = existingBindings[role.id] else { continue }
            if !eligibleIDs.contains(binding.voiceID) || (try? validateRenderBinding(binding, snapshot: snapshot)) == nil {
                issues.append(.init(code: .voiceIdentityUnknown, roleIDs: [role.id], voiceIDs: [binding.voiceID], nextAction: "请重新确认此角色的声音和制作参数；旧作品已保留。"))
            }
            if role.isNarrator || !role.allowSharedMinorVoice || role.isMajor { policies[role.id]?.sharingPolicy = .exclusive }
        }
        if !issues.contains(where: \.isBlocking) {
            let (_, stats, weights) = computeRoleDialogueStats(characters: characters, annotations: annotations, availableVoiceCount: voices.count)
            let pinnedExclusive = Set(sortedRoles.filter { existingBindings[$0.id] != nil && policies[$0.id]?.sharingPolicy == .exclusive }.compactMap { existingBindings[$0.id]?.voiceID })
            let pinnedShared = Set(sortedRoles.filter { existingBindings[$0.id] != nil && policies[$0.id]?.sharingPolicy != .exclusive }.compactMap { existingBindings[$0.id]?.voiceID })
            let unbound = sortedRoles.filter { existingBindings[$0.id] == nil }
            let hardExclusive = unbound.filter { $0.isNarrator || $0.isMajor }
            let automatic = unbound.filter { !$0.isNarrator && !$0.isMajor }.sorted {
                let l = stats[$0.id]?.dialogueAtomCount ?? 0, r = stats[$1.id]?.dialogueAtomCount ?? 0
                return l == r ? $0.id.uuidString < $1.id.uuidString : l > r
            }
            let remaining = voices.count - pinnedExclusive.count - pinnedShared.count
            let allFit = hardExclusive.count + automatic.count <= remaining
            let sharedTarget = allFit ? pinnedShared.count : max(pinnedShared.count, min(2, voices.count - pinnedExclusive.count - hardExclusive.count))
            let autoExclusiveCount = allFit ? automatic.count : max(0, remaining - hardExclusive.count - max(0, sharedTarget - pinnedShared.count))
            let exclusive = hardExclusive + automatic.prefix(autoExclusiveCount)
            let shared = Array(automatic.dropFirst(autoExclusiveCount))
            let free = voices.filter { !pinnedExclusive.contains($0.id) && !pinnedShared.contains($0.id) }
            var candidates: [UUID: [String]] = [:]
            for role in exclusive {
                let allowed = free
                let best = stats[role.id].flatMap { stat in selectBestVoice(
                    for: role, stat: stat, candidates: allowed, bookID: bookID,
                    preferredCollectionID: catalog.state.preferredCollectionIDByBookID[bookID],
                    voiceMetadataByID: catalog.state.metadataByVoiceID, currentBindings: bindings,
                    conflictWeights: weights, usageCountByVoiceID: [:]
                ) }
                candidates[role.id] = allowed.sorted {
                    if $0.id == best?.id { return true }; if $1.id == best?.id { return false }; return $0.id < $1.id
                }.map(\.id)
            }
            let matchingResult = Result { try maximumExclusiveMatching(roleIDs: exclusive.map(\.id), candidates: candidates) }
            if case let .success(matching) = matchingResult,
               shared.isEmpty || sharedTarget > 0 {
                for role in exclusive {
                    if let voice = voices.first(where: { $0.id == matching[role.id] }) {
                        bindings[role.id] = binding(roleID: role.id, voice: voice, snapshot: snapshot)
                        policies[role.id]?.sharingPolicy = .exclusive
                    }
                }
                let activeIDs = Set(sortedRoles.map(\.id))
                let taken = Set(bindings.filter { activeIDs.contains($0.key) && policies[$0.key]?.sharingPolicy == .exclusive }.values.map(\.voiceID))
                let sharedPool = voices.filter { pinnedShared.contains($0.id) }
                    + voices.filter { !taken.contains($0.id) && !pinnedShared.contains($0.id) }.prefix(max(0, sharedTarget - pinnedShared.count))
                var usage: [String: Int] = [:]
                for role in shared {
                    let allowed = sharedPool
                    if let stat = stats[role.id], let chosen = selectBestVoice(
                        for: role, stat: stat, candidates: allowed, bookID: bookID,
                        preferredCollectionID: catalog.state.preferredCollectionIDByBookID[bookID],
                        voiceMetadataByID: catalog.state.metadataByVoiceID, currentBindings: bindings,
                        conflictWeights: weights, usageCountByVoiceID: usage
                    ) {
                        bindings[role.id] = binding(roleID: role.id, voice: chosen, snapshot: snapshot)
                        policies[role.id]?.sharingPolicy = .sharedMinor
                        usage[chosen.id, default: 0] += 1
                    }
                }
                let newlyShared = shared.filter { bindings[$0.id] != nil }
                if !newlyShared.isEmpty {
                    issues.append(.init(code: .sharedVoiceConsentRequired, roleIDs: newlyShared.map(\.id),
                        voiceIDs: Array(Set(newlyShared.compactMap { bindings[$0.id]?.voiceID })), isBlocking: false,
                        nextAction: "这些角色拟共用声音，请试听并明确接受，或为角色分别选择声音。"))
                }
                for role in sortedRoles {
                    for neighbor in (weights[role.id] ?? [:]).keys.sorted(by: { $0.uuidString < $1.uuidString }) where role.id.uuidString < neighbor.uuidString {
                        if let mine = bindings[role.id], mine.voiceID == bindings[neighbor]?.voiceID {
                            issues.append(.init(code: .sharedSceneRisk, roleIDs: [role.id, neighbor], voiceIDs: [mine.voiceID], isBlocking: false, nextAction: "这些角色在同章使用同一声音，请试听后明确确认，或增加声音。"))
                        }
                    }
                }
            } else {
                let exhausted: Bool
                if case let .failure(error) = matchingResult { exhausted = error is CancellationError || error as? ExclusiveMatchingError == .budgetExceeded }
                else { exhausted = false }
                issues.append(.init(code: exhausted ? .searchBudgetExceeded : .insufficientVoiceCapacity, roleIDs: unbound.map(\.id),
                    nextAction: exhausted ? "推荐预算已耗尽，请缩小范围后重新规划。" : "当前候选不能同时满足旁白、独占与共享要求，请增加声音或明确调整角色政策。"))
            }
        }
        let unresolved = Set(active.filter { bindings[$0.id] == nil }.map(\.id))
        if !unresolved.isEmpty && !issues.contains(where: \.isBlocking) {
            issues.append(.init(code: .insufficientVoiceCapacity, roleIDs: Array(unresolved), nextAction: "部分角色没有合法候选，请调整候选范围。"))
        }
        let narratorVoices = Set(sortedRoles.filter(\.isNarrator).compactMap { bindings[$0.id]?.voiceID })
        let exclusiveVoices = Set(sortedRoles.filter { !$0.isNarrator && policies[$0.id]?.sharingPolicy == .exclusive }.compactMap { bindings[$0.id]?.voiceID })
        let sharedVoices = Set(sortedRoles.filter { policies[$0.id]?.sharingPolicy == .sharedMinor }.compactMap { bindings[$0.id]?.voiceID })
        return AudiobookCastingPlan(
            bookID: bookID, localInputDigest: AudiobookCastingDigest.local(characters: characters, annotations: annotations, bindings: existingBindings),
            snapshot: snapshot, catalog: catalog, expectedCastRevisionID: castRevisionID(bookID: bookID, characters: characters),
            proposedBindings: bindings, proposedPolicies: policies, unresolvedRoleIDs: unresolved,
            affectedRoleIDs: Set(bindings.keys.filter { bindings[$0] != existingBindings[$0] }), affectedFragmentIDs: [],
            narratorVoiceCount: narratorVoices.count, exclusiveVoiceCount: exclusiveVoices.count,
            sharedVoiceCount: sharedVoices.count, eligibleVoiceCount: voices.count, rawIssues: issues
        )
    }

    private static func binding(roleID: UUID, voice: SafeVoiceEntry, snapshot: EffectiveCapabilitySnapshot) -> AudiobookVoiceBinding {
        AudiobookVoiceBinding(roleID: roleID, voiceID: voice.id, voiceRevision: voice.voiceRevision,
            modelRevision: SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: voice.id, in: snapshot)?.expectedModelRevision ?? "")
    }

    /// Augmenting paths reserve constrained roles before a weighted choice can consume their only voice.
    enum ExclusiveMatchingError: Error, Equatable { case infeasible, budgetExceeded }

    static func maximumExclusiveMatching(roleIDs: [UUID], candidates: [UUID: [String]], visitBudget: Int = 100_000) throws -> [UUID: String] {
        var owner: [String: UUID] = [:]
        var visits = 0
        func augment(_ role: UUID, seen: inout Set<String>) throws -> Bool {
            for voice in candidates[role] ?? [] {
                visits += 1
                try Task.checkCancellation()
                if visits > visitBudget { throw ExclusiveMatchingError.budgetExceeded }
                guard seen.insert(voice).inserted else { continue }
                if try owner[voice] == nil || augment(owner[voice]!, seen: &seen) { owner[voice] = role; return true }
            }
            return false
        }
        for role in roleIDs.sorted(by: {
            let l = candidates[$0]?.count ?? 0, r = candidates[$1]?.count ?? 0
            return l == r ? $0.uuidString < $1.uuidString : l < r
        }) {
            var seen: Set<String> = []
            if try !augment(role, seen: &seen) { throw ExclusiveMatchingError.infeasible }
        }
        return Dictionary(uniqueKeysWithValues: owner.map { ($0.value, $0.key) })
    }

    /// Shared by manual, batch and plan commits. Consent must already be explicit on every role.
    static func validateBindingSet(characters: [AudiobookCharacter], bindings: [UUID: AudiobookVoiceBinding], requiredRoleIDs: Set<UUID>? = nil) throws {
        let roles = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
        for id in bindings.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let binding = bindings[id] else { continue }
            guard id == binding.roleID, roles[id] != nil else { throw AudiobookCastError.characterNotFound(id) }
            if requiredRoleIDs?.contains(id) == false { continue }
            guard binding.isSynthesisReady else { throw AudiobookCastError.voiceNotSynthesisReady(voiceID: binding.voiceID) }
            guard binding.allowedSpeed.isFinite, binding.allowedSpeed > 0,
                  binding.callerSeed.map({ (0...4_294_967_295).contains($0) }) ?? true else {
                throw AudiobookCastError.invalidCastingPlan(reason: "unsupported_render_parameter")
            }
        }
        let groups = Dictionary(grouping: bindings.values.filter { requiredRoleIDs?.contains($0.roleID) ?? true }, by: \.voiceID)
        for voiceID in groups.keys.sorted() {
            guard let group = groups[voiceID], group.count > 1 else { continue }
            for binding in group.sorted(by: { $0.roleID.uuidString < $1.roleID.uuidString }) {
                guard let role = roles[binding.roleID], !role.isNarrator, !role.isMajor, role.allowSharedMinorVoice else {
                    throw AudiobookCastError.duplicateVoiceRequiresSharedMinorConsent(voiceID: binding.voiceID, conflictingRoleID: binding.roleID)
                }
            }
        }
    }

    /// Validate the frozen binding against one capability snapshot before each new render.
    public static func validateRenderBinding(
        _ binding: AudiobookVoiceBinding, snapshot: EffectiveCapabilitySnapshot
    ) throws {
        guard let voice = snapshot.voices.first(where: { $0.id == binding.voiceID }),
              voice.available, voice.productionReady == true,
              let options = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: voice.id, in: snapshot)
        else { throw ServiceAPIClientError.invalidContract("voice_not_production_ready") }
        guard options.expectedVoiceRevision == binding.voiceRevision,
              options.expectedModelRevision == binding.modelRevision
        else { throw ServiceAPIClientError.invalidContract("casting_identity_changed") }
        guard binding.modelRevision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              (voice.mode == "system" && binding.voiceRevision == nil)
                || binding.voiceRevision?.range(of: "^vr_[0-9a-f]{32}$", options: .regularExpression) != nil
        else { throw ServiceAPIClientError.invalidContract("voice_identity_unknown") }
        if voice.mode == "clone", binding.callerSeed != nil || binding.allowedSpeed != 1 {
            throw ServiceAPIClientError.invalidContract("voice_parameters_require_reconfirmation")
        }
        guard supportsParameter("speed", value: binding.allowedSpeed, voice: voice) else {
            throw ServiceAPIClientError.invalidContract("unsupported_render_speed")
        }
        if let seed = binding.callerSeed {
            guard (0...4_294_967_295).contains(seed), supportsParameter("seed", value: Double(seed), voice: voice) else {
                throw ServiceAPIClientError.invalidContract("unsupported_caller_seed")
            }
        }
    }

    public static func supportsParameter(_ name: String, value: Double, voice: SafeVoiceEntry) -> Bool {
        guard value.isFinite,
              case let .object(operation) = voice.operations["http_speech"]?.storage,
              case let .object(parameters) = operation["parameters"]?.storage,
              case let .object(parameter) = parameters[name]?.storage,
              parameter["status"]?.stringValue == "supported" else { return false }
        if case let .array(values) = parameter["values"]?.storage {
            return values.contains { $0.doubleValue == value }
        }
        guard let minimum = parameter["minimum"]?.doubleValue,
              let maximum = parameter["maximum"]?.doubleValue else { return false }
        return minimum <= value && value <= maximum
    }

    /// New recommendations use neutral, contract-safe controls until audition accepts a change.
    public static func computeMicroProsodyAndSeed(
        for character: AudiobookCharacter,
        archetype: AudiobookVoiceArchetype,
        voiceMode: String,
        slotIndex: Int
    ) -> (allowedSpeed: Double, callerSeed: Int?) {
        (AudiobookLimits.defaultRenderSpeed, nil)
    }

    /// 辅助方法：解析 SafeVoiceEntry 的声部行当。
    public static func resolveVoiceArchetype(
        for voice: SafeVoiceEntry,
        metadata: VoiceAssetMetadata? = nil
    ) -> AudiobookVoiceArchetype {
        VoiceTaxonomyClassifier.resolveArchetype(
            voiceID: voice.id,
            gender: nil,
            age: nil,
            traits: voice.descriptors.styleTags + voice.aliases,
            description: voice.name,
            label: voice.name,
            metadata: metadata
        )
    }

    private static func selectBestVoice(
        for character: AudiobookCharacter,
        stat: AudiobookRoleDialogueStats,
        candidates: [SafeVoiceEntry],
        bookID: UUID?,
        preferredCollectionID: UUID?,
        voiceMetadataByID: [String: VoiceAssetMetadata],
        currentBindings: [UUID: AudiobookVoiceBinding],
        conflictWeights: [UUID: [UUID: Int]],
        usageCountByVoiceID: [String: Int]
    ) -> SafeVoiceEntry? {
        let profileText = (
            [character.displayName]
                + character.aliases
                + character.evidences.compactMap(\.voiceTraitSummary)
                + character.evidences.map(\.quoteExcerpt)
        ).joined(separator: " ").lowercased()

        let inferredGender = inferGender(from: profileText, isNarrator: character.isNarrator)
        let isMatureOrElder = containsAny(
            in: profileText,
            keywords: ["老", "爷", "叔", "伯", "掌柜", "师父", "长老", "深沉", "低沉", "醇厚", "苍老", "稳重", "中年", "老年"]
        )
        let isBrightOrLively = containsAny(
            in: profileText,
            keywords: ["清亮", "清脆", "活泼", "少女", "明快", "轻快", "少年", "阳光", "笑"]
        )
        let neighbors = conflictWeights[character.id] ?? [:]

        let scored = candidates.map { voice -> (SafeVoiceEntry, Int) in
            var score = 0
            let voiceIDLower = voice.id.lowercased()
            let voiceNameLower = voice.name.lowercased()
            let voiceMeta = ([voiceIDLower, voiceNameLower] + voice.aliases.map { $0.lowercased() } + voice.descriptors.styleTags.map { $0.lowercased() })
                .joined(separator: " ")
            let meta = voiceMetadataByID[voice.id]

            // 1. 专属角色音色与名称呼应加分（AC7）
            if let meta {
                if meta.originRoleID == character.id {
                    score += 500
                } else if let bookID, meta.originBookID == bookID && meta.originRoleID == nil {
                    score += 160
                }
                if let preferredCollectionID, meta.collectionIDs.contains(preferredCollectionID) {
                    score += 120
                }
                if meta.isFavorite {
                    score += 40
                }
            }

            if character.isNarrator {
                if voiceMeta.contains("narrator") || voiceMeta.contains("旁白") {
                    score += 500
                }
                if voiceIDLower == "uncle_fu" {
                    score += 240
                } else if voiceIDLower == "serena" {
                    score += 220
                }
            } else {
                for nameToken in ([character.displayName] + character.aliases) where !nameToken.isEmpty {
                    let lowerToken = nameToken.lowercased()
                    if voiceMeta.contains(lowerToken) {
                        score += 500
                    }
                }
            }

            // 2. 语种亲和度（优先中文音色）
            if voice.descriptors.locales.contains(where: { $0.lowercased().hasPrefix("zh") })
                || ["serena", "vivian", "uncle_fu", "dylan", "eric"].contains(voiceIDLower)
            {
                score += 100
            }

            // 3. 声部行当、性别与年龄特质匹配
            let voiceArchetype = resolveVoiceArchetype(for: voice, metadata: meta)
            if voiceArchetype == stat.archetype {
                score += 220
                if meta?.creationSource == .voiceDesign || voiceIDLower.hasPrefix("ab_") {
                    score += 180
                }
            }

            let voiceGender = inferVoiceGender(voiceID: voiceIDLower, voiceMeta: voiceMeta)
            if inferredGender != .unknown && voiceGender == inferredGender {
                score += 180
            } else if inferredGender != .unknown && voiceGender != .unknown && voiceGender != inferredGender {
                score -= 300
            }

            if inferredGender == .female {
                if isBrightOrLively && (voiceIDLower == "vivian" || voiceMeta.contains("明亮") || voiceMeta.contains("清脆")) {
                    score += 60
                } else if !isBrightOrLively && (voiceIDLower == "serena" || voiceMeta.contains("温柔") || voiceMeta.contains("柔和")) {
                    score += 60
                }
            } else if inferredGender == .male {
                if isMatureOrElder && (voiceIDLower == "uncle_fu" || voiceMeta.contains("醇厚") || voiceMeta.contains("稳重")) {
                    score += 80
                } else if !isMatureOrElder && (voiceIDLower == "dylan" || voiceIDLower == "eric" || voiceMeta.contains("青年") || voiceMeta.contains("活力")) {
                    score += 70
                }
            }

            // 4. 同场/同章对话冲突图着色惩罚（AC3：同场紧邻对手戏立扣 >= 600 分）
            var conflictPenalty = 0
            for (neighborRoleID, weight) in neighbors {
                if let neighborBinding = currentBindings[neighborRoleID],
                   neighborBinding.voiceID == voice.id
                {
                    conflictPenalty += weight
                }
            }
            score -= conflictPenalty

            // 5. 音色互斥加成与负载均衡惩罚
            let usageCount = usageCountByVoiceID[voice.id] ?? 0
            if usageCount == 0 {
                score += 140
            } else {
                score -= usageCount * 35
            }

            return (voice, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.id < rhs.0.id
        }

        return scored.first?.0
    }

    private enum InferredGender {
        case male
        case female
        case unknown
    }

    private static func inferGender(from text: String, isNarrator: Bool) -> InferredGender {
        if isNarrator { return .unknown }
        let femaleHits = countMatches(
            in: text,
            keywords: ["女", "姐", "妹", "娘", "姑", "婆", "妇", "嫂", "她", "小姐", "夫人", "少女", "晴", "雪", "瑶", "琳", "婷", "芳", "清亮女声", "女声"]
        )
        let maleHits = countMatches(
            in: text,
            keywords: ["男", "哥", "弟", "爷", "叔", "伯", "掌柜", "公子", "先生", "少年", "青年", "老汉", "老周", "林远", "男声", "低沉"]
        )
        if femaleHits > maleHits { return .female }
        if maleHits > femaleHits { return .male }
        return .unknown
    }

    private static func inferVoiceGender(voiceID: String, voiceMeta: String) -> InferredGender {
        if ["serena", "vivian", "ono_anna", "sohee"].contains(voiceID)
            || voiceMeta.contains("女")
            || voiceMeta.contains("female")
        {
            return .female
        }
        if ["uncle_fu", "dylan", "eric", "ryan", "aiden"].contains(voiceID)
            || voiceMeta.contains("男")
            || voiceMeta.contains("male")
        {
            return .male
        }
        return .unknown
    }

    private static func containsAny(in text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private static func countMatches(in text: String, keywords: [String]) -> Int {
        keywords.reduce(0) { acc, kw in
            acc + (text.contains(kw) ? 1 : 0)
        }
    }
}
