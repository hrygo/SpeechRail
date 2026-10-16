import Foundation
import Synchronization
import Darwin

/// XPC ingress. Native device work and every owned pump are joined before stop replies.
final class CaptureHelperService: @unchecked Sendable {
    let ownership: CaptureConnectionOwnership
    private let runtime: CaptureHelperRuntime
    private let startedAt = Date()

    init() {
        let ownership = CaptureConnectionOwnership()
        self.ownership = ownership
        self.runtime = CaptureHelperRuntime(ownership: ownership)
    }

    func start(owner: UUID, client: SpeechRailCaptureHelperClientProtocol, bundleIDs: [String],
               deviceUID: String?, label: String, epoch: String, reply: @escaping (NSError?) -> Void) {
        guard let epoch = UUID(uuidString: epoch) else {
            reply(NSError(domain: "SpeechRailCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "采集身份或接收端无效。"])); return
        }
        guard ownership.acceptStart(owner) else { reply(staleConnectionError()); return }
        nonisolated(unsafe) let reply = reply
        nonisolated(unsafe) let captureClient = client
        let operation = watchdog(seconds: 45, stage: "start")
        Task {
            defer { _ = operation.claim() }
            do {
                try await runtime.start(owner: owner,
                    configuration: .init(bundleIDs: bundleIDs, outputDeviceUID: deviceUID, name: label), epoch: epoch,
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
            } catch {
                let failure = error as NSError
                NSLog("speechrail_capture_failed status=%ld", failure.code)
                reply(failure)
            }
        }
    }

    func acknowledge(owner: UUID, epoch: String, throughSequence: UInt64) {
        guard ownership.ownsCapture(owner) else { return }
        guard let epoch = UUID(uuidString: epoch) else { runtime.rejectAcknowledgement(); return }
        runtime.acknowledge(epoch: epoch, sequence: throughSequence)
    }
    func stop(owner: UUID, reply: @escaping () -> Void) {
        nonisolated(unsafe) let reply = reply
        Task {
            await runtime.stop(owner: owner)
            reply()
        }
    }
    func invalidate(owner: UUID) {
        ownership.invalidate(owner)
        stop(owner: owner) {}
    }
    func status(owner: UUID, reply: @escaping (String) -> Void) {
        nonisolated(unsafe) let reply = reply
        Task {
            let running = await runtime.isRunning(owner: owner) ? "在采" : "空闲"
            reply("SpeechRailCaptureHelper · \(running) · 已运行 \(Int(Date().timeIntervalSince(startedAt)))s")
        }
    }

    private func staleConnectionError() -> NSError {
        NSError(domain: "com.speechrail.capture", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "音频连接已更新或正在被其他会话使用，请结束已有会话后重试。",
                           "stage": "connection"])
    }

    private func watchdog(seconds: Double, stage: String) -> CaptureOperationGate {
        let operation = CaptureOperationGate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            guard operation.claim() else { return }
            NSLog("speechrail_capture_timeout stage=%@", stage)
            // A synchronous HAL call cannot be canceled safely. The isolated helper
            // owns the private tap resources, so exiting lets HAL reclaim them.
            _exit(70)
        }
        return operation
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
    private let ownership: CaptureConnectionOwnership
    private var owner: UUID?
    private var epoch: UUID?
    private var generation = 0
    private var starting = false

    init(ownership: CaptureConnectionOwnership) { self.ownership = ownership }

    nonisolated func acknowledge(epoch: UUID, sequence: UInt64) {
        delivery.withLock { $0 }?.acknowledge(epoch: epoch, throughSequence: sequence)
    }
    nonisolated func rejectAcknowledgement() { delivery.withLock { $0 }?.requestStop(.sourceLost) }

    func start(owner: UUID, configuration: CoreAudioTapCapture.Configuration, epoch: UUID,
               deliver: @Sendable @escaping (AudioChunk) -> Void,
               stopped: @Sendable @escaping (AudioStreamError) -> Void) async throws {
        guard !starting, capture == nil else { throw AudioStreamError(reason: .sourceLost) }
        starting = true; defer { starting = false }
        generation += 1; let token = generation
        await stopTask?.value
        guard token == generation else { throw CancellationError() }
        stopTask = nil
        guard ownership.acceptStart(owner), ownership.activate(owner) else {
            throw NSError(domain: "com.speechrail.capture", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "音频连接已更新或正在被其他会话使用。", "stage": "connection"])
        }
        let sourceID = UUID()
        let pair = AudioChunkStream.makeStream(epoch: epoch, sourceID: sourceID)
        let control = AsyncStream<AudioStreamTermination>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let capture = CoreAudioTapCapture(configuration: configuration, captureEpoch: epoch, sourceID: sourceID)
        let relay = CaptureAudioRelay(epoch: epoch, stream: pair.stream, deliver: deliver, stopCapture: { reason in
            pair.continuation.finish(reason)
            control.continuation.yield(reason); control.continuation.finish()
        })
        self.owner = owner; self.capture = capture; self.relay = relay
        self.epoch = epoch; self.sourceContinuation = pair.continuation
        delivery.withLock { $0 = relay }
        observer = Task { [weak self] in
            for await reason in control.stream {
                guard !Task.isCancelled else { return }
                stopped(relay.terminalError ?? AudioStreamError(reason: reason, captureEpoch: epoch, sourceID: sourceID))
                await self?.sourceEnded(owner: owner, epoch: epoch)
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
            guard token == generation, self.owner == owner, self.epoch == epoch,
                  ownership.isCurrent(owner) else { throw CancellationError() }
        } catch {
            if self.owner == owner, self.epoch == epoch { _ = beginStop(owner: owner) }
            await stopTask?.value
            throw error
        }
    }

    private func sourceEnded(owner: UUID, epoch: UUID) {
        guard self.owner == owner, self.epoch == epoch else { return }
        _ = beginStop(owner: owner)
    }

    private func beginStop(owner expectedOwner: UUID) -> Task<Void, Never>? {
        guard self.owner == expectedOwner else { return nil }
        if let stopTask { return stopTask }
        generation += 1
        let owner = self.owner
        let capture = self.capture, relay = self.relay, observer = self.observer, queue = nativeQueue, source = sourceContinuation
        self.owner = nil; self.capture = nil; self.relay = nil; self.observer = nil; epoch = nil; sourceContinuation = nil
        delivery.withLock { $0 = nil }
        observer?.cancel()
        let operation = CaptureOperationGate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            guard operation.claim() else { return }
            NSLog("speechrail_capture_timeout stage=cleanup")
            _exit(70)
        }
        let task = Task {
            defer { _ = operation.claim() }
            await withCheckedContinuation { done in queue.async { capture?.stop(drainPending: true); done.resume() } }
            if let owner, self.ownership.ownsCapture(owner) { self.ownership.clearActive() }
            source?.finish(.completed)
            await relay?.finishAndWait()
            await observer?.value
        }
        stopTask = task
        return task
    }
    func stop(owner: UUID) async { await beginStop(owner: owner)?.value }
    func isRunning(owner: UUID) -> Bool { self.owner == owner && capture?.isRunningCapture == true }
}

/// Each XPC connection retains its own callback proxy. No connection can send
/// PCM to another client or release a newer connection's hardware.
private final class CaptureHelperEndpoint: NSObject, SpeechRailCaptureHelperProtocol {
    let owner: UUID
    let service: CaptureHelperService
    let client: SpeechRailCaptureHelperClientProtocol

    init(service: CaptureHelperService, owner: UUID, client: SpeechRailCaptureHelperClientProtocol) {
        self.service = service
        self.owner = owner
        self.client = client
    }

    func start(bundleIDs: [String], deviceUID: String?, label: String, epoch: String,
               reply: @escaping (NSError?) -> Void) {
        service.start(owner: owner, client: client, bundleIDs: bundleIDs,
                      deviceUID: deviceUID, label: label, epoch: epoch, reply: reply)
    }

    func acknowledge(epoch: String, throughSequence: UInt64) {
        service.acknowledge(owner: owner, epoch: epoch, throughSequence: throughSequence)
    }
    func stop(reply: @escaping () -> Void) { service.stop(owner: owner, reply: reply) }
    func status(reply: @escaping (String) -> Void) { service.status(owner: owner, reply: reply) }
}

final class CaptureHelperListener: NSObject, NSXPCListenerDelegate {
    private let service = CaptureHelperService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = CaptureHelperInterfaces.helper()
        connection.remoteObjectInterface = CaptureHelperInterfaces.client()
        guard let client = connection.remoteObjectProxy as? SpeechRailCaptureHelperClientProtocol else { return false }
        let owner = service.ownership.attach()
        connection.exportedObject = CaptureHelperEndpoint(service: service, owner: owner, client: client)
        connection.invalidationHandler = { [service] in service.invalidate(owner: owner) }
        connection.resume()
        return true
    }
}

let listener = NSXPCListener.service()
let delegate = CaptureHelperListener()
listener.delegate = delegate
listener.resume()
