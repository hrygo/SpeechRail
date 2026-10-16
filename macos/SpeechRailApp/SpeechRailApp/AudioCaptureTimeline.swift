import Synchronization

/// SPSC metadata owned by the existing raw sample rings. It is deliberately not Sendable:
/// the ring owns its lifetime and enforces producer/consumer access, just like its Float storage.
final class AudioCaptureTimeline {
    private struct Entry { var position: Int = 0; var uptime: UInt64 = 0 }
    private let entries: UnsafeMutablePointer<Entry>
    private let write = Atomic<Int>(0), read = Atomic<Int>(0)
    static let capacity = 64
    static let storageBytes = capacity * MemoryLayout<Entry>.stride
    init() {
        entries = .allocate(capacity: Self.capacity)
        entries.initialize(repeating: Entry(), count: Self.capacity)
    }
    deinit { entries.deinitialize(count: Self.capacity); entries.deallocate() }

    /// Producer only, before publishing samples. A full metadata ring rejects the callback.
    @inline(__always) func begin(position: Int, uptime: UInt64) -> Bool {
        let cursor = write.load(ordering: .relaxed)
        guard cursor - read.load(ordering: .acquiring) < Self.capacity else { return false }
        entries[cursor % Self.capacity] = .init(position: position, uptime: uptime)
        write.store(cursor + 1, ordering: .releasing)
        return true
    }

    /// Consumer only. Retain the last boundary until every sample from it has been consumed.
    func uptime(at position: Int, samplesPerSecond: Double) -> UInt64? {
        var cursor = read.load(ordering: .relaxed)
        let end = write.load(ordering: .acquiring)
        guard cursor < end, samplesPerSecond > 0 else { return nil }
        while cursor + 1 < end, entries[(cursor + 1) % Self.capacity].position <= position { cursor += 1 }
        let entry = entries[cursor % Self.capacity]
        read.store(cursor, ordering: .releasing)
        guard position >= entry.position else { return nil }
        let elapsed = Double(position - entry.position) * 1_000_000_000 / samplesPerSecond
        guard elapsed.isFinite, elapsed < Double(UInt64.max - entry.uptime) else { return nil }
        return entry.uptime + UInt64(elapsed)
    }

    func discard(through position: Int) { _ = uptime(at: position, samplesPerSecond: 1) }
    func reset() { read.store(0, ordering: .relaxed); write.store(0, ordering: .relaxed) }
}
