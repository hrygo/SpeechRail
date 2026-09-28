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
        ))
        #expect(harness.session.activeVersion?.segments.first?.acceptedReadings.isEmpty == true)
        // Removing something that is not there reports honestly instead of
        // pretending a save happened.
        #expect(!(harness.session.removeConfirmedReading(
            segmentID: original.id,
            displayRange: range
        )))
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
        #expect(harness.session.phase == .review)

        try harness.session.openForManualReading()

        #expect(harness.session.activeVersion?.id == acceptedVersionID)
        #expect(harness.session.activeVersion?.segments.first?.text == acceptedText)
        #expect(harness.session.pendingVersion != nil)
        #expect(harness.session.phase == .manual)
        #expect(harness.sourceFactory.sources.isEmpty)
        #expect(harness.clientFactory.clients.isEmpty)
    }

    @Test("qualifier loss surfaces as locatable review items instead of silent success")
    func semanticRiskBecomesReviewItems() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(
            title: "成本稿",
            sourceText: "仅在试运行期间，方案 A 的单次成本不超过 50 元。"
        )
        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            if prompt.schemaVersion == "teleprompter.rewrite.v1" {
                let input = try JSONDecoder().decode(
                    TeleprompterRewriteInput.self,
                    from: Data(prompt.input.utf8)
                )
                let blocks = input.groups.map { group in
                    TeleprompterRewriteBlock(
                        blockID: group.id,
                        mode: .speak,
                        text: "方案 A 的单次成本是 50 元。",
                        issues: []
                    )
                }
                return String(decoding: try JSONEncoder().encode(
                    TeleprompterRewriteOutput(blocks: blocks)
                ), as: UTF8.self)
            }
            return try TestPreparationResponse.response(for: prompt)
        }

        await harness.session.analyzeDraft()

        #expect(harness.session.phase == .review)
        #expect(harness.session.pendingVersion != nil)
        let item = try #require(harness.session.reviewItems.first {
            $0.issue == .conditionRemoved
        })
        #expect(item.sourceSnippet.contains("不超过"))
        #expect(harness.session.reviewItems.contains { $0.issue == .comparisonChanged })
        let block = try #require(harness.session.readingBlocks.first {
            $0.id == item.blockID
        })
        #expect(block.disposition == .unresolved)
    }

    @Test("condense proposes deletions that must be reviewed before use")
    func condenseCreatesDeletionReviewItems() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(title: "精简稿", sourceText: "甲段。乙段。丙段。")
        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            try TestCondenseResponse.response(for: prompt, omittingLastUnit: true)
        }

        await harness.session.condenseDraft()

        #expect(harness.session.phase == .review)
        #expect(harness.session.pendingVersion != nil)
        let item = try #require(harness.session.reviewItems.first {
            $0.issue == .contentRemoved
        })
        #expect(item.sourceSnippet.contains("丙段"), "删除审阅必须展示被删掉的原文")
        let block = try #require(harness.session.readingBlocks.first {
            $0.id == item.blockID
        })
        #expect(block.disposition == .skip)
        #expect(!harness.session.canAcceptPendingVersion, "删除未确认前不能采用")
    }

    @Test("condense fails the whole round when a must-keep paragraph would be deleted")
    func condenseFailsClosedWhenAMarkedParagraphWouldBeDeleted() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(title: "精简稿", sourceText: "甲段。\n\n乙段。\n\n丙段。")
        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            try TestCondenseResponse.response(for: prompt, omittingLastUnit: true)
        }

        let ranges = harness.session.mustKeepCandidateRanges()
        #expect(ranges.count == 3, "每个空行分隔的段落都应可被标记为必讲")

        // The fake omits the last unit, which is exactly the paragraph marked
        // must-keep. The pipeline must refuse the whole round rather than ship
        // a version that deletes it.
        await harness.session.condenseDraft(mustKeepSourceRanges: [try #require(ranges.last)])

        #expect(harness.session.pendingVersion == nil, "锁定内容被删时不得产出候选版本")
        #expect(harness.session.blocked != nil, "整轮必须失败关闭并给出提示")
        #expect(
            !harness.session.reviewItems.contains { $0.issue == .contentRemoved },
            "失败关闭时不应留下任何删减审阅项"
        )
    }

    @Test("marking one paragraph does not lock the others")
    func condenseStillReviewsDeletionsOutsideTheMarkedParagraphs() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(title: "精简稿", sourceText: "甲段。\n\n乙段。\n\n丙段。")
        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            try TestCondenseResponse.response(for: prompt, omittingLastUnit: true)
        }

        let ranges = harness.session.mustKeepCandidateRanges()
        await harness.session.condenseDraft(mustKeepSourceRanges: [try #require(ranges.first)])

        #expect(harness.session.phase == .review)
        let item = try #require(harness.session.reviewItems.first { $0.issue == .contentRemoved })
        #expect(
            item.sourceSnippet.contains("丙段"),
            "未标记的段落仍应进入删减审阅，且原文可见"
        )
        #expect(
            !item.sourceSnippet.contains("甲段"),
            "标记为必讲的段落不应出现在删减审阅里"
        )
    }

    @Test("editing the script invalidates the previous AI review state")
    func editingSourceInvalidatesReviewState() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.session.createDocument(title: "改稿", sourceText: "甲段。乙段。丙段。")
        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            try TestPreparationResponse.response(for: prompt)
        }
        await harness.session.analyzeDraft()
        #expect(harness.session.phase == .review)
        #expect(harness.session.pendingVersion != nil)
        #expect(!harness.session.readingBlocks.isEmpty)

        harness.session.updateSourceText("甲段被改写。乙段。丙段。")

        #expect(harness.session.phase == .draft)
        #expect(harness.session.pendingVersion == nil, "改稿后旧候选必须失效")
        #expect(harness.session.reviewItems.isEmpty)
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
        #expect(harness.session.pendingVersion == nil, "旧文本的分析结果不得回填")
        #expect(harness.session.reviewItems.isEmpty)
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
}

/// Condense runs through the map stage: one block per source unit, with the
/// last unit omitted so deletion review can be exercised end to end.
private enum TestCondenseResponse {
    enum Failure: Error {
        case unavailable
    }

    static func response(
        for prompt: TeleprompterPreparationPrompt,
        omittingLastUnit: Bool
    ) throws -> String {
        if prompt.schemaVersion == "teleprompter.reduction.v1" {
            return #"{"schema_version":"teleprompter.reduction.v1","patches":[],"review_block_ids":[]}"#
        }
        guard prompt.schemaVersion == "teleprompter.preparation.v2" else {
            throw Failure.unavailable
        }
        let input = try JSONDecoder().decode(
            TeleprompterPreparationMapInput.self,
            from: Data(prompt.input.utf8)
        )
        let blocks = input.targets.indices.map { index in
            if omittingLastUnit, index == input.targets.count - 1 {
                return TeleprompterMapBlock(
                    startUnit: index,
                    endUnit: index + 1,
                    mode: .omit,
                    text: "",
                    issues: [.nonspokenContent]
                )
            }
            return TeleprompterMapBlock(
                startUnit: index,
                endUnit: index + 1,
                mode: .speak,
                text: input.targets[index].rawText,
                issues: []
            )
        }
        return String(decoding: try JSONEncoder().encode(
            TeleprompterMapOutput(blocks: blocks)
        ), as: UTF8.self)
    }
}

private enum TestPreparationResponse {
    enum Failure: Error {
        case unavailable
    }

    static func response(for prompt: TeleprompterPreparationPrompt) throws -> String {
        if prompt.schemaVersion == "teleprompter.reduction.v1" {
            return #"{"schema_version":"teleprompter.reduction.v1","patches":[],"review_block_ids":[]}"#
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
                    mode: .speak,
                    text: group.sourceUnits.map(\.rawText).joined(),
                    issues: []
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
