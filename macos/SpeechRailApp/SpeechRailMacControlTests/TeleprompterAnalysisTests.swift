import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterAnalysisTests {
    private let source = "欢迎来到直播。\n今天介绍三个重点。"
    private let valid = #"{"schema_version":"teleprompter.analysis.v2","segments":[{"start_unit":0,"end_unit":1,"keywords":["直播"],"match_phrases":[],"pause_hint":"short"},{"start_unit":1,"end_unit":2,"keywords":[],"match_phrases":[],"pause_hint":"medium"}]}"#

    @Test func restoresExactTextAndOffsetsLocally() throws {
        let result = try TeleprompterAnalysisDecoder().decode(valid, sourceText: source)
        #expect(result.segments.map(\.text) == ["欢迎来到直播。", "今天介绍三个重点。"])
        #expect(result.segments[1].sourceRange.start == 8)
        #expect(result.segments[1].sourceRange.end == 17)
    }

    @Test func rejectsOmissionsOverlapAndUnknownFields() {
        for invalid in [
            valid.replacingOccurrences(of: "\"start_unit\":1", with: "\"start_unit\":0"),
            valid.replacingOccurrences(of: "\"end_unit\":2", with: "\"end_unit\":3"),
            valid.replacingOccurrences(of: "\"end_unit\":2", with: "\"end_unit\":1"),
            valid.replacingOccurrences(of: "\"pause_hint\":\"medium\"", with: "\"pause_hint\":\"medium\",\"text\":\"invented\""),
            valid.replacingOccurrences(of: "analysis.v2", with: "analysis.v1")
        ] {
            #expect(throws: TeleprompterTextError.self) {
                try TeleprompterAnalysisDecoder().decode(invalid, sourceText: source)
            }
        }
    }

    @Test func unicodeRangeIsNeverCalculatedByModel() throws {
        let source = "😀欢迎大家。第二句开始。"
        let result = try TeleprompterAnalysisDecoder().decode(valid.replacingOccurrences(of: "直播", with: "欢迎"), sourceText: source)
        #expect(result.segments[0].text == "😀欢迎大家。")
        #expect(result.segments[1].sourceRange.start == 7)
    }

    @Test func contextSeparatesInstructionsAndIncludesNumberedUnits() throws {
        let prompt = try TeleprompterAIClient.prompt(for: .init(sourceText: source, language: "zh-CN", style: "自然"))
        #expect(!prompt.instructions.contains(source))
        #expect(prompt.input.contains("units"))
        #expect(prompt.input.contains("欢迎来到直播"))
        #expect(!prompt.input.contains("source_start"))
        #expect(prompt.instructions.contains("不改写"))
    }

    @Test @MainActor func longScriptUsesBoundedWindowsAndMergesAllUnits() async throws {
        var calls = 0
        let client = TeleprompterAIClient { prompt in
            calls += 1
            let data = Data(prompt.input.utf8)
            let context = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let units = try #require(context["units"] as? [[String: Any]])
            #expect(units.count <= 12)
            let annotations = units.map { unit -> [String: Any] in
                let id = unit["id"] as! Int
                return ["start_unit": id, "end_unit": id + 1, "keywords": [], "match_phrases": [], "pause_hint": "short"]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["schema_version": "teleprompter.analysis.v2", "segments": annotations]), as: UTF8.self)
        }
        let source = String(repeating: "这是用于跟读测试的一句话。", count: 30)
        let result = try await client.analyze(.init(sourceText: source, language: nil, style: nil))
        #expect(calls == 3)
        #expect(result.segments.count == 30)
        #expect(result.segments.map(\.text).joined() == source)
        #expect(Set(result.segments.map(\.id)).count == 30)
    }

    @Test @MainActor func invalidWindowFailsWholeAnalysis() async {
        let client = TeleprompterAIClient { _ in "{}" }
        await #expect(throws: TeleprompterTextError.self) {
            try await client.analyze(.init(sourceText: source, language: nil, style: nil))
        }
    }
}
