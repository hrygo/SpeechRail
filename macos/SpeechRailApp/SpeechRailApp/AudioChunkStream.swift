import Foundation
import Synchronization

public struct AudioCaptureStamp: Sendable, Equatable {
    public let captureEpoch: UUID
    public let sourceID: UUID
    public let sourceSequence: UInt64
    public let capturedUptimeNanoseconds: UInt64
    public init(captureEpoch: UUID, sourceID: UUID, sourceSequence: UInt64, capturedUptimeNanoseconds: UInt64) {
        self.captureEpoch = captureEpoch
        self.sourceID = sourceID
        self.sourceSequence = sourceSequence
        self.capturedUptimeNanoseconds = capturedUptimeNanoseconds
    }

    /// Map the recorded source uptime into the legacy diagnostic clock; never stamp drain time as capture time.
    var capturedInstant: ContinuousClock.Instant? {
        let current = DispatchTime.now().uptimeNanoseconds
        guard current >= capturedUptimeNanoseconds, current - capturedUptimeNanoseconds <= UInt64(Int64.max) else { return nil }
        return ContinuousClock.now - .nanoseconds(Int64(current - capturedUptimeNanoseconds))
    }
}

public struct AudioSourceWatermark: Sendable, Equatable {
    public let captureEpoch: UUID
    public let sourceID: UUID
    public let sourceSequence: UInt64
    public let droppedSamplesBefore: UInt64
    public init(captureEpoch: UUID, sourceID: UUID, sourceSequence: UInt64, droppedSamplesBefore: UInt64) {
        self.captureEpoch = captureEpoch
        self.sourceID = sourceID
        self.sourceSequence = sourceSequence
        self.droppedSamplesBefore = droppedSamplesBefore
    }
}

/// 一块下游要用的音频：24 kHz / 单声道 / PCM16，外加这一块的真实电平（0…1）。
public struct AudioChunk: Sendable {
    public var pcm: Data
    public var level: Double
    /// Optional source-side evidence. File/tap test sources may omit it.
    public var capturedAt: ContinuousClock.Instant?
    /// M3/V08:来源侧块序号（单调递增）。uploader 据此发现 `bufferingNewest`
    /// 替换掉的块——序号跳跃即丢块证据，残缺语音不得当成完整意图回答。
    /// 旧调用点不填时为 nil：表示"无序号证据"，不得当成"序号连续"。
    public var sequenceNumber: Int?
    /// M3/V08:本块之前来源侧累计丢弃的样本数快照（ring 满等原因）。
    /// uploader 对比相邻两块的快照差即可得到块间丢样数，无需跨线程读 ring。
    public var droppedSamplesBefore: Int?
    public var captureStamp: AudioCaptureStamp?
    public var sourceWatermarks: [AudioSourceWatermark]

    public init(
        pcm: Data,
        level: Double,
        capturedAt: ContinuousClock.Instant? = nil,
        sequenceNumber: Int? = nil,
        droppedSamplesBefore: Int? = nil,
        captureStamp: AudioCaptureStamp? = nil,
        sourceWatermarks: [AudioSourceWatermark] = []
    ) {
        self.pcm = pcm
        self.level = level
        self.capturedAt = capturedAt
        self.sequenceNumber = sequenceNumber
        self.droppedSamplesBefore = droppedSamplesBefore
        self.captureStamp = captureStamp
        self.sourceWatermarks = sourceWatermarks
    }

    public func muted() -> AudioChunk {
        var result = self
        result.pcm = Data(count: pcm.count)
        result.level = 0
        return result
    }
}

public enum AudioOfferResult: Sendable, Equatable { case accepted, closed, overflow }
public enum AudioStreamTermination: String, Sendable, Equatable, Codable { case completed, cancelled, overflow, staleInput, sourceLost, droppedSamples }

/// Contains only identities and numeric discontinuity evidence, never PCM or transcript text.
public struct AudioStreamError: Error, LocalizedError, Sendable, Equatable, Codable {
    public let reason: AudioStreamTermination
    public let captureEpoch: UUID?
    public let sourceID: UUID?
    public let expectedSequence: UInt64?
    public let receivedSequence: UInt64?
    public let droppedSamples: UInt64?
    public init(reason: AudioStreamTermination, captureEpoch: UUID? = nil, sourceID: UUID? = nil,
                expectedSequence: UInt64? = nil, receivedSequence: UInt64? = nil, droppedSamples: UInt64? = nil) {
        self.reason = reason
        self.captureEpoch = captureEpoch
        self.sourceID = sourceID
        self.expectedSequence = expectedSequence
        self.receivedSequence = receivedSequence
        self.droppedSamples = droppedSamples
    }
    public var errorDescription: String? {
        switch reason {
        case .completed: "音频输入已结束。"
        case .cancelled: "音频采集已取消。"
        case .overflow: "音频处理未能跟上采集，输入已中断；已保存文字仍保留。"
        case .staleInput: "音频等待时间过长，输入已中断；请重新开始采集。"
        case .sourceLost: "音频来源已中断。"
        case .droppedSamples: "音频有缺失，输入已中断；这段内容尚未完整识别。"
        }
    }
}

public struct AudioStreamLimits: Sendable {
    public let maxBytes: Int
    public let maxChunks: Int
    public let maxAgeNanoseconds: UInt64
    public init(maxBytes: Int = 24_000, maxChunks: Int = 16, maxAgeNanoseconds: UInt64 = 750_000_000) {
        precondition(maxBytes > 0 && maxChunks > 0)
        self.maxBytes = maxBytes; self.maxChunks = maxChunks; self.maxAgeNanoseconds = maxAgeNanoseconds
    }
    public static let source = AudioStreamLimits()
    public static let mixerOutput = AudioStreamLimits(maxBytes: 19_200, maxChunks: 10)
}

public struct AudioStreamSnapshot: Sendable {
    public let queuedBytes: Int
    public let queuedChunks: Int
    public let peakQueuedBytes: Int
    public let peakQueuedChunks: Int
    public let waitingConsumers: Int
    public let sourceContinuityKnown: Bool
    public let termination: AudioStreamTermination?
}

/// Single-consumer pulling stream. Transformations share the source queue and add no buffering Task.
public struct AudioChunkStream: AsyncSequence, Sendable {
    public typealias Element = AudioChunk
    private let pull: @Sendable () async throws -> AudioChunk?
    private let inspect: @Sendable () -> AudioStreamSnapshot
    public var snapshot: AudioStreamSnapshot { inspect() }
    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        fileprivate let pull: @Sendable () async throws -> AudioChunk?
        public mutating func next() async throws -> AudioChunk? { try await pull() }
    }
    public struct Continuation: Sendable {
        fileprivate let core: AudioChannelCore
        @discardableResult public func offer(_ chunk: AudioChunk) -> AudioOfferResult { core.offer(chunk) }
        public func finish(_ reason: AudioStreamTermination = .completed) { core.finish(reason) }
        public func finish(_ error: AudioStreamError) { core.finish(error) }
    }
    public func makeAsyncIterator() -> AsyncIterator { .init(pull: pull) }

    public static func makeStream(
        epoch: UUID? = nil, sourceID: UUID? = nil, limits: AudioStreamLimits = .source,
        now: @Sendable @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        onDequeue: (@Sendable (AudioChunk) -> Void)? = nil,
        onTermination: (@Sendable (AudioStreamTermination) -> Void)? = nil
    ) -> (stream: AudioChunkStream, continuation: Continuation) {
        let core = AudioChannelCore(epoch: epoch, sourceID: sourceID, limits: limits, now: now, onDequeue: onDequeue, onTermination: onTermination)
        return (.init(pull: { try await core.next() }, inspect: { core.snapshot }), .init(core: core))
    }

    public func mapChunks(_ transform: @Sendable @escaping (AudioChunk) async throws -> AudioChunk) -> AudioChunkStream {
        .init(pull: {
            guard let chunk = try await pull() else { return nil }
            return try await transform(chunk)
        }, inspect: inspect)
    }

    public func observingCompletion(_ observer: @Sendable @escaping (AudioStreamTermination) async -> Void) -> AudioChunkStream {
        let notified = Mutex(false)
        let notify: @Sendable (AudioStreamTermination) async -> Void = { reason in
            let first = notified.withLock { value in if value { return false }; value = true; return true }
            if first { await observer(reason) }
        }
        return .init(pull: {
            do {
                let chunk = try await pull()
                if chunk == nil { await notify(.completed) }
                return chunk
            } catch {
                let reason = (error as? AudioStreamError)?.reason ?? (error is CancellationError ? .cancelled : .sourceLost)
                await notify(reason)
                throw error
            }
        }, inspect: inspect)
    }
}

fileprivate final class AudioChannelCore: Sendable {
    private typealias Waiter = CheckedContinuation<AudioChunk?, any Error>
    private struct State {
        var entries: [AudioChunk?]
        var head = 0, count = 0, bytes = 0, peakBytes = 0, peakCount = 0
        var epoch: UUID?, sourceID: UUID?, lastSequence: UInt64?
        var unknownEvidence = false, continuityKnown = false
        var termination: AudioStreamTermination?
        var error: AudioStreamError?
        var waiter: Waiter?
    }
    private let state: Mutex<State>
    private let limits: AudioStreamLimits
    private let now: @Sendable () -> UInt64
    private let onDequeue: (@Sendable (AudioChunk) -> Void)?
    private let onTermination: (@Sendable (AudioStreamTermination) -> Void)?

    init(epoch: UUID?, sourceID: UUID?, limits: AudioStreamLimits, now: @Sendable @escaping () -> UInt64,
         onDequeue: (@Sendable (AudioChunk) -> Void)?, onTermination: (@Sendable (AudioStreamTermination) -> Void)?) {
        self.limits = limits; self.now = now; self.onDequeue = onDequeue; self.onTermination = onTermination
        state = Mutex(State(entries: Array(repeating: nil, count: limits.maxChunks), epoch: epoch, sourceID: sourceID))
    }

    var snapshot: AudioStreamSnapshot {
        state.withLock { .init(queuedBytes: $0.bytes, queuedChunks: $0.count, peakQueuedBytes: $0.peakBytes,
            peakQueuedChunks: $0.peakCount, waitingConsumers: $0.waiter == nil ? 0 : 1,
            sourceContinuityKnown: $0.continuityKnown, termination: $0.termination) }
    }

    func offer(_ chunk: AudioChunk) -> AudioOfferResult {
        var recipient: Waiter?
        var failure: AudioStreamError?
        let result: AudioOfferResult = state.withLock { state in
            guard state.termination == nil else { return .closed }
            if let stamp = chunk.captureStamp {
                if let epoch = state.epoch, epoch != stamp.captureEpoch { return .closed }
                if let source = state.sourceID, source != stamp.sourceID { return .closed }
                state.epoch = stamp.captureEpoch; state.sourceID = stamp.sourceID
            }
            let sequence = chunk.captureStamp?.sourceSequence ?? chunk.sequenceNumber.flatMap(UInt64.init(exactly:))
            let dropped = chunk.droppedSamplesBefore.flatMap(UInt64.init(exactly:))
            let expected = state.lastSequence.flatMap { $0 == UInt64.max ? nil : $0 + 1 }
            let invalidSequence = state.lastSequence != nil && sequence != nil && sequence != expected
            let watermarkDrop = chunk.sourceWatermarks.prefix(2).reduce(UInt64(0)) { max($0, $1.droppedSamplesBefore) }
            let invalidDrop = (dropped ?? 0) > 0 || watermarkDrop > 0 || (chunk.droppedSamplesBefore ?? 0) < 0
            let invalidMetadata = chunk.sourceWatermarks.count > 2
                || (chunk.sourceWatermarks.count == 2 && chunk.sourceWatermarks[0].sourceID == chunk.sourceWatermarks[1].sourceID)
            let reason: AudioStreamTermination?
            if isStale(chunk) { reason = .staleInput }
            else if invalidMetadata { reason = .sourceLost }
            else if invalidSequence || invalidDrop || (chunk.sequenceNumber ?? 0) < 0 { reason = .droppedSamples }
            else if chunk.pcm.count > limits.maxBytes - state.bytes || state.count == limits.maxChunks { reason = .overflow }
            else { reason = nil }
            if let reason {
                let error = AudioStreamError(reason: reason, captureEpoch: chunk.captureStamp?.captureEpoch ?? state.epoch,
                    sourceID: chunk.captureStamp?.sourceID ?? state.sourceID, expectedSequence: expected,
                    receivedSequence: sequence, droppedSamples: max(dropped ?? 0, watermarkDrop))
                failure = error
                recipient = Self.close(&state, reason: reason, error: error)
                return reason == .overflow ? .overflow : .closed
            }
            if sequence == nil || chunk.captureStamp == nil { state.unknownEvidence = true }
            state.continuityKnown = !state.unknownEvidence && state.lastSequence != nil && sequence == expected
            state.lastSequence = sequence
            if let waiter = state.waiter {
                state.waiter = nil
                recipient = waiter
            } else {
                state.entries[(state.head + state.count) % state.entries.count] = chunk
                state.count += 1; state.bytes += chunk.pcm.count
                state.peakBytes = max(state.peakBytes, state.bytes); state.peakCount = max(state.peakCount, state.count)
            }
            return .accepted
        }
        if let failure {
            recipient?.resume(throwing: failure)
            onTermination?(failure.reason)
        } else if let recipient { recipient.resume(returning: chunk) }
        return result
    }

    func finish(_ reason: AudioStreamTermination) { complete(reason, evidence: nil) }
    func finish(_ error: AudioStreamError) { complete(error.reason, evidence: error) }

    private func complete(_ reason: AudioStreamTermination, evidence: AudioStreamError?) {
        var recipient: Waiter?
        var failure: AudioStreamError?
        var notify = false
        let changed = state.withLock { state -> Bool in
            guard state.termination == nil || (state.termination == .completed && reason == .cancelled) else { return false }
            if let epoch = evidence?.captureEpoch, let current = state.epoch, epoch != current { return false }
            if let source = evidence?.sourceID, let current = state.sourceID, source != current { return false }
            let error = AudioStreamError(reason: reason, captureEpoch: evidence?.captureEpoch ?? state.epoch,
                sourceID: evidence?.sourceID ?? state.sourceID, expectedSequence: evidence?.expectedSequence,
                receivedSequence: evidence?.receivedSequence, droppedSamples: evidence?.droppedSamples)
            failure = error
            notify = state.termination == nil
            recipient = Self.close(&state, reason: reason, error: reason == .completed || reason == .cancelled ? nil : error)
            return true
        }
        if changed {
            if let recipient {
                if reason == .completed { recipient.resume(returning: nil) }
                else if reason == .cancelled { recipient.resume(throwing: CancellationError()) }
                else { recipient.resume(throwing: failure ?? AudioStreamError(reason: reason)) }
            }
            if notify { onTermination?(reason) }
        }
    }

    private static func close(_ state: inout State, reason: AudioStreamTermination, error: AudioStreamError?) -> Waiter? {
        state.termination = reason; state.error = error
        if reason != .completed {
            for index in state.entries.indices { state.entries[index] = nil }
            state.head = 0; state.count = 0; state.bytes = 0
        }
        defer { state.waiter = nil }
        return state.waiter
    }

    func next() async throws -> AudioChunk? {
        let chunk: AudioChunk? = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var value: AudioChunk?
                var error: (any Error)?
                let wait = state.withLock { state -> Bool in
                    if let failure = state.error { error = failure; return false }
                    if state.termination == .cancelled { error = CancellationError(); return false }
                    if state.count > 0 {
                        value = state.entries[state.head]; state.entries[state.head] = nil
                        state.head = (state.head + 1) % state.entries.count; state.count -= 1
                        state.bytes -= value?.pcm.count ?? 0
                        return false
                    }
                    if state.termination == .completed { return false }
                    if state.waiter != nil {
                        error = AudioStreamError(reason: .sourceLost, captureEpoch: state.epoch, sourceID: state.sourceID)
                        return false
                    }
                    state.waiter = continuation
                    return true
                }
                if !wait {
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value) }
                }
            }
        } onCancel: { self.finish(.cancelled) }
        try Task.checkCancellation()
        if let chunk {
            if isStale(chunk) {
                finish(.staleInput)
                throw AudioStreamError(reason: .staleInput, captureEpoch: chunk.captureStamp?.captureEpoch,
                    sourceID: chunk.captureStamp?.sourceID)
            }
            onDequeue?(chunk)
        }
        return chunk
    }

    private func isStale(_ chunk: AudioChunk) -> Bool {
        if let stamp = chunk.captureStamp {
            let now = now()
            return now < stamp.capturedUptimeNanoseconds || now - stamp.capturedUptimeNanoseconds > limits.maxAgeNanoseconds
        }
        if let capturedAt = chunk.capturedAt { return capturedAt.duration(to: .now) > .milliseconds(750) }
        return false
    }
}
