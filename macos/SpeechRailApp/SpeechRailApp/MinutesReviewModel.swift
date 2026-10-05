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
