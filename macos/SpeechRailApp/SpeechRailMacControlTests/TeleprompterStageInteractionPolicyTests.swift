import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterStageInteractionPolicyTests {
    @Test("controls remain visible for focus, menus, VoiceOver, and opt-in always-on")
    func visibleReasonsPreventHiding() {
        let base = TeleprompterStageInteractionVisibility(
            pointerInside: false,
            controlFocusInside: false,
            menuOrPopoverPresented: false,
            alwaysShowControls: false,
            voiceOverEnabled: false,
            initialRevealActive: false,
            keyboardRevealRequested: false
        )
        #expect(!TeleprompterStageInteractionPolicy.controlsVisible(for: base))

        var visible = base
        visible.controlFocusInside = true
        #expect(TeleprompterStageInteractionPolicy.controlsVisible(for: visible))

        visible = base
        visible.menuOrPopoverPresented = true
        #expect(TeleprompterStageInteractionPolicy.controlsVisible(for: visible))

        visible = base
        visible.voiceOverEnabled = true
        #expect(TeleprompterStageInteractionPolicy.controlsVisible(for: visible))

        visible = base
        visible.alwaysShowControls = true
        #expect(TeleprompterStageInteractionPolicy.controlsVisible(for: visible))

        visible = base
        visible.pointerInside = true
        #expect(TeleprompterStageInteractionPolicy.controlsVisible(for: visible))

        visible = base
        visible.initialRevealActive = true
        #expect(TeleprompterStageInteractionPolicy.controlsVisible(for: visible))

        visible = base
        visible.keyboardRevealRequested = true
        #expect(TeleprompterStageInteractionPolicy.controlsVisible(for: visible))
    }

    @Test("reading shortcuts require reading focus and never steal control keys")
    func readingShortcutFocusPolicy() {
        #expect(
            TeleprompterStageInteractionPolicy.acceptsReadingKeyCommands(
                readingAreaFocused: true,
                controlFocusInside: false,
                menuOrPopoverPresented: false
            )
        )
        #expect(
            !TeleprompterStageInteractionPolicy.acceptsReadingKeyCommands(
                readingAreaFocused: false,
                controlFocusInside: false,
                menuOrPopoverPresented: false
            )
        )
        #expect(
            !TeleprompterStageInteractionPolicy.acceptsReadingKeyCommands(
                readingAreaFocused: true,
                controlFocusInside: true,
                menuOrPopoverPresented: false
            )
        )
        #expect(
            !TeleprompterStageInteractionPolicy.acceptsReadingKeyCommands(
                readingAreaFocused: true,
                controlFocusInside: false,
                menuOrPopoverPresented: true
            )
        )
    }

    @Test("visibility policy exposes the exact delay contract")
    func visibilityTimingIsStable() {
        #expect(TeleprompterStageInteractionPolicy.initialRevealDuration == .seconds(2))
        #expect(TeleprompterStageInteractionPolicy.hideDelay == .milliseconds(250))
        #expect(TeleprompterStageInteractionPolicy.errorNoticeDuration == .seconds(4))
    }

    @Test("keyboard reveal ends when focus leaves the control layer")
    func keyboardRevealEndsWhenFocusLeaves() {
        var state = TeleprompterStageInteractionState()
        state.requestKeyboardReveal()
        state.setControlFocus(true)
        #expect(state.keyboardRevealRequested)

        state.setControlFocus(false)

        #expect(!state.keyboardRevealRequested)
    }

    @Test("keyboard reveal ends when the pointer leaves the stage")
    func keyboardRevealEndsWhenPointerLeaves() {
        var state = TeleprompterStageInteractionState()
        state.requestKeyboardReveal()

        state.setPointerInside(false)

        #expect(!state.keyboardRevealRequested)
    }
}
