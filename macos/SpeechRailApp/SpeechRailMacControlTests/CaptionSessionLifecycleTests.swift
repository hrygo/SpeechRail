import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
final class CaptionSessionLifecycleTests: XCTestCase {
    private var harness: Harness?

    func testBandContentIncludesWindowTextAndChangesForSameUnitCorrection() throws {
        let event = try TranscriptWindowLedgerTests().fixture("window-updated-r2")
        let first = CaptionBandContent(lines: [], windowUnits: event.units, partialText: "旧半句")
        XCTAssertEqual(first.rows.map(\.text), ["合成测试。"])
        XCTAssertTrue(try XCTUnwrap(first.rows.first).isPartial)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        var units = try XCTUnwrap(json["units"] as? [[String: Any]])
        units[0]["text"] = "同一句回溯后变长，需要继续保持末行可见。"
        units[0]["text_revision"] = 2
        json["units"] = units
        let corrected = try JSONDecoder().decode(TranscriptWindowEvent.self,
            from: JSONSerialization.data(withJSONObject: json))
        let next = CaptionBandContent(lines: [], windowUnits: corrected.units, partialText: nil)
        XCTAssertEqual(first.rows.map(\.id), next.rows.map(\.id))
        XCTAssertNotEqual(first, next, "同一单元字数变化也必须触发末行跟随和高度重算")

        units[0]["text_revision"] = 3
        json["units"] = units
        let heartbeat = try JSONDecoder().decode(TranscriptWindowEvent.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(next, CaptionBandContent(lines: [], windowUnits: heartbeat.units, partialText: nil),
            "没有文字变化的协议修订不应触发滚动")
        XCTAssertTrue(CaptionBandContent(lines: [], windowUnits: [], partialText: "旧半句").rows.isEmpty)
    }

    func testBandContentTracksSameCountFinalCorrectionAndLegacyPartial() {
        var line = CaptionSession.Line(id: "line", ordinal: 1, text: "合成定稿", start: nil,
            end: nil, speakerLabel: nil)
        let first = CaptionBandContent(lines: [line], windowUnits: nil, partialText: "正在增长的半句")
        XCTAssertEqual(first.rows.map(\.text), ["合成定稿", "正在增长的半句"])
        XCTAssertEqual(first.rows.map(\.isPartial), [false, true])
        line.text = "修正后更长的合成定稿"
        let corrected = CaptionBandContent(lines: [line], windowUnits: nil, partialText: "正在增长的半句")
        XCTAssertEqual(first.rows.map(\.id), corrected.rows.map(\.id))
        XCTAssertNotEqual(first, corrected)
        XCTAssertNotEqual(corrected, CaptionBandContent(lines: [line], windowUnits: nil, partialText: "半句继续增长"))
    }

    override func tearDown() async throws {
        if let harness {
            if harness.coordinator.occupancy != nil {
                await harness.coordinator.finalize(reason: .user)
            }
            await harness.store.close()
            harness.defaults.removePersistentDomain(forName: harness.defaultsName)
            try? FileManager.default.removeItem(at: harness.directory)
        }
        harness = nil
        try await super.tearDown()
    }

    private func makeHarness(
        saveLine: (@Sendable (LineDraft, String) async throws -> Int)? = nil,
        attachSpeakerLabel: (@Sendable (String, String?) async throws -> Void)? = nil,
        configuration: TranscriptPersistenceQueue.Configuration = .init(),
        makeRealtimeClient: (@Sendable (CaptionRealtimeClientConfiguration) -> any CaptionRealtimeClient)? = nil,
        drainTimeout: Duration = .seconds(12),
        receiverGateForFirst: ConnectGate? = nil,
        revisionWindowEnabled: Bool = false
    ) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = SessionStore(directory: directory)
        try await store.open()

        let defaultsName = "caption-lifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()

        let audio = ControllableCaptionAudioSource()
        let clients = CaptionClientRegistry(receiverGateForFirst: receiverGateForFirst)
        let dependencies = CaptionSessionDependencies(
            makeRealtimeClient: { configuration in
                makeRealtimeClient?(configuration) ?? clients.make(configuration)
            },
            persistenceConfiguration: configuration,
            saveLine: saveLine,
            attachSpeakerLabel: attachSpeakerLabel,
            drainTimeout: drainTimeout,
            revisionWindowEnabled:revisionWindowEnabled
        )
        let session = CaptionSession(
            coordinator: coordinator,
            dependencies: dependencies,
            audioSourceFactory: { audio }
        )
        session.serviceReadiness = { .ready(profile: "test") }
        coordinator.starter = { kind in
            guard kind == .captions else {
                throw SessionCoordinator.CapabilityNotWired(kind: kind)
            }
            try await session.beginCapture()
        }
        coordinator.stopper = { kind in
            guard kind == .captions else { return }
            await session.stopCapture()
        }

        let harness = Harness(
            directory: directory,
            defaultsName: defaultsName,
            defaults: defaults,
            store: store,
            coordinator: coordinator,
            session: session,
            audio: audio,
            clients: clients
        )
        self.harness = harness
        return harness
    }

    private func start(_ harness: Harness) async throws -> String {
        await harness.session.openBand()
        try await harness.settle { $0.session.phase == .running }
        return try XCTUnwrap(
            harness.session.sessionID,
            harness.session.blocked?.detail ?? harness.session.lastFailure ?? "没有建立字幕记录"
        )
    }

    func testWindowSealWithoutPreviewPersistsOnceAndCompletesStoreBarrier() async throws {
        let h = try await makeHarness(revisionWindowEnabled:true)
        let id = try await start(h)
        let sealed = try TranscriptWindowLedgerTests().fixture("window-sealed-r6")
        try await h.emit(.transcriptionWindow(sealed))
        try await h.emit(.transcriptionWindow(try TranscriptWindowLedgerTests().fixture("window-sealed-replay")))
        try await h.emit(.completed(itemID:"item-1",transcript:sealed.finalUnits![0].text))
        try await h.settle { $0.session.lines.count == 1 }
        await h.session.finish()
        XCTAssertEqual(h.session.windowCapture?.queue.savedThrough,96000)
        let saved = try await h.store.lines(sessionID:id)
        XCTAssertEqual(saved.count,1)
        XCTAssertNil(h.coordinator.captureCompletionFailure(recordID:id))
    }

    func testLateUploadFailureCannotPolluteTheNextRecord() async throws {
        let gate = ConnectGate()
        let h = try await makeHarness(drainTimeout: .milliseconds(80))
        let id = try await start(h)
        let old = try XCTUnwrap(h.clients.all.last)

        await old.failAppend(gate: gate)
        h.audio.emit(AudioChunk(pcm: Data([0, 1]), level: 0.2))
        for _ in 0..<100 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        await h.coordinator.finalize(reason: .user)
        let nextID = try await start(h)
        XCTAssertNotEqual(id, nextID)
        XCTAssertNil(h.session.lastFailure)
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(h.session.lastFailure)
        XCTAssertNil(h.coordinator.captureCompletionFailure(recordID: nextID))
    }

    func testBufferedBusyDuringStopDoesNotStartASecondInterruptionCleanup() async throws {
        let h = try await makeHarness()
        let id = try await start(h)
        let client = try XCTUnwrap(h.clients.all.last)
        await client.setDrainEvents([.serverError(code: "backend_busy", message: "忙碌", requestID: nil)])
        await h.coordinator.finalize(reason: .user)
        XCTAssertEqual(h.session.phase, .idle)
        let closes = await client.closeCount
        XCTAssertEqual(closes, 1)
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
    }

    func testUploadFailureCannotBeHiddenBySuccessfulDrain() async throws {
        let h = try await makeHarness()
        let id = try await start(h)
        let client = try XCTUnwrap(h.clients.all.last)
        await client.failAppend()
        h.audio.emit(AudioChunk(pcm: Data([0, 1]), level: 0.2))
        await h.coordinator.finalize(reason: .user)
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
        XCTAssertEqual(h.coordinator.captureCompletionFailure(recordID: id)?.stage, .upload)
    }

    func testDiarizationDrainFailureStillRecordsDegradedState() async throws {
        let h = try await makeHarness()
        h.session.diarizationPreference = { true }
        let id = try await start(h)
        let client = try XCTUnwrap(h.clients.all.last)
        await client.failDiarizationDrain()
        await h.coordinator.finalize(reason: .user)
        let record = try await h.store.session(id: id)
        XCTAssertEqual(record?.diarization, .degraded)
        XCTAssertNotEqual(record?.state, .archived)
    }

    func testAlignmentFailureKeepsItsReasonAndTextAfterAuxiliaryExpiry() async throws {
        let h = try await makeHarness()
        h.session.diarizationPreference = { true }
        let id = try await start(h)
        try await h.emit(.completed(itemID: "aligned-item", transcript: "保留的字幕正文"))
        try await h.settle { $0.session.lines.count == 1 }
        try await h.emit(.attribution(itemID: "aligned-item", units: [
            .init(segmentUID: "before-failure", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.settle { $0.session.lines.first?.speakerLabel == "A" }
        try await h.emit(.alignmentFailed(
            itemID: "aligned-item", code: "alignment_timeout", message: "private backend detail"
        ))
        try await h.settle { $0.session.labeling.state == .degraded }
        let reason = try XCTUnwrap(h.session.labeling.note)
        XCTAssertEqual(h.session.labeling.diagnosticCode, "alignment_timeout")
        XCTAssertFalse(reason.contains("private backend detail"))
        XCTAssertTrue(reason.contains("超时"))

        try await h.emit(.auxiliaryIncomplete(
            itemID: "aligned-item", alignmentMissing: true, diarizationMissing: true
        ))
        try await h.settle { $0.session.lastFailure != nil }
        XCTAssertEqual(h.session.labeling.note, reason)
        XCTAssertEqual(h.session.labeling.diagnosticCode, "alignment_timeout")
        XCTAssertEqual(h.session.lastFailure, reason)
        let record = try await h.store.session(id: id)
        XCTAssertEqual(record?.diarizationNote, reason)
        XCTAssertEqual(h.session.lines.map(\.text), ["保留的字幕正文"])
        XCTAssertEqual(h.session.phase, .running)
        XCTAssertEqual(h.session.lines.first?.speakerLabel, "A")
        try await h.emit(.completed(itemID: "next-item", transcript: "后续仍能分人"))
        try await h.emit(.attribution(itemID: "next-item", units: [
            .init(segmentUID: "after-failure", speaker: "B", timingQuality: "aligned")
        ], isFinal: true))
        try await h.settle { $0.session.lines.last?.speakerLabel == "B" }
        XCTAssertEqual(h.session.labeling.labels, ["A", "B"])
    }

    func testAlignmentFailureWithoutDiarizationIsNotReplacedByWindowExpiry() async throws {
        let h = try await makeHarness()
        h.session.diarizationPreference = { false }
        _ = try await start(h)
        try await h.emit(.alignmentFailed(itemID: "A", code: "text_mismatch", message: ""))
        try await h.settle { $0.session.lastFailure != nil }
        let reason = h.session.lastFailure
        try await h.emit(.auxiliaryIncomplete(
            itemID: "A", alignmentMissing: true, diarizationMissing: false
        ))
        try await h.emit(.completed(itemID: "B", transcript: "仍在继续"))
        try await h.settle { $0.session.lines.count == 1 }
        XCTAssertEqual(h.session.lastFailure, reason)
        XCTAssertEqual(h.session.labeling.state, .off)
    }

    /// Gap1（字幕侧）：分人单项不可用不拦整场。
    ///
    /// 与会议侧同构：建两条连接（第一条带分人被拒，第二条不带分人成功），
    /// 库里记 `unavailable` + 人话，正文照常落库。
    func testWindowUnavailableFallsBackBeforeAudioAndKeepsCaptionRunning() async throws {
        let h = try await makeHarness(revisionWindowEnabled:true)
        h.session.diarizationPreference = { true }
        h.clients.failFirstDiarizedConnect(RealtimeASRClient.Failure.serverError(
            code:"unsupported_operation",message:"revision window unavailable"))
        _ = try await start(h)
        XCTAssertEqual(h.clients.madeConfigurations.count,2)
        XCTAssertEqual(h.clients.madeConfigurations.map(\.windowScene),[.caption,nil])
        XCTAssertTrue(h.clients.madeConfigurations.allSatisfy(\.diarizationEnabled))
        XCTAssertNotNil(h.session.transcriptionStatusText)
        XCTAssertNil(h.session.windowCapture)
    }

    func testDiarizationUnavailableFallsBackAndKeepsCaptionRunning() async throws {
        let h = try await makeHarness()
        h.session.diarizationPreference = { true }
        h.clients.failFirstDiarizedConnect(
            RealtimeASRClient.Failure.serverError(
                code: "backend_not_ready", message: "alignment unavailable"
            )
        )
        let id = try await start(h)

        let configurations = h.clients.madeConfigurations
        XCTAssertEqual(configurations.count, 2, "降级只重试一次")
        XCTAssertEqual(configurations.map(\.diarizationEnabled), [true, false])
        XCTAssertNil(h.session.blocked, "分人单项不可用不得拦下整场")

        try await h.emit(.completed(itemID: "A", transcript: "分人不可用时的字幕"))
        try await h.settle { $0.session.lines.count == 1 }

        let record = try await h.store.session(id: id)
        XCTAssertEqual(record?.diarization, .unavailable)
        XCTAssertEqual(record?.diarizationNote, "这场没有标出谁在说话；正文照常记录。")
        XCTAssertEqual(h.session.labeling.state, .unavailable)
    }

    /// Gap3（字幕侧）：中断续接不清空说话人面板。
    ///
    /// 与会议侧同构：中断前标出的标签是本场的事实，`retry()` 续接后
    /// 面板必须还在；新连接的归属照常写入（uid 重置不断新写），
    /// 库里的分人态也不被续接改写。账本级的 uid 语义由
    /// `SpeakerLabelingPersistenceTests` 钉住，这里只验端到端后果。
    func testRetryKeepsSpeakerPanelAndAcceptsNewAttribution() async throws {
        let h = try await makeHarness()
        h.session.diarizationPreference = { true }
        let id = try await start(h)

        // 中断前标出一位说话人。
        try await h.emit(.completed(itemID: "before", transcript: "中断前说的"))
        try await h.settle { $0.session.lines.count == 1 }
        try await h.emit(.attribution(itemID: "before", units: [
            .init(segmentUID: "unit-before", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.settle { !$0.session.labeling.labels.isEmpty }
        XCTAssertEqual(h.session.labeling.labels, ["A"])

        // 走生产中断→续接路径：连接断开，点"重新接上"。
        try await h.emit(.closed(code: nil))
        try await h.settle { $0.session.blocked != nil }
        await h.session.retry()
        try await h.settle {
            $0.session.phase == .running && $0.session.blocked == nil
                && $0.clients.all.count >= 2
        }

        // 面板保留，库里的分人态不被续接改写。
        XCTAssertEqual(h.session.labeling.labels, ["A"])
        let record = try await h.store.session(id: id)
        XCTAssertEqual(record?.diarization, .active)

        // 新连接的归属照常写入：旧行不动，新行标上。
        try await h.emit(.completed(itemID: "after", transcript: "续接后说的"))
        try await h.settle { $0.session.lines.count == 2 }
        try await h.emit(.attribution(itemID: "after", units: [
            .init(segmentUID: "unit-after", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.serverError(code: "control", message: "续接归属栅栏", requestID: nil))
        try await h.settle { $0.session.lastFailure == "续接归属栅栏" }
        let saved = await h.session.waitForPendingSaves(recordID: id)
        XCTAssertTrue(saved.isComplete)
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.text == "中断前说的" }?.speakerLabel, "A")
        XCTAssertEqual(rows.first { $0.text == "续接后说的" }?.speakerLabel, "A")
    }

    func testProtocolFailureCannotArchiveEmptyCaptionAsComplete() async throws {
        let h = try await makeHarness()
        let id = try await start(h)
        let client = try XCTUnwrap(h.clients.all.last)
        await client.failDrain()
        await h.session.finish()
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
        XCTAssertNil(h.coordinator.lastFinalizedSessionID)
        XCTAssertNil(h.coordinator.occupancy)
        XCTAssertNotNil(h.session.lastFailure)
    }

    func testWindowProtocolFailureCannotClaimSavedAfterBandCloses() async throws {
        let h = try await makeHarness(revisionWindowEnabled: true)
        let id = try await start(h)
        try await h.emit(.transcriptionWindow(try TranscriptWindowLedgerTests().fixture("window-sealed-r6")))
        try await h.settle { $0.session.lines.count == 1 }
        let client = try XCTUnwrap(h.clients.all.last)
        await client.setDrainEvents([.serverError(code: "invalid_window_receipt",
            message: "语音事件未通过检查。", requestID: nil)])
        await client.failDrain()
        await h.session.finish()
        XCTAssertEqual(h.session.phase, .idle)
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
        XCTAssertEqual(h.session.transcriptionStatusText, "字幕收尾尚未确认")
        XCTAssertEqual(h.session.completionDiagnosticCode, "invalid_window_receipt")
        _ = try await start(h)
        XCTAssertNil(h.session.completionDiagnosticCode)
    }

    func testArchiveFailureCannotClaimSavedAfterBandCloses() async throws {
        let h = try await makeHarness(revisionWindowEnabled: true)
        let id = try await start(h)
        try await h.emit(.transcriptionWindow(try TranscriptWindowLedgerTests().fixture("window-sealed-r6")))
        try await h.settle { $0.session.lines.count == 1 }
        try await h.store.execute("CREATE TEMP TRIGGER reject_caption_archive BEFORE UPDATE OF state ON session WHEN NEW.state = 'archived' BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        await h.session.finish()
        XCTAssertEqual(h.session.phase, .idle)
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
        XCTAssertNotNil(h.coordinator.pendingSeals[id])
        XCTAssertEqual(h.session.transcriptionStatusText, "字幕收尾尚未确认")
    }

    func testReceiverDeadlineCannotSealCaptionAndLateBufferedFinalIsDiscarded() async throws {
        let receiver = ConnectGate()
        let h = try await makeHarness(
            drainTimeout: .milliseconds(80), receiverGateForFirst: receiver
        )
        let id = try await start(h)
        let client = try XCTUnwrap(h.clients.all.last)
        await client.setDrainEvents([.completed(itemID: "tail", transcript: "超时的字幕尾句")])
        var stopped = false
        let stop = Task {
            await h.session.finish()
            stopped = true
        }
        for _ in 0..<100 {
            if stopped { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(stopped)
        XCTAssertNil(h.coordinator.occupancy)
        XCTAssertNotNil(h.session.lastFailure)
        await stop.value
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
        let nextID = try await start(h)
        let next = try XCTUnwrap(h.clients.all.last)
        await next.emit(.completed(itemID: "tail", transcript: "新字幕只接纳新连接"))
        await receiver.open()
        try await h.settle { $0.session.lines.contains { $0.text == "新字幕只接纳新连接" } }
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertTrue(rows.isEmpty)
        let nextRows = try await h.store.lines(sessionID: nextID)
        XCTAssertEqual(nextRows.map(\.text), ["新字幕只接纳新连接"])
    }

    func testFinalSaveFailureRetainsOneFrozenCommandAndRetriesWithoutCompletedReplay() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "item", transcript: "字幕定稿只到一次。"))
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let command = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        XCTAssertEqual(command.text, "字幕定稿只到一次。")
        XCTAssertEqual(command.role, .speaker)
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered)
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, command.lineID)
        let attempts = await gate.attempts
        XCTAssertEqual(attempts.map(\.id), [command.lineID, command.lineID])
        XCTAssertEqual(try XCTUnwrap(rows.first?.createdAt).timeIntervalSince1970,
                       command.observedAt.timeIntervalSince1970, accuracy: 0.000001)
    }

    func testPendingCaptionSaveConsumesControlAndCachesEarlyAttribution() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "item", transcript: "缓存归属字幕"))
        try await h.settle { _ in await gate.entered }
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "unit", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.serverError(code: "test_control", message: "字幕控制事件已消费", requestID: nil))
        try await h.settle { $0.session.lastFailure == "字幕控制事件已消费" }
        await gate.release()
        let settled = await h.session.waitForPendingSaves(recordID: id)
        XCTAssertTrue(settled.isComplete)
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.text, "缓存归属字幕")
        XCTAssertEqual(rows.first?.timingQuality, .aligned)
    }

    func testSavedCaptionAttributionHonoursProjectionCapacity() async throws {
        let h = try await makeHarness(configuration: .init(maximumPendingProjections: 0))
        let id = try await start(h)
        try await h.emit(.completed(itemID: "item", transcript: "已保存字幕正文"))
        try await h.settle { $0.session.lines.count == 1 }
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "unit", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.serverError(code: "control", message: "容量后控制", requestID: nil))
        try await h.settle { $0.session.lastFailure == "容量后控制" }
        _ = await h.session.waitForPendingSaves(recordID: id)
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.text), ["已保存字幕正文"])
        XCTAssertEqual(rows.first?.timingQuality, .unavailable, "rejected auxiliary work must not run inline")
    }

    func testBlockedCaptionMetadataKeepsControlResponsiveAndSettlementPending() async throws {
        let gate = SpeakerAttributionWriteGate()
        let h = try await makeHarness(attachSpeakerLabel: { try await gate.write($0, label: $1) })
        await gate.attach(h.store)
        h.session.diarizationPreference = { true }
        let id = try await start(h)
        try await h.emit(.completed(itemID: "item", transcript: "metadata等待中的字幕正文"))
        try await h.settle { $0.session.lines.count == 1 }
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "unit", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.settle { _ in await gate.entered }
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "unit", speaker: "B", timingQuality: "aligned")
        ], isFinal: false))
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "another-unit", speaker: nil, timingQuality: "unavailable")
        ], isFinal: true))
        try await h.emit(.serverError(code: "control", message: "metadata等待时控制", requestID: nil))
        var settled = false
        let waiter = Task {
            _ = await h.session.waitForPendingSaves(recordID: id)
            settled = true
        }
        for _ in 0..<200 {
            if h.session.lastFailure == "metadata等待时控制" { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(h.session.lastFailure, "metadata等待时控制")
        XCTAssertFalse(settled)
        XCTAssertTrue(h.session.pendingSaveRecordIDs.contains(id))
        await gate.release()
        await waiter.value
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.speakerLabel, "B", "accepted unit revisions must survive a later partial batch")
        XCTAssertEqual(rows.first?.timingQuality, .aligned)
        XCTAssertEqual(h.session.lines.first?.speakerLabel, "B")
    }

    func testExplicitIncompleteCaptionEndPreservesPreviewInsteadOfClaimingFullSave() async throws {
        let h = try await makeHarness(configuration: .init(maximumPendingCommands: 0))
        let id = try await start(h)
        try await h.emit(.completed(itemID: "rejected", transcript: "字幕拒绝的恢复预览"))
        try await h.settle { !$0.session.unsavedTranscriptText(recordID: id).isEmpty }
        let snapshot = try XCTUnwrap(h.session.admissionRecovery(recordID: id))
        let ended = await h.session.endIncompleteRecord(snapshot)
        XCTAssertTrue(ended)
        XCTAssertFalse(h.session.pendingSaveRecordIDs.contains(id))
        let record = try await h.store.session(id: id)
        XCTAssertEqual(record?.state, .archived)
        XCTAssertEqual(record?.endReason, .interrupted)
        let formal = try await h.store.lines(sessionID: id)
        let all = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertTrue(formal.isEmpty)
        XCTAssertEqual(all.map(\.id), [snapshot.id])
        XCTAssertTrue(all.first?.text.contains("本记录未完整保存") == true)
    }

    func testIncompleteCaptionEndCannotDiscardAnAcceptedFailedCommand() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(
            saveLine: { try await gate.save($0, id: $1) }, configuration: .init(maximumPendingCommands: 1)
        )
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "accepted", transcript: "已接纳的字幕正文"))
        try await h.settle { _ in await gate.entered }
        try await h.emit(.completed(itemID: "rejected", transcript: "拒绝的字幕预览"))
        try await h.settle { $0.session.admissionRecovery(recordID: id) != nil }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let failedID = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first?.lineID)
        let snapshot = try XCTUnwrap(h.session.admissionRecovery(recordID: id))
        let refused = await h.session.endIncompleteRecord(snapshot)
        XCTAssertFalse(refused)
        XCTAssertEqual(h.session.pendingSaveCommands(recordID: id).map(\.lineID), [failedID])
        XCTAssertEqual(h.session.admissionRecovery(recordID: id), snapshot)
        await gate.release()
        _ = await h.session.retryPendingSaves(recordID: id)
        let completed = await h.session.endIncompleteRecord(snapshot)
        XCTAssertTrue(completed)
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.id), [failedID])
        XCTAssertEqual(rows.map(\.text), ["已接纳的字幕正文"])
    }

    func testEndingOldIncompleteCaptionRecordLeavesNewCaptureAndLabelsAlone() async throws {
        let h = try await makeHarness(configuration: .init(maximumPendingCommands: 0))
        let old = try await start(h)
        try await h.emit(.completed(itemID: "old", transcript: "旧字幕拒绝内容"))
        try await h.settle { $0.session.admissionRecovery(recordID: old) != nil }
        let snapshot = try XCTUnwrap(h.session.admissionRecovery(recordID: old))
        await h.session.stopCapture()
        let current = try await start(h)
        let completed = await h.session.endIncompleteRecord(snapshot)
        XCTAssertTrue(completed)
        XCTAssertEqual(h.session.sessionID, current)
        XCTAssertEqual(h.session.phase, .running)
        XCTAssertEqual(h.coordinator.activeSessionID, current)
        XCTAssertTrue(h.session.lines.isEmpty)
        let currentRows = try await h.store.lines(sessionID: current, includePartial: true)
        XCTAssertTrue(currentRows.isEmpty)
    }

    func testIncompleteCaptionPreviewFailureKeepsRefusalProofUntilRetryCommits() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(
            saveLine: { try await gate.save($0, id: $1) }, configuration: .init(maximumPendingCommands: 0)
        )
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "rejected", transcript: "字幕预览保存失败"))
        try await h.settle { $0.session.admissionRecovery(recordID: id) != nil }
        let snapshot = try XCTUnwrap(h.session.admissionRecovery(recordID: id))
        await gate.release(failing: true)
        let first = await h.session.endIncompleteRecord(snapshot)
        XCTAssertFalse(first)
        XCTAssertEqual(h.session.admissionRecovery(recordID: id), snapshot)
        let before = try await h.store.session(id: id)
        XCTAssertNotEqual(before?.state, .archived)
        await gate.release()
        let retried = await h.session.endIncompleteRecord(snapshot)
        XCTAssertTrue(retried)
        let attempts = await gate.attempts
        XCTAssertEqual(attempts.map(\.id), [snapshot.id, snapshot.id])
        let rows = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertEqual(rows.map(\.id), [snapshot.id])
    }

    func testIncompleteCaptionSealFailureRetainsRefusalUntilSameSnapshotRetry() async throws {
        let h = try await makeHarness(configuration: .init(maximumPendingCommands: 0))
        let id = try await start(h)
        try await h.emit(.completed(itemID: "rejected", transcript: "字幕封存失败后的恢复内容"))
        try await h.settle { $0.session.admissionRecovery(recordID: id) != nil }
        let snapshot = try XCTUnwrap(h.session.admissionRecovery(recordID: id))
        try executeTranscriptRecoverySQL(directory: h.directory, statement: """
            CREATE TRIGGER fail_recovery_archive BEFORE UPDATE OF state ON session
            BEGIN SELECT RAISE(ABORT, 'archive unavailable'); END;
            """)
        let failed = await h.session.endIncompleteRecord(snapshot)
        XCTAssertFalse(failed)
        XCTAssertEqual(h.session.admissionRecovery(recordID: id), snapshot)
        XCTAssertTrue(h.session.pendingSaveRecordIDs.contains(id))
        XCTAssertEqual(h.coordinator.pendingSeals[id]?.stage, .archive)
        let savedPreview = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertEqual(savedPreview.map(\.id), [snapshot.id])
        try executeTranscriptRecoverySQL(directory: h.directory, statement: "DROP TRIGGER fail_recovery_archive;")
        let completed = await h.session.endIncompleteRecord(snapshot)
        XCTAssertTrue(completed)
        XCTAssertNil(h.session.admissionRecovery(recordID: id))
        let rows = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertEqual(rows.map(\.id), [snapshot.id])
        let archived = try await h.store.session(id: id)
        XCTAssertEqual(archived?.state, .archived)
        XCTAssertEqual(archived?.endReason, .interrupted)
    }

    func testConcurrentIncompleteCaptionEndOnlyPersistsOneRecoveryCommand() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(
            saveLine: { try await gate.save($0, id: $1) }, configuration: .init(maximumPendingCommands: 0)
        )
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "rejected", transcript: "并发结束字幕恢复内容"))
        try await h.settle { $0.session.admissionRecovery(recordID: id) != nil }
        let snapshot = try XCTUnwrap(h.session.admissionRecovery(recordID: id))
        let first = Task { await h.session.endIncompleteRecord(snapshot) }
        try await h.settle { _ in await gate.entered }
        var secondFinished = false
        let second = Task {
            let result = await h.session.endIncompleteRecord(snapshot)
            secondFinished = true
            return result
        }
        try await h.settle { _ in
            if secondFinished { return true }
            return await gate.attempts.count > 1
        }
        await gate.release()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertFalse(secondResult)
        let attempts = await gate.attempts
        XCTAssertEqual(attempts.map(\.id), [snapshot.id])
        XCTAssertNil(h.session.admissionRecovery(recordID: id))
        let rows = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertEqual(rows.map(\.id), [snapshot.id])
    }

    func testEndingIncompleteCaptionReleasesRejectedItemAttributionBudgetForNewRecord() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(
            saveLine: { try await gate.save($0, id: $1) }, configuration: .init(maximumPendingCommands: 1)
        )
        await gate.attach(h.store)
        let old = try await start(h)
        try await h.emit(.completed(itemID: "accepted", transcript: "旧字幕已接纳正文"))
        try await h.settle { _ in await gate.entered }
        for index in 0..<128 {
            let itemID = "rejected-\(index)"
            try await h.emit(.completed(itemID: itemID, transcript: "旧字幕拒绝内容"))
            try await h.emit(.attribution(itemID: itemID, units: [
                .init(segmentUID: itemID, speaker: "A")
            ], isFinal: true))
        }
        try await h.emit(.serverError(code: "cache_gate", message: "旧缓存已接纳", requestID: nil))
        try await h.settle { $0.session.lastFailure?.contains("旧缓存已接纳") == true }
        let snapshot = try XCTUnwrap(h.session.admissionRecovery(recordID: old))
        XCTAssertEqual(snapshot.rejectionCount, 128)
        await gate.release()
        let ended = await h.session.endIncompleteRecord(snapshot)
        XCTAssertTrue(ended)
        let current = try await start(h)
        try await h.emit(.segmentClosed(
            itemID: "new", sampleSpan: .init(startSample: 0, endSample: 24_000),
            reason: .vad, commitEventID: nil
        ))
        try await h.emit(.attribution(itemID: "new", units: [
            .init(segmentUID: "new-unit", speaker: "A", textStart: 0, textEnd: 6,
                  audioStartSample: 0, audioEndSample: 24_000, timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.completed(itemID: "new", transcript: "新字幕正文"))
        try await h.settle { !$0.session.lines.isEmpty }
        let saved = await h.session.waitForPendingSaves(recordID: current)
        XCTAssertTrue(saved.isComplete)
        let rows = try await h.store.lines(sessionID: current)
        XCTAssertEqual(rows.first?.timingQuality, .aligned, "closed record metadata must not consume the new record budget")
    }

    func testCaptionRecoveryPartialAlsoRetainsFixedIdentityAndStaysOutOfFormalRows() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.partialSnapshot(itemID: "partial", revision: 1, text: "只有恢复预览。"))
        try await h.emit(.completed(itemID: "partial", transcript: ""))
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let command = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        XCTAssertFalse(command.formal)
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered)
        let formal = try await h.store.lines(sessionID: id)
        XCTAssertTrue(formal.isEmpty)
        let all = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertEqual(all.map(\.id), [command.lineID])
        XCTAssertEqual(all.first?.status, .partial)
        XCTAssertTrue(h.session.lines.isEmpty)
    }

    func testFailedCaptionItemKeepsRecoverablePartialCommandAfterStoreFailure() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.partialSnapshot(itemID: "failed", revision: 1, text: "字幕失败前的预览"))
        try await h.emit(.failed(itemID: "failed", code: "asr_failed", message: "识别未完成"))
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let command = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        XCTAssertFalse(command.formal)
        XCTAssertEqual(command.text, "字幕失败前的预览")
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered)
        let formal = try await h.store.lines(sessionID: id)
        let all = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertTrue(formal.isEmpty)
        XCTAssertEqual(all.map(\.id), [command.lineID])
        XCTAssertEqual(all.first?.status, .partial)
        XCTAssertTrue(h.session.lines.isEmpty)
    }

    func testCaptionCapacityRejectionRemainsIncompleteAfterAcceptedSaveDrains() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(
            saveLine: { try await gate.save($0, id: $1) },
            configuration: .init(maximumPendingCommands: 1)
        )
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "accepted", transcript: "接纳的字幕"))
        try await h.settle { _ in await gate.entered }
        try await h.emit(.completed(itemID: "refused", transcript: "未接纳的字幕"))
        try await h.emit(.serverError(code: "test_control", message: "容量拒绝后控制继续", requestID: nil))
        try await h.settle { $0.session.lastFailure == "容量拒绝后控制继续" }
        await gate.release()
        let report = await h.session.waitForPendingSaves(recordID: id)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(h.session.unsavedTranscriptText(recordID: id), "未接纳的字幕")
        await h.session.finish()
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
        XCTAssertEqual(h.session.pendingSaveRecordIDs, [id])
    }

    func testProductionClientRetriesSaveBeforeAnySecondCompletedAndSuppressesDuplicateTerminal() async throws {
        let gate = TranscriptPersistenceGate()
        let transport = TranscriptRealtimeTestTransport()
        let h = try await makeHarness(
            saveLine: { try await gate.save($0, id: $1) },
            makeRealtimeClient: { configuration in
                TranscriptRealtimeTestClient(
                    client: RealtimeASRClient(scenePreset: configuration.scenePreset, apiKey: ""),
                    transport: transport
                )
            }
        )
        await gate.attach(h.store)
        let id = try await start(h)
        try await transport.completed(itemID: "real-item", text: "真实客户端唯一终稿")
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let frozen = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered, "retry must finish before a second completed exists")
        let beforeDuplicate = try await h.store.lines(sessionID: id)
        XCTAssertEqual(beforeDuplicate.map(\.id), [frozen.lineID])
        XCTAssertEqual(beforeDuplicate.map(\.text), ["真实客户端唯一终稿"])
        try await transport.completed(itemID: "real-item", text: "重复终态不得覆盖")
        try await transport.control("重复终态之后的控制")
        try await h.settle { $0.session.lastFailure == "重复终态之后的控制" }
        let rows = try await h.store.lines(sessionID: id)
        let attempts = await gate.attempts
        XCTAssertEqual(rows.map(\.text), ["真实客户端唯一终稿"])
        XCTAssertEqual(attempts.map(\.id), [frozen.lineID, frozen.lineID])
    }

    func testFinishWaitsForSaveAndFailureCannotArchiveTheRecord() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "tail", transcript: "尚未保存的最后一句"))
        try await h.settle { _ in await gate.entered }
        let finish = Task { await h.session.finish() }
        try await h.settle { $0.session.phase == .ending }
        let pendingRecord = try await h.store.session(id: id)
        XCTAssertNil(pendingRecord?.endedAt)
        XCTAssertEqual(h.coordinator.activeSessionID, id)
        await gate.release(failing: true)
        await finish.value
        let failedRecord = try await h.store.session(id: id)
        XCTAssertNil(failedRecord?.endedAt)
        XCTAssertNotEqual(failedRecord?.state, .archived)
        XCTAssertEqual(h.session.pendingSaveRecordIDs, [id])
        XCTAssertEqual(h.session.unsavedTranscriptText(recordID: id), "尚未保存的最后一句")
    }

    func testOldFailedRecordRetryDoesNotProjectIntoNewCaptionRecord() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        h.session.diarizationPreference = { true }
        let oldID = try await start(h)
        try await h.emit(.attribution(itemID: "same-item", units: [
            .init(segmentUID: "same-unit", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.completed(itemID: "same-item", transcript: "上一场未保存"))
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: oldID).isEmpty }
        await h.session.finish()
        let newID = try await start(h)
        XCTAssertNotEqual(oldID, newID)
        await gate.release()
        try await h.emit(.attribution(itemID: "same-item", units: [
            .init(segmentUID: "same-unit", speaker: "B", timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.completed(itemID: "same-item", transcript: "新场正文"))
        let newSettled = await h.session.waitForPendingSaves(recordID: newID)
        XCTAssertTrue(newSettled.isComplete)
        try await h.settle { $0.session.lines.count == 1 }
        let recovered = await h.session.retryPendingSaves(recordID: oldID)
        XCTAssertTrue(recovered)
        let oldRows = try await h.store.lines(sessionID: oldID)
        let newRows = try await h.store.lines(sessionID: newID)
        XCTAssertEqual(oldRows.map(\.text), ["上一场未保存"])
        XCTAssertEqual(oldRows.first?.speakerLabel, "A")
        XCTAssertEqual(oldRows.first?.timingQuality, .aligned)
        XCTAssertEqual(newRows.map(\.text), ["新场正文"])
        XCTAssertEqual(newRows.first?.speakerLabel, "B")
        XCTAssertEqual(h.session.lines.map(\.text), ["新场正文"])
        XCTAssertEqual(h.session.labeling.labels, ["B"])
        XCTAssertEqual(h.session.sessionID, newID)
        XCTAssertEqual(h.coordinator.activeSessionID, newID)
    }

    /// The production session keeps previews and frozen input ranges per item.
    /// A later final for A must not replace or inherit B input ownership.
    func testInterleavedAndLateItemsKeepTheirOwnTextAndInputRanges() async throws {
        let harness = try await makeHarness()
        let sessionID = try await start(harness)
        let spanA = RealtimeASRClient.RealtimeSampleSpan(startSample: 0, endSample: 24_000)
        let spanB = RealtimeASRClient.RealtimeSampleSpan(startSample: 24_000, endSample: 48_000)

        try await harness.emit(.partial(itemID: "A", delta: "A 的预览"))
        try await harness.emit(.partialSnapshot(itemID: "B", revision: 1, text: "B 的预览"))
        try await harness.emit(
            .segmentClosed(
                itemID: "A",
                sampleSpan: spanA,
                reason: .vad,
                commitEventID: nil
            )
        )
        try await harness.emit(
            .segmentClosed(
                itemID: "B",
                sampleSpan: spanB,
                reason: .vad,
                commitEventID: nil
            )
        )

        try await harness.emit(.completed(itemID: "B", transcript: "B 的终稿"))
        try await harness.settle { $0.session.lines.count == 1 }
        try await harness.emit(.completed(itemID: "A", transcript: "A 的终稿"))
        try await harness.settle { $0.session.lines.count == 2 }

        let lines = try await harness.store.lines(sessionID: sessionID)
        let lineA = try XCTUnwrap(lines.first { $0.text == "A 的终稿" })
        let lineB = try XCTUnwrap(lines.first { $0.text == "B 的终稿" })
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try XCTUnwrap(lineA.tStart), 0, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(lineA.tEnd), 1, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(lineB.tStart), 1, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(lineB.tEnd), 2, accuracy: 0.02)
    }

    /// Ending is an owner barrier: the final produced by drain must be saved
    /// before the coordinator archives the caption session.
    func testFinishPersistsTheFinalProducedByDrainBeforeArchive() async throws {
        let harness = try await makeHarness()
        let sessionID = try await start(harness)
        let client = try XCTUnwrap(harness.clients.all.first)
        harness.audio.emit(AudioChunk(pcm: Data([0, 1]), level: 0.2))
        harness.audio.emit(AudioChunk(pcm: Data([2, 3]), level: 0.3))
        await client.setDrainEvents([
            .segmentClosed(
                itemID: "tail",
                sampleSpan: .init(startSample: 0, endSample: 24_000),
                reason: .clientCommit,
                commitEventID: "caption-drain-commit"
            ),
            .completed(itemID: "tail", transcript: "停录前最后一句")
        ])

        await harness.session.finish()

        let lines = try await harness.store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.map(\.text), ["停录前最后一句"])
        let appendedAtDrain = await client.appendedByteCountAtDrain
        let appendedBytes = await client.appendedByteCount
        XCTAssertEqual(appendedAtDrain, 4, "提交 drain 前必须上传采集流里已缓冲的两块音频")
        XCTAssertEqual(appendedBytes, 4, "已缓冲音频只上传一次")
        let storedRecord = try await harness.store.session(id: sessionID)
        let record = try XCTUnwrap(storedRecord)
        XCTAssertEqual(record.state, .archived)
    }

    /// A failed terminal keeps the item preview available as recovery text.
    func testFailedItemKeepsItsPreviewVisibleForRecovery() async throws {
        let harness = try await makeHarness()
        _ = try await start(harness)

        try await harness.emit(
            .partialSnapshot(itemID: "recoverable", revision: 1, text: "失败前已经显示的句子")
        )
        try await harness.settle { $0.session.partialText == "失败前已经显示的句子" }
        try await harness.emit(
            .failed(itemID: "recoverable", code: "asr_failed", message: "未能识别")
        )
        try await harness.settle { $0.session.lastFailure?.contains("asr_failed") == true }

        XCTAssertEqual(harness.session.partialText, "失败前已经显示的句子")
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        let persistedLines = try await harness.store.lines(sessionID: sessionID)
        XCTAssertTrue(persistedLines.isEmpty)
    }

    @MainActor
    private final class Harness {
        let directory: URL
        let defaultsName: String
        let defaults: UserDefaults
        let store: SessionStore
        let coordinator: SessionCoordinator
        let session: CaptionSession
        let audio: ControllableCaptionAudioSource
        let clients: CaptionClientRegistry

        init(
            directory: URL,
            defaultsName: String,
            defaults: UserDefaults,
            store: SessionStore,
            coordinator: SessionCoordinator,
            session: CaptionSession,
            audio: ControllableCaptionAudioSource,
            clients: CaptionClientRegistry
        ) {
            self.directory = directory
            self.defaultsName = defaultsName
            self.defaults = defaults
            self.store = store
            self.coordinator = coordinator
            self.session = session
            self.audio = audio
            self.clients = clients
        }

        func emit(_ payload: RealtimeASRClient.Event) async throws {
            let client = try XCTUnwrap(clients.all.last)
            await client.emit(payload)
        }

        func settle(
            until predicate: @MainActor (Harness) async -> Bool,
            timeout: Duration = .seconds(5)
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while clock.now < deadline {
            if await predicate(self) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(
            "等待超时：phase=\(session.phase.rawValue)，events=\(clients.all.count)，"
                + "blocked=\(session.blocked?.detail ?? session.lastFailure ?? "none")"
        )
        }
    }
}

private final class ControllableCaptionAudioSource: AudioChunkSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AudioChunkStream.Continuation?

    func start() async throws -> AudioChunkStream {
        let pair = AudioChunkStream.makeStream()
        setContinuation(pair.continuation)
        return pair.stream
    }

    private func setContinuation(_ value: AudioChunkStream.Continuation) {
        lock.lock()
        continuation = value
        lock.unlock()
    }

    func stop() async {
        let current = lock.withLock { let current = continuation; continuation = nil; return current }
        current?.finish()
    }

    func emit(_ chunk: AudioChunk) {
        lock.lock()
        let current = continuation
        lock.unlock()
        current?.offer(chunk)
    }
}

private actor ControllableCaptionRealtimeClient: CaptionRealtimeClient {
    private let stream = RealtimeEventStream<RealtimeASRClient.Event>()
    private var drainEvents: [RealtimeASRClient.Event] = []
    private var windowSealedThrough = 0
    private var drainFails = false
    private var appendFails = false
    private var appendGate: ConnectGate?
    private var diarizationDrainFails = false
    private var connectOnceFailure: Error?
    private let receiverGate: ConnectGate?
    private(set) var drainCount = 0
    private(set) var closeCount = 0
    private(set) var appendedByteCount = 0
    private(set) var appendedByteCountAtDrain = 0

    init(receiverGate: ConnectGate? = nil, initialConnectFailure: Error? = nil) {
        self.receiverGate = receiverGate
        self.connectOnceFailure = initialConnectFailure
    }
    func events() async -> RealtimeEventStream<RealtimeASRClient.Event> {
        if let receiverGate { try? await receiverGate.wait() }
        return stream
    }
    /// 让**下一次** `connect()` 抛错一次，之后恢复正常（Gap1 降级续跑用）。
    func failConnectOnce(_ error: Error) { connectOnceFailure = error }
    func connect() async throws {
        if let failure = connectOnceFailure {
            connectOnceFailure = nil
            closeCount += 1
            throw failure
        }
    }
    func failAppend(gate: ConnectGate? = nil) { appendFails = true; appendGate = gate }
    func failDiarizationDrain() { diarizationDrainFails = true }
    func append(_ pcm: Data) async throws {
        if let appendGate { try await appendGate.wait() }
        if appendFails { throw URLError(.networkConnectionLost) }
        appendedByteCount += pcm.count
    }

    func setDrainEvents(_ events: [RealtimeASRClient.Event]) {
        drainEvents = events
    }
    func failDrain() { drainFails = true }

    func drainAndClear(timeout: Duration) async throws {
        try await drainAndClear(timeout:timeout,beforeAuxiliary:{ _ in })
    }
    func drainAndClear(timeout: Duration, beforeAuxiliary: @escaping @Sendable (Int) async throws -> Void) async throws {
        drainCount += 1
        appendedByteCountAtDrain = appendedByteCount
        let events = drainEvents
        drainEvents = []
        for event in events {
            await emit(event)
        }
        try await beforeAuxiliary(windowSealedThrough)
        if diarizationDrainFails { throw RealtimeASRClient.Failure.drainTimedOut(.diarization) }
        if drainFails { throw URLError(.timedOut) }
    }

    func close() async {
        closeCount += 1
        await stream.finish()
    }

    func emit(_ payload: RealtimeASRClient.Event) async {
        if case .transcriptionWindow(let window) = payload {
            windowSealedThrough = window.sealedThroughSample
        }
        _ = await stream.yield(
            RealtimeEventEnvelope(
                metadata: RealtimeEventMetadata(),
                payload: payload
            )
        )
    }
}

private final class CaptionClientRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ControllableCaptionRealtimeClient] = []
    private var configurations: [CaptionRealtimeClientConfiguration] = []
    private var failFirstDiarizedConnectError: Error?
    private let receiverGateForFirst: ConnectGate?

    init(receiverGateForFirst: ConnectGate? = nil) { self.receiverGateForFirst = receiverGateForFirst }

    func make(_ configuration: CaptionRealtimeClientConfiguration) -> any CaptionRealtimeClient {
        lock.lock()
        // 布防的失败经构造器一次带入：`Task { await client.failConnectOnce(...) }`
        // 与随后 `connect()` 的执行顺序无保证，偶发布防失效、测试自以为在验降级
        // 实际上首连成功了——断言全绿，验的却不是那一件事。
        var initialFailure: Error?
        if let error = failFirstDiarizedConnectError, configuration.diarizationEnabled {
            failFirstDiarizedConnectError = nil
            initialFailure = error
        }
        let client = ControllableCaptionRealtimeClient(
            receiverGate: storage.isEmpty ? receiverGateForFirst : nil,
            initialConnectFailure: initialFailure
        )
        storage.append(client)
        configurations.append(configuration)
        lock.unlock()
        return client
    }

    /// 让接下来那条**带分人**的连接在 `connect()` 抛错一次，之后恢复正常。
    func failFirstDiarizedConnect(_ error: Error) {
        lock.lock()
        failFirstDiarizedConnectError = error
        lock.unlock()
    }

    var madeConfigurations: [CaptionRealtimeClientConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }

    var all: [ControllableCaptionRealtimeClient] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
