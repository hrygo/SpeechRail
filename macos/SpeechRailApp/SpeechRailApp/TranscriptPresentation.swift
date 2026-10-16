import Foundation
import Observation

public protocol TranscriptPresentationRow: Identifiable, Sendable where ID == String { var ordinal: Int { get } }
extension TranscriptLine: TranscriptPresentationRow {}
extension MeetingSession.Line: TranscriptPresentationRow {}
extension CaptionSession.Line: TranscriptPresentationRow {}
public struct TranscriptDisplayPage<Row: TranscriptPresentationRow>: Sendable {
    public let rows: [Row]
    public let nextBeforeOrdinal: Int?
}
public typealias TranscriptPage = TranscriptDisplayPage<TranscriptLine>

/// Fixed physical slots keep normal append/eviction and ID replacement independent of archive size.
private struct TranscriptTail<Row: TranscriptPresentationRow> {
    let capacity: Int
    var slots: [Row?]
    var head = 0, count = 0
    var byID: [String: Int] = [:]
    var comparisons = 0
    init(capacity: Int) { self.capacity = capacity; slots = .init(repeating: nil, count: capacity) }
    var rows: [Row] { (0..<count).compactMap { slots[(head + $0) % capacity] } }
    func line(_ id: String) -> Row? { byID[id].flatMap { slots[$0] } }
    mutating func upsert(_ line: Row) {
        if let index = byID[line.id] { slots[index] = line; return }
        if count == 0 || line.ordinal >= slots[(head + count - 1) % capacity]!.ordinal {
            append(line); return
        }
        // Out-of-order receipts use a bounded ordered insertion, never the complete archive.
        var ordered = rows
        var lower = 0, upper = ordered.count
        while lower < upper {
            comparisons += 1
            let middle = lower + (upper-lower)/2
            if ordered[middle].ordinal < line.ordinal { lower = middle+1 } else { upper = middle }
        }
        ordered.insert(line, at: lower)
        let retained = Array(ordered.suffix(capacity))
        slots = .init(repeating: nil, count: capacity); head = 0; count = 0; byID = [:]
        for row in retained { append(row) }
    }
    private mutating func append(_ line: Row) {
        let index = (head + count) % capacity
        if count == capacity {
            if let old = slots[index] { byID.removeValue(forKey: old.id) }
            head = (head+1) % capacity
        } else { count += 1 }
        slots[index] = line; byID[line.id] = index
    }
    mutating func update(_ id: String, _ transform: (inout Row) -> Void) -> Bool {
        guard let index = byID[id], var line = slots[index] else { return false }
        transform(&line); slots[index] = line; return true
    }
}

@MainActor @Observable
public final class TranscriptPresentation<Row: TranscriptPresentationRow> {
    public typealias PageLoader = @MainActor @Sendable (Int?) async throws -> TranscriptDisplayPage<Row>
    public private(set) var rows: [Row] = []
    public private(set) var revision: UInt64 = 0
    public private(set) var arrivalCount = 0
    public private(set) var scrollAnchorID: String?
    public private(set) var isFollowingTail = true
    public private(set) var isLoadingPage = false
    public private(set) var hasEarlier = false
    @ObservationIgnored private var tail = TranscriptTail<Row>(capacity: 500)
    @ObservationIgnored private var pages: [[Row]] = []
    @ObservationIgnored private var pageByID: [String: (page: Int, row: Int)] = [:]
    @ObservationIgnored private var generation = UUID()
    public var tailCount: Int { tail.count }
    public var pageCount: Int { pages.count }
    public var pageRowCount: Int { pages.reduce(0) { $0 + $1.count } }
    public var ordinalComparisons: Int { tail.comparisons }
    public init() {}
    public func reset(_ lines: [Row]) {
        generation = UUID(); tail = .init(capacity: 500); pages = []; pageByID = [:]
        for line in lines { tail.upsert(line) }
        arrivalCount = lines.count; rows = tail.rows; hasEarlier = (rows.first?.ordinal ?? 1) > 1
        scrollAnchorID = nil; isFollowingTail = true; isLoadingPage = false; revision &+= 1
    }
    public func apply(_ line: Row) {
        let existing = tail.line(line.id) != nil || pageByID[line.id] != nil
        tail.upsert(line)
        if let location = pageByID[line.id] { pages[location.page][location.row] = line }
        if !existing { arrivalCount += 1 }
        if isFollowingTail { rows = tail.rows; hasEarlier = (rows.first?.ordinal ?? 1) > 1 }
        else if pageByID[line.id] != nil { publishPages() }
        revision &+= 1
    }
    public func line(id: String) -> Row? {
        if let location = pageByID[id] { return pages[location.page][location.row] }
        return tail.line(id)
    }
    public func update(id: String, _ transform: (inout Row) -> Void) {
        var changed = tail.update(id, transform)
        if let location = pageByID[id] { transform(&pages[location.page][location.row]); changed = true }
        guard changed else { return }
        if isFollowingTail { rows = tail.rows } else { publishPages() }
        revision &+= 1
    }
    public func replace(_ line: Row) { update(id: line.id) { $0 = line } }
    public func beginHistory(anchorID: String?) {
        if isFollowingTail {
            let frozen = tail.rows
            pages = stride(from: 0, to: frozen.count, by: 200).map { Array(frozen[$0..<min(frozen.count, $0+200)]) }
            isFollowingTail = false; publishPages()
        }
        if let anchorID, pageByID[anchorID] != nil { scrollAnchorID = anchorID }
        else if scrollAnchorID == nil { scrollAnchorID = rows.first?.id }
    }
    public func setScrollAnchor(_ id: String?) {
        guard let id, !isFollowingTail, pageByID[id] != nil else { return }
        scrollAnchorID = id
    }
    public func returnToLatest() {
        generation = UUID(); isLoadingPage = false; isFollowingTail = true; pages = []; pageByID = [:]
        rows = tail.rows; scrollAnchorID = rows.last?.id; hasEarlier = (rows.first?.ordinal ?? 1) > 1; revision &+= 1
    }
    public func requestPage(beforeOrdinal: Int?, loader: PageLoader) async throws {
        guard !isLoadingPage else { return }
        beginHistory(anchorID: scrollAnchorID)
        let token = generation; isLoadingPage = true
        defer { if token == generation { isLoadingPage = false } }
        let page = try await loader(beforeOrdinal)
        try Task.checkCancellation()
        guard token == generation else { return }
        hasEarlier = page.nextBeforeOrdinal != nil
        guard !page.rows.isEmpty else { return }
        // A loader is untrusted at this boundary: enforce the same physical page limit.
        let incoming = Array(page.rows.suffix(200))
        let ids = Set(incoming.map(\.id))
        for index in pages.indices { pages[index].removeAll { ids.contains($0.id) } }
        pages.removeAll(where: \.isEmpty)
        pages.append(incoming)
        pages.sort { ($0.first?.ordinal ?? 0) < ($1.first?.ordinal ?? 0) }
        while pages.count > 3 {
            let candidate = pages.indices.reversed().first { index in !pages[index].contains { $0.id == scrollAnchorID } } ?? pages.count-1
            pages.remove(at: candidate)
        }
        publishPages(); revision &+= 1
    }
    /// Cached pages may be nonadjacent while preserving the reader's page; expose a load action for gaps.
    public func gapBefore(id: String) -> Int? {
        guard let location = pageByID[id], location.row == 0, location.page > 0,
              let previous = pages[location.page-1].last,
              let next = pages[location.page].first, next.ordinal > previous.ordinal+1 else { return nil }
        return next.ordinal
    }
    private func publishPages() {
        pageByID = [:]
        rows = []
        for (page, values) in pages.enumerated() {
            for (row, line) in values.enumerated() where pageByID[line.id] == nil {
                pageByID[line.id] = (page, row); rows.append(line)
            }
        }
    }
}

/// The transport owns the 128-item / 30s acceptance window. Retirement removes only live lookup state.
struct LiveTranscriptItemIndex {
    typealias Key = TranscriptPreviewLedger.ItemIdentity
    typealias Entry = (lineID: String, ordinal: Int)
    private var entries: [Key: Entry] = [:]
    private var retired: Set<Key> = []
    private var retirementOrder: [Key] = []
    var count: Int { entries.count }
    subscript(key: Key) -> Entry? {
        get { entries[key] }
        set { if !retired.contains(key) { entries[key] = newValue } }
    }
    func isRetired(_ key: Key) -> Bool { retired.contains(key) }
    mutating func retire(_ key: Key) -> Entry? {
        if retired.insert(key).inserted { retirementOrder.append(key) }
        if retirementOrder.count > 512 { retired.remove(retirementOrder.removeFirst()) }
        return entries.removeValue(forKey: key)
    }
}
