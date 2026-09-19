import Foundation
import Observation

// 内心 OS：会中的**私密**问答（`SESSIONS-SPEC` §14.2，`TECHNICAL-DESIGN` §5.9）。
//
// 三条边界把它与会议正文彻底分开，三条都是**结构**而不是纪律：
//
//   1. **不进会议音频、不进转录**：它只有一条自己的 LLM 请求，与 `RealtimeASRClient` 无关。
//   2. **默认不进纪要**：`in_minutes` 默认 0，「写进纪要」是一个显式动作。
//   3. **上下文只喂本场已确认的转录**：不联网检索。没有证据就说没有证据，
//      并给出已听时长与段数——这是"我不知道"唯一有用的说法。
//
// 问答本身是资产：它写进本机 SQLite（独立于会议正文），会议记录里可回看（§14.2 的"落点"）。

/// 答案的形状（结构化输出）。四段分开，是因为用户对它们的期待不同：
/// 证据要能核对、判断允许带不确定度、措辞要能直接念出来。
public struct InnerOSAnswer: Codable, Hashable, Sendable {
    public struct Evidence: Codable, Hashable, Sendable {
        /// 对应转录里的第几段（`line.ordinal`）。找不到就给 0。
        public var ordinal: Int
        public var quote: String
    }

    public var intent: String
    public var answer: String
    public var draft: String
    public var confidence: String
    public var limitsNote: String
    public var evidence: [Evidence]

    enum CodingKeys: String, CodingKey {
        case intent
        case answer
        case draft
        case confidence
        case limitsNote = "limits_note"
        case evidence
    }

    static var jsonSchema: [String: Any] {
        [
            "type": "json_schema",
            "name": "inner_os_answer",
            "strict": true,
            "schema": [
                "type": "object",
                "additionalProperties": false,
                "required": ["intent", "answer", "draft", "confidence", "limits_note", "evidence"],
                "properties": [
                    "intent": ["type": "string", "enum": ["fact", "analysis", "draft", "mixed"]],
                    "answer": ["type": "string"],
                    "draft": ["type": "string"],
                    "confidence": [
                        "type": "string",
                        "enum": ["high", "medium", "low", "unknown"]
                    ],
                    "limits_note": ["type": "string"],
                    "evidence": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["ordinal", "quote"],
                            "properties": [
                                "ordinal": ["type": "integer"],
                                "quote": ["type": "string"]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    }
}

@MainActor
@Observable
public final class InnerOSSession {
    public enum State: Equatable, Sendable {
        case idle
        case generating
        case answered
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// 本场的问答历史（收起态里那句「已问 N 次」就是它的条数）。
    public private(set) var exchanges: [InnerOSExchange] = []
    /// 当前这一问的证据（按 exchange id 分组）。
    public private(set) var evidence: [String: [InnerOSEvidence]] = [:]
    public private(set) var lastFailure: String?
    /// 抽屉是收起还是展开。**放在会话上而不是视图里**：`⌘⇧I` 是一个全局键，
    /// 它改的必须是同一个状态，否则"按了没反应"会变成视图层级的问题。
    public var isExpanded = false

    private let coordinator: SessionCoordinator
    private let provider = LLMProvider()
    /// 在飞的那一问。**必须留着引用**：`cancel()` 取消的是它，没有引用就只是
    /// 改了一下界面状态，而请求还在跑、还会回来把答案写进库。
    private var askTask: Task<Void, Never>?
    private var sessionID: String?

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    /// 进会议时绑定会话；离开时解绑（问答不跨会话——证据必须能在本场核对）。
    public func bind(sessionID: String?) async {
        self.sessionID = sessionID
        state = .idle
        lastFailure = nil
        guard let sessionID else {
            exchanges = []
            evidence = [:]
            return
        }
        await reload(sessionID: sessionID)
    }

    public func reload(sessionID: String) async {
        exchanges = (try? await coordinator.innerOSExchanges(sessionID: sessionID)) ?? []
        var gathered: [String: [InnerOSEvidence]] = [:]
        for exchange in exchanges {
            gathered[exchange.id] =
                (try? await coordinator.innerOSEvidence(exchangeID: exchange.id)) ?? []
        }
        evidence = gathered
    }

    /// 提问。**单查询、可取消**；取消不影响录制与已经写进去的转录（§14.2）。
    ///
    /// 提问本身不进 `await` 链：界面按下去就返回，只有这一问在飞（`askTask` 是唯一的
    /// 句柄）。同一时刻只允许一问——再问一次会取消上一问，而不是两条回答争同一块界面。
    public func ask(_ question: String, configuration: LLMConfiguration) {
        askTask?.cancel()
        askTask = Task { [weak self] in
            await self?.performAsk(question, configuration: configuration)
        }
    }

    private func performAsk(_ question: String, configuration: LLMConfiguration) async {
        defer { askTask = nil }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionID else { return }
        guard configuration.isConfigured else {
            state = .failed("还没有配置对话模型（设置 → 会话）。")
            lastFailure = state.failureText
            return
        }

        let lines = (try? await coordinator.lines(sessionID: sessionID)) ?? []
        let names = (try? await coordinator.speakerNames(sessionID: sessionID)) ?? [:]
        let ordinal = lines.last?.ordinal

        var exchange = InnerOSExchange(
            id: UUID().uuidString,
            sessionID: sessionID,
            atOrdinal: ordinal,
            question: trimmed,
            model: configuration.model.isEmpty ? nil : configuration.model,
            status: .generating
        )
        // 先落一条 `generating`：取消也留痕，"问过什么"永远查得到（问答是资产）。
        _ = try? await coordinator.saveInnerOSExchange(exchange)
        exchanges.append(exchange)
        state = .generating
        lastFailure = nil

        let answerText: String
        do {
            answerText = try await provider.complete(
                configuration: configuration,
                messages: Self.prompt(question: trimmed, lines: lines, names: names),
                apiKey: LLMKeychain.load(),
                maxOutputTokens: 1_200,
                textFormat: InnerOSAnswer.jsonSchema,
                timeout: 90
            )
        } catch {
            // 取消与受阻要分开：取消是用户按的，它不该留一条"失败"，也不该把
            // 界面停在错误态上（§14.2「取消不影响录制与已经写进去的转录」）。
            let cancelled = Task.isCancelled || (error as? LLMError) == .cancelled
            let reason = cancelled
                ? "这一问取消了，没有写进答案。"
                : error.localizedDescription
            exchange.status = cancelled ? .cancelled : .failed
            exchange.answerText = nil
            exchange.limitsNote = reason
            _ = try? await coordinator.saveInnerOSExchange(exchange)
            if let index = exchanges.lastIndex(where: { $0.id == exchange.id }) {
                exchanges[index] = exchange
            }
            if cancelled {
                state = .idle
                lastFailure = nil
            } else {
                state = .failed(reason)
                lastFailure = reason
            }
            return
        }

        let decoded = Self.decode(answerText)
        exchange.answerText = decoded.answer
        exchange.draftText = decoded.draft.isEmpty ? nil : decoded.draft
        exchange.intent = InnerOSIntent(rawValue: decoded.intent)
        exchange.confidence = InnerOSConfidence(rawValue: decoded.confidence)
        exchange.limitsNote = decoded.limitsNote.isEmpty ? nil : decoded.limitsNote
        exchange.status = .ready

        // 证据锚回具体的行：ordinal → 行 id / 匿名标签 / 时间码。找不到就只留引文
        // （`InnerOSEvidence` 的注释写了为什么：引文本身才是事实）。
        let byOrdinal = Dictionary(uniqueKeysWithValues: lines.map { ($0.ordinal, $0) })
        let evidenceRows: [InnerOSEvidence] = decoded.evidence.map { item in
            let line = byOrdinal[item.ordinal]
            return InnerOSEvidence(
                lineID: line?.id,
                speakerLabel: line?.speakerLabel,
                tStart: line?.tStart,
                quote: item.quote.isEmpty ? nil : item.quote,
                contentHash: nil
            )
        }
        _ = try? await coordinator.saveInnerOSExchange(exchange, evidence: evidenceRows)
        if let index = exchanges.lastIndex(where: { $0.id == exchange.id }) {
            exchanges[index] = exchange
        }
        evidence[exchange.id] = evidenceRows
        state = .answered
    }

    /// 生成中取消。**只取消这一问**：录制、已经写进去的转录都不受影响（§14.2）。
    public func cancel() {
        askTask?.cancel()
        if case .generating = state { state = .idle }
    }

    /// 「写进纪要」：显式动作，写的是 `in_minutes = 1`（默认不进纪要是结构决定的）。
    public func includeInMinutes(exchangeID: String) async {
        try? await coordinator.setInnerOSInMinutes(exchangeID: exchangeID, included: true)
        if let index = exchanges.firstIndex(where: { $0.id == exchangeID }) {
            exchanges[index].inMinutes = true
        }
    }

    /// 收起态那一行要的两个数：问过几次、几条已写进纪要。
    public var askedCount: Int { exchanges.count }
    public var inMinutesCount: Int { exchanges.filter(\.inMinutes).count }

    // MARK: - Prompt

    /// 上下文**只喂本场已确认的转录**，动态内容排在末尾（§5.9 + §5.5 的前缀结构）。
    static func prompt(
        question: String,
        lines: [TranscriptLine],
        names: [String: String] = [:]
    ) -> [LLMMessage] {
        let transcript = MinutesGenerator.render(lines: lines, names: names)
        let context = transcript.isEmpty
            ? "（本场到目前为止还没有任何已经确认的文字记录。）"
            : transcript
        return [
            LLMMessage(
                role: .developer,
                text: "你在一次会议进行中回答使用者的私人提问。只有你能看到这段对话："
                    + "你的回答不会进入会议录音，也不会被别人看到。"
                    + "只依据下面给的转录回答；转录里没有的，就直说没有证据，"
                    + "不要用常识或猜测补成事实。"
                    + "answer 里给事实与判断，判断要带上你的不确定度；"
                    + "draft 是一句可以直接念给会议室里其他人听的话（没有合适的就留空）；"
                    + "evidence 里逐条列出你依据的原文（ordinal 用转录里的段号，quote 用原文）。",
                cacheBreakpoint: true
            ),
            LLMMessage(
                role: .user,
                text: "本场转录：\n\n\(context)\n\n我的问题：\(question)"
            )
        ]
    }

    /// 结构化答案 → 模型。端点不支持结构化输出时**退到纯文本**，但如实标注。
    static func decode(_ text: String) -> InnerOSAnswer {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let answer = try? JSONDecoder().decode(InnerOSAnswer.self, from: data) {
            return answer
        }
        return InnerOSAnswer(
            intent: "mixed",
            answer: trimmed.isEmpty ? "这一问没有拿到内容。" : trimmed,
            draft: "",
            confidence: "unknown",
            limitsNote: "这一版是以纯文本返回的（服务地址没有按结构返回），所以没有逐条列证据。",
            evidence: []
        )
    }
}

private extension InnerOSSession.State {
    var failureText: String? {
        if case .failed(let text) = self { return text }
        return nil
    }
}
