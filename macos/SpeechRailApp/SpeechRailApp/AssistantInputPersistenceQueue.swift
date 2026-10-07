import Foundation
import Observation

/// 串行保存已接纳的转录输入，把 Store IO 从事件 receiver 中移出。
///
/// 队列由 MainActor 持有，因为唯一消费者要把保存结果投影回对应功能状态；
/// 实际 IO 仍通过注入的异步闭包进入 Store actor。
@MainActor
@Observable
public final class TranscriptPersistenceQueue {
    public struct Configuration: Equatable, Sendable {
        public let maximumPendingCommands: Int
        public let maximumPendingTextScalars: Int
        public let maximumRememberedItems: Int
        public let maximumPendingProjections: Int
        public let maximumProjectionUnits: Int

        public init(
            maximumPendingCommands: Int = 32,
            maximumPendingTextScalars: Int = 64_000,
            maximumRememberedItems: Int = 512,
            maximumPendingProjections: Int = 128,
            maximumProjectionUnits: Int = 1_024
        ) {
            precondition(maximumPendingCommands >= 0)
            precondition(maximumPendingTextScalars >= 0)
            precondition(maximumRememberedItems >= 0)
            precondition(maximumPendingProjections >= 0 && maximumProjectionUnits >= 0)
            self.maximumPendingCommands = maximumPendingCommands
            self.maximumPendingTextScalars = maximumPendingTextScalars
            self.maximumRememberedItems = maximumRememberedItems
            self.maximumPendingProjections = maximumPendingProjections
            self.maximumProjectionUnits = maximumProjectionUnits
        }
    }

    /// 接纳输入时固定的身份与正文。
    public struct Command: Hashable, Identifiable, Sendable {
        public let sessionID: String
        public let connection: Int
        public let itemID: String
        public let generation: Int
        /// provider 未提供 `itemID` 时使用的本地唯一身份。
        public let acceptanceID: String
        public let lineID: String
        public let text: String
        public let source: SessionLineSource
        public let role: SessionLineRole
        public let speakerLabel: String?
        public let tStart: TimeInterval?
        public let tEnd: TimeInterval?
        public let formal: Bool
        public let isInterrupted: Bool
        public let isDeviceSwitch: Bool
        public let timingQuality: SessionTimingQuality?
        public let observedAt: Date

        public var id: String { acceptanceID }

        public init(
            sessionID: String,
            connection: Int,
            itemID: String,
            generation: Int = 0,
            acceptanceID: String = UUID().uuidString,
            lineID: String = UUID().uuidString,
            text: String,
            source: SessionLineSource = .microphone,
            role: SessionLineRole = .user,
            speakerLabel: String? = nil,
            tStart: TimeInterval? = nil,
            tEnd: TimeInterval? = nil,
            formal: Bool,
            isInterrupted: Bool? = nil,
            isDeviceSwitch: Bool = false,
            timingQuality: SessionTimingQuality? = .unavailable,
            observedAt: Date
        ) {
            self.sessionID = sessionID
            self.connection = connection
            self.itemID = itemID
            self.generation = generation
            self.acceptanceID = acceptanceID
            self.lineID = lineID
            self.text = text
            self.source = source
            self.role = role
            self.speakerLabel = speakerLabel
            self.tStart = tStart
            self.tEnd = tEnd
            self.formal = formal
            self.isInterrupted = isInterrupted ?? !formal
            self.isDeviceSwitch = isDeviceSwitch
            self.timingQuality = timingQuality
            self.observedAt = observedAt
        }

        public var textScalarCount: Int {
            text.unicodeScalars.count
        }

        public var lineDraft: LineDraft {
            LineDraft(
                sessionID: sessionID, role: role, text: text, source: source,
                speakerLabel: speakerLabel, tStart: tStart, tEnd: tEnd,
                status: formal ? .final : .partial, isInterrupted: isInterrupted,
                isDeviceSwitch: isDeviceSwitch, timingQuality: timingQuality, createdAt: observedAt
            )
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
        public let admissionRejections: Int

        public var isComplete: Bool {
            pendingCommands.isEmpty && failures.isEmpty && admissionRejections == 0
        }

        public init(pendingCommands: [Command], failures: [Failure], admissionRejections: Int = 0) {
            self.pendingCommands = pendingCommands
            self.failures = failures
            self.admissionRejections = admissionRejections
        }
    }

    public typealias Save = @MainActor (Command) async throws -> Int
    public typealias DidSave = @MainActor (Command, Int) async -> Void
    typealias ProjectionOperation = @MainActor () async -> Void

    private enum State: Equatable {
        case pending
        case saving
        case failed(String)
    }

    private struct Entry {
        let command: Command
        var state: State
    }

    private struct ProjectionKey: Hashable {
        let recordID: String
        let lineID: String
    }

    private struct ProjectionWork {
        let key: ProjectionKey
        let unitCount: Int
        let operation: ProjectionOperation
    }

    private struct ItemKey: Hashable {
        let sessionID: String
        let connection: Int
        let itemID: String
        let generation: Int
        let source: SessionLineSource
    }

    private let configuration: Configuration
    private let save: Save
    private let didSave: DidSave
    private var entries: [Entry] = []
    private var acceptedItems: [ItemKey: String] = [:]
    private var completedItemOrder: [ItemKey] = []
    private var projections: [ProjectionWork] = []
    private var activeProjection: ProjectionWork?
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

    public var outstandingRecordIDs: [String] {
        var seen: Set<String> = []
        let recordIDs = entries.map(\.command.sessionID)
            + projections.map(\.key.recordID)
            + (activeProjection.map { [$0.key.recordID] } ?? [])
        return recordIDs.filter { seen.insert($0).inserted }
    }

    var outstandingProjectionCount: Int { projections.count + (activeProjection == nil ? 0 : 1) }
    var outstandingProjectionUnits: Int {
        projections.reduce(activeProjection?.unitCount ?? 0) { $0 + $1.unitCount }
    }

    /// 辅助写入复用正文保存 owner；只有尚未执行的同一目标可合并。
    @discardableResult
    func enqueueProjection(
        recordID: String, lineID: String, unitCount: Int,
        coalescing: Bool = true,
        operation: @escaping ProjectionOperation
    ) -> Bool {
        guard !recordID.isEmpty, !lineID.isEmpty, unitCount >= 0 else { return false }
        let key = ProjectionKey(recordID: recordID, lineID: lineID)
        let existing = coalescing ? projections.firstIndex { $0.key == key } : nil
        let previousUnits = existing.map { projections[$0].unitCount } ?? 0
        guard existing != nil || outstandingProjectionCount < configuration.maximumPendingProjections,
              unitCount <= configuration.maximumProjectionUnits - outstandingProjectionUnits + previousUnits
        else { return false }
        let work = ProjectionWork(key: key, unitCount: unitCount, operation: operation)
        if let existing {
            projections[existing] = work
        } else {
            projections.append(work)
        }
        startWorkerIfNeeded()
        return true
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
        guard command.source != .keyboard, !command.itemID.isEmpty else { return nil }
        return ItemKey(
            sessionID: command.sessionID,
            connection: command.connection,
            itemID: command.itemID,
            generation: command.generation,
            source: command.source
        )
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, nextReadyPendingIndex() != nil || !projections.isEmpty else { return }
        worker = Task { @MainActor [weak self] in
            await self?.consume()
        }
    }

    private func consume() async {
        var lastWasProjection = false
        while true {
            let nextLine = nextReadyPendingIndex()
            if !projections.isEmpty, nextLine == nil || !lastWasProjection {
                let work = projections.removeFirst()
                activeProjection = work
                await work.operation()
                activeProjection = nil
                lastWasProjection = true
                resumeSettledWaiters()
                continue
            }
            guard let index = nextLine else { break }
            lastWasProjection = false
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
                rememberCompletedItem(command)
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

    private func rememberCompletedItem(_ command: Command) {
        guard let key = itemKey(for: command) else { return }
        completedItemOrder.append(key)
        while completedItemOrder.count > configuration.maximumRememberedItems {
            acceptedItems.removeValue(forKey: completedItemOrder.removeFirst())
        }
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
        guard activeProjection?.key.recordID != sessionID,
              !projections.contains(where: { $0.key.recordID == sessionID })
        else { return nil }
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

/// 用户确认结束不完整记录时使用的固定恢复快照；更新拒绝会产生新的身份。
public struct TranscriptAdmissionRecovery: Identifiable, Equatable, Sendable {
    public let id: String
    public let recordID: String
    public let text: String
    public let rejectionCount: Int
    public let observedAt: Date

    @MainActor
    var command: TranscriptPersistenceQueue.Command {
        .init(
            sessionID: recordID, connection: 0, itemID: "", lineID: id,
            text: text, source: .keyboard, role: .speaker, formal: false,
            isInterrupted: true, timingQuality: .unavailable, observedAt: observedAt
        )
    }
}

public struct TranscriptSaveRecoveryRecord: Identifiable, Sendable {
    public let id: String
    public let observedAt: Date
    public let failedCount: Int
    public let admission: TranscriptAdmissionRecovery?
}

/// 拒绝接纳也是收尾证明的一部分，不能在保存队列排空后被抹掉。
/// 只保存每场最近一次拒绝的可复制预览；不把它冒充已接纳的命令。
struct TranscriptAdmissionLedger {
    private struct Entry {
        var count: Int
        var copyText: String
        var recoveryID: String
        var observedAt: Date
    }
    private let maximumRecords: Int
    private let maximumPreviewScalars: Int
    private var entries: [String: Entry] = [:]
    private(set) var recordIDs: [String] = []
    private var hasUntrackedRejection = false

    init(maximumRecords: Int = 32, maximumPreviewScalars: Int = 64_000) {
        precondition(maximumRecords > 0 && maximumPreviewScalars >= 0)
        self.maximumRecords = maximumRecords
        self.maximumPreviewScalars = maximumPreviewScalars
    }

    var canStartNewRecord: Bool { entries.count < maximumRecords && !hasUntrackedRejection }

    mutating func reject(recordID: String, text: String) {
        guard entries[recordID] != nil || entries.count < maximumRecords else {
            hasUntrackedRejection = true
            return
        }
        if entries[recordID] == nil { recordIDs.append(recordID) }
        let previousCount = entries[recordID]?.count ?? 0
        let count = previousCount == Int.max ? Int.max : previousCount + 1
        var copyText = String(text.unicodeScalars.prefix(maximumPreviewScalars))
        if text.unicodeScalars.count > maximumPreviewScalars {
            copyText += "\n[这句内容过长，恢复预览只保留了开头。]"
        }
        entries[recordID] = Entry(
            count: count, copyText: copyText, recoveryID: UUID().uuidString, observedAt: Date()
        )
    }

    func report(
        recordID: String, saved: TranscriptPersistenceQueue.DrainReport
    ) -> TranscriptPersistenceQueue.DrainReport {
        TranscriptPersistenceQueue.DrainReport(
            pendingCommands: saved.pendingCommands, failures: saved.failures,
            admissionRejections: entries[recordID]?.count ?? (hasUntrackedRejection ? 1 : 0)
        )
    }

    func copyText(recordID: String) -> String? {
        guard let entry = entries[recordID] else { return nil }
        if entry.count > 1 {
            return "[有 \(entry.count) 句未接纳，以下只保留了最近一句。]\n" + entry.copyText
        }
        return entry.copyText
    }

    func recovery(recordID: String) -> TranscriptAdmissionRecovery? {
        guard let entry = entries[recordID], let preview = copyText(recordID: recordID) else { return nil }
        return TranscriptAdmissionRecovery(
            id: entry.recoveryID, recordID: recordID,
            text: "本记录未完整保存。以下是仍可恢复的未接纳预览，不属于正式文字记录。\n" + preview,
            rejectionCount: entry.count, observedAt: entry.observedAt
        )
    }

    /// 只能在冻结预览已落 partial、记录按中断结束之后调用。
    mutating func confirmResolution(_ snapshot: TranscriptAdmissionRecovery) -> Bool {
        guard recovery(recordID: snapshot.recordID) == snapshot else { return false }
        entries.removeValue(forKey: snapshot.recordID)
        recordIDs.removeAll { $0 == snapshot.recordID }
        return true
    }
}

/// 保存确认前到达的辅助归属，按记录及 ASR 代次关联；不改权威正文。
struct TranscriptAttributionBuffer {
    struct Payload {
        let units: [RealtimeASRClient.AttributionUnit]
        let labelsEnabled: Bool
    }
    private struct Key: Hashable {
        let recordID: String
        let identity: TranscriptPreviewLedger.ItemIdentity
    }
    private let maximumItems: Int
    private let maximumUnits: Int
    private var entries: [Key: Payload] = [:]

    init(maximumItems: Int = 128, maximumUnits: Int = 1_024) {
        precondition(maximumItems >= 0 && maximumUnits >= 0)
        self.maximumItems = maximumItems
        self.maximumUnits = maximumUnits
    }

    mutating func store(
        _ units: [RealtimeASRClient.AttributionUnit], recordID: String,
        identity: TranscriptPreviewLedger.ItemIdentity, labelsEnabled: Bool
    ) -> Bool {
        let key = Key(recordID: recordID, identity: identity)
        let previousCount = entries[key]?.units.count ?? 0
        let used = entries.values.reduce(0) { $0 + $1.units.count }
        guard entries[key] != nil || entries.count < maximumItems,
              units.count <= maximumUnits - used + previousCount else { return false }
        entries[key] = Payload(units: units, labelsEnabled: labelsEnabled)
        return true
    }

    mutating func take(
        recordID: String, identity: TranscriptPreviewLedger.ItemIdentity
    ) -> Payload? {
        entries.removeValue(forKey: Key(recordID: recordID, identity: identity))
    }
}
