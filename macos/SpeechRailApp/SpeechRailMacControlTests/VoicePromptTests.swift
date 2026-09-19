import Foundation
import XCTest

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
        XCTAssertTrue(contract.contains("普通话"))
    }

    func testStyleBlockDefersToContractAndKeepsPersona() {
        let block = VoicePrompt.styleBlock("  你是一位耐心的讲解者。  ")

        XCTAssertTrue(block.hasPrefix("# 角色风格（人设）"))
        XCTAssertTrue(block.contains("以语音对话契约和朗读要求为准"))
        XCTAssertTrue(block.hasSuffix("你是一位耐心的讲解者。"))
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
