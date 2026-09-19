import Foundation
import Observation

// 纪要生成（`SESSIONS-SPEC` §6.2 / §16.8，`TECHNICAL-DESIGN` §5.8）。
//
// 四条口径，逐条都有来源：
//
//   1. **排队、单飞、租约回收**。转录封存之后才写 `queued`；认领带租约，
//      过期租约可以被下一次启动回收——否则 App 崩一次，那一版纪要就永远卡在 `running`。
//   2. **长任务用 Responses 的 background 模式 + 轮询**。纪要要跑几十秒到几分钟，
//      不该把界面挂在一条请求上。
//   3. **重新生成只新增版本**。`version = n+1`、`is_latest` 指向最新，旧版仍可看可导出。
//   4. **失败给可读原因，不动转录**。`纪要没整理出来 · 转录已经存好了`。
//
// 隐私口径（§5.8 的显式要求，界面必须照说）：默认 `store=false`，但**后台模式下即使
// `store=false`，响应数据仍会在服务端临时落盘约 10 分钟**以支持异步执行与轮询。
// 所以这里**不许**出现"内容没经过服务器"这类说法。

/// 结构化纪要的字段（`json_schema` + `strict`）。App 负责把它渲染成 Markdown，
/// 于是"结构不合法"与"内容不好"是两件可以分开处理的事。
public struct MinutesDocument: Codable, Hashable, Sendable {
    public struct Topic: Codable, Hashable, Sendable {
        public var title: String
        public var points: [String]
    }

    public struct Action: Codable, Hashable, Sendable {
        public var owner: String
        public var task: String
        public var due: String
    }

    public var title: String
    public var summary: String
    public var topics: [Topic]
    public var decisions: [String]
    public var actions: [Action]
    public var openQuestions: [String]
    public var confidenceNotes: String

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case topics
        case decisions
        case actions
        case openQuestions = "open_questions"
        case confidenceNotes = "confidence_notes"
    }

    /// 渲染成 Markdown。库里存的就是这一段（界面直接显示，导出也用它）。
    public var markdown: String {
        var out = "# \(title.isEmpty ? "会议纪要" : title)\n\n"
        if !summary.isEmpty { out += "\(summary)\n\n" }
        for topic in topics where !topic.title.isEmpty || !topic.points.isEmpty {
            out += "## \(topic.title)\n\n"
            for point in topic.points { out += "- \(point)\n" }
            out += "\n"
        }
        if !decisions.isEmpty {
            out += "## 决定\n\n"
            for decision in decisions { out += "- \(decision)\n" }
            out += "\n"
        }
        if !actions.isEmpty {
            out += "## 待办\n\n"
            for action in actions {
                let owner = action.owner.isEmpty ? "" : "\(action.owner)："
                let due = action.due.isEmpty ? "" : "（\(action.due)）"
                out += "- \(owner)\(action.task)\(due)\n"
            }
            out += "\n"
        }
        if !openQuestions.isEmpty {
            out += "## 还没有结论的问题\n\n"
            for question in openQuestions { out += "- \(question)\n" }
            out += "\n"
        }
        if !confidenceNotes.isEmpty { out += "> \(confidenceNotes)\n" }
        return out
    }

    /// 结构化输出的 schema（`strict` 要求所有字段都在 `required` 里、且 `additionalProperties: false`）。
    static var jsonSchema: [String: Any] {
        [
            "type": "json_schema",
            "name": "meeting_minutes",
            "strict": true,
            "schema": [
                "type": "object",
                "additionalProperties": false,
                "required": [
                    "title", "summary", "topics", "decisions", "actions", "open_questions",
                    "confidence_notes"
                ],
                "properties": [
                    "title": ["type": "string"],
                    "summary": ["type": "string"],
                    "topics": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["title", "points"],
                            "properties": [
                                "title": ["type": "string"],
                                "points": ["type": "array", "items": ["type": "string"]]
                            ]
                        ]
                    ],
                    "decisions": ["type": "array", "items": ["type": "string"]],
                    "actions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["owner", "task", "due"],
                            "properties": [
                                "owner": ["type": "string"],
                                "task": ["type": "string"],
                                "due": ["type": "string"]
                            ]
                        ]
                    ],
                    "open_questions": ["type": "array", "items": ["type": "string"]],
                    "confidence_notes": ["type": "string"]
                ]
            ]
        ]
    }
}

@MainActor
@Observable
public final class MinutesGenerator {
    public enum State: Equatable, Sendable {
        case idle
        case queued
        case running
        case ready
        case failed(String)

        public var title: String {
            switch self {
            case .idle: "还没有纪要"
            case .queued: "正在排队整理…"
            case .running: "正在整理会议…"
            case .ready: "纪要在下面"
            case .failed: "纪要没整理出来 · 转录已经存好了"
            }
        }
    }

    public private(set) var state: State = .idle
    public private(set) var versions: [MinutesVersion] = []
    public private(set) var latestBody: String?
    /// 最近一次整理用的服务端响应 id（诊断用；它不是用户内容）。
    public private(set) var lastResponseID: String?
    /// 这一次失败是不是**配置问题**（没填模型 / 地址不对 / 端点没有 Responses API）。
    /// 由它决定失败条给哪个出口：配置问题给「去设置里填对话模型」，其它给「重新生成」——
    /// 配置没填时按「重新生成」只会原样再失败一次，是个死循环（用户 2026-09-19：
    /// 一次性设置要在最需要它的那一刻给）。
    private var failedOnSetup = false

    /// 这一次失败本身**是不是配置引起的**（生成器管不到配置，只如实报自己看到的）。
    /// 界面要不要给「去设置里填」，由 `MeetingSession.minutesNeedsSetup` 合并"当前配置
    /// 仍然空着"之后再判——重启后 `reload` 只读得回失败原因文本（库里没有 code 列）。
    public var failureNeedsSetup: Bool {
        guard case .failed = state else { return false }
        return failedOnSetup
    }

    private let coordinator: SessionCoordinator
    private let provider = LLMProvider()
    /// 一次只整理一份（§5.8「同会话单飞」）。
    private var inFlight: String?
    /// 在飞的那一次整理。`stop()` 取消的是它——界面上的「停止整理」要真的停下，
    /// 而不是只把按钮换掉（设计稿 `会议助手 · 会议页 · 整理中` 给出这个出口）。
    private var runTask: Task<Void, Never>?
    /// 租约时长。它比一次整理该花的时间长一点，短了会被下一个启动误回收。
    private static let lease: TimeInterval = 600

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    /// 转录封存之后调它：排队 → 认领 → 生成 → 落库（§8.2 的最后一步）。
    public func generate(sessionID: String, configuration: LLMConfiguration) async {
        guard inFlight == nil else { return }
        inFlight = sessionID
        defer { inFlight = nil }
        state = .queued
        failedOnSetup = false

        let version: MinutesVersion
        do {
            let lines = try await coordinator.lines(sessionID: sessionID)
            let names = (try? await coordinator.speakerNames(sessionID: sessionID)) ?? [:]
            let transcript = Self.render(lines: lines, names: names)
            guard !transcript.isEmpty else {
                state = .failed("这一场没有可整理的正文。")
                return
            }
            version = try await coordinator.enqueueMinutes(
                sessionID: sessionID,
                model: configuration.model.isEmpty ? nil : configuration.model,
                promptChars: transcript.count
            )
            versions = try await coordinator.minutesVersions(sessionID: sessionID)
            guard !configuration.isConfigured else {
                let task = Task { [weak self] in
                    _ = try? await self?.run(
                        version: version,
                        transcript: transcript,
                        configuration: configuration
                    )
                }
                runTask = task
                await task.value
                runTask = nil
                return
            }
            // 没配大模型：转录已经封存好了，这一版如实失败（§9 第 18 行）。
            try? await coordinator.failMinutes(
                minutesID: version.id,
                reason: "还没有配置对话模型（设置 → 会话）。转录已经存好，配好之后可以重新生成。"
            )
            failedOnSetup = true
            state = .failed("还没有配置对话模型。转录已经存好，配好之后可以重新生成。")
        } catch {
            state = .failed(error.localizedDescription)
        }
        versions = (try? await coordinator.minutesVersions(sessionID: sessionID)) ?? versions
    }

    /// 重开 App 之后回收过期租约：`running` 且租约过期的那些行可以被重新认领（§5.8）。
    public func recoverPending(configuration: LLMConfiguration) async {
        guard let sessionIDs = try? await coordinator.sessionsWithPendingMinutes() else { return }
        for sessionID in sessionIDs {
            await generate(sessionID: sessionID, configuration: configuration)
        }
    }

    /// 「停止整理」：取消在飞的那一次。**转录不受影响**——它早就封存好了，
    /// 所以这里只把这一版如实标成失败并写明原因，用户可以随时重新生成。
    public func stop() {
        runTask?.cancel()
    }

    /// 界面上要不要给「停止整理」这个出口。
    public var isBusy: Bool {
        switch state {
        case .queued, .running: true
        default: false
        }
    }

    /// 读库刷新（界面切换版本、重新打开这一场时调）。
    public func reload(sessionID: String) async {
        versions = (try? await coordinator.minutesVersions(sessionID: sessionID)) ?? []
        let latest = try? await coordinator.latestMinutes(sessionID: sessionID)
        latestBody = latest?.body
        switch latest?.status {
        case .ready: state = .ready
        case .running: state = .running
        case .queued: state = .queued
        case .failed: state = .failed(latest?.failureReason ?? "没有可读的原因")
        default: state = .idle
        }
    }

    private func run(
        version: MinutesVersion,
        transcript: String,
        configuration: LLMConfiguration
    ) async throws {
        let claimed = try await coordinator.claimMinutes(sessionID: version.sessionID, lease: Self.lease)
        guard let claimed else { return }
        state = .running
        let key = LLMKeychain.load()
        do {
            let responseID = try await provider.startBackground(
                configuration: configuration,
                messages: Self.prompt(transcript: transcript),
                apiKey: key,
                maxOutputTokens: 4_000,
                textFormat: MinutesDocument.jsonSchema
            )
            lastResponseID = responseID
            let text = try await provider.pollBackground(
                configuration: configuration,
                apiKey: key,
                responseID: responseID
            )
            let body = Self.markdown(from: text)
            try await coordinator.finishMinutes(
                minutesID: claimed.id,
                body: body,
                model: configuration.model.isEmpty ? nil : configuration.model
            )
            latestBody = body
            failedOnSetup = false
            state = .ready
        } catch {
            // 取消与失败要分开说：用户按的「停止整理」不该在记录里留下一条"整理失败"。
            let cancelled = Task.isCancelled || (error as? LLMError) == .cancelled
            let reason = cancelled
                ? "你停下了这一次整理。转录已经存好，可以重新生成。"
                : Self.readableReason(for: error)
            try? await coordinator.failMinutes(minutesID: claimed.id, reason: reason)
            // 地址写错、服务没有 Responses API 这类失败，按「重新生成」只会再撞一次；
            // 它们和「没填模型」是同一类下一步：去设置里改配置。
            if let llm = error as? LLMError {
                switch llm {
                case .notConfigured, .badBaseURL, .notResponsesAPI: failedOnSetup = true
                default: failedOnSetup = false
                }
            } else {
                failedOnSetup = false
            }
            state = .failed(reason)
        }
    }

    /// Prompt。两条硬要求：**只依据转录**、**不知道就写不知道**（与内心 OS 同一条规矩）。
    static func prompt(transcript: String) -> [LLMMessage] {
        [
            LLMMessage(
                role: .developer,
                text: "你负责把一段会议转录整理成结构化纪要。只依据转录里的内容，"
                    + "不要补你没看到的事；转录里没提到的决定、待办、负责人一律不要写。"
                    + "说话人用转录里已有的名字；同一个名字不要改写成别的称呼。"
                    + "待办的 due 没有依据时留空字符串。"
                    + "confidence_notes 写这份纪要里最不确定的一两处；如果没什么不确定的就留空。",
                cacheBreakpoint: true
            ),
            LLMMessage(role: .user, text: "下面是这一场的转录：\n\n\(transcript)")
        ]
    }

    /// 转录 → prompt 里的文本。**相对会话开始的秒**，与库里的时间码同源（§6.5）。
    static func render(lines: [TranscriptLine], names: [String: String] = [:]) -> String {
        lines.map { line in
            let speaker = line.speakerLabel.flatMap { names[$0] } ?? line.speakerLabel ?? "说话人"
            let start = line.tStart ?? 0
            return "[\(Self.timecode(start))] \(speaker)：\(line.text)"
        }.joined(separator: "\n")
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 结构化正文 → Markdown。模型没按 schema 回（端点不支持 `json_schema`）时，
    /// **不假装成功**：把纯文本原样收下，并说明"这一版没有按结构返回"。
    static func markdown(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let document = try? JSONDecoder().decode(MinutesDocument.self, from: data)
        else {
            return trimmed.isEmpty
                ? "这一版没有拿到内容。可以重新生成一次。"
                : trimmed + "\n\n> 这一版是以纯文本返回的（端点没有按结构返回）。\n"
        }
        return document.markdown
    }

    private static func readableReason(for error: Error) -> String {
        if let llm = error as? LLMError {
            switch llm {
            case .refused(let reason): return "大模型没有给结果：\(reason)"
            case .http(let status, _): return "大模型服务回了 \(status)。转录已经存好，可以重新生成。"
            case .notConfigured: return "还没有配置对话模型。"
            default: return llm.errorDescription ?? "整理没有完成。"
            }
        }
        return error.localizedDescription
    }
}
