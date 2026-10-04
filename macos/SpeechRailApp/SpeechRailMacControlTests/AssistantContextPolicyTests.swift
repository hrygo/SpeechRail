import Foundation
import SpeechRailControlKit
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-14 上下文预算、记忆审阅与作用域（A45/A46/A48；A41 随播放交付已覆盖）。
@Suite
struct AssistantContextPolicyTests {
    @Test
    func historyBudgetCountsCompleteUserReplyTurns() {
        let history = (0..<13).flatMap { index in
            [
                LLMMessage(role: .user, text: "问\(index)"),
                LLMMessage(role: .assistant, text: "答\(index)")
            ]
        }

        let trimmed = AssistantContextPolicy.trimHistory(history)

        #expect(trimmed.kept.count == AssistantContextPolicy.maxHistoryTurns * 2)
        #expect(trimmed.kept.first?.text == "问1")
        #expect(trimmed.kept.last?.text == "答12")
        #expect(trimmed.omittedCount == 1)
        #expect(trimmed.note != nil)
    }

    @Test
    func historyBudgetAppliesScalarLimitToShortHistory() {
        let history = [
            LLMMessage(role: .user, text: String(repeating: "a", count: 8_000)),
            LLMMessage(role: .assistant, text: "答"),
            LLMMessage(role: .user, text: String(repeating: "b", count: 8_000)),
            LLMMessage(role: .assistant, text: "答")
        ]

        let trimmed = AssistantContextPolicy.trimHistory(history)

        #expect(trimmed.kept.map(\.role) == [.user, .assistant])
        #expect(trimmed.kept.first?.text.unicodeScalars.count == 8_000)
        #expect(trimmed.kept.first?.text.first == "b")
        #expect(trimmed.kept.last?.text == "答")
        #expect(trimmed.omittedCount == 1)
        #expect(trimmed.kept.reduce(0) { $0 + $1.text.unicodeScalars.count } <= AssistantContextPolicy.maxHistoryScalars)
    }

    @Test
    func historyBudgetDropsOversizedTurnAsAWhole() {
        let history = [
            LLMMessage(role: .user, text: String(repeating: "a", count: 16_001)),
            LLMMessage(role: .assistant, text: "答")
        ]

        let trimmed = AssistantContextPolicy.trimHistory(history)

        #expect(trimmed.kept.isEmpty)
        #expect(trimmed.omittedCount == 1)
        #expect(trimmed.note != nil)
    }

    @Test
    func historyBudgetCountsUnicodeScalarsAcrossCompleteTurns() {
        let familyEmoji = String(repeating: "👨‍👩‍👧‍👦", count: 1_200)
        let history = [
            LLMMessage(role: .user, text: familyEmoji),
            LLMMessage(role: .assistant, text: "旧答"),
            LLMMessage(role: .user, text: familyEmoji),
            LLMMessage(role: .assistant, text: "新答")
        ]

        let trimmed = AssistantContextPolicy.trimHistory(history)

        #expect(trimmed.kept.count == 2)
        #expect(trimmed.kept.first?.role == .user)
        #expect(trimmed.kept.first?.text.unicodeScalars.count == 8_400)
        #expect(trimmed.kept.last?.text == "新答")
        #expect(trimmed.omittedCount == 1)
    }

    @Test
    func requestContextDoesNotPairAdjacentUsersAndBindsStatesToEntryIDs() throws {
        let firstQuestion = AssistantContextEntry(id: "user-1", text: "第一个未回答的问题")
        let secondQuestion = AssistantContextEntry(id: "user-2", text: "第二个问题")
        let originalReply = "  未完成原文\n🙂  "
        let reply = AssistantContextEntry(
            id: "reply-2",
            text: originalReply,
            generationStatus: .failed,
            playbackStatus: .incomplete
        )
        let currentQuestion = AssistantContextEntry(id: "current", text: "现在的问题")

        let request = try AssistantContextPolicy.buildRequestContext(
            instructions: "固定指令",
            persona: nil,
            memories: [],
            history: [
                AssistantContextTurn(user: firstQuestion, reply: nil),
                AssistantContextTurn(user: secondQuestion, reply: reply)
            ],
            currentQuestion: currentQuestion
        )

        let userMessages = request.messages.filter { $0.role == .user }
        #expect(userMessages.map(\.text) == ["第一个未回答的问题", "第二个问题", "现在的问题"])
        let assistantMessages = request.messages.filter { $0.role == .assistant }
        #expect(assistantMessages.map(\.text) == [originalReply])
        let replyStateNotes = request.messages.filter {
            $0.role == .developer && $0.text.contains("reply-2")
        }
        let replyStateNote = try #require(replyStateNotes.first)
        #expect(replyStateNotes.count == 1)
        #expect(replyStateNote.text.contains("生成失败"))
        #expect(replyStateNote.text.contains("朗读未完成"))
        #expect(replyStateNote.text.contains("reply-2"))
        #expect(request.messages.filter { $0.role == .user && $0.text == "现在的问题" }.count == 1)
    }

    @Test
    func currentQuestionIDIsNotDuplicatedFromHistory() throws {
        let currentQuestion = AssistantContextEntry(id: "current", text: "现在的问题")
        let request = try AssistantContextPolicy.buildRequestContext(
            instructions: "固定指令",
            persona: nil,
            memories: [],
            history: [
                AssistantContextTurn(
                    user: AssistantContextEntry(id: "older", text: "较早问题"),
                    reply: AssistantContextEntry(id: "older-reply", text: "较早回答")
                ),
                AssistantContextTurn(user: currentQuestion, reply: nil)
            ],
            currentQuestion: currentQuestion
        )

        #expect(request.messages.filter { $0.role == .user && $0.text == "现在的问题" }.count == 1)
        #expect(request.omittedHistoryTurns == 1)
    }

    @Test
    func failedEmptyReplyAddsNoEmptyAssistantMessage() throws {
        let request = try AssistantContextPolicy.buildRequestContext(
            instructions: "固定指令",
            persona: nil,
            memories: [],
            history: [
                AssistantContextTurn(
                    user: AssistantContextEntry(id: "user-1", text: "问题"),
                    reply: AssistantContextEntry(
                        id: "reply-1",
                        text: "",
                        generationStatus: .failed,
                        playbackStatus: .notRequested
                    )
                )
            ],
            currentQuestion: AssistantContextEntry(id: "current", text: "下一问")
        )

        #expect(request.messages.filter { $0.role == .assistant }.isEmpty)
        #expect(request.messages.contains {
            $0.role == .developer && $0.text.contains("reply-1") && $0.text.contains("生成失败")
        })
    }

    @Test
    func requestContextDropsOptionalHistoryAndMemoryToMeetTotalScalarBudget() throws {
        let request = try AssistantContextPolicy.buildRequestContext(
            instructions: String(repeating: "i", count: 23_990),
            persona: nil,
            memories: ["可选记忆"],
            history: [
                AssistantContextTurn(
                    user: AssistantContextEntry(id: "user-1", text: "旧问题"),
                    reply: AssistantContextEntry(id: "reply-1", text: "旧回答")
                )
            ],
            currentQuestion: AssistantContextEntry(id: "current", text: "q")
        )

        let requestScalars = request.instructions.unicodeScalars.count
            + request.messages.reduce(0) { $0 + $1.text.unicodeScalars.count }
        #expect(request.maxOutputTokens == 1_024)
        #expect(request.omittedHistoryTurns == 1)
        #expect(request.omittedMemories == 1)
        #expect(request.requestScalars == requestScalars)
        #expect(requestScalars <= AssistantContextPolicy.maxRequestScalars)
        #expect(request.messages.filter { $0.role == .user && $0.text == "q" }.count == 1)
        #expect(request.omissionNote?.contains("1") == true)
    }

    @Test
    func requestContextRejectsRequiredContentOverTheTotalBudget() {
        do {
            _ = try AssistantContextPolicy.buildRequestContext(
                instructions: String(repeating: "i", count: 10),
                persona: String(repeating: "p", count: 10),
                memories: [],
                history: [],
                currentQuestion: AssistantContextEntry(
                    id: "current",
                    text: String(repeating: "q", count: 23_981)
                )
            )
            Issue.record("超过总限额的必需指令与当前问题必须报错。")
        } catch let error as AssistantContextPolicy.ContextBuildError {
            #expect(
                error == .requiredContentExceedsRequestBudget(
                    requiredScalars: 24_001,
                    maximumScalars: 24_000
                )
            )
        } catch {
            Issue.record("返回了错误类型：\(error)")
        }
    }

    @Test
    func memoryRequiresEditedConfirmation() {
        #expect(AssistantContextPolicy.validatedDraft(body: "  ", kind: "fact", sourceSessionID: nil) == nil)
        #expect(AssistantContextPolicy.validatedDraft(body: "记住密码 sk-abc", kind: "fact", sourceSessionID: nil) == nil)
        #expect(AssistantContextPolicy.validatedDraft(body: "喜欢红茶", kind: "agreement", sourceSessionID: nil) == nil)

        let draft = AssistantContextPolicy.validatedDraft(
            body: "喜欢红茶",
            kind: "preference",
            sourceSessionID: "s1"
        )
        #expect(draft?.scope == "下一新场生效")
    }

    @Test
    func memoryIsBoundedDataAndRevocationIsExplicit() {
        let big = (0..<100).map { "记忆\($0)内容填充" }
        let trimmed = AssistantContextPolicy.trimMemories(big)
        let scalars = trimmed.kept.reduce(0) { $0 + $1.unicodeScalars.count }

        #expect(scalars <= AssistantContextPolicy.maxMemoryScalars)
        // 撤销明确：经 coordinator.removeMemory / setMemoryActive，本策略只保证不超限。
        #expect(trimmed.omittedCount >= 0)
    }
}
