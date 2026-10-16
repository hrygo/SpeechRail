import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct CaptureDeliveryWindowTests {
    @Test func testAckAfterDeadlineCannotReviveWindowBeforeTimerRuns() async throws {
        let clock = Mutex<UInt64>(100), epoch = UUID()
        let window = CaptureDeliveryWindow(now: { clock.withLock { $0 } })
        window.begin(epoch: epoch)
        for sequence in 1...4 { #expect(window.offer(sequence: UInt64(sequence), bytes: 1_920)) }
        let sender = Task { await window.waitForCredit() }
        let drainer = Task { await window.waitUntilDrained() }
        while window.snapshot.waitingSenders == 0 || window.snapshot.waitingDrainers == 0 { await Task.yield() }
        clock.withLock { $0 += 1_000_000_000 }
        #expect(throws: CaptureDeliveryWindow.Failure.self) {
            try window.acknowledge(epoch: epoch, throughSequence: 1)
        }
        #expect(window.snapshot.didExpire)
        #expect(window.snapshot.inFlightBytes == 0)
        #expect(!window.offer(sequence: 5, bytes: 1_920))
        window.stop() // Also releases waiters when running this regression against the old implementation.
        #expect(await !sender.value)
        #expect(await !drainer.value)
    }

    @Test func testGracefulDrainWaitsForTheLastDequeueAcknowledgement() async throws {
        let window = CaptureDeliveryWindow(), epoch = UUID(), drained = Mutex(false)
        window.begin(epoch: epoch)
        #expect(window.offer(sequence: 1, bytes: 1_920))
        #expect(window.offer(sequence: 2, bytes: 1_920))
        let task = Task { let result = await window.waitUntilDrained(); drained.withLock { $0 = true }; return result }
        while window.snapshot.waitingDrainers == 0 { await Task.yield() }
        try window.acknowledge(epoch: epoch, throughSequence: 1)
        #expect(!drained.withLock { $0 })
        try window.acknowledge(epoch: epoch, throughSequence: 2)
        #expect(await task.value)
        #expect(window.snapshot.waitingDrainers == 0)
    }

    @Test
    func testFourInFlightBlocksFifthUntilDequeued() async throws {
        let window = CaptureDeliveryWindow(now: { 10 }), epoch = UUID()
        window.begin(epoch: epoch)
        for sequence in 1...4 { #expect(window.offer(sequence: UInt64(sequence), bytes: 1_920)) }
        #expect(!window.offer(sequence: 5, bytes: 1_920))
        #expect(window.snapshot.inFlightBytes == 7_680)
        #expect(window.snapshot.inFlightChunks == 4)
        let waiting = Task { await window.waitForCredit() }
        while window.snapshot.waitingSenders == 0 { await Task.yield() }
        #expect(try window.acknowledge(epoch: epoch, throughSequence: 1))
        #expect(await waiting.value)
        #expect(window.offer(sequence: 5, bytes: 1_920))
        #expect(window.snapshot.inFlightBytes == 7_680)
        window.stop()
        #expect(window.snapshot.inFlightBytes == 0)
    }

    @Test
    func testOldEpochAckDoesNotReleaseNewCredits() throws {
        let window = CaptureDeliveryWindow(now: { 10 }), old = UUID(), current = UUID()
        window.begin(epoch: old)
        #expect(window.offer(sequence: 1, bytes: 1_920))
        window.begin(epoch: current)
        for sequence in 1...4 { #expect(window.offer(sequence: UInt64(sequence), bytes: 1_920)) }
        #expect(try !window.acknowledge(epoch: old, throughSequence: 4))
        #expect(window.snapshot.inFlightChunks == 4)
        #expect(!window.offer(sequence: 5, bytes: 1_920))
        window.stop()
    }

    @Test
    func testAckBeyondSentSequenceFails() throws {
        let window = CaptureDeliveryWindow(now: { 10 }), epoch = UUID()
        window.begin(epoch: epoch)
        #expect(window.offer(sequence: 1, bytes: 1_920))
        #expect(throws: CaptureDeliveryWindow.Failure.self) {
            try window.acknowledge(epoch: epoch, throughSequence: 2)
        }
        #expect(window.snapshot.inFlightChunks == 1)
        #expect(!window.offer(sequence: 1, bytes: 1_920))
        #expect(!window.offer(sequence: 2, bytes: 1_921))
        window.stop()
    }

    @Test
    func testNoAckTerminatesAndReleasesCapture() async throws {
        let clock = Mutex<UInt64>(100), window = CaptureDeliveryWindow(now: { clock.withLock { $0 } }), epoch = UUID()
        window.begin(epoch: epoch)
        for sequence in 1...4 { _ = window.offer(sequence: UInt64(sequence), bytes: 1_920) }
        let waiting = Task { await window.waitForCredit() }
        while window.snapshot.waitingSenders == 0 { await Task.yield() }
        clock.withLock { $0 += 1_000_000_000 }
        #expect(window.expireIfNeeded())
        #expect(await !waiting.value)
        #expect(window.snapshot.inFlightBytes == 0)
        #expect(window.snapshot.waitingSenders == 0)
        #expect(window.snapshot.didExpire)
    }

    @Test
    func testNoInFlightAudioDoesNotStartAckTimeout() throws {
        let clock = Mutex<UInt64>(100), window = CaptureDeliveryWindow(now: { clock.withLock { $0 } }), epoch = UUID()
        window.begin(epoch: epoch)
        clock.withLock { $0 += 10_000_000_000 }
        #expect(window.snapshot.ackDeadlineUptimeNanoseconds == nil)
        #expect(!window.expireIfNeeded())
        _ = window.offer(sequence: 1, bytes: 1_920)
        #expect(try window.acknowledge(epoch: epoch, throughSequence: 1))
        clock.withLock { $0 += 10_000_000_000 }
        #expect(window.snapshot.ackDeadlineUptimeNanoseconds == nil)
        #expect(!window.expireIfNeeded())
        window.stop()
    }

    @Test
    func testDuplicateAckCannotKeepAStalledCaptureAlive() throws {
        let clock = Mutex<UInt64>(100), window = CaptureDeliveryWindow(now: { clock.withLock { $0 } }), epoch = UUID()
        window.begin(epoch: epoch)
        for sequence in 1...3 { _ = window.offer(sequence: UInt64(sequence), bytes: 1_920) }
        clock.withLock { $0 += 500_000_000 }
        #expect(try window.acknowledge(epoch: epoch, throughSequence: 1))
        let deadline = window.snapshot.ackDeadlineUptimeNanoseconds
        clock.withLock { $0 += 500_000_000 }
        #expect(try !window.acknowledge(epoch: epoch, throughSequence: 1))
        #expect(window.snapshot.ackDeadlineUptimeNanoseconds == deadline)
        clock.withLock { $0 += 500_000_000 }
        #expect(window.expireIfNeeded())
    }
}
