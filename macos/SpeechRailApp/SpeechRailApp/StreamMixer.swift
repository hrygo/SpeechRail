import Foundation
import os

/// Two stable input slots. Reconnection joins the retired reader before replacing its slot.
actor StreamMixer {
    private static let diagnostics = Logger(subsystem: "com.speechrail.desktop", category: "AudioCapture")
    struct Snapshot: Sendable {
        var level: Double
        var gaps: Int
        var allocatedSlots: Int
        var activeSlots: Int
        var activeTasks: Int
        var queuedBytes: Int
        var tickCount: UInt64
        var nextTickUptimeNanoseconds: UInt64?
    }
    private struct InputRing {
        var entries = [AudioChunk?](repeating: nil, count: 16)
        var head = 0, count = 0, offset = 0, bytes = 0
        mutating func append(_ chunk: AudioChunk) -> Bool {
            guard chunk.pcm.count.isMultiple(of: 2), chunk.pcm.count <= 19_200 else { return false }
            guard !chunk.pcm.isEmpty else { return true }
            while count > 0 && (count >= entries.count || chunk.pcm.count > 19_200 - bytes) {
                if let old = entries[head] {
                    bytes -= (old.pcm.count - offset)
                }
                entries[head] = nil
                head = (head + 1) % entries.count
                count -= 1
                offset = 0
            }
            guard count < entries.count, chunk.pcm.count <= 19_200 - bytes else { return false }
            entries[(head + count) % entries.count] = chunk
            count += 1; bytes += chunk.pcm.count
            return true
        }
        mutating func take(into mixed: inout [Int32], now: UInt64) throws -> (AudioCaptureStamp?, ContinuousClock.Instant?, AudioSourceWatermark?) {
            var position = 0
            var oldestStamp: AudioCaptureStamp?, oldestInstant: ContinuousClock.Instant?, watermark: AudioSourceWatermark?
            while position < mixed.count, let chunk = entries[head] {
                if let stamp = chunk.captureStamp {
                    if now < stamp.capturedUptimeNanoseconds || now - stamp.capturedUptimeNanoseconds > 750_000_000 {
                        entries[head] = nil
                        head = (head + 1) % entries.count
                        count -= 1
                        bytes -= (chunk.pcm.count - offset)
                        offset = 0
                        continue
                    }
                    if oldestStamp == nil { oldestStamp = stamp }
                    watermark = .init(captureEpoch: stamp.captureEpoch, sourceID: stamp.sourceID,
                        sourceSequence: stamp.sourceSequence, droppedSamplesBefore: UInt64(max(0, chunk.droppedSamplesBefore ?? 0)))
                }
                if let capturedAt = chunk.capturedAt {
                    if capturedAt.duration(to: .now) > .milliseconds(750) {
                        entries[head] = nil
                        head = (head + 1) % entries.count
                        count -= 1
                        bytes -= (chunk.pcm.count - offset)
                        offset = 0
                        continue
                    }
                    if oldestInstant == nil { oldestInstant = capturedAt }
                }
                let take = min((chunk.pcm.count - offset) / 2, mixed.count - position)
                chunk.pcm.withUnsafeBytes { raw in
                    for index in 0..<take {
                        let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + index * 2, as: Int16.self))
                        mixed[position + index] += Int32(sample)
                    }
                }
                position += take; offset += take * 2; bytes -= take * 2
                if offset == chunk.pcm.count {
                    entries[head] = nil; head = (head + 1) % entries.count; count -= 1; offset = 0
                }
            }
            return (oldestStamp, oldestInstant, watermark)
        }
        mutating func clear() { self = .init() }
    }
    private struct Slot {
        var generation = UUID()
        var active = false, replacing = false, completed = false, running = false
        var ring = InputRing()
        var task: Task<Void, Never>?
    }
    private var slots: [UUID: Slot] = [:]
    private let automaticTicks: Bool
    private let now: @Sendable () -> UInt64
    private let sleepUntil: @Sendable (UInt64) async throws -> Void
    private let metrics: AppPerformanceMetrics
    private let epoch = UUID(), outputID = UUID()
    private var output: AudioChunkStream?
    private var continuation: AudioChunkStream.Continuation?
    private var ticker: Task<Void, Never>?
    private var stopped = false, draining = false
    private var level = 0.0, gaps = 0
    private var sequence: UInt64 = 0, ticks: UInt64 = 0
    private var nextTick: UInt64?

    init(automaticTicks: Bool = true,
         now: @Sendable @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         sleepUntil: @Sendable @escaping (UInt64) async throws -> Void = { deadline in
             let current = DispatchTime.now().uptimeNanoseconds
             if deadline > current { try await Task.sleep(for: .nanoseconds(Int64(min(deadline - current, UInt64(Int64.max))))) }
         }, metrics: AppPerformanceMetrics = .shared) {
        self.automaticTicks = automaticTicks; self.now = now; self.sleepUntil = sleepUntil; self.metrics = metrics
    }

    func start() -> AudioChunkStream {
        if let output { return output }
        let pair = AudioChunkStream.makeStream(epoch: epoch, sourceID: outputID, limits: .mixerOutput, now: now)
        output = pair.stream; continuation = pair.continuation
        if stopped { pair.continuation.finish(.cancelled); return pair.stream }
        if automaticTicks {
            ticker = Task { [weak self, now, sleepUntil] in
                var deadline = now()
                while !Task.isCancelled {
                    guard let next = await self?.scheduledTick(deadline: deadline) else { return }
                    deadline = next
                    do { try await sleepUntil(deadline) }
                    catch { return }
                }
            }
        }
        return pair.stream
    }

    private func scheduledTick(deadline: UInt64) -> UInt64 {
        tick(at: now())
        // Keep one time base: a small late wake must not slow the PCM clock.
        // After a large stall skip expired deadlines instead of replaying ticks.
        let current = now(), period: UInt64 = 40_000_000
        let elapsed = current >= deadline ? current - deadline : 0
        let intervals = elapsed / period + 1
        let next = deadline.addingReportingOverflow(intervals * period)
        nextTick = next.overflow ? UInt64.max : next.partialValue
        return nextTick!
    }

    func attach(sourceID: UUID, stream: AudioChunkStream) async throws {
        guard !stopped, continuation != nil else { throw AudioStreamError(reason: .cancelled) }
        guard slots[sourceID] != nil || slots.count < 2, slots[sourceID]?.replacing != true else {
            throw AudioStreamError(reason: .sourceLost, sourceID: sourceID)
        }
        if slots[sourceID] != nil { await retire(sourceID: sourceID) }
        guard !stopped else { throw AudioStreamError(reason: .cancelled) }
        var slot = Slot(); slot.active = true; slot.running = true
        let generation = slot.generation
        slot.task = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard !Task.isCancelled, await self?.ingest(sourceID: sourceID, generation: generation, chunk: chunk) == true else { break }
                }
                await self?.ended(sourceID: sourceID, generation: generation, reason: .completed)
            } catch {
                let reason = (error as? AudioStreamError)?.reason ?? (error is CancellationError ? .cancelled : .sourceLost)
                await self?.ended(sourceID: sourceID, generation: generation, reason: reason)
            }
        }
        slots[sourceID] = slot
    }

    func retire(sourceID: UUID) async {
        guard var slot = slots[sourceID] else { return }
        let generation = slot.generation, task = slot.task
        slot.active = false; slot.replacing = true; slot.ring.clear()
        slots[sourceID] = slot
        task?.cancel(); await task?.value
        if slots[sourceID]?.generation == generation {
            slots[sourceID]?.task = nil; slots[sourceID]?.replacing = false
        }
    }

    func stop(drainPending: Bool = false) async {
        stopped = true; draining = drainPending
        let ticker = self.ticker, readers = slots.values.compactMap(\.task)
        ticker?.cancel()
        if !drainPending { for task in readers { task.cancel() }; continuation?.finish(.cancelled) }
        await ticker?.value
        for task in readers { await task.value }
        if drainPending {
            while let largest = slots.values.map({ $0.ring.bytes }).max(), largest > 0,
                  output?.snapshot.termination == nil {
                tick(at: now(), whileStopping: true, frames: min(960, largest / 2))
                await Task.yield()
            }
            continuation?.finish(.completed)
        }
        self.ticker = nil; continuation = nil; slots.removeAll(); draining = false; nextTick = nil; level = 0
    }

    func snapshot() -> Snapshot {
        .init(level: level, gaps: gaps, allocatedSlots: slots.count, activeSlots: slots.values.filter(\.active).count,
              activeTasks: slots.values.filter(\.running).count + (ticker == nil ? 0 : 1),
              queuedBytes: slots.values.reduce(0) { $0 + $1.ring.bytes } + (output?.snapshot.queuedBytes ?? 0),
              tickCount: ticks, nextTickUptimeNanoseconds: nextTick)
    }

    private func ingest(sourceID: UUID, generation: UUID, chunk: AudioChunk) -> Bool {
        guard (!stopped || draining), slots[sourceID]?.active == true, slots[sourceID]?.generation == generation else { return false }
        guard slots[sourceID]?.ring.append(chunk) == true else {
            Self.diagnostics.error("mixer_input_overflow queued_bytes=\(self.slots[sourceID]?.ring.bytes ?? 0) incoming_bytes=\(chunk.pcm.count) ticks=\(self.ticks)")
            fail(.overflow); return false
        }
        return true
    }

    private func ended(sourceID: UUID, generation: UUID, reason: AudioStreamTermination) {
        guard var slot = slots[sourceID], slot.generation == generation else { return }
        slot.running = false
        if reason == .completed {
            slot.completed = true; slot.active = slot.ring.bytes > 0
        } else {
            slot.active = false; slot.ring.clear()
        }
        slots[sourceID] = slot
    }

    private func fail(_ reason: AudioStreamTermination) {
        continuation?.finish(reason)
        ticker?.cancel()
        for key in slots.keys { slots[key]?.active = false; slots[key]?.ring.clear(); slots[key]?.task?.cancel() }
    }

    /// One invocation processes one present tick, including after a delayed wake. No catch-up loop.
    func tick(at uptime: UInt64, whileStopping: Bool = false, frames: Int = 960) {
        guard (!stopped || whileStopping), frames > 0, let continuation, output?.snapshot.termination == nil else { return }
        let measureTick = metrics.isEnabled
        let startedAt = measureTick ? DispatchTime.now().uptimeNanoseconds : 0
        var measuredBytes = 0, measuredSources = 0
        var outcome = AppPerformanceOutcome.success
        defer {
            if measureTick {
                metrics.record(.init(operation: .mixerTick,
                    durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt,
                    bytes: measuredBytes, count: measuredSources, outcome: outcome))
            }
        }
        ticks &+= 1; nextTick = uptime.addingReportingOverflow(40_000_000).partialValue
        var mixed = [Int32](repeating: 0, count: frames)
        var served = 0, didGap = false
        var capturedUptime: UInt64?, capturedAt: ContinuousClock.Instant?
        var watermarks: [AudioSourceWatermark] = []
        do {
            for key in slots.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard slots[key]?.active == true else { continue }
                let bytes = slots[key]?.ring.bytes ?? 0
                guard bytes >= frames * 2 || (whileStopping && bytes > 0) else { didGap = true; continue }
                if bytes < frames * 2 { didGap = true }
                let evidence = try slots[key]!.ring.take(into: &mixed, now: uptime)
                if let stamp = evidence.0 { capturedUptime = min(capturedUptime ?? stamp.capturedUptimeNanoseconds, stamp.capturedUptimeNanoseconds) }
                if let instant = evidence.1 { capturedAt = min(capturedAt ?? instant, instant) }
                if let watermark = evidence.2 { watermarks.append(watermark) }
                served += 1
                if slots[key]?.completed == true, slots[key]?.ring.bytes == 0 { slots[key]?.active = false }
            }
        } catch {
            outcome = .failed
            fail((error as? AudioStreamError)?.reason ?? .sourceLost)
            return
        }
        guard served > 0 else { return }
        measuredBytes = frames * MemoryLayout<Int16>.size
        measuredSources = served
        if didGap { gaps += 1 }
        var pcm = Data(count: frames * 2)
        var peak: Int32 = 0
        pcm.withUnsafeMutableBytes { raw in
            for (index, value) in mixed.enumerated() {
                let clamped = min(max(value, -32_768), 32_767)
                peak = max(peak, abs(clamped))
                raw.storeBytes(of: Int16(clamped).littleEndian, toByteOffset: index * 2, as: Int16.self)
            }
        }
        level = peak == 0 ? 0 : AudioLevel.normalized(decibels: 20 * log10(Double(peak) / 32_768))
        sequence &+= 1
        let stamp = capturedUptime.map { AudioCaptureStamp(captureEpoch: epoch, sourceID: outputID,
            sourceSequence: sequence, capturedUptimeNanoseconds: $0) }
        let result = continuation.offer(.init(pcm: pcm, level: level, capturedAt: capturedAt,
            sequenceNumber: Int(exactly: sequence), droppedSamplesBefore: watermarks.isEmpty ? nil : 0,
            captureStamp: stamp, sourceWatermarks: watermarks))
        if result != .accepted {
            outcome = .failed
            fail(output?.snapshot.termination ?? .overflow)
        }
    }
}
