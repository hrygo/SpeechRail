import XCTest
@testable import SpeechRailAppSupport

@MainActor
final class FakeTranslationClient: CaptionTranslationClient, @unchecked Sendable {
    var callCount = 0
    var lastSourceText: String?
    var lastContextLines: [String]?
    var streamDeltas: [String] = ["中文", "译文"]

    func translateStream(
        sourceText: String,
        contextLines: [String]
    ) -> AsyncThrowingStream<String, any Error> {
        callCount += 1
        lastSourceText = sourceText
        lastContextLines = contextLines
        let deltas = streamDeltas
        return AsyncThrowingStream { continuation in
            for delta in deltas {
                continuation.yield(delta)
            }
            continuation.finish()
        }
    }
}

@MainActor
final class CaptionTranslatorTests: XCTestCase {
    func testChineseTextBypassesLLMTranslation() async {
        let fake = FakeTranslationClient()
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })

        let testCases = [
            "今天我们讨论实时字幕架构",
            "今天讨论 API Design"
        ]

        for text in testCases {
            let detection = CaptionLanguageDetector.detect(for: text)
            XCTAssertTrue(detection.isChinese, "Expected '\(text)' to be detected as Chinese")
            XCTAssertEqual(detection.languageCode, "zh")

            var finishedCalled = false
            coordinator.translateCompletedLine(
                lineID: UUID().uuidString,
                sourceText: text,
                contextLines: [],
                displayMode: .bilingual,
                onStreamingUpdate: { _, _ in },
                onFinished: { _, translated, lang in
                    finishedCalled = true
                    XCTAssertNil(translated, "Chinese text should have nil translatedText")
                    XCTAssertEqual(lang, "zh")
                }
            )
            // Allow Task to execute
            await Task.yield()
            XCTAssertTrue(finishedCalled)
        }

        XCTAssertEqual(fake.callCount, 0, "LLM should not be called for Chinese text")
    }

    func testJapaneseWithKanjiIsDetectedAsNonChinese() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["今天天气真好"]
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })

        let text = "今日はいい天気ですね"
        let detection = CaptionLanguageDetector.detect(for: text)
        XCTAssertFalse(detection.isChinese, "Japanese text with kanji and kana must not be detected as Chinese")
        XCTAssertEqual(detection.languageCode, "ja")

        var finishedTranslation: String?
        var finishedLang: String?
        let expectation = expectation(description: "Translation finished")

        coordinator.translateCompletedLine(
            lineID: "line-ja-1",
            sourceText: text,
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, translated, lang in
                finishedTranslation = translated
                finishedLang = lang
                expectation.fulfill()
            }
        )

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(finishedTranslation, "今天天气真好")
        XCTAssertEqual(finishedLang, "ja")
    }

    func testPartialTranslationDebouncesAndCancelsStaleInFlight() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["最后结果"]
        let coordinator = CaptionTranslationCoordinator(
            partialDebounce: .milliseconds(50),
            minimumPartialDeltaChars: 3,
            makeClient: { fake }
        )

        var latestUpdate: String?
        coordinator.schedulePartialTranslation(
            sourceText: "Hello world 1",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { latestUpdate = $0 }
        )
        coordinator.schedulePartialTranslation(
            sourceText: "Hello world 1234",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { latestUpdate = $0 }
        )
        coordinator.schedulePartialTranslation(
            sourceText: "Hello world 12345678",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { latestUpdate = $0 }
        )

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(latestUpdate, "最后结果")
        XCTAssertEqual(fake.callCount, 1, "Only the last debounced partial should have fired")
        XCTAssertEqual(fake.lastSourceText, "Hello world 12345678")
    }

    func testCompletedLineIncludesUpToThreeContextLines() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["翻译结果"]
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })

        let context = [
            "Line 1: Once upon a time",
            "Line 2: There was a coder",
            "Line 3: Working on speech",
            "Line 4: Writing subtitles",
            "Line 5: Now testing"
        ]
        let current = "Line 6: Final sentence"

        let expectation = expectation(description: "Finished with context")
        coordinator.translateCompletedLine(
            lineID: "line-ctx-6",
            sourceText: current,
            contextLines: context,
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, _, _ in
                expectation.fulfill()
            }
        )

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(fake.lastSourceText, current)
        XCTAssertEqual(fake.lastContextLines, [
            "Line 3: Working on speech",
            "Line 4: Writing subtitles",
            "Line 5: Now testing"
        ], "Context must be bounded to the last 3 lines")

        let prompt = CaptionTranslationCoordinator.buildUserPrompt(
            sourceText: current,
            contextLines: fake.lastContextLines ?? []
        )
        XCTAssertTrue(prompt.contains("Line 3: Working on speech"))
        XCTAssertTrue(prompt.contains("Line 4: Writing subtitles"))
        XCTAssertTrue(prompt.contains("Line 5: Now testing"))
        XCTAssertFalse(prompt.contains("Line 1: Once upon a time"))
        XCTAssertFalse(prompt.contains("Line 2: There was a coder"))
        XCTAssertTrue(prompt.contains("【当前句（请仅将此句译为简练中文字幕）】\n\(current)"))
    }
}
