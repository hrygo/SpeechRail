import XCTest

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class TeleprompterAnalysisTests: XCTestCase {
    private final class PromptCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""

        func set(_ prompt: String) {
            lock.lock()
            value = prompt
            lock.unlock()
        }

        func get() -> String {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let sourceText = "欢迎来到直播。\n今天介绍三个重点。"

    private var validJSON: String {
        """
        {
          "schema_version": "teleprompter.analysis.v1",
          "segments": [
            {
              "id": "segment-1",
              "source_start": 0,
              "source_end": 8,
              "text": "欢迎来到直播。",
              "keywords": ["欢迎", "直播"],
              "match_phrases": ["欢迎来到直播"],
              "pause_hint": "short",
              "unknown_field": "ignored"
            },
            {
              "id": "segment-2",
              "source_start": 8,
              "source_end": 17,
              "text": "今天介绍三个重点。",
              "keywords": ["重点"],
              "match_phrases": [],
              "pause_hint": "medium"
            }
          ]
        }
        """
    }

    func testDecoderAcceptsVersionedSchemaAndIgnoresUnknownFields() throws {
        let analysis = try TeleprompterAnalysisDecoder().decode(validJSON, sourceText: sourceText)

        XCTAssertEqual(analysis.schemaVersion, TeleprompterAnalysis.schemaVersion)
        XCTAssertEqual(analysis.segments.map(\.id), ["segment-1", "segment-2"])
        XCTAssertEqual(analysis.segments[1].pauseHint, .medium)
    }

    func testDecoderRejectsSchemaVersionMismatch() {
        let json = validJSON.replacingOccurrences(
            of: "teleprompter.analysis.v1",
            with: "teleprompter.analysis.v2"
        )

        XCTAssertThrowsError(try TeleprompterAnalysisDecoder().decode(json, sourceText: sourceText)) { error in
            XCTAssertEqual(error as? TeleprompterTextError, .invalidAnalysis)
        }
    }

    func testDecoderRejectsTextThatCannotBeTracedToSourceRange() {
        let json = validJSON.replacingOccurrences(of: "欢迎来到直播。", with: "AI 自己扩写的内容。")

        XCTAssertThrowsError(try TeleprompterAnalysisDecoder().decode(json, sourceText: sourceText)) { error in
            XCTAssertEqual(error as? TeleprompterTextError, .invalidAnalysis)
        }
    }

    func testDecoderRejectsOverlappingOrInvalidRanges() {
        let json = validJSON.replacingOccurrences(of: "\"source_start\": 8", with: "\"source_start\": 7")

        XCTAssertThrowsError(try TeleprompterAnalysisDecoder().decode(json, sourceText: sourceText)) { error in
            XCTAssertEqual(error as? TeleprompterTextError, .invalidAnalysis)
        }
    }

    func testAIClientUsesInjectedCompletionAndReturnsStructuredAnalysis() async throws {
        let capturedPrompt = PromptCapture()
        let response = validJSON
        let client = TeleprompterAIClient { prompt in
            capturedPrompt.set(prompt)
            return response
        }

        let analysis = try await client.analyze(
            .init(sourceText: sourceText, language: "zh-CN", style: "自然、适合直播")
        )

        XCTAssertEqual(analysis.segments.count, 2)
        XCTAssertTrue(capturedPrompt.get().contains(sourceText))
        XCTAssertFalse(capturedPrompt.get().contains("api_key"))
        XCTAssertFalse(capturedPrompt.get().contains("Authorization"))
    }

    func testAIClientPropagatesInvalidAnalysisWithoutMutatingSource() async {
        let client = TeleprompterAIClient { _ in "{}" }

        do {
            _ = try await client.analyze(.init(sourceText: sourceText, language: nil, style: nil))
            XCTFail("expected invalid analysis")
        } catch let error as TeleprompterTextError {
            XCTAssertEqual(error, .invalidAnalysis)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
