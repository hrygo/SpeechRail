@preconcurrency import CoreML
import FluidAudio
import Foundation
import SpeechRailDiarizationProtocol

enum MeetingWorkerError: Error { case invalidRequest, invalidModel, invalidPolicy }

/// One manager and matcher for one pipe/session. No model hub or compilation.
final class MeetingDiarizationWorker {
    private let manager: OfflineDiarizerManager
    private var matcher: SessionSpeakerMatcher
    private var calibrationCandidates: [DiarizationCalibrationCandidate] = []
    private var calibrationMatchers: [SessionSpeakerMatcher] = []
    private var calibrationHistories: [[Activity]] = []
    private var calibrationManagers: [DiarizationAcousticPolicy: OfflineDiarizerManager] = [:]
    private(set) var calibrationPayload = Data()
    private var epoch: String?
    private var stable = 0
    private var processed = 0
    private struct Activity {
        let start: Int
        let end: Int
        let slots: Set<Int>
    }
    private struct AnalysisKey: Hashable {
        let acousticPolicy: DiarizationAcousticPolicy
        let matchingEmbeddingSpace: DiarizationMatchingEmbeddingSpace
    }
    private var history: [Activity] = []

    init(
        modelDirectory: String,
        policyPath: String,
        calibrationCandidatesPath: String? = nil,
        zeroVoteReembed: Bool = false
    ) throws {
        guard !zeroVoteReembed || calibrationCandidatesPath != nil else {
            throw MeetingWorkerError.invalidPolicy
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let policy = try decoder.decode(SpeakerMatchingPolicy.self,
            from: Data(contentsOf: URL(fileURLWithPath: policyPath)))
        self.matcher = try SessionSpeakerMatcher(policy: policy)
        if let calibrationCandidatesPath {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: calibrationCandidatesPath))
            let candidates = try DiarizationCalibrationCandidate.decodeArray(bytes)
            calibrationCandidates = candidates
            calibrationMatchers = try candidates.map { try SessionSpeakerMatcher(policy: $0.matchingPolicy) }
            calibrationHistories = Array(repeating: [], count: candidates.count)
        }
        let root = URL(fileURLWithPath: modelDirectory, isDirectory: true)
        func load(_ name: String, cpuOnly: Bool = false) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = cpuOnly ? .cpuOnly : .all
            return try MLModel(contentsOf: root.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
        }
        let parameters = try JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("plda-parameters.json"))) as? [String: Any]
        guard let tensors = parameters?["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any], let encoded = psi["data_base64"] as? String,
              let bytes = Data(base64Encoded: encoded), bytes.count > 0, bytes.count.isMultiple(of: 4)
        else { throw MeetingWorkerError.invalidModel }
        var values = [Float](repeating: 0, count: bytes.count / 4)
        _ = values.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw MeetingWorkerError.invalidModel }
        let models = OfflineDiarizerModels(segmentationModel: try load("Segmentation"),
            fbankModel: try load("FBank", cpuOnly: true), embeddingModel: try load("Embedding"),
            pldaRhoModel: try load("PldaRho"), pldaPsi: values.map(Double.init), compilationDuration: 0)
        // Auto count keeps the SDK's co-chunk constrained assignment.
        let config = OfflineDiarizerConfig(
            zeroVoteReembed: .init(enabled: zeroVoteReembed)
        )
        let manager = OfflineDiarizerManager(config: config)
        self.manager = manager
        self.manager.initialize(models: models)
        for candidate in calibrationCandidates where calibrationManagers[candidate.acousticPolicy] == nil {
            var config = OfflineDiarizerConfig()
            config.segmentation.stepRatio = candidate.preprocessingPolicy.segmentationStepRatio
            config.embedding.minSegmentDurationSeconds = candidate.preprocessingPolicy.embeddingMinSegmentDurationSeconds
            let clustering = OfflineDiarizerConfig.Clustering(
                threshold: candidate.clusteringPolicy.threshold,
                warmStartFa: candidate.clusteringPolicy.warmStartFa,
                warmStartFb: candidate.clusteringPolicy.warmStartFb
            )
            config.clustering = clustering
            config.zeroVoteReembed = .init(enabled: zeroVoteReembed)
            config.exposeChunkEmbeddings = calibrationCandidates.contains {
                $0.matchingEmbeddingSpace == .pldaRho128Cosine
            }
            let candidateManager = OfflineDiarizerManager(config: config)
            candidateManager.initialize(models: models)
            calibrationManagers[candidate.acousticPolicy] = candidateManager
        }
    }

    func infer(_ data: Data, start: Int, previousStable: Int, final: Bool, epoch: String) async throws -> [String: Any] {
        guard !epoch.isEmpty, epoch.utf8.count <= 128, self.epoch == nil || self.epoch == epoch,
              start >= 0, previousStable == stable, data.count.isMultiple(of: 2),
              !data.isEmpty, data.count <= 30 * 16000 * 2,
              start <= 9_007_199_254_740_991 - data.count / 2
        else { throw MeetingWorkerError.invalidRequest }
        self.epoch = epoch
        let audio: [Float] = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        let end = start + audio.count
        guard end > processed, end >= stable else { throw MeetingWorkerError.invalidRequest }
        let result: DiarizationResult
        var calibrationResults: [DiarizationAcousticPolicy: DiarizationResult] = [:]
        if calibrationCandidates.isEmpty {
            do { result = try await manager.process(audio: audio) }
            catch OfflineDiarizationError.noSpeechDetected { result = DiarizationResult(segments: []) }
        } else {
            var preprocessingPolicies: [DiarizationPreprocessingPolicy] = []
            for candidate in calibrationCandidates where !preprocessingPolicies.contains(candidate.preprocessingPolicy) {
                preprocessingPolicies.append(candidate.preprocessingPolicy)
            }
            var preparedByPolicy: [DiarizationPreprocessingPolicy: PreparedDiarization] = [:]
            var noSpeechPolicies: Set<DiarizationPreprocessingPolicy> = []
            for preprocessingPolicy in preprocessingPolicies {
                guard let candidate = calibrationCandidates.first(where: {
                    $0.preprocessingPolicy == preprocessingPolicy
                }), let preparationManager = calibrationManagers[candidate.acousticPolicy] else {
                    throw MeetingWorkerError.invalidPolicy
                }
                do {
                    preparedByPolicy[preprocessingPolicy] = try await preparationManager.prepare(audio: audio)
                } catch OfflineDiarizationError.noSpeechDetected {
                    noSpeechPolicies.insert(preprocessingPolicy)
                }
            }
            var acousticPolicies: [DiarizationAcousticPolicy] = []
            for candidate in calibrationCandidates where !acousticPolicies.contains(candidate.acousticPolicy) {
                acousticPolicies.append(candidate.acousticPolicy)
            }
            for acousticPolicy in acousticPolicies {
                guard let candidateManager = calibrationManagers[acousticPolicy] else {
                    throw MeetingWorkerError.invalidPolicy
                }
                if noSpeechPolicies.contains(acousticPolicy.preprocessing) {
                    calibrationResults[acousticPolicy] = DiarizationResult(segments: [])
                    continue
                }
                guard let prepared = preparedByPolicy[acousticPolicy.preprocessing] else {
                    throw MeetingWorkerError.invalidPolicy
                }
                do {
                    calibrationResults[acousticPolicy] = try candidateManager.cluster(prepared)
                } catch OfflineDiarizationError.noSpeechDetected {
                    calibrationResults[acousticPolicy] = DiarizationResult(segments: [])
                }
            }
            guard let primaryPolicy = calibrationCandidates.first?.acousticPolicy,
                  let primaryResult = calibrationResults[primaryPolicy]
            else { throw MeetingWorkerError.invalidPolicy }
            result = primaryResult
        }
        typealias Analysis = (clusters: [SpeakerLocalCluster], localActivity: [(Int, Int, Set<String>)])
        func analyze(
            _ diarization: DiarizationResult,
            matchingEmbeddingSpace: DiarizationMatchingEmbeddingSpace
        ) throws -> Analysis {
            guard diarization.segments.count <= 16384,
                  diarization.segments.allSatisfy({
                      $0.startTimeSeconds.isFinite && $0.endTimeSeconds.isFinite
                      && $0.startTimeSeconds >= 0 && $0.endTimeSeconds >= $0.startTimeSeconds
                      && Double($0.endTimeSeconds) <= Double(audio.count) / 16000 + 1
                  }) else { throw MeetingWorkerError.invalidModel }
            let segments = diarization.segments.filter { $0.endTimeSeconds > $0.startTimeSeconds }
            let ids = Array(Set(segments.map(\.speakerId))).sorted()
            guard ids.count <= 32 else { throw MeetingWorkerError.invalidRequest }
            func bounds(_ segment: TimedSpeakerSegment) -> SpeakerVoiceSpan {
                .init(start: max(start, start + Int((Double(segment.startTimeSeconds) * 16000).rounded())),
                      end: min(end, start + Int((Double(segment.endTimeSeconds) * 16000).rounded())))
            }
            var boundaries = Set([start, end])
            for segment in segments { let span = bounds(segment); boundaries.insert(span.start); boundaries.insert(span.end) }
            let points = boundaries.filter { start <= $0 && $0 <= end }.sorted()
            var localActivity: [(Int, Int, Set<String>)] = []
            var unique: [String: [SpeakerVoiceSpan]] = [:]
            for index in 0..<max(0, points.count - 1) {
                let a = points[index], b = points[index + 1]
                let active = Set(segments.filter { let span = bounds($0); return span.start < b && span.end > a }.map(\.speakerId))
                localActivity.append((a,b,active))
                if active.count == 1, let id = active.first { unique[id, default: []].append(.init(start:a,end:b)) }
            }
            let rhoBySpeaker = Dictionary(
                grouping: diarization.chunkEmbeddings ?? [],
                by: \.speakerId
            )
            var clusters: [SpeakerLocalCluster] = []
            for id in ids {
                let vector: [Double]
                switch matchingEmbeddingSpace {
                case .embedding256Cosine:
                    guard let embedding = diarization.speakerDatabase?[id]
                        ?? segments.first(where: { $0.speakerId == id })?.embedding
                    else { throw MeetingWorkerError.invalidModel }
                    vector = embedding.map(Double.init)
                case .pldaRho128Cosine:
                    guard let embeddings = rhoBySpeaker[id], !embeddings.isEmpty else {
                        throw MeetingWorkerError.invalidModel
                    }
                    var sum = [Double](repeating: 0, count: 128)
                    var totalWeight = 0.0
                    for embedding in embeddings {
                        guard embedding.rho128.count == 128,
                              embedding.rho128.allSatisfy(\.isFinite),
                              embedding.endTimeSeconds > embedding.startTimeSeconds
                        else { throw MeetingWorkerError.invalidModel }
                        let weight = Double(embedding.endTimeSeconds - embedding.startTimeSeconds)
                        for index in sum.indices {
                            sum[index] += embedding.rho128[index] * weight
                        }
                        totalWeight += weight
                    }
                    guard totalWeight.isFinite, totalWeight > 0 else {
                        throw MeetingWorkerError.invalidModel
                    }
                    vector = sum.map { $0 / totalWeight }
                        + [Double](repeating: 0, count: 128)
                }
                clusters.append(SpeakerLocalCluster(id:id,centroid:vector,
                    uniqueVoice:unique[id] ?? [],anchors:[]))
            }
            return (clusters, localActivity)
        }
        let primaryAnalysis = try analyze(result, matchingEmbeddingSpace: .embedding256Cosine)
        var analysesByPolicy: [AnalysisKey: Analysis] = [:]
        for candidate in calibrationCandidates {
            let key = AnalysisKey(
                acousticPolicy: candidate.acousticPolicy,
                matchingEmbeddingSpace: candidate.matchingEmbeddingSpace
            )
            guard analysesByPolicy[key] == nil else { continue }
            guard let candidateResult = calibrationResults[candidate.acousticPolicy] else {
                throw MeetingWorkerError.invalidPolicy
            }
            analysesByPolicy[key] = try analyze(
                candidateResult,
                matchingEmbeddingSpace: candidate.matchingEmbeddingSpace
            )
        }
        let previous = stable
        func activity(
            _ analysis: Analysis,
            matcher: inout SessionSpeakerMatcher,
            history: inout [Activity]
        ) throws -> [[String:Any]] {
            let anchored = analysis.clusters.map { cluster -> SpeakerLocalCluster in
                var support: [Int:Int] = [:]
                for span in cluster.uniqueVoice {
                    for old in history where old.end > span.start && old.start < span.end && old.slots.count == 1 {
                        let count = min(old.end,span.end,previous) - max(old.start,span.start)
                        if count > 0, let slot = old.slots.first { support[slot,default:0] += count }
                    }
                }
                let total = support.values.reduce(0,+)
                let anchors = Set(support.filter { $0.value >= 8000 && Double($0.value) >= Double(total)*0.6 }.keys)
                return .init(id:cluster.id,centroid:cluster.centroid,uniqueVoice:cluster.uniqueVoice,anchors:anchors)
            }
            let matches = try matcher.assign(anchored,through:end)
            var frames: [[String:Any]] = []
            var next = history.compactMap { old -> Activity? in
                let a = max(old.start,end-60*16000), b = min(old.end,previous)
                return b > a ? Activity(start:a,end:b,slots:old.slots) : nil
            }
            if previous < start {
                frames.append(["start":previous,"end":start,"active_slots":[Int](),"reason":"activity_gap"])
            }
            for (a,b,active) in analysis.localActivity where b > max(previous,start) {
                let slots = Set(active.compactMap { matches[$0]?.slot })
                let begin = max(a,previous)
                var frame: [String:Any] = ["start":begin,"end":b,"active_slots":slots.sorted()]
                if slots.isEmpty && !active.isEmpty {
                    frame["reason"] = active.contains(where:{ matches[$0]?.reason == "speaker_capacity" })
                        ? "speaker_capacity" : "identity_uncertain"
                }
                frames.append(frame); next.append(Activity(start:begin,end:b,slots:slots))
            }
            guard next.count <= 16384 else { throw MeetingWorkerError.invalidRequest }
            history = next
            return frames
        }
        let frames = try activity(primaryAnalysis, matcher:&matcher,history:&history)
        var variants: [[String:Any]] = []
        for index in calibrationMatchers.indices {
            let candidate = calibrationCandidates[index]
            let analysisKey = AnalysisKey(
                acousticPolicy: candidate.acousticPolicy,
                matchingEmbeddingSpace: candidate.matchingEmbeddingSpace
            )
            guard let analysis = analysesByPolicy[analysisKey] else {
                throw MeetingWorkerError.invalidPolicy
            }
            let candidateFrames = try activity(
                analysis,
                matcher: &calibrationMatchers[index],
                history: &calibrationHistories[index]
            )
            variants.append(["candidate_index":index,"frames":candidateFrames,
                "identity_count":calibrationMatchers[index].identityCount,
                "prototype_count":calibrationMatchers[index].prototypeCount,
                "candidate_count":calibrationMatchers[index].candidateCount])
        }
        let candidatePayload = variants.isEmpty
            ? Data()
            : try JSONSerialization.data(withJSONObject:variants,options:[.sortedKeys])
        guard candidatePayload.count <= DiarizationPacketCodec.maxPayloadBytes else {
            throw MeetingWorkerError.invalidRequest
        }
        calibrationPayload = candidatePayload
        processed = end; stable = final ? end : max(stable,end - 10 * 16000)
        return ["protocol_version":2,"backend":"meeting_dynamic","ok":true,"epoch":epoch,
                "processed_through":processed,"stable_through":stable,"frames":frames,
                "diagnostics":["identities":matcher.identityCount,"prototypes":matcher.prototypeCount,
                               "candidates":matcher.candidateCount]]
    }
}
