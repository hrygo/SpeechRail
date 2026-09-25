import Foundation

/// 一轮 utterance 的**播放预算与结束判定**（纯状态，不持有任何音频缓冲）。
///
/// 为什么要有它：`queuedSamples == 0` 只说明"播放器现在没东西了"，可能是
/// **欠载**（服务端还在生成），也可能是**真的播完**。宣布回到 listening 必须同时满足
/// "服务端已给终态"和"这一代音频已排空"，两者要分开记。
///
/// 迟到完成、旧代取消后的 completion 都不能污染新一代：所有写入口都带 `generation`，
/// 不匹配就整条丢掉。
struct AssistantPlaybackLedger {
    struct Configuration {
        /// 排队样本上限。1 秒 @ 24 kHz mono = 24 000 samples = 48 000 bytes，
        /// 与服务端 `max_pending_audio_bytes` 同一量级。
        var maximumQueuedSamples = 24_000
        static let `default` = Configuration()
    }

    private let configuration: Configuration
    private(set) var generation: Int
    private(set) var queuedSamples = 0
    /// 服务端是否给过终态（completed / cancelled / failed）。
    private(set) var serverTerminal = false
    /// 服务端终态是哪一个；`nil` 表示还没结束。
    private(set) var terminalStatus: String?
    /// 文本输入是否已关闭（`finish_text` 已发出）。用于区分"暂时欠载"与"还没喂完"。
    private(set) var inputClosed = false

    init(configuration: Configuration = .default, generation: Int = 0) {
        self.configuration = configuration
        self.generation = generation
    }

    var maximumQueuedSamples: Int { configuration.maximumQueuedSamples }

    /// 开始新一代：清掉上一代的排队与终态（旧 completion 会因为 generation 不匹配被丢掉）。
    mutating func begin(generation: Int) {
        self.generation = generation
        queuedSamples = 0
        serverTerminal = false
        terminalStatus = nil
        inputClosed = false
    }

    /// 播放器排空。"暂时 drained ≠ 整轮结束"就是这一行的意义。
    var isDrained: Bool { queuedSamples == 0 }

    /// 整轮真正结束：服务端终态 + 该代音频已排空。
    var isUtteranceFinished: Bool { serverTerminal && isDrained }

    /// 是否还能再收下这么多样本。
    func canReserve(samples: Int) -> Bool {
        samples >= 0 && queuedSamples + samples <= configuration.maximumQueuedSamples
    }

    /// 预约预算；超预算返回 `false`（调用方必须等待，不能无界积压）。
    mutating func reserve(samples: Int) -> Bool {
        guard samples > 0 else { return false }
        guard canReserve(samples: samples) else { return false }
        queuedSamples += samples
        return true
    }

    /// 一块音频真的播完了（`dataRendered` 语义，不是 `.dataConsumed`）。
    /// 旧代的 completion 返回 `false` 且不改任何状态。
    mutating func complete(samples: Int, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        queuedSamples = max(0, queuedSamples - max(0, samples))
        return true
    }

    mutating func markInputClosed() {
        inputClosed = true
    }

    /// 服务端终态落到当前代。
    @discardableResult
    mutating func markServerTerminal(status: String, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        serverTerminal = true
        terminalStatus = status
        return true
    }

    /// 取消/打断：立刻作废这一代（排队的样本不算播过）。
    mutating func invalidate() {
        generation += 1
        queuedSamples = 0
        serverTerminal = false
        terminalStatus = nil
        inputClosed = false
    }
}
