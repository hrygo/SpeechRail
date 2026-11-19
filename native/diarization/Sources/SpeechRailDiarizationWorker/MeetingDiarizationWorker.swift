@preconcurrency import CoreML
import FluidAudio
import Foundation
import SpeechRailDiarizationProtocol

enum MeetingWorkerError: Error { case invalidRequest, invalidModel, invalidPolicy }

/// One model set and matcher per pipe/session. No model hub or compilation.
final class MeetingDiarizationWorker {
    private let acousticPipeline: AcousticPipeline
    private var matcher: SessionSpeakerMatcher
    private var calibrationCandidates: [DiarizationCalibrationCandidate] = []
    private var calibrationMatchers: [SessionSpeakerMatcher] = []
    private var calibrationHistories: [ActivityHistory] = []
    private var calibrationPipelines: [DiarizationAcousticPolicy: AcousticPipeline] = [:]
    private(set) var calibrationPayload = Data()
    private var epoch: String?
    private var stable = 0
    private var processed = 0
    private typealias LocalActivity = (start: Int, end: Int, speakers: Set<String>)

    private struct AcousticViews {
        let evidence: DiarizationResult
        let activity: DiarizationResult

        static var silence: Self {
            let empty = DiarizationResult(segments: [])
            return Self(evidence: empty, activity: empty)
        }
    }

    private struct AcousticPipeline {
        let evidence: OfflineDiarizerManager
        private let activity: OfflineDiarizerManager?

        init(config: OfflineDiarizerConfig, models: OfflineDiarizerModels) {
            var evidenceConfig = config
            evidenceConfig.exposeChunkEmbeddings = true
            evidence = OfflineDiarizerManager(config: evidenceConfig)
            evidence.initialize(models: models)

            // Zero-vote calibration may run additional embeddings in cluster().
            guard !config.zeroVoteReembed.enabled else {
                activity = nil
                return
            }
            // Only this reconstruction sees the shorter duration. Both views
            // cluster the embeddings from the same preparation pass.
            var activityConfig = evidenceConfig
            activityConfig.postProcessing.exclusiveSegments = false
            activityConfig.embedding.minSegmentDurationSeconds = 0.20
            let renderer = OfflineDiarizerManager(config: activityConfig)
            renderer.initialize(models: models)
            activity = renderer
        }

        func cluster(_ prepared: PreparedDiarization) throws -> AcousticViews {
            let matching = try evidence.cluster(prepared)
            guard let activity, let expanded = try? activity.cluster(prepared) else {
                return AcousticViews(evidence: matching, activity: matching)
            }
            // A numeric cluster label is local to a clustering pass. Only
            // project it across views when their chunk assignments agree.
            guard let left = matching.chunkEmbeddings, let right = expanded.chunkEmbeddings,
                  !left.isEmpty, left.count == right.count,
                  zip(left, right).allSatisfy({ a, b in
                      a.chunkIndex == b.chunkIndex && a.speakerIndex == b.speakerIndex && a.speakerId == b.speakerId
                  }) else {
                return AcousticViews(evidence: matching, activity: matching)
            }
            return AcousticViews(evidence: matching, activity: expanded)
        }
    }

    private struct IdentityAnchor {
        let start: Int
        let end: Int
        let slot: Int
    }
    private struct ActivityHistory {
        var anchors: [IdentityAnchor] = []
        var preview = SpeakerActivityPreview()
        var rejected: [SpeakerVoiceSpan] = []
    }
    private struct AnalysisKey: Hashable {
        let acousticPolicy: DiarizationAcousticPolicy
        let matchingEmbeddingSpace: DiarizationMatchingEmbeddingSpace
    }
    var maxSpeakers: Int { matcher.identityCapacity }
    private var history = ActivityHistory()

    init(
        modelDirectory: String,
        policyPath: String,
        calibrationCandidatesPath: String? = nil,
        zeroVoteReembed: Bool = false,
        maxSpeakers: Int? = nil
    ) throws {
        guard !zeroVoteReembed || calibrationCandidatesPath != nil else {
            throw MeetingWorkerError.invalidPolicy
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let policy = try decoder.decode(SpeakerMatchingPolicy.self,
            from: Data(contentsOf: URL(fileURLWithPath: policyPath)))
        self.matcher = try SessionSpeakerMatcher(policy: policy, maxSpeakers: maxSpeakers)
        if let calibrationCandidatesPath {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: calibrationCandidatesPath))
            let candidates = try DiarizationCalibrationCandidate.decodeArray(bytes)
            calibrationCandidates = candidates
            calibrationMatchers = try candidates.map { try SessionSpeakerMatcher(policy: $0.matchingPolicy) }
            calibrationHistories = Array(repeating: ActivityHistory(), count: candidates.count)
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
        self.acousticPipeline = AcousticPipeline(config: config, models: models)
        for candidate in calibrationCandidates where calibrationPipelines[candidate.acousticPolicy] == nil {
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
            calibrationPipelines[candidate.acousticPolicy] = AcousticPipeline(config: config, models: models)
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
        let result: AcousticViews
        var calibrationResults: [DiarizationAcousticPolicy: AcousticViews] = [:]
        if calibrationCandidates.isEmpty {
            do {
                let prepared = try await acousticPipeline.evidence.prepare(audio: audio)
                result = try acousticPipeline.cluster(prepared)
            } catch OfflineDiarizationError.noSpeechDetected {
                result = .silence
            }
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
                }), let pipeline = calibrationPipelines[candidate.acousticPolicy] else {
                    throw MeetingWorkerError.invalidPolicy
                }
                do {
                    preparedByPolicy[preprocessingPolicy] = try await pipeline.evidence.prepare(audio: audio)
                } catch OfflineDiarizationError.noSpeechDetected {
                    noSpeechPolicies.insert(preprocessingPolicy)
                }
            }
            var acousticPolicies: [DiarizationAcousticPolicy] = []
            for candidate in calibrationCandidates where !acousticPolicies.contains(candidate.acousticPolicy) {
                acousticPolicies.append(candidate.acousticPolicy)
            }
            for acousticPolicy in acousticPolicies {
                guard let pipeline = calibrationPipelines[acousticPolicy] else {
                    throw MeetingWorkerError.invalidPolicy
                }
                if noSpeechPolicies.contains(acousticPolicy.preprocessing) {
                    calibrationResults[acousticPolicy] = .silence
                    continue
                }
                guard let prepared = preparedByPolicy[acousticPolicy.preprocessing] else {
                    throw MeetingWorkerError.invalidPolicy
                }
                do {
                    calibrationResults[acousticPolicy] = try pipeline.cluster(prepared)
                } catch OfflineDiarizationError.noSpeechDetected {
                    calibrationResults[acousticPolicy] = .silence
                }
            }
            guard let primaryPolicy = calibrationCandidates.first?.acousticPolicy,
                  let primaryResult = calibrationResults[primaryPolicy]
            else { throw MeetingWorkerError.invalidPolicy }
            result = primaryResult
        }
        typealias Analysis = (clusters: [SpeakerLocalCluster], evidence: [LocalActivity],
                              rendered: [LocalActivity], overlapCentroids: [String: [Double]])
        func timeline(_ input: [TimedSpeakerSegment]) throws -> ([TimedSpeakerSegment], [LocalActivity]) {
            guard input.count <= 16384,
                  input.allSatisfy({
                      $0.startTimeSeconds.isFinite && $0.endTimeSeconds.isFinite
                      && $0.startTimeSeconds >= 0 && $0.endTimeSeconds >= $0.startTimeSeconds
                      && Double($0.endTimeSeconds) <= Double(audio.count) / 16000 + 1
                  }) else { throw MeetingWorkerError.invalidModel }
            let segments = input.filter { $0.endTimeSeconds > $0.startTimeSeconds }
            guard Set(segments.map(\.speakerId)).count <= 32 else { throw MeetingWorkerError.invalidRequest }
            func bounds(_ segment: TimedSpeakerSegment) -> SpeakerVoiceSpan {
                .init(start: max(start, start + Int((Double(segment.startTimeSeconds) * 16000).rounded())),
                      end: min(end, start + Int((Double(segment.endTimeSeconds) * 16000).rounded())))
            }
            var boundaries = Set([start, end])
            for segment in segments { let span = bounds(segment); boundaries.insert(span.start); boundaries.insert(span.end) }
            let points = boundaries.filter { start <= $0 && $0 <= end }.sorted()
            let localActivity = zip(points, points.dropFirst()).map { a, b -> LocalActivity in
                let active = Set(segments.filter { let span = bounds($0); return span.start < b && span.end > a }.map(\.speakerId))
                return (a, b, active)
            }
            return (segments, localActivity)
        }
        func analyze(
            _ views: AcousticViews,
            matchingEmbeddingSpace: DiarizationMatchingEmbeddingSpace
        ) throws -> Analysis {
            let diarization = views.evidence
            let (segments, evidence) = try timeline(diarization.segments)
            let rendered = (try? timeline(views.activity.segments).1) ?? evidence
            let ids = Set(segments.map(\.speakerId)).sorted()
            var unique: [String: [SpeakerVoiceSpan]] = [:]
            for (a,b,active) in evidence {
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
            var overlapCentroids: [String: [Double]] = [:]
            if matchingEmbeddingSpace == .embedding256Cosine {
                let overlappingIDs = Set(rendered.filter { $0.speakers.count == 2 }.flatMap(\.speakers))
                for id in overlappingIDs {
                    overlapCentroids[id] = views.activity.speakerDatabase?[id]?.map(Double.init)
                }
            }
            return (clusters, evidence, rendered, overlapCentroids)
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
        let nextStable = final ? end : max(previous, end - 10 * 16000)
        func responseHeader(_ matcher: SessionSpeakerMatcher) -> [String: Any] {
            ["protocol_version":2,"backend":"meeting_dynamic","ok":true,"epoch":epoch,
             "processed_through":end,"stable_through":nextStable,
             "diagnostics":["identities":matcher.identityCount,"prototypes":matcher.prototypeCount,
                            "candidates":matcher.candidateCount]]
        }

        func activity(
            _ analysis: Analysis,
            matcher: inout SessionSpeakerMatcher,
            history: inout ActivityHistory
        ) throws -> [[String:Any]] {
            let anchored = analysis.clusters.map { cluster -> SpeakerLocalCluster in
                var support: [Int:Int] = [:]
                for span in cluster.uniqueVoice {
                    for old in history.anchors where old.end > span.start && old.start < span.end {
                        let count = min(old.end,span.end,previous) - max(old.start,span.start)
                        if count > 0 { support[old.slot,default:0] += count }
                    }
                }
                let total = support.values.reduce(0,+)
                let anchors = Set(support.filter { $0.value >= 8000 && Double($0.value) >= Double(total)*0.6 }.keys)
                return .init(id:cluster.id,centroid:cluster.centroid,uniqueVoice:cluster.uniqueVoice,anchors:anchors)
            }
            func project(_ timeline: [LocalActivity], matches: [String: SpeakerMatch]) -> [SpeakerActivityFrame] {
                timeline.compactMap { a, b, active in
                    guard b > max(previous, start) else { return nil }
                    return .init(span: .init(start: max(a, previous), end: b),
                                 decision: SpeakerActivityDecision.resolve(active.map { matches[$0] }))
                }
            }
            let establishedSlots = 0..<matcher.identityCount
            let previouslySealedSlots = Set(history.anchors.map(\.slot))
            let previousPreview = history.preview
            var rejected = history.rejected.filter { $0.end > start }
            var evidenceFrames: [SpeakerActivityFrame] = []
            var renderedFrames: [SpeakerActivityFrame] = []
            // The two activity views can decline labels before a matched cluster
            // contributes to the identity reference. Revisited audio stays excluded.
            let matches = try matcher.assign(anchored, through: end, persist: nextStable > previous) { proposed in
                let slots = Set(proposed.values.compactMap(\.slot))
                let evidence = previousPreview.markingConflicts(
                    in: project(analysis.evidence, matches: proposed), matchedSlots: slots,
                    establishedSlots: establishedSlots, stableThrough: nextStable)
                let rendered = previousPreview.markingConflicts(
                    in: project(analysis.rendered, matches: proposed), matchedSlots: slots,
                    establishedSlots: establishedSlots, stableThrough: nextStable)
                evidenceFrames = evidence.frames
                renderedFrames = rendered.frames
                rejected.append(contentsOf: evidence.rejected)
                rejected.append(contentsOf: rendered.rejected)
                guard !rejected.isEmpty else { return [] }
                return Set(anchored.compactMap { cluster -> Int? in
                    guard let slot = proposed[cluster.id]?.slot, establishedSlots.contains(slot),
                          cluster.uniqueVoice.contains(where: { span in
                              rejected.contains { $0.start < span.end && span.start < $0.end }
                          }) else { return nil }
                    return slot
                })
            }
            let matchedSlots = Set(matches.values.compactMap(\.slot).filter { $0 < matcher.identityCount })
            var next = history.anchors.compactMap { old -> IdentityAnchor? in
                let a = max(old.start,end-60*16000), b = min(old.end,previous)
                return b > a ? IdentityAnchor(start:a,end:b,slot:old.slot) : nil
            }
            func wireFrames(_ projected: [SpeakerActivityFrame]) -> [[String: Any]] {
                var frames: [[String: Any]] = []
                if previous < start {
                    frames.append(["start":previous,"end":start,"active_slots":[Int](),"reason":"activity_gap"])
                }
                var lastDecision: SpeakerActivityDecision?
                for item in projected {
                    let decision = item.decision
                    if lastDecision == decision {
                        frames[frames.count - 1]["end"] = item.span.end
                    } else {
                        var frame: [String:Any] = ["start":item.span.start,"end":item.span.end,
                                                  "active_slots":decision.slots.sorted()]
                        if let reason = decision.reason { frame["reason"] = reason }
                        frames.append(frame)
                        lastDecision = decision
                    }
                }
                return frames
            }
            // Only the identity view can anchor a later match. Extra activity
            // in the expanded view cannot reserve or reinforce a slot.
            for item in evidenceFrames where item.span.start < nextStable {
                guard item.decision.reason == nil, item.decision.slots.count == 1,
                      let slot = item.decision.slots.first else { continue }
                next.append(IdentityAnchor(start: item.span.start, end: min(item.span.end, nextStable), slot: slot))
            }
            guard next.count <= 16384, rejected.count <= 16384 else { throw MeetingWorkerError.invalidRequest }
            let output = try DiarizationPacketCodec.activityWithinHeaderBudget(
                wireFrames(renderedFrames), evidence: { wireFrames(evidenceFrames) },
                header: responseHeader(matcher), replacingFrom: previous, through: end)
            let previewFrames: [SpeakerActivityFrame]
            switch output.source {
            case .rendered: previewFrames = renderedFrames
            case .evidence: previewFrames = evidenceFrames
            case .gap: previewFrames = []
            }
            let sealedSlots = Set(next.lazy.filter { $0.start < nextStable }.map(\.slot))
            history = ActivityHistory(anchors: next, preview: .init(
                frames: previewFrames, matchedSlots: matchedSlots.intersection(sealedSlots),
                stableThrough: nextStable), rejected: rejected)
            guard output.source == .rendered, previouslySealedSlots.count >= 2,
                  nextStable > previous else { return output.frames }

            // This pass only augments the output of already matched activity. It has
            // no effect on enrollment, refusal reasons, prototypes, or the next preview.
            let claimedSlots = Set(matches.values.compactMap(\.slot))
            let windowAnchors = Dictionary(uniqueKeysWithValues: anchored.map { ($0.id, $0.anchors) })
            var recovered: [Int: (slots: Set<Int>, spans: [SpeakerVoiceSpan])] = [:]
            for (a, b, active) in analysis.rendered where active.count == 2 {
                let span = SpeakerVoiceSpan(start: max(a, previous), end: min(b, nextStable))
                let existing = active.compactMap { matches[$0]?.slot }
                guard span.end - span.start >= 3200,
                      existing.count == 1, let primary = existing.first, previouslySealedSlots.contains(primary),
                      let id = active.first(where: { matches[$0]?.slot == nil }),
                      matches[id]?.reason != "speaker_capacity",
                      let centroid = analysis.overlapCentroids[id],
                      let secondary = matcher.confirmedOverlapSlot(
                          centroid: centroid, sealedSlots: previouslySealedSlots),
                      !claimedSlots.contains(secondary) else { continue }
                // Check agreement on the same audio and reject evidence of a third
                // speaker. One cluster can include traces of both overlapping voices.
                let pair: Set<Int> = [primary, secondary]
                let spans = previousPreview.supportingOverlap(
                    pair, during: span, windowAnchors: windowAnchors[id] ?? []
                ).filter { $0.end - $0.start >= 3200 }
                if !spans.isEmpty {
                    recovered[span.start] = (pair, spans)
                }
            }
            guard !recovered.isEmpty else { return output.frames }
            var refined: [SpeakerActivityFrame] = []
            for frame in renderedFrames {
                guard let recovery = recovered[frame.span.start],
                      case let decision = frame.decision.addingOverlap(recovery.slots),
                      decision != frame.decision else {
                    refined.append(frame)
                    continue
                }
                var cursor = frame.span.start
                for span in recovery.spans {
                    if cursor < span.start {
                        refined.append(.init(span: .init(start: cursor, end: span.start), decision: frame.decision))
                    }
                    refined.append(.init(span: span, decision: decision))
                    cursor = span.end
                }
                if cursor < frame.span.end {
                    refined.append(.init(span: .init(start: cursor, end: frame.span.end), decision: frame.decision))
                }
            }
            return try DiarizationPacketCodec.activityWithinHeaderBudget(
                wireFrames(refined), evidence: { output.frames }, header: responseHeader(matcher),
                replacingFrom: previous, through: end).frames
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
        processed = end; stable = nextStable
        var response = responseHeader(matcher)
        response["frames"] = frames
        return response
    }
}
