import Foundation
import Observation
import SQLite3
import SpeechRailControlKit

public struct WindowCheckpointCommand: Hashable, Sendable {
    public let sessionID: String
    public let id: String
    public let expectedText: String?
    public let text: String
    public let observedAt: Date
    public let source: SessionLineSource
    public let role: SessionLineRole
    public init(sessionID: String, id: String, expectedText: String?, text: String,
                observedAt: Date, source: SessionLineSource = .microphone,
                role: SessionLineRole = .speaker) {
        self.sessionID = sessionID; self.id = id; self.expectedText = expectedText
        self.text = text; self.observedAt = observedAt; self.source = source; self.role = role
    }
    func coalescing(_ next: Self) -> Self {
        .init(sessionID: sessionID, id: id, expectedText: expectedText,
              text: next.text, observedAt: observedAt, source: source, role: role)
    }
}
public struct SealedWindowCommand: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        public let line: TranscriptPersistenceQueue.Command
        public let revisionID: String
        public init(line: TranscriptPersistenceQueue.Command, revisionID: String = UUID().uuidString) {
            self.line = line; self.revisionID = revisionID
        }
        var initialRevision: TranscriptRevision {
            .init(id: revisionID, lineID: line.lineID, sessionID: line.sessionID,
                  text: line.text, origin: "asr", editedAt: line.observedAt)
        }
    }
    public let transactionID: String
    public let sessionID: String
    public let rows: [Row]
    public let savedThrough: Int
    public let checkpoint: WindowCheckpointCommand?
    public init(transactionID: String, sessionID: String, rows: [Row], savedThrough: Int,
                checkpoint: WindowCheckpointCommand? = nil) {
        self.transactionID = transactionID; self.sessionID = sessionID; self.rows = rows
        self.savedThrough = savedThrough; self.checkpoint = checkpoint
    }
}
public struct WindowSaveAck: Equatable, Sendable {
    public let transactionID: String
    public let lineOrdinals: [String: Int]
    public let savedThrough: Int
}

extension SessionStore {
    public func appendSealedWindow(_ command: SealedWindowCommand) throws -> WindowSaveAck {
        guard !command.transactionID.isEmpty, command.rows.count <= 64,
              Set(command.rows.map { $0.line.lineID }).count == command.rows.count,
              command.rows.allSatisfy({ $0.line.sessionID == command.sessionID }),
              command.rows.reduce(0, { $0 + $1.line.textScalarCount }) <= 65536,
              command.checkpoint == nil || command.checkpoint?.sessionID == command.sessionID
        else { throw SessionStoreError.statementFailed("窗口保存命令身份或容量无效") }
        try execute("BEGIN IMMEDIATE;")
        do {
            var ordinals: [String: Int] = [:]
            let existing = try command.rows.map { try storedLine(id: $0.line.lineID) }
            if existing.contains(where: { $0 != nil }) {
                // Replay recognition precedes checkpoint CAS: the prior successful
                // transaction has already retired/changed that checkpoint.
                guard existing.allSatisfy({ $0 != nil }) else {
                    throw SessionStoreError.statementFailed("窗口批次只存在部分固定行")
                }
                for row in command.rows {
                    ordinals[row.line.lineID] = try appendLineInTransaction(row.line.lineDraft, id: row.line.lineID)
                    if row.line.formal {
                        let revisions = try transcriptRevisions(lineID: row.line.lineID)
                        guard revisions.contains(row.initialRevision) else {
                            throw SessionStoreError.statementFailed("窗口初始修订与已保存字段冲突")
                        }
                    }
                }
            } else {
                // A new transaction must have the exact checkpoint parent.
                if let checkpoint = command.checkpoint { try validateCheckpoint(checkpoint) }
                for row in command.rows {
                    ordinals[row.line.lineID] = try appendLineInTransaction(row.line.lineDraft, id: row.line.lineID)
                    if row.line.formal { _ = try recordTranscriptRevision(row.initialRevision) }
                }
                if let checkpoint = command.checkpoint { try applyCheckpoint(checkpoint) }
            }
            try execute("COMMIT;")
            return WindowSaveAck(transactionID: command.transactionID,
                                 lineOrdinals: ordinals, savedThrough: command.savedThrough)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
    public func saveWindowCheckpoint(_ command: WindowCheckpointCommand) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try validateCheckpoint(command)
            try applyCheckpoint(command)
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }
    private func validateCheckpoint(_ command: WindowCheckpointCommand) throws {
        guard !command.id.isEmpty, command.text.unicodeScalars.count <= 32768 else {
            throw SessionStoreError.statementFailed("检查点超出文字容量")
        }
        if let current = try storedLine(id: command.id) {
            guard current.sessionID == command.sessionID, current.status == .partial,
                  current.role == command.role, current.source == command.source,
                  current.text == command.expectedText || current.text == command.text else {
                throw SessionStoreError.statementFailed("检查点父版本不匹配，原始恢复文字已保留")
            }
        } else if command.expectedText != nil && !command.text.isEmpty {
            throw SessionStoreError.statementFailed("检查点父版本不存在")
        }
    }
    private func applyCheckpoint(_ command: WindowCheckpointCommand) throws {
        if command.text.isEmpty {
            try withStatement("DELETE FROM line WHERE id = ? AND session_id = ? AND status = 'partial';") {
                bind($0, 1, command.id); bind($0, 2, command.sessionID); try step($0)
            }
        } else if try storedLine(id: command.id) != nil {
            try withStatement("UPDATE line SET text = ? WHERE id = ? AND session_id = ? AND status = 'partial';") {
                bind($0, 1, command.text); bind($0, 2, command.id); bind($0, 3, command.sessionID); try step($0)
            }
        } else {
            _ = try appendLineInTransaction(LineDraft(sessionID: command.sessionID, role: command.role,
                text: command.text, source: command.source, status: .partial, isInterrupted: true,
                timingQuality: .unavailable, createdAt: command.observedAt), id: command.id)
        }
    }
}

/// Immutable commands survive failed writes. Only pending checkpoints coalesce;
/// sealed batches remain FIFO and are never silently discarded.
@MainActor @Observable
public final class TranscriptWindowPersistenceQueue {
    public enum Command: Hashable, Sendable {
        case sealed(SealedWindowCommand)
        case checkpoint(WindowCheckpointCommand)
        var id: String {
            switch self { case .sealed(let c): "seal:" + c.transactionID
            case .checkpoint(let c): "checkpoint:" + c.id }
        }
        var textScalars: Int {
            switch self { case .sealed(let c): c.rows.reduce(0) { $0 + $1.line.textScalarCount }
                + (c.checkpoint?.text.unicodeScalars.count ?? 0)
            case .checkpoint(let c): c.text.unicodeScalars.count }
        }
        /// Silence still advances the save barrier, but it does not save any text.
        var changesText: Bool {
            switch self {
            case .sealed(let batch):
                batch.rows.contains { !$0.line.text.isEmpty }
                    || batch.checkpoint.map { ($0.expectedText ?? "") != $0.text } == true
            case .checkpoint(let checkpoint):
                (checkpoint.expectedText ?? "") != checkpoint.text
            }
        }
    }
    public enum Admission: Equatable { case accepted, duplicate, capacityExceeded, throttled, invalidIdentity }
    public struct Failure: Sendable {
        public let command: Command
        public let message: String
    }
    public private(set) var pending: [Command] = []
    public private(set) var failure: Failure?
    public private(set) var savedThrough = 0
    public private(set) var rejectionCount = 0
    private var worker: Task<Void, Never>?
    private var active: Command?
    private var remembered: [Command] = []
    private var lastCheckpointAt: TimeInterval = -.infinity
    private let maximumCommands: Int
    private let maximumScalars: Int
    private let save: @MainActor (Command) async throws -> WindowSaveAck
    private let didSave: @MainActor (Command, WindowSaveAck) async -> Void
    public init(maximumCommands: Int = 32, maximumScalars: Int = 262144,
        save: @escaping @MainActor (Command) async throws -> WindowSaveAck,
        didSave: @escaping @MainActor (Command, WindowSaveAck) async -> Void = { _, _ in }) {
        self.maximumCommands = maximumCommands; self.maximumScalars = maximumScalars
        self.save = save; self.didSave = didSave
    }
    @discardableResult public func enqueue(_ command: Command) -> Admission {
        if active == command || pending.contains(command) || remembered.contains(command) { return .duplicate }
        if case .sealed = command,
           ([active].compactMap { $0 } + pending + remembered).contains(where: { $0.id == command.id }) {
            rejectionCount += 1
            return .invalidIdentity
        }
        if case .checkpoint(let next) = command,
           let index = pending.indices.last,
           case .checkpoint(let prior) = pending[index], prior.id == next.id {
            let combined = Command.checkpoint(prior.coalescing(next))
            guard pending.reduce(0, { $0 + $1.textScalars }) + (active?.textScalars ?? 0)
                - pending[index].textScalars + combined.textScalars <= maximumScalars
            else { rejectionCount += 1; return .capacityExceeded }
            pending[index] = combined; start(); return .accepted
        }
        guard pending.count + (active == nil ? 0 : 1) < maximumCommands,
              pending.reduce(0, { $0 + $1.textScalars }) + (active?.textScalars ?? 0) + command.textScalars <= maximumScalars
        else { rejectionCount += 1; return .capacityExceeded }
        pending.append(command); start(); return .accepted
    }
    @discardableResult public func checkpoint(_ command: WindowCheckpointCommand,
        now: TimeInterval, force: Bool = false) -> Admission {
        guard force || now - lastCheckpointAt >= 2 else { return .throttled }
        let admission = enqueue(.checkpoint(command))
        if admission == .accepted { lastCheckpointAt = now }
        return admission
    }
    public func retry() { failure = nil; start() }
    func acknowledgeRetainedRejection() { rejectionCount = 0 }
    public func waitUntilSettled() async { await worker?.value }
    public var ownedCommands: [Command] {
        guard let active, !pending.contains(active) else { return pending }
        return [active] + pending
    }
    public var isComplete: Bool { pending.isEmpty && active == nil && failure == nil && rejectionCount == 0 }
    private func start() {
        guard worker == nil, failure == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }
    private func drain() async {
        defer { active = nil; worker = nil }
        while !pending.isEmpty && failure == nil {
            let command = pending.removeFirst(); active = command
            do {
                let ack = try await save(command)
                savedThrough = max(savedThrough, ack.savedThrough)
                remembered.append(command)
                if remembered.count > 64 { remembered.removeFirst() }
                await didSave(command, ack)
                active = nil
            } catch {
                failure = Failure(command: command, message: error.localizedDescription)
                pending.insert(command, at: 0)
            }
        }
    }
}


/// Per-capture binding keeps wire identities away from the currently selected record.
@MainActor @Observable
public final class TranscriptWindowCapture {
    public let recordID: String
    public let identity: TranscriptPreviewLedger.Identity
    public private(set) var ledger: TranscriptWindowLedger
    public private(set) var incomplete = false
    public private(set) var isDraining = false
    public private(set) var confirmed: [String: [TranscriptWindowUnit]] = [:]
    public private(set) var recoveryText = ""
    public private(set) var lastUICommitAt: ContinuousClock.Instant?
    public private(set) var fallingBehind = false
    public private(set) var blockedCommand: TranscriptWindowPersistenceQueue.Command?
    public var visibleUnits: [TranscriptWindowUnit] {
        (confirmed.values.flatMap { $0 } + ledger.units).sorted { $0.ownedSpan.start < $1.ownedSpan.start }
    }
    public var visibleText: String { visibleUnits.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
    public var statusText: String {
        if incomplete || queue.failure != nil || queue.rejectionCount > 0 { return "部分内容未完成" }
        if fallingBehind { return "识别稍慢，正在追赶" }
        if confirmed.values.contains(where: { $0.contains { !$0.text.isEmpty } })
            || queue.ownedCommands.contains(where: \.changesText) { return "文字已确认，正在保存" }
        if isDraining && !ledger.units.isEmpty { return "正在确认文字" }
        if !ledger.units.isEmpty { return "正在识别" }
        return "已保存"
    }
    private let binding: TranscriptWindowLedger.Binding
    private let source: SessionLineSource
    private let offsetSeconds: TimeInterval
    private let maximumPendingCommands: Int
    private let checkpointID = UUID().uuidString
    private let observedAt: Date
    private var checkpointText: String?
    private var waiters: [UUID: (Int, CheckedContinuation<Void, any Error>)] = [:]
    private let save: @MainActor (TranscriptWindowPersistenceQueue.Command) async throws -> WindowSaveAck
    private let didSave: @MainActor (TranscriptPersistenceQueue.Command, Int) async -> Void
    @ObservationIgnored public private(set) lazy var queue = TranscriptWindowPersistenceQueue(
        maximumCommands: maximumPendingCommands,
        save: { [weak self] command in
            guard let self else { throw CancellationError() }
            do { return try await self.save(command) }
            catch { self.failWaiters(error); throw error }
        }, didSave: { [weak self] command, ack in
            guard let self else { return }
            if case .sealed(let batch) = command {
                self.confirmed.removeValue(forKey: batch.transactionID)
                for row in batch.rows {
                    if let ordinal = ack.lineOrdinals[row.line.lineID] { await self.didSave(row.line, ordinal) }
                }
            }
            self.resolveWaiters(savedThrough: ack.savedThrough)
        })
    public init(recordID: String, identity: TranscriptPreviewLedger.Identity,
                source: SessionLineSource, offsetSeconds: TimeInterval, observedAt: Date,
                maximumPendingCommands: Int = 32,
                save: @escaping @MainActor (TranscriptWindowPersistenceQueue.Command) async throws -> WindowSaveAck,
                didSave: @escaping @MainActor (TranscriptPersistenceQueue.Command, Int) async -> Void = { _, _ in }) {
        self.recordID = recordID; self.identity = identity; self.source = source
        self.offsetSeconds = offsetSeconds; self.observedAt = observedAt
        self.maximumPendingCommands = min(32, max(1, maximumPendingCommands))
        self.save = save; self.didSave = didSave
        let binding = TranscriptWindowLedger.Binding(recordID: recordID, connectionID: UUID(), generation: identity.generation)
        self.binding = binding; self.ledger = TranscriptWindowLedger(binding: binding)
    }
    @discardableResult public func apply(_ event: TranscriptWindowEvent, observedAt now: Date) -> TranscriptWindowLedger.Admission {
        guard blockedCommand == nil else { return .rejected }
        let admission = ledger.apply(event, binding: binding)
        guard admission != .rejected && admission != .duplicate else { return admission }
        fallingBehind = event.fallingBehind ?? false
        // This clock measures the actual App projection, not socket receipt time.
        lastUICommitAt = ContinuousClock().now
        let tail = ledger.units.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        if admission == .snapshot, tail != (checkpointText ?? "") {
            let cp = checkpoint(text: tail)
            let accepted = queue.checkpoint(cp, now: now.timeIntervalSince1970)
            if accepted == .accepted { checkpointText = tail.isEmpty ? nil : tail }
            if accepted == .capacityExceeded || accepted == .invalidIdentity {
                retainRefused(.checkpoint(cp))
            }
        } else if admission != .snapshot, let tx = event.transactionID {
            var rows: [SealedWindowCommand.Row] = []
            for unit in event.finalUnits ?? [] {
                guard let item = unit.itemID else { continue }
                rows.append(row(item: item, text: unit.text, span: unit.ownedSpan, formal: true, now: now))
            }
            for item in event.failedItems ?? [] {
                incomplete = true
                recoveryText = String((recoveryText + " " + item.recoveryText).unicodeScalars.suffix(32768).map(String.init).joined())
                if !item.recoveryText.isEmpty { rows.append(row(item: item.itemID, text: item.recoveryText,
                    span: item.ownedSpan, formal: false, now: now)) }
            }
            let batch = SealedWindowCommand(transactionID: tx, sessionID: recordID, rows: rows,
                savedThrough: event.sealedThroughSample, checkpoint: checkpoint(text: tail))
            let accepted = queue.enqueue(.sealed(batch))
            if let units = event.finalUnits, !units.isEmpty { confirmed[tx] = units }
            if accepted == .accepted {
                checkpointText = tail.isEmpty ? nil : tail
            } else if accepted != .duplicate {
                // One refused transaction is retained in addition to the bounded
                // queue. The caller must stop input before accepting more events.
                retainRefused(.sealed(batch))
            }
        }
        return admission
    }
    private func checkpoint(text: String) -> WindowCheckpointCommand {
        .init(sessionID: recordID, id: checkpointID, expectedText: checkpointText,
              text: text, observedAt: observedAt, source: source)
    }
    private func row(item: String, text: String, span: TranscriptWindowSpan, formal: Bool, now: Date) -> SealedWindowCommand.Row {
        let command = TranscriptPersistenceQueue.Command(sessionID: recordID, connection: identity.connection, itemID: item,
            generation: identity.generation, text: text, source: source, role: .speaker,
            tStart: offsetSeconds + Double(span.start)/24000, tEnd: offsetSeconds + Double(span.end)/24000,
            formal: formal, isInterrupted: !formal, timingQuality: .unavailable, observedAt: now)
        return SealedWindowCommand.Row(line: command)
    }
    public func retainTail() {
        // A refused command already contains this frozen tail. Appending another
        // checkpoint would cross its unsaved CAS parent and reorder recovery.
        guard blockedCommand == nil else { return }
        let tail = ledger.units.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        guard tail != (checkpointText ?? "") else { return }
        let cp = checkpoint(text: tail)
        let accepted = queue.checkpoint(cp, now: 0, force: true)
        if accepted == .accepted { checkpointText = tail.isEmpty ? nil : tail }
        else if accepted != .duplicate { retainRefused(.checkpoint(cp)) }
    }
    private func retainRefused(_ command: TranscriptWindowPersistenceQueue.Command) {
        blockedCommand = command
        incomplete = true
        failWaiters(SessionDrainFailure(stage: .persistence, message: "部分文字尚未保存，请复制恢复内容。"))
    }
    public func retryPending() async {
        queue.retry()
        await queue.waitUntilSettled()
        guard queue.failure == nil else { return }
        if let blockedCommand, queue.enqueue(blockedCommand) == .accepted {
            let cp: WindowCheckpointCommand?
            switch blockedCommand { case .checkpoint(let checkpoint): cp = checkpoint
            case .sealed(let batch): cp = batch.checkpoint }
            if let cp { checkpointText = cp.text.isEmpty ? nil : cp.text }
            self.blockedCommand = nil
            queue.acknowledgeRetainedRejection()
            await queue.waitUntilSettled()
        }
    }
    public func waitSaved(through sample: Int) async throws {
        isDraining = true
        if queue.savedThrough >= sample { return }
        if queue.failure != nil || queue.rejectionCount > 0 {
            throw SessionDrainFailure(stage: .persistence, message: "文字已确认，但保存尚未完成。")
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = (sample, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
    private func resolveWaiters(savedThrough: Int) {
        for (id, waiter) in waiters where waiter.0 <= savedThrough {
            waiters.removeValue(forKey: id)?.1.resume()
        }
    }
    private func failWaiters(_ error: any Error) {
        let pending = waiters.values; waiters.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: error) }
    }
    public var recoveryCommands: [TranscriptPersistenceQueue.Command] {
        (queue.ownedCommands + [blockedCommand].compactMap { $0 }).flatMap { command -> [TranscriptPersistenceQueue.Command] in
            switch command {
            case .sealed(let batch): return batch.rows.map(\.line)
            case .checkpoint(let cp): return [.init(sessionID: cp.sessionID, connection: identity.connection,
                itemID: cp.id, generation: identity.generation, acceptanceID: cp.id, lineID: cp.id,
                text: cp.text, source: cp.source, role: cp.role, formal: false, observedAt: cp.observedAt)]
            }
        }
    }
}
