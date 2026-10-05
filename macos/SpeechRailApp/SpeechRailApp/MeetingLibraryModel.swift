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

    public func loadPage(offset: Int) async {
        listGeneration += 1
        let generation = listGeneration
        isLoadingList = true
        listError = nil
        do {
            let page = try await coordinator.meetingLibraryPage(
                query: query, projectID: projectID, limit: limit, offset: offset
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
}
