import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 播放预算与"整轮结束"判定的纯状态测试：不启动音频设备，不涉及可听延迟。
final class AssistantPlaybackLedgerTests: XCTestCase {
    func testReservationStaysWithinTheQueuedSampleBudget() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 3)

        XCTAssertTrue(ledger.reserve(samples: 12_000))
        XCTAssertEqual(ledger.queuedSamples, 12_000)
        XCTAssertTrue(ledger.reserve(samples: 12_000))
        XCTAssertFalse(ledger.reserve(samples: 1), "超过一秒的排队预算必须被拒绝")
        XCTAssertEqual(ledger.queuedSamples, 24_000)
    }

    func testCompletionFromAStaleGenerationIsIgnored() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 4)
        XCTAssertTrue(ledger.reserve(samples: 480))

        XCTAssertFalse(ledger.complete(samples: 480, generation: 3))
        XCTAssertEqual(ledger.queuedSamples, 480, "旧代的 completion 不能清掉新一代的排队")

        XCTAssertTrue(ledger.complete(samples: 480, generation: 4))
        XCTAssertEqual(ledger.queuedSamples, 0)
    }

    func testTemporaryDrainIsNotAFinishedUtterance() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 1)
        XCTAssertTrue(ledger.reserve(samples: 240))
        XCTAssertFalse(ledger.isUtteranceFinished)

        XCTAssertTrue(ledger.complete(samples: 240, generation: 1))
        XCTAssertTrue(ledger.isDrained)
        XCTAssertFalse(ledger.isUtteranceFinished, "只是暂时排空：服务端还没给终态")

        XCTAssertTrue(ledger.markServerTerminal(status: "completed", generation: 1))
        XCTAssertTrue(ledger.isUtteranceFinished)
        XCTAssertEqual(ledger.terminalStatus, "completed")
    }

    func testServerTerminalBeforeDrainStillWaitsForPlayback() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 9)
        XCTAssertTrue(ledger.reserve(samples: 4_800))
        XCTAssertTrue(ledger.markServerTerminal(status: "completed", generation: 9))

        XCTAssertFalse(ledger.isUtteranceFinished)
        XCTAssertTrue(ledger.complete(samples: 4_800, generation: 9))
        XCTAssertTrue(ledger.isUtteranceFinished)
    }

    func testTerminalFromAnotherGenerationDoesNotApply() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 2)
        XCTAssertFalse(ledger.markServerTerminal(status: "completed", generation: 1))
        XCTAssertNil(ledger.terminalStatus)
    }

    func testInvalidateDropsQueuedSamplesAndAdvancesTheGeneration() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 5)
        XCTAssertTrue(ledger.reserve(samples: 1_000))
        ledger.markInputClosed()
        XCTAssertTrue(ledger.markServerTerminal(status: "completed", generation: 5))

        ledger.invalidate()
        XCTAssertEqual(ledger.generation, 6)
        XCTAssertEqual(ledger.queuedSamples, 0)
        XCTAssertFalse(ledger.serverTerminal)
        XCTAssertFalse(ledger.inputClosed)
    }

    /// A40：terminal 已到但设备未播完，不宣称 completed；rendered/played 分开。
    func testA40TerminalWaitsForPlayedEvidence() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 1)
        XCTAssertTrue(ledger.reserve(samples: 1_000))
        XCTAssertTrue(ledger.markServerTerminal(status: "completed", generation: 1))
        // rendered 先到：只释放渲染预算，不算播放完成。
        XCTAssertTrue(ledger.complete(samples: 1_000, generation: 1))
        XCTAssertTrue(ledger.isDrained)
        XCTAssertFalse(ledger.isPlayedThrough, "played 未到不得宣称播放完成")
        // played 到达：才算整轮播放完成。
        XCTAssertTrue(ledger.markPlayed(samples: 1_000, generation: 1))
        XCTAssertTrue(ledger.isPlayedThrough)
    }

    /// A44：旧代 played 不得冲销新代；新代 played 正常记账。
    func testA44PendingVoiceTracksActualNextRequest() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 2)
        XCTAssertTrue(ledger.reserve(samples: 500))
        XCTAssertFalse(ledger.markPlayed(samples: 500, generation: 1), "旧代 played 应拒绝")
        XCTAssertEqual(ledger.playedSamples, 0)
        XCTAssertTrue(ledger.complete(samples: 500, generation: 2))
        XCTAssertTrue(ledger.markPlayed(samples: 500, generation: 2))
        XCTAssertEqual(ledger.playedSamples, 500)
    }

    /// A36：Emoji/组合字符/扩展汉字跨 delta 时 raw/sent/ACK 按 codepoint 一致，文字不破坏。
    func testA36UnicodeScalarAndAckAgreement() {
        var buffer = AssistantSpeechTextBuffer()
        // 跨 delta 的组合字符与扩展汉字：准入按 scalar 计，不破坏原文。
        let deltas = ["emoji 🎧", "组合é", "扩展𠀋", "家庭👨‍👩‍👧‍👦"]
        for delta in deltas {
            XCTAssertNil(buffer.append(delta), "合法增量应准入：\(delta)")
        }
        let joined = deltas.joined()
        XCTAssertEqual(buffer.offeredScalars, joined.unicodeScalars.count, "offered 按 scalar 累计")
        let chunks = buffer.flush(now: ContinuousClock().now)
        XCTAssertEqual(chunks.joined(), joined, "跨 Unicode 增量拼接不破坏原文")
        // scalar 与 grapheme 不同：限额按 scalar，不是按用户看到的字符数。
        XCTAssertNotEqual(
            joined.unicodeScalars.count, joined.count,
            "含 ZWJ 的 emoji 应证明两种计量不同"
        )
    }

    /// A37：词边界在分包中保留；Store/UI 原始输出不变。
    func testA37WordsAndWhitespaceSurviveChunking() {
        var buffer = AssistantSpeechTextBuffer()
        // Hel+lo 拆包：保守模式下英文尾词不提前切，等待后完整交付。
        buffer.append("Hel")
        XCTAssertEqual(buffer.readyChunks(now: ContinuousClock().now), [], "英文词还在长时不提前切")
        buffer.append("lo")
        // 空格独立 delta：原样保留，不吞空格。
        buffer.append(" ")
        buffer.append("世界")
        let chunks = buffer.flush(now: ContinuousClock().now)
        XCTAssertEqual(chunks.joined(), "Hello 世界", "词边界与空格保留")
        // 中英混合：原文未经清洗改写，Store/UI 侧仍是完整原文。
        var mixed = AssistantSpeechTextBuffer()
        mixed.append("Hello")
        mixed.append(" ")
        mixed.append("世界")
        XCTAssertEqual(mixed.flush(now: ContinuousClock().now).joined(), "Hello 世界")
    }

    /// A38（D 部分）：数字 token 跨片不切开语义单位；原文完整保留不猜补。
    /// 真实模型朗读质量记 R，本用例只锁分包保真策略。
    func testA38NumericTokensRemainFaithful() {
        // 3.+5 不提前切：小数还在长时保守模式不出声。
        var buffer = AssistantSpeechTextBuffer()
        buffer.append("3.")
        XCTAssertEqual(buffer.readyChunks(now: ContinuousClock().now), [], "小数未完成不提前切")
        buffer.append("5")
        buffer.append("kg")
        XCTAssertEqual(buffer.flush(now: ContinuousClock().now).joined(), "3.5kg")
        // 负号/百分号/版本号跨 delta：原文完整保留，不猜补。
        var symbols = AssistantSpeechTextBuffer()
        for delta in ["-5", "%", "v", "2", ".", "0"] {
            XCTAssertNil(symbols.append(delta))
        }
        XCTAssertEqual(symbols.flush(now: ContinuousClock().now).joined(), "-5%v2.0")
        // 金额单位：12 与万元不拆语义，原文完整。
        var money = AssistantSpeechTextBuffer()
        money.append("12")
        money.append("万元")
        XCTAssertEqual(money.flush(now: ContinuousClock().now).joined(), "12万元")
    }

    /// §7.3 交叉边界（A40/A52）：played 不回。
    /// terminal + rendered 全到但 played 缺失时，不得宣称播放完成；
    /// 完成与失败都只记一次，取消不假造 played。
    func testPlayedMissingNeverClaimsCompletion() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 11)
        XCTAssertTrue(ledger.reserve(samples: 1_000))
        XCTAssertTrue(ledger.markServerTerminal(status: "completed", generation: 11))
        XCTAssertTrue(ledger.complete(samples: 1_000, generation: 11))
        XCTAssertFalse(ledger.isPlayedThrough, "played 缺失不得宣称播放完成")
        XCTAssertEqual(ledger.playedSamples, 0, "取消不得假造 played")
    }

    /// §7.3 交叉边界（A40/A52）：device 重建后旧 rendered/played 双回。
    /// 旧代重建后的迟到 rendered/played 双双被拒，新代账本不受污染。
    func testRebuiltDeviceOldRenderedAndPlayedAreRejected() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 21)
        XCTAssertTrue(ledger.reserve(samples: 500))
        XCTAssertTrue(ledger.complete(samples: 500, generation: 21))
        XCTAssertTrue(ledger.markPlayed(samples: 500, generation: 21))
        // device 重建 = 新代开始；旧代双回迟到。
        ledger.begin(generation: 22)
        XCTAssertFalse(ledger.complete(samples: 500, generation: 21), "旧代 rendered 双回应拒绝")
        XCTAssertFalse(ledger.markPlayed(samples: 500, generation: 21), "旧代 played 双回应拒绝")
        XCTAssertEqual(ledger.renderedSamples, 0)
        XCTAssertEqual(ledger.playedSamples, 0)
    }
}
