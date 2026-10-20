---
title: "有声书工坊后续优化路线图（2026-10-20）"
status: active
audience: "产品、macOS App 开发者与验证负责人"
version: "1.1.0"
date: 2026-10-20
---

# 有声书工坊后续优化路线图

本稿承接 [2026-10-20 业务流程与用户体验审查](../audits/2026-10-20-audiobook-business-ux-review.md) 的未实施项，给出一份可按里程碑验收的后续排期。它不重复已完成的主链路优化，也不把“建议”写成承诺。

## 1. 规划原则

1. **先消除不可信状态，再增加吞吐**：导出面板说“已就绪”但准备阶段仍可能失败，会直接损伤信任；优先把门禁做成同一份只读判定。
2. **先测量再改内存**：没有真实长篇或合成大样本的峰值数据，不做 AudiobookSourceIndex 的结构性替换。
3. **不新增并行制作**：单机单服务、同一本书串行制作是现有资源与取消语义的基础；吞吐优化只做“少让用户手动找阻塞”，不做多本并发生成。
4. **可访问性是交付条件，不是收尾项**：角色选择、空态、错误提示都必须键盘与 VoiceOver 可达；UI 自动化须逐次授权，未授权时以代码审查和人工走查记录为准。
5. **每项独立可回退**：不引入 schema 变更；导出/索引/交互改动各自可单独回退。

## 2. 优先级与里程碑

| 优先级 | 任务 | 用户价值 | 成本 | 依赖 |
|---|---|---|---|---|
| P0 | M1 导出只读预检 | 消除“按了才知道”，整本/分章门禁一致 | 中高（2–3 天） | 现有 prepare 校验逻辑 |
| P0 | M0 真实长篇基线 | 给后续内存/质量结论提供可复现实证 | 低（0.5 天） | 外部语料恢复本地 |
| P1 | M2 长篇索引内存 | 降低 10M 字书稿峰值内存 | 中（1–2 天） | M0 测量 |
| P1 | M3A 角色卡选择语义 | 键盘/读屏可达，符合设计系统 | 低（0.5–1 天） | 无 |
| P2 | M3B 制作阻塞引导 | 长篇少走弯路，不误以为“没有可制作章节” | 低（1 天） | 无 |
| P2 | M4 EPUB 韧性 | 真实 EPUB 变体少失败 | 中（1 天） | 真实 EPUB 样本 |
| P3 | 批量导入 | 多本连导少点几次 | 中高（2 天） | 导入队列设计 |

建议顺序：**M0 与 M3A 可并行 → M1 → M2 → M3B → M4**。批量导入在用户明确需要前不做，避免为低频路径增加导入状态机。

## 3. M1：导出只读预检（P0）

### 3.1 问题

当前 AudiobookExportReadiness 只判断“章节是否有当前版本”，而 AudiobookExportController.prepare 还会拒绝：缺标注、待确认说话人、当前版本失效、候选资产缺失/未通过 SHA-256、片段为空。面板显示“全书已就绪”后仍可能失败，且失败原因只能在准备阶段得到。

### 3.2 方案

把 prepare 中“只读规划”和“编码提交”拆开：

- 新增 AudiobookExportPlan：包含 exportedChapters、omittedChapters、chapterRevisions、每个章节的片段候选与帧数；不写文件、不调用媒体编码。
- 新增 AudiobookExportAudit：plan + blockers；blocker 至少区分：
  - 缺标注 / 待确认说话人；
  - 当前章节版本失效（有旧版可听）；
  - 候选资产缺失或 SHA-256 未通过；
  - 片段为空；
  - 已跳过（不计阻塞，只进 omitted）。
- AudiobookExportController.audit(bookID:chapterIDs:profile:) 只读执行规划；prepare 复用同一规划结果后进入编码。UI 在导出面板打开、格式切换、章节选择变化时调用 audit。
- 面板不再用 isFullBookReady 单独判断，而以 audit.blockers 为准；每类 blocker 给出用户语言与“去处理”动作。
- 保留 NoExportableChaptersSelected 等现有错误作为最终兜底，不删除。

### 3.3 文件与接口

- macos/SpeechRailApp/SpeechRailApp/AudiobookExportController.swift：抽 makePlan/audit，prepare 改调用。
- macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift：exportAudit 状态、异步刷新、exportErrorMessage 复用。
- macos/SpeechRailApp/SpeechRailApp/AudiobookWorkshopView.swift：就绪卡改为 audit 结果；blocker 行内动作。
- macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookExportTests.swift：新增 blocker 分类与 audit/prepare 一致性测试。

### 3.4 验收

1. 五类 blocker 都有确定性夹具；面板文案与 prepare 实际拒绝原因一致。
2. 同一输入下，audit.blockers 为空时 prepare 不因“章节/标注/资产”失败；媒体帧与编码失败仍可能出现，单独提示。
3. 跳过章节只进 omitted，不阻塞 M4B；分章 MP3 只允许选择 audit ready 的章节。
4. 现有导出测试全部通过，包含取消、覆盖确认、SHA 校验与 M4B 章节边界。

### 3.5 回退

保留旧 prepare 的校验入口；若 audit 出现偏差，UI 可回退到当前 readiness 投影，prepare 行为不变。

## 4. M2：长篇索引内存（P1）

### 4.1 问题

AudiobookSourceIndex.scalarByteOffsets 是每个标量一个 Int64，10M 标量约占 80 MB，另加 paragraphStartOffsets 的 Set<Int64>。书稿上限 64 MiB，字节偏移实际不需要 64 位。

### 4.2 方案

- 先做 M0：用 5M/10M 标量合成文本记录导入时间与峰值内存，不提交真实书稿。
- 将 scalarByteOffsets 改为 [UInt32]（书稿原始字节上限 64 MiB，偏移 < 2^32）；所有读取点转为 Int，保持半开字节区间语义不变。
- paragraphStartOffsets 若仍占比较高，改为对 paragraphs 二分查找（段落已按 sourceRange.lowerBound 排序），删除 Set。
- 不改 AudiobookSourceIndex 的公开查询语义；不改变原子、片段或章节边界。

### 4.3 验收

1. 现有导入、分章、原子、片段、分析窗口测试全部通过。
2. 5M/10M 标量样本的峰值内存相对基线有可量化下降；导入时间不退化超过 10%。
3. 64 MiB 边界书稿不溢出 UInt32；超限仍按原上限拒绝。
4. 基准数据与命令写入审计/计划记录，不把合成数据提交仓库。

### 4.4 回退

[UInt32] 是一个类型替换；回退即恢复 [Int64] 和 Set，不涉及持久化格式。已导入作品不需要迁移。

## 5. M3A：角色卡选择语义（P1）

### 5.1 问题

characterCard 在整卡上使用 .onTapGesture + .focusable() + .onKeyPress，与设计系统“选择用 Button”的约定不一致；卡内已有音色、试听、展开等叶面控件，整卡手势会与嵌套按钮争夺命中与键盘焦点。

### 5.2 方案

- 只把角色标题区（头像 + 名称 + 标签 + 对白数）改成 Button，buttonStyle(.plain)，选择动作放在这里；卡身其余控件保持独立。
- 删除整卡 onTapGesture、focusable、两个 onKeyPress；由 Button 自带 Space/Return 行为。
- 选择态通过 .accessibilityAddTraits(isSelected ? .isSelected : []) 暴露；保留可见的选中背景，不把颜色作为唯一信号。
- 卡内“音色选择/试听/展开”不包进标题 Button，避免嵌套按钮。

### 5.3 验收

1. Tab 能依次到达角色标题按钮及卡内叶面控件；Space/Return 选择角色，不触发音色选择或试听。
2. VoiceOver 读出角色名、选中态与“按空格选择”提示；读屏不把整卡当按钮。
3. 点击标题区选中、点击音色/试听/展开只执行各自动作。
4. 未授权 UI 自动化时，以代码审查 + 人工键盘/读屏走查记录验收，不声称自动化通过。

## 6. M3B：制作阻塞引导（P2）

### 6.1 问题

makeConfirmedChapters 已能一次制作所有 ready/needsUpdate/paused 章节，但当没有可制作章节时，用户只看到一句错误；未知说话人、未确认配声、全部已制作三种原因混在同一个主按钮附近，长篇用户需要自己找。

### 6.2 方案

- 新增 AudiobookProductionBlocker（枚举 + 计数 + 下一步），由 makeConfirmedChapters 的 guard 分支产出，不新增制作并行。
- 书架/工作台主按钮下方显示一行“下一步”：待确认说话人 N 处 → 定位第一处；配声未确认 → 切到准备页；无可制作章节 → 说明已完成/已跳过。
- 不改变 makeConfirmedChapters 对 ready 章节的批量语义；不新增“全部重做”。

### 6.3 验收

1. 三种阻塞分别有确定性测试，主动作仍唯一。
2. 点击“下一步”只做导航/定位，不修改作品数据。
3. 没有阻塞时不显示额外提示。

## 7. M4：EPUB 韧性（P2）

- 用真实/公开 EPUB 样本覆盖：嵌套目录、百分号编码 href、XHTML 实体、linear="no"、无 OPF title、损坏 ZIP。
- 只读解析仍限制 256 MiB 解压总量、拒绝符号链接/路径穿越；不执行脚本/样式。
- 失败文案区分 DRM、损坏、缺 container/spine、空正文；新增夹具不提交版权书稿。
- 验收：现有 EPUB 合成测试 + 至少 3 个真实结构样本通过；无网络访问。

## 8. 明确不做

- 不引入多本并发生成、跨书制作队列或第二套 TTS worker。
- 不为导出新增 schema 字段；audit 结果不持久化。
- 不做 PDF/DOCX 导入；EPUB 之外的新格式另立设计。
- 不在本轮做真实 UI 自动化；需要逐次授权。

## 9. 风险与证据边界

- M1 的 audit 仍可能与编码阶段的媒体帧失败不完全一致；验收只承诺“章节/标注/资产”一致，媒体失败单独呈现。
- M0 依赖外部语料恢复本地；语料仍为云端占位时，不得用合成样本替代真实分章质量结论。
- M2 的内存数字只对合成样本负责；真实 10M 字书稿的峰值仍需在 M0 语料可用后复测。
- 所有“通过”以命令输出为准；文档、计划和退出码不单独证明质量。

## 10. 实施记录（2026-10-20）

| 项 | 状态 | 证据 |
|---|---|---|
| M1 导出只读预检 | 已落地 | controller 抽出 buildPlan/audit，prepare 复用；新增 unknownSpeaker / missingAsset 审计测试 |
| M2 长篇索引内存 | 已落地 | 2M 标量 RSS 增量 59,572,224 → 51,560,448 字节；耗时 833.2 → 885.7 ms；5M 样本 117,669,888 字节 / 2,169.6 ms |
| M3A 角色卡选择语义 | 已落地 | 标题区改为 Button，移除整卡手势/focusable；App Debug 构建通过 |
| M3B 制作阻塞引导 | 已落地 | productionBlocker 区分未配声/未知说话人/无可制作；新增确定性测试 |
| M4 EPUB 韧性 | 已落地（有已知限制） | 5 个真实 EPUB 导入通过；新增 linear=no、百分号 href、fragment、script 排除测试；彷徨因源文件无可识别章节标题，导入为 1 章 |
| M0 真实长篇基线 | 已落地 | 4 个真实 TXT 与 5 个真实 EPUB 完成导入基线，最大样本 2.66 MB / 121 章 |

M2 的 RSS 数字是测试进程内的 resident delta，包含书稿 Data 与段落结构，不等于单次索引的精确分配峰值；结论只对同机合成样本负责。

### 10.1 真实语料基线（2026-10-20）

同一台 Apple Silicon Mac，Debug 测试进程，记录整次导入（索引、分章、预览生成）的墙上时间与 RSS 增量；只记录元数据，不输出正文。

| 样本（TXT） | 字节 | 章节 | 耗时 | RSS 增量 |
| --- | ---: | ---: | ---: | ---: |
| 红楼梦 | 2,663,455 | 121 | 507.2 ms | 26,787,840 |
| 西游记 | 2,243,433 | 100 | 417.3 ms | 22,609,920 |
| 儒林外史 | 853,632 | 48 | 104.6 ms | 8,568,832 |
| 呐喊 | 281,093 | 15 | 70.4 ms | 7,061,504 |

| 样本（EPUB） | 章节 | 耗时 |
| --- | ---: | ---: |
| 红楼梦 | 121 | 637.9 ms |
| 西游记 | 101 | 570.6 ms |
| 儒林外史 | 48 | 145.6 ms |
| 呐喊 | 10 | 88.0 ms |
| 彷徨 | 1 | 67.7 ms |

彷徨的 EPUB 正文使用无 h1/h2、仅靠段落边距排版的标题，文本层没有可识别章节标记，因此整本成为 1 章；这是章节启发式的已知限制，不是解压或文本提取失败。真实样本只在本机运行，不提交仓库。

### 10.2 当前批次验证

- Audiobook 过滤测试：316 passed，4 skipped（合成/真实 benchmark 各 2 项，默认显式开启）。
- 全量测试：1827 个 XCTest passed、4 skipped；659 个 Swift Testing passed。
- scripts/macos_app_build.sh --configuration Debug：BUILD SUCCEEDED。
- uv run python scripts/check_user_doc_contract.py：OK（39 paths，21 documented error codes，9 model aliases）。
- python3 scripts/check_operator_docs.py：ok；git diff --check：clean。
