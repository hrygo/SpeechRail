import Foundation
import SpeechRailDiarizationProtocol

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("self-test failed: \(message)\n".utf8))
        exit(1)
    }
}

do {
    let declared = [
        DiarizationClusteringPolicy(threshold: 0.60, warmStartFa: 0.07, warmStartFb: 0.8),
        DiarizationClusteringPolicy(threshold: 0.45, warmStartFa: 0.07, warmStartFb: 0.8),
        DiarizationClusteringPolicy(threshold: 0.75, warmStartFa: 0.07, warmStartFb: 0.8),
        DiarizationClusteringPolicy(threshold: 0.60, warmStartFa: 0.05, warmStartFb: 0.8),
        DiarizationClusteringPolicy(threshold: 0.60, warmStartFa: 0.09, warmStartFb: 0.8),
        DiarizationClusteringPolicy(threshold: 0.60, warmStartFa: 0.07, warmStartFb: 0.5),
        DiarizationClusteringPolicy(threshold: 0.60, warmStartFa: 0.07, warmStartFb: 1.1),
    ]
    for policy in declared { try policy.validate() }
    for value in [0.0, -0.1, 2.01, Double.nan, Double.infinity] {
        do {
            try DiarizationClusteringPolicy(threshold: value, warmStartFa: 0.07, warmStartFb: 0.8)
                .validate()
            require(false, "invalid clustering threshold rejection")
        } catch {}
    }
    for value in [0.0, -0.1, Double.nan, Double.infinity] {
        do {
            try DiarizationClusteringPolicy(threshold: 0.6, warmStartFa: value, warmStartFb: 0.8)
                .validate()
            require(false, "invalid Fa rejection")
        } catch {}
        do {
            try DiarizationClusteringPolicy(threshold: 0.6, warmStartFa: 0.07, warmStartFb: value)
                .validate()
            require(false, "invalid Fb rejection")
        } catch {}
    }
} catch { require(false, "clustering policy validation") }

do {
    let baseline = DiarizationPreprocessingPolicy(
        segmentationStepRatio: 0.2, embeddingMinSegmentDurationSeconds: 1.0
    )
    let highRecall = DiarizationPreprocessingPolicy(
        segmentationStepRatio: 0.1, embeddingMinSegmentDurationSeconds: 0.0
    )
    try baseline.validate()
    try highRecall.validate()
    for value in [0.0, -0.1, 1.01, Double.nan, Double.infinity] {
        do {
            try DiarizationPreprocessingPolicy(
                segmentationStepRatio: value, embeddingMinSegmentDurationSeconds: 1.0
            ).validate()
            require(false, "invalid segmentation step ratio rejection")
        } catch {}
    }
    for value in [-0.1, 5.01, Double.nan, Double.infinity] {
        do {
            try DiarizationPreprocessingPolicy(
                segmentationStepRatio: 0.2, embeddingMinSegmentDurationSeconds: value
            ).validate()
            require(false, "invalid embedding minimum duration rejection")
        } catch {}
    }
} catch { require(false, "preprocessing policy validation") }

do {
    let policy = SpeakerMatchingPolicy(version: "test_v1", prototypePolicy: "anchor_farthest_v1",
        matchDistanceMax: 0.25, matchMarginMin: 0.06, updateDistanceMax: 0.12,
        minimumNewVoiceMs: 1500, minimumUpdateVoiceMs: 2000, candidateRetentionMs: 60000,
        modelSnapshot: "7eab74f3463c736418d0eb10296261ae581146c9",
        calibrationDigest: String(repeating: "a", count: 64))
    let candidate = DiarizationCalibrationCandidate(
        matchingPolicy: policy,
        matchingEmbeddingSpace: .pldaRho128Cosine,
        clusteringPolicy: DiarizationClusteringPolicy(threshold: 0.60, warmStartFa: 0.07, warmStartFb: 0.8),
        preprocessingPolicy: DiarizationPreprocessingPolicy(
            segmentationStepRatio: 0.1, embeddingMinSegmentDurationSeconds: 0.0
        )
    )
    try candidate.validate()
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let encoded = try encoder.encode([candidate])
    let decoded = try DiarizationCalibrationCandidate.decodeArray(encoded)
    require(decoded.count == 1 && decoded[0].clusteringPolicy.threshold == 0.60
        && decoded[0].matchingEmbeddingSpace == .pldaRho128Cosine
        && decoded[0].preprocessingPolicy.segmentationStepRatio == 0.1
        && decoded[0].preprocessingPolicy.embeddingMinSegmentDurationSeconds == 0.0,
        "calibration candidate decoding")
    do {
        _ = try DiarizationCalibrationCandidate.decodeArray(try encoder.encode(Array(repeating: candidate, count: 25)))
        require(false, "calibration candidate count limit")
    } catch {}
    do {
        _ = try DiarizationCalibrationCandidate.decodeArray(Data(repeating: 0x20, count: 65537))
        require(false, "calibration candidate encoded size limit")
    } catch {}
} catch { require(false, "calibration candidate validation") }

do {
    let payload = Data([0x01, 0x00, 0x02, 0x00])
    let encoded = try DiarizationPacketCodec.encode(
        header: ["protocol_version": DiarizationPacketCodec.protocolVersion, "operation": "append"],
        payload: payload
    )
    let decoded = try DiarizationPacketCodec.decode(encoded)
    require(decoded.header["protocol_version"] as? Int == DiarizationPacketCodec.protocolVersion, "version")
    require(decoded.header["operation"] as? String == "append", "operation")
    require(decoded.payload == payload, "binary payload")

    var rejected = false
    do {
        _ = try DiarizationPacketCodec.decode(Data([0x00]))
    } catch {
        rejected = true
    }
    require(rejected, "truncated packet rejection")
    for invalid: Any in [true, 1.5, -1, "2", NSNumber(value: UInt64.max)] {
        do { _ = try DiarizationPacketCodec.nonnegativeInteger(invalid); require(false, "strict integer") }
        catch {}
    }
    let integer = try DiarizationPacketCodec.nonnegativeInteger(NSNumber(value: 2))
    require(integer == 2, "integer accepts JSON number")
    do {
        _ = try DiarizationPacketCodec.encode(
            header: ["operation": "infer"],
            payload: Data(repeating: 0, count: DiarizationPacketCodec.maxPayloadBytes + 1)
        )
        require(false, "IPC payload limit")
    } catch PacketCodecError.packetTooLarge {}
} catch {
    FileHandle.standardError.write(Data("self-test failed: \(error)\n".utf8))
    exit(1)
}

for count in [750, 751, 752] {
    do {
        let retained = min(750, count)
        let cursor = try RetainedFrameCursor(totalFrames: count, retainedFrames: retained,
                                             emittedFrames: count - 1)
        require(cursor.localRange == (retained - 1)..<retained, "retained local index")
        require(cursor.absoluteStart == count - 1, "absolute frame axis")
    } catch { require(false, "valid retained frame cursor") }
}
do {
    _ = try RetainedFrameCursor(totalFrames: 752, retainedFrames: 750, emittedFrames: 0)
    require(false, "lost un-emitted frames must fail")
} catch {}


// Matching policy is explicit test data; never a production calibration.
do {
    let policy = SpeakerMatchingPolicy(version: "test_v1", prototypePolicy: "anchor_farthest_v1",
        matchDistanceMax: 0.25, matchMarginMin: 0.06, updateDistanceMax: 0.12,
        minimumNewVoiceMs: 1500, minimumUpdateVoiceMs: 2000, candidateRetentionMs: 60000,
        modelSnapshot: "7eab74f3463c736418d0eb10296261ae581146c9",
        calibrationDigest: String(repeating: "a", count: 64))
    var matcher = try SessionSpeakerMatcher(policy: policy)
    func cluster(_ name: String, _ axis: Int, _ start: Int, _ end: Int) -> SpeakerLocalCluster {
        var vector = [Double](repeating: 0, count: 256); vector[axis] = 1
        return SpeakerLocalCluster(id: name, centroid: vector,
            uniqueVoice: [SpeakerVoiceSpan(start: start, end: end)], anchors: [])
    }
    let first = try matcher.assign([cluster("left",0,0,32000), cluster("right",1,0,32000)], through: 32000)
    require(first["left"]?.slot == 0 && first["right"]?.slot == 1, "initial identities")
    let swapped = try matcher.assign([cluster("left",1,32000,64000),cluster("right",0,32000,64000)], through:64000)
    require(swapped["left"]?.slot == 1 && swapped["right"]?.slot == 0, "local permutation")
    let short = try matcher.assign([cluster("short",4,64000,70400)], through:70400)
    require(short["short"]?.slot == nil, "short response remains unknown")
    _ = try matcher.assign([cluster("short",4,64000,70400)], through:70400)
    require(matcher.identityCount == 2, "overlap cannot count as new voice")
    let longer = try matcher.assign([cluster("short",4,70400,96000)], through:96000)
    require(longer["short"]?.slot == 2, "unique support creates identity")
    let returning = try matcher.assign([cluster("returns",0,16000*1200,16000*1202)], through:16000*1202)
    require(returning["returns"]?.slot == 0, "identity survives absence")
    require(matcher.prototypeCount <= matcher.identityCount * 3, "bounded prototypes")
    var bad = cluster("nan",6,16000*1202,16000*1204); bad.centroid[0] = .nan
    do { _ = try matcher.assign([bad], through:16000*1204); require(false,"nonfinite vector rejection") } catch {}
    do { _ = try matcher.assign([], through:0); require(false,"regressing watermark rejection") } catch {}
    require(matcher.identityCount == 3, "invalid evidence is atomic")
    var overflowPolicy = policy; overflowPolicy.minimumNewVoiceMs = Int.max
    do { _ = try SessionSpeakerMatcher(policy:overflowPolicy); require(false,"duration overflow rejection") } catch {}

    var capacity = try SessionSpeakerMatcher(policy:policy)
    for index in 0..<32 {
        let value = try capacity.assign([cluster("speaker",index,index*32000,(index+1)*32000)], through:(index+1)*32000)
        require(value["speaker"]?.slot == index, "monotonic identity allocator")
    }
    let full = try capacity.assign([cluster("overflow",33,32*32000,33*32000)], through:33*32000)
    require(full["overflow"]?.slot == nil && full["overflow"]?.reason == "speaker_capacity", "capacity never aliases speaker")
    require(capacity.identityCount == 32, "fixed identity cap")

    var certifiedPolicy = policy
    certifiedPolicy.certifiedMaxSpeakers = 5
    certifiedPolicy.validationDigest = String(repeating: "b", count: 64)
    var certified = try SessionSpeakerMatcher(policy:certifiedPolicy)
    for index in 0..<5 {
        let value = try certified.assign(
            [cluster("speaker",index,index*32000,(index+1)*32000)], through:(index+1)*32000)
        require(value["speaker"]?.slot == index, "certified identity allocation")
    }
    let knownAtCapacity = try certified.assign(
        [cluster("known",4,160000,192000)], through:192000)
    require(knownAtCapacity["known"]?.slot == 4, "certified capacity preserves known identities")
    let beyondCertifiedCapacity = try certified.assign(
        [cluster("sixth",5,192000,224000)], through:224000)
    require(beyondCertifiedCapacity["sixth"]?.slot == nil
        && beyondCertifiedCapacity["sixth"]?.reason == "speaker_capacity",
        "certified capacity leaves excess speakers unknown")
    require(certified.identityCount == 5, "certified capacity never creates an extra identity")

    var collision = try SessionSpeakerMatcher(policy:policy)
    _ = try collision.assign([cluster("anchor",0,0,32000)], through:32000)
    let collisions = try collision.assign([cluster("one",0,32000,64000),cluster("two",0,32000,64000)], through:64000)
    require(collisions.values.filter({ $0.slot != nil }).count == 1, "one-to-one cannot-link")
    var conflict = cluster("conflict",1,64000,96000)
    conflict = SpeakerLocalCluster(id:conflict.id,centroid:conflict.centroid,uniqueVoice:conflict.uniqueVoice,anchors:[0])
    let contradicted = try collision.assign([conflict],through:96000)
    require(contradicted["conflict"]?.slot == nil, "anchor cannot override acoustic conflict")
} catch { require(false, "speaker matching policy/self-test") }
