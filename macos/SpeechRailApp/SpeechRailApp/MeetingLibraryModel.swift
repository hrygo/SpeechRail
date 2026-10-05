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
    }

    public func search(_ text: String) async {
        query = text
        await loadPage(offset: 0)
    }

    public func filter(projectID: String?) async {
        self.projectID = projectID
        await loadPage(offset: 0)
    }

    /// 切换"连归档件一起列"。回到第一页：归档件可能在任意位置，
    /// 停在原来的偏移上会落到一个空页面上。
    public func setIncludesArchived(_ includes: Bool) async {
        guard includesArchived != includes else { return }
        includesArchived = includes
        await loadPage(offset: 0)
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
