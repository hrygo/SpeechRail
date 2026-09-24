import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
public final class TeleprompterStagePresentationState {
    public var settingsRequestID: UUID?
    public private(set) var lineNavigationRequestID: UUID?
    public private(set) var lineNavigationDelta = 0

    public init() {}

    public func requestLineNavigation(by delta: Int) {
        guard delta != 0 else { return }
        lineNavigationDelta = delta
        lineNavigationRequestID = UUID()
    }
}

@MainActor
@Observable
public final class TeleprompterStageWindowController: NSObject, NSWindowDelegate {
    public let session: TeleprompterSession
    public let settings: TeleprompterStageSettings
    public let presentation = TeleprompterStagePresentationState()
    private var panel: TeleprompterPanel?
    private var restoredSavedFrame = false
    private var layoutNeedsApplyAfterZoom = false
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
        let isCreatingPanel = panel == nil
        let panel = panel ?? makePanel()
        if isCreatingPanel {
            if restoredSavedFrame {
                constrainRestoredFrameToStageLimit()
            } else {
                updatePreferredWindowSize()
            }
        }
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    public func showSettings() {
        show()
        presentation.settingsRequestID = UUID()
    }

    public func moveReadingLine(by delta: Int) {
        guard isVisible else { return }
        presentation.requestLineNavigation(by: delta)
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
        guard let panel, !panel.isZoomed else { return }
        settings.width = Double(panel.contentView?.frame.width ?? panel.contentRect(forFrameRect: panel.frame).width)
        if layoutNeedsApplyAfterZoom {
            updatePreferredWindowSize()
        }
    }

    public func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? newFrame
        return TeleprompterStageGeometryPolicy.standardFrame(
            defaultFrame: newFrame,
            visibleFrame: visibleFrame
        )
    }

    private func updatePreferredWindowSize() {
        guard let panel else { return }
        guard !panel.isZoomed else {
            layoutNeedsApplyAfterZoom = true
            return
        }
        layoutNeedsApplyAfterZoom = false
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let requestedHeight = TeleprompterStageGeometryPolicy.preferredContentHeight(
            visibleLineCount: settings.visibleLineCount,
            scriptPointSize: settings.scriptPointSize,
            lineSpacing: CGFloat(settings.lineSpacing),
            showsAuxiliaryStatus: settings.showClockAndProgress || session.isMicrophoneCapturing
        )
        let contentWidth = panel.contentView?.frame.width ?? CGFloat(settings.width)
        var frame = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(width: contentWidth, height: requestedHeight))
        )
        frame.size.height = TeleprompterStageGeometryPolicy.cappedWindowFrameHeight(
            frame.height,
            visibleFrameHeight: screenFrame.height
        )
        frame.origin.x = panel.frame.minX
        frame.origin.y = panel.frame.maxY - frame.height
        frame = constrain(frame, to: screenFrame)
        panel.setFrame(frame, display: true, animate: false)
    }

    private func constrainRestoredFrameToStageLimit() {
        guard let panel else { return }
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let maxHeight = min(SpeechRailDesignTokens.Teleprompter.stageMaximumHeight, screenFrame.height)
        guard panel.frame.height > maxHeight else { return }
        var frame = panel.frame
        frame.size.height = maxHeight
        frame.origin.y = panel.frame.maxY - maxHeight
        panel.setFrame(constrain(frame, to: screenFrame), display: true, animate: false)
    }

    private func constrain(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var result = frame
        if result.width <= visibleFrame.width {
            result.origin.x = min(max(result.minX, visibleFrame.minX), visibleFrame.maxX - result.width)
        } else {
            result.origin.x = visibleFrame.minX
        }
        if result.height <= visibleFrame.height {
            result.origin.y = min(max(result.minY, visibleFrame.minY), visibleFrame.maxY - result.height)
        } else {
            result.origin.y = visibleFrame.minY
        }
        return result
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
            height: SpeechRailDesignTokens.Teleprompter.stageMaximumHeight
        )
        panel.maxSize = NSSize(
            width: SpeechRailDesignTokens.Teleprompter.stageMaximumWidth,
            height: SpeechRailDesignTokens.Teleprompter.stageMaximumHeight
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrameAutosaveName(SpeechRailDesignTokens.Teleprompter.stageWindowAutosaveName)
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: TeleprompterStageView(
                session: session,
                settings: settings,
                presentation: presentation,
                close: { [weak self] in self?.close() },
                requestWindowLayout: { [weak self] in self?.updatePreferredWindowSize() }
            )
        )
        restoredSavedFrame = panel.setFrameUsingName(SpeechRailDesignTokens.Teleprompter.stageWindowAutosaveName)
        if !restoredSavedFrame {
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
