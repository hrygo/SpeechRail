import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

private actor SelectionReadGate {
    private var continuation: CheckedContinuation<String, Never>?
    private var waiting = false

    func read() async -> String {
        await withCheckedContinuation {
            continuation = $0
            waiting = true
        }
    }

    func waitForRead() async {
        while !waiting { await Task.yield() }
    }

    func finish(_ value: String) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
struct SelectionLoadTests {
    @Test func latestSelectionWinsWhenOlderReadFinishesLast() async throws {
        let loader = SpeechRailSelectionLoad<String>()
        let gate = SelectionReadGate()
        let older = Task { try await loader.load(id: "A") { await gate.read() } }
        await gate.waitForRead()
        #expect(loader.requestedID == "A")
        #expect(loader.isLoading)

        let newest = try await loader.load(id: "B") { "正文B" }
        #expect(newest == "正文B")
        await gate.finish("正文A")
        #expect(try await older.value == nil)
        #expect(loader.requestedID == "B")
        #expect(!loader.isLoading)
    }

    @Test func leavingTheListRetiresPendingContent() async throws {
        let loader = SpeechRailSelectionLoad<String>()
        let gate = SelectionReadGate()
        let pending = Task { try await loader.load(id: "A") { await gate.read() } }
        await gate.waitForRead()
        loader.reset()
        await gate.finish("旧正文")
        #expect(try await pending.value == nil)
        #expect(loader.requestedID == nil)
        #expect(!loader.isLoading)
    }

    @Test func olderReadFailureCannotReplaceNewerSuccess() async throws {
        let loader = SpeechRailSelectionLoad<String>()
        let gate = SelectionReadGate()
        let older = Task {
            try await loader.load(id: "A") {
                _ = await gate.read()
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        await gate.waitForRead()
        #expect(try await loader.load(id: "B") { "正文B" } == "正文B")
        await gate.finish("结束旧读取")
        #expect(try await older.value == nil)
        #expect(loader.failure == nil)
        #expect(loader.requestedID == "B")
    }

    @Test func cancelledReadCannotPublishContent() async throws {
        let loader = SpeechRailSelectionLoad<String>()
        let gate = SelectionReadGate()
        let pending = Task { try await loader.load(id: "A") { await gate.read() } }
        await gate.waitForRead()
        pending.cancel()
        await gate.finish("旧正文")
        #expect(try await pending.value == nil)
        #expect(!loader.isLoading)
        #expect(loader.failure == nil)
    }
}
