import CoreML
import FluidAudio
import Foundation
import SpeechRailDiarizationProtocol

private let protocolVersion = DiarizationPacketCodec.protocolVersion

private enum WorkerError: Error {
    case invalidPacket
    case invalidRequest
    case unsupportedModel
}

private func readExact(_ count: Int) throws -> Data? {
    var data = Data()
    while data.count < count {
        guard let chunk = try FileHandle.standardInput.read(upToCount: count - data.count) else {
            return data.isEmpty ? nil : nil
        }
        if chunk.isEmpty { return data.isEmpty ? nil : nil }
        data.append(chunk)
    }
    return data
}

private func readPacket() throws -> ([String: Any], Data)? {
    guard let prefix = try readExact(8) else { return nil }
    let sizes: (header: Int, payload: Int)
    do {
        sizes = try DiarizationPacketCodec.sizes(prefix: prefix)
    } catch {
        throw WorkerError.invalidPacket
    }
    guard let header = try readExact(sizes.header), header.count == sizes.header,
          let payload = try readExact(sizes.payload), payload.count == sizes.payload
    else { throw WorkerError.invalidPacket }
    do {
        return try DiarizationPacketCodec.decode(prefix + header + payload)
    } catch {
        throw WorkerError.invalidPacket
    }
}

private func writePacket(_ header: [String: Any], _ payload: Data = Data()) throws {
    do {
        FileHandle.standardOutput.write(try DiarizationPacketCodec.encode(header: header, payload: payload))
    } catch {
        throw WorkerError.invalidPacket
    }
}

private final class StreamingWorker {
    private let diarizer: SortformerDiarizer
    private var acceptedSamples = 0
    private var emittedFrames = 0

    init(modelPath: String) throws {
        let url = URL(fileURLWithPath: modelPath)
        guard url.pathExtension == "mlmodelc", url.lastPathComponent == "SortformerNvidiaLow_v2.1.mlmodelc" else {
            throw WorkerError.unsupportedModel
        }
        var config = SortformerConfig.balancedV2_1
        config.debugMode = false
        self.diarizer = SortformerDiarizer(config: config, timelineConfig: .sortformerDefault)
        let modelConfig = MLModelConfiguration()
        modelConfig.computeUnits = .all
        // The v3/fp16 artifact is already compiled.  Do not call compileModel.
        let model = try MLModel(contentsOf: url, configuration: modelConfig)
        let models = try SortformerModels(config: config, main: model)
        self.diarizer.initialize(models: models)
    }

    func append(_ pcm: Data, start: Int) throws -> [String: Any] {
        guard start == acceptedSamples, pcm.count.isMultiple(of: 2) else {
            throw WorkerError.invalidRequest
        }
        let samples: [Float] = pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768.0 }
        }
        acceptedSamples += samples.count
        diarizer.addAudio(samples)
        while try diarizer.process() != nil {}
        return snapshot(finished: false)
    }

    func finish(through: Int) throws -> [String: Any] {
        guard through == acceptedSamples else { throw WorkerError.invalidRequest }
        _ = try diarizer.finalizeSession()
        return snapshot(finished: true)
    }

    func poll(through: Int) throws -> [String: Any] {
        guard through <= acceptedSamples else { throw WorkerError.invalidRequest }
        return snapshot(finished: false)
    }

    private func snapshot(finished: Bool) -> [String: Any] {
        let timeline = diarizer.timeline
        let frameSamples = Int((timeline.config.frameDurationSeconds * 16000).rounded())
        let totalFrames = timeline.numFinalizedFrames
        let predictions = timeline.finalizedPredictions
        var frames: [[String: Any]] = []
        if emittedFrames < totalFrames {
            for frame in emittedFrames..<totalFrames {
                let start = frame * frameSamples
                guard start < acceptedSamples else { break }
                let base = frame * 4
                guard base + 4 <= predictions.count else { break }
                frames.append([
                    "start": start,
                    "end": min(start + frameSamples, acceptedSamples),
                    "scores": Array(predictions[base..<(base + 4)]),
                ])
            }
            emittedFrames = totalFrames
        }
        let finalizedSamples = min(totalFrames * frameSamples, acceptedSamples)
        // EOF padding advances model computation but must never extend the public
        // timebase. After finalizeSession the whole real input is processed and
        // stable, including a trailing partial frame.
        let processedSamples = finished ? acceptedSamples : finalizedSamples
        return [
            "protocol_version": protocolVersion,
            "ok": true,
            "processed_through": processedSamples,
            "stable_through": finished ? acceptedSamples : finalizedSamples,
            "frames": frames,
        ]
    }
}

private func argument(named name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

guard argument(named: "--protocol-version") == String(protocolVersion),
      let modelPath = argument(named: "--model")
else {
    exit(64)
}

do {
    let worker = try StreamingWorker(modelPath: modelPath)
    while let (header, payload) = try readPacket() {
        guard header["protocol_version"] as? Int == protocolVersion,
              let operation = header["operation"] as? String
        else { throw WorkerError.invalidRequest }
        var response: [String: Any]
        switch operation {
        case "preflight":
            response = ["protocol_version": protocolVersion, "ok": true]
        case "append":
            guard let start = header["audio_start"] as? Int,
                  let samples = header["audio_samples"] as? Int,
                  samples * 2 == payload.count
            else { throw WorkerError.invalidRequest }
            response = try worker.append(payload, start: start)
        case "poll":
            guard let through = header["through_sample"] as? Int else { throw WorkerError.invalidRequest }
            response = try worker.poll(through: through)
        case "finish":
            guard let through = header["through_sample"] as? Int else { throw WorkerError.invalidRequest }
            response = try worker.finish(through: through)
        case "cancel":
            try writePacket(["protocol_version": protocolVersion, "ok": true])
            exit(0)
        default:
            throw WorkerError.invalidRequest
        }
        if operation != "preflight" {
            guard let epoch = header["epoch"] as? String, !epoch.isEmpty else {
                throw WorkerError.invalidRequest
            }
            response["epoch"] = epoch
            response["operation"] = operation
        }
        try writePacket(response)
    }
} catch {
    try? writePacket([
        "protocol_version": protocolVersion,
        "ok": false,
        "error": "\(error)",
    ])
    exit(1)
}
