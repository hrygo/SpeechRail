import Darwin
import Foundation

public struct PreparedDubbingExport: Equatable, Sendable {
    public let leaseID: UUID
    public let audioURL: URL
    public let scriptURL: URL
    /// 片段清单：顺序、正文、角色、停顿与实际音频一一对应。
    public let manifestURL: URL
    public let sourceRevision: String
    public let audioBytes: UInt64
    public let baseName: String
    public var audioFileName: String { "\(baseName).wav" }
    public var scriptFileName: String { "\(baseName).txt" }
    public var manifestFileName: String { "\(baseName).segments.json" }
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
    public var segmentsCommitted = false
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
                             scriptDestination: URL,
                             manifestDestination: URL) async throws -> ExportCopyReceipt {
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
            let targets = [
                audioDestination.standardizedFileURL,
                scriptDestination.standardizedFileURL,
                manifestDestination.standardizedFileURL,
            ]
            // 三份文件必须落在三个不同的位置，也不能覆盖导出临时目录里的源文件。
            guard Set(targets).count == targets.count,
                  !targets.contains(export.audioURL.standardizedFileURL),
                  !targets.contains(export.scriptURL.standardizedFileURL),
                  !targets.contains(export.manifestURL.standardizedFileURL) else {
                throw DubbingExportError.invalidDestination
            }
            filesAttempted += 1
            try copy(export.audioURL, to: audioDestination, bytesWritten: &bytesWritten, trackBytes: measureExport) { receipt.audioCommitted = true }
            filesAttempted += 1
            try copy(export.scriptURL, to: scriptDestination, bytesWritten: &bytesWritten, trackBytes: measureExport) { receipt.scriptCommitted = true }
            filesAttempted += 1
            try copy(export.manifestURL, to: manifestDestination, bytesWritten: &bytesWritten, trackBytes: measureExport) { receipt.segmentsCommitted = true }
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
    /// 静音就是零字节；按块写，不按整段停顿分配缓冲区。
    private static let silenceChunk = Data(count: chunkBytes)
    struct Payload { let format: DubbingAudioFormat; let offset: UInt64; let count: UInt64 }
    static func validatePCMSize(_ count: UInt64) throws {
        guard count <= UInt64(UInt32.max) - 36, count.isMultiple(of: 2) else { throw DubbingExportError.riffOverflow }
    }
    /// 按顺序拼接候选音频，并在段间插入静音。
    ///
    /// `pauses` 与 `inputs` 对齐，单位毫秒；末段之后的停顿不写进成品——
    /// 句间停顿描述的是"两句之间"，不是成品尾巴。
    @discardableResult static func write(inputs: [URL], pauses: [Int] = [], output: URL,
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
        // 静音字节一并计入总长，长度上限与偶数对齐都在建文件之前验完。
        var silence: [UInt64] = []
        for index in payloads.indices {
            let requested = index < pauses.count ? pauses[index] : 0
            let bytes = index == payloads.count - 1
                ? 0
                : UInt64(DubbingPause.byteCount(milliseconds: requested, sampleRate: format.sampleRate))
            silence.append(bytes)
            guard bytes > 0 else { continue }
            let (sum, overflow) = count.addingReportingOverflow(bytes)
            guard !overflow else { throw DubbingExportError.riffOverflow }
            try validatePCMSize(sum); count = sum
        }
        // All format and length checks finish before creating the output.
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw DubbingExportError.invalidDestination }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: output) } }
        let destination = try FileHandle(forWritingTo: output); defer { try? destination.close() }
        try destination.write(contentsOf: header(format: format, bytes: UInt32(count)))
        for (index, pair) in zip(inputs, payloads).enumerated() {
            try Task.checkCancellation()
            let (url, payload) = pair
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
            var gap = silence[index]
            while gap > 0 {
                try Task.checkCancellation()
                let step = Int(min(UInt64(chunkBytes), gap))
                try destination.write(contentsOf: silenceChunk.prefix(step))
                gap -= UInt64(step)
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

/// 成品旁边的片段清单。
///
/// 它是「导出顺序、正文、角色、停顿与实际音频一一对应」这件事的可核对形态：
/// 音频里第 N 段就是清单里第 N 条，正文文件第 N 行也是它。
/// 只写事实，不写推测——没有角色就是 `null`，没有停顿就是 0。
enum DubbingExportManifest {
    static let schemaVersion = "dubbing_segments_v1"

    struct Entry: Codable, Equatable, Sendable {
        let index: Int
        let text: String
        let roleID: String?
        let roleName: String?
        let voiceID: String?
        let voiceName: String?
        let voiceRevision: String?
        let candidateID: String
        let durationSeconds: Double?
        let pauseAfterMilliseconds: Int

        enum CodingKeys: String, CodingKey {
            case index, text
            case roleID = "role_id"
            case roleName = "role_name"
            case voiceID = "voice_id"
            case voiceName = "voice_name"
            case voiceRevision = "voice_revision"
            case candidateID = "candidate_id"
            case durationSeconds = "duration_seconds"
            case pauseAfterMilliseconds = "pause_after_milliseconds"
        }
    }

    struct Document: Codable, Equatable, Sendable {
        let schemaVersion: String
        let projectID: String
        let projectTitle: String
        let mode: String
        let sourceRevision: String
        let segments: [Entry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case projectID = "project_id"
            case projectTitle = "project_title"
            case mode
            case sourceRevision = "source_revision"
            case segments
        }
    }

    static func make(
        project: DubbingProject,
        segments: [DubbingSegment],
        candidates: [String: DubbingCandidate],
        sourceRevision: String
    ) -> Data {
        let entries = segments.enumerated().map { index, segment -> Entry in
            let role = project.resolvedRole(for: segment)
            let candidate = segment.acceptedCandidateID.flatMap { candidates[$0] }
            return Entry(
                index: index + 1,
                text: segment.text,
                roleID: role?.id,
                roleName: role?.name,
                voiceID: project.resolvedVoiceID(for: segment),
                voiceName: role?.voice?.voiceName ?? project.recipe.recipe?.voiceID,
                voiceRevision: candidate?.provenance.recipe?.voiceRevision,
                candidateID: segment.acceptedCandidateID ?? "",
                durationSeconds: candidate?.durationSeconds,
                // 末段之后的停顿不写进音频，清单里也不该声称有。
                pauseAfterMilliseconds: index == segments.count - 1
                    ? 0
                    : segment.pauseAfterMilliseconds
            )
        }
        let document = Document(
            schemaVersion: schemaVersion,
            projectID: project.id,
            projectTitle: project.title,
            mode: project.isMultiRole ? "multi_role" : "single_voice",
            sourceRevision: sourceRevision,
            segments: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(document)) ?? Data()
    }
}
