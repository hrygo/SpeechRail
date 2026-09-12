import Foundation

public enum ControlConstants {
    public static let schemaVersion = 1
    public static let appBundleIdentifier = "com.speechrail.desktop"
    public static let agentMachServiceName = "com.speechrail.desktop.control"
    public static let agentPlistName = "com.speechrail.desktop.control.plist"
}

public enum SpeechRailProfile: String, Codable, CaseIterable, Sendable {
    case quality
    case balanced
    case light
}

public enum ControlCommand: String, Codable, CaseIterable, Sendable {
    case status
    case start
    case stop
    case restart
    case preflight
    case profileList
    case profileStatus
    case profileApply
    case profileRollback
    case operationStatus
    case operationCancel

    public var requiresConfirmation: Bool {
        switch self {
        case .start, .stop, .restart, .profileApply, .profileRollback:
            true
        case .status, .preflight, .profileList, .profileStatus, .operationStatus, .operationCancel:
            false
        }
    }

    public var isMutation: Bool {
        switch self {
        case .start, .stop, .restart, .profileApply, .profileRollback, .operationCancel:
            true
        case .status, .preflight, .profileList, .profileStatus, .operationStatus:
            false
        }
    }
}

public enum ControlResponseStatus: String, Codable, Sendable {
    case ok
    case completed
    case accepted
    case running
    case unchanged
    case committed
    case rolledBack = "rolled_back"
    case cancelled
    case failed
}

public enum OperationState: String, Codable, Sendable {
    case accepted
    case running
    case committed
    case failed
    case cancelled
}

public enum ControlErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case unauthorizedPeer = "unauthorized_peer"
    case confirmationRequired = "confirmation_required"
    case backendBusy = "backend_busy"
    case operationInProgress = "operation_in_progress"
    case managedRuntimeMissing = "managed_runtime_missing"
    case commandFailed = "command_failed"
    case serviceUnavailable = "service_unavailable"
    case transportUnavailable = "transport_unavailable"
    case unsupported
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let command: ControlCommand
    public let profile: SpeechRailProfile?
    public let operationID: String?
    public let confirmation: Bool

    public init(
        schemaVersion: Int = ControlConstants.schemaVersion,
        requestID: UUID = UUID(),
        command: ControlCommand,
        profile: SpeechRailProfile? = nil,
        operationID: String? = nil,
        confirmation: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.command = command
        self.profile = profile
        self.operationID = operationID
        self.confirmation = confirmation
    }

    public func validate() throws {
        guard schemaVersion == ControlConstants.schemaVersion else {
            throw ControlProtocolError.unsupportedSchema
        }
        if command.requiresConfirmation && !confirmation {
            throw ControlProtocolError.confirmationRequired
        }
        if command == .profileApply && profile == nil {
            throw ControlProtocolError.profileRequired
        }
        if (command == .operationStatus || command == .operationCancel) && operationID == nil {
            throw ControlProtocolError.operationRequired
        }
    }
}

public struct ServiceSnapshot: Codable, Equatable, Sendable {
    public let serviceState: String
    public let ready: Bool?
    public let port: Int?

    public init(serviceState: String, ready: Bool? = nil, port: Int? = nil) {
        self.serviceState = serviceState
        self.ready = ready
        self.port = port
    }
}

public struct ProfileSummary: Codable, Equatable, Sendable {
    public let id: SpeechRailProfile
    public let asr: String
    public let tts: String
    public let aligner: String?
    public let downloadBytes: Int64

    public init(
        id: SpeechRailProfile,
        asr: String,
        tts: String,
        aligner: String? = nil,
        downloadBytes: Int64
    ) {
        self.id = id
        self.asr = asr
        self.tts = tts
        self.aligner = aligner
        self.downloadBytes = downloadBytes
    }
}

public struct ProfileSnapshot: Codable, Equatable, Sendable {
    public let preset: SpeechRailProfile?
    public let generation: Int?
    public let asr: String?
    public let tts: String?

    public init(
        preset: SpeechRailProfile?,
        generation: Int?,
        asr: String?,
        tts: String?
    ) {
        self.preset = preset
        self.generation = generation
        self.asr = asr
        self.tts = tts
    }
}

public struct PreflightCheckSnapshot: Codable, Equatable, Sendable {
    public let name: String
    public let ok: Bool
    public let message: String

    public init(name: String, ok: Bool, message: String) {
        self.name = name
        self.ok = ok
        self.message = message
    }
}

public struct OperationSnapshot: Codable, Equatable, Sendable {
    public let operationID: String
    public let command: ControlCommand
    public let state: OperationState
    public let phase: String?
    public let errorCode: ControlErrorCode?

    public init(
        operationID: String,
        command: ControlCommand,
        state: OperationState,
        phase: String? = nil,
        errorCode: ControlErrorCode? = nil
    ) {
        self.operationID = operationID
        self.command = command
        self.state = state
        self.phase = phase
        self.errorCode = errorCode
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let command: ControlCommand
    public let status: ControlResponseStatus
    public let errorCode: ControlErrorCode?
    public let message: String?
    public let service: ServiceSnapshot?
    public let profiles: [ProfileSummary]?
    public let profile: ProfileSnapshot?
    public let checks: [PreflightCheckSnapshot]?
    public let operation: OperationSnapshot?

    public init(
        requestID: UUID,
        command: ControlCommand,
        status: ControlResponseStatus,
        errorCode: ControlErrorCode? = nil,
        message: String? = nil,
        service: ServiceSnapshot? = nil,
        profiles: [ProfileSummary]? = nil,
        profile: ProfileSnapshot? = nil,
        checks: [PreflightCheckSnapshot]? = nil,
        operation: OperationSnapshot? = nil,
        schemaVersion: Int = ControlConstants.schemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.command = command
        self.status = status
        self.errorCode = errorCode
        self.message = message
        self.service = service
        self.profiles = profiles
        self.profile = profile
        self.checks = checks
        self.operation = operation
    }

    public static func failure(
        for request: ControlRequest,
        code: ControlErrorCode,
        message: String
    ) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: request.command,
            status: .failed,
            errorCode: code,
            message: message
        )
    }

    public func rebound(to request: ControlRequest) -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: request.command,
            status: status,
            errorCode: errorCode,
            message: message,
            service: service,
            profiles: profiles,
            profile: profile,
            checks: checks,
            operation: operation,
            schemaVersion: schemaVersion
        )
    }
}

public enum ControlProtocolError: Error, Equatable, Sendable {
    case unsupportedSchema
    case confirmationRequired
    case profileRequired
    case operationRequired
    case invalidResponse

    public var errorCode: ControlErrorCode {
        switch self {
        case .unsupportedSchema, .confirmationRequired, .profileRequired, .operationRequired:
            .invalidRequest
        case .invalidResponse:
            .commandFailed
        }
    }
}

public enum ControlWireCodec {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}
