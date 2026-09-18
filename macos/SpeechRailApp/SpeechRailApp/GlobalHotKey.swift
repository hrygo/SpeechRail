import AppKit
import Carbon.HIToolbox
import Foundation

// 全局热键（`SESSIONS-SPEC` §5.2、`TECHNICAL-DESIGN` §3.7）。
//
// 走 Carbon 的 `RegisterEventHotKey`，**不是** `NSEvent.addGlobalMonitorForEvents`。
// 理由只有一条，但它是决定性的：Carbon 这条路**不需要辅助功能 / 输入监控授权**，
// 于是"按一个键唤起字幕带"不会换来一个系统授权弹窗。
//
// 四个键与规格一致：`⌘⇧L` 字幕 · `⌘⇧N` 会议 · `⌘⇧.` 结束 · `⌘⇧I` 内心 OS。
//
// 边界：热键只**发号**，不做会话判定。按下时"能不能开始"由 `SessionCoordinator` 判
// ——热键不认识占用、不认识设备，否则同一件事会有两处实现（§5.4 的同一条理由）。

/// 热键中心。一个 App 里只需要一个；注册失败的键**不影响其余键**（免费版没有配额问题，
/// 但被别的 App 抢走的组合是存在的），失败会如实记在 `unavailable` 里。
@MainActor
public final class GlobalHotKeyCenter {
    public enum Action: UInt32, CaseIterable, Sendable {
        case toggleCaptions = 1
        case startMeeting = 2
        case finishCurrent = 3
        case toggleInnerOS = 4

        /// 界面上与文档里都写这一份（键位只在两处声明：这里与规格 §5.2）。
        public var display: String {
            switch self {
            case .toggleCaptions: "⌘⇧L"
            case .startMeeting: "⌘⇧N"
            case .finishCurrent: "⌘⇧."
            case .toggleInnerOS: "⌘⇧I"
            }
        }

        var keyCode: UInt32 {
            switch self {
            // kVK_ANSI_* 是**物理键位**，所以它在任何键盘布局下都是同一个键。
            case .toggleCaptions: UInt32(kVK_ANSI_L)
            case .startMeeting: UInt32(kVK_ANSI_N)
            case .finishCurrent: UInt32(kVK_ANSI_Period)
            case .toggleInnerOS: UInt32(kVK_ANSI_I)
            }
        }

        var carbonModifiers: UInt32 {
            UInt32(cmdKey | shiftKey)
        }
    }

    private var handlers: [Action: @MainActor () -> Void] = [:]
    private var registered: [Action: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    /// 注册时被别的 App 占着的键。界面可以据此如实说明"这个键这次没生效"。
    public private(set) var unavailable: [Action] = []

    public init() {}

    /// 装好事件回调并注册四个键。**可重复调用**：已经注册过的不再重复。
    public func install() {
        installEventHandlerIfNeeded()
        for action in Action.allCases where registered[action] == nil {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(
                action.keyCode,
                action.carbonModifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                registered[action] = reference
            } else if !unavailable.contains(action) {
                unavailable.append(action)
            }
        }
        Self.publish(handlers: handlers)
    }

    /// 键 → 动作。每个能力在 App 里各自接线（热键本身不认识字幕与会议）。
    public func setHandler(_ action: Action, handler: @escaping @MainActor () -> Void) {
        handlers[action] = handler
        Self.publish(handlers: handlers)
    }

    public func uninstall() {
        for (_, reference) in registered { UnregisterEventHotKey(reference) }
        registered.removeAll()
        handlers.removeAll()
        Self.publish(handlers: [:])
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return status }
                GlobalHotKeyCenter.dispatch(id: identifier.id)
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    // MARK: - 回调落地

    private static let signature: OSType = {
        // 'SRHK'：Carbon 要求一个四字符签名，它只用来分辨"这些是不是我们的热键"。
        let characters: [Character] = ["S", "R", "H", "K"]
        return characters.reduce(OSType(0)) { ($0 << 8) | OSType($1.asciiValue ?? 0) }
    }()

    /// Carbon 的 C 回调拿不到 `self`，所以经一份**只在主线程访问**的登记表转一手。
    /// 回调本身也装在 application event target 上，因此它永远在主线程跑。
    private static let registry = HandlerRegistry()

    private static func publish(handlers: [Action: @MainActor () -> Void]) {
        registry.set(handlers)
    }

    fileprivate static func dispatch(id: UInt32) {
        guard let action = Action(rawValue: id), let handler = registry.handler(for: action) else {
            return
        }
        MainActor.assumeIsolated { handler() }
    }

    private final class HandlerRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [UInt32: @MainActor () -> Void] = [:]

        func set(_ handlers: [Action: @MainActor () -> Void]) {
            lock.lock()
            self.handlers = Dictionary(
                uniqueKeysWithValues: handlers.map { ($0.key.rawValue, $0.value) }
            )
            lock.unlock()
        }

        func handler(for action: Action) -> (@MainActor () -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return handlers[action.rawValue]
        }
    }
}
