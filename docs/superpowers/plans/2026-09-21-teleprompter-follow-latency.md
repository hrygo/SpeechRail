# 提词器实时跟读延迟执行方案

> 状态：核心跟读链路已实施并通过确定性回归；当前源代码已替换本机 managed runtime，真实 Realtime 协议探针和签名 App 安装态校验已通过。真人音频质量、长时 p95 与前台 UI 验收仍未执行，不把协议 smoke 误报为质量结论。

**Goal:** 连续朗读期间更新阅读位置，识别文本修订不再导致等待断句，延迟与错误推进均可测量。

**Architecture:** 为同一 Realtime 连接协商可修订的全文快照，保持标准 delta 的追加语义。提词器按会话选择识别分块，使用局部证据更新暂定位置，final 负责核对；不增加 LLM、不复制模型进程。

**Tech Stack:** Python 3.12、现有 Qwen3/MLX worker、WebSocket、Swift 6、SwiftUI/macOS 26+。

**Spec:** `docs/superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md` §10.3；实施时同步修订该节及 Realtime 契约。

**核实日期:** 2026-09-21。外部文档为当日查询；本机依赖事实以安装文件为准，不以 upstream main 替代。

## 已确认事实与结论边界

| 事实 | 证据及含义 |
|---|---|
| 服务为 3.0.2，quality、asr-1.7b-q8，Silero + speech admission | 本机当前 `/health`、`/readyz` 和 managed service status；安装后 PID 90161。当前 streaming 为 active；这是安装后核验时刻状态，不能外推所有朗读时刻 |
| 分块配置解析为 2.0 秒 | managed runtime 的 Settings.from_env_file 读取当前受管配置；selection 覆盖项没有 chunk 参数。不是对活动进程内存的直接读取 |
| 安装态也有 partial 前缀抑制 | 安装态 `speechrail/application/realtime_openai.py:1515` 与当前源码同一条件：不以 last_partial_text 开头则 continue |
| 本机 vendor 为 mlx-qwen3-asr 0.3.5 | vendor/current 指向的 dist-info 与 streaming.py；不等同于网上最新算法 |
| vendor 确实能产生改写 | 抽取安装态 `_append_chunk_text` 纯函数执行：相同中文前六字、后文修订且长度增加时返回修订全文；结果不以旧全文开头。仅输出布尔值和字符数，无模型加载 |
| 改写后等待 final 是已有行为 | `tests/test_realtime_openai.py::test_realtime_partial_rewrite_is_withheld_until_final`；本会话该测试及正常追加测试均通过。首次运行被全局覆盖率门槛挡住，使用 --no-cov 的同范围重跑通过 |
| App 要求两次增长证据 | FollowController：当前 >=5 tokens、上次 >=3 tokens、score >=0.88，且 aligner 已通过歧义检查。上次 >=3 是 token 数，不是三次事件 |
| 舞台按 12 个归一化字词切片滚动 | 高亮按 readingOffset 更新，滚动只在 slice ID 改变时发生；中文约 4–6 字/秒时，切片滚动本身可能呈约 2–3 秒阶梯，不能与识别冻结混为一谈 |

判定：存在三种独立且可能叠加的延迟：2 秒识别发布周期、两次证据等待、改写被协议适配层压住。主线程计算/音频发送积压尚无耗时证据，列为测量项而非已确认根因。尚未复现用户那一次真人朗读的完整时间线，也未核实该次使用的 App bundle 与源码一致。

不采用“只换 stable_text”：本机 0.3.5 前两块不扩展 stable_text，第三块才尝试发布且保留末尾五个单位；2 秒分块下首次稳定输出可能在约 6 秒后，短句仍等 final。该字段按长度保留旧值，不足以证明所有同长或增长修订均保持前缀，不能未经校验当成不可变承诺。

## 调研依据与决策

1. [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)：delta 是新可用文本，completed 是 item 的最终全文；跨 turn 完成顺序不保证。沿用标准事件语义，以 item ID 对账，不向 delta 塞替换全文。
2. [Qwen 官方流式实现](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py)：支持 unfixed chunk/token 回退，说明中间假设可修订。该实现不是本机 MLX 0.3.5，不照搬其性能数字和参数结论。
3. [MLX 实现维护者文档](https://github.com/moona3k/mlx-qwen3-asr)：提供流式状态、稳定性/改写率诊断；本机实际版本已直接读源码核验。本次不升级依赖。
4. [Amazon Transcribe partial results](https://docs.aws.amazon.com/transcribe/latest/dg/streaming-partial-results.html)：明确区分可变 partial 与稳定项，低延迟与稳定性存在权衡。借鉴语义分层，不引入 AWS 服务。

选择：本地服务新增协商的 snapshot 输出模式，提词器消费可变假设；标准 delta 模式维持标准追加协议。这里保留标准模式是公共协议边界，不是历史 alias 或旧行为迁移。不能通过更短 VAD、定时强制 commit 或按目标时长自动滚动掩盖延迟。

## 全局约束

- 修改仅限跟读链路、必要契约、相关测试和文档；保留现有 LLM/整理稿件等并行改动。
- 不使用 LLM 参与实时位置计算；不改变正文，不把估计语速当成已朗读事实。
- 同一个共享 worker、一个服务；识别分块为会话参数，不修改整个服务默认档位。
- 继续使用既有 WebSocket 客户端；此次不扩展为 SDK 替换工程。
- 不记录原文、完整转写、音频或文本 hash；诊断仅记录时长、计数、revision、样本游标及会话内匿名关联值，限内存或仓库外脱敏结果。
- 不删除或迁移用户数据。发布、服务重启与 UI 自动化依各自授权执行；本计划本身不扩大授权。

## 协议与数据流

提词器在发送任何音频之前请求：

```json
{"type":"transcription_session.update","session":{"speechrail":{"transcription":{"partial_mode":"snapshot","chunk_duration_ms":500}}}}
```

这是拟新增字段，不是当前可用接口。服务端在 updated 回显实际接受的模式与分块；unknown mode/非白名单时长返回 invalid_event；后端不支持返回 unsupported_operation。已有音频后更改这两个字段返回 invalid_state。App 收到匹配的确认后才开始采集，不静默忽略协商失败。

```json
{"type":"speechrail.transcription.snapshot","event_id":"evt_1","item_id":"item_1","content_index":0,"revision":1,"text":"本条最新识别全文"}
```

- revision 在一个 item 内从 1 严格增长；只在全文改变时递增，空文本修订也必须发送。
- 同一会话选择 snapshot 时不再重复发送该 item 的标准 delta；completed/failed 保留，completed 全文为最终权威值。
- snapshot 直接转发最新假设，不受 last_partial_text 的 startswith 条件约束。标准 delta 模式继续执行其追加语义。
- App 按 connection generation + item ID 隔离状态；event ID 去重，revision <= high-water 时忽略；final 退休 item，之后任何快照均不能复活它。
- 文本不是拼接：`item.text = snapshot.text`，随后归一化，保留现有 2048 字符/72 匹配 tokens 边界；完整 wire 文本大小按现有 domain 最大长度和消息上限校验。
- completed 可越过旧 partial 的计算结果，但不能漏处理；跨 item 不采用“最后到的 final 必然最新”的假设，沿用并核对已有 item 顺序规则。

## 分块与跟读算法

### 识别节奏

新增 domain `RealtimeTranscriptionOptions(chunk_duration_ms: int)`，factory.create 显式接收 options；普通会话从当前配置构造，提词器使用协商值。会话保存唯一 resolved chunk 值，同时传入 Qwen3StreamingSession → worker session.open → vendor init_streaming，并用于服务端音频 flush 阈值。不能只把 flush 改快而模型仍等 2 秒。

首轮实验白名单 500、1000、2000 ms；500 为目标候选，不是已验证默认。与 2000 基线使用同一批已授权音频串行比较；如果 500 达不到下述质量与时延门槛，则测 1000，选满足门槛的最低延迟配置。全部不达标则报告当前后端达不到验收，不静默降标准或切换模型。400ms VAD 与 accuracy finalization 先保持不变。

### 位置确认

保留现有半全局编辑距离、归一化、歧义分差和有界窗口；区分 candidate、provisional、committed 三种位置。

- candidate：每个新 revision 的局部匹配结果，不能直接成为已读事实。
- provisional：允许推进阅读高亮与舞台；首次为唯一精确匹配 >=8 tokens，且起点在锚点前后 4 tokens 内时，可单次推进。不能仅用末尾接近锚点证明连续。
- 其他正常前进继续要求两次不同 revision、同一路径且终点增长、score >=0.88、当前匹配 >=5、上次 >=3。不能仅凭文本长度增长判断证据一致。
- 相同文本、重复事件、同终点改写均不计第二次增长证据。需要在 Aligner.Match 增加本次对齐起点的全局 token 坐标，供路径一致性与近锚点判定使用。
- partial 后退只更新 candidate，等待下一次一致定位或 final；歧义时冻结 provisional，不按时钟猜测前进。
- final 按现有接受阈值核对；明确匹配可以前进/重读后退。无法支持暂定位置时回 item anchor 并标记待确认，不能继续宣称已确认。
- final/暂停/手动/结束/重连都构成屏障，旧计算即使完成也不能写回。应用 generation、item ID、revision 的三重检查。

### 展示与计算

先保留 12-token 切片和原有动效，分别测高亮滞后与切片滚动间隔；不把切片未换行误算成语音延迟。如位置及时但阅读区域仍明显落后，在同一套 token/阅读坐标下调整可视定位，验收时同时观察高亮和滚动，禁止按估时虚构阅读进度。

先测量再决定后台搬移：如果 handle/align 的 p95 >20ms 或 App 本地事件 queue age p95 >50ms，将纯 FollowController 放到串行 worker actor；MainActor 只发布状态。最多保留每个 item 一个待算最新快照和一个正在处理的快照；保存最多 8 个活动 item。允许跳过的是可替代快照，delta/terminal/控制事件不能任意丢弃。只有走这条优化路径才增加 mailbox，不改全局 AsyncStream 为 bufferingNewest(1)。UI 最多每 100ms 发布一次最新位置，terminal 立即发布；这不能补救上游 2 秒无新文本。

## 执行任务与验证

### Task 1：先建立可归因的时延证据

**Files:** `src/speechrail/application/realtime_openai.py`、`src/speechrail/observability/metrics.py`、`macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift`、`TeleprompterSession.swift`；新增 `tools/probe_teleprompter_latency.py` 与 `tests/test_teleprompter_latency_probe.py`。

- [x] 为 partial 增加产生/转发/因修订跳过计数，复用 asr_flush、commit 耗时指标；不得使用 item ID 作为全局 metrics label。
- [x] App 用 ContinuousClock 记录 socket 接收、handle 开始、匹配结束、状态发布；采集段记录样本序号与本地采集时刻，单独计算上传等待。服务端使用自身 monotonic，不能直接减两端未同步的时钟。
- [x] 探针按真实时间每 100ms 上传本地 PCM；慢发送时记录 lateness，不通过突发补发伪造实时测试。输出只含统计与匿名序号；不持久化转写。已用 1 秒静音 PCM fixture 运行安装态协议 smoke；真人语音和质量验收仍未覆盖。
- [ ] fake 测试注入 producer 不更新、改写被抑制、消费者延迟三种情况，分别断言 update_gap、withheld_count、queue_age 归因正确；同源时钟用虚拟时钟断言 100ms 延迟准确，不用 sleep 断言。
- [ ] 基线采集同时记录 App bundle/version、服务版本、vendor 版本、effective chunk、冷/暖状态。冷启动到 ready 与 ready 后跟读延迟分开报告。

### Task 2：实现快照契约与完整事件生命周期

**Files:** `contracts/realtime-openai.md`、`src/speechrail/compatibility/openai_realtime.py`、`src/speechrail/application/realtime_openai.py`、`tests/test_realtime_openai.py`、`macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift`；新增 `SpeechRailMacControlTests/TeleprompterSnapshotTests.swift`。

- [ ] 新增 snapshot serializer、session 配置解析/回显和 per-item revision，代码语义为：

```python
# snapshot 分支；seen_text 初始为 None，revision 初始为 0
if text != seen_text:
    revision += 1
    await send_snapshot(item_id=item_id, revision=revision, text=text)
    seen_text = text
```

- [ ] 先增加契约测试：输入 `abc → adc → adce → completed(adce)`，snapshot 应在 final 前依次输出三条，revision 1/2/3；标准模式仍只输出可追加 delta。再实现并验证。
- [ ] 覆盖非空→空修订、重复全文不递增、无 partial 的 final、failed、旧 item final/快照、重连 generation、非法字段/超长文本、协商后才开始采集。
- [ ] App 新事件使用 snapshot 替换语义，解析失败以明确流错误处理，不追加、不复用旧 revision。普通调用方保持现有默认模式。

### Task 3：会话级分块贯通

**Files:** `src/speechrail/domain/ports.py`、`src/speechrail/backends/qwen3_streaming.py`、`src/speechrail/backends/qwen3_worker.py`、`src/speechrail/application/realtime_openai.py`、`tests/test_qwen3_streaming.py`、`tests/test_qwen3_worker.py`、`tests/test_realtime_openai.py`。

- [ ] 增加 RealtimeTranscriptionOptions，并更新所有 factory 实现及 fake，不保留旧签名兼容层。
- [ ] fake worker 检查 session.open 的 chunk_sec；16k PCM16 下 500ms 的阈值是 16000 bytes，1000ms 是 32000，2000ms 是 64000；逐项断言模型值与 flush 值相同。
- [ ] 覆盖 speech admission 和普通路径、跨阈值的非整块音频、commit 尾部、不足一块短句、超出白名单、音频开始后改参数、后端拒绝。长 turn rollover 必须继承协商值。
- [ ] 参数只影响本会话；不修改共享 worker 全局配置，不取消资源准入。

### Task 4：跟读确认与舞台体验

**Files:** `macos/SpeechRailApp/SpeechRailApp/TeleprompterAligner.swift`、`TeleprompterFollowController.swift`、`TeleprompterSession.swift`；`SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift`、新增 `TeleprompterSnapshotTests.swift`；确有展示修改才涉及 `TeleprompterStageView.swift` 与设计 Token/设计文档。

- [ ] 增加 match 起点坐标、revision 高水位和全文替换输入；已有 delta 入口只用于标准模式。
- [ ] 先测唯一近锚点 8-token 单快照前进、同文本不算第二证据、改写跨 revision 保持正确位置；再实现上述确认算法。
- [ ] 测重复段不跳、同 segment 内后退、跨 segment 跳读、脱稿返回、final 推翻 partial、final 后快照、暂停/手动/重连期间迟到结果均不推进。
- [ ] 使用上限长度稿件测 Script 初始化与单次定位耗时，分别报告冷构建与稳态。仅触发阈值时实施后台串行 actor/mailbox，并增加“旧计算结果不能覆盖新 revision”的可控并发测试。
- [ ] 根据位置延迟与展示延迟分别验收；必要的 UI 自动化须逐次明确授权。手动观察结果不能冒充帧级自动化测量。

### Task 5：真实链路验收与交付

**Files:** `docs/superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md` §10.3/AC、`contracts/realtime-openai.md`、`docs/developers/testing-acceptance.md`；真实采样报告放仓库外，仅提交脱敏结论。

- [ ] 定向测试，不跑真实模型单元测试：

```bash
uv run pytest --no-cov -q tests/test_realtime_openai.py tests/test_qwen3_streaming.py tests/test_qwen3_worker.py
swift test --package-path macos/SpeechRailApp --filter TeleprompterFollowControllerTests
swift test --package-path macos/SpeechRailApp --filter TeleprompterSnapshotTests
```

- [ ] 真实音频验收与发布走项目对应 skill；先用已授权、具参考稿和人工时间标记的音频。最少覆盖普通中文、快速中文、英/中英混排、数字术语、噪声、重复段、短句、30秒以上不停顿。真实模型不进确定性单元测试。
- [ ] 2秒、1秒、0.5秒对照串行进行。先暖态测吞吐，冷启动单列；至少一段10分钟连续流检查迟延是否累积。不要仅使用合成语音得出生产结论。
- [x] 完成契约/单测/质量门槛后构建同一 revision 的服务和 App；已替换 managed runtime、重启服务并核对版本、健康状态与协商回显；已安装签名 App 并通过 XPC/codesign 静态校验。不能用源码通过测试证明安装态已修复。
- [ ] 无数据迁移；回退使用保留的 App 与 managed runtime 版本并恢复原会话策略，不改模型/用户稿件。提交、推送、PR、部署分别按已有授权处理，不自动合并。

## 验收标准（目标，非当前实测）

| 层次 | 接受条件 |
|---|---|
| 快照正确性 | fake 中每次不同修订在 final 前可见；无重复拼接、丢 final、退休 item 复活；协商值一致 |
| App 处理 | 暖态本地 queue age p95 <=50ms，单次匹配 p95 <=20ms；超限有明确归因与相应优化 |
| 连续跟读 | 可唯一定位区间，口述词结束→对应高亮 p95 <=1.5秒；首次可定位8-token片段结束→首次推进 <=2秒；报告覆盖率，不能通过大量冻结规避延迟指标 |
| 正确性 | 明确无歧义文本正确定位覆盖率 >=95%；重复/脱稿专项零错误跨段跳转；final 全文 CER/WER 相对2秒基线劣化 <=1个百分点；不同语言分别报告 |
| 长时 | 10分钟流最后一分钟与第一分钟暖态 queue age p95 差 <=100ms，音频零静默丢弃，输入欠载/超载明确报告 |
| 体验 | 连续朗读无需故意停顿才能推进；切片滚动与已读高亮分开验证；未知位置明确提示，不预测未读字 |

若没有词时间戳，真实延迟使用人工参考时间标记；服务采样时间只能代表已处理音频上界，不能冒充每个字的声学结束时刻。现有事件没有足够时间戳时，验收必须先补采证据。

## 复核重点

- 同长修订、修订为空、修订长度缩短：snapshot 必须替换且 revision 单调（Task 2/4）。
- 重复标题/相似句：单快照快路径必须同时满足唯一、精确、近锚点（Task 4）。
- 短句早于第二块结束：不能由两次事件门槛强制等下一句；final 立即处理（Task 3/4）。
- 跨 item final 乱序/连接重建：以身份与屏障判定，不能按到达顺序覆盖（Task 2/4）。
- 模型慢于实时或音频缓冲溢出：不得无限追赶或悄悄丢音频；记录并给出明确状态（Task 1/5）。

## 实施结果（2026-09-21）

- 已实施 Task 2：新增 `speechrail.transcription.snapshot`、会话级 `partial_mode/chunk_duration_ms` 协商与回显；默认 `delta/2000ms` 保持不变；snapshot 以 item 内严格递增 revision 发送，重复全文不发送。
- 连接生命周期已补强：`RealtimeASRClient.connect()` 等待 `transcription_session.updated`，服务端错误或超时失败关闭；提词器在确认后才启动音频源。
- 已实施 Task 3：`chunk_duration_ms` 从 WebSocket 会话配置贯穿到 `RealtimeTranscriptionOptions`、Qwen3 streaming worker 和服务端 flush 阈值；首个 PCM 后修改返回 `invalid_state`。
- 已实施 Task 4：App 解析快照并按全文替换，FollowController 做 event ID 去重、revision high-water、final 屏障和同 segment 严格单调推进；普通 delta 调用方保持追加语义。现有保守的两次证据门槛仍是默认路径，仅对“唯一、精确、至少 8 tokens、起点近锚点”的 snapshot 开启单快照快进；连续长稿回归测试保持通过。
- Task 1 已增加无文本内容的 partial outcome 计数（`delta_sent`、`snapshot_sent`、`rewrite_withheld`、`duplicate_suppressed`），并在 App 记录 capture→send、事件 queue age、匹配耗时的本地 monotonic 样本；跨进程校准与真人语音质量仍未验证。安装态静音协议 probe 通过：`snapshot + 500ms` 协商成功，收到 `transcription_session.updated`、snapshot 和 completed，`revision_regressions=0`。
- Task 5 的确定性与安装态验证已完成：Python 全套、Swift 138 个 XCTest + 71 个 Swift Testing（10 suites）、App Debug 编译、Xcode `SpeechRailAppTests` unit-test target、ruff、mypy 均通过；测试 target 已修正为不再把 App-only SwiftUI Sheet 编译进测试源。当前源 wheel 已替换 managed runtime，单一 LaunchAgent 健康运行；签名 App 已安装并通过 XPC/codesign 校验。没有执行前台 UI 自动化，也没有真人语音、WER/CER、10 分钟长时或 p95 质量验收。
- 安装态差异已闭环：替换前的旧 runtime 对 `snapshot + 500ms` 返回 `invalid_speechrail_extension`；替换后协议 smoke 成功，且服务端确认无活动 Realtime session、无 active batch/realtime governor request。旧 runtime 与旧 App 均保留在可回退位置/目录，未做数据迁移或删除。

保留项：如果后续真实测量确认本地匹配 p95 超过计划阈值，再实施 FollowController 串行 worker/mailbox；如果真实音频仍显示非唯一/非近锚点场景滞后，再根据采样数据调整门槛。唯一近锚点快路径已经以严格条件实现，不扩大到有歧义的 snapshot。
