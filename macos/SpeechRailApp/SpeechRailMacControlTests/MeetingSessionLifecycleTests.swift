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

    private func makeHarness() async throws -> Harness {
        let harness = try await Harness.make()
        self.harness = harness
        return harness
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
        try await h.store.finishMinutes(minutesID: minutes.id, body: "# 纪要", model: nil)

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
        try await h.store.finishMinutes(minutesID: minutes.id, body: "# 纪要", model: nil)

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
        try await h.store.finishMinutes(minutesID: minutes.id, body: "# 纪要", model: nil)
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

        static func make() async throws -> Harness {
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
                makeRealtimeClient: { configuration in clients.make(configuration) },
                powerMonitor: power
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
            XCTFail("等待超时：相位 \(session.phase.rawValue)，连接数 \(await clients.all.count)")
        }

        /// 让已经在飞的东西走完一小段，而不是等某个具体状态。
        func settleBriefly() async throws {
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
}

/// 建连闸门。关着时 `connect()` 挂起，由测试放行——
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

    init(gate: ConnectGate) {
        self.gate = gate
    }

    func events() async -> RealtimeEventStream<RealtimeASRClient.Event> {
        RealtimeEventStream<RealtimeASRClient.Event>(limits: .init(maxBufferedEvents: 32))
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
    func drainAndClear(timeout: Duration) async throws { drainCount += 1 }
    func close() async { closeCount += 1 }
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
