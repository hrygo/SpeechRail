import Foundation

/// 一轮助手回复的**唯一身份**（D08 / 方案 S4）。
///
/// 以前这轮回复没有自己的身份：正文生成完才插入一行，`Turn.id` 是临时 UUID，
/// 落库的 id 又是另一个 UUID。于是"这是哪一句"只能靠"数组最后一项"去猜——
/// 一旦生成路径和取消路径都去写"最后一行"，就可能更新到别的回复，
/// 或者同一轮插出两行。打断之后回看也认不出哪句被截断。
///
/// 现在一轮 = 一个 `AssistantReplyState`：
///
/// - `id` 同时是 SQLite 的 `line.id` 和界面 `Turn.id`，全程不变；
/// - 第一段非空正文就按这个 id 建行（`status = .partial`），之后只 UPDATE，不 INSERT；
/// - `isFinalized` 是幂等闸门：正常说完、用户打断、provider 失败、连接断开、
///   结束对话，全部经 `AssistantSession.finalizeReply(_:reply:)` 收尾，重复调用只生效一次。
///
/// 收尾与生成是分开的两件事：`isFinalized` 只表示"这一轮已经落库并归位"，
/// 播放是否放完由 TTS 协调器自己的 epoch 管——完整生成但没播完的回复，
/// 先按完整正文定稿，随后用户打断播放时再把同一行 `interrupted` 推向 true。
struct AssistantReplyState {
    /// 这一轮为什么结束。`.streaming` 只在生成途中存在。
    enum Termination: Equatable {
        case streaming
        case completed
        case interrupted
        case failed(String)

        /// 打断标记只从 false 推向 true：迟到的"正常完成"不能擦掉用户已经看到的打断。
        var marksInterrupted: Bool {
            switch self {
            case .interrupted, .failed: true
            case .streaming, .completed: false
            }
        }
    }

    /// 库里的行 id。建行之后不再改变。
    let id: String
    let sessionID: String
    /// `replyGeneration` 的取值。迟到的旧回复靠它认出自己已经过期。
    let generation: Int
    let source: SessionLineSource
    /// 这一句开始的时刻。它会作为 `LineDraft.createdAt` 落库。
    let startedAt: Date
    /// 正文（**原始** LLM 增量，未清洗）。
    var text: String
    /// 库里已经有这一行。第一段非空正文之后才有值。
    var isPersisted: Bool
    /// 落库后的序号。
    var ordinal: Int?
    /// 收尾闸门。`true` 之后任何再次收尾都是无操作。
    var isFinalized: Bool
    var termination: Termination

    init(
        id: String = "assistant_reply_\(UUID().uuidString.lowercased())",
        sessionID: String,
        generation: Int,
        source: SessionLineSource,
        startedAt: Date,
        text: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.generation = generation
        self.source = source
        self.startedAt = startedAt
        self.text = text
        self.isPersisted = false
        self.ordinal = nil
        self.isFinalized = false
        self.termination = .streaming
    }

    /// 是否已经到了"值得为这一轮建一行"的时候：累计文本里有非空白内容。
    /// 纯空白的一轮不建行，也不朗读。
    var hasSpeakableText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
