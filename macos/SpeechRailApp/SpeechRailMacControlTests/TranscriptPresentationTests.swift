import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1))) @MainActor
struct TranscriptPresentationTests {
    @Test func testClientRetirementExistsEvenWithoutDiarizationAndLiveIndexDoesNotGrow() {
        var state = RealtimeEventState(), index = LiveTranscriptItemIndex()
        let generation = UUID(), now = ContinuousClock.now
        state.reset(generation: generation, auxiliaryExpected: false)
        let identity = TranscriptPreviewLedger.Identity(connection: 1, generation: 1)
        for ordinal in 0..<2_880 {
            let itemID = "item-\(ordinal)"
            let accepted = state.complete(itemID: itemID, transcript: "synthetic", sessionID: "fixture", generation: generation, now: now)
            #expect(accepted)
            for retired in state.takeRetired() { _ = index.retire(.init(identity: identity, itemID: retired)) }
            index[.init(identity: identity, itemID: itemID)] = ("line-\(ordinal)", ordinal)
            #expect(index.count <= 128)
        }
        state.prune(now: now.advanced(by: .seconds(31)))
        for retired in state.takeRetired() { _ = index.retire(.init(identity: identity, itemID: retired)) }
        let expired = state.takeExpired()
        #expect(index.count == 0 && expired.isEmpty)
        let late = TranscriptPreviewLedger.ItemIdentity(identity: identity, itemID: "not-yet-saved")
        _ = index.retire(late)
        index[late] = ("late-save", 3_000)
        #expect(index[late] == nil)
    }
    @Test func testAppendDoesNotSortWholeHistoryAndAttributionIsIndexed() {
        let model = TranscriptPresentation<PresentationFixtureLine>()
        for ordinal in 1...20_000 { model.apply(.init(id: "line-\(ordinal)", ordinal: ordinal, text: "synthetic")) }
        #expect(model.tailCount == 500 && model.rows.count == 500)
        #expect(model.ordinalComparisons == 0)
        #expect(model.rows.first?.ordinal == 19_501)
        let revision = model.revision
        model.update(id: "line-19999") { $0.text = "updated" }
        #expect(model.line(id: "line-19999")?.text == "updated")
        #expect(model.revision == revision + 1)
        let count = model.rows.count
        model.update(id: "line-1") { $0.text = "offscreen" }
        #expect(model.rows.count == count)
        #expect(model.line(id: "line-1") == nil)
    }
    @Test func testOutOfOrderInsertAndDuplicateAreDeterministic() {
        let model = TranscriptPresentation<PresentationFixtureLine>()
        for ordinal in [3,1,5,2,4] { model.apply(.init(id: "line-\(ordinal)", ordinal: ordinal, text: "synthetic")) }
        model.apply(.init(id: "line-3", ordinal: 3, text: "revised"))
        #expect(model.rows.map(\.ordinal) == [1,2,3,4,5])
        #expect(model.line(id: "line-3")?.text == "revised")
    }
    @Test func testOlderPageArrivalPreservesAnchorAndNewLineDoesNotStealHistory() async throws {
        let model = TranscriptPresentation<PresentationFixtureLine>()
        for ordinal in 1...1_000 { model.apply(.init(id: "line-\(ordinal)", ordinal: ordinal, text: "synthetic")) }
        model.beginHistory(anchorID: "line-550")
        let loader: TranscriptPresentation<PresentationFixtureLine>.PageLoader = { before in
            let end = (before ?? 1_001) - 1
            return .init(rows: (max(1, end-199)...end).map { .init(id: "line-\($0)", ordinal: $0, text: "synthetic") }, nextBeforeOrdinal: end > 200 ? end-199 : nil)
        }
        try await model.requestPage(beforeOrdinal: 501, loader: loader)
        #expect(model.scrollAnchorID == "line-550")
        #expect(model.rows.contains { $0.id == "line-550" })
        let frozen = model.rows.map(\.id)
        for ordinal in 1_001...2_000 { model.apply(.init(id: "line-\(ordinal)", ordinal: ordinal, text: "synthetic")) }
        #expect(model.rows.map(\.id) == frozen)
        #expect(model.tailCount <= 500 && model.pageCount <= 3 && model.pageRowCount <= 600)
        model.returnToLatest()
        #expect(model.rows.last?.ordinal == 2_000)
    }
    @Test func testPageRequestsAreSingleFlightAndResetRejectsLateResult() async throws {
        let model = TranscriptPresentation<PresentationFixtureLine>(), gate = PresentationPageGate()
        model.apply(.init(id: "line-1000", ordinal: 1_000, text: "synthetic"))
        let request = Task { try await model.requestPage(beforeOrdinal: 1_000, loader: { _ in await gate.wait() }) }
        while !(await gate.waiting) { await Task.yield() }
        model.reset([])
        await gate.finish()
        try await request.value
        #expect(model.rows.isEmpty && model.pageCount == 0)
        #expect(!model.isLoadingPage)
    }
}
private struct PresentationFixtureLine: TranscriptPresentationRow, Equatable {
    let id: String
    let ordinal: Int
    var text: String
}
private actor PresentationPageGate {
    private var continuation: CheckedContinuation<TranscriptDisplayPage<PresentationFixtureLine>, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async -> TranscriptDisplayPage<PresentationFixtureLine> { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(returning: .init(rows: [.init(id: "old", ordinal: 1, text: "synthetic")], nextBeforeOrdinal: nil)); continuation = nil }
}
