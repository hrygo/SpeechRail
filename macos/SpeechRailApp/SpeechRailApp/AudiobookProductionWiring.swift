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

        func fetchEffectiveCapabilities() async throws -> EffectiveCapabilitySnapshot {
            let conditional = try await discoveryClient.fetchEffectiveCapabilities(ifNoneMatch: nil, cachedValue: nil)
            guard let snapshot = conditional.value else {
                throw ServiceAPIClientError.invalidResponse
            }
            return snapshot
        }

        func renderFragment(_ request: AudiobookRenderCallRequest) async throws -> AudiobookRenderCallOutput {
            let liveOptions = (try? await fetchEffectiveCapabilities()).flatMap {
                SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: request.voiceID, in: $0)
            }
            let options = SpeechRailRequestOptions(
                expectedVoiceRevision: liveOptions != nil ? liveOptions?.expectedVoiceRevision : request.expectedVoiceRevision,
                expectedModelRevision: liveOptions?.expectedModelRevision ?? request.expectedModelRevision,
                receiptMode: "integrity",
                purpose: "audiobook_production",
                validationPolicy: "require_output_pass"
            )
            let result = try await renderClient.createSpeechRender(
                text: request.text,
                voiceID: request.voiceID,
                speed: request.speed,
                options: options
            )
            return AudiobookRenderCallOutput(
                wavData: result.audioData,
                voiceRevision: result.voiceRevision,
                modelRevision: request.expectedModelRevision,
                pcmSHA256: result.pcmSHA256,
                requestID: result.requestID,
                receiptID: result.receiptID,
                recipeSummary: result.recipe?.digest,
                isProvenanceVerified: result.provenance.state == .verified
            )
        }
    }

    @MainActor
    public static func makeLiveDependencies(
        rootURL: URL = AudiobookProjectStore.defaultRootURL,
        llmProvider: LLMProvider,
        preferences: SessionPreferences,
        discoveryClient: any ServiceCapabilityDiscoveryClient,
        renderClient: (any SpeechRailSpeechRenderClient)? = nil,
        controlTransport: any SpeechRailControlTransport
    ) -> AudiobookDependencies {
        let effectiveRenderClient: any SpeechRailSpeechRenderClient = renderClient
            ?? ServiceAPIClient(maximumResponseBytes: AudiobookLimits.maxWAVResponseBytes)

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
                renderClient: effectiveRenderClient
            ),
            controlTransport: controlTransport,
            clock: SystemAudiobookClock()
        )
    }
}
