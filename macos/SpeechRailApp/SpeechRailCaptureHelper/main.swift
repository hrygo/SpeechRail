import Foundation
import Synchronization

/// XPC ingress. Native device work and every owned pump are joined before stop replies.
final class CaptureHelperService: NSObject, SpeechRailCaptureHelperProtocol, @unchecked Sendable {
    private let runtime = CaptureHelperRuntime()
    private let clientLock = NSLock()
    private var attachedClient: SpeechRailCaptureHelperClientProtocol?
    private let startedAt = Date()
    func attach(client: SpeechRailCaptureHelperClientProtocol) { clientLock.withLock { attachedClient = client } }

    func start(bundleIDs: [String], deviceUID: String?, label: String, epoch: String, reply: @escaping (NSError?) -> Void) {
        guard let epoch = UUID(uuidString: epoch), let client = clientLock.withLock({ attachedClient }) else {
            reply(NSError(domain: "SpeechRailCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "采集身份或接收端无效。"])); return
        }
        nonisolated(unsafe) let reply = reply
        nonisolated(unsafe) let captureClient = client
        Task {
            do {
                try await runtime.start(configuration: .init(bundleIDs: bundleIDs, outputDeviceUID: deviceUID, name: label), epoch: epoch,
                    deliver: { chunk in
                        guard let stamp = chunk.captureStamp else { return }
                        captureClient.deliver(pcm: chunk.pcm, level: chunk.level, epoch: stamp.captureEpoch.uuidString,
                            sourceID: stamp.sourceID.uuidString, sequence: stamp.sourceSequence,
                            capturedUptimeNanoseconds: stamp.capturedUptimeNanoseconds,
                            droppedSamplesBefore: UInt64(max(0, chunk.droppedSamplesBefore ?? 0)))
                    }, stopped: { error in
                        if let evidence = try? JSONEncoder().encode(error), evidence.count <= 1_024 {
                            captureClient.captureStopped(epoch: epoch.uuidString, evidence: evidence)
                        }
                    })
                reply(nil)
            } catch { reply(error as NSError) }
        }
    }

    func acknowledge(epoch: String, throughSequence: UInt64) {
        guard let epoch = UUID(uuidString: epoch) else { runtime.rejectAcknowledgement(); return }
        runtime.acknowledge(epoch: epoch, sequence: throughSequence)
    }
    func stop(reply: @escaping () -> Void) {
        nonisolated(unsafe) let reply = reply
        Task { await runtime.stop(); reply() }
    }
    func status(reply: @escaping (String) -> Void) {
        reply("SpeechRailCaptureHelper · 已运行 \(Int(Date().timeIntervalSince(startedAt)))s")
    }
}

private actor CaptureHelperRuntime {
    private let nativeQueue = DispatchQueue(label: "com.speechrail.capture-helper.native")
    private nonisolated let delivery = Mutex<CaptureAudioRelay?>(nil)
    private var capture: CoreAudioTapCapture?
    private var sourceContinuation: AudioChunkStream.Continuation?
    private var relay: CaptureAudioRelay?
    private var observer: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var epoch: UUID?
    private var generation = 0
    private var starting = false

    nonisolated func acknowledge(epoch: UUID, sequence: UInt64) {
        delivery.withLock { $0 }?.acknowledge(epoch: epoch, throughSequence: sequence)
    }
    nonisolated func rejectAcknowledgement() { delivery.withLock { $0 }?.requestStop(.sourceLost) }

    func start(configuration: CoreAudioTapCapture.Configuration, epoch: UUID,
               deliver: @Sendable @escaping (AudioChunk) -> Void,
               stopped: @Sendable @escaping (AudioStreamError) -> Void) async throws {
        guard !starting, capture == nil else { throw AudioStreamError(reason: .sourceLost) }
        starting = true; defer { starting = false }
        generation += 1; let token = generation
        await stopTask?.value
        guard token == generation else { throw CancellationError() }
        stopTask = nil
        let sourceID = UUID()
        let pair = AudioChunkStream.makeStream(epoch: epoch, sourceID: sourceID)
        let control = AsyncStream<AudioStreamTermination>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let capture = CoreAudioTapCapture(configuration: configuration, captureEpoch: epoch, sourceID: sourceID)
        let relay = CaptureAudioRelay(epoch: epoch, stream: pair.stream, deliver: deliver, stopCapture: { reason in
            pair.continuation.finish(reason)
            control.continuation.yield(reason); control.continuation.finish()
        })
        self.capture = capture; self.relay = relay; self.epoch = epoch; self.sourceContinuation = pair.continuation
        delivery.withLock { $0 = relay }
        observer = Task { [weak self] in
            for await reason in control.stream {
                guard !Task.isCancelled else { return }
                stopped(relay.terminalError ?? AudioStreamError(reason: reason, captureEpoch: epoch, sourceID: sourceID))
                await self?.sourceEnded(epoch: epoch)
                return
            }
        }
        relay.start()
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                nativeQueue.async {
                    do {
                        try capture.start(onChunk: { pair.continuation.offer($0) }, onStopped: { pair.continuation.finish($0) })
                        done.resume()
                    } catch { capture.stop(); done.resume(throwing: error) }
                }
            }
            guard token == generation, self.epoch == epoch else { throw CancellationError() }
        } catch {
            if self.epoch == epoch { _ = beginStop() }
            await stopTask?.value
            throw error
        }
    }

    private func sourceEnded(epoch: UUID) {
        guard self.epoch == epoch else { return }
        _ = beginStop()
    }

    private func beginStop() -> Task<Void, Never>? {
        if let stopTask { return stopTask }
        generation += 1
        let capture = self.capture, relay = self.relay, observer = self.observer, queue = nativeQueue, source = sourceContinuation
        self.capture = nil; self.relay = nil; self.observer = nil; epoch = nil; sourceContinuation = nil
        delivery.withLock { $0 = nil }
        observer?.cancel()
        let task = Task {
            await withCheckedContinuation { done in queue.async { capture?.stop(drainPending: true); done.resume() } }
            source?.finish(.completed)
            await relay?.finishAndWait()
            await observer?.value
        }
        stopTask = task
        return task
    }
    func stop() async { await beginStop()?.value }
}

final class CaptureHelperListener: NSObject, NSXPCListenerDelegate {
    private let service = CaptureHelperService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = CaptureHelperInterfaces.helper()
        connection.exportedObject = service
        connection.remoteObjectInterface = CaptureHelperInterfaces.client()
        guard let client = connection.remoteObjectProxy as? SpeechRailCaptureHelperClientProtocol else { return false }
        service.attach(client: client)
        connection.invalidationHandler = { [service] in service.stop {} }
        connection.resume()
        return true
    }
}

let listener = NSXPCListener.service()
let delegate = CaptureHelperListener()
listener.delegate = delegate
listener.resume()
