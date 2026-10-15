import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 分析进度观测回归：事件序列、快照收敛单调性、重试显形、错误码封闭性与
/// 进度回调不改变管线结果。全部用 fake 后端，不触真实 LLM。
final class AudiobookAnalysisProgressTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookAnalysisProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private final class RecordingProgressClient: AudiobookAnalysisClient, @unchecked Sendable {
        let configurationDigest: String
        private let lock = NSLock()
        private(set) var prompts: [AudiobookAnalysisPrompt] = []
        var failExtractionAttempts = 0
        var failAnnotationAttempts = 0
        /// 置 true 后每次 complete 都落一条诊断回执（成功带 token，失败带错误码），
        /// 供"失败调用不丢诊断"回归；默认关闭，不影响已有测试的事件序列。
        var enableDiagnostics = false
        private let collector = AudiobookAnalysisCallDiagnosticsCollector()

        var callDiagnostics: AudiobookAnalysisCallDiagnosticsCollector? {
            enableDiagnostics ? collector : nil
        }

        init(configurationDigest: String) {
            self.configurationDigest = configurationDigest
        }

        func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
            lock.withLock { prompts.append(prompt) }
            do {
                let result: String
                switch prompt.stage {
                case .extraction:
                    let remaining = lock.withLock { () -> Int in
                        failExtractionAttempts -= 1
                        return failExtractionAttempts
                    }
                    if remaining >= 0 {
                        throw AudiobookAnalysisError.invalidStructuredOutput("脚本化提取失败触发拆窗重试")
                    }
                    let atomIDs = Self.extractPrimaryAtomIDs(from: prompt.input)
                    let firstAtom = atomIDs.first.map { [$0] } ?? []
                    let resp = AudiobookExtractionResponse(mentions: [
                        .init(surfaceName: "林远", aliases: ["阿远"], evidenceAtomIDs: firstAtom, voiceTraitEvidence: "青年低沉嗓音"),
                    ])
                    result = String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)
                case .castMerge:
                    let resp = AudiobookMergeResponse(groups: [
                        .init(canonicalName: "林远", memberSurfaceNames: ["林远", "阿远"], aliases: ["阿远"], isCollisionUnresolved: false, evidenceSummary: "青年低沉嗓音"),
                    ])
                    result = String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)
                case .annotation:
                    let remaining = lock.withLock { () -> Int in
                        failAnnotationAttempts -= 1
                        return failAnnotationAttempts
                    }
                    if remaining >= 0 {
                        throw AudiobookAnalysisError.invalidStructuredOutput("脚本化标注失败触发拆窗重试")
                    }
                    let atomIDs = Self.extractPrimaryAtomIDs(from: prompt.input)
                    let roleIDs = Self.extractCandidateRoleIDs(from: prompt.input)
                    var items: [AudiobookAnnotationResponse.Item] = []
                    for (idx, atomID) in atomIDs.enumerated() {
                        if let roleID = roleIDs.first, idx % 2 == 1 {
                            items.append(.init(atomID: atomID, speakerKind: .character, roleID: roleID, candidateRoleIDs: [roleID], confidence: 0.95, evidence: "林远开口说道"))
                        } else {
                            items.append(.init(atomID: atomID, speakerKind: .narrator, roleID: nil, candidateRoleIDs: [], confidence: 0.99, evidence: "旁白叙述"))
                        }
                    }
                    let resp = AudiobookAnnotationResponse(items: items)
                    result = String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)
                }
                if enableDiagnostics {
                    collector.record(AudiobookAnalysisCallDiagnosticsCollector.Call(
                        elapsedMilliseconds: 5,
                        promptTokens: 100,
                        completionTokens: 10
                    ))
                }
                return result
            } catch {
                if enableDiagnostics {
                    collector.record(AudiobookAnalysisCallDiagnosticsCollector.Call(
                        elapsedMilliseconds: 5,
                        errorCode: AudiobookAnalysisErrorCode.code(for: error)
                    ))
                }
                throw error
            }
        }

        private static func extractPrimaryAtomIDs(from inputJSON: String) -> [UUID] {
            guard let data = inputJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            let list = (obj["primary_atoms_required"] as? [[String: Any]])
                ?? (obj["primary_atoms"] as? [[String: Any]])
                ?? []
            return list.compactMap { ($0["atomID"] as? String).flatMap(UUID.init(uuidString:)) }
        }

        private static func extractCandidateRoleIDs(from inputJSON: String) -> [UUID] {
            guard let data = inputJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["candidate_characters"] as? [[String: Any]]
            else { return [] }
            return list.compactMap { ($0["roleID"] as? String).flatMap(UUID.init(uuidString:)) }
        }
    }

    private final class CancellingProgressClient: AudiobookAnalysisClient, @unchecked Sendable {
        let configurationDigest: String
        private let lock = NSLock()
        private var callCount = 0
        private let cancelAfterCalls: Int
        private let onCancel: @Sendable () async -> Void

        init(configurationDigest: String, cancelAfterCalls: Int, onCancel: @escaping @Sendable () async -> Void) {
            self.configurationDigest = configurationDigest
            self.cancelAfterCalls = cancelAfterCalls
            self.onCancel = onCancel
        }

        func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
            let count = lock.withLock { () -> Int in
                callCount += 1
                return callCount
            }
            // 在中途确定性触发取消：让管线先发射一批进度事件，随后走取消路径
            if count == cancelAfterCalls {
                await onCancel()
            }
            switch prompt.stage {
            case .extraction:
                let resp = AudiobookExtractionResponse(mentions: [
                    .init(surfaceName: "林远", aliases: ["阿远"], evidenceAtomIDs: [], voiceTraitEvidence: "青年低沉嗓音"),
                ])
                return String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)
            case .castMerge:
                let resp = AudiobookMergeResponse(groups: [
                    .init(canonicalName: "林远", memberSurfaceNames: ["林远", "阿远"], aliases: ["阿远"], isCollisionUnresolved: false, evidenceSummary: "青年低沉嗓音"),
                ])
                return String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)
            case .annotation:
                let resp = AudiobookAnnotationResponse(items: [])
                return String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)
            }
        }
    }

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AudiobookAnalysisEvent] = []

        var events: [AudiobookAnalysisEvent] {
            lock.withLock { stored }
        }

        func sink() -> AudiobookAnalysisProgressSink {
            AudiobookAnalysisProgressSink { [weak self] event in
                guard let self else { return }
                self.lock.withLock {
                    self.stored.append(event)
                }
            }
        }
    }

    private func importSmallBook(named name: String, paragraphs: Int = 6) async throws -> (AudiobookProjectStore, UUID) {
        let store = try AudiobookProjectStore(root: tempRoot)
        var lines = ["第一章 进度观测"]
        for index in 0..<paragraphs {
            lines.append("林远沿着石阶第\(index)次登高远望。")
            lines.append("“跟紧我。”他回头说道。")
        }
        let txtURL = tempRoot.appendingPathComponent(name)
        try Data(lines.joined(separator: "\n").utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        return (store, bookID)
    }

    private func multiWindowPolicy() -> AudiobookAnalysisPolicy {
        var policy = AudiobookAnalysisPolicy.standard
        policy.maxPrimaryAtoms = 3
        policy.minWindowScalars = 10
        return policy
    }

    private func fold(_ events: [AudiobookAnalysisEvent]) -> AudiobookAnalysisProgress? {
        guard let first = events.first else { return nil }
        var progress = AudiobookAnalysisProgress(firstEvent: first)
        for event in events.dropFirst() {
            progress.apply(event)
        }
        return progress
    }

    func testProgressEventsCoverAllPhasesAndConvergeToCompletion() async throws {
        let (store, bookID) = try await importSmallBook(named: "phases.txt")
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "progress-model")
        )
        let client = RecordingProgressClient(configurationDigest: config.configurationDigest)
        let recorder = EventRecorder()
        let pipeline = AudiobookAnalysisPipeline(
            store: store,
            policy: multiWindowPolicy(),
            progressSink: recorder.sink()
        ) { _ in client }

        let summary = try await pipeline.run(bookID: bookID, config: config)
        XCTAssertTrue(summary.isAllWindowsValidated)

        let events = recorder.events
        XCTAssertFalse(events.isEmpty)
        // 首事件必须是规划事件且总窗数已知
        XCTAssertEqual(events.first?.kind, .planned)
        XCTAssertGreaterThan(events.first?.totalWindows ?? 0, 1)
        // 末事件必须是完成终态
        XCTAssertEqual(events.last?.kind, .runEnded)
        XCTAssertEqual(events.last?.outcome, .completed)
        // 三阶段事件齐备
        XCTAssertTrue(events.contains(where: { $0.kind == .windowExtracted }))
        XCTAssertTrue(events.contains(where: { $0.kind == .castBatchMerged }))
        XCTAssertTrue(events.contains(where: { $0.kind == .windowAnnotated }))
        // 序号严格递增
        let sequences = events.map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count)

        guard let progress = fold(events) else {
            return XCTFail("事件流应可收敛为快照")
        }
        XCTAssertEqual(progress.phase, .finished)
        XCTAssertEqual(progress.outcome, .completed)
        XCTAssertEqual(progress.totalWindows, summary.totalWindows)
        XCTAssertEqual(progress.annotatedWindows, summary.totalWindows)
        XCTAssertEqual(progress.extractedWindows, summary.totalWindows)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 0.0001)
    }

    func testFractionIsMonotonicAndWindowCounterFollowsPhase() async throws {
        let (store, bookID) = try await importSmallBook(named: "monotonic.txt")
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "progress-model")
        )
        let client = RecordingProgressClient(configurationDigest: config.configurationDigest)
        let recorder = EventRecorder()
        let pipeline = AudiobookAnalysisPipeline(
            store: store,
            policy: multiWindowPolicy(),
            progressSink: recorder.sink()
        ) { _ in client }

        _ = try await pipeline.run(bookID: bookID, config: config)
        let events = recorder.events
        guard let first = events.first else {
            return XCTFail("应至少有一个规划事件")
        }
        var progress = AudiobookAnalysisProgress(firstEvent: first)
        var lastFraction = progress.fraction
        var sawExtractingCounter = false
        var sawAnnotatingCounter = false
        for event in events.dropFirst() {
            progress.apply(event)
            XCTAssertGreaterThanOrEqual(
                progress.fraction, lastFraction - 0.0001,
                "百分比不得回退（事件 \(event.kind)）"
            )
            lastFraction = progress.fraction
            switch progress.phase {
            case .extracting, .annotating:
                if let text = progress.windowCounterText {
                    XCTAssertTrue(text.contains("窗"), "提取/标注阶段计数应为窗口口径：\(text)")
                    if progress.phase == .extracting { sawExtractingCounter = true }
                    else { sawAnnotatingCounter = true }
                }
            case .merging:
                if let text = progress.windowCounterText {
                    XCTAssertTrue(text.contains("组") || text.contains("归并"), "归并阶段计数应为组口径：\(text)")
                }
            case .preparing, .finished:
                break
            }
        }
        XCTAssertTrue(sawExtractingCounter)
        XCTAssertTrue(sawAnnotatingCounter)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 0.0001)
    }

    func testSplitRetryIsVisibleAndResetsOnWindowCompletion() async throws {
        let (store, bookID) = try await importSmallBook(named: "retry.txt")
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "progress-model")
        )
        let client = RecordingProgressClient(configurationDigest: config.configurationDigest)
        client.failExtractionAttempts = 1
        client.failAnnotationAttempts = 1
        let recorder = EventRecorder()
        let pipeline = AudiobookAnalysisPipeline(
            store: store,
            policy: multiWindowPolicy(),
            progressSink: recorder.sink()
        ) { _ in client }

        let summary = try await pipeline.run(bookID: bookID, config: config)
        XCTAssertTrue(summary.isAllWindowsValidated)

        let events = recorder.events
        let retryEvents = events.filter { $0.kind == .retryingSplit }
        // 提取与标注各触发一次拆窗重试
        XCTAssertGreaterThanOrEqual(retryEvents.count, 2)
        XCTAssertTrue(retryEvents.allSatisfy { $0.attempt > 1 })

        // 折叠验证：重试标记在重试事件处显形，在窗口完成处复位
        guard let first = events.first else {
            return XCTFail("应至少有一个规划事件")
        }
        var progress = AudiobookAnalysisProgress(firstEvent: first)
        var sawRetryVisible = false
        for event in events.dropFirst() {
            progress.apply(event)
            if event.kind == .retryingSplit {
                XCTAssertTrue(progress.isRetryNoticeVisible, "重试事件到达时提示必须可见")
                sawRetryVisible = true
            }
            if event.kind == .windowExtracted || event.kind == .windowAnnotated {
                XCTAssertFalse(progress.isRetrying, "窗口完成时重试标记必须复位")
            }
        }
        XCTAssertTrue(sawRetryVisible)
        XCTAssertFalse(progress.isRetryNoticeVisible)
    }

    func testFailedCallsStillEmitDiagnosticsBeforeSplitRetry() async throws {
        let (store, bookID) = try await importSmallBook(named: "failed_diag.txt")
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "progress-model")
        )
        let client = RecordingProgressClient(configurationDigest: config.configurationDigest)
        client.enableDiagnostics = true
        client.failExtractionAttempts = 1
        let recorder = EventRecorder()
        let pipeline = AudiobookAnalysisPipeline(
            store: store,
            policy: multiWindowPolicy(),
            progressSink: recorder.sink()
        ) { _ in client }

        let summary = try await pipeline.run(bookID: bookID, config: config)
        XCTAssertTrue(summary.isAllWindowsValidated)

        let events = recorder.events
        // 失败调用的诊断回执必须在重试事件之前发射（带错误码，而非被吞掉）
        let diagEvents = events.filter { $0.kind == .llmCallFinished }
        XCTAssertFalse(diagEvents.isEmpty, "应有 LLM 诊断回执事件")
        let failedDiags = diagEvents.filter { $0.errorCode != nil }
        XCTAssertFalse(failedDiags.isEmpty, "失败调用的错误码回执不得丢失")
        XCTAssertTrue(failedDiags.allSatisfy { $0.errorCode == "invalid_structured_output" })

        guard let progress = fold(events) else {
            return XCTFail("事件流应可收敛为快照")
        }
        XCTAssertEqual(progress.lastErrorCode, "invalid_structured_output")
        XCTAssertEqual(progress.llmCallCount, diagEvents.count)
    }

    func testPromptsCarryRunIDForLLMObservationCorrelation() async throws {
        let (store, bookID) = try await importSmallBook(named: "runid_corr.txt")
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "progress-model")
        )
        let client = RecordingProgressClient(configurationDigest: config.configurationDigest)
        let recorder = EventRecorder()
        let pipeline = AudiobookAnalysisPipeline(
            store: store,
            policy: multiWindowPolicy(),
            progressSink: recorder.sink()
        ) { _ in client }

        _ = try await pipeline.run(bookID: bookID, config: config)

        let events = recorder.events
        let runID = try XCTUnwrap(events.first?.runID)
        // 管线写入 prompt 的 observationSessionID 必须与事件流 runID 一致，
        // live 链路用它做 LLM 观测的 sessionID，一串到底。
        XCTAssertFalse(client.prompts.isEmpty)
        XCTAssertTrue(client.prompts.allSatisfy { $0.observationSessionID == runID })
    }

    func testRunLevelSinkTakesPrecedenceOverInstalledSink() async throws {
        let (store, bookID) = try await importSmallBook(named: "sink_param.txt")
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "progress-model")
        )
        let client = RecordingProgressClient(configurationDigest: config.configurationDigest)
        let installedRecorder = EventRecorder()
        let runRecorder = EventRecorder()
        let pipeline = AudiobookAnalysisPipeline(
            store: store,
            policy: multiWindowPolicy(),
            progressSink: installedRecorder.sink()
        ) { _ in client }

        _ = try await pipeline.run(bookID: bookID, config: config, progressSink: runRecorder.sink())

        // run 级 sink 优先：本次事件全部落在 runRecorder，安装值收不到。
        XCTAssertFalse(runRecorder.events.isEmpty)
        XCTAssertTrue(installedRecorder.events.isEmpty)
        XCTAssertEqual(runRecorder.events.first?.kind, .planned)
        XCTAssertEqual(runRecorder.events.last?.kind, .runEnded)
    }

    func testCancelEmitsCancelledOutcomeAndOutcomeCountersStaySealed() async throws {
        let (store, bookID) = try await importSmallBook(named: "cancel_progress.txt")
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "progress-model")
        )
        let recorder = EventRecorder()
        // 取消在第 2 次 LLM 调用时确定性触发：既有进度事件已发射，随后走取消路径。
        // pipeline 需先声明再赋值，闭包捕获盒子而非管线本身。
        final class PipelineBox: @unchecked Sendable {
            var pipeline: AudiobookAnalysisPipeline?
        }
        let box = PipelineBox()
        let client = CancellingProgressClient(configurationDigest: config.configurationDigest, cancelAfterCalls: 2) {
            if let pipeline = box.pipeline {
                await pipeline.cancel(bookID: bookID)
            }
        }
        let pipeline = AudiobookAnalysisPipeline(
            store: store,
            policy: multiWindowPolicy(),
            progressSink: recorder.sink()
        ) { _ in client }
        box.pipeline = pipeline

        do {
            _ = try await pipeline.run(bookID: bookID, config: config)
            XCTFail("取消后应抛出 cancelled")
        } catch let error as AudiobookAnalysisError {
            XCTAssertEqual(error, .cancelled)
        }

        let events = recorder.events
        XCTAssertGreaterThan(events.count, 1, "取消前应已发射进度事件")
        XCTAssertEqual(events.first?.kind, .planned)
        XCTAssertEqual(events.last?.kind, .runEnded)
        XCTAssertEqual(events.last?.outcome, .cancelled)
        XCTAssertEqual(events.last?.errorCode, "cancelled")
        guard let progress = fold(events) else {
            return XCTFail("事件流应可收敛为快照")
        }
        XCTAssertEqual(progress.outcome, .cancelled)
        XCTAssertEqual(progress.phase, .finished)
        // 取消后百分比停留在 0~1 之间且为确定值
        XCTAssertGreaterThanOrEqual(progress.fraction, 0.0)
        XCTAssertLessThanOrEqual(progress.fraction, 1.0)
    }

    func testStaleSequenceAndForeignRunEventsAreDiscarded() throws {
        let bookID = UUID()
        let base = AudiobookAnalysisEvent(
            runID: "run-a",
            bookID: bookID,
            sequence: 0,
            kind: .planned,
            totalWindows: 4,
            reusedCheckpointWindows: 1
        )
        var progress = AudiobookAnalysisProgress(firstEvent: base)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.0001)

        // 乱序到达的过期事件必须丢弃：计数器与阶段都不回退
        var stale = base
        stale.sequence = 0
        stale.totalWindows = 1
        stale.reusedCheckpointWindows = 0
        progress.apply(stale)
        XCTAssertEqual(progress.totalWindows, 4)
        XCTAssertEqual(progress.reusedCheckpointWindows, 1)

        // 他 run 的事件必须丢弃
        var foreign = AudiobookAnalysisEvent(
            runID: "run-b",
            bookID: bookID,
            sequence: 5,
            kind: .windowAnnotated,
            totalWindows: 99,
            annotatedWindows: 99
        )
        foreign.bookID = bookID
        progress.apply(foreign)
        XCTAssertEqual(progress.totalWindows, 4)
        XCTAssertEqual(progress.annotatedWindows, 0)
    }

    func testErrorCodesAreClosedVocabulary() throws {
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: CancellationError()), "cancelled")
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: AudiobookAnalysisError.cancelled), "cancelled")
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: AudiobookAnalysisError.invalidStructuredOutput("含原文的正文")), "invalid_structured_output")
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: AudiobookAnalysisError.atomCoverageViolation("含原文")), "atom_coverage_violation")
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: AudiobookAnalysisError.rootCallBudgetExhausted(rootWindowID: UUID())), "call_budget_exhausted")
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: AudiobookAnalysisError.configurationChangedDuringRun), "configuration_changed")
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: AudiobookAnalysisError.windowFailed(windowID: UUID(), reason: "含原文")), "window_failed")
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: LLMError.transport("127.0.0.1 secret")), "transport")
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: LLMError.http(status: 500, body: "原文")), "http_500")
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: URLError(.cancelled)), "cancelled")
        XCTAssertEqual(AudiobookAnalysisErrorCode.code(for: NSError(domain: "x", code: 1)), "unknown")
    }

    func testEventBufferIsBoundedAndRedactionSafe() throws {
        var buffer = AudiobookAnalysisEventBuffer(capacity: 3)
        let bookID = UUID()
        for seq in 0..<5 {
            buffer.append(AudiobookAnalysisEvent(
                runID: "run-buffer",
                bookID: bookID,
                sequence: seq,
                kind: .windowExtracted,
                totalWindows: 5,
                extractedWindows: seq + 1
            ))
        }
        XCTAssertEqual(buffer.events.count, 3)
        XCTAssertEqual(buffer.events.map(\.sequence), [2, 3, 4])

        // 闭式 schema 断言：序列化后不得出现任何正文/密钥/路径类字段
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = String(decoding: try encoder.encode(buffer.events), as: UTF8.self)
        let forbidden = ["prompt", "input", "instruction", "text", "transcript", "apiKey", "api_key",
                         "authorization", "path", "/Users", "file://", "quote", "excerpt", "surfaceName"]
        for token in forbidden {
            XCTAssertFalse(payload.localizedCaseInsensitiveContains(token), "事件负载不得携带 \(token)")
        }
    }
}
