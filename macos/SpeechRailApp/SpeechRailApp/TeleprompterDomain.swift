import CryptoKit
import Foundation

public enum TeleprompterTextError: Error, Equatable, LocalizedError, Sendable {
    case emptySource
    case invalidSourceRange
    case invalidAnalysis
    case promptConstructionFailed
    /// The session is mid-gesture — a live stage, a pending stop, a prepare or
    /// tighten in flight. Refusing is correct; refusing *silently* is not, so
    /// this is a thrown, user-facing reason rather than a bare `return`.
    case sessionBusy

    public var errorDescription: String? {
        switch self {
        case .emptySource:
            "请先输入稿件内容"
        case .invalidSourceRange:
            "整理结果和原稿对不上"
        case .invalidAnalysis:
            "AI 返回的整理结果无法使用"
        case .promptConstructionFailed:
            "没能准备好 AI 整理请求"
        case .sessionBusy:
            "现在不能切换稿件：提词窗口还开着，或上一步还没收尾。先关掉提词窗口再试。"
        }
    }
}

/// Failures that prevent a stage from owning or retiring its reading session.
public enum TeleprompterStageOpenError: Error, Equatable, LocalizedError, Sendable {
    case busy
    case closing

    public var errorDescription: String? {
        switch self {
        case .busy:
            "提词器正在完成其他操作，请稍后再打开。"
        case .closing:
            "提词器正在关闭并释放语音资源，请稍后再打开。"
        }
    }
}

/// AI 整理前向用户说明的数据流边界。
///
/// 文案不包含 endpoint、密钥或 provider 的实现细节，避免把敏感配置带入界面或持久化稿件。
public enum TeleprompterAIDataFlowDisclosure {
    /// 旧版本的全局确认键保留但不复用；新确认按实际 endpoint/model 作用域保存。
    public static let acknowledgementDefaultsKey =
        "speechrail.teleprompter.aiDataFlowAcknowledged.v1"
    public static let title = "整理稿件前请确认"
    public static let inlineMessage =
        "只有点击 AI 整理或朗读标注时，选中的稿件文字才会发给 AI 服务；跟读时不会调用 AI。"
    public static let message = """
        点击「允许发送并整理」后，SpeechRail 会把本次选中的原稿文字，以及目标时长、朗读节奏和表达方式，发送给设置中的 AI 服务，用来整理为适合朗读的候选稿，并检查相邻段落的衔接。

        AI 只生成候选稿，不会自动覆盖原稿；你可以逐组查看原文对照、修改、保留原文、仅作提示或跳过。确认后，朗读标注仍是可选步骤。

        不会发送麦克风、摄像头或直播画面。跟读和直播时也不会调用 AI。

        这个服务可能在本机，也可能在网络上；它是否记录或保存内容，由服务方的规则决定。
        """

    /// 不把 endpoint 原文写进 UserDefaults key；配置变化后必须重新确认数据流。
    public static func acknowledgementDefaultsKey(for configuration: LLMConfiguration) -> String {
        let material = configuration.normalizedBaseURL
            + "\u{0}"
            + configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(material.utf8))
        let fingerprint = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "speechrail.teleprompter.aiDataFlowAcknowledged.v2.\(fingerprint)"
    }
}

/// 「按时长精简」是唯一被授权删掉正文内容的加工方式，因此它自己带一段确认，
/// 不复用保真整理的确认文案——那段措辞承诺的是「不会删」。
public enum TeleprompterCondenseDisclosure {
    public static let title = "按时长精简会删掉内容"
    public static let message = """
        精简会把原稿压缩到接近你设定的目标时长，代价是真的会少讲一些内容。这和「整理朗读稿」不同：整理只改表达，不会删信息。

        删掉的每一段都会单独列出来，写明原文是什么，由你逐条决定「确认删除」还是「保留原文」。确认之前，原稿和已确认的版本都不会被覆盖。

        如果时长和内容冲突，SpeechRail 会直接告诉你冲突在哪，不会靠放慢语速假装达标。

        点击「确认精简」后，选中的稿件文字会发送给设置中的 AI 服务；不会发送麦克风、摄像头或直播画面。
        """
}

/// 提词器复核页的用户语言。
///
/// 这里集中维护默认路径上的文案，避免把内部数据模型（例如来源组、block）直接暴露给用户。
/// 高级编辑动作仍然存在，但通过明确的渐进式披露入口进入。
public enum TeleprompterReviewCopy {
    public static let successTitle = "AI 已完成整理"
    public static let successMessage = "已经生成一份适合跟读的稿件。原稿未被覆盖，确认后才会用于跟读。"
    public static let readingTitle = "整理后的朗读稿"
    public static let readingSubtitle = "先浏览并按需修改；确认后，这份稿件才会用于跟读。"
    public static let compareSourceLabel = "对照原稿"
    public static let advancedEditLabel = "编辑本段"
    public static let acceptAction = "确认并使用这份稿件"
    public static let tightenAction = "让表达更简洁"
    public static let trialAction = "先试读"
    public static let discardAction = "放弃这次整理"

    public static func blockTitle(ordinal: Int) -> String {
        "第 \(max(0, ordinal) + 1) 段"
    }
}

public struct TeleprompterSourceRange: Codable, Hashable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public func isValid(in sourceText: String) -> Bool {
        start >= 0 && end > start && end <= sourceText.utf16.count
    }
}

public typealias TeleprompterPace = TeleprompterTimingPolicy.Pace

public enum TeleprompterReviewIssue: String, Codable, Sendable, CaseIterable {
    case missingContext = "missing_context"
    case formatAmbiguity = "format_ambiguity"
    case readingChoice = "reading_choice"
    case uncertainMeaning = "uncertain_meaning"
    case nonspokenContent = "nonspoken_content"
    case subjectValueChanged = "subject_value_changed"
    case conditionRemoved = "condition_removed"
    case negationChanged = "negation_changed"
    case comparisonChanged = "comparison_changed"
    case certaintyChanged = "certainty_changed"
    /// A passage the lossy condense operation proposes to drop. Distinct from
    /// `nonspokenContent`: this content was meant to be spoken.
    case contentRemoved = "content_removed"

    public var title: String {
        switch self {
        case .missingContext: "指代缺失"
        case .formatAmbiguity: "格式歧义"
        case .readingChoice: "读法选择"
        case .uncertainMeaning: "含义存疑"
        case .nonspokenContent: "建议略过"
        case .subjectValueChanged: "主体与数值关系变化"
        case .conditionRemoved: "限定条件变化"
        case .negationChanged: "否定或禁止含义变化"
        case .comparisonChanged: "比较范围变化"
        case .certaintyChanged: "确定程度变化"
        case .contentRemoved: "这一段将被删除"
        }
    }

    public var detail: String {
        switch self {
        case .missingContext: "原文存在未指明的代词或前文依赖，请核对是否需要补足主语。"
        case .formatAmbiguity: "原文包含代码、表格或特殊符号，AI 提出了转述建议，请确认表达方式。"
        case .readingChoice: "存在多种读法（如按字读或按意译读），请选择你希望的读法。"
        case .uncertainMeaning: "原文含义模糊或存在歧义，未做臆测，请确认正文。"
        case .nonspokenContent: "模型建议不朗读此项（如版权声明、未闭合标记或纯排版内容），由你决定是否跳过。"
        case .subjectValueChanged: "主体与数值的对应关系发生变化，请确认没有互换或错配。"
        case .conditionRemoved: "原文中的时间、范围或前提条件发生变化，请确认是否保留。"
        case .negationChanged: "否定、禁止或无边界的含义可能发生变化，请核对。"
        case .comparisonChanged: "上限、下限、范围或相等关系发生变化，请确认。"
        case .certaintyChanged: "可能、预计、必须等确定程度发生变化，请确认。"
        case .contentRemoved: "精简建议不讲这一段，删除后就不会出现在朗读稿里。保留请选择“保留原文”。"
        }
    }
}

public enum TeleprompterReviewAction: String, Codable, Sendable {
    case accept      // 采用建议
    case edit        // 修改
    case keepSource  // 保留原文
    case convertToCue // 仅作提示
    case skip        // 跳过
}

public struct TeleprompterReviewItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let blockID: String
    public let issue: TeleprompterReviewIssue
    public var suggestedText: String
    public var sourceSnippet: String
    public var resolvedAction: TeleprompterReviewAction?

    public init(
        id: String = UUID().uuidString,
        blockID: String,
        issue: TeleprompterReviewIssue,
        suggestedText: String,
        sourceSnippet: String,
        resolvedAction: TeleprompterReviewAction? = nil
    ) {
        self.id = id
        self.blockID = blockID
        self.issue = issue
        self.suggestedText = suggestedText
        self.sourceSnippet = sourceSnippet
        self.resolvedAction = resolvedAction
    }

    public var isResolved: Bool {
        resolvedAction != nil
    }
}

public enum TeleprompterBlockDisposition: String, Codable, Sendable {
    case speak
    case cue
    case skip
    case unresolved
}

public enum TeleprompterBlockOrigin: String, Codable, Sendable {
    case ai
    case deterministic
    case user
}

public struct TeleprompterReadingBlock: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var ordinal: Int
    public var sourceRange: TeleprompterSourceRange
    public var text: String
    public var rawSourceText: String
    public var disposition: TeleprompterBlockDisposition
    public var origin: TeleprompterBlockOrigin
    public var reviewIssues: [TeleprompterReviewIssue]
    public var budgetSeconds: Double

    public init(
        id: String,
        ordinal: Int,
        sourceRange: TeleprompterSourceRange,
        text: String,
        rawSourceText: String = "",
        disposition: TeleprompterBlockDisposition = .speak,
        origin: TeleprompterBlockOrigin = .ai,
        reviewIssues: [TeleprompterReviewIssue] = [],
        budgetSeconds: Double = 0
    ) {
        self.id = id
        self.ordinal = ordinal
        self.sourceRange = sourceRange
        self.text = text
        self.rawSourceText = rawSourceText
        self.disposition = disposition
        self.origin = origin
        self.reviewIssues = reviewIssues
        self.budgetSeconds = budgetSeconds
    }
}

public struct TeleprompterContentSelection: Codable, Equatable, Sendable {
    public var totalParagraphCount: Int
    public var selectedParagraphIndices: Set<Int>

    public init(totalParagraphCount: Int = 0, selectedParagraphIndices: Set<Int> = []) {
        self.totalParagraphCount = totalParagraphCount
        self.selectedParagraphIndices = selectedParagraphIndices
    }

    public var isAllSelected: Bool {
        totalParagraphCount > 0 && selectedParagraphIndices.count == totalParagraphCount
    }

    public var hasExclusions: Bool {
        !isAllSelected && !selectedParagraphIndices.isEmpty
    }

    public var selectedCount: Int {
        selectedParagraphIndices.count
    }
}

/// 时长估计的语速校准来源。
///
/// 倍率 `1.0` 既是「没人试读过」的默认值，也可能恰好是某次试读的真实结果。
/// 只看倍率无法区分这两者，于是未校准的估计会和实测估计长得一模一样。
/// 这里显式记录来源，让时长估计能说清自己是按默认语速推的还是量出来的
/// （#111 步骤 5：未经有效试读使用默认估计并标明不确定性）。
public enum TeleprompterCalibrationSource: Equatable, Sendable {
    /// 没有有效试读：按默认语速估算。
    case uncalibrated
    /// 手动计时试读：倍率与实测秒数来自同一次朗读。
    case manualTrial(durationSeconds: TimeInterval)
    /// 语音辅助试读：除时长外，还留下了识别器真的听到内容的证据。
    ///
    /// 单独一种来源而不是复用 `manualTrial`，是因为两者的可信度不同：
    /// 手动秒表只证明读者按了开始和结束，语音试读还证明采集、识别与定位
    /// 这条链路当时是通的。#111 要求「手动计时、语音辅助试读的证据来源清晰」。
    case speechTrial(durationSeconds: TimeInterval, recognizedUnits: Int)
}

public struct TeleprompterTrialReadingResult: Codable, Equatable, Sendable {
    public let durationSeconds: TimeInterval
    public let baseEstimateSeconds: TimeInterval
    public let calibrationFactor: Double
    public let isAdopted: Bool

    public init(
        durationSeconds: TimeInterval,
        baseEstimateSeconds: TimeInterval,
        calibrationFactor: Double,
        isAdopted: Bool = false
    ) {
        self.durationSeconds = durationSeconds
        self.baseEstimateSeconds = baseEstimateSeconds
        self.calibrationFactor = calibrationFactor
        self.isAdopted = isAdopted
    }

    public var isWithinValidRange: Bool {
        (TeleprompterTimingPolicy.minimumCalibrationFactor...TeleprompterTimingPolicy.maximumCalibrationFactor)
            .contains(calibrationFactor)
    }
}

/// 语音辅助试读走到哪一步了。
///
/// #112 要求「主动语音试读显示真实链路状态，不能只以输入电平证明识别和定位
/// 成功」。所以「麦克风在响」不算一档：必须能把采集、识别、定位分开报给用户。
public enum TeleprompterSpeechTrialStage: Equatable, Sendable {
    case idle
    /// 正在取设备租约、连识别服务、打开麦克风。
    case preparing
    /// 采集与识别都活着；此时是否真的听到内容看证据，不看这个状态。
    case listening
    case failed(String)

    public var isActive: Bool {
        self == .preparing || self == .listening
    }
}

/// 一次语音辅助试读留下的证据。
///
/// 只记计数，不记转写正文：#112 明确「不产生音频或全文 ASR 持久化」，
/// 而逐字记录留在本机 SQLite 的提词器侧与这里都不是这个功能需要的。
public struct TeleprompterSpeechTrialEvidence: Equatable, Sendable {
    public let durationSeconds: TimeInterval
    /// 识别器返回的单位数。0 表示麦克风开了但什么都没听到。
    public let recognizedUnits: Int
    /// 其中能在稿件里定位到的单位数。0 表示听到了但对不上正文。
    public let matchedUnits: Int

    public init(durationSeconds: TimeInterval, recognizedUnits: Int, matchedUnits: Int) {
        self.durationSeconds = durationSeconds
        self.recognizedUnits = recognizedUnits
        self.matchedUnits = matchedUnits
    }

    /// 只有真的识别出内容，这次试读才比手动秒表多一档证据。
    public var provesRecognition: Bool { recognizedUnits > 0 }

    /// 识别之外还完成了定位，才算 #112 说的整条链路通了。
    public var provesAlignment: Bool { matchedUnits > 0 }

    /// 能否采用为校准。识别不到内容的试读不产生倍率——那只是又按了一次开始。
    public var isAdoptable: Bool { provesRecognition }

    /// 这次试读能给出的校准倍率，不能给出时返回 `nil`。
    ///
    /// 抽成纯函数是为了让「识别到内容」与「时长够」两个条件能被分别钉住。
    /// 合在会话方法里时，一个条件的失效很容易被另一个条件的通过掩盖过去——
    /// 这正是「没听到东西的试读也产出了倍率」能够藏住的地方。
    public func calibrationFactor(baseEstimateSeconds: TimeInterval) -> Double? {
        guard isAdoptable,
              baseEstimateSeconds > 0,
              durationSeconds >= TeleprompterTimingPolicy.minimumTrialDurationSeconds
        else { return nil }
        return durationSeconds / baseEstimateSeconds
    }
}

public struct TeleprompterRunClockState: Codable, Equatable, Sendable {
    public var elapsedSeconds: TimeInterval
    public var targetSeconds: TimeInterval
    public var estimatedRemainingSeconds: TimeInterval
    public var isPaused: Bool

    public init(
        elapsedSeconds: TimeInterval = 0,
        targetSeconds: TimeInterval = 1200,
        estimatedRemainingSeconds: TimeInterval = 1200,
        isPaused: Bool = false
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.targetSeconds = targetSeconds
        self.estimatedRemainingSeconds = estimatedRemainingSeconds
        self.isPaused = isPaused
    }

    public var targetRemainingSeconds: TimeInterval {
        max(0, targetSeconds - elapsedSeconds)
    }

    public var isOverTarget: Bool {
        elapsedSeconds > targetSeconds
    }

    public var overTargetSeconds: TimeInterval {
        max(0, elapsedSeconds - targetSeconds)
    }
}

public enum TeleprompterAnalysisSource: String, Codable, Sendable {
    case ai
    case deterministic
    case user
}

public enum TeleprompterPauseHint: String, Codable, Sendable, CaseIterable {
    case short
    case medium
    case long
}

/// Why a reader-confirmed alias cannot be used. Every case fails closed: the
/// alias is dropped from matching rather than applied loosely, because an alias
/// that silently re-targets a different term would move the reading position
/// onto text the reader never said.
public enum TeleprompterAcceptedReadingRejection: Error, Equatable, Sendable {
    /// The session is not in a state where readings can be written at all —
    /// the stage is open, a version is still being prepared, or a previous stop
    /// has not finished. Distinct from "the text moved": retrying after the
    /// session settles is what fixes this one.
    case notEditable
    /// No confirmed version holds a segment with this id.
    case segmentUnavailable
    /// There is no confirmed reading bound to that range. Distinct from a
    /// storage failure: nothing was wrong, the reading is simply already gone.
    case noSuchReading
    /// The reading was rejected by the store and the change was rolled back.
    /// The script on disk is untouched; this is a storage failure, not a
    /// problem with the reading itself.
    case saveFailed
    /// The recorded range no longer fits the segment (segment shortened or replaced).
    case rangeOutOfBounds
    /// The text at that range is no longer what the user confirmed — the segment
    /// was edited after the alias was added, so the alias would point somewhere else.
    case displayTextChanged
    case emptySpokenText
    case spokenTextTooLong
    /// Display and spoken form do not carry the same numbers and units. An alias
    /// must never be a way to launder a different quantity past the fidelity gate:
    /// `50%` → `百分之五十` is fine, `50%` → `大约一半` is not.
    case numericValuesDiffer
    /// The alias overlaps another confirmed alias on the same segment.
    case overlappingAlias
    /// The term the reader typed does not occur in the segment they picked.
    case termNotFound
    /// The term occurs more than once, so typing it cannot say *which* occurrence
    /// the alias belongs to. Guessing here would bind the reading to the wrong
    /// words, so the reader is asked to narrow it down instead.
    case termAmbiguousOccurrences(Int)
    /// Written by a newer rule revision than this build understands. Dropping it is
    /// the only safe answer: we cannot claim an entry passes rules we have not read.
    case unknownRuleRevision
}

/// A reading the reader confirmed they will say instead of the displayed text,
/// bound to exactly one occurrence inside one segment.
///
/// This exists for the cases deterministic normalisation cannot cover — product
/// names and internal jargon the recogniser reliably mis-hears. Numeric and unit
/// forms are already handled by `TeleprompterCanonicalizer`, so this type
/// deliberately refuses any alias whose numbers do not survive normalisation.
public struct TeleprompterAcceptedReading: Codable, Equatable, Sendable {
    /// Bumped when the validation rules change so stored entries can be re-checked.
    public static let currentRuleRevision = 1
    public static let maximumSpokenTextLength = 60

    /// UTF-16 range inside the owning segment's display text.
    public let displayRange: TeleprompterSourceRange
    /// The display substring at `displayRange`, recorded so a later edit that moves
    /// the text invalidates the alias instead of silently re-targeting it.
    public let displayText: String
    /// What the reader will actually say.
    public let spokenText: String
    public let ruleRevision: Int

    public init(
        displayRange: TeleprompterSourceRange,
        displayText: String,
        spokenText: String,
        ruleRevision: Int = TeleprompterAcceptedReading.currentRuleRevision
    ) {
        self.displayRange = displayRange
        self.displayText = displayText
        self.spokenText = spokenText
        self.ruleRevision = ruleRevision
    }

    private enum CodingKeys: String, CodingKey {
        case displayRange = "display_range"
        case displayText = "display_text"
        case spokenText = "spoken_text"
        case ruleRevision = "rule_revision"
    }

    /// Re-checks this alias against the segment it claims to belong to.
    ///
    /// Callers pass the segment's current text: an alias recorded before an edit
    /// must stop being honoured once the text it named has moved or changed.
    public func rejection(inSegmentText segmentText: String) -> TeleprompterAcceptedReadingRejection? {
        guard ruleRevision <= Self.currentRuleRevision else { return .unknownRuleRevision }
        guard displayRange.isValid(in: segmentText) else { return .rangeOutOfBounds }
        let nsText = segmentText as NSString
        let substring = nsText.substring(with: NSRange(
            location: displayRange.start,
            length: displayRange.end - displayRange.start
        ))
        guard substring == displayText else {
            return .displayTextChanged
        }
        let spoken = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return .emptySpokenText }
        guard spoken.count <= Self.maximumSpokenTextLength else { return .spokenTextTooLong }
        guard TeleprompterAcceptedReading.numericFingerprint(of: displayText)
                == TeleprompterAcceptedReading.numericFingerprint(of: spoken) else {
            return .numericValuesDiffer
        }
        return nil
    }

    /// The numeric and unit content of a piece of text, after deterministic
    /// normalisation. Two texts may stand in for each other only when this is
    /// equal — that is what keeps an alias from swallowing a different quantity.
    static func numericFingerprint(of text: String) -> [String] {
        TeleprompterCanonicalizer.units(text)
            .filter(\.isNumeric)
            .map(\.value)
    }
}

public struct TeleprompterSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let ordinal: Int
    public let sourceRange: TeleprompterSourceRange
    public var text: String
    public var keywords: [String]
    public var matchPhrases: [String]
    /// Reader-confirmed alternative readings for specific occurrences in this
    /// segment. Never produced by the model: the analysis schema caps
    /// `match_phrases` at zero items, so these only ever come from an explicit
    /// user confirmation. Each entry is bound to one occurrence — never global.
    public var acceptedReadings: [TeleprompterAcceptedReading]
    public var pauseHint: TeleprompterPauseHint

    public init(
        id: String,
        ordinal: Int,
        sourceRange: TeleprompterSourceRange,
        text: String,
        keywords: [String] = [],
        matchPhrases: [String] = [],
        acceptedReadings: [TeleprompterAcceptedReading] = [],
        pauseHint: TeleprompterPauseHint = .short
    ) {
        self.id = id
        self.ordinal = ordinal
        self.sourceRange = sourceRange
        self.text = text
        self.keywords = keywords
        self.matchPhrases = matchPhrases
        self.acceptedReadings = acceptedReadings
        self.pauseHint = pauseHint
    }
}

public struct TeleprompterVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let documentID: String
    public let sourceText: String
    public let segments: [TeleprompterSegment]
    public let analysisSource: TeleprompterAnalysisSource
    public let createdAt: Date

    public init(
        id: String,
        documentID: String,
        sourceText: String,
        segments: [TeleprompterSegment],
        analysisSource: TeleprompterAnalysisSource,
        createdAt: Date = .now
    ) {
        self.id = id
        self.documentID = documentID
        self.sourceText = sourceText
        self.segments = segments
        self.analysisSource = analysisSource
        self.createdAt = createdAt
    }
}

public struct TeleprompterDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var sourceText: String
    public var activeVersionID: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        sourceText: String,
        activeVersionID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.sourceText = sourceText
        self.activeVersionID = activeVersionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TeleprompterRunMode: String, Codable, Sendable {
    case following
    case paused
    case manual
}

public struct TeleprompterRunState: Codable, Equatable, Sendable {
    public let documentID: String
    public let versionID: String
    public var currentSegmentID: String?
    /// UTF-16 offset inside the current segment's display text. Older payloads
    /// simply omit it and decode as `nil`, which restores the segment start.
    public var currentSegmentOffset: Int?
    public var mode: TeleprompterRunMode
    public var lastUpdatedAt: Date

    public init(
        documentID: String,
        versionID: String,
        currentSegmentID: String?,
        currentSegmentOffset: Int? = nil,
        mode: TeleprompterRunMode,
        lastUpdatedAt: Date = .now
    ) {
        self.documentID = documentID
        self.versionID = versionID
        self.currentSegmentID = currentSegmentID
        self.currentSegmentOffset = currentSegmentOffset
        self.mode = mode
        self.lastUpdatedAt = lastUpdatedAt
    }
}

/// Restores the reading position recorded with a run. An intra-segment UTF-16
/// offset is only reused when the text it was measured against is unchanged:
/// the same frozen version, or a different version whose segment text is
/// identical. Otherwise the reader returns to the start of that segment
/// instead of pointing an old offset at different words.
public enum TeleprompterReadingProgressRestorer {
    public static func position(
        saved: TeleprompterRunState,
        versions: [TeleprompterVersion],
        activeVersion: TeleprompterVersion?
    ) -> TeleprompterAligner.Position? {
        guard let segmentID = saved.currentSegmentID,
              let activeVersion,
              let index = activeVersion.segments.firstIndex(where: { $0.id == segmentID })
        else { return nil }
        let segment = activeVersion.segments[index]
        let recordedText = versions
            .first { $0.id == saved.versionID }?
            .segments
            .first { $0.id == segmentID }?
            .text
        guard recordedText == segment.text else {
            return .init(segmentIndex: index, utf16Offset: 0)
        }
        return .init(
            segmentIndex: index,
            utf16Offset: min(max(saved.currentSegmentOffset ?? 0, 0), segment.text.utf16.count)
        )
    }
}

public struct TeleprompterDocumentBundle: Codable, Equatable, Sendable {
    public var document: TeleprompterDocument
    public var versions: [TeleprompterVersion]
    public var runState: TeleprompterRunState?

    public init(
        document: TeleprompterDocument,
        versions: [TeleprompterVersion],
        runState: TeleprompterRunState?
    ) {
        self.document = document
        self.versions = versions
        self.runState = runState
    }
}

public enum TeleprompterAlignmentDecision: Equatable, Sendable {
    case stay(confidence: Double)
    case advance(to: Int, confidence: Double)
    case uncertain(candidate: Int?, confidence: Double)
}

public struct TeleprompterAlignmentResult: Equatable, Sendable {
    public let decision: TeleprompterAlignmentDecision
    public let matchedTokens: [String]

    public init(decision: TeleprompterAlignmentDecision, matchedTokens: [String] = []) {
        self.decision = decision
        self.matchedTokens = matchedTokens
    }

    public var confidence: Double {
        switch decision {
        case let .stay(confidence), let .advance(_, confidence), let .uncertain(_, confidence):
            confidence
        }
    }
}
