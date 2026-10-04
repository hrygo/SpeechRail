import Foundation

/// VA-16 丢块、队列、超时与观测：有界纯状态。
///
/// 单调时钟计量，墙钟仅用于显示；负耗时无效，无样本为 N/A；
/// 观察写失败不抛进主流程；计数有界。
struct AssistantObservability: Sendable {
    /// 音频丢块计数（native samples 与 wire samples 单位分开）。
    var attemptedNativeSamples: Int = 0
    var acceptedNativeSamples: Int = 0
    var droppedNativeSamples: Int = 0
    var wireSamples: Int = 0
    /// 文本在途：pending raw/sent scalar。
    var pendingRawScalars: Int = 0
    var pendingSentScalars: Int = 0
    /// 播放再途：rendered/played 在途 samples。
    var inflightRenderedSamples: Int = 0
    var inflightPlayedSamples: Int = 0
    /// 取消发出/确认、input receipt/Store marker、设备停止完成。
    var cancelsIssued: Int = 0
    var cancelsConfirmed: Int = 0
    var inputReceipts: Int = 0
    var storeMarkers: Int = 0
    var deviceStopsCompleted: Int = 0

    /// 有界：计数饱和不再增长，不溢出。
    mutating func increment(_ keyPath: WritableKeyPath<AssistantObservability, Int>, by value: Int = 1) {
        let current = self[keyPath: keyPath]
        let next = current.addingReportingOverflow(value).partialValue
        self[keyPath: keyPath] = min(next, 1_000_000_000)
    }

    /// 耗时有效性：负耗时无效。
    static func isValidLatency(_ latency: Duration) -> Bool {
        latency >= .zero
    }

    /// 无样本显示 N/A。
    static func displaySamples(_ samples: Int?) -> String {
        guard let samples else { return "N/A" }
        return "\(samples)"
    }
}
