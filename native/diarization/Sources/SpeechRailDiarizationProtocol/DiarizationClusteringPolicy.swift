import Foundation

public struct DiarizationClusteringPolicy: Codable, Hashable, Sendable {
    public let threshold: Double
    public let warmStartFa: Double
    public let warmStartFb: Double

    public init(threshold: Double, warmStartFa: Double, warmStartFb: Double) {
        self.threshold = threshold
        self.warmStartFa = warmStartFa
        self.warmStartFb = warmStartFb
    }

    public func validate() throws {
        guard threshold.isFinite, threshold > 0, threshold <= 2,
              warmStartFa.isFinite, warmStartFa > 0,
              warmStartFb.isFinite, warmStartFb > 0
        else { throw MatcherError.invalidPolicy }
    }
}

public struct DiarizationPreprocessingPolicy: Codable, Hashable, Sendable {
    public let segmentationStepRatio: Double
    public let embeddingMinSegmentDurationSeconds: Double

    public init(segmentationStepRatio: Double, embeddingMinSegmentDurationSeconds: Double) {
        self.segmentationStepRatio = segmentationStepRatio
        self.embeddingMinSegmentDurationSeconds = embeddingMinSegmentDurationSeconds
    }

    public func validate() throws {
        guard segmentationStepRatio.isFinite, (0.05...1.0).contains(segmentationStepRatio),
              embeddingMinSegmentDurationSeconds.isFinite,
              (0.0...5.0).contains(embeddingMinSegmentDurationSeconds)
        else { throw MatcherError.invalidPolicy }
    }
}

public struct DiarizationAcousticPolicy: Hashable, Sendable {
    public let preprocessing: DiarizationPreprocessingPolicy
    public let clustering: DiarizationClusteringPolicy

    public init(
        preprocessing: DiarizationPreprocessingPolicy,
        clustering: DiarizationClusteringPolicy
    ) {
        self.preprocessing = preprocessing
        self.clustering = clustering
    }
}

public enum DiarizationMatchingEmbeddingSpace: String, Codable, Hashable, Sendable {
    case embedding256Cosine = "embedding256_cosine"
    case pldaRho128Cosine = "plda_rho128_cosine"
}

public struct DiarizationCalibrationCandidate: Codable, Sendable {
    public static let maximumCount = 24
    public static let maximumEncodedBytes = 64 * 1024

    public let matchingPolicy: SpeakerMatchingPolicy
    public let matchingEmbeddingSpace: DiarizationMatchingEmbeddingSpace
    public let clusteringPolicy: DiarizationClusteringPolicy
    public let preprocessingPolicy: DiarizationPreprocessingPolicy

    public init(
        matchingPolicy: SpeakerMatchingPolicy,
        matchingEmbeddingSpace: DiarizationMatchingEmbeddingSpace = .embedding256Cosine,
        clusteringPolicy: DiarizationClusteringPolicy,
        preprocessingPolicy: DiarizationPreprocessingPolicy
    ) {
        self.matchingPolicy = matchingPolicy
        self.matchingEmbeddingSpace = matchingEmbeddingSpace
        self.clusteringPolicy = clusteringPolicy
        self.preprocessingPolicy = preprocessingPolicy
    }

    public var acousticPolicy: DiarizationAcousticPolicy {
        .init(preprocessing: preprocessingPolicy, clustering: clusteringPolicy)
    }

    public func validate() throws {
        try matchingPolicy.validate()
        try clusteringPolicy.validate()
        try preprocessingPolicy.validate()
    }

    public static func decodeArray(_ data: Data) throws -> [Self] {
        guard data.count <= maximumEncodedBytes else { throw MatcherError.invalidPolicy }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let candidates = try decoder.decode([Self].self, from: data)
        guard (1...maximumCount).contains(candidates.count) else { throw MatcherError.invalidPolicy }
        try candidates.forEach { try $0.validate() }
        return candidates
    }
}
