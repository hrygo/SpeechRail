import Foundation
import Observation

@MainActor
public protocol SharedAudioPlaybackDriver: AnyObject {
    var isPlaying: Bool { get }
    var onPlaybackFinished: (@MainActor (Bool) -> Void)? { get set }
    var onProgress: (@MainActor (Double) -> Void)? { get set }
    var onLevel: (@MainActor (Float) -> Void)? { get set }
    func play(data: Data) throws
    func play(fileURL: URL, startAt: TimeInterval, rate: Float) throws
    func pause()
    func resume() throws
    func seek(to time: TimeInterval)
    func setRate(_ rate: Float)
    func stop()
    func duration(for data: Data) -> TimeInterval?
}

public extension SharedAudioPlaybackDriver {
    func play(fileURL: URL, startAt: TimeInterval, rate: Float) throws {
        throw AudioPlaybackError.playbackFailed
    }
    func pause() {
        stop()
    }
    func resume() throws {}
    func seek(to time: TimeInterval) {}
    func setRate(_ rate: Float) {}
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
    case audiobook(bookID: UUID, chapterRevisionID: UUID, fragmentID: UUID)
}

/// One player and one captured identity across all creator features.
@MainActor
@Observable
public final class SharedPlaybackOwner {
    public private(set) var target: PlaybackTarget?
    public private(set) var isPlaying = false
    public private(set) var progress: Double = 0
    public private(set) var level: Float = 0
    public private(set) var currentRate: Float = 1.0
    private let driver: any SharedAudioPlaybackDriver
    private var requestID = UUID()
    public func beginPlaybackRequest() -> UUID { requestID = UUID(); return requestID }
    public func isCurrentPlaybackRequest(_ id: UUID) -> Bool { requestID == id }
    private var token: UUID?
    @ObservationIgnored private let waveformLoader: WaveformEnvelopeLoader
    @ObservationIgnored private var waveformRequestID = UUID()
    private var visibleWaveform: (key: WaveformKey, levels: [CGFloat])?

    public init(driver: any SharedAudioPlaybackDriver = AudioPlaybackController(), waveformLoader: WaveformEnvelopeLoader = WaveformEnvelopeLoader()) {
        self.driver = driver
        self.waveformLoader = waveformLoader
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
        requestID: UUID? = nil,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) throws {
        guard requestID == nil || self.requestID == requestID else { return }
        if requestID == nil { self.requestID = UUID() }
        stopCurrentPlayback()
        let capturedToken = UUID()
        token = capturedToken
        self.target = target
        self.currentRate = 1.0
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

    public func play(
        fileURL: URL,
        startAt: TimeInterval = 0,
        rate: Float = 1.0,
        target: PlaybackTarget,
        requestID: UUID? = nil,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) throws {
        guard requestID == nil || self.requestID == requestID else { return }
        if requestID == nil { self.requestID = UUID() }
        stopCurrentPlayback()
        let capturedToken = UUID()
        token = capturedToken
        self.target = target
        let clampedRate = min(max(rate, AudiobookLimits.minPlaybackRate), AudiobookLimits.maxPlaybackRate)
        self.currentRate = clampedRate
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
            try driver.play(fileURL: fileURL, startAt: max(0, startAt), rate: clampedRate)
            isPlaying = driver.isPlaying
        } catch {
            clear()
            throw error
        }
    }

    public func pause() {
        guard token != nil else { return }
        driver.pause()
        isPlaying = driver.isPlaying
        level = 0
    }

    public func resume() throws {
        guard token != nil else { return }
        try driver.resume()
        isPlaying = driver.isPlaying
    }

    public func seek(to time: TimeInterval) {
        guard token != nil else { return }
        driver.seek(to: max(0, time))
    }

    public func setRate(_ rate: Float) {
        let clamped = min(max(rate, AudiobookLimits.minPlaybackRate), AudiobookLimits.maxPlaybackRate)
        currentRate = clamped
        guard token != nil else { return }
        driver.setRate(clamped)
    }

    public func stop() {
        requestID = UUID()
        stopCurrentPlayback()
    }

    private func stopCurrentPlayback() {
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
        visibleWaveform?.key.assetID == "\(kind):\(id)" ? visibleWaveform?.levels : nil
    }

    /// The view's .task owns this call and awaits physical cleanup on cancellation.
    /// Only one small UI projection is retained in addition to the loader's bounded LRU.
    public func prepareWaveform(key: WaveformKey, fileURL: URL) async {
        let request = UUID(); waveformRequestID = request
        visibleWaveform = nil
        let levels: [Double]
        switch await waveformLoader.acquire(key: key, fileURL: fileURL) {
        case let .ready(value): levels = value
        case let .pending(leaseID):
            do { levels = try await waveformLoader.result(leaseID: leaseID) }
            catch { await waveformLoader.release(leaseID: leaseID); return }
            await waveformLoader.release(leaseID: leaseID)
        case .deferred, .failed: return
        }
        guard !Task.isCancelled, waveformRequestID == request else { return }
        visibleWaveform = (key, levels.map { CGFloat($0) })
    }
}

/// Preserve the existing preview/render exclusion with a single admission owner.
@MainActor
@Observable
public final class SpeechCreationAdmission {
    public enum Owner: Sendable { case voice, dubbing, audiobook }
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
