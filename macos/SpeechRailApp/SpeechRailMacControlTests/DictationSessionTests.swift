import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 听写状态机回归：只用 fake 采集 / 识别 / 目标 / 交付 / 剪贴板，
/// 不打开麦克风、不联网、不写系统剪贴板。
@MainActor
final class DictationSessionTests: XCTestCase {
    private let target = DictationTarget(
        processIdentifier: 4_242,
        bundleIdentifier: "com.example.Editor",
        displayName: "编辑器"
    )

    // MARK: - 测试替身

    private final class FakeCapture: DictationAudioCapturing, @unchecked Sendable {
        var startError: Error?
        var result: DictationCaptureResult = .recorded(
            DictationRecording(pcm: Data(repeating: 1, count: 4_800))
        )
        private(set) var startCount = 0
        private(set) var finishCount = 0
        private(set) var cancelCount = 0

        func startRecording() async throws {
            startCount += 1
            if let startError { throw startError }
        }

        func finishRecording() async -> DictationCaptureResult {
            finishCount += 1
            return result
        }

        func cancelRecording() async {
            cancelCount += 1
        }
    }

    private actor FakeTranscriber: DictationTranscribing {
        private let text: String
        private let error: Error?
        private let gate: Gate?
        private(set) var callCount = 0

        init(text: String = "你好，世界。", error: Error? = nil, gate: Gate? = nil) {
            self.text = text
            self.error = error
            self.gate = gate
        }

        func transcribe(_ recording: DictationRecording) async throws -> String {
            callCount += 1
            await gate?.wait()
            if let error { throw error }
            return text
        }
    }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private final class FakeTargets: DictationTargetResolving, @unchecked Sendable {
        var target: DictationTarget?
        init(target: DictationTarget?) { self.target = target }
        func currentTarget() async -> DictationTarget? { target }
    }

    private final class FakeDeliverer: DictationTextDelivering, @unchecked Sendable {
        var attempt: DictationDeliveryAttempt = .inserted
        private(set) var delivered: [(text: String, target: DictationTarget)] = []

        func deliver(_ text: String, to target: DictationTarget) async -> DictationDeliveryAttempt {
            delivered.append((text, target))
            return attempt
        }
    }

    private final class FakeClipboard: DictationClipboardStaging, @unchecked Sendable {
        private(set) var staged: [String] = []
        func stage(_ text: String) async { staged.append(text) }
    }

    private struct TestError: LocalizedError {
        var errorDescription: String? { "识别服务不可用" }
    }

    private func makeSession(
        capture: FakeCapture = FakeCapture(),
        transcriber: FakeTranscriber = FakeTranscriber(),
        targets: FakeTargets? = nil,
        deliverer: FakeDeliverer = FakeDeliverer(),
        clipboard: FakeClipboard = FakeClipboard()
    ) -> (DictationSession, FakeCapture, FakeTranscriber, FakeDeliverer, FakeClipboard) {
        let session = DictationSession(
            audio: capture,
            transcriber: transcriber,
            targets: targets ?? FakeTargets(target: target),
            deliverer: deliverer,
            clipboard: clipboard
        )
        return (session, capture, transcriber, deliverer, clipboard)
    }

    // MARK: - 主路径

    func testToggleRecordsThenInsertsOnlyTheFinalText() async {
        let (session, capture, transcriber, deliverer, clipboard) = makeSession()

        await session.toggle()
        XCTAssertEqual(session.phase, .recording(target))
        XCTAssertEqual(capture.startCount, 1)

        await session.toggle()

        guard case let .finished(outcome) = session.phase else {
            return XCTFail("结束听写后应给出交付结果，实际为：\(session.phase)")
        }
        XCTAssertEqual(outcome.text, "你好，世界。")
        XCTAssertEqual(outcome.delivery, .inserted)
        XCTAssertEqual(outcome.target, target)
        XCTAssertEqual(deliverer.delivered.count, 1)
        XCTAssertEqual(deliverer.delivered.first?.text, "你好，世界。")
        XCTAssertEqual(deliverer.delivered.first?.target, target)
        XCTAssertTrue(clipboard.staged.isEmpty, "插入成功时不应动剪贴板")
        let transcriberCalls = await transcriber.callCount
        XCTAssertEqual(transcriberCalls, 1)
    }

    func testTextIsTrimmedBeforeDelivery() async {
        let transcriber = FakeTranscriber(text: "  前后留白  \n")
        let (session, _, _, deliverer, _) = makeSession(transcriber: transcriber)

        await session.toggle()
        await session.toggle()

        XCTAssertEqual(deliverer.delivered.first?.text, "前后留白")
    }

    // MARK: - 交付失败

    func testDeliveryFailureCopiesTextWithExplicitReason() async {
        for (attempt, reason) in [
            (DictationDeliveryAttempt.targetChanged, DictationCopyReason.targetChanged),
            (.unsupportedTarget, .unsupportedTarget),
            (.permissionDenied, .permissionDenied),
            (.failed("控件拒绝写入"), .insertionFailed)
        ] {
            let deliverer = FakeDeliverer()
            deliverer.attempt = attempt
            let (session, _, _, _, clipboard) = makeSession(deliverer: deliverer)

            await session.toggle()
            await session.toggle()

            guard case let .finished(outcome) = session.phase else {
                return XCTFail("交付失败也必须给出明确结果，实际为：\(session.phase)")
            }
            XCTAssertEqual(outcome.delivery, .copied(reason))
            XCTAssertEqual(clipboard.staged, ["你好，世界。"])
        }
    }

    func testEmptyTranscriptIsNotDelivered() async {
        let (session, _, _, deliverer, clipboard) = makeSession(
            transcriber: FakeTranscriber(text: " \n\t ")
        )

        await session.toggle()
        await session.toggle()

        XCTAssertEqual(session.phase, .failed(.emptyTranscript))
        XCTAssertTrue(deliverer.delivered.isEmpty, "没有文字就不能往目标里写东西")
        XCTAssertTrue(clipboard.staged.isEmpty)
    }

    func testTranscriptionErrorSurfacesAndDoesNotDeliver() async {
        let (session, _, _, deliverer, _) = makeSession(
            transcriber: FakeTranscriber(error: TestError())
        )

        await session.toggle()
        await session.toggle()

        guard case let .failed(failure) = session.phase else {
            return XCTFail("识别失败必须显式失败，实际为：\(session.phase)")
        }
        guard case .transcriptionFailed = failure else {
            return XCTFail("应报告识别失败，实际为：\(failure)")
        }
        XCTAssertTrue(deliverer.delivered.isEmpty)
    }

    func testBusyServiceIsReportedAsBusyNotGenericFailure() async {
        let busy = ServiceAPIClientError.http(
            statusCode: 409,
            code: "backend_busy",
            message: "另一个会话正在使用识别引擎",
            requestID: nil,
            retryable: true
        )
        let (session, _, _, _, _) = makeSession(transcriber: FakeTranscriber(error: busy))

        await session.toggle()
        await session.toggle()

        guard case let .failed(.serviceBusy(message)) = session.phase else {
            return XCTFail("忙线要单独说明，实际为：\(session.phase)")
        }
        XCTAssertTrue(message.contains("识别引擎"))
    }

    // MARK: - 并发与迟到结果

    func testHotkeyWhileTranscribingDoesNotStartASecondRecording() async {
        let gate = Gate()
        let transcriber = FakeTranscriber(gate: gate)
        let (session, capture, _, deliverer, _) = makeSession(transcriber: transcriber)

        await session.toggle()
        // 结束这一段会停在识别上（闸门未开），所以放到独立任务里跑；
        // 直接 `await session.toggle()` 会一路等到闸门打开，后面「识别中再按热键」就测不到。
        let stopping = Task { await session.toggle() }
        await waitUntil { session.phase.isBusy }
        XCTAssertTrue(session.phase.isBusy)

        // 识别还没回来：再按一次不排队、不开第二段录音。
        await session.toggle()
        XCTAssertNotNil(session.notice)
        XCTAssertEqual(capture.startCount, 1)

        await gate.open()
        await stopping.value
        await waitUntil { if case .finished = session.phase { true } else { false } }

        XCTAssertEqual(deliverer.delivered.count, 1, "同一段只能交付一次")
        XCTAssertEqual(capture.startCount, 1)
    }

    func testCancelDuringRecordingNeverUploads() async {
        let (session, capture, transcriber, deliverer, _) = makeSession()

        await session.toggle()
        await session.cancel()

        XCTAssertEqual(session.phase, .failed(.cancelled))
        XCTAssertEqual(capture.cancelCount, 1)
        XCTAssertEqual(capture.finishCount, 0)
        let transcriberCalls = await transcriber.callCount
        XCTAssertEqual(transcriberCalls, 0)
        XCTAssertTrue(deliverer.delivered.isEmpty)
    }

    func testFailureThenToggleStartsAFreshRecording() async {
        let (session, capture, _, deliverer, _) = makeSession()
        await session.toggle()
        await session.cancel()
        XCTAssertEqual(session.phase, .failed(.cancelled))

        await session.toggle()
        XCTAssertEqual(session.phase, .recording(target))
        XCTAssertEqual(capture.startCount, 2)

        await session.toggle()
        XCTAssertEqual(deliverer.delivered.count, 1)
    }

    // MARK: - 采集与准入

    func testNoFrontmostTargetFailsBeforeTouchingTheMicrophone() async {
        let capture = FakeCapture()
        let (session, _, _, _, _) = makeSession(
            capture: capture,
            targets: FakeTargets(target: nil)
        )

        await session.toggle()

        XCTAssertEqual(session.phase, .failed(.noTarget))
        XCTAssertEqual(capture.startCount, 0, "没有目标就不该占用麦克风")
    }

    func testMicrophonePermissionDeniedIsExplicit() async {
        let capture = FakeCapture()
        capture.startError = DictationCaptureError.permissionDenied
        let (session, _, _, _, _) = makeSession(capture: capture)

        await session.toggle()

        XCTAssertEqual(session.phase, .failed(.microphoneDenied))
    }

    func testCaptureFailureIsReportedWithDetail() async {
        let capture = FakeCapture()
        capture.startError = DictationCaptureError.failed("设备被占用")
        let (session, _, _, _, _) = makeSession(capture: capture)

        await session.toggle()

        guard case let .failed(.captureFailed(detail)) = session.phase else {
            return XCTFail("采集失败必须说明原因，实际为：\(session.phase)")
        }
        XCTAssertTrue(detail.contains("设备被占用"))
    }

    func testOverlongRecordingIsRejectedWithoutUpload() async {
        let capture = FakeCapture()
        capture.result = .tooLong
        let (session, _, transcriber, deliverer, _) = makeSession(capture: capture)

        await session.toggle()
        await session.toggle()

        XCTAssertEqual(session.phase, .failed(.tooLong))
        let calls = await transcriber.callCount
        XCTAssertEqual(calls, 0, "超长录音不进入识别")
        XCTAssertTrue(deliverer.delivered.isEmpty)
    }

    func testEmptyRecordingIsRejectedWithoutUpload() async {
        let capture = FakeCapture()
        capture.result = .empty
        let (session, _, transcriber, _, _) = makeSession(capture: capture)

        await session.toggle()
        await session.toggle()

        XCTAssertEqual(session.phase, .failed(.emptyTranscript))
        let calls = await transcriber.callCount
        XCTAssertEqual(calls, 0)
    }

    // MARK: - 纯值

    func testRecordingWAVHeaderDescribesPCM16Mono() {
        let recording = DictationRecording(pcm: Data(repeating: 0, count: 960))
        let wav = recording.wavData()

        XCTAssertEqual(wav.count, 44 + 960)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(recording.durationSeconds, 0.02, accuracy: 0.0001)
    }

    func testClipboardTextIsBounded() {
        let long = String(repeating: "字", count: DictationLimits.maximumClipboardCharacters + 50)
        let bounded = DictationSession.clipboardText(long)
        XCTAssertEqual(bounded.count, DictationLimits.maximumClipboardCharacters)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
