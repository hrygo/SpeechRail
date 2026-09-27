import XCTest
import SpeechRailControlKit

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// Issue #88: 模型下载取消链缺少代际守卫。
///
/// 复现完全用注入的 `ClosureControlTransport` 闭包驱动真实 `AppModel` 状态机，
/// 不新增任何 mock 类型：脚本化响应由一个小 actor 提供，伪造诊断客户端只负责
/// 满足 `AppModel.init` 的必填依赖（这些用例根本不走服务 HTTP）。
@MainActor
final class AppModelTests: XCTestCase {
    func testCapabilityFacadeFailsClosedWhenSnapshotIsStale() {
        let facade = AppCapabilityFacade(
            snapshot: Self.capabilitySnapshot(
                previewStatus: "supported",
                transcriptionStatus: "supported"
            ),
            discoveryState: .failed
        )

        XCTAssertEqual(facade.voiceDesignCreationAvailability, .unavailable)
        XCTAssertEqual(facade.voiceCloneAvailability, .unavailable)
        XCTAssertNil(facade.speechRequestOptions(for: "voice-1"))
    }

    func testCapabilityFacadeDistinguishesUnknownFromUnsupportedOperations() {
        let unsupported = AppCapabilityFacade(
            snapshot: Self.capabilitySnapshot(
                previewStatus: "unsupported",
                transcriptionStatus: "supported"
            ),
            discoveryState: .loaded
        )
        let unknown = AppCapabilityFacade(
            snapshot: Self.capabilitySnapshot(
                previewStatus: nil,
                transcriptionStatus: "supported"
            ),
            discoveryState: .loaded
        )

        XCTAssertEqual(unsupported.voiceDesignCreationAvailability, .unsupported)
        XCTAssertEqual(unknown.voiceDesignCreationAvailability, .unknown)
    }

    func testRealtimeBindingUsesASRAndSelectedVoiceModelRevisions() {
        let voice = SafeVoiceEntry(
            id: "voice-1",
            name: "测试音色",
            aliases: ["test-voice"],
            mode: "design",
            available: true,
            availabilityReason: .available,
            voiceRevision: "vr_11111111111111111111111111111111",
            voiceIdentityAssurance: .contentAddressed,
            model: ConfiguredModelIdentity(
                assurance: .configuredCatalog,
                artifact: "voice-base",
                catalogRevision: "voice-model-catalog"
            ),
            descriptors: SafeVoiceDescriptor(
                voiceMode: "instruction",
                locales: [],
                styleTags: [],
                pitchBand: "unknown",
                timbreFamily: "unknown",
                baselinePace: "unknown",
                sourceType: "instruction_profile",
                metadataMethod: "declared_only"
            ),
            operations: [
                "realtime_speech": JSONValue(.object([
                    "parameters": JSONValue(.object([
                        "instructions": JSONValue(.object([
                            "status": JSONValue(.string("unsupported"))
                        ]))
                    ])),
                    "output": JSONValue(.object([
                        "codecs": JSONValue(.array([JSONValue(.string("pcm16"))])),
                        "pcm_sample_rate": JSONValue(.integer(24_000)),
                        "channels": JSONValue(.integer(1))
                    ])),
                    "scheduling_class": JSONValue(.string("realtime_tts")),
                    "terminal_evidence": JSONValue(.string("speechrail.tts.completed"))
                ]))
            ]
        )
        let snapshot = EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "snapshot-catalog",
            snapshotID: "snapshot-1",
            profile: "quality",
            models: [
                "asr": ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    artifact: "asr",
                    catalogRevision: "asr-model-catalog"
                ),
                "tts": ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    artifact: "global-tts",
                    catalogRevision: "global-tts-catalog"
                ),
            ],
            voices: [voice],
            operations: [
                "realtime_transcription": JSONValue(.object([
                    "status": JSONValue(.string("supported"))
                ]))
            ],
            guarantees: [:]
        )
        let facade = AppCapabilityFacade(snapshot: snapshot, discoveryState: .loaded)

        XCTAssertEqual(
            facade.availability(ofVoiceOperation: "realtime_speech", voiceID: "test-voice"),
            .available
        )
        XCTAssertEqual(
            facade.realtimeBinding(for: "test-voice"),
            RealtimeCapabilityBinding(
                asrModelRevision: "asr-model-catalog",
                canonicalVoiceID: "voice-1",
                voiceRevision: "vr_11111111111111111111111111111111",
                ttsModelRevision: "voice-model-catalog"
            )
        )
        XCTAssertEqual(
            facade.realtimeBinding(),
            RealtimeCapabilityBinding(asrModelRevision: "asr-model-catalog")
        )
    }

    func testPreviewLanguageMapsVoicesToServiceLanguageNames() {
        XCTAssertEqual(AppModel.previewLanguage(forVoiceID: "ryan"), .english)
        XCTAssertEqual(AppModel.previewLanguage(forVoiceID: "aiden"), .english)
        XCTAssertEqual(AppModel.previewLanguage(forVoiceID: "ono_anna"), .japanese)
        XCTAssertEqual(AppModel.previewLanguage(forVoiceID: "sohee"), .korean)
        XCTAssertEqual(AppModel.previewLanguage(forVoiceID: "serena"), .chinese)
        XCTAssertEqual(AppModel.previewLanguage(forVoiceID: "some_custom_voice"), .chinese)
    }

    func testDefaultPreviewTextMatchesVoiceLanguage() {
        let english = AppModel.defaultPreviewText(forVoiceID: "ryan")
        XCTAssertTrue(english.contains("SpeechRail voice preview"), "english voice gets english text: \(english)")
        let japanese = AppModel.defaultPreviewText(forVoiceID: "ono_anna")
        XCTAssertFalse(japanese.contains("这是"), "japanese voice must not get chinese text")
        let chinese = AppModel.defaultPreviewText(forVoiceID: "serena")
        XCTAssertTrue(chinese.contains("音色试听"), "chinese voice keeps chinese text")
    }

    func testPendingCloneRegistrationKeepsOriginalPayloadAndBlocksRerecording() async throws {
        let creator = PendingCloneRegistrationClient()
        let model = makeModel(
            transport: ClosureControlTransport { request in
                ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            },
            creatorClient: creator
        )
        let firstAudio = Data([1, 2, 3, 4])
        let firstRecording = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try firstAudio.write(to: firstRecording)

        await model.acceptCloneRecording(fileAt: firstRecording)
        let originalRegistrationID = try XCTUnwrap(model.cloneRegistrationID)
        let originalIdempotencyKey = try XCTUnwrap(model.cloneIdempotencyKey)

        let result = await model.registerCloneVoice(
            referenceText: "这是一段用于注册音色的测试朗读文本。",
            name: "测试音色"
        )

        XCTAssertNil(result)
        let queriedKeys = await creator.statusKeys()
        let registrationCount = await creator.registrationCount()
        XCTAssertEqual(queriedKeys, [originalIdempotencyKey])
        XCTAssertEqual(registrationCount, 0)

        let replacementRecording = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data([9, 8, 7, 6]).write(to: replacementRecording)
        await model.acceptCloneRecording(fileAt: replacementRecording)

        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementRecording.path))
        XCTAssertEqual(model.cloneRecordingAudio, firstAudio)
        XCTAssertEqual(model.cloneRegistrationID, originalRegistrationID)
        XCTAssertEqual(model.cloneIdempotencyKey, originalIdempotencyKey)
        XCTAssertFalse(model.discardCloneRecording())
    }

    func testVoiceDesignCannotReviewOrPublishBeforeHearingDurableAudio() async {
        let creator = VoiceDesignWorkflowCreatorClient()
        let model = makeModel(
            transport: ClosureControlTransport { request in
                ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            },
            creatorClient: creator
        )
        let preview = VoiceDesignCandidateSnapshot(
            slot: "1",
            seed: 101,
            title: "候选 1",
            instructionSnapshot: "温暖、清晰、自然",
            referenceTextSnapshot: "这是一段用于耐久候选复核的测试参考文案。",
            status: .ready,
            audioData: Data([0, 1, 2])
        )

        model.startVoiceDesignPublication(preview, name: "测试音色")
        await waitForVoiceDesignPhase(.awaitingReferenceReview, model: model)

        var events = await creator.events()
        XCTAssertEqual(events, ["create", "candidate.get", "reference.audio"])
        model.confirmVoiceDesignReference()
        events = await creator.events()
        XCTAssertEqual(events, ["create", "candidate.get", "reference.audio"])

        model.markVoiceDesignReferenceAudioPlaybackFinished(successfully: true)
        model.confirmVoiceDesignReference()
        await waitForVoiceDesignPhase(.awaitingValidationReview, model: model)

        events = await creator.events()
        XCTAssertEqual(
            events,
            [
                "create",
                "candidate.get",
                "reference.audio",
                "confirm",
                "candidate.get",
                "validate",
                "candidate.get",
                "validation.audio",
            ]
        )
        model.publishVoiceDesignPublication(
            identityConfirmed: true,
            naturalnessConfirmed: true
        )
        events = await creator.events()
        XCTAssertFalse(events.contains("review"))
        XCTAssertFalse(events.contains("publish"))

        model.markVoiceDesignValidationAudioPlaybackFinished(successfully: true)
        model.publishVoiceDesignPublication(
            identityConfirmed: true,
            naturalnessConfirmed: true
        )
        await waitForVoiceDesignPhase(.published, model: model)
        events = await creator.events()
        XCTAssertEqual(events.suffix(3), ["review", "candidate.get", "publish"])
    }

    func testFailedVoiceDesignCancellationRetainsCandidateForRetry() async {
        let creator = VoiceDesignWorkflowCreatorClient()
        let model = makeModel(
            transport: ClosureControlTransport { request in
                ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            },
            creatorClient: creator
        )
        let preview = VoiceDesignCandidateSnapshot(
            slot: "1",
            seed: 101,
            title: "候选 1",
            instructionSnapshot: "温暖、清晰、自然",
            referenceTextSnapshot: "这是一段用于验证取消重试的测试参考文案。",
            status: .ready,
            audioData: Data([1, 2, 3])
        )
        model.startVoiceDesignPublication(preview, name: "可重试取消")
        await waitForVoiceDesignPhase(.awaitingReferenceReview, model: model)
        let candidateID = model.voiceDesignPublication.candidateID
        await creator.failNextCandidateCancel()

        model.cancelVoiceDesignPublication()
        await waitForVoiceDesignPhase(.failed, model: model)

        XCTAssertEqual(model.voiceDesignPublication.candidateID, candidateID)
        var events = await creator.events()
        XCTAssertEqual(events.filter { $0 == "cancel" }.count, 1)

        model.retryVoiceDesignPublication()
        await waitForVoiceDesignPhase(.idle, model: model)

        XCTAssertNil(model.voiceDesignPublication.candidateID)
        events = await creator.events()
        XCTAssertEqual(events.filter { $0 == "cancel" }.count, 2)
    }

    func testUnknownVoiceDesignCandidateStateBlocksReviewOperations() async {
        let creator = VoiceDesignWorkflowCreatorClient()
        let model = makeModel(
            transport: ClosureControlTransport { request in
                ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            },
            creatorClient: creator
        )
        await creator.setNextCandidateState("future_state")
        let preview = VoiceDesignCandidateSnapshot(
            slot: "1",
            seed: 101,
            title: "候选 1",
            instructionSnapshot: "温暖、清晰、自然",
            referenceTextSnapshot: "这是一段用于验证未知候选状态的测试参考文案。",
            status: .ready,
            audioData: Data([1, 2, 3])
        )

        model.startVoiceDesignPublication(preview, name: "未知状态")
        await waitForVoiceDesignPhase(.failed, model: model)

        XCTAssertEqual(model.voiceDesignPublication.candidateID, "vd_0123456789abcdef01234567")
        let events = await creator.events()
        XCTAssertFalse(events.contains("reference.audio"))
        XCTAssertFalse(events.contains("validate"))
    }

    func testLatePublishedResultDoesNotOverwriteNewPublicationGeneration() async {
        let creator = VoiceDesignWorkflowCreatorClient()
        let model = makeModel(
            transport: ClosureControlTransport { request in
                ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            },
            creatorClient: creator
        )
        let firstPreview = VoiceDesignCandidateSnapshot(
            slot: "1",
            seed: 101,
            title: "候选 1",
            instructionSnapshot: "温暖、清晰、自然",
            referenceTextSnapshot: "这是一段用于检查迟到发布结果的测试参考文案。",
            status: .ready,
            audioData: Data([0, 1, 2])
        )
        model.startVoiceDesignPublication(firstPreview, name: "第一版音色")
        await waitForVoiceDesignPhase(.awaitingReferenceReview, model: model)
        model.markVoiceDesignReferenceAudioPlaybackFinished(successfully: true)
        model.confirmVoiceDesignReference()
        await waitForVoiceDesignPhase(.awaitingValidationReview, model: model)
        model.markVoiceDesignValidationAudioPlaybackFinished(successfully: true)

        await creator.holdNextPublication()
        model.publishVoiceDesignPublication(
            identityConfirmed: true,
            naturalnessConfirmed: true
        )
        await waitForCreatorEvent("publish", creator: creator)
        model.cancelVoiceDesignPublication()
        await waitForVoiceDesignPhase(.published, model: model)
        for _ in 0..<200 where model.isRegisteringVoice {
            await Task.yield()
        }

        let secondPreview = VoiceDesignCandidateSnapshot(
            slot: "2",
            seed: 202,
            title: "候选 2",
            instructionSnapshot: "稳重、明亮、自然",
            referenceTextSnapshot: "这是一段用于检查新发布流程仍可继续的测试参考文案。",
            status: .ready,
            audioData: Data([3, 4, 5])
        )
        model.startVoiceDesignPublication(secondPreview, name: "第二版音色")
        await waitForVoiceDesignPhase(.awaitingReferenceReview, model: model)

        await creator.releaseHeldPublication()
        for _ in 0..<200 {
            await Task.yield()
        }

        XCTAssertEqual(model.voiceDesignPublication.phase, .awaitingReferenceReview)
        XCTAssertEqual(model.voiceDesignPublication.candidateID, "vd_0123456789abcdef01234567")
        XCTAssertEqual(model.voiceDesignSavingSlot, "2")
        XCTAssertTrue(model.voiceDesignSavedSlots.contains("1"))
        XCTAssertNil(model.voiceDesignSuccessMessage)

        model.markVoiceDesignReferenceAudioPlaybackFinished(successfully: true)
        model.confirmVoiceDesignReference()
        await waitForVoiceDesignPhase(.awaitingValidationReview, model: model)
    }

    private func waitForVoiceDesignPhase(
        _ expected: VoiceDesignPublicationPhase,
        model: AppModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if model.voiceDesignPublication.phase == expected {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "音色发布阶段未到达 \(expected)，当前为 \(model.voiceDesignPublication.phase)",
            file: file,
            line: line
        )
    }

    private func waitForCreatorEvent(
        _ expected: String,
        creator: VoiceDesignWorkflowCreatorClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await creator.events().contains(expected) {
                return
            }
            await Task.yield()
        }
        XCTFail("服务端 fake 没有收到 \(expected)", file: file, line: line)
    }

    private static func capabilitySnapshot(
        previewStatus: String?,
        transcriptionStatus: String?
    ) -> EffectiveCapabilitySnapshot {
        var operations: [String: JSONValue] = [:]
        if let previewStatus {
            operations["voice_preview"] = JSONValue(.object([
                "status": JSONValue(.string(previewStatus))
            ]))
        }
        if let transcriptionStatus {
            operations["transcription"] = JSONValue(.object([
                "status": JSONValue(.string(transcriptionStatus))
            ]))
        }
        return EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "snapshot-catalog",
            snapshotID: "snapshot-1",
            profile: "quality",
            models: [
                "tts_clone": ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    artifact: "clone-base",
                    catalogRevision: "clone-model-revision"
                )
            ],
            voices: [],
            operations: operations,
            guarantees: [:]
        )
    }

    // MARK: - (i) 过期 cancel→refresh 链不得覆盖更新的终态

    func testStaleCancelChainCannotOverwriteNewerTerminalRefresh() async {
        let statusScript = ModelStatusScript(schedule: .activeThenCommittedThenNil)
        let supersede = CancelSupersession()
        let transport = ClosureControlTransport { request in
            switch request.command {
            case .modelCatalog:
                return Self.modelCatalogResponse(for: request)
            case .modelStatus:
                return await statusScript.next(for: request)
            case .operationCancel:
                // 取消请求还在传输层时，界面上又发起了一次更新的模型读取。
                // 这条更新的刷新会 bump 代数——旧取消链必须据此自认过期。
                await supersede.fire()
                return Self.cancellingResponse(for: request)
            case .operationStatus:
                return Self.cancelledOperationResponse(for: request)
            default:
                return ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            }
        }

        let model = makeModel(transport: transport)
        await supersede.install { await model.refreshModels() }

        // 先让一个 model-prepare 操作处于活动态。
        await model.refreshModels()
        XCTAssertTrue(
            model.hasActiveMutation,
            "前置条件不成立：模型准备操作应当是活动态（operation=\(String(describing: model.operation))）"
        )

        await model.cancelCurrentOperation()

        XCTAssertEqual(
            model.operation?.state,
            .committed,
            "过期的 cancel→refresh 链把更新的终态覆盖回了过期操作（实际 operation=\(String(describing: model.operation))）。issue #88 要求 superseded 的取消链不得再落地状态。"
        )
        XCTAssertEqual(
            model.message,
            "模型准备已完成",
            "过期的 cancel→refresh 链用旧文案覆盖了更新刷新写下的终态消息（实际 message=\(String(describing: model.message))）。"
        )
    }

    // MARK: - (ii) 取消确认缺少 cancelling 相位时不得挂在待定文案上

    func testCancelAcknowledgementWithoutPhaseDoesNotStrandPendingMessage() async {
        // 精确复现修复前的 `UITestControlTransport` 对 `.operationCancel` 的默认响应：
        // status .completed、没有 operation、没有 cancelling 相位。
        let statusScript = ModelStatusScript(schedule: .activeThenNil)
        let transport = ClosureControlTransport { request in
            switch request.command {
            case .modelCatalog:
                return Self.modelCatalogResponse(for: request)
            case .modelStatus:
                return await statusScript.next(for: request)
            case .operationCancel:
                return ControlResponse(
                    requestID: request.requestID,
                    command: .operationCancel,
                    status: .completed
                )
            default:
                return ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            }
        }

        let model = makeModel(transport: transport)
        await model.refreshModels()
        XCTAssertTrue(
            model.hasActiveMutation,
            "前置条件不成立：模型准备操作应当是活动态（operation=\(String(describing: model.operation))）"
        )

        await model.cancelCurrentOperation()

        XCTAssertNil(
            model.message,
            "取消确认没有 cancelling 相位时，界面仍停在「正在停止模型准备…」的悬挂文案上（实际 message=\(String(describing: model.message))）。issue #88 要求取消链刷新一次，让服务状态成为唯一事实来源。"
        )
    }

    // MARK: - (iii) 更旧的模型刷新不得覆盖并发更新的刷新（issue #87）

    func testNewerConcurrentModelRefreshWinsOverOlderInFlightRefresh() async {
        let race = ConcurrentRefreshRace()
        let transport = ClosureControlTransport { request in
            switch request.command {
            case .modelCatalog:
                return await race.catalog(for: request)
            case .modelStatus:
                return await race.status(for: request)
            default:
                return ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            }
        }

        let model = makeModel(transport: transport)
        // 第一次刷新会在 modelStatus 处被拦下；拦截点内再发起一次更新的刷新，
        // 并让更新的刷新先返回，从而确定性地制造「旧读取后到」的竞争。
        await race.install { await model.refreshModels() }
        await model.refreshModels()

        XCTAssertEqual(
            model.modelStatus?.disk.modelBytes,
            ConcurrentRefreshRace.freshMarker,
            "更旧的并发刷新用过期结果覆盖了更新的刷新（实际 modelBytes=\(String(describing: model.modelStatus?.disk.modelBytes))）。issue #87 要求 generation 守卫让最新一次刷新胜出。"
        )
    }

    // MARK: - (iv) 过期取消链写下的旧文案不得挺过更新的刷新（issue #87）

    func testSupersededCancelMessageDoesNotSurviveNewerModelRefresh() async {
        let statusScript = ModelStatusScript(schedule: .activeThenNil)
        let supersede = CancelSupersession()
        let transport = ClosureControlTransport { request in
            switch request.command {
            case .modelCatalog:
                return Self.modelCatalogResponse(for: request)
            case .modelStatus:
                return await statusScript.next(for: request)
            case .operationCancel:
                // 取消请求还在传输层时，界面又发起并完成了一次更新的模型刷新；
                // 随后取消请求以失败收场——这条过期链不得再写入旧文案。
                await supersede.fire()
                throw CancelTransportFailure()
            default:
                return ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            }
        }

        let model = makeModel(transport: transport)
        await supersede.install { await model.refreshModels() }
        await model.refreshModels()
        XCTAssertTrue(
            model.hasActiveMutation,
            "前置条件不成立：模型准备操作应当是活动态（operation=\(String(describing: model.operation))）"
        )

        await model.cancelCurrentOperation()

        XCTAssertNil(
            model.message,
            "过期取消链在更新的刷新之后写下的旧文案仍然存活（实际 message=\(String(describing: model.message))）。issue #87 要求 message 有 generation token：过期链的写入必须被丢弃。"
        )
    }

    // MARK: - Helpers

    private func makeModel(
        transport: any SpeechRailControlTransport,
        creatorClient: any SpeechRailCreatorClient = UnavailableCreatorClient()
    ) -> AppModel {
        AppModel(
            transport: transport,
            apiClient: UnavailableDiagnosticsClient(),
            creatorClient: creatorClient
        )
    }

    nonisolated private static func modelCatalogResponse(for request: ControlRequest) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: .modelCatalog,
            status: .ok,
            modelCatalog: ModelCatalogSnapshot(artifacts: [], profiles: [])
        )
    }

    nonisolated private static func cancellingResponse(for request: ControlRequest) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: .operationCancel,
            status: .running,
            message: "stopping model preparation",
            operation: OperationSnapshot(
                operationID: request.operationID ?? "op-1",
                command: .modelPrepare,
                state: .running,
                phase: "cancelling",
                message: "stopping model preparation"
            )
        )
    }

    nonisolated private static func cancelledOperationResponse(for request: ControlRequest) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: .operationStatus,
            status: .failed,
            errorCode: .cancelled,
            operation: OperationSnapshot(
                operationID: "op-1",
                command: .modelPrepare,
                state: .cancelled,
                phase: "cancelled",
                errorCode: .cancelled,
                message: "model preparation was cancelled"
            )
        )
    }
}

/// `AppModel.init` 必填的诊断客户端。这些用例只跑控制平面状态机，
/// 从不触发服务 HTTP，因此读取一律失败即可。
private struct UnavailableDiagnosticsClient: ServiceDiagnosticsClient {
    var port: Int? { nil }

    func fetchHealthSnapshot() async throws -> HealthSnapshot {
        throw ServiceAPIClientError.requestFailed
    }

    func fetchMetrics() async throws -> RuntimeMetricsSnapshot {
        throw ServiceAPIClientError.requestFailed
    }
}

private actor PendingCloneRegistrationClient: SpeechRailCreatorClient {
    private var queriedKeys: [String] = []
    private var registrations = 0

    func fetchVoices() async throws -> [CreatorVoice] { [] }

    func fetchVoice(id: String) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions,
        language: String? = nil
    ) async throws -> Data {
        throw ServiceAPIClientError.requestFailed
    }

    func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        throw ServiceAPIClientError.requestFailed
    }

    func fetchCloneIdempotencyStatus(
        idempotencyKey: String
    ) async throws -> CloneIdempotencyStatus {
        queriedKeys.append(idempotencyKey)
        return CloneIdempotencyStatus(state: .pending, resultID: nil)
    }

    func fetchClonePrompts() async throws -> [ClonePrompt] { [] }

    func validateVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?
    ) async throws -> VoiceQualityReportSnapshot {
        throw ServiceAPIClientError.requestFailed
    }

    func registerVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?,
        idempotencyKey: String?
    ) async throws -> CreatorVoice {
        registrations += 1
        throw ServiceAPIClientError.requestFailed
    }

    func deleteVoice(id: String) async throws {}

    func statusKeys() -> [String] { queriedKeys }

    func registrationCount() -> Int { registrations }
}

private actor VoiceDesignWorkflowCreatorClient: SpeechRailCreatorClient {
    private var currentCandidate: VoiceDesignCandidate?
    private var recordedEvents: [String] = []
    private let candidateID = "vd_0123456789abcdef01234567"
    private let candidateRevision = "vr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let validationID = "vv_0123456789abcdef01234567"
    private var shouldHoldNextPublication = false
    private var shouldFailNextCandidateCancel = false
    private var heldPublication: CheckedContinuation<VoiceDesignPublishResult, Error>?
    private var heldPublicationResult: VoiceDesignPublishResult?
    private var nextCandidateState = "generated"

    func events() -> [String] { recordedEvents }

    func holdNextPublication() {
        shouldHoldNextPublication = true
    }

    func failNextCandidateCancel() {
        shouldFailNextCandidateCancel = true
    }

    func setNextCandidateState(_ state: String) {
        nextCandidateState = state
    }

    func releaseHeldPublication() {
        guard let heldPublication, let heldPublicationResult else { return }
        self.heldPublication = nil
        self.heldPublicationResult = nil
        heldPublication.resume(returning: heldPublicationResult)
    }

    func fetchVoices() async throws -> [CreatorVoice] { [] }

    func fetchVoice(id: String) async throws -> CreatorVoice {
        CreatorVoice(
            id: id,
            name: "测试音色",
            available: true,
            revision: candidateRevision
        )
    }

    func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions,
        language: String? = nil
    ) async throws -> Data {
        throw ServiceAPIClientError.requestFailed
    }

    func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        throw ServiceAPIClientError.requestFailed
    }

    func createVoiceDesignCandidate(
        voiceID: String,
        name: String,
        instruction: String,
        referenceText: String,
        seed: Int,
        idempotencyKey: String?
    ) async throws -> VoiceDesignCandidate {
        recordedEvents.append("create")
        let candidate = makeCandidate(
            voiceID: voiceID,
            name: name,
            state: nextCandidateState,
            validations: [],
            publishable: false
        )
        nextCandidateState = "generated"
        currentCandidate = candidate
        return candidate
    }

    func fetchVoiceDesignCandidate(id: String) async throws -> VoiceDesignCandidate {
        recordedEvents.append("candidate.get")
        guard let currentCandidate, currentCandidate.id == id else {
            throw ServiceAPIClientError.requestFailed
        }
        return currentCandidate
    }

    func fetchVoiceDesignReferenceAudio(
        id: String,
        expectedRevision: String
    ) async throws -> Data {
        recordedEvents.append("reference.audio")
        guard let currentCandidate,
              currentCandidate.id == id,
              currentCandidate.revision == expectedRevision
        else {
            throw ServiceAPIClientError.requestFailed
        }
        return Data([4, 5, 6])
    }

    func fetchVoiceDesignValidationAudio(
        id: String,
        validationID: String,
        expectedRevision: String
    ) async throws -> Data {
        recordedEvents.append("validation.audio")
        guard let currentCandidate,
              currentCandidate.id == id,
              currentCandidate.revision == expectedRevision,
              currentCandidate.latestValidation?.validationID == validationID
        else {
            throw ServiceAPIClientError.requestFailed
        }
        return Data([7, 8, 9])
    }

    func confirmVoiceDesignCandidate(
        id: String,
        referenceText: String?
    ) async throws -> VoiceDesignCandidate {
        recordedEvents.append("confirm")
        guard let existingCandidate = currentCandidate else {
            throw ServiceAPIClientError.requestFailed
        }
        let confirmed = makeCandidate(
            voiceID: existingCandidate.targetVoiceID,
            name: existingCandidate.name,
            state: "confirmed",
            validations: [],
            publishable: false
        )
        currentCandidate = confirmed
        return confirmed
    }

    func validateVoiceDesignCandidate(
        id: String,
        testText: String?,
        capabilityKey: String?,
        humanReview: VoiceDesignHumanReview?
    ) async throws -> VoiceDesignCandidate {
        if humanReview == nil {
            recordedEvents.append("validate")
        } else {
            recordedEvents.append("review")
        }
        guard let existingCandidate = currentCandidate else {
            throw ServiceAPIClientError.requestFailed
        }
        let validation = VoiceDesignValidation(
            validationID: validationID,
            candidateRevision: candidateRevision,
            status: humanReview == nil ? "warn" : "pass",
            machineStatus: "pass",
            identityStatus: humanReview?.identity ?? .notReviewed,
            naturalnessStatus: humanReview?.naturalness ?? .notReviewed,
            failureCodes: [],
            capabilityKey: "reference.render",
            modelArtifact: "tts-1.7b-base-bf16",
            modelCatalogRevision: String(repeating: "a", count: 40),
            transcriptMatch: 1.0,
            createdAt: 1,
            updatedAt: 1
        )
        let updated = makeCandidate(
            voiceID: existingCandidate.targetVoiceID,
            name: existingCandidate.name,
            state: humanReview == nil ? "validating" : "publishable",
            validations: [validation],
            publishable: humanReview != nil
        )
        currentCandidate = updated
        return updated
    }

    func publishVoiceDesignCandidate(
        id: String,
        expectedCandidateRevision: String?
    ) async throws -> VoiceDesignPublishResult {
        recordedEvents.append("publish")
        guard let existingCandidate = currentCandidate else {
            throw ServiceAPIClientError.requestFailed
        }
        let voice = CreatorVoice(
            id: existingCandidate.targetVoiceID,
            name: existingCandidate.name,
            available: true,
            revision: candidateRevision
        )
        let published = makeCandidate(
            voiceID: existingCandidate.targetVoiceID,
            name: existingCandidate.name,
            state: "published",
            validations: existingCandidate.validations,
            publishable: true
        )
        currentCandidate = published
        let result = VoiceDesignPublishResult(candidate: published, voice: voice)
        guard shouldHoldNextPublication else { return result }
        shouldHoldNextPublication = false
        return try await withCheckedThrowingContinuation { continuation in
            heldPublication = continuation
            heldPublicationResult = result
        }
    }

    func cancelVoiceDesignCandidate(id: String) async throws -> VoiceDesignCandidate {
        guard let currentCandidate, currentCandidate.id == id else {
            throw ServiceAPIClientError.requestFailed
        }
        recordedEvents.append("cancel")
        if shouldFailNextCandidateCancel {
            shouldFailNextCandidateCancel = false
            throw ServiceAPIClientError.requestFailed
        }
        let cancelled = makeCandidate(
            voiceID: currentCandidate.targetVoiceID,
            name: currentCandidate.name,
            state: "cancelled",
            validations: currentCandidate.validations,
            publishable: false
        )
        self.currentCandidate = cancelled
        return cancelled
    }

    func fetchCloneIdempotencyStatus(
        idempotencyKey: String
    ) async throws -> CloneIdempotencyStatus {
        CloneIdempotencyStatus(state: .new, resultID: nil)
    }

    func fetchClonePrompts() async throws -> [ClonePrompt] { [] }

    func validateVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?
    ) async throws -> VoiceQualityReportSnapshot {
        throw ServiceAPIClientError.requestFailed
    }

    func registerVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?,
        idempotencyKey: String?
    ) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func deleteVoice(id: String) async throws {}

    private func makeCandidate(
        voiceID: String,
        name: String,
        state: String,
        validations: [VoiceDesignValidation],
        publishable: Bool
    ) -> VoiceDesignCandidate {
        VoiceDesignCandidate(
            id: candidateID,
            targetVoiceID: voiceID,
            name: name,
            state: state,
            revision: candidateRevision,
            publishedVoiceRevision: state == "published" ? candidateRevision : nil,
            reference: VoiceDesignReference(
                audioSHA256: String(repeating: "a", count: 64),
                textSHA256: String(repeating: "b", count: 64),
                transcriptSHA256: String(repeating: "c", count: 64),
                durationSeconds: 3
            ),
            validations: validations,
            publishable: publishable
        )
    }
}

/// 按调用次序给出 `modelStatus` 响应的脚本。用 actor 隔离，保证并行测试之间
/// 没有共享可变状态。
private actor ModelStatusScript {
    enum Schedule {
        /// 第一次返回活动操作，其余次返回空活动操作（用于取消确认用例）。
        case activeThenNil
        /// 第一次活动；第二次终态 committed；之后为空（用于代际守卫用例）。
        case activeThenCommittedThenNil
    }

    private let schedule: Schedule
    private var calls = 0

    init(schedule: Schedule) {
        self.schedule = schedule
    }

    func next(for request: ControlRequest) -> ControlResponse {
        calls += 1
        switch (schedule, calls) {
        case (.activeThenNil, 1), (.activeThenCommittedThenNil, 1):
            return ControlResponse(
                requestID: request.requestID,
                command: .modelStatus,
                status: .ok,
                modelStatus: snapshot(activeOperation: activeOperation())
            )
        case (.activeThenCommittedThenNil, 2):
            return ControlResponse(
                requestID: request.requestID,
                command: .modelStatus,
                status: .ok,
                message: "模型准备已完成",
                modelStatus: snapshot(activeOperation: committedOperation())
            )
        default:
            return ControlResponse(
                requestID: request.requestID,
                command: .modelStatus,
                status: .ok,
                modelStatus: snapshot(activeOperation: nil)
            )
        }
    }

    private func snapshot(activeOperation: OperationSnapshot?) -> ModelStatusSnapshot {
        ModelStatusSnapshot(
            artifacts: [],
            disk: ModelDiskSnapshot(modelBytes: 0, freeBytes: 0),
            activeOperation: activeOperation
        )
    }

    private func activeOperation() -> OperationSnapshot {
        OperationSnapshot(
            operationID: "op-1",
            command: .modelPrepare,
            state: .running,
            phase: "download"
        )
    }

    private func committedOperation() -> OperationSnapshot {
        OperationSnapshot(
            operationID: "op-1",
            command: .modelPrepare,
            state: .committed,
            phase: "committed"
        )
    }
}

/// 让测试在取消请求「传输中」触发一次更新的刷新，从而确定性地制造代际竞争，
/// 不依赖 500ms 轮询时序。
private actor CancelSupersession {
    private var refresh: (@Sendable () async -> Void)?

    func install(_ action: @escaping @Sendable () async -> Void) {
        refresh = action
    }

    func fire() async {
        guard let refresh else { return }
        await refresh()
    }
}

/// 取消请求的传输层失败：用于让过期的取消链走进 catch 分支并尝试写入旧文案。
private struct CancelTransportFailure: Error {}

/// 制造两次并发模型刷新的确定性竞争：第一次 `modelStatus` 被拦下时触发一次更新的
/// 刷新并等待它完成，再放行旧的（过期的）响应。
private actor ConcurrentRefreshRace {
    static let staleMarker: Int64 = 111
    static let freshMarker: Int64 = 222

    private var statusCalls = 0
    private var newerRefresh: (@Sendable () async -> Void)?

    func install(_ action: @escaping @Sendable () async -> Void) {
        newerRefresh = action
    }

    func catalog(for request: ControlRequest) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: .modelCatalog,
            status: .ok,
            modelCatalog: ModelCatalogSnapshot(artifacts: [], profiles: [])
        )
    }

    func status(for request: ControlRequest) async -> ControlResponse {
        statusCalls += 1
        if statusCalls == 1 {
            if let newerRefresh { await newerRefresh() }
            return diskResponse(for: request, bytes: Self.staleMarker)
        }
        return diskResponse(for: request, bytes: Self.freshMarker)
    }

    private func diskResponse(for request: ControlRequest, bytes: Int64) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: .modelStatus,
            status: .ok,
            modelStatus: ModelStatusSnapshot(
                artifacts: [],
                disk: ModelDiskSnapshot(modelBytes: bytes, freeBytes: 0),
                activeOperation: nil
            )
        )
    }
}
