import Foundation

/// User-visible lifecycle for the optional voice-following feature.
///
/// Reading position and voice assistance deliberately have separate owners:
/// moving in the script is always legal, while audio capture only follows an
/// explicit start request and a current generation token.
public enum TeleprompterVoiceAssistState: Equatable, Sendable {
    case off
    case starting
    case following
    case stopping
    case stopFailed(String)
    case pausedByUser
    case unavailable(String)

    public var canStart: Bool {
        switch self {
        case .off, .pausedByUser, .unavailable:
            true
        case .starting, .following, .stopping, .stopFailed:
            false
        }
    }

    public var isFollowing: Bool {
        self == .following
    }

    public var isBusy: Bool {
        self == .starting || self == .stopping
    }
}

/// Pure generation and state reducer for voice assistance.
///
/// Every asynchronous operation receives the generation captured at its
/// transition point. A manual takeover changes that generation synchronously,
/// so callbacks from an older connection cannot move the script or overwrite
/// the new state.
public struct TeleprompterVoiceAssistLifecycle: Sendable {
    public private(set) var state: TeleprompterVoiceAssistState
    public private(set) var generation: UUID
    public private(set) var pendingStopDestination: TeleprompterVoiceAssistState?

    public init() {
        state = .off
        generation = UUID()
        pendingStopDestination = nil
    }

    public var canStart: Bool {
        state.canStart
    }

    public func isCurrent(_ token: UUID) -> Bool {
        token == generation
    }

    public mutating func beginStart() -> UUID? {
        guard state.canStart else { return nil }
        generation = UUID()
        pendingStopDestination = nil
        state = .starting
        return generation
    }

    @discardableResult
    public mutating func markFollowing(token: UUID) -> Bool {
        guard isCurrent(token), state == .starting else { return false }
        state = .following
        pendingStopDestination = nil
        return true
    }

    public mutating func beginStop(
        destination: TeleprompterVoiceAssistState
    ) -> UUID? {
        switch state {
        case .starting, .following, .stopFailed:
            generation = UUID()
            pendingStopDestination = destination
            state = .stopping
            return generation
        case .off, .stopping, .pausedByUser, .unavailable:
            return nil
        }
    }

    @discardableResult
    public mutating func markStopped(
        token: UUID,
        failureReason: String?
    ) -> Bool {
        guard isCurrent(token), state == .stopping else { return false }
        if let failureReason, !failureReason.isEmpty {
            state = .stopFailed(failureReason)
            return true
        }
        state = pendingStopDestination ?? .off
        pendingStopDestination = nil
        return true
    }

    @discardableResult
    public mutating func markStartFailed(
        token: UUID,
        reason: String
    ) -> Bool {
        guard isCurrent(token), state == .starting else { return false }
        pendingStopDestination = nil
        state = .unavailable(reason)
        return true
    }

    /// Used after a transport failure has already invalidated the connection.
    /// The caller performs its own best-effort resource cleanup and then calls
    /// this method so no late callback can revive the failed session.
    @discardableResult
    public mutating func invalidateAfterFailure(
        reason: String
    ) -> UUID {
        generation = UUID()
        pendingStopDestination = nil
        state = .unavailable(reason)
        return generation
    }

    @discardableResult
    public mutating func resetToOff() -> UUID {
        generation = UUID()
        pendingStopDestination = nil
        state = .off
        return generation
    }

    @discardableResult
    public mutating func markUnavailable(reason: String) -> Bool {
        guard state != .stopping else { return false }
        pendingStopDestination = nil
        state = .unavailable(reason)
        return true
    }

    public func acceptsVoiceEvents(token: UUID) -> Bool {
        isCurrent(token) && (state == .starting || state == .following)
    }
}
