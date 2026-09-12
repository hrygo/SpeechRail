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
        }
    }

    public func arguments(appHome: URL) -> [String] {
        let home = appHome.standardizedFileURL.path
        switch self {
        case let .service(command):
            return ["service", command.rawValue, "--app-home", home, "--json"]
        case .profileList:
            return ["profile", "list", "--app-home", home, "--json"]
        case .profileStatus:
            return ["profile", "status", "--app-home", home, "--json"]
        case let .profileApply(profile):
            return [
                "profile", "apply", profile.rawValue, "--yes", "--app-home", home, "--json",
            ]
        case .profileRollback:
            return ["profile", "rollback", "--yes", "--app-home", home, "--json"]
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

public protocol ManagedCommandRunner: Sendable {
    func run(_ command: ManagedCommand) async throws -> ManagedCommandResult
}

public final class ProcessManagedCommandRunner: ManagedCommandRunner, @unchecked Sendable {
    private let locator: ManagedRuntimeLocator

    public init(locator: ManagedRuntimeLocator = .default) {
        self.locator = locator
    }

    public func run(_ command: ManagedCommand) async throws -> ManagedCommandResult {
        let executable = try locator.validatedPythonExecutable()
        let arguments = command.arguments(appHome: locator.appHome)
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ManagedCommandResult, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try Self.runProcess(
                        executable: executable,
                        arguments: arguments,
                        command: command.controlCommand
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        command: ControlCommand
    ) throws -> ManagedCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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
            stdoutCollector.collect(stdoutPipe.fileHandleForReading)
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
            response = try CLIOutputDecoder.decode(stdout, command: command)
        } catch {
            if exitCode == 0 {
                throw ManagedCommandError.invalidOutput
            }
            response = nil
        }
        let message = exitCode == 0 ? nil : "managed command failed"
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

    func collect(_ handle: FileHandle) {
        var data = Data()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { break }
            let remaining = Self.maximumBytes - data.count
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
        }
        lock.lock()
        storedData = data
        lock.unlock()
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
    }
}

private struct CLIProfile: Decodable {
    let id: String
    let asr: String
    let tts: String
    let aligner: String?
    let downloadBytes: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case asr
        case tts
        case aligner
        case downloadBytes = "download_bytes"
    }
}

private struct CLICheck: Decodable {
    let name: String
    let ok: Bool
    let message: String
}

private enum CLIOutputDecoder {
    static func decode(_ data: Data, command: ControlCommand) throws -> ControlResponse {
        let envelope = try ControlWireCodec.decode(CLIEnvelope.self, from: data)
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
            operation: envelope.operationID.map {
                OperationSnapshot(
                    operationID: $0,
                    command: command,
                    state: operationState(for: responseStatus),
                    errorCode: errorCode
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
