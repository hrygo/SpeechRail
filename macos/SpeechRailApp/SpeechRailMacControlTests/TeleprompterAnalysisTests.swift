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

    @Test func rejectsUnknownTopLevelFields() {
        // The closed-object check exists at the segment level and had a test;
        // at the top level it had none, so a model could return an extra
        // sibling key and the envelope was accepted anyway.
        let withExtra = valid.replacingOccurrences(
            of: "\"segments\":[",
            with: "\"summary\":\"改写全文\",\"segments\":["
        )

        #expect(throws: TeleprompterTextError.self) {
            try TeleprompterAnalysisDecoder().decode(withExtra, sourceText: source)
        }
    }

    @Test func rejectsGapsBetweenGroups() {
        // The existing "gap" fixture ends past the last unit, so it is the upper
        // bound that catches it -- the contiguity check itself was never the
        // thing under test. Skipping a unit in the middle satisfies both the
        // upper bound and the final coverage check while leaving that unit
        // without keywords or a pause hint.
        let four = "一。二。三。四。"
        let skipping = #"{"schema_version":"teleprompter.analysis.v2","segments":[{"start_unit":0,"end_unit":1,"keywords":[],"match_phrases":[],"pause_hint":"short"},{"start_unit":2,"end_unit":4,"keywords":[],"match_phrases":[],"pause_hint":"short"}]}"#

        #expect(throws: TeleprompterTextError.self) {
            try TeleprompterAnalysisDecoder().decode(skipping, sourceText: four)
        }
    }

    @Test func rejectsModelInjectedReadingAliases() {
        // Reading aliases are the reader's decision: the session writes
        // `annotation.matchPhrases` straight into the accepted version, and
        // those phrases are what the aligner matches against. The plan requires
        // that a model can never introduce them, and this decoder check was the
        // only thing enforcing that -- with no test observing it.
        let injected = valid.replacingOccurrences(
            of: "\"match_phrases\":[]",
            with: "\"match_phrases\":[\"稳定性良好\"]"
        )

        #expect(throws: TeleprompterTextError.self) {
            try TeleprompterAnalysisDecoder().decode(injected, sourceText: source)
        }
    }

    @Test func rejectsKeywordsThatDoNotAppearInReadingOrder() throws {
        // Advancing the search bound is what makes this an ordering check
        // rather than a membership check: "文" consumes the only 文 in 中文, so
        // the earlier 中 can no longer satisfy the second keyword.
        let ordered = #"{"schema_version":"teleprompter.analysis.v2","segments":[{"start_unit":0,"end_unit":1,"keywords":["中文"],"match_phrases":[],"pause_hint":"short"}]}"#
        let reversed = #"{"schema_version":"teleprompter.analysis.v2","segments":[{"start_unit":0,"end_unit":1,"keywords":["文","中"],"match_phrases":[],"pause_hint":"short"},{"start_unit":1,"end_unit":2,"keywords":[],"match_phrases":[],"pause_hint":"short"}]}"#

        // The in-order pair is the control: it must still decode, otherwise the
        // assertion below would pass for the wrong reason.
        #expect(try TeleprompterAnalysisDecoder().decode(ordered, sourceText: "中文。").segments[0].keywords == ["中文"])
        #expect(throws: TeleprompterTextError.self) {
            try TeleprompterAnalysisDecoder().decode(reversed, sourceText: "中文。第二句。")
        }
    }

    @Test func unicodeRangeIsNeverCalculatedByModel() throws {
        let source = "😀欢迎大家。第二句开始。"
        let result = try TeleprompterAnalysisDecoder().decode(valid.replacingOccurrences(of: "直播", with: "欢迎"), sourceText: source)
        #expect(result.segments[0].text == "😀欢迎大家。")
        #expect(result.segments[1].sourceRange.start == 7)
    }

    @Test func aUnitLongerThanTheMergeBoundIsAcceptedOnItsOwn() throws {
        // The 180-character bound stops the model from *merging* units into one
        // oversized annotation. The segmenter's soft target does not bound CJK
        // sentences -- a 500-character Chinese sentence is a single unit -- so
        // before this, such a script could not be annotated at all and the
        // session reported the model's perfectly valid response as an AI
        // failure.
        let long = String(repeating: "字", count: 240) + "。"
        let oneUnit = #"{"schema_version":"teleprompter.analysis.v2","segments":[{"start_unit":0,"end_unit":1,"keywords":[],"match_phrases":[],"pause_hint":"long"}]}"#

        let result = try TeleprompterAnalysisDecoder().decode(oneUnit, sourceText: long)

        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == long)
    }

    @Test func mergingUnitsPastTheBoundIsStillRejected() throws {
        // The exemption above is for a lone unit, not for merging: two 120-unit
        // paragraphs merged into one 240-character group is exactly what the
        // bound exists to refuse.
        let paragraph = String(repeating: "字", count: 119) + "。"
        let source = paragraph + "\n" + paragraph
        let merged = #"{"schema_version":"teleprompter.analysis.v2","segments":[{"start_unit":0,"end_unit":2,"keywords":[],"match_phrases":[],"pause_hint":"short"}]}"#

        #expect(throws: TeleprompterTextError.self) {
            try TeleprompterAnalysisDecoder().decode(merged, sourceText: source)
        }
    }

    @Test @MainActor func aScriptWithAnOverlongUnitStillAnnotatesEndToEnd() async throws {
        let long = String(repeating: "字", count: 240) + "。"
        let response = #"{"schema_version":"teleprompter.analysis.v2","segments":[{"start_unit":0,"end_unit":1,"keywords":[],"match_phrases":[],"pause_hint":"long"}]}"#
        let client = TeleprompterAIClient { _ in response }

        let analysis = try await client.analyze(.init(sourceText: long, language: "zh-CN", style: "自然"))

        #expect(analysis.segments.count == 1)
        #expect(analysis.segments[0].text == long)
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

    @Test @MainActor func laterWindowFailureDoesNotReturnPartialScript() async {
        var calls = 0
        let client = TeleprompterAIClient { prompt in
            calls += 1
            if calls == 2 { return "{}" }
            let context = try #require(JSONSerialization.jsonObject(with: Data(prompt.input.utf8)) as? [String: Any])
            let units = try #require(context["units"] as? [[String: Any]])
            let annotations = try units.map { unit -> [String: Any] in
                let id = try #require(unit["id"] as? Int)
                return ["start_unit": id, "end_unit": id + 1, "keywords": [], "match_phrases": [], "pause_hint": "short"]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["schema_version": "teleprompter.analysis.v2", "segments": annotations]), as: UTF8.self)
        }
        await #expect(throws: TeleprompterTextError.self) {
            try await client.analyze(.init(sourceText: String(repeating: "测试完整稿件。", count: 24), language: nil, style: nil))
        }
        #expect(calls == 2)
    }

    @Test func rejectsInventedKeywordAndMissingLastUnit() {
        let invented = valid.replacingOccurrences(of: "直播", with: "新事实")
        #expect(throws: TeleprompterTextError.self) {
            try TeleprompterAnalysisDecoder().decode(invented, sourceText: source)
        }
        let omitted = #"{"schema_version":"teleprompter.analysis.v2","segments":[{"start_unit":0,"end_unit":1,"keywords":[],"match_phrases":[],"pause_hint":"short"}]}"#
        #expect(throws: TeleprompterTextError.self) {
            try TeleprompterAnalysisDecoder().decode(omitted, sourceText: source)
        }
    }
}
