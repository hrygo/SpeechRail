import Foundation

/// 决定"这一轮什么时候第一次开嗓，以及开嗓前后的**原始**文本怎么交给朗读"。
///
/// 以前的做法是"`delta` 去掉空白后非空才 `offer`"。那会把纯空白的增量直接丢掉，
/// 于是 LLM 分成 `"你好"`、`" "`、`"世界"` 三段到达时，朗读输入粘成 `"你好世界"`，
/// 词边界消失；反过来整轮只有空白时，判断逻辑散在调用方，无法证明它不会开嗓。
///
/// 规则：
///
///   1. 只有**累计**文本里出现非空白字符，才允许第一次 start；
///   2. start 之前把原始增量攒进有界缓冲，成功 start 后**一次**交出去并清空；
///   3. start 之后每个增量原样 offer，空格和换行都照原样传给清洗层；
///   4. 缓冲超限按整轮上限明确失败，不另开无界缓冲。
struct AssistantSpeechStartGate {
    struct Configuration {
        /// 开嗓前原始缓冲的上限（Unicode scalar）。复用整轮上限。
        var maximumPendingScalars = AssistantSpeechTextBuffer.Configuration.default.maximumTotalScalars

        static let `default` = Configuration()
    }

    enum Offer: Equatable {
        /// 还不到开嗓的时候：这一段已被原样缓冲。
        case buffered
        /// 该开嗓了，`pending` 是开嗓前缓冲的原始文本。
        case start(pending: String)
        /// 已经开嗓：这一段原样交出去（含空格与换行）。
        case speak(String)
    }

    enum Limit: Equatable {
        case pending(offered: Int, limit: Int)
    }

    private let configuration: Configuration
    private var pending: [Unicode.Scalar] = []
    private var startDisabled = false

    private(set) var isStarted = false
    private(set) var lastLimit: Limit?

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// 开嗓前缓冲里还压着的原始 scalar 数。
    var pendingScalars: Int { pending.count }

    /// 第一次 start 失败：这一轮不再自动朗读，但正文与落库照常继续。
    mutating func disableStarting() {
        isStarted = false
        startDisabled = true
        pending.removeAll()
    }

    mutating func offer(_ delta: String) -> Offer {
        if isStarted {
            return .speak(delta)
        }
        guard !startDisabled else { return .buffered }
        pending.append(contentsOf: delta.unicodeScalars)
        guard pending.count <= configuration.maximumPendingScalars else {
            lastLimit = .pending(offered: pending.count, limit: configuration.maximumPendingScalars)
            startDisabled = true
            pending.removeAll()
            return .buffered
        }
        // 只有出现非空白字符才开嗓：整轮空白不会白开一次 TTS。
        guard pending.contains(where: { !$0.properties.isWhitespace }) else { return .buffered }
        let text = String(String.UnicodeScalarView(pending))
        pending.removeAll()
        isStarted = true
        return .start(pending: text)
    }
}

/// 把 LLM 的流式增量文本切成**已经可以安全朗读**的前缀。
///
/// 它只解决一件事：同一轮 utterance 里，"什么时候把这段文本交给模型"。
/// 三条硬规则：
///
///   1. **不切开还在长的东西**——数字/单位（`3.5` + `kg`）、英文尾词（`Hel` + `lo`）；
///   2. **不切开没闭合的 Markdown**——`**粗体` 要等 `**` 到齐；
///   3. **最多等 `maximumPendingWait`**——宁可切在稍差的位置，也不能攒文本不动，
///      否则低首音延迟直接消失（低延迟优先于完美分词）。
///
/// 限额按 **Unicode scalar**（= codepoint）计，与服务端 `max_append_codepoints` 同一种度量；
/// 不能用 `String.count`（grapheme）冒充。清洗、显示、落库都用原始文本，
/// 这里产出的只是"交给 TTS 的那一份"。
struct AssistantSpeechTextBuffer {
    struct Configuration {
        /// 第一片文本之后最多等多久必须出声。
        var maximumPendingWait: Duration = .milliseconds(150)
        /// 保守模式下，非句末断点至少要凑够这么多个 scalar 才切。
        var minimumChunkScalars = 24
        /// 单片上限（服务端 `max_append_codepoints` 默认值）。
        var maximumChunkScalars = 512
        /// 整轮上限（服务端 `max_total_codepoints` 默认值）。
        var maximumTotalScalars = 4_096

        static let `default` = Configuration()
    }

    enum Limit: Equatable {
        case append(offered: Int, limit: Int)
        case total(offered: Int, limit: Int)
    }

    private let configuration: Configuration
    /// 注入时钟：测试用手动 tick，不实际 sleep。
    private let now: () -> ContinuousClock.Instant
    private var pending: [Unicode.Scalar] = []
    private var pendingSince: ContinuousClock.Instant?
    private(set) var offeredScalars = 0
    private(set) var lastLimit: Limit?

    init(
        configuration: Configuration = .default,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.configuration = configuration
        self.now = now
    }

    var pendingScalars: Int { pending.count }

    var pendingText: String { String(String.UnicodeScalarView(pending)) }

    var hasPendingText: Bool { !pending.isEmpty }

    var hasExpired: Bool { lastLimit != nil }

    /// 计入一段新到的增量。返回被触碰的限额（`nil` 表示这一段仍在预算内）。
    ///
    /// VA-11：合法 600 scalar 可一次到达，不拿 512 append 限额拒绝 provider delta。
    /// 准入先计算 candidate counts，再变更 pending/offered；单 delta 超 append
    /// 上限时仍准入，后续按安全点切分（readyChunks/flush 按 maximumChunkScalars
    /// 切片），只在整轮 total 超限时拒绝。
    mutating func append(_ delta: String) -> Limit? {
        let scalars = Array(delta.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        // 先算 candidate：超 total 才拒绝，原状态不变。
        let candidateOffered = offeredScalars + scalars.count
        if candidateOffered > configuration.maximumTotalScalars {
            let limit = Limit.total(offered: candidateOffered, limit: configuration.maximumTotalScalars)
            lastLimit = limit
            return limit
        }
        offeredScalars = candidateOffered
        if pending.isEmpty {
            pendingSince = now()
        }
        pending.append(contentsOf: scalars)
        return nil
    }

    /// 取出现在可以朗读的前缀。
    ///
    /// 三档紧急度，越往后越不挑断点：
    /// - 还没到 `maximumPendingWait`：只切在"天然停顿时且尾巴不会继续"的位置；
    /// - 到点了：退一步，切在最后一个天然停顿处（没有停顿就整段交出去）；
    /// - `force`（文本泵连等若干轮都没切出来，例如永不闭合的 Markdown）：整段交出去，
    ///   宁可读得难看，也不能把一轮 utterance 无限期卡住。
    mutating func readyChunks(now: ContinuousClock.Instant, force: Bool = false) -> [String] {
        var chunks: [String] = []
        while !pending.isEmpty {
            // 硬上限：无论断点好不好看，都不能让 pending 无界增长。
            if pending.count >= configuration.maximumChunkScalars {
                chunks.append(take(upTo: configuration.maximumChunkScalars, now: now))
                continue
            }
            let waitedLongEnough = pendingSince.map {
                $0.duration(to: now) >= configuration.maximumPendingWait
            } ?? false
            let urgency: Urgency = force ? .forced : (waitedLongEnough ? .deadline : .conservative)
            guard let cut = safeCut(urgency: urgency) else { break }
            chunks.append(take(upTo: cut, now: now))
        }
        return chunks
    }

    /// LLM 结束：剩下的全部交出去，按单片上限切开（永远不留尾巴）。
    mutating func flush(now: ContinuousClock.Instant) -> [String] {
        var chunks: [String] = []
        while !pending.isEmpty {
            let cut = min(pending.count, configuration.maximumChunkScalars)
            chunks.append(take(upTo: cut, now: now))
        }
        return chunks
    }

    mutating func reset() {
        pending.removeAll()
        pendingSince = nil
        offeredScalars = 0
        lastLimit = nil
    }

    enum Urgency: Equatable {
        case conservative
        case deadline
        case forced
    }

    private mutating func take(upTo cut: Int, now: ContinuousClock.Instant) -> String {
        let chunk = String(String.UnicodeScalarView(pending[0..<cut]))
        pending.removeFirst(cut)
        pendingSince = pending.isEmpty ? nil : now
        return chunk
    }

    /// 找一个**安全**的切点：切在 `cut` 处表示这一段结束、`pending[cut...]` 留着。
    private func safeCut(urgency: Urgency) -> Int? {
        guard !pending.isEmpty else { return nil }

        // 已经到了"必须出声"的档：不再挑断点，整段交出去。
        if urgency == .forced {
            return pending.count
        }

        var index = pending.count
        while index > 0 {
            if isUsableBreak(index), markdownBalanced(upTo: index),
               index == pending.count || !joinsTokens(pending[index - 1], pending[index]) {
                let previous = pending[index - 1]
                let keepsTokenOpen = Self.continuableTailScalars.contains(previous)
                switch urgency {
                case .deadline:
                    // 尾巴还在长（数字/单位/英文词）就先别切在这一刀上，往下找个天然停顿。
                    if index == pending.count, keepsTokenOpen { break }
                    return index
                case .conservative:
                    let strong = Self.strongTerminators.contains(previous)
                    if !keepsTokenOpen, strong || index >= configuration.minimumChunkScalars {
                        return index
                    }
                case .forced:
                    return index
                }
            }
            index -= 1
        }

        // 到点了却连一个天然停顿都没有：整段交出去（Markdown 没闭合除外）。
        if urgency == .deadline, markdownBalanced(upTo: pending.count) {
            return pending.count
        }
        return nil
    }

    /// 切点只能落在一个天然停顿的后面；`count` 表示"正好把 pending 全部交出去"。
    private func isUsableBreak(_ index: Int) -> Bool {
        guard index < pending.count else { return true }
        return Self.breakScalars.contains(pending[index - 1])
    }

    /// `previous` 与 `next` 之间是否**不该切**：数字/单位、英文单词内部。
    private func joinsTokens(_ previous: Unicode.Scalar, _ next: Unicode.Scalar) -> Bool {
        if Self.digits.contains(previous) {
            return Self.digits.contains(next) || next == "." || next == "," || next == "%"
                || Self.asciiLetters.contains(next)
        }
        if previous == "." || previous == "," || previous == "%" {
            return Self.digits.contains(next) || Self.asciiLetters.contains(next)
        }
        if Self.asciiLetters.contains(previous) {
            return Self.asciiLetters.contains(next) || next == "'" || next == "-"
        }
        return false
    }

    /// `pending[0..<cut]` 里的 Markdown 结构是否闭合（`**`、`` ` ``、`~~`、`[...](...)`）。
    private func markdownBalanced(upTo cut: Int) -> Bool {
        var backticks = 0
        var strong = 0
        var emphasis = 0
        var strikethrough = 0
        var brackets = 0
        var index = 0
        while index < cut {
            let scalar = pending[index]
            switch scalar {
            case "`":
                backticks += 1
            case "*":
                // `**` 一次配对；单个 `*` 是另一种强调，分开记。
                if index + 1 < cut, pending[index + 1] == "*" {
                    strong = strong == 0 ? 1 : 0
                    index += 1
                } else {
                    emphasis = emphasis == 0 ? 1 : 0
                }
            case "~":
                if index + 1 < cut, pending[index + 1] == "~" {
                    strikethrough = strikethrough == 0 ? 1 : 0
                    index += 1
                }
            case "[":
                brackets += 1
            case "]":
                brackets = max(0, brackets - 1)
            default:
                break
            }
            index += 1
        }
        return backticks % 2 == 0 && strong == 0 && emphasis == 0
            && strikethrough == 0 && brackets == 0
    }

    /// 线上限额与服务端同一种度量：Unicode codepoint（= scalar），不是 grapheme。
    static func scalarCount(_ text: String) -> Int { text.unicodeScalars.count }

    private static let strongTerminators: Set<Unicode.Scalar> = ["。", "！", "？", "；", "!", "?", ";", "\n"]
    private static let breakScalars: Set<Unicode.Scalar> =
        strongTerminators.union(["，", "、", "：", ",", ":", " ", "\t", "\u{3000}"])
    /// 结尾是这些字符时，**保守模式**认为后面可能还有（数字/单位/英文单词）。
    /// Markdown 字符不在这里——它们由 `markdownBalanced` 单独负责。
    private static let continuableTailScalars: Set<Unicode.Scalar> =
        digits.union(asciiLetters).union([".", ",", "%", "-"])
    private static let digits: Set<Unicode.Scalar> = Set("0123456789".unicodeScalars)
    private static let asciiLetters: Set<Unicode.Scalar> =
        Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)
}
