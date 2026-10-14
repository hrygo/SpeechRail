import Foundation
import SpeechRailControlKit

/// T13：有声书工坊生产装配（将独立 SQLite 库、冻结的 LLMProvider client、8 MiB 上限的语音合成 client 与 XPC 控制通道接入 AudiobookDependencies）。
public enum AudiobookProductionWiring {
    private final class LiveAudiobookAnalysisClient: AudiobookAnalysisClient, @unchecked Sendable {
        let configurationDigest: String
        private let provider: LLMProvider
        private let resolved: ResolvedLLMConfiguration
        private let timeoutSeconds: TimeInterval

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
            return try await provider.completeJSON(
                configuration: resolved.configuration,
                apiKey: resolved.apiKey,
                instructions: prompt.instructions,
                input: prompt.input,
                schema: schemaObject,
                maxOutputTokens: prompt.maxOutputTokens,
                timeout: timeoutSeconds,
                structuredOutputMode: .jsonSchema
            )
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
            let options = SpeechRailRequestOptions(
                expectedVoiceRevision: request.expectedVoiceRevision,
                expectedModelRevision: request.expectedModelRevision,
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
