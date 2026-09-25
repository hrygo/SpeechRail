import XCTest
@testable import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// W10：分档能力呈现的纯映射测试。
///
/// 只验证 DTO 如何解释 `/v1/voices[].streaming` 与
/// `/v1/models[].capabilities.streaming_input`。不加载模型、不连接服务，
/// 也不冒充 UI 或可听体验验收。
final class StreamingTtsCapabilitiesTests: XCTestCase {
    private func decodeVoice(_ json: String) throws -> CreatorVoice {
        try JSONDecoder().decode(CreatorVoice.self, from: Data(json.utf8))
    }

    func testCustomVoiceSpeakerDecodesAsReadyIncremental() throws {
        let voice = try decodeVoice(
            """
            {
              "id": "serena",
              "name": "Serena",
              "available": true,
              "variant": "custom_voice",
              "mode": "system",
              "streaming": {
                "supported": true,
                "reason": null,
                "hint": null,
                "protocol_version": 1,
                "implementation_version": "qwen3_tts_append_v1",
                "voice_mode": "system",
                "voice_variant": "custom_voice",
                "limits": {"max_total_codepoints": 4096},
                "axes": {
                  "variant_supported": true,
                  "artifact_available": true,
                  "profile_enabled": true,
                  "reference_ready": true,
                  "implementation_supported": true,
                  "protocol_negotiated": true,
                  "ready": true,
                  "budget_available": true
                }
              }
            }
            """
        )

        let streaming = try XCTUnwrap(voice.streaming)
        XCTAssertTrue(streaming.supported)
        XCTAssertNil(streaming.reason)
        XCTAssertEqual(streaming.protocolVersion, 1)
        XCTAssertEqual(streaming.voiceVariant, "custom_voice")
        XCTAssertTrue(streaming.axes.ready)
        XCTAssertTrue(streaming.axes.referenceReady)
        XCTAssertEqual(streaming.axes.protocolNegotiated, true)
    }

    func testUnpreparedCloneDecodesAsUnsupportedWithAnActionableHint() throws {
        let voice = try decodeVoice(
            """
            {
              "id": "clone_pending",
              "name": "Pending clone",
              "available": false,
              "variant": "base",
              "mode": "clone",
              "streaming": {
                "supported": false,
                "reason": "reference_not_ready",
                "hint": "the incremental path needs a registered clone reference for this voice",
                "protocol_version": null,
                "implementation_version": null,
                "voice_mode": "clone",
                "voice_variant": "base",
                "limits": null,
                "axes": {
                  "variant_supported": true,
                  "artifact_available": true,
                  "profile_enabled": true,
                  "reference_ready": false,
                  "implementation_supported": true,
                  "protocol_negotiated": true,
                  "ready": false,
                  "budget_available": true
                }
              }
            }
            """
        )

        let streaming = try XCTUnwrap(voice.streaming)
        XCTAssertFalse(streaming.supported)
        XCTAssertEqual(streaming.reason, "reference_not_ready")
        XCTAssertNotNil(streaming.hint, "不可用必须带可执行提示，而不是静默失败")
        XCTAssertFalse(streaming.axes.referenceReady)
        XCTAssertTrue(streaming.axes.variantSupported)
    }

    func testMissingStreamingEntryIsUnknownRatherThanSupported() throws {
        let voice = try decodeVoice(
            """
            {"id": "legacy", "name": "Legacy", "available": true, "variant": "custom_voice"}
            """
        )

        // 旧服务没有这一段：必须解析为 nil，界面按未声明处理，不能推断为可用。
        XCTAssertNil(voice.streaming)
    }

    func testPartiallyDeclaredAxesFailClosed() throws {
        let voice = try decodeVoice(
            """
            {
              "id": "partial",
              "name": "Partial",
              "available": true,
              "streaming": {
                "supported": false,
                "voice_mode": "clone",
                "axes": {"reference_ready": true}
              }
            }
            """
        )

        let streaming = try XCTUnwrap(voice.streaming)
        XCTAssertTrue(streaming.axes.referenceReady)
        // 未声明的轴一律按失败/未知处理，不因为缺字段而放大能力。
        XCTAssertFalse(streaming.axes.variantSupported)
        XCTAssertFalse(streaming.axes.artifactAvailable)
        XCTAssertFalse(streaming.axes.ready)
        XCTAssertNil(streaming.axes.protocolNegotiated)
        XCTAssertNil(streaming.axes.budgetAvailable)
    }

    func testModelUnionKeepsTheImplementationAxisSeparateFromPerVoiceSupport() {
        let unimplemented = ServiceModelCapabilities()
        let implemented = ServiceModelCapabilities(
            supportsStreamingInput: true,
            streamingProtocolNegotiated: true
        )
        let merged = unimplemented.union(implemented)

        XCTAssertTrue(merged.supportsStreamingInput)
        XCTAssertEqual(merged.streamingProtocolNegotiated, true)
    }

    func testModelUnionDoesNotInventNegotiationWhenEveryEntryIsSilent() {
        let merged = ServiceModelCapabilities().union(ServiceModelCapabilities())

        XCTAssertFalse(merged.supportsStreamingInput)
        XCTAssertNil(merged.streamingProtocolNegotiated)
    }

    func testExplicitNegotiationFailureSurvivesTheUnion() {
        let failed = ServiceModelCapabilities(
            supportsStreamingInput: false,
            streamingProtocolNegotiated: false
        )
        let alsoFailed = ServiceModelCapabilities(
            supportsStreamingInput: false,
            streamingProtocolNegotiated: false
        )
        let merged = failed.union(alsoFailed)

        XCTAssertFalse(merged.supportsStreamingInput)
        XCTAssertEqual(merged.streamingProtocolNegotiated, false)
    }
}
