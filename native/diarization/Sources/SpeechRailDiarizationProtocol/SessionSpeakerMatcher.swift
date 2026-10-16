import Foundation

public struct SpeakerMatchingPolicy: Codable, Sendable {
    public var version: String
    public var prototypePolicy: String
    public var matchDistanceMax: Double
    public var matchMarginMin: Double
    public var updateDistanceMax: Double
    public var minimumNewVoiceMs: Int
    public var minimumUpdateVoiceMs: Int
    public var candidateRetentionMs: Int
    public var modelSnapshot: String
    public var calibrationDigest: String
    public var certifiedMaxSpeakers: Int?
    public var validationDigest: String?

    public init(version: String, prototypePolicy: String, matchDistanceMax: Double,
        matchMarginMin: Double, updateDistanceMax: Double, minimumNewVoiceMs: Int,
        minimumUpdateVoiceMs: Int, candidateRetentionMs: Int, modelSnapshot: String,
        calibrationDigest: String, certifiedMaxSpeakers: Int? = nil, validationDigest: String? = nil) {
        self.version = version; self.prototypePolicy = prototypePolicy
        self.matchDistanceMax = matchDistanceMax; self.matchMarginMin = matchMarginMin
        self.updateDistanceMax = updateDistanceMax; self.minimumNewVoiceMs = minimumNewVoiceMs
        self.minimumUpdateVoiceMs = minimumUpdateVoiceMs; self.candidateRetentionMs = candidateRetentionMs
        self.modelSnapshot = modelSnapshot; self.calibrationDigest = calibrationDigest
        self.certifiedMaxSpeakers = certifiedMaxSpeakers; self.validationDigest = validationDigest
    }
    public func validate() throws {
        guard !version.isEmpty, version.utf8.count <= 128, prototypePolicy == "anchor_farthest_v1",
              matchDistanceMax.isFinite, (0..<2).contains(matchDistanceMax), matchDistanceMax > 0,
              updateDistanceMax.isFinite, (0..<matchDistanceMax).contains(updateDistanceMax),
              matchMarginMin.isFinite, (0...2).contains(matchMarginMin),
              (1500...60000).contains(minimumNewVoiceMs), (2000...60000).contains(minimumUpdateVoiceMs),
              candidateRetentionMs == 60000,
              certifiedMaxSpeakers.map({ (5...32).contains($0) }) ?? true,
              modelSnapshot == "7eab74f3463c736418d0eb10296261ae581146c9",
              calibrationDigest.count == 64,
              calibrationDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw MatcherError.invalidPolicy }
    }
}

public enum MatcherError: Error { case invalidPolicy, invalidEvidence }
public struct SpeakerVoiceSpan: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}
public struct SpeakerLocalCluster: Sendable {
    public let id: String
    public var centroid: [Double]
    /// Exclusive speech only, on the absolute session sample axis.
    public let uniqueVoice: [SpeakerVoiceSpan]
    public let anchors: Set<Int>
    public init(id: String, centroid: [Double], uniqueVoice: [SpeakerVoiceSpan], anchors: Set<Int>) {
        self.id = id; self.centroid = centroid; self.uniqueVoice = uniqueVoice; self.anchors = anchors
    }
}
public struct SpeakerMatch: Sendable {
    public let slot: Int?
    public let reason: String?
}

/// RAM only; every retained vector and interval set has a fixed upper bound.
public struct SessionSpeakerMatcher: Sendable {
    private struct Prototype: Sendable {
        let vector: [Double]
        let firstSample: Int
        let ordinal: Int
    }
    private struct Identity: Sendable {
        var representatives: [Prototype]
        var support: [SpeakerVoiceSpan]
        var pending: [SpeakerVoiceSpan] = []
    }
    private struct Candidate: Sendable {
        let vector: [Double]
        var support: [SpeakerVoiceSpan]
        let ordinal: Int
    }
    public let policy: SpeakerMatchingPolicy
    private var identities: [Identity] = []
    private var candidates: [Candidate] = []
    private var sequence = 0
    private var retiredBefore = 0
    private var latestThrough = 0
    public var identityCount: Int { identities.count }
    public var prototypeCount: Int { identities.reduce(0) { $0 + $1.representatives.count } }
    public var candidateCount: Int { candidates.count }

    public init(policy: SpeakerMatchingPolicy) throws { try policy.validate(); self.policy = policy }

    public mutating func assign(_ input: [SpeakerLocalCluster], through: Int) throws -> [String: SpeakerMatch] {
        // Invalid/over-capacity evidence cannot partially change identity state.
        var next = self
        let result = try next.assignInPlace(input, through: through)
        guard next.identities.allSatisfy({ $0.support.count <= 4096 && $0.pending.count <= 4096 }),
              next.candidates.allSatisfy({ $0.support.count <= 4096 }) else { throw MatcherError.invalidEvidence }
        self = next
        return result
    }

    private mutating func assignInPlace(_ input: [SpeakerLocalCluster], through: Int) throws -> [String: SpeakerMatch] {
        guard through >= latestThrough, through <= 9_007_199_254_740_991,
              sequence <= 9_007_199_254_740_927,
              input.count <= 32, Set(input.map(\.id)).count == input.count else {
            throw MatcherError.invalidEvidence
        }
        let clusters = try input.sorted { $0.id < $1.id }.map { cluster -> SpeakerLocalCluster in
            guard !cluster.id.isEmpty, cluster.id.count <= 128,
                  cluster.uniqueVoice.count <= 4096,
                  cluster.uniqueVoice.allSatisfy({ 0 <= $0.start && $0.start < $0.end && $0.end <= through }),
                  cluster.anchors.allSatisfy({ identities.indices.contains($0) }) else {
                throw MatcherError.invalidEvidence
            }
            return SpeakerLocalCluster(id: cluster.id, centroid: try normalized(cluster.centroid),
                uniqueVoice: union(cluster.uniqueVoice), anchors: cluster.anchors)
        }
        // Validate the whole input before mutating any state.
        latestThrough = through
        retiredBefore = max(retiredBefore, through - policy.candidateRetentionMs * 16)
        candidates = candidates.compactMap { old in
            let support = clipped(old.support, after: retiredBefore)
            return support.isEmpty ? nil : Candidate(vector: old.vector, support: support, ordinal: old.ordinal)
        }
        for index in identities.indices {
            identities[index].support = clipped(identities[index].support, after: retiredBefore)
            identities[index].pending = clipped(identities[index].pending, after: retiredBefore)
        }
        let distances = clusters.map { cluster in identities.map { identity in
            identity.representatives.map { distance(cluster.centroid, $0.vector) }.min() ?? 2
        } }
        var ambiguous = [Bool](repeating: false, count: clusters.count)
        var costs = [[Double]]()
        for (row, cluster) in clusters.enumerated() {
            let ranked = distances[row].enumerated().sorted { a, b in
                a.element == b.element ? a.offset < b.offset : a.element < b.element
            }
            let best = ranked.first
            let margin = ranked.count > 1 ? ranked[1].element - ranked[0].element : 2
            ambiguous[row] = (best != nil && best!.element <= policy.matchDistanceMax && margin < policy.matchMarginMin)
                || cluster.anchors.count > 1
                || (!cluster.anchors.isEmpty && cluster.anchors.first != best?.offset)
            var rowCosts = distances[row].enumerated().map { slot, cost in
                !ambiguous[row] && cost <= policy.matchDistanceMax
                    && (cluster.anchors.isEmpty || cluster.anchors.contains(slot)) ? cost : 1000
            }
            rowCosts += clusters.indices.map { $0 == row ? policy.matchDistanceMax + 0.001 : 1000 }
            costs.append(rowCosts)
        }
        let assignment = minimumAssignment(costs)
        let identityCapacity = policy.certifiedMaxSpeakers ?? 32
        var result: [String: SpeakerMatch] = [:]
        var usedCandidates: Set<Int> = []
        for (row, cluster) in clusters.enumerated() {
            let selected = assignment[row]
            if identities.indices.contains(selected), costs[row][selected] < 1000 {
                result[cluster.id] = SpeakerMatch(slot: selected, reason: nil)
                update(selected, cluster: cluster)
                continue
            }
            guard !ambiguous[row], cluster.anchors.isEmpty,
                  distances[row].min().map({ $0 > policy.matchDistanceMax }) ?? true else {
                result[cluster.id] = SpeakerMatch(slot: nil, reason: "identity_uncertain"); continue
            }
            guard identities.count < identityCapacity else {
                result[cluster.id] = SpeakerMatch(slot: nil, reason: "speaker_capacity")
                continue
            }
            let matches = candidates.indices.filter { !usedCandidates.contains($0)
                && distance(cluster.centroid, candidates[$0].vector) <= policy.matchDistanceMax }
                .sorted { a, b in
                    let da = distance(cluster.centroid, candidates[a].vector)
                    let db = distance(cluster.centroid, candidates[b].vector)
                    return da == db ? candidates[a].ordinal < candidates[b].ordinal : da < db
                }
            if matches.count > 1,
               distance(cluster.centroid, candidates[matches[1]].vector)
                - distance(cluster.centroid, candidates[matches[0]].vector) < policy.matchMarginMin {
                result[cluster.id] = SpeakerMatch(slot: nil, reason: "identity_uncertain"); continue
            }
            let candidateIndex: Int
            if let found = matches.first { candidateIndex = found }
            else {
                guard candidates.count < 32 else {
                    result[cluster.id] = SpeakerMatch(slot: nil, reason: "speaker_capacity"); continue
                }
                sequence += 1
                candidates.append(Candidate(vector: cluster.centroid, support: [], ordinal: sequence))
                candidateIndex = candidates.count - 1
            }
            usedCandidates.insert(candidateIndex)
            candidates[candidateIndex].support = union(candidates[candidateIndex].support
                + clipped(cluster.uniqueVoice, after: retiredBefore))
            let support = candidates[candidateIndex].support
            if duration(support) >= policy.minimumNewVoiceMs * 16,
               identities.count < identityCapacity {
                sequence += 1
                let slot = identities.count
                identities.append(Identity(representatives: [Prototype(vector: cluster.centroid,
                    firstSample: support.first?.start ?? through, ordinal: sequence)], support: support))
                // Mark consumed without shifting candidate indexes during this assignment.
                candidates[candidateIndex].support = []
                result[cluster.id] = SpeakerMatch(slot: slot, reason: nil)
            } else {
                result[cluster.id] = SpeakerMatch(slot: nil,
                    reason: identities.count >= identityCapacity ? "speaker_capacity" : "identity_uncertain")
            }
        }
        candidates.removeAll { $0.support.isEmpty }
        return result
    }

    private mutating func update(_ slot: Int, cluster: SpeakerLocalCluster) {
        let old = identities[slot]
        let nearest = old.representatives.map { distance(cluster.centroid, $0.vector) }.min() ?? 2
        guard nearest <= policy.updateDistanceMax,
              distance(cluster.centroid, old.representatives[0].vector) <= policy.matchDistanceMax else { return }
        let combined = union(old.support + clipped(cluster.uniqueVoice, after: retiredBefore))
        let newSpans = subtract(combined, removing: old.support)
        identities[slot].support = combined
        identities[slot].pending = union(old.pending + newSpans)
        guard duration(identities[slot].pending) >= policy.minimumUpdateVoiceMs * 16 else { return }
        sequence += 1
        let prototype = Prototype(vector: cluster.centroid,
            firstSample: identities[slot].pending.first?.start ?? 0, ordinal: sequence)
        identities[slot].pending = []
        let anchor = old.representatives[0]
        var pool = Array(old.representatives.dropFirst()) + [prototype]
        var selected = [anchor]
        while selected.count < 3 && !pool.isEmpty {
            pool.sort { a, b in
                let da = selected.map { distance(a.vector, $0.vector) }.min() ?? 0
                let db = selected.map { distance(b.vector, $0.vector) }.min() ?? 0
                return da == db ? (a.firstSample == b.firstSample ? a.ordinal < b.ordinal : a.firstSample < b.firstSample) : da > db
            }
            let candidate = pool.removeFirst()
            if !selected.contains(where: { distance($0.vector, candidate.vector) < 1e-12 }) {
                selected.append(candidate)
            }
        }
        identities[slot].representatives = selected
    }

    private func normalized(_ vector: [Double]) throws -> [Double] {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { throw MatcherError.invalidEvidence }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-12 else { throw MatcherError.invalidEvidence }
        return vector.map { $0 / norm }
    }
    private func distance(_ a: [Double], _ b: [Double]) -> Double {
        max(0, min(2, 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }))
    }
    private func union(_ spans: [SpeakerVoiceSpan]) -> [SpeakerVoiceSpan] {
        var merged: [SpeakerVoiceSpan] = []
        for span in spans.sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }) {
            if let last = merged.last, last.end >= span.start { merged[merged.count - 1].end = max(last.end, span.end) }
            else { merged.append(span) }
        }
        // 60 s at 16 kHz has a finite number of distinct nonempty intervals;
        // the input protocol additionally bounds the segmentation cadence.
        return merged
    }
    private func clipped(_ spans: [SpeakerVoiceSpan], after sample: Int) -> [SpeakerVoiceSpan] {
        spans.filter { $0.end > sample }.map { .init(start: max(sample, $0.start), end: $0.end) }
    }
    private func duration(_ spans: [SpeakerVoiceSpan]) -> Int { spans.reduce(0) { $0 + $1.end - $1.start } }
    private func subtract(_ spans: [SpeakerVoiceSpan], removing old: [SpeakerVoiceSpan]) -> [SpeakerVoiceSpan] {
        var result: [SpeakerVoiceSpan] = []
        for span in spans {
            var cursor = span.start
            for excluded in old where excluded.end > cursor && excluded.start < span.end {
                if cursor < excluded.start { result.append(.init(start: cursor, end: min(span.end, excluded.start))) }
                cursor = max(cursor, excluded.end)
            }
            if cursor < span.end { result.append(.init(start: cursor, end: span.end)) }
        }
        return result
    }

    /// Rectangular Hungarian assignment, including one unmatched column per row.
    private func minimumAssignment(_ cost: [[Double]]) -> [Int] {
        guard let width = cost.first?.count else { return [] }
        let n = cost.count, m = width
        var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: m + 1)
        var p = [Int](repeating: 0, count: m + 1), way = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            p[0] = i; var j0 = 0
            var minv = [Double](repeating: .infinity, count: m + 1)
            var used = [Bool](repeating: false, count: m + 1)
            repeat {
                used[j0] = true; let i0 = p[j0]; var delta = Double.infinity; var j1 = 0
                for j in 1...m where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...m {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat { let prior = way[j0]; p[j0] = p[prior]; j0 = prior } while j0 != 0
        }
        var answer = [Int](repeating: -1, count: n)
        for j in 1...m where p[j] > 0 { answer[p[j] - 1] = j - 1 }
        return answer
    }
}
