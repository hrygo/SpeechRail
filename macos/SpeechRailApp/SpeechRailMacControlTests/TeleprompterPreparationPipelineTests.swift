import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterPreparationPipelineTests {
    @Test func observationRecorderPersistsEventsAndAggregatesLowCardinalityMetrics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-ai-observability-(UUID().uuidString)", isDirectory: true)
        let location = ObservabilityLocation(
            appHome: root,
            historyDirectory: root.appendingPathComponent("history", isDirectory: true),
            logDirectory: root.appendingPathComponent("logs", isDirectory: true)
        )
        let capturedAt = Date(timeIntervalSince1970: 1_758_000_000)
        let recorder = TeleprompterAIObservationRecorder(
            location: location,
            now: { capturedAt }
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let context = TeleprompterAICallContext(
            runID: "run-test",
            requestID: "request-test",
            stage: .map,
            itemIndex: 1,
            itemCount: 3
        )
        recorder.record(
            .init(
                kind: .providerRequestStarted,
                context: context,
                model: "vendor/private-model",
                endpointHost: "provider.example",
                transportAttempt: 0,
                operation: .chat,
                compatibilityMode: .openAICompatible,
                thinkingControl: "standard_disabled",
                outcome: "started"
            )
        )
        recorder.record(
            .init(
                kind: .providerResponse,
                context: context,
                elapsedMilliseconds: 321,
                httpStatus: 200,
                responseBytes: 512,
                choiceCount: 1,
                finishReason: "stop",
                promptTokens: 8,
                completionTokens: 3,
                reasoningTokens: 2,
                model: "vendor/private-model",
                endpointHost: "provider.example",
                transportAttempt: 0,
                operation: .chat,
                compatibilityMode: .openAICompatible,
                thinkingControl: "standard_disabled",
                outcome: "received"
            )
        )
        recorder.record(
            .init(
                kind: .providerRequestStarted,
                context: context,
                transportAttempt: 1,
                operation: .chat,
                compatibilityMode: .openAICompatible,
                thinkingControl: "omitted_after_rejection",
                outcome: "started"
            )
        )
        recorder.record(
            .init(
                kind: .runFinished,
                context: .init(runID: "run-test", requestID: "run-test", stage: .preparation),
                elapsedMilliseconds: 400,
                outcome: "completed"
            )
        )
        recorder.flush()

        let snapshot = recorder.snapshot()
        #expect(
            snapshot.counters[
                "speechrail_llm_provider_requests_total|stage=map|operation=chat|mode=openai_compatible"
            ] == 2
        )
        #expect(
            snapshot.counters[
                "speechrail_llm_thinking_control_retries_total|operation=chat|mode=openai_compatible"
            ] == 1
        )
        #expect(
            snapshot.counters[
                "speechrail_llm_reasoning_tokens_total|operation=chat|mode=openai_compatible"
            ] == 2
        )
        #expect(snapshot.counters["speechrail_llm_runs_total|outcome=completed"] == 1)

        let providerHistogram = snapshot.histograms[
            "speechrail_llm_provider_duration_ms|stage=map|operation=chat|mode=openai_compatible|outcome=received"
        ]
        #expect(providerHistogram?.count == 1)
        #expect(providerHistogram?.sumMilliseconds == 321)
        #expect(providerHistogram?.buckets["le_500"] == 1)

        let eventText = try String(contentsOf: recorder.eventFileURL(for: capturedAt), encoding: .utf8)
        #expect(eventText.split(separator: "\n").count == 4)
        #expect(eventText.contains("private-model"))
        #expect(!eventText.contains("\"prompt\""))

        let metricLines = try String(
            contentsOf: recorder.metricsFileURL(for: capturedAt),
            encoding: .utf8
        ).split(separator: "\n")
        #expect(metricLines.count == 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(
            TeleprompterAIMetricsSnapshot.self,
            from: Data(metricLines[0].utf8)
        )
        #expect(persisted == snapshot)
    }

    @Test func observationRecorderPersistsStandaloneProviderTerminalSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-ai-observability-standalone-\(UUID().uuidString)", isDirectory: true)
        let location = ObservabilityLocation(
            appHome: root,
            historyDirectory: root.appendingPathComponent("history", isDirectory: true),
            logDirectory: root.appendingPathComponent("logs", isDirectory: true)
        )
        let capturedAt = Date(timeIntervalSince1970: 1_758_000_001)
        let recorder = TeleprompterAIObservationRecorder(location: location, now: { capturedAt })
        defer { try? FileManager.default.removeItem(at: root) }

        recorder.record(
            .init(
                kind: .providerResponse,
                elapsedMilliseconds: 42,
                httpStatus: 200,
                operation: .responses,
                compatibilityMode: .openAICompatible,
                thinkingControl: "standard_disabled",
                outcome: "received"
            )
        )
        recorder.flush()

        let metricLines = try String(
            contentsOf: recorder.metricsFileURL(for: capturedAt),
            encoding: .utf8
        ).split(separator: "\n")
        #expect(metricLines.count == 1)
        #expect(
            recorder.snapshot().counters[
                "speechrail_llm_provider_responses_total|stage=unknown|operation=responses|mode=openai_compatible|outcome=received"
            ] == 1
        )
    }

    @Test func runFinishedObservationIncludesTotalPreparationElapsedTime() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let observations = ObservationLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try Self.mapResponse(for: prompt)
        })

        _ = try await pipeline.prepare(fixture.input, onObservation: observations.append)

        let finished = try #require(observations.values.first { $0.kind == .runFinished })
        #expect(finished.outcome == "completed")
        #expect(finished.elapsedMilliseconds != nil)
        #expect(finished.elapsedMilliseconds ?? -1 >= 0)
    }

    @Test func observationsCorrelateCallAndRedactedFailure() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let observations = ObservationLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { _ in
            throw LLMError.http(status: 503, body: "稿件不应进入日志")
        })

        await #expect(throws: LLMError.self) {
            try await pipeline.prepare(fixture.input, onObservation: observations.append)
        }

        let values = observations.values
        let started = try #require(values.first { $0.kind == .callStarted })
        let failed = try #require(values.first { $0.kind == .callFailed })
        let startedContext = try #require(started.context)
        let failedContext = try #require(failed.context)
        #expect(startedContext.runID == failedContext.runID)
        #expect(startedContext.requestID == failedContext.requestID)
        #expect(startedContext.stage == .map)
        #expect(failed.errorCode == "http_503")
        #expect(values.allSatisfy { $0.errorCode != "稿件不应进入日志" })
    }

    @Test func truncatedMapSplitsWithoutRepeatingOversizedWindow() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let calls = CallLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try await calls.append(prompt)
            if prompt.schemaVersion == "teleprompter.preparation.v2" {
                let input = try JSONDecoder().decode(TeleprompterPreparationMapInput.self, from: Data(prompt.input.utf8))
                if input.targets.count > 2 { throw LLMError.outputTruncated }
            }
            return try Self.response(for: prompt)
        })
        let result = try await pipeline.prepare(fixture.input)
        #expect(result.mapWindows.count == 2)
        #expect(await calls.mapInputs.map { $0.targets.count } == [4, 2, 2])
        #expect(result.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
    }

    @Test func shortSourceUsesOneMapAndDoesNotReduce() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let calls = CallLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try await calls.append(prompt)
            return try Self.mapResponse(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.mapRequestCount == 1)
        #expect(result.reduceRequestCount == 0)
        #expect(result.status == .complete)
        #expect(result.draft.blocks.count == 1)
        #expect(result.draft.blocks[0].disposition == .speak)
        #expect((await calls.schemaVersions) == ["teleprompter.preparation.v2"])
    }

    @Test func malformedMapResponseUsesOneBoundedRecoveryRequest() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.preparation.v2",
               await attempts.next() == 1 {
                return "{}"
            }
            return try Self.mapResponse(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.mapRequestCount == 1)
        #expect(await attempts.value == 2)
    }

    @Test func repeatedStructuralFailureStopsAfterOneRegeneration() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.preparation.v2",
               await attempts.next() <= 2 {
                return "{}"
            }
            return try Self.mapResponse(for: prompt)
        })

        await #expect(throws: TeleprompterPreparationError.self) {
            try await pipeline.prepare(fixture.input)
        }
        #expect(await attempts.value == 2)
    }

    @Test func transientRateLimitGetsOneBoundedRetry() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.preparation.v2",
               await attempts.next() == 1 {
                throw LLMError.http(status: 429, body: "retry later")
            }
            return try Self.mapResponse(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.mapRequestCount == 1)
        #expect(await attempts.value == 2)
    }

    @Test func longSourceMapsInBoundedWindowsThenReducesEachAdjacentSeam() async throws {
        let fixture = try makeFixture(lineCount: 96)
        let calls = CallLog()
        let progress = ProgressLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try await calls.append(prompt)
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input) { update in
            progress.append(update)
        }

        #expect(result.mapRequestCount == 4)
        #expect(result.reduceRequestCount == 3)
        #expect(result.mapWindows.count == 4)
        #expect(result.mapWindows.allSatisfy { $0.sourceUnitIDs.count <= 24 })
        #expect(result.boundaries.count == 3)
        #expect(result.boundaries.allSatisfy { $0.isChecked })
        #expect(result.status == .complete)
        #expect(result.draft.blocks.count == 12)

        let mapInputs = await calls.mapInputs
        let reduceCount = await calls.reduceCount
        let reduceStartedOnlyAfterAllMaps = await calls.reduceStartedOnlyAfterAllMaps
        #expect(mapInputs.allSatisfy { $0.targets.map(\.id) == Array($0.targets.indices) })
        #expect(mapInputs.flatMap { $0.targets.map(\.rawText) }.joined() == fixture.source.sourceText)
        #expect(reduceCount == 3)
        #expect(reduceStartedOnlyAfterAllMaps)
        #expect(progress.updates.first?.phase == .mapping)
        #expect(progress.updates.last?.phase == .finalizing)
        #expect(progress.updates.contains { $0.phase == .reducing && $0.completed == 3 && $0.total == 3 })
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
    }

    @Test func reduceFailureKeepsCompleteLeafDraftAndMarksUncheckedSeams() async throws {
        let fixture = try makeFixture(lineCount: 96)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.reduction.v1" {
                throw TestFailure.reduceUnavailable
            }
            return try Self.mapResponse(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.mapRequestCount == 4)
        #expect(result.reduceRequestCount == 3)
        #expect(result.draft.blocks.count == 12)
        #expect(result.boundaries.allSatisfy { !$0.isChecked })
        #expect(result.status == .boundaryUnchecked)
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
    }

    @Test func mapFailureDoesNotProduceAnActivatablePartialDraft() async throws {
        let fixture = try makeFixture(lineCount: 96)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.preparation.v2" {
                throw TestFailure.mapUnavailable
            }
            return ""
        })

        await #expect(throws: TeleprompterPreparationError.self) {
            try await pipeline.prepare(fixture.input)
        }
    }

    @Test func cancellationInvalidatesLateMapResponse() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try? await Task.sleep(for: .milliseconds(80))
            return try Self.mapResponse(for: prompt)
        })

        let task = Task {
            try await pipeline.prepare(fixture.input)
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private struct Fixture {
        let source: TeleprompterImportedSource
        let units: [TeleprompterSourceUnit]
        let input: TeleprompterPreparationInput
    }

    private enum TestFailure: Error, Sendable {
        case mapUnavailable
        case reduceUnavailable
    }

    private actor CallLog {
        var schemaVersions: [String] = []
        var mapInputs: [TeleprompterPreparationMapInput] = []
        var reduceCount = 0
        private var mapsCompleted = 0
        private(set) var reduceStartedOnlyAfterAllMaps = true

        func append(_ prompt: TeleprompterPreparationPrompt) throws {
            schemaVersions.append(prompt.schemaVersion)
            if prompt.schemaVersion == "teleprompter.preparation.v2" {
                let input = try JSONDecoder().decode(
                    TeleprompterPreparationMapInput.self,
                    from: Data(prompt.input.utf8)
                )
                mapInputs.append(input)
                mapsCompleted += 1
            } else if prompt.schemaVersion == "teleprompter.reduction.v1" {
                reduceCount += 1
                reduceStartedOnlyAfterAllMaps = reduceStartedOnlyAfterAllMaps && mapsCompleted == 4
            }
        }
    }

    private actor AttemptCounter {
        private(set) var value = 0

        func next() -> Int {
            value += 1
            return value
        }
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TeleprompterPreparationProgress] = []

        func append(_ value: TeleprompterPreparationProgress) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var updates: [TeleprompterPreparationProgress] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private final class ObservationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TeleprompterAIObservation] = []

        func append(_ value: TeleprompterAIObservation) {
            lock.lock()
            stored.append(value)
            lock.unlock()
        }

        var values: [TeleprompterAIObservation] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func makeFixture(lineCount: Int) throws -> Fixture {
        let text = (0..<lineCount).map { "第\($0)段。\n" }.joined()
        let source = try TeleprompterSourceImporter.importData(Data(text.utf8), fileExtension: "txt")
        let units = try TeleprompterSourceUnitBuilder(maxBudgetUnits: 12).build(source)
        let plan = try TeleprompterTimingPlanner.plan(
            sourceUnits: units,
            estimates: Array(repeating: nil, count: units.count),
            targetMinutes: 20
        )
        return Fixture(
            source: source,
            units: units,
            input: TeleprompterPreparationInput(
                source: source,
                sourceUnits: units,
                timingPlan: plan,
                pace: .natural
            )
        )
    }

    private static func response(for prompt: TeleprompterPreparationPrompt) throws -> String {
        if prompt.schemaVersion == "teleprompter.reduction.v1" {
            return #"{"schema_version":"teleprompter.reduction.v1","patches":[],"review_block_ids":[]}"#
        }
        return try mapResponse(for: prompt)
    }

    private static func mapResponse(for prompt: TeleprompterPreparationPrompt) throws -> String {
        let input = try JSONDecoder().decode(
            TeleprompterPreparationMapInput.self,
            from: Data(prompt.input.utf8)
        )
        guard !input.targets.isEmpty else {
            throw TestFailure.mapUnavailable
        }
        let blocks = stride(from: 0, to: input.targets.count, by: 8).map { start in
            let end = min(start + 8, input.targets.count)
            let group = Array(input.targets[start..<end])
            return TeleprompterMapBlock(
                startUnit: group[0].id,
                endUnit: group[group.count - 1].id + 1,
                mode: .speak,
                text: group.map(\.rawText).joined(),
                issues: []
            )
        }
        let output = TeleprompterMapOutput(blocks: blocks)
        return String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
    }
}
