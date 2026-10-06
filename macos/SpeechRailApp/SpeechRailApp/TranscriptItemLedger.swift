import Foundation

/// 转录的 item 级账本（方案 MA-02 / MC-09～MC-13）。
///
/// 这层是纯状态机，不碰设备也不碰网络，所以 MC-09～MC-13 能在
/// 无采集环境下确定性验证——这些恰恰是最容易在真实会议里静默出错的地方：
/// 同一句被存两遍、跨连接复用 id 被吞、新快照被旧快照倒写。
///
/// 三条规矩：
///
/// 1. **去重按 (代次, itemID)，不按 itemID。** 同场重连后新服务可能复用
///    item ID；按裸 ID 去重会把新连接的内容当重复吞掉（MC-13）。
/// 2. **partial 按槽分开，不跨 item 拼接。** A 和 B 交错输出 partial 时，
///    "当前显示的那一句"必须归属确定（MC-09）。
/// 3. **快照按 revision 替换，迟到的小 revision 不能倒写**（MC-10）。
public struct TranscriptItemLedger: Hashable, Sendable {
    /// 当前连接代次。去重集合随之换代。
    public private(set) var generation: Int = 0

    /// 本代已定稿的 item。去重**只在代内**有效。
    private var committedInGeneration: Set<String> = []
    /// 跨代仍然有效的去重键：同一代内已提交过的 `(代次, id)`。
    private var committed: Set<Key> = []

    /// 槽 → partial 文本与它到达时的 revision。
    private var partials: [String: Partial] = [:]
    /// 界面上"当前那句"显示哪个槽。**只有一个**，归属必须确定。
    private var visibleSlot: String?

    private struct Partial: Hashable, Sendable {
        var revision: Int
        var text: String
    }

    private struct Key: Hashable, Sendable {
        var generation: Int
        var itemID: String
    }

    public init() {}

    /// 新连接接管。清空去重与 partial——上一代的 item 与这一代无关。
    public mutating func beginGeneration(_ generation: Int) {
        self.generation = generation
        committedInGeneration = []
        partials = [:]
        visibleSlot = nil
    }

    // MARK: - 去重

    /// 这个 item 在**本代**是否已经定稿过。
    public func isCommitted(_ itemID: String) -> Bool {
        committedInGeneration.contains(itemID)
    }

    /// 提交一个 item。返回 `false` 表示本代重复，调用方**不得**再落一行。
    @discardableResult
    public mutating func markCommitted(_ itemID: String) -> Bool {
        // 空 itemID **不去重**：没有身份就没有"证明这是同一句"的可能，
        // 而把无法证明重复的内容丢掉是比多留一行严重得多的错。
        guard !itemID.isEmpty else { return true }
        guard !committedInGeneration.contains(itemID) else { return false }
        committedInGeneration.insert(itemID)
        committed.insert(Key(generation: generation, itemID: itemID))
        return true
    }

    /// 落库失败时回退去重名额，让重试还能再落一次。
    ///
    /// 没有这一步的话，一次写库失败就把这个 item 永久标成"已提交"，
    /// 后续重试会被当成重复吞掉——用户看到的是"这句没了"。
    public mutating func unmarkCommitted(_ itemID: String) {
        guard !itemID.isEmpty else { return }
        committedInGeneration.remove(itemID)
        committed.remove(Key(generation: generation, itemID: itemID))
    }

    // MARK: - partial

    /// 某个 item 在本代是否曾经定稿过（跨代查询，用于诊断）。
    public func wasCommittedInAnyGeneration(_ itemID: String) -> Bool {
        committed.contains { $0.itemID == itemID }
    }

    /// 增量 partial。**只进它自己的槽**，不与别的 item 拼接。
    public mutating func acceptDelta(slot: String, delta: String) {
        guard !delta.isEmpty else { return }
        partials[slot, default: Partial(revision: 0, text: "")].text += delta
        visibleSlot = slot
    }

    /// 快照替换。返回 `false` 表示这是一次**迟到的小 revision**，不许倒写。
    ///
    /// 相等 revision 也拒绝：服务端重复投递同一份快照没有信息量，
    /// 接受它只会让"已经显示的内容"在没有任何新事实的情况下再变一次。
    @discardableResult
    public mutating func acceptSnapshot(slot: String, revision: Int, text: String) -> Bool {
        if let existing = partials[slot], revision <= existing.revision {
            return false
        }
        partials[slot] = Partial(revision: revision, text: text)
        visibleSlot = text.isEmpty ? visibleSlot : slot
        if text.isEmpty {
            // 空快照不算"当前这句"，但也不抹掉槽里已有的内容。
            return true
        }
        return true
    }

    /// 界面上"当前那句"。**归属确定**：只有一个槽。
    public var visiblePartial: String? {
        guard let visibleSlot else { return nil }
        let text = partials[visibleSlot]?.text ?? ""
        return text.isEmpty ? nil : text
    }

    /// 定稿后清掉对应槽。空 itemID 表示"清掉当前显示的那句"。
    public mutating func clearPartial(slot: String? = nil) {
        guard let slot = slot ?? visibleSlot else {
            partials = [:]
            visibleSlot = nil
            return
        }
        partials[slot] = nil
        if visibleSlot == slot { visibleSlot = nil }
    }

    /// 空 final 的恢复材料（MC-11）。
    ///
    /// 服务端回了一个空 final：内容**不能无声消失**，但也**不能进正式纪要**。
    /// 所以这里既不提交也不丢弃，而是把它记成待恢复材料交给界面提示。
    public struct RecoveryNote: Hashable, Sendable {
        public var itemID: String
        public var text: String
    }

    /// 处理一次定稿。返回该落库的行，或 `.discarded` 说明为什么没有行。
    public enum CommitOutcome: Hashable, Sendable {
        /// 该落库。`recoveryNote` 非空表示正文为空、只留恢复材料。
        case commit(itemID: String, recoveryNote: RecoveryNote?)
        /// 本代重复，不落第二行（MC-12）。
        case duplicate
        /// 正文为空且没有可恢复内容：彻底丢弃。
        case discarded
    }

    public mutating func resolveCommit(itemID: String, transcript: String) -> CommitOutcome {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // 先取回这一句**已经显示过的 partial**：空 final 到达时它是唯一的内容，
        // 直接清掉就等于让用户刚看见的字无声消失（MC-11）。
        let shownPartial = visiblePartial
        clearPartial()
        guard !text.isEmpty else {
            if let shownPartial, !shownPartial.isEmpty {
                // 保留为未定稿恢复材料：不进正式纪要，但也不消失。
                return .commit(
                    itemID: itemID,
                    recoveryNote: RecoveryNote(itemID: itemID, text: shownPartial)
                )
            }
            return .discarded
        }
        guard markCommitted(itemID) else { return .duplicate }
        return .commit(itemID: itemID, recoveryNote: nil)
    }
}
