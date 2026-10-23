import Foundation

/// T17：跨作品制作队列。队列是 macOS 调用方的调度层，架在
/// `AudiobookProductionController` 之上：它只认识「一份已确认的制作计划」，
/// 不认识片段怎么渲染、音频提交到哪个库、服务端有哪些任务。因此同一个队列
/// 可以换成配音台执行器，而不必改动调度、持久化与恢复语义。
public enum AudiobookProductionQueueError: LocalizedError, Equatable, Sendable {
    case duplicateBook
    case itemNotFound(UUID)
    case itemNotQueued(UUID)
    case itemNotActive(UUID)
    case itemNotInterrupted(UUID)
    case reorderMismatch
    case emptyPlan
    case planBookMismatch
    case queueNotPaused
    case nothingToRetry
    case persistenceFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .duplicateBook:
            return "这部作品已经有一个没结束的队列项了。等它完成、失败或取消后再重新入队。"
        case .itemNotFound:
            return "这个队列项已经不在队列里了。"
        case .itemNotQueued:
            return "只有还没开始的队列项可以调整顺序。"
        case .itemNotActive:
            return "这一项当前没有在运行，不能取消。"
        case .itemNotInterrupted:
            return "这一项没有待核对的终态。"
        case .reorderMismatch:
            return "调整顺序需要给出全部未开始项，且不能重复。"
        case .emptyPlan:
            return "这份制作预览里没有需要生成的片段。"
        case .planBookMismatch:
            return "制作预览和作品对不上，请重新预览。"
        case .queueNotPaused:
            return "队列没有暂停。"
        case .nothingToRetry:
            return "没有失败的队列项可以重试。"
        case let .persistenceFailed(reason):
            return "队列记录保存失败：\(reason)。已入队的内容仍在本次运行中有效，但重启后可能丢失。"
        }
    }
}

/// 产品状态。队列一次只运行一项，所以 `running` 至多属于一个队列项。
public enum AudiobookProductionQueueItemState: String, Codable, Equatable, Hashable, Sendable {
    /// 等待轮到。
    case queued
    /// 正在制作。
    case running
    /// 已开始但被别处的语音占用卡住（服务忙、准入被占），仍在重试窗口内。
    case waiting
    /// 已暂停或已取消。已提交的片段与检查点都保留，可继续。
    case paused
    /// 失败，带原因。需要用户明确重试，队列不会自己往下走。
    case failed
    /// 已完成。
    case completed
    /// App 上次退出时这一项还在跑，终态未经确认。等用户明确继续。
    case interrupted

    /// 这些状态各自占着一个「未结束」的名额：同一时刻同一部作品只能有一项。
    public var occupiesBook: Bool {
        switch self {
        case .queued, .running, .waiting, .paused, .interrupted: true
        case .failed, .completed: false
        }
    }
}

/// 一个队列项引用的是**冻结**的制作预览：章节范围、片段与依赖摘要都在入队时
/// 定死。执行前由执行器重新核对正文、声音与模型身份，条件变了就停在这一项，
/// 不会悄悄按新条件做下去。
public struct AudiobookProductionQueueItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bookID: UUID
    public var title: String
    public var plan: AudiobookProductionPlan
    public var state: AudiobookProductionQueueItemState
    public var failureReason: String?
    public var enqueuedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// 最近一次尝试的任务身份。重试时交给执行器，让已提交片段被复用而不是重新合成。
    public var lastTaskID: UUID?

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        title: String,
        plan: AudiobookProductionPlan,
        state: AudiobookProductionQueueItemState = .queued,
        failureReason: String? = nil,
        enqueuedAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        lastTaskID: UUID? = nil
    ) {
        self.id = id
        self.bookID = bookID
        self.title = title
        self.plan = plan
        self.state = state
        self.failureReason = failureReason
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastTaskID = lastTaskID
    }

    public var isLive: Bool { state.occupiesBook }
}

/// 队列计划整体持久化。schema 用于拒绝看不懂的旧/新格式，而不是猜。
public struct AudiobookProductionQueuePlan: Codable, Equatable, Sendable {
    public static let schema = "audiobook_production_queue_v1"

    public var schema: String
    public var items: [AudiobookProductionQueueItem]
    public var updatedAt: Date

    public init(schema: String = AudiobookProductionQueuePlan.schema, items: [AudiobookProductionQueueItem], updatedAt: Date = Date()) {
        self.schema = schema
        self.items = items
        self.updatedAt = updatedAt
    }

    public static let empty = AudiobookProductionQueuePlan(items: [])

    public var queuedItems: [AudiobookProductionQueueItem] { items.filter { $0.state == .queued } }
    public var activeItem: AudiobookProductionQueueItem? { items.first { $0.state == .running || $0.state == .waiting } }
    public var failedItems: [AudiobookProductionQueueItem] { items.filter { $0.state == .failed } }
    public var interruptedItems: [AudiobookProductionQueueItem] { items.filter { $0.state == .interrupted } }
    public var hasPendingWork: Bool { items.contains { $0.state == .queued || $0.state == .interrupted } }
}

/// 队列对一次制作尝试的全部了解。窄到配音台可以原样复用。
public struct AudiobookProductionQueueRequest: Sendable, Equatable {
    public var itemID: UUID
    public var plan: AudiobookProductionPlan
    /// 非空表示这一尝试接着上一次继续，已提交片段应被复用。
    public var continuesTaskID: UUID?

    public init(itemID: UUID, plan: AudiobookProductionPlan, continuesTaskID: UUID?) {
        self.itemID = itemID
        self.plan = plan
        self.continuesTaskID = continuesTaskID
    }
}

public struct AudiobookProductionQueueOutcome: Sendable, Equatable {
    /// 本次尝试的任务身份，队列记下来供后续重试续跑。
    public var taskID: UUID?
    public var completedFragments: Int
    public var reusedFragments: Int
    /// 非空表示在途片段的**服务端**停止状态始终没确认。此时队列不得自行开始下一项。
    public var unconfirmedRemoteStopFragmentID: UUID?
    /// 用户请求停止后的正常收尾。这不是失败：已提交片段和检查点都还在，
    /// 但这一项不算完成，队列也停在这里等用户明确恢复。
    public var stoppedByRequest: Bool

    public init(
        taskID: UUID? = nil,
        completedFragments: Int = 0,
        reusedFragments: Int = 0,
        unconfirmedRemoteStopFragmentID: UUID? = nil,
        stoppedByRequest: Bool = false
    ) {
        self.taskID = taskID
        self.completedFragments = completedFragments
        self.reusedFragments = reusedFragments
        self.unconfirmedRemoteStopFragmentID = unconfirmedRemoteStopFragmentID
        self.stoppedByRequest = stoppedByRequest
    }
}

/// 窄执行接口。队列只要求「把一份计划做到终态」与「让在跑的那次停下来」，
/// 并且**必须等到 `execute` 真正返回**才认为资源已释放——这就是停止屏障：
/// 下一项不会在当前项确认收尾前开始。
public protocol AudiobookProductionQueueExecutor: Sendable {
    func execute(_ request: AudiobookProductionQueueRequest) async throws -> AudiobookProductionQueueOutcome
    /// 刚结束的那次尝试的任务身份。失败时同样要能取到，否则重试只能从零开始，
    /// 已经提交的片段会被重新合成。
    func lastAttemptTaskID(for bookID: UUID) async -> UUID?
    /// 请求停止在跑的那一次。实现必须尽快让 `execute` 返回，且不得越权释放
    /// 不属于本次制作的资源（会议、字幕、配音台的占用照旧归它们自己）。
    func cancelActive() async
}

public enum AudiobookProductionQueueStoreError: LocalizedError, Equatable, Sendable {
    case unreadable(reason: String)
    case unsupportedSchema(String)
    case atomicWriteFailed

    public var errorDescription: String? {
        switch self {
        case let .unreadable(reason):
            return "队列记录读不出来：\(reason)。请先备份或移除队列记录文件再打开队列。"
        case let .unsupportedSchema(schema):
            return "队列记录格式不被这个版本支持，原文件没有被改动。"
        case .atomicWriteFailed:
            return "队列记录保存失败，上一份记录仍然保留。"
        }
    }
}

/// 队列计划持久化。默认实现是单个 JSON 文件的原子替换：保存中途崩溃，
/// 上一份计划完整留下，不会出现半份队列。
public protocol AudiobookProductionQueuePersisting: Sendable {
    func load() throws -> AudiobookProductionQueuePlan?
    func save(_ plan: AudiobookProductionQueuePlan) throws
}

/// 文件实现用一把锁串行化读写。队列是 actor，存盘发生在它的执行器之外，
/// 因此并发保存必须自己排序，否则两份临时文件会互相替换。
public final class AudiobookProductionQueueFileStore: AudiobookProductionQueuePersisting, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(rootURL: URL, fileName: String = "production-queue.json") {
        self.fileURL = rootURL.appendingPathComponent(fileName, isDirectory: false)
    }

    public func load() throws -> AudiobookProductionQueuePlan? {
        lock.lock()
        defer { lock.unlock() }
        // 没有记录文件就是空队列，不是错误。
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw AudiobookProductionQueueStoreError.unreadable(reason: error.localizedDescription)
        }
        do {
            let plan = try JSONDecoder().decode(AudiobookProductionQueuePlan.self, from: data)
            guard plan.schema == AudiobookProductionQueuePlan.schema else {
                throw AudiobookProductionQueueStoreError.unsupportedSchema(plan.schema)
            }
            return plan
        } catch let error as AudiobookProductionQueueStoreError {
            throw error
        } catch {
            throw AudiobookProductionQueueStoreError.unreadable(reason: error.localizedDescription)
        }
    }

    public func save(_ plan: AudiobookProductionQueuePlan) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(plan)
        } catch {
            throw AudiobookProductionQueueStoreError.unreadable(reason: error.localizedDescription)
        }
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw AudiobookProductionQueueStoreError.atomicWriteFailed
        }
    }
}

public actor AudiobookProductionQueue {
    private let executor: any AudiobookProductionQueueExecutor
    private let persistence: any AudiobookProductionQueuePersisting
    private let clock: any AudiobookClock

    private var plan: AudiobookProductionQueuePlan
    private var loopTask: Task<Void, Never>?
    private var activeItemID: UUID?
    /// 用户要求停在当前项。只在 `execute` 返回**之后**读取，从不用来打断等待——
    /// 取消必须等本项实际收尾，这是停止屏障的一部分。
    private var activeStopRequested = false
    private var isPaused = false

    public init(
        executor: any AudiobookProductionQueueExecutor,
        persistence: any AudiobookProductionQueuePersisting,
        clock: any AudiobookClock = SystemAudiobookClock(),
        restoredPlan: AudiobookProductionQueuePlan? = nil
    ) {
        self.executor = executor
        self.persistence = persistence
        self.clock = clock
        var restored = restoredPlan ?? .empty
        // 上次退出时还在跑的项没有已确认的终态。标成「待核对」，绝不自动续跑：
        // 打开 App 不得自行恢复采集、加载模型或更换档位。
        for index in restored.items.indices
        where restored.items[index].state == .running || restored.items[index].state == .waiting {
            restored.items[index].state = .interrupted
            restored.items[index].failureReason = "App 上次退出时这一项还在制作，终态尚未确认。请核对后再继续。"
            restored.items[index].finishedAt = nil
        }
        self.plan = restored
    }

    // MARK: - 读取

    public func snapshot() -> AudiobookProductionQueuePlan { plan }

    public func isQueuePaused() -> Bool { isPaused }

    public func activeQueueItemID() -> UUID? { activeItemID }

    public func item(id: UUID) -> AudiobookProductionQueueItem? { plan.items.first { $0.id == id } }

    // MARK: - 入队

    /// 入队一份已确认的制作预览。同一部作品同时只允许一个未结束项，
    /// 因此重复入队是明确拒绝，而不是默默排两次。
    public func enqueue(bookID: UUID, title: String, plan: AudiobookProductionPlan) throws {
        guard plan.bookID == bookID else { throw AudiobookProductionQueueError.planBookMismatch }
        guard !plan.fragments.isEmpty else { throw AudiobookProductionQueueError.emptyPlan }
        if self.plan.items.contains(where: { $0.bookID == bookID && $0.state.occupiesBook }) {
            throw AudiobookProductionQueueError.duplicateBook
        }
        self.plan.items.append(AudiobookProductionQueueItem(
            bookID: bookID, title: title, plan: plan, enqueuedAt: clock.now()
        ))
        try persist()
        startLoopIfNeeded()
    }

    /// 取消一个还没开始的队列项：它没有产物也没有检查点，直接离开队列。
    public func removeQueued(itemID: UUID) throws {
        guard let index = plan.items.firstIndex(where: { $0.id == itemID }) else {
            throw AudiobookProductionQueueError.itemNotFound(itemID)
        }
        guard plan.items[index].state == .queued else { throw AudiobookProductionQueueError.itemNotQueued(itemID) }
        plan.items.remove(at: index)
        try persist()
    }

    /// 调整未开始项的顺序。必须给出**全部**未开始项的一个排列，
    /// 避免「相对第几个」这种靠猜的接口。
    public func reorder(queuedIDs: [UUID]) throws {
        let current = Set(plan.queuedItems.map(\.id))
        guard Set(queuedIDs) == current, queuedIDs.count == current.count else {
            throw AudiobookProductionQueueError.reorderMismatch
        }
        let ordered = queuedIDs.compactMap { id in plan.items.first { $0.id == id } }
        var remaining = ordered.makeIterator()
        plan.items = plan.items.map { item in
            guard item.state == .queued else { return item }
            return remaining.next() ?? item
        }
        try persist()
    }

    // MARK: - 运行控制

    public func start() throws {
        guard plan.hasPendingWork else { throw AudiobookProductionQueueError.emptyPlan }
        isPaused = false
        try persist()
        startLoopIfNeeded()
    }

    /// 暂停整条队列。若当前有项在跑，先请求停止并**等它实际收尾**，
    /// 再把它标成已暂停；不确定服务端停止状态时同样停在这里。
    public func pause() async throws {
        isPaused = true
        if activeItemID != nil {
            activeStopRequested = true
            await executor.cancelActive()
            await loopTask?.value
        }
        try persist()
    }

    public func resume() throws {
        guard isPaused else { throw AudiobookProductionQueueError.queueNotPaused }
        isPaused = false
        try persist()
        startLoopIfNeeded()
    }

    /// 取消单项。跑着的那项会等收尾后标为已暂停（不冒充完成），
    /// 并且队列随之停住，由用户决定是否继续剩下的项。
    public func cancelItem(itemID: UUID) async throws {
        guard let index = plan.items.firstIndex(where: { $0.id == itemID }) else {
            throw AudiobookProductionQueueError.itemNotFound(itemID)
        }
        switch plan.items[index].state {
        case .queued:
            // 还没开始：没有产物也没有检查点，直接离开队列。
            plan.items.remove(at: index)
            try persist()
        case .running, .waiting:
            // 在跑：请求停止并等它实际收尾，再标成已暂停。队列随之停住，
            // 剩下的项等用户明确恢复——不偷偷接着做。
            isPaused = true
            activeStopRequested = true
            await executor.cancelActive()
            await loopTask?.value
            try persist()
        default:
            throw AudiobookProductionQueueError.itemNotActive(itemID)
        }
    }

    /// 只重试失败项。失败项回到未开始，队列从最前面那个未开始项继续；
    /// 已完成的项不动，它们已提交的音频也不会被重新合成。
    public func retryFailedItems() throws {
        guard plan.items.contains(where: { $0.state == .failed }) else {
            throw AudiobookProductionQueueError.nothingToRetry
        }
        for index in plan.items.indices where plan.items[index].state == .failed {
            plan.items[index].state = .queued
            plan.items[index].failureReason = nil
            plan.items[index].finishedAt = nil
        }
        isPaused = false
        try persist()
        startLoopIfNeeded()
    }

    /// 用户核对过重启后中断的项，明确让它继续。队列本身不会自动做这件事。
    public func confirmInterrupted(itemID: UUID) throws {
        guard let index = plan.items.firstIndex(where: { $0.id == itemID }) else {
            throw AudiobookProductionQueueError.itemNotFound(itemID)
        }
        guard plan.items[index].state == .interrupted else {
            throw AudiobookProductionQueueError.itemNotInterrupted(itemID)
        }
        plan.items[index].state = .queued
        plan.items[index].failureReason = nil
        try persist()
        startLoopIfNeeded()
    }

    /// App 退出前的收尾：请求停止并等当前项落地，不留下「看起来还在跑」的记录。
    public func shutdown() async {
        isPaused = true
        if activeItemID != nil {
            activeStopRequested = true
            await executor.cancelActive()
            await loopTask?.value
        }
        _ = try? persist()
    }

    // MARK: - 调度循环

    private func startLoopIfNeeded() {
        guard loopTask == nil || loopTask?.isCancelled == true else { return }
        guard !isPaused else { return }
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    private func loop() async {
        defer { loopTask = nil }
        while !Task.isCancelled {
            guard !isPaused else { return }
            guard let index = plan.items.firstIndex(where: { $0.state == .queued }) else { return }
            let item = plan.items[index]

            // 在第一次 await 之前占住这一项，避免并发入队/重试造成第二个执行身份。
            plan.items[index].state = .running
            plan.items[index].startedAt = clock.now()
            plan.items[index].finishedAt = nil
            plan.items[index].failureReason = nil
            activeItemID = item.id
            do { try persist() } catch { /* 记录仍在内存里，运行不中断 */ }

            let request = AudiobookProductionQueueRequest(
                itemID: item.id, plan: item.plan, continuesTaskID: item.lastTaskID
            )
            let outcome: AudiobookProductionQueueOutcome
            do {
                outcome = try await executor.execute(request)
            } catch {
                await finishFailed(itemID: item.id, error: error)
                return
            }
            let stopRequested = activeStopRequested
            activeStopRequested = false
            await finish(itemID: item.id, outcome: outcome, stopRequested: stopRequested)
            // 用户取消、或服务端停止状态未确认：队列停在这一项，不自行开始下一项。
            if plan.items.first(where: { $0.id == item.id })?.state == .paused { return }
        }
    }

    private func finishFailed(itemID: UUID, error: Error) async {
        defer { activeItemID = nil }
        guard let index = plan.items.firstIndex(where: { $0.id == itemID }) else { return }
        // 失败也要记下这次尝试的任务身份，重试才接得上同一次跑。
        if let taskID = await executor.lastAttemptTaskID(for: plan.items[index].bookID) {
            plan.items[index].lastTaskID = taskID
        }
        plan.items[index].state = .failed
        plan.items[index].failureReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        plan.items[index].finishedAt = clock.now()
        do { try persist() } catch { /* 下一项不会自动开始，用户重试时会再存一次 */ }
    }

    private func finish(itemID: UUID, outcome: AudiobookProductionQueueOutcome, stopRequested: Bool) async {
        defer { activeItemID = nil }
        guard let index = plan.items.firstIndex(where: { $0.id == itemID }) else { return }
        if let taskID = outcome.taskID { plan.items[index].lastTaskID = taskID }
        plan.items[index].finishedAt = clock.now()
        if stopRequested || outcome.stoppedByRequest || outcome.unconfirmedRemoteStopFragmentID != nil {
            plan.items[index].state = .paused
            plan.items[index].failureReason = outcome.unconfirmedRemoteStopFragmentID != nil
                ? "在途片段的停止状态尚未确认，继续前请先核对。"
                : "已取消。"
            // 队列停住：剩下的项等用户明确恢复。
            isPaused = true
        } else {
            plan.items[index].state = .completed
            plan.items[index].failureReason = nil
        }
        do { try persist() } catch { /* 状态已在内存里生效，保存失败只影响重启后可见性 */ }
    }

    private func persist() throws {
        plan.updatedAt = clock.now()
        try persistence.save(plan)
    }
}
