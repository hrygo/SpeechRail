import Foundation

public enum ServiceContractDecodingError: Error, Equatable, Sendable {
    case missingRequiredField(String)
    case invalidValue(String)
}

public enum ServiceAPIClientError: Error, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case requestFailed
    case requestTimedOut
    case notModifiedWithoutCache
    case invalidContract(String)
    case http(
        statusCode: Int,
        code: String,
        message: String,
        requestID: String?,
        retryable: Bool
    )

    public var statusCode: Int? {
        guard case let .http(statusCode, _, _, _, _) = self else { return nil }
        return statusCode
    }

    public var code: String? {
        guard case let .http(_, code, _, _, _) = self else { return nil }
        return code
    }

    public var requestID: String? {
        guard case let .http(_, _, _, requestID, _) = self else { return nil }
        return requestID
    }

    public var isRetryable: Bool {
        guard case let .http(_, _, _, _, retryable) = self else { return false }
        return retryable
    }
}

public struct ServiceResponseMetadata: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let requestID: String?
    public let etag: String?

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        requestID: String? = nil,
        etag: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.requestID = requestID
        self.etag = etag
    }

    public func value(forHeader name: String) -> String? {
        headers.first { key, _ in key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct ServiceConditionalResponse<Value: Sendable>: Sendable {
    public let value: Value?
    public let metadata: ServiceResponseMetadata
    public let notModified: Bool

    public init(
        value: Value?,
        metadata: ServiceResponseMetadata,
        notModified: Bool = false
    ) {
        self.value = value
        self.metadata = metadata
        self.notModified = notModified
    }

    public static func notModified(metadata: ServiceResponseMetadata) -> Self {
        Self(value: nil, metadata: metadata, notModified: true)
    }
}

public struct ServiceRawHTTPResponse: Sendable {
    public let data: Data
    public let metadata: ServiceResponseMetadata

    public init(data: Data, metadata: ServiceResponseMetadata) {
        self.data = data
        self.metadata = metadata
    }
}

public enum HTTPHeaderNames {
    public static let authorization = "Authorization"
    public static let accept = "Accept"
    public static let contentType = "Content-Type"
    public static let ifNoneMatch = "If-None-Match"
    public static let requestID = "SpeechRail-Request-Id"
    public static let etag = "ETag"
    public static let receiptID = "SpeechRail-Receipt-Id"
    public static let timingID = "SpeechRail-Timing-Id"
}

public struct JSONValue: Codable, Equatable, Sendable {
    public enum Storage: Equatable, Sendable {
        case null
        case bool(Bool)
        case integer(Int64)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])
    }

    public let storage: Storage

    public init(_ storage: Storage) {
        self.storage = storage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            storage = .null
        } else if let value = try? container.decode(Bool.self) {
            storage = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            storage = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            storage = .number(value)
        } else if let value = try? container.decode(String.self) {
            storage = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            storage = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            storage = .object(value)
        } else {
            throw ServiceContractDecodingError.invalidValue("json_value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public enum ServiceErrorCategory: Equatable, Sendable {
    case conflict
    case notReady
    case busy
    case unauthorized
    case unsupported
    case invalidContract
    case connection
}

public enum ServiceErrorClassifier {
    public static func category(for error: ServiceAPIClientError) -> ServiceErrorCategory {
        switch error {
        case .invalidContract:
            .invalidContract
        case .http(_, let code, _, _, _):
            switch code {
            case "invalid_api_key", "unauthorized", "forbidden":
                .unauthorized
            case "voice_revision_mismatch", "model_revision_mismatch":
                .conflict
            case "backend_busy", "queue_full":
                .busy
            case "backend_not_ready", "service_unavailable", "dependency_missing":
                .notReady
            case "unsupported", "not_supported":
                .unsupported
            default:
                .connection
            }
        case .invalidURL, .invalidResponse, .requestFailed, .requestTimedOut,
             .notModifiedWithoutCache:
            .connection
        }
    }
}

public enum ServiceResponseDecoder {
    public static func decode<Value: Decodable & Sendable>(
        _ data: Data,
        statusCode: Int,
        headers: [String: String],
        cachedValue: Value? = nil
    ) throws -> ServiceConditionalResponse<Value> {
        let metadata = makeMetadata(statusCode: statusCode, headers: headers)
        if statusCode == 304 {
            guard cachedValue != nil else {
                throw ServiceAPIClientError.notModifiedWithoutCache
            }
            return ServiceConditionalResponse(
                value: cachedValue,
                metadata: metadata,
                notModified: true
            )
        }
        guard (200..<300).contains(statusCode) else {
            throw makeError(data: data, metadata: metadata)
        }
        guard !data.isEmpty else {
            throw ServiceAPIClientError.invalidResponse
        }
        do {
            return ServiceConditionalResponse(
                value: try JSONDecoder().decode(Value.self, from: data),
                metadata: metadata
            )
        } catch let error as ServiceContractDecodingError {
            throw error
        } catch {
            throw ServiceAPIClientError.invalidResponse
        }
    }

    public static func decodeAudio(
        _ data: Data,
        statusCode: Int,
        headers: [String: String]
    ) throws -> SpeechAudioResponse {
        let metadata = makeMetadata(statusCode: statusCode, headers: headers)
        guard (200..<300).contains(statusCode) else {
            throw makeError(data: data, metadata: metadata)
        }
        guard !data.isEmpty, let contentType = metadata.value(forHeader: HTTPHeaderNames.contentType),
              contentType.lowercased().hasPrefix("audio/")
        else {
            throw ServiceAPIClientError.invalidResponse
        }
        return SpeechAudioResponse(
            audioData: data,
            contentType: contentType,
            receiptID: metadata.value(forHeader: HTTPHeaderNames.receiptID),
            timingID: metadata.value(forHeader: HTTPHeaderNames.timingID),
            metadata: metadata
        )
    }

    public static func makeMetadata(
        statusCode: Int,
        headers: [String: String]
    ) -> ServiceResponseMetadata {
        ServiceResponseMetadata(
            statusCode: statusCode,
            headers: headers,
            requestID: firstHeader(
                headers,
                names: [HTTPHeaderNames.requestID, "X-Request-Id", "request-id"]
            ),
            etag: firstHeader(headers, names: [HTTPHeaderNames.etag])
        )
    }

    public static func makeError(
        data: Data,
        metadata: ServiceResponseMetadata
    ) -> ServiceAPIClientError {
        let payload = try? JSONDecoder().decode(ServiceErrorEnvelope.self, from: data)
        return .http(
            statusCode: metadata.statusCode,
            code: payload?.error.code ?? "http_\(metadata.statusCode)",
            message: payload?.error.message ?? "SpeechRail request failed",
            requestID: payload?.error.requestID ?? metadata.requestID,
            retryable: payload?.error.retryable ?? (metadata.statusCode >= 500)
        )
    }

    private static func firstHeader(
        _ headers: [String: String],
        names: [String]
    ) -> String? {
        for name in names {
            if let value = headers.first(where: {
                $0.key.caseInsensitiveCompare(name) == .orderedSame
            })?.value {
                return value
            }
        }
        return nil
    }
}

private struct ServiceErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let code: String
        let message: String
        let requestID: String?
        let retryable: Bool

        enum CodingKeys: String, CodingKey {
            case code
            case message
            case requestID = "request_id"
            case retryable
        }
    }

    let error: Payload
}

public enum ModelIdentityAssurance: Codable, Equatable, Sendable {
    case unknown
    case configuredCatalog
    case unknownValue(String)

    public var rawValue: String {
        switch self {
        case .unknown: "unknown"
        case .configuredCatalog: "configured_catalog"
        case let .unknownValue(value): value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "unknown": self = .unknown
        case "configured_catalog": self = .configuredCatalog
        default: self = .unknownValue(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.singleValueContainer().encode(rawValue)
    }
}

public struct ConfiguredModelIdentity: Codable, Equatable, Sendable {
    public let assurance: ModelIdentityAssurance
    public let runtimeRevision: String?
    public let sourceModel: String?
    public let artifact: String?
    public let variant: String?
    public let catalogRevision: String?
    public let quantization: JSONValue?

    public init(
        assurance: ModelIdentityAssurance,
        runtimeRevision: String? = nil,
        sourceModel: String? = nil,
        artifact: String? = nil,
        variant: String? = nil,
        catalogRevision: String? = nil,
        quantization: JSONValue? = nil
    ) {
        self.assurance = assurance
        self.runtimeRevision = runtimeRevision
        self.sourceModel = sourceModel
        self.artifact = artifact
        self.variant = variant
        self.catalogRevision = catalogRevision
        self.quantization = quantization
    }

    enum CodingKeys: String, CodingKey {
        case assurance
        case runtimeRevision = "runtime_revision"
        case sourceModel = "source_model"
        case artifact
        case variant
        case catalogRevision = "catalog_revision"
        case quantization
    }
}

public enum SafeVoiceAvailabilityReason: Codable, Equatable, Sendable {
    case disabled
    case modelIdentityUnknown
    case voiceIncompatible
    case backendNotReady
    case available
    case revoked
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .disabled: "disabled"
        case .modelIdentityUnknown: "model_identity_unknown"
        case .voiceIncompatible: "voice_incompatible"
        case .backendNotReady: "backend_not_ready"
        case .available: "available"
        case .revoked: "voice_revoked"
        case let .unknown(value): value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "disabled": self = .disabled
        case "model_identity_unknown": self = .modelIdentityUnknown
        case "voice_incompatible": self = .voiceIncompatible
        case "backend_not_ready": self = .backendNotReady
        case "available": self = .available
        case "voice_revoked": self = .revoked
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.singleValueContainer().encode(rawValue)
    }
}

public struct SafeVoiceDescriptor: Codable, Equatable, Sendable {
    public let voiceMode: String
    public let locales: [String]
    public let styleTags: [String]
    public let pitchBand: String
    public let timbreFamily: String
    public let baselinePace: String
    public let sourceType: String
    public let metadataMethod: String

    public init(
        voiceMode: String,
        locales: [String],
        styleTags: [String],
        pitchBand: String,
        timbreFamily: String,
        baselinePace: String,
        sourceType: String,
        metadataMethod: String
    ) {
        self.voiceMode = voiceMode
        self.locales = locales
        self.styleTags = styleTags
        self.pitchBand = pitchBand
        self.timbreFamily = timbreFamily
        self.baselinePace = baselinePace
        self.sourceType = sourceType
        self.metadataMethod = metadataMethod
    }

    enum CodingKeys: String, CodingKey {
        case voiceMode = "voice_mode"
        case locales
        case styleTags = "style_tags"
        case pitchBand = "pitch_band"
        case timbreFamily = "timbre_family"
        case baselinePace = "baseline_pace"
        case sourceType = "source_type"
        case metadataMethod = "metadata_method"
    }
}

public enum VoiceIdentityAssurance: Codable, Equatable, Sendable {
    case legacy
    case contentAddressed
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .legacy: "legacy"
        case .contentAddressed: "content_addressed"
        case let .unknown(value): value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "legacy": self = .legacy
        case "content_addressed": self = .contentAddressed
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.singleValueContainer().encode(rawValue)
    }
}

public enum VoiceQualityStatus: Codable, Equatable, Sendable {
    case pass
    case warn
    case reject
    case unevaluated
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .pass: "pass"
        case .warn: "warn"
        case .reject: "reject"
        case .unevaluated: "unevaluated"
        case let .unknown(value): value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "pass": self = .pass
        case "warn": self = .warn
        case "reject": self = .reject
        case "unevaluated": self = .unevaluated
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.singleValueContainer().encode(rawValue)
    }
}

public struct SafeVoiceQualitySummary: Codable, Equatable, Sendable {
    public let status: VoiceQualityStatus?
    public let policyVersion: String?

    enum CodingKeys: String, CodingKey {
        case status
        case policyVersion = "policy_version"
    }
}

public struct SafeVoiceEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let aliases: [String]
    public let mode: String
    public let available: Bool
    public let availabilityReason: SafeVoiceAvailabilityReason
    public let variant: String?
    public let voiceRevision: String?
    public let voiceIdentityAssurance: VoiceIdentityAssurance
    public let model: ConfiguredModelIdentity
    public let descriptors: [SafeVoiceDescriptor]
    public let operations: [String: JSONValue]
    public let qualitySummary: SafeVoiceQualitySummary?
    public let snapshotID: String?

    public init(
        id: String,
        name: String,
        aliases: [String] = [],
        mode: String,
        available: Bool,
        availabilityReason: SafeVoiceAvailabilityReason,
        variant: String? = nil,
        voiceRevision: String? = nil,
        voiceIdentityAssurance: VoiceIdentityAssurance,
        model: ConfiguredModelIdentity,
        descriptors: [SafeVoiceDescriptor],
        operations: [String: JSONValue],
        qualitySummary: SafeVoiceQualitySummary? = nil,
        snapshotID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.mode = mode
        self.available = available
        self.availabilityReason = availabilityReason
        self.variant = variant
        self.voiceRevision = voiceRevision
        self.voiceIdentityAssurance = voiceIdentityAssurance
        self.model = model
        self.descriptors = descriptors
        self.operations = operations
        self.qualitySummary = qualitySummary
        self.snapshotID = snapshotID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case aliases
        case mode
        case available
        case availabilityReason = "availability_reason"
        case variant
        case voiceRevision = "voice_revision"
        case voiceIdentityAssurance = "voice_identity_assurance"
        case model
        case descriptors
        case operations
        case qualitySummary = "quality_summary"
        case snapshotID = "snapshot_id"
    }
}

public struct SafeVoiceList: Codable, Equatable, Sendable {
    public let object: String
    public let snapshotID: String
    public let catalogRevision: String
    public let data: [SafeVoiceEntry]

    public init(object: String = "list", snapshotID: String, catalogRevision: String, data: [SafeVoiceEntry]) {
        self.object = object
        self.snapshotID = snapshotID
        self.catalogRevision = catalogRevision
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case object
        case snapshotID = "snapshot_id"
        case catalogRevision = "catalog_revision"
        case data
    }
}

public struct EffectiveCapabilitySnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let serviceInstanceEpoch: String
    public let catalogRevision: String
    public let snapshotID: String
    public let profile: String?
    public let models: [String: ConfiguredModelIdentity]
    public let voices: [SafeVoiceEntry]
    public let operations: [String: JSONValue]
    public let guarantees: [String: Bool]

    public init(
        schemaVersion: String = "effective_capabilities_v1",
        serviceInstanceEpoch: String,
        catalogRevision: String,
        snapshotID: String,
        profile: String?,
        models: [String: ConfiguredModelIdentity],
        voices: [SafeVoiceEntry],
        operations: [String: JSONValue],
        guarantees: [String: Bool]
    ) {
        self.schemaVersion = schemaVersion
        self.serviceInstanceEpoch = serviceInstanceEpoch
        self.catalogRevision = catalogRevision
        self.snapshotID = snapshotID
        self.profile = profile
        self.models = models
        self.voices = voices
        self.operations = operations
        self.guarantees = guarantees
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case serviceInstanceEpoch = "service_instance_epoch"
        case catalogRevision = "catalog_revision"
        case snapshotID = "snapshot_id"
        case profile
        case models
        case voices
        case operations
        case guarantees
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func required<T: Decodable>(_ key: CodingKeys) throws -> T {
            guard container.contains(key) else {
                throw ServiceContractDecodingError.missingRequiredField(key.stringValue)
            }
            return try container.decode(T.self, forKey: key)
        }

        let schemaVersion: String = try required(.schemaVersion)
        guard schemaVersion == "effective_capabilities_v1" else {
            throw ServiceContractDecodingError.invalidValue("schema_version")
        }
        self.init(
            schemaVersion: schemaVersion,
            serviceInstanceEpoch: try required(.serviceInstanceEpoch),
            catalogRevision: try required(.catalogRevision),
            snapshotID: try required(.snapshotID),
            profile: try container.decodeIfPresent(String.self, forKey: .profile),
            models: try required(.models),
            voices: try required(.voices),
            operations: try required(.operations),
            guarantees: try required(.guarantees)
        )
    }
}

public struct VoiceRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let revision: String
    public let createdAt: String?
    public let active: Bool?
    public let revoked: Bool?

    public init(
        id: String,
        revision: String,
        createdAt: String? = nil,
        active: Bool? = nil,
        revoked: Bool? = nil
    ) {
        self.id = id
        self.revision = revision
        self.createdAt = createdAt
        self.active = active
        self.revoked = revoked
    }

    enum CodingKeys: String, CodingKey {
        case id
        case revision
        case createdAt = "created_at"
        case active
        case revoked
    }
}

public struct VoicePatch: Codable, Equatable, Sendable {
    public let name: String?
    public let instruction: String?
    public let seed: Int?
    public let expectedRevision: String?

    public init(name: String?, instruction: String?, seed: Int?, expectedRevision: String?) {
        self.name = name
        self.instruction = instruction
        self.seed = seed
        self.expectedRevision = expectedRevision
    }

    enum CodingKeys: String, CodingKey {
        case name
        case instruction
        case seed
        case expectedRevision = "expected_revision"
    }
}

public struct VoiceQualityReportSnapshotV2: Codable, Equatable, Sendable {
    public let policyVersion: String?
    public let status: VoiceQualityStatus
    public let runID: String?
    public let testedAt: String?
    public let reference: JSONValue?
    public let synthesis: JSONValue?
    public let failureCodes: [String]

    public init(
        policyVersion: String? = nil,
        status: VoiceQualityStatus,
        runID: String? = nil,
        testedAt: String? = nil,
        reference: JSONValue? = nil,
        synthesis: JSONValue? = nil,
        failureCodes: [String] = []
    ) {
        self.policyVersion = policyVersion
        self.status = status
        self.runID = runID
        self.testedAt = testedAt
        self.reference = reference
        self.synthesis = synthesis
        self.failureCodes = failureCodes
    }

    enum CodingKeys: String, CodingKey {
        case policyVersion = "policy_version"
        case status
        case runID = "run_id"
        case testedAt = "tested_at"
        case reference
        case synthesis
        case failureCodes = "failure_codes"
    }
}

public struct VoiceQualityRunRequest: Codable, Equatable, Sendable {
    public let probeSet: String
    public let runs: Int
    public let includeAudio: Bool

    public init(probeSet: String = "voice_quality_v1_zh", runs: Int = 3, includeAudio: Bool = false) {
        self.probeSet = probeSet
        self.runs = runs
        self.includeAudio = includeAudio
    }

    enum CodingKeys: String, CodingKey {
        case probeSet = "probe_set"
        case runs
        case includeAudio = "include_audio"
    }
}

public struct PronunciationSet: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let revision: String?
    public let entries: [String: String]
    public let revoked: Bool?

    public init(id: String, revision: String? = nil, entries: [String: String] = [:], revoked: Bool? = nil) {
        self.id = id
        self.revision = revision
        self.entries = entries
        self.revoked = revoked
    }
}

public struct PronunciationSetUpdate: Codable, Equatable, Sendable {
    public let id: String
    public let expectedRevision: String?
    public let entries: [String: String]

    public init(id: String, expectedRevision: String? = nil, entries: [String: String]) {
        self.id = id
        self.expectedRevision = expectedRevision
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case id
        case expectedRevision = "expected_revision"
        case entries
    }
}

public enum SpeechVoice: Codable, Equatable, Sendable {
    case name(String)
    case id(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .name(value)
            return
        }
        let object = try container.decode([String: String].self)
        guard let id = object["id"] else {
            throw ServiceContractDecodingError.missingRequiredField("voice.id")
        }
        self = .id(id)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .name(value):
            try encoder.singleValueContainer().encode(value)
        case let .id(value):
            try encoder.singleValueContainer().encode(["id": value])
        }
    }
}

public struct SpeechRequest: Codable, Equatable, Sendable {
    public let model: String
    public let input: String
    public let voice: SpeechVoice
    public let responseFormat: String?
    public let language: String?
    public let instructions: String?
    public let streamFormat: String?
    public let speed: Double?

    public init(
        input: String,
        voice: SpeechVoice,
        model: String,
        responseFormat: String? = nil,
        language: String? = nil,
        instructions: String? = nil,
        streamFormat: String? = nil,
        speed: Double? = nil
    ) {
        self.input = input
        self.voice = voice
        self.model = model
        self.responseFormat = responseFormat
        self.language = language
        self.instructions = instructions
        self.streamFormat = streamFormat
        self.speed = speed
    }

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case responseFormat = "response_format"
        case language
        case instructions
        case streamFormat = "stream_format"
        case speed
    }
}

public struct SpeechRailRequestOptions: Equatable, Sendable {
    public let expectedVoiceRevision: String?
    public let expectedModelRevision: String?
    public let pronunciationSet: String?
    public let receiptMode: String?
    public let timingMode: String?
    public let purpose: String?
    public let latencyBudgetMs: Int?

    public init(
        expectedVoiceRevision: String? = nil,
        expectedModelRevision: String? = nil,
        pronunciationSet: String? = nil,
        receiptMode: String? = nil,
        timingMode: String? = nil,
        purpose: String? = nil,
        latencyBudgetMs: Int? = nil
    ) {
        self.expectedVoiceRevision = expectedVoiceRevision
        self.expectedModelRevision = expectedModelRevision
        self.pronunciationSet = pronunciationSet
        self.receiptMode = receiptMode
        self.timingMode = timingMode
        self.purpose = purpose
        self.latencyBudgetMs = latencyBudgetMs
    }

    public var headers: [String: String] {
        var result: [String: String] = [:]
        if let expectedVoiceRevision {
            result["SpeechRail-Expected-Voice-Revision"] = expectedVoiceRevision
        }
        if let expectedModelRevision {
            result["SpeechRail-Expected-Model-Revision"] = expectedModelRevision
        }
        if let pronunciationSet {
            result["SpeechRail-Pronunciation-Set"] = pronunciationSet
        }
        if let receiptMode {
            result["SpeechRail-Receipt-Mode"] = receiptMode
        }
        if let timingMode {
            result["SpeechRail-Timing-Mode"] = timingMode
        }
        if let purpose {
            result["SpeechRail-Purpose"] = purpose
        }
        if let latencyBudgetMs {
            result["SpeechRail-Latency-Budget-Ms"] = String(latencyBudgetMs)
        }
        return result
    }
}

public struct SpeechAudioResponse: Sendable {
    public let audioData: Data
    public let contentType: String
    public let receiptID: String?
    public let timingID: String?
    public let metadata: ServiceResponseMetadata

    public init(
        audioData: Data,
        contentType: String,
        receiptID: String?,
        timingID: String?,
        metadata: ServiceResponseMetadata
    ) {
        self.audioData = audioData
        self.contentType = contentType
        self.receiptID = receiptID
        self.timingID = timingID
        self.metadata = metadata
    }
}

public enum RenderReceiptStatus: Codable, Equatable, Sendable {
    case pending
    case completed
    case cancelled
    case error
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "completed": self = .completed
        case "cancelled": self = .cancelled
        case "error": self = .error
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        let value: String = switch self {
        case .pending: "pending"
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .error: "error"
        case let .unknown(raw): raw
        }
        try encoder.singleValueContainer().encode(value)
    }
}

public struct RenderReceipt: Codable, Equatable, Sendable {
    public let receiptID: String
    public let requestID: String
    public let responseID: String?
    public let status: RenderReceiptStatus
    public let voice: JSONValue
    public let model: JSONValue
    public let audio: JSONValue
    public let text: JSONValue?
    public let planner: JSONValue?
    public let errorCode: String?
    public let createdAt: Double
    public let completedAt: Double?

    enum CodingKeys: String, CodingKey {
        case receiptID = "receipt_id"
        case requestID = "request_id"
        case responseID = "response_id"
        case status
        case voice
        case model
        case audio
        case text
        case planner
        case errorCode = "error_code"
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}

public enum TimingStatus: Codable, Equatable, Sendable {
    case pending
    case completed
    case unavailable
    case cancelled
    case error
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "completed": self = .completed
        case "unavailable": self = .unavailable
        case "cancelled": self = .cancelled
        case "error": self = .error
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        let value: String = switch self {
        case .pending: "pending"
        case .completed: "completed"
        case .unavailable: "unavailable"
        case .cancelled: "cancelled"
        case .error: "error"
        case let .unknown(raw): raw
        }
        try encoder.singleValueContainer().encode(value)
    }
}

public struct TtsTimingChunk: Codable, Equatable, Sendable {
    public let plannerChunk: Int
    public let textStart: Int
    public let textEnd: Int
    public let audioStartSample: Int
    public let audioEndSample: Int
    public let timingQuality: String
    public let displayStart: Int?
    public let displayEnd: Int?

    enum CodingKeys: String, CodingKey {
        case plannerChunk = "planner_chunk"
        case textStart = "text_start"
        case textEnd = "text_end"
        case audioStartSample = "audio_start_sample"
        case audioEndSample = "audio_end_sample"
        case timingQuality = "timing_quality"
        case displayStart = "display_start"
        case displayEnd = "display_end"
    }
}

public struct TtsTimingResource: Codable, Equatable, Sendable {
    public let timingID: String
    public let requestID: String
    public let status: TimingStatus
    public let timingQuality: String
    public let coordinateSpace: String?
    public let plannerVersion: String?
    public let sampleRate: Int
    public let totalSamples: Int?
    public let displayMapping: [String: JSONValue]
    public let chunks: [TtsTimingChunk]
    public let reason: String?
    public let createdAt: Double
    public let completedAt: Double?

    enum CodingKeys: String, CodingKey {
        case timingID = "timing_id"
        case requestID = "request_id"
        case status
        case timingQuality = "timing_quality"
        case coordinateSpace = "coordinate_space"
        case plannerVersion = "planner_version"
        case sampleRate = "sample_rate"
        case totalSamples = "total_samples"
        case displayMapping = "display_mapping"
        case chunks
        case reason
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}

public struct TranscriptionRequest: Sendable {
    public let audio: Data
    public let filename: String
    public let contentType: String
    public let model: String?
    public let language: String?
    public let languages: [String]
    public let prompt: String?
    public let timestamps: String?
    public let diarized: Bool?
    public let knownSpeakerNames: [String]
    public let knownSpeakerReferences: [String]

    public init(
        audio: Data,
        filename: String = "audio.wav",
        contentType: String = "audio/wav",
        model: String? = nil,
        language: String? = nil,
        languages: [String] = [],
        prompt: String? = nil,
        timestamps: String? = nil,
        diarized: Bool? = nil,
        knownSpeakerNames: [String] = [],
        knownSpeakerReferences: [String] = []
    ) {
        self.audio = audio
        self.filename = filename
        self.contentType = contentType
        self.model = model
        self.language = language
        self.languages = languages
        self.prompt = prompt
        self.timestamps = timestamps
        self.diarized = diarized
        self.knownSpeakerNames = knownSpeakerNames
        self.knownSpeakerReferences = knownSpeakerReferences
    }
}

public struct JobCreateRequest: Codable, Equatable, Sendable {
    public let kind: String
    public let inputReference: String
    public let params: [String: JSONValue]?

    public init(kind: String, inputReference: String, params: [String: JSONValue]? = nil) {
        self.kind = kind
        self.inputReference = inputReference
        self.params = params
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case inputReference = "input_ref"
        case params
    }
}

public struct Job: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let state: String
    public let errorCode: String?
    public let resultReference: String?
    public let queueWaitSeconds: Double?
    public let deadline: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case state
        case errorCode = "error_code"
        case resultReference = "result_ref"
        case queueWaitSeconds = "queue_wait_seconds"
        case deadline
    }
}

public struct JobList: Codable, Equatable, Sendable {
    public let object: String
    public let data: [Job]
    public let nextCursor: String?
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case object
        case data
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

public struct ReadySnapshot: Codable, Equatable, Sendable {
    public let ready: Bool
    public let diarization: JSONValue?
    public let realtimeVAD: JSONValue?

    enum CodingKeys: String, CodingKey {
        case ready
        case diarization
        case realtimeVAD = "realtime_vad"
    }
}

public enum CapabilityDiscoveryState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case notSupported
    case notReady
    case unauthorized
    case invalidContract
    case failed
}

public struct CapabilitySnapshotStore: Equatable, Sendable {
    public private(set) var snapshot: EffectiveCapabilitySnapshot?
    public private(set) var etag: String?
    public private(set) var state: CapabilityDiscoveryState
    private var generation: UInt64

    public init(
        snapshot: EffectiveCapabilitySnapshot? = nil,
        etag: String? = nil,
        state: CapabilityDiscoveryState = .idle
    ) {
        self.snapshot = snapshot
        self.etag = etag
        self.state = state
        self.generation = 0
    }

    public static func loaded(
        snapshot: EffectiveCapabilitySnapshot,
        etag: String?
    ) -> CapabilitySnapshotStore {
        CapabilitySnapshotStore(snapshot: snapshot, etag: etag, state: .loaded)
    }

    public mutating func beginRefresh() -> UInt64 {
        generation &+= 1
        state = .loading
        return generation
    }

    public mutating func apply(
        _ response: ServiceConditionalResponse<EffectiveCapabilitySnapshot>,
        requestToken: UInt64
    ) {
        guard requestToken == generation else { return }
        if response.notModified {
            guard snapshot != nil else {
                state = .invalidContract
                return
            }
            etag = response.metadata.etag ?? etag
            state = .loaded
            return
        }
        guard let value = response.value else {
            state = .invalidContract
            return
        }
        snapshot = value
        etag = response.metadata.etag ?? etag
        state = .loaded
    }

    public mutating func markUnauthorized(
        _ error: ServiceAPIClientError,
        requestToken: UInt64
    ) {
        guard requestToken == generation else { return }
        state = .unauthorized
    }

    public mutating func markUnsupported(requestToken: UInt64) {
        guard requestToken == generation else { return }
        state = .notSupported
    }

    public mutating func markFailure(
        _ error: ServiceAPIClientError,
        requestToken: UInt64
    ) {
        guard requestToken == generation else { return }
        state = switch ServiceErrorClassifier.category(for: error) {
        case .notReady: .notReady
        case .invalidContract: .invalidContract
        case .unauthorized: .unauthorized
        default: .failed
        }
    }
}
