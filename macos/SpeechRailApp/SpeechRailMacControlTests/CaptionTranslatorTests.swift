import XCTest
@testable import SpeechRailAppSupport

private struct TranslationFailure: Error {}

@MainActor
final class FakeTranslationClient: CaptionTranslationClient, @unchecked Sendable {
    var callCount = 0
    var lastSourceText: String?
    var lastContextLines: [String]?
    var lastPriorDraftTranslation: String?
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

        try? await Task.sleep(nanoseconds: 120_000_000)
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

        try? await Task.sleep(nanoseconds: 60_000_000)
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
        try? await Task.sleep(nanoseconds: 60_000_000)

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
    }
}
