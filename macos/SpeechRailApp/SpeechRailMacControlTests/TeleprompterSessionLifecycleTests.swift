import Foundation
import SpeechRailControlKit
import Testing

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
private final class FakeTeleprompterSourceFactory {
    private(set) var sources: [FakeTeleprompterAudioSource] = []
    /// Set before enabling voice assist to simulate an input device that
    /// disappeared (unplugged USB interface, dropped Bluetooth headset).
    var nextStartFailure: (any Error)?

    func make() -> any AudioChunkSource {
        let source = FakeTeleprompterAudioSource()
        source.startFailure = nextStartFailure
        nextStartFailure = nil
        sources.append(source)
        return source
    }
}

private final class FakeTeleprompterAudioSource: AudioChunkSource, @unchecked Sendable {
    private let lock = NSLock()
    private var startCountStorage = 0
    private var stopCountStorage = 0
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    var startFailure: (any Error)?

    func start() async throws -> AsyncStream<AudioChunk> {
        let failure: (any Error)? = withLock {
            startCountStorage += 1
            defer { startFailure = nil }
            return startFailure
        }
        if let failure {
            throw failure
        }
        return withLock {
            var capturedContinuation: AsyncStream<AudioChunk>.Continuation?
            let stream = AsyncStream<AudioChunk> { continuation in
                capturedContinuation = continuation
            }
            continuation = capturedContinuation
            return stream
        }
    }

    func stop() {
        let continuation = withLock {
            stopCountStorage += 1
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.finish()
    }

    var startCount: Int {
        withLock { startCountStorage }
    }

    var stopCount: Int {
        withLock { stopCountStorage }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.isWaiting = true
        }
    }

    func waitUntilWaiting() async {
        while !isWaiting && !isOpen {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        isWaiting = false
        continuation?.resume()
        continuation = nil
    }
}

/// 记录后台等待是否结束，让「不该挂起」的断言能失败而不是把整条流水线拖死。
private actor GateProbe {
    private(set) var finished = false

    func markFinished() { finished = true }
}

private actor FakeTeleprompterRealtimeClient: TeleprompterRealtimeClientProtocol {
    struct Counters: Sendable, Equatable {
        var connectCount = 0
        var appendCount = 0
        var drainCount = 0
        var closeCount = 0
    }

    private let stream: RealtimeEventStream<RealtimeASRClient.Event>
    private let connectGate: TestGate?
    private let drainGate: TestGate?
    private let drainFails: Bool
    private var counters = Counters()

    init(connectGate: TestGate? = nil, drainGate: TestGate? = nil, drainFails: Bool = false) {
        self.stream = RealtimeEventStream()
        self.connectGate = connectGate
        self.drainGate = drainGate
        self.drainFails = drainFails
    }

    func connect() async throws {
        counters.connectCount += 1
        await connectGate?.wait()
    }

    func events() async -> RealtimeEventStream<RealtimeASRClient.Event> {
        stream
    }

    func append(_ pcm: Data) async throws {
        counters.appendCount += 1
    }

    func drainAndClear(timeout: Duration) async throws {
        counters.drainCount += 1
        await drainGate?.wait()
        if drainFails {
            throw FakeFailure.drainFailed
        }
    }

    func close() async {
        counters.closeCount += 1
        await stream.finish()
    }

    func emit(_ payload: RealtimeASRClient.Event, eventID: String = UUID().uuidString) async {
        _ = await stream.yield(
            RealtimeEventEnvelope(
                metadata: RealtimeEventMetadata(eventID: eventID, sessionID: "test", sequence: nil),
                payload: payload
            )
        )
    }

    func currentCounters() -> Counters {
        counters
    }

    private enum FakeFailure: Error {
        case drainFailed
    }
}

/// Captures the recognition configuration the session hands to the transport.
@MainActor
private final class ConfigurationRecorder {
    private(set) var value: TeleprompterRealtimeConfiguration?

    func record(_ configuration: TeleprompterRealtimeConfiguration) {
        value = configuration
    }
}

private final class FakeTeleprompterClientFactory {
    private(set) var clients: [FakeTeleprompterRealtimeClient] = []
    let connectGate: TestGate?
    let drainGate: TestGate?
    let drainFails: Bool

    init(connectGate: TestGate? = nil, drainGate: TestGate? = nil, drainFails: Bool = false) {
        self.connectGate = connectGate
        self.drainGate = drainGate
        self.drainFails = drainFails
    }

    func make() -> any TeleprompterRealtimeClientProtocol {
        let client = FakeTeleprompterRealtimeClient(
            connectGate: connectGate,
            drainGate: drainGate,
            drainFails: drainFails
        )
        clients.append(client)
        return client
    }
}

@MainActor
private final class TeleprompterSessionHarness {
    let session: TeleprompterSession
    let coordinator: SessionCoordinator
    let sourceFactory: FakeTeleprompterSourceFactory
    let clientFactory: FakeTeleprompterClientFactory
    let directory: URL

    init(
        sourceFactory: FakeTeleprompterSourceFactory = .init(),
        clientFactory: FakeTeleprompterClientFactory = .init()
    ) throws {
        self.sourceFactory = sourceFactory
        self.clientFactory = clientFactory
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRail-Teleprompter-Session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sessionStore = SessionStore(directory: directory.appendingPathComponent("sessions", isDirectory: true))
        let coordinator = SessionCoordinator(store: sessionStore)
        let v2Store = try TeleprompterV2Store(directoryURL: directory.appendingPathComponent("documents", isDirectory: true))
        let session = TeleprompterSession(
            coordinator: coordinator,
            v2Store: v2Store,
            audioSourceFactory: { sourceFactory.make() }
        )
        session.realtimeClientFactory = { _, _, _ in clientFactory.make() }
        coordinator.starter = { kind in
            guard kind == .teleprompter else { return }
            try await session.beginCapture()
        }
        coordinator.stopper = { kind in
            guard kind == .teleprompter else { return }
            await session.stopCapture()
        }
        self.coordinator = coordinator
        self.session = session
    }

    func makeThreeSegmentDocument() {
        session.createDocument(
            title: "测试稿",
            sourceText: "第一段内容。第二段内容。第三段内容。"
        )
    }

    /// A second session over the same store, so restored progress has to come
    /// from disk instead of in-memory state.
    func makeReloadedSession() throws -> TeleprompterSession {
        let store = SessionStore(
            directory: directory.appendingPathComponent("sessions", isDirectory: true)
        )
        let v2Store = try TeleprompterV2Store(
            directoryURL: directory.appendingPathComponent("documents", isDirectory: true)
        )
        return TeleprompterSession(coordinator: SessionCoordinator(store: store), v2Store: v2Store)
    }

    func documentBundleURL(documentID: String) -> URL {
        directory
            .appendingPathComponent("documents", isDirectory: true)
            .appendingPathComponent("\(documentID).json", isDirectory: false)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct TeleprompterSessionLifecycleTests {
    @Test("manual open is readable without microphone, transport, or model work")
    func manualOpenHasNoAudioSideEffects() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()

        try harness.session.openForManualReading()

        #expect(harness.session.activeVersion != nil)
        #expect(harness.session.phase == .manual)
        #expect(harness.session.voiceAssistState == .off)
        #expect(!harness.session.isMicrophoneCapturing)
        #expect(harness.session.isStageOpen)
        #expect(harness.sourceFactory.sources.isEmpty)
        #expect(harness.clientFactory.clients.isEmpty)
        #expect(harness.coordinator.occupancy == nil)

        harness.session.moveToPrevious()
        #expect(harness.session.currentSegmentIndex == 0)
        harness.session.moveToNext()
        #expect(harness.session.currentSegmentIndex == 1)
    }

    @Test("a confirmed reading is stored as an alias without rewriting the script")
    func confirmingAReadingStoresItWithoutChangingTheScript() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "读法别名",
            sourceText: "SpeechRail 很快。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let original = try #require(harness.session.activeVersion?.segments.first)
        let found = (original.text as NSString).range(of: "SpeechRail")
        #expect(found.location != NSNotFound)
        let range = TeleprompterSourceRange(
            start: found.location,
            end: found.location + found.length
        )

        let rejection = harness.session.confirmReading(
            segmentID: original.id,
            displayRange: range,
            spokenText: "SpeechRail"
        )

        #expect(rejection == nil)
        let stored = try #require(harness.session.activeVersion?.segments.first)
        // The script the reader sees and records is untouched; only the matcher
        // gets a different token to look for.
        #expect(stored.text == original.text)
        #expect(stored.acceptedReadings.count == 1)
        #expect(stored.acceptedReadings.first?.displayRange == range)
        #expect(stored.acceptedReadings.first?.displayText == "SpeechRail")

        // Re-confirming the same occurrence replaces rather than stacks, so the
        // token stream cannot grow a second variant for the same words.
        #expect(harness.session.confirmReading(
            segmentID: original.id,
            displayRange: range,
            spokenText: "斯比尔雷尔"
        ) == nil)
        let replaced = try #require(harness.session.activeVersion?.segments.first)
        #expect(replaced.acceptedReadings.count == 1)
        #expect(replaced.acceptedReadings.first?.spokenText == "斯比尔雷尔")

        #expect(harness.session.removeConfirmedReading(
            segmentID: original.id,
            displayRange: range
        ) == nil)
        #expect(harness.session.activeVersion?.segments.first?.acceptedReadings.isEmpty == true)
        // Removing something that is not there says so, rather than claiming
        // a save happened or blaming the disk.
        #expect(harness.session.removeConfirmedReading(
            segmentID: original.id,
            displayRange: range
        ) == .noSuchReading)
    }

    @Test("a confirmed reading that changes the number is refused and leaves no trace")
    func confirmingAReadingThatChangesTheNumberIsRefused() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "别名数值",
            sourceText: "覆盖率是 50%。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let original = try #require(harness.session.activeVersion?.segments.first)
        let found = (original.text as NSString).range(of: "50%")
        #expect(found.location != NSNotFound)
        let range = TeleprompterSourceRange(
            start: found.location,
            end: found.location + found.length
        )

        let rejection = harness.session.confirmReading(
            segmentID: original.id,
            displayRange: range,
            spokenText: "大约一半"
        )

        #expect(rejection == .numericValuesDiffer)
        let after = try #require(harness.session.activeVersion?.segments.first)
        #expect(after.acceptedReadings.isEmpty)
        #expect(after.text == original.text)
        // A rejected confirmation must not have been written to the bundle either.
        #expect(try #require(harness.session.activeVersion).segments.count == 3)
    }

    /// #110 复审：`canEdit` 为 false 原本回的是 `.displayTextChanged`，界面把它
    /// 说成「正文变了，请重新打开窗口」。舞台明明还开着，用户重开一次窗口也
    /// 解决不了，只会白等一场。这条把「现在不能改」和「正文变了」分开。
    @Test("a reading confirmed while the stage is live reports that it is not editable")
    func confirmingAReadingWhileTheStageIsLiveIsNotEditable() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "舞台开着",
            sourceText: "SpeechRail 很快。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let segment = try #require(harness.session.activeVersion?.segments.first)
        let found = (segment.text as NSString).range(of: "SpeechRail")
        #expect(found.location != NSNotFound)
        let range = TeleprompterSourceRange(
            start: found.location,
            end: found.location + found.length
        )

        await harness.session.enableVoiceAssist()
        #expect(harness.session.canEdit == false, "语音开着时这段本就不该可改")

        #expect(harness.session.confirmReading(
            segmentID: segment.id,
            displayRange: range,
            spokenText: "斯比尔雷尔"
        ) == .notEditable)
        #expect(harness.session.activeVersion?.segments.first?.acceptedReadings.isEmpty == true)
    }

    /// #110 复审：存盘失败原本也回 `.displayTextChanged`。磁盘写不进去被说成正文
    /// 问题，方向完全错。而且内存里必须先回滚——否则界面会显示一条 store 下次
    /// 拒绝加载的读法，用户以为标好了，下次打开又没了。
    @Test("a store failure is reported as a save failure and rolls the reading back")
    func aStoreFailureIsReportedAsASaveFailureAndRolledBack() throws {
        try #require(getuid() != 0, "root 绕过目录权限，这条路径无法复现")
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "存盘失败",
            sourceText: "SpeechRail 很快。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let documentID = try #require(harness.session.document?.id)
        let segment = try #require(harness.session.activeVersion?.segments.first)
        let found = (segment.text as NSString).range(of: "SpeechRail")
        #expect(found.location != NSNotFound)
        let range = TeleprompterSourceRange(
            start: found.location,
            end: found.location + found.length
        )

        let url = harness.documentBundleURL(documentID: documentID)
        let before = try Data(contentsOf: url)
        let documentsDirectory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: documentsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: documentsDirectory.path
            )
        }

        #expect(harness.session.confirmReading(
            segmentID: segment.id,
            displayRange: range,
            spokenText: "斯比尔雷尔"
        ) == .saveFailed)
        // 内存必须回到写入前，读法不能留在界面上。
        #expect(harness.session.activeVersion?.segments.first?.acceptedReadings.isEmpty == true)
        // 磁盘字节逐字节不变。
        #expect(try Data(contentsOf: url) == before, "存盘失败后原始字节必须逐字节不变")
    }

    /// #110 复审第二条：「移除」这条路原本只返回一个 `Bool`，三种原因
    /// （舞台开着不能改／这条读法已经不在／存盘失败）全被弹窗说成
    /// 「没有保存成功，请重试」。舞台开着时重试多少次都不会成功。
    @Test("removing a reading while the stage is live reports that it is not editable")
    func removingAReadingWhileTheStageIsLiveIsNotEditable() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "舞台开着",
            sourceText: "SpeechRail 很快。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let segment = try #require(harness.session.activeVersion?.segments.first)
        let found = (segment.text as NSString).range(of: "SpeechRail")
        #expect(found.location != NSNotFound)
        let range = TeleprompterSourceRange(
            start: found.location,
            end: found.location + found.length
        )
        #expect(harness.session.confirmReading(
            segmentID: segment.id,
            displayRange: range,
            spokenText: "斯比尔雷尔"
        ) == nil)

        await harness.session.enableVoiceAssist()
        #expect(harness.session.canEdit == false)

        #expect(harness.session.removeConfirmedReading(
            segmentID: segment.id,
            displayRange: range
        ) == .notEditable)
        // 拒绝移除时读法必须原样留着。
        #expect(harness.session.activeVersion?.segments.first?.acceptedReadings.count == 1)
    }

    /// 移除路径的存盘失败必须同样回滚。这条此前完全没有覆盖：移除只返回一个
    /// `Bool`，失败时把内存里那条读法留在原处，界面显示「已移除」而磁盘上
    /// 的稿件还带着它——下次打开读法又回来了。
    @Test("a store failure while removing a reading rolls the removal back")
    func aStoreFailureWhileRemovingARollsBack() throws {
        try #require(getuid() != 0, "root 绕过目录权限，这条路径无法复现")
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "移除存盘失败",
            sourceText: "SpeechRail 很快。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let documentID = try #require(harness.session.document?.id)
        let segment = try #require(harness.session.activeVersion?.segments.first)
        let found = (segment.text as NSString).range(of: "SpeechRail")
        #expect(found.location != NSNotFound)
        let range = TeleprompterSourceRange(
            start: found.location,
            end: found.location + found.length
        )
        #expect(harness.session.confirmReading(
            segmentID: segment.id,
            displayRange: range,
            spokenText: "斯比尔雷尔"
        ) == nil)

        let url = harness.documentBundleURL(documentID: documentID)
        let before = try Data(contentsOf: url)
        let documentsDirectory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: documentsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: documentsDirectory.path
            )
        }

        #expect(harness.session.removeConfirmedReading(
            segmentID: segment.id,
            displayRange: range
        ) == .saveFailed)
        #expect(
            harness.session.activeVersion?.segments.first?.acceptedReadings.count == 1,
            "移除失败时读法必须回到内存里，否则界面显示已移除而磁盘上还在"
        )
        #expect(try Data(contentsOf: url) == before, "移除失败后原始字节必须逐字节不变")
    }

    @Test("a reading can be confirmed by typing the term instead of picking a range")
    func aReadingCanBeConfirmedByTypingTheTerm() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "按词标注",
            sourceText: "今天讲鲲鹏一体机。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let segment = try #require(harness.session.activeVersion?.segments.first)

        let resolved = harness.session.resolveDisplayTerm("鲲鹏", inSegmentID: segment.id)
        #expect(try resolved.get() == .init(start: 3, end: 5),
                "唯一出现时应当解析成它在段内的 UTF-16 范围")
        #expect(harness.session.resolveDisplayTerm("  鲲鹏  ", inSegmentID: segment.id)
            == .success(.init(start: 3, end: 5)),
                "复制粘贴常带首尾空格，不该因此认不出这个词")

        #expect(harness.session.confirmReading(
            segmentID: segment.id,
            displayTerm: "鲲鹏",
            spokenText: "昆鹏"
        ) == nil)
        let stored = try #require(harness.session.activeVersion?.segments.first)
        #expect(stored.acceptedReadings.count == 1)
        #expect(stored.acceptedReadings.first?.spokenText == "昆鹏")
        #expect(stored.text == segment.text, "标注读法不得改动显示文本")
    }

    @Test("a term occurring twice is refused rather than silently bound to the first one")
    func anAmbiguousTermIsRefusedRatherThanGuessed() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "重复词",
            sourceText: "今天讲鲲鹏，鲲鹏很好。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let segment = try #require(harness.session.activeVersion?.segments.first)

        let resolved = harness.session.resolveDisplayTerm("鲲鹏", inSegmentID: segment.id)
        #expect(resolved == .failure(.termAmbiguousOccurrences(2)))

        #expect(harness.session.confirmReading(
            segmentID: segment.id,
            displayTerm: "鲲鹏",
            spokenText: "昆鹏"
        ) == .termAmbiguousOccurrences(2))
        #expect(harness.session.activeVersion?.segments.first?.acceptedReadings.isEmpty == true,
                "拒绝之后不得留下任何写了一半的读法")

        // 换成能唯一定位的词组就应当通过——这是界面上给出的出路。
        #expect(harness.session.confirmReading(
            segmentID: segment.id,
            displayTerm: "讲鲲鹏",
            spokenText: "讲昆鹏"
        ) == nil)
        #expect(harness.session.activeVersion?.segments.first?.acceptedReadings.count == 1)
    }

    @Test("a term that is not in the chosen segment is refused")
    func aTermOutsideTheSegmentIsRefused() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "找不到的词",
            sourceText: "今天讲鲲鹏一体机。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let segment = try #require(harness.session.activeVersion?.segments.first)

        #expect(harness.session.resolveDisplayTerm("并不存在", inSegmentID: segment.id)
            == .failure(.termNotFound))
        #expect(harness.session.confirmReading(
            segmentID: segment.id,
            displayTerm: "并不存在",
            spokenText: "壹段"
        ) == .termNotFound)
        // 空输入不是「匹配到空」，而是根本没有可登记的词。
        #expect(harness.session.resolveDisplayTerm("   ", inSegmentID: segment.id)
            == .failure(.termNotFound))
        #expect(harness.session.activeVersion?.segments.first?.acceptedReadings.isEmpty == true)
    }

    @Test("a term is resolved inside the picked segment, not anywhere in the document")
    func aTermIsResolvedInsideThePickedSegment() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        // 同一个词出现在两段里，且两段内的位置不同。段内偏移才是别名绑定的
        // 坐标，拿到全文里的第一处就会把读法记到别人的段子上。
        harness.session.createDocument(
            title: "跨段同词",
            sourceText: "今天讲鲲鹏。第二段也讲鲲鹏。"
        )
        try harness.session.openForManualReading()
        let segments = try #require(harness.session.activeVersion?.segments)
        let second = try #require(segments.count == 2 ? segments[1] : nil)

        let resolved = harness.session.resolveDisplayTerm("鲲鹏", inSegmentID: second.id)
        #expect(try resolved.get() == .init(start: 5, end: 7),
                "偏移相对的是被选中段落，不是整篇稿件")

        #expect(harness.session.confirmReading(
            segmentID: second.id,
            displayTerm: "鲲鹏",
            spokenText: "昆鹏"
        ) == nil)
        #expect(harness.session.activeVersion?.segments[1].acceptedReadings.count == 1)
        #expect(harness.session.activeVersion?.segments[0].acceptedReadings.isEmpty == true,
                "只登记被选中的那一段，另一段不受影响")
    }

    @Test("a speech trial proves recognition and alignment without moving the script")
    func aSpeechTrialProvesRecognitionAndAlignmentWithoutMovingTheScript() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "语音试读",
            sourceText: "今天讲鲲鹏一体机。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let segmentBefore = try #require(harness.session.activeVersion?.segments.first)

        #expect(await harness.session.startSpeechTrial())
        #expect(harness.session.speechTrialStage == .listening,
                "采集与识别都活着才可以进入 listening")
        let client = try #require(harness.clientFactory.clients.first)
        await client.emit(.completed(itemID: "i1", transcript: "今天讲鲲鹏一体机"))

        await waitFor {
            (harness.session.speechTrialEvidence?.recognizedUnits ?? 0) > 0
        }
        let evidence = try #require(harness.session.speechTrialEvidence)
        #expect(evidence.provesRecognition, "识别器真的返回了内容")
        #expect(evidence.provesAlignment, "并且这些内容能在稿件里定位")

        // 再送一条能定位到末段的正文：即使对齐器找到了它，试读也只记证据，
        // 不许把阅读位置带走。
        await client.emit(.completed(itemID: "i2", transcript: "第三段内容"))
        await waitFor {
            (harness.session.speechTrialEvidence?.matchedUnits ?? 0) > evidence.matchedUnits
        }

        // 试读不是跟读：阅读位置、跟读状态与运行计时都不能被它动过。
        #expect(harness.session.currentSegmentIndex == 0)
        #expect(harness.session.voiceAssistState == .off)
        #expect(harness.session.phase != .following)
        #expect(!harness.session.hasHeardSpeech,
                "试读不把「听到了」记到跟读状态上")
        #expect(harness.session.readingOffset == 0)
        #expect(harness.session.activeVersion?.segments.first?.text == segmentBefore.text)
    }

    @Test("the adopt decision pins recognition and duration separately")
    func theSpeechTrialAdoptDecisionPinsBothConditionsSeparately() {
        let long = TeleprompterTimingPolicy.minimumTrialDurationSeconds + 10

        // 时长够、也听到了内容 → 给出倍率。
        let good = TeleprompterSpeechTrialEvidence(
            durationSeconds: long, recognizedUnits: 12, matchedUnits: 10
        )
        #expect(good.calibrationFactor(baseEstimateSeconds: 100) == long / 100)

        // 时长够但什么都没听到：不得产出倍率。#112 要求不能只以输入电平
        // 证明识别成功，而一个假的倍率比没有倍率更糟。
        #expect(
            TeleprompterSpeechTrialEvidence(
                durationSeconds: long, recognizedUnits: 0, matchedUnits: 0
            ).calibrationFactor(baseEstimateSeconds: 100) == nil
        )

        // 听到了但时间太短：同样不产出倍率。
        #expect(
            TeleprompterSpeechTrialEvidence(
                durationSeconds: 1, recognizedUnits: 12, matchedUnits: 10
            ).calibrationFactor(baseEstimateSeconds: 100) == nil
        )

        // 基准估计本身不成立时也不能算。
        #expect(good.calibrationFactor(baseEstimateSeconds: 0) == nil)
    }

    @Test("a speech trial uses the same explicit language and terms as following")
    func aSpeechTrialUsesTheSameRecognitionConfiguration() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        try harness.session.openForManualReading()
        harness.session.preferredSpeechLanguage = "zh"
        harness.session.aiClient = TeleprompterAIClient { prompt in
            let data = Data(prompt.input.utf8)
            let context = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let units = context?["units"] as? [[String: Any]] ?? []
            let annotations = units.map { unit -> [String: Any] in
                let id = unit["id"] as? Int ?? 0
                let raw = unit["text"] as? String ?? ""
                let keyword = String(raw.prefix(3))
                return [
                    "start_unit": id,
                    "end_unit": id + 1,
                    "keywords": keyword.isEmpty ? [] : [keyword],
                    "match_phrases": [],
                    "pause_hint": "short",
                ]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: [
                "schema_version": "teleprompter.analysis.v2",
                "segments": annotations,
            ]), as: UTF8.self)
        }
        await harness.session.annotateActiveVersion()

        let recorder = ConfigurationRecorder()
        let clientFactory = FakeTeleprompterClientFactory()
        harness.session.realtimeClientFactory = { _, _, configuration in
            recorder.record(configuration)
            return clientFactory.make()
        }

        #expect(await harness.session.startSpeechTrial())
        let configuration = try #require(recorder.value)
        #expect(configuration.language == "zh")
        #expect(
            configuration.keywords == ["第一段", "第二段", "第三段"],
            "试读要验证的正是用户显式选择的那条链路，用另一套配置等于什么也没验证"
        )
        #expect(harness.coordinator.phase != .recording,
                "试读期间不得进入录制态——那会建出记录库里的行")
        await harness.session.stopSpeechTrial()
    }

    @Test("a speech trial that heard nothing cannot become a calibration")
    func aSpeechTrialThatHeardNothingCannotBecomeACalibration() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "空试读",
            sourceText: "今天讲鲲鹏一体机。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()

        #expect(await harness.session.startSpeechTrial())
        let client = try #require(harness.clientFactory.clients.first)
        // 只送空白 partial：麦克风在响，但识别器没听到任何内容。
        await client.emit(.partial(itemID: "i1", delta: ""))
        await waitFor { harness.session.speechTrialStage == .listening }
        await harness.session.stopSpeechTrial()

        let evidence = try #require(harness.session.speechTrialEvidence)
        #expect(evidence.recognizedUnits == 0)
        #expect(!evidence.provesRecognition)
        #expect(!evidence.isAdoptable, "没听到内容的试读不产生倍率")
        #expect(harness.session.applySpeechTrialCalibration(baseEstimateSeconds: 60) == nil)
        #expect(harness.session.calibrationSource == .uncalibrated,
                "失败的试读不得改写倍率来源")
        #expect(harness.session.calibrationFactor == 1.0)
    }

    @Test("a speech trial releases the device and leaves no session row")
    func aSpeechTrialReleasesTheDeviceAndLeavesNoSessionRow() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "试读释放",
            sourceText: "今天讲鲲鹏一体机。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()

        #expect(await harness.session.startSpeechTrial())
        #expect(harness.coordinator.occupancy != nil, "试读期间设备确实被占用")
        let client = try #require(harness.clientFactory.clients.first)

        await harness.session.stopSpeechTrial()

        #expect(harness.session.speechTrialStage == .idle)
        #expect(harness.coordinator.occupancy == nil, "结束后不得残留占用")
        #expect(harness.coordinator.activeSessionID == nil,
                "试读不建 SessionStore 行")
        #expect(harness.sourceFactory.sources.first?.stopCount == 1)
        #expect(await client.currentCounters().closeCount == 1)
        #expect(harness.session.voiceAssistState == .off,
                "试读不占用语音跟读生命周期")
    }

    @Test("closing the stage during a speech trial still gives the microphone back")
    func closingTheStageDuringASpeechTrialReleasesTheDevice() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        #expect(await harness.session.startSpeechTrial())
        #expect(harness.coordinator.occupancy != nil)

        // 舞台窗口在试读期间被关掉。语音跟随的生命周期此时是 `.off`，
        // 它的 `beginStop` 对 `.off` 返回 nil——试读必须另有归处，
        // 否则麦克风与设备租约会一直挂着。
        await harness.session.closeStage()

        #expect(harness.coordinator.occupancy == nil, "关闭舞台必须归还设备租约")
        #expect(harness.sourceFactory.sources.first?.stopCount == 1, "采集必须停止")
        #expect(harness.session.speechTrialStage == .idle, "试读状态必须收尾")
        #expect(harness.session.speechTrialEvidence != nil, "已听到的内容要留下证据")
    }

    @Test("voice assist refuses to start on top of a running speech trial")
    func voiceAssistRefusesToStartDuringASpeechTrial() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        #expect(await harness.session.startSpeechTrial())
        let trialClient = try #require(harness.clientFactory.clients.first)

        // 试读期间再请求语音跟随：占用方本来就是提词器，coordinator 会认为
        // 「已经在跑同一个会话」而什么都不做，于是新管线会复用在试读那一套
        // client/source 上。必须明确拒绝，而不是让两套泵同时跑。
        await harness.session.enableVoiceAssist()

        #expect(harness.session.voiceAssistState != .following,
                "试读进行中不得进入跟读")
        #expect(harness.session.blocked == .speechTrialActive,
                "受阻原因要说对：占用麦克风的就是提词器自己的试读，写成「会议助手正在使用」会把责任推给一个根本没参与的功能")
        #expect(harness.session.speechTrialStage == .listening,
                "被拒绝的启动不得打断试读")
        #expect(harness.clientFactory.clients.count == 1, "不得另建第二条连接")
        #expect(await trialClient.currentCounters().closeCount == 0,
                "试读自己的连接不得被提前关掉")

        await harness.session.stopSpeechTrial()
    }

    @Test("manual display-line positioning preserves UTF-16 offsets and takes over voice assist")
    func manualDisplayLinePositionUsesExistingTakeover() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "UTF-16 行定位",
            sourceText: "第一段😀内容。第二段内容。第三段内容。"
        )
        try harness.session.openForManualReading()
        let segments = try #require(harness.session.activeVersion?.segments)
        #expect(segments.count == 3)

        harness.session.moveToReadingPosition(
            TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: 5)
        )
        #expect(harness.session.currentSegmentIndex == 0)
        #expect(harness.session.readingOffset == 5)

        await harness.session.enableVoiceAssist()
        let client = try #require(harness.clientFactory.clients.first)
        harness.session.moveToReadingPosition(
            TeleprompterAligner.Position(segmentIndex: 1, utf16Offset: 3)
        )
        await waitFor {
            guard harness.session.voiceAssistState == .pausedByUser,
                  harness.coordinator.occupancy == nil,
                  harness.sourceFactory.sources.first?.stopCount == 1 else {
                return false
            }
            return await client.currentCounters().closeCount == 1
        }

        #expect(harness.session.currentSegmentIndex == 1)
        #expect(harness.session.readingOffset == 3)
        #expect(harness.session.voiceAssistState == .pausedByUser)
        #expect(harness.sourceFactory.sources.first?.stopCount == 1)
        #expect(harness.coordinator.occupancy == nil)
        await harness.session.closeStage()
    }

    @Test("manual open rejects while another session operation owns the transition")
    func manualOpenRejectsWhileSessionIsPreparing() async throws {
        let connectGate = TestGate()
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(connectGate: connectGate)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        let startTask = Task { await harness.session.enableVoiceAssist() }
        await connectGate.waitUntilWaiting()
        #expect(harness.session.phase == .preparing)

        #expect(throws: TeleprompterStageOpenError.busy) {
            try harness.session.openForManualReading()
        }

        await connectGate.open()
        await startTask.value
        await harness.session.closeStage()
    }

    @Test("readyz diagnostics do not override a valid realtime capability binding")
    func realtimeBindingWinsOverReadinessDiagnostic() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        harness.session.realtimeCapabilityBindingProvider = {
            RealtimeCapabilityBinding(asrModelRevision: "asr-revision")
        }
        harness.session.serviceReadiness = {
            .notReady("readyz reports a diagnostic failure")
        }

        await harness.session.enableVoiceAssist()

        #expect(harness.session.phase == .following)
        #expect(harness.clientFactory.clients.count == 1)
        if let client = harness.clientFactory.clients.first {
            #expect(await client.currentCounters().connectCount == 1)
        } else {
            Issue.record("the valid capability binding should create a Realtime client")
        }
        await harness.session.disableVoiceAssist()
    }

    @Test("manual open rejects during close and succeeds after cleanup")
    func manualOpenRejectsDuringClose() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        #expect(harness.session.beginStageClose())
        #expect(harness.session.isClosingStage)
        #expect(throws: TeleprompterStageOpenError.closing) {
            try harness.session.openForManualReading()
        }

        await harness.session.finishStageClose()

        #expect(!harness.session.isClosingStage)
        #expect(!harness.session.isStageOpen)
        try harness.session.openForManualReading()
        #expect(harness.session.phase == .manual)
        #expect(harness.session.isStageOpen)
        await harness.session.closeStage()
    }

    @Test("disabling voice assist keeps an open stage in manual mode")
    func disablingVoiceAssistKeepsStageManual() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()

        await harness.session.disableVoiceAssist()

        #expect(harness.session.isStageOpen)
        #expect(harness.session.phase == .manual)
        #expect(harness.session.voiceAssistState == .off)
        #expect(harness.coordinator.occupancy == nil)
        await harness.session.closeStage()
    }

    /// cue/skip 不产出朗读正文，`text` 会是空的。切回「照念」时必须用原稿补上，
    /// 否则会得到一段永远念不出来的「照念」段落——那正是 decoder 对 speak
    /// 禁止的形状（speak 的正文必须非空）。
    @Test("switching a block back to speak restores readable text from its source")
    func switchingDispositionBackToSpeakRestoresText() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            try TestPreparationResponse.response(for: prompt)
        }
        await harness.session.analyzeDraft()
        #expect(harness.session.phase == .prepared)

        let block = try #require(harness.session.readingBlocks.first)
        let sourceText = block.rawSourceText
        #expect(!sourceText.isEmpty)
        #expect(!block.text.isEmpty)

        harness.session.setBlockDisposition(id: block.id, disposition: .cue)
        let cued = try #require(harness.session.readingBlocks.first { $0.id == block.id })
        #expect(cued.disposition == .cue)
        #expect(cued.text.isEmpty, "cue 不产出朗读正文")
        #expect(cued.rawSourceText == sourceText, "原稿必须留着，界面上要看得见")

        harness.session.setBlockDisposition(id: block.id, disposition: .speak)
        let restored = try #require(harness.session.readingBlocks.first { $0.id == block.id })
        #expect(restored.disposition == .speak)
        #expect(!restored.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "切回照念必须有正文可念，否则这段等于凭空消失")
        #expect(restored.text == sourceText)
    }

    @Test("manual open never adopts an unconfirmed AI draft")
    func manualOpenKeepsAcceptedVersion() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        let acceptedVersionID = try #require(harness.session.activeVersion?.id)
        let acceptedText = try #require(harness.session.activeVersion?.segments.first?.text)

        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            try TestPreparationResponse.response(for: prompt)
        }
        await harness.session.analyzeDraft()
        #expect(harness.session.pendingVersion != nil)
        #expect(harness.session.phase == .prepared)

        try harness.session.openForManualReading()

        #expect(harness.session.activeVersion?.id == acceptedVersionID)
        #expect(harness.session.activeVersion?.segments.first?.text == acceptedText)
        #expect(harness.session.pendingVersion != nil)
        #expect(harness.session.phase == .manual)
        #expect(harness.sourceFactory.sources.isEmpty)
        #expect(harness.clientFactory.clients.isEmpty)
    }

    /// 审阅页最重的一条数据安全缺陷：`acceptPendingVersion()` 先把候选版本写进
    /// `versions`、把 `pendingVersion` 置 nil、把 `document.activeVersionID` 挪到
    /// 新版本，最后才 `try saveBundle()`。存盘失败时 throw 出去，**候选版本已经
    /// 从内存里消失了**，而 `.atomicWriteFailed` 的文案偏偏是「稿件保存失败，原
    /// 版本仍然保留」——这句话在这条路上是假的。更糟的是 `canAcceptPendingVersion`
    /// 依赖 `pendingVersion != nil`，按钮随之变灰，**用户连重试都不行**。
    @Test("a store failure while accepting a pending version keeps the draft on screen")
    func aStoreFailureWhileAcceptingKeepsTheDraftOnScreen() async throws {
        try #require(getuid() != 0, "root 绕过目录权限，这条路径无法复现")
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        let acceptedVersionID = try #require(harness.session.activeVersion?.id)

        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            try TestPreparationResponse.response(for: prompt)
        }
        await harness.session.analyzeDraft()
        let documentID = try #require(harness.session.document?.id)
        #expect(harness.session.canAcceptPendingVersion, "前提：这次审阅本来是可采用的")

        let url = harness.documentBundleURL(documentID: documentID)
        let before = try Data(contentsOf: url)
        let documentsDirectory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: documentsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: documentsDirectory.path
            )
        }

        #expect(throws: TeleprompterV2StoreError.atomicWriteFailed) {
            try harness.session.acceptPendingVersion()
        }
        // 整理稿必须还在，按钮必须还能按——用户才有腾出空间后重试的机会。
        #expect(harness.session.pendingVersion != nil, "存盘失败不得销毁候选版本")
        #expect(harness.session.canAcceptPendingVersion, "存盘失败后必须还能重试")
        #expect(harness.session.activeVersion?.id == acceptedVersionID, "未写入的版本不得生效")
        #expect(harness.session.phase == .prepared, "必须仍停在整理页")
        #expect(try Data(contentsOf: url) == before, "磁盘字节必须逐字节不变")
    }

    @Test("editing the script invalidates the previous AI review state")
    func editingSourceInvalidatesPreparedState() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(title: "改稿", sourceText: "甲段。乙段。丙段。")
        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            try TestPreparationResponse.response(for: prompt)
        }
        await harness.session.analyzeDraft()
        #expect(harness.session.phase == .prepared)
        #expect(harness.session.pendingVersion != nil)
        #expect(!harness.session.readingBlocks.isEmpty)

        harness.session.updateSourceText("甲段被改写。乙段。丙段。")

        #expect(harness.session.phase == .draft)
        #expect(harness.session.pendingVersion == nil, "改稿后旧整理稿必须失效")
        #expect(harness.session.readingBlocks.isEmpty)
        #expect(harness.session.preparationResult == nil)
        #expect(harness.session.preparationProgress == nil)
    }

    @Test("an AI result that lands after an edit never comes back")
    func latePreparationResultAfterEditIsDiscarded() async throws {
        let gate = TestGate()
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(title: "改稿", sourceText: "甲段。乙段。丙段。")
        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            await gate.wait()
            return try TestPreparationResponse.response(for: prompt)
        }

        let preparation = Task { await harness.session.analyzeDraft() }
        await gate.waitUntilWaiting()
        harness.session.updateSourceText("甲段被改写。乙段。丙段。")
        await gate.open()
        await preparation.value

        #expect(harness.session.phase == .draft)
        #expect(harness.session.pendingVersion == nil, "旧文本的整理结果不得回填")
        #expect(harness.session.readingBlocks.isEmpty)
    }

    @Test("an input device that disappears fails closed and keeps manual reading")
    func inputDeviceLossFailsClosedWithManualFallback() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        harness.session.moveToSegment(1)
        harness.sourceFactory.nextStartFailure = MicrophoneCapture.Failure.engineFailed("蓝牙耳机已断开")

        await harness.session.enableVoiceAssist()

        #expect(
            harness.session.blocked == .inputDeviceUnavailable("蓝牙耳机已断开"),
            "设备异常要说明是输入设备，而不是把责任推给识别服务"
        )
        #expect(harness.session.blocked?.detail.contains("蓝牙耳机已断开") == true)
        #expect(harness.session.blocked?.detail.contains("手动") == true)
        #expect(harness.session.phase == .manual)
        #expect(harness.session.currentSegmentIndex == 1, "设备故障不能推进稿件")
        if case .unavailable = harness.session.voiceAssistState {} else {
            Issue.record("语音跟随应进入 unavailable 状态等待用户重试")
        }
        #expect(harness.coordinator.occupancy == nil, "失败后必须释放本功能的采集占用")
        for client in harness.clientFactory.clients {
            #expect(await client.currentCounters().closeCount == 1, "失败的连接必须关闭")
        }
    }

    @Test("an event storm degrades inside the bounded transport")
    func eventStormDegradesInsideBoundedTransport() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()
        let client = try #require(harness.clientFactory.clients.first)

        for revision in 1...600 {
            await client.emit(
                .partialSnapshot(
                    itemID: "storm",
                    revision: revision,
                    text: String(repeating: "甲", count: revision % 7 + 1)
                ),
                eventID: "storm-\(revision)"
            )
        }
        await settleTasks()

        #expect(harness.session.phase == .following, "事件风暴不能让舞台进入错误状态")
        #expect(harness.session.blocked == nil)
        #expect(harness.session.voiceAssistState == .following)
        #expect(
            harness.session.activeVersion?.segments.indices.contains(
                harness.session.currentSegmentIndex
            ) == true,
            "阅读位置必须仍在稿件范围内"
        )
    }

    /// 朗读提示这条路上，AI 调用成功、本地存盘失败，却被 `aiFailureMessage` 说成
    /// 「AI 暂时没能整理这份稿子……你可以重试」。责任归错了对象：AI 明明成功
    /// 了，而重试只会再烧一遍同样的调用、再失败一次。更糟的是 `versions` 里已经
    /// 写入了新提示却没回滚——用户被告知失败，提示却留在内存里，下一次任何
    /// 无关的保存（改目标时长、采用候选版本、关闭舞台存进度）会把它悄悄写进
    /// 磁盘。**报告失败，却悄悄生效**，是比报错本身更难查的一类问题。
    @Test("a store failure while saving reading cues blames the disk, not the AI, and rolls back")
    func aStoreFailureWhileSavingReadingCuesIsAttributedToTheDisk() async throws {
        try #require(getuid() != 0, "root 绕过目录权限，这条路径无法复现")
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        let documentID = try #require(harness.session.document?.id)
        let before = try #require(harness.session.activeVersion)
        let keywordsBefore = before.segments.map(\.keywords)

        harness.session.aiClient = TeleprompterAIClient { prompt in
            let data = Data(prompt.input.utf8)
            let context = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let units = context?["units"] as? [[String: Any]] ?? []
            let annotations = units.map { unit -> [String: Any] in
                let id = unit["id"] as? Int ?? 0
                let raw = unit["text"] as? String ?? ""
                let keyword = String(raw.prefix(3))
                return [
                    "start_unit": id,
                    "end_unit": id + 1,
                    "keywords": keyword.isEmpty ? [] : [keyword],
                    "match_phrases": [],
                    "pause_hint": "short",
                ]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: [
                "schema_version": "teleprompter.analysis.v2",
                "segments": annotations,
            ]), as: UTF8.self)
        }

        let url = harness.documentBundleURL(documentID: documentID)
        let onDisk = try Data(contentsOf: url)
        let documentsDirectory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: documentsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: documentsDirectory.path
            )
        }

        let message = await harness.session.annotateActiveVersion()

        // 归因必须指向保存，不能说 AI 没能整理——它明明成功了。
        let text = try #require(message)
        #expect(
            text.contains("保存"),
            "磁盘写失败必须说成保存失败，实际是 \(text)"
        )
        #expect(
            !text.contains("没能整理"),
            "AI 调用本身是成功的，把磁盘写失败说成 AI 没能整理会让读者白等一次重试，实际是 \(text)"
        )
        // 没存住就不能留在内存里，否则下一次无关保存会把它悄悄写进去。
        #expect(harness.session.activeVersion?.segments.map(\.keywords) == keywordsBefore)
        #expect(try Data(contentsOf: url) == onDisk, "磁盘字节必须逐字节不变")
    }

    /// 「直接使用原稿」是 AI 不可用时的主恢复路径，成功目标第一条就是让用户能
    /// 直接用原稿开讲。`useDeterministicFallback()` 的形态与第 43 条的
    /// `acceptPendingVersion()` 逐行相同：先 append 版本、挪 `activeVersionID`、
    /// 清掉 `pendingVersion`、把 `phase` 推到 `.ready`、清空 `blocked`，最后才
    /// `try saveBundle()`，**没有回滚**。存盘失败时：
    /// - 界面上两个「直接使用原稿」按钮用的是 `try?`，**错误被整个吞掉**，
    ///   用户点了没有任何反馈；
    /// - 内存已经推进到 `.ready`，磁盘还是原样，重开就没了；
    /// - 已经在审的 AI 结果被清空。
    @Test("a store failure while using the raw script keeps the session where it was")
    func aStoreFailureWhileUsingTheRawScriptRollsBack() async throws {
        try #require(getuid() != 0, "root 绕过目录权限，这条路径无法复现")
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        let documentID = try #require(harness.session.document?.id)
        let versionsBefore = harness.session.versions.count

        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            try TestPreparationResponse.response(for: prompt)
        }
        await harness.session.analyzeDraft()
        #expect(harness.session.pendingVersion != nil, "前提：审阅结果是在的")
        let pendingID = try #require(harness.session.pendingVersion?.id)
        let blocksBefore = harness.session.readingBlocks
        #expect(!blocksBefore.isEmpty, "前提：审阅页有内容，回滚才看得出来")

        let url = harness.documentBundleURL(documentID: documentID)
        let onDisk = try Data(contentsOf: url)
        let documentsDirectory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: documentsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: documentsDirectory.path
            )
        }

        #expect(throws: TeleprompterV2StoreError.atomicWriteFailed) {
            try harness.session.useDeterministicFallback()
        }
        // 没存住就必须整体退回：审阅结果、版本数、阶段都留在原地，
        // 用户才能再按一次「直接使用原稿」。
        #expect(harness.session.pendingVersion?.id == pendingID, "存盘失败不得清掉待采用的整理结果")
        #expect(harness.session.versions.count == versionsBefore, "存盘失败不得留下没落盘的版本")
        #expect(harness.session.readingBlocks == blocksBefore, "整理页内容必须原样留下")
        #expect(harness.session.phase == .prepared, "必须仍停在整理页而不是假装已就绪")
        #expect(try Data(contentsOf: url) == onDisk, "磁盘字节必须逐字节不变")
    }

    /// 整个回滚里最关键的字段是 `blocked`：界面上那两个「直接使用原稿」按钮
    /// **正是 `blocked` 非空时才渲染的**。`useDeterministicFallback()` 成功时把
    /// 它清成 nil 是对的，失败时若没放回去，恢复按钮就从界面上消失——用户既没有
    /// 版本、也看不到那条出路，卡在中间。这条单独钉住它。
    @Test("a store failure keeps the recovery reason that shows the raw-script button")
    func aStoreFailureKeepsTheRecoveryReason() async throws {
        try #require(getuid() != 0, "root 绕过目录权限，这条路径无法复现")
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        let documentID = try #require(harness.session.document?.id)

        let url = harness.documentBundleURL(documentID: documentID)
        let documentsDirectory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: documentsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: documentsDirectory.path
            )
        }

        // 真实流程：用户开启语音 → 没有可用版本 → 内部试一次「直接使用原稿」→
        // 存盘失败 → blocked = .noActiveVersion → 界面上出现那个恢复按钮。
        await harness.session.enableVoiceAssist()
        #expect(harness.session.blocked != nil, "前提：恢复按钮此时是可见的")

        // 用户按下那个按钮。存盘再失败一次时，blocked 必须回到 .noActiveVersion：
        // 它非空按钮才渲染，被清成 nil 的话读者既没有版本、也看不到那条出路。
        #expect(throws: TeleprompterV2StoreError.atomicWriteFailed) {
            try harness.session.useDeterministicFallback()
        }
        #expect(
            harness.session.blocked != nil,
            "存盘失败后恢复按钮必须还在——blocked 被清成 nil 的话用户就没有出路了"
        )
    }

    /// 语音开着时 `canEdit` 为 false，`load(documentID:)` 于是**静默 return**——
    /// 不抛错、不给消息。界面上那份文档行没有 `disabled` 门控，用户点另一份稿子
    /// 什么都没发生，而那支 `do`/`catch` 还会把 `operationMessage` 清成 nil，连
    /// 提示区都一并清空。判据第 2 条「切稿后旧事件不能推进」靠这个守卫成立，
    /// 但**拒绝得没有声音**：读者只会以为应用卡了。
    @Test("switching documents while the stage is live reports why it is refused")
    func switchingDocumentsWhileTheStageIsLiveIsRefusedLoudly() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        try harness.session.openForManualReading()
        let documentID = try #require(harness.session.document?.id)
        let versionID = try #require(harness.session.activeVersion?.id)

        await harness.session.enableVoiceAssist()
        #expect(harness.session.canEdit == false, "前提：语音开着时不允许切稿")

        #expect(throws: TeleprompterTextError.sessionBusy) {
            try harness.session.load(documentID: documentID)
        }
        // 拒绝必须是干净的：稿件、版本、阅读位置都不能动。
        #expect(harness.session.document?.id == documentID)
        #expect(harness.session.activeVersion?.id == versionID)
        #expect(harness.session.phase == .following, "拒绝切稿不得把舞台带下去")
    }

    /// 「重试保存」按钮存在的**前提**就是上次存盘失败了。读者腾出磁盘空间后按下
    /// 它，存盘确实成功了——但 `blocked` 仍然是 `.storeUnavailable`：横幅继续写着
    /// 「稿件保存失败」，按钮也还在。再点多少次结果都一样，**这个恢复入口永远
    /// 恢复不了**，只能靠旁边的 ✕ 手动关掉，而那等于让应用继续断言一件已经不
    /// 成立的事。同一文件的 `persistDraft()` 成功后是会清掉它的（`if case
    /// .storeUnavailable = blocked { blocked = nil }`），只有显式 `save()` 漏了。
    @Test("a successful explicit save clears the store failure it was retrying")
    func aSuccessfulExplicitSaveClearsTheStoreFailure() throws {
        try #require(getuid() != 0, "root 绕过目录权限，这条路径无法复现")
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        let documentsDirectory = harness.directory.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: documentsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: documentsDirectory.path
            )
        }

        harness.session.createDocument(title: "存盘失败", sourceText: "第一段内容。第二段内容。")
        guard case .storeUnavailable = harness.session.blocked else {
            Issue.record("前提：只读目录下新建稿件必须进入存盘失败态")
            return
        }

        // 读者腾出空间后点「重试保存」。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: documentsDirectory.path
        )
        try harness.session.save()

        #expect(
            harness.session.blocked != .storeUnavailable("稿子暂时没能保存，请稍后重试。"),
            "存盘已经成功，横幅还宣称失败——恢复入口永远恢复不了"
        )
    }

    /// 存盘失败态下（也就是第 48 条那个状态），文档只在内存里、不在 store 里。
    /// 此时 `exportMarkdown()` 与 `exportSourceData()` 双双返回 nil，而「复制稿件
    /// 内容」用的是前者且**没有任何兜底**——读者点了「复制稿件内容」，既没有复制、
    /// 也没有提示。对照两条导出路径：导出原稿有 `?? Data(doc.sourceText.utf8)`，
    /// 导出朗读稿有 `?? doc.sourceText`，**只有复制这条没有**。
    @Test("the manuscript text stays reachable for copying while the store is failing")
    func manuscriptTextStaysReachableWhileStoreFails() throws {
        try #require(getuid() != 0, "root 绕过目录权限，这条路径无法复现")
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        let documentsDirectory = harness.directory.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: documentsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: documentsDirectory.path
            )
        }

        let source = "第一段内容。第二段内容。"
        harness.session.createDocument(title: "复制", sourceText: source)
        guard case .storeUnavailable = harness.session.blocked else {
            Issue.record("前提：只读目录下必须进入存盘失败态")
            return
        }

        // 前提事实：两条现役导出接口在 store 失败时都拿不到东西。
        #expect(harness.session.exportMarkdown() == nil)
        #expect(harness.session.exportSourceData() == nil)
        // 缺陷本体：读者仍要能把稿子内容复制走。「复制稿件内容」原先直接用
        // `exportMarkdown()` 且无兜底，此时是空的——点了既没复制也没提示。
        #expect(harness.session.copyableDocumentText() == source)
    }

    /// 第 47、49 条之后把会话层里所有 `guard canEdit else { return }` 横扫了一遍，
    /// 共七处，`load` 已修，**剩下六处全是静默**。其中最刺眼的是 `deleteDocument`：
    /// 读者点删除、**在确认框里点了「删除」**、然后什么都没发生，界面那支
    /// `do`/`catch` 还会把 `operationMessage` 清成 nil。破坏性操作上「确认之后
    /// 静默」，比不做这个按钮更让人不安。
    @Test("deleting while the stage is live reports why it is refused")
    func deletingWhileTheStageIsLiveIsRefusedLoudly() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        try harness.session.openForManualReading()
        let documentID = try #require(harness.session.document?.id)

        await harness.session.enableVoiceAssist()
        #expect(harness.session.canEdit == false, "前提：语音开着时不允许破坏性操作")

        #expect(throws: TeleprompterTextError.sessionBusy) {
            try harness.session.deleteDocument(documentID: documentID)
        }
        #expect(harness.session.document?.id == documentID, "拒绝删除不得动稿件")
        #expect(harness.session.phase == .following, "拒绝删除不得把舞台带下去")
    }

    /// `createDocument` 的两个重载都是 `guard canEdit else { return }`，而调用它们的
    /// 入口里，`importFromURL` 在调用**之后无条件**设 `operationMessage = "已导入「…」`。
    /// 于是舞台开着时导入文件：什么都没导入，界面却说「已导入」——**虚假成功消息**，
    /// 比静默更坏：读者会以为稿子已经换好了，随后在旧稿上继续工作。
    @Test("importing while the stage is live reports failure instead of claiming success")
    func importingWhileTheStageIsLiveFailsLoudly() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        try harness.session.openForManualReading()
        let documentID = try #require(harness.session.document?.id)

        await harness.session.enableVoiceAssist()
        #expect(harness.session.canEdit == false, "前提：语音开着时不允许新建或导入")

        // 剪贴板／拖拽文本走的这条路径。
        #expect(throws: TeleprompterTextError.sessionBusy) {
            try harness.session.createDocumentValidated(title: "剪贴板稿件", sourceText: "新的稿子内容。")
        }
        #expect(harness.session.document?.id == documentID, "拒绝导入不得换掉当前稿件")
        #expect(harness.session.phase == .following, "拒绝导入不得把舞台带下去")
    }

    @Test("bundles this build cannot read keep their files and do not take the other documents down")
    func unreadableBundlesArePreservedAndIsolated() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        let goodID = try #require(harness.session.document?.id)

        let futureBytes = Data(#"{"format_version":3}"#.utf8)
        let future = harness.documentBundleURL(documentID: "future-format")
        try futureBytes.write(to: future)
        let corrupt = harness.documentBundleURL(documentID: "corrupt")
        try Data("{ 这不是 JSON".utf8).write(to: corrupt)
        let invalid = harness.documentBundleURL(documentID: "invalid")
        try Data(#"{"format_version":2}"#.utf8).write(to: invalid)

        let listed = try harness.session.listDocuments()

        #expect(listed.map(\.id) == [goodID], "读不动的稿件不得污染可用列表")
        #expect(
            harness.session.unavailableDocuments.map(\.id).sorted()
                == ["corrupt", "future-format", "invalid"],
            "三份读不动的稿件都要被单列出来，而不是从列表里消失"
        )
        for item in harness.session.unavailableDocuments {
            #expect(item.error != nil, "\(item.id) 必须带失败原因")
            #expect(item.isAvailable == false)
        }

        // 原数据保留：文件既没被删，也没被改写。
        for url in [future, corrupt, invalid] {
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent) 必须原样留在磁盘上"
            )
        }
        #expect(
            try Data(contentsOf: future) == futureBytes,
            "读不动的稿件文件内容不得被改写"
        )

        // 单独打开读不动的稿件必须报错，而不是静默返回一份空稿。
        #expect(throws: TeleprompterV2StoreError.self) {
            try harness.session.load(documentID: "future-format")
        }
        #expect(
            harness.session.document?.id == goodID,
            "打开失败不得换掉读者当前正在用的稿件"
        )
    }

    @Test("every stage cycle releases its capture, connection and occupancy")
    func repeatedStageCyclesReleaseResources() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()

        for _ in 0..<20 {
            try harness.session.openForManualReading()
            await harness.session.enableVoiceAssist()
            #expect(harness.session.voiceAssistState == .following)
            #expect(harness.coordinator.occupancy?.kind == .teleprompter)
            await harness.session.closeStage()
            #expect(harness.coordinator.occupancy == nil, "关闭舞台必须立即释放占用")
            #expect(harness.session.currentSegmentIndex >= 0)
        }

        #expect(harness.clientFactory.clients.count == 20)
        for client in harness.clientFactory.clients {
            #expect(await client.currentCounters().closeCount == 1, "每一轮的连接都必须关闭")
            #expect(await client.currentCounters().connectCount == 1)
        }
        #expect(harness.sourceFactory.sources.count == 20)
        #expect(harness.sourceFactory.sources.allSatisfy { $0.stopCount == 1 }, "每一轮采集都必须停止")
    }

    @Test("voice start hands the recognizer the script's keywords and the chosen language")
    func voiceStartSendsLanguageAndKeywords() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        try harness.session.openForManualReading()
        harness.session.preferredSpeechLanguage = "zh"
        harness.session.aiClient = TeleprompterAIClient { prompt in
            let data = Data(prompt.input.utf8)
            let context = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let units = context?["units"] as? [[String: Any]] ?? []
            let annotations = units.map { unit -> [String: Any] in
                let id = unit["id"] as? Int ?? 0
                // Keywords must be grounded in their own segment text; the
                // analysis decoder rejects invented terms.
                let raw = unit["text"] as? String ?? ""
                let keyword = String(raw.prefix(3))
                return [
                    "start_unit": id,
                    "end_unit": id + 1,
                    "keywords": keyword.isEmpty ? [] : [keyword],
                    "match_phrases": [],
                    "pause_hint": "short"
                ]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: [
                "schema_version": "teleprompter.analysis.v2",
                "segments": annotations
            ]), as: UTF8.self)
        }
        await harness.session.annotateActiveVersion()

        let recorder = ConfigurationRecorder()
        let clientFactory = FakeTeleprompterClientFactory()
        harness.session.realtimeClientFactory = { _, _, configuration in
            recorder.record(configuration)
            return clientFactory.make()
        }

        await harness.session.enableVoiceAssist()

        let configuration = try #require(recorder.value)
        #expect(configuration.language == "zh")
        #expect(
            configuration.keywords == ["第一段", "第二段", "第三段"],
            "识别提示必须来自当前稿件的关键词"
        )
    }

    @Test("an out-of-contract language degrades to the server default")
    func invalidSpeechLanguageIsDropped() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        try harness.session.openForManualReading()
        harness.session.preferredSpeechLanguage = "中"
        let recorder = ConfigurationRecorder()
        let clientFactory = FakeTeleprompterClientFactory()
        harness.session.realtimeClientFactory = { _, _, configuration in
            recorder.record(configuration)
            return clientFactory.make()
        }

        await harness.session.enableVoiceAssist()

        #expect(harness.session.voiceAssistState == .following)
        #expect(recorder.value?.language == nil, "越界语言不应让连接失败")
    }

    @Test("every offered recognition language survives contract sanitisation")
    func offeredSpeechLanguagesAreAllContractValid() {
        for choice in TeleprompterRealtimeConfiguration.speechLanguageChoices {
            let sanitized = TeleprompterRealtimeConfiguration(language: choice.code).sanitized
            #expect(
                sanitized.language == choice.code,
                "菜单里的「\(choice.label)」会被契约清洗成 nil：用户点了没有任何效果，而且不会报错"
            )
        }
    }

    @Test("a stored recognition language is sanitised before it reaches the connection")
    func storedSpeechLanguageIsSanitisedBeforeUse() {
        #expect(
            TeleprompterRealtimeConfiguration(language: "中").sanitized.language == nil,
            "越界值退回服务端默认，而不是带进连接"
        )
        #expect(TeleprompterRealtimeConfiguration(language: "").sanitized.language == nil)
        #expect(
            TeleprompterRealtimeConfiguration(language: "  zh  ").sanitized.language == "zh",
            "存储里可能带空白，清洗后应恢复成可用值"
        )
    }

    @Test("explicit voice start uses the current segment and old failures cannot move it")
    func manualTakeoverInvalidatesOldPipeline() async throws {
        let drainGate = TestGate()
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(drainGate: drainGate)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        harness.session.moveToSegment(1)

        await harness.session.enableVoiceAssist()

        #expect(harness.session.currentSegmentIndex == 1)
        #expect(harness.session.phase == .following)
        #expect(harness.session.voiceAssistState == .following)
        #expect(harness.coordinator.occupancy?.kind == .teleprompter)
        #expect(harness.sourceFactory.sources.first?.startCount == 1)
        let client = try #require(harness.clientFactory.clients.first)
        #expect(await client.currentCounters().connectCount == 1)

        harness.session.moveToSegment(2)
        #expect(harness.session.currentSegmentIndex == 2)
        #expect(harness.session.voiceAssistState == .stopping)

        await client.emit(
            .failed(itemID: "old", code: "backend_busy", message: "旧连接失败"),
            eventID: "old-failure"
        )
        await settleTasks()
        #expect(harness.session.currentSegmentIndex == 2)
        #expect(harness.session.blocked == nil)
        #expect(harness.session.phase == .manual)

        await drainGate.open()
        await harness.session.disableVoiceAssist()
        #expect(harness.session.voiceAssistState == .pausedByUser)
        #expect(harness.sourceFactory.sources.first?.stopCount == 1)
        #expect(await client.currentCounters().closeCount == 1)
    }

    @Test("manual takeover during a delayed connect closes the late client")
    func lateConnectAfterManualTakeoverIsReleased() async throws {
        let connectGate = TestGate()
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(connectGate: connectGate)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        let startTask = Task { await harness.session.enableVoiceAssist() }
        await connectGate.waitUntilWaiting()
        harness.session.moveToSegment(2)
        await connectGate.open()
        await startTask.value
        await waitFor { await harness.clientFactory.clients.first?.currentCounters().closeCount == 1 }

        #expect(harness.session.currentSegmentIndex == 2)
        #expect(harness.session.voiceAssistState == .pausedByUser)
        #expect(harness.coordinator.occupancy == nil)
        #expect(harness.sourceFactory.sources.isEmpty)
        let client = try #require(harness.clientFactory.clients.first)
        #expect(await client.currentCounters().closeCount == 1)
    }

    @Test("repeated manual navigation keeps the last position and starts one stop only")
    func repeatedManualNavigationIsIdempotent() async throws {
        let drainGate = TestGate()
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(drainGate: drainGate)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()
        let client = try #require(harness.clientFactory.clients.first)

        for _ in 0..<20 {
            harness.session.moveToSegment(2)
            harness.session.moveToSegment(1)
            harness.session.moveToSegment(2)
        }

        #expect(harness.session.currentSegmentIndex == 2)
        #expect(harness.session.voiceAssistState == .stopping)
        await waitFor { await client.currentCounters().drainCount == 1 }
        #expect(await client.currentCounters().drainCount == 1)

        await drainGate.open()
        await harness.session.disableVoiceAssist()
        #expect(await client.currentCounters().drainCount == 1)
        #expect(await client.currentCounters().closeCount == 1)
        #expect(harness.sourceFactory.sources.first?.stopCount == 1)
    }

    @Test("stop failure remains fail-closed until an explicit stop retry")
    func stopFailureBlocksASecondPipeline() async throws {
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(drainFails: true)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        await harness.session.enableVoiceAssist()
        await harness.session.disableVoiceAssist()

        guard case .stopFailed = harness.session.voiceAssistState else {
            Issue.record("expected stopFailed, got \(harness.session.voiceAssistState)")
            return
        }
        #expect(!harness.session.voiceAssistState.canStart)
        #expect(harness.clientFactory.clients.count == 1)

        await harness.session.retryStopVoiceAssist()
        #expect(harness.session.voiceAssistState == .off)

        await harness.session.enableVoiceAssist()
        #expect(harness.clientFactory.clients.count == 2)
        await harness.session.closeStage()
    }

    @Test("close releases resources and reopening keeps position but resets voice")
    func closeAndReopenPreservesPosition() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        harness.session.moveToSegment(2)
        await harness.session.enableVoiceAssist()
        let client = try #require(harness.clientFactory.clients.first)

        await harness.session.closeStage()

        #expect(!harness.session.isStageOpen)
        #expect(harness.session.voiceAssistState == .off)
        #expect(!harness.session.isMicrophoneCapturing)
        #expect(harness.coordinator.occupancy == nil)
        #expect(harness.sourceFactory.sources.first?.stopCount == 1)
        #expect(await client.currentCounters().closeCount == 1)

        try harness.session.openForManualReading()
        #expect(harness.session.currentSegmentIndex == 2)
        #expect(harness.session.voiceAssistState == .off)
        #expect(harness.session.isStageOpen)
        #expect(harness.clientFactory.clients.count == 1)
    }

    @Test("repeated close is idempotent")
    func repeatedCloseDoesNotDuplicateRelease() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()
        let client = try #require(harness.clientFactory.clients.first)

        await harness.session.closeStage()
        await harness.session.closeStage()

        #expect(await client.currentCounters().closeCount == 1)
        #expect(await client.currentCounters().drainCount == 1)
        #expect(harness.sourceFactory.sources.first?.stopCount == 1)
        #expect(harness.coordinator.occupancy == nil)
        #expect(!harness.session.isStageOpen)
    }

    @Test("intra-segment reading offset is restored for the same frozen version")
    func savedIntraSegmentOffsetSurvivesReload() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        try harness.session.openForManualReading()
        let documentID = try #require(harness.session.document?.id)
        let segment = try #require(harness.session.currentSegment)
        let offset = min(4, segment.text.utf16.count)
        harness.session.moveToReadingPosition(
            .init(segmentIndex: 0, utf16Offset: offset)
        )

        let reloaded = try harness.makeReloadedSession()
        try reloaded.load(documentID: documentID)

        #expect(reloaded.activeVersion?.id == harness.session.activeVersion?.id)
        #expect(reloaded.currentSegmentIndex == 0)
        #expect(reloaded.currentSegment?.text == segment.text)
        #expect(reloaded.readingOffset == offset, "同一冻结版本必须精确恢复句内位置")
    }

    @Test("run clock is continuous across voice transitions and resets only on reopen")
    func runClockSurvivesVoiceTransitions() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        var beforeVoice = harness.session.runClock.elapsedSeconds
        for _ in 0..<60 where beforeVoice <= 0 {
            try await Task.sleep(for: .milliseconds(50))
            beforeVoice = harness.session.runClock.elapsedSeconds
        }
        #expect(beforeVoice > 0)

        await harness.session.enableVoiceAssist()
        var afterVoice = harness.session.runClock.elapsedSeconds
        for _ in 0..<60 where afterVoice <= beforeVoice {
            try await Task.sleep(for: .milliseconds(50))
            afterVoice = harness.session.runClock.elapsedSeconds
        }
        #expect(afterVoice > beforeVoice)

        await harness.session.closeStage()
        #expect(!harness.session.isStageOpen)

        try harness.session.openForManualReading()
        #expect(harness.session.runClock.elapsedSeconds == 0)
    }

    /// 闸门必须记住自己已经开启。2026-09-28 实测：`drainGate` 的开启信号在等待者
    /// 到达之前发出时被整段丢弃，随后到达的 `wait()` 永久挂起。单独跑这个套件时
    /// 时序恰好成立，全量并行时翻转，`xcodebuild` 就再也等不到进程退出。
    @Test("a gate that was opened before the wait arrived still releases the wait")
    func gateOpenedBeforeWaitStillReleasesTheWait() async {
        let gate = TestGate()
        let probe = GateProbe()

        await gate.open()
        Task {
            await gate.wait()
            await probe.markFinished()
        }

        for _ in 0..<1_000 {
            if await probe.finished { break }
            await Task.yield()
        }
        #expect(await probe.finished, "先开启的闸门必须放行后到的等待者")
    }

    /// 恢复默认语速是一次选择，不是一次测量。倍率回到 1.0 之后，时长估计必须
    /// 重新按未校准呈现，否则用户会把默认值当成实测值（#111 步骤 5）。
    @Test("resetting to the default pace is not a measurement")
    func resettingCalibrationClearsItsProvenance() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        #expect(harness.session.calibrationSource == .uncalibrated)
        #expect(harness.session.calibrationFactor == 1.0)
        #expect(!harness.session.isPaceCalibrated)

        harness.session.applyTrialCalibration(
            k: 1.2,
            source: .manualTrial(durationSeconds: 72)
        )
        #expect(harness.session.calibrationSource == .manualTrial(durationSeconds: 72))
        #expect(harness.session.calibrationFactor == 1.2)
        #expect(harness.session.isPaceCalibrated)

        harness.session.applyTrialCalibration(k: 1.0, source: .uncalibrated)
        #expect(harness.session.calibrationSource == .uncalibrated)
        #expect(harness.session.calibrationFactor == 1.0)
        #expect(!harness.session.isPaceCalibrated)
    }

    /// 读者按下暂停的那一刻，跟读指示就必须已经是「手动浏览中」——不能等到
    /// 排空与关闭（最多 8 秒）跑完才改。等待窗口期间 drain 被闸门挡住，
    /// 所以这里断言的是同步交付的状态，不是收尾后的最终状态。
    @Test("pausing follow reports manual browsing before the drain finishes")
    func pausingFollowReportsManualBeforeDrainCompletes() async throws {
        let drainGate = TestGate()
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(drainGate: drainGate)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()
        #expect(harness.session.followState != .manual)

        harness.session.pauseFollowing()

        #expect(harness.session.voiceAssistState == .stopping)
        #expect(harness.session.followState == .manual)
        #expect(harness.session.followStatusText == "手动浏览中")

        await drainGate.open()
        await waitFor { harness.session.voiceAssistState == .pausedByUser }
        await harness.session.closeStage()
    }

    /// 舞台关闭的令牌是一次性的：窗口关闭委托与菜单里的「关闭」可能都到一次。
    /// 第二次 `beginStageClose()` 若换了令牌，第一次的 `finishStageClose()` 就会
    /// 在 `stageCloseToken == token` 处返回，`stageCloseToken` 永远不会被清掉，
    /// 舞台从此再也打不开。
    @Test("a second close request while closing is refused and the first still finishes")
    func secondCloseRequestDuringCloseIsRefused() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()

        #expect(harness.session.beginStageClose())
        #expect(!harness.session.beginStageClose(), "关闭令牌必须一次只发一次")

        await harness.session.finishStageClose()
        #expect(!harness.session.isClosingStage)
        #expect(!harness.session.isStageOpen)
        #expect(harness.session.voiceAssistState == .off)
        try harness.session.openForManualReading()
        #expect(harness.session.phase == .manual)
        await harness.session.closeStage()
    }

    /// 「结束当前会话」走 coordinator，不经过 `requestVoiceStop`，所以把跟读
    /// 收回手动是 `stopCapture()` 自己的职责。少了那一步，采集已经释放、
    /// 指示却还停在「跟读咬合」，并且落盘的 `mode` 也是 `.following`。
    @Test("ending the session from the coordinator returns follow state to manual")
    func coordinatorStopReturnsFollowStateToManual() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()
        #expect(harness.session.followState != .manual)
        let client = try #require(harness.clientFactory.clients.first)

        await harness.coordinator.stopCapture(endingWith: .user)

        #expect(harness.session.followState == .manual)
        #expect(harness.session.followStatusText == "手动浏览中")
        #expect(harness.coordinator.occupancy == nil)
        #expect(await client.currentCounters().closeCount == 1)
        await harness.session.closeStage()
    }

    /// 段首不能再往前、段尾不能再往后。夹取写在会话里一层，也写在
    /// `TeleprompterFollowController.manualMove` 里一层；这里钉住的是交付
    /// 行为——无论从哪一层夹，越界的那一步都停在边界上。
    @Test("segment stepping stops at both ends of the script")
    func segmentSteppingStopsAtBothEnds() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        let segments = try #require(harness.session.activeVersion?.segments)
        let lastIndex = segments.count - 1

        harness.session.moveToSegment(lastIndex)
        for _ in 0..<3 {
            harness.session.moveToNext()
        }
        #expect(harness.session.currentSegmentIndex == lastIndex)

        for _ in 0..<(lastIndex + 3) {
            harness.session.moveToPrevious()
        }
        #expect(harness.session.currentSegmentIndex == 0)
    }

    /// 目标时长属于这份稿，不属于一次运行。
    ///
    /// 它以前只活在内存里，唯一的落盘位置是 `last_run.target_seconds`——而载入
    /// 路径压根不读回那一位。于是重开一个 App 之后，`targetMinutes` 停在
    /// `defaultTargetMinutes`（20），一份两百字的稿顶着「目标 20 分」。
    @Test("a document keeps its own target minutes across a reload")
    func targetMinutesSurviveReload() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        let documentID = try #require(harness.session.document?.id)

        harness.session.setTargetMinutes(3)
        #expect(harness.session.targetMinutes == 3)
        try harness.session.save()

        let reloaded = try harness.makeReloadedSession()
        try reloaded.load(documentID: documentID)

        #expect(reloaded.targetMinutes == 3, "重开必须回到这份稿自己的目标时长，而不是全局默认")
        #expect(reloaded.runClock.targetSeconds == 180)
    }

    /// 没有存过目标时长的老文档，按原稿估算补一个，而不是直接吃 20 分钟默认值。
    @Test("a document without a stored target derives one from its own text")
    func targetMinutesFallBackToTheEstimateNotTheGlobalDefault() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "长稿",
            sourceText: String(repeating: "这是一段用来估算时长的中文稿件内容。", count: 40)
        )
        let documentID = try #require(harness.session.document?.id)
        let estimate = try #require(harness.session.suggestedTargetMinutes)
        #expect(estimate < TeleprompterTimingPolicy.defaultTargetMinutes, "用例前提：这份稿明显短于默认目标")

        // 抹掉持久化字段，模拟一份还没有 target_minutes 的旧文档。
        let url = harness.documentBundleURL(documentID: documentID)
        var bundle = try JSONDecoder().decode(
            TeleprompterV2DocumentBundle.self,
            from: Data(contentsOf: url)
        )
        bundle.document.targetMinutes = nil
        try JSONEncoder().encode(bundle).write(to: url)

        let reloaded = try harness.makeReloadedSession()
        try reloaded.load(documentID: documentID)

        #expect(reloaded.targetMinutes == estimate)
    }

    /// 估不准的时候不许再报一个分钟数。
    ///
    /// `evaluatePreflight` 会因为稿里有数字、网址或非中英文本而给出「无法预估」，
    /// 同一屏却把目标预填成「1 分」——一个说算不准，一个已经填好了。预填和预检
    /// 必须用同一个「可靠」判据，否则界面就在自相矛盾。
    @Test("no target is suggested when the duration estimate is uncertain")
    func uncertainEstimateYieldsNoTargetSuggestion() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "带数字的稿",
            sourceText: "马里亚纳海沟最深处是 10994 米。2023 年的记录是 9000 种生物。"
        )

        #expect(harness.session.suggestedTargetMinutes == nil)
        if case .uncertain = harness.session.preflightConclusion {
            // 与预检同源：预检说算不准，建议就不该给数。
        } else {
            Issue.record("含数字的稿件应判为无法预估，实际得到 \(harness.session.preflightConclusion)")
        }
    }

    /// 一次真实口播会依次经过有效推进、脱稿、回稿、重读、掉线和手动接管。
    ///
    /// 每个场景各自都有回归；这条把它们串成**一次运行**，验证状态不会互相污染。
    ///
    /// 这里断言的是**误推进与资源**：会话层拿不到真实 ASR 对齐证据，所以"该推进时
    /// 确实推进"由 `TeleprompterFollowControllerTests` 在跟随控制器层证明；这一层
    /// 负责证明无论读到哪一句、无论连不连得上，位置都不会自己乱跑，掉线也不丢位置。
    @Test("one reading run survives advance, detour, return, reread, disconnect and takeover")
    func oneReadingRunKeepsPositionHonestAcrossEveryScenario() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()
        let client = try #require(harness.clientFactory.clients.first)
        #expect(harness.session.currentSegmentIndex == 0)
        #expect(harness.session.voiceAssistState == .following)

        // 只听到本段正文时还没有可定位的新锚点：位置不动，而不是乐观地前进。
        await client.emit(.completed(itemID: "i1", transcript: "第一段内容"))
        try await Task.sleep(for: .milliseconds(120))
        #expect(
            harness.session.currentSegmentIndex == 0,
            "证据不足时不得前进，实际 \(harness.session.currentSegmentIndex)"
        )

        // 脱稿：说了稿外的话，位置不许动。
        await client.emit(.completed(itemID: "i2", transcript: "今天天气不错我们聊聊别的"))
        try await Task.sleep(for: .milliseconds(120))
        #expect(harness.session.currentSegmentIndex == 0, "脱稿不得被当成推进")

        // 有效推进 / 回稿：说到下一段正文，锚点成立，照常前进。
        await client.emit(.completed(itemID: "i3", transcript: "第二段内容"))
        await waitFor { harness.session.currentSegmentIndex == 1 }
        #expect(
            harness.session.currentSegmentIndex == 1,
            "读到下一段正文后应继续前进，实际 \(harness.session.currentSegmentIndex)"
        )

        // 重读与重复识别：重复的句子不是新的推进依据。
        await client.emit(.completed(itemID: "i4", transcript: "第一段内容"))
        try await Task.sleep(for: .milliseconds(120))
        await client.emit(.completed(itemID: "i5", transcript: "第一段内容"))
        try await Task.sleep(for: .milliseconds(120))
        #expect(
            harness.session.currentSegmentIndex <= 1,
            "重读不得把位置甩到后面，实际 \(harness.session.currentSegmentIndex)"
        )

        // 掉线：连接关闭后必须释放占用并回到手动，位置留在用户离开的地方。
        await client.emit(.closed(code: 1006))
        await waitFor { harness.coordinator.occupancy == nil }
        #expect(harness.session.phase == .manual)
        #expect(harness.session.currentSegmentIndex >= 0, "掉线不得丢掉用户的阅读位置")

        // 手动接管：用户自己挪位置；掉线那一轮的迟到事件不得再动它。
        harness.session.moveToSegment(2)
        await settleTasks()
        #expect(harness.session.currentSegmentIndex == 2, "手动接管要落在用户选的位置")
        await client.emit(.completed(itemID: "i-late", transcript: "第三段内容"))
        try await Task.sleep(for: .milliseconds(120))
        #expect(harness.session.currentSegmentIndex == 2, "掉线后的迟到事件不得推进")

        // 资源释放：关闭舞台后采集与连接都只释放一次。
        await harness.session.closeStage()
        #expect(harness.coordinator.occupancy == nil)
        for closed in harness.clientFactory.clients {
            #expect(await closed.currentCounters().closeCount >= 1)
        }
        #expect(harness.sourceFactory.sources.allSatisfy { $0.stopCount == 1 })
    }
}
private enum TestPreparationResponse {
    enum Failure: Error {
        case unavailable
    }

    static func response(for prompt: TeleprompterPreparationPrompt) throws -> String {
        if prompt.schemaVersion == "teleprompter.reduction.v1" {
            return #"{"schema_version":"teleprompter.reduction.v1","patches":[],}"#
        }
        if prompt.schemaVersion == "teleprompter.grouping.v1" {
            let input = try JSONDecoder().decode(
                TeleprompterPreparationMapInput.self,
                from: Data(prompt.input.utf8)
            )
            guard !input.targets.isEmpty else { throw Failure.unavailable }
            let groups = stride(from: 0, to: input.targets.count, by: 8).map { start in
                TeleprompterGroupingBlock(
                    startUnit: start,
                    endUnit: min(start + 8, input.targets.count)
                )
            }
            return String(decoding: try JSONEncoder().encode(
                TeleprompterGroupingOutput(groups: groups)
            ), as: UTF8.self)
        }
        if prompt.schemaVersion == "teleprompter.rewrite.v1" {
            let input = try JSONDecoder().decode(
                TeleprompterRewriteInput.self,
                from: Data(prompt.input.utf8)
            )
            guard !input.groups.isEmpty else { throw Failure.unavailable }
            let blocks = input.groups.map { group in
                TeleprompterRewriteBlock(
                    blockID: group.id,
                    disposition: .speak,
                    text: group.sourceUnits.map(\.rawText).joined(),
                )
            }
            return String(decoding: try JSONEncoder().encode(
                TeleprompterRewriteOutput(blocks: blocks)
            ), as: UTF8.self)
        }
        throw Failure.unavailable
    }
}

@MainActor
private func settleTasks() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

@MainActor
private func waitFor(
    timeoutIterations: Int = 200,
    _ condition: @MainActor () async -> Bool
) async {
    for _ in 0..<timeoutIterations {
        if await condition() { return }
        await Task.yield()
    }
}
