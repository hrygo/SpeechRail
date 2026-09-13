import Foundation

public struct DiarizationStatusSnapshot: Codable, Equatable, Sendable {
    public let configured: Bool
    public let ready: Bool
    public let code: String?
    public let message: String
    public let profile: String?

    public init(
        configured: Bool,
        ready: Bool,
        code: String? = nil,
        message: String,
        profile: String? = nil
    ) {
        self.configured = configured
        self.ready = ready
        self.code = code
        self.message = message
        self.profile = profile
    }
}

public struct RealtimeVADStatusSnapshot: Codable, Equatable, Sendable {
    public let configuredEngine: String
    public let resolvedEngine: String
    public let speechAdmissionEnabled: Bool
    public let ready: Bool
    public let code: String?
    public let message: String

    public init(
        configuredEngine: String,
        resolvedEngine: String,
        speechAdmissionEnabled: Bool,
        ready: Bool,
        code: String? = nil,
        message: String
    ) {
        self.configuredEngine = configuredEngine
        self.resolvedEngine = resolvedEngine
        self.speechAdmissionEnabled = speechAdmissionEnabled
        self.ready = ready
        self.code = code
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case configuredEngine = "configured_engine"
        case resolvedEngine = "resolved_engine"
        case speechAdmissionEnabled = "speech_admission_enabled"
        case ready
        case code
        case message
    }
}

public struct HealthSnapshot: Codable, Equatable, Sendable {
    public let status: String?
    public let service: String?
    public let version: String?
    public let backend: String?
    public let profile: SpeechRailProfile?
    public let asrReady: Bool?
    public let ttsReady: Bool?
    public let ttsWarm: Bool?
    public let diarizationReady: Bool?
    public let diarization: DiarizationStatusSnapshot?
    public let asrState: String?
    public let ttsState: String?
    public let streamingState: String?
    public let realtimeVAD: RealtimeVADStatusSnapshot?
    public let ready: Bool?
    public let jobSpoolReady: Bool?

    public init(
        status: String? = nil,
        service: String? = nil,
        version: String? = nil,
        backend: String? = nil,
        profile: SpeechRailProfile? = nil,
        asrReady: Bool? = nil,
        ttsReady: Bool? = nil,
        ttsWarm: Bool? = nil,
        diarizationReady: Bool? = nil,
        diarization: DiarizationStatusSnapshot? = nil,
        asrState: String? = nil,
        ttsState: String? = nil,
        streamingState: String? = nil,
        realtimeVAD: RealtimeVADStatusSnapshot? = nil,
        ready: Bool? = nil,
        jobSpoolReady: Bool? = nil
    ) {
        self.status = status
        self.service = service
        self.version = version
        self.backend = backend
        self.profile = profile
        self.asrReady = asrReady
        self.ttsReady = ttsReady
        self.ttsWarm = ttsWarm
        self.diarizationReady = diarizationReady
        self.diarization = diarization
        self.asrState = asrState
        self.ttsState = ttsState
        self.streamingState = streamingState
        self.realtimeVAD = realtimeVAD
        self.ready = ready
        self.jobSpoolReady = jobSpoolReady
    }

    enum CodingKeys: String, CodingKey {
        case status
        case service
        case version
        case backend
        case profile
        case asrReady = "asr_ready"
        case ttsReady = "tts_ready"
        case ttsWarm = "tts_warm"
        case diarizationReady = "diarization_ready"
        case diarization
        case asrState = "asr_state"
        case ttsState = "tts_state"
        case streamingState = "streaming_state"
        case realtimeVAD = "realtime_vad"
        case ready
        case jobSpoolReady = "job_spool_ready"
    }
}

public struct RuntimeRequestCounts: Codable, Equatable, Sendable {
    public let realtime: Int
    public let batch: Int

    public init(realtime: Int = 0, batch: Int = 0) {
        self.realtime = realtime
        self.batch = batch
    }
}

public struct RuntimeHistogramSummary: Codable, Equatable, Sendable {
    public let count: Int
    public let sum: Double
    public let average: Double

    public init(count: Int, sum: Double, average: Double) {
        self.count = count
        self.sum = sum
        self.average = average
    }

    enum CodingKeys: String, CodingKey {
        case count
        case sum
        case average = "avg"
    }
}

public struct RuntimeMetricsSnapshot: Codable, Equatable, Sendable {
    public let activeRequests: RuntimeRequestCounts
    public let pendingRequests: RuntimeRequestCounts
    public let workers: [String: String]
    public let health: [String: Bool]
    public let counters: [String: Double]
    public let gauges: [String: Double]
    public let histograms: [String: [String: RuntimeHistogramSummary]]
    public let capturedAt: Date

    public init(
        activeRequests: RuntimeRequestCounts = RuntimeRequestCounts(),
        pendingRequests: RuntimeRequestCounts = RuntimeRequestCounts(),
        workers: [String: String] = [:],
        health: [String: Bool] = [:],
        counters: [String: Double] = [:],
        gauges: [String: Double] = [:],
        histograms: [String: [String: RuntimeHistogramSummary]] = [:],
        capturedAt: Date = Date()
    ) {
        self.activeRequests = activeRequests
        self.pendingRequests = pendingRequests
        self.workers = workers
        self.health = health
        self.counters = counters
        self.gauges = gauges
        self.histograms = histograms
        self.capturedAt = capturedAt
    }

    enum CodingKeys: String, CodingKey {
        case activeRequests = "active_requests"
        case pendingRequests = "pending_requests"
        case workers
        case health
        case counters
        case gauges
        case histograms
        case capturedAt = "captured_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeRequests = try container.decodeIfPresent(RuntimeRequestCounts.self, forKey: .activeRequests)
            ?? RuntimeRequestCounts()
        pendingRequests = try container.decodeIfPresent(RuntimeRequestCounts.self, forKey: .pendingRequests)
            ?? RuntimeRequestCounts()
        workers = try container.decodeIfPresent([String: String].self, forKey: .workers) ?? [:]
        health = try container.decodeIfPresent([String: Bool].self, forKey: .health) ?? [:]
        counters = try container.decodeIfPresent([String: Double].self, forKey: .counters) ?? [:]
        gauges = try container.decodeIfPresent([String: Double].self, forKey: .gauges) ?? [:]
        histograms = try container.decodeIfPresent(
            [String: [String: RuntimeHistogramSummary]].self,
            forKey: .histograms
        ) ?? [:]
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
    }
}

public enum ModelArtifactState: String, Codable, Sendable {
    case notDownloaded = "not_downloaded"
    case downloading
    case verified
    case invalid
    case unknown
}

public enum ModelIntegrityState: String, Codable, Sendable {
    case verified
    case mismatch
    case notChecked = "not_checked"
}

public struct ModelQuantizationSnapshot: Codable, Equatable, Sendable {
    public let bits: Int?
    public let groupSize: Int?
    public let format: String

    public init(bits: Int? = nil, groupSize: Int? = nil, format: String) {
        self.bits = bits
        self.groupSize = groupSize
        self.format = format
    }

    enum CodingKeys: String, CodingKey {
        case bits
        case groupSize = "group_size"
        case format
    }
}

public struct ModelArtifactSnapshot: Codable, Equatable, Sendable {
    public let key: String
    public let modelID: String
    public let family: String
    public let variant: String
    public let revision: String
    public let provider: String
    public let repository: String
    public let quantization: ModelQuantizationSnapshot
    public let sizeBytes: Int64
    public let fileCount: Int
    public let requiredBy: [SpeechRailProfile]

    public init(
        key: String,
        modelID: String,
        family: String,
        variant: String,
        revision: String,
        provider: String,
        repository: String,
        quantization: ModelQuantizationSnapshot,
        sizeBytes: Int64,
        fileCount: Int,
        requiredBy: [SpeechRailProfile]
    ) {
        self.key = key
        self.modelID = modelID
        self.family = family
        self.variant = variant
        self.revision = revision
        self.provider = provider
        self.repository = repository
        self.quantization = quantization
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.requiredBy = requiredBy
    }

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
    }
}

public struct ModelArtifactStatusSnapshot: Codable, Equatable, Sendable {
    public let key: String
    public let state: ModelArtifactState
    public let integrity: ModelIntegrityState
    public let verifiedFileCount: Int
    public let totalFileCount: Int

    public init(
        key: String,
        state: ModelArtifactState,
        integrity: ModelIntegrityState,
        verifiedFileCount: Int,
        totalFileCount: Int
    ) {
        self.key = key
        self.state = state
        self.integrity = integrity
        self.verifiedFileCount = verifiedFileCount
        self.totalFileCount = totalFileCount
    }

    enum CodingKeys: String, CodingKey {
        case key
        case state
        case integrity
        case verifiedFileCount = "verified_file_count"
        case totalFileCount = "total_file_count"
    }
}

public struct ModelDiskSnapshot: Codable, Equatable, Sendable {
    public let modelBytes: Int64
    public let freeBytes: Int64

    public init(modelBytes: Int64, freeBytes: Int64) {
        self.modelBytes = modelBytes
        self.freeBytes = freeBytes
    }

    enum CodingKeys: String, CodingKey {
        case modelBytes = "model_bytes"
        case freeBytes = "free_bytes"
    }
}

public struct ModelCatalogSnapshot: Codable, Equatable, Sendable {
    public let artifacts: [ModelArtifactSnapshot]
    public let profiles: [ProfileSummary]

    public init(artifacts: [ModelArtifactSnapshot], profiles: [ProfileSummary]) {
        self.artifacts = artifacts
        self.profiles = profiles
    }
}

public struct ModelStatusSnapshot: Codable, Equatable, Sendable {
    public let artifacts: [ModelArtifactStatusSnapshot]
    public let diarization: [ModelArtifactStatusSnapshot]
    public let disk: ModelDiskSnapshot
    public let activeOperation: OperationSnapshot?

    public init(
        artifacts: [ModelArtifactStatusSnapshot],
        diarization: [ModelArtifactStatusSnapshot] = [],
        disk: ModelDiskSnapshot,
        activeOperation: OperationSnapshot? = nil
    ) {
        self.artifacts = artifacts
        self.diarization = diarization
        self.disk = disk
        self.activeOperation = activeOperation
    }

    enum CodingKeys: String, CodingKey {
        case artifacts
        case diarization
        case disk
        case activeOperation = "active_operation"
    }
}

public struct OperationProgressSnapshot: Codable, Equatable, Sendable {
    public let phase: String?
    public let artifactKey: String?
    public let file: String?
    public let completedBytes: Int64?
    public let expectedBytes: Int64?

    public init(
        phase: String? = nil,
        artifactKey: String? = nil,
        file: String? = nil,
        completedBytes: Int64? = nil,
        expectedBytes: Int64? = nil
    ) {
        self.phase = phase
        self.artifactKey = artifactKey
        self.file = file
        self.completedBytes = completedBytes
        self.expectedBytes = expectedBytes
    }

    enum CodingKeys: String, CodingKey {
        case phase
        case artifactKey = "artifact_key"
        case file
        case completedBytes = "completed_bytes"
        case expectedBytes = "expected_bytes"
    }
}
