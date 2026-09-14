import Foundation

enum SpeechRailCreatorLimits {
    static let speechTextMaximumLength = 4_096
    static let voiceInstructionMaximumLength = 10_000
    static let referenceTextMinimumLength = 20
    static let referenceTextMaximumLength = 240
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
