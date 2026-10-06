import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 语音契约与"送进 TTS 之前"的清洗（`TECHNICAL-DESIGN` §5.5）。
///
/// 清洗是纯函数，也正是最该有回归的地方：它一旦多切一个字符，用户听到的就不是模型原话。
final class VoicePromptTests: XCTestCase {

    func testContractKeepsVoiceFirstRules() {
        let contract = VoicePrompt.instructions

        XCTAssertTrue(contract.contains("语音助手"))
        XCTAssertTrue(contract.contains("朗读"))
        XCTAssertTrue(contract.contains("# 输出契约"))
        XCTAssertTrue(contract.contains("# 优先级"))
        XCTAssertTrue(contract.contains("不要 markdown"))
        XCTAssertTrue(contract.contains("跟随用户当前使用的语言"))
        XCTAssertFalse(contract.contains("一律用普通话"))
        XCTAssertFalse(contract.contains("只能用中文"))
    }

    func testStyleBlockDefersToContractAndKeepsPersona() {
        let block = VoicePrompt.styleBlock("  你是一位耐心的讲解者。  ")

        XCTAssertTrue(block.hasPrefix("# 角色风格（人设）"))
        // VA-10：人设不再写死服从朗读要求，以当轮模态契约为准。
        XCTAssertTrue(block.contains("以当轮模态契约为准"))
        XCTAssertTrue(block.hasSuffix("你是一位耐心的讲解者。"))
    }

    /// A33：同问题键入/语音走不同模态契约（纯文字断言，真实输出记 R）。
    func testA33ModalityPreservesRequestedStructure() {
        let text = VoicePrompt.instructionsFor(input: .keyboard, output: .textOnly)
        XCTAssertTrue(text.contains("允许 Markdown"), "文字模态应允许结构化输出")
        XCTAssertFalse(text.contains("语音识别容错"), "文字模态不套 ASR 容错")
        let spoken = VoicePrompt.instructionsFor(input: .recognizedSpeech, output: .spokenConcise)
        XCTAssertTrue(spoken.contains("朗读"), "语音模态保留朗读契约")
    }

    /// A34 / V14 fake 可测部分：关键语音歧义走澄清，不猜金额/日期/否定/专名。
    func testA34CriticalRecognitionAmbiguityIsNotGuessed() {
        for modality in [
            VoicePrompt.instructionsFor(input: .keyboard, output: .textOnly),
            VoicePrompt.instructionsFor(input: .recognizedSpeech, output: .spokenConcise),
            VoicePrompt.instructionsFor(input: .recognizedSpeech, output: .textOnly),
        ] {
            XCTAssertTrue(modality.contains("一次一问题"), "歧义澄清一次一问题")
            XCTAssertTrue(modality.contains("禁止泛化"), "禁止泛化猜测")
            // “不伪造置信度”以否定形式出现（“不伪造置信度”），
            // 此处不断言不含子串，而断言不承诺数值化置信度。
            XCTAssertTrue(modality.contains("不伪造置信度"), "必须明确不伪造置信度")
        }
    }

    func testSpokenTextStripsLayoutSyntaxButKeepsMeaning() {
        let cases: [(String, String)] = [
            ("1. Sony WH-1000XM5", "Sony WH-1000XM5"),
            ("2) 第二点", "第二点"),
            ("1、第一点", "第一点"),
            ("12. 第十二条", "第十二条"),
            ("- 第一点", "第一点"),
            ("* 星号项", "星号项"),
            ("**好**的。", "好的。"),
            ("`code` 片段", "code 片段"),
            ("# 标题一下", "标题一下"),
            ("> 引用一句", "引用一句"),
            ("🎧 真好听", "真好听"),
            // 下面这些**不能**被当成标记切掉。
            ("1.5 毫米的线", "1.5 毫米的线"),
            ("3.5 与 3. 的差别", "3.5 与 3. 的差别"),
            ("增长 12.5% 。", "增长 12.5% 。"),
            ("请看（重点）这一条", "请看（重点）这一条")
        ]

        for (input, expected) in cases {
            XCTAssertEqual(VoicePrompt.spokenText(from: input), expected, "输入：\(input)")
        }
    }

    func testSpokenTextCollapsesCodeFenceAndBlankLines() {
        let marked = "```\n第一行\n\n第二行\n```"
        XCTAssertEqual(VoicePrompt.spokenText(from: marked), "第一行 第二行")
    }
}
