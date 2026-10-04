import Foundation

/// VA-13 输入证据、自然接话与设备策略：纯策略。
///
/// 必交规则：空/纯空白 snapshot 不触发 cancel；revision 去重；
/// final-only 经统一接管；多 item 不误占 partial 槽。
/// 聚合/duck 维持关闭（deferred_evidence），只交安全规则。
enum AssistantTurnPolicy {
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

    /// 相邻 final 聚合开关：无真机基线时维持关闭。
    static var aggregationEnabled: Bool { false }
    static var aggregationState: String { "deferred_evidence" }
}
