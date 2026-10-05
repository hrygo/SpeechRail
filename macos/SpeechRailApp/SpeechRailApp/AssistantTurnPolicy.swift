import Foundation

/// VA-13 输入证据、自然接话与设备策略：纯策略。
///
/// 必交规则：空/纯空白 snapshot 不触发 cancel；revision 去重；
/// final-only 经统一接管；多 item 不误占 partial 槽。
/// 聚合/duck 维持关闭（deferred_evidence），只交安全规则。
enum AssistantTurnPolicy {
    /// 输入证据归属键：同一连接内同一 item 的同一 revision 只认一次。
    struct EvidenceKey: Hashable, Sendable {
        var connection: Int
        var itemID: String
        var revision: Int
    }

    /// partial snapshot 是否构成插话证据。
    /// 空/纯空白不触发 cancel；重复 revision 不重复触发。
    static func isBargeInEvidence(
        text: String,
        revision: Int,
        seenRevisions: Set<Int>,
        allowsBargeIn: Bool,
        isSpeakingOrGenerating: Bool
    ) -> Bool {
        guard allowsBargeIn, isSpeakingOrGenerating else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !seenRevisions.contains(revision) else { return false }
        return true
    }

    /// 生产 receiver 用的统一证据门：空/纯空白 delta 与 snapshot 无副作用；
    /// 同一 `(connection, itemID, revision)` 只触发一次；跨 item 的同 revision 独立。
    /// 调用方传入当前连接代次与已见证据集合；命中时返回更新后的集合。
    static func bargeInEvidence(
        text: String,
        connection: Int,
        itemID: String,
        revision: Int,
        seenEvidence: Set<EvidenceKey>,
        allowsBargeIn: Bool,
        isSpeakingOrGenerating: Bool
    ) -> (fires: Bool, seenEvidence: Set<EvidenceKey>) {
        guard !itemID.isEmpty else { return (false, seenEvidence) }
        guard allowsBargeIn, isSpeakingOrGenerating else { return (false, seenEvidence) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, seenEvidence)
        }
        let key = EvidenceKey(connection: connection, itemID: itemID, revision: revision)
        guard !seenEvidence.contains(key) else { return (false, seenEvidence) }
        var next = seenEvidence
        next.insert(key)
        return (true, next)
    }

    /// 相邻 final 聚合开关：无真机基线时维持关闭。
    static var aggregationEnabled: Bool { false }
    static var aggregationState: String { "deferred_evidence" }
}
