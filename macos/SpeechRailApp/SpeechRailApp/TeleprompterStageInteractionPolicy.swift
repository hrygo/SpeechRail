import Foundation

/// Inputs that decide whether stage controls are visible.
///
/// The state is intentionally flat and testable: hover is only one reason
/// controls may be shown, never the only way to make them available.
public struct TeleprompterStageInteractionVisibility: Equatable, Sendable {
    public var pointerInside: Bool
    public var controlFocusInside: Bool
    public var menuOrPopoverPresented: Bool
    public var alwaysShowControls: Bool
    public var voiceOverEnabled: Bool
    public var initialRevealActive: Bool
    public var keyboardRevealRequested: Bool

    public init(
        pointerInside: Bool,
        controlFocusInside: Bool,
        menuOrPopoverPresented: Bool,
        alwaysShowControls: Bool,
        voiceOverEnabled: Bool,
        initialRevealActive: Bool,
        keyboardRevealRequested: Bool
    ) {
        self.pointerInside = pointerInside
        self.controlFocusInside = controlFocusInside
        self.menuOrPopoverPresented = menuOrPopoverPresented
        self.alwaysShowControls = alwaysShowControls
        self.voiceOverEnabled = voiceOverEnabled
        self.initialRevealActive = initialRevealActive
        self.keyboardRevealRequested = keyboardRevealRequested
    }
}

/// Tracks the one-shot keyboard reveal request independently from the other
/// visibility reasons. Focus or pointer state owns the request, so a stale
/// Tab reveal cannot keep the controls visible forever.
public struct TeleprompterStageInteractionState: Equatable, Sendable {
    public private(set) var keyboardRevealRequested = false

    public init() {}

    public mutating func requestKeyboardReveal() {
        keyboardRevealRequested = true
    }

    public mutating func setControlFocus(_ inside: Bool) {
        keyboardRevealRequested = inside
    }

    public mutating func setPointerInside(_ inside: Bool) {
        if !inside {
            keyboardRevealRequested = false
        }
    }
}

public enum TeleprompterStageInteractionPolicy {
    public static let initialRevealDuration: Duration = .seconds(2)
    public static let hideDelay: Duration = .milliseconds(250)
    public static let errorNoticeDuration: Duration = .seconds(4)

    public static func controlsVisible(
        for input: TeleprompterStageInteractionVisibility
    ) -> Bool {
        input.pointerInside
            || input.controlFocusInside
            || input.menuOrPopoverPresented
            || input.alwaysShowControls
            || input.voiceOverEnabled
            || input.initialRevealActive
            || input.keyboardRevealRequested
    }
}
