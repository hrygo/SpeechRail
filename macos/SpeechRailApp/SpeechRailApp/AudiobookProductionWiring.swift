import Foundation
import SpeechRailControlKit

/// T13：有声书工坊生产装配（将独立 SQLite 库、冻结的 LLMProvider client、8 MiB 上限的语音合成 client 与 XPC 控制通道接入 AudiobookDependencies）。
public enum AudiobookProductionWiring {
    private final class LiveAudiobookAnalysisClient: AudiobookAnalysisClient, @unchecked Sendable {
        let configurationDigest: String
        private let provider: LLMProvider
        private let resolved: ResolvedLLMConfiguration
        private let timeoutSeconds: TimeInterval
        private let diagnosticsCollector = AudiobookAnalysisCallDiagnosticsCollector()

        var callDiagnostics: AudiobookAnalysisCallDiagnosticsCollector? { diagnosticsCollector }

        init(
            snapshot: AudiobookAnalysisConfigSnapshot,
            resolved: ResolvedLLMConfiguration,
            provider: LLMProvider,
            timeoutSeconds: TimeInterval = AudiobookLimits.analysisCallTimeoutSeconds
        ) {
            self.configurationDigest = snapshot.configurationDigest
            self.resolved = resolved
            self.provider = provider
            self.timeoutSeconds = timeoutSeconds
        }

        func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
            let schemaObject = try prompt.schemaObject()
            let startedAt = Date()
            // 每次传输尝试独立结算：completeJSON 内部的 transmission 重试会产生多次
            // started，每次 response/failed 终态都记一条回执（耗时/token/错误码），
            // 管线按记录顺序转为 llmCallFinished 事件。
            let collector = diagnosticsCollector
            // run 关联：管线把本次 runID 写进 prompt，这里用它做 LLM 观测的 sessionID，
            // 让进度事件与 LLM 观测一串到底；缺失时退回随机 ID（仅防御性兜底）。
            let observationContext = LLMRequestContext(
                sessionID: prompt.observationSessionID ?? UUID().uuidString
            )
            do {
                let content = try await provider.completeJSON(
                    configuration: resolved.configuration,
                    apiKey: resolved.apiKey,
                    instructions: prompt.instructions,
                    input: prompt.input,
                    schema: schemaObject,
                    maxOutputTokens: prompt.maxOutputTokens,
                    timeout: timeoutSeconds,
                    observationContext: observationContext,
                    observationHandler: { observation in
                        switch observation.kind {
                        case .providerResponse:
                            collector.record(AudiobookAnalysisCallDiagnosticsCollector.Call(
                                elapsedMilliseconds: observation.elapsedMilliseconds ?? max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                                promptTokens: observation.promptTokens,
                                completionTokens: observation.completionTokens,
                                reasoningTokens: observation.reasoningTokens
                            ))
                        case .providerFailed:
                            collector.record(AudiobookAnalysisCallDiagnosticsCollector.Call(
                                elapsedMilliseconds: observation.elapsedMilliseconds ?? max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                                errorCode: observation.errorCode
                            ))
                        case .providerRequestStarted:
                            break
                        }
                    },
                    structuredOutputMode: .jsonSchema
                )
                return content
            } catch {
                if !collector.hasPendingCalls {
                    // 观测钩子未触发时（如进入 completeJSON 前就抛错）仍落地一次回执，
                    // 保证每次调用都有诊断记录，错误码只保留分类结论。
                    collector.record(AudiobookAnalysisCallDiagnosticsCollector.Call(
                        elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                        errorCode: AudiobookAnalysisErrorCode.code(for: error)
                    ))
                }
                throw error
            }
        }
    }

    private struct LiveAudiobookSpeechRenderer: AudiobookSpeechRenderer {
        let discoveryClient: any ServiceCapabilityDiscoveryClient
        let renderClient: any SpeechRailSpeechRenderClient
        let voiceDesignClient: any SpeechRailVoiceDesignClient
        let voiceCatalog: VoiceCatalogStore

        func fetchEffectiveCapabilities() async throws -> EffectiveCapabilitySnapshot {
            let conditional = try await discoveryClient.fetchEffectiveCapabilities(ifNoneMatch: nil, cachedValue: nil)
            guard let snapshot = conditional.value else {
                throw ServiceAPIClientError.invalidResponse
            }
            return snapshot
        }

        private static func padReferenceTextIfNeeded(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 38 {
                return String(trimmed.prefix(180))
            }
            let suffix = "，在漫长的岁月里，每个人都在静静聆听着远方的回响与心中的答案。"
            let combined = trimmed.isEmpty
                ? "在漫长的岁月里，海风吹拂着古老的礁石，每个人都在静静聆听着远方的回响与心中的答案。"
                : (trimmed + suffix)
            return String(combined.prefix(180))
        }

        func renderFragment(_ request: AudiobookRenderCallRequest) async throws -> AudiobookRenderCallOutput {
            let snapshot = try await fetchEffectiveCapabilities()
            let binding = AudiobookVoiceBinding(
                roleID: UUID(), voiceID: request.voiceID, voiceRevision: request.expectedVoiceRevision,
                modelRevision: request.expectedModelRevision, allowedSpeed: request.speed, callerSeed: request.seed
            )
            try AudiobookCastRegistry.validateRenderBinding(binding, snapshot: snapshot)
            guard let voice = snapshot.voices.first(where: { $0.id == request.voiceID }),
                  (await voiceCatalog.refresh()).permits(voice, bookID: request.bookID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) else {
                throw ServiceAPIClientError.invalidContract("voice_scope_changed")
            }
            let result = try await renderClient.createSpeechRender(
                text: request.text, voiceID: request.voiceID, speed: request.speed,
                options: SpeechRailRequestOptions(
                    callerSeed: request.seed, expectedVoiceRevision: request.expectedVoiceRevision,
                    expectedModelRevision: request.expectedModelRevision, receiptMode: "integrity",
                    validationPolicy: "require_output_pass"
                )
            )
            return AudiobookRenderCallOutput(
                wavData: result.audioData,
                voiceRevision: result.voiceRevision,
                modelRevision: result.recipe?.modelArtifactRevision,
                pcmSHA256: result.pcmSHA256,
                requestID: result.requestID,
                receiptID: result.receiptID,
                recipeSummary: result.recipe?.digest,
                isProvenanceVerified: result.provenance.state == .verified
            )
        }

        func renderAudition(_ request: AudiobookRenderCallRequest) async throws -> Data {
            let snapshot = try await fetchEffectiveCapabilities()
            let binding = AudiobookVoiceBinding(roleID: UUID(), voiceID: request.voiceID,
                voiceRevision: request.expectedVoiceRevision, modelRevision: request.expectedModelRevision,
                allowedSpeed: request.speed, callerSeed: request.seed)
            try AudiobookCastRegistry.validateRenderBinding(binding, snapshot: snapshot, requireProductionReady: false)
            guard let voice = snapshot.voices.first(where: { $0.id == request.voiceID }),
                  (await voiceCatalog.refresh()).permits(voice, bookID: request.bookID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) else {
                throw ServiceAPIClientError.invalidContract("voice_scope_changed")
            }
            return try await renderClient.createSpeech(text: request.text, voiceID: request.voiceID, speed: request.speed,
                options: .init(callerSeed: request.seed, expectedVoiceRevision: request.expectedVoiceRevision,
                    expectedModelRevision: request.expectedModelRevision, validationPolicy: "allow_unverified"))
        }

        private static func leadVoiceOutput(voiceID: String, snapshot: EffectiveCapabilitySnapshot) throws -> AudiobookLeadVoiceCreationOutput {
            guard let voice = snapshot.voices.first(where: { $0.id == voiceID }),
                  let revision = voice.voiceRevision,
                  let model = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: voiceID, in: snapshot)?.expectedModelRevision else {
                throw ServiceAPIClientError.invalidContract("voice_identity_unknown")
            }
            try AudiobookCastRegistry.validateRenderBinding(.init(roleID: UUID(), voiceID: voiceID, voiceRevision: revision, modelRevision: model), snapshot: snapshot)
            return AudiobookLeadVoiceCreationOutput(voiceID: voice.id, voiceName: voice.name, voiceRevision: revision, modelRevision: model)
        }

        func createAndPublishLeadVoice(
            _ request: AudiobookLeadVoiceCreationRequest
        ) async throws -> AudiobookLeadVoiceCreationOutput {
            if let snapshot = try? await fetchEffectiveCapabilities(), snapshot.voices.contains(where: { $0.id == request.targetVoiceID }) {
                return try Self.leadVoiceOutput(voiceID: request.targetVoiceID, snapshot: snapshot)
            }

            let rawCandidates = request.referenceTextCandidates.isEmpty
                ? ["在漫长的岁月里，海风吹拂着古老的礁石，每个人都在寻找属于自己的答案与远方。"]
                : request.referenceTextCandidates
            let candidates = rawCandidates.map(Self.padReferenceTextIfNeeded)
            var lastError: Error = ServiceAPIClientError.invalidResponse

            for (attemptIndex, refText) in candidates.prefix(2).enumerated() {
                let attemptSeed = max(0, request.seed + attemptIndex * 17)
                let attemptVoiceID = attemptIndex == 0
                    ? request.targetVoiceID
                    : "\(request.targetVoiceID)_\(attemptIndex)"
                let idempotencyKey = "ab-lead-\(request.bookID.uuidString.prefix(8))-\(request.roleID.uuidString.prefix(8))-\(attemptIndex)"

                do {
                    var candidate = try await voiceDesignClient.createVoiceDesignCandidate(
                        voiceID: attemptVoiceID,
                        name: request.voiceName,
                        instruction: request.instruction,
                        referenceText: refText,
                        seed: attemptSeed,
                        idempotencyKey: idempotencyKey
                    )

                    if candidate.knownState != .confirmed
                        && candidate.knownState != .validating
                        && candidate.knownState != .publishable
                        && candidate.knownState != .published
                    {
                        candidate = try await voiceDesignClient.confirmVoiceDesignCandidate(
                            id: candidate.id,
                            referenceText: nil
                        )
                    }

                    let validationTestText = refText.contains("清晨的微风拂过宁静的湖面")
                        ? "在漫长的岁月里，海风吹拂着古老的礁石，每个人都在寻找属于自己的答案与远方。"
                        : "清晨的微风拂过宁静的湖面，远处的钟声在山谷间轻轻回荡，带来温暖的希望。"

                    if candidate.knownState == .confirmed || candidate.knownState == .validating {
                        candidate = try await voiceDesignClient.validateVoiceDesignCandidate(
                            id: candidate.id,
                            testText: validationTestText,
                            capabilityKey: nil,
                            mode: .validationOnly
                        )
                    }

                    guard let validation = candidate.latestValidation,
                          validation.machineStatus == VoiceDesignReview.pass.rawValue
                    else {
                        _ = try? await voiceDesignClient.cancelVoiceDesignCandidate(id: candidate.id)
                        continue
                    }

                    if candidate.knownState != .publishable {
                        candidate = try await voiceDesignClient.validateVoiceDesignCandidate(
                            id: candidate.id,
                            testText: nil,
                            capabilityKey: nil,
                            mode: .automatedAcceptance
                        )
                    }

                    let published = try await voiceDesignClient.publishVoiceDesignCandidate(
                        id: candidate.id,
                        expectedCandidateRevision: candidate.revision
                    )

                    let snapshot = try await fetchEffectiveCapabilities()
                    let output = try Self.leadVoiceOutput(voiceID: published.voice.id, snapshot: snapshot)
                    guard output.voiceRevision == published.voice.revision else { throw ServiceAPIClientError.invalidContract("casting_identity_changed") }
                    return output
                } catch {
                    lastError = error
                    continue
                }
            }

            throw lastError
        }
    }

    @MainActor
    public static func makeLiveDependencies(
        rootURL: URL = AudiobookProjectStore.defaultRootURL,
        llmProvider: LLMProvider,
        preferences: SessionPreferences,
        discoveryClient: any ServiceCapabilityDiscoveryClient,
        renderClient: (any SpeechRailSpeechRenderClient)? = nil,
        voiceDesignClient: (any SpeechRailVoiceDesignClient)? = nil,
        controlTransport: any SpeechRailControlTransport,
        voiceCatalog: VoiceCatalogStore? = nil
    ) -> AudiobookDependencies {
        let effectiveCatalog = voiceCatalog ?? .shared
        let defaultAPIClient = (renderClient == nil || voiceDesignClient == nil)
            ? ServiceAPIClient(maximumResponseBytes: AudiobookLimits.maxWAVResponseBytes) : nil
        let effectiveRenderClient: any SpeechRailSpeechRenderClient = renderClient ?? defaultAPIClient!
        let effectiveVoiceDesignClient: any SpeechRailVoiceDesignClient = voiceDesignClient ?? defaultAPIClient!

        return AudiobookDependencies(
            makeStore: {
                try AudiobookProjectStore(root: rootURL)
            },
            makeAnalysisClient: { snapshot in
                let resolved = await MainActor.run {
                    preferences.resolvedLLMConfiguration(for: .audiobook)
                }
                guard resolved.configuration.isConfigured,
                      resolved.configuration.isBaseURLValid,
                      !resolved.configuration.embedsCredential
                else {
                    throw AudiobookAnalysisError.notConfigured
                }
                let currentSnapshot = AudiobookAnalysisConfigSnapshot(
                    resolved: resolved,
                    generation: snapshot.generation
                )
                guard currentSnapshot.configurationDigest == snapshot.configurationDigest else {
                    throw AudiobookAnalysisError.configurationChangedDuringRun
                }
                return LiveAudiobookAnalysisClient(
                    snapshot: snapshot,
                    resolved: resolved,
                    provider: llmProvider
                )
            },
            resolveAnalysisSnapshot: { generation in
                let resolved = preferences.resolvedLLMConfiguration(for: .audiobook)
                return AudiobookAnalysisConfigSnapshot(
                    resolved: resolved,
                    generation: generation
                )
            },
            speechRenderer: LiveAudiobookSpeechRenderer(
                discoveryClient: discoveryClient,
                renderClient: effectiveRenderClient,
                voiceDesignClient: effectiveVoiceDesignClient,
                voiceCatalog: effectiveCatalog
            ),
            controlTransport: controlTransport,
            clock: SystemAudiobookClock(),
            voiceCatalog: effectiveCatalog
        )
    }
}
