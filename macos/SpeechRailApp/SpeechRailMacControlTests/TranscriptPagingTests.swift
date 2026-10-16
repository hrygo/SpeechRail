import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct TranscriptPagingTests {
    @Test func testFourHourArchiveRemainsCompleteAndKeysetPagesAndCopyIncludeOffscreenRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try await store.open()
        let session = try await store.createSession(.init(kind: .meeting, engineProfile: "fixture", audioSource: .microphone))
        for ordinal in 1...2_880 {
            _ = try await store.appendLine(.init(sessionID: session.id, role: .speaker, text: "synthetic-\(ordinal)", source: .microphone), id: "line-\(ordinal)")
        }
        let latest = try await store.linesPage(sessionID: session.id, beforeOrdinal: nil)
        #expect(latest.rows.count == 200 && latest.rows.last?.ordinal == 2_880)
        let older = try await store.linesPage(sessionID: session.id, beforeOrdinal: latest.nextBeforeOrdinal)
        #expect(older.rows.last?.ordinal == 2_680)
        #expect(Set(latest.rows.map(\.id)).isDisjoint(with: older.rows.map(\.id)))
        try await store.attachSpeakerLabel(lineID: "line-1", label: "A")
        #expect(try await store.linesPage(sessionID: session.id, beforeOrdinal: 201).rows.first?.speakerLabel == "A")
        #expect(try await store.lines(sessionID: session.id).count == 2_880)
        #expect(try await store.linesRange(sessionID: session.id, ordinals: 1...2_880).count == 2_880)
        let plan = try await store.transcriptPageQueryPlan()
        #expect(plan.contains("line_by_session") && !plan.contains("TEMP B-TREE"))
        await store.close()
    }
}
