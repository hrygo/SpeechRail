import Foundation
import CryptoKit
import SpeechRailControlKit

/// Bounded atomic projection; no database, clock, transport, or user-edit side effects.
public struct TranscriptWindowLedger: Sendable {
    public struct Binding: Sendable, Equatable {
        public let recordID: String
        public let connectionID: UUID
        public let generation: Int
        public init(recordID: String, connectionID: UUID, generation: Int) {
            self.recordID = recordID; self.connectionID = connectionID; self.generation = generation
        }
    }
    public enum Admission: Sendable, Equatable { case snapshot, seal, failure, duplicate, rejected }
    public private(set) var units: [TranscriptWindowUnit] = []
    public private(set) var sealedThrough = 0
    public private(set) var revision = -1
    public private(set) var latestTransaction: TranscriptWindowEvent?
    public var visibleText: String { units.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
    public var retainedFingerprints: Int { fingerprints.count }
    private let binding: Binding
    private var sessionID: String?
    private var windowID: String?
    private var epoch: Int?
    private var fingerprints: [Int: Data] = [:]
    private var fingerprintOrder: [Int] = []
    private var terminalItems: [String: String] = [:]
    private var failedTerminalIDs: Set<String> = []
    public private(set) var failedItemsCount = 0
    private var terminalOrder: [String] = []
    public init(binding: Binding) { self.binding = binding }

    @discardableResult
    public mutating func apply(_ event: TranscriptWindowEvent, binding candidate: Binding) -> Admission {
        guard candidate == binding, validID(event.sessionID), validID(event.windowID),
              validInteger(event.inputEpoch), validInteger(event.windowRevision), event.audioSpan.isValid,
              event.sealedThroughSample >= sealedThrough,
              event.audioSpan.end >= event.sealedThroughSample,
              sessionID == nil || sessionID == event.sessionID,
              windowID == nil || windowID == event.windowID,
              epoch == nil || epoch == event.inputEpoch else { return .rejected }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(event), encoded.count <= 256 * 1024 else { return .rejected }
        let fingerprint = Data(SHA256.hash(data: encoded))
        if let old = fingerprints[event.windowRevision] { return old == fingerprint ? .duplicate : .rejected }
        guard event.windowRevision > revision else { return .rejected }
        let next: [TranscriptWindowUnit]
        let admission: Admission
        if event.type == .updated {
            guard event.sealedThroughSample == sealedThrough, event.audioSpan.start == sealedThrough,
                  let snapshot = event.units, validUnits(snapshot, within: event.audioSpan, final: false)
            else { return .rejected }
            guard validRevisions(snapshot) else { return .rejected }
            next = snapshot; admission = .snapshot
        } else {
            let final = event.finalUnits ?? []
            guard let closed = event.closedSpan, closed.isValid, closed.start == sealedThrough,
                  closed.end > closed.start, closed.end == event.sealedThroughSample,
                  event.audioSpan.contains(closed), let tx = event.transactionID, validID(tx),
                  event.type == .failed ? event.finalUnits == nil : event.finalUnits != nil,
                  validUnits(final, within: closed, final: true),
                  let remaining = event.remainingUnits,
                  validUnits(remaining, within: .init(start: closed.end, end: event.audioSpan.end), final: false),
                  validRevisions(final), validRevisions(remaining),
                  let coverage = event.coverage, coverage.count <= 96,
                  Set(final.map(\.unitID)).isDisjoint(with: Set(remaining.map(\.unitID)))
            else { return .rejected }
            let failed = event.failedItems ?? []
            guard failed.count <= 32, event.type == .failed || failed.isEmpty,
                  Set(final.compactMap(\.itemID) + failed.map(\.itemID)).count == final.count + failed.count
            else { return .rejected }
            var expected: [String: TranscriptWindowSpan] = [:]
            for unit in final {
                guard let item = unit.itemID, terminalItems[item] == nil else { return .rejected }
                expected[item] = unit.ownedSpan
            }
            for item in failed {
                guard validID(item.itemID), validID(item.reason), closed.contains(item.ownedSpan),
                      item.ownedSpan.end > item.ownedSpan.start,
                      item.recoveryText.unicodeScalars.count <= 8192, terminalItems[item.itemID] == nil
                else { return .rejected }
                expected[item.itemID] = item.ownedSpan
            }
            var cursor = closed.start
            for part in coverage {
                guard part.span.isValid, part.span.start == cursor, part.span.end > cursor,
                      part.span.end <= closed.end else { return .rejected }
                if part.outcome == .silence {
                    guard part.itemID == nil, part.reason == "vad_not_admitted" else { return .rejected }
                } else {
                    guard let item = part.itemID, expected.removeValue(forKey: item) == part.span,
                          part.outcome == .speech ? final.contains(where: { $0.itemID == item })
                            : failed.contains(where: { $0.itemID == item }) else { return .rejected }
                }
                cursor = part.span.end
            }
            guard cursor == closed.end, expected.isEmpty else { return .rejected }
            for unit in final { rememberTerminal(unit.itemID!, text: unit.text) }
            for item in failed { rememberTerminal(item.itemID, text: item.recoveryText, failed: true) }
            next = remaining; admission = event.type == .failed ? .failure : .seal
        }
        // No mutation before every field, range and complete coverage has passed.
        units = next; sealedThrough = event.sealedThroughSample; revision = event.windowRevision
        sessionID = event.sessionID; windowID = event.windowID; epoch = event.inputEpoch
        if event.type != .updated { latestTransaction = event }
        fingerprints[event.windowRevision] = fingerprint; fingerprintOrder.append(event.windowRevision)
        if fingerprintOrder.count > 64 { fingerprints.removeValue(forKey: fingerprintOrder.removeFirst()) }
        return admission
    }
    public func matchesTerminal(itemID: String, text: String) -> Bool { terminalItems[itemID] == text }
    public func matchesFailure(itemID: String) -> Bool { failedTerminalIDs.contains(itemID) }
    private func validID(_ value: String) -> Bool { (1...128).contains(value.unicodeScalars.count) }
    private func validInteger(_ value: Int) -> Bool { (0...9_007_199_254_740_991).contains(value) }
    private func validRevisions(_ candidates: [TranscriptWindowUnit]) -> Bool {
        candidates.allSatisfy { unit in
            guard let old = units.first(where: { $0.unitID == unit.unitID }) else { return true }
            return unit.textRevision >= old.textRevision
                && (unit.textRevision != old.textRevision || unit.text == old.text)
                && unit.ownedSpan.start == old.ownedSpan.start
        }
    }
    private func validUnits(_ list: [TranscriptWindowUnit], within span: TranscriptWindowSpan, final: Bool) -> Bool {
        guard list.count <= 32, Set(list.map(\.unitID)).count == list.count,
              list.reduce(0, { $0 + $1.text.unicodeScalars.count }) <= 32768 else { return false }
        var cursor = span.start
        for unit in list {
            guard validID(unit.unitID), validInteger(unit.textRevision),
                  unit.text.unicodeScalars.count <= 8192, unit.ownedSpan.isValid,
                  unit.ownedSpan.start >= cursor, unit.ownedSpan.end > unit.ownedSpan.start,
                  span.contains(unit.ownedSpan), final ? (unit.state == .reviewed
                    && unit.itemID.map(validID) == true && unit.reviewScope != nil)
                    : (unit.itemID == nil && unit.reviewScope == nil) else { return false }
            cursor = unit.ownedSpan.end
        }
        return true
    }
    private mutating func rememberTerminal(_ id: String, text: String, failed: Bool = false) {
        if failed { failedTerminalIDs.insert(id); failedItemsCount += 1 }
        terminalItems[id] = text; terminalOrder.append(id)
        while terminalOrder.count > 64 {
            let retired = terminalOrder.removeFirst()
            terminalItems.removeValue(forKey: retired); failedTerminalIDs.remove(retired)
        }
    }
}
