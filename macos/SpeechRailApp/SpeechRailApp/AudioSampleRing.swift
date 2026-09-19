import Synchronization

/// Single-producer / single-consumer ring for normalized mono Float samples.
///
/// The producer is the AVAudioEngine input-tap callback and the consumer is the
/// assistant's serial drain queue. Both indices are atomic, while the sample
/// storage is preallocated; the real-time callback never allocates or waits on
/// a lock. When the ring is full, newest samples are dropped so unread samples
/// remain contiguous in time.
@available(macOS 15.0, *)
public final class AudioSampleRing: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    public init(capacity: Int) {
        var size = 2
        while size < max(capacity + 1, 2) {
            size <<= 1
        }
        self.capacity = size
        self.mask = size - 1
        self.storage = .allocate(capacity: size)
        self.storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Number of samples currently available to the consumer.
    public var availableSampleCount: Int {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        return min(write &- read, capacity - 1)
    }

    /// Test and non-realtime convenience API. The audio callback uses the
    /// pointer overload below to avoid the array allocation.
    public func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { buffer in
            write(from: buffer.baseAddress, count: buffer.count)
        }
    }

    /// Test and non-realtime convenience API. Production code drains directly
    /// into a preallocated conversion buffer instead.
    public func read(maxCount: Int) -> [Float] {
        guard maxCount > 0 else { return [] }
        var result = [Float](repeating: 0, count: min(maxCount, capacity - 1))
        let count = read(into: result.withUnsafeMutableBufferPointer { $0.baseAddress! }, maxCount: result.count)
        result.removeLast(result.count - count)
        return result
    }

    /// Writes samples from the real-time callback without allocation or lock
    /// acquisition. Samples that do not fit are dropped from the newest end.
    @inline(__always)
    internal func write(from source: UnsafePointer<Float>?, count: Int) {
        guard let source, count > 0 else { return }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = capacity - (write &- read) - 1
        guard free > 0 else { return }

        let accepted = min(count, free)
        let offset = write & mask
        let first = min(accepted, capacity - offset)
        storage.advanced(by: offset).update(from: source, count: first)
        if first < accepted {
            storage.update(from: source.advanced(by: first), count: accepted - first)
        }
        writeIndex.store(write &+ accepted, ordering: .releasing)
    }

    /// Returns a contiguous writable region for a producer that must transform
    /// samples in place without allocating a temporary array.
    @inline(__always)
    internal func writableSpan() -> (pointer: UnsafeMutablePointer<Float>, count: Int)? {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = capacity - (write &- read) - 1
        guard free > 0 else { return nil }
        let offset = write & mask
        return (storage.advanced(by: offset), min(free, capacity - offset))
    }

    /// Commits samples written into the latest `writableSpan`.
    @inline(__always)
    internal func commitWrite(_ count: Int) {
        guard count > 0 else { return }
        let write = writeIndex.load(ordering: .relaxed)
        writeIndex.store(write &+ count, ordering: .releasing)
    }

    /// Reads into a preallocated destination owned by the consumer queue.
    @inline(__always)
    internal func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        guard maxCount > 0 else { return 0 }

        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let available = min(write &- read, capacity - 1)
        let count = min(available, maxCount)
        guard count > 0 else { return 0 }

        let offset = read & mask
        let first = min(count, capacity - offset)
        destination.update(from: UnsafePointer(storage.advanced(by: offset)), count: first)
        if first < count {
            destination.advanced(by: first).update(
                from: UnsafePointer(storage),
                count: count - first
            )
        }
        readIndex.store(read &+ count, ordering: .releasing)
        return count
    }

    /// Discards all pending samples while keeping the producer's write cursor
    /// intact. Call from the consumer queue, not from the input-tap callback.
    internal func discardPending() {
        let write = writeIndex.load(ordering: .acquiring)
        readIndex.store(write, ordering: .releasing)
    }

    /// Resets both cursors after the producer has been stopped.
    internal func reset() {
        readIndex.store(0, ordering: .relaxed)
        writeIndex.store(0, ordering: .relaxed)
    }
}
