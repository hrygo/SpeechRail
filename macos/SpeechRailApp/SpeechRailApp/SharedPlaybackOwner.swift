import Foundation
import Observation

@MainActor
public protocol SharedAudioPlaybackDriver: AnyObject {
    var isPlaying: Bool { get }
    var onPlaybackFinished: (@MainActor (Bool) -> Void)? { get set }
    var onProgress: (@MainActor (Double) -> Void)? { get set }
    var onLevel: (@MainActor (Float) -> Void)? { get set }
    func play(data: Data) throws
    func stop()
    func duration(for data: Data) -> TimeInterval?
}

extension AudioPlaybackController: SharedAudioPlaybackDriver {}

public enum PlaybackTarget: Equatable, Sendable {
    case generic
    case voice(String)
    case work(String)
    case dubbingCandidate(String)
    case pendingDubbing(String)
    case designReference(candidateID: String, revision: String)
    case designValidation(candidateID: String, revision: String, validationID: String)
}

/// One player and one captured identity across all creator features.
@MainActor
@Observable
public final class SharedPlaybackOwner {
    public private(set) var target: PlaybackTarget?
    public private(set) var isPlaying = false
    public private(set) var progress: Double = 0
    public private(set) var level: Float = 0
    private let driver: any SharedAudioPlaybackDriver
    private var token: UUID?
    private var waveformEnvelopes: [String: [CGFloat]] = [:]

    public init(driver: any SharedAudioPlaybackDriver = AudioPlaybackController()) {
        self.driver = driver
    }

    public var playingWorkID: String? {
        if case let .work(id) = target { return id }
        return nil
    }

    public var playingVoiceID: String? {
        if case let .voice(id) = target { return id }
        return nil
    }

    public var playingDubbingCandidateID: String? {
        if case let .dubbingCandidate(id) = target { return id }
        return nil
    }

    public func play(
        data: Data,
        target: PlaybackTarget,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) throws {
        stop()
        let capturedToken = UUID()
        token = capturedToken
        self.target = target
        driver.onPlaybackFinished = { [weak self] success in
            guard let self, self.token == capturedToken else { return }
            self.clear()
            completion(success)
        }
        driver.onProgress = { [weak self] progress in
            guard let self, self.token == capturedToken else { return }
            self.progress = progress
        }
        driver.onLevel = { [weak self] level in
            guard let self, self.token == capturedToken else { return }
            self.level = level
        }
        do {
            try driver.play(data: data)
            isPlaying = driver.isPlaying
        } catch {
            clear()
            throw error
        }
    }

    public func stop() {
        // Revoke identity before stop can emit callbacks.
        clear()
        driver.stop()
    }

    public func stop(ifTarget expected: PlaybackTarget) {
        guard target == expected else { return }
        stop()
    }

    public func duration(for data: Data) -> TimeInterval? {
        driver.duration(for: data)
    }

    private func clear() {
        token = nil
        target = nil
        isPlaying = false
        progress = 0
        level = 0
    }

    public func waveformEnvelope(kind: String, id: String) -> [CGFloat]? {
        waveformEnvelopes["\(kind):\(id)"]
    }

    func waveformEnvelope(key: String) -> [CGFloat]? {
        waveformEnvelopes[key]
    }

    public func cacheEnvelope(
        kind: String,
        id: String,
        compute: @escaping @Sendable (Int) -> [CGFloat]?
    ) {
        cacheEnvelope(key: "\(kind):\(id)", compute: compute)
    }

    func cacheEnvelope(
        key: String,
        compute: @escaping @Sendable (Int) -> [CGFloat]?
    ) {
        guard waveformEnvelopes[key] == nil else { return }
        let buckets = SpeechRailDesignTokens.Waveform.envelopeBuckets
        Task.detached(priority: .utility) { [weak self] in
            guard let levels = compute(buckets) else { return }
            await MainActor.run { self?.waveformEnvelopes[key] = levels }
        }
    }
}

/// Preserve the existing preview/render exclusion with a single admission owner.
@MainActor
@Observable
public final class SpeechCreationAdmission {
    public enum Owner: Sendable { case voice, dubbing }
    public private(set) var owner: Owner?
    public var isBusy: Bool { owner != nil }

    public init() {}

    public func acquire(_ requester: Owner) -> Bool {
        guard owner == nil else { return false }
        owner = requester
        return true
    }

    public func release(_ requester: Owner) {
        guard owner == requester else { return }
        owner = nil
    }
}

/// A single creator banner is shared by the existing surfaces.
@MainActor
@Observable
public final class CreatorFeedback {
    public private(set) var message: String?
    public init() {}
    func publish(_ message: String?) { self.message = message }
}
