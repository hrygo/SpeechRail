@preconcurrency import CoreML
import Darwin
import FluidAudio
import Foundation

private struct ProbeOptions {
    let modelDirectory: URL
    let audioURLs: [URL]
    let clusteringPolicies: [ProbeClusteringPolicy]
    let preprocessingPolicies: [ProbePreprocessingPolicy]

    init(arguments: [String]) throws {
        var modelPath: String?
        var clusteringJSON: String?
        var preprocessingJSON: String?
        var audioPaths: [String] = []
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else {
                throw ProbeError.invalidArguments
            }
            let value = arguments[index + 1]
            switch flag {
            case "--model-dir":
                guard modelPath == nil else { throw ProbeError.invalidArguments }
                modelPath = value
            case "--audio":
                audioPaths.append(value)
            case "--clustering-policies-json":
                guard clusteringJSON == nil else { throw ProbeError.invalidArguments }
                clusteringJSON = value
            case "--preprocessing-policies-json":
                guard preprocessingJSON == nil else { throw ProbeError.invalidArguments }
                preprocessingJSON = value
            default:
                throw ProbeError.invalidArguments
            }
            index += 2
        }
        guard let modelPath, !modelPath.isEmpty, let clusteringJSON, let preprocessingJSON,
              !audioPaths.isEmpty,
              audioPaths.allSatisfy({ !$0.isEmpty })
        else { throw ProbeError.invalidArguments }
        modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true).standardizedFileURL
        audioURLs = audioPaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard let policyData = clusteringJSON.data(using: .utf8),
              let policyRows = try JSONSerialization.jsonObject(with: policyData) as? [[String: Any]],
              !policyRows.isEmpty
        else { throw ProbeError.invalidArguments }
        clusteringPolicies = try policyRows.map(ProbeClusteringPolicy.init)
        guard let preprocessingData = preprocessingJSON.data(using: .utf8),
              let preprocessingRows = try JSONSerialization.jsonObject(with: preprocessingData)
                as? [[String: Any]],
              !preprocessingRows.isEmpty
        else { throw ProbeError.invalidArguments }
        preprocessingPolicies = try preprocessingRows.map(ProbePreprocessingPolicy.init)
    }
}

private struct ProbeClusteringPolicy: Sendable {
    let threshold: Double
    let warmStartFa: Double
    let warmStartFb: Double

    init(row: [String: Any]) throws {
        guard let threshold = row["threshold"] as? Double,
              let warmStartFa = row["warm_start_fa"] as? Double,
              let warmStartFb = row["warm_start_fb"] as? Double,
              threshold.isFinite, threshold > 0, threshold <= 2,
              warmStartFa.isFinite, warmStartFa > 0,
              warmStartFb.isFinite, warmStartFb > 0
        else { throw ProbeError.invalidArguments }
        self.threshold = threshold
        self.warmStartFa = warmStartFa
        self.warmStartFb = warmStartFb
    }
}

private struct ProbePreprocessingPolicy: Sendable {
    let segmentationStepRatio: Double
    let embeddingMinSegmentDurationSeconds: Double

    init(row: [String: Any]) throws {
        guard let segmentationStepRatio = row["segmentation_step_ratio"] as? Double,
              let embeddingMinSegmentDurationSeconds = row[
                  "embedding_min_segment_duration_seconds"
              ] as? Double,
              segmentationStepRatio.isFinite, segmentationStepRatio > 0,
              segmentationStepRatio <= 1,
              embeddingMinSegmentDurationSeconds.isFinite,
              embeddingMinSegmentDurationSeconds >= 0
        else { throw ProbeError.invalidArguments }
        self.segmentationStepRatio = segmentationStepRatio
        self.embeddingMinSegmentDurationSeconds = embeddingMinSegmentDurationSeconds
    }
}

private enum ProbeError: Error {
    case invalidArguments
    case invalidModel
}

@main
private struct GlobalContextProbe {
    static func main() async {
        do {
            let options = try ProbeOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let models = try loadModels(from: options.modelDirectory)
            guard !options.clusteringPolicies.isEmpty, !options.preprocessingPolicies.isEmpty else {
                throw ProbeError.invalidArguments
            }
            let clusterManagers = options.preprocessingPolicies.map { preprocessingPolicy in
                options.clusteringPolicies.map { clusteringPolicy in
                    let config = makeConfig(
                        preprocessing: preprocessingPolicy,
                        clustering: clusteringPolicy
                    )
                    let manager = OfflineDiarizerManager(config: config)
                    manager.initialize(models: models)
                    return manager
                }
            }

            var results: [[String: Any]] = []
            for (offset, audioURL) in options.audioURLs.enumerated() {
                let (source, loadDuration) = try AudioSourceFactory().makeDiskBackedSource(
                    from: audioURL,
                    targetSampleRate: 16_000
                )
                defer { source.cleanup() }
                var preprocessingResults: [[String: Any]] = []
                for (preprocessingIndex, preprocessingPolicy) in
                    options.preprocessingPolicies.enumerated()
                {
                    let (prepared, preparationRuntime) = try await prepareAudio(
                        models: models,
                        preprocessingPolicy: preprocessingPolicy,
                        clusteringPolicy: options.clusteringPolicies[0],
                        source: source,
                        loadDuration: loadDuration
                    )
                    var candidateResults: [[String: Any]] = []
                    for (candidateIndex, manager) in
                        clusterManagers[preprocessingIndex].enumerated()
                    {
                        let candidateStartedAt = ProcessInfo.processInfo.systemUptime
                        let diarization = try manager.cluster(prepared)
                        candidateResults.append([
                            "candidate_index": candidateIndex,
                            "runtime_seconds": ProcessInfo.processInfo.systemUptime - candidateStartedAt,
                            "segments": try anonymizedSegments(diarization.segments),
                        ])
                    }
                    preprocessingResults.append([
                        "preprocessing_index": preprocessingIndex,
                        "preparation_runtime_seconds": preparationRuntime,
                        "candidates": candidateResults,
                    ])
                }
                results.append([
                    "audio_loading_runtime_seconds": loadDuration,
                    "preprocessing_profiles": preprocessingResults,
                ])
                print("PROGRESS \(offset + 1) \(options.audioURLs.count)")
            }

            let payload: [String: Any] = ["schema_version": 1, "results": results]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else {
                throw ProbeError.invalidModel
            }
            print("GLOBAL_PROBE_JSON\t\(json)")
        } catch {
            fputs("global diarization probe failed\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func loadModels(from directory: URL) throws -> OfflineDiarizerModels {
        guard directory.isFileURL else { throw ProbeError.invalidModel }
        func load(_ name: String, cpuOnly: Bool = false) throws -> MLModel {
            let compiledModel = directory.appendingPathComponent(name + ".mlmodelc", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: compiledModel.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { throw ProbeError.invalidModel }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = cpuOnly ? .cpuOnly : .all
            return try MLModel(contentsOf: compiledModel, configuration: configuration)
        }

        let parametersURL = directory.appendingPathComponent("plda-parameters.json")
        let parameters = try JSONSerialization.jsonObject(with: Data(contentsOf: parametersURL)) as? [String: Any]
        guard let tensors = parameters?["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let encoded = psi["data_base64"] as? String,
              let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty,
              bytes.count.isMultiple(of: MemoryLayout<Float>.size)
        else { throw ProbeError.invalidModel }

        var values = [Float](repeating: 0, count: bytes.count / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { destination in
            bytes.copyBytes(to: destination)
        }
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw ProbeError.invalidModel
        }

        return OfflineDiarizerModels(
            segmentationModel: try load("Segmentation"),
            fbankModel: try load("FBank", cpuOnly: true),
            embeddingModel: try load("Embedding"),
            pldaRhoModel: try load("PldaRho"),
            pldaPsi: values.map(Double.init),
            compilationDuration: 0
        )
    }

    private nonisolated static func makeConfig(
        preprocessing: ProbePreprocessingPolicy,
        clustering: ProbeClusteringPolicy
    ) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        config.segmentation.stepRatio = preprocessing.segmentationStepRatio
        config.embedding.minSegmentDurationSeconds =
            preprocessing.embeddingMinSegmentDurationSeconds
        config.clustering.threshold = clustering.threshold
        config.clustering.warmStartFa = clustering.warmStartFa
        config.clustering.warmStartFb = clustering.warmStartFb
        config.zeroVoteReembed = .init(enabled: false)
        return config
    }

    private nonisolated static func prepareAudio(
        models: OfflineDiarizerModels,
        preprocessingPolicy: ProbePreprocessingPolicy,
        clusteringPolicy: ProbeClusteringPolicy,
        source: DiskBackedAudioSampleSource,
        loadDuration: TimeInterval
    ) async throws -> (PreparedDiarization, Double) {
        let config = makeConfig(
            preprocessing: preprocessingPolicy,
            clustering: clusteringPolicy
        )
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let prepared = try await manager.prepare(
            audioSource: source,
            audioLoadingSeconds: loadDuration
        )
        return (prepared, ProcessInfo.processInfo.systemUptime - startedAt)
    }

    private static func anonymizedSegments(_ segments: [TimedSpeakerSegment]) throws -> [[String: Any]] {
        let ordered = segments.sorted {
            if $0.startTimeSeconds != $1.startTimeSeconds {
                return $0.startTimeSeconds < $1.startTimeSeconds
            }
            if $0.endTimeSeconds != $1.endTimeSeconds {
                return $0.endTimeSeconds < $1.endTimeSeconds
            }
            return $0.speakerId < $1.speakerId
        }
        var labels: [String: String] = [:]
        return try ordered.map { segment in
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            guard start.isFinite, end.isFinite, start >= 0, end > start else {
                throw ProbeError.invalidModel
            }
            if labels[segment.speakerId] == nil {
                labels[segment.speakerId] = "S\(labels.count + 1)"
            }
            guard let speaker = labels[segment.speakerId] else { throw ProbeError.invalidModel }
            return ["start": start, "end": end, "speaker": speaker]
        }
    }
}
