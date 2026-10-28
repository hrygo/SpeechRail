import XCTest
@testable import SpeechRailAppSupport

private struct TranslationFailure: Error {}

@MainActor
final class FakeTranslationClient: CaptionTranslationClient, @unchecked Sendable {
    var callCount = 0
    var lastSourceText: String?
    var lastContextLines: [String]?
    var lastPriorDraftTranslation: String?
    var lastSystemInstructions: String?
    var priorDrafts: [String?] = []
    var streamDeltas: [String] = ["中文", "译文"]
    var failure: (any Error)?
    /// 让流一直不结束，便于观察定稿瞬间的中间态（交接是否真的发生了）。
    var stallForever = false
    /// 从第 N 次调用起：一个字符都不吐就直接失败（模拟首字超时、模型不可用）。
    /// 用来构造"预览还在飞（协调器侧还没有已完成预览）→ 精翻一上来就失败"的时序。
    var failImmediatelyFromCall: Int?

    func translateStream(
        sourceText: String,
        contextLines: [String],
        priorDraftTranslation: String?,
        systemInstructions: String?
    ) -> AsyncThrowingStream<String, any Error> {
        lastSystemInstructions = systemInstructions
        return translateStream(
            sourceText: sourceText,
            contextLines: contextLines,
            priorDraftTranslation: priorDraftTranslation
        )
    }

    func translateStream(
        sourceText: String,
        contextLines: [String],
        priorDraftTranslation: String?
    ) -> AsyncThrowingStream<String, any Error> {
        callCount += 1
        let callIndex = callCount
        lastSourceText = sourceText
        lastContextLines = contextLines
        lastPriorDraftTranslation = priorDraftTranslation
        priorDrafts.append(priorDraftTranslation)
        let deltas = streamDeltas
        let failure = failure
        let stallForever = stallForever
        let failImmediatelyFromCall = failImmediatelyFromCall
        return AsyncThrowingStream { continuation in
            if let failImmediatelyFromCall, callIndex >= failImmediatelyFromCall {
                continuation.finish(throwing: failure ?? URLError(.timedOut))
                return
            }
            for delta in deltas {
                continuation.yield(delta)
            }
            if stallForever {
                return
            }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

@MainActor
final class GatedTranslationClient: CaptionTranslationClient, @unchecked Sendable {
    private(set) var started: [String] = []
    private var continuations: [String: AsyncThrowingStream<String, any Error>.Continuation] = [:]

    func translateStream(
        sourceText: String,
        contextLines: [String],
        priorDraftTranslation: String?,
        systemInstructions: String?
    ) -> AsyncThrowingStream<String, any Error> {
        started.append(sourceText)
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        continuations[sourceText] = continuation
        return stream
    }

    func translateStream(
        sourceText: String,
        contextLines: [String],
        priorDraftTranslation: String?
    ) -> AsyncThrowingStream<String, any Error> {
        translateStream(
            sourceText: sourceText,
            contextLines: contextLines,
            priorDraftTranslation: priorDraftTranslation,
            systemInstructions: nil
        )
    }

    func yield(_ translated: String, to sourceText: String) {
        continuations[sourceText]?.yield(translated)
    }

    func finish(_ sourceText: String) {
        continuations[sourceText]?.finish()
        continuations[sourceText] = nil
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

    func testTranslationStabilityCountsAppendAndRewrite() {
        var stability = CaptionTranslationStability()

        stability.record(previous: nil, current: "你好")
        XCTAssertEqual(stability.updates, 1)
        XCTAssertEqual(stability.appendedCharacters, 2)
        XCTAssertEqual(stability.erasedCharacters, 0)

        stability.record(previous: "你好", current: "你好世界")
        XCTAssertEqual(stability.updates, 2)
        XCTAssertEqual(stability.appendedCharacters, 4)
        XCTAssertEqual(stability.erasedCharacters, 0)
        XCTAssertEqual(stability.appendRatio, 1)

        stability.record(previous: "你好世界", current: "你好地球")
        XCTAssertEqual(stability.updates, 3)
        XCTAssertEqual(stability.erasedCharacters, 2)
        XCTAssertEqual(stability.appendedCharacters, 6)
        XCTAssertEqual(stability.resets, 0)

        stability.record(previous: "完全不同的句子", current: "新句")
        XCTAssertEqual(stability.resets, 1)
        XCTAssertTrue(stability.appendRatio < 1)
    }

    func testFinalTranslationRecordsStabilityAgainstDisplayedDraft() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["你好地球"]
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })
        let expectation = expectation(description: "Translation finished")

        coordinator.translateCompletedLine(
            lineID: "line-stability-1",
            sourceText: "A brand new sentence",
            contextLines: [],
            displayMode: .bilingual,
            priorDraftHint: "你好世界",
            onStreamingUpdate: { _, _ in },
            onFinished: { _, _, _ in expectation.fulfill() }
        )

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(coordinator.metrics.finalStability.updates, 1)
        XCTAssertEqual(coordinator.metrics.finalStability.erasedCharacters, 2)
        XCTAssertEqual(coordinator.metrics.finalStability.appendedCharacters, 2)
        XCTAssertEqual(coordinator.metrics.finalStability.resets, 0)
    }

    func testGlossaryParsesEntriesAndInjectsIntoPrompt() {
        let glossary = CaptionGlossary(
            text: "SpeechRail=语音轨道, Transformer → 变换器，bad, =空, SpeechRail=重复"
        )

        XCTAssertEqual(glossary.entries.map(\.source), ["SpeechRail", "Transformer", "bad"])
        XCTAssertEqual(glossary.entries[0].translation, "语音轨道")
        XCTAssertEqual(glossary.entries[1].translation, "变换器")
        XCTAssertNil(glossary.entries[2].translation)
        XCTAssertEqual(glossary.asrKeywords, ["SpeechRail", "Transformer", "bad"])

        let prompt = CaptionTranslationCoordinator.systemInstructions(
            for: .english,
            glossary: glossary
        )
        XCTAssertTrue(prompt.contains("SpeechRail → 语音轨道"))
        XCTAssertTrue(prompt.contains("Transformer → 变换器"))
        XCTAssertTrue(prompt.contains("bad（保持原文）"))
        XCTAssertTrue(prompt.contains("术语表"))
    }

    func testGlossaryCapsEntries() {
        let text = (1...30).map { "term\($0)=译\($0)" }.joined(separator: ",")
        let glossary = CaptionGlossary(text: text)
        XCTAssertEqual(glossary.entries.count, 24)
        XCTAssertEqual(glossary.entries.last?.source, "term24")
    }

    func testCompletedTranslationPassesGlossaryToModel() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["语音轨道"]
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })
        let expectation = expectation(description: "Translation finished")

        coordinator.translateCompletedLine(
            lineID: "line-glossary-1",
            sourceText: "SpeechRail keeps audio local",
            contextLines: [],
            displayMode: .bilingual,
            glossary: CaptionGlossary(text: "SpeechRail=语音轨道, Realtime=实时"),
            onStreamingUpdate: { _, _ in },
            onFinished: { _, _, _ in expectation.fulfill() }
        )

        await fulfillment(of: [expectation], timeout: 2.0)
        let instructions = try? XCTUnwrap(fake.lastSystemInstructions)
        XCTAssertTrue(instructions?.contains("SpeechRail → 语音轨道") == true)
        XCTAssertTrue(instructions?.contains("Realtime → 实时") == true)
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

        let deadline = Date().addingTimeInterval(1.0)
        while latestUpdate != "最后结果" && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(latestUpdate, "最后结果")
        XCTAssertEqual(fake.callCount, 1, "Only the last debounced partial should have fired")
        XCTAssertEqual(fake.lastSourceText, "Hello world 12345678")
    }

    func testCompletedLineIncludesUpToThreeContextLines() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["翻译结果"]
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })

        let context = [
            CaptionContextTurn(sourceText: "Line 1: Once upon a time", translatedText: "从前").formattedPromptLine,
            CaptionContextTurn(sourceText: "Line 2: There was a coder", translatedText: "有一位程序员").formattedPromptLine,
            CaptionContextTurn(sourceText: "Line 3: Working on speech", translatedText: "在做语音").formattedPromptLine,
            CaptionContextTurn(sourceText: "Line 4: Writing subtitles", translatedText: "写字幕").formattedPromptLine,
            CaptionContextTurn(sourceText: "Line 5: Now testing", translatedText: "现在测试").formattedPromptLine
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
            "原文：Line 3: Working on speech → 译文：在做语音",
            "原文：Line 4: Writing subtitles → 译文：写字幕",
            "原文：Line 5: Now testing → 译文：现在测试"
        ], "Context must be bounded to the last 3 lines")

        let prompt = CaptionTranslationCoordinator.buildUserPrompt(
            sourceText: current,
            contextLines: fake.lastContextLines ?? []
        )
        XCTAssertTrue(prompt.contains("原文：Line 3: Working on speech → 译文：在做语音"))
        XCTAssertTrue(prompt.contains("原文：Line 5: Now testing → 译文：现在测试"))
        XCTAssertFalse(prompt.contains("Line 1: Once upon a time"))
        XCTAssertFalse(prompt.contains("Line 2: There was a coder"))
        XCTAssertTrue(prompt.contains("【当前句（请仅将此句译为简练中文字幕）】\n\(current)"))
        XCTAssertFalse(prompt.contains("【当前句已上屏草稿"), "没有草稿时不应出现草稿段")
    }

    func testBuildUserPromptCarriesBilingualContextAndDraft() {
        let prompt = CaptionTranslationCoordinator.buildUserPrompt(
            sourceText: "Kubernetes schedules the pod",
            contextLines: ["原文：We run Kubernetes → 译文：我们跑 Kubernetes"],
            priorDraftTranslation: "Kubernetes 调度"
        )

        XCTAssertTrue(prompt.contains("【前文背景（仅供参考语境与专名译法，切勿重复翻译）】"))
        XCTAssertTrue(prompt.contains("原文：We run Kubernetes → 译文：我们跑 Kubernetes"))
        XCTAssertTrue(prompt.contains("【当前句已上屏草稿（若核心语义未反转请尽量保持前半句稳定）】\nKubernetes 调度"))
        XCTAssertTrue(prompt.contains("【当前句（请仅将此句译为简练中文字幕）】\nKubernetes schedules the pod"))
    }

    func testContextTurnOmitsTranslationForChineseSource() {
        let turn = CaptionContextTurn(sourceText: "这句本来就是中文", translatedText: nil)
        XCTAssertEqual(turn.formattedPromptLine, "原文：这句本来就是中文")

        let identical = CaptionContextTurn(sourceText: "这句本来就是中文", translatedText: "这句本来就是中文")
        XCTAssertEqual(identical.formattedPromptLine, "原文：这句本来就是中文")
    }

    // MARK: LocalAgreement-2 软前缀锚定

    func testLocalAgreementPrefixDropsVolatileTail() {
        XCTAssertEqual(
            CaptionTranslationCoordinator.localAgreementPrefix("我们把预算交给", "我们把预算交给财务"),
            "我们把预算"
        )
        XCTAssertNil(
            CaptionTranslationCoordinator.localAgreementPrefix("我们", "我们走"),
            "公共前缀太短时不给锚定"
        )
    }

    func testPartialTranslationCarriesSoftPrefixAnchorAcrossRounds() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["你好世界"]
        let coordinator = CaptionTranslationCoordinator(
            partialDebounce: .milliseconds(20),
            minimumPartialDeltaChars: 3,
            makeClient: { fake }
        )

        coordinator.schedulePartialTranslation(
            sourceText: "Hello world", contextLines: [], displayMode: .bilingual, onUpdate: { _ in }
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        coordinator.schedulePartialTranslation(
            sourceText: "Hello world again", contextLines: [], displayMode: .bilingual, onUpdate: { _ in }
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        coordinator.schedulePartialTranslation(
            sourceText: "Hello world again today", contextLines: [], displayMode: .bilingual, onUpdate: { _ in }
        )
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(fake.callCount, 3)
        XCTAssertNil(fake.priorDrafts[0], "第一轮没有可锚定的草稿")
        XCTAssertEqual(fake.priorDrafts[1], "你好世界", "第二轮沿用上一轮草稿")
        XCTAssertEqual(fake.priorDrafts[2], "你好", "第三轮用 LocalAgreement-2 稳定前缀（回退末尾 2 字）")
    }

    // MARK: 定稿交接与失败兜底

    func testCompletedLineWithoutClientHandsOverPartialDraft() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["预算已经批准"]
        var current: (any CaptionTranslationClient)? = fake
        let coordinator = CaptionTranslationCoordinator(
            partialDebounce: .milliseconds(20),
            minimumPartialDeltaChars: 3,
            makeClient: { current }
        )

        coordinator.schedulePartialTranslation(
            sourceText: "The budget is approved",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { _ in }
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        current = nil

        var finishedTranslation: String?
        var finishedLang: String?
        let expectation = expectation(description: "Finished without client")
        coordinator.translateCompletedLine(
            lineID: "line-draft-1",
            sourceText: "The budget is approved",
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
        XCTAssertEqual(finishedTranslation, "预算已经批准", "没有客户端时也要继承预览草稿，不能白屏")
        XCTAssertEqual(finishedLang, "en")
    }

    func testCompletedLineSalvagesPrefixAndFinishesWhenStage2Fails() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["预算已经"]
        fake.failure = TranslationFailure()
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })

        var finishedTranslation: String?
        let expectation = expectation(description: "Finished after failure")
        coordinator.translateCompletedLine(
            lineID: "line-fail-1",
            sourceText: "The budget is approved",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, translated, _ in
                finishedTranslation = translated
                expectation.fulfill()
            }
        )

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(finishedTranslation, "预算已经", "失败时保留已经到达的前缀")
    }

    func testCompletedLineFallsBackToDraftWhenStage2FailsBeforeAnyDelta() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["预算已经批准"]
        var current: (any CaptionTranslationClient)? = fake
        let coordinator = CaptionTranslationCoordinator(
            partialDebounce: .milliseconds(20),
            minimumPartialDeltaChars: 3,
            makeClient: { current }
        )

        coordinator.schedulePartialTranslation(
            sourceText: "The budget is approved",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { _ in }
        )
        try? await Task.sleep(nanoseconds: 200_000_000)

        fake.streamDeltas = []
        fake.failure = TranslationFailure()
        current = fake

        var finishedTranslation: String?
        let expectation = expectation(description: "Finished with draft fallback")
        coordinator.translateCompletedLine(
            lineID: "line-fail-2",
            sourceText: "The budget is approved",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, translated, _ in
                finishedTranslation = translated
                expectation.fulfill()
            }
        )

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(finishedTranslation, "预算已经批准", "一个字节都没到时退回 Stage 1 草稿")
    }

    // MARK: ASR 未定稿原文的视觉分层

    func testPartialStabilityKeepsCJKStablePrefix() {
        let previous = "今天天气很好我们出去走走"
        let current = "今天天气很好我们出去走走吧"
        let length = CaptionPartialStability.stablePrefixLength(previous: previous, current: current)

        XCTAssertEqual(length, previous.count - CaptionPartialStability.volatileTailReserve)
        XCTAssertEqual(String(current.prefix(length)), "今天天气很好我")
    }

    func testPartialStabilityBacksOffWholeLatinWords() {
        let previous = "I think the latency"
        let current = "I think the latency is high"
        let length = CaptionPartialStability.stablePrefixLength(previous: previous, current: current)

        XCTAssertEqual(length, 7)
        XCTAssertEqual(String(current.prefix(length)), "I think")
    }

    func testPartialStabilityStaysFlatWhenPrefixIsShortOrUnchanged() {
        XCTAssertEqual(CaptionPartialStability.stablePrefixLength(previous: "abc", current: "abcdef"), 0)
        XCTAssertEqual(CaptionPartialStability.stablePrefixLength(previous: "Hello world", current: "Hello world"), 0)
        XCTAssertEqual(CaptionPartialStability.stablePrefixLength(previous: "", current: "Hello"), 0)
    }

    // MARK: 源语种偏好与提示词工程

    func testSpecializedSystemInstructionsForEnglishJapaneseAndKorean() {
        let defaultPrompt = CaptionTranslationCoordinator.systemInstructions(for: .auto)
        let englishPrompt = CaptionTranslationCoordinator.systemInstructions(for: .english)
        let japanesePrompt = CaptionTranslationCoordinator.systemInstructions(for: .japanese)
        let koreanPrompt = CaptionTranslationCoordinator.systemInstructions(for: .korean)

        XCTAssertTrue(englishPrompt.contains("源语言为英语"))
        XCTAssertTrue(englishPrompt.contains("定语从句"))
        XCTAssertTrue(japanesePrompt.contains("SOV结构"))
        XCTAssertTrue(japanesePrompt.contains("句末谓语与否定形态"))
        XCTAssertTrue(koreanPrompt.contains("源语言为韩语（SOV结构）"))
        XCTAssertTrue(koreanPrompt.contains("敬语语气"))
        XCTAssertEqual(defaultPrompt, CaptionTranslationCoordinator.systemInstructions)
    }

    func testParagraphPromptAddsMergeRuleAndKeepsSegmentRule() {
        let single = CaptionTranslationCoordinator.systemInstructions(for: .english)
        let paragraph = CaptionTranslationCoordinator.systemInstructions(
            for: .english,
            isParagraph: true
        )

        XCTAssertTrue(single.contains("【实时切分】"))
        XCTAssertFalse(single.contains("【同段片段】"))
        XCTAssertTrue(paragraph.contains("【同段片段】"))
        XCTAssertTrue(paragraph.contains("先合并为语义完整的段落"))
    }

    func testKoreanWithHanjaIsDetectedAsKorean() {
        let detection = CaptionLanguageDetector.detect(for: "오늘 회의에서 豫算안을 승인했습니다")
        XCTAssertFalse(detection.isChinese)
        XCTAssertEqual(detection.languageCode, "ko")
    }

    func testPartialTranslationUsesLatestTextAppendedDuringDebounceWindow() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["翻译完成"]
        let coordinator = CaptionTranslationCoordinator(
            partialDebounce: .milliseconds(60),
            minimumPartialDeltaChars: 10,
            makeClient: { fake }
        )

        // 首次 12 字符跨过 10 字符门槛，进入 60ms 防抖等待
        coordinator.schedulePartialTranslation(
            sourceText: "Hello world!",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { _ in }
        )
        // 防抖期内追加 5 个字符（不足 10 字符门槛，但防抖醒来时应发送最新完整句子）
        try? await Task.sleep(nanoseconds: 15_000_000)
        coordinator.schedulePartialTranslation(
            sourceText: "Hello world! Next",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { _ in }
        )

        let deadline = Date().addingTimeInterval(1.0)
        while fake.callCount == 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(
            fake.lastSourceText,
            "Hello world! Next",
            "防抖窗口内新增的短尾词不能被丢弃"
        )
    }

    func testExplicitChinesePreferenceBypassesTranslationClient() async {
        let fake = FakeTranslationClient()
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })

        let expectation = expectation(description: "Chinese preference finished")
        var finishedTranslation: String?
        var finishedLang: String?

        coordinator.translateCompletedLine(
            lineID: "line-zh-pref",
            sourceText: "Hello world this is an apple",
            contextLines: [],
            displayMode: .bilingual,
            preferredLanguage: .chinese,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, translated, lang in
                finishedTranslation = translated
                finishedLang = lang
                expectation.fulfill()
            }
        )

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(fake.callCount, 0, "指定中文偏好时直通不调用大模型")
        XCTAssertNil(finishedTranslation)
        XCTAssertEqual(finishedLang, "zh")
    }

    func testCleanSubtitleOutputStripsThinkBlocksAndIncompleteThinkTags() {
        XCTAssertEqual(
            CaptionTranslationCoordinator.cleanSubtitleOutput("<think>正在推理词汇...</think>智能体 AI 的热潮飙升。"),
            "智能体 AI 的热潮飙升。"
        )
        XCTAssertEqual(
            CaptionTranslationCoordinator.cleanSubtitleOutput("<think>流式思考尚未闭合"),
            "",
            "未闭合的 <think> 标签在流式过程中不应泄漏上屏"
        )
    }

    func testPartialTranslatingStateResetsAfterFailureSoRowNeverStaysStuck() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = []
        fake.failure = TranslationFailure()
        let coordinator = CaptionTranslationCoordinator(
            partialDebounce: .milliseconds(10),
            minimumPartialDeltaChars: 10,
            makeClient: { fake }
        )

        // 短于 10 字符且无子句标点时，Stage 1 尚未触发，不应进入翻译中状态
        coordinator.schedulePartialTranslation(
            sourceText: "Grown",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { _ in }
        )
        XCTAssertFalse(coordinator.isTranslatingPartial)

        // 跨过阈值触发 Stage 1 时进入 isTranslatingPartial = true，失败后立即复位为 false
        coordinator.schedulePartialTranslation(
            sourceText: "Grown very rapidly, even if not quite as rapidly as",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { _ in }
        )
        XCTAssertTrue(coordinator.isTranslatingPartial)

        let deadline = Date().addingTimeInterval(1.0)
        while coordinator.isTranslatingPartial && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(
            coordinator.isTranslatingPartial,
            "Stage 1 请求失败后必须复位 isTranslatingPartial，避免底部预览行永久卡在“翻译中”"
        )
    }

    func testCompletedLineRetriesOnceWhenFirstAttemptFailsBeforeAnyDelta() async {
        var attempt = 0
        @MainActor final class FlakyFirstAttemptClient: CaptionTranslationClient, @unchecked Sendable {
            let onCall: @MainActor () -> Int
            init(onCall: @escaping @MainActor () -> Int) { self.onCall = onCall }
            func translateStream(
                sourceText: String,
                contextLines: [String],
                priorDraftTranslation: String?
            ) -> AsyncThrowingStream<String, any Error> {
                let current = onCall()
                return AsyncThrowingStream { continuation in
                    if current == 1 {
                        continuation.finish(throwing: URLError(.networkConnectionLost))
                    } else {
                        continuation.yield("重试成功译文")
                        continuation.finish()
                    }
                }
            }
        }

        let flaky = FlakyFirstAttemptClient {
            attempt += 1
            return attempt
        }
        let coordinator = CaptionTranslationCoordinator(makeClient: { flaky })
        let expectation = expectation(description: "Stage 2 retry succeeded")
        var finalOutput: String?

        coordinator.translateCompletedLine(
            lineID: "line-retry-1",
            sourceText: "The number of truly valuable applications has grown.",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, translated, _ in
                finalOutput = translated
                expectation.fulfill()
            }
        )

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(attempt, 2, "首字到达前瞬态失败应自动快速重试一次")
        XCTAssertEqual(finalOutput, "重试成功译文")
    }

    func testCompletedLineEnrichesUnfinishedContextLineFromRecentTranslationCache() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["第一句译文"]
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })

        let exp1 = expectation(description: "Line 1 finished")
        coordinator.translateCompletedLine(
            lineID: "line-1",
            sourceText: "First sentence here",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, _, _ in exp1.fulfill() }
        )
        await fulfillment(of: [exp1], timeout: 1.0)

        fake.streamDeltas = ["第二句译文"]
        let exp2 = expectation(description: "Line 2 finished")
        // 模拟调用方在 Line 1 译文落盘前只传了「原文：First sentence here」
        coordinator.translateCompletedLine(
            lineID: "line-2",
            sourceText: "Second sentence here",
            contextLines: ["原文：First sentence here"],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, _, _ in exp2.fulfill() }
        )
        await fulfillment(of: [exp2], timeout: 1.0)
        XCTAssertEqual(
            fake.lastContextLines,
            ["原文：First sentence here → 译文：第一句译文"],
            "协调器应使用近期已完成译文缓存自动补全未带译文的上下文行"
        )
    }

    func testCompletedLineRejectsMismatchedPartialDraftAndAcceptsPriorDraftHint() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["上一句的残留草稿"]
        let coordinator = CaptionTranslationCoordinator(
            partialDebounce: .milliseconds(10),
            minimumPartialDeltaChars: 5,
            makeClient: { fake }
        )

        coordinator.schedulePartialTranslation(
            sourceText: "Completely unrelated previous sentence",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { _ in }
        )
        let scheduleDeadline = Date().addingTimeInterval(1.0)
        while fake.callCount == 0 && Date() < scheduleDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        fake.streamDeltas = []
        fake.failure = TranslationFailure()

        let exp = expectation(description: "Mismatched draft rejected")
        var fallbackResult: String?
        coordinator.translateCompletedLine(
            lineID: "line-mismatch",
            sourceText: "Brand new short line",
            contextLines: [],
            displayMode: .bilingual,
            priorDraftHint: "会话层已校验同源草稿",
            onStreamingUpdate: { _, _ in },
            onFinished: { _, translated, _ in
                fallbackResult = translated
                exp.fulfill()
            }
        )
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertEqual(
            fallbackResult,
            "会话层已校验同源草稿",
            "不同句的残留 partial 草稿应被拒绝，优先采用会话层校验通过的同源 priorDraftHint"
        )
    }

    func testCleanSubtitleOutputStripsSurroundingQuotesAndPromptHeaders() {
        XCTAssertEqual(
            CaptionTranslationCoordinator.cleanSubtitleOutput("“真正有价值的应用数量也在快速增长。”"),
            "真正有价值的应用数量也在快速增长。"
        )
        XCTAssertEqual(
            CaptionTranslationCoordinator.cleanSubtitleOutput("【当前句（请仅将此句译为简练中文字幕）】\n「智能体 AI 的热潮飙升」"),
            "智能体 AI 的热潮飙升"
        )
        XCTAssertEqual(
            CaptionTranslationCoordinator.cleanSubtitleOutput("这是第一行\n这是第二行"),
            "这是第一行这是第二行",
            "中文之间的模型换行直接拼接，不插入空格"
        )
        XCTAssertEqual(
            CaptionTranslationCoordinator.cleanSubtitleOutput("the first line\nthe second line"),
            "the first line the second line",
            "拉丁词之间的换行补一个空格，避免粘连"
        )
        XCTAssertEqual(
            CaptionTranslationCoordinator.cleanSubtitleOutput("你是做什么工作的？\n我帮家庭通过保险和投资\n赚钱和省钱。\n好，不错。你想赢钱吗？\n当然想。好。"),
            "你是做什么工作的？我帮家庭通过保险和投资赚钱和省钱。好，不错。你想赢钱吗？当然想。好。",
            "带标点和断句的多行中文换行应平滑连接，避免在界面上断层"
        )
    }

    func testFinalTranslationsAreBoundedAndQueuedInArrivalOrder() async throws {
        let client = GatedTranslationClient()
        let coordinator = CaptionTranslationCoordinator(
            maximumConcurrentFinalTranslations: 1,
            makeClient: { client }
        )
        let firstFinished = expectation(description: "first finished")
        let secondFinished = expectation(description: "second finished")
        var finished: [String] = []

        coordinator.translateCompletedLine(
            lineID: "line-1",
            sourceText: "First English sentence.",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, translated, _ in
                finished.append(translated ?? "")
                firstFinished.fulfill()
            }
        )
        coordinator.translateCompletedLine(
            lineID: "line-2",
            sourceText: "Second English sentence.",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, translated, _ in
                finished.append(translated ?? "")
                secondFinished.fulfill()
            }
        )

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            client.started, ["First English sentence."],
            "并发上限为 1 时，第二句必须排队而不是同时打到模型"
        )

        client.yield("第一句", to: "First English sentence.")
        client.finish("First English sentence.")
        await fulfillment(of: [firstFinished], timeout: 1)
        let startedDeadline = Date().addingTimeInterval(1.0)
        while client.started.count < 2 && Date() < startedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            client.started, ["First English sentence.", "Second English sentence."],
            "第一句收口后队列才推进到第二句"
        )

        client.yield("第二句", to: "Second English sentence.")
        client.finish("Second English sentence.")
        await fulfillment(of: [secondFinished], timeout: 1)
        XCTAssertEqual(finished, ["第一句", "第二句"])
    }

    func testFinalTranslationMetricsRecordQueueWaitFirstDeltaAndCompletion() async throws {
        let fake = FakeTranslationClient()
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })
        let finished = expectation(description: "finished")

        coordinator.translateCompletedLine(
            lineID: "line-metrics",
            sourceText: "Hello from the metrics test.",
            contextLines: [],
            displayMode: .bilingual,
            requestedAt: Date().addingTimeInterval(-1),
            onStreamingUpdate: { _, _ in },
            onFinished: { _, _, _ in finished.fulfill() }
        )
        await fulfillment(of: [finished], timeout: 1)

        let metrics = coordinator.metrics
        XCTAssertEqual(metrics.finalRequests, 1)
        XCTAssertEqual(metrics.finalCompleted, 1)
        XCTAssertEqual(metrics.finalFailed, 0)
        XCTAssertEqual(metrics.finalQueueWait.count, 1)
        XCTAssertEqual(metrics.finalFirstDelta.count, 1)
        XCTAssertEqual(metrics.finalCompletion.count, 1)
        XCTAssertGreaterThanOrEqual(
            metrics.finalQueueWait.maximumMilliseconds, 1_000,
            "requestedAt 来自定稿到达时刻，队列等待应包含此前的落库等待"
        )
        XCTAssertGreaterThanOrEqual(metrics.finalCompletion.maximumMilliseconds, 1_000)
    }

    func testCancelAllDropsQueuedFinalAndClearsTranslatingState() async throws {
        let client = GatedTranslationClient()
        let coordinator = CaptionTranslationCoordinator(
            maximumConcurrentFinalTranslations: 1,
            makeClient: { client }
        )
        let queuedFinished = expectation(description: "queued finished")

        coordinator.translateCompletedLine(
            lineID: "line-running",
            sourceText: "Running English sentence.",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, _, _ in }
        )
        coordinator.translateCompletedLine(
            lineID: "line-queued",
            sourceText: "Queued English sentence.",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, translated, _ in
                XCTAssertNil(translated, "取消的排队行不应把预览草稿当定稿落库")
                queuedFinished.fulfill()
            }
        )

        let started1Deadline = Date().addingTimeInterval(1.0)
        while client.started.isEmpty && Date() < started1Deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(client.started, ["Running English sentence."])
        coordinator.cancelAll()
        await fulfillment(of: [queuedFinished], timeout: 1)
        XCTAssertEqual(
            client.started, ["Running English sentence."],
            "cancelAll 后排队行不得再发起模型请求"
        )
    }

    func testFinalQueueEnforcesMaximumPendingLimitAndEvictsOldestWithFallback() async throws {
        let client = GatedTranslationClient()
        let coordinator = CaptionTranslationCoordinator(
            maximumConcurrentFinalTranslations: 1,
            maximumPendingFinalTranslations: 2,
            makeClient: { client }
        )
        let evictedFinished = expectation(description: "evicted oldest pending item")
        var evictedFallback: String?

        // 第 1 条立即进入 running
        coordinator.translateCompletedLine(
            lineID: "running-1",
            sourceText: "Sentence one in flight.",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, _, _ in }
        )
        // 第 2 条进入 pending (1/2)，带 priorDraftHint
        coordinator.translateCompletedLine(
            lineID: "pending-oldest",
            sourceText: "Sentence two oldest pending.",
            contextLines: [],
            displayMode: .bilingual,
            priorDraftHint: "第二句保底草稿",
            onStreamingUpdate: { _, _ in },
            onFinished: { _, translated, _ in
                evictedFallback = translated
                evictedFinished.fulfill()
            }
        )
        // 第 3 条进入 pending (2/2)
        coordinator.translateCompletedLine(
            lineID: "pending-middle",
            sourceText: "Sentence three pending.",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, _, _ in }
        )
        // 第 4 条进入 pending，触发淘汰最旧的 pending-oldest
        coordinator.translateCompletedLine(
            lineID: "pending-newest",
            sourceText: "Sentence four newest pending.",
            contextLines: [],
            displayMode: .bilingual,
            onStreamingUpdate: { _, _ in },
            onFinished: { _, _, _ in }
        )

        await fulfillment(of: [evictedFinished], timeout: 1.0)
        XCTAssertEqual(coordinator.pendingFinalTranslationCount, 2, "等待队列长度必须受 maximumPendingFinalTranslations 限制")
        XCTAssertEqual(evictedFallback, "第二句保底草稿", "被淘汰的旧排队项必须回调 onFinished 清理状态并保留保底草稿")
        coordinator.cancelAll()
    }

    func testStabilizedStreamingDisplayHoldsPriorDraftPrefixAndSwitchesAfterRewriteOrCompletion() async {
        // 1. 流式前缀与旧草稿一致时，保持旧草稿不缩回
        XCTAssertEqual(
            CaptionTranslationCoordinator.stabilizedStreamingDisplay(
                accumulated: "我们",
                priorDisplayed: "我们正在测试实时字幕防抖"
            ),
            "我们正在测试实时字幕防抖"
        )
        // 2. 流式改写但尚不足 3 个字符时，短暂保持旧草稿避免单字闪烁
        XCTAssertEqual(
            CaptionTranslationCoordinator.stabilizedStreamingDisplay(
                accumulated: "大家",
                priorDisplayed: "我们正在测试实时字幕防抖"
            ),
            "我们正在测试实时字幕防抖"
        )
        // 3. 流式改写已满 3 个字符时，立即切换到新译文
        XCTAssertEqual(
            CaptionTranslationCoordinator.stabilizedStreamingDisplay(
                accumulated: "大家正在看",
                priorDisplayed: "我们正在测试实时字幕防抖"
            ),
            "大家正在看"
        )
        // 4. Stage 2 流式精翻端到端验证：前两个增量属于草稿前缀时不退回短词，流结束落定完整译文
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["预算", "已经", "批准，下周启动"]
        let coordinator = CaptionTranslationCoordinator(makeClient: { fake })
        var streamedUpdates: [String] = []
        var finalOutput: String?
        let exp = expectation(description: "Stage 2 stabilized streaming")

        coordinator.translateCompletedLine(
            lineID: "line-stream-guard",
            sourceText: "The budget is approved and starts next week",
            contextLines: [],
            displayMode: .bilingual,
            priorDraftHint: "预算已经批准",
            onStreamingUpdate: { _, partial in
                streamedUpdates.append(partial)
            },
            onFinished: { _, final, _ in
                finalOutput = final
                exp.fulfill()
            }
        )

        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertEqual(
            streamedUpdates,
            ["预算已经批准", "预算已经批准", "预算已经批准，下周启动"],
            "流式增量还在重复草稿前缀时不得缩回短词引起闪烁"
        )
        XCTAssertEqual(finalOutput, "预算已经批准，下周启动")
    }

    func testPartialTranslationDoesNotStarveDuringContinuousDebounceGrowth() async {
        let fake = FakeTranslationClient()
        fake.streamDeltas = ["顺延预览译文"]
        let coordinator = CaptionTranslationCoordinator(
            partialDebounce: .milliseconds(80),
            minimumPartialDeltaChars: 5,
            makeClient: { fake }
        )

        var latestUpdate: String?
        // t=0ms：触发首次防抖（80ms）
        coordinator.schedulePartialTranslation(
            sourceText: "We are testing",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { latestUpdate = $0 }
        )
        // t=30ms：同一句话顺延增长且带标点，更新待翻文本但不得重置防抖定时器
        try? await Task.sleep(for: .milliseconds(30))
        coordinator.schedulePartialTranslation(
            sourceText: "We are testing realtime,",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { latestUpdate = $0 }
        )
        // t=60ms：再次顺延增长超过 minimumPartialDeltaChars
        try? await Task.sleep(for: .milliseconds(30))
        coordinator.schedulePartialTranslation(
            sourceText: "We are testing realtime, caption stability",
            contextLines: [],
            displayMode: .bilingual,
            onUpdate: { latestUpdate = $0 }
        )
        // 连续顺延增长不重置定时器：若总耗时达 105ms 且 runner 负载较轻，可能在 t=80ms 醒来执行了 t=30ms 的快照，
        // 或在 t=80ms 调度到主线程时消费了 t=60ms 的最新快照。后续顺延增量会在初次流完成后顺畅衔接。
        // 轮询等待直到最终请求完成（最多等 1.0s），以稳定断言最终至少发起过 1 次请求且拿到最终译文。
        let deadline = Date().addingTimeInterval(1.0)
        while (fake.lastSourceText != "We are testing realtime, caption stability" || latestUpdate != "顺延预览译文") && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(fake.callCount, 1, "连续顺延增长不应被无休止重置定时器造成饥饿")
        XCTAssertEqual(fake.lastSourceText, "We are testing realtime, caption stability")
        XCTAssertEqual(latestUpdate, "顺延预览译文")
    }

    func testStabilizedDisplayPartialHoldsSingleFrameTailRollbackAndAcceptsConfirmedShrink() {
        var heldOnce = false
        let r1 = CaptionPartialStability.stabilizedDisplayPartial(
            currentDisplayed: nil,
            incoming: "今天我们来看看这个实时字幕",
            sameItem: false,
            alreadyHeldOnce: &heldOnce
        )
        XCTAssertEqual(r1, "今天我们来看看这个实时字幕")
        XCTAssertFalse(heldOnce)

        // 单帧尾部回退 2 个字：保持已上屏较长文本
        let r2 = CaptionPartialStability.stabilizedDisplayPartial(
            currentDisplayed: r1,
            incoming: "今天我们来看看这个实时",
            sameItem: true,
            alreadyHeldOnce: &heldOnce
        )
        XCTAssertEqual(r2, "今天我们来看看这个实时字幕")
        XCTAssertTrue(heldOnce)

        // 下一帧恢复增长：顺滑推进并复位 heldOnce
        let r3 = CaptionPartialStability.stabilizedDisplayPartial(
            currentDisplayed: r2,
            incoming: "今天我们来看看这个实时字幕模块",
            sameItem: true,
            alreadyHeldOnce: &heldOnce
        )
        XCTAssertEqual(r3, "今天我们来看看这个实时字幕模块")
        XCTAssertFalse(heldOnce)

        // 连续两帧回退：第一帧保持，第二帧确认采纳
        let r4 = CaptionPartialStability.stabilizedDisplayPartial(
            currentDisplayed: r3,
            incoming: "今天我们来看看这个实时字幕",
            sameItem: true,
            alreadyHeldOnce: &heldOnce
        )
        XCTAssertEqual(r4, "今天我们来看看这个实时字幕模块")
        XCTAssertTrue(heldOnce)

        let r5 = CaptionPartialStability.stabilizedDisplayPartial(
            currentDisplayed: r4,
            incoming: "今天我们来看看这个实时字幕",
            sameItem: true,
            alreadyHeldOnce: &heldOnce
        )
        XCTAssertEqual(r5, "今天我们来看看这个实时字幕")
        XCTAssertFalse(heldOnce)
    }
}
