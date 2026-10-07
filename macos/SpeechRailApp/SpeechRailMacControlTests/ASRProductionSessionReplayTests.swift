import Foundation
import CryptoKit
import SpeechRailControlKit
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

// Opt-in end-to-end replay through the production Session and Realtime client.
// Inputs and the aggregate output stay outside the repository. Authentication is
// resolved by SpeechRailAPICredentialProvider; no test prints transcript or audio.
private enum ASRProductionSessionReplaySwitch {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["SPEECHRAIL_ASR_SESSION_E2E"] == "1"
    }
}

@Suite(.serialized)
@MainActor
struct ASRProductionSessionReplayTests {
    @Test(
        .enabled(
            if: ASRProductionSessionReplaySwitch.enabled,
            "Set SPEECHRAIL_ASR_SESSION_E2E=1 and provide one external fixture to run the selected production Session."
        )
    )
    func selectedProductionSessionConsumesPacedFakeCapture() async throws {
        let configuration = try SessionReplayConfiguration.load()
        let samplerHandshake = try SessionReplaySamplerHandshake.load(
            outputURL: configuration.outputURL,
            environment: ProcessInfo.processInfo.environment
        )
        let maximumAudioSeconds = ProcessInfo.processInfo.environment[
            "SPEECHRAIL_ASR_SESSION_LONG_FIXTURE"
        ] == "1" ? 3_600 : 30
        let pcm = try ReplayPCM24K.load(
            from: configuration.audioURL, maximumAudioSeconds: maximumAudioSeconds
        )
        guard configuration.hasCompleteTeleprompterPrefixCoverage(
            fixtureSamples: pcm.bytes.count / MemoryLayout<Int16>.size
        ) else {
            throw SessionReplayFailure.invalidConfiguration
        }
        let run = try await replay(configuration, pcm: pcm.bytes)
        try configuration.write(run.summary)

        #expect(run.summary.executionGate == "pass", "The selected production Session replay must drain successfully.")
        #expect(run.summary.uploadGate == "pass", "Every fake-capture sample must reach the production Realtime client.")
        #expect(run.summary.pcmIntegrityGate == "pass", "The source-yielded and client-accepted PCM bytes must match.")
        #expect(run.summary.receiptBarrierGate == "pass", "The Session must complete the production client's drain receipt barrier.")
        #expect(run.summary.configuredEchoGate == "pass", "The production client must accept a valid session.updated ASR policy echo.")
        #expect(run.summary.spanIntegrityGate == "pass", "Admitted input spans must remain valid, ordered, and within the scene segment budget.")
        #expect(run.summary.terminalGate == "pass", "Every frozen item must have one later terminal; an unbound empty success is allowed.")
        #expect(run.summary.recognitionGate == "pass", "Representative speech must have a non-empty completed segment and no recognition or server errors.")
        #expect(run.summary.businessGate == "pass", "The selected Session must preserve its scene-specific consumer behavior.")
        #expect(run.summary.captureReleaseGate == "pass", "Capture occupancy, source, realtime client, and event mirror must be released; meeting processing may continue.")
        if configuration.scene == .assistant {
            #expect(run.summary.assistantTurnGate == "pass", "The single assistant reply must follow the VAD terminal, not a budget split.")
        }
        if configuration.scene == .teleprompter {
            #expect(run.summary.teleprompterProgressGate == "pass", "Revised previews must advance within the expected script and manual takeover must hold position.")
        }
        try await samplerHandshake?.waitForSamplerStop(timeout: .seconds(30))
    }

    private func replay(_ configuration: SessionReplayConfiguration, pcm: Data) async throws -> SessionReplayRun {
        let storage = try await SessionReplayStorage.make()
        let recorder = SessionReplayRecorder()
        let source = SessionReplayCaptureSource()
        let clientHandle = SessionReplayClientHandle()
        let fixtureSamples = pcm.count / MemoryLayout<Int16>.size
        guard configuration.hasCompleteTeleprompterPrefixCoverage(fixtureSamples: fixtureSamples) else {
            throw SessionReplayFailure.invalidConfiguration
        }
        let syntheticTrailingSilenceSamples = configuration.scene == .assistant
            ? Int(RealtimeASRClient.sampleRate * 1.5)
            : 0
        let replayPCM = syntheticTrailingSilenceSamples > 0
            ? appendingSilence(pcm, samples: syntheticTrailingSilenceSamples)
            : pcm

        do {
            let businessGate: String
            switch configuration.scene {
            case .assistant:
                businessGate = try await replayAssistant(
                    configuration,
                    pcm: replayPCM,
                    source: source,
                    recorder: recorder,
                    clientHandle: clientHandle,
                    storage: storage
                )
            case .meeting:
                businessGate = try await replayMeeting(
                    configuration,
                    pcm: replayPCM,
                    source: source,
                    recorder: recorder,
                    clientHandle: clientHandle,
                    storage: storage
                )
            case .caption:
                businessGate = try await replayCaption(
                    configuration,
                    pcm: replayPCM,
                    source: source,
                    recorder: recorder,
                    clientHandle: clientHandle,
                    storage: storage
                )
            case .teleprompter:
                businessGate = try await replayTeleprompter(
                    configuration,
                    pcm: replayPCM,
                    source: source,
                    recorder: recorder,
                    clientHandle: clientHandle,
                    storage: storage
                )
            }

            let snapshot = await recorder.snapshot()
            let client = try requireClient(clientHandle)
            let upload = await client.uploadSnapshot()
            let clientRelease = await client.releaseSnapshot()
            let captureReleaseEvidence = SessionReplayCaptureReleaseEvidence(
                coordinatorCaptureReleased: SessionReplayCaptureReleaseIntegrity.coordinatorCaptureReleased(
                    scene: configuration.scene,
                    occupancy: storage.coordinator.occupancy
                ),
                captureSourceStopped: source.isReleased,
                realtimeClientClosed: clientRelease.closed,
                eventMirrorDrained: clientRelease.mirrorStarted && clientRelease.mirrorDrained
            )
            let captureReleasePassed = SessionReplayCaptureReleaseIntegrity.validate(captureReleaseEvidence)
            let inputSamples = snapshot.sourceSamplesYielded
            let boundaries = snapshot.boundaries.sorted {
                $0.span.startSample == $1.span.startSample
                    ? $0.span.endSample < $1.span.endSample
                    : $0.span.startSample < $1.span.startSample
            }
            let requestedMaxSegmentSamples = Int(
                Double(RealtimeASRClient.sampleRate)
                    * Double(configuration.scene.preset.policy.maxSegmentMilliseconds)
                    / 1_000
            )
            let spanIntegrity = SessionReplaySpanIntegrity.validate(
                boundaries,
                uploadedSampleWatermark: upload.uploadedSamples,
                maximumSegmentSamples: requestedMaxSegmentSamples
            )
            let completeInputPassed = configuration.scene == .teleprompter
                ? inputSamples > 0 && inputSamples <= fixtureSamples
                : inputSamples == fixtureSamples + syntheticTrailingSilenceSamples
            let uploadPassed = completeInputPassed
                && upload.uploadedSamples == inputSamples
                && snapshot.uploadedSamples == inputSamples
            let pcmIntegrityPassed = await recorder.pcmStreamsMatch()
            let receiptPassed = upload.drainSucceeded && upload.uploadedSamples == inputSamples
            let configuredEchoPassed = snapshot.configuredEventCount > 0
            let terminalPassed = SessionReplayTerminalIntegrity.validate(snapshot)
            let recognitionPassed = SessionReplayRecognitionIntegrity.validate(snapshot)
            let assistantTurnPassed = configuration.scene != .assistant
                || SessionReplayAssistantTurnIntegrity.validate(snapshot)
            let teleprompterProgressPassed = configuration.scene != .teleprompter
                || snapshot.teleprompterProgressEvidence.map(SessionReplayTeleprompterProgressIntegrity.validate) == true
            let assistantTurnGate = configuration.scene == .assistant
                ? (assistantTurnPassed ? "pass" : "fail")
                : "not_applicable"
            let teleprompterProgressGate = configuration.scene == .teleprompter
                ? (teleprompterProgressPassed ? "pass" : "fail")
                : "not_applicable"
            let businessPassed = businessGate == "pass"
                && terminalPassed
                && recognitionPassed
                && assistantTurnPassed
                && teleprompterProgressPassed
            let executionPassed = uploadPassed
                && pcmIntegrityPassed
                && receiptPassed
                && configuredEchoPassed
                && spanIntegrity
                && terminalPassed
                && recognitionPassed
                && businessPassed
                && captureReleasePassed
            let run = SessionReplayRun(
                summary: SessionReplaySummary(
                    fixtureID: configuration.fixtureID,
                    scene: configuration.scene.rawValue,
                    preset: configuration.scene.preset.rawValue,
                    fixtureSamples: fixtureSamples,
                    inputSamples: inputSamples,
                    sourceSamplesYielded: snapshot.sourceSamplesYielded,
                    syntheticTrailingSilenceSamples: syntheticTrailingSilenceSamples,
                    uploadedSampleWatermark: upload.uploadedSamples,
                    requestedMaxSegmentSamples: requestedMaxSegmentSamples,
                    effectiveBudgetObservation: "validated_by_client_value_not_exposed",
                    segmentCount: boundaries.count,
                    terminalCount: snapshot.terminalCounts.values.reduce(0, +),
                    failedTerminalCount: snapshot.failedTerminalCount,
                    serverErrorCount: snapshot.serverErrorCount,
                    emptySuccessCount: snapshot.emptySuccessCount,
                    nonEmptySuccessCount: snapshot.nonEmptySuccessCount,
                    previewEventCount: snapshot.previewEventCount,
                    previewRevisionCount: snapshot.previewRevisionCount,
                    previewRevisionRegressionCount: snapshot.previewRevisionRegressionCount,
                    firstPreviewMilliseconds: snapshot.firstPreviewAt.map {
                        SessionReplayClock.milliseconds(from: snapshot.audioStartedAt, to: $0)
                    },
                    finalAfterLastAudioMilliseconds: snapshot.lastTerminalAt.map {
                        SessionReplayClock.milliseconds(from: snapshot.lastAudioSentAt, to: $0)
                    },
                    uploadGate: uploadPassed ? "pass" : "fail",
                    pcmIntegrityGate: pcmIntegrityPassed ? "pass" : "fail",
                    receiptBarrierGate: receiptPassed ? "pass" : "fail",
                    configuredEchoGate: configuredEchoPassed ? "pass" : "fail",
                    spanIntegrityGate: spanIntegrity ? "pass" : "fail",
                    terminalGate: terminalPassed ? "pass" : "fail",
                    recognitionGate: recognitionPassed ? "pass" : "fail",
                    businessGate: businessPassed ? "pass" : "fail",
                    assistantTurnGate: assistantTurnGate,
                    assistantLLMStreamCallCount: snapshot.assistantLLMCallOrders.count,
                    assistantLLMStreamCallOrder: snapshot.assistantLLMCallOrders.first,
                    assistantVADTerminalOrder: snapshot.boundaries
                        .first(where: { $0.reason == .vad })
                        .flatMap { snapshot.terminalOrder[$0.itemID] },
                    teleprompterProgressGate: teleprompterProgressGate,
                    teleprompterSameItemRevisionCount: snapshot.teleprompterProgressEvidence?.maximumSameItemRevisionCount ?? 0,
                    teleprompterPositionObservationCount: snapshot.teleprompterProgressEvidence?.observedSourcePrefixOffsetsUTF16.count ?? 0,
                    teleprompterObservedDisplayPrefixOffsetsUTF16: snapshot.teleprompterProgressEvidence?.observedDisplayPrefixOffsetsUTF16 ?? [],
                    teleprompterObservedSourcePrefixOffsetsUTF16: snapshot.teleprompterProgressEvidence?.observedSourcePrefixOffsetsUTF16 ?? [],
                    teleprompterObservedSourceSampleWatermarks: snapshot.teleprompterProgressEvidence?.observedSourceSampleWatermarks ?? [],
                    teleprompterStartDisplayPrefixUTF16: snapshot.teleprompterProgressEvidence?.firstObservedDisplayOffsetUTF16,
                    teleprompterEndDisplayPrefixUTF16: snapshot.teleprompterProgressEvidence?.lastObservedDisplayOffsetUTF16,
                    teleprompterStartSourcePrefixUTF16: snapshot.teleprompterProgressEvidence?.firstObservedSourceOffsetUTF16,
                    teleprompterEndSourcePrefixUTF16: snapshot.teleprompterProgressEvidence?.lastObservedSourceOffsetUTF16,
                    teleprompterManualDisplayPrefixUTF16: snapshot.teleprompterProgressEvidence?.manualDisplayPrefixOffsetUTF16,
                    teleprompterManualSourcePrefixUTF16: snapshot.teleprompterProgressEvidence?.manualSourcePrefixOffsetUTF16,
                    teleprompterManualSourceSampleWatermark: snapshot.teleprompterProgressEvidence?.manualSourceSampleWatermark,
                    teleprompterExpectedDisplayScriptUTF16Length: snapshot.teleprompterProgressEvidence?.expectedDisplayScriptUTF16Length,
                    teleprompterExpectedSourceUTF16Length: snapshot.teleprompterProgressEvidence?.expectedSourceUTF16Length,
                    teleprompterProcessingDiagnostics: snapshot.teleprompterProcessingDiagnostics,
                    captureReleaseGate: captureReleasePassed ? "pass" : "fail",
                    coordinatorCaptureReleased: captureReleaseEvidence.coordinatorCaptureReleased,
                    captureSourceStopped: captureReleaseEvidence.captureSourceStopped,
                    realtimeClientClosed: captureReleaseEvidence.realtimeClientClosed,
                    eventMirrorDrained: captureReleaseEvidence.eventMirrorDrained,
                    executionGate: executionPassed ? "pass" : "fail",
                    captureStopReason: configuration.scene == .teleprompter
                        ? "manual_takeover"
                        : "fixture_eof",
                    spans: boundaries.enumerated().map { index, boundary in
                        SessionReplaySummary.Span(
                            ordinal: index + 1,
                            startSample: boundary.span.startSample,
                            endSample: boundary.span.endSample,
                            reason: boundary.reason.rawValue
                        )
                    }
                )
            )
            await storage.cleanup()
            return run
        } catch {
            await storage.coordinator.finalize(reason: .user)
            if let client = clientHandle.client {
                await client.close()
            }
            await storage.cleanup()
            throw SessionReplayFailure.sessionRunFailed
        }
    }

    private func appendingSilence(_ pcm: Data, samples: Int) -> Data {
        var padded = pcm
        padded.append(Data(repeating: 0, count: samples * MemoryLayout<Int16>.size))
        return padded
    }

    private func replayAssistant(
        _ configuration: SessionReplayConfiguration,
        pcm: Data,
        source: SessionReplayCaptureSource,
        recorder: SessionReplayRecorder,
        clientHandle: SessionReplayClientHandle,
        storage: SessionReplayStorage
    ) async throws -> String {
        let realLLM = ProcessInfo.processInfo.environment["SPEECHRAIL_ASR_SESSION_REAL_LLM"] == "1"
        let llm = SessionReplayAssistantLLM(
            recorder: recorder, provider: realLLM ? LLMProvider() : nil
        )
        let dependencies = AssistantSessionDependencies(
            llm: llm,
            makeRealtimeClient: { clientConfiguration in
                let client = SessionReplayClient(
                    realtime: RealtimeASRClient(
                        port: clientConfiguration.port,
                        scenePreset: clientConfiguration.scenePreset,
                        voice: clientConfiguration.voice,
                        apiKey: clientConfiguration.apiKey,
                        expectedASRRevision: configuration.expectedASRRevision ?? clientConfiguration.expectedASRRevision,
                        expectedTTSRevision: clientConfiguration.expectedTTSRevision,
                        expectedVoiceRevision: clientConfiguration.expectedVoiceRevision,
                        callerTTSEnabled: false
                    ),
                    recorder: recorder
                )
                clientHandle.install(client)
                return client
            },
            makePlaybackChannel: { SessionReplayDiscardingPlayback() }
        )
        let session = AssistantSession(coordinator: storage.coordinator, port: configuration.port, dependencies: dependencies)
        let preferences = SessionPreferences(defaults: storage.defaults)
        if realLLM {
            // Copy only the LLM preference keys into an isolated suite. The
            // production preferences and credential store remain read-only.
            guard let appDefaults = UserDefaults(suiteName: "com.speechrail.desktop") else {
                throw SessionReplayFailure.invalidConfiguration
            }
            for key in [
                "speechrail.llm.baseURL", "speechrail.llm.model",
                "speechrail.llm.compatibilityMode", "speechrail.llm.moduleOverrides.v1"
            ] {
                if let value = appDefaults.object(forKey: key) {
                    storage.defaults.set(value, forKey: key)
                }
            }
            let copied = SessionPreferences(defaults: storage.defaults)
            let resolved = copied.llmConfiguration(for: .assistant)
            guard resolved.isConfigured, resolved.isBaseURLValid,
                  !resolved.embedsCredential,
                  let host = URL(string: resolved.normalizedBaseURL)?.host,
                  ["127.0.0.1", "localhost", "::1"].contains(host) else {
                throw SessionReplayFailure.invalidConfiguration
            }
            session.preferences = { copied }
        } else {
            preferences.llmBaseURL = "http://127.0.0.1:1/v1"
            preferences.llmModel = "session-replay-fake"
            session.preferences = { preferences }
            session.apiKeyProvider = { nil }
            session.moduleAPIKeyProvider = { _ in nil }
        }
        session.serviceReadiness = { .ready(profile: "session-replay") }
        session.audioSourceFactory = { source }
        storage.coordinator.starter = { kind in
            guard kind == .assistant else { return }
            try await session.beginCapture()
        }
        storage.coordinator.stopper = { kind in
            guard kind == .assistant else { return }
            await session.stopCapture()
        }

        await session.start(
            persona: Persona(id: "session-replay", title: "session replay", body: ""),
            voiceID: nil,
            mode: .turnTaking
        )
        guard await waitUntil({ session.phase == .listening && session.sessionID != nil }) else {
            throw SessionReplayFailure.sessionDidNotStart
        }

        try await feedPaced(pcm, to: source, recorder: recorder)
        let budgetRolloverObserved = await waitUntil(timeout: .seconds(90)) {
            await recorder.hasCompletedBudgetRollover
        }

        let businessTurnArrived = await waitUntil {
            let state = await recorder.snapshot()
            let streamCount = await llm.streamCount
            return state.boundaries.contains(where: { $0.reason == .vad })
                && !state.assistantLLMCallOrders.isEmpty
                && streamCount > 0
        }
        guard businessTurnArrived else { throw SessionReplayFailure.businessTurnDidNotArrive }
        if realLLM {
            do {
                try await verifyRealLLMResponse(llm, configuration: configuration)
            } catch {
                _ = await session.endConversation()
                throw error
            }
        }
        let turnOrderingPassed = SessionReplayAssistantTurnIntegrity.validate(await recorder.snapshot())
        let callsBeforeEnd = await llm.streamCount
        _ = await session.endConversation()
        let callsAfterEnd = await llm.streamCount

        return budgetRolloverObserved && turnOrderingPassed && callsBeforeEnd == 1 && callsAfterEnd == 1
            ? "pass" : "fail"
    }

    private func verifyRealLLMResponse(
        _ llm: SessionReplayAssistantLLM,
        configuration: SessionReplayConfiguration
    ) async throws {
        let responseArrived = await waitUntil(timeout: .seconds(90)) {
            await llm.completedStreamCount == 1
        }
        let inputMatched = await llm.formalInputMatched
        let outputCharacters = await llm.outputCharacters
        let outputContentCharacters = await llm.outputContentCharacters
        var evidence: [String: Any] = [
            "schema_version": 1,
            "mode": "real_local_llm",
            "stream_count": await llm.streamCount,
            "completed_stream_count": await llm.completedStreamCount,
            "output_characters": outputCharacters,
            "output_content_characters": outputContentCharacters,
            "formal_input_gate": inputMatched ? "pass" : "fail",
            "response_gate": responseArrived && outputContentCharacters > 0 ? "pass" : "fail",
            "scope": "real ASR + production AssistantSession + LLMProvider; fake capture/TTS/playback",
            "semantic_correctness_gate": "unset"
        ]
        if let latency = await llm.finalToLLMSeconds {
            evidence["received_final_to_llm_seconds"] = latency
        }
        let evidenceURL = configuration.outputURL.appendingPathExtension("llm.json")
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: evidenceURL.path),
              FileManager.default.createFile(
                atPath: evidenceURL.path,
                contents: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
                attributes: [.posixPermissions: 0o600]
              ),
              responseArrived, inputMatched, outputContentCharacters > 0 else {
            throw SessionReplayFailure.businessTurnDidNotArrive
        }
    }

    private func replayMeeting(
        _ configuration: SessionReplayConfiguration,
        pcm: Data,
        source: SessionReplayCaptureSource,
        recorder: SessionReplayRecorder,
        clientHandle: SessionReplayClientHandle,
        storage: SessionReplayStorage
    ) async throws -> String {
        let meetingSource = SessionReplayMeetingSource(capture: source)
        let meetingClock = SessionReplayMeetingClock()
        let dependencies = MeetingSessionDependencies(
            makeAudioSource: { meetingSource },
            makeRealtimeClient: { clientConfiguration in
                let client = SessionReplayClient(
                    realtime: RealtimeASRClient(
                        port: clientConfiguration.port,
                        scenePreset: clientConfiguration.scenePreset,
                        apiKey: clientConfiguration.apiKey,
                        expectedASRRevision: configuration.expectedASRRevision ?? clientConfiguration.expectedASRRevision
                    ),
                    recorder: recorder
                )
                clientHandle.install(client)
                return client
            },
            clock: meetingClock,
            powerMonitor: SessionReplayPowerMonitor()
        )
        let session = MeetingSession(coordinator: storage.coordinator, port: configuration.port, dependencies: dependencies)
        session.serviceReadiness = { .ready(profile: "session-replay") }
        storage.coordinator.starter = { kind in
            guard kind == .meeting else { return }
            try await session.beginCapture()
        }
        storage.coordinator.stopper = { kind in
            guard kind == .meeting else { return }
            await session.stopCapture()
        }

        await session.start(selection: MeetingAudioSelection(), title: "ASR session replay")
        guard await waitUntil({ session.phase == .recording && session.sessionID != nil }) else {
            throw SessionReplayFailure.sessionDidNotStart
        }
        let sessionID = try requireSessionID(session.sessionID)
        guard let ledgerOrigin = meetingClock.captureOrigin else {
            throw SessionReplayFailure.invalidConfiguration
        }
        try await feedPaced(pcm, to: source, recorder: recorder)
        await session.finishAndSummarize()
        let rows = try await storage.store.lines(sessionID: sessionID)
        guard let record = try await storage.store.session(id: sessionID) else { return "fail" }
        let snapshot = await recorder.snapshot()
        return SessionReplayRowIntegrity.matches(
            snapshot: snapshot,
            rows: rows,
            sessionID: sessionID,
            recordStartedAt: record.startedAt,
            ledgerOrigin: ledgerOrigin
        ) ? "pass" : "fail"
    }

    private func replayCaption(
        _ configuration: SessionReplayConfiguration,
        pcm: Data,
        source: SessionReplayCaptureSource,
        recorder: SessionReplayRecorder,
        clientHandle: SessionReplayClientHandle,
        storage: SessionReplayStorage
    ) async throws -> String {
        let dependencies = CaptionSessionDependencies { clientConfiguration in
            let client = SessionReplayClient(
                realtime: RealtimeASRClient(
                    port: clientConfiguration.port,
                    language: configuration.language,
                    scenePreset: clientConfiguration.scenePreset,
                    diarizationEnabled: clientConfiguration.diarizationEnabled,
                    apiKey: clientConfiguration.apiKey,
                    expectedASRRevision: configuration.expectedASRRevision ?? clientConfiguration.expectedASRRevision
                ),
                recorder: recorder
            )
            clientHandle.install(client)
            return client
        }
        let session = CaptionSession(
            coordinator: storage.coordinator,
            port: configuration.port,
            dependencies: dependencies,
            audioSourceFactory: { source }
        )
        session.serviceReadiness = { .ready(profile: "session-replay") }
        storage.coordinator.starter = { kind in
            guard kind == .captions else { return }
            try await session.beginCapture()
        }
        storage.coordinator.stopper = { kind in
            guard kind == .captions else { return }
            await session.stopCapture()
        }

        await session.openBand()
        guard await waitUntil({ session.phase == .running && session.sessionID != nil }) else {
            throw SessionReplayFailure.sessionDidNotStart
        }
        let sessionID = try requireSessionID(session.sessionID)
        try await feedPaced(pcm, to: source, recorder: recorder)
        await session.finish()
        let rows = try await storage.store.lines(sessionID: sessionID)
        guard let record = try await storage.store.session(id: sessionID) else { return "fail" }
        let snapshot = await recorder.snapshot()
        return SessionReplayRowIntegrity.matches(
            snapshot: snapshot,
            rows: rows,
            sessionID: sessionID,
            recordStartedAt: record.startedAt,
            ledgerOrigin: record.startedAt
        ) ? "pass" : "fail"
    }

    private func replayTeleprompter(
        _ configuration: SessionReplayConfiguration,
        pcm: Data,
        source: SessionReplayCaptureSource,
        recorder: SessionReplayRecorder,
        clientHandle: SessionReplayClientHandle,
        storage: SessionReplayStorage
    ) async throws -> String {
        guard let referenceText = configuration.referenceText else {
            throw SessionReplayFailure.missingTeleprompterReference
        }
        let v2Store = try TeleprompterV2Store(
            directoryURL: storage.root.appendingPathComponent("documents", isDirectory: true)
        )
        let session = TeleprompterSession(
            coordinator: storage.coordinator,
            v2Store: v2Store,
            port: configuration.port,
            audioSourceFactory: { source }
        )
        let observationState = SessionReplayTeleprompterObservationState()
        session.preferredSpeechLanguage = configuration.language
        session.serviceReadiness = { .ready(profile: "session-replay") }
        session.realtimeClientFactory = { [weak session] port, apiKey, realtimeConfiguration in
            let client = SessionReplayClient(
                realtime: RealtimeASRClient(
                    port: port,
                    language: realtimeConfiguration.language,
                    keywords: realtimeConfiguration.keywords,
                    scenePreset: realtimeConfiguration.scenePreset,
                    apiKey: apiKey,
                    expectedASRRevision: configuration.expectedASRRevision
                ),
                recorder: recorder,
                alignmentObserver: { @MainActor [weak session] envelope, expectedCount, watermark in
                    guard observationState.isEnabled, let session else { return }
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: .seconds(2))
                    while session.followLatencyDiagnostics.alignmentSampleCount < expectedCount,
                          expectedCount < 128, clock.now < deadline,
                          observationState.isEnabled, !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(2)) }
                        catch { break }
                    }
                    guard observationState.isEnabled else { return }
                    guard SessionReplayTeleprompterProcessingIntegrity.caughtUp(
                        receivedAlignmentEvents: expectedCount,
                        processedAlignmentSamples: session.followLatencyDiagnostics.alignmentSampleCount
                    ) else {
                        observationState.ledger.recordMissingObservation()
                        return
                    }
                    let itemID: String
                    let isPreview: Bool
                    switch envelope.payload {
                    case .partialSnapshot(let id, _, _, _):
                        itemID = id
                        isPreview = true
                    case .partial(let id, _):
                        // Check delta positions for overshoot, but only explicit
                        // snapshots prove the required same-item revisions.
                        itemID = id
                        isPreview = false
                    case .completed(let id, _):
                        itemID = id
                        isPreview = false
                    default:
                        return
                    }
                    observationState.ledger.record(
                        expectedAlignmentEvents: expectedCount,
                        itemID: itemID,
                        isPreview: isPreview,
                        position: scriptPosition(for: session, sourceText: referenceText),
                        sourceSampleWatermark: watermark,
                        expectedPrefixRanges: configuration.teleprompterExpectedPrefixRanges
                    )
                }
            )
            clientHandle.install(client)
            return client
        }
        storage.coordinator.starter = { kind in
            guard kind == .teleprompter else { return }
            try await session.beginCapture()
        }
        storage.coordinator.stopper = { kind in
            guard kind == .teleprompter else { return }
            await session.stopCapture()
        }
        session.createDocument(title: "ASR session replay", sourceText: referenceText)
        await session.beginFollowing()
        guard await waitUntil({ session.phase == .following }) else {
            throw SessionReplayFailure.sessionDidNotStart
        }

        await recorder.markAudioStarted(at: ContinuousClock().now)
        let selectedEvidence = try await feedUntilTeleprompterPreviewProgress(
            pcm,
            to: source,
            recorder: recorder,
            session: session,
            observationState: observationState,
            sourceText: referenceText,
            expectedPrefixRanges: configuration.teleprompterExpectedPrefixRanges
        )
        let beforeTakeoverSnapshot = await recorder.snapshot()
        let positionBeforeTakeover = scriptPosition(for: session, sourceText: referenceText)
        let feedEvidence = observationState.ledger.feedEvidence(itemID: selectedEvidence.itemID)
        let allEventsObserved = beforeTakeoverSnapshot.recordedAlignmentEventCount
            == observationState.ledger.observedAlignmentEvents
            && SessionReplayTeleprompterProcessingIntegrity.caughtUp(
                receivedAlignmentEvents: beforeTakeoverSnapshot.recordedAlignmentEventCount,
                processedAlignmentSamples: session.followLatencyDiagnostics.alignmentSampleCount
            )
            && beforeTakeoverSnapshot.latestPreviewItemID == selectedEvidence.itemID
        let noFinalAtManualTakeover = SessionReplayTeleprompterProcessingIntegrity.hasUnfinalizedPreview(
            itemID: feedEvidence.itemID,
            firstPreviewOrders: beforeTakeoverSnapshot.firstPreviewOrderByItem,
            terminalCounts: beforeTakeoverSnapshot.terminalCounts
        )
        let diagnostics = SessionReplayTeleprompterProcessingDiagnostics(
            receivedAlignmentEvents: beforeTakeoverSnapshot.recordedAlignmentEventCount,
            processedAlignmentSamples: session.followLatencyDiagnostics.alignmentSampleCount,
            partialTextCodepoints: session.partialText?.unicodeScalars.count ?? 0,
            uncertainty: session.uncertainty.flatMap { $0.isFinite ? $0 : nil },
            earlierTerminalCount: beforeTakeoverSnapshot.terminalCounts.values.reduce(0, +),
            allObservedPrefixesWithinGold: feedEvidence.allObservedPrefixesWithinGold,
            observedAlignmentEvents: observationState.ledger.observedAlignmentEvents
        )
        observationState.isEnabled = false
        session.takeOverForManualScroll()
        let positionAtTakeover = scriptPosition(for: session, sourceText: referenceText)
        await recorder.recordTeleprompterProcessingDiagnostics(diagnostics)
        await session.disableVoiceAssist()
        let positionAfterStop = scriptPosition(for: session, sourceText: referenceText)
        let previewBeforeFinal = noFinalAtManualTakeover
        let evidence = SessionReplayTeleprompterProgressEvidence(
            maximumSameItemRevisionCount: feedEvidence.sameItemRevisionCount,
            observedDisplayPrefixOffsetsUTF16: feedEvidence.observedDisplayPrefixOffsetsUTF16,
            observedSourcePrefixOffsetsUTF16: feedEvidence.observedSourcePrefixOffsetsUTF16,
            observedSourceSampleWatermarks: feedEvidence.observedSourceSampleWatermarks,
            expectedDisplayScriptUTF16Length: positionAtTakeover?.expectedDisplayScriptUTF16Length ?? 0,
            expectedSourceUTF16Length: referenceText.utf16.count,
            manualDisplayPrefixOffsetUTF16: positionAfterStop?.displayPrefixOffsetUTF16,
            manualSourcePrefixOffsetUTF16: positionAfterStop?.sourcePrefixOffsetUTF16,
            manualSourceSampleWatermark: beforeTakeoverSnapshot.sourceSamplesYielded,
            expectedPrefixRanges: configuration.teleprompterExpectedPrefixRanges,
            revisionsMonotonic: beforeTakeoverSnapshot.previewRevisionRegressionCount == 0,
            noFinalAtManualTakeover: noFinalAtManualTakeover,
            previewBeforeFinal: previewBeforeFinal,
            manualPositionStable: positionBeforeTakeover != nil
                && positionBeforeTakeover == positionAtTakeover
                && positionAtTakeover == positionAfterStop
                && session.phase == .manual,
            allObservedPrefixesWithinGold: feedEvidence.allObservedPrefixesWithinGold && allEventsObserved
        )
        await recorder.recordTeleprompterProgressEvidence(evidence)
        return SessionReplayTeleprompterProgressIntegrity.validate(evidence) ? "pass" : "fail"
    }

    private func feedPaced(
        _ pcm: Data,
        to source: SessionReplayCaptureSource,
        recorder: SessionReplayRecorder,
        markAudioStart: Bool = true
    ) async throws {
        if markAudioStart { await recorder.markAudioStarted(at: ContinuousClock().now) }
        let chunkBytes = 960 * MemoryLayout<Int16>.size
        let clock = ContinuousClock()
        var deadline = clock.now
        var sequenceNumber = 0
        for offset in stride(from: 0, to: pcm.count, by: chunkBytes) {
            let end = min(offset + chunkBytes, pcm.count)
            let chunk = AudioChunk(
                pcm: pcm.subdata(in: offset..<end),
                level: 0.25,
                sequenceNumber: sequenceNumber,
                droppedSamplesBefore: 0
            )
            guard source.yield(chunk) else { throw SessionReplayFailure.captureBufferOverflow }
            await recorder.recordSourcePCM(chunk.pcm, sentAt: clock.now)
            sequenceNumber += 1
            deadline = deadline.advanced(by: .milliseconds(40))
            try await clock.sleep(until: deadline, tolerance: .milliseconds(8))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(120),
        _ predicate: @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard !Task.isCancelled else { return false }
            if await predicate() { return true }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        guard !Task.isCancelled else { return false }
        return await predicate()
    }

    private func feedUntilTeleprompterPreviewProgress(
        _ pcm: Data,
        to source: SessionReplayCaptureSource,
        recorder: SessionReplayRecorder,
        session: TeleprompterSession,
        observationState: SessionReplayTeleprompterObservationState,
        sourceText: String,
        expectedPrefixRanges: [SessionReplayExpectedPrefixRange]?
    ) async throws -> SessionReplayTeleprompterFeedEvidence {
        let chunkBytes = 960 * MemoryLayout<Int16>.size
        let clock = ContinuousClock()
        var deadline = clock.now
        var sequenceNumber = 0
        for offset in stride(from: 0, to: pcm.count, by: chunkBytes) {
            let end = min(offset + chunkBytes, pcm.count)
            let chunk = AudioChunk(
                pcm: pcm.subdata(in: offset..<end),
                level: 0.25,
                sequenceNumber: sequenceNumber,
                droppedSamplesBefore: 0
            )
            guard source.yield(chunk) else { throw SessionReplayFailure.captureBufferOverflow }
            await recorder.recordSourcePCM(chunk.pcm, sentAt: clock.now)
            sequenceNumber += 1
            deadline = deadline.advanced(by: .milliseconds(40))
            try await clock.sleep(until: deadline, tolerance: .milliseconds(8))

            let snapshot = await recorder.snapshot()
            // A stream yield only proves enqueueing. The existing bounded
            // Session alignment diagnostics advance after handle/sync finishes.
            guard SessionReplayTeleprompterProcessingIntegrity.caughtUp(
                receivedAlignmentEvents: snapshot.recordedAlignmentEventCount,
                processedAlignmentSamples: session.followLatencyDiagnostics.alignmentSampleCount
            ) else { continue }
            if observationState.ledger.observedAlignmentEvents == snapshot.recordedAlignmentEventCount,
               let position = scriptPosition(for: session, sourceText: sourceText) {
                let itemID = observationState.ledger.latestPreviewItemID
                let evidence = observationState.ledger.feedEvidence(itemID: itemID)
                if SessionReplayTeleprompterProcessingIntegrity.hasUnfinalizedPreview(
                    itemID: itemID,
                    firstPreviewOrders: snapshot.firstPreviewOrderByItem,
                    terminalCounts: snapshot.terminalCounts
                ) && SessionReplayTeleprompterFeedIntegrity.validate(
                    evidence,
                    expectedDisplayScriptUTF16Length: position.expectedDisplayScriptUTF16Length,
                    expectedSourceUTF16Length: sourceText.utf16.count,
                    expectedPrefixRanges: expectedPrefixRanges
                ) {
                    return evidence
                }
            }
        }
        return observationState.ledger.feedEvidence(itemID: observationState.ledger.latestPreviewItemID)
    }

    private func scriptPosition(
        for session: TeleprompterSession,
        sourceText: String
    ) -> SessionReplayScriptPosition? {
        guard let segments = session.activeVersion?.segments,
              !segments.isEmpty,
              segments.indices.contains(session.currentSegmentIndex) else {
            return nil
        }
        let segmentLengths = segments.map { $0.text.utf16.count }
        let segmentOffset = session.readingOffset
        guard segmentOffset >= 0,
              segmentOffset <= segmentLengths[session.currentSegmentIndex] else {
            return nil
        }
        let currentSegment = segments[session.currentSegmentIndex]
        guard let sourcePrefixOffset = SessionReplayScriptSourcePosition.prefixOffset(
            sourceRange: currentSegment.sourceRange,
            segmentUTF16Length: segmentLengths[session.currentSegmentIndex],
            segmentOffsetUTF16: segmentOffset,
            sourceUTF16Length: sourceText.utf16.count
        ) else {
            return nil
        }
        let separatorsBefore = session.currentSegmentIndex * 2
        let precedingTextLength = segmentLengths.prefix(session.currentSegmentIndex).reduce(0, +)
        let expectedLength = segmentLengths.reduce(0, +) + max(0, segmentLengths.count - 1) * 2
        return SessionReplayScriptPosition(
            segmentIndex: session.currentSegmentIndex,
            segmentOffsetUTF16: segmentOffset,
            displayPrefixOffsetUTF16: precedingTextLength + separatorsBefore + segmentOffset,
            sourcePrefixOffsetUTF16: sourcePrefixOffset,
            expectedDisplayScriptUTF16Length: expectedLength
        )
    }
}
