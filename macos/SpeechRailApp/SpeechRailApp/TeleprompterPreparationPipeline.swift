import Foundation
import OSLog

public enum TeleprompterAIStage: String, Codable, Equatable, Sendable {
    case preparation
    case grouping
    case rewrite
    case map
    case reduce
    case analysis
}

public enum TeleprompterAIObservationKind: String, Codable, Equatable, Sendable {
    case runStarted = "run_started"
    case runFinished = "run_finished"
    case callStarted = "call_started"
    case callFinished = "call_finished"
    case callFailed = "call_failed"
    case providerRequestStarted = "provider_request_started"
    case providerResponse = "provider_response"
    case providerFailed = "provider_failed"
}

public struct TeleprompterAICallContext: Codable, Equatable, Sendable {
    public let runID: String
    public let requestID: String
    public let stage: TeleprompterAIStage
    public let itemIndex: Int?
    public let itemCount: Int?
    public let attempt: Int

    public init(
        runID: String,
        requestID: String,
        stage: TeleprompterAIStage,
        itemIndex: Int? = nil,
        itemCount: Int? = nil,
        attempt: Int = 0
    ) {
        self.runID = runID
        self.requestID = requestID
        self.stage = stage
        self.itemIndex = itemIndex
        self.itemCount = itemCount
        self.attempt = max(0, attempt)
    }
}

public struct TeleprompterAIObservation: Codable, Equatable, Sendable {
    public let kind: TeleprompterAIObservationKind
    public let component: String
    public let context: TeleprompterAICallContext?
    public let elapsedMilliseconds: Int?
    public let httpStatus: Int?
    public let responseBytes: Int?
    public let choiceCount: Int?
    public let finishReason: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let reasoningTokens: Int?
    public let model: String?
    public let endpointHost: String?
    public let transportAttempt: Int?
    public let operation: LLMOperation?
    public let compatibilityMode: LLMCompatibilityMode?
    public let thinkingControl: String?
    public let structuredOutputMode: LLMStructuredOutputMode?
    public let outcome: String?
    public let errorCode: String?

    public init(
        kind: TeleprompterAIObservationKind,
        component: String = "pipeline",
        context: TeleprompterAICallContext? = nil,
        elapsedMilliseconds: Int? = nil,
        httpStatus: Int? = nil,
        responseBytes: Int? = nil,
        choiceCount: Int? = nil,
        finishReason: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        model: String? = nil,
        endpointHost: String? = nil,
        transportAttempt: Int? = nil,
        operation: LLMOperation? = nil,
        compatibilityMode: LLMCompatibilityMode? = nil,
        thinkingControl: String? = nil,
        structuredOutputMode: LLMStructuredOutputMode? = nil,
        outcome: String? = nil,
        errorCode: String? = nil
    ) {
        self.kind = kind
        self.component = component
        self.context = context
        self.elapsedMilliseconds = elapsedMilliseconds
        self.httpStatus = httpStatus
        self.responseBytes = responseBytes
        self.choiceCount = choiceCount
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.model = model
        self.endpointHost = endpointHost
        self.transportAttempt = transportAttempt
        self.operation = operation
        self.compatibilityMode = compatibilityMode
        self.thinkingControl = thinkingControl
        self.structuredOutputMode = structuredOutputMode
        self.outcome = outcome
        self.errorCode = errorCode
    }
}

public typealias TeleprompterAIObservationHandler = @Sendable (TeleprompterAIObservation) -> Void

public struct TeleprompterAIMetricHistogram: Codable, Equatable, Sendable {
    public let count: Int
    public let sumMilliseconds: Int
    /// Cumulative upper-bound buckets, suitable for local aggregation or Prometheus conversion.
    public let buckets: [String: Int]

    public init(count: Int, sumMilliseconds: Int, buckets: [String: Int]) {
        self.count = count
        self.sumMilliseconds = sumMilliseconds
        self.buckets = buckets
    }
}

public struct TeleprompterAIMetricsSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let recordType: String
    public let capturedAt: Date
    /// Keys contain only bounded dimensions: stage, operation, mode and outcome/error code.
    public let counters: [String: Int]
    public let histograms: [String: TeleprompterAIMetricHistogram]

    public init(
        schemaVersion: Int = 1,
        recordType: String = "teleprompter_ai_metrics",
        capturedAt: Date,
        counters: [String: Int],
        histograms: [String: TeleprompterAIMetricHistogram]
    ) {
        self.schemaVersion = schemaVersion
        self.recordType = recordType
        self.capturedAt = capturedAt
        self.counters = counters
        self.histograms = histograms
    }
}

private struct TeleprompterAIEventRecord: Codable {
    let schemaVersion: Int
    let recordType: String
    let capturedAt: Date
    let observation: TeleprompterAIObservation

    init(capturedAt: Date, observation: TeleprompterAIObservation) {
        self.schemaVersion = 1
        self.recordType = "teleprompter_ai_event"
        self.capturedAt = capturedAt
        self.observation = observation
    }
}

/// App-side LLM observability sink.
///
/// Event JSONL is intentionally append-only and contains only the already-redacted
/// observation metadata. Metric aggregation happens on the same serial queue and
/// is flushed as a daily cumulative snapshot when a preparation run or standalone
/// provider request finishes. File I/O is fail-open and never runs on the provider
/// request task.
public final class TeleprompterAIObservationRecorder: @unchecked Sendable {
    private static let durationBuckets: [(name: String, upperBound: Int)] = [
        ("le_100", 100),
        ("le_250", 250),
        ("le_500", 500),
        ("le_1000", 1_000),
        ("le_2500", 2_500),
        ("le_5000", 5_000),
        ("le_10000", 10_000),
        ("le_30000", 30_000),
        ("le_60000", 60_000),
        ("le_120000", 120_000),
    ]

    private static let logger = Logger(
        subsystem: "com.speechrail.desktop",
        category: "teleprompter.ai.recorder"
    )

    private let location: ObservabilityLocation
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.speechrail.teleprompter-ai-observability")
    private var counters: [String: Int] = [:]
    private var histograms: [String: TeleprompterAIMetricHistogram] = [:]

    public init(
        location: ObservabilityLocation = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.location = location
        self.now = now
    }

    public func record(_ observation: TeleprompterAIObservation) {
        let capturedAt = now()
        queue.async { [self] in
            updateMetrics(for: observation)
            append(
                TeleprompterAIEventRecord(capturedAt: capturedAt, observation: observation),
                to: eventFileURL(for: capturedAt)
            )
            let isTerminalProviderObservation = observation.context == nil
                && (observation.kind == .providerResponse || observation.kind == .providerFailed)
            if observation.kind == .runFinished || isTerminalProviderObservation {
                append(snapshot(capturedAt: capturedAt), to: metricsFileURL(for: capturedAt))
            }
        }
    }

    public func flush() {
        queue.sync {}
    }

    public func snapshot() -> TeleprompterAIMetricsSnapshot {
        queue.sync { snapshot(capturedAt: now()) }
    }

    public func eventFileURL(for date: Date) -> URL {
        location.logDirectory
            .appendingPathComponent("teleprompter-ai", isDirectory: true)
            .appendingPathComponent("events-\(Self.dateStamp(for: date)).jsonl")
    }

    public func metricsFileURL(for date: Date) -> URL {
        location.historyDirectory
            .appendingPathComponent("teleprompter-ai", isDirectory: true)
            .appendingPathComponent("metrics-\(Self.dateStamp(for: date)).jsonl")
    }

    private func updateMetrics(for observation: TeleprompterAIObservation) {
        let dimensions = dimensions(for: observation)
        switch observation.kind {
        case .providerRequestStarted:
            increment("speechrail_llm_provider_requests_total|\(dimensions)")
            if (observation.transportAttempt ?? 0) > 0 {
                increment(
                    "speechrail_llm_provider_retries_total|operation=\(label(observation.operation?.rawValue))|mode=\(label(observation.compatibilityMode?.rawValue))"
                )
            }
            if observation.thinkingControl == "omitted_after_rejection" {
                increment(
                    "speechrail_llm_thinking_control_retries_total|operation=\(label(observation.operation?.rawValue))|mode=\(label(observation.compatibilityMode?.rawValue))"
                )
            }
        case .providerResponse:
            increment(
                "speechrail_llm_provider_responses_total|\(dimensions)|outcome=\(label(observation.outcome))"
            )
        case .providerFailed:
            increment(
                "speechrail_llm_provider_failures_total|\(dimensions)|error=\(label(observation.errorCode))"
            )
        case .callStarted:
            if (observation.context?.attempt ?? 0) > 0 {
                increment(
                    "speechrail_llm_pipeline_retries_total|stage=\(label(observation.context?.stage.rawValue))"
                )
            }
        case .callFinished:
            increment("speechrail_llm_calls_total|\(dimensions)|outcome=completed")
        case .callFailed:
            increment(
                "speechrail_llm_call_failures_total|\(dimensions)|error=\(label(observation.errorCode))"
            )
        case .runStarted:
            break
        case .runFinished:
            increment("speechrail_llm_runs_total|outcome=\(label(observation.outcome))")
        }

        if let reasoningTokens = observation.reasoningTokens, reasoningTokens > 0 {
            increment(
                "speechrail_llm_reasoning_tokens_total|operation=\(label(observation.operation?.rawValue))|mode=\(label(observation.compatibilityMode?.rawValue))",
                by: reasoningTokens
            )
        }

        guard let elapsed = observation.elapsedMilliseconds, elapsed >= 0,
              let metricName = durationMetricName(for: observation.kind) else {
            return
        }
        let key = "\(metricName)|\(dimensions)|outcome=\(label(observation.outcome))"
        var histogram = histograms[key] ?? .init(count: 0, sumMilliseconds: 0, buckets: [:])
        var buckets = histogram.buckets
        for bucket in Self.durationBuckets where elapsed <= bucket.upperBound {
            buckets[bucket.name, default: 0] += 1
        }
        buckets["le_inf", default: 0] += 1
        histogram = .init(
            count: histogram.count + 1,
            sumMilliseconds: histogram.sumMilliseconds + elapsed,
            buckets: buckets
        )
        histograms[key] = histogram
    }

    private func increment(_ key: String, by value: Int = 1) {
        counters[key, default: 0] += value
    }

    private func snapshot(capturedAt: Date) -> TeleprompterAIMetricsSnapshot {
        .init(
            capturedAt: capturedAt,
            counters: counters,
            histograms: histograms
        )
    }

    private func append<T: Encodable>(_ value: T, to url: URL) {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(value)
            data.append(0x0A)
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Observability is fail-open: a full or unavailable log directory must
            // never turn a successful provider response into an application error.
            Self.logger.error(
                "append_failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func durationMetricName(for kind: TeleprompterAIObservationKind) -> String? {
        switch kind {
        case .providerResponse, .providerFailed:
            "speechrail_llm_provider_duration_ms"
        case .callFinished, .callFailed:
            "speechrail_llm_call_duration_ms"
        case .runFinished:
            "speechrail_llm_run_duration_ms"
        default:
            nil
        }
    }

    private func dimensions(for observation: TeleprompterAIObservation) -> String {
        [
            "stage=\(label(observation.context?.stage.rawValue))",
            "operation=\(label(observation.operation?.rawValue))",
            "mode=\(label(observation.compatibilityMode?.rawValue))",
        ].joined(separator: "|")
    }

    private func label(_ value: String?) -> String {
        let value = value?.isEmpty == false ? value! : "unknown"
        let bounded = value.prefix(48)
        let normalized = bounded.map { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
                ? String(character)
                : "_"
        }.joined()
        return normalized.isEmpty ? "unknown" : normalized
    }

    private static func dateStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private final class TeleprompterAIRecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: TeleprompterAIObservationRecorder?

    func install(_ recorder: TeleprompterAIObservationRecorder?) {
        lock.lock()
        self.recorder = recorder
        lock.unlock()
    }

    func record(_ observation: TeleprompterAIObservation) {
        lock.lock()
        let recorder = self.recorder
        lock.unlock()
        recorder?.record(observation)
    }
}

public enum TeleprompterAIObservability {
    private static let recorderBox = TeleprompterAIRecorderBox()

    private static let logger = Logger(
        subsystem: "com.speechrail.desktop",
        category: "teleprompter.ai"
    )

    private static let applicationVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version)(\(build))"
    }()

    public static func emit(
        _ observation: TeleprompterAIObservation,
        to handler: TeleprompterAIObservationHandler? = nil
    ) {
        handler?(observation)
        recorderBox.record(observation)

        let context = observation.context
        let message = [
            "app=\(applicationVersion)",
            "kind=\(observation.kind.rawValue)",
            "component=\(observation.component)",
            "run_id=\(context?.runID ?? "-")",
            "request_id=\(context?.requestID ?? "-")",
            "stage=\(context?.stage.rawValue ?? "-")",
            "index=\(context?.itemIndex.map(String.init) ?? "-")",
            "count=\(context?.itemCount.map(String.init) ?? "-")",
            "attempt=\(context.map { String($0.attempt) } ?? "-")",
            "elapsed_ms=\(observation.elapsedMilliseconds.map(String.init) ?? "-")",
            "http_status=\(observation.httpStatus.map(String.init) ?? "-")",
            "response_bytes=\(observation.responseBytes.map(String.init) ?? "-")",
            "choices=\(observation.choiceCount.map(String.init) ?? "-")",
            "finish=\(observation.finishReason ?? "-")",
            "prompt_tokens=\(observation.promptTokens.map(String.init) ?? "-")",
            "completion_tokens=\(observation.completionTokens.map(String.init) ?? "-")",
            "reasoning_tokens=\(observation.reasoningTokens.map(String.init) ?? "-")",
            "model=\(observation.model ?? "-")",
            "endpoint_host=\(observation.endpointHost ?? "-")",
            "transport_attempt=\(observation.transportAttempt.map(String.init) ?? "-")",
            "operation=\(observation.operation?.rawValue ?? "-")",
            "compatibility_mode=\(observation.compatibilityMode?.rawValue ?? "-")",
            "thinking_control=\(observation.thinkingControl ?? "-")",
            "structured_output_mode=\(observation.structuredOutputMode?.rawValue ?? "-")",
            "outcome=\(observation.outcome ?? "-")",
            "error_code=\(observation.errorCode ?? "-")"
        ].joined(separator: " ")

        switch observation.kind {
        case .callFailed, .providerFailed:
            logger.error("\(message, privacy: .public)")
        default:
            logger.info("\(message, privacy: .public)")
        }
    }

    public static func install(recorder: TeleprompterAIObservationRecorder?) {
        recorderBox.install(recorder)
    }

    public static func errorCode(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? LLMError {
            switch error {
            case .notConfigured: return "not_configured"
            case .badBaseURL: return "bad_base_url"
            case .transport: return "transport"
            case .http(let status, _), .httpWithRetry(let status, _, _): return "http_\(status)"
            case .notChatAPI: return "not_chat_api"
            case .notResponsesAPI: return "not_responses_api"
            case .unsupportedStructuredOutput: return "unsupported_structured_output"
            case .outputTruncated: return "output_truncated"
            case .invalidStructuredResponse: return "invalid_structured_response"
            case .refused: return "refused"
            case .cancelled: return "cancelled"
            }
        }
        if let error = error as? TeleprompterPreparationError {
            return error.diagnostic?.code.rawValue ?? "preparation_error"
        }
        return "unknown"
    }
}

public enum TeleprompterPreparationPhase: String, Codable, Equatable, Sendable {
    case mapping
    case reducing
    case finalizing
}

public struct TeleprompterPreparationProgress: Codable, Equatable, Sendable {
    public let phase: TeleprompterPreparationPhase
    public let completed: Int
    public let total: Int
    public let currentIndex: Int?

    public init(
        phase: TeleprompterPreparationPhase,
        completed: Int,
        total: Int,
        currentIndex: Int? = nil
    ) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.currentIndex = currentIndex
    }
}

public struct TeleprompterPreparationInput: Equatable, Sendable {
    public let source: TeleprompterImportedSource
    public let sourceUnits: [TeleprompterSourceUnit]
    public let timingPlan: TeleprompterTimingPlan
    public let pace: TeleprompterPace
    public let calibrationFactor: Double
    public let operation: TeleprompterPreparationOperation
    public let selectedUnitIDs: Set<Int>?
    public let currentBlocks: [TeleprompterMapCurrentBlock]

    public init(
        source: TeleprompterImportedSource,
        sourceUnits: [TeleprompterSourceUnit],
        timingPlan: TeleprompterTimingPlan,
        pace: TeleprompterPace,
        calibrationFactor: Double = 1.0,
        operation: TeleprompterPreparationOperation = .prepare,
        selectedUnitIDs: Set<Int>? = nil,
        currentBlocks: [TeleprompterMapCurrentBlock] = []
    ) {
        self.source = source
        self.sourceUnits = sourceUnits
        self.timingPlan = timingPlan
        self.pace = pace
        self.calibrationFactor = calibrationFactor
        self.operation = operation
        self.selectedUnitIDs = selectedUnitIDs
        self.currentBlocks = currentBlocks
    }
}

public struct TeleprompterPreparationPolicy: Codable, Equatable, Sendable {
    public let maxWindowUnits: Int
    public let maxWindowBudgetUnits: Int
    public let maxGroupUnits: Int
    public let maxReadOnlyContextUnits: Int
    public let maxRecoveryRequests: Int

    public init(
        maxWindowUnits: Int = 24,
        maxWindowBudgetUnits: Int = 1_600,
        maxGroupUnits: Int = 8,
        maxReadOnlyContextUnits: Int = 1,
        maxRecoveryRequests: Int = 3
    ) {
        self.maxWindowUnits = max(1, maxWindowUnits)
        self.maxWindowBudgetUnits = max(1, maxWindowBudgetUnits)
        self.maxGroupUnits = max(1, maxGroupUnits)
        self.maxReadOnlyContextUnits = max(0, maxReadOnlyContextUnits)
        self.maxRecoveryRequests = max(0, maxRecoveryRequests)
    }
}

public struct TeleprompterPreparationMapWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let ordinal: Int
    public let sourceUnitIDs: [Int]
    public let localBudgetSeconds: TimeInterval

    public init(
        id: String,
        ordinal: Int,
        sourceUnitIDs: [Int],
        localBudgetSeconds: TimeInterval
    ) {
        self.id = id
        self.ordinal = ordinal
        self.sourceUnitIDs = sourceUnitIDs
        self.localBudgetSeconds = localBudgetSeconds
    }
}

public enum TeleprompterPreparationBoundaryState: String, Codable, Equatable, Sendable {
    case checked
    case unchecked
    case notApplicable
}

public struct TeleprompterPreparationBoundary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let leftBlockID: String
    public let rightBlockID: String
    public var state: TeleprompterPreparationBoundaryState
    public var reviewBlockIDs: [String]
    public var failureMessage: String?

    public init(
        id: String,
        leftBlockID: String,
        rightBlockID: String,
        state: TeleprompterPreparationBoundaryState,
        reviewBlockIDs: [String] = [],
        failureMessage: String? = nil
    ) {
        self.id = id
        self.leftBlockID = leftBlockID
        self.rightBlockID = rightBlockID
        self.state = state
        self.reviewBlockIDs = reviewBlockIDs
        self.failureMessage = failureMessage
    }

    public var isChecked: Bool { state == .checked }
}

public enum TeleprompterPreparationStatus: String, Codable, Equatable, Sendable {
    case complete
    case reviewRequired
    case boundaryUnchecked
}

public struct TeleprompterReadingDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceRevisionID: String
    public let sourceSHA256: String
    public let targetMinutes: Int
    public let targetSeconds: TimeInterval
    public let budgetSeconds: TimeInterval
    public var blocks: [TeleprompterReadingBlock]
    public var revisions: [String: Int]
    public var boundaries: [TeleprompterPreparationBoundary]
    public var durationEstimate: TeleprompterDurationEstimate

    public init(
        id: String,
        sourceRevisionID: String,
        sourceSHA256: String,
        targetMinutes: Int,
        targetSeconds: TimeInterval,
        budgetSeconds: TimeInterval,
        blocks: [TeleprompterReadingBlock],
        revisions: [String: Int],
        boundaries: [TeleprompterPreparationBoundary],
        durationEstimate: TeleprompterDurationEstimate
    ) {
        self.id = id
        self.sourceRevisionID = sourceRevisionID
        self.sourceSHA256 = sourceSHA256
        self.targetMinutes = targetMinutes
        self.targetSeconds = targetSeconds
        self.budgetSeconds = budgetSeconds
        self.blocks = blocks
        self.revisions = revisions
        self.boundaries = boundaries
        self.durationEstimate = durationEstimate
    }
}

public struct TeleprompterPreparationResult: Codable, Equatable, Sendable {
    public let draft: TeleprompterReadingDraft
    public let status: TeleprompterPreparationStatus
    public let mapWindows: [TeleprompterPreparationMapWindow]
    public let mapRequestCount: Int
    public let rewriteRequestCount: Int
    public let reduceRequestCount: Int
    public let fallbackBlockCount: Int

    public init(
        draft: TeleprompterReadingDraft,
        status: TeleprompterPreparationStatus,
        mapWindows: [TeleprompterPreparationMapWindow],
        mapRequestCount: Int,
        reduceRequestCount: Int,
        rewriteRequestCount: Int = 0,
        fallbackBlockCount: Int = 0
    ) {
        self.draft = draft
        self.status = status
        self.mapWindows = mapWindows
        self.mapRequestCount = mapRequestCount
        self.rewriteRequestCount = rewriteRequestCount
        self.reduceRequestCount = reduceRequestCount
        self.fallbackBlockCount = max(0, fallbackBlockCount)
    }

    public var blocks: [TeleprompterReadingBlock] { draft.blocks }
    public var boundaries: [TeleprompterPreparationBoundary] { draft.boundaries }
    public var hasLocalFallback: Bool { fallbackBlockCount > 0 }
}

public struct TeleprompterPreparationPipeline: Sendable {
    public typealias Completion = @Sendable (TeleprompterPreparationPrompt) async throws -> String
    public typealias ProgressHandler = @Sendable (TeleprompterPreparationProgress) -> Void
    public typealias ObservationHandler = TeleprompterAIObservationHandler

    private let completion: Completion
    private let policy: TeleprompterPreparationPolicy

    public init(
        completion: @escaping Completion,
        policy: TeleprompterPreparationPolicy = .init()
    ) {
        self.completion = completion
        self.policy = policy
    }

    public func prepare(
        _ input: TeleprompterPreparationInput,
        onProgress: ProgressHandler? = nil,
        onObservation: ObservationHandler? = nil
    ) async throws -> TeleprompterPreparationResult {
        let runID = UUID().uuidString
        let runStartedAt = Date()
        let runContext = TeleprompterAICallContext(
            runID: runID,
            requestID: runID,
            stage: .preparation
        )
        var completed = false
        var completedWithFallback = false
        observe(
            .init(
                kind: .runStarted,
                context: runContext,
                outcome: "started"
            ),
            onObservation: onObservation
        )
        defer {
            observe(
                .init(
                    kind: .runFinished,
                    context: runContext,
                    elapsedMilliseconds: elapsedMilliseconds(since: runStartedAt),
                    outcome: completed ? (completedWithFallback ? "completed_with_fallback" : "completed") : "failed"
                ),
                onObservation: onObservation
            )
        }

        let selection = try validate(input)
        var windows = try makeWindows(selection: selection, input: input)
        onProgress?(.init(phase: .mapping, completed: 0, total: windows.count))

        var windowStates: [[BlockState]] = []
        windowStates.reserveCapacity(windows.count)
        var mapRequestCount = 0
        var rewriteRequestCount = 0
        var fallbackBlockCount = 0
        var recoveryRequestCount = 0
        let recoveryBudget = min(policy.maxRecoveryRequests, max(2, min(windows.count, 3)))
        var splitWindowIDs = Set<String>()

        var windowIndex = 0
        while windowIndex < windows.count {
            try Task.checkCancellation()
            let window = windows[windowIndex]
            let sourceUnits = selection.unitsByID
            let targets = window.sourceUnitIDs.compactMap { sourceUnits[$0] }
            guard targets.count == window.sourceUnitIDs.count else {
                throw TeleprompterPreparationError.invalidSourceUnits
            }
            let readOnlyContext = makeContext(
                for: window,
                selection: selection,
                maxUnits: policy.maxReadOnlyContextUnits
            )
            let prompt: TeleprompterPreparationPrompt
            if input.operation == .prepare {
                prompt = try TeleprompterPreparationPromptBuilder.grouping(
                    targets: targets,
                    formatHint: input.source.formatHint,
                    globalTargetSeconds: input.timingPlan.targetSeconds,
                    localBudgetSeconds: window.localBudgetSeconds,
                    weightMode: input.timingPlan.weightMode,
                    pace: input.pace,
                    calibrationFactor: input.calibrationFactor,
                    operation: input.operation,
                    readOnlyContext: readOnlyContext,
                    maxGroupUnits: policy.maxGroupUnits
                )
            } else {
                prompt = try TeleprompterPreparationPromptBuilder.map(
                    targets: targets,
                    formatHint: input.source.formatHint,
                    globalTargetSeconds: input.timingPlan.targetSeconds,
                    localBudgetSeconds: window.localBudgetSeconds,
                    weightMode: input.timingPlan.weightMode,
                    pace: input.pace,
                    calibrationFactor: input.calibrationFactor,
                    operation: input.operation,
                    currentBlocks: input.currentBlocks.filter {
                        $0.startUnit < (window.sourceUnitIDs.last ?? -1) + 1
                            && $0.endUnit > (window.sourceUnitIDs.first ?? 0)
                    },
                    readOnlyContext: readOnlyContext,
                    maxGroupUnits: policy.maxGroupUnits
                )
            }
            var states: [BlockState]?
            var usedLocalFallback = false
            do {
                let context = TeleprompterAICallContext(
                    runID: runID,
                    requestID: UUID().uuidString,
                    stage: input.operation == .prepare ? .grouping : .map,
                    itemIndex: windowIndex,
                    itemCount: windows.count
                )
                if input.operation == .prepare {
                    let outcome = try await mapAndRewriteStates(
                        prompt: prompt,
                        targets: targets,
                        window: window,
                        sourceUnits: sourceUnits,
                        input: input,
                        readOnlyContext: readOnlyContext,
                        context: context,
                        recoveryBudget: max(0, recoveryBudget - recoveryRequestCount),
                        onObservation: onObservation
                    )
                    states = outcome.states
                    recoveryRequestCount += outcome.recoveryRequestsUsed
                } else {
                    states = try await mapStates(
                        prompt: prompt,
                        targets: targets,
                        window: window,
                        sourceUnits: sourceUnits,
                        pace: input.pace,
                        context: context,
                        onObservation: onObservation
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let rawError {
                let stageFailure = rawError as? WindowStageFailure
                let initialError = stageFailure?.underlying ?? rawError
                recoveryRequestCount += stageFailure?.recoveryRequestsUsed ?? 0
                if isTruncatedMapFailure(initialError) {
                    let splitCost = input.operation == .prepare ? 2 : 1
                    let canSplitWindow = window.sourceUnitIDs.count > 1
                        && !splitWindowIDs.contains(window.id)
                        && recoveryRequestCount + splitCost <= recoveryBudget
                    if !canSplitWindow {
                        let terminal = normalizedMapFailure(initialError)
                        guard let fallback = makeLocalFallback(
                            for: window,
                            sourceUnits: sourceUnits,
                            pace: input.pace,
                            error: terminal,
                            onObservation: onObservation
                        ) else { throw terminal }
                        states = fallback
                        usedLocalFallback = true
                        completedWithFallback = true
                        // Continue to final assembly with a complete, source-backed window.
                    } else {
                        let children = try split(window: window, timingPlan: input.timingPlan)
                        // 新协议每个子窗包含 grouping + rewrite，因此两个子窗相对原窗增加两个请求；
                        // tighten 兼容路径仍只有一个 Map 请求。子窗不递归拆分。
                        recoveryRequestCount += splitCost
                        splitWindowIDs.formUnion(children.map(\.id))
                        windows.replaceSubrange(windowIndex...windowIndex, with: children)
                        windows = windows.enumerated().map { index, item in
                            .init(id: item.id, ordinal: index, sourceUnitIDs: item.sourceUnitIDs,
                                  localBudgetSeconds: item.localBudgetSeconds)
                        }
                        onProgress?(.init(phase: .mapping, completed: windowIndex,
                                          total: windows.count, currentIndex: windowIndex))
                        continue
                    }
                }
                if states == nil, input.operation == .prepare {
                    let terminal = normalizedMapFailure(initialError)
                    guard let fallback = makeLocalFallback(
                        for: window,
                        sourceUnits: sourceUnits,
                        pace: input.pace,
                        error: terminal,
                        onObservation: onObservation
                    ) else { throw terminal }
                    states = fallback
                    usedLocalFallback = true
                    completedWithFallback = true
                }
                if states == nil, input.operation != .prepare {
                    var failure: Error = initialError
                    let canRetryTransient = isTransientProviderFailure(initialError)
                    let canRecoverStructure = isStructuralMapFailure(initialError)
                    if recoveryRequestCount < recoveryBudget,
                       canRetryTransient || canRecoverStructure {
                        try await waitBeforeRetryIfNeeded(failure)
                        recoveryRequestCount += 1
                        let retryPrompt = canRecoverStructure
                            ? recoveryPrompt(from: prompt, error: initialError)
                            : prompt
                        do {
                            let retryContext = TeleprompterAICallContext(
                                runID: runID,
                                requestID: UUID().uuidString,
                                stage: .map,
                                itemIndex: windowIndex,
                                itemCount: windows.count,
                                attempt: 1
                            )
                            states = try await mapStates(
                                prompt: retryPrompt,
                                targets: targets,
                                window: window,
                                sourceUnits: sourceUnits,
                                pace: input.pace,
                                context: retryContext,
                                onObservation: onObservation
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let retryError {
                            failure = retryError
                        }
                    }

                    if states == nil {
                        let terminal = normalizedMapFailure(failure)
                        guard let fallback = makeLocalFallback(
                            for: window,
                            sourceUnits: sourceUnits,
                            pace: input.pace,
                            error: terminal,
                            onObservation: onObservation
                        ) else { throw terminal }
                        states = fallback
                        usedLocalFallback = true
                        completedWithFallback = true
                    }
                }
            }
            guard let states, !states.isEmpty else {
                throw TeleprompterPreparationError.invalidPromptResponse
            }
            windowStates.append(states)
            if !usedLocalFallback {
                mapRequestCount += 1
                if input.operation == .prepare { rewriteRequestCount += 1 }
            } else {
                fallbackBlockCount += states.count
            }
            onProgress?(.init(
                phase: .mapping,
                completed: windowIndex + 1,
                total: windows.count,
                currentIndex: windowIndex
            ))
            windowIndex += 1
        }

        let allBlocks = windowStates.flatMap { $0 }
        let reduceBoundaries = makeReduceBoundaries(
            windowStates: windowStates,
            selection: selection
        )
        onProgress?(.init(phase: .reducing, completed: 0, total: reduceBoundaries.count))

        var mutableStates = allBlocks
        var boundaries: [TeleprompterPreparationBoundary] = []
        boundaries.reserveCapacity(reduceBoundaries.count)
        var reduceRequestCount = 0

        for (boundaryIndex, boundaryPair) in reduceBoundaries.enumerated() {
            try Task.checkCancellation()
            let left = mutableStates[boundaryPair.leftIndex]
            let right = mutableStates[boundaryPair.rightIndex]
            var boundary = TeleprompterPreparationBoundary(
                id: boundaryPair.id,
                leftBlockID: left.block.id,
                rightBlockID: right.block.id,
                state: .notApplicable
            )

            guard left.block.disposition == .speak, right.block.disposition == .speak else {
                boundaries.append(boundary)
                onProgress?(.init(
                    phase: .reducing,
                    completed: boundaryIndex + 1,
                    total: reduceBoundaries.count,
                    currentIndex: boundaryIndex
                ))
                continue
            }

            let editable = [
                reduceBlock(left),
                reduceBlock(right)
            ]
            let readOnly = makeReduceContext(
                for: boundaryPair,
                states: mutableStates
            )
            let prompt = try TeleprompterPreparationPromptBuilder.reduce(
                editableBlocks: editable,
                readOnlyBlocks: readOnly,
                editableBudgetSeconds: left.block.budgetSeconds + right.block.budgetSeconds,
                editableEstimatedSeconds: estimateSeconds(
                    text: left.block.text + right.block.text,
                    pace: input.pace,
                    calibrationFactor: input.calibrationFactor
                ),
                pace: input.pace,
                calibrationFactor: input.calibrationFactor
            )
            reduceRequestCount += 1
            let context = TeleprompterAICallContext(
                runID: runID,
                requestID: UUID().uuidString,
                stage: .reduce,
                itemIndex: boundaryIndex,
                itemCount: reduceBoundaries.count
            )
            do {
                let response = try await call(
                    prompt,
                    context: context,
                    onObservation: onObservation
                )
                try Task.checkCancellation()
                let output = try TeleprompterReduceDecoder().decode(
                    response,
                    editableBlocks: editable
                )
                try apply(output: output, to: &mutableStates)
                boundary.state = .checked
                boundary.reviewBlockIDs = output.reviewBlockIDs
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                observe(
                    .init(
                        kind: .callFailed,
                        component: "reduce_decoder",
                        context: context,
                        errorCode: TeleprompterAIObservability.errorCode(for: error)
                    ),
                    onObservation: onObservation
                )
                boundary.state = .unchecked
                boundary.failureMessage = "boundary reduction unavailable"
            }
            boundaries.append(boundary)
            onProgress?(.init(
                phase: .reducing,
                completed: boundaryIndex + 1,
                total: reduceBoundaries.count,
                currentIndex: boundaryIndex
            ))
        }

        try Task.checkCancellation()
        onProgress?(.init(phase: .finalizing, completed: 0, total: 1))
        let draft = try finalize(
            input: input,
            selection: selection,
            states: mutableStates,
            boundaries: boundaries
        )
        let status: TeleprompterPreparationStatus
        if boundaries.contains(where: { $0.state == .unchecked }) {
            status = .boundaryUnchecked
        } else if draft.blocks.contains(where: { $0.disposition == .unresolved })
                    || boundaries.contains(where: { !$0.reviewBlockIDs.isEmpty }) {
            status = .reviewRequired
        } else {
            status = .complete
        }
        onProgress?(.init(phase: .finalizing, completed: 1, total: 1))
        completed = true
        return .init(
            draft: draft,
            status: status,
            mapWindows: windows,
            mapRequestCount: mapRequestCount,
            reduceRequestCount: reduceRequestCount,
            rewriteRequestCount: rewriteRequestCount,
            fallbackBlockCount: fallbackBlockCount
        )
    }
}

/// The UI-independent adapter boundary between the preparation pipeline and an
/// LLM provider. The provider receives one fully constructed prompt at a time;
/// scheduling, validation, cancellation, and assembly remain in the pipeline.
public struct TeleprompterPreparationClient: Sendable {
    public typealias Completion = @Sendable (TeleprompterPreparationPrompt) async throws -> String
    public typealias ObservationHandler = TeleprompterAIObservationHandler

    private let pipeline: TeleprompterPreparationPipeline

    public init(
        completion: @escaping Completion,
        policy: TeleprompterPreparationPolicy = .init()
    ) {
        self.pipeline = TeleprompterPreparationPipeline(completion: completion, policy: policy)
    }

    public func prepare(
        _ input: TeleprompterPreparationInput,
        onProgress: TeleprompterPreparationPipeline.ProgressHandler? = nil,
        onObservation: ObservationHandler? = nil
    ) async throws -> TeleprompterPreparationResult {
        try await pipeline.prepare(
            input,
            onProgress: onProgress,
            onObservation: onObservation
        )
    }
}

private extension TeleprompterPreparationPipeline {
    struct Selection {
        let units: [TeleprompterSourceUnit]
        let unitsByID: [Int: TeleprompterSourceUnit]
        let selectedIDs: [Int]
    }

    struct BlockState {
        var block: TeleprompterReadingBlock
        var sourceUnitIDs: [Int]
        var sourceUnits: [TeleprompterMapContextItem]
        var revision: Int
    }

    struct GroupState {
        let id: String
        let sourceUnitIDs: [Int]
        let sourceUnits: [TeleprompterMapContextItem]
        let protectedLiterals: [String]
        let budgetSeconds: TimeInterval
    }

    struct BoundaryPair {
        let id: String
        let leftIndex: Int
        let rightIndex: Int
    }

    struct ProviderCallFailure: Error {
        let underlying: Error
    }

    struct WindowStageFailure: Error {
        let underlying: Error
        let recoveryRequestsUsed: Int
    }

    struct WindowStatesResult {
        let states: [BlockState]
        let recoveryRequestsUsed: Int
    }

    func recoveryPrompt(
        from prompt: TeleprompterPreparationPrompt,
        error: Error
    ) -> TeleprompterPreparationPrompt {
        let diagnostic = (error as? TeleprompterPreparationError)?.diagnostic
        let code = diagnostic?.code.rawValue ?? "invalid_structured_response"
        let field = diagnostic?.fieldPath ?? "unknown"
        return .init(
            instructions: prompt.instructions + "\n上一轮响应未通过本地校验（code=\(code), field=\(field)）。请丢弃上一轮输出，只根据同一份输入重新输出完整、连续、闭合的 JSON；不要复述原始响应、错误正文或解释失败原因。",
            input: prompt.input,
            schemaVersion: prompt.schemaVersion,
            promptVersion: prompt.promptVersion
        )
    }

    func isStructuralMapFailure(_ error: Error) -> Bool {
        if let failure = error as? ProviderCallFailure {
            return (failure.underlying as? LLMError) == .invalidStructuredResponse
        }
        guard let error = error as? TeleprompterPreparationError else { return false }
        switch error {
        case .invalidPromptResponse, .invalidPromptResponseDetailed:
            return true
        default:
            return false
        }
    }

    func isTruncatedMapFailure(_ error: Error) -> Bool {
        guard let failure = error as? ProviderCallFailure else { return false }
        return (failure.underlying as? LLMError) == .outputTruncated
    }

    func isTransientProviderFailure(_ error: Error) -> Bool {
        guard let failure = error as? ProviderCallFailure,
              let providerError = failure.underlying as? LLMError else { return false }
        switch providerError {
        case let .http(status, _), let .httpWithRetry(status, _, _):
            return status == 429 || (500...599).contains(status)
        default:
            return false
        }
    }

    func canRetryStage(_ error: Error) -> Bool {
        isStructuralMapFailure(error) || isTransientProviderFailure(error)
    }

    func waitBeforeRetryIfNeeded(_ error: Error) async throws {
        guard let delay = retryAfterDelay(for: error), delay > 0 else { return }
        try await Task.sleep(for: .seconds(delay))
    }

    func retryAfterDelay(for error: Error) -> TimeInterval? {
        let underlying = (error as? ProviderCallFailure)?.underlying ?? error
        guard let providerError = underlying as? LLMError else { return nil }
        guard case let .httpWithRetry(_, _, retryAfter) = providerError else { return nil }
        return min(max(retryAfter, 0), 60)
    }

    func normalizedMapFailure(_ error: Error) -> Error {
        guard let failure = error as? ProviderCallFailure else { return error }
        if let providerError = failure.underlying as? LLMError {
            return providerError
        }
        return TeleprompterPreparationError.invalidPromptResponse
    }

    func split(
        window: TeleprompterPreparationMapWindow,
        timingPlan: TeleprompterTimingPlan
    ) throws -> [TeleprompterPreparationMapWindow] {
        let midpoint = window.sourceUnitIDs.count / 2
        guard midpoint > 0, midpoint < window.sourceUnitIDs.count else {
            throw TeleprompterPreparationError.invalidPromptResponse
        }
        let leftIDs = Array(window.sourceUnitIDs[..<midpoint])
        let rightIDs = Array(window.sourceUnitIDs[midpoint...])
        return [leftIDs, rightIDs].enumerated().map { index, IDs in
            .init(
                id: "\(window.id)-split-\(index)",
                ordinal: window.ordinal + index,
                sourceUnitIDs: IDs,
                localBudgetSeconds: timingPlan.budget(for: IDs)
            )
        }
    }

    func observe(
        _ observation: TeleprompterAIObservation,
        onObservation: TeleprompterAIObservationHandler?
    ) {
        TeleprompterAIObservability.emit(observation, to: onObservation)
    }

    func call(
        _ prompt: TeleprompterPreparationPrompt,
        context: TeleprompterAICallContext,
        onObservation: TeleprompterAIObservationHandler?
    ) async throws -> String {
        let prompt = prompt.withObservationContext(context)
        let startedAt = Date()
        observe(
            .init(
                kind: .callStarted,
                context: context,
                outcome: "started"
            ),
            onObservation: onObservation
        )
        do {
            let response = try await completion(prompt)
            observe(
                .init(
                    kind: .callFinished,
                    context: context,
                    elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                    outcome: "completed"
                ),
                onObservation: onObservation
            )
            return response
        } catch is CancellationError {
            observe(
                .init(
                    kind: .callFailed,
                    context: context,
                    elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                    outcome: "cancelled",
                    errorCode: "cancelled"
                ),
                onObservation: onObservation
            )
            throw CancellationError()
        } catch let error as LLMError where error == .cancelled {
            observe(
                .init(
                    kind: .callFailed,
                    context: context,
                    elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                    outcome: "cancelled",
                    errorCode: "cancelled"
                ),
                onObservation: onObservation
            )
            throw CancellationError()
        } catch let error as TeleprompterPreparationError {
            observe(
                .init(
                    kind: .callFailed,
                    context: context,
                    elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                    errorCode: TeleprompterAIObservability.errorCode(for: error)
                ),
                onObservation: onObservation
            )
            throw error
        } catch {
            observe(
                .init(
                    kind: .callFailed,
                    context: context,
                    elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                    errorCode: TeleprompterAIObservability.errorCode(for: error)
                ),
                onObservation: onObservation
            )
            throw ProviderCallFailure(underlying: error)
        }
    }

    func mapStates(
        prompt: TeleprompterPreparationPrompt,
        targets: [TeleprompterSourceUnit],
        window: TeleprompterPreparationMapWindow,
        sourceUnits: [Int: TeleprompterSourceUnit],
        pace: TeleprompterPace,
        context: TeleprompterAICallContext,
        onObservation: TeleprompterAIObservationHandler?
    ) async throws -> [BlockState] {
        let response = try await call(
            prompt,
            context: context,
            onObservation: onObservation
        )
        try Task.checkCancellation()
        do {
            let output = try TeleprompterMapDecoder().decode(
                response,
                targets: targets,
                maxGroupUnits: policy.maxGroupUnits
            )
            return try makeBlockStates(
                output: output,
                window: window,
                sourceUnits: sourceUnits,
                pace: pace
            )
        } catch {
            observe(
                .init(
                    kind: .callFailed,
                    component: "map_decoder",
                    context: context,
                    errorCode: TeleprompterAIObservability.errorCode(for: error)
                ),
                onObservation: onObservation
            )
            throw error
        }
    }

    func mapAndRewriteStates(
        prompt: TeleprompterPreparationPrompt,
        targets: [TeleprompterSourceUnit],
        window: TeleprompterPreparationMapWindow,
        sourceUnits: [Int: TeleprompterSourceUnit],
        input: TeleprompterPreparationInput,
        readOnlyContext: TeleprompterMapReadOnlyContext,
        context: TeleprompterAICallContext,
        recoveryBudget: Int,
        onObservation: TeleprompterAIObservationHandler?
    ) async throws -> WindowStatesResult {
        var recoveryRequestsUsed = 0
        let groups: [GroupState]
        do {
            groups = try await groupingStates(
                prompt: prompt,
                targets: targets,
                window: window,
                sourceUnits: sourceUnits,
                context: context,
                onObservation: onObservation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            guard !isTruncatedMapFailure(error),
                  recoveryRequestsUsed < recoveryBudget,
                  canRetryStage(error) else {
                throw WindowStageFailure(underlying: error, recoveryRequestsUsed: recoveryRequestsUsed)
            }
            try await waitBeforeRetryIfNeeded(error)
            recoveryRequestsUsed += 1
            do {
                groups = try await groupingStates(
                    prompt: recoveryPrompt(from: prompt, error: error),
                    targets: targets,
                    window: window,
                    sourceUnits: sourceUnits,
                    context: stageContext(from: context, stage: .grouping, attempt: 1),
                    onObservation: onObservation
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let retryError {
                throw WindowStageFailure(
                    underlying: retryError,
                    recoveryRequestsUsed: recoveryRequestsUsed
                )
            }
        }

        let rewriteGroups = groups.map { group in
            TeleprompterRewriteGroup(
                id: group.id,
                sourceUnits: group.sourceUnits,
                protectedLiterals: group.protectedLiterals,
                budgetSeconds: group.budgetSeconds
            )
        }
        let rewritePrompt = try TeleprompterPreparationPromptBuilder.rewrite(
            groups: rewriteGroups,
            globalTargetSeconds: input.timingPlan.targetSeconds,
            localBudgetSeconds: window.localBudgetSeconds,
            weightMode: input.timingPlan.weightMode,
            pace: input.pace,
            calibrationFactor: input.calibrationFactor,
            operation: input.operation,
            readOnlyContext: readOnlyContext
        )
        let rewriteContext = stageContext(from: context, stage: .rewrite, attempt: context.attempt)
        do {
            let states = try await rewriteStates(
                prompt: rewritePrompt,
                rewriteGroups: rewriteGroups,
                groups: groups,
                sourceUnits: sourceUnits,
                context: rewriteContext,
                onObservation: onObservation
            )
            return .init(states: states, recoveryRequestsUsed: recoveryRequestsUsed)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            guard !isTruncatedMapFailure(error),
                  recoveryRequestsUsed < recoveryBudget,
                  canRetryStage(error) else {
                throw WindowStageFailure(underlying: error, recoveryRequestsUsed: recoveryRequestsUsed)
            }
            try await waitBeforeRetryIfNeeded(error)
            recoveryRequestsUsed += 1
            do {
                let states = try await rewriteStates(
                    prompt: recoveryPrompt(from: rewritePrompt, error: error),
                    rewriteGroups: rewriteGroups,
                    groups: groups,
                    sourceUnits: sourceUnits,
                    context: stageContext(from: rewriteContext, stage: .rewrite, attempt: 1),
                    onObservation: onObservation
                )
                return .init(states: states, recoveryRequestsUsed: recoveryRequestsUsed)
            } catch is CancellationError {
                throw CancellationError()
            } catch let retryError {
                throw WindowStageFailure(
                    underlying: retryError,
                    recoveryRequestsUsed: recoveryRequestsUsed
                )
            }
        }
    }

    func groupingStates(
        prompt: TeleprompterPreparationPrompt,
        targets: [TeleprompterSourceUnit],
        window: TeleprompterPreparationMapWindow,
        sourceUnits: [Int: TeleprompterSourceUnit],
        context: TeleprompterAICallContext,
        onObservation: TeleprompterAIObservationHandler?
    ) async throws -> [GroupState] {
        let response = try await call(prompt, context: context, onObservation: onObservation)
        try Task.checkCancellation()
        do {
            let output = try TeleprompterGroupingDecoder().decode(
                response,
                targets: targets,
                maxGroupUnits: policy.maxGroupUnits
            )
            return try makeGroupStates(output: output, window: window, sourceUnits: sourceUnits)
        } catch {
            observe(
                .init(
                    kind: .callFailed,
                    component: "grouping_decoder",
                    context: context,
                    errorCode: TeleprompterAIObservability.errorCode(for: error)
                ),
                onObservation: onObservation
            )
            throw error
        }
    }

    func rewriteStates(
        prompt: TeleprompterPreparationPrompt,
        rewriteGroups: [TeleprompterRewriteGroup],
        groups: [GroupState],
        sourceUnits: [Int: TeleprompterSourceUnit],
        context: TeleprompterAICallContext,
        onObservation: TeleprompterAIObservationHandler?
    ) async throws -> [BlockState] {
        let response = try await call(prompt, context: context, onObservation: onObservation)
        try Task.checkCancellation()
        do {
            let output = try TeleprompterRewriteDecoder().decode(response, groups: rewriteGroups)
            return try makeBlockStates(output: output, groups: groups, sourceUnits: sourceUnits)
        } catch {
            observe(
                .init(
                    kind: .callFailed,
                    component: "rewrite_decoder",
                    context: context,
                    errorCode: TeleprompterAIObservability.errorCode(for: error)
                ),
                onObservation: onObservation
            )
            throw error
        }
    }

    func stageContext(
        from context: TeleprompterAICallContext,
        stage: TeleprompterAIStage,
        attempt: Int
    ) -> TeleprompterAICallContext {
        .init(
            runID: context.runID,
            requestID: UUID().uuidString,
            stage: stage,
            itemIndex: context.itemIndex,
            itemCount: context.itemCount,
            attempt: attempt
        )
    }

    func makeGroupStates(
        output: TeleprompterGroupingOutput,
        window: TeleprompterPreparationMapWindow,
        sourceUnits: [Int: TeleprompterSourceUnit]
    ) throws -> [GroupState] {
        let totalBudgetUnits = window.sourceUnitIDs.reduce(0) { $0 + (sourceUnits[$1]?.budgetUnits ?? 0) }
        return try output.groups.map { group in
            let IDs = window.sourceUnitIDs.filter { $0 >= group.startUnit && $0 < group.endUnit }
            guard let first = IDs.first,
                  IDs.last == group.endUnit - 1,
                  IDs.count == group.endUnit - group.startUnit,
                  IDs.allSatisfy({ sourceUnits[$0] != nil }) else {
                throw TeleprompterPreparationError.invalidSourceUnits
            }
            let units = IDs.compactMap { sourceUnits[$0] }
            let rawUnits = units.map { TeleprompterMapContextItem(id: $0.id, rawText: $0.rawText) }
            let protected = units.flatMap { TeleprompterProtectedLiteralExtractor.extract(from: $0.rawText) }
            let budgetUnits = units.reduce(0) { $0 + $1.budgetUnits }
            return GroupState(
                id: "block-\(first)-\(group.endUnit)",
                sourceUnitIDs: IDs,
                sourceUnits: rawUnits,
                protectedLiterals: Array(Set(protected)).sorted(),
                budgetSeconds: totalBudgetUnits > 0
                    ? window.localBudgetSeconds * Double(budgetUnits) / Double(totalBudgetUnits)
                    : 0
            )
        }
    }

    func makeBlockStates(
        output: TeleprompterRewriteOutput,
        groups: [GroupState],
        sourceUnits: [Int: TeleprompterSourceUnit]
    ) throws -> [BlockState] {
        let allowed = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        return try output.blocks.enumerated().map { offset, block in
            guard let group = allowed[block.blockID],
                  let first = group.sourceUnitIDs.first,
                  let last = group.sourceUnitIDs.last,
                  let firstUnit = sourceUnits[first],
                  let lastUnit = sourceUnits[last] else {
                throw TeleprompterPreparationError.invalidSourceUnits
            }
            let rawText = group.sourceUnits.map(\.rawText).joined()
            let text: String
            let disposition: TeleprompterBlockDisposition
            switch block.mode {
            case .speak:
                text = block.text
                disposition = .speak
            case .review:
                text = block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rawText : block.text
                disposition = .unresolved
            case .omit:
                text = ""
                disposition = .unresolved
            }
            return BlockState(
                block: .init(
                    id: group.id,
                    ordinal: offset,
                    sourceRange: .init(start: firstUnit.sourceRange.start, end: lastUnit.sourceRange.end),
                    text: text,
                    rawSourceText: rawText,
                    disposition: disposition,
                    origin: .ai,
                    reviewIssues: block.issues,
                    budgetSeconds: group.budgetSeconds
                ),
                sourceUnitIDs: group.sourceUnitIDs,
                sourceUnits: group.sourceUnits,
                revision: 0
            )
        }
    }

    func makeLocalFallback(
        for window: TeleprompterPreparationMapWindow,
        sourceUnits: [Int: TeleprompterSourceUnit],
        pace: TeleprompterPace,
        error: Error,
        onObservation: TeleprompterAIObservationHandler?
    ) -> [BlockState]? {
        guard isLocallyRecoverable(error) else { return nil }
        let totalBudgetUnits = window.sourceUnitIDs.reduce(0) { $0 + (sourceUnits[$1]?.budgetUnits ?? 0) }
        let states = window.sourceUnitIDs.enumerated().compactMap { offset, id -> BlockState? in
            guard let unit = sourceUnits[id] else { return nil }
            let sourceItems = [TeleprompterMapContextItem(id: id, rawText: unit.rawText)]
            let budget = totalBudgetUnits > 0
                ? window.localBudgetSeconds * Double(unit.budgetUnits) / Double(totalBudgetUnits)
                : 0
            return BlockState(
                block: .init(
                    id: "block-\(id)-\(id + 1)",
                    ordinal: offset,
                    sourceRange: unit.sourceRange,
                    text: unit.rawText,
                    rawSourceText: unit.rawText,
                    disposition: .unresolved,
                    origin: .deterministic,
                    reviewIssues: [.uncertainMeaning],
                    budgetSeconds: budget
                ),
                sourceUnitIDs: [id],
                sourceUnits: sourceItems,
                revision: 0
            )
        }
        guard states.count == window.sourceUnitIDs.count else { return nil }
        observe(
            .init(
                kind: .callFinished,
                component: "local_recovery",
                outcome: "source_fallback",
                errorCode: TeleprompterAIObservability.errorCode(for: error)
            ),
            onObservation: onObservation
        )
        _ = pace
        return states
    }

    func isLocallyRecoverable(_ error: Error) -> Bool {
        if let error = error as? TeleprompterPreparationError {
            switch error {
            case .invalidPromptResponse, .invalidPromptResponseDetailed:
                return true
            default:
                return false
            }
        }
        guard let error = error as? LLMError else { return false }
        switch error {
        case .invalidStructuredResponse, .outputTruncated, .transport:
            return true
        case .http(let status, _), .httpWithRetry(let status, _, _):
            return status == 408 || status == 409 || status == 425 || status == 429
                || (500...599).contains(status)
        case .notConfigured, .badBaseURL, .notResponsesAPI, .notChatAPI,
             .unsupportedStructuredOutput, .refused, .cancelled:
            return false
        }
    }

    func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    func validate(_ input: TeleprompterPreparationInput) throws -> Selection {
        let units = input.sourceUnits
        guard !units.isEmpty,
              units.allSatisfy({ $0.sourceRevisionID == input.source.sourceRevisionID }),
              units.map(\.id) == Array(units.indices),
              units.map(\.ordinal) == Array(units.indices),
              units.map(\.rawText).joined().data(using: .utf8) == input.source.sourceText.data(using: .utf8) else {
            throw TeleprompterPreparationError.invalidSourceUnits
        }
        let unitsByID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let selectedIDs = input.selectedUnitIDs.map { $0.sorted() } ?? units.map(\.id)
        guard !selectedIDs.isEmpty,
              selectedIDs == Array(Set(selectedIDs)).sorted(),
              selectedIDs.allSatisfy({ unitsByID[$0] != nil }),
              input.timingPlan.allocations.map(\.sourceUnitID).allSatisfy({ unitsByID[$0] != nil }) else {
            throw TeleprompterPreparationError.invalidSourceUnits
        }
        guard input.timingPlan.allocations.count == units.count,
              input.timingPlan.allocations.map(\.sourceUnitID) == units.map(\.id),
              input.timingPlan.allocations.allSatisfy({ $0.budgetSeconds.isFinite && $0.budgetSeconds >= 0 }) else {
            throw TeleprompterPreparationError.invalidTimingPlan
        }
        return Selection(units: units, unitsByID: unitsByID, selectedIDs: selectedIDs)
    }

    func makeWindows(
        selection: Selection,
        input: TeleprompterPreparationInput
    ) throws -> [TeleprompterPreparationMapWindow] {
        var windows: [TeleprompterPreparationMapWindow] = []
        var currentIDs: [Int] = []
        var currentBudgetUnits = 0

        func flush() {
            guard !currentIDs.isEmpty else { return }
            windows.append(.init(
                id: "map-\(windows.count)",
                ordinal: windows.count,
                sourceUnitIDs: currentIDs,
                localBudgetSeconds: input.timingPlan.budget(for: currentIDs)
            ))
            currentIDs.removeAll(keepingCapacity: true)
            currentBudgetUnits = 0
        }

        for (index, id) in selection.selectedIDs.enumerated() {
            let unit = selection.unitsByID[id]!
            let previousID = index > 0 ? selection.selectedIDs[index - 1] : nil
            let isNewRun = previousID.map { $0 + 1 != id } ?? false
            if isNewRun { flush() }
            guard unit.budgetUnits <= policy.maxWindowBudgetUnits else {
                throw TeleprompterPreparationError.invalidPromptResponse
            }
            let exceedsCount = currentIDs.count >= policy.maxWindowUnits
            let exceedsBudget = !currentIDs.isEmpty
                && currentBudgetUnits + unit.budgetUnits > policy.maxWindowBudgetUnits
            if exceedsCount || exceedsBudget { flush() }
            currentIDs.append(id)
            currentBudgetUnits += unit.budgetUnits
        }
        flush()
        guard !windows.isEmpty else { throw TeleprompterPreparationError.invalidSourceUnits }
        return windows
    }

    func makeContext(
        for window: TeleprompterPreparationMapWindow,
        selection: Selection,
        maxUnits: Int
    ) -> TeleprompterMapReadOnlyContext {
        guard maxUnits > 0, let first = window.sourceUnitIDs.first, let last = window.sourceUnitIDs.last else {
            return .init()
        }
        let selected = Set(selection.selectedIDs)
        var before: [TeleprompterMapContextItem] = []
        var after: [TeleprompterMapContextItem] = []
        if selected.contains(first - 1), let unit = selection.unitsByID[first - 1] {
            before.append(.init(id: unit.id, rawText: unit.rawText))
        }
        if selected.contains(last + 1), let unit = selection.unitsByID[last + 1] {
            after.append(.init(id: unit.id, rawText: unit.rawText))
        }
        return .init(hints: [], before: Array(before.prefix(maxUnits)), after: Array(after.prefix(maxUnits)))
    }

    func makeBlockStates(
        output: TeleprompterMapOutput,
        window: TeleprompterPreparationMapWindow,
        sourceUnits: [Int: TeleprompterSourceUnit],
        pace: TeleprompterPace
    ) throws -> [BlockState] {
        output.blocks.enumerated().map { offset, block in
            let IDs = window.sourceUnitIDs.filter { $0 >= block.startUnit && $0 < block.endUnit }
            guard let first = IDs.first, let last = IDs.last,
                  let firstUnit = sourceUnits[first], let lastUnit = sourceUnits[last] else {
                return nil
            }
            let rawText = IDs.compactMap { sourceUnits[$0]?.rawText }.joined()
            let text: String
            let disposition: TeleprompterBlockDisposition
            switch block.mode {
            case .speak:
                text = block.text
                disposition = .speak
            case .review:
                text = block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rawText : block.text
                disposition = .unresolved
            case .omit:
                text = ""
                disposition = .unresolved
            }
            let reviewIssues = block.issues
            return BlockState(
                block: .init(
                    id: "block-\(first)-\(block.endUnit)",
                    ordinal: offset,
                    sourceRange: .init(start: firstUnit.sourceRange.start, end: lastUnit.sourceRange.end),
                    text: text,
                    rawSourceText: rawText,
                    disposition: disposition,
                    origin: .ai,
                    reviewIssues: reviewIssues,
                    budgetSeconds: window.localBudgetSeconds * Double(IDs.reduce(0) { $0 + sourceUnits[$1]!.budgetUnits })
                        / Double(max(1, window.sourceUnitIDs.reduce(0) { $0 + sourceUnits[$1]!.budgetUnits }))
                ),
                sourceUnitIDs: IDs,
                sourceUnits: IDs.compactMap { sourceUnits[$0] }.map {
                    .init(id: $0.id, rawText: $0.rawText)
                },
                revision: 0
            )
        }.compactMap { $0 }
    }

    func makeReduceBoundaries(
        windowStates: [[BlockState]],
        selection: Selection
    ) -> [BoundaryPair] {
        guard windowStates.count > 1 else { return [] }
        var offsets: [Int] = []
        var cursor = 0
        for states in windowStates {
            offsets.append(cursor)
            cursor += states.count
        }
        var boundaries: [BoundaryPair] = []
        for index in 0..<(windowStates.count - 1) {
            guard let left = windowStates[index].last,
                  let right = windowStates[index + 1].first,
                  left.sourceUnitIDs.last.map({ $0 + 1 }) == right.sourceUnitIDs.first else {
                continue
            }
            let leftIndex = offsets[index] + windowStates[index].count - 1
            let rightIndex = offsets[index + 1]
            boundaries.append(.init(
                id: "boundary-\(left.block.id)-\(right.block.id)",
                leftIndex: leftIndex,
                rightIndex: rightIndex
            ))
        }
        return boundaries
    }

    func makeReduceContext(
        for boundary: BoundaryPair,
        states: [BlockState]
    ) -> [TeleprompterReduceEditableBlock] {
        if boundary.leftIndex > 0 {
            let state = states[boundary.leftIndex - 1]
            return [reduceBlock(state)]
        }
        if boundary.rightIndex + 1 < states.count {
            let state = states[boundary.rightIndex + 1]
            return [reduceBlock(state)]
        }
        return []
    }

    func reduceBlock(_ state: BlockState) -> TeleprompterReduceEditableBlock {
        .init(
            id: state.block.id,
            revision: state.revision,
            text: state.block.text,
            sourceUnits: state.sourceUnits,
            protectedLiterals: TeleprompterProtectedLiteralExtractor.extract(from: state.block.rawSourceText)
        )
    }

    func apply(
        output: TeleprompterReduceOutput,
        to states: inout [BlockState]
    ) throws {
        let indices = Dictionary(uniqueKeysWithValues: states.enumerated().map { ($0.element.block.id, $0.offset) })
        let patches = output.patches.compactMap { patch -> (Int, TeleprompterReducePatch)? in
            guard let index = indices[patch.blockID] else { return nil }
            return (index, patch)
        }
        guard patches.count == output.patches.count,
              patches.map(\.0).count == Set(patches.map(\.0)).count else {
            throw TeleprompterPreparationError.invalidPromptResponse
        }
        for (index, patch) in patches {
            guard states[index].revision == patch.revision else {
                throw TeleprompterPreparationError.invalidPromptResponse
            }
        }
        for (index, patch) in patches {
            states[index].block.text = patch.text
            states[index].revision += 1
        }
    }

    func estimateSeconds(
        text: String,
        pace: TeleprompterPace,
        calibrationFactor: Double
    ) -> TimeInterval? {
        let estimate = TeleprompterDurationEstimator.estimate(
            text,
            pace: pace,
            calibrationFactor: calibrationFactor
        )
        return estimate.pointSeconds ?? (estimate.knownPartSeconds > 0 ? estimate.knownPartSeconds : nil)
    }

    func finalize(
        input: TeleprompterPreparationInput,
        selection: Selection,
        states: [BlockState],
        boundaries: [TeleprompterPreparationBoundary]
    ) throws -> TeleprompterReadingDraft {
        let covered = states.flatMap(\.sourceUnitIDs)
        guard covered == selection.selectedIDs,
              Set(states.map { $0.block.id }).count == states.count,
              states.allSatisfy({ !$0.block.rawSourceText.isEmpty || $0.block.disposition == .unresolved }) else {
            throw TeleprompterPreparationError.invalidPromptResponse
        }
        var blocks = states.map(\.block)
        for index in blocks.indices { blocks[index].ordinal = index }
        let revisions = Dictionary(uniqueKeysWithValues: states.map { ($0.block.id, $0.revision) })
        let readingText = blocks
            .filter { $0.disposition == .speak || $0.disposition == .unresolved }
            .map(\.text)
            .joined(separator: "\n\n")
        let durationEstimate = TeleprompterDurationEstimator.estimate(
            readingText,
            pace: input.pace,
            calibrationFactor: input.calibrationFactor
        )
        return .init(
            id: "draft-\(input.source.sourceRevisionID)-\(input.operation.rawValue)",
            sourceRevisionID: input.source.sourceRevisionID,
            sourceSHA256: input.source.sourceSHA256,
            targetMinutes: input.timingPlan.targetMinutes,
            targetSeconds: input.timingPlan.targetSeconds,
            budgetSeconds: input.timingPlan.budgetSeconds,
            blocks: blocks,
            revisions: revisions,
            boundaries: boundaries,
            durationEstimate: durationEstimate
        )
    }
}
