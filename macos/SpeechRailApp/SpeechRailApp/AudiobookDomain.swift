import CryptoKit
import Foundation
import SpeechRailControlKit

// MARK: - Centralized Default Budgets & Limits

public enum AudiobookLimits {
    public static let maxRawFileBytes: Int = 64 * 1024 * 1024
    public static let maxTotalScalars: Int = 10_000_000
    public static let maxPreviewScalars: Int = 6_000
    public static let maxAtomScalars: Int = 160

    public static let maxWindowPrimaryScalars: Int = 4_000
    public static let maxWindowPrimaryAtoms: Int = 256
    public static let maxWindowContextScalarsPerSide: Int = 500
    public static let maxCastSummaryScalars: Int = 4_000
    public static let maxTotalPromptScalars: Int = 64_000
    public static let minSplitWindowScalars: Int = 64

    public static let maxExtractionOutputTokens: Int = 4_000
    public static let maxConsolidationOutputTokens: Int = 4_000
    public static let maxAnnotationOutputTokens: Int = 6_000
    public static let analysisCallTimeoutSeconds: TimeInterval = 90
    public static let maxCastMergeBatchSize: Int = 32
    public static let maxCompleteJSONCallsPerRootWindow: Int = 4

    public static let targetFragmentScalars: Int = 180
    public static let maxFragmentScalars: Int = 240
    public static let maxInFlightRenderRequests: Int = 1
    public static let maxWAVResponseBytes: Int = 8 * 1024 * 1024
    public static let maxRenderTransientRetries: Int = 3
    public static let defaultRenderSpeed: Double = 1.0

    public static let maxStorePageSize: Int = 100
    public static let minPlaybackRate: Float = 0.5
    public static let maxPlaybackRate: Float = 2.0
    public static let bookmarkAutosaveIntervalSeconds: TimeInterval = 5.0

    public static let maxExportManifestBytes: Int = 64 * 1024 * 1024
    public static let exportIOChunkBytes: Int = 64 * 1024
    public static let exportNoProgressTimeoutSeconds: TimeInterval = 90
    public static let exportMaxDurationSeconds: TimeInterval = 2 * 3600
    public static let intermediateSampleRate: Int = 48_000
    public static let intermediateChannels: Int = 1
    public static let exportAudioBitrateKbps: Int = 128
}

// MARK: - Core Source & Identity Types

public enum AudiobookSourceError: Error, Equatable, Sendable, LocalizedError {
    case invalidUTF8
    case rangeOutOfBounds(AudiobookSourceRange, totalBytes: Int64)
    case invertedRange(AudiobookSourceRange)
    case nonScalarBoundary(Int64)
    case coverageHole(expectedLowerBound: Int64, actualLowerBound: Int64)
    case coverageOverlap(previousUpperBound: Int64, nextLowerBound: Int64)
    case coverageDuplicate(AudiobookSourceRange)
    case coverageIncomplete(coveredUntil: Int64, totalBytes: Int64)
    case unknownAtomID(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            "正文字节不是有效的 UTF-8 编码。"
        case let .rangeOutOfBounds(range, totalBytes):
            "来源区间 [\(range.lowerBound), \(range.upperBound)) 超出正文长度 \(totalBytes)。"
        case let .invertedRange(range):
            "来源区间下界 \(range.lowerBound) 大于上界 \(range.upperBound)。"
        case let .nonScalarBoundary(offset):
            "字节偏移 \(offset) 未落在 Unicode 字符边界上。"
        case let .coverageHole(expected, actual):
            "正文区间存在遗漏：期望从 \(expected) 继续，实际从 \(actual) 开始。"
        case let .coverageOverlap(previous, next):
            "正文区间存在重叠：前一段结束于 \(previous)，下一段开始于 \(next)。"
        case let .coverageDuplicate(range):
            "正文区间重复覆盖：[\(range.lowerBound), \(range.upperBound))。"
        case let .coverageIncomplete(coveredUntil, totalBytes):
            "正文末尾未完整覆盖：仅覆盖至 \(coveredUntil) / \(totalBytes)。"
        case let .unknownAtomID(id):
            "未知的正文单元标识：\(id.uuidString)。"
        }
    }
}

/// Half-open UTF-8 byte interval `[lowerBound, upperBound)` on canonical source text.
public struct AudiobookSourceRange: Codable, Equatable, Hashable, Sendable, Comparable {
    public let lowerBound: Int64
    public let upperBound: Int64

    public init(lowerBound: Int64, upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var byteCount: Int64 {
        upperBound - lowerBound
    }

    public var isEmpty: Bool {
        lowerBound == upperBound
    }

    public static func < (lhs: AudiobookSourceRange, rhs: AudiobookSourceRange) -> Bool {
        if lhs.lowerBound != rhs.lowerBound {
            return lhs.lowerBound < rhs.lowerBound
        }
        return lhs.upperBound < rhs.upperBound
    }
}

public enum AudiobookTextAtomKind: String, Codable, Equatable, Hashable, Sendable {
    case body
    case heading
    case formatting
}

public struct AudiobookTextAtom: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let chapterID: UUID
    public let ordinal: Int
    public let sourceRange: AudiobookSourceRange
    public let kind: AudiobookTextAtomKind

    public init(
        id: UUID = UUID(),
        chapterID: UUID,
        ordinal: Int,
        sourceRange: AudiobookSourceRange,
        kind: AudiobookTextAtomKind
    ) {
        self.id = id
        self.chapterID = chapterID
        self.ordinal = ordinal
        self.sourceRange = sourceRange
        self.kind = kind
    }
}

// MARK: - Distinct Status Enums (Never Sharing a Generic `.completed`)

public enum AudiobookAnalysisState: String, Codable, Equatable, Hashable, Sendable {
    case notStarted
    case running
    case paused
    case failed
    case allWindowsValidated
}

public enum AudiobookChapterReadinessState: String, Codable, Equatable, Hashable, Sendable {
    case awaitingGlobalAnalysis
    case awaitingCastConfirmation
    case blockedByUnknownSpeakers
    case readyForProduction
    case producing
    case paused
    case needsUpdate
    case chapterAudioReady
    case failed
}

public enum AudiobookProductionState: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case running
    case pausing
    case paused
    case blockedByConditions
    case partialChaptersReady
    case allConfirmedChaptersProduced
    case fullBookProduced
    case failed
}

public enum AudiobookListenableState: String, Codable, Equatable, Hashable, Sendable {
    case noneAvailable
    case previousRevisionAvailable
    case partialChaptersListenable
    case fullBookListenable
}

// MARK: - Book & Chapter Models

public struct AudiobookBook: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sourceID: UUID
    public var title: String
    public var author: String?
    public let sourceSHA256: String
    public let canonicalByteCount: Int64
    public let scalarCount: Int
    public let originalEncoding: String
    public var analysisState: AudiobookAnalysisState
    public var productionState: AudiobookProductionState
    public var listenableState: AudiobookListenableState
    public var confirmedCastRevisionID: UUID?
    public var confirmedAuditionVoiceSetDigest: String?
    public var currentProductionRevisionID: UUID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sourceID: UUID = UUID(),
        title: String,
        author: String? = nil,
        sourceSHA256: String,
        canonicalByteCount: Int64,
        scalarCount: Int,
        originalEncoding: String,
        analysisState: AudiobookAnalysisState = .notStarted,
        productionState: AudiobookProductionState = .idle,
        listenableState: AudiobookListenableState = .noneAvailable,
        confirmedCastRevisionID: UUID? = nil,
        confirmedAuditionVoiceSetDigest: String? = nil,
        currentProductionRevisionID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.author = author
        self.sourceSHA256 = sourceSHA256
        self.canonicalByteCount = canonicalByteCount
        self.scalarCount = scalarCount
        self.originalEncoding = originalEncoding
        self.analysisState = analysisState
        self.productionState = productionState
        self.listenableState = listenableState
        self.confirmedCastRevisionID = confirmedCastRevisionID
        self.confirmedAuditionVoiceSetDigest = confirmedAuditionVoiceSetDigest
        self.currentProductionRevisionID = currentProductionRevisionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AudiobookChapter: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let sourceID: UUID
    public var ordinal: Int
    public var title: String
    public var sourceRange: AudiobookSourceRange
    public var excludedRanges: [AudiobookSourceRange]
    public var currentChapterRevisionID: UUID?
    public var previousChapterRevisionID: UUID?

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        sourceID: UUID,
        ordinal: Int,
        title: String,
        sourceRange: AudiobookSourceRange,
        excludedRanges: [AudiobookSourceRange] = [],
        currentChapterRevisionID: UUID? = nil,
        previousChapterRevisionID: UUID? = nil
    ) {
        self.id = id
        self.bookID = bookID
        self.sourceID = sourceID
        self.ordinal = ordinal
        self.title = title
        self.sourceRange = sourceRange
        self.excludedRanges = excludedRanges
        self.currentChapterRevisionID = currentChapterRevisionID
        self.previousChapterRevisionID = previousChapterRevisionID
    }
}

// MARK: - Character, Voice Persona, Voice Binding & Analysis Annotation

/// 六维声学画像模型（对齐 Qwen3-TTS-12Hz-1.7B-VoiceDesign 控制维度与 voices.md 基频守卫）。
public struct AudiobookVoicePersona: Codable, Equatable, Hashable, Sendable {
    public var ageGenderAnchor: String
    public var pitchAndRegister: String
    public var timbreAndTexture: String
    public var pacingAndDiction: String
    public var emotionalUndertone: String
    public var contrastiveNote: String?
    public var customChips: [String]

    public init(
        ageGenderAnchor: String,
        pitchAndRegister: String,
        timbreAndTexture: String,
        pacingAndDiction: String,
        emotionalUndertone: String,
        contrastiveNote: String? = nil,
        customChips: [String] = []
    ) {
        self.ageGenderAnchor = ageGenderAnchor
        self.pitchAndRegister = pitchAndRegister
        self.timbreAndTexture = timbreAndTexture
        self.pacingAndDiction = pacingAndDiction
        self.emotionalUndertone = emotionalUndertone
        self.contrastiveNote = contrastiveNote
        self.customChips = customChips
    }

    /// 将六维声学画像编译为 60–130 字的黄金长度 Qwen3-TTS VoiceDesign 指令（含成年基频防漂移守卫）。
    public func compiledVoiceDesignInstruction(roleName: String, isNarrator: Bool) -> String {
        if isNarrator {
            return "有声书旁白（\(ageGenderAnchor)）：\(pitchAndRegister)，\(timbreAndTexture)。朗读时\(pacingAndDiction)，整体透出\(emotionalUndertone)的叙事氛围，近讲演播室纯净收音，呼吸与停连自然。"
        }
        var clauses: [String] = [
            "角色「\(roleName)」（\(ageGenderAnchor)）",
            "\(pitchAndRegister)，\(timbreAndTexture)",
            "说话时\(pacingAndDiction)，声音透出\(emotionalUndertone)的人物气质"
        ]
        if let contrastive = contrastiveNote?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contrastive.isEmpty
        {
            clauses.append(contrastive)
        }
        clauses.append("咬字清晰自然，贴合有声书戏剧对白演绎，近讲收音干净真实。")
        return clauses.joined(separator: "；")
    }

    /// 结合角色名、别称、提取的声线线索、原书台词证据与同书同性角色对比，推断完整的六维声学画像。
    public static func infer(
        for character: AudiobookCharacter,
        peers: [AudiobookCharacter] = [],
        recompute: Bool = false
    ) -> AudiobookVoicePersona {
        if !recompute, let explicit = character.evidences.compactMap(\.voicePersona).first {
            return explicit
        }

        let allTraitSummaries = character.evidences
            .compactMap(\.voiceTraitSummary)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let rawTrait = allTraitSummaries.first ?? ""
        let traitClauses = extractDistinctClauses(from: allTraitSummaries)

        // 仅提取引号外的旁白归属动作（如“老周放下烟袋，低声叹道：”），避免引号内台词内容（如“今晚风浪急”）污染角色语速推断
        let attributionSnippets = character.evidences.map {
            AudiobookAuditionScriptSelector.stripDialogueQuotes(from: $0.quoteExcerpt)
        }
        let traitAndAttributionCorpus = (
            [character.displayName]
                + character.aliases
                + allTraitSummaries
                + attributionSnippets
        ).joined(separator: " ")

        if character.isNarrator {
            let customTrait = rawTrait.isEmpty ? "声线温润通透、富有空间纵深感" : rawTrait
            return AudiobookVoicePersona(
                ageGenderAnchor: "30至40岁成年叙事者",
                pitchAndRegister: "中音区基频平稳扎实，胸腔共鸣自然",
                timbreAndTexture: customTrait,
                pacingAndDiction: "语速从容均匀，停连富有文学呼吸感，吐字清晰端庄",
                emotionalUndertone: "沉静克制、引人入胜",
                contrastiveNote: nil,
                customChips: ["沉稳胸腔共鸣", "演播室近讲感", "语速从容均匀", "温润叙事质感", "呼吸停连自然"]
            )
        }

        let gender = inferGender(from: traitAndAttributionCorpus, roleName: character.displayName)
        let ageBand = inferAgeBand(from: traitAndAttributionCorpus, roleName: character.displayName)

        // 拆分 LLM 提取的多维子句，避免同一特征在多个维度重复出现
        let explicitAgeClause = traitClauses.first {
            containsAny(in: $0, keywords: ["岁", "青年", "中年", "老年", "少年", "少女", "老者", "成年"])
        }
        let explicitPitchClause = traitClauses.first {
            $0 != explicitAgeClause && containsAny(in: $0, keywords: ["音区", "中低音", "中高音", "低音", "高音", "共鸣", "胸腔", "头腔", "基频"])
        }
        let explicitPacingClause = traitClauses.first {
            $0 != explicitAgeClause && $0 != explicitPitchClause
                && containsAny(in: $0, keywords: ["语速", "吐字", "咬字", "干脆", "利落", "舒缓", "从容", "慢条斯理", "急促", "停顿", "停连"])
        }
        let explicitEmotionClause = traitClauses.first {
            $0 != explicitAgeClause && $0 != explicitPitchClause && $0 != explicitPacingClause
                && containsAny(in: $0, keywords: ["气场", "气质", "冷静", "克制", "威严", "温婉", "明朗", "阴鸷", "内敛", "果决", "沉稳"])
        }
        let explicitTimbreClauses = traitClauses.filter {
            $0 != explicitAgeClause && $0 != explicitPitchClause && $0 != explicitPacingClause && $0 != explicitEmotionClause
        }

        // 基频守卫（voices.md）：成年角色明确标注稳健成年年龄段，避免少年/幼态词导致基频向上漂移
        let defaultAgeGenderAnchor: String = {
            switch (gender, ageBand) {
            case (.male, .elder):
                return "60岁左右老年男性"
            case (.male, .middleAged):
                return "40至50岁中年男性"
            case (.male, .youth):
                return "18至22岁青年男性"
            case (.male, .youngAdult):
                return "26至32岁成年男性"
            case (.female, .elder):
                return "60岁左右老年女性"
            case (.female, .middleAged):
                return "38至48岁中年女性"
            case (.female, .youth):
                return "18至22岁年轻女性"
            case (.female, .youngAdult):
                return "24至30岁成年女性"
            case (.unknown, .elder):
                return "60岁左右年长者"
            case (.unknown, .middleAged):
                return "40岁左右成熟成年人"
            case (.unknown, _):
                return "26至34岁成年角色"
            }
        }()

        let ageGenderAnchor: String = {
            guard let clause = explicitAgeClause else { return defaultAgeGenderAnchor }
            if clause.contains("男") || clause.contains("女") {
                if clause.contains("成年") || clause.contains("中年") || clause.contains("老年") {
                    return clause
                }
                return "\(clause)（成年稳健基频）"
            }
            return defaultAgeGenderAnchor
        }()

        let pitchAndRegister: String = {
            let basePitch: String
            if containsAny(in: traitAndAttributionCorpus, keywords: ["低沉", "浑厚", "低音", "胸腔", "雄浑"]) || ageBand == .elder || ageBand == .middleAged {
                basePitch = gender == .female
                    ? "中低音区（基频稳重），胸腔共鸣温和扎实"
                    : "中低音区（基频稳定在成年男声低频带），胸腔共鸣浑厚扎实"
            } else if containsAny(in: traitAndAttributionCorpus, keywords: ["清脆", "清亮", "明快", "清越", "银铃"]) {
                basePitch = gender == .male
                    ? "中音偏亮音区，基频干净利落，共鸣通透"
                    : "中高音区，声线清亮通透，头腔与口腔共鸣明晰"
            } else {
                basePitch = gender == .female
                    ? "自然中音区（成年女声舒适基频带），共鸣柔和通透"
                    : "稳健中低音区（成年男声标准基频带），胸腔共鸣自然饱满"
            }
            if let explicitPitchClause, !basePitch.contains(explicitPitchClause) {
                return "\(basePitch)（\(explicitPitchClause)）"
            }
            return basePitch
        }()

        let timbreAndTexture: String = {
            let chosenTimbre = explicitTimbreClauses.joined(separator: "、")
            if !chosenTimbre.isEmpty {
                return "音色兼具「\(chosenTimbre)」质感，声带纹理真实自然"
            }
            if !rawTrait.isEmpty {
                return "音色兼具「\(rawTrait)」质感，声带纹理真实自然"
            }
            if ageBand == .elder {
                return "嗓音略带沧桑沙哑的颗粒感与岁月风霜气息"
            }
            if ageBand == .middleAged {
                return "音色醇厚沉实，质感老练稳重"
            }
            return gender == .female
                ? "音色清润细腻，富有亲和力与层次感"
                : "音色干净温润，略带克制的磁性颗粒感"
        }()

        let pacingAndDiction: String = {
            if let explicitPacingClause {
                return "\(explicitPacingClause)，吐字清晰自然，重音与停连层次分明"
            }
            // 优先检查低声/叹气/苍老等慢速线索（不受引号内“风浪急”等台词词汇干扰）
            if containsAny(in: traitAndAttributionCorpus, keywords: ["语速慢", "语速缓", "舒缓", "低声", "叹道", "叹了口气", "轻声", "沉思", "慢条斯理", "摇了摇头"]) || ageBand == .elder {
                return "语速舒缓沉着，字句间留有沉思停顿，尾音收束自然"
            }
            if containsAny(in: traitAndAttributionCorpus, keywords: ["语速快", "急促", "喝道", "喊道", "厉声", "干脆", "利落", "快言快语"]) {
                return "语速干脆利落，吐字清晰有力，重音果断"
            }
            return "语速平稳适中，咬字清晰自然，句间停连富有对话节奏感"
        }()

        let emotionalUndertone: String = {
            if let explicitEmotionClause {
                return explicitEmotionClause
            }
            if containsAny(in: traitAndAttributionCorpus, keywords: ["冷峻", "冷漠", "寒声", "警觉", "严肃", "威严", "厉声"]) {
                return "冷静克制、机敏果决"
            }
            if containsAny(in: traitAndAttributionCorpus, keywords: ["笑道", "活泼", "欢快", "打趣", "明朗", "爽朗"]) {
                return "明朗鲜活、灵动自然"
            }
            if ageBand == .elder || ageBand == .middleAged {
                return "饱经世事、沉稳内敛"
            }
            return "沉着笃定、真实鲜活"
        }()

        // 同书同性角色对比去重（Contrastive Peer Disambiguation）
        let sameGenderPeers = peers.filter { peer in
            guard !peer.isNarrator, peer.id != character.id else { return false }
            let peerCorpus = ([peer.displayName, peer.primaryVoiceTraitSummary ?? ""] + peer.aliases).joined(separator: " ")
            return inferGender(from: peerCorpus, roleName: peer.displayName) == gender
        }
        let contrastiveNote: String? = {
            guard !sameGenderPeers.isEmpty else { return nil }
            let sortedPeerIDs = (sameGenderPeers.map(\.id) + [character.id]).sorted { $0.uuidString < $1.uuidString }
            let slotIndex = sortedPeerIDs.firstIndex(of: character.id) ?? 0
            switch slotIndex % 3 {
            case 0:
                return "声线偏醇厚胸腔共鸣，语调更为内敛沉稳"
            case 1:
                return "声线偏清朗通透，咬字更显明快利落"
            default:
                return "声线略带微哑颗粒感与气息层次，停顿更具戏剧张力"
            }
        }()

        let chips: [String] = {
            var list: [String] = []
            for clause in traitClauses where clause.count >= 2 && clause.count <= 8 {
                list.append(clause)
            }
            switch (gender, ageBand) {
            case (.male, .elder), (.male, .middleAged):
                list.append(contentsOf: ["沧桑醇厚", "胸腔低音", "沉稳慢速", "微哑颗粒感", "世故内敛"])
            case (.male, _):
                list.append(contentsOf: ["青年中低音", "清朗磁性", "咬字干脆", "沉着克制", "近讲对白感"])
            case (.female, .elder), (.female, .middleAged):
                list.append(contentsOf: ["温婉醇厚", "知性中低音", "从容舒缓", "柔和共鸣", "叙事层次感"])
            case (.female, _):
                list.append(contentsOf: ["清亮灵动", "温润通透", "细腻气声", "明快自然", "富有感染力"])
            case (.unknown, _):
                list.append(contentsOf: ["稳健中音区", "咬字清晰", "自然停连", "戏剧张力", "演播室质感"])
            }
            return Array(NSOrderedSet(array: list).compactMap { $0 as? String }.prefix(6))
        }()

        return AudiobookVoicePersona(
            ageGenderAnchor: ageGenderAnchor,
            pitchAndRegister: pitchAndRegister,
            timbreAndTexture: timbreAndTexture,
            pacingAndDiction: pacingAndDiction,
            emotionalUndertone: emotionalUndertone,
            contrastiveNote: contrastiveNote,
            customChips: chips
        )
    }

    private enum Gender {
        case male
        case female
        case unknown
    }

    private enum AgeBand {
        case youth
        case youngAdult
        case middleAged
        case elder
    }

    private static func extractDistinctClauses(from summaries: [String]) -> [String] {
        let separators = CharacterSet(charactersIn: "，、；,;。")
        var result: [String] = []
        for summary in summaries {
            let parts = summary
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for part in parts where !result.contains(part) {
                result.append(part)
            }
        }
        return result
    }

    private static func inferGender(from text: String, roleName: String) -> Gender {
        let lower = (roleName + " " + text).lowercased()
        let femaleHits = countMatches(
            in: lower,
            keywords: ["女", "姐", "妹", "娘", "姑", "婆", "妇", "嫂", "她", "小姐", "夫人", "少女", "晴", "雪", "瑶", "琳", "婷", "芳", "婉", "薇", "柔", "女声"]
        )
        let maleHits = countMatches(
            in: lower,
            keywords: ["男", "哥", "弟", "爷", "叔", "伯", "掌柜", "公子", "先生", "少年", "青年", "老汉", "老周", "林远", "男声", "低沉", "大汉", "兄"]
        )
        if femaleHits > maleHits { return .female }
        if maleHits > femaleHits { return .male }
        return .unknown
    }

    private static func inferAgeBand(from text: String, roleName: String) -> AgeBand {
        let combined = roleName + " " + text
        // 优先识别明确的数字年龄（如 “55岁”、“28岁”、“19岁”）
        if let explicitAge = parseExplicitNumericAge(from: combined) {
            if explicitAge >= 55 { return .elder }
            if explicitAge >= 36 { return .middleAged }
            if explicitAge <= 22 { return .youth }
            return .youngAdult
        }
        if containsAny(in: combined, keywords: ["老", "爷", "婆", "苍老", "年迈", "白发", "老者", "老叟", "老妪"]) {
            return .elder
        }
        if containsAny(in: combined, keywords: ["叔", "伯", "掌柜", "师父", "长老", "中年", "夫人", "沉稳醇厚"]) {
            return .middleAged
        }
        if containsAny(in: combined, keywords: ["少女", "少年", "小妹", "学徒", "清脆"]) {
            return .youth
        }
        return .youngAdult
    }

    private static func parseExplicitNumericAge(from text: String) -> Int? {
        guard let range = text.range(of: #"(\d{1,2})\s*岁"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(text[range])
        let digits = matched.filter(\.isNumber)
        return Int(digits)
    }

    private static func containsAny(in text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private static func countMatches(in text: String, keywords: [String]) -> Int {
        keywords.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }
}

/// 原书「黄金试听台词」提纯与打分优选器（确保 100% 满足 20–240 字符门禁、剥离引号外旁白、规避数字复验风险）。
public enum AudiobookAuditionScriptSelector {
    public static func selectCandidates(
        from rawTexts: [String],
        roleName: String,
        aliases: [String] = [],
        isNarrator: Bool = false,
        maxCandidates: Int = 3
    ) -> [String] {
        var pureSegments: [String] = []

        for raw in rawTexts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != roleName else { continue }
            if isNarrator {
                let narration = stripDialogueQuotes(from: trimmed)
                if narration.count >= 6 {
                    pureSegments.append(narration)
                }
            } else {
                let extractedQuotes = extractQuotedDialogues(from: trimmed)
                if !extractedQuotes.isEmpty {
                    // 若同一段落内为夹带旁白动作的两段同一角色对白（如 “先别慌，”林远道，“等他们靠近再动手！”），合并为完整台词
                    if extractedQuotes.count > 1 {
                        let mergedInAtom = joinQuoteFragments(extractedQuotes)
                        if mergedInAtom.count >= 6 && mergedInAtom.count <= 200 {
                            pureSegments.append(mergedInAtom)
                        } else {
                            pureSegments.append(contentsOf: extractedQuotes)
                        }
                    } else {
                        pureSegments.append(contentsOf: extractedQuotes)
                    }
                } else {
                    let cleaned = stripNarratorAttributionPrefix(from: trimmed, roleName: roleName, aliases: aliases)
                    if cleaned.count >= 6 {
                        pureSegments.append(cleaned)
                    }
                }
            }
        }

        // 将相邻短句拼接为 35–95 字的黄金长度试听台词，兼顾单句与组合句（防止包含关系子句重复拼接）
        var candidatePool: [String] = []
        for idx in pureSegments.indices {
            let single = sanitizeForValidationGate(pureSegments[idx])
            if single.count >= 20 && single.count <= 200 {
                candidatePool.append(single)
            }
            var combined = pureSegments[idx]
            var nextIdx = idx + 1
            while nextIdx < pureSegments.count && combined.count < 75 {
                let nextSeg = pureSegments[nextIdx]
                nextIdx += 1
                guard !combined.contains(nextSeg), !nextSeg.contains(combined) else { continue }
                let tentative = joinQuoteFragments([combined, nextSeg])
                if tentative.count > 180 { break }
                combined = tentative
                let sanitizedCombined = sanitizeForValidationGate(combined)
                if sanitizedCombined.count >= 24 && sanitizedCombined.count <= 180 {
                    candidatePool.append(sanitizedCombined)
                }
            }
        }

        // 若单句仍不足 20 字，为原书短台词补齐符合人物语境的试听尾句，确保严格通过 20–240 字门禁
        if candidatePool.isEmpty, let firstShort = pureSegments.first {
            let padded = padToMinimumLength(firstShort, roleName: roleName, isNarrator: isNarrator)
            candidatePool.append(padded)
        }

        // 按表现力与声学锚点适配度打分去重（始终优先使用原书真实台词）
        var seen = Set<String>()
        var scored = candidatePool.compactMap { text -> (String, Int)? in
            let normalized = String(text.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 20, normalized.count <= 240, !seen.contains(normalized) else {
                return nil
            }
            seen.insert(normalized)
            return (normalized, scoreAuditionText(normalized))
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.count > rhs.0.count
        }
        .map(\.0)

        // 仅当原书没有任何可用台词时，使用兜底黄金文案（严格位于 35–75 字区间且不含阿拉伯数字）
        if scored.isEmpty {
            let fallback: String = isNarrator
                ? "夜色渐深，远处的灯火在微风中轻轻摇曳，海浪拍打着栈桥，故事从这里缓缓展开。"
                : "我是\(roleName)，这句来自原书的试听台词，将用于定型我在整部有声书中的专属角色声线与情感语气。"
            scored.append(sanitizeForValidationGate(fallback))
        }

        return Array(scored.prefix(max(1, maxCandidates)))
    }

    private static func joinQuoteFragments(_ fragments: [String]) -> String {
        var result = ""
        let trailingPunctuation: Set<Character> = ["。", "！", "？", "…", "，", "；", "、", "：", ",", ";", ":"]
        for fragment in fragments {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if result.isEmpty {
                result = trimmed
            } else {
                let needsComma = !result.last.map({ trailingPunctuation.contains($0) })!
                result += (needsComma ? "，" : "") + trimmed
            }
        }
        return result
    }

    private static func extractQuotedDialogues(from text: String) -> [String] {
        let pairs: [(Character, Character)] = [("“", "”"), ("「", "」"), ("『", "』"), ("\"", "\"")]
        var results: [String] = []
        for (openChar, closeChar) in pairs {
            var current = ""
            var inside = false
            for ch in text {
                if ch == openChar && !inside {
                    inside = true
                    current = ""
                } else if ch == closeChar && inside {
                    inside = false
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        results.append(trimmed)
                    }
                } else if inside {
                    current.append(ch)
                }
            }
            if !results.isEmpty { break }
        }
        return results
    }

    public static func stripDialogueQuotes(from text: String) -> String {
        var result = text
        let pairs: [(String, String)] = [("“", "”"), ("「", "」"), ("『", "』")]
        for (openQ, closeQ) in pairs {
            while let start = result.range(of: openQ),
                  let end = result.range(of: closeQ, range: start.upperBound..<result.endIndex)
            {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripNarratorAttributionPrefix(
        from text: String,
        roleName: String,
        aliases: [String]
    ) -> String {
        var cleaned = text.replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .replacingOccurrences(of: "「", with: "")
            .replacingOccurrences(of: "」", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ([roleName] + aliases) where !token.isEmpty {
            for verb in ["低声说道：", "低声叹道：", "说道：", "叹道：", "笑道：", "道：", "说：", "喊道：", "应道：", "感叹道："] {
                if cleaned.hasPrefix(token + verb) {
                    cleaned = String(cleaned.dropFirst((token + verb).count))
                }
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 将阿拉伯数字（含年份、小数、百分比与基数）转为中文自然口语数字以规避 `voice_design_text_fidelity_v2` 的数字转写误差，并规范句尾标点。
    public static func sanitizeForValidationGate(_ text: String) -> String {
        let digitMap: [Character: String] = [
            "0": "零", "1": "一", "2": "二", "3": "三", "4": "四",
            "5": "五", "6": "六", "7": "七", "8": "八", "9": "九"
        ]
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "zh_Hans")

        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count + 8)
        var i = 0

        func spellDigits(_ digits: String, digitByDigit: Bool) -> String {
            if !digitByDigit,
               digits.count <= 4,
               !digits.hasPrefix("0"),
               let intValue = Int(digits),
               let spelled = formatter.string(from: NSNumber(value: intValue))
            {
                return spelled
            }
            return digits.map { digitMap[$0] ?? String($0) }.joined()
        }

        while i < chars.count {
            let ch = chars[i]
            if digitMap[ch] != nil {
                var intPart = ""
                while i < chars.count, digitMap[chars[i]] != nil {
                    intPart.append(chars[i])
                    i += 1
                }
                // 检查小数（如 3.5 -> 三点五）
                var fracPart = ""
                if i + 1 < chars.count,
                   chars[i] == ".",
                   digitMap[chars[i + 1]] != nil
                {
                    i += 1 // consume '.'
                    while i < chars.count, digitMap[chars[i]] != nil {
                        fracPart.append(chars[i])
                        i += 1
                    }
                }
                // 检查紧随其后的百分号（如 50% -> 百分之五十）与年份（如 1998年 -> 一九九八年）
                let isPercentage = (i < chars.count && chars[i] == "%")
                if isPercentage { i += 1 }
                let isYear = (fracPart.isEmpty && intPart.count == 4 && i < chars.count && chars[i] == "年")

                let spokenInt = spellDigits(intPart, digitByDigit: isYear)
                let spokenNumber: String
                if !fracPart.isEmpty {
                    let spokenFrac = spellDigits(fracPart, digitByDigit: true)
                    spokenNumber = "\(spokenInt)点\(spokenFrac)"
                } else {
                    spokenNumber = spokenInt
                }

                if isPercentage {
                    out.append("百分之\(spokenNumber)")
                } else {
                    out.append(spokenNumber)
                }
            } else if ch == "\n" || ch == "\r" {
                out.append("，")
                i += 1
            } else {
                out.append(ch)
                i += 1
            }
        }

        var trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonTerminalTrailing: Set<Character> = ["，", "、", "；", "：", ",", ";", ":", "-", "—"]
        while let last = trimmed.last, nonTerminalTrailing.contains(last) {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return "" }
        if !trimmed.hasSuffix("。") && !trimmed.hasSuffix("！") && !trimmed.hasSuffix("？") && !trimmed.hasSuffix("…") {
            return trimmed + "。"
        }
        return trimmed
    }

    private static func padToMinimumLength(_ shortQuote: String, roleName: String, isNarrator: Bool) -> String {
        let base = sanitizeForValidationGate(shortQuote)
        if base.count >= 22 { return String(base.prefix(200)) }
        let suffix = isNarrator
            ? "夜风拂过寂静的街巷，万物在暮色中悄然苏醒。"
            : "这话我已经仔细想过了，今晚咱们就按这个主意行事。"
        let combined = base + suffix
        return String(combined.prefix(200))
    }

    private static func scoreAuditionText(_ text: String) -> Int {
        var score = 0
        let len = text.count
        if (24...95).contains(len) {
            score += 50
        } else if (20...130).contains(len) {
            score += 35
        } else {
            score += 10
        }
        if text.contains("，") && (text.contains("。") || text.contains("！") || text.contains("？")) {
            score += 30
        }
        if text.contains("！") || text.contains("？") || text.contains("…") {
            score += 20
        }
        return score
    }
}

public struct AudiobookCharacterEvidence: Codable, Equatable, Hashable, Sendable {
    public let chapterID: UUID
    public let sourceRange: AudiobookSourceRange
    public let quoteExcerpt: String
    public var voiceTraitSummary: String?
    public var voicePersona: AudiobookVoicePersona?

    public init(
        chapterID: UUID,
        sourceRange: AudiobookSourceRange,
        quoteExcerpt: String,
        voiceTraitSummary: String? = nil,
        voicePersona: AudiobookVoicePersona? = nil
    ) {
        self.chapterID = chapterID
        self.sourceRange = sourceRange
        self.quoteExcerpt = quoteExcerpt
        self.voiceTraitSummary = voiceTraitSummary
        self.voicePersona = voicePersona
    }

    public init(
        atomID: UUID,
        quoteExcerpt: String,
        voiceTraitSummary: String? = nil,
        voicePersona: AudiobookVoicePersona? = nil
    ) {
        self.chapterID = atomID
        self.sourceRange = AudiobookSourceRange(lowerBound: 0, upperBound: 0)
        self.quoteExcerpt = quoteExcerpt
        self.voiceTraitSummary = voiceTraitSummary
        self.voicePersona = voicePersona
    }
}

public struct AudiobookCharacter: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public var displayName: String
    public var aliases: [String]
    public let isNarrator: Bool
    public var isMajor: Bool
    public var allowSharedMinorVoice: Bool
    public var evidences: [AudiobookCharacterEvidence]
    public var firstAppearanceRange: AudiobookSourceRange?
    public var chapterIDs: [UUID]
    public var voicePolicy: AudiobookRoleVoicePolicy?
    public var manualTier: AudiobookRoleTier?
    public var voiceTraitsOverride: AudiobookVoiceTraits?
    public var requiredVoiceTraits: AudiobookVoiceTraits?

    public var effectiveVoicePolicy: AudiobookRoleVoicePolicy {
        voicePolicy ?? .init(sharingPolicy: isNarrator || !allowSharedMinorVoice ? .exclusive : .automatic)
    }

    public var primaryVoiceTraitSummary: String? {
        evidences.compactMap(\.voiceTraitSummary)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    /// 结合同书其他角色推断或读取该角色的六维声学画像。
    public func resolvedVoicePersona(peers: [AudiobookCharacter] = []) -> AudiobookVoicePersona {
        AudiobookVoicePersona.infer(for: self, peers: peers)
    }

    /// 为 Qwen3-TTS VoiceDesign 自动生成的六维声学描述提示词（可直接预填到「音色创作」页）。
    public var recommendedVoiceDesignInstruction: String {
        resolvedVoicePersona().compiledVoiceDesignInstruction(
            roleName: displayName,
            isNarrator: isNarrator
        )
    }

    /// 为 Qwen3-TTS VoiceDesign 自动提纯并优选的原书代表性试听台词（严格满足 20–240 字符门禁与无数字复验风险）。
    public var recommendedVoiceDesignReferenceText: String {
        AudiobookAuditionScriptSelector.selectCandidates(
            from: evidences.map(\.quoteExcerpt),
            roleName: displayName,
            aliases: aliases,
            isNarrator: isNarrator,
            maxCandidates: 1
        ).first ?? "我是\(displayName)，这句来自原书的试听台词，将用于定型我在有声书中的专属角色声线。"
    }

    /// 根据角色六维声学画像与原书线索，确定性推导角色的六大标准声部行当。
    public func inferredVoiceArchetype(peers: [AudiobookCharacter] = []) -> AudiobookVoiceArchetype {
        if isNarrator { return .narrator }
        let profile = VoiceTaxonomyClassifier.resolveTraits(description: primaryVoiceTraitSummary ?? "", override: voiceTraitsOverride)
        let mature = ["middleAged", "elder"].contains(profile.age.value)
        if profile.age.value == "child" { return .neutralEnsemble }
        switch profile.gender.value {
        case "male": return mature ? .matureMale : .youngMale
        case "female": return mature ? .matureFemale : .youngFemale
        default: return .neutralEnsemble
        }
    }

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        displayName: String,
        aliases: [String] = [],
        isNarrator: Bool = false,
        isMajor: Bool = true,
        allowSharedMinorVoice: Bool = false,
        evidences: [AudiobookCharacterEvidence] = [],
        firstAppearanceRange: AudiobookSourceRange? = nil,
        chapterIDs: [UUID] = [],
        voicePolicy: AudiobookRoleVoicePolicy? = nil,
        manualTier: AudiobookRoleTier? = nil,
        voiceTraitsOverride: AudiobookVoiceTraits? = nil,
        requiredVoiceTraits: AudiobookVoiceTraits? = nil
    ) {
        self.voiceTraitsOverride = voiceTraitsOverride
        self.requiredVoiceTraits = requiredVoiceTraits
        self.voicePolicy = voicePolicy
        self.manualTier = manualTier
        self.id = id
        self.bookID = bookID
        self.displayName = displayName
        self.aliases = aliases
        self.isNarrator = isNarrator
        self.isMajor = isMajor
        self.allowSharedMinorVoice = allowSharedMinorVoice
        self.evidences = evidences
        self.firstAppearanceRange = firstAppearanceRange
        self.chapterIDs = chapterIDs
    }

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        displayName: String,
        aliases: [String] = [],
        evidences: [AudiobookCharacterEvidence],
        primaryVoiceTraitSummary: String?,
        isNarrator: Bool = false,
        isMajor: Bool = true,
        allowSharedMinorVoice: Bool = false,
        firstAppearanceRange: AudiobookSourceRange? = nil,
        chapterIDs: [UUID] = []
    ) {
        var updatedEvidences = evidences
        if let trait = primaryVoiceTraitSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trait.isEmpty
        {
            if updatedEvidences.isEmpty {
                updatedEvidences = [
                    AudiobookCharacterEvidence(
                        chapterID: chapterIDs.first ?? UUID(),
                        sourceRange: firstAppearanceRange ?? AudiobookSourceRange(lowerBound: 0, upperBound: 0),
                        quoteExcerpt: displayName,
                        voiceTraitSummary: trait
                    )
                ]
            } else if updatedEvidences[0].voiceTraitSummary == nil {
                updatedEvidences[0].voiceTraitSummary = trait
            }
        }
        self.init(
            id: id,
            bookID: bookID,
            displayName: displayName,
            aliases: aliases,
            isNarrator: isNarrator,
            isMajor: isMajor,
            allowSharedMinorVoice: allowSharedMinorVoice,
            evidences: updatedEvidences,
            firstAppearanceRange: firstAppearanceRange,
            chapterIDs: chapterIDs
        )
    }
}

public struct AudiobookVoiceBinding: Codable, Equatable, Hashable, Sendable {
    public let roleID: UUID
    public let voiceID: String
    public let voiceRevision: String?
    public let modelRevision: String
    public let isSynthesisReady: Bool
    public let allowedSpeed: Double
    public let callerSeed: Int?

    public init(
        roleID: UUID,
        voiceID: String,
        voiceRevision: String?,
        modelRevision: String,
        isSynthesisReady: Bool = true,
        allowedSpeed: Double = AudiobookLimits.defaultRenderSpeed,
        callerSeed: Int? = nil
    ) {
        self.roleID = roleID
        self.voiceID = voiceID
        self.voiceRevision = voiceRevision
        self.modelRevision = modelRevision
        self.isSynthesisReady = isSynthesisReady
        self.allowedSpeed = allowedSpeed
        self.callerSeed = callerSeed
    }

    public var bindingDigest: String {
        let seedPart = callerSeed.map(String.init) ?? "nil"
        let canonical = "\(roleID.uuidString)|\(voiceID)|\(voiceRevision ?? "<absent>")|\(modelRevision)|\(isSynthesisReady)|\(String(format: "%.3f", allowedSpeed))|\(seedPart)"
        return AudiobookDigest.sha256Hex(Data(canonical.utf8))
    }
}

public enum AudiobookSpeakerAssignment: Codable, Equatable, Hashable, Sendable {
    case assigned(roleID: UUID)
    case unknown(reason: String, candidateRoleIDs: [UUID])

    public var roleID: UUID? {
        if case let .assigned(id) = self { return id }
        return nil
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

public struct AudiobookAnalysisWindow: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let rootWindowID: UUID
    public let bookID: UUID
    public let chapterID: UUID
    public let ordinal: Int
    public let primaryAtomIDs: [UUID]
    public let leadingContextAtomIDs: [UUID]
    public let trailingContextAtomIDs: [UUID]
    public let policyFingerprint: String
    public let configurationDigest: String
    public let generation: Int
    public var isCompleted: Bool

    public init(
        id: UUID = UUID(),
        rootWindowID: UUID? = nil,
        bookID: UUID,
        chapterID: UUID,
        ordinal: Int,
        primaryAtomIDs: [UUID],
        leadingContextAtomIDs: [UUID] = [],
        trailingContextAtomIDs: [UUID] = [],
        policyFingerprint: String,
        configurationDigest: String,
        generation: Int = 1,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.rootWindowID = rootWindowID ?? id
        self.bookID = bookID
        self.chapterID = chapterID
        self.ordinal = ordinal
        self.primaryAtomIDs = primaryAtomIDs
        self.leadingContextAtomIDs = leadingContextAtomIDs
        self.trailingContextAtomIDs = trailingContextAtomIDs
        self.policyFingerprint = policyFingerprint
        self.configurationDigest = configurationDigest
        self.generation = generation
        self.isCompleted = isCompleted
    }
}

public struct AudiobookAnnotation: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let chapterID: UUID
    public let windowID: UUID
    public let atomID: UUID
    public let sourceRange: AudiobookSourceRange
    public var assignment: AudiobookSpeakerAssignment
    public var evidence: String?
    public var userConfirmed: Bool
    public var annotationRevision: Int

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        windowID: UUID,
        atomID: UUID,
        sourceRange: AudiobookSourceRange,
        assignment: AudiobookSpeakerAssignment,
        evidence: String? = nil,
        userConfirmed: Bool = false,
        annotationRevision: Int = 1
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.windowID = windowID
        self.atomID = atomID
        self.sourceRange = sourceRange
        self.assignment = assignment
        self.evidence = evidence
        self.userConfirmed = userConfirmed
        self.annotationRevision = annotationRevision
    }
}

// MARK: - Fragment, Render Candidate, Revision, Bookmark & Export

public struct AudiobookFragment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let chapterID: UUID
    public let ordinal: Int
    public let roleID: UUID
    public let sourceRange: AudiobookSourceRange
    public let atomIDs: [UUID]
    public let localAssignmentDigest: String
    public let voiceBindingDigest: String
    public let policyDigest: String
    public let dependencyDigest: String

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        ordinal: Int,
        roleID: UUID,
        sourceRange: AudiobookSourceRange,
        atomIDs: [UUID],
        localAssignmentDigest: String,
        voiceBindingDigest: String,
        policyDigest: String,
        dependencyDigest: String
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.ordinal = ordinal
        self.roleID = roleID
        self.sourceRange = sourceRange
        self.atomIDs = atomIDs
        self.localAssignmentDigest = localAssignmentDigest
        self.voiceBindingDigest = voiceBindingDigest
        self.policyDigest = policyDigest
        self.dependencyDigest = dependencyDigest
    }
}

public struct AudiobookRenderCandidate: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let chapterID: UUID
    public let fragmentID: UUID
    public let taskID: UUID
    public let generation: Int
    public let relativeAssetPath: String
    public let fileSHA256: String
    public let pcmSHA256: String
    public let frameCount: Int64
    public let sampleRate: Int
    public let dependencyDigest: String
    public let requestID: String?
    public let receiptDigest: String?
    public let recipeSummary: String?
    public let isReceiptVerified: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        fragmentID: UUID,
        taskID: UUID = UUID(),
        generation: Int,
        relativeAssetPath: String,
        fileSHA256: String,
        pcmSHA256: String,
        frameCount: Int64,
        sampleRate: Int = AudiobookLimits.intermediateSampleRate,
        dependencyDigest: String,
        requestID: String? = nil,
        receiptDigest: String? = nil,
        recipeSummary: String? = nil,
        isReceiptVerified: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.fragmentID = fragmentID
        self.taskID = taskID
        self.generation = generation
        self.relativeAssetPath = relativeAssetPath
        self.fileSHA256 = fileSHA256
        self.pcmSHA256 = pcmSHA256
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.dependencyDigest = dependencyDigest
        self.requestID = requestID
        self.receiptDigest = receiptDigest
        self.recipeSummary = recipeSummary
        self.isReceiptVerified = isReceiptVerified
        self.createdAt = createdAt
    }

    public var durationSeconds: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / Double(sampleRate)
    }
}

public struct AudiobookFragmentCandidateBinding: Codable, Equatable, Hashable, Sendable {
    public let fragmentID: UUID
    public let candidateID: UUID
    public let sourceRange: AudiobookSourceRange
    public let dependencyDigest: String

    public init(
        fragmentID: UUID,
        candidateID: UUID,
        sourceRange: AudiobookSourceRange,
        dependencyDigest: String
    ) {
        self.fragmentID = fragmentID
        self.candidateID = candidateID
        self.sourceRange = sourceRange
        self.dependencyDigest = dependencyDigest
    }
}

public struct AudiobookChapterRevision: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let chapterID: UUID
    public let sourceID: UUID
    public let revisionNumber: Int
    public let orderedBindings: [AudiobookFragmentCandidateBinding]
    public let totalFrameCount: Int64
    public let sampleRate: Int
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        sourceID: UUID,
        revisionNumber: Int,
        orderedBindings: [AudiobookFragmentCandidateBinding],
        totalFrameCount: Int64,
        sampleRate: Int = AudiobookLimits.intermediateSampleRate,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.sourceID = sourceID
        self.revisionNumber = revisionNumber
        self.orderedBindings = orderedBindings
        self.totalFrameCount = totalFrameCount
        self.sampleRate = sampleRate
        self.createdAt = createdAt
    }
}

public struct AudiobookProductionRevision: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let sourceID: UUID
    public let chapterRevisionIDsByChapter: [UUID: UUID]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        sourceID: UUID,
        chapterRevisionIDsByChapter: [UUID: UUID],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.sourceID = sourceID
        self.chapterRevisionIDsByChapter = chapterRevisionIDsByChapter
        self.createdAt = createdAt
    }
}

public struct AudiobookBookmark: Codable, Equatable, Hashable, Sendable {
    public let bookID: UUID
    public let chapterID: UUID
    public let chapterRevisionID: UUID
    public let fragmentID: UUID
    public let sourceAnchorRange: AudiobookSourceRange
    public let fragmentOffsetSeconds: TimeInterval
    public let playbackRate: Float
    public let updatedAt: Date

    public init(
        bookID: UUID,
        chapterID: UUID,
        chapterRevisionID: UUID,
        fragmentID: UUID,
        sourceAnchorRange: AudiobookSourceRange,
        fragmentOffsetSeconds: TimeInterval,
        playbackRate: Float = 1.0,
        updatedAt: Date = Date()
    ) {
        self.bookID = bookID
        self.chapterID = chapterID
        self.chapterRevisionID = chapterRevisionID
        self.fragmentID = fragmentID
        self.sourceAnchorRange = sourceAnchorRange
        self.fragmentOffsetSeconds = fragmentOffsetSeconds
        self.playbackRate = playbackRate
        self.updatedAt = updatedAt
    }
}

public struct AudiobookOmittedChapterRecord: Codable, Equatable, Hashable, Sendable {
    public let chapterID: UUID
    public let chapterTitle: String
    public let reason: String

    public init(chapterID: UUID, chapterTitle: String, reason: String) {
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.reason = reason
    }
}

public struct AudiobookExportRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let productionRevisionID: UUID
    public let profileRawValue: String
    public let exportedChapterIDs: [UUID]
    public let omittedChapters: [AudiobookOmittedChapterRecord]
    public let finalFileSHA256: String
    public let totalFrameCount: Int64
    public let durationSeconds: TimeInterval
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        productionRevisionID: UUID,
        profileRawValue: String,
        exportedChapterIDs: [UUID],
        omittedChapters: [AudiobookOmittedChapterRecord] = [],
        finalFileSHA256: String,
        totalFrameCount: Int64,
        durationSeconds: TimeInterval,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.productionRevisionID = productionRevisionID
        self.profileRawValue = profileRawValue
        self.exportedChapterIDs = exportedChapterIDs
        self.omittedChapters = omittedChapters
        self.finalFileSHA256 = finalFileSHA256
        self.totalFrameCount = totalFrameCount
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}

public enum AudiobookDigest {
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Mass Character Casting Stratification & 100+ Voice Asset Catalog

/// 有声书角色四级分层（用于配音优先级、双池隔离与工作台分组展示）。
public enum AudiobookRoleTier: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    /// 旁白（固定独占叙事声线）。
    case narrator
    /// 核心主角（独占声线，推荐定制专属 VoiceDesign 音色）。
    case lead
    /// 常驻配角（跨章或多次发言，默认进入配角行当共享池并享受高优先级防撞色）。
    case supporting
    /// 龙套群像与未开口背景人物（1~2 句台词或仅在叙述中提及，全自动托管）。
    case ensemble

    public var badgeTitle: String {
        switch self {
        case .narrator: return "旁白"
        case .lead: return "主角"
        case .supporting: return "配角"
        case .ensemble: return "群像"
        }
    }

    public var sortPriority: Int {
        switch self {
        case .narrator: return 0
        case .lead: return 1
        case .supporting: return 2
        case .ensemble: return 3
        }
    }
}

/// 面向配角批量托管与 100+ 音色库自动分面归类的六大标准声部行当。
public enum AudiobookVoiceArchetype: String, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case narrator = "narrator"
    case youngMale = "young_male"
    case matureMale = "mature_male"
    case youngFemale = "young_female"
    case matureFemale = "mature_female"
    case neutralEnsemble = "neutral_ensemble"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .narrator: return "沉稳旁白声部"
        case .youngMale: return "青年男声行当"
        case .matureMale: return "中老年男声行当"
        case .youngFemale: return "青年女声行当"
        case .matureFemale: return "成熟女声行当"
        case .neutralEnsemble: return "中性/孩童群像"
        }
    }

    public var shortBadgeTitle: String {
        switch self {
        case .narrator: return "旁白叙事"
        case .youngMale: return "青年男声"
        case .matureMale: return "中老年男声"
        case .youngFemale: return "青年女声"
        case .matureFemale: return "成熟女声"
        case .neutralEnsemble: return "特色群像"
        }
    }

    public var shortCode: String {
        switch self {
        case .narrator: return "nar"
        case .youngMale: return "ym"
        case .matureMale: return "mm"
        case .youngFemale: return "yf"
        case .matureFemale: return "mf"
        case .neutralEnsemble: return "ne"
        }
    }

    public func defaultScenarioInstruction(forBookTitle bookTitle: String) -> String {
        switch self {
        case .narrator:
            return "有声书《\(bookTitle)》沉稳旁白声部：35岁成熟叙事者，中音区胸腔共鸣扎实，声音温润通透、吐字清晰从容，语速平稳舒展，具备文学作品的画面感与纵深感；严禁尖锐童音或机械朗读腔，录音室级干声。"
        case .youngMale:
            return "有声书《\(bookTitle)》青年男声群像行当：24岁成年青年男性，中音偏清朗，声线干净利落、富有朝气与少年锐气，咬字清晰自然，基频稳定在成年男声区间；严禁儿童稚嫩音，录音室级干声。"
        case .matureMale:
            return "有声书《\(bookTitle)》中老年男声群像行当：48岁沉稳中年男性，男中低音浑厚磁性，胸腔共鸣饱满，声线略带岁月沧桑与故事感，语速稳健有力；严禁高亢尖细，录音室级干声。"
        case .youngFemale:
            return "有声书《\(bookTitle)》青年女声群像行当：22岁成年青年女性，女中音偏清亮灵动，音色清澈柔和、富有生命力与表现力，气息自然流畅，基频稳定在成年女声区间；严禁刺耳幼童音，录音室级干声。"
        case .matureFemale:
            return "有声书《\(bookTitle)》成熟女声群像行当：38岁知性成熟女性，女中音温婉醇厚，声线端庄沉静、圆润有质感，语速从容舒缓，富有情感张力与包容感；录音室级干声。"
        case .neutralEnsemble:
            return "有声书《\(bookTitle)》特色与中性群像行当：清澈自然的少年或中性群像声线，中音区干净通透、辨识度高，语气生动自然、吐字轻快明晰，适合演绎书中的少年或特色配角群像；录音室级干声。"
        }
    }

    public func defaultScenarioReferenceText(forBookTitle bookTitle: String) -> String {
        switch self {
        case .narrator:
            return "夜色缓缓笼罩着远方的山峦与渡口，微风拂过寂静的街道，一段尘封已久的往事正随着灯火悄然展开。"
        case .youngMale:
            return "既然已经走到了这一步，无论前路有多少风雨险阻，我们都必须亲自去闯一闯，绝不半途而废！"
        case .matureMale:
            return "这世上的诸多变故，老夫早已见怪不怪了，你们且安心休整，明日天一亮咱们便按计划行事。"
        case .youngFemale:
            return "你看那边的星光多亮啊，只要大家还能并肩站在一起，再难熬的寒冬也一定会过去，迎来温暖的春天。"
        case .matureFemale:
            return "有些事情急不得，越是风浪大的时候，心里越要稳得住，先把眼前的线索理清楚再做决断也不迟。"
        case .neutralEnsemble:
            return "快看那边，远处的船队已经靠岸了，大家赶紧收拾好行囊过去看看，千万别错过了这次难得的机会！"
        }
    }
}

/// 单个角色的全书对白与出场统计投影。
public struct AudiobookRoleDialogueStats: Codable, Equatable, Hashable, Sendable {
    public var roleID: UUID
    public var dialogueAtomCount: Int
    public var dialogueScalarCount: Int = 0
    public var statisticsRevision: String = "dialogue-stats-v2"
    public var speakingChapterIDs: Set<UUID>
    public var tier: AudiobookRoleTier
    public var archetype: AudiobookVoiceArchetype
    /// 与该角色在同一场戏（相邻 6 个正文块内）直接对话的对手角色 ID 集合。
    public var scenePartnerRoleIDs: Set<UUID>
    /// 与该角色在同一章内共同出场的角色 ID 集合。
    public var sameChapterRoleIDs: Set<UUID>

    public init(
        roleID: UUID,
        dialogueAtomCount: Int = 0,
        speakingChapterIDs: Set<UUID> = [],
        tier: AudiobookRoleTier = .ensemble,
        archetype: AudiobookVoiceArchetype = .neutralEnsemble,
        scenePartnerRoleIDs: Set<UUID> = [],
        sameChapterRoleIDs: Set<UUID> = []
    ) {
        self.roleID = roleID
        self.dialogueAtomCount = dialogueAtomCount
        self.speakingChapterIDs = speakingChapterIDs
        self.tier = tier
        self.archetype = archetype
        self.scenePartnerRoleIDs = scenePartnerRoleIDs
        self.sameChapterRoleIDs = sameChapterRoleIDs
    }

    /// 是否需要强制绑定音色才能通过角色确认门禁（零台词仅提及背景人物豁免阻塞）。
    public var requiresVoiceBinding: Bool {
        tier == .narrator || dialogueAtomCount > 0
    }
}

public struct AudiobookVoiceAttribute: Codable, Equatable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case manual, service, textInference, unknown }
    public var value: String
    public var source: Source
    public var confidence: Double
    public init(value: String = "unknown", source: Source = .unknown, confidence: Double = 0) {
        self.value = value
        self.source = source
        self.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
    }
}

/// Independent perceived attributes; unknown is a fact, not a random demographic default.
public struct AudiobookVoiceTraits: Codable, Equatable, Hashable, Sendable {
    public var gender = AudiobookVoiceAttribute()
    public var age = AudiobookVoiceAttribute()
    public var pitch = AudiobookVoiceAttribute()
    public var texture = AudiobookVoiceAttribute()
    public var locale = AudiobookVoiceAttribute()
    public var pacing = AudiobookVoiceAttribute()
    public init() {}
}

public struct AudiobookCastingScene: Equatable, Sendable {
    public var chapterID: UUID
    public var sourceRange: AudiobookSourceRange
    public var isConfirmed: Bool
    public init(chapterID: UUID, sourceRange: AudiobookSourceRange, isConfirmed: Bool = true) {
        self.chapterID = chapterID; self.sourceRange = sourceRange; self.isConfirmed = isConfirmed
    }
}

public enum VoiceCatalogLoadState: String, Codable, Sendable {
    case loading, ready, missing, unreadable, unsupportedSchema
}

/// One immutable read, including preferences; load failures are never an empty success.
public struct VoiceCatalogSnapshot: Equatable, Sendable {
    public let state: VoiceCatalogStore.PersistedState
    public let loadState: VoiceCatalogLoadState
    public let revision: String
    public init(state: VoiceCatalogStore.PersistedState = .init(), loadState: VoiceCatalogLoadState = .ready) {
        self.init(state: state, loadState: loadState, makeRevision: Self.makeRevision)
    }
    init(
        state: VoiceCatalogStore.PersistedState, loadState: VoiceCatalogLoadState,
        makeRevision: @Sendable (VoiceCatalogStore.PersistedState, VoiceCatalogLoadState) -> String
    ) {
        self.state = state
        self.loadState = state.metadataByVoiceID.allSatisfy { $0.key == $0.value.voiceID } ? loadState : .unreadable
        self.revision = makeRevision(state, self.loadState)
    }
    private static func makeRevision(_ state: VoiceCatalogStore.PersistedState, _ loadState: VoiceCatalogLoadState) -> String {
        AudiobookCastingDigest.hash([
            loadState.rawValue,
            AudiobookCastingDigest.hash(state.metadataByVoiceID),
            AudiobookCastingDigest.hash(state.collections.sorted { $0.id.uuidString < $1.id.uuidString }),
            state.preferredCollectionIDByBookID.map { "\($0.key)|\($0.value)" }.sorted().joined(separator: ",")
        ])
    }
    public func permits(_ voice: SafeVoiceEntry, bookID: UUID) -> Bool {
        guard loadState == .ready || loadState == .missing else { return false }
        guard let metadata = state.metadataByVoiceID[voice.id] else {
            return voice.mode == "system" && voice.isSystem == true && voice.isDefault == true
        }
        guard metadata.voiceID == voice.id else { return false }
        guard metadata.lifecycleState == .active else { return false }
        switch metadata.visibilityScope {
        case .unknown: return voice.mode == "system" && voice.isSystem == true && voice.isDefault == true && metadata.creationSource == nil && metadata.originBookID == nil
        case .bookExclusive: return metadata.originBookID == bookID
        case .globalReusable: return true
        }
    }
}

public struct AudiobookRoleVoicePolicy: Codable, Equatable, Hashable, Sendable {
    public enum SharingPolicy: String, Codable, Sendable { case automatic, exclusive, sharedMinor }
    public enum BindingOrigin: String, Codable, Sendable { case manual, acceptedRecommendation, automatic, legacyUnknown }
    public var sharingPolicy: SharingPolicy
    public var bindingOrigin: BindingOrigin
    public var isLocked: Bool
    public init(sharingPolicy: SharingPolicy, bindingOrigin: BindingOrigin = .automatic, isLocked: Bool = false) {
        self.sharingPolicy = sharingPolicy
        self.bindingOrigin = bindingOrigin
        self.isLocked = isLocked
    }
}

public struct AudiobookCastingIssue: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable { case error, warning, info }
    public enum Code: String, Sendable {
        case noEligibleVoices, catalogUnavailable, voiceNotProductionReady, unsupportedRenderParameter
        case bindingReplacementConsentRequired, insufficientVoiceCapacity, lockedBindingConflict, castRevisionChanged, capabilityChanged
        case unresolvedSpeaker, searchBudgetExceeded, voiceIdentityUnknown, voiceScopeUnavailable, sharedSceneRisk, sharedVoiceConsentRequired
    }
    public let code: Code
    public let roleIDs: [UUID]
    public let voiceIDs: [String]
    public let isBlocking: Bool
    public let severity: Severity
    public let nextAction: String
    /// Acknowledgements are bound to the entire proposal, not just the same role pair.
    public var id: UUID { AudiobookCastingDigest.uuid("\(contextDigest)|\(code.rawValue)|\(roleIDs)|\(voiceIDs)") }
    var contextDigest: String = ""
    public init(code: Code, roleIDs: [UUID] = [], voiceIDs: [String] = [], isBlocking: Bool = true, severity: Severity? = nil, nextAction: String) {
        self.code = code
        self.roleIDs = roleIDs.sorted { $0.uuidString < $1.uuidString }
        self.voiceIDs = voiceIDs.sorted()
        self.isBlocking = isBlocking
        self.severity = isBlocking ? .error : (severity ?? .warning)
        self.nextAction = nextAction
    }
}

public struct AudiobookCastingPlan: Equatable, Sendable {
    public let bookID: UUID
    public let localInputDigest: String
    public let snapshot: EffectiveCapabilitySnapshot
    public let catalog: VoiceCatalogSnapshot
    public let expectedCastRevisionID: UUID
    public let proposedBindings: [UUID: AudiobookVoiceBinding]
    public let proposedPolicies: [UUID: AudiobookRoleVoicePolicy]
    public let unresolvedRoleIDs: Set<UUID>
    public let affectedRoleIDs: Set<UUID>
    public internal(set) var affectedFragmentIDs: Set<UUID>
    public let narratorVoiceCount: Int
    public let exclusiveVoiceCount: Int
    public let sharedVoiceCount: Int
    public let eligibleVoiceCount: Int
    public internal(set) var hasUnavoidableSceneConflicts: Bool = false
    public internal(set) var strategy: AudiobookCastingStrategy = .sceneAware
    public internal(set) var evaluatedCandidates: Int = 0
    public internal(set) var scoredCombinations: Int = 0
    var cachedScores = AudiobookCastingScoreCache()
    var undoingRevisionID: UUID?
    var restoringRolePolicies: [UUID: AudiobookCastingPolicySnapshot] = [:]
    var allowsLockedReplacement = false
    var requiresCompleteCast: Bool = true
    var sourceContextDigest: String?
    var rawIssues: [AudiobookCastingIssue]
    public var snapshotID: String { snapshot.snapshotID }
    public var voiceCatalogRevision: String { catalog.revision }
    public var inputDigest: String {
        AudiobookCastingDigest.hash([
            "casting-p1-v1:\(strategy.rawValue)", localInputDigest, sourceContextDigest ?? "<unattached>",
            AudiobookCastingDigest.hash(snapshot), catalog.revision,
            AudiobookCastingDigest.hash(proposedBindings.values.sorted { $0.roleID.uuidString < $1.roleID.uuidString }),
            proposedPolicies.map { "\($0.key)|\($0.value.sharingPolicy)|\($0.value.bindingOrigin)|\($0.value.isLocked)" }.sorted().joined(separator: ",")
        ])
    }
    public var issues: [AudiobookCastingIssue] {
        let digest = inputDigest
        return rawIssues.map { issue in var copy = issue; copy.contextDigest = digest; return copy }
    }
    public var requiredAcknowledgements: Set<UUID> { Set(issues.filter { !$0.isBlocking && $0.severity == .warning }.map(\.id)) }
    public var isApplicable: Bool { unresolvedRoleIDs.isEmpty && !rawIssues.contains(where: \.isBlocking) }
}

/// Canonical unordered input records. JSON preserves field boundaries and missing identity.
enum AudiobookCastingDigest {
    static func hash<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        guard let data = try? encoder.encode(value), let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return AudiobookDigest.sha256Hex(Data("invalid_input".utf8))
        }
        func canonical(_ object: Any) -> Any {
            if let array = object as? [Any] {
                return array.map { item -> (Any, Data) in
                    let normalized = canonical(item)
                    let encoded = (try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
                    return (normalized, encoded)
                }.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map { $0.0 }
            }
            if let dictionary = object as? [String: Any] { return dictionary.mapValues(canonical) }
            return object
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: canonical(object), options: [.sortedKeys, .fragmentsAllowed])) ?? data
        return AudiobookDigest.sha256Hex(encoded)
    }
    static func local(characters: [AudiobookCharacter], annotations: [AudiobookAnnotation], bindings: [UUID: AudiobookVoiceBinding]) -> String {
        hash([hash(characters), hash(annotations), hash(Array(bindings.values))])
    }
    static func uuid(_ value: String) -> UUID {
        let hex = String(AudiobookDigest.sha256Hex(Data(value.utf8)).prefix(32))
        let i = Array(hex)
        return UUID(uuidString: "\(String(i[0..<8]))-\(String(i[8..<12]))-\(String(i[12..<16]))-\(String(i[16..<20]))-\(String(i[20..<32]))")!
    }
}

/// 音色资产的三层可见性作用域（彻底解决单书角色专用音色污染全局列表的问题）。
public enum VoiceAssetScope: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    /// 全局通用音色（系统预置音色、通用自建音色、或从单书晋升入库的精品音色，对所有书籍与演播台可见）。
    case globalReusable = "global_reusable"
    /// 书籍剧组专用音色（在有声书工坊中为特定角色设计生成，默认仅在该书选角池置顶显示，不污染其他书籍与演播台）。
    case bookExclusive = "book_exclusive"
    /// 归档音色（完结项目或低频音色，默认从活跃选角器中隐藏，但保留 ID 供历史工程重合成使用）。
    case unknown = "unknown"

    public var title: String {
        switch self {
        case .globalReusable: return "全局通用"
        case .bookExclusive: return "剧组专用"
        case .unknown: return "归属待确认"
        }
    }
}

/// 音色创建来源分类（用于 100+ 音色库分面检索）。
public enum VoiceAssetLifecycleState: String, Codable, Equatable, Hashable, Sendable { case active, archived }

public enum VoiceCreationSource: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    /// 系统内置标准音色（支持 0.5x~2.0x 连续变速）。
    case systemPreset = "system_preset"
    /// 通过自然语言声学指令生成的定制音色（Voice Design）。
    case voiceDesign = "voice_design"
    /// 通过参考音频克隆的音色（Instant / Zero-Shot Clone）。
    case instantClone = "instant_clone"
    case imported = "imported"
    case unknown = "unknown"

    public var title: String {
        switch self {
        case .systemPreset: return "系统预置"
        case .voiceDesign: return "AI 声学设计"
        case .instantClone: return "参考音频克隆"
        case .imported: return "导入"
        case .unknown: return "来源待确认"
        }
    }
}

/// 单个音色在客户端侧的增强分类与归属元数据（持久化于 Application Support/SpeechRail/voice_catalog_metadata.json）。
public struct VoiceAssetMetadata: Codable, Equatable, Hashable, Sendable {
    public var voiceID: String
    public var visibilityScope: VoiceAssetScope
    public var lifecycleState: VoiceAssetLifecycleState
    public var originBookID: UUID?
    public var originBookTitle: String?
    public var originRoleID: UUID?
    public var originRoleName: String?
    public var archetypeOverride: AudiobookVoiceArchetype?
    public var voiceTraits: AudiobookVoiceTraits?
    public var creationSource: VoiceCreationSource?
    public var isFavorite: Bool
    public var customTags: [String]
    public var collectionIDs: Set<UUID>
    public var createdAt: Date? = Date()
    public var updatedAt: Date

    public init(
        voiceID: String,
        visibilityScope: VoiceAssetScope = .unknown,
        lifecycleState: VoiceAssetLifecycleState = .active,
        originBookID: UUID? = nil,
        originBookTitle: String? = nil,
        originRoleID: UUID? = nil,
        originRoleName: String? = nil,
        archetypeOverride: AudiobookVoiceArchetype? = nil,
        voiceTraits: AudiobookVoiceTraits? = nil,
        creationSource: VoiceCreationSource? = nil,
        isFavorite: Bool = false,
        customTags: [String] = [],
        collectionIDs: Set<UUID> = [],
        updatedAt: Date = Date()
    ) {
        self.voiceID = voiceID
        self.visibilityScope = visibilityScope
        self.lifecycleState = lifecycleState
        self.originBookID = originBookID
        self.originBookTitle = originBookTitle
        self.originRoleID = originRoleID
        self.originRoleName = originRoleName
        self.archetypeOverride = archetypeOverride
        self.voiceTraits = voiceTraits
        self.creationSource = creationSource
        self.isFavorite = isFavorite
        self.customTags = customTags
        self.collectionIDs = collectionIDs
        self.updatedAt = updatedAt
    }
}

/// 自定义剧团音色包 / 合集（例如「古风仙侠剧团包」「现代悬疑主力声优包」）。
public struct VoiceCollection: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var iconSystemName: String
    public var description: String
    public var voiceIDs: Set<String>
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        iconSystemName: String = "waveform.badge.plus",
        description: String = "",
        voiceIDs: Set<String> = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.description = description
        self.voiceIDs = voiceIDs
        self.createdAt = createdAt
    }
}

/// 从明确元数据和描述提取独立属性；没有依据的属性保留 unknown。
public enum VoiceTaxonomyClassifier {
    public static func resolveTraits(for voice: SafeVoiceEntry, metadata: VoiceAssetMetadata? = nil) -> AudiobookVoiceTraits {
        var explicit = metadata?.voiceTraits ?? .init()
        func service(_ value: String) -> AudiobookVoiceAttribute { .init(value: value, source: .service, confidence: 1) }
        if explicit.pitch.source == .unknown, ["low", "middle", "high"].contains(voice.descriptors.pitchBand) {
            explicit.pitch = service(voice.descriptors.pitchBand)
        }
        if explicit.texture.source == .unknown, !["", "unknown"].contains(voice.descriptors.timbreFamily) {
            explicit.texture = service(voice.descriptors.timbreFamily)
        }
        if explicit.pacing.source == .unknown, !["", "unknown"].contains(voice.descriptors.baselinePace) {
            explicit.pacing = service(voice.descriptors.baselinePace)
        }
        if explicit.locale.source == .unknown, let locale = voice.descriptors.locales.first(where: { !["", "unknown"].contains($0) }) {
            explicit.locale = service(locale.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? locale)
        }
        return resolveTraits(description: ([voice.name] + voice.descriptors.styleTags).joined(separator: " "), override: explicit)
    }

    /// 结合音色原始声学字段与本地扩展元数据，确定性推导其六大声部行当。
    public static func resolveTraits(description: String, override manual: AudiobookVoiceTraits? = nil) -> AudiobookVoiceTraits {
        let text = description.lowercased()
        let englishWords = Set(text.split { !$0.isLetter }.map(String.init))
        func any(_ words: [String]) -> Bool {
            words.contains { word in
                if word.unicodeScalars.allSatisfy({ $0.isASCII }) {
                    return word.contains(" ") ? text.contains(word) : englishWords.contains(word)
                }
                return text.contains(word)
            }
        }
        func attribute(_ value: String?) -> AudiobookVoiceAttribute {
            value.map { .init(value: $0, source: .textInference, confidence: 0.7) } ?? .init()
        }
        var result = AudiobookVoiceTraits()
        let female = any(["female", "woman", "girl", "女", "奶奶", "婆婆"])
        let male = any(["male", "man", "boy", "男", "大叔", "爷爷"])
        result.gender = attribute(any(["neutral", "中性"]) ? "neutral" : (female != male ? (female ? "female" : "male") : nil))
        result.age = attribute(any(["child", "kid", "童", "孩"]) ? "child" :
            (any(["elder", "elderly", "senior", "老年", "奶奶", "爷爷", "沧桑"]) ? "elder" :
            (any(["middle", "mature", "中年", "成熟", "大叔"]) ? "middleAged" :
            (any(["young", "青年", "少年", "少女"]) ? "young" : nil))))
        result.pitch = attribute(any(["low", "低音", "低沉"]) ? "low" : (any(["high", "高音"]) ? "high" : (any(["middle pitch", "中音"]) ? "middle" : nil)))
        let textures = ["柔和", "醇厚", "沙哑", "清澈", "清脆", "warm", "hoarse", "bright"].filter { any([$0]) }
        result.texture = attribute(textures.isEmpty ? nil : textures.sorted().joined(separator: ","))
        result.locale = attribute(any(["中文", "普通话", "mandarin", "zh"]) ? "zh" : (any(["english", "英语", "en"]) ? "en" : nil))
        result.pacing = attribute(any(["清晰", "clear"]) ? "clear" : (any(["舒缓", "slow"]) ? "slow" : (any(["轻快", "fast"]) ? "fast" : nil)))
        if let manual {
            if manual.gender.source == .manual || manual.gender.source == .service { result.gender = manual.gender }
            if manual.age.source == .manual || manual.age.source == .service { result.age = manual.age }
            if manual.pitch.source == .manual || manual.pitch.source == .service { result.pitch = manual.pitch }
            if manual.texture.source == .manual || manual.texture.source == .service { result.texture = manual.texture }
            if manual.locale.source == .manual || manual.locale.source == .service { result.locale = manual.locale }
            if manual.pacing.source == .manual || manual.pacing.source == .service { result.pacing = manual.pacing }
        }
        return result
    }

    public static func resolveArchetype(
        voiceID: String = "", gender: String? = nil, age: String? = nil, traits: [String] = [],
        description: String? = nil, label: String, metadata: VoiceAssetMetadata? = nil
    ) -> AudiobookVoiceArchetype {
        if let override = metadata?.archetypeOverride { return override }
        let text = ([gender ?? "", age ?? "", description ?? "", label] + traits).joined(separator: " ")
        let profile = resolveTraits(description: text, override: metadata?.voiceTraits)
        if text.contains("旁白") || text.contains("叙事") || text.lowercased().contains("narrator") { return .narrator }
        if profile.age.value == "child" { return .neutralEnsemble }
        let mature = ["middleAged", "elder"].contains(profile.age.value)
        switch profile.gender.value {
        case "male": return mature ? .matureMale : .youngMale
        case "female": return mature ? .matureFemale : .youngFemale
        default: return .neutralEnsemble
        }
    }

    public static func resolveCreationSource(
        mode: String,
        description: String?,
        metadata: VoiceAssetMetadata? = nil
    ) -> VoiceCreationSource {
        if let explicit = metadata?.creationSource {
            return explicit
        }
        let lowerMode = mode.lowercased()
        if lowerMode == "system" || lowerMode == "preset" {
            return .systemPreset
        }
        return .unknown
    }

    /// 根据角色人设推导角色的声部行当。
    public static func inferCharacterArchetype(
        isNarrator: Bool,
        displayName: String,
        ageGenderAnchor: String,
        voiceQualities: String = ""
    ) -> AudiobookVoiceArchetype {
        if isNarrator {
            return .narrator
        }
        return resolveArchetype(
            gender: ageGenderAnchor,
            age: ageGenderAnchor,
            traits: [voiceQualities],
            description: ageGenderAnchor,
            label: displayName,
            metadata: nil
        )
    }
}

/// 持久化管理 100+ 音色的作用域（全局通用 / 书籍专用 / 归档）、星标与剧团合集。
public enum VoiceCatalogError: LocalizedError, Equatable, Sendable {
    case unavailable, unknownVoice, scopeConfirmationRequired, revisionChanged, ownershipConflict
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "声音目录暂时无法保存，请检查目录或恢复副本后重试。"
        case .unknownVoice: return "找不到此声音的归属记录。"
        case .scopeConfirmationRequired: return "请先确认此声音的可用范围，再恢复使用。"
        case .revisionChanged: return "声音目录已变化，请刷新后重试。"
        case .ownershipConflict: return "此声音已有其他归属，原记录已保留，请重新确认。"
        }
    }
}

public actor VoiceCatalogStore {
    public static let shared = VoiceCatalogStore(storageURL: defaultStorageURL())
    public static let didChange = Notification.Name("SpeechRail.voiceCatalog.didChange")
    public struct PersistedState: Codable, Equatable, Sendable {
        public var metadataByVoiceID: [String: VoiceAssetMetadata]
        public var collections: [VoiceCollection]
        public var preferredCollectionIDByBookID: [UUID: UUID]
        public init(metadataByVoiceID: [String: VoiceAssetMetadata] = [:], collections: [VoiceCollection] = [], preferredCollectionIDByBookID: [UUID: UUID] = [:]) {
            self.metadataByVoiceID = metadataByVoiceID; self.collections = collections; self.preferredCollectionIDByBookID = preferredCollectionIDByBookID
        }
    }
    nonisolated let storageURL: URL?
    private let writeAtomically: @Sendable (Data, URL) throws -> Void
    private let readContents: @Sendable (URL) throws -> Data
    private let metrics: AppPerformanceMetrics
    private var cachedSnapshot = VoiceCatalogSnapshot(loadState: .loading)
    private var state = PersistedState()
    private var loadState: VoiceCatalogLoadState = .loading
    private var revision = 0
    private var originalDocument: [String: Any] = [:]
    private var needsMigration = false
    public static func defaultStorageURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SpeechRail", isDirectory: true).appendingPathComponent("voice_catalog_metadata.json")
    }
    public init(storageURL: URL? = nil) {
        self.init(storageURL: storageURL, readContents: { try Data(contentsOf: $0) })
    }
    init(
        storageURL: URL?,
        readContents: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
        writeAtomically: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
        metrics: AppPerformanceMetrics = .shared
    ) {
        self.storageURL = storageURL
        self.readContents = readContents
        self.writeAtomically = writeAtomically
        self.metrics = metrics
        if storageURL == nil {
            loadState = .ready
            cachedSnapshot = .init(state: state, loadState: .ready)
        }
    }
    private func reloadFromDisk() {
        guard let storageURL else { return }
        defer { cachedSnapshot = .init(state: state, loadState: loadState) }
        do {
            let data = try readContents(storageURL)
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoiceCatalogError.unavailable }
            let version = (document["schemaVersion"] ?? document["schema_version"]) as? Int
            if let version, version != 2 { loadState = .unsupportedSchema; return }
            var content = version == nil ? document : (document["state"] as? [String: Any] ?? [:])
            if version == nil {
                guard var metadata = content["metadataByVoiceID"] as? [String: [String: Any]] else { throw VoiceCatalogError.unavailable }
                for (id, var record) in metadata {
                    let oldScope = record.removeValue(forKey: "scope") as? String
                    if oldScope == "archived" {
                        record["visibilityScope"] = "unknown"; record["lifecycleState"] = "archived"
                    } else {
                        record["visibilityScope"] = oldScope ?? record["visibilityScope"] ?? "unknown"
                        record["lifecycleState"] = record["lifecycleState"] ?? "active"
                    }
                    metadata[id] = record
                }
                content["metadataByVoiceID"] = metadata
            }
            let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONSerialization.data(withJSONObject: content))
            guard decoded.metadataByVoiceID.allSatisfy({ $0.key == $0.value.voiceID }) else { throw VoiceCatalogError.unavailable }
            state = decoded; revision = document["revision"] as? Int ?? 0
            originalDocument = document; needsMigration = version == nil; loadState = .ready
        } catch {
            let error = error as NSError
            loadState = error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError ? .missing : .unreadable
            if loadState == .missing {
                state = .init(); revision = 0; originalDocument = [:]; needsMigration = false
            }
        }
    }
    /// Explicit I/O boundary. Rendering uses VoiceCatalogModel's immutable snapshot.
    public func refresh() -> VoiceCatalogSnapshot {
        do {
            return try metrics.measure(.catalogRefresh) {
                reloadFromDisk()
                guard loadState == .ready || loadState == .missing else { throw VoiceCatalogError.unavailable }
                return cachedSnapshot
            }
        } catch { return cachedSnapshot }
    }
    public func snapshot() -> VoiceCatalogSnapshot { cachedSnapshot }
    public var metadataByVoiceID: [String: VoiceAssetMetadata] { snapshot().state.metadataByVoiceID }
    public var collections: [VoiceCollection] { snapshot().state.collections }
    public func metadata(for voiceID: String) -> VoiceAssetMetadata? { snapshot().state.metadataByVoiceID[voiceID] }
    public func preferredCollectionID(for bookID: UUID) -> UUID? { snapshot().state.preferredCollectionIDByBookID[bookID] }

    /// Publish only after atomic persistence. One process serializes writes; no cross-store transaction is implied.
    private func mutate<T>(_ body: (inout PersistedState) throws -> T) throws -> T {
        do {
            _ = refresh()
            guard loadState == .ready || loadState == .missing else { throw VoiceCatalogError.unavailable }
            var proposed = state
            let result = try body(&proposed)
            guard proposed.metadataByVoiceID.allSatisfy({ $0.key == $0.value.voiceID }) else { throw VoiceCatalogError.unavailable }
            let changed = proposed != state || needsMigration
            if changed {
                if let url = storageURL {
                    let encoded = try JSONEncoder().encode(proposed)
                    var content = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                    let oldContent = (originalDocument["state"] as? [String: Any]) ?? originalDocument
                    // Preserve unknown top-level and record fields while allowing known optional fields to be cleared.
                    let known = Set(["voiceID", "scope", "visibilityScope", "lifecycleState", "originBookID", "originBookTitle", "originRoleID", "originRoleName", "archetypeOverride", "voiceTraits", "creationSource", "isFavorite", "customTags", "collectionIDs", "createdAt", "updatedAt"])
                    let oldMeta = oldContent["metadataByVoiceID"] as? [String: [String: Any]] ?? [:]
                    var newMeta = content["metadataByVoiceID"] as? [String: [String: Any]] ?? [:]
                    func retainingNestedFields(_ new: Any, previous: Any?) -> Any {
                        guard let proposed = new as? [String: Any], var saved = previous as? [String: Any] else { return new }
                        for (key, value) in proposed { saved[key] = retainingNestedFields(value, previous: saved[key]) }
                        return saved
                    }
                    for (id, record) in newMeta {
                        var preserved = oldMeta[id]?.filter { !known.contains($0.key) } ?? [:]
                        preserved.merge(record) { _, new in new }
                        if let traits = record["voiceTraits"] { preserved["voiceTraits"] = retainingNestedFields(traits, previous: oldMeta[id]?["voiceTraits"]) }
                        newMeta[id] = preserved
                    }
                    for (key, value) in oldContent where !["metadataByVoiceID", "collections", "preferredCollectionIDByBookID"].contains(key) { content[key] = value }
                    let oldCollections = oldContent["collections"] as? [[String: Any]] ?? []
                    var newCollections = content["collections"] as? [[String: Any]] ?? []
                    let collectionKeys = Set(["id", "name", "iconSystemName", "description", "voiceIDs", "createdAt"])
                    for index in newCollections.indices {
                        let id = newCollections[index]["id"] as? String
                        var preserved = oldCollections.first { ($0["id"] as? String) == id }?.filter { !collectionKeys.contains($0.key) } ?? [:]
                        preserved.merge(newCollections[index]) { _, new in new }; newCollections[index] = preserved
                    }
                    content["collections"] = newCollections
                    content["metadataByVoiceID"] = newMeta
                    var envelope = originalDocument.filter { !["schema_version", "metadataByVoiceID", "collections", "preferredCollectionIDByBookID"].contains($0.key) }
                    envelope["schemaVersion"] = 2; envelope["revision"] = revision + 1; envelope["state"] = content
                    let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if needsMigration, FileManager.default.fileExists(atPath: url.path) {
                        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".legacy." + UUID().uuidString + ".backup")
                        try FileManager.default.copyItem(at: url, to: backup)
                    }
                    try writeAtomically(data, url)
                    originalDocument = envelope
                }
                state = proposed; revision += 1; needsMigration = false; loadState = .ready
                cachedSnapshot = .init(state: state, loadState: .ready)
            }
            if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
            return result
        } catch { throw error }
    }
    public func setPreferredCollectionID(_ collectionID: UUID?, for bookID: UUID) throws {
        try mutate { state in
            if let collectionID, !state.collections.contains(where: { $0.id == collectionID }) { throw VoiceCatalogError.unknownVoice }
            state.preferredCollectionIDByBookID[bookID] = collectionID
        }
    }
    @discardableResult
    public func registerBookExclusiveVoice(voiceID: String, bookID: UUID, bookTitle: String?, roleID: UUID?, roleName: String?, archetype: AudiobookVoiceArchetype?, creationSource: VoiceCreationSource = .voiceDesign) throws -> VoiceAssetMetadata {
        try mutate { state in
            if let old = state.metadataByVoiceID[voiceID] {
                guard old.originBookID == bookID, old.originRoleID == roleID, old.creationSource == creationSource else { throw VoiceCatalogError.ownershipConflict }
                return old // Recovery must preserve later promotion, archival, favorites and collections.
            }
            let meta = VoiceAssetMetadata(voiceID: voiceID, visibilityScope: .bookExclusive, originBookID: bookID,
                originBookTitle: bookTitle, originRoleID: roleID, originRoleName: roleName, archetypeOverride: archetype, creationSource: creationSource)
            state.metadataByVoiceID[voiceID] = meta; return meta
        }
    }
    @discardableResult
    public func registerArchetypeEnsembleVoice(voiceID: String, bookID: UUID, bookTitle: String?, archetype: AudiobookVoiceArchetype) throws -> VoiceAssetMetadata {
        try registerBookExclusiveVoice(voiceID: voiceID, bookID: bookID, bookTitle: bookTitle, roleID: nil, roleName: nil, archetype: archetype, creationSource: .voiceDesign)
    }
    @discardableResult
    public func registerGlobalVoice(voiceID: String, creationSource: VoiceCreationSource) throws -> VoiceAssetMetadata {
        try mutate { state in
            var meta = state.metadataByVoiceID[voiceID] ?? .init(voiceID: voiceID)
            guard meta.originBookID == nil, meta.visibilityScope != .bookExclusive,
                  meta.creationSource == nil || meta.creationSource == .unknown || meta.creationSource == creationSource else {
                throw VoiceCatalogError.ownershipConflict
            }
            if meta.visibilityScope != .globalReusable || meta.creationSource != creationSource {
                meta.visibilityScope = .globalReusable; meta.creationSource = creationSource; meta.updatedAt = Date()
                state.metadataByVoiceID[voiceID] = meta
            }
            return meta
        }
    }
    @discardableResult
    public func promoteToGlobalReusable(voiceID: String) throws -> VoiceAssetMetadata {
        try mutate { state in
            var meta = state.metadataByVoiceID[voiceID] ?? .init(voiceID: voiceID)
            meta.visibilityScope = .globalReusable; meta.updatedAt = Date(); state.metadataByVoiceID[voiceID] = meta; return meta
        }
    }
    public func archiveVoices(voiceIDs: Set<String>) throws {
        try mutate { state in
            for id in voiceIDs {
                var meta = state.metadataByVoiceID[id] ?? .init(voiceID: id)
                meta.lifecycleState = .archived; meta.updatedAt = Date(); state.metadataByVoiceID[id] = meta
            }
        }
    }
    public func unarchiveVoices(voiceIDs: Set<String>) throws {
        try mutate { state in
            for id in voiceIDs {
                guard var meta = state.metadataByVoiceID[id] else { throw VoiceCatalogError.unknownVoice }
                guard meta.visibilityScope != .unknown, meta.visibilityScope != .bookExclusive || meta.originBookID != nil else { throw VoiceCatalogError.scopeConfirmationRequired }
                meta.lifecycleState = .active; meta.updatedAt = Date(); state.metadataByVoiceID[id] = meta
            }
        }
    }
    public func archiveBookExclusiveVoices(bookID: UUID) throws {
        try mutate { state in
            for (id, var metadata) in state.metadataByVoiceID
            where metadata.originBookID == bookID && metadata.visibilityScope == .bookExclusive {
                metadata.lifecycleState = .archived
                metadata.updatedAt = Date()
                state.metadataByVoiceID[id] = metadata
            }
        }
    }
    @discardableResult
    public func toggleFavorite(voiceID: String) throws -> Bool {
        try mutate { state in
            var meta = state.metadataByVoiceID[voiceID] ?? .init(voiceID: voiceID)
            meta.isFavorite.toggle(); meta.updatedAt = Date(); state.metadataByVoiceID[voiceID] = meta; return meta.isFavorite
        }
    }
    public func setArchetypeOverride(_ archetype: AudiobookVoiceArchetype?, for voiceID: String) throws {
        try mutate { state in
            var meta = state.metadataByVoiceID[voiceID] ?? .init(voiceID: voiceID)
            meta.archetypeOverride = archetype; meta.updatedAt = Date(); state.metadataByVoiceID[voiceID] = meta
        }
    }
    public func setVoiceTraits(_ traits: AudiobookVoiceTraits, for voiceID: String) throws {
        try mutate { state in
            var meta = state.metadataByVoiceID[voiceID] ?? .init(voiceID: voiceID)
            meta.voiceTraits = traits; meta.updatedAt = Date(); state.metadataByVoiceID[voiceID] = meta
        }
    }
    @discardableResult
    public func createCollection(name: String, description: String = "", voiceIDs: Set<String> = []) throws -> VoiceCollection {
        try mutate { state in
            let collection = VoiceCollection(name: name, description: description, voiceIDs: voiceIDs)
            state.collections.append(collection)
            for id in voiceIDs { var meta = state.metadataByVoiceID[id] ?? .init(voiceID: id); meta.collectionIDs.insert(collection.id); state.metadataByVoiceID[id] = meta }
            return collection
        }
    }
    public func addVoices(_ voiceIDs: Set<String>, toCollection collectionID: UUID) throws {
        try mutate { state in
            guard let index = state.collections.firstIndex(where: { $0.id == collectionID }) else { throw VoiceCatalogError.unknownVoice }
            state.collections[index].voiceIDs.formUnion(voiceIDs)
            for id in voiceIDs { var meta = state.metadataByVoiceID[id] ?? .init(voiceID: id); meta.collectionIDs.insert(collectionID); state.metadataByVoiceID[id] = meta }
        }
    }
    public func isVoiceActiveForBook(voiceID: String, currentBookID: UUID?) -> Bool {
        cachedSnapshot.isVoiceActiveForBook(voiceID: voiceID, currentBookID: currentBookID)
    }
}


public enum AudiobookRegistrationCrashStage: String, CaseIterable, Sendable {
    case afterIntentRegistered, afterCatalogPersisted, afterCatalogStage, afterBindingCommitted
}

/// Bounded metadata only: no manuscript, prompt, reference text or audio enters the journal.
public struct AudiobookVoiceRegistrationIntent: Codable, Equatable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable { case registered, catalogPersisted, bindingCommitted, completed, needsReview }
    public let id: UUID
    public let bookID: UUID
    public let roleID: UUID?
    public let voiceID: String
    public let bookTitle: String?
    public let roleName: String?
    public let archetype: AudiobookVoiceArchetype?
    public let creationSource: VoiceCreationSource
    public let binding: AudiobookVoiceBinding?
    public let expectedCastRevisionID: UUID
    public let expectedVoiceSetDigest: String
    public let expectedCatalogRevision: String
    public let onlyIfUnbound: Bool
    public var phase: Phase
    public var targetMetadataDigest: String {
        AudiobookCastingDigest.hash([bookID.uuidString, roleID?.uuidString ?? "", voiceID, creationSource.rawValue, archetype?.rawValue ?? ""])
    }
    public var contentDigest: String {
        AudiobookCastingDigest.hash([targetMetadataDigest, expectedCastRevisionID.uuidString, expectedVoiceSetDigest,
            binding?.bindingDigest ?? "catalog-only", String(onlyIfUnbound)])
    }
}


struct AudiobookCastingPolicySnapshot: Codable, Equatable, Sendable {
    let roleID: UUID
    let policy: AudiobookRoleVoicePolicy?
    let allowSharedMinorVoice: Bool
}
struct AudiobookCastingUndoRecord: Codable, Equatable, Sendable {
    let id: UUID
    let bookID: UUID
    let previousBindings: [UUID: AudiobookVoiceBinding]
    let previousPolicies: [AudiobookCastingPolicySnapshot]
    let affectedRoleIDs: Set<UUID>
    let afterDigest: String
}
public struct AudiobookCastingRecommendation: Equatable, Sendable {
    public let planDigest: String
    public let isApplicable: Bool
    public let affectedRoleIDs: Set<UUID>
    public let affectedFragmentIDs: Set<UUID>
    public let reasonsByRoleID: [UUID: [String]]
    public let recoveryActions: [String]
    public init(plan: AudiobookCastingPlan) {
        planDigest = plan.inputDigest; isApplicable = plan.isApplicable
        affectedRoleIDs = plan.affectedRoleIDs; affectedFragmentIDs = plan.affectedFragmentIDs
        reasonsByRoleID = Dictionary(uniqueKeysWithValues: plan.affectedRoleIDs.map { role in
            let policy = plan.proposedPolicies[role]
            return (role, [policy?.sharingPolicy == .exclusive ? "为此角色单独保留声音" : "按同场关系分配共用声音", "符合本书可用范围和制作条件"])
        })
        recoveryActions = Array(Set(plan.issues.filter { $0.isBlocking || $0.severity == .warning }.map(\.nextAction))).sorted()
    }
}
public struct AudiobookCastingAudition: Equatable, Sendable {
    public enum Kind: String, Sendable { case sameTextComparison, dialogueComparison }
    public struct Item: Equatable, Sendable {
        public let roleID: UUID
        public let voiceID: String
        public let sourceRange: AudiobookSourceRange
        public let text: String
        public let binding: AudiobookVoiceBinding
    }
    public let kind: Kind
    public let items: [Item]
    public let planDigest: String
}


public extension VoiceCatalogSnapshot {
    func isVoiceActiveForBook(voiceID: String, currentBookID: UUID?) -> Bool {
        guard loadState == .ready || loadState == .missing,
              let metadata = state.metadataByVoiceID[voiceID], metadata.lifecycleState == .active else { return false }
        return metadata.visibilityScope == .globalReusable
            || (metadata.visibilityScope == .bookExclusive && currentBookID != nil && metadata.originBookID == currentBookID)
    }

    func permitsSurface(_ voice: CreatorVoice, bookID: UUID?) -> Bool {
        permitsSurface(voiceID: voice.id,
            isDefaultSystemPreset: voice.mode == "system" && voice.isSystem && voice.isDefault, bookID: bookID)
    }

    func permitsSurface(_ voice: SafeVoiceEntry, bookID: UUID?) -> Bool {
        permitsSurface(voiceID: voice.id,
            isDefaultSystemPreset: voice.mode == "system" && voice.isSystem == true && voice.isDefault == true, bookID: bookID)
    }

    private func permitsSurface(voiceID: String, isDefaultSystemPreset: Bool, bookID: UUID?) -> Bool {
        guard loadState == .ready || loadState == .missing else { return false }
        guard let meta = state.metadataByVoiceID[voiceID] else { return isDefaultSystemPreset }
        guard meta.voiceID == voiceID, meta.lifecycleState == .active else { return false }
        if meta.visibilityScope == .unknown { return isDefaultSystemPreset && meta.creationSource == nil && meta.originBookID == nil }
        return meta.visibilityScope == .globalReusable || (meta.visibilityScope == .bookExclusive && bookID != nil && meta.originBookID == bookID)
    }
}
