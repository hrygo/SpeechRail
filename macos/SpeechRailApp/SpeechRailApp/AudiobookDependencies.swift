import Foundation
import SpeechRailControlKit

/// T08：有声书工坊窄依赖协议、可注入时钟与组合根容器。
public protocol AudiobookClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemAudiobookClock: AudiobookClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

public struct AudiobookRenderCallRequest: Equatable, Sendable {
    public var text: String
    public var voiceID: String
    public var speed: Double
    public var expectedVoiceRevision: String
    public var expectedModelRevision: String
    public var seed: Int?

    public init(
        text: String,
        voiceID: String,
        speed: Double = AudiobookLimits.defaultRenderSpeed,
        expectedVoiceRevision: String,
        expectedModelRevision: String,
        seed: Int? = nil
    ) {
        self.text = text
        self.voiceID = voiceID
        self.speed = speed
        self.expectedVoiceRevision = expectedVoiceRevision
        self.expectedModelRevision = expectedModelRevision
        self.seed = seed
    }
}

public struct AudiobookRenderCallOutput: Equatable, Sendable {
    public var wavData: Data
    public var voiceRevision: String?
    public var modelRevision: String?
    public var pcmSHA256: String?
    public var requestID: String?
    public var receiptID: String?
    public var recipeSummary: String?
    public var isProvenanceVerified: Bool

    public init(
        wavData: Data,
        voiceRevision: String? = nil,
        modelRevision: String? = nil,
        pcmSHA256: String? = nil,
        requestID: String? = nil,
        receiptID: String? = nil,
        recipeSummary: String? = nil,
        isProvenanceVerified: Bool = true
    ) {
        self.wavData = wavData
        self.voiceRevision = voiceRevision
        self.modelRevision = modelRevision
        self.pcmSHA256 = pcmSHA256
        self.requestID = requestID
        self.receiptID = receiptID
        self.recipeSummary = recipeSummary
        self.isProvenanceVerified = isProvenanceVerified
    }
}

public struct AudiobookLeadVoiceCreationRequest: Equatable, Sendable {
    public var bookID: UUID
    public var roleID: UUID
    public var targetVoiceID: String
    public var voiceName: String
    public var instruction: String
    public var referenceTextCandidates: [String]
    public var seed: Int

    public init(
        bookID: UUID,
        roleID: UUID,
        targetVoiceID: String,
        voiceName: String,
        instruction: String,
        referenceTextCandidates: [String],
        seed: Int
    ) {
        self.bookID = bookID
        self.roleID = roleID
        self.targetVoiceID = targetVoiceID
        self.voiceName = voiceName
        self.instruction = instruction
        self.referenceTextCandidates = referenceTextCandidates
        self.seed = seed
    }
}

public struct AudiobookLeadVoiceCreationOutput: Equatable, Sendable {
    public var voiceID: String
    public var voiceName: String
    public var voiceRevision: String
    public var modelRevision: String

    public init(
        voiceID: String,
        voiceName: String,
        voiceRevision: String,
        modelRevision: String
    ) {
        self.voiceID = voiceID
        self.voiceName = voiceName
        self.voiceRevision = voiceRevision
        self.modelRevision = modelRevision
    }
}

public protocol AudiobookSpeechRenderer: Sendable {
    func fetchEffectiveCapabilities() async throws -> EffectiveCapabilitySnapshot
    func renderFragment(_ request: AudiobookRenderCallRequest) async throws -> AudiobookRenderCallOutput
    func createAndPublishLeadVoice(_ request: AudiobookLeadVoiceCreationRequest) async throws -> AudiobookLeadVoiceCreationOutput
}

public extension AudiobookSpeechRenderer {
    func createAndPublishLeadVoice(_ request: AudiobookLeadVoiceCreationRequest) async throws -> AudiobookLeadVoiceCreationOutput {
        throw ServiceAPIClientError.requestFailed
    }
}

public struct UnavailableAudiobookSpeechRenderer: AudiobookSpeechRenderer {
    public init() {}

    public func fetchEffectiveCapabilities() async throws -> EffectiveCapabilitySnapshot {
        throw ServiceAPIClientError.requestFailed
    }

    public func renderFragment(_ request: AudiobookRenderCallRequest) async throws -> AudiobookRenderCallOutput {
        throw ServiceAPIClientError.requestFailed
    }
}

/// 组合根注入给 `AudiobookWorkflowModel` 的窄依赖集合。
public struct UnavailableControlTransport: SpeechRailControlTransport, Sendable {
    public init() {}
    public func send(_ request: ControlRequest) async throws -> ControlResponse {
        ControlResponse(
            requestID: request.requestID,
            command: request.command,
            status: .unavailable,
            errorCode: .transportUnavailable,
            message: "控制代理传输未连接。"
        )
    }
}

public struct AudiobookDependencies: Sendable {
    public typealias AnalysisClientFactory = @Sendable (AudiobookAnalysisConfigSnapshot) async throws -> any AudiobookAnalysisClient
    public typealias StoreFactory = @Sendable () throws -> AudiobookProjectStore

    public var makeStore: StoreFactory
    public var makeAnalysisClient: AnalysisClientFactory
    public var resolveAnalysisSnapshot: @MainActor @Sendable (Int) -> AudiobookAnalysisConfigSnapshot
    public var speechRenderer: any AudiobookSpeechRenderer
    public var controlTransport: any SpeechRailControlTransport
    public var clock: any AudiobookClock

    public init(
        makeStore: @escaping StoreFactory,
        makeAnalysisClient: @escaping AnalysisClientFactory,
        resolveAnalysisSnapshot: @escaping @MainActor @Sendable (Int) -> AudiobookAnalysisConfigSnapshot,
        speechRenderer: any AudiobookSpeechRenderer,
        controlTransport: any SpeechRailControlTransport = UnavailableControlTransport(),
        clock: any AudiobookClock = SystemAudiobookClock()
    ) {
        self.makeStore = makeStore
        self.makeAnalysisClient = makeAnalysisClient
        self.resolveAnalysisSnapshot = resolveAnalysisSnapshot
        self.speechRenderer = speechRenderer
        self.controlTransport = controlTransport
        self.clock = clock
    }

    public static var unavailable: AudiobookDependencies {
        AudiobookDependencies(
            makeStore: {
                throw AudiobookStoreError.storageUnavailable("未配置有声书存储目录。")
            },
            makeAnalysisClient: { _ in
                throw AudiobookAnalysisError.notConfigured
            },
            resolveAnalysisSnapshot: { generation in
                AudiobookAnalysisConfigSnapshot(
                    configuration: LLMConfiguration(),
                    generation: generation
                )
            },
            speechRenderer: UnavailableAudiobookSpeechRenderer(),
            controlTransport: UnavailableControlTransport(),
            clock: SystemAudiobookClock()
        )
    }
}
