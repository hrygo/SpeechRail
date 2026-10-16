# Realtime 布局与说话人归属修复计划

> **For agentic workers:** 按 TDD 逐项实施；主代理负责集成、回归与最终审查，布局和对齐复现采用边界明确的委派。

**Goal:** 消除会议实时文本的布局反馈，保证分人结果归属原识别段，修复可复现的对齐适配问题并保留脱敏失败原因。

**Architecture:** ASR 冻结段的身份随辅助结果保存；分人更新按原 item/revision 分组。布局只消费离散滚动状态，辅助失败保留正文并明确记录失败码。

**Tech Stack:** Python 3.14、pytest、Swift 6、SwiftUI、XCTest / Swift Testing。

**Spec:** `contracts/realtime-openai.md`、`contracts/realtime-events.schema.json`、`docs/developers/macos-app-design-system.md`、本次修复请求。

## Global Constraints

- 保留用户数据、现有运行配置和其他人的改动；不提交或推送。
- 确定性回归使用 fake backend 和虚构文字，不访问模型、真实录音或前台窗口。
- 不放宽文本保真、时间单调与边界校验来掩盖失败。
- 不记录音频、转写正文、prompt、秘密或绝对模型路径。
- App 构建使用仓库包装脚本。初始阶段不安装或接管 UI；用户随后明确授权安装、重启、真实模型与会议/字幕窗口实机验收，后续按此范围执行。

## Review Focus

- 辅助结果迟于下一段开始时，仍只更新原段。
- 多段同时完成、空段、重复 finish 和结束时的最后归属事件不会混写或丢失。
- 对齐失败和后续窗口超时不会用泛化消息覆盖已知原因。
- 用户回看时新文字不抢滚动，短内容与边界抖动不会触发布局反馈。
- 未验证的真实模型或 UI 行为不计为验收通过。

## Task 1: 转录滚动状态与布局

**Files:** `MeetingViewLiveTranscript.swift`、`MeetingView.swift`、`TranscriptFollowState.swift` 及 `TranscriptFollowStateTests.swift`。

**Interfaces:** 保留已有 `TranscriptFollowState` 的回看、未读与跳回最新语义；以滚动几何的离散结果替代 preference 写入循环。

- [x] 先添加短内容、长内容、阈值、未读和跳回最新的回归并确认 RED。
- [x] 实施布局与跟随修复，保留 Reduce Motion、键盘和无障碍路径。
- [x] 运行相关 Swift 回归与 App 编译。

## Task 2: 固定识别段的辅助事件身份

**Files:** `src/speechrail/application/realtime_auxiliary.py`、`tests/test_realtime_owners.py`、`tests/test_realtime_openai.py`、Realtime 契约说明。

**Interfaces:** `FrozenTranscript.item_id/transcript_revision/epoch` 是归属权威；每条分人更新只携带所属段的 spans。finish 在辅助事件交付后发布收尾屏障。

- [x] 添加跨段迟到、多段分组和结束屏障回归，确认现有实现失败。
- [x] 保存不可变归属身份，修复更新与最终快照的投影。
- [x] 运行 owner、wire 和 schema 定向回归。

## Task 3: 对齐根因与错误诊断

**Files:** `src/speechrail/application/alignment.py`、相关 alignment worker/adapter、`src/speechrail/observability/metrics.py`、`MeetingSession.swift`、`CaptionSession.swift` 及对应回归。

**Interfaces:** 保留稳定的对齐失败码；指标与结构化日志只包含有界分类及计数。会议/字幕保留正文，记录具体辅助失败，不由后续泛化超时覆盖。

- [x] 静态核对实际 vendor 结果形状与 adapter，构造能证明根因的确定性回归。
- [x] 修复适配根因并保留严格校验，增加失败分类、脱敏诊断和客户端保存回归。
- [x] 运行 alignment、metrics、会议与字幕生命周期回归。

## Task 4: 集成验证与交付

- [x] 对修改范围执行 Ruff、Mypy、契约检查与必要 Python/Swift 回归。
- [x] 使用 `scripts/macos_app_build.sh --configuration Debug` 验证 App 编译。
- [x] 审查 diff、隐私与生命周期边界；记录实际结果和未验证范围。

## Progress

- 初始证据：系统日志确认 300 次布局循环及 SIGTRAP；单场 16 条定稿、0 标签、15 次对齐不可用；安装态相关服务源码与 checkout 哈希一致。
- 已授权实施与必要回归；之后用户明确授权安装、重启和实机/UI 验收，已保留独立服务与 App 回退点。

## 已确认的故障路径

| 证据类型 | 故障路径 | 修复 |
|---|---|---|
| 系统日志、源码与确定性状态测试 | 会议滚动区以 GeometryReader / PreferenceKey 测量再写回状态，视口与未读横幅参与布局反馈；距离方向反了 | 使用 ScrollGeometry 的离散区间、状态去重及阈值缓冲，移除原始几何状态 |
| 安装态 vendor 静态源码、fake adapter RED/GREEN | mlx-qwen3-asr 0.3.5 允许相等时间点，worker 丢弃零时长 token，校验器随后因口语字符缺失返回 text_mismatch | 保留 vendor token；segment 合并相邻有效范围，细粒度或全零时长以 resolution 错误失败 |
| 并发 fake RED/GREEN | activity 在 append 返回前发布更新，processed 水位先于 accepted_samples，正常输出被误判无效 | 跨异步边界前预留已接纳样本水位，保留 ledger 的严格校验 |
| 多段 fake 与 wire 回归 | 归属更新携带后续 item 身份及全场 units，finish 未等事件消费者 | 保存冻结身份，按段发送，排空更新后发送终态；done 只带最后完成段快照 |
| 会话生命周期 RED/GREEN、日志脱敏回归 | App 忽略 alignment.failed；泛化超时覆盖具体原因，worker 错误缺少分类 | 保留安全分类、原因指标和分阶段元数据日志；会议/字幕显示可读原因，保留正文及标签 |
| Chrome 实机音频进程元数据、helper 边界 RED/GREEN | 声音由内嵌 `com.google.Chrome.helper` 发出，仅根 App ID 命中静音 | 展开已选择 App 内声明的 helper ID；排除包外符号链接和未选择的根 App |
| 窄窗口 UI 复现、滚动状态 RED/GREEN | 跳回最新的程序动画被当成用户上翻，新增内容再次积累未读 | 使用 ScrollPosition 贴底；只有用户交互/惯性滚动阶段改变跟随状态 |
| 字幕/会议收尾实测与 12 组分包回归 | 重采样尾样本越过尚未提交的 VAD 剩余 PCM；冻结范围少一样本，返回 alignment_pcm_mismatch | 尾样本按顺序经过同一 VAD/admission 缓冲；补成完整帧时正常评分，冻结范围与实际 PCM 一致 |
| 真实合成音频截断复现、模型配置与适配器 RED/GREEN | 24,001 样本音频的模型结束点为 24,320，超出约 20 ms；80 ms 格点的最近尾格点被当成精确时间拒绝 | 模型适配器读取配置格点，只将最近尾格点与真实 PCM 边界相交；通用严格校验不变，非法顺序、离格点与较远越界继续失败 |

历史 16 条定稿中有 15 条对齐失败，但旧日志未保存逐段错误码，无法追认它们是否全部由同一
collapsed timestamp 缺陷触发。这里确认的是可复现实现缺陷及其修复，不把这一推断写成历史实测。

## 验证记录

以下为 2026-10-16 09:42 CST 的源码阶段检查点；当时未安装、未切换服务或档位。

| 检查 | 实际结果 |
|---|---|
| Python：14 个 alignment / diarization / Realtime / schema / observability 相关文件 | 278 passed，1 skipped；跳过项依赖开发环境未安装的 vendor runtime |
| Swift：TranscriptFollowStateTests、MeetingSessionLifecycleTests、CaptionSessionLifecycleTests、RealtimeContractTests | 151 项 XCTest 与 2 项 Swift Testing 通过 |
| App：`scripts/macos_app_build.sh --configuration Debug` | BUILD SUCCEEDED；临时 App 由包装脚本清理 |
| 修改范围 Ruff、8 个源文件 Mypy、`git diff --check` | 通过 |
| 测试约束核验 | 新故障回归先 RED 后 GREEN；临时反转时间方向校验使 5 项合并回归失败，恢复后通过 |
| 独立只读审查 | 已处理关闭分人时的原因覆盖、非法 vendor 输出分类、worker I/O / timeout 分类和异常正文泄露问题 |
| 运行态只读核验 | `/health` 为 ok，仍运行 3.10.0；不含本次源码修复 |

该检查点的确定性回归均使用 fake backend、虚构文字和合成 PCM 字节，未采集麦克风或运行真实模型。

## 授权后的安装与实机验证

核验日期：2026-10-16。以下为直接实测，不作为正式声学质量基准或长时稳定性承诺。

| 检查 | 实际结果 |
|---|---|
| 最终 Python：17 个相关测试文件 | 327 passed、1 skipped（开发环境缺 vendor；真实推理使用已安装 vendor） |
| 最终 Swift：音频边界、滚动、会议/字幕生命周期与 Realtime 契约 | 169 项 XCTest 与 2 项 Swift Testing 通过 |
| 新增收尾回归 | 12 组 37/768 样本分包与不同尾长，修复前 10 组失败、修复后全通过；同时核对 ASR PCM 顺序、aligner PCM 与冻结范围 |
| App 构建与安装 | 仓库包装脚本 BUILD SUCCEEDED；本地 XPC 门禁、签名静态验证和唯一安装检查通过，路径为 `~/Applications/SpeechRail.app` |
| 服务安装 | 3.10.0；保留 quality/quality 与 generation 13，selection 与安装前逐字节一致，唯一 8201 listener；9 个修复模块与 wheel、源码哈希一致 |
| 首次真实模型 ASR/对齐/分人 | 6 段非空定稿、6 次对齐成功、A/B 两位说话人，对齐/分人失败均为 0 |
| Chrome 会议采集 | 31 段全部完成对齐与分人，归档后两位说话人及用户显示名编辑保留 |
| 窄窗口滚动、暂停/恢复/结束 | 上翻出现 2 条未读；跳回后新增 3 段仍贴底、无误报；最终 32 段、两位说话人。该场 31 段对齐，1 段返回模型时间越界；与样本边界错误分别记录 |
| 最终服务真实模型收尾复查 | 511 样本分包，4 次带重采样尾样本的提交；6 段非空定稿、6 次对齐成功、A/B 两位说话人，对齐/分人失败均为 0 |
| 最终服务真实模型截断边界复查 | 同一组 12 个合成片段，修复前 11 次对齐成功、1 次最近尾格点越界；修复后 12 次全部成功，分出 A/B，无对齐/分人失败 |
| 最终服务字幕 UI 收尾 | 53 秒真实采集后停止并归档，10 段全部对齐、9 段有匿名说话人标签，diarization 为 active、无失败诊断；麦克风与实时连接释放 |
| App CPU 实机采样 | 三轮共 329 个 5 秒采样，分别覆盖 6 分 25 秒、8 分 51 秒、11 分 57 秒；峰值分别 20.3%、38.8%、33.4%，无达到 90% 的采样；未复现单核占满、卡死或布局崩溃 |

构建 App 使用从任务起点创建的隔离 worktree，仅合入本次 11 个 Swift 文件，避免将并行的有声书/音色任务一并安装。Python wheel 从当前已核验源码构建，版本未递增，也未创建提交、tag 或远端发布。

最终服务 wheel SHA-256：`ef9d77dcdeda80190b84bd8c960d6d1085ddc5061f331bfbb7f88e7cd6845ccb`。
App 可执行文件 SHA-256：`9c39874513c3090209998e11da21188aeb57051d168353707061fc7f67461a33`。
服务回退点为原 `3278b88ab848` release；App 原版 ZIP 与 selection 快照位于仓库外本次修复缓存的 `rollback/`。回退时仍须走 managed controller 与唯一安装流程，保留当前用户数据、私有配置和模型。

10:51 CST 运行态复核：service PID 24101，唯一 8201 listener，`/health=ok`、`/readyz.ready=true`，
quality/quality、generation 13；batch/realtime active requests 与实时会话均为 0，最终服务启动以来
对齐失败计数为 0。App 3.10.0 / build 52，唯一安装与 local XPC 验证通过；最新 App 自 10:16 起
未产生新的崩溃报告。隔离构建 worktree 已归档，修复源码仍保留在原工作区。

验收收尾：临时内存音频服务器与内置浏览器测试页已关闭。Mac 锁屏后，无法继续恢复本次测试
选择的 Chrome 会议采集来源、关闭 Chrome 测试页；已请求用户解锁。会议与字幕均已停止，
麦克风已释放，服务保持运行。该限制只涉及测试界面清理，不影响上面的修复与实测结果。

已发现的独立问题：会议自动整理纪要返回 HTTP 400，App 明确保留文字记录并提示重试；该 LLM 调用未在本次 ASR/分人修复中调整。首次 TCC 弹窗、来源重启恢复、Distribution 签名/公证、多设备与蓝牙、多人声学质量基准、长时稳定性未包含在本次验收结论中。

模型时间精度依据：本机实际 snapshot 的 `timestamp_segment_time=80`，与
[Qwen 官方配置](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B-hf/blob/c07281df297b9905d24a508279258cccf987a064/processor_config.json)
一致（2026-10-16 核实）。尾格点相交规则是 SpeechRail 适配层的明确策略，最大调整为模型半格，
并非对所有供应商时间放宽公差。
