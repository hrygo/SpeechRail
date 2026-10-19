import CandidateFrames
import CandidatePacketCodec
import CoreML
import FluidAudio
import Foundation

private let revision = "503b4bd1bbf7220882de39fe8ae6716aae4132da"
private enum CandidateError: Error { case invalidRequest, invalidOutput, unavailableArtifact }

private func readExact(_ count: Int, allowEOF: Bool = false) throws -> Data? {
    var result = Data()
    while result.count < count {
        guard let part = try FileHandle.standardInput.read(upToCount: count - result.count), !part.isEmpty else {
            if allowEOF && result.isEmpty { return nil }
            throw CandidateError.invalidRequest
        }
        result.append(part)
    }
    return result
}

private func readPacket() throws -> ([String: Any], Data)? {
    guard let prefix = try readExact(8, allowEOF: true) else { return nil }
    let sizes = try DiarizationPacketCodec.sizes(prefix: prefix)
    guard sizes.payload <= 32_000,
          let header = try readExact(sizes.header), let audio = try readExact(sizes.payload) else {
        throw CandidateError.invalidRequest
    }
    return try DiarizationPacketCodec.decode(prefix + header + audio)
}

private func writePacket(_ header: [String: Any]) throws {
    var metadata = header
    var payload = Data()
    if let frames = metadata.removeValue(forKey: "frames") {
        payload = try JSONSerialization.data(withJSONObject: frames)
        guard payload.count <= 512 * 1024 else { throw CandidateError.invalidOutput }
    }
    FileHandle.standardOutput.write(try DiarizationPacketCodec.encode(header: metadata, payload: payload))
}

// A single sequential task owns this non-Sendable SDK object, with no actor
// reentrancy or task-per-chunk fanout. Only the local loader is reachable.
@MainActor
private final class CandidateWorker {
    private let diarizer: Nemotron3Diarizer
    private let preset: String
    private let computeUnits: String
    private var epoch: String?
    private var accepted = 0
    private var timeline = CandidateFrames()
    private var finished = false

    init(directory: URL, preset: String, computeUnits: String) async throws {
        guard ["fast32", "fast128"].contains(preset),
              let config = Nemotron3Config.preset(named: preset) else { throw CandidateError.invalidRequest }
        let units: MLComputeUnits
        switch computeUnits {
        case "all": units = .all
        case "cpuOnly": units = .cpuOnly
        case "cpuAndGPU": units = .cpuAndGPU
        case "cpuAndNeuralEngine": units = .cpuAndNeuralEngine
        default: throw CandidateError.invalidRequest
        }
        // Reject missing precompiled bundles, preventing SDK .mlpackage fallback.
        let bundle = directory.appendingPathComponent(config.modelFileName)
        let embeddingURL = directory.appendingPathComponent("learnable_sil_emb.bin")
        for url in [bundle, bundle.appendingPathComponent("coremldata.bin"), embeddingURL] {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CandidateError.unavailableArtifact }
        }
        let embedding = try Data(contentsOf: embeddingURL)
        guard embedding.count == 2048,
              embedding.withUnsafeBytes({ $0.bindMemory(to: Float.self).allSatisfy(\.isFinite) }) else {
            throw CandidateError.unavailableArtifact
        }
        let models = try await Nemotron3Models.load(config: config, directory: directory, computeUnits: units)
        // SDK creates backings but does not require all declared shapes to match.
        let description = models.model.modelDescription
        let inputShapes: [String: [Int]] = [
            "chunk": [1, config.chunkMelFrames, 128], "chunk_lengths": [1],
            "spkcache": [1, 264, 512], "spkcache_lengths": [1],
            "fifo": [1, 40, 512], "fifo_lengths": [1],
        ]
        let outputShapes: [String: [Int]] = [
            "speaker_preds": [1, config.packedFrames, 8],
            "speaker_preds_10ms": [1, config.packedFrames * 8, 8],
            "chunk_pre_encode_embs": [1, config.chunkEncFrames, 512],
        ]
        for (name, shape) in inputShapes {
            let constraint = description.inputDescriptionsByName[name]?.multiArrayConstraint
            let dtype: MLMultiArrayDataType = name.hasSuffix("_lengths") ? .int32 : .float16
            guard constraint?.shape.map(\.intValue) == shape, constraint?.dataType == dtype else {
                throw CandidateError.unavailableArtifact
            }
        }
        for (name, shape) in outputShapes {
            let constraint = description.outputDescriptionsByName[name]?.multiArrayConstraint
            guard constraint?.shape.map(\.intValue) == shape, constraint?.dataType == .float16 else {
                throw CandidateError.unavailableArtifact
            }
        }
        self.diarizer = Nemotron3Diarizer(config: config, models: models)
        self.preset = preset
        self.computeUnits = computeUnits
    }

    func handle(_ header: [String: Any], audio: Data) throws -> [String: Any] {
        guard try DiarizationPacketCodec.nonnegativeInteger(header["protocol_version"]) == 3,
              let operation = header["operation"] as? String else { throw CandidateError.invalidRequest }
        var response: [String: Any] = ["protocol_version": 3, "backend": "nemotron3_candidate",
            "sdk_revision": revision, "ok": true, "operation": operation,
            "preset": preset, "compute_units": computeUnits]
        if operation == "preflight" {
            guard audio.isEmpty, epoch == nil else { throw CandidateError.invalidRequest }
            response["model_shape_verified"] = true
            return response
        }
        guard let requestEpoch = header["epoch"] as? String, !requestEpoch.isEmpty,
              requestEpoch.utf8.count <= 128, epoch == nil || epoch == requestEpoch else {
            throw CandidateError.invalidRequest
        }
        epoch = requestEpoch
        response["epoch"] = requestEpoch
        let results: [Nemotron3ChunkResult]
        if operation == "append" {
            guard !finished, audio.count.isMultiple(of: 2), audio.count <= 32_000,
                  try DiarizationPacketCodec.nonnegativeInteger(header["audio_start"]) == accepted,
                  try DiarizationPacketCodec.nonnegativeInteger(header["audio_samples"]) == audio.count / 2,
                  accepted <= 9_007_199_254_708_831 else { throw CandidateError.invalidRequest }
            let samples = audio.withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
            }
            diarizer.appendAudio(samples)
            accepted += samples.count
            results = try diarizer.processBufferedAudio()
        } else if operation == "finish" {
            guard audio.isEmpty,
                  try DiarizationPacketCodec.nonnegativeInteger(header["through_sample"]) == accepted else {
                throw CandidateError.invalidRequest
            }
            results = finished ? [] : try diarizer.finishStream()
            finished = true
        } else { throw CandidateError.invalidRequest }
        guard results.allSatisfy({ $0.numSpeakers == 8 && $0.frameCount >= 0
            && $0.probabilities.count == $0.frameCount * 8 }) else { throw CandidateError.invalidOutput }
        let frames = try timeline.consume(chunks: results.map(\.probabilities),
                                          accepted: accepted, final: finished)
        response["frames"] = frames.map { ["start": $0.start, "end": $0.end, "scores": $0.scores] as [String: Any] }
        response["processed_through"] = timeline.emitted
        response["stable_through"] = timeline.emitted
        return response
    }
}

@main
private struct Main {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 8, args[0] == "--model", args[2] == "--protocol-version",
                  args[3] == "3", args[4] == "--preset", args[6] == "--compute-units" else {
                throw CandidateError.invalidRequest
            }
            let worker = try await CandidateWorker(directory: URL(fileURLWithPath: args[1]),
                                                   preset: args[5], computeUnits: args[7])
            while let (header, audio) = try readPacket() {
                if header["operation"] as? String == "cancel" {
                    guard audio.isEmpty,
                          try DiarizationPacketCodec.nonnegativeInteger(header["protocol_version"]) == 3 else {
                        throw CandidateError.invalidRequest
                    }
                    break
                }
                try writePacket(worker.handle(header, audio: audio))
            }
        } catch {
            // No error descriptions: CoreML errors may include private paths.
            try? writePacket(["protocol_version": 3, "backend": "nemotron3_candidate",
                              "sdk_revision": revision, "ok": false, "code": "candidate_worker_failed"])
            Foundation.exit(1)
        }
    }
}
