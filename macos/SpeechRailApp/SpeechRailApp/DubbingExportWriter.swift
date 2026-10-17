import Darwin
import Foundation

public struct PreparedDubbingExport: Equatable, Sendable {
    public let leaseID: UUID
    public let audioURL: URL
    public let scriptURL: URL
    public let sourceRevision: String
    public let audioBytes: UInt64
    public let baseName: String
    public var audioFileName: String { "\(baseName).wav" }
    public var scriptFileName: String { "\(baseName).txt" }
}
public enum DubbingExportError: Error, LocalizedError, Equatable, Sendable {
    case exportBusy, incompleteProject, invalidWAV, riffOverflow, invalidDestination
    public var errorDescription: String? {
        switch self {
        case .exportBusy: "上一次导出尚未结束，请先保存或取消。"
        case .incompleteProject: "还有段落没有采用有效版本，全部采用后才能导出成品。"
        case .invalidWAV: "候选音频文件不完整，无法导出。"
        case .riffOverflow: "成品超过 WAV 文件大小上限，请分段导出。"
        case .invalidDestination: "导出目标无效，请重新选择保存位置。"
        }
    }
}
public struct ExportCopyReceipt: Equatable, Sendable {
    public var audioCommitted = false
    public var scriptCommitted = false
}
public struct ExportCopyFailure: Error, Sendable {
    public let receipt: ExportCopyReceipt
    public let cancelled: Bool
}

/// All handles and filesystem work stay on this actor. Each destination has its own commit point.
public actor DubbingExportWriter {
    public private(set) var activeFileHandles = 0
    private let onRead: (@Sendable (Int) -> Void)?
    private let beforePublish: (@Sendable (URL) throws -> Void)?
    private let metrics: AppPerformanceMetrics
    public init(onRead: (@Sendable (Int) -> Void)? = nil, beforePublish: (@Sendable (URL) throws -> Void)? = nil,
                metrics: AppPerformanceMetrics = .shared) {
        self.onRead = onRead; self.beforePublish = beforePublish; self.metrics = metrics
    }
    public func copyPrepared(_ export: PreparedDubbingExport, audioDestination: URL,
                             scriptDestination: URL) async throws -> ExportCopyReceipt {
        let measureExport = metrics.isEnabled
        let startedAt = measureExport ? DispatchTime.now().uptimeNanoseconds : 0
        var bytesWritten = 0, filesAttempted = 0
        var outcome = AppPerformanceOutcome.success
        defer {
            if measureExport {
                metrics.record(.init(operation: .dubbingExport,
                    durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt,
                    bytes: bytesWritten, count: filesAttempted, outcome: outcome))
            }
        }
        var receipt = ExportCopyReceipt()
        do {
            let targets = [audioDestination.standardizedFileURL, scriptDestination.standardizedFileURL]
            guard targets[0] != targets[1], !targets.contains(export.audioURL.standardizedFileURL),
                  !targets.contains(export.scriptURL.standardizedFileURL) else { throw DubbingExportError.invalidDestination }
            filesAttempted += 1
            try copy(export.audioURL, to: audioDestination, bytesWritten: &bytesWritten, trackBytes: measureExport) { receipt.audioCommitted = true }
            filesAttempted += 1
            try copy(export.scriptURL, to: scriptDestination, bytesWritten: &bytesWritten, trackBytes: measureExport) { receipt.scriptCommitted = true }
            return receipt
        } catch {
            outcome = error is CancellationError ? .cancelled : .failed
            throw ExportCopyFailure(receipt: receipt, cancelled: error is CancellationError)
        }
    }
    private func copy(_ source: URL, to destination: URL, bytesWritten: inout Int, trackBytes: Bool,
                      committed: () -> Void) throws {
        try Task.checkCancellation()
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".speechrail-export-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw DubbingExportError.invalidDestination }
        defer { try? FileManager.default.removeItem(at: staging) }
        let input = try FileHandle(forReadingFrom: source); activeFileHandles += 1
        defer { try? input.close(); activeFileHandles -= 1 }
        let output = try FileHandle(forWritingTo: staging); activeFileHandles += 1
        defer { try? output.close(); activeFileHandles -= 1 }
        while true {
            try Task.checkCancellation()
            let bytes = try input.read(upToCount: DubbingStreamingWAV.chunkBytes) ?? Data()
            onRead?(bytes.count)
            if bytes.isEmpty { break }
            try output.write(contentsOf: bytes)
            if trackBytes {
                let (total, overflow) = bytesWritten.addingReportingOverflow(bytes.count)
                bytesWritten = overflow ? .max : total
            }
        }
        try output.synchronize()
        try beforePublish?(destination)
        try Task.checkCancellation()
        let result = staging.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in Darwin.rename(from!, to!) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Rename is the per-file commit, even if a later directory sync fails.
        committed()
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Bounded parsing/copying on the store's non-reentrant filesystem transaction.
enum DubbingStreamingWAV {
    static let chunkBytes = 256 * 1024
    struct Payload { let format: DubbingAudioFormat; let offset: UInt64; let count: UInt64 }
    static func validatePCMSize(_ count: UInt64) throws {
        guard count <= UInt64(UInt32.max) - 36, count.isMultiple(of: 2) else { throw DubbingExportError.riffOverflow }
    }
    @discardableResult static func write(inputs: [URL], output: URL,
                                         onRead: (@Sendable (Int) -> Void)? = nil) throws -> UInt64 {
        guard !inputs.isEmpty else { throw DubbingExportError.incompleteProject }
        let payloads = try inputs.map { try parse($0, onRead: onRead) }
        let format = payloads[0].format
        guard format.isLinearMono16 else { throw DubbingProjectError.audioFormatUnsupported }
        var count: UInt64 = 0
        for payload in payloads {
            guard payload.format == format else { throw DubbingProjectError.audioFormatMismatch }
            let (sum, overflow) = count.addingReportingOverflow(payload.count)
            guard !overflow else { throw DubbingExportError.riffOverflow }
            try validatePCMSize(sum); count = sum
        }
        // All format and length checks finish before creating the output.
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw DubbingExportError.invalidDestination }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: output) } }
        let destination = try FileHandle(forWritingTo: output); defer { try? destination.close() }
        try destination.write(contentsOf: header(format: format, bytes: UInt32(count)))
        for (url, payload) in zip(inputs, payloads) {
            try Task.checkCancellation()
            let source = try FileHandle(forReadingFrom: url)
            defer { try? source.close() }
            try source.seek(toOffset: payload.offset)
            var remaining = payload.count
            while remaining > 0 {
                try Task.checkCancellation()
                let bytes = try read(source, count: Int(min(UInt64(chunkBytes), remaining)), onRead: onRead)
                remaining -= UInt64(bytes.count)
                try destination.write(contentsOf: bytes)
            }
        }
        try destination.synchronize(); succeeded = true
        return count + 44
    }
    static func parse(_ url: URL, onRead: (@Sendable (Int) -> Void)? = nil) throws -> Payload {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        let riff = try read(file, count: 12, onRead: onRead)
        guard riff.prefix(4) == Data("RIFF".utf8), riff.suffix(4) == Data("WAVE".utf8) else { throw DubbingExportError.invalidWAV }
        let end = UInt64(u32(riff, 4)) + 8
        guard end >= 12, end <= size else { throw DubbingExportError.invalidWAV }
        var cursor: UInt64 = 12, format: DubbingAudioFormat?, payload: (UInt64, UInt64)?
        while cursor + 8 <= end {
            try Task.checkCancellation(); try file.seek(toOffset: cursor)
            let chunk = try read(file, count: 8, onRead: onRead), bytes = UInt64(u32(chunk, 4)), body = cursor + 8
            guard bytes <= end - body, body + bytes + bytes % 2 <= end else { throw DubbingExportError.invalidWAV }
            if chunk.prefix(4) == Data("fmt ".utf8) {
                guard format == nil, bytes >= 16 else { throw DubbingExportError.invalidWAV }
                let fmt = try read(file, count: 16, onRead: onRead)
                guard u16(fmt, 0) == 1 else { throw DubbingProjectError.audioFormatUnsupported }
                let candidate = DubbingAudioFormat(sampleRate: Int(u32(fmt, 4)), channels: Int(u16(fmt, 2)), bitsPerSample: Int(u16(fmt, 14)))
                guard candidate.isLinearMono16, candidate.sampleRate > 0,
                      UInt64(u32(fmt, 8)) == UInt64(candidate.sampleRate) * 2, u16(fmt, 12) == 2 else { throw DubbingProjectError.audioFormatUnsupported }
                format = candidate
            } else if chunk.prefix(4) == Data("data".utf8) {
                guard payload == nil, bytes > 0, bytes.isMultiple(of: 2) else { throw DubbingExportError.invalidWAV }
                payload = (body, bytes)
            }
            cursor = body + bytes + bytes % 2
        }
        guard cursor == end, let format, let payload else { throw DubbingExportError.invalidWAV }
        return .init(format: format, offset: payload.0, count: payload.1)
    }
    private static func read(_ handle: FileHandle, count: Int, onRead: (@Sendable (Int) -> Void)?) throws -> Data {
        guard count <= chunkBytes, let data = try handle.read(upToCount: count), data.count == count else { throw DubbingExportError.invalidWAV }
        onRead?(data.count); return data
    }
    private static func u16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset+1]) << 8 }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset+1]) << 8 | UInt32(data[offset+2]) << 16 | UInt32(data[offset+3]) << 24
    }
    private static func header(format: DubbingAudioFormat, bytes: UInt32) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); append(bytes + 36); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(format.sampleRate)); append(UInt32(format.sampleRate * 2))
        append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(bytes); return data
    }
}
