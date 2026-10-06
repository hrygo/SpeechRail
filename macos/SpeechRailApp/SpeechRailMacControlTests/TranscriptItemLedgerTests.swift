import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// item 级转录账本（方案 MA-02 / MC-09～MC-13）。
///
/// 钉的都是**同一句话不能被弄丢、也不能被弄成两遍**：
final class TranscriptItemLedgerTests: XCTestCase {
    // MARK: - MC-09 交错 partial

    func testInterleavedPartialsDoNotConcatenateAcrossItems() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        ledger.acceptDelta(slot: "A", delta: "我们先说")
        ledger.acceptDelta(slot: "B", delta: "我同意")
        // A 槽的内容仍然是 A 的，不含 B。
        XCTAssertEqual(ledger.visiblePartial, "我同意")
        ledger.clearPartial(slot: "B")
        XCTAssertEqual(ledger.visiblePartial, nil)
    }

    func testDeltasAccumulateWithinTheirOwnSlot() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        ledger.acceptDelta(slot: "A", delta: "前半")
        ledger.acceptDelta(slot: "A", delta: "后半")
        XCTAssertEqual(ledger.visiblePartial, "前半后半")
    }

    func testEmptyDeltaIsIgnored() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        ledger.acceptDelta(slot: "A", delta: "有内容")
        ledger.acceptDelta(slot: "A", delta: "")
        XCTAssertEqual(ledger.visiblePartial, "有内容")
    }

    // MARK: - MC-10 快照按 revision 替换

    func testLaterRevisionReplacesInsteadOfAppending() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        XCTAssertTrue(ledger.acceptSnapshot(slot: "A", revision: 3, text: "改过的第三版"))
        XCTAssertEqual(ledger.visiblePartial, "改过的第三版")
    }

    func testLateOlderRevisionCannotOverwrite() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        _ = ledger.acceptSnapshot(slot: "A", revision: 3, text: "第三版")
        // 迟到的第二版不许倒写。
        XCTAssertFalse(ledger.acceptSnapshot(slot: "A", revision: 2, text: "第二版"))
        XCTAssertEqual(ledger.visiblePartial, "第三版")
    }

    func testEqualRevisionIsAlsoRejected() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        _ = ledger.acceptSnapshot(slot: "A", revision: 2, text: "第二版")
        XCTAssertFalse(ledger.acceptSnapshot(slot: "A", revision: 2, text: "又一个第二版"))
        XCTAssertEqual(ledger.visiblePartial, "第二版")
    }

    func testRevisionMonotonicPerSlotNotGlobal() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        _ = ledger.acceptSnapshot(slot: "A", revision: 9, text: "A 的第九版")
        // 另一个槽从低 revision 开始是正常的。
        XCTAssertTrue(ledger.acceptSnapshot(slot: "B", revision: 1, text: "B 的第一版"))
        XCTAssertEqual(ledger.visiblePartial, "B 的第一版")
    }

    // MARK: - MC-11 空 final

    func testEmptyFinalKeepsShownPartialAsRecoveryMaterial() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        ledger.acceptDelta(slot: "A", delta: "已经显示出来的半句")
        let outcome = ledger.resolveCommit(itemID: "item-1", transcript: "")
        guard case .commit(_, let note) = outcome else {
            return XCTFail("空 final 必须留下恢复材料，实际是 \(outcome)")
        }
        XCTAssertEqual(note?.text, "已经显示出来的半句")
        XCTAssertEqual(note?.itemID, "item-1")
    }

    func testRecoveryMaterialIsNotReportedAsCommitted() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        ledger.acceptDelta(slot: "A", delta: "半句")
        _ = ledger.resolveCommit(itemID: "item-1", transcript: "")
        // 恢复材料**不是**正式纪要内容，不许占去重名额之外的权威行。
        XCTAssertFalse(ledger.isCommitted("item-1"))
    }

    func testEmptyFinalWithNothingShownIsDiscarded() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        let outcome = ledger.resolveCommit(itemID: "item-1", transcript: "   ")
        XCTAssertEqual(outcome, .discarded)
    }

    func testNonEmptyFinalClearsThePartial() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        ledger.acceptDelta(slot: "A", delta: "临时")
        let outcome = ledger.resolveCommit(itemID: "item-1", transcript: "定稿")
        guard case .commit(_, let note) = outcome else {
            return XCTFail("应当落库，实际是 \(outcome)")
        }
        XCTAssertNil(note)
        XCTAssertNil(ledger.visiblePartial)
    }

    // MARK: - MC-12 同代重复 final

    func testDuplicateFinalInSameConnectionProducesNoSecondLine() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        let first = ledger.resolveCommit(itemID: "item-1", transcript: "第一遍")
        let second = ledger.resolveCommit(itemID: "item-1", transcript: "又来一遍")
        guard case .commit = first else { return XCTFail("第一次应当落库") }
        XCTAssertEqual(second, .duplicate)
    }

    // MARK: - MC-13 跨连接复用 item ID

    func testReusedItemIDInNewConnectionIsNotSwallowed() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        _ = ledger.resolveCommit(itemID: "shared-id", transcript: "上一场连接的内容")
        // 重连：新服务复用了同一个 item ID。
        ledger.beginGeneration(2)
        let outcome = ledger.resolveCommit(itemID: "shared-id", transcript: "新连接的内容")
        guard case .commit = outcome else {
            return XCTFail("跨连接复用 ID 必须能落库，实际是 \(outcome)")
        }
        XCTAssertTrue(ledger.isCommitted("shared-id"))
    }

    func testNewGenerationForgetsPartialsAndDedupButKeepsHistory() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        ledger.acceptDelta(slot: "A", delta: "上一代的半句")
        _ = ledger.resolveCommit(itemID: "item-1", transcript: "落库了")
        ledger.beginGeneration(2)
        XCTAssertNil(ledger.visiblePartial)
        XCTAssertFalse(ledger.isCommitted("item-1"))
        // 历史仍在，只是不再参与本代去重。
        XCTAssertTrue(ledger.wasCommittedInAnyGeneration("item-1"))
    }

    // MARK: - 有界输入

    func testEmptyItemIDIsStillDeduplicated() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        guard case .commit = ledger.resolveCommit(itemID: "", transcript: "第一句") else {
            return XCTFail("空 itemID 也应当落库")
        }
        // 没有 itemID 时无法按 id 去重，但同一代里也不该重复计入权威行。
        XCTAssertEqual(ledger.resolveCommit(itemID: "", transcript: "第二句"), .commit(itemID: "", recoveryNote: nil))
    }

    func testFailedPersistReleasesTheDedupSlotForRetry() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        guard case .commit = ledger.resolveCommit(itemID: "item-1", transcript: "要落库") else {
            return XCTFail("应当落库")
        }
        // 写库失败 → 回退去重名额。
        ledger.unmarkCommitted("item-1")
        guard case .commit = ledger.resolveCommit(itemID: "item-1", transcript: "要落库") else {
            return XCTFail("重试必须还能再落一次，不能被当成重复吞掉")
        }
        XCTAssertTrue(ledger.isCommitted("item-1"))
    }

    func testUnmarkOfEmptyItemIDIsHarmless() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        ledger.unmarkCommitted("")
        XCTAssertFalse(ledger.isCommitted(""))
    }

    func testClearPartialWithoutVisibleSlotEmptiesEverything() {
        var ledger = TranscriptItemLedger()
        ledger.beginGeneration(1)
        ledger.acceptDelta(slot: "A", delta: "内容")
        ledger.clearPartial()
        XCTAssertNil(ledger.visiblePartial)
    }
}
