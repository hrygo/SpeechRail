import Foundation

/// 提词器时长算法策略与预检规则。
///
/// 遵循 `docs/superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md` §6 与 §13：
/// - 算法参数集中在此处声明，不与视觉 Token 混用；
/// - 纯计算模型，中英文朗读计数互斥，支持个人语速校准系数 k；
/// - 篇幅计划预算 B = 0.95 * targetSeconds（5% 余量）；
/// - 波动带展示为 [0.8D, 1.25D]（启发式范围，非置信区间）。
public enum TeleprompterTimingPolicy {
    /// 目标时长边界（分钟）
    public static let minimumTargetMinutes: Int = 1
    public static let maximumTargetMinutes: Int = 120
    public static let defaultTargetMinutes: Int = 20

    /// 篇幅预算折扣（5% 余量）
    public static let budgetRatio: Double = 0.95

    /// 试读有效范围
    public static let minimumTrialDurationSeconds: TimeInterval = 30
    public static let suggestedTrialDurationSeconds: TimeInterval = 60
    public static let minimumCalibrationFactor: Double = 0.5
    public static let maximumCalibrationFactor: Double = 2.0

    /// 快捷目标时长选项（分钟）
    public static let quickTargets: [Int] = [5, 10, 15, 20, 30, 60, 120]

    /// 朗读节奏档位
    public enum Pace: String, CaseIterable, Codable, Sendable, Identifiable {
        case relaxed
        case natural
        case brisk

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .relaxed: "舒缓"
            case .natural: "自然"
            case .brisk: "明快"
            }
        }

        public var subtitle: String {
            switch self {
            case .relaxed: "约 180 字/分"
            case .natural: "约 220 字/分"
            case .brisk: "约 260 字/分"
            }
        }

        /// 中文等价字/分钟
        public var cjkUnitsPerMinute: Double {
            switch self {
            case .relaxed: 180
            case .natural: 220
            case .brisk: 260
            }
        }

        /// 英文词/分钟
        public var latinWordsPerMinute: Double {
            switch self {
            case .relaxed: 110
            case .natural: 140
            case .brisk: 165
            }
        }
    }

    /// 文本计量结果（中英互斥）
    public struct TextMetrics: Equatable, Sendable {
        public let hanCount: Int
        public let latinWordCount: Int
        public let hasUnresolvedPronunciation: Bool
        public let uncertaintyReasons: [String]

        public init(
            hanCount: Int,
            latinWordCount: Int,
            hasUnresolvedPronunciation: Bool = false,
            uncertaintyReasons: [String] = []
        ) {
            self.hanCount = hanCount
            self.latinWordCount = latinWordCount
            self.hasUnresolvedPronunciation = hasUnresolvedPronunciation
            self.uncertaintyReasons = uncertaintyReasons
        }

        public var totalUnits: Int {
            hanCount + latinWordCount
        }

        public var isEmpty: Bool {
            totalUnits == 0
        }
    }

    /// 时长预估结果
    public struct EstimateResult: Equatable, Sendable {
        /// 预估中心秒数（若无法可靠预估则为 nil）
        public let pointSeconds: TimeInterval?
        /// 波动范围 [0.8D, 1.25D]
        public let rangeSeconds: ClosedRange<TimeInterval>?
        /// 是否包含不确定性
        public let isUncertain: Bool
        /// 不确定原因说明
        public let uncertaintyReason: String?
        /// 可可靠计量的已知部分秒数；不把未知内容当作 0 秒。
        public let knownPartSeconds: TimeInterval

        public init(
            pointSeconds: TimeInterval?,
            rangeSeconds: ClosedRange<TimeInterval>?,
            isUncertain: Bool,
            uncertaintyReason: String? = nil,
            knownPartSeconds: TimeInterval = 0
        ) {
            self.pointSeconds = pointSeconds
            self.rangeSeconds = rangeSeconds
            self.isUncertain = isUncertain
            self.uncertaintyReason = uncertaintyReason
            self.knownPartSeconds = knownPartSeconds
        }

        public var pointMinutes: Double? {
            pointSeconds.map { $0 / 60.0 }
        }
    }

    /// 可行性预检结论
    public enum PreflightConclusion: Equatable, Sendable {
        /// 文本为空
        case emptyText
        /// 目标超出合法范围 (1–120 分钟)
        case invalidTarget(String)
        /// 无法可靠预估
        case uncertain(String)
        /// 内容偏少：D/B < 0.75
        case underfilled(estimateMinutes: Double, targetMinutes: Int)
        /// 与目标大致匹配：0.75 <= D/B <= 1.00
        case matching(estimateMinutes: Double, targetMinutes: Int)
        /// 可能略超时：1.00 < D/B <= 1.15
        case slightlyOver(estimateMinutes: Double, targetMinutes: Int)
        /// 目标偏紧：D/B > 1.15
        case tight(estimateMinutes: Double, targetMinutes: Int)

        public var badgeTitle: String {
            switch self {
            case .emptyText: "无内容"
            case .invalidTarget: "目标无效"
            case .uncertain: "无法预估"
            case .underfilled: "内容偏少"
            case .matching: "大致匹配"
            case .slightlyOver: "可能略超时"
            case .tight: "目标偏紧"
            }
        }

        public var userGuidance: String {
            switch self {
            case .emptyText:
                "请先输入或导入稿件内容。"
            case .invalidTarget(let message):
                message
            case .uncertain(let message):
                message
            case .underfilled(let est, let target):
                "预计 \(formatMinutes(est)) 读完，少于目标 \(target) 分钟。这份稿可能提前读完，无需补充内容也可以使用。"
            case .matching(let est, let target):
                "预计 \(formatMinutes(est))，与目标 \(target) 分钟大致匹配，可正常整理。"
            case .slightlyOver(let est, let target):
                "预计 \(formatMinutes(est))，可能略微超过目标 \(target) 分钟，将采用更紧凑自然的口语表达。"
            case .tight(let est, let target):
                "按当前节奏可能需要 \(formatMinutes(est))，明显超过目标 \(target) 分钟。可延长目标、选择本次要讲的段落，或仍按完整内容整理。"
            }
        }

        private func formatMinutes(_ minutes: Double) -> String {
            let mins = Int(round(minutes))
            return "\(max(1, mins)) 分钟"
        }
    }

    // MARK: - 计算与分析纯函数

    /// 计量文本（中文字符与拉丁单词，互斥计数）
    public static func countMetrics(in text: String) -> TextMetrics {
        var hanCount = 0
        var latinWordCount = 0
        var inLatinWord = false
        var reasons = Set<String>()

        for scalar in text.unicodeScalars {
            // Han 字符区间判断
            if (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x20000...0x2A6DF).contains(scalar.value) {
                hanCount += 1
                inLatinWord = false
            } else if scalar.value < 128 && CharacterSet.letters.contains(scalar) {
                if !inLatinWord {
                    latinWordCount += 1
                    inLatinWord = true
                }
            } else if CharacterSet.decimalDigits.contains(scalar) {
                reasons.insert("unresolvedPronunciation")
                inLatinWord = false
            } else if CharacterSet.letters.contains(scalar) {
                reasons.insert("nonLatinLanguage")
                inLatinWord = false
            } else {
                inLatinWord = false
            }
        }

        if text.range(of: #"(?:https?://|www\.)"#, options: .regularExpression) != nil {
            reasons.insert("url")
        }

        return TextMetrics(
            hanCount: hanCount,
            latinWordCount: latinWordCount,
            hasUnresolvedPronunciation: !reasons.isEmpty,
            uncertaintyReasons: reasons.sorted()
        )
    }

    /// 估算朗读用时
    public static func estimateDuration(
        metrics: TextMetrics,
        pace: Pace,
        calibrationFactor: Double = 1.0
    ) -> EstimateResult {
        guard !metrics.isEmpty else {
            return EstimateResult(
                pointSeconds: 0,
                rangeSeconds: 0...0,
                isUncertain: false,
                knownPartSeconds: 0
            )
        }

        let k = min(max(calibrationFactor, minimumCalibrationFactor), maximumCalibrationFactor)
        guard !metrics.hasUnresolvedPronunciation else {
            let knownPartSeconds = 60.0 * (
                Double(metrics.hanCount) / pace.cjkUnitsPerMinute +
                Double(metrics.latinWordCount) / pace.latinWordsPerMinute
            ) * k
            return EstimateResult(
                pointSeconds: nil,
                rangeSeconds: nil,
                isUncertain: true,
                uncertaintyReason: "包含数字、网址或非中英文本，无法可靠预估整稿时长",
                knownPartSeconds: knownPartSeconds
            )
        }

        let baseSeconds = 60.0 * (
            Double(metrics.hanCount) / pace.cjkUnitsPerMinute +
            Double(metrics.latinWordCount) / pace.latinWordsPerMinute
        )
        let point = k * baseSeconds
        let lower = 0.8 * point
        let upper = 1.25 * point

        return EstimateResult(
            pointSeconds: point,
            rangeSeconds: lower...upper,
            isUncertain: false,
            knownPartSeconds: point
        )
    }

    /// 可行性预检
    public static func evaluatePreflight(
        text: String,
        targetMinutes: Int,
        pace: Pace,
        calibrationFactor: Double = 1.0
    ) -> PreflightConclusion {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .emptyText
        }

        guard (minimumTargetMinutes...maximumTargetMinutes).contains(targetMinutes) else {
            return .invalidTarget("目标时长应在 \(minimumTargetMinutes)–\(maximumTargetMinutes) 分钟之间。")
        }

        let metrics = countMetrics(in: trimmed)
        let estimate = estimateDuration(metrics: metrics, pace: pace, calibrationFactor: calibrationFactor)

        guard let pointSeconds = estimate.pointSeconds, !estimate.isUncertain else {
            return .uncertain(estimate.uncertaintyReason ?? "无法可靠预估时长")
        }

        let targetSeconds = Double(targetMinutes * 60)
        let budgetSeconds = budgetRatio * targetSeconds
        let ratio = pointSeconds / budgetSeconds
        let estMinutes = pointSeconds / 60.0

        if ratio < 0.75 {
            return .underfilled(estimateMinutes: estMinutes, targetMinutes: targetMinutes)
        } else if ratio <= 1.00 {
            return .matching(estimateMinutes: estMinutes, targetMinutes: targetMinutes)
        } else if ratio <= 1.15 {
            return .slightlyOver(estimateMinutes: estMinutes, targetMinutes: targetMinutes)
        } else {
            return .tight(estimateMinutes: estMinutes, targetMinutes: targetMinutes)
        }
    }
}
