import Foundation
import Testing
import SQLite3
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TranscriptWindowPersistenceTests {
    func fixture() async throws -> (SessionStore, String, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(directory: directory)
        try await store.open()
        let session = try await store.createSession(SessionDraft(kind: .meeting,
            engineProfile: "quality", audioSource: .microphone))
        return (store, session.id, directory)
    }
    func row(_ session: String, id: String) -> SealedWindowCommand.Row {
        .init(line: .init(sessionID: session, connection: 1, itemID: id, lineID: id,
            text: "合成正文", role: .speaker, formal: true, observedAt: Date(timeIntervalSince1970: 100)),
            revisionID: "revision-" + id)
    }
    @Test func successfulBatchRetryPrecedesStaleCheckpointCAS() async throws {
        let (store, session, _) = try await fixture()
        let initial = WindowCheckpointCommand(sessionID: session, id: "checkpoint", expectedText: nil,
            text: "旧尾文", observedAt: Date(timeIntervalSince1970: 99))
        try await store.saveWindowCheckpoint(initial)
        let checkpoint = WindowCheckpointCommand(sessionID: session, id: "checkpoint", expectedText: "旧尾文",
            text: "剩余尾文", observedAt: Date(timeIntervalSince1970: 99))
        let command = SealedWindowCommand(transactionID: "transaction", sessionID: session,
            rows: [row(session, id: "one"), row(session, id: "two")],
            savedThrough: 96000, checkpoint: checkpoint)
        let first = try await store.appendSealedWindow(command)
        let second = try await store.appendSealedWindow(command)
        #expect(first == second)
        #expect(try await store.lines(sessionID: session).count == 2)
        #expect(try await store.transcriptRevisions(lineID: "one").first?.origin == "asr")
        #expect(SessionStore.schemaVersion == 13)
        await store.close()
    }
    @Test func secondLineFailureRollsBackEntireBatchAndOutbox() async throws {
        let (store, session, _) = try await fixture()
        try await store.execute("CREATE TEMP TRIGGER reject_second BEFORE INSERT ON line WHEN NEW.id = 'two' BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        let command = SealedWindowCommand(transactionID: "transaction", sessionID: session,
            rows: [row(session, id: "one"), row(session, id: "two")], savedThrough: 96000)
        await #expect(throws: (any Error).self) { try await store.appendSealedWindow(command) }
        #expect(try await store.lines(sessionID: session, includePartial: true).isEmpty)
        #expect(try await store.transcriptRevisions(lineID: "one").isEmpty)
        await store.close()
    }
    @Test(arguments: ["revision", "outbox", "checkpoint"])
    func everyTransactionalFailureRollsBackRowsAndInitialRevision(stage: String) async throws {
        let (store, session, _) = try await fixture()
        let original = WindowCheckpointCommand(sessionID:session,id:"checkpoint",expectedText:nil,
            text:"恢复尾文",observedAt:Date(timeIntervalSince1970:99))
        try await store.saveWindowCheckpoint(original)
        let sql: String
        switch stage {
        case "revision": sql = "CREATE TEMP TRIGGER injected BEFORE INSERT ON transcript_revision BEGIN SELECT RAISE(ABORT, 'injected'); END;"
        case "outbox": sql = "CREATE TEMP TRIGGER injected BEFORE INSERT ON search_index_outbox BEGIN SELECT RAISE(ABORT, 'injected'); END;"
        default: sql = "CREATE TEMP TRIGGER injected BEFORE DELETE ON line WHEN OLD.id = 'checkpoint' BEGIN SELECT RAISE(ABORT, 'injected'); END;"
        }
        try await store.execute(sql)
        let command = SealedWindowCommand(transactionID:"transaction",sessionID:session,
            rows:[row(session,id:"one"),row(session,id:"two")],savedThrough:96000,
            checkpoint:.init(sessionID:session,id:"checkpoint",expectedText:"恢复尾文",text:"",
                observedAt:Date(timeIntervalSince1970:99)))
        await #expect(throws:(any Error).self) { try await store.appendSealedWindow(command) }
        let lines = try await store.lines(sessionID:session,includePartial:true)
        #expect(lines.count == 1 && lines.first?.text == "恢复尾文")
        #expect(try await store.transcriptRevisions(lineID:"one").isEmpty)
        await store.close()
    }

    @Test func checkpointCannotOverwriteFinalOrAnotherGeneration() async throws {
        let (store, session, _) = try await fixture()
        _ = try await store.appendLine(row(session, id: "final").line.lineDraft, id: "final")
        let checkpoint = WindowCheckpointCommand(sessionID: session, id: "final", expectedText: "合成正文",
            text: "篡改", observedAt: Date(timeIntervalSince1970: 100))
        await #expect(throws: (any Error).self) { try await store.saveWindowCheckpoint(checkpoint) }
        #expect(try await store.lines(sessionID: session).first?.text == "合成正文")
        await store.close()
    }

    @Test func newWindowRowsRemainReadableByTheSchema13ReadonlyQuery() async throws {
        let (store, session, directory) = try await fixture()
        let command = SealedWindowCommand(transactionID:"transaction",sessionID:session,
            rows:[row(session,id:"fixed")],savedThrough:96000,
            checkpoint:.init(sessionID:session,id:"tail",expectedText:nil,text:"待确认尾文",
                observedAt:Date(timeIntervalSince1970:100)))
        _ = try await store.appendSealedWindow(command)
        await store.close()
        var pointer: OpaquePointer?
        #expect(sqlite3_open_v2(directory.appendingPathComponent(SessionStore.fileName).path,
            &pointer,SQLITE_OPEN_READONLY,nil) == SQLITE_OK)
        let db = try #require(pointer)
        defer { sqlite3_close_v2(db) }
        // Column order and status predicate used by the pre-window v13 reader.
        let sql = """
        SELECT id, session_id, ordinal, role, speaker_label, text, t_start, t_end, source, status,
               interrupted, device_switch, starred, timing_quality, created_at
        FROM line WHERE session_id = ? AND status = 'final' ORDER BY ordinal ASC;
        """
        var query: OpaquePointer?
        #expect(sqlite3_prepare_v2(db,sql,-1,&query,nil) == SQLITE_OK)
        let statement = try #require(query)
        defer { sqlite3_finalize(statement) }
        session.withCString { _ = sqlite3_bind_text(statement,1,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString:sqlite3_column_text(statement,0)) == "fixed")
        #expect(String(cString:sqlite3_column_text(statement,5)) == "合成正文")
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        #expect(sqlite3_exec(db,"DELETE FROM line;",nil,nil,nil) == SQLITE_READONLY)
    }
}


@MainActor struct TranscriptWindowCaptureTests {
    @Test func lagStatusChangesWithoutReplacingVisibleTextOrReusingRevision() async throws {
        let capture = TranscriptWindowCapture(recordID: "record",
            identity: .init(connection: 1, generation: 1), source: .microphone,
            offsetSeconds: 0, observedAt: Date(), save: { command in
                WindowSaveAck(transactionID: command.id, lineOrdinals: [:], savedThrough: 0)
            })
        let original = try TranscriptWindowLedgerTests().fixture("window-updated-r2")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["falling_behind"] = true
        let slow = try JSONDecoder().decode(TranscriptWindowEvent.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(capture.apply(slow, observedAt: Date()) == .snapshot)
        #expect(capture.fallingBehind && capture.statusText == "识别稍慢，正在追赶")
        let text = capture.visibleText
        json["falling_behind"] = false
        let invalid = try JSONDecoder().decode(TranscriptWindowEvent.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(capture.apply(invalid, observedAt: Date()) == .rejected)
        #expect(capture.fallingBehind)
        json["window_revision"] = 3
        let caughtUp = try JSONDecoder().decode(TranscriptWindowEvent.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(capture.apply(caughtUp, observedAt: Date()) == .snapshot)
        #expect(!capture.fallingBehind && capture.visibleText == text)
        await capture.retryPending()
    }

    @Test func refusedBatchRetainsItsCheckpointUntilOrderedRetry() async throws {
        let (store, session, _) = try await TranscriptWindowPersistenceTests().fixture()
        var unblock: CheckedContinuation<Void, Never>?
        var writes = 0
        let capture = TranscriptWindowCapture(recordID: session,
            identity: .init(connection: 1, generation: 1), source: .microphone,
            offsetSeconds: 0, observedAt: Date(timeIntervalSince1970: 100), maximumPendingCommands: 1,
            save: { command in
                writes += 1
                if writes == 1 { await withCheckedContinuation { unblock = $0 } }
                switch command { case .sealed(let batch): return try await store.appendSealedWindow(batch)
                case .checkpoint(let cp):
                    try await store.saveWindowCheckpoint(cp)
                    return WindowSaveAck(transactionID: cp.id, lineOrdinals: [:], savedThrough: 0)
                }
            })
        let events = TranscriptWindowLedgerTests()
        _ = capture.apply(try events.fixture("window-updated-r2"), observedAt: Date(timeIntervalSince1970: 100))
        while unblock == nil { await Task.yield() }
        #expect(!capture.recoveryCommands.isEmpty)
        _ = capture.apply(try events.fixture("window-sealed-r6"), observedAt: Date(timeIntervalSince1970: 101))
        #expect(capture.blockedCommand != nil)
        capture.retainTail()
        #expect(capture.queue.pending.isEmpty)
        unblock?.resume()
        await capture.retryPending()
        #expect(capture.blockedCommand == nil)
        #expect(capture.queue.isComplete)
        #expect(capture.queue.savedThrough == 96000)
        #expect(try await store.lines(sessionID: session).count == 1)
        await store.close()
    }

    @Test func activeCommandsRemainAvailableForRecoveryAndCountAgainstCoalescing() async {
        var unblock: CheckedContinuation<Void, Never>?
        let queue = TranscriptWindowPersistenceQueue(maximumScalars: 10, save: { command in
            await withCheckedContinuation { unblock = $0 }
            return WindowSaveAck(transactionID: "save", lineOrdinals: [:], savedThrough: 0)
        })
        func cp(_ id: String, _ text: String) -> WindowCheckpointCommand {
            .init(sessionID: "session", id: id, expectedText: nil, text: text, observedAt: Date())
        }
        #expect(queue.enqueue(.checkpoint(cp("active", "12345678"))) == .accepted)
        while unblock == nil { await Task.yield() }
        #expect(queue.ownedCommands.count == 1)
        #expect(queue.enqueue(.checkpoint(cp("pending", "1"))) == .accepted)
        #expect(queue.enqueue(.checkpoint(cp("pending", "123"))) == .capacityExceeded)
        unblock?.resume()
        // Release the next admitted command as well.
        unblock = nil
        while unblock == nil { await Task.yield() }
        unblock?.resume()
        await queue.waitUntilSettled()
        #expect(queue.ownedCommands.isEmpty)
    }

    @Test func windowAndStoreAcknowledgmentStaySeparate() async throws {
        let (store, session, _) = try await TranscriptWindowPersistenceTests().fixture()
        let capture = TranscriptWindowCapture(recordID: session,
            identity: .init(connection: 1, generation: 1), source: .microphone,
            offsetSeconds: 0, observedAt: Date(timeIntervalSince1970: 100),
            save: { command in
                switch command { case .sealed(let batch): return try await store.appendSealedWindow(batch)
                case .checkpoint(let cp):
                    try await store.saveWindowCheckpoint(cp)
                    return WindowSaveAck(transactionID: cp.id, lineOrdinals: [:], savedThrough: 0)
                }
            })
        let events = TranscriptWindowLedgerTests()
        #expect(capture.apply(try events.fixture("window-updated-r2"), observedAt: Date(timeIntervalSince1970: 100)) == .snapshot)
        #expect(capture.visibleText.isEmpty == false)
        #expect(capture.apply(try events.fixture("window-sealed-r6"), observedAt: Date(timeIntervalSince1970: 101)) == .seal)
        try await capture.waitSaved(through: 96000)
        #expect(capture.queue.savedThrough == 96000)
        #expect(try await store.lines(sessionID: session).count == 1)
        #expect(capture.apply(try events.fixture("window-sealed-replay"), observedAt: Date(timeIntervalSince1970: 102)) == .duplicate)
        await store.close()
    }
}
