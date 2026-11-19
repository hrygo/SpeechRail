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
    let start = 9_007_199_254_000_000
    let end = start + 160_000
    let header: [String: Any] = ["epoch": String(repeating: "a", count: 128), "stable_through": end]
    let dense: [[String: Any]] = (0..<1000).map { i in
        ["start": start + 160 * i, "end": start + 160 * (i + 1),
         "active_slots": [i % 2], "reason": "identity_uncertain"]
    }
    let evidence: [[String: Any]] = [["start": start, "end": end, "active_slots": [2]]]
    let (original, originalSource) = try DiarizationPacketCodec.activityWithinHeaderBudget(
        evidence, evidence: { dense }, header: header, replacingFrom: start, through: end)
    require(originalSource == .rendered && original[0]["active_slots"] as? [Int] == [2],
        "keep the expanded view when it fits")
    let (fallback, fallbackSource) = try DiarizationPacketCodec.activityWithinHeaderBudget(
        dense, evidence: { evidence }, header: header, replacingFrom: start, through: end)
    require(fallbackSource == .evidence && fallback.count == 1 && fallback[0]["active_slots"] as? [Int] == [2],
        "dense activity falls back to the same-window evidence")
    let (gap, gapSource) = try DiarizationPacketCodec.activityWithinHeaderBudget(
        dense, evidence: { dense }, header: header, replacingFrom: start, through: end)
    require(gapSource == .gap && gap.count == 1 && gap[0]["start"] as? Int == start && gap[0]["end"] as? Int == end
            && gap[0]["reason"] as? String == "activity_gap",
        "oversized fallback keeps an unknown span covering the replacement range")
    var response = header
    response["frames"] = gap
    _ = try DiarizationPacketCodec.encode(header: response)
} catch { require(false, "activity response header budget") }

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
    var previewMatcher = try SessionSpeakerMatcher(policy: policy)
    let shared = (0..<3).map { cluster("voice-\($0)", $0, $0 * 32000, ($0 + 1) * 32000) }
    let preview = try previewMatcher.assign(
        shared + [cluster("spurious-split", 3, 96000, 128000)], through: 160000, persist: false)
    require(preview["spurious-split"]?.slot != nil && previewMatcher.identityCount == 0,
        "provisional activity cannot reserve a session speaker slot")
    let sealed = try previewMatcher.assign(
        shared + [cluster("fourth-voice", 4, 128000, 160000)], through: 320000)
    require(sealed["fourth-voice"]?.slot != nil && previewMatcher.identityCount == 4,
        "first sealed output can enroll the real fourth speaker")
    let later = try previewMatcher.assign([
        cluster("fifth-voice", 5, 320000, 352000), cluster("returning", 4, 352000, 384000),
    ], through: 384000)
    require(later["fifth-voice"]?.reason == "speaker_capacity"
            && later["returning"]?.slot == sealed["fourth-voice"]?.slot,
        "after sealing, reject extra voices and keep established slots")

    var limited = try SessionSpeakerMatcher(policy: policy, maxSpeakers: 2)
    let pair = try limited.assign([cluster("a",0,0,32000),cluster("b",1,0,32000)], through:32000)
    require(pair["a"]?.slot == 0 && pair["b"]?.slot == 1, "requested pair allocation")
    let late = try limited.assign([cluster("new",2,32000,64000)], through:64000)
    require(late["new"]?.slot == nil && late["new"]?.reason == "speaker_capacity",
        "underestimated count rejects late voice instead of merging")
    let originalPair = try limited.assign([cluster("back",0,64000,96000)], through:96000)
    require(originalPair["back"]?.slot == 0 && limited.identityCount == 2,
        "late voice cannot evict original pair")
    var overestimated = try SessionSpeakerMatcher(policy: policy, maxSpeakers: 4)
    _ = try overestimated.assign([cluster("only",0,0,32000)], through:32000)
    let interjection = try overestimated.assign([cluster("short",1,32000,38400)], through:38400)
    require(interjection["short"]?.slot == nil && overestimated.identityCount == 1,
        "overestimated count does not fill identities from short interjections")
    let lateLong = try overestimated.assign([cluster("new",1,38400,70400)], through:70400)
    require(lateLong["new"]?.slot == 1, "late supported speaker can enter available budget")
    for bad in [0,5] {
        do { _ = try SessionSpeakerMatcher(policy: policy, maxSpeakers: bad)
            require(false, "invalid requested identity budget") } catch {}
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
    for index in 0..<4 {
        let value = try capacity.assign([cluster("speaker",index,index*32000,(index+1)*32000)], through:(index+1)*32000)
        require(value["speaker"]?.slot == index, "monotonic identity allocator")
    }
    let full = try capacity.assign([cluster("overflow",4,4*32000,5*32000)], through:5*32000)
    require(full["overflow"]?.slot == nil && full["overflow"]?.reason == "speaker_capacity", "capacity never aliases speaker")
    require(capacity.identityCount == 4, "fixed four-identity cap")
    let sixth = try capacity.assign([cluster("sixth",5,160000,192000)], through:192000)
    require(sixth["sixth"]?.slot == nil, "sixth voice stays unknown")
    let returns = try capacity.assign([cluster("returns",0,192000,224000)], through:224000)
    require(returns["returns"]?.slot == 0 && capacity.identityCount == 4,
        "extra voices cannot evict or rotate an existing identity")
    let briefKnown = try capacity.assign([cluster("brief",0,224000,230400)], through:230400)
    require(briefKnown["brief"]?.slot == nil && briefKnown["brief"]?.reason == "identity_uncertain",
        "short acoustic evidence cannot borrow a known identity")

    var certifiedPolicy = policy
    certifiedPolicy.certifiedMaxSpeakers = 4
    certifiedPolicy.validationDigest = String(repeating: "b", count: 64)
    var certified = try SessionSpeakerMatcher(policy:certifiedPolicy)
    for index in 0..<4 {
        let value = try certified.assign(
            [cluster("speaker",index,index*32000,(index+1)*32000)], through:(index+1)*32000)
        require(value["speaker"]?.slot == index, "certified identity allocation")
    }
    let knownAtCapacity = try certified.assign(
        [cluster("known",4,160000,192000)], through:192000)
    require(knownAtCapacity["known"]?.slot == nil, "fifth voice is rejected at certified capacity")
    let beyondCertifiedCapacity = try certified.assign(
        [cluster("sixth",5,192000,224000)], through:224000)
    require(beyondCertifiedCapacity["sixth"]?.slot == nil
        && beyondCertifiedCapacity["sixth"]?.reason == "speaker_capacity",
        "certified capacity leaves excess speakers unknown")
    require(certified.identityCount == 4, "certified capacity never creates an extra identity")

    var drift = try SessionSpeakerMatcher(policy:policy)
    _ = try drift.assign([cluster("anchor",0,0,32000)], through:32000)
    func angled(_ degrees: Double, _ start: Int) -> SpeakerLocalCluster {
        var vector = [Double](repeating:0,count:256)
        vector[0] = cos(degrees * .pi / 180); vector[1] = sin(degrees * .pi / 180)
        return .init(id:"voice",centroid:vector,
            uniqueVoice:[.init(start:start,end:start+32000)],anchors:[])
    }
    _ = try drift.assign([angled(20,32000)], through:64000)
    _ = try drift.assign([angled(40,64000)], through:96000)
    let prototypesBeforeRefusal = drift.prototypeCount
    let drifting = try drift.assign([angled(60,96000)], through:128000)
    require(drifting["voice"]?.slot == nil, "representative chain cannot drift away from original anchor")
    require(drift.prototypeCount == prototypesBeforeRefusal, "rejected voice cannot update prototypes")
    let original = try drift.assign([cluster("original",0,128000,160000)], through:160000)
    require(original["original"]?.slot == 0, "original identity survives rejected drift")

    var refusedUpdate = try SessionSpeakerMatcher(policy: policy)
    _ = try refusedUpdate.assign([cluster("anchor", 0, 0, 32000)], through: 32000)
    _ = try refusedUpdate.assign([angled(20, 32000)], through: 64000, withholdingUpdatesFor: { _ in [0] })
    require(refusedUpdate.prototypeCount == 1, "a conflict cannot strengthen the matched identity")
    _ = try refusedUpdate.assign([angled(20, 32000)], through: 64000)
    require(refusedUpdate.prototypeCount == 2, "accepted evidence contributes to the prototype")

    let mixed = SpeakerActivityDecision.resolve([
        SpeakerMatch(slot:0,reason:nil), SpeakerMatch(slot:nil,reason:"speaker_capacity")])
    require(mixed.slots == [0] && mixed.reason == "speaker_capacity",
        "retain matched overlap activity and the refusal for the additional voice")
    let overlap = SpeakerActivityDecision.resolve([
        SpeakerMatch(slot:0,reason:nil), SpeakerMatch(slot:1,reason:nil)])
    require(overlap.slots == [0, 1] && overlap.reason == nil,
        "keep both speakers when both are independently matched")
    let missing = SpeakerActivityDecision.resolve([nil])
    require(missing.slots.isEmpty && missing.reason == "identity_uncertain",
        "missing acoustic match must fail closed")

    let uncertainOverlap = SpeakerActivityDecision.resolve([SpeakerMatch(slot: 0, reason: nil), nil])
    let recoveredOverlap = uncertainOverlap.addingOverlap([0, 1])
    require(recoveredOverlap.slots == [0, 1] && recoveredOverlap.reason == "identity_uncertain",
        "preserve the primary activity and refusal when a second known voice is recovered")
    require(mixed.addingOverlap([0, 1]) == mixed,
        "capacity refusal cannot be bypassed by overlap recovery")
    require(missing.addingOverlap([0, 1]) == missing && uncertainOverlap.addingOverlap([1, 2]) == uncertainOverlap,
        "overlap recovery cannot insert a primary label or disagree with it")
    let distinct = cluster("distinct", 1, 0, 32000).centroid
    require(limited.confirmedOverlapSlot(centroid: distinct, sealedSlots: [0, 1]) == 1,
        "short overlap can project a confirmed identity without new enrollment")
    require(limited.confirmedOverlapSlot(centroid: distinct, sealedSlots: [0]) == nil,
        "a secondary slot must already have confirmed solo evidence")
    let unrecognized = cluster("unrecognized", 2, 0, 32000).centroid
    require(limited.confirmedOverlapSlot(centroid: unrecognized, sealedSlots: [0, 1]) == nil,
        "an unrecognized voice cannot take a sealed slot")

    let one = SpeakerActivityDecision.resolve([SpeakerMatch(slot: 0, reason: nil)])
    let two = SpeakerActivityDecision.resolve([SpeakerMatch(slot: 1, reason: nil)])
    func frame(_ start: Int, _ end: Int, _ decision: SpeakerActivityDecision) -> SpeakerActivityFrame {
        .init(span: .init(start: start, end: end), decision: decision)
    }
    let previousOverlap = SpeakerActivityPreview(
        frames: [frame(0, 30, overlap), frame(30, 50, recoveredOverlap)],
        matchedSlots: [0, 1], stableThrough: 20)
    require(previousOverlap.supportingOverlap([0, 1], during: .init(start: 15, end: 45))
                == [.init(start: 20, end: 30)],
        "only the unsealed portion of an unambiguous pair is usable as overlap evidence")
    require(previousOverlap.supportingOverlap([0, 1], during: .init(start: 50, end: 60)).isEmpty,
        "earlier matches do not label a different portion of audio")
    require(previousOverlap.supportingOverlap([0, 2], during: .init(start: 20, end: 30)).isEmpty,
        "the two windows must agree on the exact pair")
    require(previousOverlap.supportingOverlap([0, 1], during: .init(start: 20, end: 30), windowAnchors: [2]).isEmpty,
        "evidence of another identity vetoes overlap recovery")
    require(previousOverlap.supportingOverlap([0, 1], during: .init(start: 20, end: 30), windowAnchors: [0])
                == [.init(start: 20, end: 30)],
        "solo evidence of the first voice can coexist with the same confirmed pair")
    let unsealedIdentityPair = SpeakerActivityPreview(
        frames: [frame(20, 30, overlap)], matchedSlots: [0], stableThrough: 20)
    require(unsealedIdentityPair.supportingOverlap([0, 1], during: .init(start: 20, end: 30)).isEmpty,
        "a pair containing a provisional identity does not provide overlap evidence")
    let previous = SpeakerActivityPreview(
        frames: [frame(0, 10, one), frame(10, 40, two), frame(40, 50, mixed), frame(50, 70, two)],
        matchedSlots: [0, 1], stableThrough: 20)
    let current = [frame(0, 45, one), frame(45, 55, overlap), frame(55, 70, one)]
    let guarded = previous.markingConflicts(
        in: current, matchedSlots: [0], establishedSlots: 0..<2, stableThrough: 65)
    require(guarded.frames == [
        frame(0, 20, one), frame(20, 40, missing), frame(40, 45, one), frame(45, 55, overlap),
        frame(55, 65, missing), frame(65, 70, one),
    ], "a disappearing matched voice makes only the contested sealed interval unknown")
    require(guarded.rejected == [.init(start: 20, end: 40), .init(start: 55, end: 65)],
        "conflicted intervals are available for exclusion from identity updates")
    require(previous.markingConflicts(
        in: current, matchedSlots: [0, 1], establishedSlots: 0..<2, stableThrough: 65).frames == current,
        "keep current activity when both identities are independently matched")
    require(previous.markingConflicts(
        in: current, matchedSlots: [0], establishedSlots: 0..<0, stableThrough: 65).frames == current,
        "a genuinely new assignment is not a reuse of a prior identity")
    let provisional = SpeakerActivityPreview(frames: [frame(10, 40, two)], matchedSlots: [0], stableThrough: 20)
    require(provisional.markingConflicts(
        in: current, matchedSlots: [], establishedSlots: 0..<2, stableThrough: 65).frames == current,
        "an uncommitted speaker cannot veto a later match")

    var collision = try SessionSpeakerMatcher(policy:policy)
    _ = try collision.assign([cluster("anchor",0,0,32000)], through:32000)
    let collisions = try collision.assign([cluster("one",0,32000,64000),cluster("two",0,32000,64000)], through:64000)
    require(collisions.values.filter({ $0.slot != nil }).count == 1, "one-to-one cannot-link")
    var conflict = cluster("conflict",1,64000,96000)
    conflict = SpeakerLocalCluster(id:conflict.id,centroid:conflict.centroid,uniqueVoice:conflict.uniqueVoice,anchors:[0])
    let contradicted = try collision.assign([conflict],through:96000)
    require(contradicted["conflict"]?.slot == nil, "anchor cannot override acoustic conflict")
} catch { require(false, "speaker matching policy/self-test") }
