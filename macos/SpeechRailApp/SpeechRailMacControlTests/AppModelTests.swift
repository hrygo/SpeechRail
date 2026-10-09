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
    func testControlProbeStartsUnknownAndCancellationKeepsConfirmedFailure() async {
        let script = ControlProbeScript()
        let model = makeModel(transport: ClosureControlTransport { request in
            try await script.respond(to: request)
        })
        XCTAssertEqual(model.controlConnectionSummary, "未读取")
        XCTAssertEqual(model.jobQueueSummary, "未读取")
        await script.setStep(.failure)
        await model.refresh()
        XCTAssertEqual(model.controlConnectionSummary, "不可用")
        let confirmedMessage = model.controlPlaneMessage
        for step in [ControlProbeScript.Step.cancelList, .cancelStatus] {
            await script.setStep(step)
            await model.refresh()
            XCTAssertEqual(model.controlPlaneMessage, confirmedMessage)
            XCTAssertEqual(model.controlConnectionSummary, "不可用")
        }
        await script.setStep(.success)
        await model.refresh()
        XCTAssertNil(model.controlPlaneMessage)
        XCTAssertEqual(model.controlConnectionSummary, "已响应")
        await script.setStep(.cancelStatus)
        await model.refresh()
        XCTAssertEqual(model.controlConnectionSummary, "已响应")
    }

    func testControlProbeCancelledBeforeAnyResultRemainsUnknown() async {
        let model = makeModel(transport: ClosureControlTransport { _ in
            throw CancellationError()
        })
        await model.refresh()
        XCTAssertEqual(model.controlConnectionSummary, "未读取")
    }

    func testJobQueueDistinguishesAbsentFalseTrueAndFailedHealthRead() async {
        let health = HealthProbeScript()
        let model = AppModel(
            transport: ClosureControlTransport { _ in throw CancellationError() },
            apiClient: health, creatorClient: UnavailableCreatorClient()
        )
        XCTAssertEqual(model.jobQueueSummary, "未读取")
        for (ready, expected) in [(nil, "未读取"), (true, "可用"), (false, "未就绪")] {
            await health.setSnapshot(HealthSnapshot(jobSpoolReady: ready))
            await model.refresh()
            XCTAssertEqual(model.jobQueueSummary, expected)
        }
        await health.setSnapshot(nil)
        await model.refresh()
        XCTAssertEqual(model.health?.jobSpoolReady, false, "失败不清掉旧快照")
        XCTAssertEqual(model.jobQueueSummary, "未读取", "旧快照不能冒充这次的读取事实")
    }

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
            mode: "system",
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
                ttsModelRevision: "global-tts-catalog"
            )
        )
        XCTAssertEqual(
            facade.realtimeBinding(),
            RealtimeCapabilityBinding(asrModelRevision: "asr-model-catalog")
        )
    }

    /// 克隆音色必须 pin `tts_clone` 槽位的号，而不是 voice 自带的 model 号。
    ///
    /// 回归线上故障：助手选 clone 音色时 App 发的是 voice 条目自带的 model 号，
    /// 服务端按 mode 取 `tts_clone` 制品比对，永不对等，每次都 409
    /// `model_revision_conflict`。system 音色走 `tts` 槽位不受影响。
    func testRealtimeBindingForCloneVoicePinsCloneSlotRevision() {
        let voice = SafeVoiceEntry(
            id: "wom-clone-1",
            name: "克隆音色",
            aliases: ["clone-voice"],
            mode: "clone",
            available: true,
            availabilityReason: .available,
            voiceRevision: "vr_22222222222222222222222222222222",
            voiceIdentityAssurance: .contentAddressed,
            model: ConfiguredModelIdentity(
                assurance: .configuredCatalog,
                artifact: "clone-base",
                catalogRevision: "voice-self-model-catalog"
            ),
            descriptors: SafeVoiceDescriptor(
                voiceMode: "clone",
                locales: [],
                styleTags: [],
                pitchBand: "unknown",
                timbreFamily: "unknown",
                baselinePace: "unknown",
                sourceType: "generated_reference",
                metadataMethod: "declared_only"
            ),
            operations: [
                "realtime_speech": JSONValue(.object([
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
                "tts_clone": ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    artifact: "clone-base",
                    catalogRevision: "clone-slot-catalog"
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
            facade.realtimeBinding(for: "clone-voice"),
            RealtimeCapabilityBinding(
                asrModelRevision: "asr-model-catalog",
                canonicalVoiceID: "wom-clone-1",
                voiceRevision: "vr_22222222222222222222222222222222",
                ttsModelRevision: "clone-slot-catalog"
            )
        )
    }

    /// 未知 mode 不猜制品：binding 直接 fail-closed，而不是拿一个服务端
    /// 永远比不上的号去建连。
    func testRealtimeBindingRejectsUnknownVoiceMode() {
        let voice = SafeVoiceEntry(
            id: "voice-unknown-mode",
            name: "未知模式音色",
            aliases: ["unknown-mode-voice"],
            mode: "design",
            available: true,
            availabilityReason: .available,
            voiceRevision: "vr_33333333333333333333333333333333",
            voiceIdentityAssurance: .contentAddressed,
            model: ConfiguredModelIdentity(
                assurance: .configuredCatalog,
                artifact: "design-artifact",
                catalogRevision: "voice-self-model-catalog"
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
        // 快照里故意不放 voice_design 槽位：未知 mode 取不到号必须 fail-closed。
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

        XCTAssertNil(facade.realtimeBinding(for: "unknown-mode-voice"))
    }

    /// instruction 音色没有 runtime 合成角色：Realtime 建连不为它 pin 任何制品号，
    /// 即使快照里有 voice_design 槽位也直接 fail-closed。
    func testRealtimeBindingRejectsInstructionVoiceMode() {
        let voice = SafeVoiceEntry(
            id: "voice-instruction-1",
            name: "设计音色",
            aliases: ["instruction-voice"],
            mode: "instruction",
            available: true,
            availabilityReason: .available,
            voiceRevision: "vr_44444444444444444444444444444444",
            voiceIdentityAssurance: .contentAddressed,
            model: ConfiguredModelIdentity(
                assurance: .configuredCatalog,
                artifact: "tts-design",
                catalogRevision: "design-self-model-revision"
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
                "voice_design": ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    artifact: "tts-design",
                    catalogRevision: "design-slot-revision"
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

        XCTAssertNil(facade.realtimeBinding(for: "instruction-voice"))
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
        // pin 取的是快照顶层按 mode 分槽的制品号（system→tts），
        // 所以“没发布模型身份”复现为顶层 tts 槽位缺 catalogRevision。
        let voice = Self.voice(voiceRevision: nil)
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
                    assurance: .unknown,
                    artifact: nil
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

        XCTAssertNil(
            AppCapabilityFacade(
                snapshot: snapshot,
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
                "tts": ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    artifact: "global-tts",
                    catalogRevision: "voice-model-catalog"
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
        let revision = "vr_" + String(repeating: "a", count: 32)
        let creator = VoiceOutputCheckCreatorClient(
            response: VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(
                    status: .pass,
                    runID: "vq_0123456789abcdef0123456789abcdef"
                ),
                validationPersisted: false
            ),
            voices: [voiceOutputCheckVoice(id: "voice_clone_a", revision: revision)]
        )
        let model = await makeVoiceOutputCheckModel(creatorClient: creator)

        let state = await model.checkVoiceOutput(voiceID: "voice_clone_a")

        guard case .passedNotPersisted(let voiceID, _) = state else {
            return XCTFail("unpersisted pass must not be reported as accepted, got \(state)")
        }
        XCTAssertEqual(voiceID, "voice_clone_a")
        XCTAssertEqual(state.voiceRevision, revision)
        XCTAssertEqual(state.resultMessage, "检查已完成，但结果未保存，请重试。")
        XCTAssertFalse(state.isRunning)
    }

    /// A recorded pass is reported as accepted, and the wording makes clear it is
    /// a past observation rather than a standing production confirmation.
    func testVoiceOutputCheckWithPersistedPassIsAccepted() async {
        let revision = "vr_" + String(repeating: "a", count: 32)
        let creator = VoiceOutputCheckCreatorClient(
            response: VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(
                    status: .pass,
                    runID: "vq_0123456789abcdef0123456789abcdef"
                ),
                validationPersisted: true
            ),
            voices: [voiceOutputCheckVoice(id: "voice_clone_a", revision: revision)]
        )
        let model = await makeVoiceOutputCheckModel(creatorClient: creator)

        let state = await model.checkVoiceOutput(voiceID: "voice_clone_a")

        guard case .passed(let voiceID, _, let runID) = state else {
            return XCTFail("recorded pass must be reported as accepted, got \(state)")
        }
        XCTAssertEqual(voiceID, "voice_clone_a")
        XCTAssertEqual(state.voiceRevision, revision)
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
            ),
            voices: [voiceOutputCheckVoice(id: "voice_clone_a")]
        )
        let model = await makeVoiceOutputCheckModel(creatorClient: creator)

        let state = await model.checkVoiceOutput(voiceID: "voice_clone_a")

        guard case .failed = state else {
            return XCTFail("a reject report must not be reported as accepted, got \(state)")
        }
        XCTAssertEqual(state.resultMessage, "配音效果检查未通过：服务生成的参考音频无效，请重试或打开诊断")
    }

    func testVoiceOutputCheckFailsClosedWhenVoiceRevisionChangesDuringCheck() async {
        let originalRevision = "vr_" + String(repeating: "a", count: 32)
        let updatedRevision = "vr_" + String(repeating: "b", count: 32)
        let voiceID = "voice_clone_revision"
        let creator = VoiceOutputCheckCreatorClient(
            response: VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(status: .pass, runID: "vq_stale"),
                validationPersisted: true
            ),
            voices: [voiceOutputCheckVoice(id: voiceID, revision: originalRevision)]
        )
        await creator.setVoicesAfterNextQualityRun([
            voiceOutputCheckVoice(id: voiceID, revision: updatedRevision)
        ])
        let model = await makeVoiceOutputCheckModel(creatorClient: creator)

        let state = await model.checkVoiceOutput(voiceID: voiceID)

        guard case let .error(actualVoiceID, actualRevision, message) = state else {
            return XCTFail("a check against an obsolete revision must fail closed, got \(state)")
        }
        XCTAssertEqual(actualVoiceID, voiceID)
        XCTAssertEqual(actualRevision, updatedRevision)
        XCTAssertEqual(message, "检查期间音色版本发生变化，请重新检查。")
    }

    /// A check that started for one voice must not overwrite the state after the
    /// user switched to a different voice and started a new check.
    func testLateVoiceOutputCheckResultDoesNotPolluteNewerSelection() async throws {
        let revision = "vr_" + String(repeating: "a", count: 32)
        let creator = VoiceOutputCheckCreatorClient(
            response: VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(status: .pass, runID: "vq_first"),
                validationPersisted: true
            ),
            voices: [
                voiceOutputCheckVoice(id: "voice_clone_a", revision: revision),
                voiceOutputCheckVoice(id: "voice_clone_b", revision: revision)
            ]
        )
        let model = await makeVoiceOutputCheckModel(creatorClient: creator)

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
            ),
            voices: [voiceOutputCheckVoice(id: "voice_clone_a")]
        )
        let model = await makeVoiceOutputCheckModel(creatorClient: creator)

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

    private func makeVoiceOutputCheckModel(
        creatorClient: VoiceOutputCheckCreatorClient
    ) async -> AppModel {
        let model = makeModel(
            transport: ClosureControlTransport { request in
                ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .completed
                )
            },
            creatorClient: creatorClient
        )
        let didLoadVoices = await model.refreshCreatorVoices()
        XCTAssertTrue(didLoadVoices, "the check needs an authoritative voice revision")
        return model
    }

    private func voiceOutputCheckVoice(
        id: String,
        revision: String = "vr_11111111111111111111111111111111"
    ) -> CreatorVoice {
        CreatorVoice(
            id: id,
            name: id,
            available: true,
            mode: "clone",
            revision: revision
        )
    }

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

private actor ControlProbeScript {
    enum Step: Sendable { case success, failure, cancelList, cancelStatus }
    private var step = Step.success

    func setStep(_ value: Step) { step = value }

    func respond(to request: ControlRequest) throws -> ControlResponse {
        if step == .failure { throw CancelTransportFailure() }
        if (step == .cancelList && request.command == .profileList)
            || (step == .cancelStatus && request.command == .profileStatus) {
            throw CancellationError()
        }
        return ControlResponse(
            requestID: request.requestID, command: request.command, status: .completed
        )
    }
}

private actor HealthProbeScript: ServiceDiagnosticsClient {
    nonisolated var port: Int? { nil }
    private var snapshot: HealthSnapshot?
    func setSnapshot(_ value: HealthSnapshot?) { snapshot = value }
    func fetchHealthSnapshot() async throws -> HealthSnapshot {
        guard let snapshot else { throw ServiceAPIClientError.requestFailed }
        return snapshot
    }
    func fetchMetrics() async throws -> RuntimeMetricsSnapshot {
        throw ServiceAPIClientError.requestFailed
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
    private var voices: [CreatorVoice]
    private var voicesAfterNextQualityRun: [CreatorVoice]?

    init(
        response: VoiceQualityRunResponse,
        voices: [CreatorVoice] = []
    ) {
        self.response = response
        self.voices = voices
    }

    func setResponse(_ value: VoiceQualityRunResponse) {
        response = value
    }

    func setVoicesAfterNextQualityRun(_ value: [CreatorVoice]) {
        voicesAfterNextQualityRun = value
    }

    func runCount() -> Int { runs }

    func fetchVoices() async throws -> [CreatorVoice] { voices }

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
        if let voicesAfterNextQualityRun {
            voices = voicesAfterNextQualityRun
            self.voicesAfterNextQualityRun = nil
        }
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

    /// 有界等待 fake 客户端接住请求。无界自旋在条件永不成立时会把整个套件挂住，
    /// 而不是让这条用例失败——失败要能指出是哪一步没发生。
    func waitUntilHeld(file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<600 {
            if heldContinuation != nil { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("等待 fake 客户端接住请求超时（600ms）", file: file, line: line)
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
            models: [
                "tts": ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    artifact: "global-tts",
                    catalogRevision: "tts-model-revision"
                ),
            ],
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
    private let renderResultOverride: SpeechRenderResult?
    /// 前 `succeedingRenders` 次正式渲染成功，之后一律失败。
    ///
    /// #182 要复现的是"第一次成功、第二次失败"：只有先成功过一次，页面才会
    /// 留下 `lastCreatedWork`，第二次失败才可能被那件旧成品遮住。`nil` 表示
    /// 不限次数（保持既有用例的行为不变）。
    private var succeedingRenders: Int?

    init(
        audio: Data,
        renderError: Error? = nil,
        renderResult: SpeechRenderResult? = nil,
        succeedingRenders: Int? = nil
    ) {
        self.audio = audio
        self.renderError = renderError
        self.renderResultOverride = renderResult
        self.succeedingRenders = succeedingRenders
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
        if let succeedingRenders {
            guard succeedingRenders > 0 else { throw ServiceAPIClientError.requestFailed }
            self.succeedingRenders = succeedingRenders - 1
        }
        if let renderResultOverride {
            return renderResultOverride
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

private struct SavedReceiptClient: SpeechRailReceiptClient {
    let receipt: RenderReceipt
    func fetchReceipt(id: String) async throws -> RenderReceipt { receipt }
    func fetchReceipt(byRequestID requestID: String) async throws -> RenderReceipt { receipt }
}

/// 写盘失败的 FileManager，用来验证"保存失败仍保留 pending、可重试"。
/// Fails the first index write and then behaves normally, so a retry has to
/// travel through the same recovery path a real disk-full retry would.
private final class FailOnceIndexWriteGate {
    private var remainingFailures = 1

    func makeOperations() -> CreativeWorkFileOperations {
        CreativeWorkFileOperations(writeInterceptor: { [self] url, _ in
            guard remainingFailures > 0, url.lastPathComponent == "works.json" else {
                return
            }
            remainingFailures -= 1
            throw CocoaError(.fileWriteOutOfSpace)
        })
    }
}

/// 把某一次渲染挂住，直到测试显式放行。用来构造受控的异步交错。
private actor RenderGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var shouldFail = false

    /// 挂住这次渲染。返回 `true` 表示放行之后应当抛出，
    /// 用来构造「响应在途、项目已换代、结果是失败」的交错。
    func wait() async -> Bool {
        guard !isOpen else { return shouldFail }
        await withCheckedContinuation { continuations.append($0) }
        return shouldFail
    }

    func open(failing: Bool = false) {
        isOpen = true
        shouldFail = failing
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// 段落返修用的正式制作替身：音色目录里只有一件可用音色，
/// 渲染结果携带与原作品相同的配方摘要，因此候选可被采用。
private actor DubbingRenderClient: SpeechRailCreatorClient {
    private(set) var renderCalls: [(text: String, voiceID: String, speed: Double)] = []
    private let audio: Data
    private let renderResult: SpeechRenderResult
    private let voice: CreatorVoice
    private let renderGates: [RenderGate]

    init(
        audio: Data,
        recipe: RenderRecipeSnapshot,
        voice: CreatorVoice,
        renderGates: [RenderGate] = []
    ) {
        self.audio = audio
        self.renderResult = SpeechRenderResult(
            audioData: audio,
            planID: "plan_segment",
            voiceRevision: voice.revision,
            planSHA256: "plan_sha_segment",
            pcmSHA256: "pcm_sha_segment",
            recipe: recipe,
            requestID: "req-segment",
            receiptID: "rr_0123456789abcdef0123456789abcdef",
            receiptStatus: .completed,
            receiptCompletedAt: 2,
            provenance: RenderProvenance(state: .verified, reason: nil)
        )
        self.voice = voice
        self.renderGates = renderGates
    }

    func fetchVoices() async throws -> [CreatorVoice] { [voice] }

    func fetchVoice(id: String) async throws -> CreatorVoice {
        guard id == voice.id else { throw ServiceAPIClientError.requestFailed }
        return voice
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
        // 按调用次序取闸门：关着的那些把对应这次渲染挂住，用来构造受控的异步交错。
        let index = renderCalls.count - 1
        if index < renderGates.count, await renderGates[index].wait() {
            throw ServiceAPIClientError.requestFailed
        }
        return renderResult
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

extension AppModelTests {
    private static func renderVoice() -> CreatorVoice {
        CreatorVoice(id: "ryan", name: "动感英语男声", available: true, mode: "system")
    }

    private func makeRenderModel(
        store: CreativeWorkStore,
        creator: any SpeechRailCreatorClient,
        receiptClient: (any SpeechRailReceiptClient)? = nil
    ) -> AppModel {
        AppModel(
            transport: ClosureControlTransport { request in
                Self.modelCatalogResponse(for: request)
            },
            apiClient: UnavailableDiagnosticsClient(),
            discoveryClient: PreviewDiscoveryClient(snapshot: Self.previewSnapshot()),
            creatorClient: creator,
            receiptClient: receiptClient,
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

    /// #182：保存过一次作品之后，后续生成失败**必须**仍然有一条用户可见的提示。
    ///
    /// 旧实现把结果位写成 `pending / lastCreatedWork / creatorMessage` 的互斥链。
    /// `lastCreatedWork` 只在删除那件作品时才清空，于是它会永远遮住失败——
    /// 而"保存过至少一件作品"恰恰是配音台的正常状态。
    ///
    /// 现在结果位收敛成 `DubbingDeskSlot`（**故意没有失败分支**），失败与结果
    /// 并排呈现。本用例锁定两件事同时可得。
    func testAFailedGenerationStaysVisibleAfterAnEarlierWorkWasSaved() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-fail-after-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativeWorkStore(directory: directory)
        let audio = silentPreviewWAV(marker: 0x20)
        // 只让第一次渲染成功。
        let creator = ScriptedRenderClient(audio: audio, succeedingRenders: 1)
        let model = makeRenderModel(store: store, creator: creator)
        await model.refreshDiscovery()

        // 第一次：成功并保存，让页面进入"有成品"的正常状态。
        _ = await model.synthesizeAndSave(
            text: "第一次生成，这段会成功。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        let saved = try XCTUnwrap(model.savePendingDubbing())
        guard case .savedWork(let slotted) = model.dubbingDeskSlot else {
            return XCTFail("保存后结果位应是已保存的成品")
        }
        XCTAssertEqual(slotted.id, saved.id)
        XCTAssertNil(model.creatorMessage, "成功收尾时不得残留提示")

        // 第二次：失败。旧成品仍在，但失败提示必须同时可得。
        _ = await model.synthesizeAndSave(
            text: "第二次生成，这段会失败。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        XCTAssertNotNil(
            model.creatorMessage,
            "生成失败时必须仍有一条提示——旧成品不得把它遮住（#182）"
        )
        guard case .savedWork = model.dubbingDeskSlot else {
            return XCTFail("失败不改变已有成品，结果位仍应是那件已保存作品")
        }
        XCTAssertNil(model.pendingDubbing, "失败的生成不得留下待保存音频")

        // 结构性保证：DubbingDeskSlot 根本没有失败分支，所以"遮蔽"在类型上
        // 不可能发生——视图读的是这两者，不再自己串 if let。
        let calls = await creator.renderCalls
        XCTAssertEqual(calls.count, 2, "两次生成都真的发出了请求")
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

    /// 配方与追溯状态在生成时冻结，保存时原样落盘；
    /// 文件字节摘要由作品库在提交时补上。
    func testSavedWorkCarriesTheFrozenRecipeAndProvenance() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-recipe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativeWorkStore(directory: directory)
        let audio = silentPreviewWAV(marker: 0x41)
        // #189：fixture 的服务端摘要必须是 data chunk 的真摘要，
        // 否则落盘比对会诚实地降为 partial（这正是本测试要覆盖的语义）。
        let audioDigest = try AudioDigest.sha256HexOfPCM(in: audio)
        let recipe = RenderRecipeSnapshot(
            state: .complete,
            missingFields: [],
            digest: String(repeating: "e", count: 64),
            rawTextSHA256: String(repeating: "a", count: 64),
            acousticTextSHA256: String(repeating: "b", count: 64),
            normalizationRevision: "tts_norm_v1",
            plannerRevision: "tts_bounded_v1",
            pronunciationRevision: "unused",
            voiceID: "ryan",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            voiceMode: "system",
            modelRole: "tts",
            modelArtifact: "tts-artifact",
            modelArtifactRevision: "cat-1",
            engineRevision: "rt_" + String(repeating: "d", count: 64),
            effectiveSpeed: 1.0,
            effectiveLanguage: "zh",
            seedPolicy: "derived",
            outputFormat: "wav",
            sampleRate: 24_000,
            channels: 1
        )
        let creator = ScriptedRenderClient(
            audio: audio,
            renderResult: SpeechRenderResult(
                audioData: audio,
                planID: "plan_" + String(repeating: "f", count: 32),
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                planSHA256: String(repeating: "c", count: 64),
                pcmSHA256: audioDigest,
                recipe: recipe,
                requestID: "req-production",
                receiptID: "rr_0123456789abcdef0123456789abcdef",
                receiptStatus: .completed,
                receiptCompletedAt: 2,
                provenance: RenderProvenance(state: .verified, reason: nil)
            )
        )
        let model = makeRenderModel(store: store, creator: creator)
        await model.refreshDiscovery()

        _ = await model.synthesizeAndSave(
            text: "配方落盘验证文稿。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        let pending = try XCTUnwrap(model.pendingDubbing)
        let work = try XCTUnwrap(model.savePendingDubbing())

        XCTAssertNil(
            pending.provenance.audioFileSHA256,
            "生成时还没有文件，摘要不能提前编造"
        )
        XCTAssertEqual(work.provenance.state, .verified)
        XCTAssertEqual(work.provenance.planSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(work.provenance.pcmSHA256, audioDigest)
        XCTAssertEqual(work.provenance.recipe, recipe)
        XCTAssertNotNil(work.provenance.audioFileSHA256, "提交后必须记录真实文件摘要")

        // 重新打开作品库：配方与追溯状态仍然可读，不依赖服务还在运行。
        let reopened = try XCTUnwrap(CreativeWorkStore(directory: directory).list().first)
        XCTAssertEqual(reopened.provenance.recipe, recipe)
        XCTAssertEqual(reopened.provenance.state, .verified)
        XCTAssertEqual(reopened.provenance.audioFileSHA256, work.provenance.audioFileSHA256)
        XCTAssertEqual(reopened.provenance.requestID, "req-production")
        XCTAssertEqual(reopened.provenance.receiptID, "rr_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(reopened.provenance.receiptStatus, .completed)
        XCTAssertEqual(reopened.provenance.receiptCompletedAt, 2)

        let laterReceipt = try JSONDecoder().decode(RenderReceipt.self, from: Data("""
        {
          "receipt_id": "rr_0123456789abcdef0123456789abcdef",
          "request_id": "req-production", "status": "cancelled",
          "voice": {}, "model": {}, "audio": {},
          "error_code": null, "created_at": 1, "completed_at": 3
        }
        """.utf8))
        let queryModel = makeRenderModel(
            store: store, creator: creator,
            receiptClient: SavedReceiptClient(receipt: laterReceipt)
        )
        let queried = try await queryModel.lookupWorkReceipt(reopened)
        XCTAssertEqual(queried.status, .cancelled)
        XCTAssertEqual(try store.list().first?.provenance, reopened.provenance)
    }

    /// 回执拿不到时音频照常保存，追溯状态照实标为不可用，绝不补造身份。
    func testAnUntraceableRenderStillSavesItsAudio() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-untraced-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativeWorkStore(directory: directory)
        let audio = silentPreviewWAV(marker: 0x42)
        let creator = ScriptedRenderClient(
            audio: audio,
            renderResult: SpeechRenderResult(
                audioData: audio,
                planID: nil,
                voiceRevision: nil,
                provenance: RenderProvenance(state: .unavailable, reason: "receipt_unavailable")
            )
        )
        let model = makeRenderModel(store: store, creator: creator)
        await model.refreshDiscovery()

        _ = await model.synthesizeAndSave(
            text: "回执缺失也要保住音频。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        let work = try XCTUnwrap(model.savePendingDubbing())

        XCTAssertNil(work.provenance.recipe)
        XCTAssertNil(work.provenance.planSHA256)
        XCTAssertNil(work.planID)
        XCTAssertEqual(work.provenance.state, .unavailable)
        XCTAssertEqual(work.provenance.reason, "receipt_unavailable")
        XCTAssertEqual(try store.loadAudio(for: work), audio, "追溯不完整不等于丢掉音频")
    }

    /// #189：服务端摘要与本地 data 摘要对不上时，音频保留、
    /// provenance 降为 `.partial(audio_digest_mismatch)`——缺失与不匹配不同码。
    func testDigestMismatchKeepsAudioAndMarksPartial() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-mismatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativeWorkStore(directory: directory)
        let audio = silentPreviewWAV(marker: 0x43)
        let creator = ScriptedRenderClient(
            audio: audio,
            renderResult: SpeechRenderResult(
                audioData: audio,
                planID: "plan_" + String(repeating: "f", count: 32),
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                planSHA256: String(repeating: "c", count: 64),
                // 假摘要：与 data chunk 真摘要必然不一致。
                pcmSHA256: String(repeating: "9", count: 64),
                recipe: nil,
                provenance: RenderProvenance(state: .verified, reason: nil)
            )
        )
        let model = makeRenderModel(store: store, creator: creator)
        await model.refreshDiscovery()

        _ = await model.synthesizeAndSave(
            text: "摘要对不上也要保住音频。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        let work = try XCTUnwrap(model.savePendingDubbing())

        XCTAssertEqual(work.provenance.state, .partial)
        XCTAssertEqual(work.provenance.reason, "audio_digest_mismatch")
        XCTAssertEqual(try store.loadAudio(for: work), audio, "摘要不匹配不等于丢掉音频")
    }

    /// 保存失败必须保留 pending 以便重试，且不得留下半条作品。
    func testFailedSaveKeepsPendingAndAllowsRetry() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = FailOnceIndexWriteGate()
        let failing = CreativeWorkStore(
            directory: directory,
            fileOperations: gate.makeOperations()
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

        // 同一个 AppModel、同一个待保存结果重试：不重新生成，也不换作品标识。
        let committed = try XCTUnwrap(model.savePendingDubbing())
        XCTAssertNil(model.pendingDubbing, "保存成功后待保存结果才被清空")
        XCTAssertEqual(committed.id, pending.workID)
        XCTAssertEqual(try failing.list().map(\.id), [pending.workID], "同一次生成只落一条")
        XCTAssertEqual(try failing.loadAudio(for: committed), pending.audioData)
        XCTAssertNil(model.savePendingDubbing(), "没有待保存内容时不再写盘")
        XCTAssertEqual(try failing.list().count, 1)
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

// MARK: - (D) 段落返修：只重做受影响范围，采用/撤销，导出与正文一致

extension AppModelTests {
    /// 有界等待：只用来等异步状态机落地，不作为同步手段。
    private func waitUntilDubbing(
        _ condition: () -> Bool,
        iterations: Int = 600,
        message: String = "condition was not met"
    ) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(message)
    }

    /// 等待一个需要 `await` 才能读到的条件。用于跨 actor 边界的在途状态。
    private func waitUntilDubbingAsync(
        _ condition: () async -> Bool,
        iterations: Int = 600,
        message: String = "condition was not met"
    ) async throws {
        for _ in 0..<iterations {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(message)
    }

    /// 让已放行的任务把收尾跑完。这里刻意不 `XCTFail`：
    /// 收尾本身没有可观测的状态变化，只有它**做错之后**才会被断言抓到。
    private func settleDubbing(iterations: Int = 200) async throws {
        for _ in 0..<iterations {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func dubbingRecipe(
        digest: String?,
        voiceID: String = "ryan",
        effectiveSpeed: Double = 1.0
    ) -> RenderRecipeSnapshot {
        RenderRecipeSnapshot(
            state: digest == nil ? .partial : .complete,
            missingFields: digest == nil ? ["parameters.seed_policy"] : [],
            digest: digest,
            voiceID: voiceID,
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            voiceMode: "system",
            effectiveSpeed: effectiveSpeed,
            outputFormat: "wav",
            sampleRate: 24_000,
            channels: 1
        )
    }

    private static func dubbingVoice() -> CreatorVoice {
        CreatorVoice(
            id: "ryan",
            name: "动感英语男声",
            available: true,
            mode: "system",
            revision: "vr_0123456789abcdef0123456789abcdef"
        )
    }

    private static func dubbingWork(
        script: String,
        provenance: RenderProvenanceSnapshot,
        title: String = "段落返修样例"
    ) -> CreativeWork {
        CreativeWork(
            id: "work_dubbing_source",
            title: title,
            scriptText: script,
            voiceID: "ryan",
            voiceName: "动感英语男声",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            planID: "plan_source",
            renderRevision: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 1,
            audioFileName: "work_dubbing_source.wav",
            provenance: provenance
        )
    }

    private func makeDubbingModel(
        creator: any SpeechRailCreatorClient,
        recipeDigest: String?
    ) -> (AppModel, CreativeWorkStore, DubbingProjectStore) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-dubbing-\(UUID().uuidString)", isDirectory: true)
        let works = CreativeWorkStore(
            directory: root.appendingPathComponent("Works", isDirectory: true)
        )
        let projects = DubbingProjectStore(
            directory: root.appendingPathComponent("Projects", isDirectory: true)
        )
        let model = AppModel(
            transport: ClosureControlTransport { request in
                Self.modelCatalogResponse(for: request)
            },
            apiClient: UnavailableDiagnosticsClient(),
            discoveryClient: PreviewDiscoveryClient(snapshot: Self.previewSnapshot()),
            creatorClient: creator,
            workStore: works,
            dubbingProjectStore: projects
        )
        let provenance = RenderProvenanceSnapshot(
            state: recipeDigest == nil ? .partial : .verified,
            reason: nil,
            planSHA256: "plan_sha_source",
            recipe: Self.dubbingRecipe(digest: recipeDigest),
            pcmSHA256: "pcm_sha_source"
        )
        return (model, works, projects)
    }

    private func saveSourceWork(
        into store: CreativeWorkStore,
        script: String,
        recipeDigest: String?,
        title: String? = nil,
        workID: String = "work_dubbing_source"
    ) throws -> CreativeWork {
        var work = Self.dubbingWork(
            script: script,
            provenance: RenderProvenanceSnapshot(
                state: recipeDigest == nil ? .partial : .verified,
                reason: nil,
                planSHA256: "plan_sha_source",
                recipe: Self.dubbingRecipe(digest: recipeDigest),
                pcmSHA256: "pcm_sha_source"
            ),
            title: title ?? "段落返修样例"
        )
        if workID != "work_dubbing_source" {
            work = CreativeWork(
                id: workID,
                title: work.title,
                scriptText: work.scriptText,
                voiceID: work.voiceID,
                voiceName: work.voiceName,
                voiceRevision: work.voiceRevision,
                planID: work.planID,
                renderRevision: work.renderRevision,
                createdAt: work.createdAt,
                durationSeconds: work.durationSeconds,
                audioFileName: "\(workID).wav",
                provenance: work.provenance
            )
        }
        return try store.save(work, audioData: silentPreviewWAV(marker: 0x44))
    }

    /// 打开段落项目只拆文稿，不搬走原作品音频，也不产生任何候选。
    func testOpeningDubbingProjectSplitsScriptWithoutTouchingSourceAudio() throws {
        let creator = ScriptedRenderClient(audio: silentPreviewWAV(marker: 0x50))
        let (model, works, projects) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        let work = try saveSourceWork(
            into: works,
            script: "第一段正文。\n第二段正文。",
            recipeDigest: "digest-1"
        )
        let sourceAudio = try works.loadAudio(for: work)

        let project = try XCTUnwrap(model.startDubbingProject(for: work))

        XCTAssertEqual(project.segments.map(\.text), ["第一段正文。", "第二段正文。"])
        XCTAssertEqual(model.dubbingCandidates, [], "打开项目不生成任何候选")
        XCTAssertNil(model.dubbingExportBundle)
        XCTAssertEqual(try works.loadAudio(for: work), sourceAudio, "原作品音频原地不动")
        XCTAssertEqual(try projects.list().count, 1)
    }

    /// 版本漂移拒绝旧项目采用；显式建立新项目后可继续生成与采用。
    func testChangedConditionsCanStartANewProjectWithoutRewritingTheOldOne() async throws {
        let currentRecipe = Self.dubbingRecipe(digest: "current-digest")
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x61),
            recipe: currentRecipe, voice: Self.dubbingVoice()
        )
        let (model, works, projects) = makeDubbingModel(creator: creator, recipeDigest: "old-digest")
        await model.refreshDiscovery()
        await model.refreshCreatorVoices()
        let work = Self.dubbingWork(
            script: "第一段。\n第二段。",
            provenance: RenderProvenanceSnapshot(
                state: .verified, reason: nil,
                recipe: RenderRecipeSnapshot(
                    state: .complete, missingFields: [], digest: "old-digest",
                    voiceID: "ryan", voiceMode: "system",
                    modelArtifactRevision: "old-catalog", effectiveSpeed: 1
                )
            )
        )
        try works.save(work, audioData: silentPreviewWAV(marker: 0x10))
        let original = try XCTUnwrap(model.startDubbingProject(for: work))
        let storedOriginal = try XCTUnwrap(projects.list().first { $0.id == original.id })
        XCTAssertNotNil(model.dubbingConditionsMessage, "入口立即提示可确认的模型版本漂移")
        let segment = try XCTUnwrap(original.segments.first)
        model.startDubbingSegmentRedo(segment.id)
        try await waitUntilDubbing { model.dubbingBusySegmentID == nil && !model.dubbingCandidates.isEmpty }
        let changed = try XCTUnwrap(model.dubbingCandidates.first)
        XCTAssertFalse(model.adoptDubbingCandidate(changed))
        XCTAssertFalse(model.dubbingMessage?.contains("重新生成") == true)
        XCTAssertTrue(model.rebuildDubbingProject(using: changed))
        let rebuilt = try XCTUnwrap(model.dubbingProject)
        XCTAssertNotEqual(rebuilt.id, original.id)
        XCTAssertEqual(rebuilt.recipe.recipe?.digest, "current-digest")
        XCTAssertTrue(model.dubbingCandidates.isEmpty)
        XCTAssertTrue(rebuilt.segments.allSatisfy { $0.acceptedCandidateID == nil })
        XCTAssertEqual(try projects.list().first { $0.id == original.id }, storedOriginal)
        XCTAssertEqual(try projects.loadAudio(for: changed), silentPreviewWAV(marker: 0x61))

        model.startDubbingSegmentRedo(try XCTUnwrap(rebuilt.segments.first).id)
        try await waitUntilDubbing { model.dubbingBusySegmentID == nil && !model.dubbingCandidates.isEmpty }
        XCTAssertTrue(model.adoptDubbingCandidate(try XCTUnwrap(model.dubbingCandidates.first)))
        XCTAssertEqual(try projects.list().first { $0.id == original.id }, storedOriginal)
    }

    /// 只重做被点中的那一段：送出的文本只有这一段，其余候选与采用关系不变。
    func testRedoingOneSegmentOnlyRendersThatSegment() async throws {
        let recipe = Self.dubbingRecipe(digest: "digest-1")
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x60),
            recipe: recipe,
            voice: Self.dubbingVoice()
        )
        let (model, works, projects) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        await model.refreshCreatorVoices()
        let work = try saveSourceWork(
            into: works,
            script: "第一段正文。\n第二段正文。",
            recipeDigest: "digest-1"
        )
        let project = try XCTUnwrap(model.startDubbingProject(for: work))
        let secondSegment = try XCTUnwrap(project.segments.last)

        model.startDubbingSegmentRedo(secondSegment.id)
        try await waitUntilDubbing { model.dubbingBusySegmentID == nil && !model.dubbingCandidates.isEmpty }

        let calls = await creator.renderCalls
        XCTAssertEqual(calls.map(\.text), ["第二段正文。"], "只重做被点中的那一段")
        let candidate = try XCTUnwrap(model.dubbingCandidates.first)
        XCTAssertEqual(candidate.segmentID, secondSegment.id)
        let reopened = try XCTUnwrap(projects.candidates(forProject: project.id).first)
        XCTAssertEqual(reopened.provenance.requestID, "req-segment")
        XCTAssertEqual(reopened.provenance.receiptID, "rr_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(reopened.provenance.receiptStatus, .completed)
        XCTAssertEqual(reopened.provenance.receiptCompletedAt, 2)
        XCTAssertNil(
            project.segments.first?.acceptedCandidateID,
            "生成候选不会自动采用"
        )
        XCTAssertNotNil(model.dubbingMessage)
    }

    /// 重做必须用**当初那一次**的语速，而不是当前默认或 App 里的当前值。
    ///
    /// 配方摘要 `isValid` 是按 `recipe.digest` 逐字段算的，`effective_speed` 在其中。
    /// 语速一旦不同，新候选的摘要就对不上项目的摘要，采用会被判成
    /// 「制作条件与当前项目不一致」——用户看到的是「已生成新版本」，采用时却被拒。
    /// 这里让配方带一个**不等于 1.0** 的语速：默认语速与兜底值都是 1.0，
    /// 用 1.0 做断言等于什么都没考。
    func testRedoingASegmentUsesTheSpeedRecordedInTheRecipe() async throws {
        let recipe = Self.dubbingRecipe(digest: "digest-1", effectiveSpeed: 1.25)
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x61),
            recipe: recipe,
            voice: Self.dubbingVoice()
        )
        let (model, works, _) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        await model.refreshCreatorVoices()
        let work = try Self.dubbingWork(
            script: "第一段正文。\n第二段正文。",
            provenance: RenderProvenanceSnapshot(
                state: .verified,
                reason: nil,
                planSHA256: "plan_sha_source",
                recipe: recipe,
                pcmSHA256: "pcm_sha_source"
            )
        )
        let saved = try works.save(work, audioData: silentPreviewWAV(marker: 0x44))
        let project = try XCTUnwrap(model.startDubbingProject(for: saved))
        let secondSegment = try XCTUnwrap(project.segments.last)

        model.startDubbingSegmentRedo(secondSegment.id)
        try await waitUntilDubbing {
            model.dubbingBusySegmentID == nil && !model.dubbingCandidates.isEmpty
        }

        let calls = await creator.renderCalls
        XCTAssertEqual(calls.map(\.speed), [1.25], "重做必须沿用原作品记录下来的语速")
        // 语速对得上，摘要才可能对上；采用不应被「制作条件不一致」挡住。
        let candidate = try XCTUnwrap(model.dubbingCandidates.first)
        XCTAssertTrue(model.adoptDubbingCandidate(candidate), "语速一致时候选应当可采用")
    }

    /// 采用后可以撤销回到上一版；撤销只改引用，已保存的音频一个都不删。
    func testAdoptAndUndoAdoptionMoveBetweenCandidateVersions() async throws {
        let recipe = Self.dubbingRecipe(digest: "digest-1")
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x70),
            recipe: recipe,
            voice: Self.dubbingVoice()
        )
        let (model, works, projects) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        await model.refreshCreatorVoices()
        let work = try saveSourceWork(
            into: works,
            script: "只有一段正文。",
            recipeDigest: "digest-1"
        )
        let project = try XCTUnwrap(model.startDubbingProject(for: work))
        let segment = try XCTUnwrap(project.segments.first)

        model.startDubbingSegmentRedo(segment.id)
        try await waitUntilDubbing { model.dubbingBusySegmentID == nil && !model.dubbingCandidates.isEmpty }
        let first = try XCTUnwrap(model.dubbingCandidates.first)
        XCTAssertTrue(model.adoptDubbingCandidate(first))

        model.startDubbingSegmentRedo(segment.id)
        try await waitUntilDubbing { model.dubbingCandidates.count == 2 }
        let second = try XCTUnwrap(
            model.dubbingCandidates.first(where: { $0.id != first.id })
        )
        XCTAssertTrue(model.adoptDubbingCandidate(second))
        XCTAssertEqual(
            model.dubbingProject?.segments.first?.acceptedCandidateID,
            second.id
        )

        XCTAssertTrue(model.undoDubbingAdoption(inSegment: segment.id))
        XCTAssertEqual(
            model.dubbingProject?.segments.first?.acceptedCandidateID,
            first.id,
            "撤销回到上一版，而不是清空"
        )
        XCTAssertEqual(
            try projects.candidates(forProject: project.id).count,
            2,
            "撤销不删除任何候选音频"
        )
        // 采用过两次，就有两步历史：第二次撤销回到"最初没有采用任何候选"。
        XCTAssertTrue(
            model.undoDubbingAdoption(inSegment: segment.id),
            "还有一步历史时继续回退"
        )
        XCTAssertNil(model.dubbingProject?.segments.first?.acceptedCandidateID)
        XCTAssertFalse(
            model.undoDubbingAdoption(inSegment: segment.id),
            "没有更早的历史时不再回退"
        )
        XCTAssertEqual(
            model.dubbingProject?.segments.first?.acceptedCandidateID,
            nil,
            "被拒绝的撤销不改变当前采用项"
        )
    }

    /// 导出只在每段都有采用版本时发生，且音频样本与正文逐段对应。
    func testExportProducesAudioAndScriptFromAdoptedSegmentsOnly() async throws {
        let recipe = Self.dubbingRecipe(digest: "digest-1")
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x80, frames: 1_200),
            recipe: recipe,
            voice: Self.dubbingVoice()
        )
        let (model, works, _) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        await model.refreshCreatorVoices()
        let work = try saveSourceWork(
            into: works,
            script: "第一段正文。\n第二段正文。",
            recipeDigest: "digest-1"
        )
        let project = try XCTUnwrap(model.startDubbingProject(for: work))
        let first = try XCTUnwrap(project.segments.first)
        let second = try XCTUnwrap(project.segments.last)

        model.prepareDubbingExport()
        XCTAssertNil(model.dubbingExportBundle, "有段落没采用版本时不导出半成品")
        XCTAssertNotNil(model.dubbingMessage)

        model.startDubbingSegmentRedo(first.id)
        try await waitUntilDubbing { model.dubbingCandidates.count == 1 }
        XCTAssertTrue(model.adoptDubbingCandidate(try XCTUnwrap(model.dubbingCandidates.first)))
        model.prepareDubbingExport()
        XCTAssertNil(
            model.dubbingExportBundle,
            "还有段落没有采用版本时仍然拒绝导出"
        )

        model.startDubbingSegmentRedo(second.id)
        try await waitUntilDubbing { model.dubbingCandidates.count == 2 }
        let secondCandidate = try XCTUnwrap(
            model.dubbingCandidates.first(where: { $0.segmentID == second.id })
        )
        XCTAssertTrue(model.adoptDubbingCandidate(secondCandidate))

        model.prepareDubbingExport()
        let bundle = try XCTUnwrap(model.dubbingExportBundle)
        XCTAssertEqual(bundle.script, "第一段正文。\n第二段正文。")

        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: target) }
        XCTAssertTrue(model.writeDubbingExport(to: target))
        let wav = try Data(contentsOf: target.appendingPathComponent(bundle.audioFileName))
        let script = try String(
            contentsOf: target.appendingPathComponent(bundle.scriptFileName),
            encoding: .utf8
        )
        XCTAssertEqual(script, "第一段正文。\n第二段正文。")

        // 两段各 1_200 帧、每帧 2 字节：导出的 data chunk 就是两段样本顺序拼接。
        let pcm = try DubbingAudioExport.clip(fromWAV: wav).pcm
        XCTAssertEqual(pcm.count, 2 * 1_200 * 2)
        XCTAssertEqual(
            Array(pcm.prefix(2_400)),
            Array(try DubbingAudioExport.clip(fromWAV: silentPreviewWAV(marker: 0x80, frames: 1_200)).pcm)
        )
        XCTAssertNil(model.dubbingExportBundle, "写盘后清空待导出内容")
    }

    /// 成品文件名必须是用户在目录里**看得见**的名字。
    ///
    /// 作品名来自文稿首行，用户写什么都会进来。以点开头的名字在 macOS 上是隐藏
    /// 文件：导出提示「已导出 …」，用户回到自己选的目录却什么也没看到。全是非法
    /// 字符或全是点时必须退回默认名，超长必须收敛——否则拼出来的路径不可预期。
    func testExportFileNamesStayVisibleAndBounded() async throws {
        func baseName(for title: String) async throws -> String {
            let recipe = Self.dubbingRecipe(digest: "digest-1")
            let creator = DubbingRenderClient(
                audio: silentPreviewWAV(marker: 0x81, frames: 1_200),
                recipe: recipe,
                voice: Self.dubbingVoice()
            )
            let (model, works, _) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
            await model.refreshCreatorVoices()
            let work = try saveSourceWork(
                into: works,
                script: "只有一段。",
                recipeDigest: "digest-1",
                title: title
            )
            let project = try XCTUnwrap(model.startDubbingProject(for: work))
            let segment = try XCTUnwrap(project.segments.first)
            model.startDubbingSegmentRedo(segment.id)
            try await waitUntilDubbing {
                model.dubbingBusySegmentID == nil && !model.dubbingCandidates.isEmpty
            }
            XCTAssertTrue(model.adoptDubbingCandidate(try XCTUnwrap(model.dubbingCandidates.first)))
            model.prepareDubbingExport()
            return try XCTUnwrap(model.dubbingExportBundle).baseName
        }

        for title in [
            ".." + "/成品:" + String(repeating: "长", count: 200),
            ".隐藏的配音",
            "...",
            "///",
            "   ",
        ] {
            let name = try await baseName(for: title)
            XCTAssertFalse(
                name.hasPrefix("."),
                "「\(title.debugDescription)」导出的名字不能以点开头：那是隐藏文件"
            )
            XCTAssertFalse(name.contains("/"), "「\(title.debugDescription)」不得留下路径分隔符")
            XCTAssertFalse(name.contains(":"), "「\(title.debugDescription)」不得留下非法字符")
            XCTAssertLessThanOrEqual(name.count, 80, "文件名要收敛到可预期的长度")
            XCTAssertFalse(name.isEmpty, "任何标题都得给出一个能看见的文件名")
        }

        let plain = try await baseName(for: "正常标题")
        XCTAssertEqual(plain, "正常标题", "普通标题原样用作文件名")
    }

    /// 导出写到一半失败时，必须照实说写到哪一步了。
    ///
    /// 音频与正文是一对：正文没落地时，目标目录里躺着的是一份**没有对应文案的
    /// 成品**。此前无论失败发生在哪一步，文案都是「请确认目标位置可写」——
    /// 而目标位置可能完全可写，只是正文那个路径被占了、或者磁盘在写第二份时满了。
    /// 用户会被引导去检查一个没坏的目录。
    func testExportSaysWhichHalfFailed() async throws {
        let recipe = Self.dubbingRecipe(digest: "digest-1")
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x84, frames: 1_200),
            recipe: recipe,
            voice: Self.dubbingVoice()
        )
        let (model, works, _) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        await model.refreshCreatorVoices()
        let work = try saveSourceWork(
            into: works,
            script: "只有一段。",
            recipeDigest: "digest-1"
        )
        let project = try XCTUnwrap(model.startDubbingProject(for: work))
        let segment = try XCTUnwrap(project.segments.first)
        model.startDubbingSegmentRedo(segment.id)
        try await waitUntilDubbing {
            model.dubbingBusySegmentID == nil && !model.dubbingCandidates.isEmpty
        }
        XCTAssertTrue(model.adoptDubbingCandidate(try XCTUnwrap(model.dubbingCandidates.first)))
        model.prepareDubbingExport()
        let bundle = try XCTUnwrap(model.dubbingExportBundle)

        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: target) }
        // 正文那个路径先被一个同名目录占住：写音频会成功，写正文必然失败。
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent(bundle.scriptFileName, isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertFalse(model.writeDubbingExport(to: target))
        XCTAssertEqual(
            model.dubbingMessage,
            "已写入 \(bundle.audioFileName)，但正文没能写入：目标位置可能被占用或空间不足。",
            "失败发生在第二步时必须说清楚音频已经落地了"
        )
        XCTAssertNotNil(
            model.dubbingExportBundle,
            "写了一半也要保留待导出内容，让用户可以换个位置重试"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent(bundle.audioFileName).path
            ),
            "音频确实已经落地——这正是文案要说清的事"
        )
    }

    /// 没有完整配方摘要的作品不能只重做一段：宁可拒绝，也不假装是同一次制作。
    func testSegmentRedoRefusedWhenRecipeDigestIsUnknown() async throws {
        let recipe = Self.dubbingRecipe(digest: nil)
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x90),
            recipe: recipe,
            voice: Self.dubbingVoice()
        )
        let (model, works, _) = makeDubbingModel(creator: creator, recipeDigest: nil)
        // 音色必须先可用，否则拒绝会落在「音色不可用」那道守卫上，
        // 配方摘要这条根本没被考到——曾经就是这个情况：断言只有
        // `XCTAssertNotNil(dubbingMessage)`，换成哪条守卫拒绝它都绿。
        await model.refreshCreatorVoices()
        XCTAssertTrue(
            model.creatorVoices.contains { $0.id == recipe.voiceID },
            "前置条件：配方里的音色当前可用，配方缺失才是唯一的拒绝理由"
        )
        let work = try saveSourceWork(
            into: works,
            script: "一段没有配方摘要的正文。",
            recipeDigest: nil
        )
        let project = try XCTUnwrap(model.startDubbingProject(for: work))
        let segment = try XCTUnwrap(project.segments.first)

        model.startDubbingSegmentRedo(segment.id)

        XCTAssertNil(model.dubbingBusySegmentID, "被拒绝的重做不进入在途状态")
        XCTAssertEqual(model.dubbingCandidates, [])
        XCTAssertEqual(
            model.dubbingProject?.recipe.recipe?.digest,
            nil,
            "缺失的事实保持缺失，不用随机值补齐"
        )
        XCTAssertEqual(
            model.dubbingMessage,
            "这件作品没有记录完整的制作配方，无法安全地只重做其中一段。",
            "必须是「缺配方摘要」这条拒绝，而不是别的原因碰巧也拒了"
        )
        let calls = await creator.renderCalls
        XCTAssertTrue(calls.isEmpty, "被拒绝的重做不得触达渲染")
    }

    /// 已有一段在重做时，第二段必须被明确拒绝而不是并行跑。
    ///
    /// 并行会让两段各自往库里写候选，而 `dubbingRedoGeneration` 这套陈旧回写防护
    /// 是按「同一时刻只有一段在飞」的前提设计的——前提不成立时它救不了场。
    func testASecondSegmentRedoIsRefusedWhileOneIsInFlight() async throws {
        let recipe = Self.dubbingRecipe(digest: "digest-1")
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x91),
            recipe: recipe,
            voice: Self.dubbingVoice()
        )
        let (model, works, _) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        await model.refreshCreatorVoices()
        let work = try saveSourceWork(
            into: works,
            script: "第一段正文。\n第二段正文。",
            recipeDigest: "digest-1"
        )
        let project = try XCTUnwrap(model.startDubbingProject(for: work))
        let first = try XCTUnwrap(project.segments.first)
        let second = try XCTUnwrap(project.segments.last)

        model.startDubbingSegmentRedo(first.id)
        XCTAssertEqual(model.dubbingBusySegmentID, first.id, "第一段已进入在途状态")
        model.startDubbingSegmentRedo(second.id)

        XCTAssertEqual(
            model.dubbingMessage,
            "已有一段在重做，请等它完成或先取消。",
            "第二段必须被明确拒绝"
        )
        XCTAssertEqual(
            model.dubbingBusySegmentID,
            first.id,
            "被拒绝的第二段不得顶掉第一段的在途状态"
        )

        try await waitUntilDubbing { model.dubbingBusySegmentID == nil }
        let calls = await creator.renderCalls
        XCTAssertEqual(calls.map(\.text), ["第一段正文。"], "只有被放行的那一段触达渲染")
    }

    /// 配方里的音色当前不可用时不得返修：换了音色就不再是同一制作条件。
    func testSegmentRedoIsRefusedWhileTheRecipeVoiceIsUnavailable() async throws {
        let recipe = Self.dubbingRecipe(digest: "digest-1")
        let unavailable = CreatorVoice(
            id: "ryan",
            name: "动感英语男声",
            available: false,
            mode: "system",
            revision: "vr_0123456789abcdef0123456789abcdef"
        )
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x92),
            recipe: recipe,
            voice: unavailable
        )
        let (model, works, _) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        await model.refreshCreatorVoices()
        let work = try saveSourceWork(
            into: works,
            script: "一段正文。",
            recipeDigest: "digest-1"
        )
        let project = try XCTUnwrap(model.startDubbingProject(for: work))
        let segment = try XCTUnwrap(project.segments.first)

        model.startDubbingSegmentRedo(segment.id)

        XCTAssertNil(model.dubbingBusySegmentID, "被拒绝的重做不进入在途状态")
        XCTAssertEqual(
            model.dubbingMessage,
            "这件作品使用的音色当前暂不可用，无法重做段落。"
        )
        let calls = await creator.renderCalls
        XCTAssertTrue(calls.isEmpty, "被拒绝的重做不得触达渲染")
    }

    /// 「列表没读到」与「音色不在列表里」必须说成两句话。
    ///
    /// 音色列表读失败时 `creatorVoices` 是空的，`first(where:)` 必然落空。
    /// 此前这与「这件作品用的音色确实不在列表里」共用一条文案，都会把用户
    /// 指向「音色不可用」——但那时候音色可能完全正常，是我们没读到。
    func testSegmentRedoNamesTheReasonTheVoiceListIsUnusable() async throws {
        // 这件作品用的音色不在当前音色库里：列表读到与没读到，两种情况都要说清。
        let recipe = Self.dubbingRecipe(digest: "digest-1", voiceID: "not_in_library")
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x93),
            recipe: recipe,
            voice: Self.dubbingVoice()
        )
        let (model, works, _) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        // 刻意不调用 refreshCreatorVoices()：这就是列表尚未读到的状态。
        let work = try works.save(
            Self.dubbingWork(
                script: "一段正文。",
                provenance: RenderProvenanceSnapshot(
                    state: .verified,
                    reason: nil,
                    planSHA256: "plan_sha_source",
                    recipe: recipe,
                    pcmSHA256: "pcm_sha_source"
                )
            ),
            audioData: silentPreviewWAV(marker: 0x44)
        )
        let project = try XCTUnwrap(model.startDubbingProject(for: work))
        let segment = try XCTUnwrap(project.segments.first)

        model.startDubbingSegmentRedo(segment.id)

        XCTAssertNil(model.dubbingBusySegmentID)
        XCTAssertEqual(
            model.dubbingMessage,
            "还没读到音色列表，无法确认这件作品用的音色是否可用，请先刷新一次。",
            "没读到列表时不得把责任说成音色不可用"
        )
        let unreadCalls = await creator.renderCalls
        XCTAssertTrue(unreadCalls.isEmpty)

        // 列表读到了、音色确实不在其中：这才是「条件变了」的说法。
        await model.refreshCreatorVoices()
        model.startDubbingSegmentRedo(segment.id)
        XCTAssertEqual(
            model.dubbingMessage,
            "这件作品使用的音色不在当前的音色列表里，无法重做段落。"
        )
        let missingCalls = await creator.renderCalls
        XCTAssertTrue(missingCalls.isEmpty)
    }

    /// 上一代重做的收尾不得踩掉新一代重做的在途状态。
    ///
    /// 交错（旧项目在途 → 关闭 → 新项目重做在途 → 旧渲染返回）：
    /// 旧任务的 `defer { finishDubbingSegmentRedo(generation: 旧) }` 里那句
    /// `guard dubbingRedoGeneration == generation` 是唯一拦住它的东西。
    /// 没有它，旧任务会把**新**任务的在途标记清成 nil——界面显示「不忙」，
    /// 而新渲染其实还在跑；`cancelDubbingSegmentRedo()` 也从此按不住它
    /// （句柄已被置 nil）。方案 §5 C1 要求「受控异步乱序」，
    /// 此处按交错写用例，而不是按主路径。
    func testAStaleRedoDoesNotClearTheNextProjectsBusyState() async throws {
        let staleGate = RenderGate()
        let liveGate = RenderGate()
        let recipe = Self.dubbingRecipe(digest: "digest-1")
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x94),
            recipe: recipe,
            voice: Self.dubbingVoice(),
            renderGates: [staleGate, liveGate]
        )
        let (model, works, projects) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        await model.refreshCreatorVoices()
        let staleWork = try saveSourceWork(
            into: works,
            script: "只有一段正文。",
            recipeDigest: "digest-1"
        )
        let staleProject = try XCTUnwrap(model.startDubbingProject(for: staleWork))
        let staleSegment = try XCTUnwrap(staleProject.segments.first)
        model.startDubbingSegmentRedo(staleSegment.id)
        // 有界轮询到渲染真的挂住为止：闸门是协作式的，抢跑会测不到交错。
        try await waitUntilDubbingAsync { await creator.renderCalls.count == 1 }
        XCTAssertEqual(model.dubbingBusySegmentID, staleSegment.id, "关闭前这次重做确实在途")

        model.closeDubbingProject()

        // 新项目立刻接上第二次重做，并挂在自己的闸门上。
        let liveWork = try saveSourceWork(
            into: works,
            script: "新的一段正文。",
            recipeDigest: "digest-1",
            workID: "work_dubbing_live"
        )
        let liveProject = try XCTUnwrap(model.startDubbingProject(for: liveWork))
        let liveSegment = try XCTUnwrap(liveProject.segments.first)
        model.startDubbingSegmentRedo(liveSegment.id)
        try await waitUntilDubbingAsync { await creator.renderCalls.count == 2 }
        XCTAssertEqual(model.dubbingBusySegmentID, liveSegment.id, "新项目的重做在途")

        // 现在才让旧渲染返回：旧任务的收尾此刻才跑。
        await staleGate.open()
        try await settleDubbing()

        XCTAssertEqual(
            model.dubbingBusySegmentID,
            liveSegment.id,
            "上一代重做的收尾不得把新一代的在途状态清成 nil"
        )
        XCTAssertEqual(model.dubbingProject?.id, liveProject.id, "项目没有被旧任务换掉")
        XCTAssertTrue(
            try projects.candidates(forProject: staleProject.id).isEmpty,
            "旧项目的候选一个都不该留下"
        )

        await liveGate.open()
        try await waitUntilDubbing {
            model.dubbingBusySegmentID == nil && !model.dubbingCandidates.isEmpty
        }
        XCTAssertEqual(model.dubbingCandidates.first?.segmentID, liveSegment.id)
    }

    /// 上一代重做**失败**时，报错也不得写进新项目的界面。
    ///
    /// 与上一条互补：那条钉的是成功路径上的 `defer` 收尾，这条钉的是
    /// `catch` 分支里的 `guard dubbingRedoGeneration == generation`。
    /// 失败路径尤其容易漏——它只在渲染**抛错**时才走到，而抛错时
    /// `Task.checkCancellation()` 还没执行到，所以这条分支不能靠取消兜底。
    func testAFailedStaleRedoDoesNotReportIntoTheNextProject() async throws {
        let staleGate = RenderGate()
        let liveGate = RenderGate()
        let recipe = Self.dubbingRecipe(digest: "digest-1")
        let creator = DubbingRenderClient(
            audio: silentPreviewWAV(marker: 0x95),
            recipe: recipe,
            voice: Self.dubbingVoice(),
            renderGates: [staleGate, liveGate]
        )
        let (model, works, _) = makeDubbingModel(creator: creator, recipeDigest: "digest-1")
        await model.refreshCreatorVoices()
        let staleWork = try saveSourceWork(
            into: works,
            script: "只有一段正文。",
            recipeDigest: "digest-1"
        )
        let staleProject = try XCTUnwrap(model.startDubbingProject(for: staleWork))
        model.startDubbingSegmentRedo(try XCTUnwrap(staleProject.segments.first).id)
        try await waitUntilDubbingAsync { await creator.renderCalls.count == 1 }

        model.closeDubbingProject()

        let liveWork = try saveSourceWork(
            into: works,
            script: "新的一段正文。",
            recipeDigest: "digest-1",
            workID: "work_dubbing_live"
        )
        let liveProject = try XCTUnwrap(model.startDubbingProject(for: liveWork))
        let liveSegment = try XCTUnwrap(liveProject.segments.first)
        model.startDubbingSegmentRedo(liveSegment.id)
        try await waitUntilDubbingAsync { await creator.renderCalls.count == 2 }
        XCTAssertNil(model.dubbingMessage, "新项目的重做刚起，没有待展示的错误")

        // 旧渲染现在才失败：它的报错属于旧项目，不该出现在界面上。
        await staleGate.open(failing: true)
        try await settleDubbing()

        XCTAssertNil(
            model.dubbingMessage,
            "上一代的失败不得写进新项目的界面"
        )
        XCTAssertEqual(model.dubbingBusySegmentID, liveSegment.id, "新项目的在途状态不受影响")
        XCTAssertEqual(model.dubbingProject?.id, liveProject.id)

        await liveGate.open()
        try await waitUntilDubbing { model.dubbingBusySegmentID == nil }
    }

    /// #186：文案提到的成因必须与用户实际能修的方向一致。
    ///
    /// 此前 `DubbingProjectError.invalidIdentifier`（数据不自洽）被说成
    /// 「请检查磁盘权限和可用空间」，而真正的磁盘满/没权限——它不走
    /// `DubbingProjectError`，以 `CocoaError` 原样冒出来——反而落到笼统的
    /// 「段落操作失败，请重试」。两边的成因与文案正好错位。
    func testDubbingErrorsNameTheCauseTheUserCanActuallyActOn() {
        // 数据不自洽：重试无用，要重新生成这一段。不得提磁盘。
        let dataFault = AppModel.dubbingErrorMessage(for: DubbingProjectError.invalidIdentifier)
        XCTAssertFalse(
            dataFault.contains("磁盘") || dataFault.contains("空间"),
            "数据异常不得被说成磁盘问题：\(dataFault)"
        )
        XCTAssertTrue(
            dataFault.contains("重新生成"),
            "数据异常要给出一个真正有用的下一步：\(dataFault)"
        )

        // 真正的存储失败：磁盘满与没权限都归到磁盘这一支。
        for code in [CocoaError.Code.fileWriteOutOfSpace, .fileWriteNoPermission] {
            let storageFault = AppModel.dubbingErrorMessage(
                for: CocoaError(code)
            )
            XCTAssertTrue(
                storageFault.contains("磁盘") && storageFault.contains("空间"),
                "\(code) 是存储失败，文案必须说磁盘与空间：\(storageFault)"
            )
        }

        // 别的失败不得被顺手说成磁盘问题。
        let other = AppModel.dubbingErrorMessage(for: CocoaError(.fileNoSuchFile))
        XCTAssertFalse(
            other.contains("磁盘"),
            "文件不存在不是磁盘问题，不得套用磁盘文案：\(other)"
        )
    }

    /// #184：副标题不得把「不知道音色是谁」说成「原音色」。
    ///
    /// 旧实现是 `dubbingProjectVoiceName ?? "原音色"`，而 nil 有四种来源。
    /// 最糟的是"不在列表里"：副标题刚承诺一个音色，第一次返修就被
    /// `startDubbingSegmentRedo` 拒绝，用户看到自相矛盾。
    func testTheSegmentRedoSubtitleNeverClaimsAVoiceItDoesNotHave() {
        let library = [CreatorVoice(id: "voice-1", name: "沉稳男声", available: true)]

        // 查到了：说是哪一个。
        XCTAssertEqual(
            DubbingProjectVoice.resolve(
                voiceID: "voice-1",
                voicesLoadState: .loaded,
                voices: library
            ),
            .named("沉稳男声")
        )

        // 没记录：这个项目压根没写音色，说"原音色"是凭空断言。
        XCTAssertEqual(
            DubbingProjectVoice.resolve(
                voiceID: nil,
                voicesLoadState: .loaded,
                voices: library
            ),
            .notRecorded
        )

        // 列表没读到：还没读、正在读、读失败，三种都不是"没有音色"这个结论。
        for state in [CreatorVoicesLoadState.unknown, .loading, .failed] {
            let voice = DubbingProjectVoice.resolve(
                voiceID: "voice-1",
                voicesLoadState: state,
                voices: library
            )
            XCTAssertEqual(voice, .listUnread, "\(state) 时我们还不知道音色是谁")
            XCTAssertFalse(
                voice.text.contains("原音色"),
                "\(state) 时不得说成「原音色」——那是把不知道说成知道"
            )
        }

        // 列表读到了、音色确实不在其中：这是第三种情况，不能与"没读到"混为一谈。
        let absent = DubbingProjectVoice.resolve(
            voiceID: "voice-9",
            voicesLoadState: .loaded,
            voices: library
        )
        XCTAssertEqual(absent, .notInLibrary)
        XCTAssertFalse(
            absent.text.contains("音色为"),
            "不在列表里时副标题不得承诺一个音色，否则第一次返修就被拒绝（#184）"
        )

        // 四种取值的文案互不相同——否则"分开说"只是形式。
        let texts = [
            DubbingProjectVoice.named("沉稳男声").text,
            DubbingProjectVoice.notRecorded.text,
            DubbingProjectVoice.listUnread.text,
            DubbingProjectVoice.notInLibrary.text,
        ]
        XCTAssertEqual(
            Set(texts).count, 4,
            "四种状态必须给出四种说法：\(texts)"
        )
    }
}

// MARK: - (G) 跨入口一致：App 在发出请求之前就拒绝服务会拒绝的渲染

extension AppModelTests {
    /// REST 与 MCP 的拒绝表在 `tests/test_interface_parity.py`。App 这一侧回答
    /// 同一个问题：无效渲染不得离开 App，也不得留下任何"待保存"的残留。
    func testCreatorRefusesInvalidRendersBeforeSendingAnything() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechrail-parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativeWorkStore(directory: directory)
        let creator = ScriptedRenderClient(audio: silentPreviewWAV(marker: 0x30))
        let model = makeRenderModel(store: store, creator: creator)
        await model.refreshDiscovery()

        _ = await model.synthesizeAndSave(text: "   ", voice: Self.renderVoice(), speed: 1.0)
        XCTAssertNotNil(model.creatorMessage, "空文稿在本地就被拒绝")

        _ = await model.synthesizeAndSave(
            text: String(
                repeating: "字",
                count: SpeechRailCreatorLimits.speechTextMaximumLength + 1
            ),
            voice: Self.renderVoice(),
            speed: 1.0
        )
        XCTAssertNotNil(model.creatorMessage, "超长文稿在本地就被拒绝")

        let cloneVoice = CreatorVoice(
            id: "narrator",
            name: "旁白",
            available: true,
            mode: "clone",
            revision: "vr_0123456789abcdef0123456789abcdef"
        )
        _ = await model.synthesizeAndSave(text: "一段正常文稿。", voice: cloneVoice, speed: 1.25)
        XCTAssertNotNil(model.creatorMessage, "参考音色的语速限制在本地就被拒绝")

        XCTAssertNil(model.pendingDubbing, "被拒绝的渲染不留下待保存结果")
        let refusedCalls = await creator.renderCalls
        XCTAssertEqual(refusedCalls.count, 0, "被拒绝的渲染不得离开 App")

        // 规则一致不等于一律拒绝：合法文稿照常生成。
        _ = await model.synthesizeAndSave(
            text: "一段正常文稿。",
            voice: Self.renderVoice(),
            speed: 1.0
        )
        XCTAssertNotNil(model.pendingDubbing)
        let acceptedCalls = await creator.renderCalls
        XCTAssertEqual(acceptedCalls.count, 1)
    }
}

// MARK: - (F) 首次使用：只把"还差什么"说清楚，不替用户动手

extension AppModelTests {
    /// 「去处理」必须把人送到真正有那个动作的页面：这条映射原先把三步都指回
    /// 服务状态——选档位与准备模型其实在模型组合页（#210）。
    func testEveryReadinessStepLandsOnThePageThatOwnsTheAction() {
        XCTAssertEqual(
            FirstResultReadiness.Step.serviceReachable.ownerRoute,
            .overview,
            "启停服务的按钮就在服务状态页上"
        )
        XCTAssertEqual(
            FirstResultReadiness.Step.profileSelected.ownerRoute,
            .models,
            "选运行档位的控件在模型组合页，不在服务状态页"
        )
        XCTAssertEqual(
            FirstResultReadiness.Step.modelsReady.ownerRoute,
            .models,
            "下载、校验与应用模型的动作在模型组合页"
        )
        XCTAssertEqual(
            FirstResultReadiness.Step.voiceAvailable.ownerRoute,
            .voiceLibrary,
            "准备可用音色的入口在音色库"
        )
    }

    /// 落在用户已经在的那一页时不给按钮：点了不动的按钮比没有按钮更糟。
    func testOnlyStepsThatNeedAnotherPageGetADestinationButton() {
        for step in FirstResultReadiness.Step.allCases {
            XCTAssertEqual(
                step.needsDestination(awayFrom: .overview),
                step.ownerRoute != .overview,
                "\(step.rawValue) 的按钮可见性与它的目标页不一致"
            )
        }
        XCTAssertFalse(
            FirstResultReadiness.Step.serviceReachable.needsDestination(awayFrom: .overview),
            "服务可达的缺口由本页的启动/重启按钮承担，卡片不再给一个原地不动的按钮"
        )
    }

    private func readiness(
        hasHealth: Bool = true,
        healthFailure: ServiceHealthFailureKind? = nil,
        hasProfile: Bool = true,
        modelAvailability: ModelAvailabilityState = .available,
        modelStatusMessage: String? = nil,
        voices: [CreatorVoice] = [],
        voicesLoadState: CreatorVoicesLoadState = .loaded,
        discoveryState: CapabilityDiscoveryState = .loaded
    ) -> FirstResultReadiness {
        FirstResultReadinessBuilder.evaluate(
            hasHealth: hasHealth,
            healthFailure: healthFailure,
            hasProfile: hasProfile,
            modelAvailability: modelAvailability,
            modelStatusMessage: modelStatusMessage,
            voices: voices,
            voicesLoadState: voicesLoadState,
            discoveryState: discoveryState
        )
    }

    private var availableVoice: CreatorVoice {
        CreatorVoice(id: "ryan", name: "动感英语男声", available: true, mode: "system")
    }

    /// 正面证据齐了才算就绪：探针通过本身不构成任何一步的满足。
    func testFirstResultIsReadyOnlyWhenEveryStepHasPositiveEvidence() {
        XCTAssertTrue(readiness(voices: [availableVoice]).isReady)

        XCTAssertFalse(
            readiness(voices: []).isReady,
            "没有可用音色时不得声称可以拿到第一条真实结果"
        )
        XCTAssertFalse(readiness(hasProfile: false, voices: [availableVoice]).isReady)
        XCTAssertFalse(
            readiness(modelAvailability: .notReady, voices: [availableVoice]).isReady,
            "模型没准备好就不是就绪"
        )
    }

    /// 服务探针成功不等于第一条真实结果可用：模型与音色仍要各自有正面证据。
    func testHealthyProbeAloneNeverReportsReady() {
        let projection = readiness(voices: [])

        XCTAssertFalse(projection.isReady)
        XCTAssertFalse(
            projection.steps.contains { $0.step == .serviceReachable },
            "服务已经可达就不该再列为缺口"
        )
    }

    /// 还没读到状态不等于失败：未知的步骤单独标出，不混进确定缺口里。
    func testUnknownStepsAreNotReportedAsKnownBlockers() {
        let projection = readiness(
            hasHealth: false,
            voices: [],
            discoveryState: .idle
        )

        let unknown = projection.unknownSteps.map(\.step)
        XCTAssertTrue(unknown.contains(.serviceReachable))
        XCTAssertFalse(
            projection.blockingSteps.map(\.step).contains(.serviceReachable),
            "还没读到服务状态不是已确认的缺口"
        )
        XCTAssertFalse(projection.isReady)
    }

    /// 每一处缺口都要说清下一步动作，且不承诺 App 会替用户完成它。
    func testEveryBlockerNamesTheNextActionForTheUser() {
        let projection = readiness(
            healthFailure: .connection,
            hasProfile: false,
            modelAvailability: .failed,
            modelStatusMessage: "磁盘空间不足",
            voices: [],
            voicesLoadState: .failed
        )

        XCTAssertEqual(
            Set(projection.blockingSteps.map(\.step)),
            [
                .serviceReachable,
                .profileSelected,
                .modelsReady,
                .voiceAvailable,
            ]
        )
        for step in projection.blockingSteps {
            XCTAssertFalse(step.detail.isEmpty, "\(step.step) 没有告诉用户下一步做什么")
        }
        XCTAssertTrue(
            projection.blockingSteps
                .first { $0.step == .modelsReady }?
                .detail
                .contains("磁盘空间不足") == true,
            "已知的失败原因要原样带给用户，不替换成通用文案"
        )
    }

    /// 模型状态还没读到时是未知，不是缺口：`modelAvailability` 的初始值就是
    /// `.unknown`，每个用户在首次读取完成前都停在这里。
    func testUnknownModelAvailabilityIsNotReportedAsAKnownBlocker() {
        let projection = readiness(
            modelAvailability: .unknown,
            voices: [availableVoice]
        )

        XCTAssertFalse(projection.isReady, "模型状态未知时不得声称可以拿到第一条真实结果")
        XCTAssertTrue(
            projection.unknownSteps.map(\.step).contains(.modelsReady),
            "还没读到模型状态属于未知，不是已确认的缺口"
        )
        XCTAssertFalse(
            projection.blockingSteps.map(\.step).contains(.modelsReady),
            "未知不得混进确定缺口——否则会催用户去修一个没坏的东西"
        )
    }

    /// 档位在这台机器上根本跑不了：这是确定的缺口，且必须给出可执行的下一步。
    func testUnsupportedMachineIsAKnownBlockerWithItsOwnNextAction() {
        let projection = readiness(
            modelAvailability: .unsupported,
            voices: [availableVoice]
        )

        XCTAssertEqual(projection.blockingSteps.map(\.step), [.modelsReady])
        XCTAssertTrue(projection.unknownSteps.isEmpty, "服务已明确回话，不该再算未知")
        XCTAssertFalse(projection.isReady)
        // 先 count 后 allSatisfy，且全程不下标：断言失败后代码仍会继续执行，
        // 直接 blockingSteps[0] 会在缺口为空时越界崩溃，把整个测试进程带倒。
        let modelDetails = projection.blockingSteps
            .filter { $0.step == .modelsReady }
            .map(\.detail)
        XCTAssertEqual(modelDetails.count, 1)
        XCTAssertTrue(
            modelDetails.allSatisfy { !$0.isEmpty },
            "换机器这类结论必须说清用户下一步能做什么"
        )
    }

    /// 音色列表读到了、但当前一个都不能用：这是确定的缺口，不是未知。
    func testLoadedButUnavailableVoicesAreAKnownBlocker() {
        let unavailable = CreatorVoice(
            id: "design-1",
            name: "设计音色",
            available: false,
            mode: "voice_design"
        )
        let projection = readiness(voices: [unavailable])

        XCTAssertEqual(projection.blockingSteps.map(\.step), [.voiceAvailable])
        XCTAssertTrue(projection.unknownSteps.isEmpty)
    }

    /// 音色列表读到了，但当前能力快照还没确认：可用性仍然没有结论。
    ///
    /// 这一步与模型状态同理——把它算成已确认的缺口，等于催用户去修一个他还没有
    /// 资格判断的东西。默认参数下 `discoveryState` 恒为 `.loaded`，所以这条分支
    /// 必须显式把状态改成未加载才走得到。
    func testVoiceAvailabilityIsUnknownUntilCapabilityDiscoveryIsLoaded() {
        let projection = readiness(
            voices: [],
            voicesLoadState: .loaded,
            discoveryState: .idle
        )

        XCTAssertTrue(
            projection.unknownSteps.map(\.step).contains(.voiceAvailable),
            "能力快照未确认时，音色是否可用还没有结论"
        )
        XCTAssertFalse(
            projection.blockingSteps.map(\.step).contains(.voiceAvailable),
            "未知不得混进确定缺口"
        )
        XCTAssertFalse(projection.isReady)
    }

    /// 音色列表**还没读到**时，这是未知，不是「你没有音色」。
    ///
    /// `CreatorVoicesLoadState` 的初始值就是 `.unknown`，`.loading` 也在路上。
    /// 这两种状态此前落进 `default` 分支，于是 App 一启动就告诉用户
    /// 「还没有可用于配音的音色，先在『音色库』里准备一个」——用户可能明明有，
    /// 却被推去重新做一个。这与「未知不得混进确定缺口」是同一条纪律。
    func testAnUnreadVoiceListIsNotReportedAsHavingNoVoices() {
        for state in [CreatorVoicesLoadState.unknown, .loading] {
            let projection = readiness(voices: [], voicesLoadState: state)

            XCTAssertTrue(
                projection.unknownSteps.map(\.step).contains(.voiceAvailable),
                "\(state) 时音色是否可用还没有结论"
            )
            XCTAssertFalse(
                projection.blockingSteps.map(\.step).contains(.voiceAvailable),
                "\(state) 不得被说成已确认的缺口"
            )
            let voiceDetail = projection.unknownSteps
                .first { $0.step == .voiceAvailable }?
                .detail ?? ""
            XCTAssertFalse(
                voiceDetail.contains("音色库"),
                "\(state) 时不该催用户去准备一个他可能已经有的音色"
            )
        }
    }

    /// 全是未知时不显示这张卡：有标题、有分隔线、没有任何一行的空壳没有意义。
    func testTheReadinessCardOnlyAppearsWhenThereIsSomethingToDo() {
        let allUnknown = readiness(
            hasHealth: false,
            modelAvailability: .unknown,
            voices: [],
            voicesLoadState: .unknown,
            discoveryState: .idle
        )
        XCTAssertTrue(allUnknown.unknownSteps.count >= 3, "这组输入应当全是未知")
        XCTAssertTrue(
            allUnknown.blockingSteps.isEmpty,
            "前提：这组输入没有任何确定缺口"
        )
        XCTAssertFalse(
            allUnknown.hasActionableSteps,
            "没有确定缺口时不该出现一张让用户「去处理」的空卡"
        )
        XCTAssertFalse(allUnknown.isReady, "未知仍然不是就绪")

        XCTAssertTrue(
            readiness(voices: []).hasActionableSteps,
            "确认没有可用音色时必须给出下一步"
        )
    }

    /// #183：配音台音色选择器不得把「没读到」「读取失败」说成「服务没有音色」。
    ///
    /// `refreshCreatorVoices()` 的 catch 分支会 `creatorVoices = []` 并置 `.failed`。
    /// 旧实现只问 `availableVoices.isEmpty`，于是这三种状态拿到同一句话，
    /// 并把用户送去「音色创作」——解决不了一次读取失败。
    func testTheVoicePickerNeverCallsAnUnreadListHavingNoVoices() {
        let usable = [CreatorVoice(id: "v1", name: "可用音色", available: true)]
        let unusable = [CreatorVoice(id: "v2", name: "停用音色", available: false)]

        // 还没读到过、或正在读：我们不知道有没有音色。
        for state in [CreatorVoicesLoadState.unknown, .loading] {
            let picker = CreatorVoicePickerState.resolve(loadState: state, voices: [])
            XCTAssertEqual(
                picker, .reading,
                "\(state) 不是「没有音色」这个结论"
            )
            XCTAssertFalse(
                picker.suggestsCreatingVoice,
                "\(state) 时催用户去创作一个他可能已经有的音色"
            )
        }

        // 读取失败：更不能催用户去创作，也不能说成"服务没有返回音色"。
        let failed = CreatorVoicePickerState.resolve(loadState: .failed, voices: [])
        XCTAssertEqual(failed, .unreadable)
        XCTAssertTrue(failed.offersReload, "读失败时的正确动作是重新加载")
        XCTAssertFalse(failed.suggestsCreatingVoice)
        XCTAssertFalse(
            failed.emptyDescription.contains("没有返回"),
            "读失败不得被说成服务确实没有返回音色"
        )

        // 读到了、确有可用音色。
        XCTAssertEqual(
            CreatorVoicePickerState.resolve(loadState: .loaded, voices: usable),
            .available
        )
        // 读到了、音色都在但当前不可用：这才是"没有可用音色"。
        XCTAssertEqual(
            CreatorVoicePickerState.resolve(loadState: .loaded, voices: unusable),
            .noneAvailable
        )
        XCTAssertEqual(
            CreatorVoicePickerState.resolve(loadState: .loaded, voices: []),
            .noneAvailable
        )
        // 只有"确实没有"才该把用户送去音色创作。
        XCTAssertTrue(
            CreatorVoicePickerState.resolve(loadState: .loaded, voices: []).suggestsCreatingVoice
        )
    }
}
