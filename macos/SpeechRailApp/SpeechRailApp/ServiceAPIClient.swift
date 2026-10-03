import Foundation
import SpeechRailControlKit

#if SWIFT_PACKAGE
// 同一 package 内的 conformance 不算 retroactive；Xcode 中是独立 framework，仍需 @retroactive。
extension ServiceAPIClientError: LocalizedError {}
#else
extension ServiceAPIClientError: @retroactive LocalizedError {}
#endif

extension ServiceAPIClientError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "服务地址无效"
        case .invalidResponse:
            "服务返回了无法识别的结果"
        case .requestFailed:
            "无法连接本机 SpeechRail 服务"
        case .requestTimedOut:
            "本机 SpeechRail 服务响应超时"
        case .notModifiedWithoutCache, .invalidContract, .http:
            // Server detail can contain backend paths or implementation text.
            // Feature surfaces map stable error codes to user-facing copy.
            "SpeechRail 服务请求失败"
        }
    }
}

public protocol ServiceDiagnosticsClient: Sendable {
    var port: Int? { get }
    /// 稿 `runtime` 的「服务端口」行写的是 `host:port`：只报端口时看不出这一行连的是
    /// 哪台主机。默认实现返回 nil，既有实现不必都实现它。
    var connectionHost: String? { get }

    func fetchHealthSnapshot() async throws -> HealthSnapshot
    func fetchMetrics() async throws -> RuntimeMetricsSnapshot
}

public extension ServiceDiagnosticsClient {
    var connectionHost: String? { nil }
}

public final class ServiceAPIClient: @unchecked Sendable {
    private static let longRunningRequestTimeout: TimeInterval = 180
    private let baseURL: URL
    private let transport: any ServiceTransporting
    private let requestBuilder: ServiceRequestBuilder

    public init(
        port: Int = 8201,
        session: URLSession = .shared,
        apiKey: String? = nil
    ) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let resolvedKey = apiKey ?? SpeechRailAPICredentialProvider.resolve()
        self.transport = ServiceHTTPTransport(session: session)
        self.requestBuilder = ServiceRequestBuilder(baseURL: self.baseURL, apiKey: resolvedKey)
    }

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        apiKey: String? = nil
    ) {
        self.baseURL = baseURL
        let resolvedKey = apiKey ?? SpeechRailAPICredentialProvider.resolve()
        self.transport = ServiceHTTPTransport(session: session)
        self.requestBuilder = ServiceRequestBuilder(baseURL: baseURL, apiKey: resolvedKey)
    }

    public var port: Int? { baseURL.port }

    public var connectionHost: String? { baseURL.host }

    public func fetchHealthSnapshot() async throws -> HealthSnapshot {
        try await get(path: "/health")
    }

    public func fetchHealth() async throws -> ServiceSnapshot {
        let payload = try await fetchHealthSnapshot()
        let ready = payload.ready ?? payload.asrReady.map { asrReady in
            guard let ttsReady = payload.ttsReady else { return asrReady }
            return asrReady && ttsReady
        }
        return ServiceSnapshot(
            serviceState: payload.status ?? "unknown",
            ready: ready,
            port: baseURL.port
        )
    }

    public func fetchMetrics() async throws -> RuntimeMetricsSnapshot {
        try await get(path: "/metrics")
    }

    public func fetchReadiness() async throws -> ReadySnapshot {
        try await get(path: "/readyz")
    }

    public func fetchEffectiveCapabilities(
        ifNoneMatch: String?
    ) async throws -> ServiceConditionalResponse<EffectiveCapabilitySnapshot> {
        try await fetchEffectiveCapabilities(ifNoneMatch: ifNoneMatch, cachedValue: nil)
    }

    public func fetchEffectiveCapabilities(
        ifNoneMatch: String?,
        cachedValue: EffectiveCapabilitySnapshot?
    ) async throws -> ServiceConditionalResponse<EffectiveCapabilitySnapshot> {
        let response = try await execute(
            makeRequest(
                path: "/v1/speechrail/capabilities",
                method: "GET",
                accept: "application/json",
                headers: conditionalHeaders(ifNoneMatch)
            )
        )
        return try ServiceResponseDecoder.decode(
            response.data,
            statusCode: response.metadata.statusCode,
            headers: response.metadata.headers,
            cachedValue: cachedValue
        )
    }

    public func fetchSafeVoices(
        ifNoneMatch: String?
    ) async throws -> ServiceConditionalResponse<SafeVoiceList> {
        try await fetchSafeVoices(ifNoneMatch: ifNoneMatch, cachedValue: nil)
    }

    public func fetchSafeVoices(
        ifNoneMatch: String?,
        cachedValue: SafeVoiceList?
    ) async throws -> ServiceConditionalResponse<SafeVoiceList> {
        let response = try await execute(
            makeRequest(
                path: "/v1/speechrail/voices",
                method: "GET",
                accept: "application/json",
                headers: conditionalHeaders(ifNoneMatch)
            )
        )
        return try ServiceResponseDecoder.decode(
            response.data,
            statusCode: response.metadata.statusCode,
            headers: response.metadata.headers,
            cachedValue: cachedValue
        )
    }

    public func fetchVoices() async throws -> [CreatorVoice] {
        let response: CreatorVoiceListResponse = try await get(path: "/v1/voices")
        guard response.object == "list" else {
            throw ServiceAPIClientError.invalidResponse
        }
        return response.data
    }

    public func fetchVoice(id: String) async throws -> CreatorVoice {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await get(path: "/v1/voices/\(id)")
    }

    public func createVoice(
        name: String,
        instruction: String,
        id: String?,
        seed: Int?
    ) async throws -> CreatorVoice {
        try await postJSON(
            path: "/v1/voices",
            body: CreateVoiceRequestBody(
                name: name,
                instruction: instruction,
                id: id,
                seed: seed
            )
        )
    }

    public func fetchVoiceRevisions(id: String) async throws -> [VoiceRevision] {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        let response: VoiceRevisionListResponse = try await get(
            path: "/v1/speechrail/voices/\(id)/revisions"
        )
        guard response.object == "list" else {
            throw ServiceAPIClientError.invalidResponse
        }
        return response.data
    }

    public func synthesize(
        _ request: SpeechRequest,
        options: SpeechRailRequestOptions = SpeechRailRequestOptions()
    ) async throws -> SpeechAudioResponse {
        try await postAudio(
            path: "/v1/audio/speech",
            body: request,
            accept: Self.audioAcceptHeader(for: request.responseFormat),
            headers: options.headers
        )
    }

    public func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions
    ) async throws -> Data {
        try await synthesize(
            SpeechRequest(
                input: text,
                voice: .name(voiceID),
                model: "speechrail/qwen3-tts",
                responseFormat: "wav",
                speed: speed
            ),
            // Audition is the permissive default, but an explicit caller
            // request still wins: formal production states its policy on the
            // options, so a client that only implements this primitive (such as
            // the protocol's default createSpeechRender) cannot silently
            // downgrade a deliverable to unverified output.
            options: options.withValidationPolicy(
                options.validationPolicy ?? "allow_unverified"
            )
        ).audioData
    }

    /// 正式制作：要多一份 render receipt 的 plan 身份与音色 revision。
    ///
    /// 收据拿不到不影响出音频——作品照常保存，只是把追溯状态标成不完整，
    /// 身份字段留空，不在制作路径上因为追溯信息而报失败，也不用任何值补齐它。
    public func createSpeechRender(
        text: String,
        voiceID: String,
        speed: Double,
        options: SpeechRailRequestOptions
    ) async throws -> SpeechRenderResult {
        let response = try await synthesize(
            SpeechRequest(
                input: text,
                voice: .name(voiceID),
                model: "speechrail/qwen3-tts",
                responseFormat: "wav",
                speed: speed
            ),
            // The render path is formal production: pin the strict validation
            // policy here (not just at the caller) so no caller can produce a
            // deliverable from an unverified clone voice. Every other option
            // is carried over from the caller.
            options: SpeechRailRequestOptions(
                expectedVoiceRevision: options.expectedVoiceRevision,
                expectedModelRevision: options.expectedModelRevision,
                pronunciationSet: options.pronunciationSet,
                receiptMode: "integrity",
                timingMode: options.timingMode,
                purpose: options.purpose,
                latencyBudgetMs: options.latencyBudgetMs,
                languageOverride: options.languageOverride,
                validationPolicy: "require_output_pass"
            )
        )
        var voiceRevision = options.expectedVoiceRevision
        var planID: String?
        var planSHA256: String?
        var pcmSHA256: String?
        var recipe: RenderRecipeSnapshot?
        var provenance = RenderProvenance(
            state: .unavailable,
            reason: response.receiptID == nil ? "receipt_not_negotiated" : "receipt_unavailable"
        )
        if let receiptID = response.receiptID,
           let receipt = try? await fetchReceipt(id: receiptID)
        {
            voiceRevision = receipt.voiceRevision ?? voiceRevision
            planID = receipt.planID
            planSHA256 = receipt.planSHA256
            pcmSHA256 = receipt.pcmSHA256
            recipe = receipt.recipe
            provenance = Self.provenance(for: receipt)
        }
        return SpeechRenderResult(
            audioData: response.audioData,
            planID: planID,
            voiceRevision: voiceRevision,
            planSHA256: planSHA256,
            pcmSHA256: pcmSHA256,
            recipe: recipe,
            provenance: provenance
        )
    }

    /// Maps one terminal receipt onto an honest traceability statement.
    ///
    /// A receipt that is still pending, or that never carried a recipe, does not
    /// make the render unverifiable audio: the caller keeps the audio and the
    /// reason it cannot claim full traceability.
    static func provenance(for receipt: RenderReceipt) -> RenderProvenance {
        guard receipt.status == .completed else {
            return RenderProvenance(
                state: .partial,
                reason: "receipt_status_\(receipt.status.wireValue)"
            )
        }
        guard let recipe = receipt.recipe else {
            return RenderProvenance(state: .partial, reason: "recipe_missing")
        }
        // `state` and `digest` are the server's own summary of itself; the
        // missing-field list is decoded independently. Requiring all three to
        // agree is what keeps "verified" from meaning "the server said so".
        guard recipe.state == .complete,
              recipe.digest != nil,
              recipe.missingFields.isEmpty
        else {
            return RenderProvenance(
                state: .partial,
                reason: Self.recipeIncompleteReason(recipe)
            )
        }
        // 配方齐全只说明服务端描述执行过程的事实齐全，与「App 手里的这段音频就是
        // 它渲染的那段」是两件事。没有音频摘要就没有任何可追溯的对象——此前
        // `.verified` 甚至不需要 `audio.pcm_sha256`，于是一个未经校验的摘要会
        // 跟着作品一起存下来（#188）。
        //
        // 注意这里只要求"存在"，不要求"已比对"：比对要在收到的字节上重新计算
        // 摘要，涉及主线程开销与"verified"的语义边界，属独立决策（#189）。
        guard receipt.pcmSHA256 != nil else {
            return RenderProvenance(state: .partial, reason: "audio_digest_missing")
        }
        return RenderProvenance(state: .verified, reason: nil)
    }

    /// Names which of the server's three signals disagreed.
    ///
    /// The missing-field list is the only one that carries the *facts*, so it
    /// is worth spelling out. When the list is empty the disagreement is
    /// between `state` and `digest`, and appending an empty list to
    /// `recipe_incomplete_` would read like a truncated string rather than a
    /// diagnosis.
    private static func recipeIncompleteReason(_ recipe: RenderRecipeSnapshot) -> String {
        if !recipe.missingFields.isEmpty {
            return "recipe_incomplete_\(recipe.missingFields.joined(separator: ","))"
        }
        if recipe.state != .complete {
            return "recipe_state_\(recipe.state.rawValue)"
        }
        return "recipe_digest_missing"
    }

    public func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        try await postAudio(
            path: "/v1/voices/previews",
            body: VoicePreviewRequestBody(
                input: text,
                instruction: instruction,
                seed: seed,
                speed: speed
            ),
            accept: "audio/*"
        ).audioData
    }

    public func fetchReceipt(id: String) async throws -> RenderReceipt {
        guard id.range(of: "^rr_[0-9a-f]{32}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await get(path: "/v1/speechrail/audio/receipts/\(id)")
    }

    public func fetchReceipt(byRequestID requestID: String) async throws -> RenderReceipt {
        guard requestID.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await get(
            path: "/v1/speechrail/audio/receipts/by-request/\(requestID)"
        )
    }

    public func fetchTiming(id: String) async throws -> TtsTimingResource {
        guard id.range(of: "^tm_[0-9a-f]{32}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await get(path: "/v1/speechrail/audio/timings/\(id)")
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
        let urlRequest = try makeTranscriptionRequest(request)
        let response = try await execute(urlRequest)
        let contentType = response.metadata.value(forHeader: HTTPHeaderNames.contentType)?.lowercased()
        if contentType?.hasPrefix("application/json") == true {
            do {
                let decoded: ServiceConditionalResponse<TranscriptionResponse> = try ServiceResponseDecoder.decode(
                    response.data,
                    statusCode: response.metadata.statusCode,
                    headers: response.metadata.headers
                )
                guard let value = decoded.value else {
                    throw ServiceAPIClientError.invalidResponse
                }
                return value
            } catch let error as ServiceContractDecodingError {
                throw ServiceAPIClientError.invalidContract(String(describing: error))
            }
        }
        guard let text = String(data: response.data, encoding: .utf8), !text.isEmpty else {
            throw ServiceAPIClientError.invalidResponse
        }
        return TranscriptionResponse(text: text)
    }

    public func createJob(_ request: JobCreateRequest) async throws -> Job {
        try await postJSON(path: "/v1/jobs", body: request)
    }

    public func fetchJobs(limit: Int = 20, cursor: String? = nil) async throws -> JobList {
        guard (1...100).contains(limit) else {
            throw ServiceAPIClientError.invalidURL
        }
        var query: [(String, String)] = [("limit", String(limit))]
        if let cursor, !cursor.isEmpty {
            query.append(("cursor", cursor))
        }
        return try await get(path: "/v1/jobs", query: query)
    }

    public func fetchJob(id: String) async throws -> Job {
        try await get(path: try jobPath(id: id))
    }

    public func cancelJob(id: String) async throws -> Job {
        let request = try makeRequest(
            path: try jobPath(id: id),
            method: "DELETE",
            accept: "application/json"
        )
        let response = try await execute(request)
        return try decodeJSON(Job.self, from: response)
    }

    public func fetchJobResult(id: String) async throws -> JobResult {
        let request = try makeRequest(
            path: try jobPath(id: id) + "/result",
            method: "GET",
            accept: "application/json"
        )
        let response = try await execute(request)
        let contentType = response.metadata.value(forHeader: HTTPHeaderNames.contentType)?.lowercased()
        if contentType?.hasPrefix("application/json") == true {
            let envelope = try decodeJSON(JobResultEnvelope.self, from: response)
            return JobResult(
                resultReference: envelope.resultReference,
                data: nil,
                contentType: contentType,
                metadata: response.metadata
            )
        }
        guard !response.data.isEmpty else {
            throw ServiceAPIClientError.invalidResponse
        }
        return JobResult(
            resultReference: nil,
            data: response.data,
            contentType: contentType,
            metadata: response.metadata
        )
    }

    public func createVoiceDesignCandidate(
        voiceID: String,
        name: String,
        instruction: String,
        referenceText: String,
        seed: Int,
        idempotencyKey: String?
    ) async throws -> VoiceDesignCandidate {
        var headers: [String: String] = [:]
        if let idempotencyKey, !idempotencyKey.isEmpty {
            headers["Idempotency-Key"] = idempotencyKey
        }
        let response: VoiceDesignCandidateEnvelope = try await postJSON(
            path: "/v1/voice-designs",
            body: VoiceDesignCreateRequestBody(
                voiceID: voiceID,
                name: name,
                instruction: instruction,
                referenceText: referenceText,
                seed: seed
            ),
            headers: headers
        )
        return response.candidate
    }

    public func fetchVoiceDesignCandidates() async throws -> [VoiceDesignCandidate] {
        let response: VoiceDesignCandidateListResponse = try await get(path: "/v1/voice-designs")
        guard response.object == "list" else {
            throw ServiceAPIClientError.invalidResponse
        }
        return response.data
    }

    public func fetchVoiceDesignCandidate(id: String) async throws -> VoiceDesignCandidate {
        let response: VoiceDesignCandidateEnvelope = try await get(
            path: try voiceDesignPath(id: id)
        )
        return response.candidate
    }

    public func fetchVoiceDesignReferenceAudio(
        id: String,
        expectedRevision: String
    ) async throws -> Data {
        try await getWAV(
            path: try voiceDesignPath(id: id) + "/audio",
            expectedRevision: expectedRevision
        )
    }

    public func fetchVoiceDesignValidationAudio(
        id: String,
        validationID: String,
        expectedRevision: String
    ) async throws -> Data {
        try await getWAV(
            path: try voiceDesignValidationAudioPath(
                candidateID: id,
                validationID: validationID
            ),
            expectedRevision: expectedRevision
        )
    }

    public func cancelVoiceDesignCandidate(id: String) async throws -> VoiceDesignCandidate {
        let response: VoiceDesignCandidateEnvelope = try await postJSON(
            path: try voiceDesignPath(id: id) + "/cancel",
            body: EmptyJSONBody()
        )
        return response.candidate
    }

    public func confirmVoiceDesignCandidate(
        id: String,
        referenceText: String?
    ) async throws -> VoiceDesignCandidate {
        let response: VoiceDesignCandidateEnvelope = try await postJSON(
            path: try voiceDesignPath(id: id) + "/confirm",
            body: VoiceDesignConfirmRequestBody(referenceText: referenceText)
        )
        return response.candidate
    }

    public func validateVoiceDesignCandidate(
        id: String,
        testText: String?,
        capabilityKey: String?,
        humanReview: VoiceDesignHumanReview?
    ) async throws -> VoiceDesignCandidate {
        let response: VoiceDesignCandidateEnvelope = try await postJSON(
            path: try voiceDesignPath(id: id) + "/validate",
            body: VoiceDesignValidateRequestBody(
                testText: testText,
                capabilityKey: capabilityKey,
                humanReview: humanReview
            )
        )
        return response.candidate
    }

    public func publishVoiceDesignCandidate(
        id: String,
        expectedCandidateRevision: String?
    ) async throws -> VoiceDesignPublishResult {
        try await postJSON(
            path: try voiceDesignPath(id: id) + "/publish",
            body: VoiceDesignPublishRequestBody(
                expectedCandidateRevision: expectedCandidateRevision
            )
        )
    }

    public func updateVoice(
        id: String,
        name: String?,
        instruction: String?,
        seed: Int?,
        expectedRevision: String
    ) async throws -> VoiceRevisionMutation {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        guard !expectedRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceAPIClientError.invalidContract("missing expected voice revision")
        }
        return try await postJSON(
            path: "/v1/speechrail/voices/\(id)",
            body: VoicePatch(
                name: name,
                instruction: instruction,
                seed: seed,
                expectedRevision: expectedRevision
            ),
            method: "PATCH"
        )
    }

    public func rollbackVoice(
        id: String,
        targetRevision: String,
        expectedRevision: String
    ) async throws -> VoiceRevisionMutation {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await postJSON(
            path: "/v1/speechrail/voices/\(id)/rollback",
            body: VoiceRollbackRequestBody(
                targetRevision: targetRevision,
                expectedRevision: expectedRevision
            )
        )
    }

    public func revokeVoiceRevision(id: String, revision: String) async throws -> VoiceRevisionMutation {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await postJSON(
            path: "/v1/speechrail/voices/\(id)/revisions/\(revision)/revoke",
            body: EmptyJSONBody()
        )
    }

    public func fetchPronunciationSet(id: String, revision: String) async throws -> PronunciationSet {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await get(
            path: "/v1/speechrail/pronunciation-sets/\(id)/revisions/\(revision)"
        )
    }

    public func fetchPronunciationSetSummaries() async throws -> [PronunciationSetSummary] {
        let response: PronunciationSetListResponse = try await get(
            path: "/v1/speechrail/pronunciation-sets"
        )
        guard response.object == "list" else {
            throw ServiceAPIClientError.invalidResponse
        }
        return response.data
    }

    public func upsertPronunciationSet(
        id: String,
        expectedRevision: String?,
        entries: [PronunciationEntry]
    ) async throws -> PronunciationSet {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await postJSON(
            path: "/v1/speechrail/pronunciation-sets/\(id)",
            body: PronunciationSetUpdate(
                id: id,
                expectedRevision: expectedRevision,
                entries: entries
            ),
            method: "PUT"
        )
    }

    public func revokePronunciationRevision(
        id: String,
        revision: String
    ) async throws -> PronunciationSet {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await postJSON(
            path: "/v1/speechrail/pronunciation-sets/\(id)/revisions/\(revision)/revoke",
            body: EmptyJSONBody()
        )
    }

    public func deletePronunciationSet(id: String) async throws {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        let request = try makeRequest(
            path: "/v1/speechrail/pronunciation-sets/\(id)",
            method: "DELETE",
            accept: "application/json"
        )
        _ = try await execute(request)
    }

    public func runVoiceQuality(
        id: String,
        request: VoiceQualityRunRequest = VoiceQualityRunRequest()
    ) async throws -> VoiceQualityRunResponse {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await postJSON(
            path: "/v1/speechrail/voices/\(id)/quality-runs",
            body: request
        )
    }

    /// `GET /v1/voices/clone/prompts`：官方提词稿。列表为空不是失败——服务端在资产缺失时
    /// 就返回空数组，界面照它显示「没有提词稿，自己写一段」。
    public func fetchClonePrompts() async throws -> [ClonePrompt] {
        let response: ClonePromptListResponse = try await get(path: "/v1/voices/clone/prompts")
        guard response.object == "list" else {
            throw ServiceAPIClientError.invalidResponse
        }
        return response.data
    }

    /// `POST /v1/voices/clone/validate`：与注册同一条管线，但不落任何档案。
    public func validateVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?
    ) async throws -> VoiceQualityReportSnapshot {
        let request = try makeVoiceCloneRequest(
            path: "/v1/voices/clone/validate",
            audio: audio,
            referenceText: referenceText,
            name: name,
            voiceID: voiceID,
            idempotencyKey: nil
        )
        let response = try await execute(request)
        do {
            return try JSONDecoder().decode(VoiceQualityReportSnapshot.self, from: response.data)
        } catch {
            throw ServiceAPIClientError.invalidResponse
        }
    }

    /// `POST /v1/voices/clone`：用参考录音注册音色。
    ///
    /// `idempotencyKey` 与 `voiceID` 由调用方在一次逻辑注册里保持不变：响应丢失时重试
    /// 同一个键，服务端会把第一次创建的那条档案还回来，而不是又建一个（§13.2）。
    public func registerVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?,
        idempotencyKey: String?
    ) async throws -> CreatorVoice {
        let request = try makeVoiceCloneRequest(
            path: "/v1/voices/clone",
            audio: audio,
            referenceText: referenceText,
            name: name,
            voiceID: voiceID,
            idempotencyKey: idempotencyKey
        )
        let response = try await execute(request)
        do {
            return try JSONDecoder().decode(CreatorVoice.self, from: response.data)
        } catch {
            throw ServiceAPIClientError.invalidResponse
        }
    }

    public func fetchCloneIdempotencyStatus(
        idempotencyKey: String
    ) async throws -> CloneIdempotencyStatus {
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              idempotencyKey.count <= 256
        else {
            throw ServiceAPIClientError.invalidContract("invalid clone idempotency key")
        }
        return try await get(
            path: "/v1/speechrail/voices/clone/idempotency",
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    /// `POST /v1/voices/clone` 与 `…/validate` 共用一份 multipart 正文：
    /// `audio` 文件字段 + `ref_text` / `name` / 可选 `id`，与 OpenAPI `VoiceCloneRequest` 一一对应。
    private func makeVoiceCloneRequest(
        path: String,
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?,
        idempotencyKey: String?
    ) throws -> URLRequest {
        var request = try makeRequest(path: path, method: "POST", accept: "application/json")
        request.timeoutInterval = Self.longRunningRequestTimeout
        let boundary = "speechrail-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            audio: audio,
            filename: "reference.wav",
            fields: [
                ("ref_text", referenceText),
                ("name", name),
                ("id", voiceID)
            ]
        )
        return request
    }

    /// 手工拼 multipart：URLSession 没有表单构造器，而 `text/plain` 的字段部分
    /// 必须与文件部分用同一条 boundary 串起来。字段顺序固定，便于对着请求体核对。
    nonisolated static func multipartBody(
        boundary: String,
        audio: Data,
        filename: String,
        fields: [(String, String?)],
        fileFieldName: String = "audio",
        audioContentType: String = "audio/wav"
    ) -> Data {
        var body = Data()
        func append(_ text: String) {
            body.append(Data(text.utf8))
        }
        for (name, value) in fields {
            guard let value, !value.isEmpty else { continue }
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(audioContentType)\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    public func deleteVoice(id: String) async throws {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        let request = try makeRequest(
            path: "/v1/voices/\(id)",
            method: "DELETE",
            accept: "application/json"
        )
        _ = try await execute(request)
    }

    private func get<Value: Decodable & Sendable>(
        path: String,
        query: [(String, String)] = [],
        headers: [String: String] = [:]
    ) async throws -> Value {
        let request = try makeRequest(
            path: path,
            method: "GET",
            accept: "application/json",
            headers: headers,
            query: query
        )
        let response = try await execute(request)
        do {
            let decoded: ServiceConditionalResponse<Value> = try ServiceResponseDecoder.decode(
                response.data,
                statusCode: response.metadata.statusCode,
                headers: response.metadata.headers
            )
            guard let value = decoded.value else {
                throw ServiceAPIClientError.invalidResponse
            }
            return value
        } catch {
            if let error = error as? ServiceAPIClientError {
                throw error
            }
            if let error = error as? ServiceContractDecodingError {
                throw ServiceAPIClientError.invalidContract(String(describing: error))
            }
            throw ServiceAPIClientError.invalidResponse
        }
    }

    private func postJSON<Body: Encodable, Value: Decodable & Sendable>(
        path: String,
        body: Body,
        method: String = "POST",
        headers: [String: String] = [:]
    ) async throws -> Value {
        var request = try makeRequest(
            path: path,
            method: method,
            accept: "application/json",
            headers: headers
        )
        request.timeoutInterval = Self.longRunningRequestTimeout
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await execute(request)
        do {
            let decoded: ServiceConditionalResponse<Value> = try ServiceResponseDecoder.decode(
                response.data,
                statusCode: response.metadata.statusCode,
                headers: response.metadata.headers
            )
            guard let value = decoded.value else {
                throw ServiceAPIClientError.invalidResponse
            }
            return value
        } catch {
            if let error = error as? ServiceAPIClientError {
                throw error
            }
            if let error = error as? ServiceContractDecodingError {
                throw ServiceAPIClientError.invalidContract(String(describing: error))
            }
            throw ServiceAPIClientError.invalidResponse
        }
    }

    private func postAudio<Body: Encodable>(
        path: String,
        body: Body,
        accept: String,
        headers: [String: String] = [:]
    ) async throws -> SpeechAudioResponse {
        var request = try makeRequest(
            path: path,
            method: "POST",
            accept: accept,
            headers: headers
        )
        request.timeoutInterval = Self.longRunningRequestTimeout
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await execute(request)
        return try ServiceResponseDecoder.decodeAudio(
            response.data,
            statusCode: response.metadata.statusCode,
            headers: response.metadata.headers
        )
    }

    private static func audioAcceptHeader(for responseFormat: String?) -> String {
        switch responseFormat?.lowercased() {
        case "mp3": "audio/mpeg"
        case "opus": "audio/opus"
        case "aac": "audio/aac"
        case "flac": "audio/flac"
        case "wav": "audio/wav"
        case "pcm": "audio/x-pcm"
        default: "audio/*"
        }
    }

    private func makeTranscriptionRequest(_ request: TranscriptionRequest) throws -> URLRequest {
        guard !request.filename.contains("\r"),
              !request.filename.contains("\n"),
              !request.filename.contains("\""),
              !request.contentType.contains("\r"),
              !request.contentType.contains("\n")
        else {
            throw ServiceAPIClientError.invalidURL
        }

        var fields: [(String, String?)] = [
            ("model", request.model),
            ("language", request.language),
            ("prompt", request.prompt),
            ("response_format", request.responseFormat),
            ("temperature", request.temperature.map { String($0) }),
            ("stream", request.stream.map { String($0) }),
            ("chunking_strategy", request.chunkingStrategy),
            ("timestamp_granularities", request.timestamps),
        ]
        fields.append(contentsOf: request.languages.map { ("languages", $0) })
        fields.append(contentsOf: request.timestampGranularities.map { ("timestamp_granularities[]", $0) })
        fields.append(contentsOf: request.include.map { ("include", $0) })
        fields.append(contentsOf: request.keywords.map { ("keywords", $0) })
        fields.append(contentsOf: request.knownSpeakerNames.map { ("known_speaker_names", $0) })
        fields.append(contentsOf: request.knownSpeakerReferences.map { ("known_speaker_references", $0) })

        let boundary = "speechrail-\(UUID().uuidString)"
        var urlRequest = try makeRequest(
            path: "/v1/audio/transcriptions",
            method: "POST",
            accept: Self.transcriptionAcceptHeader(for: request.responseFormat)
        )
        urlRequest.timeoutInterval = Self.longRunningRequestTimeout
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: HTTPHeaderNames.contentType
        )
        urlRequest.httpBody = Self.multipartBody(
            boundary: boundary,
            audio: request.audio,
            filename: request.filename,
            fields: fields,
            fileFieldName: "file",
            audioContentType: request.contentType
        )
        return urlRequest
    }

    private static func transcriptionAcceptHeader(for responseFormat: String) -> String {
        switch responseFormat.lowercased() {
        case "text", "srt", "vtt": "text/plain"
        default: "application/json"
        }
    }

    private func jobPath(id: String) throws -> String {
        guard id.range(of: "^job_[0-9a-f]{32}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return "/v1/jobs/\(id)"
    }

    private func voiceDesignPath(id: String) throws -> String {
        guard id.range(of: "^vd_[0-9a-f]{24}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return "/v1/voice-designs/\(id)"
    }

    private func voiceDesignValidationAudioPath(
        candidateID: String,
        validationID: String
    ) throws -> String {
        guard validationID.range(
            of: "^vv_[0-9a-f]{24}$",
            options: .regularExpression
        ) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try voiceDesignPath(id: candidateID)
            + "/validations/\(validationID)/audio"
    }

    private func getWAV(
        path: String,
        expectedRevision: String
    ) async throws -> Data {
        guard expectedRevision.range(
            of: "^vr_[0-9a-f]{32}$",
            options: .regularExpression
        ) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        let request = try makeRequest(
            path: path,
            method: "GET",
            accept: "audio/wav",
            headers: [
                "SpeechRail-Expected-Candidate-Revision": expectedRevision,
            ]
        )
        let response = try await execute(request)
        guard response.data.count >= 12,
              response.data.prefix(4) == Data("RIFF".utf8),
              response.data.dropFirst(8).prefix(4) == Data("WAVE".utf8)
        else {
            throw ServiceAPIClientError.invalidResponse
        }
        return response.data
    }

    private func decodeJSON<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from response: ServiceRawHTTPResponse
    ) throws -> Value {
        do {
            let decoded: ServiceConditionalResponse<Value> = try ServiceResponseDecoder.decode(
                response.data,
                statusCode: response.metadata.statusCode,
                headers: response.metadata.headers
            )
            guard let value = decoded.value else {
                throw ServiceAPIClientError.invalidResponse
            }
            return value
        } catch let error as ServiceAPIClientError {
            throw error
        } catch let error as ServiceContractDecodingError {
            throw ServiceAPIClientError.invalidContract(String(describing: error))
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        accept: String,
        headers: [String: String] = [:],
        query: [(String, String)] = []
    ) throws -> URLRequest {
        var request = try requestBuilder.make(
            path: path,
            method: method,
            query: query,
            headers: headers,
            body: nil
        )
        request.setValue(accept, forHTTPHeaderField: HTTPHeaderNames.accept)
        return request
    }

    private func execute(_ request: URLRequest) async throws -> ServiceRawHTTPResponse {
        let response = try await transport.execute(request)
        if (200..<300).contains(response.metadata.statusCode)
            || response.metadata.statusCode == 304
        {
            return response
        }
        throw ServiceResponseDecoder.makeError(
            data: response.data,
            metadata: response.metadata
        )
    }

    private func conditionalHeaders(_ etag: String?) -> [String: String] {
        guard let etag, !etag.isEmpty else { return [:] }
        return [HTTPHeaderNames.ifNoneMatch: etag]
    }
}

extension ServiceAPIClient:
    ServiceDiagnosticsClient,
    SpeechRailCreatorClient,
    ServiceCapabilityDiscoveryClient
{}

private struct CreatorVoiceListResponse: Decodable {
    let object: String
    let data: [CreatorVoice]
}

/// `GET /v1/voices/clone/prompts` 的信封（OpenAPI `ClonePromptList`）。
private struct ClonePromptListResponse: Decodable {
    let object: String
    let data: [ClonePrompt]
}

private struct PronunciationSetListResponse: Decodable {
    let object: String
    let data: [PronunciationSetSummary]
}

private struct VoiceDesignCandidateEnvelope: Decodable {
    let candidate: VoiceDesignCandidate
}

private struct VoiceDesignCandidateListResponse: Decodable {
    let object: String
    let data: [VoiceDesignCandidate]
}

private struct VoicePreviewRequestBody: Encodable {
    let model = "speechrail/qwen3-tts"
    let input: String
    let instruction: String
    let seed: Int?
    let speed: Double
    let language = "auto"
    let responseFormat = "wav"

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case instruction
        case seed
        case speed
        case language
        case responseFormat = "response_format"
    }
}

private struct VoiceDesignCreateRequestBody: Encodable {
    let voiceID: String
    let name: String
    let instruction: String
    let referenceText: String
    let seed: Int
    let language = "zh"

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
        case instruction
        case referenceText = "reference_text"
        case seed
        case language
    }
}

private struct VoiceDesignConfirmRequestBody: Encodable {
    let referenceText: String?

    enum CodingKeys: String, CodingKey {
        case referenceText = "reference_text"
    }
}

private struct VoiceDesignValidateRequestBody: Encodable {
    let testText: String?
    let capabilityKey: String?
    let humanReview: VoiceDesignHumanReview?

    enum CodingKeys: String, CodingKey {
        case testText = "test_text"
        case capabilityKey = "capability_key"
        case humanReview = "human_review"
    }
}

private struct VoiceDesignPublishRequestBody: Encodable {
    let expectedCandidateRevision: String?

    enum CodingKeys: String, CodingKey {
        case expectedCandidateRevision = "expected_candidate_revision"
    }
}

private struct CreateVoiceRequestBody: Encodable {
    let name: String
    let instruction: String
    let id: String?
    let seed: Int?
}

private struct VoiceRevisionListResponse: Decodable {
    let object: String
    let data: [VoiceRevision]
}

private struct JobResultEnvelope: Decodable, Sendable {
    let resultReference: String

    enum CodingKeys: String, CodingKey {
        case resultReference = "result_ref"
    }
}

private struct VoiceRollbackRequestBody: Encodable {
    let targetRevision: String
    let expectedRevision: String

    enum CodingKeys: String, CodingKey {
        case targetRevision = "target_revision"
        case expectedRevision = "expected_revision"
    }
}

private struct EmptyJSONBody: Encodable {}
