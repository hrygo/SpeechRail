import XCTest
@testable import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// Streaming diagnostics are a per-voice projection. These tests decode the
/// projection without loading a model or connecting to a service.
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

    /// 音色没声明可用性时按**不可用**处理。
    ///
    /// `available` 缺字段不等于「大概可用」——服务端没说，就是没说。
    /// 段落返修、试听这些入口都拿 `voice.available` 当闸门；
    /// 默认值一旦反过来，没声明的音色会直接出现在可选列表里。
    /// 既有解码用例全都显式写了 `"available": true`，这条默认值没人钉过。
    func testAVoiceWithoutAnAvailabilityFieldIsNotTreatedAsUsable() throws {
        let voice = try decodeVoice(
            """
            {"id": "undeclared", "name": "未声明可用性"}
            """
        )

        XCTAssertFalse(voice.available, "没声明可用性的音色不得被当成可用")
        XCTAssertNil(voice.availabilityReason, "原因同样没声明，不该编一个出来")
    }

    /// 同理：`implementation_supported` 缺字段按不支持处理。
    ///
    /// `testPartiallyDeclaredAxesFailClosed` 逐条断言了另外几个轴，
    /// 唯独漏掉这一个——它就混在同一段解码里，看得见却没人钉。
    func testAxesWithoutImplementationSupportedFailClosed() throws {
        let voice = try decodeVoice(
            """
            {
              "id": "partial-axes",
              "name": "Partial axes",
              "available": true,
              "streaming": {
                "supported": true,
                "voice_mode": "clone",
                "axes": {"reference_ready": true}
              }
            }
            """
        )

        let streaming = try XCTUnwrap(voice.streaming)
        XCTAssertTrue(streaming.axes.referenceReady)
        XCTAssertFalse(streaming.axes.implementationSupported, "没声明实现支持时按不支持处理")
    }

}
