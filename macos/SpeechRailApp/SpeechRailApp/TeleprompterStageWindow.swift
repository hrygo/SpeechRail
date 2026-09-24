import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
public final class TeleprompterStagePresentationState {
    public var settingsRequestID: UUID?

    public init() {}
}

@MainActor
@Observable
public final class TeleprompterStageWindowController: NSObject, NSWindowDelegate {
    public let session: TeleprompterSession
    public let settings: TeleprompterStageSettings
    public let presentation = TeleprompterStagePresentationState()
    private var panel: TeleprompterPanel?
    public private(set) var lastPresentationError: String?
    public private(set) var isVisible = false

    public init(session: TeleprompterSession, settings: TeleprompterStageSettings) {
        self.session = session
        self.settings = settings
    }

    public func show() {
        do {
            try session.openForManualReadingIfNeeded()
            lastPresentationError = nil
        } catch {
            lastPresentationError = error.localizedDescription
            isVisible = false
            return
        }
        let panel = panel ?? makePanel()
        panel.setContentSize(
            NSSize(
                width: settings.width,
                height: SpeechRailDesignTokens.Teleprompter.stageDefaultHeight
            )
        )
        panel.orderFrontRegardless()
        isVisible = true
    }

    public func showSettings() {
        show()
        presentation.settingsRequestID = UUID()
    }

    public func close() {
        panel?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        isVisible = false
        guard session.beginStageClose() else { return }
        Task { await session.finishStageClose() }
    }

    public func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        settings.width = Double(panel.frame.width)
    }

    private func makePanel() -> TeleprompterPanel {
        let panel = TeleprompterPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: settings.width,
                height: SpeechRailDesignTokens.Teleprompter.stageDefaultHeight
            ),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "SpeechRail · AI 提词器"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(
            width: SpeechRailDesignTokens.Teleprompter.stageMinimumWidth,
            height: SpeechRailDesignTokens.Teleprompter.stageMinimumHeight
        )
        panel.contentMaxSize = NSSize(
            width: SpeechRailDesignTokens.Teleprompter.stageMaximumWidth,
            height: 1_200
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrameAutosaveName(SpeechRailDesignTokens.Teleprompter.stageWindowAutosaveName)
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: TeleprompterStageView(
                session: session,
                settings: settings,
                presentation: presentation,
                close: { [weak self] in self?.close() }
            )
        )
        if !panel.setFrameUsingName(SpeechRailDesignTokens.Teleprompter.stageWindowAutosaveName) {
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - settings.width / 2
                let y = screenFrame.maxY - SpeechRailDesignTokens.Teleprompter.stageDefaultHeight - SpeechRailDesignTokens.Teleprompter.stageTopInset
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                panel.center()
            }
        }
        self.panel = panel
        return panel
    }
}

private final class TeleprompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
