import AVFoundation
import CoreAudio
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
