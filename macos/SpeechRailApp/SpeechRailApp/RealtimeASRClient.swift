import Foundation
import SpeechRailControlKit

/// App 场景的断句预设。短暂停顿是否结束一轮由调用方场景决定，
/// Realtime 服务只执行这里传入的静音窗口。
enum RealtimeVADProfile: Sendable {
    case assistantTurnTaking
    case assistantDuplex
    case caption
    case meeting
    case teleprompter

    static func assistant(_ mode: AssistantMode) -> Self {
        mode == .turnTaking ? .assistantTurnTaking : .assistantDuplex
    }

    var silenceDurationMilliseconds: Int {
        switch self {
        case .assistantTurnTaking: 1_200
        case .assistantDuplex, .meeting: 900
        case .caption, .teleprompter: 400
        }
    }
}

enum RealtimeASRSocketFrame: Sendable {
    case text(String)
    case data(Data)
    case unsupported
}

protocol RealtimeASRTransport: Sendable {
    func resume() async
    func send(_ text: String) async throws
    func receive() async throws -> RealtimeASRSocketFrame
    func closeCode() async -> Int?
    func cancel() async
}

private actor URLSessionRealtimeASRTransport: RealtimeASRTransport {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() async {
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> RealtimeASRSocketFrame {
        switch try await task.receive() {
        case .string(let text): .text(text)
        case .data(let data): .data(data)
        @unknown default: .unsupported
        }
    }

    func closeCode() async -> Int? {
        task.closeCode == .invalid ? nil : task.closeCode.rawValue
    }

    func cancel() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Bounded per-connection transcript/auxiliary state. Transcript identity is
/// the item ID; task, epoch, and revision are validated attributes, not map keys.
struct RealtimeEventState: Sendable {
    static let maxItems = 128
    static let itemLifetime: Duration = .seconds(30)
    static let maxTranscriptUTF8Bytes = 64 * 1024
    static let maxAlignmentUnits = 1_024
    static let maxDiarizationSpans = 1_024
    static let maxAuxiliaryBytes = 256 * 1024
    private static let auxiliaryEntryOverheadBytes = 64

    enum LimitViolation: Equatable, Sendable {
        case transcript
        case alignment
        case diarization

        var message: String {
            switch self {
            case .transcript:
                "单条实时转写超过本地安全上限，已关闭当前连接。"
            case .alignment:
                "单条实时对齐数据超过本地安全上限，已关闭当前连接。"
            case .diarization:
                "单条实时说话人数据超过本地安全上限，已关闭当前连接。"
            }
        }
    }

    struct Range: Equatable, Sendable {
        let start: Int
        let end: Int
    }

    struct Snapshot: Sendable {
        let transcript: String?
        let alignmentUnits: [RealtimeASRClient.AttributionUnit]
        let diarizationSpans: [RealtimeASRClient.DiarizationSpan]
        let auxiliaryExpected: Bool
    }

    struct ExpiredItem: Sendable {
        let itemID: String
        let snapshot: Snapshot
    }

    private struct SampleSpanKey: Hashable, Sendable {
        let start: Int
        let end: Int
    }

    private struct Item: Sendable {
        let generation: UUID
        let sessionID: String
        var taskID: String?
        var epoch: Int?
        var transcript: String?
        var frozenTranscriptRevision: Int?
        var isTextTerminal = false
        var latestHypothesisRevision: Int?
        var alignmentTranscriptRevision: Int?
        var alignmentRevision: Int?
        var alignmentUnits: [String: RealtimeASRClient.AttributionUnit] = [:]
        var alignmentStorageBytes = 0
        var diarizationTranscriptRevision: Int?
        var diarizationRevision: Int?
        var diarizationSpans: [SampleSpanKey: RealtimeASRClient.DiarizationSpan] = [:]
        var diarizationStorageBytes = 0
        var lastActivity: ContinuousClock.Instant

        init(
            generation: UUID,
            sessionID: String,
            taskID: String?,
            epoch: Int?,
            now: ContinuousClock.Instant
        ) {
            self.generation = generation
            self.sessionID = sessionID
            self.taskID = taskID
            self.epoch = epoch
            self.lastActivity = now
        }
    }

    private var generation = UUID()
    private var sessionID: String?
    private var serverTaskID: String?
    private var latestEpoch: Int?
    private var itemOrder: [String] = []
    private var items: [String: Item] = [:]
    private var retiredUntil: [String: ContinuousClock.Instant] = [:]
    private var retiredOrder: [String] = []
    private var pendingExpiry: [ExpiredItem] = []
    private var auxiliaryExpected = false
    private var lastLimitViolation: LimitViolation?

    mutating func takeLimitViolation() -> LimitViolation? {
        defer { lastLimitViolation = nil }
        return lastLimitViolation
    }

    mutating func reset(generation: UUID, auxiliaryExpected: Bool) {
        self.generation = generation
        self.sessionID = nil
        serverTaskID = nil
        latestEpoch = nil
        itemOrder.removeAll(keepingCapacity: true)
        items.removeAll(keepingCapacity: true)
        retiredUntil.removeAll(keepingCapacity: true)
        retiredOrder.removeAll(keepingCapacity: true)
        pendingExpiry.removeAll(keepingCapacity: true)
        lastLimitViolation = nil
        self.auxiliaryExpected = auxiliaryExpected
    }

    mutating func clear() {
        sessionID = nil
        serverTaskID = nil
        latestEpoch = nil
        itemOrder.removeAll(keepingCapacity: false)
        items.removeAll(keepingCapacity: false)
        retiredUntil.removeAll(keepingCapacity: false)
        retiredOrder.removeAll(keepingCapacity: false)
        pendingExpiry.removeAll(keepingCapacity: false)
        lastLimitViolation = nil
    }

    mutating func prune(now: ContinuousClock.Instant) {
        let expiredIDs = itemOrder.filter { itemID in
            guard let item = items[itemID] else { return true }
            return item.lastActivity.duration(to: now) > Self.itemLifetime
        }
        for itemID in expiredIDs {
            retire(itemID, now: now)
        }
        retiredOrder.removeAll { itemID in
            guard let deadline = retiredUntil[itemID], deadline > now else {
                retiredUntil.removeValue(forKey: itemID)
                return true
            }
            return false
        }
    }

    mutating func takeExpired() -> [ExpiredItem] {
        defer { pendingExpiry.removeAll(keepingCapacity: true) }
        return pendingExpiry
    }

    func snapshot(itemID: String) -> Snapshot? {
        guard let item = items[itemID] else { return nil }
        return snapshot(item)
    }

    func hasHypothesis(itemID: String) -> Bool {
        items[itemID]?.latestHypothesisRevision != nil
    }

    func nextExpiryDelay(now: ContinuousClock.Instant) -> Duration? {
        guard let oldest = items.values.min(by: {
            $0.lastActivity < $1.lastActivity
        }) else { return nil }
        let deadline = oldest.lastActivity.advanced(by: Self.itemLifetime)
        return deadline <= now ? .zero : now.duration(to: deadline)
    }

    @discardableResult
    mutating func observeDelta(
        itemID: String,
        delta: String,
        sessionID: String,
        generation: UUID,
        now: ContinuousClock.Instant
    ) -> Bool {
        lastLimitViolation = nil
        let deltaBytes = delta.utf8.count
        guard deltaBytes <= Self.maxTranscriptUTF8Bytes else {
            lastLimitViolation = .transcript
            return false
        }
        guard prepareBaseItem(
            itemID: itemID,
            sessionID: sessionID,
            generation: generation,
            now: now,
            createIfMissing: true
        ) else { return false }
        var item = items[itemID]!
        guard !item.isTextTerminal else { return false }
        if item.latestHypothesisRevision == nil {
            let transcriptBytes = item.transcript?.utf8.count ?? 0
            guard deltaBytes <= Self.maxTranscriptUTF8Bytes - transcriptBytes else {
                lastLimitViolation = .transcript
                return false
            }
            item.transcript = (item.transcript ?? "") + delta
        }
        item.lastActivity = now
        items[itemID] = item
        touch(itemID)
        return true
    }

    @discardableResult
    mutating func acceptHypothesis(
        itemID: String,
        taskID: String,
        epoch: Int,
        revision: Int,
        text: String,
        sessionID: String,
        generation: UUID,
        now: ContinuousClock.Instant
    ) -> Bool {
        lastLimitViolation = nil
        guard text.utf8.count <= Self.maxTranscriptUTF8Bytes else {
            lastLimitViolation = .transcript
            return false
        }
        guard revision >= 0,
              !itemID.isEmpty,
              items[itemID]?.latestHypothesisRevision.map({ revision > $0 }) ?? true,
              canAcceptExtension(
                itemID: itemID,
                taskID: taskID,
                epoch: epoch,
                sessionID: sessionID,
                generation: generation,
                now: now,
                createIfMissing: true
              ),
              var item = items[itemID],
              !item.isTextTerminal
        else { return false }
        item.latestHypothesisRevision = revision
        item.transcript = text
        item.lastActivity = now
        items[itemID] = item
        touch(itemID)
        return true
    }

    @discardableResult
    mutating func complete(
        itemID: String,
        transcript: String,
        sessionID: String,
        generation: UUID,
        now: ContinuousClock.Instant
    ) -> Bool {
        lastLimitViolation = nil
        guard transcript.utf8.count <= Self.maxTranscriptUTF8Bytes else {
            lastLimitViolation = .transcript
            return false
        }
        guard prepareBaseItem(
            itemID: itemID,
            sessionID: sessionID,
            generation: generation,
            now: now,
            createIfMissing: true
        ) else { return false }
        var item = items[itemID]!
        guard !item.isTextTerminal else { return false }
        item.transcript = transcript
        item.isTextTerminal = true
        item.lastActivity = now
        items[itemID] = item
        touch(itemID)
        return true
    }

    @discardableResult
    mutating func failText(
        itemID: String,
        sessionID: String,
        generation: UUID,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard prepareBaseItem(
            itemID: itemID,
            sessionID: sessionID,
            generation: generation,
            now: now,
            createIfMissing: true
        ),
        var item = items[itemID],
        !item.isTextTerminal
        else { return false }
        item.isTextTerminal = true
        item.lastActivity = now
        items[itemID] = item
        touch(itemID)
        return true
    }

    @discardableResult
    mutating func applyAlignment(
        itemID: String,
        taskID: String,
        epoch: Int,
        transcriptRevision: Int,
        metadataRevision: Int,
        sampleSpan: Range,
        codepointSpan: Range,
        units: [RealtimeASRClient.AttributionUnit],
        sessionID: String,
        generation: UUID,
        now: ContinuousClock.Instant
    ) -> Bool {
        lastLimitViolation = nil
        guard units.count <= Self.maxAlignmentUnits else {
            lastLimitViolation = .alignment
            return false
        }
        guard transcriptRevision >= 0,
              metadataRevision >= 0,
              let candidate = items[itemID],
              candidate.generation == generation,
              candidate.sessionID == sessionID,
              candidate.isTextTerminal,
              candidate.frozenTranscriptRevision == nil
                  || candidate.frozenTranscriptRevision == transcriptRevision,
              let transcript = candidate.transcript,
              Self.validAlignment(
                units: units,
                codepointSpan: codepointSpan,
                sampleSpan: sampleSpan,
                transcript: transcript
              )
        else { return false }
        if let boundRevision = candidate.alignmentTranscriptRevision,
           boundRevision != transcriptRevision {
            return false
        }
        if let previous = candidate.alignmentRevision, metadataRevision < previous {
            return false
        }
        var updatedUnits = candidate.alignmentUnits
        var updatedStorageBytes = candidate.alignmentStorageBytes
        if let previous = candidate.alignmentRevision, metadataRevision > previous {
            updatedUnits.removeAll(keepingCapacity: true)
            updatedStorageBytes = 0
        }
        for unit in units {
            let existing = updatedUnits[unit.segmentUID]
            if existing == nil, updatedUnits.count >= Self.maxAlignmentUnits {
                lastLimitViolation = .alignment
                return false
            }
            let previousCost = existing.map(Self.alignmentStorageCost) ?? 0
            let nextCost = Self.alignmentStorageCost(unit)
            let nextStorageBytes = updatedStorageBytes - previousCost + nextCost
            let otherStorageBytes = candidate.diarizationStorageBytes
            guard nextCost <= Self.maxAuxiliaryBytes - otherStorageBytes,
                  nextStorageBytes <= Self.maxAuxiliaryBytes - otherStorageBytes
            else {
                lastLimitViolation = .alignment
                return false
            }
            updatedUnits[unit.segmentUID] = unit
            updatedStorageBytes = nextStorageBytes
        }
        guard canAcceptExtension(
            itemID: itemID,
            taskID: taskID,
            epoch: epoch,
            sessionID: sessionID,
            generation: generation,
            now: now,
            createIfMissing: false
        ),
        var item = items[itemID] else { return false }

        item.alignmentTranscriptRevision = transcriptRevision
        item.frozenTranscriptRevision = transcriptRevision
        item.alignmentRevision = metadataRevision
        item.alignmentUnits = updatedUnits
        item.alignmentStorageBytes = updatedStorageBytes
        item.lastActivity = now
        items[itemID] = item
        touch(itemID)
        return true
    }

    @discardableResult
    mutating func acceptAlignmentFailure(
        itemID: String,
        taskID: String,
        epoch: Int,
        transcriptRevision: Int,
        metadataRevision: Int,
        sessionID: String,
        generation: UUID,
        now: ContinuousClock.Instant
    ) -> Bool {
        lastLimitViolation = nil
        guard transcriptRevision >= 0,
              metadataRevision >= 0,
              let candidate = items[itemID],
              candidate.isTextTerminal,
              candidate.frozenTranscriptRevision == nil
                  || candidate.frozenTranscriptRevision == transcriptRevision,
              canAcceptExtension(
                itemID: itemID,
                taskID: taskID,
                epoch: epoch,
                sessionID: sessionID,
                generation: generation,
                now: now,
                createIfMissing: false
              ),
              var item = items[itemID],
              item.isTextTerminal
        else { return false }
        if let boundRevision = item.alignmentTranscriptRevision,
           boundRevision != transcriptRevision {
            return false
        }
        if let previous = item.alignmentRevision {
            guard metadataRevision >= previous else { return false }
            if metadataRevision > previous {
                item.alignmentUnits.removeAll(keepingCapacity: true)
                item.alignmentStorageBytes = 0
            }
        }
        if item.alignmentTranscriptRevision == nil {
            item.alignmentStorageBytes = 0
        }
        item.frozenTranscriptRevision = transcriptRevision
        item.alignmentRevision = metadataRevision
        item.lastActivity = now
        items[itemID] = item
        touch(itemID)
        return true
    }

    @discardableResult
    mutating func applyDiarization(
        itemID: String,
        taskID: String,
        epoch: Int,
        transcriptRevision: Int,
        metadataRevision: Int,
        spans: [RealtimeASRClient.DiarizationSpan],
        sessionID: String,
        generation: UUID,
        now: ContinuousClock.Instant
    ) -> Bool {
        lastLimitViolation = nil
        guard spans.count <= Self.maxDiarizationSpans else {
            lastLimitViolation = .diarization
            return false
        }
        guard transcriptRevision >= 0,
              metadataRevision >= 0,
              spans.allSatisfy({ $0.startSample >= 0 && $0.endSample > $0.startSample }),
              let candidate = items[itemID],
              candidate.generation == generation,
              candidate.sessionID == sessionID,
              candidate.frozenTranscriptRevision == nil
                  || candidate.frozenTranscriptRevision == transcriptRevision
        else { return false }

        var updatedSpans = candidate.diarizationSpans
        var updatedStorageBytes = candidate.diarizationStorageBytes
        if let previousTranscriptRevision = candidate.diarizationTranscriptRevision {
            guard transcriptRevision >= previousTranscriptRevision else { return false }
            if transcriptRevision > previousTranscriptRevision {
                updatedSpans.removeAll(keepingCapacity: true)
                updatedStorageBytes = 0
            }
        }
        if let previousMetadataRevision = candidate.diarizationRevision {
            guard metadataRevision >= previousMetadataRevision else { return false }
            if metadataRevision > previousMetadataRevision {
                updatedSpans.removeAll(keepingCapacity: true)
                updatedStorageBytes = 0
            }
        }
        for span in spans {
            let key = SampleSpanKey(start: span.startSample, end: span.endSample)
            let existing = updatedSpans[key]
            if existing == nil, updatedSpans.count >= Self.maxDiarizationSpans {
                lastLimitViolation = .diarization
                return false
            }
            let previousCost = existing.map(Self.diarizationStorageCost) ?? 0
            let nextCost = Self.diarizationStorageCost(span)
            let nextStorageBytes = updatedStorageBytes - previousCost + nextCost
            let otherStorageBytes = candidate.alignmentStorageBytes
            guard nextCost <= Self.maxAuxiliaryBytes - otherStorageBytes,
                  nextStorageBytes <= Self.maxAuxiliaryBytes - otherStorageBytes
            else {
                lastLimitViolation = .diarization
                return false
            }
            updatedSpans[key] = span
            updatedStorageBytes = nextStorageBytes
        }
        guard canAcceptExtension(
            itemID: itemID,
            taskID: taskID,
            epoch: epoch,
            sessionID: sessionID,
            generation: generation,
            now: now,
            createIfMissing: false
        ),
        var item = items[itemID] else { return false }
        item.diarizationTranscriptRevision = transcriptRevision
        item.frozenTranscriptRevision = transcriptRevision
        item.diarizationRevision = metadataRevision
        item.diarizationSpans = updatedSpans
        item.diarizationStorageBytes = updatedStorageBytes
        item.lastActivity = now
        items[itemID] = item
        touch(itemID)
        return true
    }

    @discardableResult
    mutating func acceptSessionEvent(
        taskID: String,
        epoch: Int,
        sessionID: String,
        generation: UUID,
        now: ContinuousClock.Instant
    ) -> Bool {
        canAcceptExtension(
            itemID: nil,
            taskID: taskID,
            epoch: epoch,
            sessionID: sessionID,
            generation: generation,
            now: now,
            createIfMissing: false
        )
    }

    private mutating func prepareBaseItem(
        itemID: String,
        sessionID: String,
        generation: UUID,
        now: ContinuousClock.Instant,
        createIfMissing: Bool
    ) -> Bool {
        guard !itemID.isEmpty,
              generation == self.generation,
              acceptSession(sessionID)
        else { return false }
        if var item = items[itemID] {
            guard item.generation == generation, item.sessionID == sessionID else {
                return false
            }
            item.lastActivity = now
            items[itemID] = item
            touch(itemID)
            return true
        }
        guard createIfMissing, retiredUntil[itemID] == nil else { return false }
        makeRoom(now: now)
        items[itemID] = Item(
            generation: generation,
            sessionID: sessionID,
            taskID: serverTaskID,
            epoch: latestEpoch,
            now: now
        )
        itemOrder.append(itemID)
        return true
    }

    private mutating func canAcceptExtension(
        itemID: String?,
        taskID: String,
        epoch: Int,
        sessionID: String,
        generation: UUID,
        now: ContinuousClock.Instant,
        createIfMissing: Bool
    ) -> Bool {
        guard !taskID.isEmpty,
              epoch >= 0,
              generation == self.generation,
              acceptSession(sessionID),
              serverTaskID == nil || serverTaskID == taskID,
              latestEpoch == nil || epoch >= latestEpoch!
        else { return false }

        var existing: Item?
        if let itemID {
            guard !itemID.isEmpty, retiredUntil[itemID] == nil else { return false }
            existing = items[itemID]
            if let existing {
                guard existing.generation == generation,
                      existing.sessionID == sessionID,
                      existing.taskID == nil || existing.taskID == taskID,
                      existing.epoch == nil || existing.epoch == epoch
                else { return false }
            } else if !createIfMissing {
                return false
            }
        }

        serverTaskID = taskID
        if latestEpoch == nil || epoch > latestEpoch! {
            latestEpoch = epoch
        }
        if let itemID {
            if existing == nil {
                makeRoom(now: now)
                items[itemID] = Item(
                    generation: generation,
                    sessionID: sessionID,
                    taskID: taskID,
                    epoch: epoch,
                    now: now
                )
                itemOrder.append(itemID)
            } else if var item = existing {
                item.taskID = taskID
                item.epoch = epoch
                item.lastActivity = now
                items[itemID] = item
                touch(itemID)
            }
        }
        return true
    }

    private mutating func acceptSession(_ sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        if let expected = self.sessionID, expected != sessionID { return false }
        self.sessionID = sessionID
        return true
    }

    private mutating func makeRoom(now: ContinuousClock.Instant) {
        guard items.count >= Self.maxItems, let oldest = itemOrder.first else { return }
        retire(oldest, now: now)
    }

    private mutating func retire(_ itemID: String, now: ContinuousClock.Instant) {
        guard let item = items.removeValue(forKey: itemID) else {
            itemOrder.removeAll { $0 == itemID }
            return
        }
        itemOrder.removeAll { $0 == itemID }
        if auxiliaryExpected {
            pendingExpiry.append(ExpiredItem(itemID: itemID, snapshot: snapshot(item)))
        }
        retiredUntil[itemID] = now.advanced(by: Self.itemLifetime)
        retiredOrder.removeAll { $0 == itemID }
        retiredOrder.append(itemID)
        while retiredOrder.count > Self.maxItems {
            let removed = retiredOrder.removeFirst()
            retiredUntil.removeValue(forKey: removed)
        }
    }

    private mutating func touch(_ itemID: String) {
        itemOrder.removeAll { $0 == itemID }
        itemOrder.append(itemID)
    }

    private func snapshot(_ item: Item) -> Snapshot {
        Snapshot(
            transcript: item.transcript,
            alignmentUnits: item.alignmentUnits.values.sorted {
                ($0.textStart ?? Int.max, $0.segmentUID)
                    < ($1.textStart ?? Int.max, $1.segmentUID)
            },
            diarizationSpans: item.diarizationSpans.values.sorted {
                ($0.startSample, $0.endSample) < ($1.startSample, $1.endSample)
            },
            auxiliaryExpected: auxiliaryExpected
        )
    }

    private static func validAlignment(
        units: [RealtimeASRClient.AttributionUnit],
        codepointSpan: Range,
        sampleSpan: Range,
        transcript: String
    ) -> Bool {
        let codepointCount = transcript.unicodeScalars.count
        guard codepointSpan.start <= codepointSpan.end,
              codepointSpan.end <= codepointCount,
              sampleSpan.start <= sampleSpan.end
        else { return false }
        return units.allSatisfy { unit in
            guard let textStart = unit.textStart,
                  let textEnd = unit.textEnd,
                  let audioStart = unit.audioStartSample,
                  let audioEnd = unit.audioEndSample
            else { return false }
            return textStart >= codepointSpan.start
                && textEnd >= textStart
                && textEnd <= codepointSpan.end
                && audioStart >= sampleSpan.start
                && audioEnd >= audioStart
                && audioEnd <= sampleSpan.end
        }
    }

    private static func alignmentStorageCost(
        _ unit: RealtimeASRClient.AttributionUnit
    ) -> Int {
        auxiliaryEntryOverheadBytes
            + MemoryLayout<RealtimeASRClient.AttributionUnit>.stride
            + unit.segmentUID.utf8.count * 2
            + (unit.speaker?.utf8.count ?? 0)
            + (unit.timingQuality?.utf8.count ?? 0)
            + (unit.granularity?.utf8.count ?? 0)
    }

    private static func diarizationStorageCost(
        _ span: RealtimeASRClient.DiarizationSpan
    ) -> Int {
        auxiliaryEntryOverheadBytes
            + MemoryLayout<RealtimeASRClient.DiarizationSpan>.stride
            + (span.speaker?.utf8.count ?? 0)
    }
}

// `/v1/realtime` 的客户端（契约：`contracts/realtime-openai.md`）。
//
// 它只做四件事：**连、配、喂 PCM、收事件**。没有大模型、没有播放、没有业务状态——
// 那些属于助手 / 会议 / 字幕各自的会话层（`TECHNICAL-DESIGN` §5.3）。
//
// 三条从契约直接落下来的硬约束，写在这里免得以后被"顺手优化"掉：
//
//   1. **线上格式固定 24 kHz / 单声道 / PCM16**，而且**首个 PCM 之后不得改格式**。
//      换设备只能重建采集、不重开会话（`TECHNICAL-DESIGN` §5.2 第 5 条）。
//   2. **partial 只进内存**：官方 `delta` 是可追加的稳定前缀，
//      `speechrail.transcription.hypothesis` 是**可改写全文**（必须整段替换）——
//      所以定稿只认 `completed` 的全量 `transcript`。
//   3. **`backend_busy` 是准入结果，不是异常**：它连的是会话占用守卫，不是错误弹窗
//      （`IMPLEMENTATION-READINESS` §3 的同一条结论）。

/// Realtime ASR 的客户端。一个实例对应一条 WebSocket、一次会话。
public actor RealtimeASRClient {
    /// 契约里的 canonical ASR profile。用别名（`gpt-4o-transcribe`）也能连上，
    /// 但那是给标准 OpenAI 客户端准备的；App 是我们自己的客户端，报 canonical 名。
    public static let canonicalASRModel = "speechrail/qwen3-asr-1.7b"

    /// 流式转写的线上格式。当前 SpeechRail transcription session 固定使用
    /// 24 kHz / 单声道 / PCM16；原生层归一到这个格式，服务端再重采样到 16 kHz 内核。
    public static let sampleRate: Double = 24_000

    public enum Failure: LocalizedError, Equatable, Sendable {
        case unsupportedModel(String)
        case transport(String)
        case closed(Int?)
        case drainTimedOut(RealtimeDrainStage)

        public var errorDescription: String? {
            switch self {
            case .unsupportedModel(let model):
                "这个档位不支持流式模型 \(model)。"
            case .transport(let message):
                "连不上语音服务：\(message)"
            case .closed(let code):
                code.map { "语音服务断开了连接（\($0)）。" } ?? "语音服务断开了连接。"
            case .drainTimedOut(let stage):
                switch stage {
                case .commit:
                    "语音服务没有在关闭期限内确认提交。"
                case .terminalItems:
                    "最后一段语音没有在关闭期限内完成转写。"
                case .diarization:
                    "说话人归属没有在关闭期限内完成收口。"
                case .clear:
                    "语音服务没有在关闭期限内确认清空缓冲区。"
                case .close:
                    "语音服务没有在关闭期限内完成关闭。"
                }
            }
        }
    }

    /// 一个**归属单元**：对齐器给的可冻结文本片段，加上分人给出的匿名标签。
    ///
    /// 当前 wire 把两件事分开：`speechrail.alignment.done` 给 `segment_uid` 与
    /// 文本/采样区间，`speechrail.diarization.*` 只给「采样区间 → 匿名说话人」。
    /// 客户端按采样区间重叠把两者合起来，`segmentUID` 仍是正文不可变、归属原位
    /// 修订的稳定坐标（`SpeakerLabeling`）。
    public struct AttributionUnit: Sendable, Equatable {
        public var segmentUID: String
        public var speaker: String?
        public var textStart: Int?
        public var textEnd: Int?
        public var audioStartSample: Int?
        public var audioEndSample: Int?
        public var timingQuality: String?
        public var granularity: String?

        public init(
            segmentUID: String,
            speaker: String? = nil,
            textStart: Int? = nil,
            textEnd: Int? = nil,
            audioStartSample: Int? = nil,
            audioEndSample: Int? = nil,
            timingQuality: String? = nil,
            granularity: String? = nil
        ) {
            self.segmentUID = segmentUID
            self.speaker = speaker
            self.textStart = textStart
            self.textEnd = textEnd
            self.audioStartSample = audioStartSample
            self.audioEndSample = audioEndSample
            self.timingQuality = timingQuality
            self.granularity = granularity
        }
    }

    /// `speechrail.diarization.*` 的一条分人区间：采样区间 → 匿名说话人。
    ///
    /// 说话人为 `nil` 表示这一段没有可用的归属（服务端明确给了 unknown）。
    public struct DiarizationSpan: Sendable, Equatable {
        public var speaker: String?
        public var startSample: Int
        public var endSample: Int

        public init(speaker: String?, startSample: Int, endSample: Int) {
            self.speaker = speaker
            self.startSample = startSample
            self.endSample = endSample
        }
    }

    public struct RealtimeSampleSpan: Sendable, Equatable {
        public let startSample: Int
        public let endSample: Int

        public init(startSample: Int, endSample: Int) {
            self.startSample = startSample
            self.endSample = endSample
        }
    }

    /// Typed hypothesis evidence already validated from the current wire event.
    /// `nil` means unknown; zero is an explicit "no proven stable prefix".
    public struct RealtimeHypothesisEvidence: Sendable, Equatable {
        public let stablePrefixCodepoints: Int?
        public let sampleSpan: RealtimeSampleSpan?

        public init(
            stablePrefixCodepoints: Int? = nil,
            sampleSpan: RealtimeSampleSpan? = nil
        ) {
            self.stablePrefixCodepoints = stablePrefixCodepoints
            self.sampleSpan = sampleSpan
        }
    }

    /// 服务端事件里**会话层真正需要的那一部分**。
    public enum Event: Sendable {
        /// `session.created`：握手完成，服务端声明了实际能力。
        case ready(model: String)
        /// `session.updated`：配置生效，可以开始喂 PCM。
        case configured
        /// 官方 append-only partial（内存态）。它是增量，调用点自己累加。
        case partial(itemID: String, delta: String)
        /// 可修订 partial 的最新全文（`speechrail.transcription.hypothesis`）。
        /// 调用点必须替换 item 文本，不得追加。
        case partialSnapshot(
            itemID: String,
            revision: Int,
            text: String,
            evidence: RealtimeHypothesisEvidence = .init()
        )
        /// 文本终态。当前 wire 的 final 只承载正文；对齐与匿名声归属**随后独立到达**，
        /// 不得等待它们、也不得用它们改写正文。
        case completed(itemID: String, transcript: String)
        case failed(itemID: String, code: String, message: String)
        /// 归属（对齐 + 分人）修订，**只改归属列**。
        ///
        /// `isFinal` 为 true 表示这是分人收口后的最后一份（`speechrail.diarization.done`）。
        case attribution(itemID: String, units: [AttributionUnit], isFinal: Bool)
        /// `speechrail.alignment.failed`：对齐拿不到证据。正文仍成功，只是没有时间码。
        case alignmentFailed(itemID: String, code: String, message: String)
        /// `speechrail.diarization.failed`：一次 active→degraded。正文继续，标签停更。
        case diarizationDegraded(code: String, message: String)
        /// TTS 音频块（24 kHz PCM16）。助手那一侧才用得上。
        case ttsAudio(requestID: String, taskID: String?, pcm: Data)
        /// 增量 utterance 已取得准入（`speechrail.tts.started`）。
        /// **收到它之前不得 append，服务端在此之前也不会发 PCM。**
        case ttsStarted(requestID: String, taskID: String?, limits: TTSStreamLimits?)
        /// 一次 append 的 ACK（`speechrail.tts.text_accepted`）。
        /// ACK 失败不推进 `appendSequence`——调用方只认这些回执推进序号。
        case ttsTextAccepted(
            requestID: String,
            taskID: String?,
            appendSequence: Int,
            totalCodepoints: Int
        )
        /// TTS 一轮结束：`speechrail.tts.completed` / `.cancelled` / `.failed`。
        /// 每次 utterance **恰好一个** terminal；失败带稳定错误码与消息。
        case ttsEnded(
            requestID: String,
            taskID: String?,
            status: String,
            code: String?,
            message: String?
        )
        /// 顶层 `error`。请求级错误带 `request_id`；会话级错误没有。
        case serverError(code: String, message: String, requestID: String?)
        /// Session-wide diarization drain barrier; it is not an item terminal.
        case diarizationFinished
        /// A recent item's auxiliary window expired. Text remains owned by the session.
        case auxiliaryIncomplete(
            itemID: String,
            alignmentMissing: Bool,
            diarizationMissing: Bool
        )
        case closed(code: Int?)
    }

    private let url: URL
    private let apiKey: String?
    private let model: String
    /// `audio.input.transcription.language`. `nil` leaves the server default.
    private let language: String?
    /// `audio.input.transcription.keywords`: proper nouns and hard terms from
    /// the current script, so the recognizer prefers the script's wording.
    private let keywords: [String]?
    /// 静音窗口由 App 的场景预设选择；服务端据此确定句末。
    private let silenceDurationMilliseconds: Int
    private let threshold: Double
    /// 分人开关（每场一次，**首个 PCM 之前**协商，之后改不了）。
    private let diarizationEnabled: Bool
    /// `session.speechrail.task`（会话层语义标签）。
    private let sessionTask: SpeechRailSessionUpdate.Task
    private let expectedASRRevision: String?
    /// 当前 caller-owned TTS voice 的 revision。随 voice 一起在连接内更新。
    private var expectedVoiceRevision: String?
    /// 当前 caller-owned voice 对应的 TTS 制品 revision。
    private var expectedTTSRevision: String?
    private let callerTTSEnabled: Bool
    /// `speechrail.tts.start` 的 task：助手会话固定 `conversation`。
    private let ttsTask: SpeechRailSessionUpdate.Task
    private let session: URLSession
    private let eventStream: RealtimeEventStream<Event>

    private var transport: (any RealtimeASRTransport)?
    private var receiveLoop: Task<Void, Never>?
    private var itemExpiryTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var didClose = false
    private var configurationAcknowledged = false
    private var configurationFailure: Failure?
    /// 下一次 caller-owned TTS request 使用的音色。
    private var voice: String?
    private var activeTTSRequestID: String?
    private var activeTTSAudioWindowBytes = SpeechRailTTSStart.maximumAudioWindowBytes
    private var activeTTSAcknowledgedSampleOffset = 0
    private var activeTTSTaskID: String?
    private var activeTTSAudioSuppressed = false
    /// 当前 request 是否已经进入增量模式（收到过 `speechrail.tts.started`）。
    private var activeTTSStreaming = false
    /// 最后一个被 ACK 的 append 序号；从 -1 起，与契约的"空输入为 -1"一致。
    private var activeTTSConsumedSequence = -1
    private var expectedAudioChunkIndex = 0
    private var expectedAudioSampleOffset = 0
    /// 因请求不匹配/序号不连续/奇数字节而被丢掉的音频块计数（诊断用）。
    public private(set) var droppedAudioChunks = 0
    /// `finish` 的 event_id。契约要求同一个 id 重试幂等、不同 id 拒绝。
    private var finishEventID: String?
    private var finishSent = false
    private var clearSent = false
    /// Cumulative 24 kHz samples sent on this connection; clear does not reset it.
    private var uploadedSampleCount = 0
    private var expectedDrainCommitEventID: String?
    private var drainReceiptReceived = false
    private var drainFailure: Failure?
    private var expectedDrainSamples = 0
    private var diarizationAcknowledged = false
    /// Per-connection item identity, revisions, and bounded auxiliary snapshots.
    private var eventState = RealtimeEventState()
    private var sequenceValidator = RealtimeSequenceValidator()
    /// Latest sequence diagnostic. The event envelope remains the source of
    /// truth; this property is only a non-sensitive convenience for session UI.
    public private(set) var sequenceStatus: RealtimeSequenceStatus = .missing
    /// Opaque server session identity and a bounded in-memory event ID window.
    /// Neither is persisted or logged.
    public private(set) var serverSessionID: String?
    public private(set) var recentEventIDs: [String] = []
    private var currentEventMetadata: RealtimeEventMetadata?
    private var currentEventReceivedAt: ContinuousClock.Instant?
    private var closeCode: Int?

    public init(
        port: Int = 8201,
        model: String = RealtimeASRClient.canonicalASRModel,
        language: String? = nil,
        keywords: [String]? = nil,
        silenceDurationMilliseconds: Int = 400,
        threshold: Double = 0.5,
        diarizationEnabled: Bool = false,
        sessionTask: SpeechRailSessionUpdate.Task = .conversation,
        voice: String? = nil,
        apiKey: String? = nil,
        session: URLSession = .shared,
        expectedASRRevision: String? = nil,
        expectedTTSRevision: String? = nil,
        expectedVoiceRevision: String? = nil,
        callerTTSEnabled: Bool = false,
        ttsTask: SpeechRailSessionUpdate.Task = .conversation,
        eventStreamLimits: RealtimeEventStream<Event>.Limits = .default
    ) {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        self.url = components.url!
        // 与 REST 走**同一处**凭据解析：服务配了 key 时，握手缺 `Authorization` 会被
        // 以 1008 关掉（契约「连接与认证」）。这里不自己读环境变量。
        self.apiKey = apiKey ?? SpeechRailAPICredentialProvider.resolve()
        self.model = model
        self.language = language
        self.keywords = keywords
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.threshold = threshold
        self.diarizationEnabled = diarizationEnabled
        self.sessionTask = sessionTask
        self.expectedASRRevision = expectedASRRevision
        self.expectedTTSRevision = expectedTTSRevision
        self.expectedVoiceRevision = expectedVoiceRevision
        self.callerTTSEnabled = callerTTSEnabled
        self.ttsTask = ttsTask
        self.voice = voice
        self.session = session
        self.eventStream = RealtimeEventStream(limits: eventStreamLimits)
    }

    /// 事件流。**只能取一次**：这条流与这条连接一一对应，多个消费者会让"谁负责写库"变得不确定。
    public func events() -> RealtimeEventStream<Event> {
        eventStream
    }

    // MARK: - 连接

    /// 建连、声明转写会话、发送 current-only 配置。返回即表示可以开始喂 PCM。
    public func connect() async throws {
        guard transport == nil else { return }
        guard !didClose else { throw Failure.closed(closeCode) }
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        try await connect(using: URLSessionRealtimeASRTransport(task: task))
    }

    func connect(using transport: any RealtimeASRTransport) async throws {
        guard self.transport == nil else { return }
        guard !didClose else { throw Failure.closed(closeCode) }
        connectionGeneration = UUID()
        eventState.reset(
            generation: connectionGeneration,
            auxiliaryExpected: diarizationEnabled
        )
        sequenceValidator.reset()
        serverSessionID = nil
        recentEventIDs.removeAll(keepingCapacity: true)
        sequenceStatus = .missing
        configurationAcknowledged = false
        configurationFailure = nil
        self.transport = transport
        await transport.resume()
        startReceiveLoop(using: transport, generation: connectionGeneration)

        // `session.update` 要在首个 PCM **之前**落地：24 kHz 格式、任务、
        // 分人与 caller-owned TTS 都在这一刻协商。
        do {
            try await send(configurationEvent())
            try await waitForConfigurationAcknowledgement()
        } catch {
            await finish(code: nil)
            throw error
        }
    }

    /// 关掉连接。调用点负责把它带来的中断写进账本（`service_lost`）。
    public func close() async {
        await finish(code: nil)
    }

    // MARK: - 上行

    /// 追加一段 24 kHz / 单声道 / PCM16。
    public func append(_ pcm: Data) async throws {
        guard !pcm.isEmpty else { return }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "event_id": UUID().uuidString,
            "audio": pcm.base64EncodedString()
        ]
        guard expectedDrainCommitEventID == nil, pcm.count.isMultiple(of: 2) else {
            throw Failure.transport("音频输入已在收尾，或音频帧不完整。")
        }
        uploadedSampleCount += pcm.count / 2
        try await send(payload)
    }

    /// 手动触发终态。`endpointing` 打开时服务端自己会在静音处提交，这一条是给
    /// "用户按了结束"用的：它保证最后半句也走完一次提交，而不是留在缓冲区里丢掉。
    @discardableResult
    public func commit(eventID: String = UUID().uuidString) async throws -> String {
        try await send(["type": "input_audio_buffer.commit", "event_id": eventID])
        return eventID
    }

    /// 只提交在途的那一句，不清缓冲、不结束分人、连接继续可用（MC-16 暂停边界）。
    ///
    /// 与 `drainAndClear` 的区别是刻意分开的：收尾走后者，因为它要把分人跑完并清空；
    /// 暂停走这里，因为暂停之后这条连接还要接着录。
    public func flushPendingUtterance() async throws {
        _ = try await commit(eventID: UUID().uuidString)
    }

    /// Discards the uncommitted input buffer. Repeating the operation on one
    /// connection is intentionally idempotent, but a new connection gets a
    /// fresh clear barrier.
    public func clear() async throws {
        guard !clearSent else { return }
        try await send(["type": "input_audio_buffer.clear", "event_id": UUID().uuidString])
        clearSent = true
    }

    /// Wait for the server to retire all preceding input, even when an older
    /// transcript terminal arrives before this barrier or input is already empty.
    public func drainAndClear(timeout: Duration = .seconds(8)) async throws {
        guard expectedDrainCommitEventID == nil else {
            throw Failure.transport("音频会话正在收尾。")
        }
        let eventID = UUID().uuidString
        expectedDrainCommitEventID = eventID
        expectedDrainSamples = uploadedSampleCount
        drainReceiptReceived = false
        drainFailure = nil
        defer { expectedDrainCommitEventID = nil }
        do {
            try await withStageTimeout(stage: .commit, timeout: timeout) {
                try await self.send([
                    "type": "input_audio_buffer.commit", "event_id": eventID,
                    "speechrail": ["request_receipt": true]
                ])
            }
            try await waitForDeclaredItems(timeout: timeout)
            if diarizationEnabled {
                try await withStageTimeout(stage: .diarization, timeout: timeout) {
                    try await self.finishDiarization()
                }
                try await waitForDiarizationAcknowledgement(timeout: timeout)
            }
            try await withStageTimeout(stage: .clear, timeout: timeout) {
                try await self.clear()
            }
        } catch {
            // An old server or lost receipt must never cause a speculative clear.
            // Closing bounds the outstanding worker/session lifetime on failure.
            await finish(code: nil)
            throw error
        }
    }

    /// 换音色。**下一次 TTS request 生效**，只影响 TTS，不进 prompt。
    /// voice 没有可验证 revision 时必须传 nil，以免沿用旧音色的 pin。
    public func updateVoice(
        _ voice: String,
        expectedVoiceRevision: String? = nil,
        expectedTTSRevision: String? = nil
    ) async throws {
        self.voice = voice
        self.expectedVoiceRevision = expectedVoiceRevision
        self.expectedTTSRevision = expectedTTSRevision
    }

    /// 开始一次增量 utterance（契约 §3.3.1）。
    ///
    /// 返回只表示 `speechrail.tts.start` 已发出；必须等到 `.ttsStarted` 才能 append。
    /// 文本、序列号、ACK 等待和打断都归调用方（`AssistantTTSStreamCoordinator`）。
    public func startTTSStream(
        requestID: String, speed: Double? = nil,
        audioWindowBytes: Int = SpeechRailTTSStart.maximumAudioWindowBytes
    ) async throws {
        guard (2...SpeechRailTTSStart.maximumAudioWindowBytes).contains(audioWindowBytes),
              audioWindowBytes.isMultiple(of: 2) else {
            throw Failure.transport("朗读缓冲容量无效")
        }
        activeTTSRequestID = requestID
        activeTTSAudioWindowBytes = audioWindowBytes
        activeTTSAcknowledgedSampleOffset = 0
        activeTTSTaskID = nil
        activeTTSAudioSuppressed = false
        activeTTSStreaming = false
        activeTTSConsumedSequence = -1
        expectedAudioChunkIndex = 0
        expectedAudioSampleOffset = 0
        guard let voice, !voice.isEmpty else {
            clearActiveTTS()
            throw Failure.transport("没有可用的朗读音色")
        }
        do {
            try await send(
                SpeechRailTTSStart(
                    requestID: requestID,
                    task: ttsTask,
                    voice: voice,
                    speed: speed,
                    voiceRevision: expectedVoiceRevision,
                    expectedModelRevision: expectedTTSRevision,
                    audioWindowBytes: audioWindowBytes
                ).jsonObject
            )
        } catch {
            if activeTTSRequestID == requestID { clearActiveTTS() }
            throw error
        }
    }

    /// 往当前 utterance 追加一段已经稳定的文本。
    public func appendTTSText(_ text: String, sequence: Int) async throws {
        guard let requestID = activeTTSRequestID else {
            throw Failure.transport("没有活动的 TTS utterance")
        }
        try await send(
            SpeechRailTTSAppendText(
                requestID: requestID,
                sequence: sequence,
                text: text
            ).jsonObject
        )
    }

    /// 关闭文本输入。`lastSequence` 必须是最后一次 ACK 的序号；空输入为 `-1`。
    public func finishTTSText(lastSequence: Int) async throws {
        guard let requestID = activeTTSRequestID else {
            throw Failure.transport("没有活动的 TTS utterance")
        }
        try await send(
            SpeechRailTTSFinishText(
                requestID: requestID,
                lastSequence: lastSequence
            ).jsonObject
        )
    }

    /// 取消正在合成的 TTS（用户插话）。未发送的音频由服务端丢弃。
    public func cancelTTS() async throws {
        guard let requestID = activeTTSRequestID else { return }
        // 用户侧停止优先：取消确认在途期间即使服务端再发 delta，也不能进入播放层。
        activeTTSAudioSuppressed = true
        try await send(
            SpeechRailTTSCancel(requestID: requestID).jsonObject
        )
    }

    /// Return consumption credits for exactly this request. Final callbacks after
    /// a terminal and stale callbacks cannot grant credits to the next request.
    public func acknowledgeTTSAudio(requestID: String, sampleOffset: Int) async throws {
        guard requestID == activeTTSRequestID, !activeTTSAudioSuppressed else { return }
        guard sampleOffset > activeTTSAcknowledgedSampleOffset,
              sampleOffset <= expectedAudioSampleOffset
        else { return }
        activeTTSAcknowledgedSampleOffset = sampleOffset
        try await send(SpeechRailTTSAudioAck(requestID: requestID, sampleOffset: sampleOffset).jsonObject)
    }

    /// 推流结束时的分人 EOF 屏障：等水位对齐再封存，末段不丢（§14.3）。
    ///
    /// 只在协商过分人的会话上调用。同一个 `event_id` 重试是幂等的——所以重试安全。
    public func finishDiarization() async throws {
        guard diarizationEnabled, !finishSent else { return }
        let id = finishEventID ?? UUID().uuidString
        finishEventID = id
        try await send(["type": "speechrail.diarization.finish", "event_id": id])
        finishSent = true
    }

    private func send(_ payload: [String: Any]) async throws {
        guard let transport else { throw Failure.transport("连接还没建立") }
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else {
            throw Failure.transport("事件没能编码成 JSON")
        }
        do {
            try await transport.send(text)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    /// 转写会话的配置。形状对着服务端的 current-only 解析写：
    /// `session.audio.input.format` 固定 24 kHz `audio/pcm`，转写模型位于
    /// `session.audio.input.transcription`，SpeechRail 扩展位于 `session.speechrail`。
    ///
    /// 分人按 `session.speechrail.diarization.enabled` opt-in，**只能在这里声明一次**：
    /// 首个 PCM 之后再协商，服务端按契约回 `invalid_state`（§14.3 的开关粒度）。
    /// 分人需要「采样区间 → 说话人」与「文本 → 采样区间」两半，所以同批打开
    /// `speechrail.alignment`（服务端的对齐器是分人的既有前置条件）。
    private func configurationEvent() -> [String: Any] {
        SpeechRailSessionUpdate(
            model: model,
            task: sessionTask,
            language: language,
            keywords: keywords,
            endpointing: SpeechRailSessionUpdate.Endpointing(
                threshold: threshold,
                silenceDurationMilliseconds: silenceDurationMilliseconds
            ),
            ttsEnabled: callerTTSEnabled,
            alignment: SpeechRailSessionUpdate.Alignment(
                enabled: diarizationEnabled,
                granularity: diarizationEnabled ? "segment" : nil
            ),
            diarizationEnabled: diarizationEnabled,
            expectedASRRevision: expectedASRRevision
        ).jsonObject
    }

    private func withStageTimeout<T: Sendable>(
        stage: RealtimeDrainStage,
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.drainTimedOut(stage)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func waitForConfigurationAcknowledgement(
        timeout: Duration = .seconds(8)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if configurationAcknowledged {
                return
            }
            if let configurationFailure {
                throw configurationFailure
            }
            if didClose {
                throw Failure.closed(closeCode)
            }
            guard clock.now < deadline else {
                throw Failure.transport("语音服务没有在期限内确认转写配置。")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Wait for the precise command receipt, not an unrelated transcript terminal.
    private func waitForDeclaredItems(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if didClose {
                throw Failure.closed(closeCode)
            }
            if let drainFailure { throw drainFailure }
            if drainReceiptReceived {
                return
            }
            guard clock.now < deadline else {
                throw Failure.drainTimedOut(.terminalItems)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForDiarizationAcknowledgement(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if didClose {
                throw Failure.closed(closeCode)
            }
            if diarizationAcknowledged {
                return
            }
            guard clock.now < deadline else {
                throw Failure.drainTimedOut(.diarization)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - 下行

    private func startReceiveLoop(
        using transport: any RealtimeASRTransport,
        generation: UUID
    ) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await transport.receive()
                    await self?.handle(message, generation: generation)
                } catch {
                    await self?.finish(code: await transport.closeCode())
                    return
                }
            }
        }
    }

    private func handle(
        _ message: RealtimeASRSocketFrame,
        generation: UUID
    ) async {
        guard !didClose, generation == connectionGeneration else { return }
        let data: Data
        switch message {
        case .text(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        case .unsupported: return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            await rejectProtocolEvent(code: "invalid_server_event")
            return
        }
        guard let type = object["type"] as? String, !type.isEmpty else {
            await rejectProtocolEvent(code: "invalid_server_event")
            return
        }
        let metadata = RealtimeEventMetadata(
            eventID: object["event_id"] as? String,
            sessionID: object["session_id"] as? String,
            sequence: Self.int(object["sequence"])
        )
        sequenceStatus = sequenceValidator.accept(metadata)
        guard sequenceStatus.isAccepted else {
            await rejectProtocolEvent(code: "realtime_protocol_violation")
            return
        }
        serverSessionID = metadata.sessionID
        recentEventIDs = sequenceValidator.recentEventIDs
        currentEventMetadata = metadata
        let receivedAt = ContinuousClock().now
        currentEventReceivedAt = receivedAt
        eventState.prune(now: receivedAt)
        await flushExpiredItems()
        guard !didClose, generation == connectionGeneration else { return }
        defer {
            currentEventMetadata = nil
            currentEventReceivedAt = nil
        }
        switch type {
        case "session.created":
            let model = (object["session"] as? [String: Any])?["model"] as? String ?? self.model
            await emit(.ready(model: model))
        case "session.updated":
            await emit(.configured)
            if !didClose {
                configurationAcknowledged = true
            }
        case "conversation.item.input_audio_transcription.delta":
            let itemID = object["item_id"] as? String ?? ""
            guard !itemID.isEmpty else {
                await rejectProtocolEvent(code: "invalid_server_event")
                return
            }
            let delta = object["delta"] as? String ?? ""
            guard eventState.observeDelta(
                itemID: itemID,
                delta: delta,
                sessionID: metadata.sessionID!,
                generation: generation,
                now: currentEventReceivedAt!
            ) else {
                if await rejectItemStateLimitIfNeeded() { return }
                break
            }
            if eventState.hasHypothesis(itemID: itemID) {
                break
            }
            await flushExpiredItems()
            await emit(
                .partial(
                    itemID: itemID,
                    delta: delta
                )
            )
        case "speechrail.input_audio_buffer.committed":
            guard let expectedDrainCommitEventID,
                  object["commit_event_id"] as? String == expectedDrainCommitEventID else { break }
            guard let samples = object["accepted_samples"] as? NSNumber,
                  CFGetTypeID(samples) != CFBooleanGetTypeID(),
                  samples.doubleValue.isFinite,
                  samples.doubleValue >= 0, samples.doubleValue < Double(Int.max),
                  samples.doubleValue.rounded(.towardZero) == samples.doubleValue,
                  samples.int64Value == Int64(expectedDrainSamples) else {
                await rejectProtocolEvent(code: "invalid_commit_receipt")
                return
            }
            drainReceiptReceived = true
        case "speechrail.transcription.hypothesis":
            // 官方 `delta` 是可证明的稳定前缀；hypothesis 是**可改写全文**。两者分开解码，
            // 调用点用整段替换而不是追加（契约 §5.1）。
            let itemID = object["utterance_id"] as? String ?? ""
            let taskID = object["task_id"] as? String ?? ""
            let epoch = Self.int(object["epoch"])
            guard let revision = Self.int(object["revision"]), revision > 0,
                  let text = object["text"] as? String else {
                await emit(.failed(itemID: itemID, code: "invalid_hypothesis", message: "流式转写快照格式无效"))
                return
            }
            let stablePrefixCodepoints: Int?
            if let rawStablePrefix = object["stable_prefix_codepoints"] {
                guard let value = Self.int(rawStablePrefix),
                      value >= 0,
                      value <= text.unicodeScalars.count else {
                    await emit(
                        .failed(
                            itemID: itemID,
                            code: "invalid_hypothesis",
                            message: "稳定前缀超出当前快照范围"
                        )
                    )
                    return
                }
                stablePrefixCodepoints = value
            } else {
                stablePrefixCodepoints = nil
            }
            let sampleSpan: RealtimeSampleSpan?
            if let rawSampleSpan = object["sample_span"] {
                guard let value = Self.span(rawSampleSpan) else {
                    await emit(
                        .failed(
                            itemID: itemID,
                            code: "invalid_hypothesis",
                            message: "采样范围格式无效"
                        )
                    )
                    return
                }
                sampleSpan = .init(startSample: value.start, endSample: value.end)
            } else {
                sampleSpan = nil
            }
            guard !itemID.isEmpty, let epoch else { break }
            guard eventState.acceptHypothesis(
                    itemID: itemID,
                    taskID: taskID,
                    epoch: epoch,
                    revision: revision,
                    text: text,
                    sessionID: metadata.sessionID!,
                    generation: generation,
                    now: currentEventReceivedAt!
                  ) else {
                if await rejectItemStateLimitIfNeeded() { return }
                break
            }
            await flushExpiredItems()
            await emit(
                .partialSnapshot(
                    itemID: itemID,
                    revision: revision,
                    text: text,
                    evidence: .init(
                        stablePrefixCodepoints: stablePrefixCodepoints,
                        sampleSpan: sampleSpan
                    )
                )
            )
        case "conversation.item.input_audio_transcription.completed":
            let itemID = object["item_id"] as? String ?? ""
            let transcript = object["transcript"] as? String ?? ""
            guard !itemID.isEmpty else { break }
            guard eventState.complete(
                    itemID: itemID,
                    transcript: transcript,
                    sessionID: metadata.sessionID!,
                    generation: generation,
                    now: currentEventReceivedAt!
                  ) else {
                if await rejectItemStateLimitIfNeeded() { return }
                break
            }
            await flushExpiredItems()
            await emit(.completed(itemID: itemID, transcript: transcript))
        case "conversation.item.input_audio_transcription.failed":
            let itemID = object["item_id"] as? String ?? ""
            guard !itemID.isEmpty,
                  eventState.failText(
                    itemID: itemID,
                    sessionID: metadata.sessionID!,
                    generation: generation,
                    now: currentEventReceivedAt!
                  )
            else { break }
            let error = object["error"] as? [String: Any]
            await flushExpiredItems()
            await emit(
                .failed(
                    itemID: itemID,
                    code: error?["code"] as? String ?? object["code"] as? String ?? "backend_error",
                    message: error?["message"] as? String ?? object["message"] as? String ?? "流式转写失败"
                )
            )
        case "speechrail.alignment.done":
            guard let itemID = object["utterance_id"] as? String,
                  let taskID = object["task_id"] as? String,
                  let epoch = Self.int(object["epoch"]),
                  let transcriptRevision = Self.int(object["transcript_revision"]),
                  let metadataRevision = Self.int(object["metadata_revision"]),
                  let sampleSpan = Self.span(object["sample_span"]),
                  let codepointSpan = Self.span(object["codepoint_span"]),
                  let units = Self.alignmentUnitsStrict(object["units"])
            else { break }
            guard eventState.applyAlignment(
                    itemID: itemID,
                    taskID: taskID,
                    epoch: epoch,
                    transcriptRevision: transcriptRevision,
                    metadataRevision: metadataRevision,
                    sampleSpan: sampleSpan,
                    codepointSpan: codepointSpan,
                    units: units,
                    sessionID: metadata.sessionID!,
                    generation: generation,
                    now: currentEventReceivedAt!
                  ) else {
                if await rejectItemStateLimitIfNeeded() { return }
                break
            }
            await flushExpiredItems()
            await emit(attribution(itemID: itemID, isFinal: false))
        case "speechrail.alignment.failed":
            let itemID = object["utterance_id"] as? String ?? ""
            guard let taskID = object["task_id"] as? String,
                  let epoch = Self.int(object["epoch"]),
                  let transcriptRevision = Self.int(object["transcript_revision"]),
                  let metadataRevision = Self.int(object["metadata_revision"]),
                  eventState.acceptAlignmentFailure(
                    itemID: itemID,
                    taskID: taskID,
                    epoch: epoch,
                    transcriptRevision: transcriptRevision,
                    metadataRevision: metadataRevision,
                    sessionID: metadata.sessionID!,
                    generation: generation,
                    now: currentEventReceivedAt!
                  )
            else { break }
            let error = object["error"] as? [String: Any]
            await emit(
                .alignmentFailed(
                    itemID: itemID,
                    code: error?["code"] as? String ?? "alignment_failed",
                    message: error?["message"] as? String ?? "对齐没有拿到时间证据。"
                )
            )
        case "speechrail.diarization.updated":
            guard let itemID = object["utterance_id"] as? String,
                  let taskID = object["task_id"] as? String,
                  let epoch = Self.int(object["epoch"]),
                  let transcriptRevision = Self.int(object["transcript_revision"]),
                  let metadataRevision = Self.int(object["metadata_revision"]),
                  let spans = Self.diarizationSpansStrict(object["units"])
            else { break }
            guard eventState.applyDiarization(
                    itemID: itemID,
                    taskID: taskID,
                    epoch: epoch,
                    transcriptRevision: transcriptRevision,
                    metadataRevision: metadataRevision,
                    spans: spans,
                    sessionID: metadata.sessionID!,
                    generation: generation,
                    now: currentEventReceivedAt!
                  ) else {
                if await rejectItemStateLimitIfNeeded() { return }
                break
            }
            await flushExpiredItems()
            await emit(attribution(itemID: itemID, isFinal: false))
        case "speechrail.diarization.done":
            guard let itemID = object["utterance_id"] as? String,
                  let taskID = object["task_id"] as? String,
                  let epoch = Self.int(object["epoch"]),
                  let transcriptRevision = Self.int(object["transcript_revision"]),
                  let metadataRevision = Self.int(object["metadata_revision"]),
                  let spans = Self.diarizationSpansStrict(object["units"]),
                  eventState.acceptSessionEvent(
                    taskID: taskID,
                    epoch: epoch,
                    sessionID: metadata.sessionID!,
                    generation: generation,
                    now: currentEventReceivedAt!
                  )
            else { break }
            diarizationAcknowledged = true
            if eventState.applyDiarization(
                itemID: itemID,
                taskID: taskID,
                epoch: epoch,
                transcriptRevision: transcriptRevision,
                metadataRevision: metadataRevision,
                spans: spans,
                sessionID: metadata.sessionID!,
                generation: generation,
                now: currentEventReceivedAt!
            ) {
                await emit(attribution(itemID: itemID, isFinal: false))
            } else if await rejectItemStateLimitIfNeeded() {
                return
            }
            await emit(.diarizationFinished)
        case "speechrail.diarization.failed":
            guard let taskID = object["task_id"] as? String,
                  let epoch = Self.int(object["epoch"]),
                  eventState.acceptSessionEvent(
                    taskID: taskID,
                    epoch: epoch,
                    sessionID: metadata.sessionID!,
                    generation: generation,
                    now: currentEventReceivedAt!
                  )
            else { break }
            let error = object["error"] as? [String: Any]
            await emit(
                .diarizationDegraded(
                    code: error?["code"] as? String ?? "diarization_degraded",
                    message: error?["message"] as? String ?? "说话人编号停止更新了。"
                )
            )
        case "speechrail.tts.started":
            guard
                let started = TTSSessionStarted(object: object),
                started.requestID == activeTTSRequestID
            else { break }
            guard started.audioWindowBytes == activeTTSAudioWindowBytes else {
                await emit(
                    .ttsEnded(
                        requestID: started.requestID, taskID: started.taskID, status: "failed",
                        code: "tts_audio_window_mismatch",
                        message: "语音服务确认的朗读缓冲容量与请求不一致。"
                    )
                )
                clearActiveTTS()
                break
            }
            // 播放层只认 canonical 24 kHz / mono PCM16。服务端协商出别的格式时明确失败，
            // 不把未协商的字节当 24k 喂给播放器（§6 第 3 条）。
            guard started.sampleRate == TTSAudioPosition.canonicalSampleRate,
                  started.channels == 1 else {
                await emit(
                    .ttsEnded(
                        requestID: started.requestID,
                        taskID: started.taskID,
                        status: "failed",
                        code: "unsupported_output_format",
                        message: "语音服务给出的输出格式不是 24 kHz 单声道。"
                    )
                )
                clearActiveTTS()
                break
            }
            activeTTSTaskID = started.taskID
            activeTTSStreaming = true
            expectedAudioChunkIndex = 0
            expectedAudioSampleOffset = 0
            await emit(
                .ttsStarted(
                    requestID: started.requestID,
                    taskID: started.taskID,
                    limits: started.limits
                )
            )
        case "speechrail.tts.text_accepted":
            guard
                let accepted = TTSTextAccepted(object: object),
                accepted.requestID == activeTTSRequestID,
                accepted.appendSequence == activeTTSConsumedSequence + 1
            else { break }
            activeTTSConsumedSequence = accepted.appendSequence
            await emit(
                .ttsTextAccepted(
                    requestID: accepted.requestID,
                    taskID: accepted.taskID,
                    appendSequence: accepted.appendSequence,
                    totalCodepoints: accepted.totalCodepoints
                )
            )
        case "speechrail.tts.audio.delta":
            // 旧 request、取消后的迟到块、身份不符的块：静默隔离，不进播放层。
            guard
                let requestID = activeTTSRequestID,
                object["request_id"] as? String == requestID,
                !activeTTSAudioSuppressed
            else { break }
            guard
                let base64 = object["delta"] as? String,
                let data = Data(base64Encoded: base64),
                !data.isEmpty,
                data.count.isMultiple(of: MemoryLayout<Int16>.size)
            else {
                droppedAudioChunks += 1
                break
            }
            if activeTTSStreaming, !acceptAudioPosition(object: object, pcmBytes: data.count) {
                droppedAudioChunks += 1
                break
            }
            await emit(
                .ttsAudio(requestID: requestID, taskID: activeTTSTaskID, pcm: data),
                decodedAudioBytes: data.count
            )
        case "speechrail.tts.completed", "speechrail.tts.cancelled", "speechrail.tts.failed":
            guard
                let requestID = object["request_id"] as? String,
                requestID == activeTTSRequestID
            else { break }
            let status: String
            var code: String?
            var message: String?
            switch type {
            case "speechrail.tts.completed":
                status = "completed"
            case "speechrail.tts.cancelled":
                status = "cancelled"
            default:
                status = "failed"
                let error = object["error"] as? [String: Any]
                code = error?["code"] as? String ?? "tts_failed"
                message = error?["message"] as? String ?? "这一轮朗读失败了。"
            }
            await emit(
                .ttsEnded(
                    requestID: requestID,
                    taskID: activeTTSTaskID ?? object["task_id"] as? String,
                    status: status,
                    code: code,
                    message: message
                )
            )
            clearActiveTTS()
        case "error":
            let error = object["error"] as? [String: Any]
            let errorMessage = error?["message"] as? String ?? "语音服务返回了一个错误"
            if let expectedDrainCommitEventID,
               error?["event_id"] as? String == expectedDrainCommitEventID {
                drainFailure = .transport(errorMessage)
            }
            if !configurationAcknowledged {
                configurationFailure = .transport(errorMessage)
            }
            let requestID = error?["request_id"] as? String ?? object["request_id"] as? String
            if let requestID, requestID == activeTTSRequestID {
                clearActiveTTS()
            }
            await emit(
                .serverError(
                    code: error?["code"] as? String ?? error?["type"] as? String ?? "unknown",
                    message: errorMessage,
                    requestID: requestID
                )
            )
        default:
            // 其余事件不属于这一层：不报错，也不记日志。
            break
        }
        scheduleItemExpiry()
    }

    private func scheduleItemExpiry() {
        guard !didClose, itemExpiryTask == nil else { return }
        let generation = connectionGeneration
        itemExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.nextItemExpiryDelay(generation: generation) else {
                    break
                }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    break
                }
                await self?.expireItems(generation: generation)
            }
            await self?.finishItemExpiryLoop(generation: generation)
        }
    }

    private func nextItemExpiryDelay(generation: UUID) -> Duration? {
        guard !didClose, generation == connectionGeneration else { return nil }
        return eventState.nextExpiryDelay(now: ContinuousClock().now)
    }

    private func expireItems(generation: UUID) async {
        guard !didClose, generation == connectionGeneration else { return }
        eventState.prune(now: ContinuousClock().now)
        await flushExpiredItems()
    }

    private func finishItemExpiryLoop(generation: UUID) {
        guard generation == connectionGeneration else { return }
        itemExpiryTask = nil
    }

    private func rejectProtocolEvent(code: String, message: String? = nil) async {
        guard !didClose else { return }
        let message = message ?? "语音服务事件顺序或身份无效，已关闭当前连接。"
        if !configurationAcknowledged {
            configurationFailure = .transport(message)
        }
        await emit(.serverError(code: code, message: message, requestID: nil))
        await finish(code: nil)
    }

    private func rejectItemStateLimitIfNeeded() async -> Bool {
        guard let violation = eventState.takeLimitViolation() else { return false }
        await rejectProtocolEvent(
            code: "realtime_item_state_overflow",
            message: violation.message
        )
        return true
    }

    /// 把对齐单元与分人区间按采样重叠合起来，交给会话层（§5.2）。
    private func attribution(itemID: String, isFinal: Bool) -> Event {
        guard let snapshot = eventState.snapshot(itemID: itemID) else {
            return .attribution(itemID: itemID, units: [], isFinal: false)
        }
        return .attribution(
            itemID: itemID,
            units: Self.mergedAttributionUnits(snapshot),
            isFinal: isFinal
        )
    }

    private static func mergedAttributionUnits(
        _ snapshot: RealtimeEventState.Snapshot
    ) -> [AttributionUnit] {
        snapshot.alignmentUnits.map { unit -> AttributionUnit in
            var updated = unit
            if let start = unit.audioStartSample, let end = unit.audioEndSample, end > start {
                updated.speaker = Self.speaker(
                    forStart: start,
                    end: end,
                    spans: snapshot.diarizationSpans
                )
            }
            return updated
        }
    }

    /// 取与 `[start, end)` 重叠最多的分人区间的说话人（没有重叠就是 `nil`）。
    private static func speaker(forStart start: Int, end: Int, spans: [DiarizationSpan]) -> String? {
        var best: (overlap: Int, speaker: String?)?
        for span in spans {
            let overlap = min(end, span.endSample) - max(start, span.startSample)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap {
                best = (overlap, span.speaker)
            }
        }
        return best?.speaker
    }

    /// `speechrail.alignment.done.units`：拒绝半份或不符合 schema 的位置单元。
    private static func alignmentUnitsStrict(_ value: Any?) -> [AttributionUnit]? {
        guard let items = value as? [[String: Any]] else { return nil }
        var result: [AttributionUnit] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard
                let uid = item["segment_uid"] as? String,
                !uid.isEmpty,
                let textStart = int(item["text_start"]),
                let textEnd = int(item["text_end"]),
                let audioStart = int(item["audio_start_sample"]),
                let audioEnd = int(item["audio_end_sample"]),
                let timingQuality = item["timing_quality"] as? String,
                let granularity = item["granularity"] as? String
            else { return nil }
            result.append(
                AttributionUnit(
                    segmentUID: uid,
                    textStart: textStart,
                    textEnd: textEnd,
                    audioStartSample: audioStart,
                    audioEndSample: audioEnd,
                    timingQuality: timingQuality,
                    granularity: granularity
                )
            )
        }
        return result
    }

    /// `speechrail.diarization.updated/done.units`：采样区间 → 匿名说话人（可空）。
    private static func diarizationSpansStrict(_ value: Any?) -> [DiarizationSpan]? {
        guard let items = value as? [[String: Any]] else { return nil }
        var result: [DiarizationSpan] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard let span = Self.span(item["sample_span"]) else { return nil }
            let speaker: String?
            if let value = item["speaker"] as? String {
                speaker = value.isEmpty ? nil : value
            } else if item["speaker"] is NSNull {
                speaker = nil
            } else {
                return nil
            }
            result.append(
                DiarizationSpan(
                    speaker: speaker,
                    startSample: span.start,
                    endSample: span.end
                )
            )
        }
        return result
    }

    private static func span(_ value: Any?) -> RealtimeEventState.Range? {
        guard let object = value as? [String: Any],
              let start = int(object["start"]),
              let end = int(object["end"]),
              start >= 0,
              end >= start
        else { return nil }
        return RealtimeEventState.Range(start: start, end: end)
    }

    private func flushExpiredItems() async {
        for expired in eventState.takeExpired() {
            await emit(
                .attribution(
                    itemID: expired.itemID,
                    units: Self.mergedAttributionUnits(expired.snapshot),
                    isFinal: false
                )
            )
            await emit(
                .auxiliaryIncomplete(
                    itemID: expired.itemID,
                    alignmentMissing: expired.snapshot.alignmentUnits.isEmpty,
                    diarizationMissing: expired.snapshot.diarizationSpans.isEmpty
                )
            )
            if didClose { return }
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// 增量 PCM 的块序号与 sample offset 必须严格连续。输出格式由 `started.output_format`
    /// 协商（只接受 canonical 24 kHz / mono PCM16）；不合格的块宁可丢掉，
    /// 也不能把错位音频拼进同一轮播放缓冲。
    private func acceptAudioPosition(object: [String: Any], pcmBytes: Int) -> Bool {
        guard let position = TTSAudioPosition(object: object) else { return false }
        guard
            position.chunkIndex == expectedAudioChunkIndex,
            position.sampleOffset == expectedAudioSampleOffset
        else { return false }
        expectedAudioChunkIndex += 1
        expectedAudioSampleOffset = position.nextSampleOffset(pcmBytes: pcmBytes)
        return true
    }

    /// 清空当前 TTS 关联。**只有身份匹配的调用方才该调用它**，
    /// 否则旧 response 的迟到终态会抹掉新一轮的状态。
    private func clearActiveTTS() {
        activeTTSRequestID = nil
        activeTTSTaskID = nil
        activeTTSAudioSuppressed = false
        activeTTSStreaming = false
        activeTTSConsumedSequence = -1
        expectedAudioChunkIndex = 0
        expectedAudioSampleOffset = 0
    }

    private func emit(_ event: Event, decodedAudioBytes: Int = 0) async {
        guard !didClose else { return }
        let envelope = RealtimeEventEnvelope(
            metadata: currentEventMetadata ?? RealtimeEventMetadata(),
            payload: event,
            receivedAt: currentEventReceivedAt ?? ContinuousClock().now
        )
        let result = await eventStream.yield(
            envelope,
            decodedAudioBytes: decodedAudioBytes
        )
        guard result == .overflow else { return }

        let message = "语音事件积压超过本地安全上限，已关闭当前连接。"
        if !configurationAcknowledged {
            configurationFailure = .transport(message)
        }
        let terminalMetadata = RealtimeEventMetadata()
        let now = ContinuousClock().now
        await finish(
            code: nil,
            terminalEvents: [
                RealtimeEventEnvelope(
                    metadata: terminalMetadata,
                    payload: .serverError(
                        code: "realtime_event_stream_overflow",
                        message: message,
                        requestID: nil
                    ),
                    receivedAt: now
                ),
                RealtimeEventEnvelope(
                    metadata: terminalMetadata,
                    payload: .closed(code: nil),
                    receivedAt: now
                )
            ],
            discardPending: true
        )
    }

    /// 只收尾一次：接收循环、显式 `close()`、以及流被取消这三条路都会走到这里。
    private func finish(
        code: Int?,
        terminalEvents: [RealtimeEventEnvelope<Event>]? = nil,
        discardPending: Bool = false
    ) async {
        guard !didClose else { return }
        didClose = true
        closeCode = code
        receiveLoop?.cancel()
        receiveLoop = nil
        itemExpiryTask?.cancel()
        itemExpiryTask = nil
        connectionGeneration = UUID()
        eventState.clear()
        let transport = self.transport
        self.transport = nil
        activeTTSRequestID = nil
        activeTTSTaskID = nil
        activeTTSAudioSuppressed = true
        await transport?.cancel()
        let terminals = terminalEvents ?? [
            RealtimeEventEnvelope(
                metadata: RealtimeEventMetadata(),
                payload: .closed(code: code)
            )
        ]
        await eventStream.finish(
            terminalEvents: terminals,
            discardPending: discardPending
        )
    }
}
