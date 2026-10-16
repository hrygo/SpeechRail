import Foundation

/// Local anonymity boundary. This value is frozen before any attribution writes.
public struct SpeakerScopeBinding: Sendable, Equatable {
    public enum Failure: Error { case invalidLabel, capacityExceeded }
    public let recordID: String
    public let connectionGeneration: Int
    public let serverSessionID: String
    public let inputEpoch: Int
    public let scope: UUID
    private var nextUser = 1
    private var allocated: Set<String> = []
    public init(recordID: String, connectionGeneration: Int, serverSessionID: String,
                inputEpoch: Int, scope: UUID = UUID()) {
        self.recordID = recordID; self.connectionGeneration = connectionGeneration
        self.serverSessionID = serverSessionID; self.inputEpoch = inputEpoch; self.scope = scope
    }
    public var prefix: String { "d" + scope.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ":" }
    public mutating func serverLabel(_ raw: String, capacity: Int) throws -> String {
        guard (1...32).contains(capacity), raw.first == "S", let index = Int(raw.dropFirst()),
              (1...capacity).contains(index), raw == "S\(index)" else { throw Failure.invalidLabel }
        let label = prefix + raw
        guard allocated.contains(label) || allocated.count < capacity else { throw Failure.capacityExceeded }
        allocated.insert(label)
        return label
    }
    public mutating func allocateUserLabel(existing: Set<String>, capacity: Int) throws -> String {
        let used = allocated.union(existing.filter { $0.hasPrefix(prefix) })
        guard (1...32).contains(capacity), used.count < capacity else { throw Failure.capacityExceeded }
        while nextUser <= 32 && used.contains(prefix + "U\(nextUser)") { nextUser += 1 }
        guard nextUser <= 32 else { throw Failure.capacityExceeded }
        let label = prefix + "U\(nextUser)"
        nextUser += 1
        allocated = used.union([label])
        return label
    }
}
