import Foundation
import Observation

/// 串行保存已接纳的助手输入，把 Store IO 从事件 receiver 中移出。
///
/// 队列由 MainActor 持有，因为唯一消费者要把保存结果投影回助手状态；
/// 实际 IO 仍通过注入的异步闭包进入 Store actor。
@MainActor
@Observable
public final class AssistantInputPersistenceQueue {
    public struct Configuration: Equatable, Sendable {
        public let maximumPendingCommands: Int
        public let maximumPendingTextScalars: Int

        public init(
            maximumPendingCommands: Int = 32,
            maximumPendingTextScalars: Int = 64_000
        ) {
            precondition(maximumPendingCommands >= 0)
            precondition(maximumPendingTextScalars >= 0)
            self.maximumPendingCommands = maximumPendingCommands
            self.maximumPendingTextScalars = maximumPendingTextScalars
        }
    }

    /// 接纳输入时固定的身份与正文。
    public struct Command: Hashable, Identifiable, Sendable {
        public let sessionID: String
        public let connection: Int
        public let itemID: String
        /// provider 未提供 `itemID` 时使用的本地唯一身份。
        public let acceptanceID: String
        public let lineID: String
        public let text: String
        public let source: SessionLineSource
        public let tStart: TimeInterval?
        public let formal: Bool
        public let observedAt: Date

        public var id: String { acceptanceID }

        public init(
            sessionID: String,
            connection: Int,
            itemID: String,
            acceptanceID: String = UUID().uuidString,
            lineID: String = UUID().uuidString,
            text: String,
            source: SessionLineSource = .microphone,
            tStart: TimeInterval? = nil,
            formal: Bool,
            observedAt: Date
        ) {
            self.sessionID = sessionID
            self.connection = connection
            self.itemID = itemID
            self.acceptanceID = acceptanceID
            self.lineID = lineID
            self.text = text
            self.source = source
            self.tStart = tStart
            self.formal = formal
            self.observedAt = observedAt
        }

        public var textScalarCount: Int {
            text.unicodeScalars.count
        }
    }

    public enum Admission: Equatable, Sendable {
        case accepted
        case duplicate(existingLineID: String)
        case capacityExceeded
        case invalidIdentity
    }

    public enum SaveResult: Equatable, Sendable {
        case saved(ordinal: Int)
        case failed(message: String)
        case blocked(byLineID: String)
    }

    public struct Failure: Equatable, Sendable {
        public let command: Command
        public let message: String

        public init(command: Command, message: String) {
            self.command = command
            self.message = message
        }
    }

    /// A record is settled when it has no active save and is either drained or blocked
    /// by a failed command that needs an explicit retry.
    public struct DrainReport: Equatable, Sendable {
        public let pendingCommands: [Command]
        public let failures: [Failure]

        public var isComplete: Bool {
            pendingCommands.isEmpty && failures.isEmpty
        }

        public init(pendingCommands: [Command], failures: [Failure]) {
            self.pendingCommands = pendingCommands
            self.failures = failures
        }
    }

    public typealias Save = @MainActor (Command) async throws -> Int
    public typealias DidSave = @MainActor (Command, Int) async -> Void

    private enum State: Equatable {
        case pending
        case saving
        case failed(String)
    }

    private struct Entry {
        let command: Command
        var state: State
    }

    private struct ItemKey: Hashable {
        let sessionID: String
        let connection: Int
        let itemID: String
    }

    private let configuration: Configuration
    private let save: Save
    private let didSave: DidSave
    private var entries: [Entry] = []
    private var acceptedItems: [ItemKey: String] = [:]
    private var worker: Task<Void, Never>?
    private var drainWaiters: [String: [CheckedContinuation<DrainReport, Never>]] = [:]
    private var resultWaiters: [String: [UUID: CheckedContinuation<SaveResult, Never>]] = [:]
    private var resultInterests: Set<String> = []
    private var retainedResults: [String: SaveResult] = [:]

    private static let missingResultMessage = "没有可等待的输入保存命令"
    private static let cancelledWaitMessage = "等待输入保存已取消"

    public init(
        configuration: Configuration = Configuration(),
        save: @escaping Save,
        didSave: @escaping DidSave
    ) {
        self.configuration = configuration
        self.save = save
        self.didSave = didSave
    }

    /// 尚未完全完成的已接纳命令数，包含失败项。
    public var outstandingCommandCount: Int {
        entries.count
    }

    /// 已接纳命令占用的 Unicode scalar 数，包含失败项。
    public var outstandingTextScalarCount: Int {
        entries.reduce(into: 0) { total, entry in
            total += entry.command.textScalarCount
        }
    }

    public func pendingCommands(sessionID: String) -> [Command] {
        entries.compactMap { entry in
            guard entry.command.sessionID == sessionID else { return nil }
            guard entry.state == .pending || entry.state == .saving else { return nil }
            return entry.command
        }
    }

    public func failures(sessionID: String) -> [Failure] {
        entries.compactMap { entry in
            guard entry.command.sessionID == sessionID,
                  case .failed(let message) = entry.state
            else {
                return nil
            }
            return Failure(command: entry.command, message: message)
        }
    }

    /// 展示保留接纳顺序与失败正文；不把尚未保存的行混进存储镜像。
    func unsettledInputs(sessionID: String) -> [(command: Command, failure: String?)] {
        entries.compactMap { entry in
            guard entry.command.sessionID == sessionID else { return nil }
            if case .failed(let message) = entry.state {
                return (entry.command, message)
            }
            return (entry.command, nil)
        }
    }

    /// 同步接纳命令；拒绝时不改变现有队列。
    @discardableResult
    public func enqueue(_ command: Command) -> Admission {
        guard !command.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.acceptanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.lineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .invalidIdentity
        }

        let key = itemKey(for: command)
        if let key, let existingLineID = acceptedItems[key] {
            return .duplicate(existingLineID: existingLineID)
        }
        guard !entries.contains(where: { $0.command.lineID == command.lineID }),
              retainedResults[command.lineID] == nil,
              resultWaiters[command.lineID] == nil
        else {
            return .invalidIdentity
        }

        let scalarCount = command.textScalarCount
        guard entries.count < configuration.maximumPendingCommands,
              scalarCount <= configuration.maximumPendingTextScalars - outstandingTextScalarCount
        else {
            return .capacityExceeded
        }

        entries.append(Entry(command: command, state: .pending))
        if let key {
            acceptedItems[key] = command.lineID
        }
        if command.source == .keyboard {
            resultInterests.insert(command.lineID)
        }
        startWorkerIfNeeded()
        return .accepted
    }

    /// 使用原命令正文与行 ID 重试一个失败项。
    @discardableResult
    public func retry(sessionID: String, lineID: String) -> Bool {
        guard let index = entries.firstIndex(where: {
            $0.command.sessionID == sessionID
                && $0.command.lineID == lineID
                && isFailed($0.state)
        }) else {
            return false
        }
        retainedResults.removeValue(forKey: lineID)
        entries[index].state = .pending
        startWorkerIfNeeded()
        return true
    }

    /// 等待一条已接纳命令的结果。keyboard 命令可在消费者启动前完成；
    /// 这类结果只保留到第一次读取，普通 ASR 保存不会累积结果。
    public func waitForResult(lineID: String) async -> SaveResult {
        if let result = retainedResults.removeValue(forKey: lineID) {
            resultInterests.remove(lineID)
            return result
        }
        guard let index = entries.firstIndex(where: { $0.command.lineID == lineID }) else {
            return .failed(message: Self.missingResultMessage)
        }
        if case .failed(let message) = entries[index].state {
            resultInterests.remove(lineID)
            return .failed(message: message)
        }
        if let failedPredecessorLineID = failedPredecessorLineID(before: index) {
            resultInterests.remove(lineID)
            return .blocked(byLineID: failedPredecessorLineID)
        }
        if Task.isCancelled {
            resultInterests.remove(lineID)
            return .failed(message: Self.cancelledWaitMessage)
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resultWaiters[lineID, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelResultWaiter(lineID: lineID, waiterID: waiterID)
            }
        }
    }

    /// 等待该记录的当前保存结束。若有失败项，会返回失败及其后尚未处理的同记录命令。
    public func waitUntilSettled(sessionID: String) async -> DrainReport {
        if let report = settledReport(sessionID: sessionID) {
            return report
        }
        return await withCheckedContinuation { continuation in
            drainWaiters[sessionID, default: []].append(continuation)
        }
    }

    private func itemKey(for command: Command) -> ItemKey? {
        guard command.source == .microphone, !command.itemID.isEmpty else { return nil }
        return ItemKey(
            sessionID: command.sessionID,
            connection: command.connection,
            itemID: command.itemID
        )
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, nextReadyPendingIndex() != nil else { return }
        worker = Task { @MainActor [weak self] in
            await self?.consume()
        }
    }

    private func consume() async {
        while let index = nextReadyPendingIndex() {
            let command = entries[index].command
            entries[index].state = .saving
            do {
                let ordinal = try await save(command)
                await didSave(command, ordinal)
                if let savedIndex = entries.firstIndex(where: {
                    $0.command.acceptanceID == command.acceptanceID
                }) {
                    entries.remove(at: savedIndex)
                }
                completeResult(.saved(ordinal: ordinal), lineID: command.lineID)
            } catch {
                if let failedIndex = entries.firstIndex(where: {
                    $0.command.acceptanceID == command.acceptanceID
                }) {
                    entries[failedIndex].state = .failed(error.localizedDescription)
                    completeBlockedResults(after: failedIndex)
                }
                completeResult(.failed(message: error.localizedDescription), lineID: command.lineID)
            }
            resumeSettledWaiters()
        }

        worker = nil
        resumeSettledWaiters()
        startWorkerIfNeeded()
    }

    private func completeResult(_ result: SaveResult, lineID: String) {
        if let waiters = resultWaiters.removeValue(forKey: lineID), !waiters.isEmpty {
            resultInterests.remove(lineID)
            for waiter in waiters.values {
                waiter.resume(returning: result)
            }
        } else if resultInterests.contains(lineID), retainedResults[lineID] == nil {
            retainedResults[lineID] = result
        }
    }

    private func completeBlockedResults(after failedIndex: Int) {
        guard entries.indices.contains(failedIndex) else { return }
        let failedCommand = entries[failedIndex].command

        for index in entries.indices where index > failedIndex {
            let entry = entries[index]
            guard entry.command.sessionID == failedCommand.sessionID,
                  entry.state == .pending
            else {
                continue
            }
            completeResult(
                .blocked(byLineID: failedCommand.lineID),
                lineID: entry.command.lineID
            )
        }
    }

    private func cancelResultWaiter(lineID: String, waiterID: UUID) {
        guard var waiters = resultWaiters[lineID],
              let waiter = waiters.removeValue(forKey: waiterID)
        else {
            return
        }
        if waiters.isEmpty {
            resultWaiters.removeValue(forKey: lineID)
            resultInterests.remove(lineID)
        } else {
            resultWaiters[lineID] = waiters
        }
        waiter.resume(returning: .failed(message: Self.cancelledWaitMessage))
    }

    /// 保持每条记录内的接纳顺序。某记录失败只阻塞该记录后续命令，
    /// 同一消费者仍可处理其他记录。
    private func nextReadyPendingIndex() -> Int? {
        for index in entries.indices {
            guard entries[index].state == .pending else { continue }
            let blockedByEarlierFailure = entries[..<index].contains { earlier in
                earlier.command.sessionID == entries[index].command.sessionID
                    && isFailed(earlier.state)
            }
            if !blockedByEarlierFailure {
                return index
            }
        }
        return nil
    }

    private func failedPredecessorLineID(before index: Int) -> String? {
        guard entries.indices.contains(index) else { return nil }
        let command = entries[index].command
        return entries[..<index].first(where: { earlier in
            earlier.command.sessionID == command.sessionID && isFailed(earlier.state)
        })?.command.lineID
    }

    private func settledReport(sessionID: String) -> DrainReport? {
        let recordEntries = entries.filter { $0.command.sessionID == sessionID }
        guard !recordEntries.contains(where: { $0.state == .saving }) else { return nil }

        let failures = recordEntries.compactMap { entry -> Failure? in
            guard case .failed(let message) = entry.state else { return nil }
            return Failure(command: entry.command, message: message)
        }
        let pending = recordEntries.compactMap { entry -> Command? in
            guard entry.state == .pending else { return nil }
            return entry.command
        }
        guard pending.isEmpty || !failures.isEmpty else { return nil }
        return DrainReport(pendingCommands: pending, failures: failures)
    }

    private func resumeSettledWaiters() {
        for sessionID in Array(drainWaiters.keys) {
            guard let report = settledReport(sessionID: sessionID),
                  let waiters = drainWaiters.removeValue(forKey: sessionID)
            else {
                continue
            }
            for waiter in waiters {
                waiter.resume(returning: report)
            }
        }
    }

    private func isFailed(_ state: State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
