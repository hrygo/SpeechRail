import Foundation
import SpeechRailControlKit

enum SpeechRailCreatorLimits {
    static let speechTextMaximumLength = 4_096
    static let voiceInstructionMaximumLength = 10_000
    static let referenceTextMinimumLength = 20
    static let referenceTextMaximumLength = 240
    /// 克隆注册的 `name` / `ref_text` 上限来自 OpenAPI `VoiceCloneRequest`
    /// （`name` 32、`ref_text` 2000），比「声音设计」那条链宽一倍以上：
    /// 用户读了一整段提词稿，实际朗读文本本来就可能比 240 字长。
    static let cloneNameMaximumLength = 32
    static let cloneReferenceTextMaximumLength = 2_000
}

/// `GET /v1/voices/clone/prompts` 的一段官方提词稿（`ClonePromptItem`）。
public struct ClonePrompt: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let category: String
    public let title: String
    public let script: String
    public let tips: String

    public init(id: String, category: String, title: String, script: String, tips: String) {
        self.id = id
        self.category = category
        self.title = title
        self.script = script
        self.tips = tips
    }
}

/// 参考音频的质量报告（OpenAPI `VoiceQualityReport`）。
///
/// 只解码界面真正会说出口的字段：结论、失败码与参考段的量测。`synthesis` 是
/// 「输出验收」那一半，注册这一刻它必然是未评估的（`synthesis_validation`），
/// 所以这里保留它但不在注册页展示（REDESIGN-SPEC §13.2）。
public struct VoiceQualityReportSnapshot: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pass
        case warn
        case reject
        case unevaluated
    }

    public struct Reference: Codable, Equatable, Sendable {
        public let durationSeconds: Double
        public let sampleRate: Int
        public let channels: Int
        public let speechActiveRatio: Double
        public let noiseFloorDecibels: Double
        public let estimatedSNRDecibels: Double
        public let clippingRatio: Double
        public let leadingSilenceSeconds: Double
        public let trailingSilenceSeconds: Double
        public let transcriptMatch: Double?

        public init(
            durationSeconds: Double,
            sampleRate: Int,
            channels: Int = 1,
            speechActiveRatio: Double,
            noiseFloorDecibels: Double,
            estimatedSNRDecibels: Double,
            clippingRatio: Double,
            leadingSilenceSeconds: Double = 0,
            trailingSilenceSeconds: Double = 0,
            transcriptMatch: Double?
        ) {
            self.durationSeconds = durationSeconds
            self.sampleRate = sampleRate
            self.channels = channels
            self.speechActiveRatio = speechActiveRatio
            self.noiseFloorDecibels = noiseFloorDecibels
            self.estimatedSNRDecibels = estimatedSNRDecibels
            self.clippingRatio = clippingRatio
            self.leadingSilenceSeconds = leadingSilenceSeconds
            self.trailingSilenceSeconds = trailingSilenceSeconds
            self.transcriptMatch = transcriptMatch
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
            sampleRate = try container.decode(Int.self, forKey: .sampleRate)
            channels = try container.decodeIfPresent(Int.self, forKey: .channels) ?? 1
            speechActiveRatio = try container.decode(Double.self, forKey: .speechActiveRatio)
            noiseFloorDecibels = try container.decode(Double.self, forKey: .noiseFloorDecibels)
            estimatedSNRDecibels = try container.decode(Double.self, forKey: .estimatedSNRDecibels)
            clippingRatio = try container.decode(Double.self, forKey: .clippingRatio)
            leadingSilenceSeconds = try container.decodeIfPresent(
                Double.self,
                forKey: .leadingSilenceSeconds
            ) ?? 0
            trailingSilenceSeconds = try container.decodeIfPresent(
                Double.self,
                forKey: .trailingSilenceSeconds
            ) ?? 0
            transcriptMatch = try container.decodeIfPresent(Double.self, forKey: .transcriptMatch)
        }

        enum CodingKeys: String, CodingKey {
            case durationSeconds = "duration_seconds"
            case sampleRate = "sample_rate"
            case channels
            case speechActiveRatio = "speech_active_ratio"
            case noiseFloorDecibels = "noise_floor_dbfs"
            case estimatedSNRDecibels = "estimated_snr_db"
            case clippingRatio = "clipping_ratio"
            case leadingSilenceSeconds = "leading_silence_seconds"
            case trailingSilenceSeconds = "trailing_silence_seconds"
            case transcriptMatch = "transcript_match"
        }
    }

    public struct Synthesis: Codable, Equatable, Sendable {
        public let probeCount: Int?
        public let successfulProbeCount: Int?
        public let activeRMSDecibels: Double?
        public let peakDecibels: Double?
        public let chunkJumpP95Decibels: Double?
        public let clippingRatio: Double?
        public let deterministic: Bool?
        public let transcriptMatch: Double?
        public let intelligibilityEvaluated: Bool?

        public init(
            probeCount: Int? = nil,
            successfulProbeCount: Int? = nil,
            activeRMSDecibels: Double? = nil,
            peakDecibels: Double? = nil,
            chunkJumpP95Decibels: Double? = nil,
            clippingRatio: Double? = nil,
            deterministic: Bool? = nil,
            transcriptMatch: Double? = nil,
            intelligibilityEvaluated: Bool? = nil
        ) {
            self.probeCount = probeCount
            self.successfulProbeCount = successfulProbeCount
            self.activeRMSDecibels = activeRMSDecibels
            self.peakDecibels = peakDecibels
            self.chunkJumpP95Decibels = chunkJumpP95Decibels
            self.clippingRatio = clippingRatio
            self.deterministic = deterministic
            self.transcriptMatch = transcriptMatch
            self.intelligibilityEvaluated = intelligibilityEvaluated
        }

        enum CodingKeys: String, CodingKey {
            case probeCount = "probe_count"
            case successfulProbeCount = "successful_probe_count"
            case activeRMSDecibels = "active_rms_dbfs"
            case peakDecibels = "peak_dbfs"
            case chunkJumpP95Decibels = "chunk_jump_p95_db"
            case clippingRatio = "clipping_ratio"
            case deterministic
            case transcriptMatch = "transcript_match"
            case intelligibilityEvaluated = "intelligibility_evaluated"
        }
    }

    public let policyVersion: String
    public let status: Status
    public let runID: String?
    public let testedAt: String?
    public let failureCodes: [String]
    public let reference: Reference
    public let synthesis: Synthesis?

    public init(
        policyVersion: String,
        status: Status,
        runID: String? = nil,
        testedAt: String? = nil,
        failureCodes: [String],
        reference: Reference,
        synthesis: Synthesis? = nil
    ) {
        self.policyVersion = policyVersion
        self.status = status
        self.runID = runID
        self.testedAt = testedAt
        self.failureCodes = failureCodes
        self.reference = reference
        self.synthesis = synthesis
    }

    enum CodingKeys: String, CodingKey {
        case policyVersion = "policy_version"
        case status
        case runID = "run_id"
        case testedAt = "tested_at"
        case failureCodes = "failure_codes"
        case reference
        case synthesis
    }
}

public struct VoiceCreationSnapshot: Codable, Equatable, Sendable {
    public let origin: String?
    public let method: String?
    public let modelArtifact: String?
    public let modelRevision: String?
    public let seed: Int?
    public let instructionSHA256: String?
    public let referenceTextSHA256: String?
    public let referenceAudioSHA256: String?
    public let preprocessingVersion: String?

    public init(
        origin: String? = nil,
        method: String? = nil,
        modelArtifact: String? = nil,
        modelRevision: String? = nil,
        seed: Int? = nil,
        instructionSHA256: String? = nil,
        referenceTextSHA256: String? = nil,
        referenceAudioSHA256: String? = nil,
        preprocessingVersion: String? = nil
    ) {
        self.origin = origin
        self.method = method
        self.modelArtifact = modelArtifact
        self.modelRevision = modelRevision
        self.seed = seed
        self.instructionSHA256 = instructionSHA256
        self.referenceTextSHA256 = referenceTextSHA256
        self.referenceAudioSHA256 = referenceAudioSHA256
        self.preprocessingVersion = preprocessingVersion
    }

    enum CodingKeys: String, CodingKey {
        case origin
        case method
        case modelArtifact = "model_artifact"
        case modelRevision = "model_revision"
        case seed
        case instructionSHA256 = "instruction_sha256"
        case referenceTextSHA256 = "reference_text_sha256"
        case referenceAudioSHA256 = "reference_audio_sha256"
        case preprocessingVersion = "preprocessing_version"
    }
}

public struct CreatorVoiceCapabilities: Codable, Equatable, Sendable {
    public let supportsSpeaker: Bool
    public let supportsInstruction: Bool
    public let supportsClone: Bool

    public init(
        supportsSpeaker: Bool = false,
        supportsInstruction: Bool = false,
        supportsClone: Bool = false
    ) {
        self.supportsSpeaker = supportsSpeaker
        self.supportsInstruction = supportsInstruction
        self.supportsClone = supportsClone
    }

    enum CodingKeys: String, CodingKey {
        case supportsSpeaker = "supports_speaker"
        case supportsInstruction = "supports_instruction"
        case supportsClone = "supports_clone"
    }
}

public struct CreatorVoice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let instruction: String
    public let seed: Int?
    public let aliases: [String]
    public let isDefault: Bool
    public let isSystem: Bool
    public let createdAt: Double
    public let available: Bool
    public let variant: String?
    public let capabilities: CreatorVoiceCapabilities
    public let mode: String?
    public let refText: String?
    public let durationSeconds: Double?
    public let revision: String?
    public let revoked: Bool
    public let availabilityReason: SafeVoiceAvailabilityReason?
    public let quality: VoiceQualityReportSnapshotV2?
    public let creation: VoiceCreationSnapshot?

    public init(
        id: String,
        name: String,
        description: String = "",
        instruction: String = "",
        seed: Int? = nil,
        aliases: [String] = [],
        isDefault: Bool = false,
        isSystem: Bool = false,
        createdAt: Double = 0,
        available: Bool = false,
        variant: String? = nil,
        capabilities: CreatorVoiceCapabilities = CreatorVoiceCapabilities(),
        mode: String? = nil,
        refText: String? = nil,
        durationSeconds: Double? = nil,
        revision: String? = nil,
        revoked: Bool = false,
        availabilityReason: SafeVoiceAvailabilityReason? = nil,
        quality: VoiceQualityReportSnapshotV2? = nil,
        creation: VoiceCreationSnapshot? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.instruction = instruction
        self.seed = seed
        self.aliases = aliases
        self.isDefault = isDefault
        self.isSystem = isSystem
        self.createdAt = createdAt
        self.available = available
        self.variant = variant
        self.capabilities = capabilities
        self.mode = mode
        self.refText = refText
        self.durationSeconds = durationSeconds
        self.revision = revision
        self.revoked = revoked
        self.availabilityReason = availabilityReason
        self.quality = quality
        self.creation = creation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        instruction = try container.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        seed = try container.decodeIfPresent(Int.self, forKey: .seed)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        isSystem = try container.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
        capabilities = try container.decodeIfPresent(
            CreatorVoiceCapabilities.self,
            forKey: .capabilities
        ) ?? CreatorVoiceCapabilities()
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        refText = try container.decodeIfPresent(String.self, forKey: .refText)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        revoked = try container.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
        availabilityReason = try container.decodeIfPresent(
            SafeVoiceAvailabilityReason.self,
            forKey: .availabilityReason
        )
        quality = try container.decodeIfPresent(VoiceQualityReportSnapshotV2.self, forKey: .quality)
        creation = try container.decodeIfPresent(VoiceCreationSnapshot.self, forKey: .creation)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case instruction
        case seed
        case aliases
        case isDefault = "is_default"
        case isSystem = "is_system"
        case createdAt = "created_at"
        case available
        case variant
        case capabilities
        case mode
        case refText = "ref_text"
        case durationSeconds = "duration_seconds"
        case revision
        case revoked
        case availabilityReason = "availability_reason"
        case quality
        case creation
    }
}

public protocol SpeechRailCreatorClient: Sendable {
    func fetchVoices() async throws -> [CreatorVoice]
    func fetchVoice(id: String) async throws -> CreatorVoice
    func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions
    ) async throws -> Data
    func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data
    func registerVoiceDesign(
        id: String,
        name: String,
        instruction: String,
        referenceText: String,
        seed: Int
    ) async throws -> CreatorVoice
    func fetchClonePrompts() async throws -> [ClonePrompt]
    func validateVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?
    ) async throws -> VoiceQualityReportSnapshot
    func registerVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?,
        idempotencyKey: String?
    ) async throws -> CreatorVoice
    func updateVoice(
        id: String,
        name: String?,
        instruction: String?,
        seed: Int?
    ) async throws -> CreatorVoice
    func deleteVoice(id: String) async throws

    func createVoice(
        name: String,
        instruction: String,
        id: String?,
        seed: Int?
    ) async throws -> CreatorVoice
    func fetchVoiceRevisions(id: String) async throws -> [VoiceRevision]
    func updateVoice(
        id: String,
        name: String?,
        instruction: String?,
        seed: Int?,
        expectedRevision: String?
    ) async throws -> VoiceRevisionMutation
    func rollbackVoice(
        id: String,
        targetRevision: String,
        expectedRevision: String
    ) async throws -> VoiceRevisionMutation
    func revokeVoiceRevision(id: String, revision: String) async throws -> VoiceRevisionMutation
    func fetchPronunciationSet(id: String, revision: String) async throws -> PronunciationSet
    func upsertPronunciationSet(
        id: String,
        expectedRevision: String?,
        entries: [PronunciationEntry]
    ) async throws -> PronunciationSet
    func revokePronunciationRevision(id: String, revision: String) async throws -> PronunciationSet
    func deletePronunciationSet(id: String) async throws
    func runVoiceQuality(
        id: String,
        request: VoiceQualityRunRequest
    ) async throws -> VoiceQualityReportSnapshotV2
}

public extension SpeechRailCreatorClient {
    func createVoice(
        name: String,
        instruction: String,
        id: String?,
        seed: Int?
    ) async throws -> CreatorVoice {
        throw ServiceAPIClientError.http(
            statusCode: 501,
            code: "unsupported",
            message: "voice creation is unsupported by this client",
            requestID: nil,
            retryable: false
        )
    }

    func fetchVoiceRevisions(id: String) async throws -> [VoiceRevision] {
        throw ServiceAPIClientError.http(
            statusCode: 501,
            code: "unsupported",
            message: "voice revisions are unsupported by this client",
            requestID: nil,
            retryable: false
        )
    }

    func updateVoice(
        id: String,
        name: String?,
        instruction: String?,
        seed: Int?,
        expectedRevision: String?
    ) async throws -> VoiceRevisionMutation {
        throw ServiceAPIClientError.http(
            statusCode: 501,
            code: "unsupported",
            message: "conditional voice updates are unsupported by this client",
            requestID: nil,
            retryable: false
        )
    }

    func rollbackVoice(
        id: String,
        targetRevision: String,
        expectedRevision: String
    ) async throws -> VoiceRevisionMutation {
        throw ServiceAPIClientError.http(
            statusCode: 501,
            code: "unsupported",
            message: "voice rollback is unsupported by this client",
            requestID: nil,
            retryable: false
        )
    }

    func revokeVoiceRevision(id: String, revision: String) async throws -> VoiceRevisionMutation {
        throw ServiceAPIClientError.http(
            statusCode: 501,
            code: "unsupported",
            message: "voice revision revocation is unsupported by this client",
            requestID: nil,
            retryable: false
        )
    }

    func fetchPronunciationSet(id: String, revision: String) async throws -> PronunciationSet {
        throw ServiceAPIClientError.http(
            statusCode: 501,
            code: "unsupported",
            message: "pronunciation sets are unsupported by this client",
            requestID: nil,
            retryable: false
        )
    }

    func upsertPronunciationSet(
        id: String,
        expectedRevision: String?,
        entries: [PronunciationEntry]
    ) async throws -> PronunciationSet {
        throw ServiceAPIClientError.http(
            statusCode: 501,
            code: "unsupported",
            message: "pronunciation sets are unsupported by this client",
            requestID: nil,
            retryable: false
        )
    }

    func revokePronunciationRevision(id: String, revision: String) async throws -> PronunciationSet {
        throw ServiceAPIClientError.http(
            statusCode: 501,
            code: "unsupported",
            message: "pronunciation revisions are unsupported by this client",
            requestID: nil,
            retryable: false
        )
    }

    func deletePronunciationSet(id: String) async throws {
        throw ServiceAPIClientError.http(
            statusCode: 501,
            code: "unsupported",
            message: "pronunciation sets are unsupported by this client",
            requestID: nil,
            retryable: false
        )
    }

    func runVoiceQuality(
        id: String,
        request: VoiceQualityRunRequest
    ) async throws -> VoiceQualityReportSnapshotV2 {
        throw ServiceAPIClientError.http(
            statusCode: 501,
            code: "unsupported",
            message: "voice quality runs are unsupported by this client",
            requestID: nil,
            retryable: false
        )
    }
}

struct UnavailableCreatorClient: SpeechRailCreatorClient {
    func fetchVoices() async throws -> [CreatorVoice] {
        throw ServiceAPIClientError.requestFailed
    }

    func fetchVoice(id: String) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions
    ) async throws -> Data {
        throw ServiceAPIClientError.requestFailed
    }

    func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        throw ServiceAPIClientError.requestFailed
    }

    func registerVoiceDesign(
        id: String,
        name: String,
        instruction: String,
        referenceText: String,
        seed: Int
    ) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func fetchClonePrompts() async throws -> [ClonePrompt] {
        throw ServiceAPIClientError.requestFailed
    }

    func validateVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?
    ) async throws -> VoiceQualityReportSnapshot {
        throw ServiceAPIClientError.requestFailed
    }

    func registerVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?,
        idempotencyKey: String?
    ) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func updateVoice(
        id: String,
        name: String?,
        instruction: String?,
        seed: Int?
    ) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func deleteVoice(id: String) async throws {
        throw ServiceAPIClientError.requestFailed
    }
}
