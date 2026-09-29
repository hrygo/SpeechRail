import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterVoiceAssistLifecycleTests {
    @Test("voice starts off and follows the explicit start transition")
    func explicitStartTransition() throws {
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        #expect(lifecycle.state == .off)
        let startTokenValue = lifecycle.beginStart()
        let startToken = try #require(startTokenValue)
        #expect(lifecycle.state == .starting)
        #expect(lifecycle.isCurrent(startToken))
        let didFollow = lifecycle.markFollowing(token: startToken)
        #expect(didFollow)
        #expect(lifecycle.state == .following)
    }

    @Test("manual takeover immediately invalidates the old start token")
    func manualTakeoverInvalidatesStartingSession() throws {
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        let startTokenValue = lifecycle.beginStart()
        let startToken = try #require(startTokenValue)
        let stopTokenValue = lifecycle.beginStop(destination: .pausedByUser)
        let stopToken = try #require(stopTokenValue)

        #expect(lifecycle.state == .stopping)
        #expect(!lifecycle.isCurrent(startToken))
        let staleFollow = lifecycle.markFollowing(token: startToken)
        #expect(!staleFollow)
        #expect(lifecycle.isCurrent(stopToken))
        let didStop = lifecycle.markStopped(token: stopToken, failureReason: nil)
        #expect(didStop)
        #expect(lifecycle.state == .pausedByUser)
    }

    @Test("stop failure remains fail-closed and can be retried to the same destination")
    func failedStopRequiresExplicitRetry() throws {
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        let startTokenValue = lifecycle.beginStart()
        let startToken = try #require(startTokenValue)
        let didFollow = lifecycle.markFollowing(token: startToken)
        #expect(didFollow)
        let stopTokenValue = lifecycle.beginStop(destination: .off)
        let stopToken = try #require(stopTokenValue)

        let didFailStop = lifecycle.markStopped(token: stopToken, failureReason: "drain timed out")
        #expect(didFailStop)
        #expect(lifecycle.state == .stopFailed("drain timed out"))
        #expect(!lifecycle.canStart)
        #expect(lifecycle.pendingStopDestination == .off)

        let retryTokenValue = lifecycle.beginStop(destination: .off)
        let retryToken = try #require(retryTokenValue)
        let didRetryStop = lifecycle.markStopped(token: retryToken, failureReason: nil)
        #expect(didRetryStop)
        #expect(lifecycle.state == .off)
    }

    @Test("start failure does not become a hidden automatic retry")
    func failedStartIsUnavailableUntilUserStartsAgain() throws {
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        let tokenValue = lifecycle.beginStart()
        let token = try #require(tokenValue)
        let didFailStart = lifecycle.markStartFailed(token: token, reason: "service unavailable")
        #expect(didFailStart)
        #expect(lifecycle.state == .unavailable("service unavailable"))
        #expect(lifecycle.canStart)

        let retryValue = lifecycle.beginStart()
        let retry = try #require(retryValue)
        #expect(retry != token)
        #expect(lifecycle.state == .starting)
    }

    @Test("a connection from before a stop can no longer deliver voice events")
    func staleConnectionIsRejectedAfterStopAndRestart() throws {
        // This is the guard `upload` and `handle` both stand on: an audio chunk
        // or an ASR event carrying an older generation must not move the script.
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        let firstStartValue = lifecycle.beginStart()
        let firstStart = try #require(firstStartValue)
        let didFollow = lifecycle.markFollowing(token: firstStart)
        #expect(didFollow)
        let firstStopValue = lifecycle.beginStop(destination: .off)
        let firstStop = try #require(firstStopValue)
        let didStop = lifecycle.markStopped(token: firstStop, failureReason: nil)
        #expect(didStop)
        let secondStartValue = lifecycle.beginStart()
        let secondStart = try #require(secondStartValue)

        #expect(!lifecycle.acceptsVoiceEvents(token: firstStart))
        #expect(!lifecycle.acceptsVoiceEvents(token: firstStop))
        #expect(lifecycle.acceptsVoiceEvents(token: secondStart))
    }

    @Test("a device error mid-start cannot be overwritten by the start's own late callback")
    func lateStartCallbackCannotResurrectAFailedStart() throws {
        // `markUnavailable` deliberately leaves the generation alone, so the
        // start token is still current when the failure arrives. Only the state
        // check keeps a late `markFollowing` from putting the session back into
        // `.following` after the device has already been reported unavailable.
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        let tokenValue = lifecycle.beginStart()
        let token = try #require(tokenValue)
        let didMark = lifecycle.markUnavailable(reason: "麦克风被其他应用占用")
        #expect(didMark)

        let didFollow = lifecycle.markFollowing(token: token)
        #expect(!didFollow)
        #expect(lifecycle.state == .unavailable("麦克风被其他应用占用"))
    }

    @Test("a late start failure cannot knock a following session offline")
    func lateStartFailureCannotOverwriteAFollowingSession() throws {
        // `markFollowing` does not bump the generation, so the start token is
        // still current afterwards. A duplicate or retried failure callback
        // would otherwise take a healthy following session down.
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        let tokenValue = lifecycle.beginStart()
        let token = try #require(tokenValue)
        let didFollow = lifecycle.markFollowing(token: token)
        #expect(didFollow)

        let didFail = lifecycle.markStartFailed(token: token, reason: "late")
        #expect(!didFail)
        #expect(lifecycle.state == .following)
    }

    @Test("a repeated stop callback cannot move the reader's chosen destination")
    func duplicateStopCallbackCannotMoveTheDestination() throws {
        // `markStopped` does not bump the generation, so a duplicated drain
        // callback arrives with a still-current token. Without the state check
        // it would fall through to the `?? .off` default and silently turn the
        // reader's pause into a full stop.
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        let startValue = lifecycle.beginStart()
        let start = try #require(startValue)
        let didFollow = lifecycle.markFollowing(token: start)
        #expect(didFollow)
        let stopValue = lifecycle.beginStop(destination: .pausedByUser)
        let stop = try #require(stopValue)
        let didStop = lifecycle.markStopped(token: stop, failureReason: nil)
        #expect(didStop)
        #expect(lifecycle.state == .pausedByUser)

        let repeated = lifecycle.markStopped(token: stop, failureReason: nil)
        #expect(!repeated)
        #expect(lifecycle.state == .pausedByUser)
    }

    @Test("a stop failure with no reason is still a failure")
    func emptyStopFailureReasonIsNotRecordedAsSuccess() throws {
        // The session shows `.stopFailed` with a fixed message and never shows
        // the reason text, so keeping the failure costs the reader nothing --
        // whereas recording an empty reason as a clean stop would tell them the
        // microphone was released when it may not have been.
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        let startValue = lifecycle.beginStart()
        let start = try #require(startValue)
        let didFollow = lifecycle.markFollowing(token: start)
        #expect(didFollow)
        let stopValue = lifecycle.beginStop(destination: .off)
        let stop = try #require(stopValue)

        let didFail = lifecycle.markStopped(token: stop, failureReason: "")
        #expect(didFail)
        #expect(lifecycle.state == .stopFailed(""))
        #expect(!lifecycle.canStart)
    }

    @Test("a device error during a stop does not abandon the stop")
    func deviceErrorDuringStopKeepsTheStopInFlight() throws {
        // `markUnavailable` carries no cleanup contract, unlike
        // `invalidateAfterFailure` where the caller releases resources itself.
        // Letting it overwrite `.stopping` would drop the pending destination
        // and leave the in-flight stop callback unable to complete.
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        let startValue = lifecycle.beginStart()
        let start = try #require(startValue)
        let didFollow = lifecycle.markFollowing(token: start)
        #expect(didFollow)
        let stopValue = lifecycle.beginStop(destination: .off)
        let stop = try #require(stopValue)

        let didMark = lifecycle.markUnavailable(reason: "设备断开")
        #expect(!didMark)
        #expect(lifecycle.state == .stopping)
        #expect(lifecycle.pendingStopDestination == .off)
        let didStop = lifecycle.markStopped(token: stop, failureReason: nil)
        #expect(didStop)
        #expect(lifecycle.state == .off)
    }

    @Test("both transitions in flight report busy, and a paused session can start again")
    func busyCoversStopAndPauseRemainsStartable() throws {
        var lifecycle = TeleprompterVoiceAssistLifecycle()
        #expect(!lifecycle.state.isBusy)

        let startValue = lifecycle.beginStart()
        let start = try #require(startValue)
        #expect(lifecycle.state.isBusy)
        let didFollow = lifecycle.markFollowing(token: start)
        #expect(didFollow)
        #expect(!lifecycle.state.isBusy)

        let stopValue = lifecycle.beginStop(destination: .pausedByUser)
        let stop = try #require(stopValue)
        #expect(lifecycle.state.isBusy)
        let didStop = lifecycle.markStopped(token: stop, failureReason: nil)
        #expect(didStop)
        #expect(!lifecycle.state.isBusy)

        #expect(lifecycle.state == .pausedByUser)
        #expect(lifecycle.canStart)
        let restarted = lifecycle.beginStart()
        #expect(restarted != nil)
        #expect(!lifecycle.canStart)
    }
}
