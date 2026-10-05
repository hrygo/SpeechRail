import Foundation
import Observation

/// 纪要核对的编辑状态（MA-11）。
///
/// 三件事在这里被刻意分开，因为它们失败的方式完全不同：
/// - **草稿**（`draft`）：用户正在写的东西。保存失败**不能丢**（MC-47）——
///   磁盘写不进去就把用户的字弄没了，用户会重写一遍，甚至直接不信任这个功能。
/// - **保存失败**（`saveFailure`）：和草稿分开报。用户看到的是"没存上"，
///   不是"你的内容没了"——这两句话对应的下一步动作完全不同。
/// - **成功基线**（`lastSavedBody`）：成功之后才更新，并且清掉失败态。
@MainActor
@Observable
public final class MinutesReviewModel {
    /// 用户正在编辑的正文。**保存失败时不清空**（MC-47）。
    public private(set) var draft: String
    /// 上一次成功写进库的正文。撤销回到这里，不是回到空。
    public private(set) var lastSavedBody: String
    public private(set) var saveFailure: String?
    public private(set) var isSaving = false
    /// 用户改过但还没落库。界面用它提示"还有改动没存"。
    public private(set) var hasUnsavedChanges = false

    /// 正在核对的那一版。保存成功后指向新写出来的那一版——
    /// 改一次多一版，所以指针要跟着走，否则下一次保存会改错版本。
    public private(set) var minutesID: String
    public private(set) var bodyOrigin: MinutesBodyOrigin
    /// 正文出处变了要提示：用户改过之后，"这是 AI 写的"这句话就不成立了。
    public private(set) var originChanged = false

    private let coordinator: SessionCoordinator
    private let sessionID: String

    public init(coordinator: SessionCoordinator, sessionID: String, version: MinutesVersion) {
        self.coordinator = coordinator
        self.sessionID = sessionID
        self.openingVersionID = version.id
        self.minutesID = version.id
        self.bodyOrigin = version.bodyOrigin
        self.draft = version.body ?? ""
        self.lastSavedBody = version.body ?? ""
    }

    public func update(_ text: String) {
        draft = text
        hasUnsavedChanges = text != lastSavedBody
    }

    /// 存草稿。**失败只报失败，一个字都不动草稿**（MC-47）。
    @discardableResult
    public func save() async -> Bool {
        guard draft != lastSavedBody else {
            hasUnsavedChanges = false
            return true
        }
        isSaving = true
        saveFailure = nil
        do {
            let saved = try await coordinator.saveUserMinutesEdit(
                sessionID: sessionID,
                editingMinutesID: minutesID,
                body: draft
            )
            minutesID = saved.id
            originChanged = saved.bodyOrigin != bodyOrigin
            bodyOrigin = saved.bodyOrigin
            // 成功之后才更新基线；草稿保持用户写的样子，不"刷新"成别的内容。
            lastSavedBody = draft
            hasUnsavedChanges = false
            saveFailure = nil
            isSaving = false
            await loadLineage()
            return true
        } catch {
            saveFailure = error.localizedDescription
            isSaving = false
            return false
        }
    }

    /// 撤销：回到上一次成功写进库的正文。
    ///
    /// 这是**编辑框里**的撤销，还没落库；已经存过的版本由库里的
    /// `undoMinutesEdit` 另存一版处理。两者分开，用户按撤销时不必担心影响历史。
    public func revertToLastSaved() {
        draft = lastSavedBody
        hasUnsavedChanges = false
        saveFailure = nil
    }

    /// 血缘：从第一版到当前版。**用户要能看见自己改过什么**（MC-48）。
    public private(set) var lineage: [MinutesVersion] = []
    /// 与「打开时的第一版」的差异。nil = 还没加载。
    public private(set) var comparison: MinutesVersionDiff?

    private var openingVersionID: String

    /// 读一次血缘。进来时记下起点，之后一直和它比——
    /// 用户要回答的是"我这次改了什么"，不是"和上一版差了什么"。
    public func loadLineage() async {
        lineage = (try? await coordinator.minutesEditLineage(minutesID: minutesID)) ?? []
        recomputeComparison()
    }

    private func recomputeComparison() {
        // 基准是**用户打开时看到的那一版**，不是血缘的起点。
        // 打开一版已经改过的纪要时，起点是 AI 原文，但那不是用户这次想比的。
        guard let opening = lineage.first(where: { $0.id == openingVersionID }),
              let current = lineage.first(where: { $0.id == minutesID })
        else {
            comparison = nil
            return
        }
        comparison = MinutesDiff.lineDiff(from: opening.body ?? "", to: current.body ?? "")
    }

    /// 采用当前这一版。**只有用户明确按下去才算**（MC-31）：
    /// 改完不等于采用，生成新版本也不等于采用。
    @discardableResult
    public func adopt() async -> Bool {
        // 采用之前必须先把草稿落库。存不进去就**不能**继续采用：
        // 否则采用的是一版用户根本没看到的内容，"采用"就成了空话。
        if hasUnsavedChanges {
            guard await save() else { return false }
        }
        do {
            let ok = try await coordinator.adoptMinutes(
                sessionID: sessionID,
                minutesID: minutesID,
                expectedCurrentID: lineage.last(where: { $0.isAccepted })?.id
            )
            if ok { await loadLineage() }
            return ok
        } catch {
            saveFailure = error.localizedDescription
            return false
        }
    }

    /// 正文出处的人话。界面直接显示它，不要让用户去猜。
    public var originSummary: String {
        switch bodyOrigin {
        case .ai: "这段是模型整理的"
        case .userEdited: "你改过这段"
        case .userSupplement: "这段是你补充的"
        case .legacyImport: "这段来自旧库导入，没有来源引用"
        }
    }
}

/// 快捷键在编辑态怎么处理（MC-73）。
///
/// 中文输入法组字、回车选词、Esc 取消组字的时候，键盘命令根本没有"按下"这个动作。
/// 这时候还走一遍全局快捷键，最典型的后果是**输入法选词按回车顺手采用了纪要**。
/// 所以：**编辑控件是 first responder 时，会话级快捷键一律不生效**。
public enum ReviewShortcutPolicy {
    /// 编辑控件是 first responder 时抑制会话级快捷键。
    public static func suppressesSessionShortcuts(isTextInputFocused: Bool) -> Bool {
        isTextInputFocused
    }

    /// 组字中连输入控件自己的回车也不算提交——那一下是选词。
    public static func shouldSubmit(isComposing: Bool) -> Bool {
        !isComposing
    }

    /// 组字中不弹确认层。用户在选词，不是在结束会议。
    public static func shouldPresentConfirm(isComposing: Bool) -> Bool {
        !isComposing
    }
}
