import Foundation

public enum ControlConstants {
    public static let schemaVersion = 1
    public static let appBundleIdentifier = "com.speechrail.desktop"
    public static let agentMachServiceName = "com.speechrail.desktop.control"
    public static let localXPCServiceName = "com.speechrail.desktop.local-control"
    public static let agentPlistName = "com.speechrail.desktop.control.plist"
}

/// 一个独立规格档位（ASR 与 TTS 各自选择，见目标架构 §2.1）。
///
/// 历史四档 preset（`extreme`/`balanced`/`light`）已不存在：档位现在只有
/// `fast`/`quality`/`reference` 三档，且 ASR 与 TTS 分别选择、不共享一个 preset ID。
public enum SpeechRailProfile: Codable, CaseIterable, Hashable, RawRepresentable, Sendable {
    case fast
    case quality
    case reference
    case unrecognized(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "fast":
            self = .fast
        case "quality":
            self = .quality
        case "reference":
            self = .reference
        default:
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .fast:
            "fast"
        case .quality:
            "quality"
        case .reference:
            "reference"
        case let .unrecognized(value):
            value
        }
    }

    public static let allCases: [SpeechRailProfile] = [
        .fast,
        .quality,
        .reference,
    ]

    public var isSelectable: Bool {
        if case .unrecognized = self {
            return false
        }
        return true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = Self(rawValue: value) ?? .unrecognized(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 一次档位切换/制品准备的完整选择：ASR 与 TTS 两项规格。
///
/// 「快捷组合」把两项写相同值（`quick`），高级用户可以在诊断页分别调整，
/// 二者在 wire 上都落到同一对 `asr_spec`/`tts_spec`。
public struct SpecSelection: Codable, Equatable, Hashable, Sendable {
    public let asrSpec: SpeechRailProfile
    public let ttsSpec: SpeechRailProfile

    public init(asrSpec: SpeechRailProfile, ttsSpec: SpeechRailProfile) {
        self.asrSpec = asrSpec
        self.ttsSpec = ttsSpec
    }

    /// 快捷组合：两档取同一档位。
    public static func quick(_ tier: SpeechRailProfile) -> SpecSelection {
        SpecSelection(asrSpec: tier, ttsSpec: tier)
    }

    public var isSelectable: Bool {
        asrSpec.isSelectable && ttsSpec.isSelectable
    }

    /// 两项相同才有一个「当前快捷档位」；否则只能分别呈现。
    public var quickTier: SpeechRailProfile? {
        asrSpec == ttsSpec ? asrSpec : nil
    }

    /// 解析服务健康快照里的 `<asr>/<tts>` 规格对；未知档位返回 nil。
    public init?(wire: String?) {
        guard let wire else { return nil }
        let parts = wire.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let asr = SpeechRailProfile(rawValue: String(parts[0])),
              let tts = SpeechRailProfile(rawValue: String(parts[1]))
        else { return nil }
        self.init(asrSpec: asr, ttsSpec: tts)
    }

    public var wireValue: String {
        "\(asrSpec.rawValue)/\(ttsSpec.rawValue)"
    }
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
    case modelCatalog
    case modelStatus
    case modelPrepare
    case operationStatus
    case operationCancel

    public var requiresConfirmation: Bool {
        switch self {
        case .start, .stop, .restart, .profileApply, .profileRollback, .modelPrepare:
            true
        case .status, .preflight, .profileList, .profileStatus, .modelCatalog, .modelStatus,
             .operationStatus, .operationCancel:
            false
        }
    }

    public var isMutation: Bool {
        switch self {
        case .start, .stop, .restart, .profileApply, .profileRollback, .modelPrepare,
             .operationCancel:
            true
        case .status, .preflight, .profileList, .profileStatus, .modelCatalog, .modelStatus,
             .operationStatus:
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
    case interrupted
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
    case modelUnavailable = "model_unavailable"
    case downloadFailed = "download_failed"
    case integrityMismatch = "integrity_mismatch"
    case insufficientDiskSpace = "insufficient_disk_space"
    case cancelled
    case unsupported
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let command: ControlCommand
    public let selection: SpecSelection?
    public let operationID: String?
    public let confirmation: Bool

    public init(
        schemaVersion: Int = ControlConstants.schemaVersion,
        requestID: UUID = UUID(),
        command: ControlCommand,
        selection: SpecSelection? = nil,
        operationID: String? = nil,
        confirmation: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.command = command
        self.selection = selection
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
        if command == .profileApply || command == .modelPrepare {
            guard let selection else {
                throw ControlProtocolError.profileRequired
            }
            guard selection.isSelectable else {
                throw ControlProtocolError.profileUnsupported
            }
        }
        if (command == .operationStatus || command == .operationCancel) && operationID == nil {
            throw ControlProtocolError.operationRequired
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
        case asrSpec = "asr_spec"
        case ttsSpec = "tts_spec"
        case operationID = "operation_id"
        case confirmation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        command = try container.decode(ControlCommand.self, forKey: .command)
        let asrSpec = try container.decodeIfPresent(SpeechRailProfile.self, forKey: .asrSpec)
        let ttsSpec = try container.decodeIfPresent(SpeechRailProfile.self, forKey: .ttsSpec)
        if let asrSpec, let ttsSpec {
            selection = SpecSelection(asrSpec: asrSpec, ttsSpec: ttsSpec)
        } else {
            selection = nil
        }
        operationID = try container.decodeIfPresent(String.self, forKey: .operationID)
        confirmation = try container.decode(Bool.self, forKey: .confirmation)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(selection?.asrSpec, forKey: .asrSpec)
        try container.encodeIfPresent(selection?.ttsSpec, forKey: .ttsSpec)
        try container.encodeIfPresent(operationID, forKey: .operationID)
        try container.encode(confirmation, forKey: .confirmation)
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
    public let ttsClone: String?
    public let diarization: Bool
    public let downloadBytes: Int64

    public init(
        id: SpeechRailProfile,
        asr: String,
        tts: String,
        aligner: String? = nil,
        ttsClone: String? = nil,
        diarization: Bool = false,
        downloadBytes: Int64
    ) {
        self.id = id
        self.asr = asr
        self.tts = tts
        self.aligner = aligner
        self.ttsClone = ttsClone
        self.diarization = diarization
        self.downloadBytes = downloadBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SpeechRailProfile.self, forKey: .id)
        asr = try container.decode(String.self, forKey: .asr)
        tts = try container.decode(String.self, forKey: .tts)
        aligner = try container.decodeIfPresent(String.self, forKey: .aligner)
        ttsClone = try container.decodeIfPresent(String.self, forKey: .ttsClone)
        diarization = try container.decodeIfPresent(Bool.self, forKey: .diarization) ?? false
        downloadBytes = try container.decode(Int64.self, forKey: .downloadBytes)
    }

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

public struct ProfileSnapshot: Codable, Equatable, Sendable {
    /// 已提交选择的两项规格；任一为空表示还没配置过。
    public let asrSpec: SpeechRailProfile?
    public let ttsSpec: SpeechRailProfile?
    public let generation: Int?
    /// 实际绑定的 ASR/TTS 制品 key（诊断用，不参与选择）。
    public let asr: String?
    public let tts: String?

    public init(
        asrSpec: SpeechRailProfile?,
        ttsSpec: SpeechRailProfile?,
        generation: Int?,
        asr: String?,
        tts: String?
    ) {
        self.asrSpec = asrSpec
        self.ttsSpec = ttsSpec
        self.generation = generation
        self.asr = asr
        self.tts = tts
    }

    /// 已提交的完整选择；缺任一项时为 nil（未配置）。
    public var selection: SpecSelection? {
        guard let asrSpec, let ttsSpec else { return nil }
        return SpecSelection(asrSpec: asrSpec, ttsSpec: ttsSpec)
    }

    /// 面向用户的当前选择标签，例如 `quality/quality`。
    public var label: String? {
        selection.map { "\($0.asrSpec.rawValue)/\($0.ttsSpec.rawValue)" }
    }

    enum CodingKeys: String, CodingKey {
        case asrSpec = "asr_spec"
        case ttsSpec = "tts_spec"
        case generation
        case asr
        case tts
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
    public let selection: SpecSelection?
    public let state: OperationState
    public let phase: String?
    public let progress: OperationProgressSnapshot?
    public let errorCode: ControlErrorCode?
    public let message: String?

    public init(
        operationID: String,
        command: ControlCommand,
        selection: SpecSelection? = nil,
        state: OperationState,
        phase: String? = nil,
        progress: OperationProgressSnapshot? = nil,
        errorCode: ControlErrorCode? = nil,
        message: String? = nil
    ) {
        self.operationID = operationID
        self.command = command
        self.selection = selection
        self.state = state
        self.phase = phase
        self.progress = progress
        self.errorCode = errorCode
        self.message = message
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
    public let modelCatalog: ModelCatalogSnapshot?
    public let modelStatus: ModelStatusSnapshot?
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
        modelCatalog: ModelCatalogSnapshot? = nil,
        modelStatus: ModelStatusSnapshot? = nil,
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
        self.modelCatalog = modelCatalog
        self.modelStatus = modelStatus
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
            modelCatalog: modelCatalog,
            modelStatus: modelStatus,
            operation: operation,
            schemaVersion: schemaVersion
        )
    }
}

public enum ControlProtocolError: Error, Equatable, Sendable {
    case unsupportedSchema
    case confirmationRequired
    case profileRequired
    case profileUnsupported
    case operationRequired
    case invalidResponse

    public var errorCode: ControlErrorCode {
        switch self {
        case .unsupportedSchema, .confirmationRequired, .profileRequired, .profileUnsupported,
             .operationRequired:
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
