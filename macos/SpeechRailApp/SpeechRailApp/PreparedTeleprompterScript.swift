import CryptoKit
import Foundation

public struct PreparedTeleprompterScript: Sendable {
    public let versionID: String
    public let segmentDigest: String
    public let script: TeleprompterAligner.Script
    public init(versionID: String, segments: [TeleprompterSegment]) throws {
        self.versionID = versionID
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        segmentDigest = SHA256.hash(data: try encoder.encode(segments)).map { String(format: "%02x", $0) }.joined()
        script = .init(segments: segments)
    }
}

/// A version's segments are immutable. Resolve on lifecycle boundaries, then pass the frozen value.
struct TeleprompterScriptCache {
    private(set) var current: PreparedTeleprompterScript?
    private(set) var prepareCount = 0
    mutating func prepare(versionID: String, segments: [TeleprompterSegment]) throws -> PreparedTeleprompterScript {
        if let current, current.versionID == versionID { return current }
        let prepared = try AppPerformanceMetrics.shared.measure(.teleprompterPrepare) {
            try PreparedTeleprompterScript(versionID: versionID, segments: segments)
        }
        current = prepared; prepareCount += 1
        return prepared
    }
    mutating func clear() { current = nil }
}
