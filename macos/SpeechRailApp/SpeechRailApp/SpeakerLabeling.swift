import Foundation
import Observation

// 分人归属的账本。**会议与字幕共用这一个**（`SESSIONS-SPEC` §14.3：同一套会话内匿名标签、
// 同一处改名、同一套降级话术），所以它既不认识会议也不认识字幕，只认识"归属"这件事。
//
// 三条从契约与规格直接落下来的规矩：
//
//   1. **只改归属列，正文一个字不动**（§15.3 第 2 条）。服务端的归属是"原位修订"，
//      所以这里唯一的写库动作是 `attachSpeakerLabel` 与 `speaker_name`。
//   2. **`segment_uid` 是修订的坐标**：`completed` 带回来一批单元，后来的
//      `speechrail.diarization.updated` 按 uid 找行。所以"uid 落在哪一行"必须被记住，
//      否则修订事件无处可写——这张表在内存里，锚在这一次会话上。
//   3. **降级就停更、不擦除**（§14.3）：`diarization_overloaded` 之后标签停止更新，
//      已经给出的保留，并如实写进 `session.diarization_note`。
//
// 合并、标记为「我」都是**显示名层面的别名**，不是重建归属：两者都只写 `speaker_name`，
// `line.speaker_label` 一个字不动，所以"已并入 A"永远可回溯（§6.2.1 的保存口径）。

@MainActor
@Observable
public final class SpeakerLabeling {
    /// 分人的三种状态，对着库里 `session.diarization` 的取值域（§7.1）。
    public enum State: String, Sendable {
        case off
        case active
        case degraded
        case unavailable
    }

    /// 一位说话人在面板里的样子（§6.2.1 的"说话人行"）。
    public struct Speaker: Identifiable, Equatable, Sendable {
        public var label: String
        public var displayName: String?
        public var lineCount: Int
        public var firstOrdinal: Int?
        /// 服务端给的声学建议（"这两个标签可能是同一个人"）。**只是建议**，要不要合由用户按。
        public var suggestedMergeInto: String?
        /// 本场被并掉的标签集合（"已并入 A"的可回溯状态）。
        public var mergedLabels: Set<String>

        public var id: String { label }

        /// 面板上的状态胶囊：`已标注` / `待标注` / `已合并`。
        public var status: String {
            if mergedLabels.contains(label) { return "已合并" }
            return displayName == nil ? "待标注" : "已标注"
        }
    }

    /// 服务端固定上限（契约：最多四名匿名说话人）。
    public static let maxSpeakers = 4

    private let coordinator: SessionCoordinator

    public private(set) var sessionID: String?
    /// 本场出现过的匿名标签，按首次出现的顺序。
    public private(set) var labels: [String] = []
    public private(set) var displayNames: [String: String] = [:]
    public private(set) var lineCounts: [String: Int] = [:]
    public private(set) var firstOrdinal: [String: Int] = [:]
    public private(set) var suggestions: [RealtimeASRClient.SpeakerLink] = []
    public private(set) var state: State = .off
    /// 降级的可读原因（面板上原话显示，也是 `session.diarization_note` 的内容）。
    public private(set) var note: String?

    /// `segment_uid` → 库里的行 id。修订事件靠它找行。
    private var lineByUnit: [String: String] = [:]
    /// `segment_uid` → 已经写进库的那个标签（去重：同一个归属不重复写库）。
    private var appliedByUnit: [String: String] = [:]
    /// 本场被并掉的标签 → 目标标签（"已并入 A"）。
    private var mergedInto: [String: String] = [:]

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - 会话边界

    /// 新会话开始：账本归零（**不跨会话**——§14.3 的边界：不做跨会话身份）。
    public func begin(sessionID: String, enabled: Bool) {
        self.sessionID = sessionID
        labels = []
        displayNames = [:]
        lineCounts = [:]
        firstOrdinal = [:]
        suggestions = []
        lineByUnit = [:]
        appliedByUnit = [:]
        mergedInto = [:]
        note = nil
        state = enabled ? .active : .off
    }

    /// 打开一场历史记录：只读回已经落库的显示名与出现过的标签，
    /// 不重建 uid 表（那时候修订早结束了）。
    public func load(sessionID: String, labels: [String], displayNames: [String: String]) {
        self.sessionID = sessionID
        self.labels = labels
        self.displayNames = displayNames
    }

    public func end() {
        sessionID = nil
        lineByUnit = [:]
        appliedByUnit = [:]
    }

    public var isEnabled: Bool { state == .active || state == .degraded }

    // MARK: - 事件

    /// `completed` 带回来的单元：记下"uid 落在这一行"，并返回**当前**归属。
    ///
    /// 返回值要写进 `LineDraft.speakerLabel`——否则界面在修订事件到达之前会显示成"未标注"。
    @discardableResult
    public func register(
        units: [RealtimeASRClient.AttributionUnit],
        lineID: String,
        ordinal: Int
    ) -> String? {
        guard isEnabled, !units.isEmpty else { return nil }
        var label: String?
        for unit in units {
            lineByUnit[unit.segmentUID] = lineID
            guard let speaker = unit.speaker, !speaker.isEmpty else { continue }
            appliedByUnit[unit.segmentUID] = speaker
            if label == nil { label = speaker }
            observe(label: speaker, ordinal: ordinal)
        }
        return label
    }

    /// `speechrail.diarization.updated`：按 uid 原位修归属。**正文不参与**。
    ///
    /// 写库前比较一次：同一个归属重复到达（服务端会重复推稳定前缀）不产生第二次写。
    public func apply(units: [RealtimeASRClient.AttributionUnit]) async {
        guard isEnabled else { return }
        for unit in units {
            guard let lineID = lineByUnit[unit.segmentUID] else { continue }
            let desired = unit.speaker
            if let applied = appliedByUnit[unit.segmentUID], applied == desired { continue }
            do {
                try await coordinator.attachSpeakerLabel(lineID: lineID, label: desired)
            } catch {
                // 写不进去不是"归属没发生"，但也不该让整条链停下：正文已经落了库，
                // 归属可以事后人工标注。如实留一句。
                note = "有一条说话人归属没能写进记录库：\(error.localizedDescription)"
                continue
            }
            if let desired {
                appliedByUnit[unit.segmentUID] = desired
                observe(label: desired, ordinal: nil)
            } else {
                appliedByUnit.removeValue(forKey: unit.segmentUID)
            }
        }
    }

    /// 会话级声学建议。只登记，不自动合并——那会替用户做决定。
    public func noteSuggestions(_ links: [RealtimeASRClient.SpeakerLink]) {
        suggestions = links
    }

    /// 这一行当前归属到的标签（按 uid 反查）。
    ///
    /// 修订事件到达时用它在内存里刷新 chip：库里那一行已经改过了，界面不该等到重开才跟上。
    public func attributedLabel(forLineID lineID: String) -> String? {
        for (uid, id) in lineByUnit where id == lineID {
            if let label = appliedByUnit[uid] { return label }
        }
        return nil
    }

    /// 一次 active→degraded：标签停更、已给出的保留（§9 第 12 行）。
    public func markDegraded(code: String, message: String) {
        guard state == .active else { return }
        state = .degraded
        note = message.isEmpty ? "分人停止更新了（\(code)），正文照常记录。" : message
    }

    /// 档位不支持（`light`）：**不给一个永远点不动的开关**，只给一句说明（§6.2.1 的降级形状）。
    public func markUnavailable(note: String) {
        state = .unavailable
        self.note = note
    }

    private func observe(label: String, ordinal: Int?) {
        if !labels.contains(label) { labels.append(label) }
        if let ordinal {
            lineCounts[label, default: 0] += 1
            if firstOrdinal[label] == nil { firstOrdinal[label] = ordinal }
        }
    }

    // MARK: - 用户动作（只写显示名与归属列）

    /// 改名。两个标签可以被改成同一个名字——同一个人在两条链路上被标成两个标签时就这么办。
    public func rename(label: String, to name: String) async {
        guard let sessionID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await coordinator.renameSpeaker(sessionID: sessionID, label: label, name: trimmed)
            displayNames[label] = trimmed
        } catch {
            note = "改名没能保存：\(error.localizedDescription)"
        }
    }

    /// 标记为「我」。分人只输出匿名标签，本机这一侧由用户指认；写的是显示名，
    /// 所以它和改名是同一种动作（拆出才是改归属）。
    public func markAsMe(label: String) async {
        await rename(label: label, to: "我")
        mergedInto.removeValue(forKey: label)
    }

    /// 与另一个标签合并。两个标签的行都保留可见，正文一个字不动。
    public func merge(label: String, into target: String) async {
        guard label != target else { return }
        let name = displayNames[target] ?? target
        await rename(label: label, to: name)
        mergedInto[label] = target
    }

    /// 从某一位拆出若干行（选一段区间）。这是**唯一**会改 `line.speaker_label` 的用户动作。
    ///
    /// 新标签取一个没用过的字母；四位上限内没有空位时沿用最后一个，不悄悄造第五个。
    public func split(lineIDs: [String], to label: String? = nil) async {
        guard !lineIDs.isEmpty else { return }
        let target = label ?? nextAvailableLabel()
        for lineID in lineIDs {
            do {
                try await coordinator.attachSpeakerLabel(lineID: lineID, label: target)
            } catch {
                note = "拆出没能保存：\(error.localizedDescription)"
                return
            }
        }
        observe(label: target, ordinal: nil)
    }

    private func nextAvailableLabel() -> String {
        let used = Set(labels)
        for code in 0..<Self.maxSpeakers {
            let candidate = String(UnicodeScalar(UInt8(65 + code)))
            if !used.contains(candidate) { return candidate }
        }
        return labels.last ?? "A"
    }

    // MARK: - 呈现

    public var speakers: [Speaker] {
        labels.map { label in
            Speaker(
                label: label,
                displayName: displayNames[label],
                lineCount: lineCounts[label] ?? 0,
                firstOrdinal: firstOrdinal[label],
                suggestedMergeInto: suggestions.first { $0.from == label }?.to,
                mergedLabels: Set(mergedInto.keys)
            )
        }
    }

    /// 行内 chip 上的那一个词：有显示名给显示名，没有给「说话人 A」。
    public nonisolated static func chipText(label: String, displayName: String?) -> String {
        guard let displayName, !displayName.isEmpty else { return "说话人 \(label)" }
        return displayName
    }

    /// 记录库那一行的说话人摘要：「张三、李四」。
    public var summaryText: String? {
        guard !labels.isEmpty else { return nil }
        return labels.map { Self.chipText(label: $0, displayName: displayNames[$0]) }.joined(separator: "、")
    }
}
