import Foundation

/// T05：全书角色归并、候选批次筛选（每批最多 32 个候选）与同名/别称碰撞保留。
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

    /// 将提取阶段得到的 mentions 按最多 32 个一批分批。
    public static func batchMentions(
        _ mentions: [AudiobookExtractionResponse.Mention],
        batchSize: Int = AudiobookLimits.maxCastMergeBatchSize
    ) -> [[AudiobookExtractionResponse.Mention]] {
        let clampedBatchSize = max(1, min(batchSize, AudiobookLimits.maxCastMergeBatchSize))
        var deduplicatedBySurface: [String: AudiobookExtractionResponse.Mention] = [:]
        var orderedKeys: [String] = []

        for mention in mentions {
            let trimmed = mention.surfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if var existing = deduplicatedBySurface[trimmed] {
                let mergedAliases = Array(Set(existing.aliases + mention.aliases)).sorted()
                let mergedAtomIDs = Array(Set(existing.evidenceAtomIDs + mention.evidenceAtomIDs))
                existing.aliases = mergedAliases
                existing.evidenceAtomIDs = mergedAtomIDs
                if existing.voiceTraitEvidence == nil, let trait = mention.voiceTraitEvidence, !trait.isEmpty {
                    existing.voiceTraitEvidence = trait
                }
                deduplicatedBySurface[trimmed] = existing
            } else {
                var normalized = mention
                normalized.surfaceName = trimmed
                deduplicatedBySurface[trimmed] = normalized
                orderedKeys.append(trimmed)
            }
        }

        let orderedMentions = orderedKeys.compactMap { deduplicatedBySurface[$0] }
        guard !orderedMentions.isEmpty else { return [] }

        var batches: [[AudiobookExtractionResponse.Mention]] = []
        var index = 0
        while index < orderedMentions.count {
            let end = min(orderedMentions.count, index + clampedBatchSize)
            batches.append(Array(orderedMentions[index..<end]))
            index = end
        }
        return batches
    }

    /// 结合已有角色库与本批归并输出，更新全书角色表（保留稳定 role ID 与旁白）。
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
        let mentionsByName: [String: AudiobookExtractionResponse.Mention] = Dictionary(
            uniqueKeysWithValues: batchMentions.map { ($0.surfaceName, $0) }
        )

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

            var evidences: [AudiobookCharacterEvidence] = []
            var chapterIDSet = Set<UUID>()
            var earliestRange: AudiobookSourceRange?

            for name in allNames {
                guard let mention = mentionsByName[name] else { continue }
                for atomID in mention.evidenceAtomIDs {
                    guard let atom = atomsByID[atomID] else { continue }
                    chapterIDSet.insert(atom.chapterID)
                    if earliestRange == nil || atom.sourceRange < earliestRange! {
                        earliestRange = atom.sourceRange
                    }
                    let excerpt = (try? source.text(in: atom.sourceRange)) ?? name
                    evidences.append(
                        AudiobookCharacterEvidence(
                            chapterID: atom.chapterID,
                            sourceRange: atom.sourceRange,
                            quoteExcerpt: String(excerpt.prefix(120))
                        )
                    )
                }
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
                let combinedEvidences = updated.evidences + evidences
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

    /// 为单窗标注筛选候选角色摘要（不把全书庞大的角色库无上限塞入单次 prompt）。
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
            let evidenceNote = character.evidences.first?.quoteExcerpt
            let summary = AudiobookPromptCharacterSummary(
                roleID: character.id,
                canonicalName: character.displayName,
                aliases: Array(character.aliases.prefix(8)),
                evidenceNote: evidenceNote.map { String($0.prefix(60)) }
            )
            let estimatedScalars = summary.canonicalName.unicodeScalars.count
                + summary.aliases.joined(separator: ",").unicodeScalars.count
                + (summary.evidenceNote?.unicodeScalars.count ?? 0)
                + 64
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
}
