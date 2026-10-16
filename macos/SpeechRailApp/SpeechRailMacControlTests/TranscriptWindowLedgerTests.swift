import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif
import SpeechRailControlKit

struct TranscriptWindowLedgerTests {
    let binding = TranscriptWindowLedger.Binding(recordID: UUID().uuidString, connectionID: UUID(), generation: 1)
    func fixture(_ name: String) throws -> TranscriptWindowEvent {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(TranscriptWindowEvent.self,
            from: Data(contentsOf: root.appendingPathComponent("tests/fixtures/realtime-current/server/"+name+".json")))
    }
    @Test func skippedSnapshotsAndTerminalReplayAreAtomic() throws {
        var ledger = TranscriptWindowLedger(binding: binding)
        #expect(ledger.apply(try fixture("window-updated-r2"), binding: binding) == .snapshot)
        #expect(ledger.apply(try fixture("window-updated-r5"), binding: binding) == .snapshot)
        #expect(ledger.units.count == 1)
        #expect(ledger.apply(try fixture("window-sealed-r6"), binding: binding) == .seal)
        #expect(ledger.units.isEmpty)
        #expect(ledger.apply(try fixture("window-sealed-replay"), binding: binding) == .duplicate)
        #expect(ledger.apply(try fixture("window-updated-r5"), binding: binding) == .rejected)
    }
    @Test func sealedTransactionDoesNotRequireAnyPreview() throws {
        var ledger = TranscriptWindowLedger(binding: binding)
        #expect(ledger.apply(try fixture("window-sealed-r6"), binding: binding) == .seal)
        #expect(ledger.sealedThrough == 96000)
    }
    @Test func failedTransactionOwnsRecoveryWithoutFinalUnits() throws {
        var ledger = TranscriptWindowLedger(binding: binding)
        #expect(ledger.apply(try fixture("window-sealed-r6"), binding: binding) == .seal)
        let failed = try fixture("window-failed-r7")
        #expect(failed.finalUnits == nil)
        #expect(ledger.apply(failed, binding: binding) == .failure)
        #expect(ledger.sealedThrough == 192000)
        #expect(ledger.matchesFailure(itemID: "item-2"))
        #expect(ledger.latestTransaction?.failedItems?.first?.recoveryText == "合成恢复文字")
    }
    @Test func emptyReviewedSpeechRetainsItsTerminalOwner() throws {
        var ledger = TranscriptWindowLedger(binding: binding)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture("window-sealed-r6"))) as? [String: Any])
        var units = try #require(json["final_units"] as? [[String: Any]])
        units[0]["text"] = ""
        json["final_units"] = units
        let empty = try JSONDecoder().decode(TranscriptWindowEvent.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(ledger.apply(empty, binding: binding) == .seal)
        #expect(ledger.matchesTerminal(itemID: "item-1", text: ""))
        #expect(ledger.sealedThrough == 96000)
    }
    @Test func wrongLocalRecordIsRejected() throws {
        var ledger = TranscriptWindowLedger(binding: binding)
        let wrong = TranscriptWindowLedger.Binding(recordID: UUID().uuidString, connectionID: binding.connectionID, generation: 1)
        #expect(ledger.apply(try fixture("window-updated-r2"), binding: wrong) == .rejected)
        #expect(ledger.units.isEmpty)
    }
    @Test func sameRevisionWithDifferentContentIsRejected() throws {
        var ledger = TranscriptWindowLedger(binding: binding)
        let original = try fixture("window-updated-r2")
        #expect(ledger.apply(original, binding: binding) == .snapshot)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var units = try #require(json["units"] as? [[String: Any]])
        units[0]["text"] = "不相同的正文"
        json["units"] = units
        let conflicting = try JSONDecoder().decode(TranscriptWindowEvent.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(ledger.apply(conflicting, binding: binding) == .rejected)
    }

    @Test(arguments: [false, true]) func terminalTailCannotChangeSameVersionText(failed: Bool) throws {
        var ledger = TranscriptWindowLedger(binding: binding)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var snapshot = try #require(JSONSerialization.jsonObject(with: encoder.encode(fixture("window-updated-r2"))) as? [String: Any])
        var tail = try #require((snapshot["units"] as? [[String: Any]])?.first)
        tail["owned_span"] = ["start": 96000, "end": 192000]
        snapshot["units"] = [tail]; snapshot["audio_span"] = ["start": 0, "end": 192000]
        #expect(ledger.apply(try decoder.decode(TranscriptWindowEvent.self, from: JSONSerialization.data(withJSONObject: snapshot)), binding: binding) == .snapshot)
        let name = failed ? "window-failed-r7" : "window-sealed-r6"
        var terminal = try #require(JSONSerialization.jsonObject(with: encoder.encode(fixture(name))) as? [String: Any])
        // A leading silence transaction leaves the already displayed tail mutable.
        terminal["closed_span"] = ["start": 0, "end": 96000]
        terminal["sealed_through_sample"] = 96000
        terminal["audio_span"] = ["start": 0, "end": 192000]
        terminal["coverage"] = [["span": ["start": 0, "end": 96000], "outcome": "silence", "reason": "vad_not_admitted"]]
        terminal["failed_items"] = []
        if !failed { terminal["final_units"] = [] }
        tail["text"] = "同版本陈旧正文"
        terminal["remaining_units"] = [tail]
        let stale = try decoder.decode(TranscriptWindowEvent.self, from: JSONSerialization.data(withJSONObject: terminal))
        #expect(ledger.apply(stale, binding: binding) == .rejected)
        #expect(ledger.sealedThrough == 0)
        #expect(ledger.visibleText == "合成测试。")
    }

    @Test func sealedFinalCannotChangeSameVersionText() throws {
        var ledger = TranscriptWindowLedger(binding: binding)
        #expect(ledger.apply(try fixture("window-updated-r2"), binding: binding) == .snapshot)
        var terminal = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture("window-sealed-r6"))) as? [String: Any])
        var final = try #require(terminal["final_units"] as? [[String: Any]])
        final[0]["text_revision"] = 1; terminal["final_units"] = final
        let stale = try JSONDecoder().decode(TranscriptWindowEvent.self, from: JSONSerialization.data(withJSONObject: terminal))
        #expect(ledger.apply(stale, binding: binding) == .rejected)
        #expect(ledger.sealedThrough == 0)
    }

    @Test func tenThousandSnapshotsRetainOnlyBoundedFingerprintsAndLatestUnits() throws {
        let binding = TranscriptWindowLedger.Binding(recordID:"record",connectionID:UUID(),generation:1)
        var ledger = TranscriptWindowLedger(binding:binding)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var json = try #require(JSONSerialization.jsonObject(with:encoder.encode(fixture("window-updated-r2"))) as? [String:Any])
        var units = try #require(json["units"] as? [[String:Any]])
        for revision in 2...10001 {
            json["window_revision"] = revision
            units[0]["text"] = "修订\(revision)"; units[0]["text_revision"] = revision
            if revision == 5000 { units = [units[0]] }
            json["units"] = units
            let event = try decoder.decode(TranscriptWindowEvent.self,from:JSONSerialization.data(withJSONObject:json))
            #expect(ledger.apply(event,binding:binding) == .snapshot)
        }
        #expect(ledger.retainedFingerprints == 64)
        #expect(ledger.units.count == 1)
    }
    @Test func unicodeCodepointAndUnsafeIntegerLimitsAreEnforcedAtomically() throws {
        let binding = TranscriptWindowLedger.Binding(recordID:"record",connectionID:UUID(),generation:1)
        var ledger = TranscriptWindowLedger(binding:binding)
        var json = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(fixture("window-updated-r2"))) as? [String:Any])
        var units = try #require(json["units"] as? [[String:Any]])
        units[0]["text"] = String(repeating:"e\u{301}",count:5000)
        json["units"] = units
        let event = try JSONDecoder().decode(TranscriptWindowEvent.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(ledger.apply(event,binding:binding) == .rejected)
        #expect(ledger.units.isEmpty)
        json["units"] = []; json["input_epoch"] = 9_007_199_254_740_992
        let unsafe = try JSONDecoder().decode(TranscriptWindowEvent.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(ledger.apply(unsafe,binding:binding) == .rejected)
    }
}
