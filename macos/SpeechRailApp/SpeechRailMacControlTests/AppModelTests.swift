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

    /// 契约里 `voice_revision` 可空（"legacy voices remain null"），所以系统预置音色
    /// 仍然要能进入实时对讲：缺版本号只是**不带 pin**，不是不可用。
    /// 回归这个缺陷——它曾让所有系统预置音色一律报「语音服务未就绪」。
    func testRealtimeBindingAcceptsLegacyVoiceWithoutRevision() {
        let binding = AppCapabilityFacade(
            snapshot: Self.snapshot(voice: Self.voice(voiceRevision: nil)),
            discoveryState: .loaded
        ).realtimeBinding(for: "legacy-voice")

        XCTAssertEqual(
            binding,
            RealtimeCapabilityBinding(
                asrModelRevision: "asr-model-catalog",
                canonicalVoiceID: "voice-1",
                voiceRevision: nil,
                ttsModelRevision: "voice-model-catalog"
            )
        )
        XCTAssertEqual(binding?.includesSpeech, true)
    }

    /// 放宽的是**音色版本号**这一个可空字段。模型 catalog pin 缺失仍然 fail-closed：
    /// 那说明服务没有发布这个音色用的模型身份，不能靠猜。
    func testRealtimeBindingStillRequiresVoiceModelCatalogRevision() {
        var voice = Self.voice(voiceRevision: nil)
        voice = SafeVoiceEntry(
            id: voice.id,
            name: voice.name,
            aliases: voice.aliases,
            mode: voice.mode,
            available: voice.available,
            availabilityReason: voice.availabilityReason,
            variant: voice.variant,
            voiceRevision: voice.voiceRevision,
            voiceIdentityAssurance: voice.voiceIdentityAssurance,
            model: ConfiguredModelIdentity(
                assurance: .unknown,
                artifact: nil
            ),
            descriptors: voice.descriptors,
            operations: voice.operations
        )

        XCTAssertNil(
            AppCapabilityFacade(
                snapshot: Self.snapshot(voice: voice),
                discoveryState: .loaded
            ).realtimeBinding(for: "legacy-voice")
        )
    }

    /// 音色级 operation 的声明就是「列了这个键」，`parameters` 只是可选的参数说明。
    /// 少列参数说明不该把整个音色判成不可用。
    func testRealtimeBindingAcceptsDeclaredOperationWithoutParameterList() {
        let facade = AppCapabilityFacade(
            snapshot: Self.snapshot(
                voice: Self.voice(voiceRevision: nil, declaresParameters: false)
            ),
            discoveryState: .loaded
        )

        XCTAssertEqual(
            facade.availability(ofVoiceOperation: "realtime_speech", voiceID: "legacy-voice"),
            .available
        )
        XCTAssertEqual(facade.realtimeBinding(for: "legacy-voice")?.includesSpeech, true)
    }

    /// 反过来：服务**没有**为这个音色声明实时朗读时，仍然必须拦住。
    func testRealtimeBindingRejectsVoiceWithoutDeclaredRealtimeSpeech() {
        let facade = AppCapabilityFacade(
            snapshot: Self.snapshot(
                voice: Self.voice(
                    voiceRevision: nil,
                    declaresParameters: true,
                    declaresRealtimeSpeech: false
                )
            ),
            discoveryState: .loaded
        )

        XCTAssertEqual(
            facade.availability(ofVoiceOperation: "realtime_speech", voiceID: "legacy-voice"),
            .unsupported
        )
        XCTAssertNil(facade.realtimeBinding(for: "legacy-voice"))
    }

    private static func voice(voiceRevision: String?) -> SafeVoiceEntry {
        voice(voiceRevision: voiceRevision, declaresParameters: true)
    }

    /// - Parameter declaresParameters: 契约里 `operations.*.parameters` 是可选的；
    ///   置 false 复现「服务声明了该 operation 但没列参数说明」的服务端形状。
    /// - Parameter declaresRealtimeSpeech: 置 false 复现「服务没给这个音色声明
    ///   实时朗读」——这一条必须继续 fail-closed。
    private static func voice(
        voiceRevision: String?,
        declaresParameters: Bool,
        declaresRealtimeSpeech: Bool = true
    ) -> SafeVoiceEntry {
        var operationFields: [String: JSONValue] = [
            "output": JSONValue(.object([
                "codecs": JSONValue(.array([JSONValue(.string("pcm16"))])),
                "pcm_sample_rate": JSONValue(.integer(24_000)),
                "channels": JSONValue(.integer(1))
            ])),
            "scheduling_class": JSONValue(.string("realtime_tts")),
            "terminal_evidence": JSONValue(.string("speechrail.tts.completed")),
        ]
        if declaresParameters {
            operationFields["parameters"] = JSONValue(.object([
                "instructions": JSONValue(.object([
                    "status": JSONValue(.string("unsupported"))
                ]))
            ]))
        }
        return SafeVoiceEntry(
            id: "voice-1",
            name: "测试音色",
            aliases: ["legacy-voice"],
            mode: "system",
            available: true,
            availabilityReason: .available,
            voiceRevision: voiceRevision,
            voiceIdentityAssurance: voiceRevision == nil ? .legacy : .contentAddressed,
            model: ConfiguredModelIdentity(
                assurance: .configuredCatalog,
                artifact: "voice-base",
                catalogRevision: "voice-model-catalog"
            ),
            descriptors: SafeVoiceDescriptor(
                voiceMode: "system",
                locales: [],
                styleTags: [],
                pitchBand: "unknown",
                timbreFamily: "unknown",
                baselinePace: "unknown",
                sourceType: "system_preset",
                metadataMethod: "declared_only"
            ),
            operations: declaresRealtimeSpeech
                ? ["realtime_speech": JSONValue(.object(operationFields))]
                : [:]
        )
    }

    private static func snapshot(voice: SafeVoiceEntry) -> EffectiveCapabilitySnapshot {
        EffectiveCapabilitySnapshot(
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
            ],
            voices: [voice],
            operations: [
                "realtime_transcription": JSONValue(.object([
                    "status": JSONValue(.string("supported"))
                ]))
            ],
            guarantees: [:]
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

    /// 助手等没有试听文案输入的入口会走 nil 分支：英语/日语/韩语音色不能被中文硬读。
    func testPreviewTextFallsBackToVoiceLanguageWhenCallerSuppliesNone() {
        for voiceID in ["ryan", "aiden"] {
            let resolved = AppModel.resolvedPreviewText(forVoiceID: voiceID, text: nil)
            XCTAssertFalse(
                resolved.contains("这是"),
                "\(voiceID) 无文案输入时不应回落到中文默认：\(resolved)"
            )
            XCTAssertTrue(resolved.contains("SpeechRail"))
        }
        XCTAssertFalse(
            AppModel.resolvedPreviewText(forVoiceID: "ono_anna", text: nil).contains("这是"),
            "日语音色不应使用中文默认文案"
        )
        XCTAssertTrue(
            AppModel.resolvedPreviewText(forVoiceID: "serena", text: nil).contains("音色试听"),
            "中文音色保持中文默认文案"
        )
    }

    /// 用户显式改写的文案优先于语种默认值。
    func testPreviewTextKeepsCallerSuppliedWording() {
        let custom = "  自定义试听文案  "
        XCTAssertEqual(
            AppModel.resolvedPreviewText(forVoiceID: "ryan", text: custom),
            "自定义试听文案"
        )
    }

    /// 服务端声明的示例文案是唯一事实源，本地映射只是缺失时的兜底。
    func testServerDeclaredPreviewWinsOverTheLocalFallback() {
        // serena 本地兜底是中文；服务端声明英文时必须用服务端文案，
        // 否则又会退回"按音色 ID 猜语种"的老路。
        let voice = CreatorVoice(
            id: "serena",
            name: "温柔中文女声",
            preview: VoicePreviewSample(
                locale: "en",
                text: "This is a voice preview. The speech should be clear and natural."
            )
        )

        XCTAssertEqual(
            AppModel.resolvedPreviewText(for: voice, text: nil),
            "This is a voice preview. The speech should be clear and natural."
        )
        XCTAssertEqual(AppModel.previewLanguage(for: voice), "en")
    }

    /// 用户改过文案时既不覆盖文案，也不继承 preset 的语言。
    func testUserWordingBeatsServerPreviewText() {
        let voice = CreatorVoice(
            id: "ryan",
            name: "动感英语男声",
            preview: VoicePreviewSample(locale: "en", text: "Server sample text.")
        )
        let custom = "  用户自己写的试听文案  "

        XCTAssertEqual(
            AppModel.resolvedPreviewText(for: voice, text: custom),
            "用户自己写的试听文案"
        )
    }

    /// 服务端没有声明示例时退回本地兜底，而不是不显示任何文案。
    func testMissingServerPreviewFallsBackLocally() {
        let voice = CreatorVoice(id: "ono_anna", name: "轻快日语女声")

        XCTAssertEqual(
            AppModel.resolvedPreviewText(for: voice, text: nil),
            AppModel.defaultPreviewText(forVoiceID: "ono_anna")
        )
        XCTAssertEqual(AppModel.previewLanguage(for: voice), "japanese")
    }

    func testPendingCloneRegistrationReplaysTheSameOperationAndBlocksRerecording() async throws {
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
        XCTAssertEqual(queriedKeys, [originalIdempotencyKey, originalIdempotencyKey])
        XCTAssertEqual(registrationCount, 1)

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

    func testDefinitiveCloneRejectionAllowsRerecordingWithANewOperation() async throws {
        let creator = RejectingCloneRegistrationClient()
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
        let recording = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: recording)
        await model.acceptCloneRecording(fileAt: recording)
        let rejectedID = try XCTUnwrap(model.cloneRegistrationID)
        let rejectedKey = try XCTUnwrap(model.cloneIdempotencyKey)

        let result = await model.registerCloneVoice(
            referenceText: "这是一段用于注册音色的测试朗读文本。",
            name: "测试音色"
        )

        XCTAssertNil(result)
        XCTAssertTrue(model.discardCloneRecording())
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data([5, 6, 7, 8]).write(to: replacement)
        await model.acceptCloneRecording(fileAt: replacement)
        XCTAssertNotEqual(model.cloneRegistrationID, rejectedID)
        XCTAssertNotEqual(model.cloneIdempotencyKey, rejectedKey)
        XCTAssertEqual(model.cloneRecordingAudio, Data([5, 6, 7, 8]))
    }

    /// C1 + S3: a `pass` report whose evidence was not persisted must not be
    /// promoted to "已验收". The user is told to retry instead.
    func testVoiceOutputCheckWithPersistedFalseIsNotTreatedAsAccepted() async {
        let creator = VoiceOutputCheckCreatorClient(
            response: VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(
                    status: .pass,
                    runID: "vq_0123456789abcdef0123456789abcdef"
                ),
                validationPersisted: false
            )
        )
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

        let state = await model.checkVoiceOutput(voiceID: "voice_clone_a")

        guard case .passedNotPersisted(let voiceID, _) = state else {
            return XCTFail("unpersisted pass must not be reported as accepted, got \(state)")
        }
        XCTAssertEqual(voiceID, "voice_clone_a")
        XCTAssertEqual(state.resultMessage, "检查已完成，但结果未保存，请重试。")
        XCTAssertFalse(state.isRunning)
    }

    /// A recorded pass is reported as accepted, and the wording makes clear it is
    /// a past observation rather than a standing production confirmation.
    func testVoiceOutputCheckWithPersistedPassIsAccepted() async {
        let creator = VoiceOutputCheckCreatorClient(
            response: VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(
                    status: .pass,
                    runID: "vq_0123456789abcdef0123456789abcdef"
                ),
                validationPersisted: true
            )
        )
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

        let state = await model.checkVoiceOutput(voiceID: "voice_clone_a")

        guard case .passed(let voiceID, _, let runID) = state else {
            return XCTFail("recorded pass must be reported as accepted, got \(state)")
        }
        XCTAssertEqual(voiceID, "voice_clone_a")
        XCTAssertEqual(runID, "vq_0123456789abcdef0123456789abcdef")
        let message = try? XCTUnwrap(state.resultMessage)
        XCTAssertTrue(message?.contains("本次检查通过") == true, message ?? "")
        XCTAssertTrue(message?.contains("生成时仍会确认当前声音环境") == true, message ?? "")
    }

    func testVoiceOutputCheckFailureCarriesActionableMessage() async {
        let creator = VoiceOutputCheckCreatorClient(
            response: VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(
                    status: .reject,
                    failureCodes: ["output_invalid"]
                ),
                validationPersisted: true
            )
        )
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

        let state = await model.checkVoiceOutput(voiceID: "voice_clone_a")

        guard case .failed = state else {
            return XCTFail("a reject report must not be reported as accepted, got \(state)")
        }
        XCTAssertEqual(state.resultMessage, "配音效果检查未通过：服务生成的参考音频无效，请重试或打开诊断")
    }

    /// A check that started for one voice must not overwrite the state after the
    /// user switched to a different voice and started a new check.
    func testLateVoiceOutputCheckResultDoesNotPolluteNewerSelection() async throws {
        let creator = VoiceOutputCheckCreatorClient(
            response: VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(status: .pass, runID: "vq_first"),
                validationPersisted: true
            )
        )
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

        let staleTask = Task { await model.checkVoiceOutput(voiceID: "voice_clone_a") }
        // Let the first check enter its in-flight window, then supersede it.
        while model.voiceOutputCheckInFlightVoiceID == nil {
            await Task.yield()
        }

        await creator.setResponse(
            VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(status: .pass, runID: "vq_second"),
                validationPersisted: true
            )
        )
        let fresh = await model.checkVoiceOutput(voiceID: "voice_clone_b")
        _ = await staleTask.value

        guard case let .passed(_, _, runID) = fresh else {
            return XCTFail("the newest check must win, got \(model.voiceOutputCheck)")
        }
        XCTAssertEqual(runID, "vq_second")
        XCTAssertEqual(model.voiceOutputCheck.voiceID, "voice_clone_b")
    }

    /// A duplicate submission for the same voice while its check is running must
    /// not start a second server run.
    func testDuplicateVoiceOutputCheckForSameVoiceIsIgnored() async throws {
        let creator = VoiceOutputCheckCreatorClient(
            response: VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(status: .pass, runID: "vq_only"),
                validationPersisted: true
            )
        )
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

        let first = Task { await model.checkVoiceOutput(voiceID: "voice_clone_a") }
        while model.voiceOutputCheckInFlightVoiceID == nil {
            await Task.yield()
        }
        let duplicate = await model.checkVoiceOutput(voiceID: "voice_clone_a")
        _ = await first.value

        XCTAssertTrue(duplicate.isRunning)
        let calls = await creator.runCount()
        XCTAssertEqual(calls, 1)
    }

    /// F7: a machine-rejected candidate is `failed` on the service side, so
    /// re-validating it is rejected every time. The only reachable action is
    /// "重新生成候选", and taking it must not issue another `validate` call.
    func testFailedVoiceDesignCandidateOffersRegenerationInsteadOfRetry() async throws {
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
            referenceTextSnapshot: "这是一段用于终态复现与重新生成的测试参考文案。",
            status: .ready,
            audioData: Data([0, 1, 2])
        )

        model.startVoiceDesignPublication(preview, name: "测试音色")
        await waitForVoiceDesignPhase(.awaitingReferenceReview, model: model)
        await creator.failNextValidationWithTerminalCandidate()
        model.markVoiceDesignReferenceAudioPlaybackFinished(successfully: true)
        model.confirmVoiceDesignReference()
        await waitForVoiceDesignPhase(.failed, model: model)

        XCTAssertEqual(model.voiceDesignPublicationRetryActionTitle, "重新生成候选")
        let eventsBeforeRetry = await creator.events()
        XCTAssertEqual(eventsBeforeRetry.filter { $0 == "validate" }.count, 1)

        model.retryVoiceDesignPublication()
        for _ in 0..<200 {
            if !model.isGeneratingVoiceDesign, model.voiceDesignPublication.phase != .failed {
                break
            }
            await Task.yield()
        }
        let eventsAfterRetry = await creator.events()
        // The retry must not replay validation against a terminal candidate.
        XCTAssertEqual(
            eventsAfterRetry.filter { $0 == "validate" }.count,
            eventsBeforeRetry.filter { $0 == "validate" }.count
        )
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

    func testRetryResumesValidationWhenCandidateIsParkedInValidating() async {
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
            referenceTextSnapshot: "这是一段用于验证复验重试的测试参考文案。",
            status: .ready,
            audioData: Data([0, 1, 2])
        )

        model.startVoiceDesignPublication(preview, name: "复验重试")
        await waitForVoiceDesignPhase(.awaitingReferenceReview, model: model)
        model.markVoiceDesignReferenceAudioPlaybackFinished(successfully: true)
        await creator.failNextValidationLeavingCandidateValidating()
        model.confirmVoiceDesignReference()

        // The service commits `validating` before it synthesizes, so a failure
        // after that point strands the candidate there with no stored result.
        await waitForVoiceDesignPhase(.failed, model: model)
        XCTAssertEqual(
            model.voiceDesignPublication.candidateID,
            "vd_0123456789abcdef01234567"
        )

        model.retryVoiceDesignPublication()
        await waitForVoiceDesignPhase(.awaitingValidationReview, model: model)

        let events = await creator.events()
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
                "candidate.get",
                "validate",
                "candidate.get",
                "validation.audio",
            ]
        )
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

/// Returns a scripted namespaced quality-run envelope so the check state machine
/// can be driven without a service. `runVoiceQuality` is the only method that
/// matters here; the rest use the protocol's default implementations.
private actor VoiceOutputCheckCreatorClient: SpeechRailCreatorClient {
    private var response: VoiceQualityRunResponse
    private var runs = 0

    init(response: VoiceQualityRunResponse) {
        self.response = response
    }

    func setResponse(_ value: VoiceQualityRunResponse) {
        response = value
    }

    func runCount() -> Int { runs }

    func fetchVoices() async throws -> [CreatorVoice] { [] }

    func fetchVoice(id: String) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions
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

    func runVoiceQuality(
        id: String,
        request: VoiceQualityRunRequest
    ) async throws -> VoiceQualityRunResponse {
        runs += 1
        return response
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
        options: SpeechRailRequestOptions
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

private actor RejectingCloneRegistrationClient: SpeechRailCreatorClient {
    func fetchVoices() async throws -> [CreatorVoice] { [] }

    func fetchVoice(id: String) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions
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
        throw ServiceAPIClientError.http(
            statusCode: 400,
            code: "voice_quality_reject",
            message: "Reference quality rejected",
            requestID: nil,
            retryable: false
        )
    }

    func deleteVoice(id: String) async throws {}
}

private actor VoiceDesignWorkflowCreatorClient: SpeechRailCreatorClient {
    private var currentCandidate: VoiceDesignCandidate?
    private var recordedEvents: [String] = []
    private let candidateID = "vd_0123456789abcdef01234567"
    private let candidateRevision = "vr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let validationID = "vv_0123456789abcdef01234567"
    private var shouldHoldNextPublication = false
    private var shouldFailNextCandidateCancel = false
    private var shouldFailNextValidation = false
    private var shouldFailNextValidationTerminally = false
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

    /// Mimic a Base validation that dies after the service already committed
    /// `validating`: the candidate is parked there with no stored result.
    func failNextValidationLeavingCandidateValidating() {
        shouldFailNextValidation = true
    }

    /// Machine verification rejects the candidate: the service moves it to the
    /// terminal `failed` state, which no longer accepts re-validation.
    func failNextValidationWithTerminalCandidate() {
        shouldFailNextValidationTerminally = true
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
        options: SpeechRailRequestOptions
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
        if shouldFailNextValidationTerminally, humanReview == nil {
            shouldFailNextValidationTerminally = false
            let validation = VoiceDesignValidation(
                validationID: validationID,
                candidateRevision: candidateRevision,
                status: "reject",
                machineStatus: "reject",
                identityStatus: .notReviewed,
                naturalnessStatus: .notReviewed,
                failureCodes: ["output_invalid"],
                capabilityKey: "reference.render",
                modelArtifact: "tts-1.7b-base-bf16",
                modelCatalogRevision: String(repeating: "a", count: 40),
                transcriptMatch: 0.2,
                createdAt: 1,
                updatedAt: 1
            )
            let terminal = makeCandidate(
                voiceID: existingCandidate.targetVoiceID,
                name: existingCandidate.name,
                state: "failed",
                validations: [validation],
                publishable: false
            )
            currentCandidate = terminal
            return terminal
        }
        if shouldFailNextValidation, humanReview == nil {
            shouldFailNextValidation = false
            currentCandidate = makeCandidate(
                voiceID: existingCandidate.targetVoiceID,
                name: existingCandidate.name,
                state: "validating",
                validations: [],
                publishable: false
            )
            throw ServiceAPIClientError.http(
                statusCode: 502,
                code: "output_invalid",
                message: "Base validation output was invalid",
                requestID: nil,
                retryable: true
            )
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

// MARK: - (k) 试听缓存身份与迟到回包隔离

extension AppModelTests {
    private static func previewKey(
        voiceID: String = "ryan",
        voiceRevision: String? = "vr_0123456789abcdef0123456789abcdef",
        catalogEpoch: String? = "catalog-1",
        input: String = "试听文本",
        language: String? = "en",
        speed: Double = 1.0
    ) -> VoicePreviewCacheKey {
        VoicePreviewCacheKey(
            canonicalVoiceID: voiceID,
            voiceRevision: voiceRevision,
            catalogEpoch: catalogEpoch,
            input: input,
            languageOverride: language,
            speed: speed
        )
    }

    /// 同身份可命中；文本 / 语言 / 音色 revision / 模型 epoch 任一变化都不误命中。
    func testPreviewCacheKeySeparatesEveryIdentityDimension() {
        let base = Self.previewKey()

        XCTAssertEqual(base, Self.previewKey(), "同一次请求应当命中")

        XCTAssertNotEqual(base, Self.previewKey(input: "另一段文本"))
        XCTAssertNotEqual(base, Self.previewKey(language: "zh"))
        XCTAssertNotEqual(base, Self.previewKey(language: nil), "auto 与显式语言不是同一次生成")
        XCTAssertNotEqual(base, Self.previewKey(speed: 1.1))
        XCTAssertNotEqual(base, Self.previewKey(voiceID: "aiden"))
        XCTAssertNotEqual(
            base,
            Self.previewKey(voiceRevision: "vr_ffffffffffffffffffffffffffffffff"),
            "音色重新生成后不能复用旧音频"
        )
        XCTAssertNotEqual(
            base,
            Self.previewKey(catalogEpoch: "catalog-2"),
            "换用另一份模型后不能复用旧音频"
        )
    }

    /// 系统音色没有 revision 时用 catalog epoch 隔离，而不是编一个假 revision。
    func testPreviewCacheKeyUsesCatalogEpochForSystemVoices() {
        let key = AppModel.previewCacheKey(
            voice: CreatorVoice(id: "ryan", name: "动感英语男声", available: true),
            options: SpeechRailRequestOptions(),
            catalogRevision: "snapshot-catalog",
            input: "试听文本",
            languageOverride: "en",
            speed: 1.0
        )

        XCTAssertNil(key.voiceRevision, "系统音色不应被赋予假 revision")
        XCTAssertEqual(key.catalogEpoch, "snapshot-catalog")
    }

    /// 已撤销音色换版后，即使文案与语速相同也不是同一次请求。
    func testPreviewCacheKeyTracksTheRevisionTheServerWillPin() {
        let voice = CreatorVoice(
            id: "clone_voice",
            name: "克隆音色",
            available: true,
            revision: "vr_0123456789abcdef0123456789abcdef"
        )
        let pinned = AppModel.previewCacheKey(
            voice: voice,
            options: SpeechRailRequestOptions(
                expectedVoiceRevision: "vr_0123456789abcdef0123456789abcdef",
                expectedModelRevision: "model-1"
            ),
            catalogRevision: "snapshot-catalog",
            input: "试听文本",
            languageOverride: nil,
            speed: 1.0
        )
        let repinned = AppModel.previewCacheKey(
            voice: voice,
            options: SpeechRailRequestOptions(
                expectedVoiceRevision: "vr_ffffffffffffffffffffffffffffffff",
                expectedModelRevision: "model-1"
            ),
            catalogRevision: "snapshot-catalog",
            input: "试听文本",
            languageOverride: nil,
            speed: 1.0
        )

        XCTAssertNotEqual(pinned, repinned)
    }

    /// 只缓存非空结果；超出上限时按写入顺序淘汰最旧条目。
    func testPreviewAudioCacheRejectsEmptyAndEvictsOldest() {
        var cache = VoicePreviewAudioCache(byteLimit: 10)
        let first = Self.previewKey(input: "一")
        let second = Self.previewKey(input: "二")
        let third = Self.previewKey(input: "三")

        XCTAssertFalse(cache.insert(Data(), for: first), "空音频不入缓存")
        XCTAssertNil(cache.data(for: first))

        XCTAssertTrue(cache.insert(Data(repeating: 1, count: 6), for: first))
        XCTAssertTrue(cache.insert(Data(repeating: 2, count: 6), for: second))
        XCTAssertEqual(cache.count, 1, "超出上限后只保留最新条目")
        XCTAssertNil(cache.data(for: first))
        XCTAssertNotNil(cache.data(for: second))
        XCTAssertLessThanOrEqual(cache.totalBytes, cache.byteLimit)

        XCTAssertFalse(
            cache.insert(Data(repeating: 3, count: 11), for: third),
            "单条超过上限直接拒绝，不清空已有缓存"
        )
        XCTAssertNotNil(cache.data(for: second))
    }
}

// MARK: - (l) 迟到回包不得污染新请求

/// `AVAudioPlayer` 只接受合法容器，测试必须给真实可解码的 WAV 而不是任意字节。
private func silentPreviewWAV(marker: UInt8, frames: Int = 2_400) -> Data {
    let bytesPerFrame = 2
    let dataSize = frames * bytesPerFrame
    var wav = Data("RIFF".utf8)
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) {
        Array($0)
    })
    wav.append(contentsOf: Data("WAVEfmt ".utf8))
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(24_000).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(24_000 * UInt32(bytesPerFrame)).littleEndian) {
        Array($0)
    })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(bytesPerFrame).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
    wav.append(contentsOf: Data("data".utf8))
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
    for _ in 0..<frames {
        wav.append(contentsOf: withUnsafeBytes(of: Int16(truncatingIfNeeded: Int(marker)).littleEndian) {
            Array($0)
        })
    }
    return wav
}

/// 只在第一次合成上挂起，让"取消 → 重新开始 → 迟到返回"这条交错可复现。
private actor HeldPreviewCreatorClient: SpeechRailCreatorClient {
    private(set) var requestedInputs: [String] = []
    private var heldContinuation: CheckedContinuation<Data, Error>?
    private var pendingInput: String?
    private var callCount = 0

    func fetchVoices() async throws -> [CreatorVoice] { [] }

    func fetchVoice(id: String) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func waitUntilHeld() async {
        while heldContinuation == nil {
            await Task.yield()
        }
    }

    func releaseHeld(with data: Data) {
        guard let heldContinuation else { return }
        self.heldContinuation = nil
        heldContinuation.resume(returning: data)
    }

    func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions
    ) async throws -> Data {
        requestedInputs.append(text)
        callCount += 1
        // 第一次挂起，模拟"取消之后网络才返回"。
        if callCount == 1, heldContinuation == nil {
            pendingInput = text
            return try await withCheckedThrowingContinuation { continuation in
                heldContinuation = continuation
            }
        }
        return silentPreviewWAV(marker: 0xB2)
    }

    func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        throw ServiceAPIClientError.requestFailed
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

    func createVoiceDesignCandidate(
        voiceID: String,
        name: String,
        instruction: String,
        referenceText: String,
        seed: Int
    ) async throws -> VoiceQualityReportSnapshotV2 {
        throw ServiceAPIClientError.requestFailed
    }
}

private struct PreviewDiscoveryClient: ServiceCapabilityDiscoveryClient {
    let snapshot: EffectiveCapabilitySnapshot

    func fetchEffectiveCapabilities(
        ifNoneMatch: String?,
        cachedValue: EffectiveCapabilitySnapshot?
    ) async throws -> ServiceConditionalResponse<EffectiveCapabilitySnapshot> {
        ServiceConditionalResponse(
            value: snapshot,
            metadata: ServiceResponseMetadata(statusCode: 200, requestID: "req-1")
        )
    }

    func fetchSafeVoices(
        ifNoneMatch: String?,
        cachedValue: SafeVoiceList?
    ) async throws -> ServiceConditionalResponse<SafeVoiceList> {
        ServiceConditionalResponse(
            value: SafeVoiceList(
                snapshotID: "voices-1",
                catalogRevision: "voices-catalog",
                data: []
            ),
            metadata: ServiceResponseMetadata(statusCode: 200, requestID: "req-2")
        )
    }

    func fetchReadiness() async throws -> ReadySnapshot {
        ReadySnapshot(ready: true)
    }
}

extension AppModelTests {
    private static func previewSnapshot() -> EffectiveCapabilitySnapshot {
        EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "snapshot-catalog",
            snapshotID: "snapshot-1",
            profile: "quality",
            models: [:],
            voices: [
                SafeVoiceEntry(
                    id: "ryan",
                    name: "动感英语男声",
                    aliases: [],
                    mode: "system",
                    available: true,
                    availabilityReason: .available,
                    variant: "custom_voice",
                    voiceIdentityAssurance: .legacy,
                    model: ConfiguredModelIdentity(
                        assurance: .configuredCatalog,
                        catalogRevision: "tts-model-revision"
                    ),
                    descriptors: SafeVoiceDescriptor(
                        voiceMode: "system",
                        locales: [],
                        styleTags: [],
                        pitchBand: "unknown",
                        timbreFamily: "unknown",
                        baselinePace: "unknown",
                        sourceType: "system_preset",
                        metadataMethod: "declared_only"
                    ),
                    operations: ["http_speech": JSONValue(.string("supported"))]
                )
            ],
            operations: [:],
            guarantees: [:]
        )
    }

    /// A 取消 → B 开始 → A 迟到：A 的音频既不能播放、也不能进缓存，更不能把
    /// B 的进度与提示抹掉。
    func testLatePreviewResponseCannotPolluteTheNewerRequest() async {
        let creator = HeldPreviewCreatorClient()
        let model = AppModel(
            transport: ClosureControlTransport { request in
                Self.modelCatalogResponse(for: request)
            },
            apiClient: UnavailableDiagnosticsClient(),
            discoveryClient: PreviewDiscoveryClient(snapshot: Self.previewSnapshot()),
            creatorClient: creator
        )
        await model.refreshDiscovery()

        let voice = CreatorVoice(
            id: "ryan",
            name: "动感英语男声",
            available: true,
            preview: VoicePreviewSample(locale: "en", text: "server sample")
        )

        // A：在途挂起。
        let first = Task { @MainActor in await model.previewVoice(voice) }
        await creator.waitUntilHeld()
        XCTAssertTrue(model.isCreatingSpeech)
        XCTAssertEqual(model.previewingVoiceID, "ryan")

        // 取消 A，再让 B 走完整条链路。
        model.cancelVoicePreview()
        XCTAssertFalse(model.isCreatingSpeech, "取消方负责收尾，不等迟到请求的 defer")
        XCTAssertNil(model.previewingVoiceID)

        await model.previewVoice(voice, text: "第二次试听的文案")
        XCTAssertFalse(model.isCreatingSpeech)
        XCTAssertNil(model.previewingVoiceID)
        XCTAssertNil(model.creatorMessage, "B 成功收尾时不应残留 A 的提示")

        // A 现在才迟到。
        await creator.releaseHeld(with: silentPreviewWAV(marker: 0xA1))
        _ = await first.value

        XCTAssertFalse(model.isCreatingSpeech, "迟到的 defer 不得清空新请求的状态")
        XCTAssertNil(model.previewingVoiceID)
        XCTAssertNil(model.creatorMessage)

        // 迟到的音频没有进缓存：先停播（否则会命中"再次点击同一音色＝停止"），
        // 再用 A 的文案重放一次，必须重新发起合成。
        model.stopAudio()
        let callsBeforeReplay = await creator.requestedInputs.count
        await model.previewVoice(voice, text: "server sample")
        let callsAfterReplay = await creator.requestedInputs.count
        XCTAssertEqual(
            callsAfterReplay,
            callsBeforeReplay + 1,
            "被取消请求的迟到音频不得留在缓存里"
        )
    }
}

// MARK: - (m) 显式保存：只保存一次、身份冻结、不静默丢弃

/// 正式制作路径的可控替身：返回合法 WAV，并记录每次 render 的身份参数。
private actor ScriptedRenderClient: SpeechRailCreatorClient {
    private(set) var renderCalls: [(text: String, voiceID: String, speed: Double)] = []
    private(set) var renderPolicies: [String?] = []
    private let audio: Data
    private let renderError: Error?

    init(audio: Data, renderError: Error? = nil) {
        self.audio = audio
        self.renderError = renderError
    }

    func fetchVoices() async throws -> [CreatorVoice] { [] }

    func fetchVoice(id: String) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions
    ) async throws -> Data {
        audio
    }

    func createSpeechRender(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions
    ) async throws -> SpeechRenderResult {
        renderCalls.append((text, voiceID, speed))
        renderPolicies.append(options.validationPolicy)
        if let renderError {
            throw renderError
        }
        return SpeechRenderResult(
            audioData: audio,
            planID: "plan_frozen_at_generation",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef"
        )
    }

    func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        throw ServiceAPIClientError.requestFailed
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

    func createVoiceDesignCandidate(
        voiceID: String,
        name: String,
        instruction: String,
        referenceText: String,
        seed: Int
    ) async throws -> VoiceQualityReportSnapshotV2 {
        throw ServiceAPIClientError.requestFailed
    }
}

/// 写盘失败的 FileManager，用来验证"保存失败仍保留 pending、可重试"。
private final class FailingWriteFileManager: FileManager {
    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

extension AppModelTests {
    private static func renderVoice() -> CreatorVoice {
        CreatorVoice(id: "ryan", name: "动感英语男声", available: true, mode: "system")
    }

    private func makeRenderModel(
        store: CreativeWorkStore,
        creator: any SpeechRailCreatorClient
    ) -> AppModel {
        AppModel(
            transport: ClosureControlTransport { request in
                Self.modelCatalogResponse(for: request)
            },
            apiClient: UnavailableDiagnosticsClient(),
            discoveryClient: PreviewDiscoveryClient(snapshot: Self.previewSnapshot()),
            creatorClient: creator,
            workStore: store
        )
    }

    /// 生成、播放、导出不入库；显式保存只增加一条；重复保存仍是同一条。
    /// F1: formal production must state its validation policy at the call site,
    /// not only at the client boundary. Otherwise a creator client that resolves
    /// `createSpeechRender` to the protocol default would hand an unverified
    /// render to the work library.
    func testFormalRenderAlwaysRequestsStrictOutputValidation() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-strict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativeWorkStore(directory: directory)
        let creator = ScriptedRenderClient(audio: silentPreviewWAV(marker: 0x20))
        let model = makeRenderModel(store: store, creator: creator)
        await model.refreshDiscovery()

        _ = await model.synthesizeAndSave(
            text: "这是一段用于验证正式制作策略的文稿。",
            voice: Self.renderVoice(),
            speed: 1.0
        )

        let policies = await creator.renderPolicies
        XCTAssertEqual(policies, ["require_output_pass"])
    }

    /// F1: 当服务因严格门禁拒绝这次正式制作时，App 不得留下任何"待保存"的
    /// 音频。没有 pendingDubbing，就没有可被误当成已验收作品的残留。
    func testRejectedStrictRenderLeavesNoPendingDubbingAudio() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-strict-reject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativeWorkStore(directory: directory)
        // 服务拒绝严格渲染（如证据缺失 / 身份变化），客户端以错误结束这次生成。
        let rejecting = ScriptedRenderClient(
            audio: silentPreviewWAV(marker: 0x20),
            renderError: ServiceAPIClientError.requestFailed
        )
        let model = makeRenderModel(store: store, creator: rejecting)
        await model.refreshDiscovery()

        _ = await model.synthesizeAndSave(
            text: "这是一段应当被服务端拒绝的正式制作文稿。",
            voice: Self.renderVoice(),
            speed: 1.0
        )

        // 拒绝后既不能有待保存音频，也不能落一条作品。
        XCTAssertNil(model.pendingDubbing, "被拒绝的正式制作不得留下待保存音频")
        XCTAssertEqual(try store.list().count, 0, "被拒绝的正式制作不得落库")
        // 拒绝必须以一条明确的用户可见提示结束，而不是静默。
        XCTAssertNotNil(model.creatorMessage, "被拒绝时必须给出明确提示")
    }

    func testExplicitSaveAddsExactlyOneWorkAndIsIdempotent() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativeWorkStore(directory: directory)
        let audio = silentPreviewWAV(marker: 0x20)
        let creator = ScriptedRenderClient(audio: audio)
        let model = makeRenderModel(store: store, creator: creator)
        await model.refreshDiscovery()

        _ = await model.synthesizeAndSave(
            text: "  这是一段用于验证显式保存的文稿。  ",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        let pending = try XCTUnwrap(model.pendingDubbing)

        // 生成本身不写库；播放与导出也只读内存。
        XCTAssertEqual(try store.list().count, 0, "生成不自动入库")
        model.playPendingDubbing()
        XCTAssertEqual(try store.list().count, 0, "播放不自动入库")

        // 显式保存：恰好一条。
        let saved = try XCTUnwrap(model.savePendingDubbing())
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertNil(model.pendingDubbing, "保存成功后清空待保存状态")
        XCTAssertEqual(saved.id, pending.workID, "作品 ID 必须是生成时冻结的幂等键")

        // 再次点击保存（双击）：待保存状态已清空，因此是空操作，不新增作品。
        XCTAssertNil(model.savePendingDubbing())
        XCTAssertEqual(try store.list().count, 1)

        // 存储层按 id 去重：同一个 workID 重复写入仍是同一条，不会变成两份。
        try store.save(saved, audioData: audio)
        let works = try store.list()
        XCTAssertEqual(works.count, 1, "同一次生成重复保存只应有一条作品")
        XCTAssertEqual(works.first?.id, saved.id, "幂等键必须落在同一条作品上")
    }

    /// 保存的字节就是试听的那段，元数据取自冻结的 pending，而不是当前 UI 选项。
    func testSavedWorkCarriesTheFrozenGenerationIdentity() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativeWorkStore(directory: directory)
        let audio = silentPreviewWAV(marker: 0x40)
        let model = makeRenderModel(store: store, creator: ScriptedRenderClient(audio: audio))
        await model.refreshDiscovery()

        _ = await model.synthesizeAndSave(
            text: "身份冻结验证文稿。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        let pending = try XCTUnwrap(model.pendingDubbing)
        let work = try XCTUnwrap(model.savePendingDubbing())

        XCTAssertEqual(work.id, pending.workID)
        XCTAssertEqual(work.voiceID, pending.voiceID)
        XCTAssertEqual(work.voiceName, pending.voiceName)
        XCTAssertEqual(work.voiceRevision, pending.voiceRevision)
        XCTAssertEqual(work.planID, pending.planID)
        XCTAssertEqual(work.renderRevision, pending.renderRevision)
        XCTAssertEqual(work.scriptText, pending.scriptText, "文稿两端空白应已归一")

        let written = try store.loadAudio(for: work)
        XCTAssertEqual(written, pending.audioData, "保存的字节必须就是试听的那段")
        XCTAssertEqual(written, audio)

        // 同文稿同音色再次生成：renderRevision 递增，但仍是新的一次生成。
        _ = await model.synthesizeAndSave(
            text: "身份冻结验证文稿。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        let second = try XCTUnwrap(model.pendingDubbing)
        XCTAssertEqual(second.renderRevision, 2)
        XCTAssertNotEqual(second.workID, pending.workID, "新一次生成是新的作品")
        XCTAssertNotEqual(second.renderID, pending.renderID, "新一次生成是新的 render 身份")
        XCTAssertTrue(second.renderID.hasPrefix("render_"))
    }

    /// 保存失败必须保留 pending 以便重试，且不得留下半条作品。
    func testFailedSaveKeepsPendingAndAllowsRetry() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = CreativeWorkStore(
            directory: directory,
            fileManager: FailingWriteFileManager()
        )
        let audio = silentPreviewWAV(marker: 0x60)
        let model = makeRenderModel(store: failing, creator: ScriptedRenderClient(audio: audio))
        await model.refreshDiscovery()

        _ = await model.synthesizeAndSave(
            text: "保存失败应当保留待保存结果。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        let pending = try XCTUnwrap(model.pendingDubbing)

        XCTAssertNil(model.savePendingDubbing(), "写盘失败时返回 nil")
        XCTAssertEqual(model.pendingDubbing, pending, "失败后必须还能重试")
        XCTAssertNotNil(model.creatorMessage)

        // 换一个可写的 store 重试：同一次生成仍然只落一条。
        let good = CreativeWorkStore(directory: directory)
        let healthy = makeRenderModel(store: good, creator: ScriptedRenderClient(audio: audio))
        await healthy.refreshDiscovery()
        _ = await healthy.synthesizeAndSave(
            text: "保存失败应当保留待保存结果。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        _ = healthy.savePendingDubbing()
        XCTAssertEqual(try good.list().count, 1)
    }

    /// 未保存的结果不会被下一次生成静默顶掉；只有显式放弃才会丢弃。
    func testUnsavedPendingIsNotSilentlyDiscardedByANewGeneration() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativeWorkStore(directory: directory)
        let creator = ScriptedRenderClient(audio: silentPreviewWAV(marker: 0x10))
        let model = makeRenderModel(store: store, creator: creator)
        await model.refreshDiscovery()

        _ = await model.synthesizeAndSave(
            text: "第一段未保存的文稿。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        let first = try XCTUnwrap(model.pendingDubbing)

        model.startSynthesisAndSave(
            text: "第二段文稿。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        XCTAssertEqual(model.pendingDubbing, first, "未保存的结果不能被静默丢弃")
        XCTAssertNotNil(model.creatorMessage)

        // 显式放弃之后才可以重新生成。
        model.discardPendingDubbing()
        XCTAssertNil(model.pendingDubbing)
        model.startSynthesisAndSave(
            text: "第二段文稿。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.pendingDubbing?.scriptText, "第二段文稿。")

        // 取消进行中的生成不影响已完成但未保存的结果。
        let second = try XCTUnwrap(model.pendingDubbing)
        model.cancelSynthesis()
        XCTAssertEqual(model.pendingDubbing, second)
    }
}
