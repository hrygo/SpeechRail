import Foundation
import Observation
import SpeechRailControlKit

// 分人归属的账本。**会议与字幕共用这一个**（`SESSIONS-SPEC` §14.3：同一套会话内匿名标签、
// 同一处改名、同一套降级话术），所以它既不认识会议也不认识字幕，只认识"归属"这件事。
//
// 三条从契约与规格直接落下来的规矩：
//
//   1. **只改归属列，正文一个字不动**（§15.3 第 2 条）。服务端的归属是"原位修订"，
//      自动归属原子保存逐词快照；人工整行标注与显示名另行保存。
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

    public private(set) var maxSpeakers = 4
    private var scopeBinding: SpeakerScopeBinding?

    public func configureCapacity(_ capacity: SpeechRailDiarizationCapacity, recordID: String,
        generation: Int, serverSessionID: String, inputEpoch: Int) {
        guard capacity.isValid, recordID == sessionID, let maximum = capacity.maxSpeakers else { return }
        maxSpeakers = maximum
        if capacity.backend != .meetingDynamic { scopeBinding = nil; return }
        if let scope = scopeBinding, scope.recordID == recordID,
           scope.connectionGeneration == generation, scope.serverSessionID == serverSessionID,
           scope.inputEpoch == inputEpoch { return }
        scopeBinding = SpeakerScopeBinding(recordID:recordID,
            connectionGeneration:generation,serverSessionID:serverSessionID,inputEpoch:inputEpoch)
    }

    private func localLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard var scope = scopeBinding else { return raw }
        do {
            let label = try scope.serverLabel(raw,capacity:maxSpeakers)
            scopeBinding = scope
            return label
        } catch SpeakerScopeBinding.Failure.capacityExceeded {
            diagnosticCode = "speaker_capacity"
            note = "已达到本次录音的说话人数上限，新增说话人暂未确认。"
            return nil
        } catch { return nil }
    }

    private let coordinator: SessionCoordinator
    private let attachAttribution: @MainActor (String, [TranscriptAttributionUnit]) async throws -> TranscriptLine
    /// 写下一条说话人修订之后要跑一次。
    ///
    /// 改名/合并/标记「我」都会追加一条 `kind='speaker'` 的修订事件，
    /// 而纪要是否需要复核正是靠这些事件算出来的。不回调的话，用户改完名字，
    /// 界面上"需复核"要等到下一次重新整理或重开才出现——验收标准 3 说的
    /// 「修改来源后相关结论提示复核」就落空了。回调放在这一层，是为了让这几条
    /// 路径**都**带上它：`markAsMe` 与 `merge` 内部就是调 `rename`。
    ///
    /// `split`（拆出）也带：它在**用户动作这一层**单独记一条归属修订，
    /// 自动逐词修订不记作用户修改；人工动作单独追加来源修订。
    /// 异步是为了让刷新在动作返回**之前**完成：否则用户改完名字，
    /// 界面先回显新名字、"需复核"再晚一步出现，中间那一瞬看着像是没生效。
    var onSourceRevision: (@MainActor () async -> Void)?

    public private(set) var sessionID: String?
    /// 本场出现过的匿名标签，按首次出现的顺序。
    public private(set) var labels: [String] = []
    public private(set) var displayNames: [String: String] = [:]
    public private(set) var lineCounts: [String: Int] = [:]
    public private(set) var firstOrdinal: [String: Int] = [:]
    public private(set) var state: State = .off
    /// 降级的可读原因（面板上原话显示，也是 `session.diarization_note` 的内容）。
    public private(set) var note: String?
    /// 用于诊断的稳定错误码；面板继续显示可读说明。
    public private(set) var diagnosticCode: String?

    /// `segment_uid` → 库里的行 id。修订事件靠它找行。
    private var lineByUnit: [String: String] = [:]
    private var unitsByLine: [String: Set<String>] = [:]
    /// 已接纳的原始单元与成功保存的整行投影分开；保存失败不形成去重证明。
    private var registeredByUnit: [String: RealtimeASRClient.AttributionUnit] = [:]
    private struct AppliedLine {
        let requested: [TranscriptAttributionUnit]
        let projection: TranscriptLine
    }
    private var appliedByLine: [String: AppliedLine] = [:]
    private var lifecycle = UUID()
    /// 本场被并掉的标签 → 目标标签（"已并入 A"）。
    private var mergedInto: [String: String] = [:]

    public init(
        coordinator: SessionCoordinator,
        attachAttribution: (@MainActor (String, [TranscriptAttributionUnit]) async throws -> TranscriptLine)? = nil,
        onSourceRevision: (@MainActor () async -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.attachAttribution = attachAttribution ?? { lineID, units in
            try await coordinator.attachTranscriptAttribution(lineID: lineID, units: units)
        }
        self.onSourceRevision = onSourceRevision
    }

    // MARK: - 会话边界

    /// 新会话开始：账本归零（**不跨会话**——§14.3 的边界：不做跨会话身份）。
    public func begin(sessionID: String, enabled: Bool) {
        lifecycle = UUID()
        scopeBinding = nil; maxSpeakers = 4
        self.sessionID = sessionID
        labels = []
        displayNames = [:]
        lineCounts = [:]
        firstOrdinal = [:]
        lineByUnit = [:]
        unitsByLine = [:]
        registeredByUnit = [:]
        appliedByLine = [:]
        mergedInto = [:]
        note = nil
        diagnosticCode = nil
        state = enabled ? .active : .off
    }

    /// 同场续接（新 epoch / 新连接）：只重置 uid 坐标系，保留面板显示。
    ///
    /// `segment_uid` 是服务端按连接生成的（`seg_{uuid4hex[:12]}`），跨连接无意义，
    /// 所以 uid→行索引与已应用表必须随新连接清空，否则迟到修订会串写。
    /// 但中断前已标出的标签/改名/计数是本场的事实，清空它们等于让面板“失忆”——
    /// 用户看到的是“断了一下，之前标的人全没了”，直到新归属到达才逐个回来。
    /// 降级态也不回退：续接不治愈 degraded/unavailable，只是不擦除显示。
    public func beginNewConnection(sessionID: String) {
        lifecycle = UUID()
        scopeBinding = nil; maxSpeakers = 4
        self.sessionID = sessionID
        lineByUnit = [:]
        unitsByLine = [:]
        registeredByUnit = [:]
        appliedByLine = [:]
    }

    /// 打开一场历史记录：只读回已经落库的显示名与出现过的标签，
    /// 不重建 uid 表（那时候修订早结束了）。
    public func load(sessionID: String, labels: [String], displayNames: [String: String]) {
        lifecycle = UUID()
        lineByUnit = [:]
        unitsByLine = [:]
        registeredByUnit = [:]
        appliedByLine = [:]
        self.sessionID = sessionID
        self.labels = labels
        self.displayNames = displayNames
    }

    public func end() {
        lifecycle = UUID()
        sessionID = nil
        lineByUnit = [:]
        unitsByLine = [:]
        registeredByUnit = [:]
        appliedByLine = [:]
    }

    public var isEnabled: Bool { state == .active || state == .degraded }

    // MARK: - 事件

    /// 登记这一行的完整单元快照并退休被替换的 uid；返回第一项可用标签仅供面板登记。
    ///
    /// 这里仅建立 `segment_uid` → 行的索引；只有 `apply` 成功写入库后才登记为已应用。
    /// 这样首个晚到归属不会因为刚注册时就被标成"已应用"而跳过持久化。
    @discardableResult
    public func register(
        units: [RealtimeASRClient.AttributionUnit],
        lineID: String,
        ordinal: Int
    ) -> String? {
        guard isEnabled, !units.isEmpty else { return nil }
        var label: String?
        let currentIDs = Set(units.map(\.segmentUID))
        for uid in (unitsByLine[lineID] ?? []).subtracting(currentIDs) where lineByUnit[uid] == lineID {
            lineByUnit.removeValue(forKey: uid)
            registeredByUnit.removeValue(forKey: uid)
        }
        unitsByLine[lineID] = currentIDs
        for unit in units {
            if lineByUnit[unit.segmentUID] != lineID {
                appliedByLine.removeValue(forKey: lineID)
            }
            if let previous = lineByUnit[unit.segmentUID], previous != lineID { unitsByLine[previous]?.remove(unit.segmentUID) }
            lineByUnit[unit.segmentUID] = lineID
            unitsByLine[lineID, default: []].insert(unit.segmentUID)
            registeredByUnit[unit.segmentUID] = unit
            guard let speaker = localLabel(unit.speaker), !speaker.isEmpty else { continue }
            if label == nil { label = speaker }
            observe(label: speaker, ordinal: ordinal)
        }
        return label
    }

    /// `speechrail.diarization.updated`：按 uid 原位修归属。**正文不参与**。
    ///
    /// 写库前比较一次：同一个归属重复到达（服务端会重复推稳定前缀）不产生第二次写。
    public func apply(units: [RealtimeASRClient.AttributionUnit]) async {
        let command = freezeAttribution(units: units)
        for unit in units {
            if let target = lineByUnit[unit.segmentUID], command.acceptsProjection(for: target) {
                registeredByUnit[unit.segmentUID] = unit
            }
        }
        await apply(command)
    }

    struct AttributionCommand {
        fileprivate let lifecycle: UUID
        fileprivate let targets: [AttributionTarget]
        fileprivate let invalidLines: Set<String>
        func acceptsProjection(for lineID: String) -> Bool { !invalidLines.contains(lineID) }
    }

    fileprivate struct AttributionTarget {
        let lineID: String
        let units: [TranscriptAttributionUnit]
    }

    /// 冻结整行快照；部分 uid 修订保留该行其他已登记的词。
    func freezeAttribution(
        units: [RealtimeASRClient.AttributionUnit], lineID: String? = nil
    ) -> AttributionCommand {
        guard isEnabled else { return .init(lifecycle: lifecycle, targets: [], invalidLines: []) }
        var lineOrder: [String] = []
        var incoming: [String: [RealtimeASRClient.AttributionUnit]] = [:]
        for unit in units {
            guard let target = lineID ?? lineByUnit[unit.segmentUID] else { continue }
            if incoming[target] == nil { lineOrder.append(target) }
            incoming[target, default: []].append(unit)
        }
        var targets: [AttributionTarget] = []
        var invalid: Set<String> = []
        for target in lineOrder {
            var snapshot: [String: RealtimeASRClient.AttributionUnit] = [:]
            if lineID == nil {
                for uid in unitsByLine[target] ?? [] { snapshot[uid] = registeredByUnit[uid] }
            }
            let updates = incoming[target] ?? []
            guard Set(updates.map(\.segmentUID)).count == updates.count else {
                invalid.insert(target); continue
            }
            for unit in updates { snapshot[unit.segmentUID] = unit }
            var mapped: [TranscriptAttributionUnit] = []
            for unit in snapshot.values.sorted(by: {
                ($0.textStart ?? Int.max, $0.textEnd ?? Int.max, $0.segmentUID)
                    < ($1.textStart ?? Int.max, $1.textEnd ?? Int.max, $1.segmentUID)
            }) {
                guard let start = unit.textStart, let end = unit.textEnd else {
                    invalid.insert(target); break
                }
                mapped.append(.init(id: unit.segmentUID, textStart: start, textEnd: end,
                    speakerLabel: localLabel(unit.speaker),
                    audioStartSample: unit.audioStartSample, audioEndSample: unit.audioEndSample))
            }
            guard !invalid.contains(target) else { continue }
            targets.append(.init(lineID: target, units: mapped))
        }
        return .init(lifecycle: lifecycle, targets: targets, invalidLines: invalid)
    }

    @discardableResult
    func apply(_ command: AttributionCommand) async -> Set<String> {
        var confirmedLines: Set<String> = []
        if lifecycle == command.lifecycle, !command.invalidLines.isEmpty {
            note = "有一条说话人归属缺少文字范围，正文已保留。"
        }
        for target in command.targets {
            func ownsProjection() -> Bool {
                lifecycle == command.lifecycle && target.units.allSatisfy { lineByUnit[$0.id] == target.lineID }
            }
            if ownsProjection(), appliedByLine[target.lineID]?.requested == target.units {
                confirmedLines.insert(target.lineID)
                continue
            }
            let saved: TranscriptLine
            do { saved = try await attachAttribution(target.lineID, target.units) }
            catch {
                if ownsProjection() { note = "有一条说话人归属没能写进记录库，正文已保留。" }
                continue
            }
            guard ownsProjection() else { continue }
            appliedByLine[target.lineID] = .init(requested: target.units, projection: saved)
            confirmedLines.insert(target.lineID)
            for label in Set(saved.attributionUnits.compactMap(\.speakerLabel)) {
                observe(label: label, ordinal: nil)
            }
            if let label = saved.speakerLabel { observe(label: label, ordinal: nil) }
        }
        return confirmedLines
    }

    public func attributedLabel(forLineID lineID: String) -> String? {
        appliedByLine[lineID]?.projection.speakerLabel
    }

    func attributedLine(forLineID lineID: String) -> TranscriptLine? {
        appliedByLine[lineID]?.projection
    }

    /// Called after accepted attribution writes leave the shared persistence owner.
    func retireLine(_ lineID: String) {
        appliedByLine.removeValue(forKey: lineID)
        for unit in unitsByLine.removeValue(forKey: lineID) ?? [] {
            if lineByUnit[unit] == lineID {
                lineByUnit.removeValue(forKey: unit); registeredByUnit.removeValue(forKey: unit)
            }
        }
    }
    var liveUnitCount: Int { lineByUnit.count }

    /// 一次 active→degraded：标签停更、已给出的保留（§9 第 12 行）。
    public func markDegraded(code: String, message: String) {
        guard state == .active
            || (state == .degraded && diagnosticCode == "auxiliary_window_expired"
                && code != "auxiliary_window_expired") else { return }
        state = .degraded
        diagnosticCode = code
        note = message.isEmpty ? "说话人编号停止更新了（\(code)），正文照常记录。" : message
    }

    /// 对齐失败只影响辅助标注，保留正文及后续可用归属；不展示后端异常正文。
    @discardableResult
    public func recordAlignmentFailure(code: String) -> String {
        let diagnostic: (code: String, detail: String)
        switch code {
        case "text_mismatch":
            diagnostic = (code, "部分文字未能匹配到录音中的位置")
        case "alignment_timeout":
            diagnostic = (code, "部分文字的时间标注超时")
        case "alignment_overloaded":
            diagnostic = (code, "时间标注正忙，部分文字未能完成标注")
        case "alignment_pcm_overflow", "alignment_pcm_mismatch":
            diagnostic = (code, "部分录音未能完整用于时间标注")
        case "invalid_alignment", "alignment_out_of_bounds", "alignment_not_monotonic":
            diagnostic = (code, "部分文字的时间位置不可靠")
        case "alignment_time_resolution_insufficient", "granularity_unsupported":
            diagnostic = (code, "这段录音无法提供足够精确的文字位置")
        case "alignment_stale":
            diagnostic = (code, "部分文字的辅助标注已过期")
        case "alignment_unavailable", "alignment_worker_failed", "alignment_failed":
            diagnostic = (code, "部分文字的时间标注暂不可用")
        default:
            diagnostic = ("alignment_failed", "部分文字的时间标注暂不可用")
        }
        let message = diagnostic.detail + (isEnabled
            ? "，这部分暂时无法区分说话人；正文已经保留。"
            : "；正文已经保留。")
        if isEnabled {
            markDegraded(code: diagnostic.code, message: message)
            return note ?? message
        }
        diagnosticCode = diagnostic.code
        return message
    }

    /// 服务或历史记录说这场标不了说话人：**不给一个永远点不动的开关**，只给一句说明
    /// （§6.2.1 的降级形状）。分人是任务级 opt-in，因此这不是档位属性。
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
            // 写成了修订，依赖这份来源的纪要该提示复核了。
            await onSourceRevision?()
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
        let name = displayText(for: target)
        await rename(label: label, to: name)
        mergedInto[label] = target
    }

    /// 从某一位拆出若干行（选一段区间）。这是**唯一**会改 `line.speaker_label` 的用户动作。
    ///
    /// 显式目标必须是已有标签；新标签按本段确认的容量分配，满额时保留原归属。
    public func split(lineIDs: [String], to label: String? = nil) async {
        guard !lineIDs.isEmpty, let sessionID else { return }
        if let label, !labels.contains(label) {
            let legacyLabel = label.utf8.count == 1 && label.utf8.first.map {
                $0 >= 65 && Int($0 - 65) < min(maxSpeakers,26)
            } == true
            guard scopeBinding == nil && legacyLabel else {
                note = "请选择已有说话人，或使用「拆出」创建新说话人。"
                return
            }
        }
        guard let target = label ?? nextAvailableLabel() else {
            note = "本段的说话人数量已达上限，无法继续拆出；原有归属已保留。"
            return
        }
        for lineID in lineIDs {
            do {
                let generation = lifecycle
                let saved = try await coordinator.attachSpeakerLabel(lineID: lineID, label: target)
                if lifecycle == generation {
                    retireLine(lineID)
                    appliedByLine[lineID] = .init(requested: [], projection: saved)
                }
            } catch {
                note = "拆出没能保存：\(error.localizedDescription)"
                return
            }
        }
        observe(label: target, ordinal: nil)
        // 归属变了，依赖旧归属的纪要该提示复核。事件记在**用户动作**这一层，
        // 自动归属与用户动作分离，只有这里追加来源修订。
        do {
            try await coordinator.noteSpeakerAttributionChange(
                sessionID: sessionID,
                detail: "\(target)|拆出 \(lineIDs.count) 句"
            )
        } catch {
            // 归属已经改成功了，只是没记上修订事件。
            // 这要说出来：否则用户看到的纪要不会提示复核，而界面上什么异常都没有。
            note = "归属已经改了，但没能记下这次修订：\(error.localizedDescription)"
        }
        // Saved attribution must reach the live list even when revision bookkeeping fails.
        await onSourceRevision?()
    }

    private func nextAvailableLabel() -> String? {
        let used = Set(labels)
        if var scope = scopeBinding {
            let label = try? scope.allocateUserLabel(existing:used,capacity:maxSpeakers)
            scopeBinding = scope
            return label
        }
        for code in 0..<min(maxSpeakers,26) {
            let candidate = String(UnicodeScalar(UInt8(65 + code)))
            if !used.contains(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - 呈现

    public var speakers: [Speaker] {
        labels.map { label in
            Speaker(
                label: label,
                displayName: displayNames[label],
                lineCount: lineCounts[label] ?? 0,
                firstOrdinal: firstOrdinal[label],
                // 当前 wire 不再给会话级声学建议，所以这一栏永远是空的。
                suggestedMergeInto: nil,
                mergedLabels: Set(mergedInto.keys)
            )
        }
    }

    /// 行内 chip 上的那一个词：有显示名给显示名，没有给「说话人 A」。
    public nonisolated static func chipText(label: String, displayName: String?, ordinal: Int? = nil) -> String {
        guard let displayName, !displayName.isEmpty else {
            if label.first == "d", let tail = label.split(separator:":").last,
               tail.first == "S" || tail.first == "U", Int(tail.dropFirst()) != nil {
                return ordinal.map { "说话人 \($0)" } ?? "未命名说话人"
            }
            return "说话人 \(label)"
        }
        return displayName
    }

    public func displayText(for label: String) -> String {
        Self.chipText(label:label, displayName:displayNames[label],
            ordinal:labels.firstIndex(of:label).map { $0 + 1 })
    }

    public nonisolated static func displayOrdinals(for labels: [String]) -> [String: Int] {
        var ordinals: [String: Int] = [:]
        for label in labels where ordinals[label] == nil { ordinals[label] = ordinals.count + 1 }
        return ordinals
    }

    /// 记录库那一行的说话人摘要：「张三、李四」。
    public var summaryText: String? {
        guard !labels.isEmpty else { return nil }
        return labels.map { displayText(for:$0) }.joined(separator: "、")
    }
}
