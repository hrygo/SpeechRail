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
    ///
    /// MC-45：切会先取消在飞的那一问。旧任务的库归属是对的（建行时已绑定 A 的
    /// sessionID），但它的迟到结果不得写进 B 的界面状态（`exchanges`/`state`），
    /// 也不得清掉 B 新任务的句柄。
    public func bind(sessionID: String?) async {
        askTask?.cancel()
        askTask = nil
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
        ask(
            question,
            resolvedConfiguration: ResolvedLLMConfiguration(
                configuration: configuration,
                apiKey: LLMKeychain.load(),
                origin: .global
            )
        )
    }

    /// 应用入口传入已经解析好的模块配置，避免执行层重新读取 global Key。
    public func ask(_ question: String, resolvedConfiguration: ResolvedLLMConfiguration) {
        askTask?.cancel()
        askTask = Task { [weak self] in
            await self?.performAsk(question, resolvedConfiguration: resolvedConfiguration)
        }
    }

    private func performAsk(
        _ question: String,
        resolvedConfiguration: ResolvedLLMConfiguration
    ) async {
        defer { askTask = nil }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionID else { return }
        let configuration = resolvedConfiguration.configuration
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
                apiKey: resolvedConfiguration.apiKey,
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
            // MC-45：库归档照写 A 的行；界面状态只写当初那一场。
            let stillOurs = self.sessionID == sessionID
            // MC-41/MC-42：终态走条件 UPDATE；写入失败抛错，调用方不得吞错报成功。
            do {
                _ = try await coordinator.finishInnerOSExchange(exchange)
            } catch {
                guard stillOurs else { return }
                state = .failed("答案没能存进去：\(error.localizedDescription)。可以复制问题重试。")
                lastFailure = error.localizedDescription
                return
            }
            guard stillOurs else { return }
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
        // MC-45：库归档以建行时的 sessionID 为准，切会也不丢 A 的答案；
        // 界面状态只写当初那一场：切会后 self.sessionID 已变，旧任务不得碰 B 的
        // `exchanges`/`evidence`/`state`，也不得清掉 B 新任务的句柄。
        let stillOurs = self.sessionID == sessionID
        // MC-41/MC-42：答案、状态、证据同一事务落库；失败抛错，不半保存。
        do {
            _ = try await coordinator.finishInnerOSExchange(exchange, evidence: evidenceRows)
        } catch {
            guard stillOurs else { return }
            state = .failed("答案没能存进去：\(error.localizedDescription)。可以复制问题重试。")
            lastFailure = error.localizedDescription
            return
        }
        guard stillOurs else { return }
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
    ///
    /// **返回是否真的写进了库。** 原来这里是 `try?` 吞掉错误、无论成败都把标签翻过去，
    /// 于是写失败时界面照样显示「已写进纪要」——用户据此以为这句已经收进纪要，
    /// 封存之后却发现没有。私密问答默认不进入纪要，这个标签就是他的判断依据，
    /// 它不能说谎。
    @discardableResult
    public func includeInMinutes(exchangeID: String, excerpt: String? = nil) async -> Bool {
        await setInMinutes(true, exchangeID: exchangeID, excerpt: excerpt)
    }

    /// 撤回「写进纪要」。原来这条**够不着**：`setInnerOSInMinutes(included: false)`
    /// 在生产代码里没有调用方，界面上勾上之后只剩一枚静态标签，勾错了只能重新封存。
    @discardableResult
    public func excludeFromMinutes(exchangeID: String) async -> Bool {
        await setInMinutes(false, exchangeID: exchangeID, excerpt: nil)
    }

    /// 写进纪要失败时的提示。`nil` = 没有失败。
    public private(set) var supplementError: String?

    /// 只有**真的写进库了**才翻标签。失败时列表保持原样，并把话说到界面上。
    private func setInMinutes(
        _ included: Bool,
        exchangeID: String,
        excerpt: String?
    ) async -> Bool {
        supplementError = nil
        let changed: Bool
        do {
            changed = try await coordinator.setInnerOSInMinutes(
                exchangeID: exchangeID, included: included, excerpt: excerpt
            )
        } catch {
            supplementError = "\(error.localizedDescription)。这一句的「写进纪要」没有改动。"
            return false
        }
        guard changed else {
            supplementError = "找不到这一条问答。这一句的「写进纪要」没有改动。"
            return false
        }
        if let index = exchanges.firstIndex(where: { $0.id == exchangeID }) {
            exchanges[index].inMinutes = included
            // 撤回时一并清掉：库里已经把 excerpt 置空了，内存里留着会让界面上
            // 那枚标签与用户"这句不要"的判断对不上。
            exchanges[index].minutesExcerpt = included ? normalizedExcerpt(excerpt) : nil
        }
        return true
    }

    private func normalizedExcerpt(_ excerpt: String?) -> String? {
        let trimmed = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// 收起态那一行要的两个数：问过几次、几条已写进纪要。
    public var askedCount: Int { exchanges.count }
    public var inMinutesCount: Int { exchanges.filter(\.inMinutes).count }

    // MARK: - 选句（MC-43）

    /// 把一条答案切成用户可以逐句勾选的句子。
    ///
    /// MC-43 的粒度是"一句"：用户要能只把某半句写进纪要，而不是整条问答的
    /// 全有或全无。切分只认**句末标点**，不猜语义——把"5% 流量"从
    /// "先跑 5% 流量"里切出来，界面上就会出现一个用户从没说过、
    /// 也没法认领的碎片。
    ///
    /// 小数点与版本号不断句：`0.5%`、`v3.5.6` 被切开之后用户看到的是两个
    /// 他没写过的东西。规则与 `TeleprompterSegmenter` 一致，刻意不合并成
    /// 一处：提词器切的是朗读单元，这里切的是"用户勾了哪几句"，
    /// 边界处的坑相同但后果不同，合成一处会让其中一个被另一个的假设绑住。
    static func selectableSentences(in answer: String) -> [String] {
        let characters = Array(answer)
        var sentences: [String] = []
        var start = 0
        var index = 0
        while index < characters.count {
            guard Self.isSentenceEnd(characters, at: index) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, Self.isClosingMark(characters[end]) { end += 1 }
            let slice = String(characters[start..<end])
            if !slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(slice)
            }
            start = end
            index = end
        }
        if start < characters.count {
            let tail = String(characters[start...])
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(tail)
            }
        }
        return sentences
    }

    private static func isSentenceEnd(_ characters: [Character], at index: Int) -> Bool {
        guard ".。!?！？;；\n".contains(characters[index]) else { return false }
        guard characters[index] == "." || characters[index] == ";" else { return true }
        let previous = index > 0 ? characters[index - 1] : nil
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        // 小数、版本号、域名、缩写：句号不是句末。
        if let previous, let next,
           previous.isNumber, next.isNumber {
            return false
        }
        if let previous, let next, previous.isLetter, next.isLetter {
            return false
        }
        if characters[index] == ";", previous.map({ "：:，,".contains($0) }) == true {
            return true
        }
        if characters[index] == ";" { return true }
        return !abbreviationBefore(characters, at: index)
    }

    private static func abbreviationBefore(_ characters: [Character], at index: Int) -> Bool {
        var start = index
        while start > 0 {
            let previous = characters[start - 1]
            guard previous.isLetter || previous.isNumber || previous == "." else { break }
            start -= 1
        }
        let token = String(characters[start..<index]).lowercased()
        return ["dr", "mr", "mrs", "ms", "prof", "sr", "jr", "e.g", "i.e"].contains(token)
    }

    private static func isClosingMark(_ character: Character) -> Bool {
        "\"'\u{201D}\u{2019}》」』）)]}〉〕】".contains(character)
    }

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
