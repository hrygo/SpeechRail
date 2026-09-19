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

    func testDiscardPendingAllowsProducerToContinue() {
        let ring = AudioSampleRing(capacity: 7)

        ring.write([0, 1, 2])
        ring.discardPending()
        ring.write([3, 4])

        XCTAssertEqual(ring.read(maxCount: 8), [3, 4])
    }
}
