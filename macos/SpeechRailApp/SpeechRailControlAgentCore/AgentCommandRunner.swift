import Foundation
import SpeechRailControlKit

public enum ManagedServiceCommand: String, Sendable {
    case start
    case stop
    case restart
    case status
    case preflight
}

public enum ManagedCommand: Equatable, Sendable {
    case service(ManagedServiceCommand)
    case profileList
    case profileStatus
    case profileApply(SpeechRailProfile)
    case profileRollback
    case modelCatalog
    case modelStatus
    case modelPrepare(SpeechRailProfile)

    public var controlCommand: ControlCommand {
        switch self {
        case let .service(command):
            switch command {
            case .start: .start
            case .stop: .stop
            case .restart: .restart
            case .status: .status
            case .preflight: .preflight
            }
        case .profileList: .profileList
        case .profileStatus: .profileStatus
        case .profileApply: .profileApply
        case .profileRollback: .profileRollback
        case .modelCatalog: .modelCatalog
        case .modelStatus: .modelStatus
        case .modelPrepare: .modelPrepare
        }
    }

    public func arguments(appHome: URL) -> [String] {
        let home = appHome.standardizedFileURL.path
        let commandPrefix = ["-m", "speechrail"]
        switch self {
        case let .service(command):
            return commandPrefix + [
                "service", command.rawValue, "--app-home", home, "--json",
            ]
        case .profileList:
            return commandPrefix + ["profile", "list", "--app-home", home, "--json"]
        case .profileStatus:
            return commandPrefix + ["profile", "status", "--app-home", home, "--json"]
        case let .profileApply(profile):
            return commandPrefix + [
                "profile", "apply", profile.rawValue, "--yes", "--app-home", home, "--json",
            ]
        case .profileRollback:
            return commandPrefix + [
                "profile", "rollback", "--yes", "--app-home", home, "--json",
            ]
        case .modelCatalog:
            return commandPrefix + ["model", "catalog", "--app-home", home, "--json"]
        case .modelStatus:
            return commandPrefix + ["model", "status", "--app-home", home, "--json"]
        case let .modelPrepare(profile):
            return commandPrefix + [
                "model", "prepare", profile.rawValue, "--yes", "--app-home", home, "--json",
            ]
        }
    }
}

public struct ManagedRuntimeLocator: Sendable {
    public let appHome: URL

    public init(appHome: URL) {
        self.appHome = appHome.standardizedFileURL
    }

    public static var `default`: ManagedRuntimeLocator {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpeechRail", isDirectory: true)
        return ManagedRuntimeLocator(appHome: home)
    }

    public var pythonExecutable: URL {
        appHome
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python", isDirectory: false)
    }

    public func validatedPythonExecutable() throws -> URL {
        let executable = pythonExecutable
        guard executable.path.hasPrefix("/") else {
            throw ManagedCommandError.runtimeMissing
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ManagedCommandError.runtimeMissing
        }
        return executable
    }
}

public enum ManagedCommandError: Error, Equatable, Sendable {
    case runtimeMissing
    case launchFailed
    case invalidOutput
}

public struct ManagedCommandResult: Sendable {
    public let exitCode: Int32
    public let response: ControlResponse?
    public let message: String?

    public init(exitCode: Int32, response: ControlResponse?, message: String? = nil) {
        self.exitCode = exitCode
        self.response = response
        self.message = message
    }
}

public typealias ManagedCommandProgressHandler = @Sendable (OperationProgressSnapshot) -> Void

public protocol ManagedCommandRunner: Sendable {
    func run(_ command: ManagedCommand) async throws -> ManagedCommandResult
}

public protocol ProgressAwareManagedCommandRunner: ManagedCommandRunner {
    func run(
        _ command: ManagedCommand,
        progress: @escaping ManagedCommandProgressHandler
    ) async throws -> ManagedCommandResult
}

public protocol CancellableManagedCommandRunner: ProgressAwareManagedCommandRunner {
    func cancelCurrentCommand() -> Bool
}

public final class ProcessManagedCommandRunner: CancellableManagedCommandRunner, @unchecked Sendable {
    private let locator: ManagedRuntimeLocator
    private let processLock = NSLock()
    private var activeProcess: Process?

    public init(locator: ManagedRuntimeLocator = .default) {
        self.locator = locator
    }

    public func run(_ command: ManagedCommand) async throws -> ManagedCommandResult {
        try await run(command, progress: { _ in })
    }

    public func run(
        _ command: ManagedCommand,
        progress: @escaping ManagedCommandProgressHandler
    ) async throws -> ManagedCommandResult {
        let executable = try locator.validatedPythonExecutable()
        let arguments = command.arguments(appHome: locator.appHome)
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ManagedCommandResult, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try Self.runProcess(
                        executable: executable,
                        arguments: arguments,
                        command: command,
                        progress: progress,
                        processState: self
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func cancelCurrentCommand() -> Bool {
        processLock.lock()
        defer { processLock.unlock() }
        guard let activeProcess, activeProcess.isRunning else { return false }
        activeProcess.terminate()
        return true
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        command: ManagedCommand,
        progress: @escaping ManagedCommandProgressHandler,
        processState: ProcessManagedCommandRunner
    ) throws -> ManagedCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        processState.processLock.lock()
        processState.activeProcess = process
        processState.processLock.unlock()
        defer {
            processState.processLock.lock()
            if processState.activeProcess === process {
                processState.activeProcess = nil
            }
            processState.processLock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw ManagedCommandError.launchFailed
        }

        let stdoutCollector = PipeCollector()
        let stderrCollector = PipeCollector()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutCollector.collect(stdoutPipe.fileHandleForReading) { line in
                if let snapshot = CLIOutputDecoder.decodeProgress(line, command: command) {
                    progress(snapshot)
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCollector.collect(stderrPipe.fileHandleForReading)
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        let exitCode = process.terminationStatus
        let stdout = stdoutCollector.data
        let response: ControlResponse?
        do {
            response = try CLIOutputDecoder.decode(stdout, command: command.controlCommand)
        } catch {
            if exitCode == 0 {
                throw ManagedCommandError.invalidOutput
            }
            response = nil
        }
        let message: String?
        if let responseMessage = response?.message, !responseMessage.isEmpty {
            message = responseMessage
        } else if exitCode == 0 {
            message = nil
        } else {
            message = ManagedCommandDiagnostics.failureMessage(from: stderrCollector.data)
        }
        return ManagedCommandResult(exitCode: exitCode, response: response, message: message)
    }
}

private final class PipeCollector: @unchecked Sendable {
    private static let maximumBytes = 1024 * 1024
    private let lock = NSLock()
    private var storedData = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    func collect(_ handle: FileHandle, onLine: (@Sendable (Data) -> Void)? = nil) {
        var data = Data()
        var lineBuffer = Data()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { break }
            data.append(chunk)
            if data.count > Self.maximumBytes {
                data = Data(data.suffix(Self.maximumBytes))
            }
            guard onLine != nil else { continue }
            lineBuffer.append(chunk)
            if lineBuffer.count > Self.maximumBytes {
                lineBuffer = Data(lineBuffer.suffix(Self.maximumBytes))
            }
            while let newline = lineBuffer.firstIndex(of: 0x0A) {
                let line = Data(lineBuffer[..<newline])
                lineBuffer.removeSubrange(...newline)
                onLine?(line)
            }
        }
        if !lineBuffer.isEmpty {
            onLine?(lineBuffer)
        }
        lock.lock()
        storedData = data
        lock.unlock()
    }
}

private enum ManagedCommandDiagnostics {
    private static let secretPattern = #"(?i)\b(api[_-]?key|authorization|token|secret|password)\b\s*[:=]\s*\S+"#
    private static let pathPattern = #"(?<![:\w])/[^\s"']+"#

    static func failureMessage(from data: Data) -> String {
        guard let output = String(data: data, encoding: .utf8) else {
            return "managed command failed"
        }
        let detail = output
            .split(whereSeparator: { $0.isNewline })
            .reversed()
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let detail else {
            return "managed command failed"
        }

        let redactedSecrets = replacingMatches(
            in: detail,
            pattern: secretPattern,
            template: "$1=[redacted]"
        )
        let redactedPaths = replacingMatches(
            in: redactedSecrets,
            pattern: pathPattern,
            template: "[path]"
        )
        return "managed command failed: \(String(redactedPaths.prefix(200)))"
    }

    private static func replacingMatches(in value: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}

private struct CLIEnvelope: Decodable {
    let schemaVersion: Int
    let command: String
    let status: String
    let errorCode: String?
    let message: String?
    let serviceState: String?
    let operationID: String?
    let preset: String?
    let generation: Int?
    let asr: String?
    let tts: String?
    let profiles: [CLIProfile]?
    let checks: [CLICheck]?
    let artifacts: [CLIArtifact]?
    let diarization: [CLIArtifact]?
    let disk: CLIDisk?
    let preparedID: String?
    let event: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case command
        case status
        case errorCode = "error_code"
        case message
        case serviceState = "service_state"
        case operationID = "operation_id"
        case preset
        case generation
        case asr
        case tts
        case profiles
        case checks
        case artifacts
        case diarization
        case disk
        case preparedID = "prepared_id"
        case event
    }
}

private struct CLIProgressEnvelope: Decodable {
    let event: String?
    let phase: String?
    let artifact: String?
    let artifactKey: String?
    let file: String?
    let bytes: Int64?
    let completedBytes: Int64?
    let expectedBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case event
        case phase
        case artifact
        case artifactKey = "artifact_key"
        case file
        case bytes
        case completedBytes = "completed_bytes"
        case expectedBytes = "expected_bytes"
    }
}

private struct CLIProfile: Decodable {
    let id: String
    let asr: String
    let tts: String
    let aligner: String?
    let ttsClone: String?
    let diarization: Bool?
    let downloadBytes: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case asr
        case tts
        case aligner
        case ttsClone = "tts_clone"
        case diarization
        case downloadBytes = "download_bytes"
    }
}

private struct CLIArtifact: Decodable {
    let key: String
    let modelID: String?
    let family: String?
    let variant: String?
    let revision: String?
    let provider: String?
    let repository: String?
    let quantization: ModelQuantizationSnapshot?
    let sizeBytes: Int64?
    let fileCount: Int?
    let requiredBy: [SpeechRailProfile]?
    let state: ModelArtifactState?
    let integrity: ModelIntegrityState?
    let verifiedFileCount: Int?
    let totalFileCount: Int?

    enum CodingKeys: String, CodingKey {
        case key
        case modelID = "model_id"
        case family
        case variant
        case revision
        case provider
        case repository
        case quantization
        case sizeBytes = "size_bytes"
        case fileCount = "file_count"
        case requiredBy = "required_by"
        case state
        case integrity
        case verifiedFileCount = "verified_file_count"
        case totalFileCount = "total_file_count"
    }
}

private struct CLIDisk: Decodable {
    let modelBytes: Int64
    let freeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case modelBytes = "model_bytes"
        case freeBytes = "free_bytes"
    }
}

private struct CLICheck: Decodable {
    let name: String
    let ok: Bool
    let message: String
}

private enum CLIOutputDecoder {
    static func decodeProgress(
        _ data: Data,
        command: ManagedCommand
    ) -> OperationProgressSnapshot? {
        guard command.controlCommand == .modelPrepare,
              let envelope = try? ControlWireCodec.decode(CLIProgressEnvelope.self, from: data),
              envelope.event == "progress"
        else {
            return nil
        }
        return OperationProgressSnapshot(
            phase: envelope.phase,
            artifactKey: envelope.artifactKey ?? envelope.artifact,
            file: envelope.file,
            completedBytes: envelope.completedBytes ?? envelope.bytes,
            expectedBytes: envelope.expectedBytes
        )
    }

    static func decode(_ data: Data, command: ControlCommand) throws -> ControlResponse {
        let envelopeData: Data
        if command == .modelPrepare {
            let lines = data.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D })
            envelopeData = lines.last.map { Data($0) } ?? data
        } else {
            envelopeData = data
        }
        let envelope = try ControlWireCodec.decode(CLIEnvelope.self, from: envelopeData)
        guard envelope.schemaVersion == ControlConstants.schemaVersion,
              let responseStatus = ControlResponseStatus(rawValue: envelope.status)
        else {
            throw ManagedCommandError.invalidOutput
        }

        let profiles = try envelope.profiles?.map { profile in
            guard let id = SpeechRailProfile(rawValue: profile.id) else {
                throw ManagedCommandError.invalidOutput
            }
            return ProfileSummary(
                id: id,
                asr: profile.asr,
                tts: profile.tts,
                aligner: profile.aligner,
                ttsClone: profile.ttsClone,
                diarization: profile.diarization ?? false,
                downloadBytes: profile.downloadBytes
            )
        }
        let profile: ProfileSnapshot?
        if envelope.preset != nil || envelope.generation != nil || envelope.asr != nil || envelope.tts != nil {
            let preset = envelope.preset.flatMap(SpeechRailProfile.init(rawValue:))
            if envelope.preset != nil && preset == nil {
                throw ManagedCommandError.invalidOutput
            }
            profile = ProfileSnapshot(
                preset: preset,
                generation: envelope.generation,
                asr: envelope.asr,
                tts: envelope.tts
            )
        } else {
            profile = nil
        }
        let checks = envelope.checks?.map {
            PreflightCheckSnapshot(name: $0.name, ok: $0.ok, message: $0.message)
        }
        let modelCatalog: ModelCatalogSnapshot?
        if let artifacts = envelope.artifacts,
           artifacts.contains(where: { $0.modelID != nil })
        {
            let rows = try artifacts.map { artifact in
                guard let modelID = artifact.modelID,
                      let family = artifact.family,
                      let variant = artifact.variant,
                      let revision = artifact.revision,
                      let provider = artifact.provider,
                      let repository = artifact.repository,
                      let quantization = artifact.quantization,
                      let sizeBytes = artifact.sizeBytes,
                      let fileCount = artifact.fileCount,
                      let requiredBy = artifact.requiredBy
                else {
                    throw ManagedCommandError.invalidOutput
                }
                return ModelArtifactSnapshot(
                    key: artifact.key,
                    modelID: modelID,
                    family: family,
                    variant: variant,
                    revision: revision,
                    provider: provider,
                    repository: repository,
                    quantization: quantization,
                    sizeBytes: sizeBytes,
                    fileCount: fileCount,
                    requiredBy: requiredBy
                )
            }
            modelCatalog = ModelCatalogSnapshot(
                artifacts: rows,
                profiles: profiles ?? []
            )
        } else {
            modelCatalog = nil
        }
        let modelStatus: ModelStatusSnapshot?
        let statusArtifacts = envelope.artifacts?.filter { $0.state != nil } ?? []
        let diarizationArtifacts = envelope.diarization ?? []
        if !statusArtifacts.isEmpty || !diarizationArtifacts.isEmpty {
            guard let disk = envelope.disk else {
                throw ManagedCommandError.invalidOutput
            }
            func decodeStatusRows(_ artifacts: [CLIArtifact]) throws -> [ModelArtifactStatusSnapshot] {
                try artifacts.map { artifact in
                    guard let state = artifact.state,
                          let integrity = artifact.integrity,
                          let verifiedFileCount = artifact.verifiedFileCount,
                          let totalFileCount = artifact.totalFileCount
                    else {
                        throw ManagedCommandError.invalidOutput
                    }
                    return ModelArtifactStatusSnapshot(
                        key: artifact.key,
                        state: state,
                        integrity: integrity,
                        verifiedFileCount: verifiedFileCount,
                        totalFileCount: totalFileCount
                    )
                }
            }
            modelStatus = ModelStatusSnapshot(
                artifacts: try decodeStatusRows(statusArtifacts),
                diarization: try decodeStatusRows(diarizationArtifacts),
                disk: ModelDiskSnapshot(modelBytes: disk.modelBytes, freeBytes: disk.freeBytes)
            )
        } else {
            modelStatus = nil
        }
        let errorCode = envelope.errorCode.flatMap(ControlErrorCode.init(rawValue:))
        return ControlResponse(
            requestID: UUID(),
            command: command,
            status: responseStatus,
            errorCode: errorCode,
            message: envelope.message,
            service: envelope.serviceState.map { ServiceSnapshot(serviceState: $0) },
            profiles: profiles,
            profile: profile,
            checks: checks,
            modelCatalog: modelCatalog,
            modelStatus: modelStatus,
            operation: envelope.operationID.map {
                OperationSnapshot(
                    operationID: $0,
                    command: command,
                    state: operationState(for: responseStatus),
                    phase: envelope.status,
                    errorCode: errorCode,
                    message: envelope.message
                )
            }
        )
    }

    private static func operationState(for status: ControlResponseStatus) -> OperationState {
        switch status {
        case .accepted: .accepted
        case .running: .running
        case .committed, .completed, .unchanged: .committed
        case .cancelled: .cancelled
        case .ok, .rolledBack, .failed: .failed
        }
    }
}
