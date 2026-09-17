import Foundation
import SpeechRailControlKit

/// Prometheus 直方图在某一时刻的累计 `sum` / `count`。
///
/// 页面上的「窗口值」一律由两个采样点的增量得出（`increase(sum) / increase(count)`），
/// 而不是把服务端自进程启动以来的 lifetime 均值当成实时值——这是
/// Prometheus / Grafana 的惯用口径，也让时间窗选择真的改变数字
/// （REDESIGN-SPEC §7.6，2026-09-15 用户复核）。
public struct RuntimeHistogramTotals: Equatable, Sendable {
    public let sum: Double
    public let count: Double

    public init(sum: Double, count: Double) {
        self.sum = sum
        self.count = count
    }

    public var average: Double? {
        count > 0 ? sum / count : nil
    }

    /// 相对前一个采样点的增量。没有前一个点、或服务重启导致计数回退时
    /// 返回 `nil`：那一段就是「无数据」，不能当成 0。
    public func delta(since earlier: RuntimeHistogramTotals?) -> RuntimeHistogramTotals? {
        guard let earlier else { return nil }
        let sum = self.sum - earlier.sum
        let count = self.count - earlier.count
        guard sum >= 0, count >= 0 else { return nil }
        return RuntimeHistogramTotals(sum: sum, count: count)
    }
}

/// 用户口径的用量：这个时间窗里到底发生了什么。
///
/// 首屏展示的是这一组事实，而不是 `rate(speechrail_http_requests_total[...])`：
/// 后者把控制面自己的轮询（`/health`、`/metrics`、`/v1/models`、`/v1/voices`）也算成
/// 「请求」：本机实测 1188 次累计请求里 1159 次是控制面轮询（97.6%）——用户什么都没做
/// 时数字在动，用户真的在合成时它又几乎不动。所以这里只数语音接口，
/// 并且把「次数」与「音频秒数」分开。
public struct RuntimeUsageTotals: Equatable, Sendable {
    /// `/v1/audio/speech` 的累计请求数（含失败，失败数另有口径）。
    public let ttsRequests: Double?
    /// `/v1/audio/transcriptions` 的累计请求数。
    public let asrRequests: Double?
    /// 已合成音频的总时长（秒）。
    public let ttsAudioSeconds: Double?
    /// 已识别音频的总时长（秒）。
    public let asrAudioSeconds: Double?
    /// 已建立的实时语音会话数。
    public let realtimeSessions: Double?

    public init(
        ttsRequests: Double? = nil,
        asrRequests: Double? = nil,
        ttsAudioSeconds: Double? = nil,
        asrAudioSeconds: Double? = nil,
        realtimeSessions: Double? = nil
    ) {
        self.ttsRequests = ttsRequests
        self.asrRequests = asrRequests
        self.ttsAudioSeconds = ttsAudioSeconds
        self.asrAudioSeconds = asrAudioSeconds
        self.realtimeSessions = realtimeSessions
    }

    public var isEmpty: Bool {
        ttsRequests == nil
            && asrRequests == nil
            && ttsAudioSeconds == nil
            && asrAudioSeconds == nil
            && realtimeSessions == nil
    }

    /// 两个采样点之间的增量。规则与 `RuntimeHistogramTotals.delta(since:)` 一致：
    /// 缺任一端、或服务重启导致计数回退时该字段为 `nil`——那是无数据，不是 0。
    public func delta(since earlier: RuntimeUsageTotals?) -> RuntimeUsageTotals {
        func increment(_ current: Double?, _ previous: Double?) -> Double? {
            guard let current, let previous, current >= previous else { return nil }
            return current - previous
        }
        return RuntimeUsageTotals(
            ttsRequests: increment(ttsRequests, earlier?.ttsRequests),
            asrRequests: increment(asrRequests, earlier?.asrRequests),
            ttsAudioSeconds: increment(ttsAudioSeconds, earlier?.ttsAudioSeconds),
            asrAudioSeconds: increment(asrAudioSeconds, earlier?.asrAudioSeconds),
            realtimeSessions: increment(realtimeSessions, earlier?.realtimeSessions)
        )
    }
}

public struct RuntimeMetricsSample: Identifiable, Equatable, Sendable {
    public let capturedAt: Date
    public let activeRequests: Int
    /// Figma `lineChart` 画两条线：实时请求（实线）与批处理请求（虚线），
    /// 并发图因此必须保留分类计数，而不是只留一个合计值。
    public let realtimeActiveRequests: Int
    public let batchActiveRequests: Int
    public let pendingRequests: Int
    public let requestCount: Double?
    /// `status="5xx"` 的累计计数：RED 方法里的 Errors。
    public let requestErrors: Double?
    public let queueRejections: Double?
    public let workerEvictions: Double?
    public let asrLatencySeconds: Double?
    public let ttsLatencySeconds: Double?
    public let asrRTF: Double?
    public let ttsRTF: Double?
    public let ttsTTFASeconds: Double?
    public let activeRealtimeSessions: Int?
    public let requestRatePerSecond: Double?
    public let errorRatePerSecond: Double?
    public let queueRejectionRatePerSecond: Double?
    public let resources: RuntimeResourceSnapshot?
    /// 直方图累计量：窗口值（指标条与摘要）要按时间窗重新求增量。
    public let asrDuration: RuntimeHistogramTotals?
    public let ttsDuration: RuntimeHistogramTotals?
    public let ttsTTFA: RuntimeHistogramTotals?
    public let asrRTFTotals: RuntimeHistogramTotals?
    public let ttsRTFTotals: RuntimeHistogramTotals?
    /// TTS 时延直方图按 `voice_class` 拆开的累计量。服务不按 worker 暴露时延，
    /// 这是这条直方图上唯一真实存在的维度（`system` / `custom` / `clone`），
    /// 把它合并掉等于丢掉 Grafana 会保留的那个 label。
    public let ttsDurationByVoiceClass: [String: RuntimeHistogramTotals]
    /// 用户口径的累计用量（只含语音接口），首屏的「我用了多少」由它求窗口增量。
    public let usage: RuntimeUsageTotals

    public var id: Date { capturedAt }

    public init(
        capturedAt: Date,
        activeRequests: Int,
        realtimeActiveRequests: Int = 0,
        batchActiveRequests: Int = 0,
        pendingRequests: Int,
        requestCount: Double?,
        requestErrors: Double? = nil,
        queueRejections: Double?,
        workerEvictions: Double? = nil,
        asrLatencySeconds: Double?,
        ttsLatencySeconds: Double?,
        asrRTF: Double? = nil,
        ttsRTF: Double? = nil,
        ttsTTFASeconds: Double? = nil,
        activeRealtimeSessions: Int? = nil,
        requestRatePerSecond: Double? = nil,
        errorRatePerSecond: Double? = nil,
        queueRejectionRatePerSecond: Double? = nil,
        resources: RuntimeResourceSnapshot? = nil,
        asrDuration: RuntimeHistogramTotals? = nil,
        ttsDuration: RuntimeHistogramTotals? = nil,
        ttsTTFA: RuntimeHistogramTotals? = nil,
        asrRTFTotals: RuntimeHistogramTotals? = nil,
        ttsRTFTotals: RuntimeHistogramTotals? = nil,
        ttsDurationByVoiceClass: [String: RuntimeHistogramTotals] = [:],
        usage: RuntimeUsageTotals = RuntimeUsageTotals()
    ) {
        self.capturedAt = capturedAt
        self.activeRequests = activeRequests
        self.realtimeActiveRequests = realtimeActiveRequests
        self.batchActiveRequests = batchActiveRequests
        self.pendingRequests = pendingRequests
        self.requestCount = requestCount
        self.requestErrors = requestErrors
        self.queueRejections = queueRejections
        self.workerEvictions = workerEvictions
        self.asrLatencySeconds = asrLatencySeconds
        self.ttsLatencySeconds = ttsLatencySeconds
        self.asrRTF = asrRTF
        self.ttsRTF = ttsRTF
        self.ttsTTFASeconds = ttsTTFASeconds
        self.activeRealtimeSessions = activeRealtimeSessions
        self.requestRatePerSecond = requestRatePerSecond
        self.errorRatePerSecond = errorRatePerSecond
        self.queueRejectionRatePerSecond = queueRejectionRatePerSecond
        self.resources = resources
        self.asrDuration = asrDuration
        self.ttsDuration = ttsDuration
        self.ttsTTFA = ttsTTFA
        self.asrRTFTotals = asrRTFTotals
        self.ttsRTFTotals = ttsRTFTotals
        self.ttsDurationByVoiceClass = ttsDurationByVoiceClass
        self.usage = usage
    }
}

public enum RuntimeMetricsSampler {
    /// 语音接口的路由模板。`/metrics` 的 `endpoint` label 就是 FastAPI 的 route path，
    /// 所以这两个字面量是契约值，不是猜测。
    static let ttsEndpoint = "/v1/audio/speech"
    static let asrEndpoint = "/v1/audio/transcriptions"
    /// 音色试听也走 `record_tts`，所以它同样是「合成」的一次：只数
    /// `/v1/audio/speech` 会让「次数」与「音频秒数」对不上（后者包含试听）。
    static let voicePreviewEndpoint = "/v1/voices/previews"

    public static func makeSample(
        from metrics: RuntimeMetricsSnapshot,
        capturedAt: Date = Date(),
        previous: RuntimeMetricsSample? = nil
    ) -> RuntimeMetricsSample {
        let requestCount = sumValues(
            metrics.counters,
            prefix: "speechrail_http_requests_total"
        )
        // RED 的 Errors：只数 5xx。4xx 在本机服务里主要是调用方输入问题，
        // 混进来会让「服务端错误率」失去意义。
        let requestErrors = sumValues(
            metrics.counters,
            prefix: "speechrail_http_requests_total"
        ) { key in
            key.contains("status=\"5")
        }
        let queueRejections = sumValues(
            metrics.counters,
            prefix: "speechrail_governor_queue_rejections_total"
        )
        let workerEvictions = sumValues(
            metrics.counters,
            prefix: "speechrail_worker_evictions_total"
        )
        let asrDuration = totals(metrics, name: "speechrail_asr_inference_duration_seconds")
        let ttsDuration = totals(metrics, name: "speechrail_tts_inference_duration_seconds")
        let ttsDurationByVoiceClass = totalsByLabel(
            metrics,
            name: "speechrail_tts_inference_duration_seconds",
            label: "voice_class"
        )
        let ttsTTFA = totals(metrics, name: "speechrail_tts_ttfa_seconds")
        let asrRTFTotals = totals(metrics, name: "speechrail_asr_rtf")
        let ttsRTFTotals = totals(metrics, name: "speechrail_tts_rtf")
        // 用户口径的用量：只数语音接口。控制面轮询（`/health`、`/metrics`、`/v1/models`、
        // `/v1/voices`）是 App 自己在读状态，把它们算进「请求」会让这个数字既不听用户的
        // 话，也不反映工作量（REDESIGN-SPEC §7.6）。
        let usage = RuntimeUsageTotals(
            ttsRequests: speechRequestCount(
                metrics,
                endpoints: [ttsEndpoint, voicePreviewEndpoint]
            ),
            asrRequests: speechRequestCount(metrics, endpoints: [asrEndpoint]),
            ttsAudioSeconds: sumValues(
                metrics.counters,
                prefix: "speechrail_tts_generated_audio_seconds_total"
            ),
            asrAudioSeconds: sumValues(
                metrics.counters,
                prefix: "speechrail_asr_processed_audio_seconds_total"
            ),
            realtimeSessions: sumValues(
                metrics.counters,
                prefix: "speechrail_realtime_sessions_total"
            )
        )
        return RuntimeMetricsSample(
            capturedAt: capturedAt,
            activeRequests: metrics.activeRequests.realtime + metrics.activeRequests.batch,
            realtimeActiveRequests: metrics.activeRequests.realtime,
            batchActiveRequests: metrics.activeRequests.batch,
            pendingRequests: metrics.pendingRequests.realtime + metrics.pendingRequests.batch,
            requestCount: requestCount,
            requestErrors: requestErrors,
            queueRejections: queueRejections,
            workerEvictions: workerEvictions,
            // 图形上的每个点都是「与上一个采样点之间」的增量均值：这才叫窗口值，
            // lifetime 均值是一条几乎不动、也不能反映当下的线。
            asrLatencySeconds: asrDuration?.delta(since: previous?.asrDuration)?.average,
            ttsLatencySeconds: ttsDuration?.delta(since: previous?.ttsDuration)?.average,
            asrRTF: asrRTFTotals?.delta(since: previous?.asrRTFTotals)?.average,
            ttsRTF: ttsRTFTotals?.delta(since: previous?.ttsRTFTotals)?.average,
            ttsTTFASeconds: ttsTTFA?.delta(since: previous?.ttsTTFA)?.average,
            activeRealtimeSessions: sumValues(
                metrics.gauges,
                prefix: "speechrail_realtime_active_sessions"
            ).map { max(0, Int($0.rounded())) },
            requestRatePerSecond: counterRate(
                current: requestCount,
                previous: previous?.requestCount,
                capturedAt: capturedAt,
                previousCapturedAt: previous?.capturedAt
            ),
            errorRatePerSecond: counterRate(
                current: requestErrors,
                previous: previous?.requestErrors,
                capturedAt: capturedAt,
                previousCapturedAt: previous?.capturedAt
            ),
            queueRejectionRatePerSecond: counterRate(
                current: queueRejections,
                previous: previous?.queueRejections,
                capturedAt: capturedAt,
                previousCapturedAt: previous?.capturedAt
            ),
            resources: metrics.resources,
            asrDuration: asrDuration,
            ttsDuration: ttsDuration,
            ttsTTFA: ttsTTFA,
            asrRTFTotals: asrRTFTotals,
            ttsRTFTotals: ttsRTFTotals,
            ttsDurationByVoiceClass: ttsDurationByVoiceClass,
            usage: usage
        )
    }

    private static func sumValues(
        _ values: [String: Double],
        prefix: String,
        matching predicate: (String) -> Bool = { _ in true }
    ) -> Double? {
        let matchingValues = values
            .filter { $0.key == prefix || $0.key.hasPrefix("\(prefix){") }
            .filter { predicate($0.key) }
            .map(\.value)
        guard !matchingValues.isEmpty else { return nil }
        return matchingValues.reduce(0, +)
    }

    /// 若干个语音接口的累计请求数之和。某个接口从没被调用过时它没有序列，
    /// 那不是「读不到」，只是这个接口贡献 0。
    private static func speechRequestCount(
        _ metrics: RuntimeMetricsSnapshot,
        endpoints: [String]
    ) -> Double? {
        let counts = endpoints.compactMap { endpoint in
            sumValues(metrics.counters, prefix: "speechrail_http_requests_total") { key in
                key.contains("endpoint=\"\(endpoint)\"")
            }
        }
        guard !counts.isEmpty else { return nil }
        return counts.reduce(0, +)
    }

    /// 直方图可能带多个 label 组合（例如 realtime phase）。窗口口径把它们并成
    /// 一条：`count` 加权、`sum` 相加，和 Prometheus 对同一指标做聚合一致。
    private static func totals(
        _ metrics: RuntimeMetricsSnapshot,
        name: String
    ) -> RuntimeHistogramTotals? {
        guard let series = metrics.histograms[name], !series.isEmpty else { return nil }
        let samples = series.values.filter { $0.count > 0 }
        guard !samples.isEmpty else { return nil }
        let count = samples.reduce(0.0) { $0 + Double($1.count) }
        guard count > 0 else { return nil }
        let sum = samples.reduce(0.0) { $0 + $1.sum }
        return RuntimeHistogramTotals(sum: sum, count: count)
    }

    /// 把一条直方图按某个 label 的取值分组，每组再按 Prometheus 的方式聚合
    /// （`count` 加权、`sum` 相加）。取不到该 label 的序列会被忽略：那是别的
    /// 维度，不是这个分组的数据。
    private static func totalsByLabel(
        _ metrics: RuntimeMetricsSnapshot,
        name: String,
        label: String
    ) -> [String: RuntimeHistogramTotals] {
        guard let series = metrics.histograms[name], !series.isEmpty else { return [:] }
        var grouped: [String: [RuntimeHistogramSummary]] = [:]
        for (key, summary) in series where summary.count > 0 {
            guard let value = labelValue(key, label: label) else { continue }
            grouped[value, default: []].append(summary)
        }
        return grouped.compactMapValues { samples in
            let count = samples.reduce(0.0) { $0 + Double($1.count) }
            guard count > 0 else { return nil }
            return RuntimeHistogramTotals(
                sum: samples.reduce(0.0) { $0 + $1.sum },
                count: count
            )
        }
    }

    /// 服务端的 JSON 用 Prometheus 的标签串做键（`{voice_class="system"}`），
    /// 这里只取需要的那个标签值，不假设它在串里的位置。
    public static func labelValue(_ key: String, label: String) -> String? {
        let pattern = label + "=\""
        guard let start = key.range(of: pattern)?.upperBound else { return nil }
        guard let end = key[start...].firstIndex(of: "\"") else { return nil }
        return String(key[start..<end])
    }

    private static func counterRate(
        current: Double?,
        previous: Double?,
        capturedAt: Date,
        previousCapturedAt: Date?
    ) -> Double? {
        guard let current,
              let previous,
              let previousCapturedAt,
              current >= previous
        else { return nil }
        let elapsed = capturedAt.timeIntervalSince(previousCapturedAt)
        guard elapsed > 0 else { return nil }
        return (current - previous) / elapsed
    }
}

/// 当前时间窗内的窗口值。
///
/// 和 Grafana 面板一样：统计数字取窗内首尾两点的 `increase(...)` 或
/// `rate(...)`，而不是读最后一个采样点的瞬时值——瞬时值会被单次请求带偏，
/// 并且让「1 分钟 / 5 分钟 / 本次会话」这个选择失去意义。
/// 计数器缺失、服务重启导致回退、或窗内样本不足两个时一律返回 `nil`：
/// 那是「无数据」，不是 0。
/// 一种音色类别（`/metrics` 的 `voice_class` 标签）在窗口内的 TTS 时延。
///
/// 服务的时延直方图不按 worker 拆分，`voice_class` 是这条直方图唯一真实存在的
/// 维度：系统音色、我的音色、参考音色各算一条，比合并成一个数字更接近
/// Prometheus / Grafana 的读法（REDESIGN-SPEC §7.6）。
public struct RuntimeVoiceClassLatency: Equatable, Sendable, Identifiable {
    public let voiceClass: String
    public let seconds: Double
    public let count: Double

    public var id: String { voiceClass }

    public init(voiceClass: String, seconds: Double, count: Double) {
        self.voiceClass = voiceClass
        self.seconds = seconds
        self.count = count
    }
}

/// 把 `/metrics` 的直方图名字与标签串翻成用户语言。
///
/// 指标原文是运维口径的唯一事实（排障、对 Grafana 时要用它），所以翻译只发生在展示层；
/// 认不出的名字原样保留，不替它编一个含义。
public enum RuntimeHistogramPresentation {
    public static func title(forMetric name: String) -> String {
        switch name {
        case "speechrail_asr_inference_duration_seconds":
            "语音识别耗时"
        case "speechrail_tts_inference_duration_seconds":
            "语音合成耗时"
        case "speechrail_tts_ttfa_seconds":
            "合成首帧时间"
        case "speechrail_asr_rtf":
            "识别耗时倍率"
        case "speechrail_tts_rtf":
            "合成耗时倍率"
        case "speechrail_http_request_duration_seconds":
            "接口响应时间"
        default:
            name
        }
    }

    /// 平均值这一列的单位。倍率是比值，没有单位。
    public static func unit(forMetric name: String) -> String {
        switch name {
        case "speechrail_asr_rtf", "speechrail_tts_rtf":
            ""
        case "speechrail_asr_inference_duration_seconds",
             "speechrail_tts_inference_duration_seconds",
             "speechrail_tts_ttfa_seconds",
             "speechrail_http_request_duration_seconds":
            "秒"
        default:
            ""
        }
    }

    /// `voice_class` 的三个取值来自服务端的低基数映射（`speechrail/domain/tts.py`）。
    public static func voiceClassTitle(_ voiceClass: String) -> String {
        switch voiceClass {
        case "system":
            "系统音色"
        case "clone":
            "参考音色"
        case "custom":
            "我的音色"
        default:
            voiceClass
        }
    }

    /// 把 Prometheus 标签串译成人话：`{voice_class="system"}` → `系统音色`，
    /// `{endpoint="/health"}` → `/health`。认不出的标签串原样返回。
    public static func labelSummary(_ labels: String) -> String {
        if let voiceClass = RuntimeMetricsSampler.labelValue(labels, label: "voice_class") {
            return voiceClassTitle(voiceClass)
        }
        if let endpoint = RuntimeMetricsSampler.labelValue(labels, label: "endpoint") {
            return endpoint
        }
        return labels
    }

    /// 带单位的平均值：`0.412 秒`；倍率只报数字。
    public static func formattedAverage(_ value: Double, unit: String) -> String {
        let number = String(format: "%.3f", value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}

public struct RuntimeMonitoringWindow: Equatable, Sendable {
    public let samples: [RuntimeMetricsSample]

    public init(samples: [RuntimeMetricsSample]) {
        self.samples = samples
    }

    public var isEmpty: Bool { samples.isEmpty }
    public var latest: RuntimeMetricsSample? { samples.last }

    public var windowSeconds: Double? {
        guard let first = samples.first, let last = samples.last, samples.count > 1 else {
            return nil
        }
        let seconds = last.capturedAt.timeIntervalSince(first.capturedAt)
        return seconds > 0 ? seconds : nil
    }

    /// `rate(speechrail_http_requests_total[window])`
    public var requestRate: Double? { rate(\.requestCount) }

    /// `rate(speechrail_http_requests_total{status="5xx"}[window])`
    public var errorRate: Double? { rate(\.requestErrors) }

    /// `rate(speechrail_governor_queue_rejections_total[window])`
    public var queueRejectionRate: Double? { rate(\.queueRejections) }

    /// `speechrail_worker_evictions_total` 的窗口增量（次数，不是速率）。
    public var workerEvictions: Double? { increaseOf(\.workerEvictions) }

    /// Errors /（Rate）的比值，0–1。
    public var errorRatio: Double? {
        guard let errors = increaseOf(\.requestErrors),
              let requests = increaseOf(\.requestCount),
              requests > 0
        else { return nil }
        return min(max(errors / requests, 0), 1)
    }

    /// `increase(sum) / increase(count)`：窗内时延均值。
    public var asrLatencySeconds: Double? { histogramAverage(\.asrDuration) }
    public var ttsLatencySeconds: Double? { histogramAverage(\.ttsDuration) }
    public var ttsTTFASeconds: Double? { histogramAverage(\.ttsTTFA) }
    public var asrRTF: Double? { histogramAverage(\.asrRTFTotals) }
    public var ttsRTF: Double? { histogramAverage(\.ttsRTFTotals) }

    /// `speechrail_tts_inference_duration_seconds{voice_class=…}` 的窗口均值，
    /// 每个类别各算一次 `increase(sum) / increase(count)`。空数组表示窗内没有
    /// 该维度的样本——是无数据，不是 0。
    public var ttsLatencyByVoiceClass: [RuntimeVoiceClassLatency] {
        guard let first = samples.first, let last = samples.last, samples.count > 1 else {
            return []
        }
        let classes = Set(first.ttsDurationByVoiceClass.keys)
            .union(last.ttsDurationByVoiceClass.keys)
        return classes.compactMap { voiceClass -> RuntimeVoiceClassLatency? in
            guard let delta = last.ttsDurationByVoiceClass[voiceClass]?
                .delta(since: first.ttsDurationByVoiceClass[voiceClass]),
                let seconds = delta.average
            else { return nil }
            return RuntimeVoiceClassLatency(
                voiceClass: voiceClass,
                seconds: seconds,
                count: delta.count
            )
        }
        .sorted { $0.voiceClass < $1.voiceClass }
    }

    /// 窗内被观测到的请求数，用于说明上面的速率有多可信。
    public var requestIncrease: Double? { increaseOf(\.requestCount) }

    /// 用户口径的窗内用量：只含语音接口的次数与音频秒数。
    /// 窗内样本不足两个、或服务重启导致计数回退时整体为空——那是无数据，不是 0。
    public var usageIncrease: RuntimeUsageTotals {
        guard let first = samples.first, let last = samples.last, samples.count > 1 else {
            return RuntimeUsageTotals()
        }
        return last.usage.delta(since: first.usage)
    }

    /// 窗内 5xx 次数。首屏「有没有出错」问的是次数，不是每秒速率。
    public var errorIncrease: Double? { monotonicIncrease(\.requestErrors) }

    /// 窗内被准入策略拒绝的次数。
    public var queueRejectionIncrease: Double? { monotonicIncrease(\.queueRejections) }

    /// 单调计数器（只增）的窗内增量，**缺失的序列按 0 处理**。
    ///
    /// 计数器的序列只在第一次自增时才出现：没有失败过，`status="5xx"` 的序列就根本不存在。
    /// 若照搬 `increaseOf`，首屏会显示「— 等待样本」，用户读到的是「读不到」，
    /// 而事实是「这期间一次都没有」。相反，两侧都有序列时只要有回退（服务重启）
    /// 就仍然是 `nil`——那是真的读不到。
    private func monotonicIncrease(
        _ keyPath: KeyPath<RuntimeMetricsSample, Double?>
    ) -> Double? {
        guard let first = samples.first, let last = samples.last, samples.count > 1 else {
            return nil
        }
        let earlier = first[keyPath: keyPath] ?? 0
        let current = last[keyPath: keyPath] ?? 0
        guard current >= earlier else { return nil }
        return current - earlier
    }

    private func increaseOf(
        _ keyPath: KeyPath<RuntimeMetricsSample, Double?>
    ) -> Double? {
        guard let first = samples.first,
              let last = samples.last,
              samples.count > 1,
              let firstValue = first[keyPath: keyPath],
              let lastValue = last[keyPath: keyPath],
              lastValue >= firstValue
        else { return nil }
        return lastValue - firstValue
    }

    private func rate(
        _ keyPath: KeyPath<RuntimeMetricsSample, Double?>
    ) -> Double? {
        guard let increase = increaseOf(keyPath), let seconds = windowSeconds else {
            return nil
        }
        return increase / seconds
    }

    private func histogramAverage(
        _ keyPath: KeyPath<RuntimeMetricsSample, RuntimeHistogramTotals?>
    ) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        return last[keyPath: keyPath]?.delta(since: first[keyPath: keyPath])?.average
    }
}

// MARK: - 服务落盘的历史指标

/// 服务每 60 秒把一段区间写进 `<app home>/state/metrics-rollup/YYYY-MM-DD.jsonl`
/// （服务端 `src/speechrail/observability/rollup.py`，按 UTC 日期分文件、默认保留 30 天）。
///
/// App 自己的采样只留 60 个点（5 分钟）且随 App 退出丢失，所以「上周有没有变慢」这类问题
/// 只能由这份文件回答：它跨服务重启保留，行内容是一段区间的增量而不是累计值。
/// 字段与服务端的行结构 1:1 对应；缺字段一律按「读不到」处理，不按 0 处理。
public struct MetricsHistoryRecord: Decodable, Sendable {
    public struct Requests: Decodable, Sendable {
        public let httpTotal: Double?
        public let speechTotal: Double?
        public let tts: Double?
        public let asr: Double?
        public let failed: Double?
        public let clientErrors: Double?
    }

    public struct AudioSeconds: Decodable, Sendable {
        public let tts: Double?
        public let asr: Double?
    }

    /// 服务端以毫秒给出，且只有 `count`/`avg`/`p50`/`p95` 四个字段。
    public struct LatencyEntry: Decodable, Sendable {
        public let count: Double?
        public let avg: Double?
        public let p50: Double?
        public let p95: Double?
    }

    public struct Latency: Decodable, Sendable {
        public let tts: LatencyEntry?
        public let asr: LatencyEntry?
    }

    public struct Realtime: Decodable, Sendable {
        public let sessions: Double?
        public let turns: Double?
        public let bargeinEvents: Double?
        public let activeSessions: Double?
    }

    public struct Capacity: Decodable, Sendable {
        public let queueRejections: Double?
        public let active: Double?
        public let pending: Double?
        public let activePeak: Double?
        public let pendingPeak: Double?
        public let totalCapacity: Double?
    }

    public struct Memory: Decodable, Sendable {
        public let physicalFootprintBytes: Double?
        public let footprintComplete: Bool?
        public let footprintProcessCount: Double?
        public let declaredFootprintBytes: Double?
    }

    public struct Workers: Decodable, Sendable {
        public let states: [String: String]?
        public let evictions: Double?
    }

    public let schemaVersion: Int?
    public let kind: String?
    public let serviceVersion: String?
    public let profile: String?
    public let pid: Int?
    public let intervalStart: Date?
    public let intervalEnd: Date?
    public let intervalSeconds: Double?
    public let processStartedAt: Date?
    public let uptimeSeconds: Double?
    public let requests: Requests?
    public let audioSeconds: AudioSeconds?
    public let latencyMs: Latency?
    public let realtime: Realtime?
    public let capacity: Capacity?
    public let memory: Memory?
    public let workers: Workers?
}

/// 一个统计桶（跨度大约 60 个点，具体粒度见 `MetricsHistoryLoader.bucketSeconds`）。
///
/// 只有桶里真的有记录时才存在——空桶不画点，避免把「服务没运行」画成「用量归零」。
public struct MetricsHistoryPoint: Identifiable, Equatable, Sendable {
    public let id: Date
    public let start: Date
    public let end: Date
    public let coveredSeconds: Double
    public let ttsRequests: Double
    public let asrRequests: Double
    public let failedRequests: Double
    public let ttsAudioSeconds: Double
    public let asrAudioSeconds: Double
    public let activePeak: Double
    public let pendingPeak: Double
    public let queueRejections: Double
    public let workerEvictions: Double
    public let memoryPeakBytes: Double?
    public let asrSeconds: Double?
    public let ttsSeconds: Double?
    public let asrP95Seconds: Double?
    public let ttsP95Seconds: Double?
}

/// 整个跨度上的合计。耗时是按时长样本量加权的窗口均值，`p95` 取区间内最大值。
public struct MetricsHistoryTotals: Equatable, Sendable {
    public let ttsRequests: Double
    public let asrRequests: Double
    public let failedRequests: Double
    public let clientErrors: Double
    public let ttsAudioSeconds: Double
    public let asrAudioSeconds: Double
    public let queueRejections: Double
    public let workerEvictions: Double
    public let activePeak: Double
    public let pendingPeak: Double
    public let memoryPeakBytes: Double?
    public let asrSeconds: Double?
    public let ttsSeconds: Double?
    public let asrP95Seconds: Double?
    public let ttsP95Seconds: Double?

    public static let empty = MetricsHistoryTotals(
        ttsRequests: 0,
        asrRequests: 0,
        failedRequests: 0,
        clientErrors: 0,
        ttsAudioSeconds: 0,
        asrAudioSeconds: 0,
        queueRejections: 0,
        workerEvictions: 0,
        activePeak: 0,
        pendingPeak: 0,
        memoryPeakBytes: nil,
        asrSeconds: nil,
        ttsSeconds: nil,
        asrP95Seconds: nil,
        ttsP95Seconds: nil
    )
}

/// 一段跨度的历史读数。目录不存在或没有记录时依然是一个可展示的对象，
/// 页面要能说清「没有历史数据」与「目录是哪个」，而不是显示一片空白。
public struct MetricsHistory: Equatable, Sendable {
    public let directoryPath: String
    public let directoryExists: Bool
    public let windowSeconds: Double
    public let bucketSeconds: Double
    public let rangeStart: Date
    public let rangeEnd: Date
    public let points: [MetricsHistoryPoint]
    public let totals: MetricsHistoryTotals
    /// 落在跨度内的记录条数。
    public let recordCount: Int
    /// 读不动的行数（半截写入、字段缺失、时间戳非法）。不等于 0 时页面要说明。
    public let skippedLines: Int
    /// 行内 `interval_seconds` 之和：真实被记录覆盖的秒数，可能小于跨度。
    public let coveredSeconds: Double
    /// 跨度内服务重启次数（相邻记录的 pid 变化次数）。
    public let restarts: Int
    /// 相邻记录之间的空档个数（重启或服务停摆留下的洞）。
    public let gaps: Int
    public let lastRecordedAt: Date?
    public let serviceVersions: [String]
    public let profiles: [String]

    public var isEmpty: Bool { recordCount == 0 }
}

/// App 读取本机落盘产物时用的位置：历史指标目录与日志目录。
///
/// 默认按服务的默认约定解析（app home 下的 `state/metrics-rollup`、
/// `~/Library/Logs/SpeechRail`），并尊重 `SPEECHRAIL_APP_HOME`、
/// `SPEECHRAIL_METRICS_ROLLUP_DIR`、`SPEECHRAIL_LOG_DIR` 三个覆盖。
/// 做成可注入的值而不是散落的路径计算，是为了让页面能在测试里指向临时目录。
public struct ObservabilityLocation: Equatable, Sendable {
    public let appHome: URL
    public let historyDirectory: URL
    public let logDirectory: URL

    public init(appHome: URL, historyDirectory: URL, logDirectory: URL) {
        self.appHome = appHome
        self.historyDirectory = historyDirectory
        self.logDirectory = logDirectory
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ObservabilityLocation {
        let appHome = managedAppHome(environment: environment)
        return ObservabilityLocation(
            appHome: appHome,
            historyDirectory: MetricsHistoryLoader.directory(appHome: appHome, environment: environment),
            logDirectory: MetricsHistoryLoader.logDirectory(appHome: appHome, environment: environment)
        )
    }

    public static var `default`: ObservabilityLocation { resolve() }

    /// 服务与 App 共用的 app home 约定：`SPEECHRAIL_APP_HOME`，否则
    /// `~/Library/Application Support/SpeechRail`（与 `ManagedRuntimeLocator.default` 一致）。
    private static func managedAppHome(environment: [String: String]) -> URL {
        let configured = environment["SPEECHRAIL_APP_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpeechRail", isDirectory: true)
    }
}

public enum MetricsHistoryLoader {
    /// 默认目录名，与服务端 `default_rollup_path` 一致（app home 下的 `state/metrics-rollup`）。
    public static let defaultDirectoryName = "state/metrics-rollup"

    /// 服务端把「区间写得比现在这行更宽」视为正常：写失败时下一行会覆盖该区间。
    /// 超过默认采样周期一倍，就说明这段时间里没有写入——那是空档。
    private static let nominalIntervalSeconds = 60.0
    private static let gapToleranceSeconds = 30.0

    /// 历史目录。服务端可被 `SPEECHRAIL_METRICS_ROLLUP_DIR` 覆盖（环境变量或
    /// `{app home}/config/.env`），这里按同一优先级解析，否则 App 会去看一个不存在的目录。
    public static func directory(
        appHome: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = configuredPath(
            named: "SPEECHRAIL_METRICS_ROLLUP_DIR",
            appHome: appHome,
            environment: environment
        ) {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return appHome.appendingPathComponent(defaultDirectoryName, isDirectory: true)
    }

    /// 日志目录。默认 `~/Library/Logs/SpeechRail`，同样允许服务端配置覆盖。
    public static func logDirectory(
        appHome: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = configuredPath(
            named: "SPEECHRAIL_LOG_DIR",
            appHome: appHome,
            environment: environment
        ) {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SpeechRail", isDirectory: true)
    }

    /// 桶粒度：目标是大约 60 个点，坐标轴刻度才好读。
    ///
    /// 用固定梯级而不是「跨度/60」的连续值：桶边界按绝对时间对齐，梯级能让两次刷新之间
    /// 的点不会因为粒度变化而整体位移。
    public static func bucketSeconds(forWindowSeconds seconds: Double) -> Double {
        let target = max(nominalIntervalSeconds, (seconds / 60.0).rounded(.up))
        let ladder: [Double] = [60, 300, 900, 1800, 3600, 10800, 21600, 43200, 86400]
        return ladder.first { $0 >= target } ?? ladder[ladder.count - 1]
    }

    /// 读取 `[now - windowSeconds, now]` 的历史并聚合成桶。
    ///
    /// 不抛错：读不动目录就是「没有历史」，页面需要区分「没数据」与「服务异常」。
    public static func load(
        directory: URL,
        now: Date,
        windowSeconds: Double,
        bucketSeconds explicitBucketSeconds: Double? = nil
    ) -> MetricsHistory {
        let fileManager = FileManager.default
        let window = max(windowSeconds, nominalIntervalSeconds)
        let rangeStart = now.addingTimeInterval(-window)
        let bucketSeconds = explicitBucketSeconds ?? bucketSeconds(forWindowSeconds: window)
        var directoryExists = false
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            directoryExists = isDirectory.boolValue
        }

        var records: [MetricsHistoryRecord] = []
        var skippedLines = 0
        if directoryExists {
            let decoder = makeDecoder()
            for file in candidateFiles(
                in: directory,
                since: rangeStart.addingTimeInterval(-86_400),
                fileManager: fileManager
            ) {
                guard let data = try? Data(contentsOf: file),
                      let contents = String(data: data, encoding: .utf8)
                else {
                    skippedLines += 1
                    continue
                }
                for rawLine in contents.split(whereSeparator: \.isNewline) {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    guard !line.isEmpty else { continue }
                    guard let data = line.data(using: .utf8),
                          let record = try? decoder.decode(MetricsHistoryRecord.self, from: data),
                          let start = record.intervalStart
                    else {
                        skippedLines += 1
                        continue
                    }
                    guard start >= rangeStart, start <= now else { continue }
                    records.append(record)
                }
            }
            records.sort { ($0.intervalStart ?? .distantPast) < ($1.intervalStart ?? .distantPast) }
        }

        return summarize(
            records: records,
            directory: directory,
            directoryExists: directoryExists,
            skippedLines: skippedLines,
            now: now,
            windowSeconds: window,
            bucketSeconds: bucketSeconds
        )
    }

    /// 从已解码的记录聚合。单独暴露是为了让聚合口径可以被直接测试，
    /// 不必为了验证一个加权平均去写一整套文件。
    public static func summarize(
        records: [MetricsHistoryRecord],
        directory: URL,
        directoryExists: Bool = true,
        skippedLines: Int = 0,
        now: Date,
        windowSeconds: Double,
        bucketSeconds: Double
    ) -> MetricsHistory {
        var buckets: [Date: MetricsHistoryAccumulator] = [:]
        var totals = MetricsHistoryAccumulator(start: now, end: now)
        var coveredSeconds = 0.0
        var restarts = 0
        var gaps = 0
        var previous: MetricsHistoryRecord?
        var versions: [String] = []
        var profiles: [String] = []
        let tolerance = gapToleranceSeconds

        for record in records {
            guard let start = record.intervalStart else { continue }
            let end = record.intervalEnd ?? start
            coveredSeconds += record.intervalSeconds ?? max(end.timeIntervalSince(start), 0)
            totals.add(record)

            let key = bucketStart(for: start, bucketSeconds: bucketSeconds)
            var accumulator = buckets[key] ?? MetricsHistoryAccumulator(start: key, end: end)
            accumulator.add(record)
            buckets[key] = accumulator

            if let previous, let previousStart = previous.intervalStart {
                if let previousPid = previous.pid, let pid = record.pid, previousPid != pid {
                    restarts += 1
                } else {
                    let previousEnd = previous.intervalEnd ?? previousStart
                    if start.timeIntervalSince(previousEnd) > tolerance {
                        gaps += 1
                    }
                }
            }
            if let version = record.serviceVersion, !version.isEmpty, versions.last != version {
                if !versions.contains(version) { versions.append(version) }
            }
            if let profile = record.profile, !profile.isEmpty, !profiles.contains(profile) {
                profiles.append(profile)
            }
            previous = record
        }

        let points = buckets
            .sorted { $0.key < $1.key }
            .map { $0.value.point }

        return MetricsHistory(
            directoryPath: directory.path,
            directoryExists: directoryExists,
            windowSeconds: windowSeconds,
            bucketSeconds: bucketSeconds,
            rangeStart: now.addingTimeInterval(-windowSeconds),
            rangeEnd: now,
            points: points,
            totals: totals.totals,
            recordCount: records.count,
            skippedLines: skippedLines,
            coveredSeconds: coveredSeconds,
            restarts: restarts,
            gaps: gaps,
            lastRecordedAt: records.compactMap { $0.intervalEnd ?? $0.intervalStart }.max(),
            serviceVersions: versions,
            profiles: profiles
        )
    }

    private static func bucketStart(for date: Date, bucketSeconds: Double) -> Date {
        let interval = max(bucketSeconds, nominalIntervalSeconds)
        let index = (date.timeIntervalSince1970 / interval).rounded(.down)
        return Date(timeIntervalSince1970: index * interval)
    }

    /// 只读跨度里可能相关的文件：文件名是 UTC 日期，比跨度起点早一天以后的都算候选。
    private static func candidateFiles(
        in directory: URL,
        since cutoff: Date,
        fileManager: FileManager
    ) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .filter { file in
                guard let day = fileDay(file) else { return true }
                return day >= cutoff.addingTimeInterval(-86_400)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func fileDay(_ file: URL) -> Date? {
        let name = file.deletingPathExtension().lastPathComponent
        return try? Date(name, strategy: .iso8601.year().month().day())
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseTimestamp(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "不是合法的 ISO8601 时间戳"
                )
            }
            return date
        }
        return decoder
    }

    /// 服务端写的是 `2026-09-16T10:22:44.373Z`（带毫秒）。这里两种都收，
    /// 因为不带小数秒的写法同样合法。
    private static func parseTimestamp(_ raw: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(raw)
    }

    /// 环境变量优先，其次 `{app home}/config/.env`（服务端设置文件）。
    /// 只解析这一个键，不把整份配置读进内存。
    private static func configuredPath(
        named name: String,
        appHome: URL,
        environment: [String: String]
    ) -> String? {
        if let value = normalizedPath(environment[name]) {
            return value
        }
        let envFile = appHome
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(".env", isDirectory: false)
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }
            let raw = String(line[line.index(after: separator)...])
            return normalizedPath(raw)
        }
        return nil
    }

    private static func normalizedPath(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return (value as NSString).expandingTildeInPath
    }
}

/// 桶与合计共用一套累加口径：次数、时长、拒绝、驱逐求和，峰值取最大，
/// 耗时用「样本数加权」的窗口均值，p95 取区间内最大值。
private struct MetricsHistoryAccumulator {
    var start: Date
    var end: Date
    var coveredSeconds = 0.0
    var records = 0
    var ttsRequests = 0.0
    var asrRequests = 0.0
    var failedRequests = 0.0
    var clientErrors = 0.0
    var ttsAudioSeconds = 0.0
    var asrAudioSeconds = 0.0
    var activePeak = 0.0
    var pendingPeak = 0.0
    var queueRejections = 0.0
    var workerEvictions = 0.0
    var memoryPeakBytes: Double?
    var asrLatencyWeighted = 0.0
    var asrLatencyCount = 0.0
    var ttsLatencyWeighted = 0.0
    var ttsLatencyCount = 0.0
    var asrP95Seconds: Double?
    var ttsP95Seconds: Double?

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    mutating func add(_ record: MetricsHistoryRecord) {
        records += 1
        if let start = record.intervalStart { self.start = min(self.start, start) }
        let recordEnd = record.intervalEnd ?? record.intervalStart ?? end
        end = max(end, recordEnd)
        coveredSeconds += record.intervalSeconds ?? 0
        if let requests = record.requests {
            ttsRequests += requests.tts ?? 0
            asrRequests += requests.asr ?? 0
            failedRequests += requests.failed ?? 0
            clientErrors += requests.clientErrors ?? 0
        }
        if let audio = record.audioSeconds {
            ttsAudioSeconds += audio.tts ?? 0
            asrAudioSeconds += audio.asr ?? 0
        }
        if let capacity = record.capacity {
            activePeak = max(activePeak, capacity.activePeak ?? 0)
            pendingPeak = max(pendingPeak, capacity.pendingPeak ?? 0)
            queueRejections += capacity.queueRejections ?? 0
        }
        workerEvictions += record.workers?.evictions ?? 0
        if let memory = record.memory,
           memory.footprintComplete != false,
           let footprint = memory.physicalFootprintBytes {
            memoryPeakBytes = max(memoryPeakBytes ?? footprint, footprint)
        }
        let asrContribution = Self.latencyContribution(record.latencyMs?.asr)
        asrLatencyWeighted += asrContribution.weighted
        asrLatencyCount += asrContribution.count
        let ttsContribution = Self.latencyContribution(record.latencyMs?.tts)
        ttsLatencyWeighted += ttsContribution.weighted
        ttsLatencyCount += ttsContribution.count
        asrP95Seconds = maxOptional(asrP95Seconds, seconds(fromMilliseconds: record.latencyMs?.asr?.p95))
        ttsP95Seconds = maxOptional(ttsP95Seconds, seconds(fromMilliseconds: record.latencyMs?.tts?.p95))
    }

    /// 一条时延记录的加权贡献：`avg × 样本数` 与样本数本身。
    /// 窗口均值由 `Σ(avg×count) / Σcount` 得出，而不是把各行的均值再平均一次
    /// ——后者会让样本少的区间和样本多的区间一样重。
    private static func latencyContribution(
        _ entry: MetricsHistoryRecord.LatencyEntry?
    ) -> (weighted: Double, count: Double) {
        guard let entry, let observations = entry.count, observations > 0, let average = entry.avg else {
            return (0, 0)
        }
        return (average * observations, observations)
    }

    private func seconds(fromMilliseconds value: Double?) -> Double? {
        guard let value else { return nil }
        return value / 1000
    }

    private func maxOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let rhs else { return lhs }
        return max(lhs ?? rhs, rhs)
    }

    var totals: MetricsHistoryTotals {
        MetricsHistoryTotals(
            ttsRequests: ttsRequests,
            asrRequests: asrRequests,
            failedRequests: failedRequests,
            clientErrors: clientErrors,
            ttsAudioSeconds: ttsAudioSeconds,
            asrAudioSeconds: asrAudioSeconds,
            queueRejections: queueRejections,
            workerEvictions: workerEvictions,
            activePeak: activePeak,
            pendingPeak: pendingPeak,
            memoryPeakBytes: memoryPeakBytes,
            asrSeconds: weightedAverage(weighted: asrLatencyWeighted, count: asrLatencyCount),
            ttsSeconds: weightedAverage(weighted: ttsLatencyWeighted, count: ttsLatencyCount),
            asrP95Seconds: asrP95Seconds,
            ttsP95Seconds: ttsP95Seconds
        )
    }

    var point: MetricsHistoryPoint {
        MetricsHistoryPoint(
            id: start,
            start: start,
            end: end,
            coveredSeconds: coveredSeconds,
            ttsRequests: ttsRequests,
            asrRequests: asrRequests,
            failedRequests: failedRequests,
            ttsAudioSeconds: ttsAudioSeconds,
            asrAudioSeconds: asrAudioSeconds,
            activePeak: activePeak,
            pendingPeak: pendingPeak,
            queueRejections: queueRejections,
            workerEvictions: workerEvictions,
            memoryPeakBytes: memoryPeakBytes,
            asrSeconds: weightedAverage(weighted: asrLatencyWeighted, count: asrLatencyCount),
            ttsSeconds: weightedAverage(weighted: ttsLatencyWeighted, count: ttsLatencyCount),
            asrP95Seconds: asrP95Seconds,
            ttsP95Seconds: ttsP95Seconds
        )
    }

    private func weightedAverage(weighted: Double, count: Double) -> Double? {
        guard count > 0 else { return nil }
        return weighted / count / 1000
    }
}
