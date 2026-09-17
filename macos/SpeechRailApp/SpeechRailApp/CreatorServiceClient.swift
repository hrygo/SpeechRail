import Foundation

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
        public let speechActiveRatio: Double
        public let noiseFloorDecibels: Double
        public let estimatedSNRDecibels: Double
        public let clippingRatio: Double
        public let transcriptMatch: Double?

        enum CodingKeys: String, CodingKey {
            case durationSeconds = "duration_seconds"
            case sampleRate = "sample_rate"
            case speechActiveRatio = "speech_active_ratio"
            case noiseFloorDecibels = "noise_floor_dbfs"
            case estimatedSNRDecibels = "estimated_snr_db"
            case clippingRatio = "clipping_ratio"
            case transcriptMatch = "transcript_match"
        }
    }

    public let policyVersion: String
    public let status: Status
    public let failureCodes: [String]
    public let reference: Reference

    enum CodingKeys: String, CodingKey {
        case policyVersion = "policy_version"
        case status
        case failureCodes = "failure_codes"
        case reference
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
        durationSeconds: Double? = nil
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
    }
}

public protocol SpeechRailCreatorClient: Sendable {
    func fetchVoices() async throws -> [CreatorVoice]
    func fetchVoice(id: String) async throws -> CreatorVoice
    func createSpeech(text: String, voiceID: String, speed: Double) async throws -> Data
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
}

struct UnavailableCreatorClient: SpeechRailCreatorClient {
    func fetchVoices() async throws -> [CreatorVoice] {
        throw ServiceAPIClientError.requestFailed
    }

    func fetchVoice(id: String) async throws -> CreatorVoice {
        throw ServiceAPIClientError.requestFailed
    }

    func createSpeech(text: String, voiceID: String, speed: Double) async throws -> Data {
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
