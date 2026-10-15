import Foundation
import SpeechRailControlKit

/// T05：全书角色归并、候选批次筛选（每批最多 32 个候选）、声线特征保留与智能音色推荐匹配。
public enum AudiobookCastRegistry {
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
        let nonNarrators = characters.filter { !$0.isNarrator }
        let scored = nonNarrators.map { character -> (AudiobookCharacter, Int) in
            var score = 0
            if character.chapterIDs.contains(chapterID) {
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

        let effectiveVoiceCount = max(2, availableVoiceCount)
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
                copy.chapterIDs = Array(Set(copy.chapterIDs).union(chapters))
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

    /// 基于角色称谓、六维声学画像、音色作用域隔离（排除其他书籍专用音色与归档音色）、双池物理隔离、同场对话冲突图着色与微语速/Seed 分化，生成全书配声绑定。
    public static func recommendVoiceBindings(
        characters: [AudiobookCharacter],
        availableVoices: [SafeVoiceEntry],
        existingBindings: [UUID: AudiobookVoiceBinding] = [:],
        annotations: [AudiobookAnnotation] = [],
        bookID: UUID? = nil,
        preferredCollectionID: UUID? = nil,
        voiceMetadataByID: [String: VoiceAssetMetadata] = VoiceCatalogStore.shared.metadataByVoiceID
    ) -> [UUID: AudiobookVoiceBinding] {
        let allReadyVoices = availableVoices.filter { $0.available && $0.productionReady != false }
        guard !allReadyVoices.isEmpty else { return existingBindings }

        let resolvedBookID = bookID ?? characters.first?.bookID
        let resolvedCollectionID = preferredCollectionID
            ?? resolvedBookID.flatMap { VoiceCatalogStore.shared.preferredCollectionID(for: $0) }

        // 步骤 0：音色作用域过滤（剔除其他书籍专用音色与已归档音色，解决 B6）
        let scopedVoices = allReadyVoices.filter { voice in
            guard let meta = voiceMetadataByID[voice.id] else { return true }
            switch meta.scope {
            case .globalReusable:
                return true
            case .bookExclusive:
                guard let resolvedBookID else { return false }
                return meta.originBookID == nil || meta.originBookID == resolvedBookID
            case .archived:
                return false
            }
        }
        let readyVoices = scopedVoices.isEmpty ? allReadyVoices : scopedVoices

        // 步骤 1：计算四级分层与同场对白冲突图
        let (stratifiedCharacters, statsByRoleID, conflictWeights) = computeRoleDialogueStats(
            characters: characters,
            annotations: annotations,
            availableVoiceCount: readyVoices.count
        )

        var result = existingBindings
        var exclusiveUsedVoiceIDs = Set<String>()
        var sharedUsedVoiceIDs = Set<String>()
        var usageCountByVoiceID: [String: Int] = [:]

        for role in stratifiedCharacters {
            if let existing = result[role.id], existing.isSynthesisReady {
                usageCountByVoiceID[existing.voiceID, default: 0] += 1
                if role.isNarrator || !role.allowSharedMinorVoice {
                    exclusiveUsedVoiceIDs.insert(existing.voiceID)
                } else {
                    sharedUsedVoiceIDs.insert(existing.voiceID)
                }
            }
        }

        // 步骤 2：独占池与共享池双池容量规划（确保当存在配角时，配角共享池至少留有可用音色，消除 B2 绑定死锁）
        var unboundExclusive = stratifiedCharacters.filter {
            result[$0.id]?.isSynthesisReady != true && ($0.isNarrator || !$0.allowSharedMinorVoice)
        }
        var unboundShared = stratifiedCharacters.filter {
            result[$0.id]?.isSynthesisReady != true && (!$0.isNarrator && $0.allowSharedMinorVoice)
        }

        if !unboundShared.isEmpty && readyVoices.count >= 2 {
            let minSharedVoices = min(4, max(1, readyVoices.count / 3))
            let maxExclusiveCapacity = max(1, readyVoices.count - exclusiveUsedVoiceIDs.count - minSharedVoices)
            if unboundExclusive.count > maxExclusiveCapacity {
                let overflow = unboundExclusive.suffix(from: maxExclusiveCapacity)
                unboundExclusive = Array(unboundExclusive.prefix(maxExclusiveCapacity))
                for var demoted in overflow {
                    demoted.isMajor = false
                    demoted.allowSharedMinorVoice = true
                    unboundShared.append(demoted)
                }
            }
        }

        // 步骤 3：为旁白与核心主角分配独占音色
        for character in unboundExclusive {
            let stat = statsByRoleID[character.id] ?? AudiobookRoleDialogueStats(
                roleID: character.id,
                tier: character.isNarrator ? .narrator : .lead,
                archetype: character.inferredVoiceArchetype(peers: stratifiedCharacters)
            )
            let unusedVoices = readyVoices.filter {
                !exclusiveUsedVoiceIDs.contains($0.id) && !sharedUsedVoiceIDs.contains($0.id)
            }
            let nonExclusiveVoices = readyVoices.filter { !exclusiveUsedVoiceIDs.contains($0.id) }
            let candidatePool = !unusedVoices.isEmpty
                ? unusedVoices
                : (!nonExclusiveVoices.isEmpty ? nonExclusiveVoices : readyVoices)

            guard let chosen = selectBestVoice(
                for: character,
                stat: stat,
                candidates: candidatePool,
                bookID: resolvedBookID,
                preferredCollectionID: resolvedCollectionID,
                voiceMetadataByID: voiceMetadataByID,
                currentBindings: result,
                conflictWeights: conflictWeights,
                usageCountByVoiceID: usageCountByVoiceID
            ) else { continue }

            let modelRev = chosen.model.catalogRevision
                ?? chosen.model.runtimeRevision
                ?? "qwen3-tts-v1"
            let binding = AudiobookVoiceBinding(
                roleID: character.id,
                voiceID: chosen.id,
                voiceRevision: chosen.voiceRevision ?? "v1",
                modelRevision: modelRev,
                isSynthesisReady: true,
                allowedSpeed: AudiobookLimits.defaultRenderSpeed,
                callerSeed: nil
            )
            result[character.id] = binding
            exclusiveUsedVoiceIDs.insert(chosen.id)
            usageCountByVoiceID[chosen.id, default: 0] += 1
        }

        // 步骤 4：构建配角共享池（严格剔除 exclusiveUsedVoiceIDs）并执行 Welsh-Powell 同场防撞色图着色
        let nonExclusivePool = readyVoices.filter { !exclusiveUsedVoiceIDs.contains($0.id) }
        let sharedPool = nonExclusivePool.isEmpty ? readyVoices : nonExclusivePool

        let orderedShared = unboundShared.sorted { lhs, rhs in
            let statL = statsByRoleID[lhs.id] ?? AudiobookRoleDialogueStats(roleID: lhs.id)
            let statR = statsByRoleID[rhs.id] ?? AudiobookRoleDialogueStats(roleID: rhs.id)
            let speaksL = statL.dialogueAtomCount > 0
            let speaksR = statR.dialogueAtomCount > 0
            if speaksL != speaksR { return speaksL && !speaksR }
            if statL.scenePartnerRoleIDs.count != statR.scenePartnerRoleIDs.count {
                return statL.scenePartnerRoleIDs.count > statR.scenePartnerRoleIDs.count
            }
            if statL.dialogueAtomCount != statR.dialogueAtomCount {
                return statL.dialogueAtomCount > statR.dialogueAtomCount
            }
            return lhs.displayName < rhs.displayName
        }

        var sharedSlotIndexByVoiceID: [String: Int] = [:]
        for role in stratifiedCharacters where !role.isNarrator && role.allowSharedMinorVoice {
            if let existing = existingBindings[role.id], existing.isSynthesisReady {
                sharedSlotIndexByVoiceID[existing.voiceID, default: 0] += 1
            }
        }

        for character in orderedShared {
            let stat = statsByRoleID[character.id] ?? AudiobookRoleDialogueStats(
                roleID: character.id,
                tier: .supporting,
                archetype: character.inferredVoiceArchetype(peers: stratifiedCharacters)
            )
            guard let chosen = selectBestVoice(
                for: character,
                stat: stat,
                candidates: sharedPool,
                bookID: resolvedBookID,
                preferredCollectionID: resolvedCollectionID,
                voiceMetadataByID: voiceMetadataByID,
                currentBindings: result,
                conflictWeights: conflictWeights,
                usageCountByVoiceID: usageCountByVoiceID
            ) else { continue }

            let slotIndex = sharedSlotIndexByVoiceID[chosen.id, default: 0]
            sharedSlotIndexByVoiceID[chosen.id] = slotIndex + 1

            let (microSpeed, seed) = computeMicroProsodyAndSeed(
                for: character,
                archetype: stat.archetype,
                voiceMode: chosen.mode,
                slotIndex: slotIndex
            )

            let modelRev = chosen.model.catalogRevision
                ?? chosen.model.runtimeRevision
                ?? "qwen3-tts-v1"
            let binding = AudiobookVoiceBinding(
                roleID: character.id,
                voiceID: chosen.id,
                voiceRevision: chosen.voiceRevision ?? "v1",
                modelRevision: modelRev,
                isSynthesisReady: true,
                allowedSpeed: microSpeed,
                callerSeed: seed
            )
            result[character.id] = binding
            sharedUsedVoiceIDs.insert(chosen.id)
            usageCountByVoiceID[chosen.id, default: 0] += 1
        }

        return result
    }

    /// 模式感知微韵律与确定性种子错位算法（算法 D）：
    /// - system / preset 音色：按角色声部与槽位分配 0.92x ~ 1.08x 微语速错位；
    /// - clone / instruction 音色：严格锁定 speed = 1.0，分配确定性种子 [101, 202, 303, 404]。
    public static func computeMicroProsodyAndSeed(
        for character: AudiobookCharacter,
        archetype: AudiobookVoiceArchetype,
        voiceMode: String,
        slotIndex: Int
    ) -> (allowedSpeed: Double, callerSeed: Int?) {
        let lowerMode = voiceMode.lowercased()
        if lowerMode == "clone" || lowerMode == "instruction" {
            let seeds = [101, 202, 303, 404]
            return (AudiobookLimits.defaultRenderSpeed, seeds[max(0, slotIndex) % seeds.count])
        }

        let persona = character.resolvedVoicePersona()
        let combined = "\(persona.ageGenderAnchor) \(persona.pacingAndDiction) \(character.primaryVoiceTraitSummary ?? "")".lowercased()

        if combined.contains("老") || combined.contains("舒缓") || combined.contains("沉着") || archetype == .matureMale || archetype == .matureFemale {
            let speeds = [1.00, 0.94, 0.97, 0.92, 1.03]
            return (speeds[max(0, slotIndex) % speeds.count], nil)
        }
        if combined.contains("少年") || combined.contains("少女") || combined.contains("干脆") || combined.contains("利落") || combined.contains("急促") {
            let speeds = [1.00, 1.05, 0.97, 1.08, 1.03]
            return (speeds[max(0, slotIndex) % speeds.count], nil)
        }
        let speeds = [1.00, 0.96, 1.04, 0.93, 1.06]
        return (speeds[max(0, slotIndex) % speeds.count], nil)
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
            metadata: metadata ?? VoiceCatalogStore.shared.metadata(for: voice.id)
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
