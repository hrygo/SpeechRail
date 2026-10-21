# 有声书缺失音色准备与批量创建 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 缺音色时预填全部创建物料，创作者浏览确认后批量创建，并返回全书配声准备。

**Architecture:** 在现有有声书工作流内增加可编辑的创建草稿与集中审阅表单，复用 `AudiobookSpeechRenderer.createAndPublishLeadVoice` 的设计、校验、发布链和本书资产登记。批量串行运行、逐项保留结果；创建完成后重新计算配声建议。

**Tech Stack:** Swift 6、SwiftUI、现有本机 SpeechRail API、XCTest fake renderer。

**Spec:** 当前用户明确要求自动备齐物料、浏览确认与批量创建；沿用此前明确的“不一键开始生成章节音频”。

## Global Constraints

- macOS 26+、Apple silicon；不新增依赖或修改服务公共契约。
- 名称、声音描述、试听文稿可编辑；来源依据与默认建议分开呈现，不把推断当原文事实。
- 普通缺声路径按实际发声角色准备，旁白和明确独占角色单列，其余按声音类型合并；保留主角及单角色定制入口。
- 已绑定声音受保护；创建物料不调用生成，显式确认后才调用创建；章节音频始终另行启动。
- 复用真实质量校验与版本身份，不伪造可用状态；共享和撞音仍需确认。
- UI 复用设计 Token、原生控件及无障碍标签；无本次授权不接管窗口。
- 无数据库迁移；未提交创建草稿保存在当前工作台内存，切书后清除。

## Review Focus

- 全书无可用声音：提供完整且可编辑的物料，直到确认前生成调用为零。
- 部分失败或取消：成功声音保留，重试不重复创建成功项，取消停止后续项。
- 创建期间角色或选声变化、切书：不能覆盖新选择，迟到结果不能污染另一作品。
- 原文台词过短、无证据、长书名及 Unicode：默认材料合法，缺证据明确标注，字段在提交前校验。
- 新声音校验不合格、归属登记失败：逐项可见失败，不能显示配声就绪或自动开始章节制作。

### Task 1: 草稿与物料

**Files:** 新建 `AudiobookVoicePreparation.swift`；修改 `AudiobookWorkflowTests.swift`，登记 SwiftPM/Xcode sources。

**Interfaces:** `AudiobookVoiceCreationDraft` 保存目标、关联角色、来源、可编辑字段、选择和状态，产生经过校验且按内容冻结身份的 `AudiobookLeadVoiceCreationRequest`。

- [x] 先增加缺声时不生成、材料可编辑、合并共享角色、保护已有选择的失败用例。
- [x] 实现材料准备和字段校验，原文摘录与默认试听稿保留来源说明。
- [x] 定向运行新增测试，确认材料满足服务字段约束。

### Task 2: 显式批量创建

**Files:** `AudiobookWorkflowModel.swift`、`AudiobookProductionWiring.swift`、相关测试。

**Interfaces:** `prepareVoiceCreationDrafts`、`createSelectedVoiceDrafts`、`cancelVoiceDraftCreation`；逐项状态和汇总供表单消费。

- [x] 增加勾选/编辑、部分失败重试、取消、切书、在途选声保护和零章节渲染测试。
- [x] 串行提交选中且未成功项目，保存实际结果与本书归属；每次异步返回核对目标作品与资料会话。
- [x] 创建链检查取消，幂等键区分创建材料及尝试；传输/登记重试复用候选，终止质量失败重试生成新候选，发布成功后的核验与登记独立收尾。
- [x] 完成后刷新声音并重新准备配声建议，保留风险确认。

### Task 3: 集中审阅与交付

**Files:** 新建 `AudiobookVoicePreparationSheet.swift`；修改 `AudiobookBookWorkspaceView.swift` 和正式有声书文档。

- [x] 缺声时提供可见的“浏览并创建音色”入口，主角/群像/单角色创建统一先进入审阅。
- [x] 展示选择、字段、来源折叠区、进度、逐项失败与重试、停止后续项目；保留可编辑草稿。
- [x] 定向执行有声书及创建链回归、测试登记检查、包装脚本构建和 diff 检查。
- [x] 报告自动测试证据与未进行的 UI/真实音色验收；按当前授权保留本地改动，不自动提交、推送或安装。

## 验证记录（2026-10-21）

- `swift test --package-path macos/SpeechRailApp --filter Audiobook`：356 项 XCTest 中 352 项通过、4 项按显式环境开关跳过；另 2 项 Swift Testing 通过，共 354 项通过、0 失败。跳过项为手动图像导出、显式基准及真实书稿夹具，不把它们算作已验收。
- `bash scripts/macos_app_build.sh --configuration Release --timeout 600 -- ARCHS=arm64`：正常 Release 编译成功，包装脚本清理临时 App。正式安装未替换，唯一登记检查通过。
- `python3 scripts/check_macos_test_target_coverage.py`、Xcode project `plutil -lint` 和 diff 检查通过。
- 独立只读审查发现的终止质量失败重试、发布后取消问题均有 RED→GREEN 用例；切书加载期间迟到结果也已复现并修复。将资料会话检查的 `&&` 临时反转为 `||` 后，切书回归出现预期失败；恢复源码摘要一致，9 项批量相关测试再次通过。
- 使用合成作品与 fake 服务；没有真实生成、UI 自动化、服务或档位调整、提交、推送、安装。创建草稿无持久化迁移，现有安装与用户作品保持原状。

## 真实创建故障复核与修复（2026-10-21）

- 08:44–08:45 本机四项设计、参考检查与发布均返回成功；App 在发布后误用正式制作准入核对身份，未运行输出检查即将四项报为失败。此前 fake 把新发布声音直接设为 production ready，未覆盖这一真实状态。
- 发布身份核对与正式制作准入分开：先独立登记无绑定的本书资产，再运行输出检查；要求报告通过且检查记录已保存，刷新能力并严格核对就绪、版本与参数后才绑定。新增「已创建待检查」状态，失败不重建；修改物料或参考候选终止失败才生成新候选。
- 无绑定资产意图在重试时复用原记录，角色与群像均不受其他角色选声导致的全书摘要变化阻塞；恢复资产意图不会提前应用绑定。角色、群像两种重试缺口均先复现 RED 再修复。
- 真实检查四个已发布声音均为 pass 且 validation_persisted=true；复核发现严格声音详情已就绪，原子能力快照仍因冷 worker 报 model_runtime_identity_unknown。能力路由原先手工构造 binding/read evidence，漏掉现有 canonical helper 的 recorded-runtime 恢复；改为复用 validation_verdict_for_voice。新增冷机有效记录、暖机 runtime 变化、无有效 runtime 三种路由回归，后两种继续拒绝准入。未降低任何正式制作门槛。
- 最后一次 App 回归：361 项 XCTest 中 357 项通过、4 项按显式开关跳过，另 2 项 Swift Testing 通过，共 359 项通过、0 失败。14 项 batch 用例包含真实发布后未就绪、未保存证据、乐观声明就绪、检查失败重试、角色/群像摘要变化及取消/切书保护。
- 服务相关定向回归 132 项通过；ruff、单文件 mypy、版本一致性、测试 target 登记及 diff 检查通过。未运行无关完整 Python 套件或基准。
- 将 isRecordedOutputPass 临时改为仅检查 report pass，未保存证据的回归出现错误绑定并按预期失败；定点恢复后 Workflow SHA-256 与实验前一致，最终回归通过。独立只读审查已复核角色与群像意图复用、服务 canonical helper 及门禁恢复，无新增高置信 P1/P2。
- 09:20 复核本机已安装修复服务与 Release arm64 App，版本仍为 4.0.1 (61)，仅本地 ad hoc 包。服务 wheel SHA-256 为 541393d69d1b7927c21eb2f0d0b19d36c3a712c4321af076739ab56d0521e70d；App executable SHA-256 为 cf717373815cad6d748cdc3be0db0a67f4fe3eccf2dd7cddf5bff7c849ae9053。App 源快照指纹为 21cb1428350e7ff956cdd1f0136be882bfefb66a0a2bf94baf7c74be4c4fb57e。
- 使用受管 installer/controller 完成 service stop、换包和 start；downloaded_bytes=0，配置与 selection 文件摘要保持不变，quality/quality、auto=off、generation=13 保留。新服务 health/readyz 为 200，四个已有声音的原子能力快照均为 production_ready=true，复用原 run_id，没有重新生成。旧 managed release 与 App ZIP 保留供回退。
- App 安装到 ~/Applications/SpeechRail.app，静态签名和内嵌 XPC 校验通过；临时 App 已清理，LaunchServices 唯一登记另见安装回执。其他会话的中文时间格式改动原样保留，并纳入同一当前源快照。
- 本次未接管 UI、未自动操作真实作品绑定、未生成章节音频、未提交或推送；自动批量工作流用 fake 回归，真实证据覆盖已有声音的输出检查及服务准入恢复。安装回执与 ZIP 回退点保存在仓库外 app-backups，候选证据保存在 SpeechRail 的 release-candidates 缓存目录。

## 配声说明浮层遮挡操作修复（2026-10-21）

- 用户截图显示完整角色分配说明挤满浮层。09:24 对安装版精确 PID 2637 做三秒进程采样，主线程主要处于事件等待，未捕获持续死锁；该证据不能排除截图前的瞬时停顿。未接管窗口、焦点或输入。
- 将说明区抽为独立生产面板；同结构的未约束离屏面板在 54、500 个合成角色下分别为 962pt、7652pt，超长单项为 6525pt，先出现预期失败。
- 说明使用固定 420 × 520pt 面板，角色依据为惰性列表并独立滚动；标题、关闭及试听操作在滚动区外，提供 Escape 关闭。共享/撞音确认、应用门禁与制作入口保持原调用。
- 两项新增离屏回归修复后通过；相关展示回归共 13 项，12 通过、1 项按显式环境开关跳过人工关键帧导出、0 失败。测试不创建窗口；不能由尺寸断言推导末尾滚动、Escape 或真实操作已验收。
- 独立只读审查无 P1/P2；测试 target 登记、project plist 和 diff 检查通过。
- 2026-10-21T09:36:30.161167+08:00 完成 Release arm64 App-only 替换，版本仍为 4.0.1 (61)；正常退出旧 App，按精确身份结束旧 App XPC helper，未操作语音服务、档位或模型。签名、内嵌 XPC 与 LaunchServices 唯一登记通过，候选源快照在构建前后保持一致。新版尚未启动，真实桌面验收需当前用户另行授权。
- App executable SHA-256：57cf4ec102fa5e05115e5b401add541a4edda895f87ef19d7497ed2c8bd8e0d3；源快照指纹：1c424a2973bfe0eb02fda5c1e64adafa537805a38a62d32c6ddfb56d7644d1a9。旧 App ZIP、源清单和安装回执保存在仓库外 app-backups；未提交或推送，保留并行中文展示格式修改。
- 用户明确授权本轮界面验收后，当前作品已完成配声确认且保存了 143/895 段，原待确认方案已不存在；未回退确认、改绑或恢复制作。改用同一生产面板与 Token 编译的独立窗口，54 个合成角色，不连接语音服务，不读取或写入作品。
- 实际桌面滚动到第 54 项时关闭按钮与试听菜单仍可见，菜单可展开，关闭后可重新打开。发现首次直接 Escape 未关闭、点击说明区后才可关闭；默认将键盘焦点移到说明区后，首次及随后连续三次直接 Escape 均成功关闭。未修改系统键盘导航。
- 隔离验收窗口已退出，原作品仍为制作已暂停、已保存 143/895 段；本次没有生成新音频。最终焦点修复后的展示回归为 12 通过、1 人工导出用例跳过、0 失败；ImageRenderer 离屏图不建立交互焦点，键盘结论来自上述真实隔离窗口，不能冒充整本作品工作流验收。增量独立审查无 P1/P2。
- 2026-10-21T09:47:58.171354+08:00 已将包含默认焦点修复的 Release arm64 App 替换到 ~/Applications/SpeechRail.app，4.0.1 (61)。最终 executable SHA-256：0b9f4ca179a3639cd426a32b8157b05135712f3ee10a52da4a38f554e9dc8b83；源快照指纹：b1e3841bdb7d38f252fbb53f0cf7ba6e86f8589f66c933dff7b4e95e07a5e619。签名、内嵌 XPC、LaunchServices 唯一登记通过，旧版已归档，服务运行态未变；本次最终安装后未再次启动 App。
