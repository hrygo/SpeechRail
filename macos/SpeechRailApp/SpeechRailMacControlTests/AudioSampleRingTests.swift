import AVFoundation
import CoreAudio
import Synchronization
import Testing
import XCTest

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@available(macOS 15.0, *)
final class AudioSampleRingTests: XCTestCase {
    func testReadPreservesSamplesAcrossWrapAround() {
        // The implementation keeps one slot empty and rounds backing storage
        // to a power of two; seven is the usable capacity of this test ring.
        let ring = AudioSampleRing(capacity: 7)

        ring.write([0, 1, 2, 3, 4, 5])
        XCTAssertEqual(ring.read(maxCount: 3), [0, 1, 2])

        ring.write([6, 7, 8, 9])

        XCTAssertEqual(ring.read(maxCount: 8), [3, 4, 5, 6, 7, 8, 9])
    }

    func testFullRingDropsNewestSamplesWithoutOverwritingUnreadData() {
        let ring = AudioSampleRing(capacity: 7)

        ring.write([0, 1, 2, 3, 4, 5, 6, 7])

        XCTAssertEqual(ring.read(maxCount: 8), [0, 1, 2, 3, 4, 5, 6])
    }

    // MARK: - M3/V08:丢样可计数

    /// V08:整批写满时丢弃的样本必须计数——调用方据此判定输入是否完整。
    func testFullRingDropIsCounted() {
        let ring = AudioSampleRing(capacity: 7)

        XCTAssertEqual(ring.droppedSampleCount, 0, "初始丢样计数必须为零")
        ring.write([0, 1, 2, 3, 4, 5, 6, 7])

        // 可用容量 7：接纳前 7 个，第 8 个丢弃。
        XCTAssertEqual(ring.droppedSampleCount, 1, "满时多余的 1 个样本必须计数")
        XCTAssertEqual(ring.read(maxCount: 8), [0, 1, 2, 3, 4, 5, 6])
    }

    /// V08:部分容纳不下时 accepted + dropped == count，不多不少。
    func testPartialOverflowCountsExactlyTheRemainder() {
        let ring = AudioSampleRing(capacity: 7)

        ring.write([0, 1, 2, 3, 4])
        XCTAssertEqual(ring.droppedSampleCount, 0)
        // 剩余空位 2：写 5 个，接纳 2 个，丢弃 3 个。
        ring.write([5, 6, 7, 8, 9])

        XCTAssertEqual(ring.droppedSampleCount, 3, "超出空位的 3 个样本必须精确计数")
        XCTAssertEqual(ring.read(maxCount: 8), [0, 1, 2, 3, 4, 5, 6])
    }

    /// V08:ring 满时整批写入直接计数，不吞掉整批。
    func testWriteToFullRingCountsWholeBatch() {
        let ring = AudioSampleRing(capacity: 7)

        ring.write([0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(ring.droppedSampleCount, 0)
        ring.write([7, 8, 9])

        XCTAssertEqual(ring.droppedSampleCount, 3, "满时整批 3 个样本必须计数")
        XCTAssertEqual(ring.read(maxCount: 8), [0, 1, 2, 3, 4, 5, 6])
    }

    func testDiscardPendingAllowsProducerToContinue() {
        let ring = AudioSampleRing(capacity: 7)

        ring.write([0, 1, 2])
        ring.discardPending()
        ring.write([3, 4])

        XCTAssertEqual(ring.read(maxCount: 8), [3, 4])
    }
}

final class AudioCaptureBoundaryTests: XCTestCase {
    func testAssistantLayoutsWrapAndMix() throws {
        for common in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [false, true] {
                for channels in [1, 2, 3] {
                    let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag:
                        kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
                    let format = try XCTUnwrap(AVAudioFormat(commonFormat: common, sampleRate: 48_000,
                        interleaved: interleaved, channelLayout: layout))
                    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
                    buffer.frameLength = 4
                    for channel in 0..<channels {
                        for frame in 0..<4 {
                            let offset = frame * buffer.stride
                            let value = frame + channel + 1
                            if let data = buffer.floatChannelData { data[channel][offset] = Float(value) / 32 }
                            if let data = buffer.int16ChannelData { data[channel][offset] = Int16(value * 1_024) }
                            if let data = buffer.int32ChannelData { data[channel][offset] = Int32(value * 67_108_864) }
                        }
                    }
                    let ring = AudioSampleRing(capacity: 7)
                    ring.write([0, 0, 0, 0, 0, 0])
                    _ = ring.read(maxCount: 6)
                    AudioEngineSession.copyInputToRing(buffer, into: ring)
                    let actual = ring.read(maxCount: 8)
                    XCTAssertEqual(actual.count, 4)
                    for (frame, sample) in actual.enumerated() {
                        XCTAssertEqual(sample, (Float(frame + 1) + Float(channels - 1) / 2) / 32,
                                       accuracy: 0.000_001)
                    }
                }
            }
        }
    }

    func testAssistantFullRingDropsOnlyNewestSamples() throws {
        let buffer = try makeBuffer(channels: 1, interleaved: false)
        for i in 0..<4 { buffer.floatChannelData![0][i] = Float(i + 5) }
        let ring = AudioSampleRing(capacity: 7)
        ring.write([0, 1, 2, 3, 4])
        AudioEngineSession.copyInputToRing(buffer, into: ring)
        XCTAssertEqual(ring.read(maxCount: 8), [0, 1, 2, 3, 4, 5, 6])
    }

    func testTapLayoutsAcrossRepeatedWraps() throws {
        for channels in [1, 2, 3, 6] {
            for interleaved in [false, true] {
                let buffer = try makeBuffer(channels: channels, interleaved: interleaved)
                for frame in 0..<4 {
                    for channel in 0..<channels {
                        buffer.floatChannelData![channel][frame * buffer.stride] = Float(frame * channels + channel)
                    }
                }
                let ring = InterleavedFloatRing(capacity: 1_024, channels: channels)
                for _ in 0..<200 {
                    CoreAudioTapCapture.copyInputToRing(buffer.audioBufferList, into: ring, channels: channels)
                    XCTAssertEqual(read(ring), Array(0..<(4 * channels)).map(Float.init))
                }
            }
        }
    }

    func testTapInterleavedFramesUseBytesPerFrame() throws {
        let buffer = try makeBuffer(channels: 2, interleaved: true, capacity: 8)
        for i in 0..<16 { buffer.floatChannelData![0][i] = Float(i) }
        let ring = InterleavedFloatRing(capacity: 1_024, channels: 2)
        CoreAudioTapCapture.copyInputToRing(buffer.audioBufferList, into: ring, channels: 2)
        XCTAssertEqual(read(ring), Array(0..<8).map(Float.init))
    }

    func testTapShortestPlaneAndMalformedLayouts() throws {
        let buffer = try makeBuffer(channels: 2, interleaved: false)
        for i in 0..<4 {
            buffer.floatChannelData![0][i] = Float(i)
            buffer.floatChannelData![1][i] = Float(i + 10)
        }
        let list = buffer.mutableAudioBufferList
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        buffers[1].mDataByteSize = 8
        let ring = InterleavedFloatRing(capacity: 1_024, channels: 2)
        CoreAudioTapCapture.copyInputToRing(UnsafePointer(list), into: ring, channels: 2)
        XCTAssertEqual(read(ring), [0, 10, 1, 11])
        buffers[1].mDataByteSize = 7
        CoreAudioTapCapture.copyInputToRing(UnsafePointer(list), into: ring, channels: 2)
        XCTAssertTrue(read(ring).isEmpty)
        CoreAudioTapCapture.copyInputToRing(UnsafePointer(list), into: ring, channels: 1)
        XCTAssertTrue(read(ring).isEmpty)
    }

    func testTapRejectsUnsupportedStreamFormats() throws {
        for channels in [1, 2, 6] {
            for interleaved in [false, true] {
                let buffer = try makeBuffer(channels: channels, interleaved: interleaved)
                let valid = buffer.format.streamDescription.pointee
                XCTAssertTrue(CoreAudioTapCapture.supportsTapFormat(valid))
                let input = try XCTUnwrap(CoreAudioTapCapture.makeInputFormat(valid))
                XCTAssertEqual(input.channelCount, UInt32(channels))
                let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                    sampleRate: 24_000, channels: 1, interleaved: true))
                XCTAssertNotNil(AVAudioConverter(from: input, to: output))
                var invalid = valid
                invalid.mSampleRate = .nan
                XCTAssertFalse(CoreAudioTapCapture.supportsTapFormat(invalid))
                invalid = valid; invalid.mBitsPerChannel = 16
                XCTAssertFalse(CoreAudioTapCapture.supportsTapFormat(invalid))
                invalid = valid; invalid.mFormatFlags |= kAudioFormatFlagIsBigEndian
                XCTAssertFalse(CoreAudioTapCapture.supportsTapFormat(invalid))
                invalid = valid; invalid.mBytesPerFrame += 4
                XCTAssertFalse(CoreAudioTapCapture.supportsTapFormat(invalid))
            }
        }
    }

    func testTapIncludesHelpersEmbeddedInSelectedApplication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = directory.appendingPathComponent("Browser.app")
        try makeApplication(browser, bundleID: "test.browser")
        try makeApplication(browser.appendingPathComponent("Contents/Frameworks/Browser Helper.app"),
                            bundleID: "test.browser.helper")
        try makeApplication(directory.appendingPathComponent("Other.app"), bundleID: "test.other")

        XCTAssertEqual(
            CoreAudioTapCapture.bundleIDsIncludingHelpers(["test.browser"], applicationURLs: [browser]),
            ["test.browser", "test.browser.helper"]
        )
    }

    func testTapSelectsOnlyWebKitProcessesOwnedBySelectedApplication() {
        let processes: [CoreAudioTapCapture.AudioProcessIdentity] = [
            .init(objectID: 1, bundleID: "test.meeting", responsibleBundleID: "test.meeting"),
            .init(objectID: 2, bundleID: "com.apple.WebKit.GPU", responsibleBundleID: "test.meeting"),
            .init(objectID: 3, bundleID: "com.apple.WebKit.GPU", responsibleBundleID: "test.other"),
            .init(objectID: 4, bundleID: "com.apple.WebKit.GPU", responsibleBundleID: nil),
            .init(objectID: 5, bundleID: "test.other", responsibleBundleID: "test.other")
        ]
        XCTAssertEqual(CoreAudioTapCapture.selectedAudioProcessIDs(
            bundleIDs: ["test.meeting"], processes: processes), [1, 2])
        XCTAssertEqual(CoreAudioTapCapture.selectedAudioProcessIDs(
            bundleIDs: [], processes: processes), [])
        let replacement: [CoreAudioTapCapture.AudioProcessIdentity] = [
            .init(objectID: 2, bundleID: "com.apple.WebKit.GPU", responsibleBundleID: "test.other"),
            .init(objectID: 6, bundleID: "com.apple.WebKit.GPU", responsibleBundleID: "test.meeting")
        ]
        XCTAssertEqual(CoreAudioTapCapture.selectedAudioProcessIDs(
            bundleIDs: ["test.meeting"], processes: replacement), [6])
    }

    func testTapRejectsUnselectedApplicationAndHelperSymlinkEscapes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = directory.appendingPathComponent("Browser.app")
        let other = directory.appendingPathComponent("Other.app")
        try makeApplication(browser, bundleID: "test.browser")
        try makeApplication(other, bundleID: "test.other")
        try FileManager.default.createSymbolicLink(
            at: browser.appendingPathComponent("Contents/Other.app"), withDestinationURL: other
        )

        XCTAssertEqual(
            CoreAudioTapCapture.bundleIDsIncludingHelpers(["test.browser"], applicationURLs: [other, browser]),
            ["test.browser"]
        )
    }

    func testTapDeduplicatesHelperIdentitiesBeforeAnyHelperStarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = directory.appendingPathComponent("Browser.app")
        try makeApplication(browser, bundleID: "test.browser")
        for name in ["Renderer", "Audio"] {
            try makeApplication(browser.appendingPathComponent("Contents/Frameworks/\(name).app"),
                                bundleID: "test.browser.helper")
        }
        XCTAssertEqual(
            CoreAudioTapCapture.bundleIDsIncludingHelpers(["test.browser", "test.browser"], applicationURLs: [browser]),
            ["test.browser", "test.browser.helper"]
        )
        XCTAssertEqual(CoreAudioTapCapture.bundleIDsIncludingHelpers(["test.missing"], applicationURLs: []),
                       ["test.missing"])
    }

    private func makeApplication(_ url: URL, bundleID: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func makeBuffer(channels: Int, interleaved: Bool, capacity: UInt32 = 4) throws -> AVAudioPCMBuffer {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag:
            kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            interleaved: interleaved, channelLayout: layout))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        buffer.frameLength = 4
        return buffer
    }

    private func read(_ ring: InterleavedFloatRing) -> [Float] {
        var result: [Float] = []
        while let span = ring.readableSpan() {
            result.append(contentsOf: UnsafeBufferPointer(start: span.pointer, count: span.count))
            ring.commitRead(span.count)
        }
        return result
    }
}

private enum XPCReplyLatchTestError: Error, Equatable {
    case timedOut
    case lateReply
}

@Suite(.timeLimit(.minutes(1)))
struct XPCReplyLatchTests {
    @Test func testPreCancelledRequestDoesNotSendStart() async {
        let sent = Mutex(false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await XPCReplyLatch.perform(timeout: .seconds(1), timeoutError: XPCReplyLatchTestError.timedOut) { _ in
                sent.withLock { $0 = true }
            }
        }

        do {
            try await task.value
            Issue.record("A canceled start must fail")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(sent.withLock { $0 } == false)
    }

    @Test func testCancellationWinsAndIgnoresLateSuccessReply() async throws {
        let (requests, requestContinuation) = AsyncStream<XPCReplyLatch>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            try await XPCReplyLatch.perform(timeout: .seconds(5), timeoutError: XPCReplyLatchTestError.timedOut) {
                _ = requestContinuation.yield($0)
            }
        }
        var iterator = requests.makeAsyncIterator()
        let lateReply = try #require(await iterator.next())
        requestContinuation.finish()
        task.cancel()

        do {
            try await task.value
            Issue.record("Cancellation must win before the remote reply")
        } catch {
            #expect(error is CancellationError)
        }
        lateReply.resolve(.success(()))
    }

    @Test func testTimeoutWinsAndIgnoresLateSuccessReply() async throws {
        let (requests, requestContinuation) = AsyncStream<XPCReplyLatch>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            try await XPCReplyLatch.perform(timeout: .milliseconds(20), timeoutError: XPCReplyLatchTestError.timedOut) {
                _ = requestContinuation.yield($0)
            }
        }
        var iterator = requests.makeAsyncIterator()
        let lateReply = try #require(await iterator.next())
        requestContinuation.finish()

        do {
            try await task.value
            Issue.record("An unresponsive helper must time out")
        } catch {
            #expect(error as? XPCReplyLatchTestError == .timedOut)
        }
        lateReply.resolve(.success(()))
    }

    @Test func testFirstReplyWinsWhenSuccessArrivesBeforeTimeout() async throws {
        try await XPCReplyLatch.perform(timeout: .seconds(1), timeoutError: XPCReplyLatchTestError.timedOut) { latch in
            latch.resolve(.success(()))
            latch.resolve(.failure(XPCReplyLatchTestError.lateReply))
        }
    }
}

final class CaptureHelperOwnershipTests: XCTestCase {
    func testOperationWatchdogCannotWinAfterSuccessfulCompletion() {
        let gate = CaptureOperationGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    func testOldConnectionInvalidationCannotStopNewCapture() {
        let ownership = CaptureConnectionOwnership()
        let old = ownership.attach()
        XCTAssertTrue(ownership.activate(old))
        ownership.invalidate(old)
        let fresh = ownership.attach()
        XCTAssertTrue(ownership.acceptStart(fresh))
        // The accepted start reaps the invalidated owner's hardware first.
        ownership.clearActive()
        XCTAssertTrue(ownership.activate(fresh))
        ownership.invalidate(old)
        XCTAssertFalse(ownership.ownsCapture(old))
        XCTAssertTrue(ownership.isCurrent(fresh))
        XCTAssertTrue(ownership.ownsCapture(fresh))
    }

    func testInvalidatedOrSupersededConnectionCannotStart() {
        let ownership = CaptureConnectionOwnership()
        let old = ownership.attach()
        let fresh = ownership.attach()
        XCTAssertFalse(ownership.activate(old))
        XCTAssertTrue(ownership.activate(fresh))
        ownership.invalidate(fresh)
        XCTAssertFalse(ownership.isCurrent(fresh))
        // The matching invalidation still owns cleanup of its active capture.
        XCTAssertTrue(ownership.ownsCapture(fresh))
        ownership.clearActive()
        XCTAssertFalse(ownership.activate(fresh))
        XCTAssertFalse(ownership.ownsCapture(fresh))
    }

    func testNewConnectionCannotReplaceLiveCapture() {
        let ownership = CaptureConnectionOwnership()
        let first = ownership.attach()
        XCTAssertTrue(ownership.activate(first))
        XCTAssertTrue(ownership.acceptStart(first))
        let second = ownership.attach()
        XCTAssertFalse(ownership.acceptStart(second))
        XCTAssertFalse(ownership.activate(second))
        XCTAssertTrue(ownership.ownsCapture(first))
        ownership.invalidate(first)
        XCTAssertTrue(ownership.acceptStart(second))
        ownership.clearActive()
        XCTAssertTrue(ownership.activate(second))
        ownership.invalidate(first)
        XCTAssertTrue(ownership.ownsCapture(second))
    }

    func testSupersededStartCannotPublishAfterNativeCleanup() {
        let ownership = CaptureConnectionOwnership()
        let first = ownership.attach()
        XCTAssertTrue(ownership.activate(first))
        ownership.invalidate(first)
        let second = ownership.attach()
        XCTAssertTrue(ownership.acceptStart(second))
        let third = ownership.attach()
        ownership.clearActive()
        XCTAssertFalse(ownership.activate(second))
        XCTAssertFalse(ownership.acceptStart(second))
        XCTAssertTrue(ownership.acceptStart(third))
        XCTAssertTrue(ownership.activate(third))
    }

    func testCaptureStartFailureKeepsTheRealOSStatusAcrossXPC() {
        let error = CoreAudioTapCapture.Failure.deviceStartFailed(268451843).diagnosticError
        XCTAssertEqual(error.code, 268451843)
        XCTAssertEqual(error.userInfo["stage"] as? String, "device_start")
        XCTAssertTrue(error.localizedDescription.contains("268451843"))
        XCTAssertFalse(error.localizedDescription.contains("CoreAudioTapCapture.Failure error"))
    }
}
