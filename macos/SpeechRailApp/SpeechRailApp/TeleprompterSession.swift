import Foundation
import Observation
import SpeechRailControlKit

@MainActor
@Observable
public final class TeleprompterSession {
    public enum Phase: String, Sendable, Equatable {
        case draft
        case analyzing
        case review
        case ready
        case preparing
        case following
        case paused
        case uncertain
        case manual
        case ended
    }

    public enum BlockReason: Equatable, Sendable {
        case noActiveVersion
        case microphoneDenied
        case serviceNotReady(String)
        case serviceBusy(String)
        case occupiedBy(SessionKind)
        case streamFailed(String)
        case aiUnavailable(String)
        case storeUnavailable(String)

        public var title: String {
            switch self {
            case .noActiveVersion: "还没有可跟读的稿子"
            case .microphoneDenied: "麦克风不可用"
            case .serviceNotReady: "语音识别还没准备好"
            case .serviceBusy: "语音识别正在被其他功能使用"
            case .occupiedBy(let kind): "\(kind.title)正在使用麦克风"
            case .streamFailed: "跟读暂时停了"
            case .aiUnavailable: "AI 整理暂时不可用"
            case .storeUnavailable: "稿子保存失败"
            }
        }

        public var detail: String {
            switch self {
            case .noActiveVersion:
                "先确认一份用于跟读的稿子，或直接按原文分段。"
            case .microphoneDenied:
                "请在系统设置中允许 SpeechRail 使用麦克风，然后再试。你也可以先手动提词。"
            case .serviceNotReady(let message), .serviceBusy(let message), .streamFailed(let message),
                 .aiUnavailable(let message), .storeUnavailable(let message):
                message
            case .occupiedBy(let kind):
                "结束\(kind.title)后才能开始跟读；现在仍可以手动提词。"
            }
        }
    }

    public enum ServiceReadiness: Sendable {
        case ready(profile: String?)
        case notReady(String)
    }

    public private(set) var phase: Phase = .draft
    public private(set) var blocked: BlockReason?
    public private(set) var document: TeleprompterDocument?
    public private(set) var versions: [TeleprompterVersion] = []
    public private(set) var pendingVersion: TeleprompterVersion?
    public private(set) var partialText: String?
    public private(set) var currentSegmentIndex = 0
    public private(set) var uncertainty: Double?
    public private(set) var lastFailure: String?
    public private(set) var readingOffset = 0
    public private(set) var isResuming = false
    public var canEdit: Bool { source == nil && client == nil && phase != .preparing && !isResuming }
    public var isCapturing: Bool { client != nil }

    public var activeVersion: TeleprompterVersion? {
        if let runningVersion { return runningVersion }
        guard let activeID = document?.activeVersionID else { return nil }
        return versions.first { $0.id == activeID }
    }

    public var currentSegment: TeleprompterSegment? {
        guard let segments = activeVersion?.segments, segments.indices.contains(currentSegmentIndex) else {
            return nil
        }
        return segments[currentSegmentIndex]
    }

    public var progressText: String {
        guard let count = activeVersion?.segments.count, count > 0 else { return "未开始" }
        return "第 \(min(currentSegmentIndex + 1, count)) / \(count) 段"
    }

    public var serviceReadiness: (@MainActor () async -> ServiceReadiness)?
    public var audioSourceFactory: @MainActor () -> AudioChunkSource = { MicrophoneCapture() }
    public var aiClient: TeleprompterAIClient?

    private let coordinator: SessionCoordinator
    private let store: TeleprompterStore
    private let port: Int
    private let apiKey: String?
    private var source: AudioChunkSource?
    private var client: RealtimeASRClient?
    private var pump: Task<Void, Never>?
    private var followController = TeleprompterFollowController()
    private var isStoppingIntentionally = false
    private var runningVersion: TeleprompterVersion?
    private var captureGeneration = UUID()
    private var draftGeneration = UUID()

    public init(
        coordinator: SessionCoordinator,
        store: TeleprompterStore,
        port: Int = 8201,
        apiKey: String? = nil,
        audioSourceFactory: (@MainActor () -> AudioChunkSource)? = nil
    ) {
        self.coordinator = coordinator
        self.store = store
        self.port = port
        self.apiKey = apiKey
        if let audioSourceFactory {
            self.audioSourceFactory = audioSourceFactory
        }
    }

    public func listDocuments() throws -> [TeleprompterDocument] {
        try store.listDocuments()
    }

    public func load(documentID: String) throws {
        guard canEdit else { return }
        draftGeneration = UUID()
        let bundle = try store.loadBundle(documentID: documentID)
        document = bundle.document
        versions = bundle.versions
        pendingVersion = nil
        let restoredIndex = bundle.runState.flatMap { state in
            activeVersion?.segments.firstIndex { $0.id == state.currentSegmentID }
        } ?? 0
        currentSegmentIndex = restoredIndex
        followController = TeleprompterFollowController(
            currentIndex: restoredIndex,
            mode: bundle.runState?.mode ?? .manual
        )
        phase = activeVersion == nil ? .draft : .ready
        blocked = nil
    }

    public func createDocument(title: String, sourceText: String) {
        guard canEdit else { return }
        draftGeneration = UUID()
        let now = Date()
        document = TeleprompterDocument(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名稿子" : title,
            sourceText: sourceText,
            createdAt: now,
            updatedAt: now
        )
        versions = []
        pendingVersion = nil
        currentSegmentIndex = 0
        phase = .draft
        blocked = nil
        lastFailure = nil
        persistDraft()
    }

    public func deleteDocument(documentID: String) throws {
        guard canEdit else { return }
        guard phase != .following, phase != .paused, phase != .uncertain else { return }
        try store.deleteDocument(documentID: documentID)
        if document?.id == documentID {
            let remaining = try store.listDocuments()
            if let first = remaining.first {
                try load(documentID: first.id)
            } else {
                document = nil
                versions = []
                pendingVersion = nil
                currentSegmentIndex = 0
                phase = .draft
                blocked = nil
            }
        }
    }

    public func duplicateDocument(documentID: String) throws -> TeleprompterDocument {
        guard canEdit else { throw TeleprompterTextError.invalidAnalysis }
        guard phase != .following, phase != .paused, phase != .uncertain else {
            throw TeleprompterTextError.emptySource
        }
        let newBundle = try store.duplicateDocument(documentID: documentID)
        try load(documentID: newBundle.document.id)
        return newBundle.document
    }

    public func exportMarkdown() -> String? {
        guard let document else { return nil }
        let bundle = TeleprompterDocumentBundle(
            document: document,
            versions: versions,
            runState: nil
        )
        return store.exportMarkdown(bundle)
    }

    public func updateTitle(_ title: String) {
        guard canEdit else { return }
        guard phase != .following, phase != .paused, phase != .uncertain else { return }
        document?.title = title
        document?.updatedAt = Date()
        persistDraft()
    }

    public func updateSourceText(_ sourceText: String) {
        guard canEdit else { return }
        draftGeneration = UUID()
        guard phase != .following, phase != .paused, phase != .uncertain else { return }
        document?.sourceText = sourceText
        document?.updatedAt = Date()
        pendingVersion = nil
        phase = .draft
        persistDraft()
    }

    public func useDeterministicFallback() throws {
        guard canEdit else { return }
        draftGeneration = UUID()
        guard var document else { throw TeleprompterTextError.emptySource }
        let segments = try TeleprompterSegmenter.segment(sourceText: document.sourceText)
        let version = TeleprompterVersion(
            id: UUID().uuidString,
            documentID: document.id,
            sourceText: document.sourceText,
            segments: segments,
            analysisSource: .deterministic
        )
        versions.append(version)
        document.activeVersionID = version.id
        document.updatedAt = Date()
        self.document = document
        pendingVersion = nil
        currentSegmentIndex = 0
        followController = TeleprompterFollowController()
        phase = .ready
        blocked = nil
        try saveBundle()
    }

    public func analyzeDraft(language: String? = nil, style: String? = nil) async {
        guard canEdit, phase != .analyzing else { return }
        guard let document else {
            blocked = .aiUnavailable("请先创建一份稿子。")
            return
        }
        guard let aiClient else {
            blocked = .aiUnavailable("还没有设置 AI 整理服务；你可以直接按原文分段。")
            return
        }
        phase = .analyzing
        let generation = draftGeneration
        blocked = nil
        do {
            let analysis = try await aiClient.analyze(
                TeleprompterAnalysisRequest(
                    sourceText: document.sourceText,
                    language: language,
                    style: style
                )
            )
            guard generation == draftGeneration, self.document?.id == document.id, canEdit else { return }
            pendingVersion = TeleprompterVersion(
                id: UUID().uuidString,
                documentID: document.id,
                sourceText: document.sourceText,
                segments: analysis.segments,
                analysisSource: .ai
            )
            phase = .review
        } catch {
            guard generation == draftGeneration, self.document?.id == document.id, canEdit else { return }
            blocked = .aiUnavailable(Self.aiFailureMessage(for: error))
            phase = .draft
        }
    }

    public func acceptPendingVersion() throws {
        guard canEdit, let pendingVersion, var document,
              pendingVersion.documentID == document.id,
              pendingVersion.sourceText == document.sourceText else {
            throw TeleprompterTextError.invalidAnalysis
        }
        versions.append(pendingVersion)
        document.activeVersionID = pendingVersion.id
        document.updatedAt = Date()
        self.document = document
        self.pendingVersion = nil
        currentSegmentIndex = 0
        followController = TeleprompterFollowController()
        phase = .ready
        blocked = nil
        try saveBundle()
    }

    public func discardPendingVersion() {
        guard canEdit else { return }
        pendingVersion = nil
        phase = activeVersion == nil ? .draft : .ready
    }

    public func updatePendingSegment(id: String, text: String) {
        guard canEdit, let pendingVersion,
              let index = pendingVersion.segments.firstIndex(where: { $0.id == id }) else { return }
        var segments = pendingVersion.segments
        segments[index].text = text
        segments[index].keywords = []
        segments[index].matchPhrases = []
        self.pendingVersion = TeleprompterVersion(
            id: pendingVersion.id,
            documentID: pendingVersion.documentID,
            sourceText: pendingVersion.sourceText,
            segments: segments,
            analysisSource: .user,
            createdAt: pendingVersion.createdAt
        )
    }

    public func beginFollowing() async {
        guard client == nil, phase != .preparing else { return }
        if activeVersion == nil || phase == .draft {
            do { try useDeterministicFallback() }
            catch { blocked = .noActiveVersion; return }
        }
        guard activeVersion != nil else {
            blocked = .noActiveVersion
            phase = .manual
            return
        }
        if let occupancy = coordinator.occupancy, occupancy.kind != .teleprompter {
            blocked = .occupiedBy(occupancy.kind)
            phase = .manual
            return
        }
        blocked = nil
        await coordinator.requestStart(.teleprompter)
    }

    /// SessionCoordinator 的 starter：此时已取得 `.teleprompter` 占用，但还没有持久化记录。
    public func beginCapture() async throws {
        guard client == nil, let activeVersion else { throw Blocked(reason: .noActiveVersion) }
        runningVersion = activeVersion
        draftGeneration = UUID()
        phase = .preparing
        blocked = nil
        lastFailure = nil
        do {
            try await startPipeline()
        } catch {
            runningVersion = nil
            let reason = Self.blockReason(for: error)
            blocked = reason
            phase = .manual
            throw Blocked(reason: reason)
        }
    }

    public func pauseFollowing() {
        guard phase == .following || phase == .uncertain else { return }
        followController.pause()
        syncFollowState()
        phase = .paused
        saveProgress()
    }

    public func resumeFollowing() async {
        guard phase == .paused || phase == .manual || phase == .uncertain else { return }
        guard !isResuming else { return }
        guard let client else { await beginFollowing(); return }
        isResuming = true
        let generation = captureGeneration
        followController.pause()
        defer { isResuming = false }
        do {
            try await client.drainAndClear(timeout: .seconds(8))
        } catch {
            guard generation == captureGeneration else { return }
            await enterManual(.streamFailed("暂时无法恢复跟读，请重新开始。"))
            return
        }
        guard generation == captureGeneration else { return }
        followController.resume()
        syncFollowState()
        phase = .following
        blocked = nil
        saveProgress()
    }

    public func moveToPrevious() {
        guard let count = activeVersion?.segments.count else { return }
        followController.move(to: currentSegmentIndex - 1, segmentCount: count)
        syncFollowState()
        phase = .manual
        saveProgress()
    }

    public func moveToSegment(_ index: Int) {
        guard let count = activeVersion?.segments.count else { return }
        followController.move(to: index, segmentCount: count)
        syncFollowState()
        phase = .manual
        saveProgress()
    }

    public func moveToNext() {
        guard let count = activeVersion?.segments.count else { return }
        followController.move(to: currentSegmentIndex + 1, segmentCount: count)
        syncFollowState()
        phase = .manual
        saveProgress()
    }

    public func resetFollow() async {
        await resumeFollowing()
    }

    public func endFollowing() async {
        if coordinator.occupancy?.kind == .teleprompter {
            await coordinator.stopCapture(endingWith: .user)
        } else {
            await stopCapture()
        }
        phase = .ended
        saveProgress()
    }

    /// SessionCoordinator 的 stopper：停止采集、关闭 ASR、只保存段落进度。
    public func stopCapture() async {
        guard !isStoppingIntentionally else { return }
        isStoppingIntentionally = true
        captureGeneration = UUID()
        source?.stop()
        source = nil
        if let client {
            do {
                try await client.drainAndClear(timeout: .seconds(8))
            } catch {
                lastFailure = error.localizedDescription
            }
            await client.close()
        }
        client = nil
        pump?.cancel()
        pump = nil
        partialText = nil
        followController.resetFollowWindow()
        syncFollowState()
        saveProgress()
        runningVersion = nil
        isStoppingIntentionally = false
    }

    private func startPipeline() async throws {
        if let serviceReadiness {
            switch await serviceReadiness() {
            case .ready:
                break
            case .notReady(let message):
                throw Blocked(reason: .serviceNotReady(message))
            }
        }

        let source = audioSourceFactory()
        self.source = source
        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await source.start()
        } catch {
            self.source = nil
            throw Blocked(reason: Self.blockReason(for: error))
        }

        let client = RealtimeASRClient(
            port: port,
            silenceDurationMilliseconds: 400,
            diarizationEnabled: false,
            apiKey: apiKey
        )
        do {
            try await client.connect()
        } catch {
            source.stop()
            self.source = nil
            throw Blocked(reason: .serviceNotReady(error.localizedDescription))
        }

        self.client = client
        captureGeneration = UUID()
        isStoppingIntentionally = false
        partialText = nil
        uncertainty = nil
        coordinator.sessionDidStartRecording(id: nil)
        followController.resume()
        syncFollowState()
        phase = .following
        startPump(stream: stream, client: client)
    }

    private func startPump(stream: AsyncStream<AudioChunk>, client: RealtimeASRClient) {
        pump?.cancel()
        let generation = captureGeneration
        pump = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await chunk in stream {
                        guard let self else { return }
                        await self.upload(chunk, to: client, generation: generation)
                    }
                }
                group.addTask { [weak self] in
                    let events = await client.events()
                    for await envelope in events {
                        guard let self else { return }
                        await self.handle(envelope, generation: generation)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func upload(_ chunk: AudioChunk, to client: RealtimeASRClient, generation: UUID) async {
        guard generation == captureGeneration, !isStoppingIntentionally,
              !isResuming, followController.mode == .following else { return }
        do {
            try await client.append(chunk.pcm)
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    private func handle(
        _ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>, generation: UUID
    ) async {
        guard generation == captureGeneration, !isStoppingIntentionally else { return }
        switch envelope.payload {
        case .partial(let itemID, let delta):
            guard !isResuming, let activeVersion else { return }
            followController.receivePartial(itemID: itemID, delta: delta, segments: activeVersion.segments)
            syncFollowState()
        case .completed(let itemID, let transcript, _):
            guard !isResuming, let activeVersion else { return }
            followController.receiveCompleted(
                itemID: itemID, transcript: transcript,
                segments: activeVersion.segments
            )
            syncFollowState()
            if followController.mode == .following {
                phase = uncertainty == nil ? .following : .uncertain
            }
        case .serverError(let code, let message, _, _, _, _):
            if code == "backend_busy" {
                await enterManual(.serviceBusy(message))
            } else {
                lastFailure = message
            }
        case .failed(_, let code, let message):
            await enterManual(.streamFailed("\(code)：\(message)"))
        case .closed:
            if !isStoppingIntentionally {
                await enterManual(.streamFailed("Realtime 连接已断开，可以手动继续或重试。"))
            }
        default:
            break
        }
    }

    private func enterManual(_ reason: BlockReason) async {
        captureGeneration = UUID()
        source?.stop()
        source = nil
        await client?.close()
        client = nil
        pump?.cancel()
        pump = nil
        followController.enterManual()
        syncFollowState()
        blocked = reason
        phase = .manual
        saveProgress()
        runningVersion = nil
    }

    private func syncFollowState() {
        currentSegmentIndex = followController.currentIndex
        readingOffset = followController.position.utf16Offset
        partialText = followController.partialPreview
        uncertainty = followController.uncertainty
    }

    private func saveProgress() {
        guard let document, let activeVersion else { return }
        do {
            try store.updateRunState(
                TeleprompterRunState(
                    documentID: document.id,
                    versionID: activeVersion.id,
                    currentSegmentID: currentSegment?.id,
                    mode: followController.mode
                )
            )
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    private func saveBundle() throws {
        guard let document else { throw TeleprompterStoreError.invalidBundle }
        try store.saveBundle(
            TeleprompterDocumentBundle(
                document: document,
                versions: versions,
                runState: nil
            )
        )
    }

    private func persistDraft() {
        do { try saveBundle() }
        catch { blocked = .storeUnavailable("稿子暂时没能保存，请稍后重试。") }
    }

    private static func blockReason(for error: Error) -> BlockReason {
        if let failure = error as? MicrophoneCapture.Failure, failure == .permissionDenied {
            return .microphoneDenied
        }
        if let blocked = error as? Blocked { return blocked.reason }
        return .serviceNotReady(error.localizedDescription)
    }

    private static func aiFailureMessage(for error: Error) -> String {
        if let error = error as? LLMError,
           error == .unsupportedStructuredOutput {
            return "当前 AI 服务暂时无法整理这份稿子。请在设置中更换 AI 服务，或直接按原文分段；原稿没有变化。"
        }
        return "AI 暂时没能整理这份稿子，原稿没有变化。你可以重试，或直接按原文分段。"
    }

    private struct Blocked: Error {
        let reason: BlockReason
    }
}
