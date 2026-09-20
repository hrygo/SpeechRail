import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
public final class TeleprompterStageWindowController: NSObject, NSWindowDelegate {
    public let session: TeleprompterSession
    public let settings: TeleprompterStageSettings
    private var panel: TeleprompterPanel?
    private var isClosingProgrammatically = false

    public init(session: TeleprompterSession, settings: TeleprompterStageSettings) {
        self.session = session
        self.settings = settings
    }

    public func show() {
        let panel = panel ?? makePanel()
        panel.setContentSize(
            NSSize(
                width: settings.width,
                height: SpeechRailDesignTokens.Teleprompter.stageDefaultHeight
            )
        )
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    public func close() {
        guard let panel else { return }
        isClosingProgrammatically = true
        panel.close()
        isClosingProgrammatically = false
    }

    public func windowWillClose(_ notification: Notification) {
        guard !isClosingProgrammatically else { return }
        Task { await session.endFollowing() }
    }

    private func makePanel() -> TeleprompterPanel {
        let panel = TeleprompterPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: settings.width,
                height: SpeechRailDesignTokens.Teleprompter.stageDefaultHeight
            ),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "SpeechRail · AI 提词器"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrameAutosaveName(SpeechRailDesignTokens.Teleprompter.stageWindowAutosaveName)
        panel.sharingType = .none
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: TeleprompterStageView(
                session: session,
                settings: settings,
                close: { [weak self] in self?.close() }
            )
        )
        if !panel.setFrameUsingName(SpeechRailDesignTokens.Teleprompter.stageWindowAutosaveName) {
            panel.center()
        }
        self.panel = panel
        return panel
    }
}

private final class TeleprompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
