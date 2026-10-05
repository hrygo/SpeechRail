import Foundation
import Observation

/// 会议知识库的列表与详情状态（MA-12）。
///
/// **选择代次**是这个类型存在的理由（MC-50）：
/// 用户从 A 切到 B，A 的详情可能还在读；等它回来的时候，
/// 如果直接写进界面，B 的标题就会配上 A 的正文。
/// 所以每次选中都会给一个代次号，读回来的结果**代次对不上就丢掉**。
@MainActor
@Observable
public final class MeetingLibraryModel {
    /// 列表当前显示的行。**分页取数，不是只取最近几场**（MC-52）。
    public private(set) var rows: [MeetingLibraryRow] = []
    public private(set) var counts: MeetingLibraryCounts = .zero
    public private(set) var isLoadingList = false
    public private(set) var listError: String?

    /// 当前选中的文档。选中 ≠ 活动会议：查看历史时正在录的那场仍然在跑。
    public private(set) var selectedDocumentID: String?
    public private(set) var snapshot: MeetingReviewSnapshot?
    public private(set) var isLoadingDetail = false
    public private(set) var detailError: String?

    /// 当前页。翻页位置要能恢复，否则每次回来都要从头翻。
    public var offset: Int = 0
    public var limit: Int = 50
    public private(set) var query: String = ""
    public private(set) var projectID: String?

    /// 是否把已归档的会议也列出来。默认**不**列——归档的意义就是"搜索、导出、
    /// 问答都看不见它"。
    ///
    /// 但用户必须能在需要时把它找回来：撤不了归档，「可撤销」就是一句空话。
    /// 所以这个开关是"把归档件也摆出来看看"，不是"把归档件恢复成可用"——
    /// 撤销要走详情里的动作，语义不同。
    public private(set) var includesArchived = false

    /// 详情页签：纪要 / 转录。真正切换，不是两个都堆在一起。
    public enum DetailTab: String, CaseIterable, Hashable {
        case minutes
        case transcript

        public var title: String {
            switch self {
            case .minutes: "纪要"
            case .transcript: "转录"
            }
        }
    }
    public var detailTab: DetailTab = .minutes

    /// 只依赖 `SessionCoordinator`——界面不直接持有 `SessionStore`（§5.1 的缝）。
    private let coordinator: SessionCoordinator
    /// 每次选中 +1。读回来的结果代次对不上就丢弃。
    private var generation: Int = 0
    /// 列表也用代次：搜索词连着改两次，先发的那次回来不能覆盖后一次。
    private var listGeneration: Int = 0

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    public var hasMore: Bool { offset + rows.count < counts.total }

    /// 当前选中那一场的会话 id。核对视图要靠它找到"当前该看哪一版"。
    public var selectedSessionID: String? {
        rows.first { $0.id == selectedDocumentID }?.sessionID
    }

    /// 冷启动直接打开某场历史纪要（MC-48）。没服务也能读：全部走本地库。
    public func open(documentID: String) async {
        selectedDocumentID = documentID
        await loadDetail()
    }

    public func reload() async {
        await loadPage(offset: offset)
        await loadOpenItems(offset: 0)
        await loadConflicts()
    }

    public func search(_ text: String) async {
        query = text
        await loadPage(offset: 0)
    }

    public func filter(projectID: String?) async {
        self.projectID = projectID
        await loadPage(offset: 0)
        await loadOpenItems(offset: 0)
        await loadConflicts()
    }

    /// 切换"连归档件一起列"。回到第一页：归档件可能在任意位置，
    /// 停在原来的偏移上会落到一个空页面上。
    public func setIncludesArchived(_ includes: Bool) async {
        guard includesArchived != includes else { return }
        includesArchived = includes
        await loadPage(offset: 0)
        await loadOpenItems(offset: 0)
    }

    public func loadPage(offset: Int) async {
        listGeneration += 1
        let generation = listGeneration
        isLoadingList = true
        listError = nil
        do {
            let page = try await coordinator.meetingLibraryPage(
                query: query, projectID: projectID,
                includesArchived: includesArchived, limit: limit, offset: offset
            )
            guard generation == listGeneration else { return }  // 已经有更新的查询了
            rows = page.rows
            counts = page.counts
            self.offset = offset
            isLoadingList = false
        } catch {
            guard generation == listGeneration else { return }
            listError = error.localizedDescription
            isLoadingList = false
        }
    }

    public func loadMore() async {
        guard hasMore, !isLoadingList else { return }
        await loadPage(offset: offset + limit)
    }

    public func select(_ documentID: String?) async {
        let generation = beginSelection(documentID)
        guard let documentID else { return }
        do {
            let loaded = try await coordinator.meetingReviewSnapshot(documentID: documentID)
            commitDetail(loaded, generation: generation)
        } catch {
            commitDetailError(error.localizedDescription, generation: generation)
        }
    }

    /// 开始一次选中。**返回的代次号要交给 `commitDetail`**。
    ///
    /// 拆成两步是为了能**确定性地**测"迟到的结果不写进界面"：
    /// 靠两个并发任务赛跑来验证，测出来的通过与否取决于机器快慢。
    @discardableResult
    public func beginSelection(_ documentID: String?) -> Int {
        generation += 1
        selectedDocumentID = documentID
        snapshot = nil
        detailError = nil
        isLoadingDetail = documentID != nil
        return generation
    }

    /// 代次对不上就**直接丢掉**：A 的迟到结果不能覆盖已经切过去的 B（MC-50）。
    public func commitDetail(_ loaded: MeetingReviewSnapshot?, generation: Int) {
        guard generation == self.generation else { return }
        snapshot = loaded
        isLoadingDetail = false
    }

    public func commitDetailError(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        detailError = message
        isLoadingDetail = false
    }

    /// 当前代次。测试用它确认守卫确实在工作，而不是碰巧没写。
    public var currentGeneration: Int { generation }

    private func loadDetail() async {
        await select(selectedDocumentID)
        // 标签跟着选中的文档走：切到另一场就该是另一场的标签，
        // 留着上一场的标签等于把 A 的标签贴到 B 上。
        if let documentID = selectedDocumentID {
            documentTags = await tags(for: documentID)
            await loadChangeProposals(documentID: documentID)
        } else {
            documentTags = []
            changeProposals = []
        }
    }

    // MARK: - 这一版可能变了什么（MC-54 / MA-14）

    /// 当前选中的那一场，重新生成之后**可能**变了什么。
    ///
    /// 与详情里的正文对比不是一回事：正文对比回答"我这次改了什么"（行级），
    /// 这里回答"重新生成把哪条结论换掉了"（条目级，按相似度跨版本配对）。
    public private(set) var changeProposals: [KnowledgeChangeProposal] = []

    /// 读候选差异。**失败不是大事**：读不到就说读不到，不清空成"没有变化"——
    /// 两者对用户的含义完全不同。
    public func loadChangeProposals(documentID: String) async {
        do {
            changeProposals = try await coordinator.knowledgeChangeProposals(documentID: documentID)
            changeProposalsError = nil
        } catch {
            changeProposals = []
            changeProposalsError = error.localizedDescription
        }
    }

    public private(set) var changeProposalsError: String?

    public var changeProposalsHeadline: String {
        changeProposals.isEmpty
            ? "这一版可能变了什么"
            : "这一版可能变了什么（\(changeProposals.count) 处）"
    }

    /// 读失败时的提示。**只有读失败才说话**：没重新生成过就是没有，
    /// 界面不摆这一段，不必为常态噪声占地方。
    public var changeProposalsHint: String? {
        guard let error = changeProposalsError else { return nil }
        return "\(error)。暂时看不出这一版改了什么。"
    }

    /// 空态文案。**说清下一步做什么**，不写"暂无数据"。
    public var emptyStateHint: String {
        if !query.isEmpty { return "没有匹配「\(query)」的会议，换个词或清空搜索。" }
        if counts.total == 0 { return "还没有整理过的会议。录一场，或导入一份纪要。" }
        return "往后翻还有 \(max(0, counts.total - rows.count)) 场。"
    }

    // MARK: - 归档与删除（MA-18）

    /// 正在执行删除或撤销的文档 id。非空时那一行的动作禁用，避免连点两次。
    public private(set) var pendingDocumentID: String?
    /// 最近一次删除的结论。成功时带着**具体数目**。
    public private(set) var lastReport: MeetingDeletionReport?
    /// 最近一次撤销归档的结果。`false` 表示这份文档不是归档态，撤不了。
    public private(set) var lastRestore: Bool?
    public private(set) var archiveError: String?
    /// 项目与标签操作失败时的提示。与 `archiveError` 分开：
    /// 「这场会归不了项目」和「这场会删不掉」对应的下一步动作完全不同。
    public private(set) var projectError: String?
    /// 当前选中那一场的标签。详情里的标签编辑改它。
    public private(set) var documentTags: [String] = []

    /// 这一档要不要用户亲自确认。
    ///
    /// 判定放在模型而不是各个按钮里：三档删除散在三个入口各自判断的话，
    /// 迟早会有一处把不可撤销的那档也放过去。界面的责任只是把确认面板摆出来。
    public static func requiresConfirmation(_ mode: MeetingDeletionMode) -> Bool {
        !mode.isRecoverable
    }

    /// 三档删除（MA-18 / MC-43、MC-44、MC-62）。
    ///
    /// 失败**不吞**：出错时 `archiveError` 有话，界面照原样留在这一场，
    /// 库里一个字节都没变（删除是单事务的）。静默失败会让用户以为删掉了。
    public func delete(_ documentID: String, mode: MeetingDeletionMode) async {
        pendingDocumentID = documentID
        archiveError = nil
        lastReport = nil
        lastRestore = nil
        do {
            let report = try await coordinator.deleteMeetingKnowledge(
                documentID: documentID, mode: mode
            )
            lastReport = report
            pendingDocumentID = nil
            // 刚动过这一场，还开着它的详情就不成立了——留着会让人对着一个已经归档
            // 或已删的会议读纪要，读到的是一份已经不参与检索与导出的内容。
            if selectedDocumentID == documentID { await select(nil) }
            await loadPage(offset: offset)
        } catch {
            archiveError = error.localizedDescription
            pendingDocumentID = nil
        }
    }

    /// 撤销归档。**只对 `.archive` 有意义**，另两档数据已经不在库里。
    @discardableResult
    public func restore(_ documentID: String) async -> Bool {
        pendingDocumentID = documentID
        archiveError = nil
        lastReport = nil
        do {
            let restored = try await coordinator.restoreMeetingKnowledge(documentID: documentID)
            lastRestore = restored
            pendingDocumentID = nil
            await loadPage(offset: offset)
            return restored
        } catch {
            archiveError = error.localizedDescription
            pendingDocumentID = nil
            lastRestore = false
            return false
        }
    }

    /// 导出当前选中的那一场（MA-19 / 验收 4「导出已有资料」）。
    ///
    /// 钉住详情正在显示的那一版纪要（MC-48）：用户看的是哪一版，
    /// 导出去就得是哪一版。返回 nil 表示**这场导不出**——导入的纪要
    /// 没有会话、没有转录行可导，硬凑一个空壳比老实说导不出更坏。
    public func exportPayload() async throws -> SessionExportPayload? {
        guard let documentID = selectedDocumentID else { return nil }
        return try await coordinator.meetingExportPayload(
            documentID: documentID,
            minutesVersionID: snapshot?.minutesVersionID
        )
    }

    // MARK: - 项目与标签（MA-13）
    //
    // 项目、标签都是**用户写的**，导入与生成都不猜（方案 MA-13）。
    // 此前这三个 API 生产代码零消费方：项目筛选用不了、标签加不上、
    // 连"这场会属于哪个项目"都没地方改。

    /// 全部项目。筛选菜单的数据源；空库时是空的，不影响浏览。
    public private(set) var projects: [MeetingProject] = []

    public func loadProjects() async {
        projects = (try? await coordinator.meetingProjects()) ?? []
    }

    /// 新建项目。**空名拒绝**——项目是筛选依据，空名筛不出任何东西。
    @discardableResult
    public func createProject(named name: String) async -> MeetingProject? {
        do {
            let project = try await coordinator.createMeetingProject(name: name)
            await loadProjects()
            return project
        } catch {
            projectError = error.localizedDescription
            return nil
        }
    }

    public func renameProject(id: String, to name: String) async {
        do {
            try await coordinator.renameMeetingProject(id: id, name: name)
            await loadProjects()
            await loadPage(offset: offset)
        } catch {
            projectError = error.localizedDescription
        }
    }

    /// 把这一场归到某个项目，或移出项目（`nil`）。
    ///
    /// 改完要重载列表：项目名显示在行上，不重载用户会以为没生效。
    public func assignProject(_ projectID: String?) async {
        guard let documentID = selectedDocumentID else { return }
        do {
            try await coordinator.updateMeetingDocument(
                id: documentID, projectID: .some(projectID)
            )
            await loadPage(offset: offset)
            if let selected = rows.first(where: { $0.id == documentID }) {
                selectedDocumentID = selected.id
                await loadDetail()
            }
        } catch {
            projectError = error.localizedDescription
        }
    }

    /// 关掉提示。`projectError` 对界面只读，否则界面就能随手清掉失败原因，
    /// 提示与真实状态就分家了。
    public func clearProjectError() { projectError = nil }

    public func tags(for documentID: String) async -> [String] {
        (try? await coordinator.meetingDocumentTags(documentID: documentID)) ?? []
    }

    public func setTags(_ newTags: [String], for documentID: String) async {
        do {
            try await coordinator.setMeetingDocumentTags(documentID: documentID, tags: newTags)
            documentTags = await tags(for: documentID)
        } catch {
            projectError = error.localizedDescription
        }
    }

    // MARK: - 未完成事项（MC-56）
    //
    // 「某项目有 37 条未完成事项 → 列出所有未完成」。之前这条验收在库里算得出来，
    // 界面上却没有入口；而且很容易做成"取最新 10 条"就宣称是全部——
    // 所以这里同时持有**全量总数**和**当前页**，翻页翻得完才算数。

    /// 当前这一页未完成事项。行动项，按会议时间倒序。
    public private(set) var openItems: [KnowledgeEvidence] = []
    /// 全量计数。**不是 `openItems.count`**——那只是这一页。
    public private(set) var openItemCounts: KnowledgeItemCounts = .zero
    public private(set) var isLoadingOpenItems = false
    public private(set) var openItemsError: String?
    public private(set) var openItemOffset: Int = 0
    public let openItemLimit: Int = 50

    /// 列表也用代次：连续点两次"未完成事项"，先发的那次不能覆盖后一次。
    private var openItemsGeneration: Int = 0

    public var hasMoreOpenItems: Bool { openItemOffset + openItems.count < openItemCounts.total }

    /// 未完成事项的范围跟着当前的筛选走：选了项目就只看这个项目，
    /// 连归档的一起列的时候未完成也跟着算——否则计数和用户看到的范围对不上。
    public var openItemScope: MeetingKnowledgeScope {
        MeetingKnowledgeScope(projectID: projectID, includesArchived: includesArchived)
    }

    /// 清单看哪些。默认只看未完成，但**必须能切到「全部」**——
    /// 做完就彻底看不见、也撤不回来的清单比没有更糟。
    public enum OpenItemMode: String, CaseIterable, Hashable {
        case open
        case all

        public var title: String {
            switch self {
            case .open: "未完成"
            case .all: "全部"
            }
        }
    }

    public private(set) var openItemMode: OpenItemMode = .open

    public func setOpenItemMode(_ mode: OpenItemMode) async {
        guard openItemMode != mode else { return }
        openItemMode = mode
        await loadOpenItems(offset: 0)
    }

    /// 正在写执行状态的条目 id。非空时那一行禁用，避免连点两次记成两条事件。
    public private(set) var pendingOpenItemID: String?
    /// 写失败时要说的那一句。**失败不吞**：静默失败会让用户以为标上了。
    public private(set) var openItemWriteError: String?

    public func loadOpenItems(offset: Int) async {
        openItemsGeneration += 1
        let generation = openItemsGeneration
        isLoadingOpenItems = true
        openItemsError = nil
        do {
            let page = try await coordinator.meetingKnowledgeItems(
                filter: KnowledgeItemFilter(kinds: ["action"], openOnly: openItemMode == .open),
                scope: openItemScope,
                limit: openItemLimit,
                offset: offset
            )
            guard generation == openItemsGeneration else { return }
            openItems = page.items
            openItemCounts = page.counts
            openItemOffset = offset
            isLoadingOpenItems = false
        } catch {
            guard generation == openItemsGeneration else { return }
            openItemsError = error.localizedDescription
            isLoadingOpenItems = false
        }
    }

    public func loadMoreOpenItems() async {
        guard hasMoreOpenItems, !isLoadingOpenItems else { return }
        await loadOpenItems(offset: openItemOffset + openItemLimit)
    }

    /// 记一次状态变化。**返回是否成功**，界面据此决定要不要收起菜单。
    ///
    /// 成功之后留在原来那一页：勾掉一条，下面的一条顶上来，
    /// 弹回第一页等于惩罚一个正在认真清理待办的用户。
    @discardableResult
    public func markOpenItem(_ itemID: String, status: ActionExecutionStatus) async -> Bool {
        pendingOpenItemID = itemID
        openItemWriteError = nil
        do {
            try await coordinator.recordActionExecution(itemID: itemID, status: status)
            pendingOpenItemID = nil
            await reloadOpenItemsKeepingPlace()
            return true
        } catch {
            openItemWriteError = error.localizedDescription
            pendingOpenItemID = nil
            return false
        }
    }

    /// 空串与纯空白归一成 nil。空串是"清掉"，不是"保持原样"——
    /// 留一个看不见的旧负责人，比没有负责人更糟。
    private func normalized(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 改负责人和期限。**不顺带改状态**：填了期限不等于这件事已经做完。
    ///
    /// 空字符串是"清掉"，不是"保持原样"——留一个看不见的旧负责人更糟。
    @discardableResult
    public func updateOpenItem(_ itemID: String, owner: String?, due: String?) async -> Bool {
        pendingOpenItemID = itemID
        openItemWriteError = nil
        do {
            try await coordinator.recordActionExecution(
                itemID: itemID,
                status: .open,
                ownerText: .some(normalized(owner)),
                dueText: .some(normalized(due))
            )
            pendingOpenItemID = nil
            await reloadOpenItemsKeepingPlace()
            return true
        } catch {
            openItemWriteError = error.localizedDescription
            pendingOpenItemID = nil
            return false
        }
    }

    /// 写完之后按原位置重载；最后一页被清空时退回一页，不停在空页面上。
    private func reloadOpenItemsKeepingPlace() async {
        await loadOpenItems(offset: openItemOffset)
        guard openItems.isEmpty, openItemOffset > 0 else { return }
        await loadOpenItems(offset: max(0, openItemOffset - openItemLimit))
    }


    /// 空态文案。说清为什么是空的，以及下一步能做什么。
    public var openItemsEmptyHint: String {
        if openItemCounts.total > 0 {
            return "往后翻还有 \(max(0, openItemCounts.total - openItems.count)) 条。"
        }
        if projectID != nil { return "这个项目下没有未完成的事项。换个项目看看。" }
        return "没有未完成的事项。会上定的待办都会出现在这里。"
    }

    /// 写失败时给用户的那一句，顺带说清下一步。
    public var openItemWriteHint: String {
        guard let error = openItemWriteError else { return "" }
        return "\(error)。清单没有变化，可以再试一次。"
    }

    /// 一句话的当前状态，给清单面板的标题用。
    public var openItemsHeadline: String {
        let noun = openItemMode == .open ? "未完成事项" : "全部行动项"
        return openItemCounts.total == 0 ? noun : "\(noun)（共 \(openItemCounts.total) 条）"
    }

    // MARK: - 跨会议结论冲突（MC-57、MC-58）
    //
    // 闭环的最后一环：两场会说的话对不上时怎么办。唯一被允许的答案是
    // **把矛盾摆出来、说清缺什么限定、让用户定**。系统自己合成一句一致意见，
    // 就是用一句没人说过的话把两场会的分歧盖掉。

    public private(set) var conflicts: [KnowledgeChangeProposal] = []
    public private(set) var isLoadingConflicts = false
    public private(set) var conflictError: String?
    /// 确认替代失败时的提示。与 `conflictError` 分开：一个是读不到，一个是写不进。
    public private(set) var conflictWriteError: String?
    /// 正在确认的那一处。非空时那一行禁用，避免连点两次写两条替代关系。
    public private(set) var pendingConflictID: String?
    private var conflictsGeneration: Int = 0

    public func loadConflicts() async {
        conflictsGeneration += 1
        let generation = conflictsGeneration
        isLoadingConflicts = true
        conflictError = nil
        do {
            let found = try await coordinator.conflictingKnowledgeDecisions(scope: openItemScope)
            guard generation == conflictsGeneration else { return }
            conflicts = found
            isLoadingConflicts = false
        } catch {
            guard generation == conflictsGeneration else { return }
            conflictError = error.localizedDescription
            isLoadingConflicts = false
        }
    }

    /// 确认「后一条取代前一条」。**返回是否成功**。
    ///
    /// 成功之后重载：这一处不该还挂在面板上——用户刚点过，
    /// 再看到同一条只会怀疑上一步到底有没有生效（`conflictingDecisions`
    /// 现在会跳过已确认替代的两边）。
    @discardableResult
    public func confirmSuperseding(_ conflict: KnowledgeChangeProposal) async -> Bool {
        guard let fromID = conflict.previousItemID, let toID = conflict.proposedItemID else {
            conflictWriteError = "这一处没有指向具体的两条结论，没法确认取代关系。"
            return false
        }
        pendingConflictID = conflict.id
        conflictWriteError = nil
        do {
            try await coordinator.confirmKnowledgeSupersession(
                fromItemID: fromID, toItemID: toID, basis: .userConfirmed
            )
            pendingConflictID = nil
            await loadConflicts()
            return true
        } catch {
            conflictWriteError = "\(error.localizedDescription)。两边说法都原样留着，什么都没改。"
            pendingConflictID = nil
            return false
        }
    }

    public var conflictsHeadline: String {
        conflicts.isEmpty ? "跨会议结论冲突" : "跨会议结论冲突（\(conflicts.count) 处）"
    }

    /// 空态说清为什么空。**不写"暂无数据"**。
    public var conflictsEmptyHint: String {
        if projectID != nil { return "这个项目下没有跨会议结论冲突。换个项目看看。" }
        return "两场会的结论对不上时会出现在这里，系统不会替你合成一个折中说法。"
    }

    public var conflictWriteHint: String {
        guard let error = conflictWriteError else { return "" }
        return error
    }

    // MARK: - 知识归档包（MA-19）

    /// 导出归档包。**revision 必填**——用户在看哪一版，包里就是哪一版（MC-48）。
    ///
    /// 这一场还没整理出纪要时导不了，也不退回"导个空壳"：
    /// 归档包的 `minutesID` 是必填项，缺了整包就没有意义。
    public func exportArchive(scope: KnowledgeArchiveScope, to directory: URL) async throws -> URL? {
        guard let documentID = selectedDocumentID else { return nil }
        guard let minutesID = snapshot?.minutesVersionID else { return nil }
        return try await coordinator.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: minutesID, scope: scope
            ),
            to: directory
        )
    }

    /// 导入预检（MC-71）。**必须先看这个再谈导入**：同 ID 异内容的冲突
    /// 静默跳过就是丢用户数据。
    public func previewArchive(at packageURL: URL) async throws -> KnowledgeArchivePreview {
        try await coordinator.previewKnowledgeArchive(at: packageURL)
    }

    /// 真正导入。成功后刷新列表——新文档得当场出现。
    public func importArchive(at packageURL: URL) async throws -> KnowledgeArchiveImportResult {
        let result = try await coordinator.importKnowledgeArchive(at: packageURL)
        await loadPage(offset: 0)
        return result
    }

    /// 一次删除之后给用户看的那句话。
    ///
    /// **说具体数目与还剩什么**，不写"操作成功"：用户真正想知道的是
    /// "哪几样东西没了、剩下的还算不算数"。`markedForReview` 要单独说——
    /// 结论还在、还能看，但它不再自称已核对，这是需要用户动手的那件事。
    public static func summary(for report: MeetingDeletionReport) -> String {
        var parts: [String] = []
        switch report.mode {
        case .archive:
            parts.append("已归档。搜索、导出和问答都看不见它，数据一行不少，可以撤销。")
        case .removeTranscript:
            parts.append("已移除完整转录 \(report.removedLines) 句。纪要和结论留着。")
            if report.removedRevisions > 0 {
                parts.append("原句的修订记录 \(report.removedRevisions) 条也一并移除。")
            }
            parts.append("引用它们的原句已经读不到了。")
        case .deleteEverything:
            parts.append("已完整删除，不能撤销。")
            var removed: [String] = []
            if report.removedLines > 0 { removed.append("转录 \(report.removedLines) 句") }
            if report.removedMinutes > 0 { removed.append("纪要 \(report.removedMinutes) 版") }
            if report.removedItems > 0 { removed.append("结论 \(report.removedItems) 条") }
            if report.removedAnchors > 0 { removed.append("引用 \(report.removedAnchors) 处") }
            if report.removedSnapshots > 0 { removed.append("来源快照 \(report.removedSnapshots) 份") }
            parts.append(
                removed.isEmpty
                    ? "这一场本来就没有可删的内容。"
                    : "一并清掉：" + removed.joined(separator: "、") + "。"
            )
        }
        if report.markedForReview > 0 {
            parts.append("其中 \(report.markedForReview) 条结论不再自称已核对，需要你再看一眼。")
        }
        return parts.joined(separator: "")
    }
}
