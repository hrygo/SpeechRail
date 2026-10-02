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
            try Self.response(for: prompt)
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

        let result = try await pipeline.prepare(fixture.input, onObservation: observations.append)
        #expect(result.hasLocalFallback)

        let values = observations.values
        let started = try #require(values.first { $0.kind == .callStarted })
        let failed = try #require(values.first { $0.kind == .callFailed })
        let startedContext = try #require(started.context)
        let failedContext = try #require(failed.context)
        #expect(startedContext.runID == failedContext.runID)
        #expect(startedContext.requestID == failedContext.requestID)
        #expect(startedContext.stage == .grouping)
        #expect(failed.errorCode == "http_503")
        #expect(values.allSatisfy { $0.errorCode != "稿件不应进入日志" })
    }

    @Test func structuralMapFailureEmitsStableDiagnosticCode() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let observations = ObservationLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.grouping.v1" {
                return "{}"
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input, onObservation: observations.append)
        #expect(result.status == .complete)
        #expect(result.fallbackBlockCount == fixture.units.count)

        let decoderFailure = try #require(
            observations.values.first { $0.component == "grouping_decoder" && $0.kind == .callFailed }
        )
        #expect(decoderFailure.errorCode == "schema_keys")
    }

    @Test func truncatedMapSplitsWithoutRepeatingOversizedWindow() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let calls = CallLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try await calls.append(prompt)
            if prompt.schemaVersion == "teleprompter.grouping.v1" {
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
        let observations = ObservationLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try await calls.append(prompt)
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input, onObservation: observations.append)

        #expect(result.fallbackBlockCount == 0, "fallback=\(result.fallbackBlockCount), errors=\(observations.values.compactMap { $0.errorCode })")
        #expect(result.mapRequestCount == 1)
        #expect(result.rewriteRequestCount == 1)
        #expect(result.reduceRequestCount == 0)
        #expect(result.status == .complete)
        #expect(result.draft.blocks.count == 1)
        #expect(result.draft.blocks[0].disposition == .speak)
        #expect((await calls.schemaVersions) == ["teleprompter.grouping.v1", "teleprompter.rewrite.v1"])
    }

    @Test func subjectValueSwapIsRejectedByHardGateAndKeepsSource() async throws {
        let fixture = try makeFixture(
            text: "方案 A 的成本是 50 元，方案 B 的成本是 80 元。"
        )
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.rewrite.v1" {
                let input = try JSONDecoder().decode(
                    TeleprompterRewriteInput.self,
                    from: Data(prompt.input.utf8)
                )
                let blocks = input.groups.map { group in
                    TeleprompterRewriteBlock(
                        blockID: group.id,
                        disposition: .speak,
                        text: Self.swappedPrices(group.sourceUnits.map(\.rawText).joined()),
                    )
                }
                return String(decoding: try JSONEncoder().encode(
                    TeleprompterRewriteOutput(blocks: blocks)
                ), as: UTF8.self)
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.fallbackBlockCount == result.draft.blocks.count,
                "出现级顺序不一致必须整篇退回原稿")
        #expect(
            result.draft.blocks.map(\.text).joined() == "方案 A 的成本是 50 元，方案 B 的成本是 80 元。",
            "回退必须逐字保留原文"
        )
    }

    /// cue/skip 不产出朗读正文（decoder 强制 text 为空），但原稿必须留在
    /// `rawSourceText` 上——界面显示的正是它。此前 pipeline 把正文清空后，
    /// 展示层再去读同一个 `text`，于是这类段落在界面上永远是一片空白，
    /// 「跳过就成了让内容凭空消失的开关」。
    @Test func cueAndSkipBlocksKeepTheirSourceTextVisible() async throws {
        // 20 个单元会被 grouping 并成 3 组以上，cue 与 skip 才都有机会出现。
        let fixture = try makeFixture(lineCount: 20)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.reduction.v1" {
                return #"{"schema_version":"teleprompter.reduction.v1","patches":[]}"#
            }
            if prompt.schemaVersion == "teleprompter.rewrite.v1" {
                let input = try JSONDecoder().decode(
                    TeleprompterRewriteInput.self,
                    from: Data(prompt.input.utf8)
                )
                let blocks = input.groups.enumerated().map { offset, group in
                    TeleprompterRewriteBlock(
                        blockID: group.id,
                        disposition: offset.isMultiple(of: 2) ? .cue : .skip,
                        text: ""
                    )
                }
                return String(decoding: try JSONEncoder().encode(
                    TeleprompterRewriteOutput(blocks: blocks)
                ), as: UTF8.self)
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.status == .complete)
        #expect(result.draft.blocks.count >= 2, "需要多组才能同时覆盖 cue 与 skip")
        #expect(Set(result.draft.blocks.map(\.disposition)) == [.cue, .skip])
        for block in result.draft.blocks {
            #expect(block.disposition != .speak)
            #expect(block.text.isEmpty, "\(block.disposition) 不产出朗读正文")
            #expect(!block.rawSourceText.isEmpty,
                    "原稿必须留在 rawSourceText 上，否则界面上这段内容凭空消失")
        }
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
    }

    @Test func unchangedRewriteStaysSpeak() async throws {
        let fixture = try makeFixture(
            text: "方案 A 的成本是 50 元，方案 B 的成本是 80 元。"
        )
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.status == .complete)
        let block = try #require(result.draft.blocks.first)
        #expect(block.disposition == .speak)
    }

    @Test func malformedMapResponseUsesOneBoundedRecoveryRequest() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let prompts = PromptLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            await prompts.append(prompt)
            if prompt.schemaVersion == "teleprompter.grouping.v1",
               await attempts.next() == 1 {
                return #"{"secret-response-body":"DO_NOT_LEAK"}"#
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.mapRequestCount == 1)
        #expect(result.rewriteRequestCount == 1)
        #expect(await attempts.value == 2)
        let recoveryPrompt = try #require(await prompts.values.first {
            $0.instructions.contains("schema_keys")
        })
        #expect(!recoveryPrompt.instructions.contains("DO_NOT_LEAK"))
    }

    @Test func rewriteFailureRetriesOnlyRewriteWithTheOriginalGrouping() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let groupingCalls = AttemptCounter()
        let rewriteCalls = AttemptCounter()
        let prompts = PromptLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            await prompts.append(prompt)
            if prompt.schemaVersion == "teleprompter.grouping.v1" {
                _ = await groupingCalls.next()
            }
            if prompt.schemaVersion == "teleprompter.rewrite.v1",
               await rewriteCalls.next() == 1 {
                return "{}"
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.status == .complete)
        #expect(await groupingCalls.value == 1)
        #expect(await rewriteCalls.value == 2)
        let rewritePrompts = await prompts.values.filter { $0.schemaVersion == "teleprompter.rewrite.v1" }
        // 致命断言：下一行按 0／1 取下标，非致命断言失败后不会停，测试会越界
        // trap 把整个测试进程带崩，变异探针只能记成 INVALID——真回归就此变成
        // 「什么都没证明」。
        try #require(rewritePrompts.count == 2)
        #expect(rewritePrompts[0].input == rewritePrompts[1].input)
        #expect(rewritePrompts[1].instructions.contains("schema_keys"))
    }

    @Test func transientRetryWaitsForRetryAfterBeforeTheNextStageRequest() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let timestamps = TimestampLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            await timestamps.append()
            if prompt.schemaVersion == "teleprompter.grouping.v1",
               await attempts.next() == 1 {
                throw LLMError.httpWithRetry(status: 429, body: "", retryAfter: 0.05)
            }
            return try Self.response(for: prompt)
        })

        _ = try await pipeline.prepare(fixture.input)

        let values = await timestamps.values
        // 计数必须用 `#require`（致命）而不是 `#expect`：下面紧接着按 3 个元素
        // 取下标，非致命断言失败后不会停，测试会越界 trap 把整个测试进程带崩。
        // 崩掉的那一轮在变异探针里被记成 INVALID——**真回归因此变成「什么都没
        // 证明」**，比直接失败糟得多。
        try #require(values.count >= 3)
        #expect(values[1].timeIntervalSince(values[0]) >= 0.04)
    }

    @Test func repeatedStructuralFailureStopsAfterOneRegeneration() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.grouping.v1",
               await attempts.next() <= 2 {
                return "{}"
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)
        #expect(result.status == .complete)
        #expect(result.fallbackBlockCount == fixture.units.count)
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
        #expect(await attempts.value == 2)
    }

    @Test func quotaExhaustionStopsTheRunWithoutWaitingOrFallingBack() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let timestamps = TimestampLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            await timestamps.append()
            await attempts.next()
            // 14 天后恢复的配额：重试和原文回退都只会把「没整理」说成「整理好了」。
            throw LLMError.usageLimitExceeded(retryAfter: 1_257_998)
        })

        let startedAt = Date()
        await #expect(throws: LLMError.usageLimitExceeded(retryAfter: 1_257_998)) {
            _ = try await pipeline.prepare(fixture.input)
        }

        // 不重试：只发过第一次请求。
        #expect(await attempts.value == 1)
        // 不等待：真实故障是「睡满 Retry-After 再失败一次」。这里给宽松上界，
        // 只要求不再是几十秒量级。
        #expect(Date().timeIntervalSince(startedAt) < 5)
        let values = await timestamps.values
        try #require(values.count == 1)
    }

    @Test func anUnrecognizedButLongRetryAfterIsAlsoTerminal() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            await attempts.next()
            // 没命中配额措辞，但 Retry-After 长得像配额而不是抖动，同样不该等。
            throw LLMError.httpWithRetry(status: 429, body: "", retryAfter: 3_600)
        })

        let startedAt = Date()
        await #expect(throws: LLMError.httpWithRetry(status: 429, body: "", retryAfter: 3_600)) {
            _ = try await pipeline.prepare(fixture.input)
        }
        #expect(await attempts.value == 1)
        #expect(Date().timeIntervalSince(startedAt) < 5)
    }

    @Test func aShortRetryAfterStillWaitsAndRetries() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.grouping.v1",
               await attempts.next() == 1 {
                throw LLMError.httpWithRetry(status: 429, body: "", retryAfter: 0.05)
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)
        // 「早失败」不能变成「不再重试」：真正的限流仍要按 Retry-After 退避后重试。
        #expect(result.fallbackBlockCount == 0)
        #expect(await attempts.value == 2)
    }

    @Test func transientRateLimitGetsOneBoundedRetry() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.grouping.v1",
               await attempts.next() == 1 {
                throw LLMError.http(status: 429, body: "retry later")
            }
            return try Self.response(for: prompt)
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
        #expect(result.rewriteRequestCount == 4)
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
            return try Self.response(for: prompt)
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
            if prompt.schemaVersion == "teleprompter.grouping.v1" {
                throw LLMError.http(status: 503, body: "temporarily unavailable")
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)
        #expect(result.status == .complete)
        #expect(result.fallbackBlockCount == fixture.units.count)
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
    }

    @Test func oneWindowFailureKeepsOtherWindowsAndFallsBackOnlyLocally() async throws {
        let fixture = try makeFixture(lineCount: 96)
        let groupingCalls = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.grouping.v1" {
                let call = await groupingCalls.next()
                if call == 2 || call == 3 {
                    throw LLMError.http(status: 503, body: "temporarily unavailable")
                }
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.status == .complete)
        #expect(result.fallbackBlockCount > 0)
        #expect(result.fallbackBlockCount < result.draft.blocks.count)
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
        #expect(result.draft.blocks.contains { $0.origin == .ai && $0.disposition == .speak })
        #expect(result.draft.blocks.contains { $0.origin == .deterministic && $0.disposition == .speak },
                "单窗失败退回原稿时也应直接可念")
    }

    @Test func cancellationInvalidatesLateMapResponse() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try? await Task.sleep(for: .milliseconds(80))
            return try Self.response(for: prompt)
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
        private var windowsCompleted = 0
        private(set) var reduceStartedOnlyAfterAllMaps = true

        func append(_ prompt: TeleprompterPreparationPrompt) throws {
            schemaVersions.append(prompt.schemaVersion)
            if prompt.schemaVersion == "teleprompter.grouping.v1" {
                let input = try JSONDecoder().decode(
                    TeleprompterPreparationMapInput.self,
                    from: Data(prompt.input.utf8)
                )
                mapInputs.append(input)
            } else if prompt.schemaVersion == "teleprompter.rewrite.v1" {
                windowsCompleted += 1
            } else if prompt.schemaVersion == "teleprompter.reduction.v1" {
                reduceCount += 1
                reduceStartedOnlyAfterAllMaps = reduceStartedOnlyAfterAllMaps && windowsCompleted == 4
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

    private actor PromptLog {
        private(set) var values: [TeleprompterPreparationPrompt] = []

        func append(_ prompt: TeleprompterPreparationPrompt) {
            values.append(prompt)
        }
    }

    private actor TimestampLog {
        private(set) var values: [Date] = []

        func append() {
            values.append(Date())
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

    @Test func tableRowsKeepTheirOwnPricesAcrossRewrite() async throws {
        let fixture = try makeFixture(
            text: """
            | 套餐 | 价格 |
            | 标准版 | 99 元 |
            | 专业版 | 199 元 |
            """
        )
        let sourceText = fixture.units.map(\.rawText).joined()

        let faithful = TeleprompterPreparationPipeline(completion: { prompt in
            try Self.response(for: prompt)
        })
        let kept = try await faithful.prepare(fixture.input)

        #expect(kept.status == .complete)
        let spoken = kept.draft.blocks.map(\.text).joined()
        #expect(spoken.contains("标准版") && spoken.contains("专业版"))
        let standardPrice = try #require(spoken.range(of: "99"))
        let proPrice = try #require(spoken.range(of: "199"))
        let standardName = try #require(spoken.range(of: "标准版"))
        let proName = try #require(spoken.range(of: "专业版"))
        #expect(
            standardName.upperBound <= standardPrice.lowerBound
                && standardPrice.upperBound <= proName.lowerBound
                && proName.upperBound <= proPrice.lowerBound,
            "忠实改写后每个价格仍属于自己那一行"
        )

        let crossed = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.rewrite.v1" {
                let input = try JSONDecoder().decode(
                    TeleprompterRewriteInput.self,
                    from: Data(prompt.input.utf8)
                )
                let blocks = input.groups.map { group in
                    TeleprompterRewriteBlock(
                        blockID: group.id,
                        disposition: .speak,
                        text: Self.swappedTablePrices(group.sourceUnits.map(\.rawText).joined()),
                    )
                }
                return String(decoding: try JSONEncoder().encode(
                    TeleprompterRewriteOutput(blocks: blocks)
                ), as: UTF8.self)
            }
            return try Self.response(for: prompt)
        })
        let rejected = try await crossed.prepare(fixture.input)

        #expect(rejected.fallbackBlockCount == rejected.draft.blocks.count,
                "跨行调换价格必须整篇退回原稿")
        #expect(
            rejected.draft.blocks.map(\.text).joined() == sourceText,
            "回退必须逐字保留表格原文"
        )
    }

    @Test func unterminatedCodeAndFormulaSurviveTheFidelityGate() async throws {
        let fixture = try makeFixture(
            text: """
            配置示例：
            ```
            latency_ms = 200
            公式：T = L / R，其中 L 为 200 ms。
            """
        )
        let sourceText = fixture.units.map(\.rawText).joined()
        #expect(sourceText.contains("latency_ms = 200"), "未闭合代码块不能丢内容")
        #expect(sourceText.contains("T = L / R"), "公式不能被吞掉")

        let faithful = TeleprompterPreparationPipeline(completion: { prompt in
            try Self.response(for: prompt)
        })
        let kept = try await faithful.prepare(fixture.input)
        #expect(kept.status == .complete)
        let spoken = kept.draft.blocks.map(\.text).joined()
        #expect(spoken.contains("latency_ms = 200"))
        #expect(spoken.contains("200 ms"))

        let mutated = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.rewrite.v1" {
                let input = try JSONDecoder().decode(
                    TeleprompterRewriteInput.self,
                    from: Data(prompt.input.utf8)
                )
                let blocks = input.groups.map { group in
                    TeleprompterRewriteBlock(
                        blockID: group.id,
                        disposition: .speak,
                        text: Self.rewrittenLatency(group.sourceUnits.map(\.rawText).joined()),
                    )
                }
                return String(decoding: try JSONEncoder().encode(
                    TeleprompterRewriteOutput(blocks: blocks)
                ), as: UTF8.self)
            }
            return try Self.response(for: prompt)
        })
        let rejected = try await mutated.prepare(fixture.input)

        #expect(rejected.fallbackBlockCount == rejected.draft.blocks.count,
                "改写代码里的数值必须整篇退回原稿")
        #expect(rejected.draft.blocks.map(\.text).joined() == sourceText)
    }

    @Test func droppingANumberSignIsRejectedByTheHardGate() async throws {
        let fixture = try makeFixture(
            text: "毛利 -3 万元，误差 +5 %，环比 −7 个百分点。"
        )

        let faithful = TeleprompterPreparationPipeline(completion: { prompt in
            try Self.response(for: prompt)
        })
        let kept = try await faithful.prepare(fixture.input)
        #expect(kept.status == .complete, "带符号的原文必须能原样通过")

        let unsigned = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.rewrite.v1" {
                let input = try JSONDecoder().decode(
                    TeleprompterRewriteInput.self,
                    from: Data(prompt.input.utf8)
                )
                let blocks = input.groups.map { group in
                    TeleprompterRewriteBlock(
                        blockID: group.id,
                        disposition: .speak,
                        text: Self.strippedNumberSigns(group.sourceUnits.map(\.rawText).joined()),
                    )
                }
                return String(decoding: try JSONEncoder().encode(
                    TeleprompterRewriteOutput(blocks: blocks)
                ), as: UTF8.self)
            }
            return try Self.response(for: prompt)
        })
        let rejected = try await unsigned.prepare(fixture.input)

        #expect(rejected.fallbackBlockCount == rejected.draft.blocks.count,
                "去掉正负号会改变含义，必须整篇退回原稿")
        #expect(
            rejected.draft.blocks.map(\.text).joined() == fixture.units.map(\.rawText).joined(),
            "回退必须逐字保留带符号的原文"
        )
    }

    private static func swappedTablePrices(_ text: String) -> String {
        text
            .replacingOccurrences(of: "99", with: "\u{1}")
            .replacingOccurrences(of: "199", with: "99")
            .replacingOccurrences(of: "\u{1}", with: "199")
    }

    private static func strippedNumberSigns(_ text: String) -> String {
        text
            .replacingOccurrences(of: "-3", with: "3")
            .replacingOccurrences(of: "+5", with: "5")
            .replacingOccurrences(of: "\u{2212}7", with: "7")
    }

    private static func rewrittenLatency(_ text: String) -> String {
        text.replacingOccurrences(of: "200", with: "250")
    }

    // MARK: - 第六十八轮：素材构建管线的「模型不规矩」素材
    //
    // 这一组此前**一条变异都杀不掉**（F 组首轮 18 条零击杀）。共同原因不是
    // 「没测」，而是既有 87 条用例只喂规规矩矩的模型输出：分组首尾相接、
    // 改写块都指向真实分组、窗口结果非空、服务端只回 429。
    //
    // 下面每一条都只做一件事：**造出一种具体的「模型不规矩」**，然后钉住
    // 管线必须拒绝它，而不是把它悄悄变成一份看起来正常的稿子。

    @Test func groupingThatSkipsMiddleUnitsIsRejected() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.grouping.v1" {
                // 第 1 号单元被跳过：分组从 2 开始，0 号和 1 号都不在任何区间里。
                let units = try JSONDecoder().decode(
                    TeleprompterPreparationMapInput.self,
                    from: Data(prompt.input.utf8)
                )
                let blocks = [
                    TeleprompterGroupingBlock(startUnit: 0, endUnit: 1),
                    TeleprompterGroupingBlock(
                        startUnit: 2,
                        endUnit: units.targets.count + 8
                    )
                ]
                return String(decoding: try JSONEncoder().encode(
                    TeleprompterGroupingOutput(groups: blocks)
                ), as: UTF8.self)
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        // 守卫抛出的错会被本地兜底接住，所以**可观察的差别不在抛不抛错，而在
        // 交付的稿子还全不全**。「跳过中间单元」与第 63 轮 A3 同一族，只是那一族
        // 在解码器侧、这一族在管线侧：去掉区间守卫，第 1 号单元就此消失，
        // 而状态仍然是「完成」。
        #expect(result.fallbackBlockCount == fixture.units.count)
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
    }

    @Test func rewriteBlockReferencingAnUnknownGroupIsRejected() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.rewrite.v1" {
                let input = try JSONDecoder().decode(
                    TeleprompterRewriteInput.self,
                    from: Data(prompt.input.utf8)
                )
                // 凭空造一个不存在的分组：块里的文字没有对应的源单元。
                let blocks = [TeleprompterRewriteBlock(
                    blockID: "block-9000-9001",
                    disposition: .speak,
                    text: "模型自己编出来的一段话。",
                )]
                _ = input
                return String(decoding: try JSONEncoder().encode(
                    TeleprompterRewriteOutput(blocks: blocks)
                ), as: UTF8.self)
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        // 凭空造块被拒后同样走本地兜底，因此钉的是「一个源单元都不许少」：
        // 去掉守卫后这个块会去认第一个分组，其余分组的内容全部落空。
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
    }

    @Test func emptyGroupingOutputIsRejectedInsteadOfBecomingACompletedWindow() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.grouping.v1" {
                return #"{"schema_version":"teleprompter.grouping.v1","groups":[]}"#
            }
            if prompt.schemaVersion == "teleprompter.rewrite.v1" {
                return #"{"schema_version":"teleprompter.rewrite.v1","blocks":[]}"#
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        // 空结果不能被记成「一次成功的窗口」：那会让这一窗的内容凭空消失，
        // 而对外仍然是 complete。守卫把它变成一次本地兜底，读者拿到的是
        // 标着 unresolved 的完整原稿，而不是一份少了一整窗的稿子。
        #expect(result.fallbackBlockCount == fixture.units.count)
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
    }

    @Test func configurationFailureIsNotSilentlyDowngradedToReadingTheSource() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let pipeline = TeleprompterPreparationPipeline(completion: { _ in
            // 未配置模型属于「重试也没用」的一类。读者以为 AI 不可用、却拿到一份
            // 看起来完全正常的稿子，是判据 1「稿件可信」的直接违反：降级本身
            // 没有告诉读者发生过。
            throw LLMError.notConfigured
        })

        await #expect(throws: LLMError.self) {
            try await pipeline.prepare(fixture.input)
        }
    }

    @Test func serverErrorGetsOneBoundedRetryJustLikeRateLimit() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.grouping.v1",
               await attempts.next() == 1 {
                throw LLMError.http(status: 503, body: "upstream unavailable")
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        // 429 的重试用例早就有，5xx 此前没有——服务端 5xx 不再触发重试时，
        // 读者要多白等一次完整往返。
        #expect(result.mapRequestCount == 1)
        #expect(await attempts.value == 2)
    }

    @Test func seamNextToAnOmittedBlockIsNotSentToTheReduceStage() async throws {
        // 接缝只存在于**窗口之间**，所以这条要 4 个窗口才构造得出来
        // （96 个单元 × 每窗 24 个 = 4 窗 3 缝）。
        let fixture = try makeFixture(lineCount: 96)
        let reduceCalls = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.reduction.v1" {
                _ = await reduceCalls.next()
                return #"{"schema_version":"teleprompter.reduction.v1","patches":[]}"#
            }
            if prompt.schemaVersion == "teleprompter.rewrite.v1" {
                let input = try JSONDecoder().decode(
                    TeleprompterRewriteInput.self,
                    from: Data(prompt.input.utf8)
                )
                // 把第 0 号窗口的最后一个块（单元 23）改成省略块：于是第 0 条接缝
                // 的左侧不再是 speak。
                let blocks = input.groups.map { group -> TeleprompterRewriteBlock in
                    if group.sourceUnits.contains(where: { $0.id == 23 }) {
                        return TeleprompterRewriteBlock(
                            blockID: group.id,
                            disposition: .skip,
                            text: "",
                        )
                    }
                    return TeleprompterRewriteBlock(
                        blockID: group.id,
                        disposition: .speak,
                        text: group.sourceUnits.map(\.rawText).joined(),
                    )
                }
                return String(decoding: try JSONEncoder().encode(
                    TeleprompterRewriteOutput(blocks: blocks)
                ), as: UTF8.self)
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        // 省略块不含朗读内容，送去做接缝合并会把非朗读内容接进朗读正文，
        // 所以那一条接缝必须留在原地不查。
        #expect(result.boundaries.count == 3)
        #expect(result.reduceRequestCount == 2)
        #expect(await reduceCalls.value == 2)
        #expect(result.boundaries.map(\.isChecked) == [false, true, true])
    }

    @Test func truncatedGroupingIsNotRetriedBecauseTruncationIsDeterministic() async throws {
        let fixture = try makeFixture(lineCount: 1)
        let groupingCalls = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.grouping.v1" {
                _ = await groupingCalls.next()
                throw LLMError.outputTruncated
            }
            return try Self.response(for: prompt)
        })

        _ = try? await pipeline.prepare(fixture.input)

        // 输出被截断是**确定性**失败：同样的请求再发一次还是被截断。重试只是
        // 白花一次调用并推迟失败暴露，正确的处置是切窗或本地兜底。
        #expect(await groupingCalls.value == 1)
    }

    @Test func transportFailureFallsBackLocallyInsteadOfFailingTheWholeDraft() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.grouping.v1" {
                throw LLMError.transport("simulated transport failure")
            }
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        // 传输层抖动和流提前结束都属于「本机可以自己兜住」的一类：整篇准备失败
        // 等于一次网络抖动让读者开不了讲。降级必须给出**完整的原稿**并标成
        // 待复核，而不是少一段。
        #expect(result.fallbackBlockCount == fixture.units.count)
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
        #expect(result.status == .complete)
    }

    private func makeFixture(lineCount: Int) throws -> Fixture {
        try makeFixture(text: (0..<lineCount).map { "第\($0)段。\n" }.joined())
    }

    private func makeFixture(text: String) throws -> Fixture {
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

    private static func swappedPrices(_ text: String) -> String {
        text
            .replacingOccurrences(of: "50", with: "\u{1}")
            .replacingOccurrences(of: "80", with: "50")
            .replacingOccurrences(of: "\u{1}", with: "80")
    }

    private static func response(for prompt: TeleprompterPreparationPrompt) throws -> String {
        if prompt.schemaVersion == "teleprompter.reduction.v1" {
            return #"{"schema_version":"teleprompter.reduction.v1","patches":[]}"#
        }
        if prompt.schemaVersion == "teleprompter.grouping.v1" {
            return try groupingResponse(for: prompt)
        }
        if prompt.schemaVersion == "teleprompter.rewrite.v1" {
            return try rewriteResponse(for: prompt)
        }
        return try mapResponse(for: prompt)
    }

    private static func groupingResponse(for prompt: TeleprompterPreparationPrompt) throws -> String {
        let input = try JSONDecoder().decode(
            TeleprompterPreparationMapInput.self,
            from: Data(prompt.input.utf8)
        )
        guard !input.targets.isEmpty else { throw TestFailure.mapUnavailable }
        let groups = stride(from: 0, to: input.targets.count, by: 8).map { start in
            let end = min(start + 8, input.targets.count)
            return TeleprompterGroupingBlock(startUnit: start, endUnit: end)
        }
        return String(decoding: try JSONEncoder().encode(TeleprompterGroupingOutput(groups: groups)), as: UTF8.self)
    }

    private static func rewriteResponse(for prompt: TeleprompterPreparationPrompt) throws -> String {
        let input = try JSONDecoder().decode(
            TeleprompterRewriteInput.self,
            from: Data(prompt.input.utf8)
        )
        guard !input.groups.isEmpty else { throw TestFailure.mapUnavailable }
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
                disposition: .speak,
                text: group.map(\.rawText).joined(),
            )
        }
        let output = TeleprompterMapOutput(blocks: blocks)
        return String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
    }
}
