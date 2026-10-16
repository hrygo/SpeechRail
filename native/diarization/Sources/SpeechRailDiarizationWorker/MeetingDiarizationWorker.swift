@preconcurrency import CoreML
import FluidAudio
import Foundation
import SpeechRailDiarizationProtocol

enum MeetingWorkerError: Error { case invalidRequest, invalidModel, invalidPolicy }

/// One manager and matcher for one pipe/session. No model hub or compilation.
final class MeetingDiarizationWorker {
    private let manager: OfflineDiarizerManager
    private var matcher: SessionSpeakerMatcher
    private var calibrationMatchers: [SessionSpeakerMatcher] = []
    private var calibrationHistories: [[Activity]] = []
    private(set) var calibrationPayload = Data()
    private var epoch: String?
    private var stable = 0
    private var processed = 0
    private struct Activity {
        let start: Int
        let end: Int
        let slots: Set<Int>
    }
    private var history: [Activity] = []

    init(modelDirectory: String, policyPath: String, calibrationPoliciesPath: String? = nil) throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let policy = try decoder.decode(SpeakerMatchingPolicy.self,
            from: Data(contentsOf: URL(fileURLWithPath: policyPath)))
        self.matcher = try SessionSpeakerMatcher(policy: policy)
        if let calibrationPoliciesPath {
            let bytes = try Data(contentsOf:URL(fileURLWithPath:calibrationPoliciesPath))
            guard bytes.count <= 65536 else { throw MeetingWorkerError.invalidPolicy }
            let policies = try decoder.decode([SpeakerMatchingPolicy].self,from:bytes)
            guard (1...24).contains(policies.count) else { throw MeetingWorkerError.invalidPolicy }
            calibrationMatchers = try policies.map { try SessionSpeakerMatcher(policy:$0) }
            calibrationHistories = Array(repeating:[],count:policies.count)
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
        let config = OfflineDiarizerConfig()
        self.manager = OfflineDiarizerManager(config: config)
        self.manager.initialize(models: models)
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
        do { result = try await manager.process(audio: audio) }
        catch OfflineDiarizationError.noSpeechDetected { result = DiarizationResult(segments: []) }
        guard result.segments.count <= 16384,
              result.segments.allSatisfy({
                  $0.startTimeSeconds.isFinite && $0.endTimeSeconds.isFinite
                  && $0.startTimeSeconds >= 0 && $0.endTimeSeconds >= $0.startTimeSeconds
                  && Double($0.endTimeSeconds) <= Double(audio.count) / 16000 + 1
              }) else { throw MeetingWorkerError.invalidModel }
        let segments = result.segments.filter { $0.endTimeSeconds > $0.startTimeSeconds }
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
        var clusters: [SpeakerLocalCluster] = []
        for id in ids {
            guard let vector = result.speakerDatabase?[id] ?? segments.first(where: { $0.speakerId == id })?.embedding else {
                throw MeetingWorkerError.invalidModel
            }
            clusters.append(SpeakerLocalCluster(id:id,centroid:vector.map(Double.init),
                uniqueVoice:unique[id] ?? [],anchors:[]))
        }
        let previous = stable
        func activity(matcher: inout SessionSpeakerMatcher, history: inout [Activity]) throws -> [[String:Any]] {
            let anchored = clusters.map { cluster -> SpeakerLocalCluster in
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
            for (a,b,active) in localActivity where b > max(previous,start) {
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
        let frames = try activity(matcher:&matcher,history:&history)
        var variants: [[String:Any]] = []
        for index in calibrationMatchers.indices {
            let candidate = try activity(matcher:&calibrationMatchers[index],history:&calibrationHistories[index])
            variants.append(["candidate_index":index,"frames":candidate,
                "identity_count":calibrationMatchers[index].identityCount,
                "prototype_count":calibrationMatchers[index].prototypeCount,
                "candidate_count":calibrationMatchers[index].candidateCount])
        }
        calibrationPayload = variants.isEmpty ? Data() : try JSONSerialization.data(withJSONObject:variants,options:[.sortedKeys])
        processed = end; stable = final ? end : max(stable,end - 10 * 16000)
        return ["protocol_version":2,"backend":"meeting_dynamic","ok":true,"epoch":epoch,
                "processed_through":processed,"stable_through":stable,"frames":frames,
                "diagnostics":["identities":matcher.identityCount,"prototypes":matcher.prototypeCount,
                               "candidates":matcher.candidateCount]]
    }
}
