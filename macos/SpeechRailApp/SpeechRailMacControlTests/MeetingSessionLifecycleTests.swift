import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 会议编排层的端到端生命周期（MA-01 收尾，场景 MC-05～MC-08、MC-16）。
///
/// 这一层此前只有**接缝本身**的测试（`MeetingConnectionGeneration` 那个值类型），
/// 生产 `MeetingSession` 一次都没被驱动过——"旧连接不许写进新连接"这条不变量，
/// 在真正会用到它的那段代码里没有任何回归。
///
/// 现在 `MeetingSession` 进了单测目标（设备 / 连接 / 时钟 / 睡眠通知都经
/// `MeetingSessionDependencies` 注入），这些场景才第一次能在无设备环境下跑起来。
/// 钉的是**后果**：谁占了设备、谁写了记录、界面相位是什么、哪条连接还在收音频。
@MainActor
final class MeetingSessionLifecycleTests: XCTestCase {
    private var harness: Harness?

    override func tearDown() async throws {
        if let harness { await harness.store.close() }
        harness = nil
        try await super.tearDown()
    }

    private func makeHarness(
        saveLine: (@Sendable (LineDraft, String) async throws -> Int)? = nil,
        configuration: TranscriptPersistenceQueue.Configuration = .init(),
        makeRealtimeClient: (@Sendable (MeetingRealtimeClientConfiguration) -> any MeetingRealtimeClient)? = nil
    ) async throws -> Harness {
        let harness = try await Harness.make(
            saveLine: saveLine, configuration: configuration, makeRealtimeClient: makeRealtimeClient
        )
        self.harness = harness
        return harness
    }

    func testFinalFailureKeepsFrozenCommandAndExplicitRetryNeedsNoSecondCompleted() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let id = try XCTUnwrap(h.session.sessionID)
        try await h.emit(.completed(itemID: "fixed-item", transcript: "只接收一次定稿正文。"))
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let command = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        XCTAssertEqual(command.text, "只接收一次定稿正文。")
        XCTAssertEqual(command.role, .speaker)
        XCTAssertEqual(command.source, .microphone)
        XCTAssertEqual(command.timingQuality, .unavailable)
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered)
        let rows = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, command.lineID)
        XCTAssertEqual(rows.first?.status, .final, "saving a final must not create a partial substitute")
        let attempts = await gate.attempts
        XCTAssertEqual(attempts.map(\.id), [command.lineID, command.lineID])
        XCTAssertEqual(try XCTUnwrap(rows.first?.createdAt).timeIntervalSince1970,
                       command.observedAt.timeIntervalSince1970, accuracy: 0.000001)
    }

    func testPendingSaveDoesNotBlockControlAndAttributionArrivingBeforeSaveIsReplayed() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let id = try XCTUnwrap(h.session.sessionID)
        let span = RealtimeASRClient.RealtimeSampleSpan(startSample: 0, endSample: 24_000)
        try await h.emit(.segmentClosed(itemID: "item", sampleSpan: span, reason: .vad, commitEventID: nil))
        try await h.emit(.completed(itemID: "item", transcript: "缓存归属正文"))
        try await h.settle { _ in await gate.entered }
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "unit", speaker: "A", textStart: 0, textEnd: 6,
                  audioStartSample: 0, audioEndSample: 24_000, timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.serverError(code: "test_control", message: "控制事件已消费", requestID: nil))
        try await h.settle { $0.session.lastFailure == "test_control：控制事件已消费" }
        await gate.release()
        let settled = await h.session.waitForPendingSaves(recordID: id)
        XCTAssertTrue(settled.isComplete)
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.text, "缓存归属正文")
        XCTAssertEqual(rows.first?.timingQuality, .aligned)
    }

    func testCapacityFailureKeepsAcceptedCommandAndControlReceiverResponsive() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(
            saveLine: { try await gate.save($0, id: $1) },
            configuration: .init(maximumPendingCommands: 1)
        )
        await gate.attach(h.store)
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let id = try XCTUnwrap(h.session.sessionID)
        try await h.emit(.completed(itemID: "first", transcript: "先接纳的正文"))
        try await h.settle { _ in await gate.entered }
        try await h.emit(.completed(itemID: "second", transcript: "容量外的正文"))
        try await h.emit(.serverError(code: "test_control", message: "容量满时仍消费控制", requestID: nil))
        try await h.settle { $0.session.lastFailure == "test_control：容量满时仍消费控制" }
        XCTAssertEqual(h.session.pendingSaveCommands(recordID: id).map(\.text), ["先接纳的正文"])
        await gate.release()
        let settled = await h.session.waitForPendingSaves(recordID: id)
        XCTAssertFalse(settled.isComplete, "容量拒绝不能在已接纳命令排空后变成全部保存")
        XCTAssertEqual(h.session.unsavedTranscriptText(recordID: id), "容量外的正文")
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.text), ["先接纳的正文"])
        await h.clients.all.last?.finishEventsOnClose()
        let result = await h.coordinator.finalize(reason: .user)
        XCTAssertEqual(result, .skipped(recordID: id))
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
    }

    func testFailedItemRecoveryRetainsFixedPartialCommandAfterStoreFailure() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let id = try XCTUnwrap(h.session.sessionID)
        try await h.emit(.partialSnapshot(itemID: "failed", revision: 1, text: "会议失败前的预览"))
        try await h.emit(.failed(itemID: "failed", code: "asr_failed", message: "识别未完成"))
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let command = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        XCTAssertFalse(command.formal)
        XCTAssertEqual(command.text, "会议失败前的预览")
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered)
        let formal = try await h.store.lines(sessionID: id)
        let all = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertTrue(formal.isEmpty)
        XCTAssertEqual(all.map(\.id), [command.lineID])
        XCTAssertTrue(h.session.lines.isEmpty)
    }

    func testRejectedRecoveryMaterialDoesNotClaimItIsBeingSaved() async throws {
        let h = try await makeHarness(configuration: .init(maximumPendingCommands: 0))
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let id = try XCTUnwrap(h.session.sessionID)
        try await h.emit(.partialSnapshot(itemID: "recovery", revision: 1, text: "容量外的恢复材料"))
        try await h.emit(.completed(itemID: "recovery", transcript: ""))
        try await h.settle { $0.session.pendingSaveRecordIDs == [id] }
        let hint = try XCTUnwrap(h.session.lastFailure)
        XCTAssertTrue(hint.contains("请先复制"))
        XCTAssertFalse(hint.contains("正在保留"))
        let report = await h.session.waitForPendingSaves(recordID: id)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(h.session.unsavedTranscriptText(recordID: id), "容量外的恢复材料")
    }

    func testMeetingProductionClientSaveRetryDoesNotNeedTerminalReplay() async throws {
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
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let id = try XCTUnwrap(h.session.sessionID)
        try await transport.completed(itemID: "real-item", text: "会议真实客户端唯一终稿")
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let frozen = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered)
        let beforeDuplicate = try await h.store.lines(sessionID: id)
        XCTAssertEqual(beforeDuplicate.map(\.id), [frozen.lineID])
        try await transport.completed(itemID: "real-item", text: "重复终态不得覆盖")
        try await transport.control("已越过重复终态")
        try await h.settle { $0.session.lastFailure == "test_control：已越过重复终态" }
        let rows = try await h.store.lines(sessionID: id)
        let attempts = await gate.attempts
        XCTAssertEqual(rows.map(\.text), ["会议真实客户端唯一终稿"])
        XCTAssertEqual(attempts.map(\.id), [frozen.lineID, frozen.lineID])
        await h.session.stopCapture()
    }

    func testMeetingFinalizeWaitsForSaveAndFailureDoesNotArchive() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let id = try XCTUnwrap(h.session.sessionID)
        await h.clients.all.last?.finishEventsOnClose()
        try await h.emit(.completed(itemID: "tail", transcript: "会议最后一句未存"))
        try await h.settle { _ in await gate.entered }
        let finish = Task { await h.coordinator.finalize(reason: .user) }
        try await h.settle { _ in await h.clients.all.last?.closeCount == 1 }
        let pendingRecord = try await h.store.session(id: id)
        XCTAssertNil(pendingRecord?.endedAt)
        XCTAssertEqual(h.coordinator.activeSessionID, id)
        await gate.release(failing: true)
        let result = await finish.value
        XCTAssertEqual(result, .skipped(recordID: id), "stopper撤销保存证明后不得归档")
        let failedRecord = try await h.store.session(id: id)
        XCTAssertNil(failedRecord?.endedAt)
        XCTAssertNotEqual(failedRecord?.state, .archived)
        XCTAssertEqual(h.session.pendingSaveRecordIDs, [id])
    }

    // MARK: - MC-08：采集起来了但建连失败

    /// 建连失败：设备、连接、租约都要**准确**收回，而且不得留下一条什么都没有的记录。
    ///
    /// 最后一条最容易漏：`begin()` 失败若不回退，`session` 表里会多一行
    /// "开过但没录到"的会，事后回看列表里就是一条空会。
    func testConnectFailureReleasesEverythingAndLeavesNoBlankRecord() async throws {
        let h = try await makeHarness()
        await h.clients.failNextConnect()

        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .idle }

        // 失败路径上采集会被停不止一次（`startPipeline` 的 catch 与 `beginCapture`
        // 的 catch 各喊一次）。两次都是防御性的幂等调用，所以断的是"收干净了没有"，
        // 不是"喊了几次"。
        XCTAssertGreaterThanOrEqual(h.audio.stopCount, 1, "建连失败必须把已经开起来的采集停掉")
        let firstClient = try XCTUnwrap(h.clients.all.first)
        let closed = await firstClient.closeCount
        XCTAssertGreaterThan(closed, 0, "建连失败的连接必须自己收尾，不能留着一条挂着的握手")
        XCTAssertNotEqual(h.session.phase, .recording, "失败不得停在录制态")
        XCTAssertNil(h.session.sessionID, "失败不得给自己一个会话 id")
        let count = try await h.store.sessionCount()
        XCTAssertEqual(count, 0, "失败的启动不得在库里留下空白记录")
        XCTAssertNil(h.coordinator.occupancy, "设备租约要收回，不能占着不让下一场开始")
        XCTAssertNil(h.coordinator.activeLeaseID)
        XCTAssertNotNil(h.session.blocked, "失败要有可读结论，而不是安静地什么都不发生")
    }

    /// 拦在更前面：采集自己没起来。设备从来没被拿过，就不该有"停掉采集"这回事。
    func testCaptureFailureDoesNotPretendItStarted() async throws {
        let h = try await makeHarness()
        h.audio.startError = h.captureFailure

        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .idle }

        // `beginCapture` 失败时无条件 `audio.stop()` 是**防御性**的：采集没过也照喊一次，
        // 对一个没起来的通道来说是幂等空操作。所以这里不断言 stop 次数，
        // 断的是"有没有留下东西"。
        XCTAssertEqual(h.clients.all.count, 0, "采集没过就不该去建连")
        let count = try await h.store.sessionCount()
        XCTAssertEqual(count, 0)
        XCTAssertNil(h.coordinator.occupancy)
        XCTAssertEqual(h.session.blocked, .microphoneDenied)
    }

    // MARK: - MC-05 / MC-06：启动挂起期间用户结束

    /// 启动到一半（建连还没回来）用户就结束了这一场。
    ///
    /// 旧启动回来之后**不得**把自己复活：不得把相位写成录制、不得给自己建记录。
    /// 钉的是这个后果，不是不变量本身——`MeetingConnectionGeneration` 的单测
    /// 已经证明令牌本身没问题，缺的是"启动流程会不会在被挂起之后重新领一代"。
    func testStartSuspendedAtConnectCannotResurrectAfterTheSessionEnded() async throws {
        let h = try await makeHarness()

        // 建连闸门默认关着：启动会停在 connect() 上。
        // 这一句**必须**放进 Task：直接 await 的话测试自己就堵在闸门上，
        // 永远轮不到下面去放行——那不是被测代码的问题，是测试把自己锁死了。
        let startTask = Task { await h.session.start(selection: MeetingAudioSelection()) }
        try await h.settle { await $0.clients.all.count == 1 }
        try await h.settle { $0.phase == .preparing }

        // 用户在这一场还没成型时结束它。
        // 走**界面真正会走的那条路**：`finishAndSummarize()`。直接调
        // `coordinator.stopCapture` 会绕开一段真实逻辑——那条路在 `sessionID`
        // 还没出来时压根不碰采集与代次，而这恰恰是要验的地方。
        await h.session.finishAndSummarize()
        // 结束之后本层相位必须离开「准备中」：没有记录就没有可整理的，
        // 停在准备态会让页面一直显示"正在准备"，像一场永远开不起来的会。
        try await h.settle { $0.phase == .idle }
        XCTAssertNotEqual(h.session.phase, .recording)

        // 旧启动现在才回来。
        await h.clients.openGate()
        await startTask.value
        try await h.settleBriefly()

        XCTAssertNotEqual(
            h.session.phase, .recording,
            "已经结束的场不许被一个迟到的启动改回录制态"
        )
        XCTAssertNil(h.session.sessionID, "迟到的启动不得给自己建记录")
        let count = try await h.store.sessionCount()
        XCTAssertEqual(count, 0, "迟到的启动不得在库里留下空白记录")
    }

    /// MC-06：会议 A 启动到一半，用户合法切到 B。A 迟到的结果只准收自己，B 的 id 不能被碰。
    func testLateStartOfSessionACannotStealSessionBsIdentity() async throws {
        let h = try await makeHarness()

        let startA = Task { await h.session.start(selection: MeetingAudioSelection()) }
        try await h.settle { await $0.clients.all.count == 1 }
        // 走**界面真正会走的那条路**：`finishAndSummarize()`。直接调
        // `coordinator.stopCapture` 会绕开一段真实逻辑——那条路在 `sessionID`
        // 还没出来时压根不碰采集与代次，而这恰恰是要验的地方。
        await h.session.finishAndSummarize()
        // 结束之后本层相位必须离开「准备中」：没有记录就没有可整理的，
        // 停在准备态会让页面一直显示"正在准备"，像一场永远开不起来的会。
        try await h.settle { $0.phase == .idle }

        // B 合法开始，并且必须成功。
        await h.clients.openGate()
        await startA.value
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let bID = try XCTUnwrap(h.session.sessionID)

        // A 迟到的结果现在才回来（闸门已开，它不会再挂）。
        try await h.settleBriefly()

        XCTAssertEqual(h.session.sessionID, bID, "A 迟到不得换掉 B 的会话 id")
        XCTAssertEqual(h.session.phase, .recording, "B 不该被 A 的迟到结果打断")
    }

    // MARK: - MC-07：两代连接交叠

    /// 睡眠中断后重连：只有新一代连接继续上行，旧连接不再收到音频。
    ///
    /// 走的是**生产路径**（睡眠接缝 → `enterInterruption` → `continueAfterInterruption`），
    /// 不是测试专用的钩子。
    func testOnlyTheNewestConnectionKeepsUpstreaming() async throws {
        let h = try await makeHarness()
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }

        h.audio.emit(AudioChunk(pcm: Data([0, 1]), level: 0.4))
        try await h.settleBriefly()
        let first = try XCTUnwrap(h.clients.all.first)
        let firstBytesBefore = await first.appendedByteCount
        XCTAssertGreaterThan(firstBytesBefore, 0, "第一代连接本来是在上行的")

        // 睡一觉 → 中断 → 续接（新一代连接）。
        h.power.fireSleep()
        try await h.settle { $0.phase == .interrupted }
        await h.session.continueAfterInterruption()
        try await h.settle { $0.phase == .recording }
        try await h.settle { await $0.clients.all.count >= 2 }

        let second = try XCTUnwrap(h.clients.all.last)
        XCTAssertNotEqual(
            ObjectIdentifier(first), ObjectIdentifier(second), "重连必须是一条新连接"
        )

        h.audio.emit(AudioChunk(pcm: Data([2, 3]), level: 0.5))
        try await h.settleBriefly()

        let firstBytesAfter = await first.appendedByteCount
        let secondBytes = await second.appendedByteCount
        XCTAssertGreaterThan(secondBytes, 0, "新连接必须能上行")
        XCTAssertEqual(firstBytesAfter, firstBytesBefore, "旧连接不得再收到音频")
    }

    // MARK: - MC-16：暂停前后不拼句

    /// 暂停一次恰好切一刀，继续一次不切；再暂停再切。
    ///
    /// 切少了就是前后黏成一句（那句跨越了没录上的时间，是假的）；
    /// 切多了等于把一句正常的话拆成几句。
    func testPauseCutsExactlyOncePerPause() async throws {
        let h = try await makeHarness()
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let client = try XCTUnwrap(h.clients.all.last)

        XCTAssertFalse(h.session.isPaused)
        await h.session.togglePause()
        XCTAssertTrue(h.session.isPaused, "按了暂停要真的停")
        var flushes = await client.flushCount
        XCTAssertEqual(flushes, 1, "暂停一次切一刀")

        await h.session.togglePause()
        XCTAssertFalse(h.session.isPaused, "再按一次要恢复")
        flushes = await client.flushCount
        XCTAssertEqual(flushes, 1, "恢复不切：上一刀已经把边界划出来了")

        await h.session.togglePause()
        flushes = await client.flushCount
        XCTAssertEqual(flushes, 2, "第二次暂停再切一刀")
    }

    /// 暂停期间一个音频都不许再上行；恢复后重新上行。
    ///
    /// 切句和停上行是两件事：切句划边界，停上行是不录。少任何一样，
    /// "暂停"就都名不副实。
    func testNoAudioIsUploadedWhilePaused() async throws {
        let h = try await makeHarness()
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let client = try XCTUnwrap(h.clients.all.last)

        h.audio.emit(AudioChunk(pcm: Data([0, 1]), level: 0.4))
        try await h.settleBriefly()

        await h.session.togglePause()
        let atPause = await client.appendedByteCount
        h.audio.emit(AudioChunk(pcm: Data([2, 3]), level: 0.5))
        try await h.settleBriefly()
        var bytes = await client.appendedByteCount
        XCTAssertEqual(bytes, atPause, "暂停期间不得再上行")

        await h.session.togglePause()
        h.audio.emit(AudioChunk(pcm: Data([4, 5]), level: 0.5))
        try await h.settleBriefly()
        bytes = await client.appendedByteCount
        XCTAssertGreaterThan(bytes, atPause, "恢复后要能接着上行")
    }

    // MARK: - MC-02：没配置对话模型时，会议本身不算失败

    /// 没填对话模型时，**文字记录照旧可用**，只有纪要那一步标成"待配置"。
    ///
    /// 这一条此前没有任何回归：它是"AI 不可用不许连累会议记录"的分界线。
    /// 判错的方向很具体——把整场会议显示成失败，用户会以为这半小时白开了，
    /// 于是重开一次；其实文字都在。
    ///
    /// `LLMConfiguration()` 是空的，`LLMProvider` 在本地就抛 `notConfigured`
    /// （`guard configuration.isConfigured`），不碰网络，所以这条是确定性的。
    func testUnconfiguredModelKeepsTheTranscriptAndOnlyMarksMinutes() async throws {
        let h = try await makeHarness()
        let record = try await h.coordinator.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        _ = try await h.store.appendLine(
            LineDraft(
                sessionID: record.id,
                role: .speaker,
                text: "预算按 35 万元报。",
                source: .microphone,
                status: .final
            )
        )

        let generator = MinutesGenerator(coordinator: h.coordinator)
        await generator.generate(sessionID: record.id, configuration: LLMConfiguration())
        try await h.settleBriefly()

        // 失败的是纪要，不是会议。
        guard case .failed = generator.state else {
            return XCTFail("没配置模型时纪要必须落失败，实际是 \(generator.state)")
        }
        XCTAssertTrue(
            generator.failureNeedsSetup,
            "没填模型要给「去设置里填」，不能给「重新生成」——后者只会原样再失败一次"
        )

        // 文字记录完好：关掉重开（这里用同一个库重读一次）仍能取回。
        let lines = try await h.store.lines(sessionID: record.id)
        XCTAssertEqual(lines.map(\.text), ["预算按 35 万元报。"], "文字记录必须完好")
        let record_ = try await h.store.session(id: record.id)
        XCTAssertNotNil(record_, "会议记录必须还在")

        // 不得有任何一版纪要自称整理好了。
        let usable = try await h.store.latestUsableMinutes(sessionID: record.id)
        XCTAssertNil(usable, "没有模型就不该有可用版本；空正文或失败任务不得显示成功")
    }

    // MARK: - 验收 3：改了来源，当场就要提示复核

    /// 改一次说话人显示名，依赖这份来源的纪要**当场**被标成需复核。
    ///
    /// 此前这条是断的：改名/合并/标记「我」/拆出四条路径写完 `speaker_revision`
    /// 就结束，谁也不重算复核状态。界面上"需复核"要等下一次重新整理或重开才出现，
    /// 用户看到的是"我改了名字，什么提示都没有"——验收标准 3 说的
    /// 「修改来源后相关结论提示复核」在最主要的触发路径上根本没接上。
    ///
    /// 走**生产路径**：真的启动一场会，再经 `MeetingSession.renameSpeaker` 改名。
    func testRenamingASpeakerMarksTheMinutesForReviewRightAway() async throws {
        let (h, _, minutesID) = try await makeStartedMeetingWithMinutes()

        // 改显示名 = 追加一条说话人修订。
        await h.session.renameSpeaker(label: "A", to: "张三")

        let pending = h.session.minutes.versionsNeedingReview
        XCTAssertTrue(
            pending.contains(minutesID),
            "改名之后必须当场提示复核，不能等下一次重新整理才出现"
        )
        let needsReview = try await h.store.minutesNeedsReview(minutesID: minutesID)
        XCTAssertTrue(needsReview, "库这一层的判断也应当是同一结论")
    }

    /// 合并说话人同样要当场提示复核——它内部就是 `rename`。
    ///
    /// 上一节只钉了改名，把"共用代码"当成覆盖。这一条把它落实：
    /// 合并是用户改归属的常用入口（「这两条其实是同一个人」），
    /// 它写的也是一条 `kind='speaker'` 修订。
    func testMergingSpeakersMarksTheMinutesForReviewRightAway() async throws {
        let (h, _, minutesID) = try await makeStartedMeetingWithMinutes()
        await h.session.renameSpeaker(label: "A", to: "张三")
        let baseline = h.session.minutes.versionsNeedingReview
        XCTAssertTrue(baseline.contains(minutesID), "前置：改名已经让它需复核")

        // 把 B 并进已改名的 A：内部会以 A 的显示名给 B 补一次改名。
        await h.session.merge(label: "B", into: "A")
        let pending = h.session.minutes.versionsNeedingReview
        XCTAssertTrue(pending.contains(minutesID), "合并同样要当场提示复核")
        let revisions = try await h.store.speakerRevisions(sessionID: try XCTUnwrap(h.session.sessionID))
        XCTAssertGreaterThanOrEqual(
            revisions.count, 2,
            "合并要真的写下第二条修订；只刷界面不算数"
        )
    }

    /// 标记「我」也是同一条路径（`markAsMe` → `rename`）。
    func testMarkingAsMeMarksTheMinutesForReviewRightAway() async throws {
        let (h, _, minutesID) = try await makeStartedMeetingWithMinutes()
        await h.session.markAsMe(label: "A")
        XCTAssertTrue(
            h.session.minutes.versionsNeedingReview.contains(minutesID),
            "标记「我」同样要当场提示复核"
        )
    }

    /// 拆出**也**要提示复核——事件记在用户动作这一层，不在 `attachSpeakerLabel`。
    ///
    /// 用户说"这几句不是他说的"，是一次有意的更正，和改名同一类：依据旧归属的
    /// 结论该被提示复核。此前它不提示，而**不能**顺手去改 `attachSpeakerLabel`——
    /// 那条同时是实时对齐写归属的路径，在那里记会被每次对齐到达刷屏。
    func testSplittingSpeakersMarksTheMinutesForReview() async throws {
        let h = try await makeHarness()
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let sessionID = try XCTUnwrap(h.session.sessionID)
        _ = try await h.store.appendLine(
            LineDraft(
                sessionID: sessionID, role: .speaker, text: "这一句先归给 A。",
                source: .microphone, tStart: 0, status: .final
            ),
            id: "\(sessionID)-line"
        )
        let minutes = try await h.store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await h.store.claimMinutes(sessionID: sessionID, lease: 600)
        try await h.store.finishMinutesForTestOnly(minutesID: minutes.id, body: "# 纪要", model: nil)

        await h.session.split(lineIDs: ["\(sessionID)-line"], to: "B")

        let revisions = try await h.store.speakerRevisions(sessionID: sessionID)
        XCTAssertEqual(
            revisions.count, 1,
            "拆出要记一条归属修订；一次拆出记一条，不是每行一条"
        )
        XCTAssertTrue(
            h.session.minutes.versionsNeedingReview.contains(minutes.id),
            "拆出改了归属，依赖旧归属的纪要必须当场提示复核"
        )
        let needsReview = try await h.store.minutesNeedsReview(minutesID: minutes.id)
        XCTAssertTrue(needsReview, "库这一层的判断也应当是同一结论")
    }

    /// 实时对齐写归属**不得**被当成用户改来源。
    ///
    /// 这是上一条成立的前提：`attachSpeakerLabel` 也服务于对齐证据的迟到到达。
    /// 若在那里记修订事件，每次对齐到达都会给这一场盖上一个复核标记，
    /// 真正需要提示的那批会被淹掉。
    func testAlignmentWritingAttributionDoesNotMarkTheMinutesForReview() async throws {
        let h = try await makeHarness()
        // 这一条只验库层，不启动会议：对齐到达走的是 `attachSpeakerLabel` 本身。
        let record = try await h.store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        let sessionID = record.id
        let lineID = "\(sessionID)-line"
        _ = try await h.store.appendLine(
            LineDraft(
                sessionID: sessionID, role: .speaker, text: "这一句先归给 A。",
                source: .microphone, tStart: 0, status: .final
            ),
            id: lineID
        )
        let minutes = try await h.store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await h.store.claimMinutes(sessionID: sessionID, lease: 600)
        try await h.store.finishMinutesForTestOnly(minutesID: minutes.id, body: "# 纪要", model: nil)

        // 对齐证据迟到：只写归属，不写修订事件。
        try await h.store.attachSpeakerLabel(lineID: lineID, label: "A")

        let revisions = try await h.store.speakerRevisions(sessionID: sessionID)
        XCTAssertTrue(revisions.isEmpty, "对齐写归属不是用户动作，不得刷出复核标记")
        let needsReview = try await h.store.minutesNeedsReview(minutesID: minutes.id)
        XCTAssertFalse(needsReview)
    }

    /// 启动一场会并给它一版整理好的纪要。
    private func makeStartedMeetingWithMinutes() async throws -> (Harness, String, String) {
        let h = try await makeHarness()
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection())
        try await h.settle { $0.phase == .recording }
        let sessionID = try XCTUnwrap(h.session.sessionID)
        let minutes = try await h.store.enqueueMinutes(
            sessionID: sessionID, model: nil, promptChars: 8
        )
        _ = try await h.store.claimMinutes(sessionID: sessionID, lease: 600)
        try await h.store.finishMinutesForTestOnly(minutesID: minutes.id, body: "# 纪要", model: nil)
        return (h, sessionID, minutes.id)
    }
}

// MARK: - 夹具

extension MeetingSessionLifecycleTests {
    /// 一个会议会话 + 它脚下那些可替换的外部世界。
    @MainActor
    final class Harness {
        let store: SessionStore
        let coordinator: SessionCoordinator
        let session: MeetingSession
        let audio: ControllableAudioSource
        let clients: ClientRegistry
        let power: MeetingPowerMonitorForTests
        let directory: URL
        let captureFailure: MeetingAudioBlocked

        /// 界面相位。断言里写 `h.phase` 而不是 `h.session.phase`——
        /// 后者把"看的是哪一层"藏进了每一条断言里。
        var phase: MeetingSession.Phase { session.phase }

        private init(
            store: SessionStore,
            coordinator: SessionCoordinator,
            session: MeetingSession,
            audio: ControllableAudioSource,
            clients: ClientRegistry,
            power: MeetingPowerMonitorForTests,
            directory: URL
        ) {
            self.store = store
            self.coordinator = coordinator
            self.session = session
            self.audio = audio
            self.clients = clients
            self.power = power
            self.directory = directory
            self.captureFailure = MeetingAudioBlocked(reason: .microphoneDenied)
        }

        static func make(
            saveLine: (@Sendable (LineDraft, String) async throws -> Int)? = nil,
            configuration: TranscriptPersistenceQueue.Configuration = .init(),
            makeRealtimeClient: (@Sendable (MeetingRealtimeClientConfiguration) -> any MeetingRealtimeClient)? = nil
        ) async throws -> Harness {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("meeting-lifecycle-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = SessionStore(directory: directory)
            try await store.open()

            let defaults = UserDefaults(suiteName: "meeting-lifecycle-\(UUID().uuidString)") ?? .standard
            let coordinator = SessionCoordinator(store: store, defaults: defaults)
            await coordinator.openStore()

            let audio = ControllableAudioSource()
            let clients = ClientRegistry()
            let power = MeetingPowerMonitorForTests()
            let dependencies = MeetingSessionDependencies(
                makeAudioSource: { audio },
                makeRealtimeClient: { configuration in
                    makeRealtimeClient?(configuration) ?? clients.make(configuration)
                },
                powerMonitor: power,
                persistenceConfiguration: configuration,
                saveLine: saveLine
            )
            let session = MeetingSession(coordinator: coordinator, dependencies: dependencies)
            coordinator.starter = { _ in try await session.beginCapture() }
            coordinator.stopper = { _ in await session.stopCapture() }
            return Harness(
                store: store,
                coordinator: coordinator,
                session: session,
                audio: audio,
                clients: clients,
                power: power,
                directory: directory
            )
        }

        /// 等到 `predicate` 为真。
        ///
        /// 生产代码整条链都是异步的，测试只能轮询——但轮询的是**可观察后果**
        /// （相位、连接数），不是内部调用次数。轮询不等于放水：超时照样失败。
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
            XCTFail("等待超时：相位 \(session.phase.rawValue)，连接数 \(await clients.all.count)，"
                + "blocked=\(session.blocked?.detail ?? session.lastFailure ?? "none")")
        }

        /// 让已经在飞的东西走完一小段，而不是等某个具体状态。
        func settleBriefly() async throws {
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)) }
        }

        /// 往**当前那一代**连接投一条服务端事件。
        ///
        /// 投给"最后一条"连接而不是"第一条"：重连场景（MC-13）里新服务
        /// 才拥有事件流，投错连接的话测试会意外地通过——
        /// 事件进了旧连接，而旧连接早就不被消费了。
        func emit(_ payload: RealtimeASRClient.Event) async throws {
            let client = try XCTUnwrap(clients.all.last, "还没有连接：先把会议开起来再投事件")
            await client.emit(payload)
        }

        /// 往**指定第几代**连接投事件。MC-14 需要往**已被换下的旧连接**上投，
        /// 那种情况下"最后一条"恰恰是投错的——要投的正是不能被消费的那条。
        func emit(_ payload: RealtimeASRClient.Event, toGeneration index: Int) async throws {
            let all = clients.all
            let client = try XCTUnwrap(
                all.indices.contains(index) ? all[index] : nil,
                "第 \(index) 代连接还不存在"
            )
            await client.emit(payload)
        }
    }
    // MARK: - 会前轻量标题（MA-10 / 方案 §4.1 / MC-04）
    //
    // 「第一屏主动作开始记录，保留轻量标题和来源摘要。**标题可为空**、
    // 项目可稍后补；不要为了归档要求用户先完成复杂表单。」
    //
    // 此前台页上**一个输入框都没有**：用户开始会议之后，这一场在库里叫什么，
    // 只能等结束之后去知识库里改。而 MC-04 的验收原话是"已经输入标题和
    // 会前笔记 → 输入检查或开始失败后重试 → 输入原样保留"——没有输入框，
    // 那条验收在真实路径上根本无法被触发。

    func testPreMeetingTitleBecomesTheSessionTitle() async throws {
        let h = try await makeHarness()
        await h.clients.openGate()
        await h.session.start(
            selection: MeetingAudioSelection(usesMicrophone: true),
            title: "周五发布评审"
        )
        try await h.settle { $0.phase == .recording }

        let id = try XCTUnwrap(h.session.sessionID)
        let record = try await h.store.session(id: id)
        XCTAssertEqual(
            record?.title, "周五发布评审",
            "用户会前写的标题就是这场会的名字，不该等到结束之后再去库里改"
        )
    }

    /// §4.1 明确「标题可为空」。**空标题不许被拦下来**——
    /// 为了归档要求用户先完成复杂表单，就是把门槛又加回去了。
    func testEmptyTitleIsStillAllowed() async throws {
        let h = try await makeHarness()
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection(usesMicrophone: true), title: "")
        try await h.settle { $0.phase == .recording }

        let id = try XCTUnwrap(h.session.sessionID)
        let record = try await h.store.session(id: id)
        XCTAssertNotNil(record, "空标题照样能开始")
    }

    func testNilTitleIsAlsoAllowed() async throws {
        let h = try await makeHarness()
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection(usesMicrophone: true), title: nil)
        try await h.settle { $0.phase == .recording }
        XCTAssertNotNil(h.session.sessionID)
    }

    /// MC-04：失败之后重试，**标题与来源一个字都不能变**。
    ///
    /// 会前这一屏的输入是用户为了这场会专门打的字。清空它等于让用户重打一遍，
    /// 而失败往往还发生在同一台机器、同一个占用它的应用上——他改不掉。
    func testTitleAndSelectionSurviveAFailedStart() async throws {
        let h = try await makeHarness()
        let selection = MeetingAudioSelection(usesMicrophone: true)
        await h.clients.failNextConnect()

        await h.session.start(selection: selection, title: "周五发布评审")
        try await h.settle { $0.session.blocked != nil }

        XCTAssertEqual(
            h.session.pendingTitle, "周五发布评审",
            "启动失败不该把用户写的标题清掉"
        )
        XCTAssertEqual(
            h.session.phase, .idle,
            "失败之后要回到能再按一次的状态，而不是卡在半路"
        )
        // 会话自己那份 `selection` 失败时会被清掉（`resetKeepingLines`），
        // 这是**有意的**：它由界面持有的来源重新喂进来。会前那一屏的来源摘要
        // 活在 `MeetingView` 的状态里，那一份才是用户看到、也保得住的那个。
        // 所以这里只钉"会话记得住标题"——那一层真的一直没人管过。

        // 重试：用户什么都不用改，直接再按一次开始。
        await h.clients.openGate()
        await h.session.start(selection: selection, title: "周五发布评审")
        try await h.settle { $0.phase == .recording }
        let id = try XCTUnwrap(h.session.sessionID)
        let record = try await h.store.session(id: id)
        XCTAssertEqual(record?.title, "周五发布评审")
        let count = try await h.store.sessionCount()
        XCTAssertEqual(count, 1, "重试不该留下两条记录")
    }

    /// 连续失败也不能把输入清掉——用户可能连着按三次"开始"。
    func testRepeatedFailuresKeepTheTitle() async throws {
        let h = try await makeHarness()
        for _ in 0..<3 {
            await h.clients.failNextConnect()
            await h.session.start(
                selection: MeetingAudioSelection(usesMicrophone: true),
                title: "周五发布评审"
            )
            try await h.settle { $0.session.blocked != nil }
            XCTAssertEqual(h.session.pendingTitle, "周五发布评审")
        }
        let count = try await h.store.sessionCount()
        XCTAssertEqual(count, 0, "三次失败都不该留下空会")
    }

    /// 下一场会议**不该继承上一场的标题**。
    ///
    /// 会前那一屏的输入框在界面上还留着，用户很可能没清就按了第二次开始。
    /// 会前那一屏的输入框在界面上还留着，用户很可能没清就按了第二次开始。
    func testTitleDoesNotLeakIntoTheNextMeeting() async throws {
        let h = try await makeHarness()
        await h.clients.failNextConnect()
        await h.session.start(
            selection: MeetingAudioSelection(usesMicrophone: true), title: "周五发布评审"
        )
        try await h.settle { $0.session.blocked != nil }
        XCTAssertEqual(h.session.pendingTitle, "周五发布评审")

        // 用户没改标题就按了第二次开始（界面上输入框还留着上一场的内容）。
        await h.clients.openGate()
        await h.session.start(
            selection: MeetingAudioSelection(usesMicrophone: true), title: nil
        )
        try await h.settle { $0.phase == .recording }
        XCTAssertNil(
            h.session.pendingTitle,
            "这一场没写标题，就该是 nil，而不是上一场那句"
        )
        let id = try XCTUnwrap(h.session.sessionID)
        let record = try await h.store.session(id: id)
        XCTAssertNil(record?.title, "库里也不能留下上一场的名字")
    }

    // MARK: - MC-09～MC-13：转录身份、空结果与时间（方案 §17.2）
    //
    // 这一组此前**端不到端**，原因不是做不到，是没人接线：那份假连接
    // 的 `events()` 每次现造一条**空流**，测试没有任何办法往里投事件，
    // 于是生产 `handle` 里那几条 MC-09/10/14 的分支从来没被真的走过。
    // 断言只落在 `TranscriptItemLedger` 自己身上——那是账本层，
    // 不是"事件到达 → 落库 → 界面上看见"这条真实链路。
    //
    // 现在假连接持有**存下来的那一条**流，事件按真实 wire 顺序投进去。

    /// 起一场会并等到录制态。麦克风必须显式勾上，否则空选择会被
    /// `noSourceSelected` 挡掉，`start()` 根本进不到录制态。
    private func startRecording(_ h: Harness) async throws -> String {
        await h.clients.openGate()
        await h.session.start(selection: MeetingAudioSelection(usesMicrophone: true))
        try await h.settle { $0.phase == .recording }
        return try XCTUnwrap(h.session.sessionID)
    }

    /// MC-09：A 和 B 交错出 partial。单 item 的文本不许被拼在一起，
    /// 另一个 item 的结果仍要按**它自己的身份**落库。
    ///
    /// 拼错了的后果很具体：库里出现一句"A 的半句 + B 的半句"，
    /// 归属和引用全都指错，而界面上看起来只是一句正常的话。
    func testInterleavedPartialsDoNotBleedIntoEachOther() async throws {
        let h = try await makeHarness()
        let sessionID = try await startRecording(h)

        try await h.emit(.partial(itemID: "A", delta: "灰度下周三"))
        try await h.emit(.partial(itemID: "B", delta: "预算是三万"))
        try await h.emit(.partial(itemID: "A", delta: "开始。"))
        try await h.emit(.completed(itemID: "A", transcript: "灰度下周三开始。"))
        try await h.emit(.completed(itemID: "B", transcript: "预算是三万。"))
        try await h.settle { $0.session.lines.count == 2 }

        let lines = try await h.store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.count, 2, "两个 item 落两行，不该多也不该少")
        let texts = lines.map(\.text).sorted()
        XCTAssertEqual(texts, ["灰度下周三开始。", "预算是三万。"], "各按各的身份落库")
        for line in lines {
            let text = line.text ?? ""
            XCTAssertFalse(
                text.contains("三万") && text.contains("灰度"),
                "两个 item 的文本不得被拼进同一行：\(text)"
            )
        }
    }

    /// B 的 final 先到，A 的 final 后到；正文与冻结的输入区间仍按各自 item 归属。
    func testLateFinalKeepsItsItemAndFrozenInputRange() async throws {
        let h = try await makeHarness()
        let sessionID = try await startRecording(h)

        let spanA = RealtimeASRClient.RealtimeSampleSpan(startSample: 0, endSample: 24_000)
        let spanB = RealtimeASRClient.RealtimeSampleSpan(startSample: 24_000, endSample: 48_000)
        try await h.emit(
            .segmentClosed(
                itemID: "A",
                sampleSpan: spanA,
                reason: .vad,
                commitEventID: nil
            )
        )
        try await h.emit(
            .segmentClosed(
                itemID: "B",
                sampleSpan: spanB,
                reason: .vad,
                commitEventID: nil
            )
        )

        try await h.emit(.completed(itemID: "B", transcript: "B 的正文"))
        try await h.settle { $0.session.lines.count == 1 }
        try await h.emit(.completed(itemID: "A", transcript: "A 的正文"))
        try await h.settle { $0.session.lines.count == 2 }

        let lines = try await h.store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.count, 2)
        let lineA = try XCTUnwrap(lines.first { $0.text == "A 的正文" })
        let lineB = try XCTUnwrap(lines.first { $0.text == "B 的正文" })
        let startA = try XCTUnwrap(lineA.tStart)
        let endA = try XCTUnwrap(lineA.tEnd)
        let startB = try XCTUnwrap(lineB.tStart)
        let endB = try XCTUnwrap(lineB.tEnd)
        XCTAssertEqual(startB - startA, 1, accuracy: 0.02)
        XCTAssertEqual(endB - endA, 1, accuracy: 0.02)
        XCTAssertGreaterThan(endA, startA)
        XCTAssertGreaterThan(endB, startB)
    }

    /// The save owner must wait until drain events are consumed before it
    /// archives the meeting. A tail final and its later attribution belong to
    /// the ending connection and must both reach the original saved row.
    func testDrainFinalAndLateAttributionReachSaveOwnerBeforeArchive() async throws {
        let h = try await makeHarness()
        let preferencesName = "meeting-drain-\(UUID().uuidString)"
        let preferencesDefaults = try XCTUnwrap(UserDefaults(suiteName: preferencesName))
        defer { preferencesDefaults.removePersistentDomain(forName: preferencesName) }
        let preferences = SessionPreferences(defaults: preferencesDefaults)
        preferences.meetingDiarizationEnabled = true
        h.session.preferences = { preferences }

        let sessionID = try await startRecording(h)
        let client = try XCTUnwrap(h.clients.all.last)
        h.audio.emit(AudioChunk(pcm: Data([0, 1]), level: 0.2))
        h.audio.emit(AudioChunk(pcm: Data([2, 3]), level: 0.3))
        await client.setDrainEvents([
            .segmentClosed(
                itemID: "tail",
                sampleSpan: .init(startSample: 0, endSample: 48_000),
                reason: .clientCommit,
                commitEventID: "meeting-drain-commit"
            ),
            .completed(itemID: "tail", transcript: "会议最后一句"),
            .attribution(
                itemID: "tail",
                units: [
                    RealtimeASRClient.AttributionUnit(
                        segmentUID: "tail-segment",
                        speaker: "A",
                        textStart: 0,
                        textEnd: 6,
                        audioStartSample: 0,
                        audioEndSample: 48_000,
                        timingQuality: "aligned"
                    )
                ],
                isFinal: true
            ),
            .diarizationFinished
        ])
        await client.finishEventsOnClose()

        await h.session.finishAndSummarize()

        let lines = try await h.store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.count, 1, "drain 尾句应在归档前落库一次")
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.text, "会议最后一句")
        XCTAssertEqual(line.speakerLabel, "A", "final 之后的 drain attribution 也须写入同一行")
        XCTAssertEqual(try XCTUnwrap(line.tStart), 0, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(line.tEnd), 2, accuracy: 0.02)
        let appendedAtDrain = await client.appendedByteCountAtDrain
        let appendedBytes = await client.appendedByteCount
        XCTAssertEqual(appendedAtDrain, 4, "提交 drain 前必须上传采集流里已缓冲的两块音频")
        XCTAssertEqual(appendedBytes, 4, "已缓冲音频只上传一次")
        let record = try await h.store.session(id: sessionID)
        XCTAssertEqual(record?.state, .archived, "只有 drain 和晚到辅助结果完成后才归档")
    }

    /// MC-10：同一 item 连续快照修订，先到 3 再迟到 2。
    /// **全文替换**而非追加；旧 revision 不许倒写。
    func testLateSnapshotRevisionDoesNotOverwriteTheNewerOne() async throws {
        let h = try await makeHarness()
        _ = try await startRecording(h)

        try await h.emit(.partialSnapshot(itemID: "A", revision: 3, text: "第三版说法"))
        try await h.emit(.partialSnapshot(itemID: "A", revision: 2, text: "第二版说法"))
        try await h.settleBriefly()

        let visible = h.session.partialText ?? ""
        XCTAssertEqual(visible, "第三版说法", "迟到的旧 revision 不许倒写")
        XCTAssertFalse(
            visible.contains("第二版"),
            "快照是替换不是追加：两版拼在一起等于把两份说法当成一句"
        )
    }

    /// MC-11：已经显示过非空 partial，同一个 item 却回来一个**空 final**。
    /// 三件事都要成立：内容**保留为未定稿恢复材料**并给出提示、
    /// **不进入正式纪要**、**不无声消失**。
    ///
    /// 这是验收 2「空输出不得显示成功」在会议侧的具体形态。
    func testEmptyFinalKeepsTheTextAsRecoveryMaterialInsteadOfLosingIt() async throws {
        let h = try await makeHarness()
        let sessionID = try await startRecording(h)

        try await h.emit(.partial(itemID: "A", delta: "这句已经显示给用户了"))
        try await h.emit(.completed(itemID: "A", transcript: ""))
        try await h.settleBriefly()

        // ① 不进入正式纪要：默认读法只给终稿行。
        let finalLines = try await h.store.lines(sessionID: sessionID)
        XCTAssertTrue(finalLines.isEmpty, "空 final 不得当成一句话落进正式转录")

        // ② 不无声消失：以未定稿身份留在库里。
        let all = try await h.store.lines(sessionID: sessionID, includePartial: true)
        XCTAssertEqual(all.count, 1, "这句得留在库里，不能凭空消失")
        XCTAssertEqual(all.first?.status, .partial, "它只能是非终稿")
        XCTAssertEqual(all.first?.text, "这句已经显示给用户了")

        // ③ 提示要说清发生了什么，而不是安静地什么都不发生。
        let hint = try XCTUnwrap(h.session.lastFailure)
        XCTAssertTrue(
            hint.contains("没有拿到定稿正文") && hint.contains("已原样保留"),
            "要明说这句没定稿但已保留：\(hint)"
        )
    }

    /// MC-12：同连接同 item 已提交 final，重复的 final 与重复的事件再到达。
    /// 只一条权威行、只推进一次 ordinal、不重复产出知识项。
    func testDuplicateFinalDoesNotCreateASecondAuthoritativeRow() async throws {
        let h = try await makeHarness()
        let sessionID = try await startRecording(h)

        try await h.emit(.completed(itemID: "A", transcript: "只该有一行"))
        try await h.settle { $0.session.lines.count == 1 }
        try await h.emit(.completed(itemID: "A", transcript: "只该有一行"))
        try await h.settleBriefly()

        let lines = try await h.store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.count, 1, "同一 item 的重复 final 只留一条权威行")
        XCTAssertEqual(lines.first?.text, "只该有一行")
        let ordinal = try XCTUnwrap(lines.first?.ordinal)
        XCTAssertEqual(ordinal, 1, "重复 final 不得再推进一次 ordinal")
    }

    /// MC-13：同场重连，**新服务复用 item ID**。
    /// 新 final 不得被上一条连接的去重集丢弃。
    ///
    /// 去重原本按裸 `item_id`，且只在新建会话时清空——同场重连之后，
    /// 新服务的 ID 落进上一代连接的去重集，于是整句消失。
    /// 用户看到的是"重连之后后半段话全没了"，而界面上没有任何提示。
    func testReconnectWithReusedItemIDStillCommitsTheNewFinal() async throws {
        let h = try await makeHarness()
        let sessionID = try await startRecording(h)

        try await h.emit(.completed(itemID: "shared-id", transcript: "重连之前说的"))
        try await h.settle { $0.session.lines.count == 1 }

        // 走生产重连路径（睡眠接缝 → enterInterruption → continueAfterInterruption）。
        h.power.fireSleep()
        try await h.settle { $0.phase == .interrupted }
        await h.session.continueAfterInterruption()
        try await h.settle { $0.phase == .recording }
        try await h.settle { await $0.clients.all.count >= 2 }

        // 新服务复用了同一个 item ID。
        try await h.emit(.completed(itemID: "shared-id", transcript: "重连之后说的"))
        try await h.settle { $0.session.lines.count == 2 }

        let lines = try await h.store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.count, 2, "新服务的 final 不得被上一代连接的去重集丢弃")
        XCTAssertEqual(
            lines.map(\.text), ["重连之前说的", "重连之后说的"],
            "两代各落一行，后半句不许凭空消失"
        )
    }

    /// MC-14：连接 A 已失效、B 正在记录，A 随后才发 `failed` / `closed` /
    /// `attribution`。三件事都不许发生：**不清 B 的 partial**、**不停 B**、
    /// **不把归属写给 B 的行**。
    ///
    /// 上一条 MC-13 钉的是"新服务的 final 不被丢弃"，这一条钉的是反方向：
    /// 旧连接**迟到的副作用**同样不能算数。
    ///
    /// **这条用例证明的是什么、不证明什么，说清楚**：
    /// 做它的时候以为挡住旧连接的是事件循环里的 `isCurrent` 代次守卫，
    /// 做完做了变异检验——把那个 `guard` 拆掉，本用例**照样全绿**。
    /// 真正挡住的是 `startPump` 里的 `pump?.cancel()`：`RealtimeEventChannel.next()`
    /// 先查 `Task.isCancelled` 再取缓冲，所以取消之后**连已缓冲的事件都不会被取出**，
    /// 旧流的迭代直接结束。
    ///
    /// 所以：它锁的是**可观察后果**（旧连接的迟到事件不碰当前这一代），
    /// 这条值得留——将来谁动了取消语义，它会红。但它**不证明**那个代次守卫；
    /// 守卫的逻辑另有 `MeetingConnectionGeneration` 的单测覆盖。
    /// 把它记成"代次守卫已端到端验证"就是本分支反复在修的那种毛病：
    /// 断言全绿，验的却不是它。
    func testStaleConnectionCannotTouchTheLiveRecording() async throws {
        let h = try await makeHarness()
        let sessionID = try await startRecording(h)

        // B 接管：走生产重连路径。
        h.power.fireSleep()
        try await h.settle { $0.phase == .interrupted }
        await h.session.continueAfterInterruption()
        try await h.settle { $0.phase == .recording }
        try await h.settle { await $0.clients.all.count >= 2 }
        let live = await h.clients.all.count - 1
        XCTAssertGreaterThanOrEqual(live, 1)

        // B 正常提交一句，并留着一个未完成的 partial。
        try await h.emit(.completed(itemID: "Y", transcript: "B 这一场的第一句"))
        try await h.emit(.partial(itemID: "Z", delta: "B 还没说完的半句"))
        try await h.settle { $0.session.lines.count == 1 }
        try await h.settleBriefly()
        let beforeStale = h.session.partialText ?? ""
        XCTAssertTrue(beforeStale.contains("B 还没说完"), "先确认 B 的 partial 确实在")

        // A 迟到地来了一串副作用，全部指向 **B 的 item**——
        // 这是最坏的一种：A 不只是报自己的账，它在动当前这一代的账。
        try await h.emit(.failed(itemID: "Z", code: "server_error", message: "迟到的失败"), toGeneration: 0)
        try await h.emit(
            .attribution(
                itemID: "Y",
                units: [
                    RealtimeASRClient.AttributionUnit(
                        segmentUID: "seg-1", speaker: "说话人 1",
                        textStart: 0, textEnd: 6
                    )
                ],
                isFinal: true
            ),
            toGeneration: 0
        )
        await h.clients.all[0].finishEvents()
        try await h.settleBriefly()

        // ① 不清 B 的 partial。
        let afterStale = h.session.partialText ?? ""
        XCTAssertTrue(
            afterStale.contains("B 还没说完"),
            "A 迟到的 failed 不得清掉 B 当前的 partial：\(afterStale)"
        )
        // ② 不停 B。
        XCTAssertEqual(h.phase, .recording, "A 迟到不得把 B 停掉")
        let liveClient = await h.clients.all.last
        let liveClosed = await liveClient?.closeCount ?? -1
        XCTAssertEqual(liveClosed, 0, "当前这一代连接不得被旧连接的收尾带着一起关掉")
        // ③ 不把归属写给 B 的行。
        let lines = try await h.store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "B 这一场的第一句")
        XCTAssertNil(
            lines.first?.speakerLabel,
            "A 迟到的归属不得写到 B 的行上——那等于给这句话安了一个没人说过的话"
        )
    }

}
/// 这是"启动到一半用户结束了"能被造出来的唯一办法。
actor ConnectGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pendingFailure: Error?

    /// 让**接下来那一次**建连失败，之后恢复成功。
    ///
    /// 与 `open()` 分开是必须的：合成一个方法的话，"设失败"和"放行"之间会被
    /// 后一次 `open(nil)` 把失败抹掉，于是测试自以为在验建连失败，实际上建连成功了——
    /// 断言全绿，验的却不是那一件事。
    func failNext(_ error: Error) {
        pendingFailure = error
    }

    func wait() async throws {
        if isOpen {
            if let failure = pendingFailure { pendingFailure = nil; throw failure }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        if let failure = pendingFailure { pendingFailure = nil; throw failure }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// 一条不握手、不连 loopback 的连接。建连时机由闸门控制。
actor ControllableRealtimeClient: MeetingRealtimeClient {
    private let gate: ConnectGate
    private(set) var connectCount = 0
    private(set) var closeCount = 0
    private(set) var flushCount = 0
    private(set) var drainCount = 0
    private(set) var appendedByteCount = 0
    private(set) var appendedByteCountAtDrain = 0
    private var drainEvents: [RealtimeASRClient.Event] = []
    private var finishEventsWhenClosed = false

    init(gate: ConnectGate) {
        self.gate = gate
    }

    /// **这条流必须是存下来的那一条**，不能每次 `events()` 现造一条：
    /// 现造的话测试往里塞的事件，生产 session 永远收不到，于是断言全绿、
    /// 验的却不是它。此前这份假件正是这么写的，也是 MC-09～MC-13
    /// 一直端不到端的原因。
    private let stream = RealtimeEventStream<RealtimeASRClient.Event>(
        limits: .init(maxBufferedEvents: 256)
    )

    func events() async -> RealtimeEventStream<RealtimeASRClient.Event> { stream }

    /// 按真实 wire 顺序投一条服务端事件。
    func emit(_ payload: RealtimeASRClient.Event) async {
        await stream.yield(
            RealtimeEventEnvelope(metadata: RealtimeEventMetadata(), payload: payload)
        )
    }

    /// 模拟这条连接**迟到地**断开：事件流收尾。
    ///
    /// MC-14 要验的正是"已被换下的连接随后才报 closed"——不结束这条流，
    /// 就没法在测试里造出那个时序。
    func finishEvents() async {
        await stream.finish()
    }

    func connect() async throws {
        connectCount += 1
        do {
            try await gate.wait()
        } catch {
            // 生产 `RealtimeASRClient.connect` 在握手失败时先 `finish(code: nil)`
            // 再把错误抛出去——它自己收尾，不指望调用方补一次 `close()`。
            // 假件照抄这一点：否则这条测试断的是假件自己的脾气，
            // 而不是生产代码的契约。
            closeCount += 1
            throw error
        }
    }

    func append(_ pcm: Data) async throws { appendedByteCount += pcm.count }
    func flushPendingUtterance() async throws { flushCount += 1 }
    func setDrainEvents(_ events: [RealtimeASRClient.Event]) {
        drainEvents = events
    }

    func finishEventsOnClose() {
        finishEventsWhenClosed = true
    }

    func drainAndClear(timeout: Duration) async throws {
        drainCount += 1
        appendedByteCountAtDrain = appendedByteCount
        let events = drainEvents
        drainEvents = []
        for event in events {
            await emit(event)
        }
    }
    func close() async {
        closeCount += 1
        if finishEventsWhenClosed {
            await stream.finish()
        }
    }
}

/// 建出来的连接按顺序收在一处，测试要按"第几条"来断言。
final class ClientRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ControllableRealtimeClient] = []
    let gate = ConnectGate()

    func make(_ configuration: MeetingRealtimeClientConfiguration) -> any MeetingRealtimeClient {
        let client = ControllableRealtimeClient(gate: gate)
        lock.lock()
        storage.append(client)
        lock.unlock()
        return client
    }

    var all: [ControllableRealtimeClient] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// 让接下来那次建连失败，之后恢复正常。
    func failNextConnect() async {
        await gate.failNext(MeetingAudioBlocked(reason: .engineFailed("测试：服务没起来")))
        await gate.open()
    }

    func openGate() async {
        await gate.open()
    }
}

/// 不碰设备的采集通道。流保持打开，所以录制态能真的持续下去。
@MainActor
final class ControllableAudioSource: MeetingAudioSource {
    /// 这一场有多少块是补的静音（来源没跟上）。默认 0：假件不制造补洞。
    var gapCount: Int = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var muted = false
    private(set) var resolvedSource: SessionAudioSource = .microphone
    var onSystemAudioLost: (@MainActor (String) -> Void)?
    var startError: Error?
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func start(selection: MeetingAudioSelection) async throws -> AsyncStream<AudioChunk> {
        startCount += 1
        if let startError { throw startError }
        resolvedSource = selection.resolvedSource
        let pair = AsyncStream<AudioChunk>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func stop() async {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func setMicrophoneMuted(_ muted: Bool) { self.muted = muted }
    func restartSystemAudio() async -> Bool { true }

    /// 造一次"来源 App 退出"。
    func fireSystemAudioLost(_ reason: String) {
        onSystemAudioLost?(reason)
    }

    /// 往采集流里塞一块音频。
    func emit(_ chunk: AudioChunk) {
        continuation?.yield(chunk)
    }

}
