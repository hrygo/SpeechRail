import Foundation

// 会话三能力的领域类型。**取值一律对着库里的取值域写**（SESSIONS-SPEC §15.2 / §15.6 R1 / §15.7 R2），
// 所以这里的 `rawValue` 不是内部实现细节：它就是列里那一串字符，改它等于改数据。
//
// 一条最容易搞错的规矩（§15.7 末注）：**中断是事件，不是阶段**。库里 `session.state` 只有
// `recording` / `processing` / `archived`；「这次断过」由未闭合的 `session_interruption` 行推出。
// 所以 `SessionPhase` 里的 `.interrupted` 是**界面的**相位，`SessionRecordState` 才是库里的。

// MARK: - 能力

public enum SessionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case assistant
    case meeting
    case captions
    case teleprompter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .assistant: "语音助手"
        case .meeting: "会议助手"
        case .captions: "实时字幕"
        case .teleprompter: "AI 提词器"
        }
    }

    /// 侧边栏占用行与状态带里的短名（「实时字幕进行中」这类句子由调用点拼）。
    public var shortTitle: String {
        switch self {
        case .assistant: "语音助手"
        case .meeting: "会议助手"
        case .captions: "实时字幕"
        case .teleprompter: "AI 提词器"
        }
    }

    public var systemImage: String {
        switch self {
        case .assistant: "message.circle"
        case .meeting: "person.2"
        case .captions: "captions.bubble"
        case .teleprompter: "text.bubble"
        }
    }

    public var route: AppRoute {
        switch self {
        case .assistant: .assistant
        case .meeting: .meeting
        case .captions: .captions
        case .teleprompter: .teleprompter
        }
    }

    public var persistencePolicy: SessionPersistencePolicy {
        switch self {
        case .teleprompter: .ephemeral
        case .assistant, .meeting, .captions: .persistent
        }
    }
}

public enum SessionPersistencePolicy: String, Codable, Sendable {
    case persistent
    case ephemeral
}

// MARK: - 库里的取值域

/// `session.state`。只有三种；中断不在其中（§15.7）。
public enum SessionRecordState: String, Codable, Sendable, CaseIterable {
    case recording
    case processing
    case archived
}

/// 每个 `line.source` 来自哪一路；`keyboard` 是打字输入，不是音频（§15.7 R2 ③）。
public enum SessionLineSource: String, Codable, Sendable {
    case microphone
    case system
    case mixed
    case keyboard
}

/// `session.audio_source`：本次选的采集来源配置。**没有 `keyboard`**——它描述采集，不描述提问方式。
public enum SessionAudioSource: String, Codable, Sendable {
    case microphone
    case system
    case mixed

    public var title: String {
        switch self {
        case .microphone: "麦克风"
        case .system: "本机音频"
        case .mixed: "麦克风 + 本机音频"
        }
    }
}

public enum SessionDiarizationState: String, Codable, Sendable {
    case off
    case active
    case degraded
    case unavailable
}

public enum SessionEndReason: String, Codable, Sendable {
    case user
    case interrupted
    case unexpectedExit = "unexpected_exit"

    public var title: String {
        switch self {
        case .user: "已结束"
        case .interrupted: "中断后结束"
        case .unexpectedExit: "意外退出"
        }
    }
}

public enum SessionInterruptionReason: String, Codable, Sendable {
    case serviceLost = "service_lost"
    case sleep
    case sourceLost = "source_lost"
    case unexpectedExit = "unexpected_exit"

    /// 直接拿来写界面文案（用户的问法是「这一段到底录没录上」）。
    public var title: String {
        switch self {
        case .serviceLost: "语音服务断开"
        case .sleep: "Mac 睡眠"
        case .sourceLost: "音频来源中断"
        case .unexpectedExit: "应用意外退出"
        }
    }
}

public enum SessionLineRole: String, Codable, Sendable {
    case speaker
    case user
    case assistant
}

public enum SessionLineStatus: String, Codable, Sendable {
    case partial
    case final
}

public enum SessionTimingQuality: String, Codable, Sendable {
    case aligned
    case unavailable
}

public enum MinutesStatus: String, Codable, Sendable {
    case queued
    case running
    case ready
    case failed
    /// 用户明确停下的这一次（MA-07/MC-30）。与 `failed` 分开说：
    /// 失败是"没整理出来"，取消是"用户不要了"，两者给出的下一步不同。
    case cancelled
    /// 请求可能已被远端受理，但本地没拿到 response id 就断了（MA-07/MC-28、§8.5）。
    /// 与 `failed` 分开，因为它**不能自动重发**：重发可能重复执行、重复计费。
    case submissionUnknown = "submission_unknown"

    /// 界面上那个胶囊的字（与 `MinutesGenerator.State.title` 同一套词）。
    public var title: String {
        switch self {
        case .queued: "排队中"
        case .running: "整理中"
        case .ready: "已生成"
        case .failed: "没整理出来"
        case .cancelled: "已停止"
        case .submissionUnknown: "提交结果待确认"
        }
    }
}

/// 生成没成的**性质**（MC-34：三类原因必须可区分）。
///
/// 分开是因为下一步不同：空输出可以重试，拒答换个问法才有用，
/// 结构不合法要去看服务是不是真按 schema 返回，而截断意味着这一版**尾部丢了**，
/// 把它当"整理完了"就是把没听到的当没说过。
public enum MinutesFailureKind: String, Equatable, Sendable {
    /// 空输出或只有空白（MC-33）。
    case empty
    /// 服务以纯文本返回，没有按结构返回。
    case unstructured
    /// 结构不合法：缺字段、类型不对、schema 版本不认识。
    case schemaInvalid
    /// 模型明确拒答。
    case refused
    /// 输出被截断，尾部没有拿全。
    case incomplete

    /// 给界面的一句话（不含正文，避免把整段模型输出回显出来）。
    public var title: String {
        switch self {
        case .empty: "没有拿到内容"
        case .unstructured: "服务没有按结构返回"
        case .schemaInvalid: "结构对不上"
        case .refused: "模型没有作答"
        case .incomplete: "输出被截断"
        }
    }
}

// MARK: - 结构化纪要候选（v2，§7.5）

/// 一个来源单元：转录里的一条发言，**程序分配 id**（§7.5）。
///
/// 模型只被允许引用这些 id，不允许自己写库主键。所以"这条结论依据哪句话"
/// 在生成之前就已经确定了一个可核对的身份，而不是模型随口写一个字符串。
public struct MinutesSourceUnit: Hashable, Sendable, Identifiable {
    public var id: String
    public var lineID: String
    public var ordinal: Int
    public var speaker: String
    public var text: String
    public var startSeconds: Double?
    /// 超长单句被切分后的段序号（0 起）。未切分时为 nil。
    ///
    /// 切分只影响送进 prompt 的粒度：`lineID` 仍指向原句，
    /// 锚点因此照样落回不可变修订（MA-09/MC-46）。
    public var segmentIndex: Int?
    /// 该来源单元被切成了几段。未切分时为 nil。
    public var segmentCount: Int?
    /// 本段在原句正文里的字符范围。未切分时为 nil。
    public var segmentRange: Range<Int>?

    public init(
        id: String,
        lineID: String,
        ordinal: Int,
        speaker: String,
        text: String,
        startSeconds: Double?,
        segmentIndex: Int? = nil,
        segmentCount: Int? = nil,
        segmentRange: Range<Int>? = nil
    ) {
        self.id = id
        self.lineID = lineID
        self.ordinal = ordinal
        self.speaker = speaker
        self.text = text
        self.startSeconds = startSeconds
        self.segmentIndex = segmentIndex
        self.segmentCount = segmentCount
        self.segmentRange = segmentRange
    }

    /// 这段是否来自被切分的超长发言（`u7#2` 这种形态）。
    public var isSegment: Bool { segmentCount != nil }

    /// 该段所属的**原始**来源单元 id（切分前）。
    ///
    /// 校验与锚点用这个 id：几段合起来指向同一句原文，
    /// 引用其中任一段都应落到同一句上。
    public var rootUnitID: String {
        guard let count = segmentCount, count > 0 else { return id }
        return id.split(separator: "#").first.map(String.init) ?? id
    }
}

/// 结论的**语气**：说定了、有条件、只是提议、还是已经撤回（MC-37）。
///
/// 这一栏不是修饰词。原文里"建议先灰度"被写成"决定全量发布"，
/// 读起来一样顺，但结论的性质完全不同——所以它由模型声明、由验证器核对。
public enum MinutesDecisionModality: String, Codable, Hashable, Sendable {
    case decided
    case conditional
    case proposed
    case retracted
}

/// 待办的**承诺程度**（MC-37/MC-38）：答应了要做，还是只是有人提了一句。
public enum MinutesCommitment: String, Codable, Hashable, Sendable {
    case committed
    case proposed
}

/// 结构化纪要候选（`speechrail.minutes.v2`）。
///
/// 模型能写的只有这些内容与来源引用；`localID` 是**候选内**编号，
/// 持久 ID、审阅状态、快照关联都由程序在保存时分配（§7.5）。
public struct MinutesCandidateV2: Codable, Hashable, Sendable {
    public struct OverviewItem: Codable, Hashable, Sendable {
        public var localID: String
        public var text: String
        public var sourceUnitIDs: [String]

        enum CodingKeys: String, CodingKey {
            case localID = "local_id"
            case text
            case sourceUnitIDs = "source_unit_ids"
        }

        public init(localID: String, text: String, sourceUnitIDs: [String]) {
            self.localID = localID
            self.text = text
            self.sourceUnitIDs = sourceUnitIDs
        }
    }

    public struct DecisionItem: Codable, Hashable, Sendable {
        public var localID: String
        public var text: String
        public var modality: MinutesDecisionModality
        public var conditions: [String]
        public var sourceUnitIDs: [String]

        enum CodingKeys: String, CodingKey {
            case localID = "local_id"
            case text
            case modality
            case conditions
            case sourceUnitIDs = "source_unit_ids"
        }

        public init(
            localID: String,
            text: String,
            modality: MinutesDecisionModality,
            conditions: [String],
            sourceUnitIDs: [String]
        ) {
            self.localID = localID
            self.text = text
            self.modality = modality
            self.conditions = conditions
            self.sourceUnitIDs = sourceUnitIDs
        }
    }

    public struct ActionItem: Codable, Hashable, Sendable {
        public var localID: String
        public var task: String
        /// 负责人**照写**，不解析成人名账号；原文没说是谁就空着（MC-38）。
        public var ownerText: String?
        /// 期限**照写**（"下周三"就写"下周三"），不从日历或生成日期折算（MC-38）。
        public var dueExpression: String?
        public var commitment: MinutesCommitment
        public var sourceUnitIDs: [String]

        enum CodingKeys: String, CodingKey {
            case localID = "local_id"
            case task
            case ownerText = "owner_text"
            case dueExpression = "due_expression"
            case commitment
            case sourceUnitIDs = "source_unit_ids"
        }

        public init(
            localID: String,
            task: String,
            ownerText: String?,
            dueExpression: String?,
            commitment: MinutesCommitment,
            sourceUnitIDs: [String]
        ) {
            self.localID = localID
            self.task = task
            self.ownerText = ownerText
            self.dueExpression = dueExpression
            self.commitment = commitment
            self.sourceUnitIDs = sourceUnitIDs
        }
    }

    public struct OpenQuestionItem: Codable, Hashable, Sendable {
        public var localID: String
        public var text: String
        public var sourceUnitIDs: [String]

        enum CodingKeys: String, CodingKey {
            case localID = "local_id"
            case text
            case sourceUnitIDs = "source_unit_ids"
        }

        public init(localID: String, text: String, sourceUnitIDs: [String]) {
            self.localID = localID
            self.text = text
            self.sourceUnitIDs = sourceUnitIDs
        }
    }

    /// 契约里写死的版本号。模型必须原样回它；不认识就走 schema 不合法，
    /// 而不是"尽量按新的理解解析"。
    public static let schemaVersion = "speechrail.minutes.v2"

    public var schemaVersion: String
    public var title: String
    public var overview: [OverviewItem]
    public var decisions: [DecisionItem]
    public var actions: [ActionItem]
    public var openQuestions: [OpenQuestionItem]
    public var confidenceNotes: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case title
        case overview
        case decisions
        case actions
        case openQuestions = "open_questions"
        case confidenceNotes = "confidence_notes"
    }

    public init(
        schemaVersion: String = MinutesCandidateV2.schemaVersion,
        title: String,
        overview: [OverviewItem],
        decisions: [DecisionItem],
        actions: [ActionItem],
        openQuestions: [OpenQuestionItem],
        confidenceNotes: String
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.overview = overview
        self.decisions = decisions
        self.actions = actions
        self.openQuestions = openQuestions
        self.confidenceNotes = confidenceNotes
    }
}

/// 纪要候选的证据核对结论（MA-08）。
///
/// 两条底线：
/// 1. **引文存在 ≠ 支持结论**。所以"引到了"只是最低门槛，
///    语义上撑不住的一律进复核，而不是因为有引用就放行（MC-37）。
/// 2. **错误结果保留但不升可信**。被拒的条目仍然留在正文里让人看得见，
///    但整版标成需复核，不允许自动采用、不允许显示成"整理好了"。
public enum MinutesEvidenceValidator {
    /// 单条结论的核对结果。
    public enum Verdict: String, Codable, Hashable, Sendable {
        /// 引用与语气都对得上。
        case supported
        /// 引用合法，但语义上有可疑之处——保留，标复核。
        case needsReview
        /// 引用本身就不成立——不作为结论发布。
        case rejected
    }

    public struct Finding: Codable, Hashable, Sendable {
        public var localID: String
        public var kind: String
        public var verdict: Verdict
        public var reason: String

        public init(localID: String, kind: String, verdict: Verdict, reason: String) {
            self.localID = localID
            self.kind = kind
            self.verdict = verdict
            self.reason = reason
        }
    }

    /// 整版的核对报告。保存时随候选一起落库，用户看得到"这一版哪里需要核对"。
    public struct Report: Codable, Hashable, Sendable {
        public var findings: [Finding]

        public init(findings: [Finding]) {
            self.findings = findings
        }

        public func findings(for localID: String) -> [Finding] {
            findings.filter { $0.localID == localID }
        }

        /// 这一版需不需要复核：有 `needsReview` 或 `rejected` 就是。
        public var needsReview: Bool {
            findings.contains { $0.verdict != .supported }
        }

        public var rejectedCount: Int {
            findings.filter { $0.verdict == .rejected }.count
        }

        public var reviewCount: Int {
            findings.filter { $0.verdict == .needsReview }.count
        }
    }

    /// 核对一份候选。
    ///
    /// `units` 是**本次封存的来源单元全集**——只有在这里面的 id 才算"存在"。
    /// 引用不在集合里的 id 一律 `rejected`，绝不按序号去别的会议里猜一个（MC-35）。
    /// - Parameter citableUnitIDs: 本次允许当依据的单元 id（MA-09 的**拥有区**）。
    ///   为 nil 表示不额外限制（短会单窗、归并后的全量复核走这条）。
    ///   分窗核对时必须传 `window.citableUnitIDs`：重叠区只供理解前后文，
    ///   拿它当依据等于让邻窗的重复内容混进这一窗的结论。
    public static func validate(
        candidate: MinutesCandidateV2,
        units: [MinutesSourceUnit],
        citableUnitIDs: Set<String>? = nil
    ) -> Report {
        let byID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var findings: [Finding] = []

        for item in candidate.overview {
            findings.append(contentsOf: check(
                localID: item.localID,
                kind: "overview",
                text: item.text,
                sourceUnitIDs: item.sourceUnitIDs,
                units: byID,
                citableUnitIDs: citableUnitIDs
            ))
        }
        for item in candidate.decisions {
            findings.append(contentsOf: check(
                localID: item.localID,
                kind: "decision",
                text: item.text,
                sourceUnitIDs: item.sourceUnitIDs,
                units: byID,
                modality: item.modality,
                conditions: item.conditions,
                citableUnitIDs: citableUnitIDs
            ))
        }
        for item in candidate.openQuestions {
            findings.append(contentsOf: check(
                localID: item.localID,
                kind: "open_question",
                text: item.text,
                sourceUnitIDs: item.sourceUnitIDs,
                units: byID,
                citableUnitIDs: citableUnitIDs
            ))
        }
        for item in candidate.actions {
            findings.append(contentsOf: check(
                localID: item.localID,
                kind: "action",
                text: item.task,
                sourceUnitIDs: item.sourceUnitIDs,
                units: byID,
                ownerText: item.ownerText,
                dueExpression: item.dueExpression,
                commitment: item.commitment,
                citableUnitIDs: citableUnitIDs
            ))
        }
        return Report(findings: findings)
    }

    // MARK: - 单条核对

    private static func check(
        localID: String,
        kind: String,
        text: String,
        sourceUnitIDs: [String],
        units: [String: MinutesSourceUnit],
        modality: MinutesDecisionModality? = nil,
        conditions: [String] = [],
        ownerText: String? = nil,
        dueExpression: String? = nil,
        commitment: MinutesCommitment? = nil,
        citableUnitIDs: Set<String>? = nil
    ) -> [Finding] {
        var findings: [Finding] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [Finding(
                localID: localID,
                kind: kind,
                verdict: .rejected,
                reason: "这一条没有正文"
            )]
        }

        // ① 引用身份（MC-35）：不存在的 id 一律拒绝，不按序号兜底。
        var resolved: [MinutesSourceUnit] = []
        for unitID in sourceUnitIDs {
            if let unit = units[unitID] {
                // 单元存在但不属于本窗口的拥有区：重叠区只供读，不能当依据。
                if let citableUnitIDs, !citableUnitIDs.contains(unitID) {
                    findings.append(Finding(
                        localID: localID,
                        kind: kind,
                        verdict: .rejected,
                        reason: "引用了 \(unitID)，它只是相邻窗口的重叠上下文，不能作为这一条的依据"
                    ))
                    continue
                }
                resolved.append(unit)
            } else {
                findings.append(Finding(
                    localID: localID,
                    kind: kind,
                    verdict: .rejected,
                    reason: "引用了不存在的来源单元 \(unitID)"
                ))
            }
        }
        if sourceUnitIDs.isEmpty {
            findings.append(Finding(
                localID: localID,
                kind: kind,
                verdict: .needsReview,
                reason: "没有指明依据哪几句"
            ))
        }
        // 已经有引用不成立的问题，后面的语义判断没有意义。
        guard findings.isEmpty else { return findings }

        let corpus = resolved.map(\.text).joined(separator: "\n")

        // ② 数字一致性（MC-38）：结论里的数字必须能在所引原文里找到。
        //    单位错、否定漏、金额改写，全靠这一条兜住。
        for number in numbers(in: trimmed) where !corpus.contains(number) {
            findings.append(Finding(
                localID: localID,
                kind: kind,
                verdict: .needsReview,
                reason: "结论里的“\(number)”在所引原文中没有出现，请核对是否听错或改写了单位"
            ))
        }

        // ③ 语气（MC-37）：原文是建议/条件/撤回，结论却写成已决定。
        if let modality, modality == .decided {
            if containsAny(corpus, ["建议", "提议", "可以考虑", "倾向于", "要不要", "是否"]) {
                findings.append(Finding(
                    localID: localID,
                    kind: kind,
                    verdict: .needsReview,
                    reason: "原文是建议或待定，结论却写成已决定"
                ))
            }
            if containsAny(corpus, ["如果", "假如", "除非", "前提是", "条件是"]) && !conditionsMatch(conditions, corpus: corpus) {
                findings.append(Finding(
                    localID: localID,
                    kind: kind,
                    verdict: .needsReview,
                    reason: "原文带条件，结论没有把条件写出来"
                ))
            }
            // ④ 撤回（MC-37）：原文撤回了，结论不能还当决定。
            if containsAny(corpus, ["撤回", "取消", "作废", "不做了", "先不"]) {
                findings.append(Finding(
                    localID: localID,
                    kind: kind,
                    verdict: .needsReview,
                    reason: "原文里这段被撤回或暂缓，结论却写成已决定"
                ))
            }
        }

        // ⑤ 待办的负责人/期限（MC-38）：填了就要在原文里有依据；
        //    没依据说明是模型自己编的，而正确做法是留空。
        if let commitment, commitment == .committed, !containsAny(corpus, ["我来", "我负责", "负责", "会做", "我这边"]) {
            findings.append(Finding(
                localID: localID,
                kind: kind,
                verdict: .needsReview,
                reason: "待办标成已承诺，但所引原文里没有认领的说法"
            ))
        }
        if let ownerText, !ownerText.isEmpty, !corpus.contains(ownerText) {
            findings.append(Finding(
                localID: localID,
                kind: kind,
                verdict: .needsReview,
                reason: "负责人“\(ownerText)”在所引原文中没有出现"
            ))
        }
        if let dueExpression, !dueExpression.isEmpty {
            let numbersInDue = numbers(in: dueExpression)
            if !numbersInDue.isEmpty, !numbersInDue.allSatisfy({ corpus.contains($0) }) {
                findings.append(Finding(
                    localID: localID,
                    kind: kind,
                    verdict: .needsReview,
                    reason: "期限“\(dueExpression)”里的数字在所引原文中没有出现"
                ))
            }
        }
        return findings
    }

    // MARK: - 小工具

    /// 抽取结论里的数字串（含小数），单位与符号原样带走。
    /// "约 3.5 万元" 抽出 "3.5"；"下周"抽不出东西——那本来就该由原文说了算。
    static func numbers(in text: String) -> [String] {
        guard text.contains(where: \.isNumber) else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]+(?:\.[0-9]+)?"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func conditionsMatch(_ conditions: [String], corpus: String) -> Bool {
        let cleaned = conditions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !cleaned.isEmpty && cleaned.allSatisfy { corpus.contains($0) }
    }

    private static func containsAny(_ corpus: String, _ needles: [String]) -> Bool {
        needles.contains { corpus.contains($0) }
    }
}

/// 结构化纪要的字段（`json_schema` + `strict`）。App 负责把它渲染成 Markdown，
/// 于是"结构不合法"与"内容不好"是两件可以分开处理的事。
///
/// v2（MA-08）：字段带**来源单元引用**与**语气**，让"这条结论依据哪几句"、
/// "这是建议还是已决定"成为可核对的数据，而不是只能靠读正文猜。
public enum MinutesCandidateCodec {
    /// 一次解析的结果：候选、核对报告、以及渲染好的正文。
    public struct Prepared: Sendable {
        public var candidate: MinutesCandidateV2
        public var report: MinutesEvidenceValidator.Report
        public var body: String
    }

    /// 解析结果：成功带着候选与核对报告，失败带着**可区分**的原因。
    public enum Outcome: Sendable {
        case prepared(Prepared)
        case failed(kind: MinutesFailureKind, reason: String)
    }

    /// 解码 + 核对 + 渲染。**只有这一条路能把候选变成可用纪要**——
    /// 直接拿模型原文当正文，就是"原文兜底后 ready"，计划明令禁止。
    public static func prepare(text: String, units: [MinutesSourceUnit]) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(
                kind: .empty,
                reason: "这一版没有拿到内容。可以重新生成一次。"
            )
        }
        guard let data = trimmed.data(using: .utf8) else {
            return .failed(kind: .unstructured, reason: unstructured(trimmed))
        }
        guard let candidate = try? JSONDecoder().decode(MinutesCandidateV2.self, from: data) else {
            return .failed(kind: .unstructured, reason: unstructured(trimmed))
        }
        guard candidate.schemaVersion == MinutesCandidateV2.schemaVersion else {
            return .failed(
                kind: .schemaInvalid,
                reason: "这一版用的是 \(candidate.schemaVersion)，这个版本只认 "
                    + MinutesCandidateV2.schemaVersion + "。原文已保留，但不能作为可用纪要。"
            )
        }
        let report = MinutesEvidenceValidator.validate(candidate: candidate, units: units)
        return .prepared(Prepared(
            candidate: candidate,
            report: report,
            body: markdown(for: candidate, report: report)
        ))
    }

    /// 分窗解码 + 核对（MA-09）。
    ///
    /// 与单窗 `prepare` 的唯一区别是核对时按**本窗拥有区**限制可引用单元：
    /// 重叠区只供读懂前后文，拿它当依据就是让邻窗内容重复进结论。
    /// 渲染出来的正文在这里不用——归并之后才渲染一次。
    public static func prepareWindow(
        text: String,
        window: MinutesWindow
    ) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(
                kind: .empty,
                reason: "第 \(window.index + 1) 个窗口没有拿到内容。"
            )
        }
        guard let data = trimmed.data(using: .utf8),
              let candidate = try? JSONDecoder().decode(MinutesCandidateV2.self, from: data)
        else {
            return .failed(
                kind: .unstructured,
                reason: "第 \(window.index + 1) 个窗口没有按结构返回。"
            )
        }
        guard candidate.schemaVersion == MinutesCandidateV2.schemaVersion else {
            return .failed(
                kind: .schemaInvalid,
                reason: "第 \(window.index + 1) 个窗口用的是 \(candidate.schemaVersion)，"
                    + "这个版本只认 \(MinutesCandidateV2.schemaVersion)。"
            )
        }
        let report = MinutesEvidenceValidator.validate(
            candidate: candidate,
            units: window.owned,
            citableUnitIDs: window.citableUnitIDs
        )
        return .prepared(Prepared(
            candidate: candidate,
            report: report,
            body: markdown(for: candidate, report: report)
        ))
    }

    /// 纯文本返回：原文**保留**下来，但说清它没有被校验过。
    private static func unstructured(_ text: String) -> String {
        text + "\n\n> 这一版是以纯文本返回的（服务地址没有按结构返回），尚未按结构校验，不能作为可用纪要。\n"
    }

    /// 渲染成 Markdown。库里存的就是这一段（界面直接显示，导出也用它）。
    ///
    /// 被验证器判为 `rejected` 的条目**仍然渲染出来**——错误结果保留但不升可信：
    /// 删掉它用户就看不出模型编了什么，而标成"已整理好"才是真的骗人。
    public static func markdown(
        for candidate: MinutesCandidateV2,
        report: MinutesEvidenceValidator.Report
    ) -> String {
        var out = "# \(candidate.title.isEmpty ? "会议纪要" : candidate.title)\n\n"
        if !candidate.overview.isEmpty {
            out += "## 概述\n\n"
            for item in candidate.overview {
                out += line(item.text, localID: item.localID, report: report)
            }
            out += "\n"
        }
        if !candidate.decisions.isEmpty {
            out += "## 结论\n\n"
            for item in candidate.decisions {
                var text = item.text
                switch item.modality {
                case .decided: break
                case .conditional: text += "（有条件）"
                case .proposed: text += "（只是提议，未定）"
                case .retracted: text += "（会上已撤回）"
                }
                if !item.conditions.isEmpty {
                    text += "（条件：" + item.conditions.joined(separator: "；") + "）"
                }
                out += line(text, localID: item.localID, report: report)
            }
            out += "\n"
        }
        if !candidate.actions.isEmpty {
            out += "## 待办\n\n"
            for item in candidate.actions {
                var text = item.task
                // 负责人/期限照写，没依据就留空——不为了让 JSON 好看而填"待定"
                // 再折算成一个具体时间（MC-38）。
                if let owner = item.ownerText, !owner.isEmpty { text += "（\(owner)）" }
                if let due = item.dueExpression, !due.isEmpty { text += "（期限：\(due)）" }
                if item.commitment == .proposed { text += "（提议，未认领）" }
                out += line(text, localID: item.localID, report: report)
            }
            out += "\n"
        }
        if !candidate.openQuestions.isEmpty {
            out += "## 还没有结论的问题\n\n"
            for item in candidate.openQuestions {
                out += line(item.text, localID: item.localID, report: report)
            }
            out += "\n"
        }
        let flagged = report.findings.filter { $0.verdict == .needsReview }
        if !flagged.isEmpty {
            out += "## 需要你核对的地方\n\n"
            out += "以下结论的依据或语气与转录对不上，先按待核对看待：\n\n"
            for finding in flagged {
                out += "- \(finding.reason)\n"
            }
            out += "\n"
        }
        if !candidate.confidenceNotes.isEmpty { out += "> \(candidate.confidenceNotes)\n" }
        return out
    }

    /// 一条结论 + 它自己的核对标记。被拒绝的条目挂上"这条没通过引用核对"。
    private static func line(_ text: String, localID: String, report: MinutesEvidenceValidator.Report) -> String {
        let findings = report.findings(for: localID)
        guard !findings.isEmpty else { return "- \(text)\n" }
        let marker = findings.contains { $0.verdict == .rejected } ? "（未通过引用核对）" : "（待核对）"
        return "- \(text)\(marker)\n"
    }

    /// 把候选 + 核对报告 + 来源单元摊成**可落库**的条目与锚点（§7.4）。
    ///
    /// `revisionIDsByLine` 是这一步的关键：来源单元带的是 `lineID`，
    /// 而锚点必须指**不可变的修订**。少了这个映射，引用就永远指着会变的 `line`——
    /// 用户改一次转录，旧纪要的"依据"就悄悄换成了新文字（MC-46）。
    ///
    /// 查不到修订的行仍然建锚点，但 `revisionID` 为空：那是一条"来源不可读"的引用，
    /// 比没有引用诚实，也不比没有引用更可用。
    public static func itemDrafts(
        for candidate: MinutesCandidateV2,
        report: MinutesEvidenceValidator.Report,
        unitsByID: [String: MinutesSourceUnit],
        revisionIDsByLine: [String: String]
    ) -> [MinutesItemDraft] {
        var drafts: [MinutesItemDraft] = []

        func append(localID: String, kind: String, text: String, unitIDs: [String]) {
            let findings = report.findings(for: localID)
            // 一条上多条问题时取最严重的那个：只要有一条引用不成立，整条就不能算通过。
            let verdict: MinutesEvidenceValidator.Verdict? = {
                if findings.contains(where: { $0.verdict == .rejected }) { return .rejected }
                if findings.contains(where: { $0.verdict == .needsReview }) { return .needsReview }
                // 没发现问题就是核对通过。`nil` 只留给"没跑过验证器"的旧版本，
                // 两者混同的话，"没查过"会被读成"查过且没问题"。
                return .supported
            }()
            let anchors = unitIDs.compactMap { unitID -> MinutesAnchorDraft? in
                guard let unit = unitsByID[unitID] else { return nil }
                return MinutesAnchorDraft(
                    unitID: unitID,
                    lineID: unit.lineID,
                    revisionID: revisionIDsByLine[unit.lineID],
                    speakerLabel: unit.speaker,
                    startSeconds: unit.startSeconds
                )
            }
            drafts.append(MinutesItemDraft(
                localID: localID,
                kind: kind,
                text: text,
                verdict: verdict,
                anchors: anchors
            ))
        }

        for item in candidate.overview {
            append(localID: item.localID, kind: "overview", text: item.text, unitIDs: item.sourceUnitIDs)
        }
        for item in candidate.decisions {
            append(localID: item.localID, kind: "decision", text: item.text, unitIDs: item.sourceUnitIDs)
        }
        for item in candidate.actions {
            append(localID: item.localID, kind: "action", text: item.task, unitIDs: item.sourceUnitIDs)
        }
        for item in candidate.openQuestions {
            append(localID: item.localID, kind: "open_question", text: item.text, unitIDs: item.sourceUnitIDs)
        }
        return drafts
    }

    /// 结构化输出的 schema（`strict`：所有字段都在 `required` 里、且 `additionalProperties: false`）。
    ///
    /// `source_unit_ids` 是**必填**的：让"没有依据"成为一件模型必须写出来的事，
    /// 而不是靠它自觉。取值范围由 prompt 里的来源单元清单约束。
    static var jsonSchema: [String: Any] {
        let stringArray: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let unitIDs: [String: Any] = [
            "type": "array",
            "items": ["type": "string"],
            "description": "结论依据的来源单元 id，只能用清单里出现过的 id",
        ]
        return [
            "type": "json_schema",
            "name": "meeting_minutes_v2",
            "strict": true,
            "schema": [
                "type": "object",
                "additionalProperties": false,
                "required": [
                    "schema_version", "title", "overview", "decisions", "actions",
                    "open_questions", "confidence_notes",
                ],
                "properties": [
                    "schema_version": [
                        "type": "string",
                        "enum": [MinutesCandidateV2.schemaVersion],
                    ],
                    "title": ["type": "string"],
                    "overview": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["local_id", "text", "source_unit_ids"],
                            "properties": [
                                "local_id": ["type": "string"],
                                "text": ["type": "string"],
                                "source_unit_ids": unitIDs,
                            ],
                        ],
                    ],
                    "decisions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["local_id", "text", "modality", "conditions", "source_unit_ids"],
                            "properties": [
                                "local_id": ["type": "string"],
                                "text": ["type": "string"],
                                "modality": [
                                    "type": "string",
                                    "enum": ["decided", "conditional", "proposed", "retracted"],
                                ],
                                "conditions": stringArray,
                                "source_unit_ids": unitIDs,
                            ],
                        ],
                    ],
                    "actions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": false,
                            "required": [
                                "local_id", "task", "owner_text", "due_expression",
                                "commitment", "source_unit_ids",
                            ],
                            "properties": [
                                "local_id": ["type": "string"],
                                "task": ["type": "string"],
                                "owner_text": ["type": "string"],
                                "due_expression": ["type": "string"],
                                "commitment": ["type": "string", "enum": ["committed", "proposed"]],
                                "source_unit_ids": unitIDs,
                            ],
                        ],
                    ],
                    "open_questions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["local_id", "text", "source_unit_ids"],
                            "properties": [
                                "local_id": ["type": "string"],
                                "text": ["type": "string"],
                                "source_unit_ids": unitIDs,
                            ],
                        ],
                    ],
                    "confidence_notes": ["type": "string"],
                ],
            ],
        ]
    }
}

// MARK: - 结论条目与证据锚点（MA-08 / §7.4）

/// 纪要里的一条结论（概述 / 结论 / 待办 / 未决问题）。
///
/// 与候选 JSON 里的 `local_id` 一一对应，但**持久 id 由程序分配**——
/// 模型给的只是候选内编号，库里的身份是程序给的（§7.5）。
public struct MinutesItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var minutesID: String
    public var localID: String
    public var kind: String
    public var text: String
    /// 这一条的核对结论。`nil` 表示这一版没有跑过验证器（旧 Markdown 纪要）。
    public var verdict: MinutesEvidenceValidator.Verdict?
    public var sortOrder: Int
    public var anchors: [MinutesEvidenceAnchor]

    public init(
        id: String,
        minutesID: String,
        localID: String,
        kind: String,
        text: String,
        verdict: MinutesEvidenceValidator.Verdict?,
        sortOrder: Int,
        anchors: [MinutesEvidenceAnchor] = []
    ) {
        self.id = id
        self.minutesID = minutesID
        self.localID = localID
        self.kind = kind
        self.text = text
        self.verdict = verdict
        self.sortOrder = sortOrder
        self.anchors = anchors
    }
}

/// 一条结论锚定的一个来源单元（§7.4）。
///
/// `revisionID` 是**不可变**的行修订，不是 `line`：用户后来改了转录，
/// 旧纪要仍然指着他当时依据的那一版原文（MC-46）。
/// `quote` 从修订读回，不在这里复制一份正文——复制就会漂移。
public struct MinutesEvidenceAnchor: Identifiable, Hashable, Sendable {
    public var id: String
    public var itemID: String
    /// 候选内的来源单元 id（`u1`、`u2`…），保留是为了能对回候选 JSON。
    public var unitID: String
    public var lineID: String?
    public var revisionID: String?
    public var snapshotID: String?
    public var speakerLabel: String?
    public var startSeconds: Double?
    /// 锚点对应的原文（读自修订）。修订被删时为 nil——不拿当前 `line` 顶替。
    public var quote: String?
    /// 永远是 `exact_source_match`：只证明引文来自该来源，
    /// **不证明纪要陈述被引文充分支持**（§7.4 的显式警告）。
    public var verification: String

    public init(
        id: String,
        itemID: String,
        unitID: String,
        lineID: String? = nil,
        revisionID: String? = nil,
        snapshotID: String? = nil,
        speakerLabel: String? = nil,
        startSeconds: Double? = nil,
        quote: String? = nil,
        verification: String = "exact_source_match"
    ) {
        self.id = id
        self.itemID = itemID
        self.unitID = unitID
        self.lineID = lineID
        self.revisionID = revisionID
        self.snapshotID = snapshotID
        self.speakerLabel = speakerLabel
        self.startSeconds = startSeconds
        self.quote = quote
        self.verification = verification
    }
}

/// 保存一版候选时一起写下的条目与锚点（写库用的中间形态）。
public struct MinutesItemDraft: Sendable {
    public var localID: String
    public var kind: String
    public var text: String
    public var verdict: MinutesEvidenceValidator.Verdict?
    public var anchors: [MinutesAnchorDraft]

    public init(
        localID: String,
        kind: String,
        text: String,
        verdict: MinutesEvidenceValidator.Verdict?,
        anchors: [MinutesAnchorDraft]
    ) {
        self.localID = localID
        self.kind = kind
        self.text = text
        self.verdict = verdict
        self.anchors = anchors
    }
}

public struct MinutesAnchorDraft: Sendable {
    public var unitID: String
    public var lineID: String?
    public var revisionID: String?
    public var speakerLabel: String?
    public var startSeconds: Double?

    public init(
        unitID: String,
        lineID: String? = nil,
        revisionID: String? = nil,
        speakerLabel: String? = nil,
        startSeconds: Double? = nil
    ) {
        self.unitID = unitID
        self.lineID = lineID
        self.revisionID = revisionID
        self.speakerLabel = speakerLabel
        self.startSeconds = startSeconds
    }
}

/// 快照输入里的用户补充组装（MC-43/MC-35/MC-36）。
/// 只收 `inMinutes` 且全部引文已校验的问答；任一条引文未通过即整条丢弃。
/// 纯值逻辑，放在 Domain 层以便 SPM 测试目标直接覆盖。
public enum MinutesSupplements: Sendable {
    public static func render(
        questions: [(id: String, question: String, answer: String?, inMinutes: Bool)],
        verifiedIDs: Set<String>
    ) -> String {
        let blocks = questions.compactMap { item -> String? in
            guard item.inMinutes, verifiedIDs.contains(item.id) else { return nil }
            let question = item.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = (item.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty || !answer.isEmpty else { return nil }
            var block = "【用户选择的 AI 补充（不是会议原文）】问：\(question)"
            if !answer.isEmpty { block += "\n答：\(answer)" }
            return block
        }
        return blocks.joined(separator: "\n\n")
    }
}
// MARK: - 中文全文检索的分词与规范化（MA-15 / §6.5）

/// 检索分词器（MA-15）。
///
/// 一条硬约束来自 MC-54：查「预算」「回滚」这种**两个汉字**必须有明确通路，
/// 不能因为 trigram 不足 3 字而无声漏检。所以这里不用 trigram，也不用
/// `unicode61` 直接切中文——那会把一整句连续汉字切成一个 token。
///
/// 做法是**自己分词，文档与查询走同一条规则**：
/// - CJK 连续段：索引时写入单字与相邻二元组；查询时二元组逐个 AND。
///   「会议室」因此既能命中「会议」也能命中「议室」所在的整句。
/// - 字母/数字段（`v3.5.6`、`3.5`、`35` 这类带点写法）：整段作为一个 token，
///   只做 NFKC 与大小写规范化。MC-55 要求 `3.5万元` 与 `35万元` 不被当成同值——
///   数字段整体进 token 就自然区分开，不需要任何金额启发式。
public enum KnowledgeSearchTokenizer {
    /// CJK 表意文字区段（含扩展区与假名）。
    static func isWideScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FA1F:
            true
        default:
            false
        }
    }

    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return isWideScript(scalar)
    }

    /// 规范化：NFKC（全角→半角、兼容字符归一）+ ASCII 小写。
    ///
    /// NFKC 是「同一条规范化」能成立的前提：`３.５` 与 `3.5` 必须落到同一个 token，
    /// 否则同一份内容换个输入方式就检索不到。
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// 切成「宽字符段」与「字母数字段」。其余字符是分隔符。
    ///
    /// `.`/`-`/`_` 只有**左右都是字母数字**时才并入当前段：
    /// `v3.5.6` 保持一段，而 `3.5万元` 会切成 `3.5` 与 `万元` 两段——
    /// 金额与单位分开，MC-55 的同值混淆就不会发生。
    static func runs(in normalized: String) -> [(text: String, wide: Bool)] {
        let characters = Array(normalized)
        var result: [(String, Bool)] = []
        var current = ""
        var currentIsWide = false

        func flush() {
            if !current.isEmpty { result.append((current, currentIsWide)) }
            current = ""
        }

        for (offset, character) in characters.enumerated() {
            let wide = isWide(character)
            let alnum = wide || character.isLetter || character.isNumber
            if alnum {
                if !current.isEmpty, currentIsWide != wide { flush() }
                currentIsWide = wide
                current.append(character)
                continue
            }
            let joiner = character == "." || character == "-" || character == "_"
            let nextIsAlnum = offset + 1 < characters.count
                && { let next = characters[offset + 1]
                     return isWide(next) || next.isLetter || next.isNumber }()
            if joiner, !current.isEmpty, !currentIsWide, nextIsAlnum {
                current.append(character)
                continue
            }
            flush()
            currentIsWide = false
        }
        flush()
        return result
    }

    /// **索引侧**词项：宽字符段写单字与二元组，字母数字段整段写入。
    public static func indexTerms(for text: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        for (run, wide) in runs(in: normalize(text)) {
            for piece in widePieces(run, wide: wide) where seen.insert(piece).inserted {
                terms.append(piece)
            }
        }
        return terms
    }

    /// **查询侧**词项：宽字符段只发二元组（单字查询才用单字）。
    ///
    /// 查询词项必须是索引词项的子集，否则永远命中不到——这是「同一套分词」
    /// 在代码里唯一需要守住的不变量。
    public static func queryTerms(for text: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        for (run, wide) in runs(in: normalize(text)) {
            let pieces = wide ? bigrams(of: run) : [run]
            for piece in pieces where seen.insert(piece).inserted {
                terms.append(piece)
            }
        }
        return terms
    }

    private static func widePieces(_ run: String, wide: Bool) -> [String] {
        guard wide else { return [run] }
        let characters = Array(run)
        guard !characters.isEmpty else { return [] }
        var pieces = characters.map(String.init)
        pieces.append(contentsOf: bigrams(of: run))
        return pieces
    }

    /// 连续宽字符段的相邻二元组。单字段没有二元组，返回空。
    static func bigrams(of run: String) -> [String] {
        let characters = Array(run)
        guard characters.count >= 2 else { return [] }
        return (0...(characters.count - 2)).map { index in
            String(characters[index]) + String(characters[index + 1])
        }
    }

    /// 写入索引列的文本：词项空格分隔。
    ///
    /// 索引列存的是**分词结果**而不是原文：原文另有出处，这里只负责可检索。
    public static func indexDocument(for text: String) -> String {
        indexTerms(for: text).joined(separator: " ")
    }

    /// FTS5 的 MATCH 表达式。返回 nil 表示这个查询没有可用词项
    /// （全是标点之类），调用方据此回退，不拿"零结果"冒充"确实没有"。
    public static func matchExpression(for query: String) -> String? {
        let terms = queryTerms(for: query)
        guard !terms.isEmpty else { return nil }
        return terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")
    }
}

// MARK: - 长会议分窗（MA-09 / §6.3）

/// token 预算的**保守估计**（§6.3）。
///
/// 这里没有 tokenizer，所以刻意不做“字符数当 token 数”的等价换算：
/// 中日韩表意文字按 1 字 ≈ 1 token，其余按 4 字符 ≈ 1 token 估，
/// 同一段文本得到的值明显偏大。偏大只会让窗口切得更碎（多几次请求），
/// 偏小会让请求超限、把尾部悄悄丢掉——后者正是计划禁止的行为。
public enum MinutesTokenEstimate: Sendable {
    /// 保守估计一段文本的 token 数。
    ///
    /// 这是**上界近似**，不是精确 tokenize。调用方在超限时继续拆窗，不截断。
    public static func tokens(in text: String) -> Int {
        var wide = 0
        var narrow = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FA1F:
                wide += 1
            default:
                narrow += 1
            }
        }
        let narrowTokens = (narrow + 3) / 4
        return max(1, wide + narrowTokens)
    }
}

/// 一次会议整理的窗口预算（§6.3）。
///
/// `windowTokens` 是**每窗拥有区的实验起点**，不是模型能力承诺：
/// 真实取值要按目标模型的上下文窗口校准。
public struct MinutesWindowBudget: Hashable, Sendable {
    /// 每个窗口拥有区的 token 预算（实验起点 2,500～4,000）。
    public var windowTokens: Int
    /// 提示 + 输出 + 安全余量。超预算时先缩窗口，不动余量。
    public var reserveTokens: Int
    /// 相邻窗口的重叠单元数（只读上下文，不产生重复条目）。
    public var overlapUnits: Int
    /// 超长单句切分后的每段目标 token。
    public var segmentTokens: Int

    public init(
        windowTokens: Int = 3_000,
        reserveTokens: Int = 2_000,
        overlapUnits: Int = 2,
        segmentTokens: Int = 600
    ) {
        self.windowTokens = max(200, windowTokens)
        self.reserveTokens = max(0, reserveTokens)
        self.overlapUnits = max(0, overlapUnits)
        self.segmentTokens = max(100, segmentTokens)
    }

    /// 由 provider/model 的上下文能力反推窗口预算。
    ///
    /// 拿不到模型上下文（当前配置里没有这一项）时返回 nil，
    /// 让调用方用保守的默认预算——**不**因为“不知道”就假装整场塞得进一个窗口。
    public static func fit(
        contextTokens: Int?,
        requestedOutputTokens: Int,
        overlapUnits: Int = 2
    ) -> MinutesWindowBudget? {
        guard let contextTokens, contextTokens > 0 else { return nil }
        let usable = contextTokens - requestedOutputTokens
        guard usable > 200 else { return nil }
        let reserve = usable / 4
        let body = usable - reserve
        // 夹进 2,500～4,000 的实验区间；区间本身也要被上下文能力允许。
        let window = min(4_000, max(200, body))
        return MinutesWindowBudget(
            windowTokens: window,
            reserveTokens: reserve,
            overlapUnits: overlapUnits
        )
    }
}

/// 一个窗口的来源范围（§6.3）。
///
/// `owned` 是**这个窗口负责出结论的区间**，每个来源单元在全场只 owned 一次；
/// `context` 是邻窗重叠的只读上下文——模型可以读来理解前后文，
/// 但**不能**拿它当依据，也不能因它产生重复条目。
public struct MinutesWindow: Hashable, Sendable, Identifiable {
    public var index: Int
    public var owned: [MinutesSourceUnit]
    public var contextBefore: [MinutesSourceUnit]
    public var contextAfter: [MinutesSourceUnit]
    public var estimatedTokens: Int

    public var id: String { "w\(index)" }

    /// 可被引用（当依据）的单元 id 集合。重叠区不在其中。
    public var citableUnitIDs: Set<String> {
        Set(owned.map(\.id))
    }

    public init(
        index: Int,
        owned: [MinutesSourceUnit],
        contextBefore: [MinutesSourceUnit],
        contextAfter: [MinutesSourceUnit],
        estimatedTokens: Int
    ) {
        self.index = index
        self.owned = owned
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.estimatedTokens = estimatedTokens
    }
}

/// 长会议分窗器（MA-09 / §6.3）。
///
/// 三条口径，逐条对应计划：
///
/// 1. **每个来源单元恰好 owned 一次**。覆盖账本靠这条算完整覆盖；
///    重叠只进 `context`，不重复产生依据。
/// 2. **超长单句明确切分**。一句话本身超预算时按字符边界切成多段，
///    每段有自己的来源单元 id（`u7#2`），`lineID` 仍指向原句——
///    锚点因此仍能落回不可变修订（MC-46）。
/// 3. **按发言轮次优先成窗**。切点尽量落在说话人变化处，避免腰斩话题；
///    实在没有轮次边界才按 token 硬切。
public enum MinutesWindowPlanner {
    /// 把来源单元切成有界窗口。短会返回单窗（回退口径：短会仍走同一验证器）。
    public static func plan(
        units: [MinutesSourceUnit],
        budget: MinutesWindowBudget = MinutesWindowBudget()
    ) -> [MinutesWindow] {
        guard !units.isEmpty else { return [] }
        let segments = units.flatMap { segment(unit: $0, budget: budget) }
        guard !segments.isEmpty else { return [] }

        var windows: [MinutesWindow] = []
        var current: [MinutesSourceUnit] = []
        var currentTokens = 0

        func cost(_ unit: MinutesSourceUnit) -> Int {
            MinutesTokenEstimate.tokens(in: unit.text)
        }
        func flush() {
            guard !current.isEmpty else { return }
            windows.append(MinutesWindow(
                index: windows.count,
                owned: current,
                contextBefore: [],
                contextAfter: [],
                estimatedTokens: currentTokens
            ))
            current = []
            currentTokens = 0
        }

        for unit in segments {
            let unitCost = cost(unit)
            if !current.isEmpty, currentTokens + unitCost > budget.windowTokens {
                // 切点优先落在说话人变化处：把同一个人连着说的话放进同一窗。
                if let boundary = lastSpeakerBoundary(in: current, before: unit.speaker),
                   boundary > 0 {
                    let tail = Array(current[boundary...])
                    current = Array(current[..<boundary])
                    flush()
                    current = tail
                    currentTokens = tail.reduce(0) { $0 + cost($1) }
                } else {
                    flush()
                }
            }
            current.append(unit)
            currentTokens += unitCost
        }
        flush()

        return withOverlap(windows, overlapUnits: budget.overlapUnits)
    }

    /// 超长单句切分。返回的段各自是独立的来源单元，id 带 `#序号`，
    /// `lineID` 仍指向原句。不截断原文，也不让一段超长发言吃光整窗预算。
    static func segment(unit: MinutesSourceUnit, budget: MinutesWindowBudget) -> [MinutesSourceUnit] {
        let cost = MinutesTokenEstimate.tokens(in: unit.text)
        guard cost > budget.windowTokens, unit.text.count > budget.segmentTokens else {
            return [unit]
        }
        let characters = Array(unit.text)
        var slices: [Range<Int>] = []
        var start = 0
        while start < characters.count {
            var end = min(start + budget.segmentTokens, characters.count)
            if end < characters.count {
                // 在后半段里找标点或空白做切点，读起来更自然。
                let searchStart = max(start + budget.segmentTokens / 2, start + 1)
                if let found = (searchStart..<end).last(where: { isBoundary(characters[$0]) }) {
                    end = found + 1
                }
            }
            slices.append(start..<end)
            start = end
        }
        guard slices.count > 1 else { return [unit] }
        let total = slices.count
        return slices.enumerated().map { offset, range in
            var piece = unit
            piece.id = "\(unit.id)#\(offset + 1)"
            piece.text = String(characters[range])
            piece.segmentIndex = offset
            piece.segmentCount = total
            piece.segmentRange = range
            return piece
        }
    }

    private static func isBoundary(_ character: Character) -> Bool {
        "，。；！？、,.!?; \n\t".contains(character)
    }

    /// 找“下一条说话人不同”的位置；没有轮次变化返回 nil。
    private static func lastSpeakerBoundary(
        in units: [MinutesSourceUnit],
        before nextSpeaker: String
    ) -> Int? {
        guard let last = units.last else { return nil }
        guard last.speaker != nextSpeaker else { return nil }
        var index = units.count - 1
        while index > 0 {
            if units[index].speaker != units[index - 1].speaker { return index }
            index -= 1
        }
        return nil
    }

    /// 给每个窗口补上只读重叠：前窗尾部若干单元 + 后窗头部若干单元。
    /// 重叠不增加拥有单元，也不改变覆盖账本。
    private static func withOverlap(
        _ windows: [MinutesWindow],
        overlapUnits: Int
    ) -> [MinutesWindow] {
        guard overlapUnits > 0, windows.count > 1 else { return windows }
        return windows.enumerated().map { index, window in
            var updated = window
            if index > 0 {
                updated.contextBefore = Array(windows[index - 1].owned.suffix(overlapUnits))
            }
            if index < windows.count - 1 {
                updated.contextAfter = Array(windows[index + 1].owned.prefix(overlapUnits))
            }
            return updated
        }
    }
}

/// 一个窗口的处理结果（覆盖账本的一行）。
public enum MinutesWindowOutcome: String, Codable, Hashable, Sendable {
    /// 已处理并产出候选。
    case processed
    /// 该窗口失败（网络、结构不合法、拒答等）。**可单独重试。**
    case failed
    /// 输出被截断，尾部没拿全。
    case truncated
}

/// 覆盖账本（§6.3 / MC-40）。
///
/// 回答一个问题：**这一版的结论覆盖了整场会议的哪些部分，漏了哪些。**
/// 没有被处理的窗口不允许消失在“100% 完成”里。
public struct MinutesCoverageLedger: Codable, Hashable, Sendable {
    public struct WindowRecord: Codable, Hashable, Sendable {
        public var index: Int
        /// 该窗口 owned 的来源单元 id（全场不重叠）。
        public var ownedUnitIDs: [String]
        public var outcome: MinutesWindowOutcome
        public var failureReason: String?

        public init(
            index: Int,
            ownedUnitIDs: [String],
            outcome: MinutesWindowOutcome,
            failureReason: String? = nil
        ) {
            self.index = index
            self.ownedUnitIDs = ownedUnitIDs
            self.outcome = outcome
            self.failureReason = failureReason
        }
    }

    /// 全场 eligible 的来源单元 id（按顺序）。
    public var eligibleUnitIDs: [String]
    public var windows: [WindowRecord]

    public init(eligibleUnitIDs: [String], windows: [WindowRecord]) {
        self.eligibleUnitIDs = eligibleUnitIDs
        self.windows = windows
    }

    /// 从窗口计划生成一份账本。
    ///
    /// `pendingOutcomes` 给出每个窗口的初始结果（重试时保留成功窗口、
    /// 把失败窗口重新标成待处理）。缺省按计划假定全部成功。
    public static func planned(
        units: [MinutesSourceUnit],
        windows: [MinutesWindow],
        outcomes: [Int: MinutesWindowOutcome] = [:],
        failureReasons: [Int: String] = [:]
    ) -> MinutesCoverageLedger {
        MinutesCoverageLedger(
            eligibleUnitIDs: units.map(\.id),
            windows: windows.map { window in
                WindowRecord(
                    index: window.index,
                    ownedUnitIDs: window.owned.map(\.id),
                    outcome: outcomes[window.index] ?? .processed,
                    failureReason: failureReasons[window.index]
                )
            }
        )
    }

    /// 已成功处理的窗口下标。
    public var processedWindowIndexes: [Int] {
        windows.filter { $0.outcome == .processed }.map(\.index).sorted()
    }

    /// 失败的窗口下标（可局部重试）。
    public var failedWindowIndexes: [Int] {
        windows.filter { $0.outcome == .failed }.map(\.index).sorted()
    }

    /// 被截断的窗口下标。
    public var truncatedWindowIndexes: [Int] {
        windows.filter { $0.outcome == .truncated }.map(\.index).sorted()
    }

    /// 已覆盖（被某个成功窗口拥有）的来源单元 id，保持原顺序。
    public var coveredUnitIDs: [String] {
        let covered = Set(
            windows.filter { $0.outcome == .processed }.flatMap(\.ownedUnitIDs)
        )
        return eligibleUnitIDs.filter { covered.contains($0) }
    }

    /// **缺口**：eligible 但没有被任何成功窗口覆盖的来源单元 id。
    ///
    /// 有缺口就**不许**声称整场完整——候选可以部分可用，但必须说清漏了什么。
    public var gapUnitIDs: [String] {
        let covered = Set(coveredUnitIDs)
        return eligibleUnitIDs.filter { !covered.contains($0) }
    }

    /// 单元层面是否全覆盖。
    public var coversAllUnits: Bool {
        gapUnitIDs.isEmpty
    }

    /// 这一版是否可以宣称“整场完整”。
    ///
    /// 单元全覆盖**且**没有失败/截断窗口才算。单元都覆盖了但中间某窗
    /// 结构不合法，照样不能报 100%。
    public var isComplete: Bool {
        coversAllUnits && failedWindowIndexes.isEmpty && truncatedWindowIndexes.isEmpty
    }

    /// 覆盖情况的一句话说明，进正文与失败原因。
    ///
    /// 缺口不给具体文字（可能是私人内容），只报数量：用户要的是
    /// “哪里没整理到”，不是把没整理的原文再抄一遍。
    public func summary() -> String {
        if isComplete {
            return "已覆盖全部 \(eligibleUnitIDs.count) 条来源。"
        }
        var parts: [String] = []
        if !gapUnitIDs.isEmpty {
            parts.append("有 \(gapUnitIDs.count) 条转录没有整理到")
        }
        if !failedWindowIndexes.isEmpty {
            parts.append("有 \(failedWindowIndexes.count) 个窗口整理失败")
        }
        if !truncatedWindowIndexes.isEmpty {
            parts.append("有 \(truncatedWindowIndexes.count) 个窗口输出被截断")
        }
        return parts.joined(separator: "，") + "；这一版是部分结果，不能当作整场完整纪要。"
    }
}

/// 库里的一行窗口进度（MA-09）。
///
/// 局部重试要靠它：成功的窗口带着已拿到的候选与远端响应 id，
/// 重试时**只**重跑失败的那些，再把全部候选重新归并。
public struct MinutesWindowRecord: Hashable, Sendable, Identifiable {
    public var index: Int
    public var ownedUnitIDs: [String]
    public var contextUnitIDs: [String]
    public var outcome: MinutesWindowOutcome
    public var failureReason: String?
    /// 这一窗产出的候选原文。归并与局部重试都从它读，不重新请求模型。
    public var candidateJSON: String?
    public var remoteResponseID: String?
    public var updatedAt: Date

    public var id: String { "w\(index)" }

    /// 读回这一窗的候选。解不开当没有候选，不猜内容。
    public var candidate: MinutesCandidateV2? {
        guard let candidateJSON, let data = candidateJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MinutesCandidateV2.self, from: data)
    }

    public init(
        index: Int,
        ownedUnitIDs: [String],
        contextUnitIDs: [String] = [],
        outcome: MinutesWindowOutcome,
        failureReason: String? = nil,
        candidateJSON: String? = nil,
        remoteResponseID: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.index = index
        self.ownedUnitIDs = ownedUnitIDs
        self.contextUnitIDs = contextUnitIDs
        self.outcome = outcome
        self.failureReason = failureReason
        self.candidateJSON = candidateJSON
        self.remoteResponseID = remoteResponseID
        self.updatedAt = updatedAt
    }
}

/// 多窗口候选的全局归并（§6.3 reduce）。
///
/// 归并必须**能访问候选对应的原文**，所以这里接收完整的 `units`，
/// 以来源身份去重：同一件事在重叠区被两个窗口各写一次时只留一条，
/// 引用取并集，条数不翻倍（MC-39）。
public enum MinutesCandidateMerger {
    public struct Merged: Sendable {
        public var candidate: MinutesCandidateV2
        public var report: MinutesEvidenceValidator.Report
    }

    /// 把各窗口候选归并成一份，并按全量来源单元重新核对。
    ///
    /// 跨窗撤回/修订的口径（§6.3）：`decided` 与 `retracted` 指向同一
    /// 来源单元时**两个事件都保留**，但标成“存在分歧/未确认”——既不因为
    /// 撤回那句出现在后面就自动认定前面那句作废，也不悄悄只留最新的那句。
    public static func merge(
        windowCandidates: [MinutesCandidateV2],
        units: [MinutesSourceUnit],
        title: String? = nil,
        coverageNote: String? = nil
    ) -> Merged {
        var overview: [MinutesCandidateV2.OverviewItem] = []
        var decisions: [MinutesCandidateV2.DecisionItem] = []
        var actions: [MinutesCandidateV2.ActionItem] = []
        var openQuestions: [MinutesCandidateV2.OpenQuestionItem] = []
        var notes: [String] = []

        for candidate in windowCandidates {
            for item in candidate.overview { mergeOverview(item, into: &overview) }
            for item in candidate.decisions { mergeDecision(item, into: &decisions) }
            for item in candidate.actions { mergeAction(item, into: &actions) }
            for item in candidate.openQuestions { mergeOpenQuestion(item, into: &openQuestions) }
            let note = candidate.confidenceNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty, !notes.contains(note) { notes.append(note) }
        }

        // 跨窗分歧：同一件事既被定了又被撤回时，把这两条结论都标成未确认，
        // 两个事件都留在正文里。判定按**结论说的是同一件事**，不是按引用了
        // 同一句——提出在第 3 句、撤回在第 80 句是常态，两者没有共同来源。
        let disputedTexts = disputedDecisionTexts(decisions: decisions)
        if !disputedTexts.isEmpty {
            let marker = "存在分歧/未确认"
            for index in decisions.indices {
                guard disputedTexts.contains(decisions[index].text) else { continue }
                if !decisions[index].conditions.contains(marker) {
                    decisions[index].conditions.append(marker)
                }
            }
            notes.append(
                "有结论在会议不同阶段被提出又撤回，已保留两个事件并标为未确认，请对照原文核对。"
            )
        }
        if let coverageNote, !coverageNote.isEmpty {
            notes.append(coverageNote)
        }

        let merged = MinutesCandidateV2(
            title: title ?? windowCandidates.first?.title ?? "会议纪要",
            overview: overview,
            decisions: decisions,
            actions: actions,
            openQuestions: openQuestions,
            confidenceNotes: notes.joined(separator: "\n")
        )
        // 归并后按**全量**来源单元重新核对：引用仍必须落在真实快照里。
        let report = MinutesEvidenceValidator.validate(candidate: merged, units: units)
        return Merged(candidate: merged, report: report)
    }

    /// 概述按（文本 + 来源集合）去重：重叠区被两个窗口各写一次时合成一条。
    private static func mergeOverview(
        _ item: MinutesCandidateV2.OverviewItem,
        into items: inout [MinutesCandidateV2.OverviewItem]
    ) {
        if let existing = items.firstIndex(where: {
            $0.text == item.text && sameSourceSet($0.sourceUnitIDs, item.sourceUnitIDs)
        }) {
            items[existing].sourceUnitIDs = union(items[existing].sourceUnitIDs, item.sourceUnitIDs)
            return
        }
        var fresh = item
        if items.contains(where: { $0.localID == item.localID }) {
            fresh.localID = "\(item.localID)-\(items.count + 1)"
        }
        items.append(fresh)
    }

    /// 结论去重：同文本、同语气、同来源集合才算重复。
    /// `decided` 与 `retracted` 语气不同，**永不**互相吞掉（§6.3）。
    private static func mergeDecision(
        _ item: MinutesCandidateV2.DecisionItem,
        into items: inout [MinutesCandidateV2.DecisionItem]
    ) {
        if let existing = items.firstIndex(where: {
            $0.text == item.text
                && $0.modality == item.modality
                && sameSourceSet($0.sourceUnitIDs, item.sourceUnitIDs)
        }) {
            items[existing].sourceUnitIDs = union(items[existing].sourceUnitIDs, item.sourceUnitIDs)
            items[existing].conditions = mergeConditions(items[existing].conditions, item.conditions)
            return
        }
        var fresh = item
        if items.contains(where: { $0.localID == item.localID }) {
            fresh.localID = "\(item.localID)-\(items.count + 1)"
        }
        items.append(fresh)
    }

    /// 待办去重（MC-39）：重叠窗口看到同一条待办时只留一条。
    ///
    /// 判定用「任务文本相同 **或** 来源完全相同」，并合并负责人/期限。
    /// 两窗分别写“李雷跟进”和“李雷（owner）跟进”是同一件事的两种写法，
    /// 拆成两条待办就是重复劳动的源头。
    private static func mergeAction(
        _ item: MinutesCandidateV2.ActionItem,
        into items: inout [MinutesCandidateV2.ActionItem]
    ) {
        if let existing = items.firstIndex(where: {
            $0.task == item.task || sameSourceSet($0.sourceUnitIDs, item.sourceUnitIDs)
        }) {
            items[existing].sourceUnitIDs = union(items[existing].sourceUnitIDs, item.sourceUnitIDs)
            if items[existing].ownerText?.isEmpty ?? true {
                items[existing].ownerText = item.ownerText
            }
            if items[existing].dueExpression?.isEmpty ?? true {
                items[existing].dueExpression = item.dueExpression
            }
            // 承诺程度不一致时不替用户判断哪个对：保留“被认领”的一侧，
            // 差异由验证器与核对界面去暴露（§6.4）。
            if items[existing].commitment != item.commitment {
                items[existing].commitment = .committed
            }
            return
        }
        var fresh = item
        if items.contains(where: { $0.localID == item.localID }) {
            fresh.localID = "\(item.localID)-\(items.count + 1)"
        }
        items.append(fresh)
    }

    private static func mergeOpenQuestion(
        _ item: MinutesCandidateV2.OpenQuestionItem,
        into items: inout [MinutesCandidateV2.OpenQuestionItem]
    ) {
        if let existing = items.firstIndex(where: {
            $0.text == item.text && sameSourceSet($0.sourceUnitIDs, item.sourceUnitIDs)
        }) {
            items[existing].sourceUnitIDs = union(items[existing].sourceUnitIDs, item.sourceUnitIDs)
            return
        }
        var fresh = item
        if items.contains(where: { $0.localID == item.localID }) {
            fresh.localID = "\(item.localID)-\(items.count + 1)"
        }
        items.append(fresh)
    }

    /// 同一件事既有 `decided` 又有 `retracted` 时，返回这些结论的正文。
    ///
    /// 按正文归组而不是按来源单元：跨窗的提出与撤回本来就不引用同一句，
    /// 按单元判定会把真正的分歧漏掉。
    private static func disputedDecisionTexts(
        decisions: [MinutesCandidateV2.DecisionItem]
    ) -> Set<String> {
        let decided = Set(decisions.filter { $0.modality == .decided }.map(\.text))
        let retracted = Set(decisions.filter { $0.modality == .retracted }.map(\.text))
        return decided.intersection(retracted)
    }

    private static func sameSourceSet(_ lhs: [String], _ rhs: [String]) -> Bool {
        Set(lhs) == Set(rhs)
    }

    private static func union(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set(lhs)
        var result = lhs
        for id in rhs where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    private static func mergeConditions(_ lhs: [String], _ rhs: [String]) -> [String] {
        var result = lhs
        for condition in rhs where !result.contains(condition) {
            result.append(condition)
        }
        return result
    }
}

/// 需复核的纪要版本判断（MC-46 后半句）：任一来源修订晚于纪要创建即需复核。
/// 纯值逻辑，放在 Domain 层以便 SPM 测试目标直接覆盖；`MinutesGenerator.reviewIDs`
/// 只是把库里的修订事件与版本列表喂给它。
/// 迟到结果归属判断（MC-45）：库归档以建行时的会话为准，界面状态只写当初那一场。
/// 纯值逻辑，放在 Domain 层以便 SPM 测试目标直接覆盖。
public enum LateResultOwnership: Sendable {
    /// 界面状态能不能写：当前绑定仍是建行那一场时才能写。
    public static func mayWriteUI(boundSessionID: String?, builtSessionID: String?) -> Bool {
        boundSessionID == builtSessionID
    }
}

public enum MinutesReview: Sendable {
    public static func needsReview(
        versionCreatedAt: Date,
        revisionDates: [Date]
    ) -> Bool {
        revisionDates.contains { $0 > versionCreatedAt }
    }

    public static func reviewIDs(
        versions: [(id: String, createdAt: Date)],
        revisions: [Date]
    ) -> Set<String> {
        guard !revisions.isEmpty else { return [] }
        var ids: Set<String> = []
        for version in versions {
            if needsReview(versionCreatedAt: version.createdAt, revisionDates: revisions) {
                ids.insert(version.id)
            }
        }
        return ids
    }
}

/// 任务冻结的配置指纹（MA-07/MC-32）。
///
/// 一次生成任务在排队时就把它用的端点与模型固定下来；用户在任务跑着的时候改设置，
/// 当前任务**不跟着换**——换了等于同一任务前后用了两个端点，出了错无法归因。
/// 新配置从下一次任务生效，这件事由界面说明，不靠这里猜。
///
/// 刻意**不含密钥**：指纹只用于回答"还是同一套配置吗"，不用于重建凭据。
/// 凭据在调用时按安全来源解析，不落库（§8.3）。
public struct MinutesJobConfig: Hashable, Sendable {
    public var baseURL: String
    public var model: String
    public var compatibilityMode: String

    public init(baseURL: String, model: String, compatibilityMode: String) {
        self.baseURL = baseURL
        self.model = model
        self.compatibilityMode = compatibilityMode
    }

    /// 排队那一刻从当前设置取指纹。
    public init(_ configuration: LLMConfiguration) {
        self.init(
            baseURL: configuration.normalizedBaseURL,
            model: configuration.model,
            compatibilityMode: configuration.compatibilityMode.rawValue
        )
    }

    /// 还原成可调用的配置。恢复旧任务时**用它**而不是当前设置（MC-32）。
    ///
    /// 兼容模式读不出来时按通用档走：那是"调用方式"的默认值，不是替用户选模型或端点。
    /// 端点与模型一律照指纹原样还原——那才是这次任务答应过的配置。
    public var configuration: LLMConfiguration {
        LLMConfiguration(
            baseURL: baseURL,
            model: model,
            compatibilityMode: LLMCompatibilityMode(rawValue: compatibilityMode) ?? .openAICompatible
        )
    }

    /// 持久化形态：一行可比较的指纹，不含密钥与正文。
    public var fingerprint: String {
        [baseURL, model, compatibilityMode]
            .map { $0.replacingOccurrences(of: "|", with: "/") }
            .joined(separator: "|")
    }

    /// 从持久化指纹读回；形状不合法时返回 nil，调用方按"配置对不上"处理，
    /// 不猜、不填默认值（MC-32）。
    public static func parse(_ raw: String?) -> MinutesJobConfig? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        return MinutesJobConfig(baseURL: parts[0], model: parts[1], compatibilityMode: parts[2])
    }
}

/// 一次生成请求"远端到底收没收到"的确定程度（MA-07/MC-28、§8.5）。
///
/// 分两类不是为了显得严谨，是因为它们的下一步不同：
/// 知道结果的失败可以按原因重试或改配置；查不出来的那一类**不能自动重发**——
/// 没有可验证的幂等能力时，重发可能重复执行、重复计费。
public enum MinutesSubmissionCertainty: Equatable, Sendable {
    /// 知道结果：服务明确回了状态码、明确拒答、明确没有这个 API。
    case known
    /// 查不出来：请求可能已经送达，只是回执没到手。
    case unknown

    /// 只把**传输层**失败算成未知：发出去没等到回执，或连接中途断了。
    ///
    /// 已知偏保守的一侧：连不上服务（其实还没发出去）也落在未知这一侧。
    /// 宁可多问一句，不替用户断言远端没在跑。
    public static func classify(_ error: Error) -> MinutesSubmissionCertainty {
        guard let llm = error as? LLMError else { return .known }
        if case .transport = llm { return .unknown }
        return .known
    }
}

public enum InnerOSIntent: String, Codable, Sendable {
    case fact
    case analysis
    case draft
    case mixed
}

public enum InnerOSConfidence: String, Codable, Sendable {
    case low
    case medium
    case high

    /// 答案卡上那个胶囊的字。**不确定度是要给用户看的**：判断与事实分开，
    /// 也就是为了让这一格有意义（§5.9）。
    public var label: String {
        switch self {
        case .high: "较有把握"
        case .medium: "中等把握"
        case .low: "不太确定"
        }
    }
}

public enum InnerOSStatus: String, Codable, Sendable {
    case generating
    case ready
    case cancelled
    case failed
}

public enum AssistantMemoryKind: String, Codable, Sendable {
    case fact
    case preference
    case summary
}

// MARK: - 时间点快照（跨存储只靠快照连接，不靠外键）

/// 人设快照。**会话开始写一次，之后不接受更新**（§14.4：换人设会让前缀缓存整段失效）。
public struct PersonaSnapshot: Hashable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// 音色快照。音色被删或改名之后，旧记录仍然说得清「当时用的是谁」（TECHNICAL-DESIGN §6.6）。
public struct VoiceSnapshot: Hashable, Sendable {
    public var id: String
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

// MARK: - 记录

/// `session` 一行。
public struct SessionRecord: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: SessionKind
    public var title: String?
    public var state: SessionRecordState
    public var createdAt: Date
    public var startedAt: Date
    public var endedAt: Date?
    public var engineProfile: String
    public var audioSource: SessionAudioSource
    public var diarization: SessionDiarizationState
    public var diarizationNote: String?
    public var llmEndpoint: String?
    public var llmModel: String?
    public var persona: PersonaSnapshot?
    public var voice: VoiceSnapshot?
    /// 空 = `user`（§15.6 R1：既有行为不用改）。
    public var endReason: SessionEndReason?

    public init(
        id: String,
        kind: SessionKind,
        title: String? = nil,
        state: SessionRecordState,
        createdAt: Date,
        startedAt: Date,
        endedAt: Date? = nil,
        engineProfile: String,
        audioSource: SessionAudioSource,
        diarization: SessionDiarizationState = .off,
        diarizationNote: String? = nil,
        llmEndpoint: String? = nil,
        llmModel: String? = nil,
        persona: PersonaSnapshot? = nil,
        voice: VoiceSnapshot? = nil,
        endReason: SessionEndReason? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.engineProfile = engineProfile
        self.audioSource = audioSource
        self.diarization = diarization
        self.diarizationNote = diarizationNote
        self.llmEndpoint = llmEndpoint
        self.llmModel = llmModel
        self.persona = persona
        self.voice = voice
        self.endReason = endReason
    }

    public var endedReason: SessionEndReason { endReason ?? .user }
}

/// `line` 一行（转录 / 字幕 / 对话正文共用）。
public struct TranscriptLine: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var ordinal: Int
    public var role: SessionLineRole
    /// 分人匿名标签 `A`…`D`，会话内唯一；不是实名（服务只输出匿名 label）。
    public var speakerLabel: String?
    public var text: String
    public var tStart: TimeInterval?
    public var tEnd: TimeInterval?
    public var source: SessionLineSource
    public var status: SessionLineStatus
    /// 助手的这一句被用户打断（§14.5）。**不是错误**，与 `status == .partial` 是两件事。
    public var isInterrupted: Bool
    public var isDeviceSwitch: Bool
    public var isStarred: Bool
    public var timingQuality: SessionTimingQuality?
    public var createdAt: Date

    public init(
        id: String,
        sessionID: String,
        ordinal: Int,
        role: SessionLineRole,
        speakerLabel: String? = nil,
        text: String,
        tStart: TimeInterval? = nil,
        tEnd: TimeInterval? = nil,
        source: SessionLineSource,
        status: SessionLineStatus = .final,
        isInterrupted: Bool = false,
        isDeviceSwitch: Bool = false,
        isStarred: Bool = false,
        timingQuality: SessionTimingQuality? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.ordinal = ordinal
        self.role = role
        self.speakerLabel = speakerLabel
        self.text = text
        self.tStart = tStart
        self.tEnd = tEnd
        self.source = source
        self.status = status
        self.isInterrupted = isInterrupted
        self.isDeviceSwitch = isDeviceSwitch
        self.isStarred = isStarred
        self.timingQuality = timingQuality
        self.createdAt = createdAt
    }

    /// SRT 时间码与导出物一律从 `tStart` 取（§6.5）。没有时间戳的行导不出时间码。
    public var hasTimecode: Bool { tStart != nil }
}

/// 记录库列表用的摘要。`openInterruption` 是**查出来的**事实，不是存出来的字段。
public struct SessionSummary: Identifiable, Hashable, Sendable {
    public var record: SessionRecord
    public var lineCount: Int
    public var speakerCount: Int
    public var openInterruption: SessionInterruptionReason?
    public var latestMinutesStatus: MinutesStatus?

    public var id: String { record.id }

    public init(
        record: SessionRecord,
        lineCount: Int,
        speakerCount: Int,
        openInterruption: SessionInterruptionReason? = nil,
        latestMinutesStatus: MinutesStatus? = nil
    ) {
        self.record = record
        self.lineCount = lineCount
        self.speakerCount = speakerCount
        self.openInterruption = openInterruption
        self.latestMinutesStatus = latestMinutesStatus
    }

    /// 会话时长：结束后取封存值，进行中由调用点传「现在」。
    public func duration(now: Date = Date()) -> TimeInterval {
        let end = record.endedAt ?? (record.state == .archived ? record.startedAt : now)
        return max(0, end.timeIntervalSince(record.startedAt))
    }
}

public struct SessionInterruption: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var atOrdinal: Int
    public var reason: SessionInterruptionReason
    /// 空 = 没有续接，这一段到此为止。
    public var resumedAt: Date?
    public var createdAt: Date

    public init(
        id: String,
        sessionID: String,
        atOrdinal: Int,
        reason: SessionInterruptionReason,
        resumedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.atOrdinal = atOrdinal
        self.reason = reason
        self.resumedAt = resumedAt
        self.createdAt = createdAt
    }
}

public struct SessionChange: Identifiable, Hashable, Sendable {
    public var id: String
    public var atOrdinal: Int
    public var kind: String
    public var value: String
    public var createdAt: Date

    public init(id: String, atOrdinal: Int, kind: String = "voice", value: String, createdAt: Date = Date()) {
        self.id = id
        self.atOrdinal = atOrdinal
        self.kind = kind
        self.value = value
        self.createdAt = createdAt
    }
}

/// 记录库"回看这一条"要显示的全部内容，**一次读完**。
///
/// 翻一条记录原本是 4 次串行库读 + 5 处独立状态写入：每次 `await` 返回都触发
/// 一次界面更新，高亮、页头、正文、元信息分几步跳出来，用户看着像卡住。
/// 合成一个值之后，界面只被赋值一次。
///
/// 它是**快照**，不是事务：四条 SELECT 在 actor 里顺序执行，四份数据来自
/// 同一个串行化的连接，期间不会有别的写入插进来。不要为它加
/// `BEGIN/COMMIT`——那会把一次纯读变成一次写事务。
public struct SessionReviewSnapshot: Hashable, Sendable {
    public var record: SessionRecord
    /// 与 `SessionStore.lines` 默认口径一致：**只含已定稿行**。
    public var lines: [TranscriptLine]
    /// 匿名标签 → 用户手写的名字。
    public var speakerNames: [String: String]
    /// 音色变更点，回看时每一行的徽标按它回推。
    public var voiceChanges: [SessionChange]

    public init(
        record: SessionRecord,
        lines: [TranscriptLine],
        speakerNames: [String: String],
        voiceChanges: [SessionChange]
    ) {
        self.record = record
        self.lines = lines
        self.speakerNames = speakerNames
        self.voiceChanges = voiceChanges
    }
}

/// 纪要的一个版本。重新生成只新增版本，不覆盖旧版。
public struct MinutesVersion: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var version: Int
    public var status: MinutesStatus
    /// Markdown；`status == .queued` 时为空。
    public var body: String?
    public var model: String?
    /// 只存长度：项目约束不允许记录完整 prompt。
    public var promptChars: Int?
    public var isLatest: Bool
    /// MA-06/MC-25/MC-31：用户当前采用版。`isLatest` 只是最新尝试，
    /// 生成失败不清采用指针；采用走预期版本比较，冲突拒绝覆盖。
    public var isAccepted: Bool
    public var attempts: Int
    public var failureReason: String?
    public var leaseUntil: Date?
    public var createdAt: Date

    /// v2 迁移标记：该版本正文是旧库原样迁入的，没有来源快照与结构引用。
    /// 不补造引用；只有用户明确生成新候选时才请求模型补充结构（MA-05/MC-68）。
    public var isLegacyImport: Bool

    // MARK: - 任务身份（MA-07）：任务与内容版本分离

    /// 远端后台响应 id（MA-07/MC-28）。持久化后，App 退出再打开可以**继续轮询原请求**，
    /// 而不是把整场重新发一遍——重新发可能重复计费，也可能覆盖用户已采用的版本。
    /// 它是服务端对象标识，不是用户内容；日志里只记脱敏身份。
    public var remoteResponseID: String?
    /// 本次任务冻结的配置（模型/端点指纹，MA-07/MC-32）。
    /// 用户在任务跑的时候改设置，不能让当前任务偷偷换端点；
    /// 新配置从下一次任务生效这件事由界面说明。
    public var configSnapshot: String?
    /// 任务绑定的来源快照 id（MA-05/MC-20）。同一任务不能边读边跟随来源变化。
    public var snapshotID: String?
    /// 用户按下「停止整理」的时刻（MA-07/MC-30）。非空表示取消已被请求；
    /// 远端是否确认取消是另一件事，不能由这个字段冒充。
    public var cancelRequestedAt: Date?

    // MARK: - 结构化候选与核对报告（MA-08）

    /// 这一版的结构化候选原文（`speechrail.minutes.v2` 的 JSON）。
    /// 正文是渲染结果，**这份是数据**：引文、语气、待办的承诺程度都在里面。
    public var candidateJSON: String?
    /// 这一版的核对报告。**它和正文一起存**，因为"哪里需要核对"是这一版的一部分，
    /// 脱离正文单独保存的话，改了正文就没人知道原来核对的是哪一版。
    public var reviewJSON: String?
    /// 这一版的覆盖账本 JSON（MA-09/§6.3）。记录哪些来源单元被整理到、
    /// 哪些窗口失败或被截断。为 nil 表示这是单窗或旧版本，没有分窗账本。
    public var coverageJSON: String?

    /// 读回核对报告。存的是 JSON 文本，这里解一次；解不开就当没有报告，
    /// 不假装"核对通过"——那正好是验证器最不该犯的错。
    public var review: MinutesEvidenceValidator.Report? {
        guard let reviewJSON, let data = reviewJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MinutesEvidenceValidator.Report.self, from: data)
    }

    /// 读回覆盖账本。解不开当没有账本，**不**默认成"全部覆盖"——
    /// 缺账本和账本说全覆盖是两件事，只有后者才允许说整场完整。
    public var coverage: MinutesCoverageLedger? {
        guard let coverageJSON, let data = coverageJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MinutesCoverageLedger.self, from: data)
    }

    public init(
        id: String,
        sessionID: String,
        version: Int,
        status: MinutesStatus,
        body: String? = nil,
        model: String? = nil,
        promptChars: Int? = nil,
        isLatest: Bool = false,
        isAccepted: Bool = false,
        attempts: Int = 0,
        failureReason: String? = nil,
        leaseUntil: Date? = nil,
        createdAt: Date = Date(),
        isLegacyImport: Bool = false,
        remoteResponseID: String? = nil,
        configSnapshot: String? = nil,
        snapshotID: String? = nil,
        cancelRequestedAt: Date? = nil,
        candidateJSON: String? = nil,
        reviewJSON: String? = nil,
        coverageJSON: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.version = version
        self.status = status
        self.body = body
        self.model = model
        self.promptChars = promptChars
        self.isLatest = isLatest
        self.isAccepted = isAccepted
        self.attempts = attempts
        self.failureReason = failureReason
        self.leaseUntil = leaseUntil
        self.createdAt = createdAt
        self.isLegacyImport = isLegacyImport
        self.remoteResponseID = remoteResponseID
        self.configSnapshot = configSnapshot
        self.snapshotID = snapshotID
        self.cancelRequestedAt = cancelRequestedAt
        self.candidateJSON = candidateJSON
        self.reviewJSON = reviewJSON
        self.coverageJSON = coverageJSON
    }

    /// 这次任务是否可以复用已持久化的远端响应（MC-28）：有远端 id，
    /// 说明请求已被服务端接受，恢复时应当查询原任务而不是重新发起。
    public var hasRemoteResponse: Bool {
        guard let remoteResponseID else { return false }
        return !remoteResponseID.isEmpty
    }
}

// MARK: - 会议知识文档（MA-05）

/// 会议知识文档：独立于采集会话对象存在，导入文档可以没有采集会话（MA-05/MC-68）。
/// 标题与项目元数据由知识文档持有；仍需供旧会话列表显示的标题走统一投影，
/// 不出现两个独立可改、互相漂移的标题源。
public struct MeetingDocument: Identifiable, Hashable, Sendable {
    public var id: String
    /// 可空：采集会话存在时唯一映射，导入文档允许为 nil，不伪造“录过音”（MC-68）。
    public var sourceSessionID: String?
    public var title: String?
    public var projectID: String?
    public var occurredAt: Date?
    public var timezone: String?
    /// 权威库删除语义：非空表示已删除/不可检索，先标记再清理派生（MA-18/MC-62）。
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        sourceSessionID: String? = nil,
        title: String? = nil,
        projectID: String? = nil,
        occurredAt: Date? = nil,
        timezone: String? = nil,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceSessionID = sourceSessionID
        self.title = title
        self.projectID = projectID
        self.occurredAt = occurredAt
        self.timezone = timezone
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 转录来源修订：ASR 原文与用户修订分开，新修改产生新 revision，不覆盖原始记录（MA-05/MC-46）。
public struct TranscriptRevision: Identifiable, Hashable, Sendable {
    public var id: String
    public var lineID: String
    public var sessionID: String
    public var text: String
    /// `asr` / `user_edit` / `legacy_import`：旧库迁入正文标 legacy，不补造来源。
    public var origin: String
    public var parentRevisionID: String?
    public var editedAt: Date

    public init(
        id: String,
        lineID: String,
        sessionID: String,
        text: String,
        origin: String,
        parentRevisionID: String? = nil,
        editedAt: Date = Date()
    ) {
        self.id = id
        self.lineID = lineID
        self.sessionID = sessionID
        self.text = text
        self.origin = origin
        self.parentRevisionID = parentRevisionID
        self.editedAt = editedAt
    }
}

/// 会议来源快照：生成基于固定快照，同一任务不能边读边跟随变化（MA-05/MC-20）。
/// 快照写入与文档关联是同一事务，失败全部回滚，不发已保存回执（MC-20）。
public struct MeetingSourceSnapshot: Identifiable, Hashable, Sendable {
    public var id: String
    public var documentID: String
    public var lineRevisionIDs: [String]
    public var speakerMapRevision: String?
    public var noteRefs: [String]
    public var coverage: String?
    /// `ok` / `degraded`：降级快照必须携带缺口信息，不能掩盖（MC-19）。
    public var sealResult: String
    public var createdAt: Date

    public init(
        id: String,
        documentID: String,
        lineRevisionIDs: [String] = [],
        speakerMapRevision: String? = nil,
        noteRefs: [String] = [],
        coverage: String? = nil,
        sealResult: String = "ok",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.lineRevisionIDs = lineRevisionIDs
        self.speakerMapRevision = speakerMapRevision
        self.noteRefs = noteRefs
        self.coverage = coverage
        self.sealResult = sealResult
        self.createdAt = createdAt
    }
}

public struct InnerOSExchange: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var askedAt: Date
    /// 提问时的转录水位。
    public var atOrdinal: Int?
    public var question: String
    public var intent: InnerOSIntent?
    public var answerText: String?
    public var draftText: String?
    public var confidence: InnerOSConfidence?
    public var limitsNote: String?
    public var model: String?
    public var status: InnerOSStatus
    /// 「写进纪要」是显式动作，默认 0（§14.2）。
    public var inMinutes: Bool

    public init(
        id: String,
        sessionID: String,
        askedAt: Date = Date(),
        atOrdinal: Int? = nil,
        question: String,
        intent: InnerOSIntent? = nil,
        answerText: String? = nil,
        draftText: String? = nil,
        confidence: InnerOSConfidence? = nil,
        limitsNote: String? = nil,
        model: String? = nil,
        status: InnerOSStatus = .generating,
        inMinutes: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.askedAt = askedAt
        self.atOrdinal = atOrdinal
        self.question = question
        self.intent = intent
        self.answerText = answerText
        self.draftText = draftText
        self.confidence = confidence
        self.limitsNote = limitsNote
        self.model = model
        self.status = status
        self.inMinutes = inMinutes
    }
}

/// 内心 OS 答案引用的那一行原文。`lineID` 允许为空（那一行可能已被移除），
/// 所以渲染时**先把 `quote` 当作事实**，不要假定还能顺着 id 找回正文。
public struct InnerOSEvidence: Identifiable, Hashable, Sendable {
    public var id: String
    public var lineID: String?
    public var speakerLabel: String?
    public var tStart: TimeInterval?
    public var quote: String?
    public var contentHash: String?

    public init(
        id: String = UUID().uuidString,
        lineID: String? = nil,
        speakerLabel: String? = nil,
        tStart: TimeInterval? = nil,
        quote: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.lineID = lineID
        self.speakerLabel = speakerLabel
        self.tStart = tStart
        self.quote = quote
        self.contentHash = contentHash
    }
}

/// 助手的长期信息：与某一次会话解耦，会话被移除时它仍然留着。
public struct AssistantMemory: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: AssistantMemoryKind
    public var body: String
    public var sourceSessionID: String?
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        kind: AssistantMemoryKind,
        body: String,
        sourceSessionID: String? = nil,
        isActive: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.body = body
        self.sourceSessionID = sourceSessionID
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 记录名：用户不取名时，用**第一句**顶上来。
///
/// 为什么要有它（2026-09-19 用户验收："记录和纪要是资产"）：一条记录不取名，记录库那一列
/// 就是一排「未命名 + 时间 + N 句」，翻起来认不出哪条是哪条，而"继续这一轮"、"导出"、
/// "重命名"这些动作都要先认得它。第一句是这段对话里**唯一一处用户可以自己认领的标签**，
/// 拿它当名字比"未命名"有用，也比让模型编一个标题诚实（用户改名之后以改名为准：
/// 那一列只由人来写，这个建议只用一次）。
///
/// 取法（列表一行只放得下这么多，宁可短也不能折一半）：
/// 1. 压掉所有换行与多余空白——名字是一行字；
/// 2. 先取到第一个句末（`。！？`）为止；这一句短到不足 6 个字，就把下一句也接上，
///    免得名字只有"嗯"、"那个"这种没有信息量的一句；
/// 3. 还是太长就砍到 20 个字，优先断在最后一个逗号处（读起来是半句而不是断字），加省略号。
public enum SessionTitleSuggestion {
    /// 名字最多几个字。列表行的宽度与"一眼扫得过去"共同定下来的数。
    public static let maxLength = 20

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?", "."]
    private static let softBreaks: Set<Character> = ["，", "、", ",", "；", ";", "：", ":", " "]

    public static func suggest(from text: String) -> String? {
        let flat = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "「」“”\"'"))
        guard !flat.isEmpty else { return nil }

        // 第 2 步：句末之前的部分。整段都没有句末时就是整段（后面按长度收）。
        var head = ""
        var rest = Substring(flat)
        while let enderIndex = rest.firstIndex(where: { sentenceEnders.contains($0) }) {
            head += rest[rest.startIndex..<enderIndex]
            rest = rest[rest.index(after: enderIndex)...]
            if head.count >= 6 { break }
            head += "，"   // 太短就把下一句接上，句读用逗号
        }
        if head.isEmpty { head = flat }

        let trimmedHead = head.trimmingCharacters(in: CharacterSet(charactersIn: "，、,；;：: "))
        guard !trimmedHead.isEmpty else { return nil }
        guard trimmedHead.count > maxLength else { return trimmedHead }

        // 第 3 步：砍到 20 个字，能断在逗号处就断在逗号处。
        let clipped = trimmedHead.prefix(maxLength)
        if let breakIndex = clipped.lastIndex(where: { softBreaks.contains($0) }),
           clipped.distance(from: clipped.startIndex, to: breakIndex) >= 8 {
            return String(clipped[clipped.startIndex..<breakIndex]) + "…"
        }
        return String(clipped) + "…"
    }
}

// MARK: - 建行 / 落行的输入

/// `createSession` 的输入。只在**首个 PCM 已发送**时调用（§6.4）。
public struct SessionDraft: Sendable {
    public var kind: SessionKind
    public var engineProfile: String
    public var audioSource: SessionAudioSource
    public var diarization: SessionDiarizationState
    public var diarizationNote: String?
    public var llmEndpoint: String?
    public var llmModel: String?
    public var persona: PersonaSnapshot?
    public var voice: VoiceSnapshot?
    public var startedAt: Date
    public var title: String?

    public init(
        kind: SessionKind,
        engineProfile: String,
        audioSource: SessionAudioSource,
        diarization: SessionDiarizationState = .off,
        diarizationNote: String? = nil,
        llmEndpoint: String? = nil,
        llmModel: String? = nil,
        persona: PersonaSnapshot? = nil,
        voice: VoiceSnapshot? = nil,
        title: String? = nil,
        startedAt: Date = Date()
    ) {
        self.kind = kind
        self.engineProfile = engineProfile
        self.audioSource = audioSource
        self.diarization = diarization
        self.diarizationNote = diarizationNote
        self.llmEndpoint = llmEndpoint
        self.llmModel = llmModel
        self.persona = persona
        self.voice = voice
        self.title = title
        self.startedAt = startedAt
    }
}

/// `appendLine` 的输入。`ordinal` 由库分配（§15.7 R2 ①：取号与插入同一事务）。
public struct LineDraft: Sendable {
    public var sessionID: String
    public var role: SessionLineRole
    public var text: String
    public var source: SessionLineSource
    public var speakerLabel: String?
    public var tStart: TimeInterval?
    public var tEnd: TimeInterval?
    public var status: SessionLineStatus
    public var isInterrupted: Bool
    public var isDeviceSwitch: Bool
    public var timingQuality: SessionTimingQuality?
    /// 这一句的**观测时刻**（D09）。
    ///
    /// `nil` 表示"沿用 Store 写入的那一刻"——那是插入延迟，不是用户说话的时间。
    /// 助手语音行会显式传**第一个非空证据被本机收到的那一刻**：既不冒充声学开口
    /// 时间，也不会因为"每条都写同一串零"而让回看的时间轴恒等于会话起点。
    public var createdAt: Date?

    public init(
        sessionID: String,
        role: SessionLineRole,
        text: String,
        source: SessionLineSource,
        speakerLabel: String? = nil,
        tStart: TimeInterval? = nil,
        tEnd: TimeInterval? = nil,
        status: SessionLineStatus = .final,
        isInterrupted: Bool = false,
        isDeviceSwitch: Bool = false,
        timingQuality: SessionTimingQuality? = nil,
        createdAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.role = role
        self.text = text
        self.source = source
        self.speakerLabel = speakerLabel
        self.tStart = tStart
        self.tEnd = tEnd
        self.status = status
        self.isInterrupted = isInterrupted
        self.isDeviceSwitch = isDeviceSwitch
        self.timingQuality = timingQuality
        self.createdAt = createdAt
    }
}

// MARK: - 知识归档包（MA-19 / MC-48、MC-65、MC-66、MC-71）

/// 归档范围。**分享包与完整归档是两种东西，不是一个开关的两端**（MA-19）。
///
/// 分享包只装"这一版纪要说过什么、依据哪几句"：选定的**那一版**结论条目、
/// 证据锚点，以及锚点真正引用到的那几行原文与行修订。它不装整场转录，
/// 也不装其他版本——分享出去的东西不该顺手把整场会议和历史版本一起带走。
///
/// 完整归档装整场：所有纪要版本、全部条目与锚点、被引用过的全部行修订、
/// 来源快照、分窗账本。用途是保真往返与本地归档，不是直接发给别人。
public enum KnowledgeArchiveScope: String, Codable, Hashable, Sendable {
    case share
    case fullArchive = "full_archive"

    public var title: String {
        switch self {
        case .share: "分享包"
        case .fullArchive: "完整归档"
        }
    }
}

/// 导出选择（MA-19）。三件事缺一不可：`document` 定位是哪一场知识，
/// `revision` 固定是哪一版纪要，`scope` 决定装多少。
///
/// **revision 是必填而不是可选的"当前版"**（MC-48）：用户在看 v1、库里已经有 v3 时，
/// 导出必须还是 v1。传 nil 让导出"自己挑一版"就是这条验收的失败形态。
public struct KnowledgeArchiveSelection: Hashable, Sendable {
    public var documentID: String
    public var minutesID: String
    public var scope: KnowledgeArchiveScope

    public init(documentID: String, minutesID: String, scope: KnowledgeArchiveScope) {
        self.documentID = documentID
        self.minutesID = minutesID
        self.scope = scope
    }
}

/// 归档包里的失败。**没有"读不到就导空壳"这一项**：读失败是失败，不是空内容。
public enum KnowledgeArchiveError: Error, LocalizedError, Equatable {
    case documentNotFound(String)
    /// 选定的那一版读不到。不允许退回"当前展示版"冒充（MC-48）。
    case minutesNotFound(String)
    /// 选定的那一版没有正文。导出一个空壳再宣称成功，比直接失败更糟（MC-65）。
    case minutesBodyMissing(String)
    /// 库里读错了。原文消息保留，但不产出任何文件。
    case readFailed(String)
    /// 目标已存在。已导出的文件不静默覆盖（MA-19 回退条款）。
    case destinationExists(String)
    case malformedPackage(String)
    /// 包里有不让落盘的东西：路径穿越、符号链接、未知条目。
    case entryRejected(String)
    case payloadTooLarge(Int)
    case invalidIdentifier(String)
    /// 包内引用指向包里没有的对象。
    case brokenReference(String)
    /// 同 ID 异内容。必须先看冲突预览，不允许部分覆盖用户现有文档。
    case identityConflict(String)

    public var errorDescription: String? {
        switch self {
        case .documentNotFound(let id):
            "找不到这场会议知识文档（\(id)）"
        case .minutesNotFound(let id):
            "找不到选中的纪要版本（\(id)），没有导出"
        case .minutesBodyMissing(let id):
            "选中的那一版没有正文，导不出可读的纪要"
        case .readFailed(let detail):
            "读取知识内容失败：\(detail)"
        case .destinationExists(let name):
            "目标已存在，没有覆盖它：\(name)"
        case .malformedPackage(let detail):
            "这个包读不出来：\(detail)"
        case .entryRejected(let name):
            "包里有不让导入的内容：\(name)"
        case .payloadTooLarge(let bytes):
            "包太大了（\(bytes) 字节），超过导入上限"
        case .invalidIdentifier(let detail):
            "包里的标识不合法：\(detail)"
        case .brokenReference(let detail):
            "包里的引用断了：\(detail)"
        case .identityConflict(let detail):
            "有同 ID 但内容不同的对象，先看冲突预览再决定：\(detail)"
        }
    }
}

/// 清单（MA-19）。只存计数、身份与版本，**不存正文、不存绝对路径**：
/// 清单跟着包走，泄露面必须和包本身一样小（与 MA-20 备份清单同一口径）。
public struct KnowledgeArchiveManifest: Codable, Hashable, Sendable {
    public static let schemaID = "speechrail.meeting.knowledge-archive/1"
    public static let manifestFileName = "manifest.json"
    public static let markdownFileName = "minutes.md"
    public static let structuredFileName = "structured.json"
    public static let directoryExtension = "srknowledge"

    public var schema: String
    public var createdAt: Date
    public var scope: KnowledgeArchiveScope
    public var documentID: String
    /// 文档标题。清单里唯一一处人类可读文本：它让包名可认，
    /// 又不携带正文——泄露面仍是一个标题，不是一整场会议。
    public var documentTitle: String?
    /// 采集会话存在时才有；导入来源的文档允许为空（不伪造"录过音"）。
    public var sessionID: String?
    /// 用户选中的那一版。全程按它取，任何环节都不改。
    public var selectedMinutesID: String
    public var selectedVersion: Int
    /// 导出时这一场的采用指针。往返后要能核回同一个 id（MC-66）。
    public var acceptedMinutesID: String?
    public var sourceSchemaVersion: Int
    public var counts: KnowledgeArchiveCounts
    public var files: [KnowledgeArchiveFile]

    public init(
        schema: String = KnowledgeArchiveManifest.schemaID,
        createdAt: Date = Date(),
        scope: KnowledgeArchiveScope,
        documentID: String,
        documentTitle: String? = nil,
        sessionID: String?,
        selectedMinutesID: String,
        selectedVersion: Int,
        acceptedMinutesID: String?,
        sourceSchemaVersion: Int,
        counts: KnowledgeArchiveCounts,
        files: [KnowledgeArchiveFile]
    ) {
        self.schema = schema
        self.createdAt = createdAt
        self.scope = scope
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.sessionID = sessionID
        self.selectedMinutesID = selectedMinutesID
        self.selectedVersion = selectedVersion
        self.acceptedMinutesID = acceptedMinutesID
        self.sourceSchemaVersion = sourceSchemaVersion
        self.counts = counts
        self.files = files
    }
}

/// 包内文件条目。带字节数：清单说有 12 KB、实际只有 200 B 的包
/// 不是损坏就是被截断，两种都不该当可用包导入。
public struct KnowledgeArchiveFile: Codable, Hashable, Sendable {
    public var name: String
    public var byteCount: Int

    public init(name: String, byteCount: Int) {
        self.name = name
        self.byteCount = byteCount
    }
}

/// 计数。导入后按同一组数字核对"少了没有、多了没有"——逐项比，
/// 只比总数会把"少一条、多一条"这种互相抵消的情况判成一致。
public struct KnowledgeArchiveCounts: Codable, Hashable, Sendable {
    public var sessions: Int
    public var lines: Int
    public var speakerNames: Int
    public var documents: Int
    public var snapshots: Int
    public var revisions: Int
    public var minutes: Int
    public var items: Int
    public var anchors: Int
    public var windows: Int

    public init(
        sessions: Int,
        lines: Int,
        speakerNames: Int,
        documents: Int,
        snapshots: Int,
        revisions: Int,
        minutes: Int,
        items: Int,
        anchors: Int,
        windows: Int
    ) {
        self.sessions = sessions
        self.lines = lines
        self.speakerNames = speakerNames
        self.documents = documents
        self.snapshots = snapshots
        self.revisions = revisions
        self.minutes = minutes
        self.items = items
        self.anchors = anchors
        self.windows = windows
    }

    public static let zero = KnowledgeArchiveCounts(
        sessions: 0, lines: 0, speakerNames: 0, documents: 0, snapshots: 0,
        revisions: 0, minutes: 0, items: 0, anchors: 0, windows: 0
    )
}

/// 冲突预览的一条（MC-71）。**同 ID 是两回事，同 ID 同内容又是另一回事**：
/// 内容相同就跳过（幂等重导），内容不同才是冲突，必须让用户先看见。
public struct KnowledgeArchiveConflict: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case session
        case line
        case speakerName = "speaker_name"
        case document
        case snapshot
        case revision
        case minutes
        case minutesItem = "minutes_item"
        case evidence
        case window
    }

    public var kind: Kind
    public var id: String
    /// true 表示库里已有且内容完全一致，可以直接跳过。
    public var isIdentical: Bool

    public init(kind: Kind, id: String, isIdentical: Bool) {
        self.kind = kind
        self.id = id
        self.isIdentical = isIdentical
    }
}

/// 导入预检结论。只读，不写库。
public struct KnowledgeArchivePreview: Sendable {
    public var manifest: KnowledgeArchiveManifest
    public var conflicts: [KnowledgeArchiveConflict]
    /// 包里要落库的对象数（不含会跳过的重复项）。
    public var newObjectCount: Int

    public init(manifest: KnowledgeArchiveManifest, conflicts: [KnowledgeArchiveConflict], newObjectCount: Int) {
        self.manifest = manifest
        self.conflicts = conflicts
        self.newObjectCount = newObjectCount
    }

    /// 真正的冲突 = 同 ID 但内容不同。同内容重复不算。
    public var realConflicts: [KnowledgeArchiveConflict] {
        conflicts.filter { !$0.isIdentical }
    }

    public var isSafeToImport: Bool { realConflicts.isEmpty }
}

/// 导入结果。只报事实，不报"成功"以外的判断。
public struct KnowledgeArchiveImportResult: Sendable {
    public var documentID: String
    public var selectedMinutesID: String
    public var inserted: KnowledgeArchiveCounts
    public var skippedIdentical: Int

    public init(
        documentID: String,
        selectedMinutesID: String,
        inserted: KnowledgeArchiveCounts,
        skippedIdentical: Int
    ) {
        self.documentID = documentID
        self.selectedMinutesID = selectedMinutesID
        self.inserted = inserted
        self.skippedIdentical = skippedIdentical
    }
}

/// `structured.json` 的根。**字段名与内部类型解耦**：内部改字段名不会静默改掉
/// 已经发出去的包，老包也不会因为新版本内部重构就读不回来（MA-19 开放格式）。
public struct KnowledgeArchivePayload: Codable, Hashable, Sendable {
    public static let schemaID = "speechrail.meeting.knowledge-archive.payload/1"

    public var schema: String
    public var document: ArchiveDocument
    public var session: ArchiveSession?
    public var lines: [ArchiveLine]
    /// 匿名标签 → 显示名。**正文一个字不动**（§15.3）。
    public var speakerNames: [String: String]
    public var snapshots: [ArchiveSnapshot]
    public var revisions: [ArchiveRevision]
    public var minutes: [ArchiveMinutes]
    public var items: [ArchiveItem]
    public var windows: [ArchiveWindow]

    public init(
        schema: String = KnowledgeArchivePayload.schemaID,
        document: ArchiveDocument,
        session: ArchiveSession?,
        lines: [ArchiveLine],
        speakerNames: [String: String],
        snapshots: [ArchiveSnapshot],
        revisions: [ArchiveRevision],
        minutes: [ArchiveMinutes],
        items: [ArchiveItem],
        windows: [ArchiveWindow]
    ) {
        self.schema = schema
        self.document = document
        self.session = session
        self.lines = lines
        self.speakerNames = speakerNames
        self.snapshots = snapshots
        self.revisions = revisions
        self.minutes = minutes
        self.items = items
        self.windows = windows
    }
}

public struct ArchiveDocument: Codable, Hashable, Sendable {
    public var id: String
    public var sourceSessionID: String?
    public var title: String?
    public var projectID: String?
    public var occurredAt: Double?
    public var timezone: String?
    public var deletedAt: Double?
    public var createdAt: Double
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case projectID = "project_id"
        case timezone
        case sourceSessionID = "source_session_id"
        case occurredAt = "occurred_at"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        sourceSessionID: String? = nil,
        title: String? = nil,
        projectID: String? = nil,
        occurredAt: Double? = nil,
        timezone: String? = nil,
        deletedAt: Double? = nil,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.sourceSessionID = sourceSessionID
        self.title = title
        self.projectID = projectID
        self.occurredAt = occurredAt
        self.timezone = timezone
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ArchiveSession: Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var title: String?
    public var state: String
    public var createdAt: Double
    public var startedAt: Double
    public var endedAt: Double?
    public var engineProfile: String
    public var audioSource: String
    public var diarization: String
    public var diarizationNote: String?
    public var llmEndpoint: String?
    public var llmModel: String?
    public var personaID: String?
    public var personaTitle: String?
    public var voiceID: String?
    public var voiceName: String?
    public var endReason: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case state
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case engineProfile = "engine_profile"
        case audioSource = "audio_source"
        case diarization
        case diarizationNote = "diarization_note"
        case llmEndpoint = "llm_endpoint"
        case llmModel = "llm_model"
        case personaID = "persona_id"
        case personaTitle = "persona_title"
        case voiceID = "voice_id"
        case voiceName = "voice_name"
        case endReason = "end_reason"
    }

    public init(
        id: String,
        kind: String,
        title: String? = nil,
        state: String,
        createdAt: Double,
        startedAt: Double,
        endedAt: Double? = nil,
        engineProfile: String,
        audioSource: String,
        diarization: String,
        diarizationNote: String? = nil,
        llmEndpoint: String? = nil,
        llmModel: String? = nil,
        personaID: String? = nil,
        personaTitle: String? = nil,
        voiceID: String? = nil,
        voiceName: String? = nil,
        endReason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.engineProfile = engineProfile
        self.audioSource = audioSource
        self.diarization = diarization
        self.diarizationNote = diarizationNote
        self.llmEndpoint = llmEndpoint
        self.llmModel = llmModel
        self.personaID = personaID
        self.personaTitle = personaTitle
        self.voiceID = voiceID
        self.voiceName = voiceName
        self.endReason = endReason
    }
}

public struct ArchiveLine: Codable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var ordinal: Int
    public var role: String
    public var speakerLabel: String?
    public var text: String
    public var tStart: Double?
    public var tEnd: Double?
    public var source: String
    public var status: String
    public var interrupted: Bool
    public var deviceSwitch: Bool
    public var starred: Bool
    public var timingQuality: String?
    public var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case ordinal
        case role
        case text
        case source
        case status
        case interrupted
        case starred
        case sessionID = "session_id"
        case speakerLabel = "speaker_label"
        case tStart = "t_start"
        case tEnd = "t_end"
        case deviceSwitch = "device_switch"
        case timingQuality = "timing_quality"
        case createdAt = "created_at"
    }

    public init(
        id: String,
        sessionID: String,
        ordinal: Int,
        role: String,
        speakerLabel: String? = nil,
        text: String,
        tStart: Double? = nil,
        tEnd: Double? = nil,
        source: String,
        status: String,
        interrupted: Bool,
        deviceSwitch: Bool,
        starred: Bool,
        timingQuality: String? = nil,
        createdAt: Double
    ) {
        self.id = id
        self.sessionID = sessionID
        self.ordinal = ordinal
        self.role = role
        self.speakerLabel = speakerLabel
        self.text = text
        self.tStart = tStart
        self.tEnd = tEnd
        self.source = source
        self.status = status
        self.interrupted = interrupted
        self.deviceSwitch = deviceSwitch
        self.starred = starred
        self.timingQuality = timingQuality
        self.createdAt = createdAt
    }
}

public struct ArchiveSnapshot: Codable, Hashable, Sendable {
    public var id: String
    public var documentID: String
    public var lineRevisionIDs: [String]
    public var speakerMapRevision: String?
    public var noteRefs: [String]
    public var coverage: String?
    public var sealResult: String
    public var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case coverage
        case documentID = "document_id"
        case lineRevisionIDs = "line_revision_ids"
        case speakerMapRevision = "speaker_map_revision"
        case noteRefs = "note_refs"
        case sealResult = "seal_result"
        case createdAt = "created_at"
    }

    public init(
        id: String,
        documentID: String,
        lineRevisionIDs: [String],
        speakerMapRevision: String? = nil,
        noteRefs: [String],
        coverage: String? = nil,
        sealResult: String,
        createdAt: Double
    ) {
        self.id = id
        self.documentID = documentID
        self.lineRevisionIDs = lineRevisionIDs
        self.speakerMapRevision = speakerMapRevision
        self.noteRefs = noteRefs
        self.coverage = coverage
        self.sealResult = sealResult
        self.createdAt = createdAt
    }
}

public struct ArchiveRevision: Codable, Hashable, Sendable {
    public var id: String
    public var lineID: String
    public var sessionID: String
    public var text: String
    public var origin: String
    public var parentRevisionID: String?
    public var editedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case origin
        case lineID = "line_id"
        case sessionID = "session_id"
        case parentRevisionID = "parent_revision_id"
        case editedAt = "edited_at"
    }

    public init(
        id: String,
        lineID: String,
        sessionID: String,
        text: String,
        origin: String,
        parentRevisionID: String? = nil,
        editedAt: Double
    ) {
        self.id = id
        self.lineID = lineID
        self.sessionID = sessionID
        self.text = text
        self.origin = origin
        self.parentRevisionID = parentRevisionID
        self.editedAt = editedAt
    }
}

public struct ArchiveMinutes: Codable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var version: Int
    public var status: String
    public var body: String?
    public var model: String?
    public var promptChars: Int?
    public var isLatest: Bool
    public var isAccepted: Bool
    public var attempts: Int
    public var failureReason: String?
    public var leaseUntil: Double?
    public var createdAt: Double
    public var isLegacyImport: Bool
    public var remoteResponseID: String?
    public var configSnapshot: String?
    public var snapshotID: String?
    public var cancelRequestedAt: Double?
    public var candidateJSON: String?
    public var reviewJSON: String?
    public var coverageJSON: String?

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case status
        case body
        case model
        case attempts
        case sessionID = "session_id"
        case promptChars = "prompt_chars"
        case isLatest = "is_latest"
        case isAccepted = "is_accepted"
        case failureReason = "failure_reason"
        case leaseUntil = "lease_until"
        case createdAt = "created_at"
        case isLegacyImport = "is_legacy_import"
        case remoteResponseID = "remote_response_id"
        case configSnapshot = "config_snapshot"
        case snapshotID = "snapshot_id"
        case cancelRequestedAt = "cancel_requested_at"
        case candidateJSON = "candidate_json"
        case reviewJSON = "review_json"
        case coverageJSON = "coverage_json"
    }

    public init(
        id: String,
        sessionID: String,
        version: Int,
        status: String,
        body: String?,
        model: String? = nil,
        promptChars: Int? = nil,
        isLatest: Bool,
        isAccepted: Bool,
        attempts: Int,
        failureReason: String? = nil,
        leaseUntil: Double? = nil,
        createdAt: Double,
        isLegacyImport: Bool,
        remoteResponseID: String? = nil,
        configSnapshot: String? = nil,
        snapshotID: String? = nil,
        cancelRequestedAt: Double? = nil,
        candidateJSON: String? = nil,
        reviewJSON: String? = nil,
        coverageJSON: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.version = version
        self.status = status
        self.body = body
        self.model = model
        self.promptChars = promptChars
        self.isLatest = isLatest
        self.isAccepted = isAccepted
        self.attempts = attempts
        self.failureReason = failureReason
        self.leaseUntil = leaseUntil
        self.createdAt = createdAt
        self.isLegacyImport = isLegacyImport
        self.remoteResponseID = remoteResponseID
        self.configSnapshot = configSnapshot
        self.snapshotID = snapshotID
        self.cancelRequestedAt = cancelRequestedAt
        self.candidateJSON = candidateJSON
        self.reviewJSON = reviewJSON
        self.coverageJSON = coverageJSON
    }
}

public struct ArchiveItem: Codable, Hashable, Sendable {
    public var id: String
    public var minutesID: String
    public var localID: String
    public var kind: String
    public var text: String
    public var verdict: String?
    public var sortOrder: Int
    public var anchors: [ArchiveAnchor]

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case verdict
        case anchors
        case minutesID = "minutes_id"
        case localID = "local_id"
        case sortOrder = "sort_order"
    }

    public init(
        id: String,
        minutesID: String,
        localID: String,
        kind: String,
        text: String,
        verdict: String?,
        sortOrder: Int,
        anchors: [ArchiveAnchor]
    ) {
        self.id = id
        self.minutesID = minutesID
        self.localID = localID
        self.kind = kind
        self.text = text
        self.verdict = verdict
        self.sortOrder = sortOrder
        self.anchors = anchors
    }
}

public struct ArchiveAnchor: Codable, Hashable, Sendable {
    public var id: String
    public var itemID: String
    public var unitID: String
    public var lineID: String?
    public var revisionID: String?
    public var snapshotID: String?
    public var speakerLabel: String?
    public var startSeconds: Double?
    /// 锚点当时的原文。**随包带走**：来源行之后被改被删，这段引文仍然可读，
    /// 否则导入到一个新库就只剩一个指不到东西的指针（MC-66）。
    public var quote: String?
    public var verification: String

    enum CodingKeys: String, CodingKey {
        case id
        case quote
        case verification
        case itemID = "item_id"
        case unitID = "unit_id"
        case lineID = "line_id"
        case revisionID = "revision_id"
        case snapshotID = "snapshot_id"
        case speakerLabel = "speaker_label"
        case startSeconds = "start_seconds"
    }

    public init(
        id: String,
        itemID: String,
        unitID: String,
        lineID: String? = nil,
        revisionID: String? = nil,
        snapshotID: String? = nil,
        speakerLabel: String? = nil,
        startSeconds: Double? = nil,
        quote: String? = nil,
        verification: String
    ) {
        self.id = id
        self.itemID = itemID
        self.unitID = unitID
        self.lineID = lineID
        self.revisionID = revisionID
        self.snapshotID = snapshotID
        self.speakerLabel = speakerLabel
        self.startSeconds = startSeconds
        self.quote = quote
        self.verification = verification
    }
}

public struct ArchiveWindow: Codable, Hashable, Sendable {
    public var id: String
    public var minutesID: String
    public var index: Int
    public var ownedUnitIDs: [String]
    public var contextUnitIDs: [String]
    public var outcome: String
    public var failureReason: String?
    public var candidateJSON: String?
    public var remoteResponseID: String?
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case index
        case outcome
        case minutesID = "minutes_id"
        case ownedUnitIDs = "owned_unit_ids"
        case contextUnitIDs = "context_unit_ids"
        case failureReason = "failure_reason"
        case candidateJSON = "candidate_json"
        case remoteResponseID = "remote_response_id"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        minutesID: String,
        index: Int,
        ownedUnitIDs: [String],
        contextUnitIDs: [String],
        outcome: String,
        failureReason: String? = nil,
        candidateJSON: String? = nil,
        remoteResponseID: String? = nil,
        updatedAt: Double
    ) {
        self.id = id
        self.minutesID = minutesID
        self.index = index
        self.ownedUnitIDs = ownedUnitIDs
        self.contextUnitIDs = contextUnitIDs
        self.outcome = outcome
        self.failureReason = failureReason
        self.candidateJSON = candidateJSON
        self.remoteResponseID = remoteResponseID
        self.updatedAt = updatedAt
    }
}

// MARK: - 归档包的模型转换（MA-19）
//
// 库内类型不直接 `Codable`，包的 DTO 也不直接复用库内类型。中间这一层
// 显式写出每个字段，是为了让"包格式"这件事有唯一答案：内部改字段名不会
// 静默改掉已经发出去的包，反过来老包也不会因为内部重构读不回来。
extension MeetingDocument {
    var archiveModel: ArchiveDocument {
        ArchiveDocument(
            id: id,
            sourceSessionID: sourceSessionID,
            title: title,
            projectID: projectID,
            occurredAt: occurredAt?.timeIntervalSince1970,
            timezone: timezone,
            deletedAt: deletedAt?.timeIntervalSince1970,
            createdAt: createdAt.timeIntervalSince1970,
            updatedAt: updatedAt.timeIntervalSince1970
        )
    }
}

extension SessionRecord {
    var archiveModel: ArchiveSession {
        ArchiveSession(
            id: id,
            kind: kind.rawValue,
            title: title,
            state: state.rawValue,
            createdAt: createdAt.timeIntervalSince1970,
            startedAt: startedAt.timeIntervalSince1970,
            endedAt: endedAt?.timeIntervalSince1970,
            engineProfile: engineProfile,
            audioSource: audioSource.rawValue,
            diarization: diarization.rawValue,
            diarizationNote: diarizationNote,
            llmEndpoint: llmEndpoint,
            llmModel: llmModel,
            personaID: persona?.id,
            personaTitle: persona?.title,
            voiceID: voice?.id,
            voiceName: voice?.name,
            endReason: endReason?.rawValue
        )
    }
}

extension TranscriptLine {
    var archiveModel: ArchiveLine {
        ArchiveLine(
            id: id,
            sessionID: sessionID,
            ordinal: ordinal,
            role: role.rawValue,
            speakerLabel: speakerLabel,
            text: text,
            tStart: tStart,
            tEnd: tEnd,
            source: source.rawValue,
            status: status.rawValue,
            interrupted: isInterrupted,
            deviceSwitch: isDeviceSwitch,
            starred: isStarred,
            timingQuality: timingQuality?.rawValue,
            createdAt: createdAt.timeIntervalSince1970
        )
    }
}

extension MeetingSourceSnapshot {
    var archiveModel: ArchiveSnapshot {
        ArchiveSnapshot(
            id: id,
            documentID: documentID,
            lineRevisionIDs: lineRevisionIDs,
            speakerMapRevision: speakerMapRevision,
            noteRefs: noteRefs,
            coverage: coverage,
            sealResult: sealResult,
            createdAt: createdAt.timeIntervalSince1970
        )
    }
}

extension TranscriptRevision {
    var archiveModel: ArchiveRevision {
        ArchiveRevision(
            id: id,
            lineID: lineID,
            sessionID: sessionID,
            text: text,
            origin: origin,
            parentRevisionID: parentRevisionID,
            editedAt: editedAt.timeIntervalSince1970
        )
    }
}

extension MinutesVersion {
    /// 租约是"谁正在跑这一版"的本机状态，不是内容身份：包带走它没有意义，
    /// 导入到新库还会让新库以为有个幽灵任务在跑。所以导出时清空。
    var archiveModel: ArchiveMinutes {
        ArchiveMinutes(
            id: id,
            sessionID: sessionID,
            version: version,
            status: status.rawValue,
            body: body,
            model: model,
            promptChars: promptChars,
            isLatest: isLatest,
            isAccepted: isAccepted,
            attempts: attempts,
            failureReason: failureReason,
            leaseUntil: nil,
            createdAt: createdAt.timeIntervalSince1970,
            isLegacyImport: isLegacyImport,
            remoteResponseID: remoteResponseID,
            configSnapshot: configSnapshot,
            snapshotID: snapshotID,
            cancelRequestedAt: cancelRequestedAt?.timeIntervalSince1970,
            candidateJSON: candidateJSON,
            reviewJSON: reviewJSON,
            coverageJSON: coverageJSON
        )
    }
}

extension MinutesItem {
    var archiveModel: ArchiveItem {
        ArchiveItem(
            id: id,
            minutesID: minutesID,
            localID: localID,
            kind: kind,
            text: text,
            verdict: verdict?.rawValue,
            sortOrder: sortOrder,
            anchors: anchors.map { anchor in
                ArchiveAnchor(
                    id: anchor.id,
                    itemID: anchor.itemID,
                    unitID: anchor.unitID,
                    lineID: anchor.lineID,
                    revisionID: anchor.revisionID,
                    snapshotID: anchor.snapshotID,
                    speakerLabel: anchor.speakerLabel,
                    startSeconds: anchor.startSeconds,
                    quote: anchor.quote,
                    verification: anchor.verification
                )
            }
        )
    }
}

extension MinutesWindowRecord {
    /// 窗口行本身不记自己属于哪一版（那在查询条件里），父 id 由调用方按
    /// 查它时用的那个版本填进来——猜错的话包里的分窗就会指到别的版本上。
    func archiveModel(minutesID: String) -> ArchiveWindow {
        ArchiveWindow(
            id: id,
            minutesID: minutesID,
            index: index,
            ownedUnitIDs: ownedUnitIDs,
            contextUnitIDs: contextUnitIDs,
            outcome: outcome.rawValue,
            failureReason: failureReason,
            candidateJSON: candidateJSON,
            remoteResponseID: remoteResponseID,
            updatedAt: updatedAt.timeIntervalSince1970
        )
    }
}

// MARK: - 知识范围与删除（MA-18 / MC-43、MC-44、MC-62、MC-72）

/// 一次检索、导出或问答**能看到哪些内容**（MA-18）。
///
/// 默认值是"最窄的那一档"：不限项目，但**不含已归档的文档**。
/// 归档之后用户还要能找回，所以数据留着；可它不能再出现在搜索结果、
/// 分享包和跨会议问答里——「找不回」和「还在被引用」必须是一回事。
public struct MeetingKnowledgeScope: Hashable, Sendable {
    /// 只看这一个项目；nil = 不按项目限制。
    public var projectID: String?
    /// 显式点名可见的文档。非空时**只认这些**，项目过滤不再生效。
    public var documentIDs: Set<String>
    /// 是否包含已归档的文档。默认否。
    public var includesArchived: Bool

    public init(
        projectID: String? = nil,
        documentIDs: Set<String> = [],
        includesArchived: Bool = false
    ) {
        self.projectID = projectID
        self.documentIDs = documentIDs
        self.includesArchived = includesArchived
    }

    /// 默认范围：全库可见内容，不含归档。
    public static let standard = MeetingKnowledgeScope()
}

/// 删除的三个档位。**它们不是强度不同的同一个动作**，恢复能力完全不同，
/// 所以连回退文案都不一样（MA-18）。
public enum MeetingDeletionMode: String, Codable, Hashable, Sendable {
    /// 只归档：立刻不可检索、不可导出，数据一行不少。**可以撤销**。
    case archive
    /// 只移除完整转录：原句与行修订删掉，纪要与结论留下（锚点变成"来源已不可读"）。
    case removeTranscript = "remove_transcript"
    /// 完整删除：正文、纪要、条目、锚点、快照全清。**不假装可撤销**。
    case deleteEverything = "delete_everything"

    public var title: String {
        switch self {
        case .archive: "归档（可恢复）"
        case .removeTranscript: "只移除完整转录"
        case .deleteEverything: "完整删除（不可撤销）"
        }
    }

    /// 只有归档能撤销。另两档的用户文案里不许出现"撤销"两个字。
    public var isRecoverable: Bool { self == .archive }
}

/// 删除报告。**外部副本边界必须说在报告里**（MC-72）：本机删干净了，
/// 用户自己导出的包、离线备份、已经发出去的文件都不在这件事的管辖范围内，
/// 不说清楚就等于让用户以为删干净了。
public struct MeetingDeletionReport: Hashable, Sendable {
    public var documentID: String
    public var mode: MeetingDeletionMode
    public var removedLines: Int
    public var removedRevisions: Int
    public var removedSnapshots: Int
    public var removedMinutes: Int
    public var removedItems: Int
    public var removedAnchors: Int
    /// 本机已清理的派生索引条数。
    public var purgedIndexEntries: Int

    public init(
        documentID: String,
        mode: MeetingDeletionMode,
        removedLines: Int = 0,
        removedRevisions: Int = 0,
        removedSnapshots: Int = 0,
        removedMinutes: Int = 0,
        removedItems: Int = 0,
        removedAnchors: Int = 0,
        purgedIndexEntries: Int = 0
    ) {
        self.documentID = documentID
        self.mode = mode
        self.removedLines = removedLines
        self.removedRevisions = removedRevisions
        self.removedSnapshots = removedSnapshots
        self.removedMinutes = removedMinutes
        self.removedItems = removedItems
        self.removedAnchors = removedAnchors
        self.purgedIndexEntries = purgedIndexEntries
    }

    /// 界面上必须原样念给用户听的一段话。它说谎的代价是用户以为删干净了。
    public var externalCopyWarning: String {
        switch mode {
        case .archive:
            return "归档只是把它从搜索、分享和问答里收起来，内容还在本机，随时可以撤销。"
        case .removeTranscript:
            return "完整转录已从本机删除，纪要与结论保留。已经导出的归档包和离线备份里仍有原句，那些不在本次删除范围内。"
        case .deleteEverything:
            return "本机相关的正文、纪要、条目与来源已全部删除，且无法撤销。你此前导出的归档包、离线备份以及已经分享出去的文件仍在别处，需要你自己处理。"
        }
    }
}

/// 用户明确选中的「AI 补充」（MC-43）。
///
/// 它**不是会议事实**：说话人、措辞、语气都来自模型，读起来像会议里说过的话，
/// 实际是模型对用户选中那一句的归纳。所以单独一个类型，不混进转录行，
/// 也不许被当成"会上有人这么说"。
public struct MeetingSupplement: Identifiable, Hashable, Sendable {
    public var id: String
    public var exchangeID: String
    public var question: String
    public var answerText: String
    public var includedAt: Date

    public init(
        id: String,
        exchangeID: String,
        question: String,
        answerText: String,
        includedAt: Date = Date()
    ) {
        self.id = id
        self.exchangeID = exchangeID
        self.question = question
        self.answerText = answerText
        self.includedAt = includedAt
    }
}

// MARK: - 跨会议证据问答（MA-17 / MC-56～MC-64）
//
// 这一层只做**取证据与接地**：把授权范围内的事实、状态与来源摆出来，
// 并判定一份答案能不能被这些证据支撑。它不调用模型、不联网、不执行任何动作——
// 措辞是调用方（App 侧 `LLMProvider`）的事。把这两件事混在一起，
// "模型说了什么"和"库里有什么"就再也分不开了。

/// 问题分类。不同的问题要用不同取数方式：**列表问题必须翻页取全**，
/// 拿 top-k 当全量就是漏答；点问题才轮到检索归纳（MC-57）。
public enum KnowledgeQuestionKind: String, Hashable, Sendable {
    /// "上季度都决定了什么"——要穷举，不许只给前几条。
    case list
    /// "预算到底是多少"——要围绕一个点归纳。
    case point
    /// "下次会前准备稿"——要保留未决与证据，不自动发送、不建日程。
    case preparation

    public var title: String {
        switch self {
        case .list: "清单问题"
        case .point: "单点问题"
        case .preparation: "会前准备"
        }
    }
}

/// 问题分类器。**规则写在代码里而不是交给模型**：分类错了会静默漏数据，
/// 那比分类得粗糙严重得多。
public enum KnowledgeQuestionClassifier {
    public static func classify(_ question: String) -> KnowledgeQuestionKind {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if preparationKeywords.contains(where: { text.contains($0) }) { return .preparation }
        if listKeywords.contains(where: { text.contains($0) }) { return .list }
        return .point
    }

    private static let preparationKeywords = ["准备稿", "准备一下", "下次会议", "下次会", "会前", "预备"]
    /// 清单类问法。看到这些词就必须翻页取全，不能只回最相关的几条。
    private static let listKeywords = [
        "都决定", "都做了", "有哪些", "列出", "清单", "所有", "分别", "汇总", "一共",
        "哪些", "几次", "多少个"
    ]
}

/// 一条结论的三个状态轴。**不是一个枚举**：一条历史版本里的待复核结论，
/// 它同时是"历史"和"待核对"，压成单值就必然丢掉一半信息。
public struct KnowledgeItemStatus: Hashable, Sendable {
    /// 是否来自这一场当前采用版（没有采用版时为最新可用版）。
    public var isCurrent: Bool
    /// 同一件事在会上既被定了又被撤回。**这不是错误，是事实**：
    /// 两个事件都保留，标出来让用户自己判断（§6.3）。
    public var isDisputed: Bool
    /// 证据核对没通过，或还没跑过核对。
    public var needsReview: Bool

    public init(isCurrent: Bool = false, isDisputed: Bool = false, needsReview: Bool = false) {
        self.isCurrent = isCurrent
        self.isDisputed = isDisputed
        self.needsReview = needsReview
    }

    /// 给界面用的一行话。三轴都报，不合并成一个含糊的"已确认"。
    public var summary: String {
        var parts: [String] = []
        parts.append(isCurrent ? "当前版本" : "历史版本")
        if isDisputed { parts.append("存在分歧") }
        if needsReview { parts.append("待核对") }
        return parts.joined(separator: " · ")
    }
}

/// 一条可引用的证据。它是"结论 + 它依据的原句 + 它的状态"三件套——
/// 只给结论不给来源，就和模型自己编的一句话没有区别了。
public struct KnowledgeEvidence: Identifiable, Hashable, Sendable {
    public var id: String
    public var documentID: String
    public var sessionID: String
    public var minutesID: String
    public var version: Int
    /// `decision` / `action` / `open_question` / `overview`
    public var kind: String
    public var text: String
    public var status: KnowledgeItemStatus
    public var anchors: [MinutesEvidenceAnchor]
    /// 会议发生时间。**没有就空着**，不拿纪要生成时间冒充。
    public var occurredAt: Date?

    public init(
        id: String,
        documentID: String,
        sessionID: String,
        minutesID: String,
        version: Int,
        kind: String,
        text: String,
        status: KnowledgeItemStatus,
        anchors: [MinutesEvidenceAnchor],
        occurredAt: Date?
    ) {
        self.id = id
        self.documentID = documentID
        self.sessionID = sessionID
        self.minutesID = minutesID
        self.version = version
        self.kind = kind
        self.text = text
        self.status = status
        self.anchors = anchors
        self.occurredAt = occurredAt
    }

    /// 还能不能当"已确认的事实"引用。历史版本、分歧、待核对都不算。
    public var isEstablishedFact: Bool {
        status.isCurrent && !status.isDisputed && !status.needsReview
    }

    /// 给模型看的证据块。**逐条编号、原句成块**：模型看到的是一个可引用的清单，
    /// 而不是一段需要它自己分辨哪句是资料的话。
    public func citationBlock() -> String {
        // 结论正文必须在块里。只给 id、类型和出处，模型看到的是一堆没有内容的
        // 标签——它要回答就得自己编，而那正是我们要防的事。
        var lines = ["[\(id)] \(kind)｜第 \(version) 版｜\(status.summary)｜\(text)"]
        for anchor in anchors {
            guard let quote = anchor.quote, !quote.isEmpty else { continue }
            let time = anchor.startSeconds.map { "（\(SessionExporter.clock($0))）" } ?? ""
            lines.append("  依据：\(quote)\(time)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 一次检索的结论。**总数与是否还有更多必须带出来**：只回 20 条却不告诉用户
/// 还有 40 条，和"只有 20 条"在用户眼里没有区别。
public struct KnowledgeRetrieval: Sendable {
    public var question: String
    public var kind: KnowledgeQuestionKind
    public var evidence: [KnowledgeEvidence]
    /// 授权范围内的命中总数（不受分页限制）。
    public var totalMatched: Int
    /// 本页之前已经跳过多少条。**翻页是否到底要看它**：
    /// 只拿本页条数比总数，翻到最后一页永远小于总数，调用方会一直翻下去。
    public var offset: Int
    /// 固定检索快照的 id。同一次问答的多次取数应当落在同一份事实上。
    public var snapshotID: String?

    public init(
        question: String,
        kind: KnowledgeQuestionKind,
        evidence: [KnowledgeEvidence],
        totalMatched: Int,
        offset: Int = 0,
        snapshotID: String?
    ) {
        self.question = question
        self.kind = kind
        self.evidence = evidence
        self.totalMatched = totalMatched
        self.offset = offset
        self.snapshotID = snapshotID
    }

    /// 后面还有没有。空页也算"还有"——那说明 offset 越过了总数，调用方应当停。
    public var hasMore: Bool { offset + evidence.count < totalMatched }
    public var isEmpty: Bool { evidence.isEmpty }

    /// 能当"已确认事实"用的证据。拒答判定看的是这个，不是 `evidence`。
    public var establishedFacts: [KnowledgeEvidence] { evidence.filter(\.isEstablishedFact) }
}

/// 拒答。**每种原因给用户看的话不一样**：没找到材料和找到了但都还没核对，
/// 下一步做的事完全不同。
public enum KnowledgeRefusalReason: String, Hashable, Sendable {
    /// 授权范围内根本没有相关记录。
    case noEvidence
    /// 找到了，但全部是历史版本、分歧或待核对——没有能当事实用的。
    case nothingVerified
    /// 问题落在授权范围之外。
    case outOfScope

    public var message: String {
        switch self {
        case .noEvidence:
            "在你授权的范围内没有找到相关记录。没有记录不等于没发生过，这里不做推断。"
        case .nothingVerified:
            "找到了相关记录，但都还是历史版本、存在分歧或待核对，不能当作已确认的事实。需要先核对。"
        case .outOfScope:
            "这个问题涉及你还没有授权我查看的内容。请先调整可见范围。"
        }
    }
}

/// 答案里的一段。**每一段都必须挂证据**：挂不上的段落要么被丢掉，要么整份答案作废。
public struct KnowledgeAnswerSegment: Hashable, Sendable {
    public var text: String
    public var evidenceIDs: [String]
    /// 这一段涉及的结论状态，让读者知道哪些是事实、哪些还在核对。
    public var status: KnowledgeItemStatus

    public init(text: String, evidenceIDs: [String], status: KnowledgeItemStatus) {
        self.text = text
        self.evidenceIDs = evidenceIDs
        self.status = status
    }
}

/// 接地后的答案。**未经接地的话不算答案**，只是一个待验证的字符串。
public struct KnowledgeAnswerDraft: Sendable {
    public var segments: [KnowledgeAnswerSegment]
    public var refusal: KnowledgeRefusalReason?
    /// 引用了检索结果里没有的证据的段落数。正常应当是 0。
    public var danglingCitations: Int

    public init(segments: [KnowledgeAnswerSegment], refusal: KnowledgeRefusalReason?, danglingCitations: Int) {
        self.segments = segments
        self.refusal = refusal
        self.danglingCitations = danglingCitations
    }

    public var isRefused: Bool { refusal != nil }
    /// 每一段都挂着检索结果里真实存在的证据。
    public var isGrounded: Bool { !isRefused && danglingCitations == 0 && !segments.isEmpty }
}

public enum KnowledgeGrounding {
    /// 把一段候选答案按证据接地。
    ///
    /// 三道检查，缺一不可：
    /// 1. 检索结果里没有可用事实 → 拒答，不给"看起来像答案"的东西（MC-56、MC-60）；
    /// 2. 段落引用了检索结果之外的证据 → 整段丢掉并计数（MC-63）；
    /// 3. 剩下的段落必须都还挂着**当前**有效证据——来源被删/归档之后，
    ///    迟到的答案不能继续显示已经不存在的内容（MC-63、MC-72）。
    public static func ground(
        segments: [KnowledgeAnswerSegment],
        retrieval: KnowledgeRetrieval,
        liveEvidenceIDs: Set<String>? = nil
    ) -> KnowledgeAnswerDraft {
        if retrieval.isEmpty {
            return KnowledgeAnswerDraft(segments: [], refusal: .noEvidence, danglingCitations: 0)
        }
        let available = liveEvidenceIDs ?? Set(retrieval.evidence.map(\.id))
        let live = Set(retrieval.evidence.filter { available.contains($0.id) }.map(\.id))
        if live.isEmpty {
            return KnowledgeAnswerDraft(segments: [], refusal: .noEvidence, danglingCitations: 0)
        }
        var kept: [KnowledgeAnswerSegment] = []
        var dangling = 0
        for segment in segments {
            let cited = segment.evidenceIDs.filter { live.contains($0) }
            guard !cited.isEmpty else {
                dangling += 1
                continue
            }
            kept.append(KnowledgeAnswerSegment(
                text: segment.text,
                evidenceIDs: cited,
                status: segment.status
            ))
        }
        guard !kept.isEmpty else {
            return KnowledgeAnswerDraft(segments: [], refusal: .nothingVerified, danglingCitations: dangling)
        }
        // 引得到证据、但没有一条能当已确认事实用时，不给"这就是结论"的口气。
        // 找到了材料和"能用"是两件事，混起来就会把待核对的说法讲成定论。
        let liveEstablished = retrieval.evidence.filter { live.contains($0.id) && $0.isEstablishedFact }
        if liveEstablished.isEmpty {
            return KnowledgeAnswerDraft(segments: [], refusal: .nothingVerified, danglingCitations: dangling)
        }
        return KnowledgeAnswerDraft(segments: kept, refusal: nil, danglingCitations: dangling)
    }
}

/// 下次会议准备稿（MA-17）。**纯数据**：它没有"发送"也没有"建日程"的能力，
/// 生成它不等于做了什么。准备稿里的每一条都必须带回它的证据。
public struct MeetingPrepDraft: Sendable {
    public var generatedAt: Date
    /// 仍未解决的问题，带出处。
    public var openQuestions: [KnowledgeEvidence]
    /// 还没完成的动作，带出处。
    public var pendingActions: [KnowledgeEvidence]
    /// 需要复核的结论，**放在最前面**：拿未核对的结论去做准备，
    /// 等于把不确定性带进下一场会。
    public var needsReview: [KnowledgeEvidence]

    public init(
        generatedAt: Date = Date(),
        openQuestions: [KnowledgeEvidence],
        pendingActions: [KnowledgeEvidence],
        needsReview: [KnowledgeEvidence]
    ) {
        self.generatedAt = generatedAt
        self.openQuestions = openQuestions
        self.pendingActions = pendingActions
        self.needsReview = needsReview
    }

    public var isEmpty: Bool {
        openQuestions.isEmpty && pendingActions.isEmpty && needsReview.isEmpty
    }

    /// 渲染成给用户看/给模型看的纯文本。**不会**被自动发出去。
    public func markdown() -> String {
        var rows: [String] = ["# 下次会议准备稿", ""]
        if !needsReview.isEmpty {
            rows.append("## 先核对（这几条还不能当结论用）")
            rows.append("")
            rows.append(contentsOf: needsReview.map { "- \($0.text)（\($0.status.summary)）" })
            rows.append("")
        }
        if !openQuestions.isEmpty {
            rows.append("## 上次没答完")
            rows.append("")
            rows.append(contentsOf: openQuestions.map { "- \($0.text)（\($0.status.summary)）" })
            rows.append("")
        }
        if !pendingActions.isEmpty {
            rows.append("## 待办")
            rows.append("")
            rows.append(contentsOf: pendingActions.map { "- \($0.text)（\($0.status.summary)）" })
            rows.append("")
        }
        if isEmpty {
            rows.append("授权范围内没有待跟进的内容。")
            rows.append("")
        }
        rows.append("---")
        rows.append("")
        rows.append("这份准备稿只是把你已授权范围内的未决与待办列出来，不会自动发送，也不会创建日程。")
        return rows.joined(separator: "\n")
    }
}

// MARK: - 结构化知识投影（MA-13 / MC-51、MC-52、MC-56）

/// 严格程度。**默认档包含待核对内容**（MC-52）：只有待核对候选的那场会
/// 不能从库里消失，那会让用户以为内容丢了。严格档是"只看已确认"的显式选择。
public enum KnowledgeVerificationFilter: String, Hashable, Sendable {
    case includeUnverified
    case strictlyVerified

    public var title: String {
        switch self {
        case .includeUnverified: "含待核对"
        case .strictlyVerified: "只看已确认"
        }
    }
}

/// 事项筛选条件。所有条件**同时生效**（AND），不做"命中一个就算"。
public struct KnowledgeItemFilter: Hashable, Sendable {
    /// 按**稳定项目 id** 过滤，不按名字（MC-51）。
    public var projectIDs: Set<String>
    public var documentIDs: Set<String>
    public var tags: Set<String>
    public var kinds: Set<String>
    public var verification: KnowledgeVerificationFilter

    public init(
        projectIDs: Set<String> = [],
        documentIDs: Set<String> = [],
        tags: Set<String> = [],
        kinds: Set<String> = ["decision", "action", "open_question", "overview"],
        verification: KnowledgeVerificationFilter = .includeUnverified
    ) {
        self.projectIDs = projectIDs
        self.documentIDs = documentIDs
        self.tags = tags
        self.kinds = kinds
        self.verification = verification
    }

    public static let all = KnowledgeItemFilter()
}

/// 筛选后的计数。**必须与同一批列表出自同一个谓词**——分开算就会出现
/// "显示 12 条、列出 9 条"，用户没法判断该信哪个。
public struct KnowledgeItemCounts: Hashable, Sendable {
    public var total: Int
    public var byKind: [String: Int]
    public var needsReview: Int
    public var disputed: Int

    public init(total: Int = 0, byKind: [String: Int] = [:], needsReview: Int = 0, disputed: Int = 0) {
        self.total = total
        self.byKind = byKind
        self.needsReview = needsReview
        self.disputed = disputed
    }

    public static let zero = KnowledgeItemCounts()
}

/// 一页结构化事项。分页信息齐全，翻页不重复不遗漏（MC-49、MC-56）。
public struct KnowledgeItemPage: Sendable {
    public var items: [KnowledgeEvidence]
    public var counts: KnowledgeItemCounts
    public var offset: Int
    public var limit: Int

    public init(items: [KnowledgeEvidence], counts: KnowledgeItemCounts, offset: Int, limit: Int) {
        self.items = items
        self.counts = counts
        self.offset = offset
        self.limit = limit
    }

    public var hasMore: Bool { offset + items.count < counts.total }
}

/// 项目（MA-13 / MC-51）。
///
/// **身份是 id，不是名字**：两个项目可以同名——一个是 2024 年的「发布」，
/// 一个是 2025 年的「发布」。按名字归一，用户看到的计数就会把两场不相干的会混成一份。
public struct MeetingProject: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
