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
}
