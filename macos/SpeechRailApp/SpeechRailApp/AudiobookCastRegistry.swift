import Foundation
import SpeechRailControlKit

/// T05：全书角色归并、候选批次筛选（每批最多 32 个候选）、声线特征保留与智能音色推荐匹配。
public enum AudiobookCastRegistry {
    static func castRevisionID(bookID: UUID, characters: [AudiobookCharacter]) -> UUID {
        let sorted = characters.sorted { $0.id.uuidString < $1.id.uuidString }
        let raw = sorted.map { "\($0.id.uuidString):\($0.isNarrator):\($0.allowSharedMinorVoice):\(AudiobookCastingDigest.hash($0.voicePolicy))" }
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
        characters: [AudiobookCharacter], annotations: [AudiobookAnnotation], availableVoiceCount: Int = 8,
        source: AudiobookSourceIndex? = nil, atoms: [AudiobookTextAtom] = [], scenes: [AudiobookCastingScene] = []
    ) -> (updatedCharacters: [AudiobookCharacter], statsByRoleID: [UUID: AudiobookRoleDialogueStats], conflictWeights: [UUID: [UUID: Int]]) {
        let graph = AudiobookSceneConflictGraph.build(characters: characters, annotations: annotations, atoms: atoms, scenes: scenes)
        var counts: [UUID: Int] = [:], scalars: [UUID: Int] = [:], chapters: [UUID: Set<UUID>] = [:]
        let unique = Dictionary(grouping: annotations, by: { "\($0.chapterID)|\($0.sourceRange.lowerBound)|\($0.sourceRange.upperBound)|\($0.assignment.roleID?.uuidString ?? "unknown")" }).values.compactMap(\.first)
        for annotation in unique {
            guard let role = annotation.assignment.roleID else { continue }
            counts[role, default: 0] += 1
            chapters[role, default: []].insert(annotation.chapterID)
        }
        // Union source intervals before counting; repeated windows and overlapping retries cannot inflate text volume.
        for role in characters {
            let ranges = unique.filter { $0.assignment.roleID == role.id }.map(\.sourceRange).sorted()
            var merged: [AudiobookSourceRange] = []
            for range in ranges {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = .init(lowerBound: last.lowerBound, upperBound: max(last.upperBound, range.upperBound))
                } else { merged.append(range) }
            }
            if let source { scalars[role.id] = merged.reduce(0) { $0 + ((try? source.text(in: $1).unicodeScalars.count) ?? 0) } }
        }
        func volume(_ id: UUID) -> Int { source == nil ? (counts[id] ?? 0) : (scalars[id] ?? 0) }
        let ranked = characters.filter { !$0.isNarrator && volume($0.id) > 0 }.sorted {
            volume($0.id) == volume($1.id) ? $0.id.uuidString < $1.id.uuidString : volume($0.id) > volume($1.id)
        }
        let total = ranked.reduce(0) { $0 + volume($1.id) }
        var front = 0, leads: Set<UUID> = []
        for role in ranked where front < Int(ceil(Double(total) * 0.75)) {
            leads.insert(role.id); front += volume(role.id)
        }
        var stats: [UUID: AudiobookRoleDialogueStats] = [:]
        for role in characters {
            let inferred: AudiobookRoleTier = role.isNarrator ? .narrator : (leads.contains(role.id) ? .lead : ((chapters[role.id]?.count ?? 0) > 1 ? .supporting : .ensemble))
            var item = AudiobookRoleDialogueStats(roleID: role.id, dialogueAtomCount: counts[role.id] ?? 0,
                speakingChapterIDs: chapters[role.id] ?? [], tier: role.manualTier ?? inferred,
                archetype: role.inferredVoiceArchetype(peers: characters))
            item.dialogueScalarCount = scalars[role.id] ?? 0
            item.statisticsRevision = source == nil ? "dialogue-stats-v2:source-unavailable" : "dialogue-stats-v2:unicode-scalars"
            for edge in graph.edges where edge.roleA == role.id || edge.roleB == role.id {
                let other = edge.roleA == role.id ? edge.roleB : edge.roleA
                if edge.kind == .directDialogue { item.scenePartnerRoleIDs.insert(other) }
                if edge.kind == .chapterCoPresence { item.sameChapterRoleIDs.insert(other) }
            }
            stats[role.id] = item
        }
        return (characters, stats, graph.weights)
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
        existingBindings: [UUID: AudiobookVoiceBinding],
        strategy: AudiobookCastingStrategy = .sceneAware
    ) -> AudiobookCastingPlan {
        makeCastingPlan(characters: characters, annotations: annotations, snapshot: snapshot,
            catalog: catalog, bookID: bookID, existingBindings: existingBindings, requiredRoleIDs: nil, strategy: strategy)
    }

    /// Store may narrow the required set only after checking complete source annotations.
    static func makeCastingPlan(
        characters: [AudiobookCharacter], annotations: [AudiobookAnnotation], snapshot: EffectiveCapabilitySnapshot,
        catalog: VoiceCatalogSnapshot, bookID: UUID, existingBindings: [UUID: AudiobookVoiceBinding], requiredRoleIDs: Set<UUID>?,
        source: AudiobookSourceIndex? = nil, atoms: [AudiobookTextAtom] = [], strategy: AudiobookCastingStrategy = .sceneAware, cachedScores: AudiobookCastingScoreCache = .init()
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
            policies[role.id] = role.voicePolicy ?? .init(
                sharingPolicy: role.isNarrator || role.isMajor || (existingBindings[role.id] != nil && !role.allowSharedMinorVoice) ? .exclusive : (existingBindings[role.id] != nil && role.allowSharedMinorVoice ? .sharedMinor : .automatic),
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
                        || (catalog.state.metadataByVoiceID[id]?.visibilityScope == .bookExclusive && catalog.state.metadataByVoiceID[id]?.originBookID == nil)
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
        let scoreMatrixExceedsBudget = !voices.isEmpty && sortedRoles.count > 100_000 / voices.count
        if Task.isCancelled || characters.count > 2_000 || graphCost > 2_000_000 || scoreMatrixExceedsBudget {
            issues.append(.init(code: .searchBudgetExceeded, nextAction: "推荐已停止；请缩小范围后重试，已有配声保持不变。"))
        }
        let duplicateGroups = Dictionary(grouping: sortedRoles.compactMap { role -> (AudiobookCharacter, AudiobookVoiceBinding)? in
            bindings[role.id].map { (role, $0) }
        }, by: { $0.1.voiceID })
        for group in duplicateGroups.values {
            if group.count > 1 && group.contains(where: { policies[$0.0.id]?.sharingPolicy != .sharedMinor }) {
                issues.append(.init(code: .lockedBindingConflict, roleIDs: group.map { $0.0.id }, voiceIDs: [group[0].1.voiceID], nextAction: "请明确调整独占声音，现有绑定不会自动降级为共享。"))
            }
        }
        for role in sortedRoles {
            guard let binding = existingBindings[role.id] else { continue }
            if !eligibleIDs.contains(binding.voiceID) || (try? validateRenderBinding(binding, snapshot: snapshot)) == nil {
                issues.append(.init(code: .voiceIdentityUnknown, roleIDs: [role.id], voiceIDs: [binding.voiceID], nextAction: "请重新确认此角色的声音和制作参数；旧作品已保留。"))
            }
            if role.isNarrator { policies[role.id]?.sharingPolicy = .exclusive }
        }
        var cache = cachedScores
        let initialScoreCount = cache.evaluationCount
        var scored: [UUID: [String: Int]] = [:]
        var evaluations = 0
        if !issues.contains(where: \.isBlocking) {
            let (_, stats, _) = computeRoleDialogueStats(characters: characters, annotations: annotations, availableVoiceCount: voices.count, source: source, atoms: atoms)
            let graph = AudiobookSceneConflictGraph.build(characters: characters, annotations: annotations, atoms: atoms)
            let weights = graph.weights
            let voiceRevisions = Dictionary(uniqueKeysWithValues: voices.map { voice in
                (voice.id, AudiobookCastingDigest.hash([AudiobookCastingDigest.hash(voice), AudiobookCastingDigest.hash(catalog.state.metadataByVoiceID[voice.id]), catalog.state.preferredCollectionIDByBookID[bookID]?.uuidString ?? ""]))
            })
            let voiceProfiles = Dictionary(uniqueKeysWithValues: voices.map { ($0.id, VoiceTaxonomyClassifier.resolveTraits(for: $0, metadata: catalog.state.metadataByVoiceID[$0.id])) })
            scoring: for role in sortedRoles {
                let desired = VoiceTaxonomyClassifier.resolveTraits(description: role.primaryVoiceTraitSummary ?? "", override: role.voiceTraitsOverride)
                let roleRevision = AudiobookCastingDigest.hash([role.primaryVoiceTraitSummary ?? "", role.displayName, AudiobookCastingDigest.hash(role.voiceTraitsOverride)])
                for voice in voices {
                    if Task.isCancelled {
                        issues.append(.init(code: .searchBudgetExceeded, nextAction: "推荐已取消，已有配声保持不变。"))
                        break scoring
                    }
                    let meta = catalog.state.metadataByVoiceID[voice.id]
                    scored[role.id, default: [:]][voice.id] = cache.score(role: role.id, voice: voice.id, roleRevision: roleRevision, voiceRevision: voiceRevisions[voice.id]!) {
                        preferenceScore(role: role, voice: voice, metadata: meta, preferredCollectionID: catalog.state.preferredCollectionIDByBookID[bookID], desiredTraits: desired, actualTraits: voiceProfiles[voice.id])
                    }
                }
            }
            let pinnedExclusive = Set(sortedRoles.filter { existingBindings[$0.id] != nil && policies[$0.id]?.sharingPolicy == .exclusive }.compactMap { existingBindings[$0.id]?.voiceID })
            let pinnedShared = Set(sortedRoles.filter { existingBindings[$0.id] != nil && policies[$0.id]?.sharingPolicy != .exclusive }.compactMap { existingBindings[$0.id]?.voiceID })
            let unbound = sortedRoles.filter { existingBindings[$0.id] == nil }
            let hardExclusive = unbound.filter { policies[$0.id]?.sharingPolicy == .exclusive }
            let automatic = unbound.filter { policies[$0.id]?.sharingPolicy != .exclusive }.sorted {
                let l = stats[$0.id]?.dialogueScalarCount ?? 0, r = stats[$1.id]?.dialogueScalarCount ?? 0
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
                let allowed = free.filter { matchesRequiredTraits(role: role, voice: $0, metadata: catalog.state.metadataByVoiceID[$0.id]) }
                candidates[role.id] = allowed.sorted {
                    let l = scored[role.id]?[$0.id] ?? 0, r = scored[role.id]?[$1.id] ?? 0
                    return l == r ? $0.id < $1.id : l > r
                }.map(\.id)
            }
            let matchingResult = Result { try maximumWeightExclusiveMatching(roleIDs: exclusive.map(\.id), candidates: candidates, scores: scored) }
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
                let sharedIDs = shared.map(\.id)
                let frozen = Dictionary(uniqueKeysWithValues: bindings.filter { activeIDs.contains($0.key) }.map { ($0.key, $0.value.voiceID) })
                do {
                    let outcome = try AudiobookCastingPlanner.assign(roleIDs: sharedIDs,
                        candidates: Dictionary(uniqueKeysWithValues: shared.map { role in (role.id, sharedPool.filter { matchesRequiredTraits(role: role, voice: $0, metadata: catalog.state.metadataByVoiceID[$0.id]) }.map(\.id)) }), graph: graph,
                        frozen: frozen, strategy: strategy, scores: scored,
                        volumes: stats.mapValues { max(1, $0.dialogueScalarCount) })
                    evaluations = outcome.evaluatedCandidates
                    if outcome.status == .budgetExceeded {
                        issues.append(.init(code: .searchBudgetExceeded, nextAction: "场景推荐预算已耗尽，请缩小范围或切回基础推荐。"))
                    }
                    for role in shared {
                        if let voice = sharedPool.first(where: { $0.id == outcome.assignments[role.id] }) {
                            bindings[role.id] = binding(roleID: role.id, voice: voice, snapshot: snapshot)
                            policies[role.id]?.sharingPolicy = .sharedMinor
                        }
                    }
                } catch {
                    issues.append(.init(code: .searchBudgetExceeded, nextAction: "推荐已取消，已有配声保持不变。"))
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
        for id in bindings.keys where existingBindings[id] == nil {
            policies[id]?.bindingOrigin = .acceptedRecommendation
            policies[id]?.isLocked = true
        }
        var plan = AudiobookCastingPlan(
            bookID: bookID, localInputDigest: AudiobookCastingDigest.local(characters: characters, annotations: annotations, bindings: existingBindings),
            snapshot: snapshot, catalog: catalog, expectedCastRevisionID: castRevisionID(bookID: bookID, characters: characters),
            proposedBindings: bindings, proposedPolicies: policies, unresolvedRoleIDs: unresolved,
            affectedRoleIDs: Set(bindings.keys.filter { bindings[$0] != existingBindings[$0] }), affectedFragmentIDs: [],
            narratorVoiceCount: narratorVoices.count, exclusiveVoiceCount: exclusiveVoices.count,
            sharedVoiceCount: sharedVoices.count, eligibleVoiceCount: voices.count, rawIssues: issues
        )
        plan.strategy = strategy; plan.evaluatedCandidates = evaluations
        plan.hasUnavoidableSceneConflicts = issues.contains(where: { $0.code == .sharedSceneRisk })
        plan.scoredCombinations = cache.evaluationCount - initialScoreCount; plan.cachedScores = cache
        return plan
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
            // Prefer a free slot before displacing a whole alternating path.
            for voice in candidates[role] ?? [] {
                visits += 1
                try Task.checkCancellation()
                if visits > visitBudget { throw ExclusiveMatchingError.budgetExceeded }
                if !seen.contains(voice), owner[voice] == nil { seen.insert(voice); owner[voice] = role; return true }
            }
            for voice in candidates[role] ?? [] {
                visits += 1
                try Task.checkCancellation()
                if visits > visitBudget { throw ExclusiveMatchingError.budgetExceeded }
                guard seen.insert(voice).inserted else { continue }
                if let prior = owner[voice], try augment(prior, seen: &seen) { owner[voice] = role; return true }
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

    static func maximumWeightExclusiveMatching(roleIDs: [UUID], candidates: [UUID: [String]], scores: [UUID: [String: Int]], workBudget: Int = 20_000_000) throws -> [UUID: String] {
        _ = try maximumExclusiveMatching(roleIDs: roleIDs, candidates: candidates)
        let roles = roleIDs.sorted { $0.uuidString < $1.uuidString }
        let voices = Set(candidates.values.flatMap { $0 }).sorted()
        guard !roles.isEmpty else { return [:] }
        let n = roles.count, m = voices.count, infinity = 1_000_000_000
        let limit = max(0, min(20_000_000, workBudget))
        var work = 0
        func consumeWork() throws {
            try Task.checkCancellation()
            guard work < limit else { throw ExclusiveMatchingError.budgetExceeded }
            work += 1
        }
        let allowed = candidates.mapValues(Set.init)
        guard m == 0 || n <= 100_000 / m else { throw ExclusiveMatchingError.budgetExceeded }
        let costs = try roles.map { role in try voices.map { voice in
            try consumeWork()
            return allowed[role]?.contains(voice) == true ? -(scores[role]?[voice] ?? 0) : infinity / 2
        } }
        var u = [Int](repeating: 0, count: n + 1), v = [Int](repeating: 0, count: m + 1)
        var owner = [Int](repeating: 0, count: m + 1), way = owner
        for i in 1...n {
            try Task.checkCancellation()
            owner[0] = i
            var column = 0, minimum = [Int](repeating: infinity, count: m + 1), used = [Bool](repeating: false, count: m + 1)
            repeat {
                used[column] = true
                let row = owner[column]
                var delta = infinity, next = 0
                for j in 1...m where !used[j] {
                    try consumeWork()
                    let cost = costs[row - 1][j - 1]
                    let reduced = cost - u[row] - v[j]
                    if reduced < minimum[j] { minimum[j] = reduced; way[j] = column }
                    if minimum[j] < delta { delta = minimum[j]; next = j }
                }
                for j in 0...m {
                    try consumeWork()
                    if used[j] { u[owner[j]] += delta; v[j] -= delta } else { minimum[j] -= delta }
                }
                column = next
            } while owner[column] != 0
            repeat { let previous = way[column]; owner[column] = owner[previous]; column = previous } while column != 0
        }
        var result: [UUID: String] = [:]
        for j in 1...m where owner[j] > 0 {
            let role = roles[owner[j] - 1], voice = voices[j - 1]
            guard allowed[role]?.contains(voice) == true else { throw ExclusiveMatchingError.infeasible }
            result[role] = voice
        }
        return result
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
                guard let role = roles[binding.roleID], !role.isNarrator,
                      role.voicePolicy.map({ $0.sharingPolicy == .sharedMinor }) ?? (!role.isMajor && role.allowSharedMinorVoice) else {
                    throw AudiobookCastError.duplicateVoiceRequiresSharedMinorConsent(voiceID: binding.voiceID, conflictingRoleID: binding.roleID)
                }
            }
        }
    }

    /// Validate the frozen binding against one capability snapshot before each new render.
    public static func validateRenderBinding(
        _ binding: AudiobookVoiceBinding, snapshot: EffectiveCapabilitySnapshot
    ) throws {
        try validateRenderBinding(binding, snapshot: snapshot, requireProductionReady: true)
    }

    static func validateRenderBinding(
        _ binding: AudiobookVoiceBinding, snapshot: EffectiveCapabilitySnapshot, requireProductionReady: Bool
    ) throws {
        guard let voice = snapshot.voices.first(where: { $0.id == binding.voiceID }),
              voice.available, !requireProductionReady || voice.productionReady == true,
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

    static func matchesRequiredTraits(role: AudiobookCharacter, voice: SafeVoiceEntry, metadata: VoiceAssetMetadata?) -> Bool {
        guard let required = role.requiredVoiceTraits else { return true }
        let actual = VoiceTaxonomyClassifier.resolveTraits(for: voice, metadata: metadata)
        return [(required.gender, actual.gender), (required.age, actual.age), (required.pitch, actual.pitch), (required.texture, actual.texture), (required.locale, actual.locale), (required.pacing, actual.pacing)]
            .allSatisfy { expected, observed in expected.value == "unknown" || expected.value == observed.value }
    }

    static func preferenceScore(role: AudiobookCharacter, voice: SafeVoiceEntry, metadata: VoiceAssetMetadata?, preferredCollectionID: UUID?, desiredTraits: AudiobookVoiceTraits? = nil, actualTraits: AudiobookVoiceTraits? = nil) -> Int {
        let desired = desiredTraits ?? VoiceTaxonomyClassifier.resolveTraits(description: role.primaryVoiceTraitSummary ?? "", override: role.voiceTraitsOverride)
        let actual = actualTraits ?? VoiceTaxonomyClassifier.resolveTraits(for: voice, metadata: metadata)
        var score = 0
        for (left, right) in [(desired.gender, actual.gender), (desired.age, actual.age), (desired.pitch, actual.pitch), (desired.texture, actual.texture), (desired.locale, actual.locale), (desired.pacing, actual.pacing)] {
            if left.value != "unknown" && right.value != "unknown" { score += left.value == right.value ? 80 : -80 }
        }
        if metadata?.originRoleID == role.id { score += 500 }
        if let preferredCollectionID, metadata?.collectionIDs.contains(preferredCollectionID) == true { score += 120 }
        if metadata?.isFavorite == true { score += 40 }
        if role.isNarrator && (voice.name.contains("旁白") || voice.name.lowercased().contains("narrator")) { score += 500 }
        return score
    }

}


/// Edge types retain independent provenance; weak repetition never upgrades a relation.
public struct AudiobookSceneConflictGraph: Equatable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case directDialogue, sceneCoPresence, chapterCoPresence }
    public struct Edge: Equatable, Sendable {
        public let roleA: UUID
        public let roleB: UUID
        public let kind: Kind
        public var sourceIDs: Set<String>
        public init(roleA: UUID, roleB: UUID, kind: Kind, sourceIDs: Set<String>) {
            let sorted = [roleA, roleB].sorted { $0.uuidString < $1.uuidString }
            self.roleA = sorted[0]; self.roleB = sorted[1]; self.kind = kind; self.sourceIDs = sourceIDs
        }
    }
    public let edges: [Edge]
    public init(edges: [Edge]) {
        var merged: [String: Edge] = [:]
        for edge in edges where edge.roleA != edge.roleB {
            let key = "\(edge.roleA)|\(edge.roleB)|\(edge.kind.rawValue)"
            if var old = merged[key] { old.sourceIDs.formUnion(edge.sourceIDs); merged[key] = old }
            else { merged[key] = edge }
        }
        self.edges = merged.keys.sorted().compactMap { merged[$0] }
    }
    public var weights: [UUID: [UUID: Int]] {
        var result: [UUID: [UUID: Int]] = [:]
        for edge in edges {
            let base = edge.kind == .directDialogue ? 600 : (edge.kind == .sceneCoPresence ? 120 : 30)
            let weight = base * min(3, edge.sourceIDs.count)
            result[edge.roleA, default: [:]][edge.roleB, default: 0] += weight
            result[edge.roleB, default: [:]][edge.roleA, default: 0] += weight
        }
        return result
    }
    public static func build(characters: [AudiobookCharacter], annotations: [AudiobookAnnotation], atoms: [AudiobookTextAtom] = [], scenes: [AudiobookCastingScene] = []) -> Self {
        let narrator = Set(characters.filter(\.isNarrator).map(\.id))
        let valid = Set(characters.map(\.id))
        let unique = Dictionary(grouping: annotations, by: { "\($0.chapterID)|\($0.sourceRange.lowerBound)|\($0.sourceRange.upperBound)|\($0.assignment.roleID?.uuidString ?? "unknown")" }).values.compactMap(\.first)
        var edges: [Edge] = []
        for (chapter, rows) in Dictionary(grouping: unique, by: \.chapterID) {
            let ordered = rows.sorted { $0.sourceRange < $1.sourceRange }
            let chapterRoles = Set(ordered.compactMap(\.assignment.roleID)).subtracting(narrator).intersection(valid).sorted { $0.uuidString < $1.uuidString }
            for (index, role) in chapterRoles.enumerated() {
                for other in chapterRoles.dropFirst(index + 1) {
                    edges.append(.init(roleA: role, roleB: other, kind: .chapterCoPresence, sourceIDs: ["chapter-v1|\(chapter)"]))
                }
            }
            let confirmed = scenes.filter { $0.chapterID == chapter && $0.isConfirmed }
            func sceneKey(_ annotation: AudiobookAnnotation) -> String? {
                let matches = confirmed.filter { $0.sourceRange.lowerBound <= annotation.sourceRange.lowerBound && $0.sourceRange.upperBound >= annotation.sourceRange.upperBound }
                guard matches.count == 1, let scene = matches.first else { return nil }
                return "scene-v1|\(chapter)|\(scene.sourceRange.lowerBound)|\(scene.sourceRange.upperBound)"
            }
            let chapterAtoms = atoms.filter { $0.chapterID == chapter }.sorted { $0.sourceRange < $1.sourceRange }
            func position(_ annotation: AudiobookAnnotation, fallback: Int) -> Int {
                chapterAtoms.firstIndex { $0.sourceRange.lowerBound <= annotation.sourceRange.lowerBound && $0.sourceRange.upperBound > annotation.sourceRange.lowerBound } ?? fallback
            }
            var previous: (AudiobookAnnotation, Int)?
            for (index, row) in ordered.enumerated() {
                guard let role = row.assignment.roleID, valid.contains(role), !narrator.contains(role) else { continue }
                let pos = position(row, fallback: index)
                if let (prior, priorPosition) = previous, let other = prior.assignment.roleID, role != other {
                    let leftScene = sceneKey(prior), rightScene = sceneKey(row)
                    let sameScene = !confirmed.isEmpty ? (leftScene != nil && leftScene == rightScene) : pos - priorPosition <= 6
                    if sameScene {
                        let source = "direct-v2|\(chapter)|\(prior.sourceRange.lowerBound)-\(prior.sourceRange.upperBound)|\(row.sourceRange.lowerBound)-\(row.sourceRange.upperBound)"
                        edges.append(.init(roleA: role, roleB: other, kind: .directDialogue, sourceIDs: [source]))
                        edges.append(.init(roleA: role, roleB: other, kind: .sceneCoPresence, sourceIDs: [leftScene ?? "inferred-window-v2|\(source)"]))
                    }
                }
                previous = (row, pos)
            }
            for scene in confirmed {
                let roles = Set(ordered.filter { $0.sourceRange.lowerBound >= scene.sourceRange.lowerBound && $0.sourceRange.upperBound <= scene.sourceRange.upperBound }.compactMap(\.assignment.roleID)).subtracting(narrator).intersection(valid).sorted { $0.uuidString < $1.uuidString }
                for (i, role) in roles.enumerated() {
                    for other in roles.dropFirst(i + 1) {
                        edges.append(.init(roleA: role, roleB: other, kind: .sceneCoPresence, sourceIDs: ["confirmed-scene-v1|\(chapter)|\(scene.sourceRange.lowerBound)|\(scene.sourceRange.upperBound)"]))
                    }
                }
            }
        }
        return .init(edges: edges)
    }
}

public enum AudiobookCastingStrategy: String, Codable, Sendable { case baseline, sceneAware }
public enum AudiobookCastingPlanner {
    public enum Status: String, Sendable { case solved, residualConflicts, provenInsufficient, budgetExceeded }
    public struct Outcome: Equatable, Sendable {
        public let assignments: [UUID: String]
        public let residualDirectPairs: [AudiobookSceneConflictGraph.Edge]
        public let status: Status
        public let evaluatedCandidates: Int
    }
    /// Bounded list coloring; frozen choices are never touched by greedy or repair passes.
    public static func assign(roleIDs: [UUID], candidates: [UUID: [String]], graph: AudiobookSceneConflictGraph,
        frozen: [UUID: String] = [:], strategy: AudiobookCastingStrategy = .sceneAware, budget: Int = 100_000,
        scores: [UUID: [String: Int]] = [:], volumes: [UUID: Int] = [:]) throws -> Outcome {
        let roles = Set(roleIDs).sorted { $0.uuidString < $1.uuidString }
        var choices: [UUID: [String]] = [:]
        for role in roles { choices[role] = Array(Set(candidates[role] ?? [])).sorted() }
        guard frozen.allSatisfy({ !roles.contains($0.key) || choices[$0.key]?.contains($0.value) == true }) else {
            throw AudiobookCastError.invalidCastingPlan(reason: "locked_binding_outside_candidates")
        }
        let limit = max(0, min(100_000, budget))
        var evaluated = 0, exhausted = false
        let direct = graph.edges.filter { $0.kind == .directDialogue }
        let weights = graph.weights
        func conflicts(_ map: [UUID: String]) -> [AudiobookSceneConflictGraph.Edge] {
            direct.filter { edge in map[edge.roleA] != nil && map[edge.roleA] == map[edge.roleB] }
        }
        func next(_ map: [UUID: String]) -> UUID? {
            roles.filter { map[$0] == nil }.sorted { a, b in
                let countA = choices[a]?.count ?? 0, countB = choices[b]?.count ?? 0
                if countA != countB { return countA < countB }
                if strategy == .sceneAware {
                    func saturation(_ role: UUID) -> Int { Set((weights[role] ?? [:]).keys.compactMap { map[$0] }).count }
                    let sa = saturation(a), sb = saturation(b)
                    if sa != sb { return sa > sb }
                    let wa = (weights[a] ?? [:]).values.reduce(0, +), wb = (weights[b] ?? [:]).values.reduce(0, +)
                    if wa != wb { return wa > wb }
                }
                if volumes[a, default: 0] != volumes[b, default: 0] { return volumes[a, default: 0] > volumes[b, default: 0] }
                return a.uuidString < b.uuidString
            }.first
        }
        func cost(_ role: UUID, _ voice: String, _ map: [UUID: String]) -> (Int, Int, Int, Int) {
            let strong = direct.filter { ($0.roleA == role && map[$0.roleB] == voice) || ($0.roleB == role && map[$0.roleA] == voice) }.count
            let weak = (weights[role] ?? [:]).filter { map[$0.key] == voice }.values.reduce(0, +)
            let load = map.filter { $0.value == voice }.keys.reduce(0) { $0 + max(1, volumes[$1, default: 1]) }
            return (strong, weak, -(scores[role]?[voice] ?? 0), load)
        }
        func ordered(_ role: UUID, _ map: [UUID: String]) -> [String] {
            var ranked: [(String, (Int, Int, Int, Int))] = []
            for voice in choices[role] ?? [] {
                guard evaluated < limit else { exhausted = true; break }
                evaluated += 1
                ranked.append((voice, cost(role, voice, map)))
            }
            return ranked.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.0)
        }
        var greedy = frozen
        while let role = next(greedy) {
            try Task.checkCancellation()
            guard let voice = ordered(role, greedy).first else { break }
            greedy[role] = voice
            if exhausted { break }
        }
        var best = greedy
        if strategy == .sceneAware && !conflicts(best).isEmpty && !exhausted {
            var search = frozen
            func solve() throws -> Bool {
                try Task.checkCancellation()
                if !conflicts(search).isEmpty { return false }
                guard let role = next(search) else { best = search; return true }
                for voice in ordered(role, search) {
                    if exhausted { return false }
                    search[role] = voice
                    if try solve() { return true }
                    search.removeValue(forKey: role)
                    if exhausted { return false }
                }
                return false
            }
            _ = try solve()
        }
        let residual = conflicts(best)
        let complete = roles.allSatisfy { best[$0] != nil }
        let status: Status = exhausted ? .budgetExceeded : (!complete ? .provenInsufficient : (residual.isEmpty ? .solved : (strategy == .sceneAware ? .provenInsufficient : .residualConflicts)))
        return .init(assignments: best, residualDirectPairs: residual, status: status, evaluatedCandidates: evaluated)
    }
}

/// Cache keys separate role and voice semantics from catalogue-wide presentation revisions.
public struct AudiobookCastingScoreCache: Equatable, Sendable {
    private var values: [String: Int] = [:]
    public private(set) var evaluationCount = 0
    public init() {}
    public mutating func score(role: UUID, voice: String, roleRevision: String, voiceRevision: String, compute: () -> Int) -> Int {
        let key = "\(role)|\(voice)|\(roleRevision)|\(voiceRevision)"
        if let cached = values[key] { return cached }
        let value = compute(); evaluationCount += 1
        if values.count >= 200_000 { values.removeAll(keepingCapacity: true) }
        values[key] = value; return value
    }
    public mutating func scores(roleIDs: [UUID], voiceIDs: [String], roleRevision: String, voiceRevision: String, compute: (UUID, String) -> Int) -> [UUID: [String: Int]] {
        var result: [UUID: [String: Int]] = [:]
        for role in Set(roleIDs).sorted(by: { $0.uuidString < $1.uuidString }) {
            for voice in Set(voiceIDs).sorted() {
                result[role, default: [:]][voice] = score(role: role, voice: voice, roleRevision: roleRevision, voiceRevision: voiceRevision) { compute(role, voice) }
            }
        }
        return result
    }
}
