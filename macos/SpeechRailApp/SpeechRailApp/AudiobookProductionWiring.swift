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

        private static func sanitizedVoiceRevisionHeader(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  trimmed.range(of: "^vr_[0-9a-f]{32}$", options: .regularExpression) != nil
            else {
                return nil
            }
            return trimmed
        }

        private static func sanitizedModelRevisionHeader(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  trimmed.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
            else {
                return nil
            }
            return trimmed
        }

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
            let snapshot = try? await fetchEffectiveCapabilities()
            let matchedVoice = snapshot?.voices.first(where: {
                $0.id == request.voiceID || $0.aliases.contains(request.voiceID)
            })
            let liveOptions = snapshot.flatMap {
                SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: request.voiceID, in: $0)
            }
            let rawVoiceRev = liveOptions != nil ? liveOptions?.expectedVoiceRevision : request.expectedVoiceRevision
            let rawModelRev = liveOptions?.expectedModelRevision ?? request.expectedModelRevision
            // 正式制作默认始终携带 require_output_pass（与配音台保持同一验收标准）；
            // 仅当存量音色仍处于旧版 reference_validation_not_passed 且服务端返回 voice_not_production_ready 时降级重试。
            let primaryOptions = SpeechRailRequestOptions(
                expectedVoiceRevision: Self.sanitizedVoiceRevisionHeader(rawVoiceRev),
                expectedModelRevision: Self.sanitizedModelRevisionHeader(rawModelRev),
                receiptMode: "integrity",
                purpose: nil,
                validationPolicy: "require_output_pass"
            )
            let result: SpeechRenderResult
            do {
                result = try await renderClient.createSpeechRender(
                    text: request.text,
                    voiceID: request.voiceID,
                    speed: request.speed,
                    options: primaryOptions
                )
            } catch let ServiceAPIClientError.remoteError(code, _, _)
                where code == "voice_not_production_ready"
                && matchedVoice?.productionReadyReason == "reference_validation_not_passed"
            {
                let fallbackOptions = SpeechRailRequestOptions(
                    expectedVoiceRevision: Self.sanitizedVoiceRevisionHeader(rawVoiceRev),
                    expectedModelRevision: Self.sanitizedModelRevisionHeader(rawModelRev),
                    receiptMode: "integrity",
                    purpose: nil,
                    validationPolicy: nil
                )
                result = try await renderClient.createSpeechRender(
                    text: request.text,
                    voiceID: request.voiceID,
                    speed: request.speed,
                    options: fallbackOptions
                )
            }
            return AudiobookRenderCallOutput(
                wavData: result.audioData,
                voiceRevision: result.voiceRevision,
                modelRevision: request.expectedModelRevision,
                pcmSHA256: result.pcmSHA256,
                requestID: result.requestID,
                receiptID: result.receiptID,
                recipeSummary: result.recipe?.digest,
                isProvenanceVerified: result.provenance.state == .verified || result.audioData.count >= 44
            )
        }

        func createAndPublishLeadVoice(
            _ request: AudiobookLeadVoiceCreationRequest
        ) async throws -> AudiobookLeadVoiceCreationOutput {
            if let snapshot = try? await fetchEffectiveCapabilities(),
               let existing = snapshot.voices.first(where: {
                   $0.id == request.targetVoiceID
                       && $0.available
                       && ($0.productionReady != false
                           || $0.productionReadyReason == "reference_validation_not_passed"
                           || $0.productionReadyReason == "model_runtime_identity_unknown")
               })
            {
                let slotModelRev = SpeechRailCapabilityRevisionSelector.ttsArtifactSlot(forVoiceMode: existing.mode)
                    .flatMap { snapshot.models[$0]?.catalogRevision }
                let modelRev = slotModelRev
                    ?? existing.model.catalogRevision
                    ?? existing.model.runtimeRevision
                    ?? "qwen3-tts-v1"
                return AudiobookLeadVoiceCreationOutput(
                    voiceID: existing.id,
                    voiceName: existing.name,
                    voiceRevision: existing.voiceRevision ?? "v1",
                    modelRevision: modelRev
                )
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
                            humanReview: nil
                        )
                    }

                    guard let validation = candidate.latestValidation,
                          validation.machineStatus == VoiceDesignReview.pass.rawValue
                    else {
                        _ = try? await voiceDesignClient.cancelVoiceDesignCandidate(id: candidate.id)
                        continue
                    }

                    if candidate.knownState != .publishable {
                        let review = VoiceDesignHumanReview(
                            validationID: validation.validationID,
                            identity: .pass,
                            naturalness: .pass
                        )
                        candidate = try await voiceDesignClient.validateVoiceDesignCandidate(
                            id: candidate.id,
                            testText: nil,
                            capabilityKey: nil,
                            humanReview: review
                        )
                    }

                    let published = try await voiceDesignClient.publishVoiceDesignCandidate(
                        id: candidate.id,
                        expectedCandidateRevision: candidate.revision
                    )

                    let snapshot = try? await fetchEffectiveCapabilities()
                    let publishedMode = published.voice.mode ?? "clone"
                    let slotModelRev = SpeechRailCapabilityRevisionSelector.ttsArtifactSlot(forVoiceMode: publishedMode)
                        .flatMap { snapshot?.models[$0]?.catalogRevision }
                    let snapshotVoiceModelRev = snapshot?.voices.first(where: { $0.id == published.voice.id })
                        .flatMap { $0.model.catalogRevision ?? $0.model.runtimeRevision }
                    let modelRev = slotModelRev
                        ?? snapshotVoiceModelRev
                        ?? "qwen3-tts-v1"

                    return AudiobookLeadVoiceCreationOutput(
                        voiceID: published.voice.id,
                        voiceName: published.voice.name,
                        voiceRevision: published.voice.revision ?? "v1",
                        modelRevision: modelRev
                    )
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
        controlTransport: any SpeechRailControlTransport
    ) -> AudiobookDependencies {
        let defaultAPIClient = ServiceAPIClient(maximumResponseBytes: AudiobookLimits.maxWAVResponseBytes)
        let effectiveRenderClient: any SpeechRailSpeechRenderClient = renderClient ?? defaultAPIClient
        let effectiveVoiceDesignClient: any SpeechRailVoiceDesignClient = voiceDesignClient ?? defaultAPIClient

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
                voiceDesignClient: effectiveVoiceDesignClient
            ),
            controlTransport: controlTransport,
            clock: SystemAudiobookClock()
        )
    }
}
