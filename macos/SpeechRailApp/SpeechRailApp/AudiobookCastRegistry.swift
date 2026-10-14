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
        var accumulatedScalars = 2
        for (character, _) in scored {
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
            let estimatedScalars = summary.canonicalName.unicodeScalars.count
                + summary.aliases.joined(separator: ",").unicodeScalars.count
                + (summary.evidenceNote?.unicodeScalars.count ?? 0)
                + 72
            if accumulatedScalars + estimatedScalars > policy.maxCharacterSummaryScalars {
                break
            }
            selected.append(summary)
            accumulatedScalars += estimatedScalars
            if selected.count >= policy.maxMergeCandidatesPerBatch {
                break
            }
        }
        return selected
    }

    /// 全书分析后根据实际对白频次与跨章分布更新主次角色标记及排序（旁白置顶，高频主角优先，龙套默认允许共用声线）。
    public static func refreshCharacterMajorStatusAndOrder(
        characters: [AudiobookCharacter],
        annotations: [AudiobookAnnotation]
    ) -> [AudiobookCharacter] {
        guard !characters.isEmpty else { return [] }
        var dialogueCounts: [UUID: Int] = [:]
        var activeChaptersByRole: [UUID: Set<UUID>] = [:]
        for ann in annotations {
            if let roleID = ann.assignment.roleID {
                dialogueCounts[roleID, default: 0] += 1
                activeChaptersByRole[roleID, default: []].insert(ann.chapterID)
            }
        }

        let narrators = characters.filter(\.isNarrator)
        let nonNarrators = characters.filter { !$0.isNarrator }
        let totalNonNarrators = nonNarrators.count

        let updatedNonNarrators = nonNarrators.map { role -> (AudiobookCharacter, Int) in
            var copy = role
            let count = dialogueCounts[role.id, default: 0]
            if let chapters = activeChaptersByRole[role.id], !chapters.isEmpty {
                copy.chapterIDs = Array(Set(copy.chapterIDs).union(chapters))
            }
            // 若角色总数较少（<= 4）或台词数 >= 2 或跨多章出场，视为主要角色；仅偶发 1 句且角色众多时归为可共用声线的次要角色
            let isMajorRole = totalNonNarrators <= 4 || count >= 2 || copy.chapterIDs.count >= 2
            copy.isMajor = isMajorRole
            if !isMajorRole {
                copy.allowSharedMinorVoice = true
            }
            return (copy, count)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.chapterIDs.count != rhs.0.chapterIDs.count {
                return lhs.0.chapterIDs.count > rhs.0.chapterIDs.count
            }
            return lhs.0.displayName < rhs.0.displayName
        }
        .map(\.0)

        return narrators + updatedNonNarrators
    }

    /// 基于角色称谓、提取的声线线索（性别/年龄段/音色特质）与可用音色目录进行多维打分与去重匹配。
    public static func recommendVoiceBindings(
        characters: [AudiobookCharacter],
        availableVoices: [SafeVoiceEntry],
        existingBindings: [UUID: AudiobookVoiceBinding] = [:]
    ) -> [UUID: AudiobookVoiceBinding] {
        let readyVoices = availableVoices.filter { $0.available && $0.productionReady != false }
        guard !readyVoices.isEmpty else { return existingBindings }

        var result = existingBindings
        var usedVoiceIDs = Set(result.values.map(\.voiceID))

        let orderedCharacters = characters.sorted { lhs, rhs in
            if lhs.isNarrator != rhs.isNarrator { return lhs.isNarrator }
            if lhs.isMajor != rhs.isMajor { return lhs.isMajor }
            return lhs.displayName < rhs.displayName
        }

        for character in orderedCharacters {
            if let existing = result[character.id], existing.isSynthesisReady {
                usedVoiceIDs.insert(existing.voiceID)
                continue
            }

            let unusedVoices = readyVoices.filter { !usedVoiceIDs.contains($0.id) }
            let pool = (!unusedVoices.isEmpty && (character.isNarrator || !character.allowSharedMinorVoice))
                ? unusedVoices
                : readyVoices

            let bestVoice = selectBestVoice(
                for: character,
                candidates: pool,
                usedVoiceIDs: usedVoiceIDs
            )
            guard let chosen = bestVoice else { continue }

            let isDuplicate = usedVoiceIDs.contains(chosen.id)
            if isDuplicate && (character.isNarrator || !character.allowSharedMinorVoice) {
                continue
            }

            let modelRev = chosen.model.catalogRevision
                ?? chosen.model.runtimeRevision
                ?? "qwen3-tts-v1"
            let binding = AudiobookVoiceBinding(
                roleID: character.id,
                voiceID: chosen.id,
                voiceRevision: chosen.voiceRevision ?? "v1",
                modelRevision: modelRev,
                isSynthesisReady: true
            )
            result[character.id] = binding
            usedVoiceIDs.insert(chosen.id)
        }

        return result
    }

    private static func selectBestVoice(
        for character: AudiobookCharacter,
        candidates: [SafeVoiceEntry],
        usedVoiceIDs: Set<String>
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

        let scored = candidates.map { voice -> (SafeVoiceEntry, Int) in
            var score = 0
            let voiceIDLower = voice.id.lowercased()
            let voiceNameLower = voice.name.lowercased()
            let voiceMeta = ([voiceIDLower, voiceNameLower] + voice.aliases.map { $0.lowercased() } + voice.descriptors.styleTags.map { $0.lowercased() })
                .joined(separator: " ")

            // 1. 角色名与音色名/ID 直接呼应（如 v-narrator、旁白、角色同名定制音色）
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

            // 3. 性别、年龄与声线特征匹配
            let voiceGender = inferVoiceGender(voiceID: voiceIDLower, voiceMeta: voiceMeta)
            if inferredGender != .unknown && voiceGender == inferredGender {
                score += 180
            } else if inferredGender != .unknown && voiceGender != .unknown && voiceGender != inferredGender {
                score -= 150
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

            // 4. 音色互斥加成（优先为不同角色分配尚未占用的独立声线）
            if !usedVoiceIDs.contains(voice.id) {
                score += 300
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
