---
title: "语音助手用户旅程优化：Luna 详细执行方案"
status: proposed
version: "0.1.0"
date: 2026-10-03
---

# 语音助手用户旅程优化：Luna 详细执行方案

- 原方案：[SpeechRail 语音助手：按用户旅程优化的详细可执行方案](SpeechRail_Voice_Assistant_User_Journey_Executable_Plan_2026-10-03.md)。已从 Downloads 原样移动至本目录，SHA-256：`6ecc49163cc03dbcea08f98347cba8ddfc4dbe6ca44b53bd232b17131d62ebf6`。
- 本地核验：2026-10-03，Asia/Shanghai；`main`，HEAD `be75055cc0a5f7f044ae56c955896812a1d69915`，与原方案基线一致。未核验远端是否存在后续提交。
- 本轮范围：原方案移动、源码与契约分析、执行方案落盘。业务代码、数据库、服务配置均未修改；测试、构建、真实模型、录音、UI 自动化、提交、推送和发布均未执行。
- 已存在的三份未跟踪文档属于其他任务：`2026-10-03-roi-evolution-luna-guide.md`、`2026-10-03-teleprompter-user-journey-luna-guide.md`、`SpeechRail_Teleprompter_User_Journey_Executable_Plan_2026-10-03.md`。不得修改或混入本任务交付。
- **100% 的口径是方案需求覆盖**：F01～F18、VA-01～VA-18、A01～A60及原方案各章节均有实施或条件决策落点。它不表示代码覆盖率、测试通过率、真实质量或性能已经达到 100%。验收状态初始全部为 `not_run`。
- 路径简写：`APP` = `macos/SpeechRailApp/SpeechRailApp/`；`TEST` = `macos/SpeechRailApp/SpeechRailMacControlTests/`；命令默认在仓库根目录执行。下文标为“拟新增”的类型、方法、文件、测试和工具尚不存在，不能当成现有接口调用。
- 原方案中的远端分支、Draft PR、发布、性能目标和运行命令均为材料建议，不构成授权。后续实施按当时用户要求与 `AGENTS.md` 执行。

## 1. 问题结论

推荐保留现有编排、共享音频引擎、caller-owned 增量 TTS 和本地记录库，先修所有权与收尾，再完成文字/语音旅程，最后用证据决定声学策略和性能优化。

本地静态复核确认三个优先反例具备代码依据：

1. `AssistantView.endConversation()` 调用全局 `SessionCoordinator.stopCapture`，而文字助手并不持有该协调器的设备占用。必须将助手结束动作绑定自己的记录与租约。
2. `startPump` 的唯一事件消费者依次 `await handle`；`noteSpeechEvidence` 等待 `interruptCurrentReply → tts.cancel → 匹配 terminal`，匹配 terminal 又需要同一消费者继续处理。必须把终态等待移至有所有权的异步副作用。
3. `stopCapture` 在 drain 前递增 `connectionToken`，`handle` 先以它过滤事件；合法尾句可能在应用侧被丢弃。必须保留有界 draining 接收资格，先完成网络水位，再完成应用保存水位。

随后处理跨 `await` 的回复事务、迟到事件、副作用身份、模型目的地冻结、文字降级、真实状态展示、朗读分包保真、播放交付、记忆与记录闭环。

以上为源码事实及静态风险，未在本机运行复现。不得把“完成本方案”写成“修复已通过”。

| 里程碑 | 工作范围 | 必须得到的结果 |
|---|---|---|
| M0 安全底座 | VA-17 的 fake 工装；VA-01～06；VA-16 最小计数 | 助手不误停别的会话；终态能被接收；尾句能归档；旧操作不能覆盖新会话；路由不漂移 |
| M1 默认旅程 | VA-07～10；VA-15 标签与失败处理 | 文字独立可用；恢复语音显式；首屏和状态真实；草稿、焦点、滚动、记录操作可恢复 |
| M2 朗读与声学证据 | VA-11～13、VA-16～17 | 等价分包保真；播放证据分层；真实接话/插话/设备与长时验证有独立结果 |
| M3 长对话与增强 | VA-14、VA-15 上下文续接、VA-18 | 上下文有预算；记忆经审阅；旧记录可显式续接；优化以对照报告决定 |

M0/M1 可先交付；M2/M3 全部保留执行定义。未授权或未测的真实验收不允许用 fake 结果代替。

## 2. 当前实现与根因

### 2.1 历史依据、有效契约与证据限制

> 🧠 **From Hindsight memory (SpeechRail 组件职责与权威边界)** — 历史决定将 LLM、history、memory、persona、播放与 barge-in 归调用方，服务保持无状态 Speech Plane。本方案沿用这一职责边界；当前依据已核对 `contracts/realtime-openai.md` 的责任边界与客户端编排。

> 🧠 **From Hindsight memory (SpeechRail 开发约定与验证方法)** — 历史约定要求能力语义变更补显式回归，契约变化同步契约与用户文档，并保留并行改动。当前依据是根 `AGENTS.md`、测试验收文档和生产 `AssistantSession` 的依赖注入测试；历史测试成绩未当成本轮实测。

图谱：`Users-hrygo-Documents-SpeechRail`，generation `2026-10-01T23:35:51Z`。已执行 `check_index_coverage`：`AssistantSession`、`AssistantView`、`App` 有解析缺口，`RealtimeASRClient` 为 unusable，`LLMProvider` 与其测试显示 `metadata_changed`。关键结论使用对应源码直接核验；未逐行审计这些文件的全部范围，也不据图谱声称完整影响分析。图谱 trace 出现同名 `cancel` 跨语言候选，未将其当成真实调用证据。实施前不重建索引，只重新核验变化范围。

当前 wire 固定 24 kHz mono PCM16，输入收尾 receipt 的 `accepted_samples` 是连接累计接受样本数；它证明服务处理水位，不能证明应用数据库提交。服务没有 `speech_started`/`speech_stopped`，也不支持由本方案自行假定的 `response.cancel`、`conversation.item.truncate` 或云端 `semantic_vad`。

原方案 E01～E08 是原作者的官方资料索引。本轮不把其 2026-10-03 查阅记录扩展成新的在线验证成绩；实施 Apple 播放回调变化时，按 VA-12 再核对当时 SDK 与官方定义。

### 2.2 源码定位与处理映射

| 原发现 | 当前文件与符号 | 已核验逻辑、直接原因 | 落点 |
|---|---|---|---|
| F01 | `AssistantView.endConversation/restartWithPersonaPick`；`SessionCoordinator.stopCapture` | View 结束当前全局 occupancy；纯文字建档不占 occupancy | VA-01 |
| F02 | `AssistantSession.startPump/handle/noteSpeechEvidence`；`AssistantTTSStreamCoordinator.cancel` | 顺序接收者等待自己负责送达的终态 | VA-02 |
| F03 | `AssistantSession.stopCapture/handle`；`RealtimeASRClient.drainAndClear` | connection 先失效；receipt 在客户端内部处理，不向编排层发布应用保存标记 | VA-03 |
| F04 | `persistReplyPartial/finalizeReply`；`AssistantReplyState` | partial 写回旧值副本；finalize 的 `isCurrent` 在 await 前计算，once 标记仅写局部副本 | VA-04 |
| F05 | `ask/commitUserTurn/beginReply` | 取消旧 reply Task 后直接顶替 `currentReply`，未统一前任收尾 | VA-04 |
| F06 | `handle(.ttsAudio/.ttsEnded)`、`makeTTSStreamCoordinator.onOutcome` | request 校验前改 speaking/闭麦；外围终态与 outcome 忽略完整归属 | VA-05 |
| F07 | `createConversationRecord/tearDownPrivate` | 旧建档 await 返回后无条件清当前 source/client/tts 引用 | VA-05 |
| F08 | `BlockReason.allowsTyping/ask/statusTitle`；View 状态带 | 语音失败排除 typing；View 重推 phase 并可能借用全局 elapsed | VA-07～08 |
| F09 | `openVoiceTransport/runReply/ensureTextConversation` | 每轮重新解析 preferences；文字初始化未加载本场记忆 | VA-06 |
| F10 | `AssistantView.statusFacts`、首屏 | 以模型名存在冒充连接；硬编码就绪和说话即录；数据去向说明不足 | VA-08 |
| F11 | `AssistantSpeechTextBuffer.append/sendChunk` | delta 大于 TTS chunk 上限即拒绝；且拒绝前已经修改 pending/offered；服务协商限额仅在发送时检查 | VA-11 |
| F12 | `AssistantAudioSession.enqueuePlayback`、`AssistantAudioPlayback`、`AssistantPlaybackLedger`；history | rendered 回调承担整轮完成；history 保存全生成文本，缺交付说明 | VA-12、14 |
| F13 | `sendPrompt`、turn count 的 scrollTo、`turnRow/replay` | 示例覆盖草稿；新增行强制滚底；无 TTS 静默 return | VA-09、12 |
| F14 | 声音测试示例；`previewSelectedVoice` | “测试朗读”走文字 ask，按现有规则不自动朗读；已有音色试听入口应复用 | VA-12 |
| F15 | `handle(.partialSnapshot/.completed)` | 空 snapshot 也 noteSpeechEvidence；final-only 不走同一接管策略 | VA-02、13 |
| F16 | `runReply`；`VoicePrompt.instructions/styleBlock` | 所有输入使用“来自语音、将朗读”的提示词 | VA-10 |
| F17 | `continueFromReview/remember`；`AssistantMemoryKind` | 继续只 prefill；记住整行立即以 fact 保存；类型现为 fact/preference/summary | VA-14～15 |
| F18 | View 资产操作；`SessionCoordinator.finalize/sealSession` | `try?` 隐藏写入/读取失败；封存失败仍发布成功 ID | VA-03、15 |

额外已核验事实：

- `SessionStore.schemaVersion == 1`；`migrate()` 当前仅从空库建 `schemaV1`，不能直接 bump 后对 v1 重执行建表。
- `finalizeAssistantLine` 已有 `id + session_id + role` 守卫、affected-row 检查和 interrupted 单向合并；保留这些规则。不要把任何 SQL 错误都当“行不存在”并 fallback INSERT。
- `AudioEngineSession.stop()` 的硬件 teardown 在队列异步执行，返回不证明释放完成；`stopPlayback()` 已可等待。
- ring 和 capture AsyncStream 已有界，后者为 `.bufferingNewest(64)`；当前 yield/drop 与 ring 满丢样未完整反馈。不要用新无界队列替换。
- `LLMProvider` 已要求匹配 response 的 `response.completed`；EOF/`[DONE]` 不算成功，已有对应测试。`failed/incomplete` 当前归入 `LLMError.refused`，需改进分类，不需要重做 SSE 或 SDK transport。
- `SessionExportPanel.write` 已处理文件写入失败并返回 Bool；主要缺口是 View 将库读取失败转换为空数组。不要另建一套导出器。
- `Package.swift` 和 Xcode project 都有显式 source membership；新生产文件与测试要加入对应目标。

## 3. 目标行为

### 3.1 控制与内容不变量

1. 助手“结束”捕获本场身份，文字结束不改会议/字幕/提词器的 occupancy、phase、设备、记录或 stopper。
2. 新输入按顺序接纳；前任回复先撤输出权、停止/取消并收尾，再启动下一次 TTS。重试原问题不得重复插入用户行。
3. 接收事件先校验 session/connection/request/epoch，再发生 UI、闭麦、错误、预算、内容副作用；退休 terminal 只能解除自己的屏障。
4. 接收循环不等待需要它继续消费才可完成的条件；长等待由可取消、可回收、有身份的 effect 持有。
5. 结束时停止新的输入生产，但 draining 连接可处理合法 final。final 只归档、不调用 LLM/TTS；receipt 与落库屏障分别验证。
6. 已生成、已播放、已保存独立呈现；生成正文完整保留，不以帧比例编造“已读文本”。
7. 所有保存失败保留内存待保存内容与重试/复制出口；不发布成功 ID，也不把 SQL 错误冒充网络故障。
8. 模型目的地、配置、人设与记忆按本场快照生效；全局设置变更显示“下次新对话生效”，不得自动换备用 endpoint。
9. 文字可用性只看 LLM/Store/本场结束状态，语音故障和别的功能占麦克风不能直接阻断它。
10. 原始输入和回答留在记录中；ASR 未确认片段标“识别未完成”，不能自动交 LLM。
11. 日志与评估报告仅包含匿名计数、时长、错误分类和版本；无 PCM、Base64、完整文本/prompt、秘密或可复原文本 hash。

### 3.2 十二态产品合同

| 状态 | 必须显示 | 主动作、限制 |
|---|---|---|
| 未配置 | 还没有配置对话模型；麦克风未开启 | 就地设置；保留草稿，打开页面不申请权限 |
| 已配置未开始 | 模型已配置，尚未检查；麦克风未开启 | 发送、开始语音；不显示已连接/语音就绪 |
| 启动中 | 正在准备语音 | 取消准备；草稿可编辑，开始单飞 |
| 文字对话 | 文字对话 | 发送、开启语音、结束；无电平或别的功能计时 |
| 语音聆听 | 正在聆听 | 静音、发送、结束；仅在真实采集时显示电平 |
| 生成中 | 正在回答 | 停止回答、继续写；新提交按确定顺序接管 |
| 播放中 | 正在朗读 | 停止朗读/回答；实时对讲允许有效插话 |
| 用户静音 | 麦克风已静音，暂停上传 | 取消静音；解释仍持本地设备；关闭语音才释放 |
| 语音故障可打字 | 语音已中断，可以继续打字 | 发送、重试语音；保留本场记录和上下文 |
| 保存失败 | 部分内容还没保存 | 重试保存、复制；禁止“已保存”成功带 |
| 正在结束 | 正在收下最后一句并保存 | 禁新回复/新语音；重复结束共用同一任务 |
| 结束回看 | 已结束，按真实数据标识未完成项 | 导出、改名、移除、用相同设置新建、基于记录继续 |

回看旧记录时另显示活跃助手的简短状态及返回入口；不得用 review 状态隐藏后台采集。

## 4. 推荐解决方案

### 4.1 架构与取舍

沿现有类型扩展，新增小型纯值/策略仅在独立测试需要时提取：

- **拟新增 `AssistantEndTarget`**：记录 ID、会话启动 generation、可选设备 lease ID；供助手专属动作使用。
- **拟新增 `AssistantContextSnapshot`**：已解析 LLMConfiguration、密钥 scope/revision 引用、人设、选中记忆、数据发送同意和上下文预算。密钥值只在现有凭据链与请求内存中。
- **拟新增 `AssistantPresentation`**：由当前事实生成十二态与动作可用性，View 不再猜 phase/全局状态。
- **拟新增 `AssistantReplyLifecycle` 值状态**：基于 replyID 管理正文 revision、收尾 claim、保存结果和 history 投影；延续 `AssistantReplyState`，不增加第二个会话编排 actor。
- **拟新增 `AssistantPlaybackInvocation`**：独立播放 ID、目标 turnID、requestID、epoch、实际 voice pin；首次朗读、重播、试听不混用最后回复身份。
- **拟新增 `AssistantTurnPolicy`**：空证据过滤、重复 revision 去重、final-only 接管；聚合/提前 duck 是独立实验 policy，不默认启用。

采用“顺序轻量归约 + 有所有权的异步副作用”。禁止给每个事件无条件启动独立 Task，禁止复制 AssistantSession、共享引擎或 TTS 队列。

### 4.2 实施边界与条件增强

| 内容 | 本方案决定 |
|---|---|
| 18 个 VA 工作包 | 全部保留；每个包有目标文件、依赖、完成条件和验收行 |
| 真正上下文续接 A50 | 在 M3 明确设计并实施，不用改标签 A49 冒充完成；用户先选择范围，新建记录，不改旧记录 |
| 文字回复朗读 | 当前无通道时禁用并解释；M2 声音测试复用既有试听，不自动开麦。TTS-only 独立通道作为条件增强 |
| ASR-only、TTS-only、按住说话 | 本轮核心交付不强制加入；VA-07/12/13记录进入条件、设计边界与未做原因，不静默丢项 |
| 语义聚合、局部 VAD、duck、摘要 | 先形成基线/fixture/结果字段；有授权与收益证据后实施和启用；无证据保留 `deferred_evidence` |
| 性能优化 | 测量和决策是必交付项；没有瓶颈不凭空修改采集粒度、连接检查或调度 |
| 服务公共协议 | 默认不变；仅增加客户端内部 seam/事件投影。确需 wire 变化时先另列 contract delta，再同步契约与用户文档 |
| 本地 commit | 本文件标出建议提交点；根 `AGENTS.md` 明确“未被明确要求时不自动提交”。后续用户授权提交后按逻辑单元执行 |
| 分支、PR、push、merge、安装发布 | 本轮不执行；实施时按实际授权，原方案 feature/fix 前缀建议改为项目默认 `codex/` |

不引入唤醒词、后台录音、全局裸热键、文件/电脑操作工具、联网搜索、通用 RAG、多 Agent、自动长期记忆、云端同步、实名分人、LLM 声学判定或第二套音频引擎。

### 4.3 覆盖追踪规则

VA 的“完成”需要对应 D 回归和文档一致；U/R 未执行时必须保留独立 `not_run`。工作包覆盖表与 A 场景表不得以区间概括掩盖漏项。

原方案 §0～§19 的对应：§0/1→本文件 §1/2；§2～10→§3/5/7；§11→§4/6；§12/13→§5/10；§14→§7；§15/16→§7/8；§17→§6.7/9；§18→§4.2/9；§19→§2/8。性能目标与隐私约束沿原方案 §15 全量承接。

## 5. 详细实施步骤

### VA-17a：先建立生产路径工装与证据账本

**文件**：`TEST/AssistantSessionTests.swift`、`AssistantPersistenceTests.swift`、`AssistantTTSStreamCoordinatorTests.swift`；`tests/fixtures/assistant_realtime_lifecycle.json`；`APP/AssistantSessionDependencies.swift`。

1. 扩展现有 FakeAssistantLLM 捕获配置、messages、instructions、maxOutputTokens；仅捕获合成 fixture，不读取 Keychain。扩展 FakeAssistantRealtime 的 cancel script，让匹配 terminal 必须经真实事件流送达；fake ACK 改用 `unicodeScalars.count`。
2. Gate 必须能分别阻塞“操作已经进入”“写入已完成但调用尚未返回”；现有 Gate 单 continuation 不适合作为多个并发等待者共享槽。每个操作独立 Gate，或改为按 operationID 管理 waiter，取消后只释放匹配等待者。
3. **拟新增 `AssistantPersistence` 窄协议及测试 adapter**，默认由现有 coordinator 转发 Store。仅覆盖 Session 实际需要的 createSession、appendLine、finalizeAssistantLine、sealSession、memories、noteVoiceChange、setSessionTitle；不暴露原始 SQLite。测试 adapter 包真实临时 Store，能在调用前后注入 Gate/错误；生产不增加 DEBUG 故障开关。
4. fake audio 增加捕获尾部排空、停播屏障、设备停止屏障、rendered/played 回调与旧 epoch 注入；不得构造 AVAudioEngine。
5. **拟新增验收账本**记录 A01～A60的 D/U/R子项、required/deferred、not_run/pass/fail/blocked、命令、base/head、证据位置、时间和未执行理由。mixed 类型不可用一个 pass 隐藏未跑子项。

**完成条件**：可构造 A03/A05/A09/A10/A15 的确定顺序；A03 不直接调 coordinator.handleTerminal；工装没有模型、音频、网络依赖。建议提交点：`test: expose assistant lifecycle races through production seams`，仅在获得提交授权后。

### VA-01：助手专属结束与租约隔离

**依赖**：VA-17a。**文件**：`APP/AssistantSession.swift`、`AssistantView.swift`、`SessionCoordinator.swift`、`App.swift`、`ControlMenuView.swift`；拟新增 `TEST/AssistantEndRoutingTests.swift`。

1. 在 coordinator 获得设备时生成 **拟新增 `activeLeaseID`**；preparing 阶段尚无 recordID 也能锁定租约。结束目标不能只比 `.assistant`，否则旧助手 A 的迟到结束仍会结束新助手 B。
2. **拟新增 `AssistantSession.endConversation(target:)`** 与 single-flight 结束任务。文字按自己的 recordID封存；语音调用 **拟新增 coordinator 目标结束入口**，同时核对 kind、leaseID和可用的 recordID。
3. coordinator 在每个 await 返回后重新比目标；当前占用变化后只完成旧目标记录，不清新 occupancy/activeSessionID/计时。未匹配目标返回明确 superseded/mismatch，不全局 stop。
4. 页面页头、底栏、Esc 的停止回答与结束快捷键、人设重开分别连接正确 action。App 菜单现有“结束当前设备会话”仍按其明确全局名称工作；助手页面上下文命令绑定助手 target，不能把全局菜单偷换为助手动作。
5. `restartWithPersonaPick` 只有前场目标收尾成功或用户明确处理保存失败后才能新开；准备阶段取消不需要伪造记录。退出/切功能的助手 stopper只调用“停止 transport”，不得反向调用 coordinator 造成递归封存。

**完成条件**：A01/A02/A18；会议 occupancy、phase、记录、stopper计数逐项不变。旧结束任务不能结束新 lease。建议提交点：`fix: scope assistant ending to its record and device lease`。

### VA-02：解除接收与取消的等待环

**依赖**：VA-17a。**文件**：`APP/AssistantSession.swift` 的 startPump/handle/noteSpeechEvidence/interruptCurrentReply/runReply；`AssistantTTSStreamCoordinator.swift`。

1. 将泵拆为可分别停止的 uploader/receiver任务；receiver 保持一个顺序消费者。轻量处理 ACK/terminal和身份归约，不 await远端 cancel确认。
2. 插话、手动停止、provider失败统一 **拟新增 `InterruptIntent` effect**。先同步撤 reply输出权、claim前任、登记 retiring request并作废播放epoch，再将有界停播→cancel→terminal等待交给唯一 effect。
3. TTS coordinator应在 **任何 await以前** 登记 retirement barrier。`begin` 同时检查 retiringRequests与retiredTerminals，堵住“已作废但闩尚未挂上”的窗口；保留 terminal提前到达的prefetch。
4. 接收者继续送 terminal给退休请求。effect完成只在session/connection/intent仍匹配时改变当前 phase；即使过期，也回收自己资源与waiter。
5. 音频不能在receiver内 await播放背压：送入有界音频队列与单consumer；控制事件继续归约。队列满明确失败/关闭，不能丢PCM后宣称完整。配置上限复用现有预算并记录。
6. 超时或cancel发送失败仍先保持本地停止，再关闭归属未知连接；新文字回答可继续，新TTS必须等确认或显式重建连接。不要以发送完成替代空闲屏障。

**完成条件**：A03/A04/A08/A55。A03经唯一事件流正常完成，不靠实际等待2s超时；取消未确认始终 fail-closed。建议提交点：`fix: keep assistant control events flowing during cancellation`。

### VA-03：输入排空、尾句与保存双屏障

**依赖**：VA-01/02。**文件**：`APP/AssistantSession.swift`、`AssistantAudioSession.swift`、`AssistantSessionDependencies.swift`、`RealtimeASRClient.swift`、`SessionCoordinator.swift`、`SessionStore.swift`。

1. **拟新增 InputLifecycle**：active/draining/closed；固定ending session与draining connection。结束推进startToken以禁止启动发布，但不立即撤销该连接的合法ASR归档资格。TTS输出权立即撤销。
2. 在共享引擎串行queue上停止tap生产，按静音/半双工准入策略排出已捕获允许上传的尾部、finish capture stream；uploader排完后才冻结发送水位。**拟新增 `finishCaptureAndDrain()` / `stopAndWait()`** 必须返回可等待结果，不能把现有同步stop当完成屏障。
3. Realtime内部 **拟新增 Event `.inputDrainReceipt(...)`**：校验matching commitID和累计samples后按同一事件流emit。保留现有receipt失败不clear、关闭连接规则。无需新增wire事件，服务已有receipt。
4. Session收到marker时，前面的final归约已登记保存操作。等待该marker以前的保存任务全部settled，分别返回saved/failed；receiver不等待这个聚合任务。`drainAndClear`返回与应用marker到达可能赛跑，结束同时等两者，不能假定顺序。
5. draining 的completed去重后仅保存 user/partial恢复，不beginReply；空final使用已有“显示过hypothesis则保留未完成”规则。failed、正常空输入、receipt超时、保存失败分别记录。
6. coordinator封存返回 **拟新增 `SessionSealResult`**。成功且记录读回archived才发布lastFinalizedSessionID；失败保留pendingSeal与内存未保存文本，硬件仍释放。`sealSession`也返回实际结果；0受影响行不算成功。
7. 使用绝对deadline约束网络、停止、应用保存阶段。沿用现有8s作为网络预算起点；现有实现各阶段分别用timeout，不能宣传总耗时恒小于8s。应用保存超时不能取消尚在SQLite执行的事务并假定未提交；晚到成功按旧目标对账，重试用同ID幂等。

**完成条件**：A05/A06/A07/A47；尾句落原记录一次、LLM/TTS不增加；DB Gate挂起时无保存成功带。建议将目标结束与双屏障保持自洽增量，提交点 `fix: drain assistant input before publishing saved completion`。

### VA-04：回复接管、跨 await 与保存幂等

**依赖**：VA-02。**文件**：`APP/AssistantSession.swift`、`AssistantReplyState.swift`、`SessionStore.swift`、`SessionDomain.swift`；拟新增 `TEST/AssistantReplyPersistenceRaceTests.swift`。

1. `ask`与ASR final共用 **拟新增 submitTurn入口**，固定questionID/replyID/source/意图。默认第二问题停止前任并处理新问题；接纳序列按单调submission ordinal，两个await结束先后不能改变顺序。
2. 用户问题固定lineID，保存成功才返回accepted；保存期间退出/被替代时旧结果只绑定原session，不进入新场history。重试回答引用原questionID，创建新attempt/reply，不复制用户行。
3. 增强ReplyState：正文revision、persisting/finalizing/saved/saveFailed、finalization claim、historyApplied。共享claim在第一个await前登记，以replyID为键；局部isFinalized不再作为唯一once证据。
4. partial返回时仅更新匹配reply的isPersisted/ordinal，保留当前较新的text/revision；禁止用旧整个reply副本赋给currentReply。
5. finalization按固定身份、最新可见正文和单向termination合并写Store；返回后重算当前身份。旧操作可完成旧记录，却不能清新的streamingReply、currentReply、phase或错误。
6. Store提供 **拟新增原子助手行upsert/finalize**：同ID检查session/role；存在则更新，不存在才插入；普通SQL故障直接失败。正文revision不得倒退，interrupted/failed证据不能被迟到success清除。
7. history与turns按ID upsert一次，按输入/回复次序重建上下文；不靠完成时间append乱序。保存失败正文仍可见且明确未保存；重试保存不重调模型。

**完成条件**：A09～A12；分别检查Store、turns、LLM捕获history。建议提交点：`fix: make assistant reply ownership survive persistence awaits`。

### VA-05：事件、启动与回调身份过滤

**依赖**：VA-02/04。**文件**：`APP/AssistantSession.swift`、`AssistantTTSStreamCoordinator.swift`、`AssistantAudioSession.swift`、`AssistantAudioPlayback.swift`。

1. `.ttsAudio`先校验当前connection/request，再更改speaking/闭麦；队列入队和await返回再校验epoch。拒绝事件不归还新代预算。
2. `.ttsEnded`先分current/retired/unknown：retired只解自己的闩；unknown不改phase/error；current才可改交付状态。onOutcome带完整invocation/request/epoch，不忽略generation。
3. device invalidation、upload错误、start/retry失败都携带source/connection身份；旧source失败不写新lastFailure。一个await前“我还活着”不能覆盖返回后的复核。
4. startup持有私有TransportLease直到所有准备和建档完成。清理只释放自己资源；删除共享引用必须compare-and-clear，不用无条件nil。
5. 迟到建档只按其recordID封存并报告真实结果；对新coordinator lease无副作用。重试single-flight沿用，任务句柄compare-and-clear。

**完成条件**：A13/A14/A15/A52，旧event/callback/cleanup不能污染B。建议提交点：`fix: filter stale assistant effects before shared state changes`。

### VA-06：会话路由、人设、记忆快照

**依赖**：VA-04/05。**文件**：`APP/AssistantSession.swift`、`AssistantSessionDependencies.swift`、`SessionPreferences.swift`、`VoicePrompt.swift`、`AssistantView.swift`。

1. **拟新增统一prepareContext**供文字、语音新场调用；先清上一场memories/history，再加载选中active记忆。失败明确“本次未加载记忆”，不沿用旧数组。
2. 开始时冻结resolvedLLMConfiguration，包括normalizedBaseURL、model、协议/兼容模式、thinking规则、密钥scope/revision；正文persona快照冻结。Store只存非秘密配置，不保存key或完整prompt。
3. runReply从snapshot取route，不再次解析preferences；reconnect只换ASR/TTS transport，保持sessionID、ordinal、history、mute和route。credential已撤销时阻断并提示，不恢复到另一配置。
4. 新数据目的地发送前展示文本/历史/记忆范围。**拟新增 consent key**只由规范化route字段、model、用途和payload类别/版本构成，不对正文/密钥hash。新目的地或发送范围扩大重新确认；拒绝保留草稿。
5. 模型连接检查绑定route revision、检查时间、outcome；只读review使用历史模型快照，不显示当前“已连接”。

**完成条件**：A21～A24；A/B目的地变化captured request证明不漂移，语音/文字memory语义一致。建议提交点：`fix: pin assistant routing and memory to the conversation`。

### VA-07：文字独立可用与显式恢复语音

**依赖**：VA-01/03/06。**文件**：`APP/AssistantSession.swift`、`SessionCoordinator.swift`、`AssistantView.swift`。

1. 以LLM配置、Store可用性、是否ending决定typing；microphoneDenied/occupied/serviceBusy/serviceNotReady/streamFailed不直接禁typing。模型与Store错误仍给具体出口。
2. 语音断线停止自有transport与设备，但保留本场record/history/context；typed继续同场。关闭语音与mute分开：mute只停上传，closeVoice释放设备。
3. 文字升级语音需显式动作、能力pin与权限，并经coordinator现有冲突确认；拒绝不改文字记录。升级成功将自有record附到新assistant lease，不另建记录。
4. 纯文字idle发送也执行统一模型准入和数据说明；不可因ensureTextConversation总能建档而把错误配置算accepted后静默失败。
5. ASR-only增强进入条件：现有combined capability会稳定阻断实际需求且用户要求拆分。届时按ASR binding独立建连，输出textOnly，沿用同一record；不伪造TTS capability，不在核心修复中偷加。

**完成条件**：A16/A17/A19/A20，permission请求次数与mic/RT counters受断言。建议提交点：`feat: keep assistant text conversation usable through voice failures`。

### VA-08：可信首屏、模式与数据去向

**依赖**：VA-06/07。**文件**：`APP/AssistantView.swift`、`SessionSurfaceViews.swift`、`SpeechRailDesignTokens.swift`；拟新增 `APP/AssistantPresentation.swift`、`TEST/AssistantPresentationTests.swift`。

1. 实现§3.2十二态纯presentation与action availability；输入事实来自AssistantSession和其lease，不直接借全局coordinator.elapsed/level。
2. 替换硬编码“语音已就绪”“说话即录”“模型已连接”；检查未执行时仅已配置，连接检查过期/失败显示实际结果。
3. 数据说明采用“本机SpeechRail处理语音；文本和启用记忆发给配置的模型服务；记录保存在此Mac”。endpoint分类仅描述地址，不从loopback推断服务绝不外发。
4. 首屏保留发送与开始语音；角色/声音/模式摘要一行，详细设置放既有inspector；record入口简化，保留常用动作键盘/无障碍入口。
5. 沿设计系统§3.1/3.2的Token和共享组件；不铺玻璃内容面板。新尺寸仅在Token集中声明并同步文档。

**完成条件**：A25/A26/A27及12态纯测试；实际视觉检查记U。建议提交点：`feat: present truthful assistant readiness and data flow`。

### VA-09：草稿、阅读位置、输入法与恢复

**依赖**：VA-04/08。**文件**：`APP/AssistantView.swift`、`SessionSurfaceViews.swift`；拟新增 `APP/AssistantComposerPolicy.swift`及其测试。

1. 保留当前send单飞、snapshot一致才清稿。sendPrompt改为非破坏填入：空稿直接填入；非空提供插入/替换/取消，替换可Undo；不能点击模板就自动覆盖发送。
2. 重试绑定questionID和replyAttempt，不复制问题；未接纳发送才重试草稿；模型失败、保存失败、语音失败使用不同动作。
3. followLatest按用户滚动意图与底部可见性维护。稳定tail anchor跟随同reply增量；向上阅读关闭跟随，显示“回到最新”；后台新增/刷新不抢位置。
4. IME marked text期间Return交给系统组合；多行用Return换行、⌘Return发送，Shift/Return行为与控件规则一致并有可见说明。Esc先由IME/弹窗/菜单消费，再执行本场停止回答。
5. 焦点只在明确用户动作或已有输入任务恢复时移动；异步状态、voice event、inspector展开不强制聚焦。Reduce Motion即时分支。

**完成条件**：A28～A32；composer纯函数D与真实IME/焦点U分别验收。建议提交点：`feat: preserve assistant drafts and reading position during replies`。

### VA-10：输入输出模态与模型终态分类

**依赖**：VA-06。**文件**：`APP/VoicePrompt.swift`、`AssistantSession.swift`、`LLMProvider.swift`；`TEST/VoicePromptTests.swift`、`LLMProviderTests.swift`。

1. **拟新增 typed input/output policy**：keyboard/recognizedSpeech，textOnly/spokenConcise。顶层instructions每轮组装，人设styleBlock不再写死“所有回答服从朗读要求”。
2. keyboard允许Markdown、代码、完整步骤，不应用ASR容错；spoken默认短且能按用户明确要求展开。数字/日期/否定/专名歧义仅必要确认，禁止泛化“结合上下文猜”。
3. 原正文、spoken转换、交付状态分开；提示明确没有查网/文件/执行工具，不新增外部能力。
4. 保留provider现有responseID与completed/EOF规则；将failed/incomplete与refusal分别分类。优先在现有LLMError增加case与消息映射，不重写SDK/SSE。拒答正文可呈现，空completed在Session显示空输出；structured JSON路径的refusal规则保持独立。

**完成条件**：A33/A34/A55；复用既有EOF/DONE/错response终态回归。提示词测试只证明文字契约，真实模型质量记R。建议提交点：`fix: apply assistant prompts and failures by actual modality`。

### VA-11：分包一致性、保真与有界文本

**依赖**：VA-02/10。**文件**：`APP/AssistantSpeechTextBuffer.swift`、`AssistantTTSStreamCoordinator.swift`、`VoicePrompt.swift`；既有buffer/coordinator/prompt测试。

1. 分离provider事件安全上限、原始待处理上限、整轮原始预算、服务append/total预算。合法600 scalar可一次到达；不拿512 append限额拒绝provider delta。
2. 准入先计算candidate counts，再变更pending/offered；超限拒绝该delta时原状态不变。避免先Array拷贝超大delta；上游decoder单事件预算与Session整轮上限分别防无界增长。
3. `started.limits`确认后取本地与服务更小值；清洗后可能扩长，按清洗后的append限额再次安全切分并计实际sent scalar。服务总量限制不能只读不执行。
4. **拟新增有状态spoken renderer**保留跨片空格、英文词、Markdown边界和原文区间映射；不逐片trim粘词。原始store/UI文本不改。代码/长URL按明确“请看屏幕”策略跳读并留下状态。
5. deadline/forced不得切未完成小数、负号、单位、百分号、版本号或英文词。先送安全前缀；敏感token无合法断点且达到有界长度/等待时停止朗读、保留文字与原因。数值不猜补。
6. 150ms等当前候选等待保持可配置；保真安全规则必须回归，激进切分只在VA-18对照证明收益后启用。ACK按scalar累计，sequence连续，finish等待最后ACK。

**完成条件**：A35～A39；单delta/分片/跨Unicode/缩小limits的等价准入与语义断言。建议提交点：`fix: make assistant spoken content independent of transport chunks`。

### VA-12：播放交付、重播与实际音色

**依赖**：VA-04/05/11。**文件**：`APP/AssistantAudioSession.swift`、`AssistantAudioPlayback.swift`、`AssistantPlaybackLedger.swift`、`AssistantTTSStreamCoordinator.swift`、`AssistantReplyState.swift`、`AssistantView.swift`、`SessionStore.swift`。

1. 明确rendered是渲染证据，played是设备播放回调证据，任何一个都不等于用户听懂。先核对当前SDK回调定义；选择`.dataPlayedBack`作为“播放完成”门槛时同步两个播放实现和fake。
2. 若继续以rendered释放渲染预算，需独立played未完成账本；不能rendered后提前completed，且音频实际总在途量仍有上限。推荐首版由played同时释放播放预算与完成，随后用背压/设备实测决定是否拆分。
3. playbackInvocation绑定originalTurnID，而非lastFinalizedReply。停止重播A只更新A本次播放记录，B生成状态不变。played late callback按epoch/device generation拒绝。
4. 完整生成但未放完标“朗读未完成”；history携带交付说明，不截同比例字符；文本answer仍完整可复制。
5. 音色选择pending，request启动时固定voice/revision。以真实reply ordinal登记session_change；保存失败不发布已生效记录，回滚pending或标未保存。不能跨await猜currentOrdinal+1。
6. “测试声音”连接现有`previewSelectedVoice`/试听协调：明确暂停或拒绝正在播放的回答，完成后不自动重播；禁止用typed question假测试。无TTS通道的行禁play并给启用说明。
7. TTS-only增强如需实施，新增render task和已有PCM播放adapter，明确不请求麦克风；共享音频设备冲突经原播放协调处理，不建立第二个常驻引擎。本轮无需求/证据时记录延期，但A43的可见反馈必须完成。

**完成条件**：A40～A44。记录状态迁移按§6.7，不能伪造已听文本。建议提交点：`feat: distinguish assistant generation from playback delivery`。

### VA-13：输入证据、自然接话与设备策略

**依赖**：VA-02/05及VA-17基线。**文件**：`APP/AssistantSession.swift`、`RealtimeASRClient.swift`、`AssistantAudioSession.swift`；拟新增 `APP/AssistantTurnPolicy.swift`及测试。

1. 必交：空/纯空白snapshot不触发cancel；revision去重；final-only经统一接管；多item不能把别人的partial槽误当当前输入。保持空final未确认恢复。
2. 必交：明确区分turnTaking与duplex的事实。voiceProcessingUnavailable提示更换为一问一答/设备，不能只叫serviceNotReady；不依据耳机名称宣称AEC通过。
3. 真人评估停顿、自修正、补一句、短答案、附和与复述。任何“与助手文本相似即回声”的过滤必须接受真人复述反例；手动停止不经语义分类。
4. 条件policy：相邻final聚合只合并尚未发模型的用户输入窗口，手动发送立即flush，最大等待有界；配置和新增等待写policy revision。局部VAD只能提前duck，明确插话才取消；不伪造wire事件/置信度。
5. 没有R基线时只交必修证据规则与实验开关/评估定义，聚合/duck维持关闭，状态`deferred_evidence`；不能用调低阈值冒充改善。

**完成条件**：A08确定性通过，A56/A57/A58逐设备真实验收另记。按证据拆提交点，安全规则先交。

### VA-14：上下文预算、记忆审阅与作用域

**依赖**：VA-06/10/12。**文件**：`APP/AssistantSession.swift`、`VoicePrompt.swift`、`SessionPreferences.swift`、`AssistantView.swift`、`SessionDomain.swift`、`SessionStore.swift`；拟新增context builder测试。

1. 请求从有预算的builder组装：固定契约/风格→有来源记忆→近期完整turn→本轮问题，并预留输出。已确认model token budget使用对应计量；未知window不凭空推断。
2. 首版明确客户端保守上限：拟新增policy默认最多12个完整历史turn、历史正文16,000 scalar、选中记忆4,000 scalar、输出maxOutputTokens=1,024。它们是候选产品限额，不等于模型token window。固定指令/当前问题也计入总安全预算，单独超限返回可修改内容的错误，不截断用户关键问题。
3. 最近turn裁剪不拆半个user/assistant配对；failed/interrupted回复可连同交付说明保留；Store完整历史不删。显示省略turn范围和原因，budget已知过小时fail明确。
4. 记住动作先展示可编辑draft：正文、kind、来源session/line/role、作用范围。默认用户选择；助手建议不自动设fact。现有kind为fact/preference/summary；“约定”采用preference的文案解释，不静默新增rawValue或把summary假称约定。
5. 保存确认前不upsert；取消不写；停用/删除错误可恢复。默认下一新场生效；如用户选择立即应用当前场，在停止当前生成并确认后重建下一轮memory snapshot，不改已经发出的请求。
6. 记忆作为有来源数据块，长度有界，不直接原文拼成可覆盖应用规则的developer指令；使用角色边界/序列化转义并说明数据非命令。拒绝保存明显秘密的候选，不把秘密发诊断。
7. 来源摘要条件：只有裁剪造成实际续接缺失且用户要求时评估，摘要独立保存来源turnID/生成route/policy，不改原文，模型失败可回最近turn策略。

**完成条件**：A41/A45/A46/A48，预算与注入测试D、真实语义R分开。建议提交点：`feat: bound assistant context and review explicit memories`。

### VA-15：记录闭环与真正续接

**依赖**：VA-01/03/14。**文件**：`APP/AssistantView.swift`、`SessionCoordinator.swift`、`SessionStore.swift`、`SessionDomain.swift`、`SessionExporter.swift`。

1. 封存、读record、reviewSnapshot、改名、删记录、导出取消`try?`成功外观；分别do/catch并保留旧界面。写成功后reload；读失败不替换成[]/空record。
2. 未保存内存导出另命名“复制未保存内容”，不能混同“导出已保存记录”。导出器现有磁盘失败/取消逻辑复用；失败保留目标record。
3. 当前继续按钮与说明统一改“用相同设置新建”，只prefill不承诺继承history。活跃助手存在时，新建先明确处理当前场，不只closeReview就隐藏采集。
4. A50独立动作“基于此记录继续讨论”：读取一致快照→展示selected turn范围、记忆与目的地→确认→创建新record和父记录引用→生成context seed。原文不改，不自动开麦，当前活跃场先按明确目标结束。
5. seed仅包含用户选定完整turn与有来源交付说明，不复制用户密钥/旧route同意。seed应冻结选定文字，防后续删父记录破坏子记录；parent引用可置空但保留来源信息和范围描述。
6. 移除记录目标明确并二次确认；失败留原record。新增活跃/未保存目标保护，不能移除自己仍写入的记录。

**完成条件**：A47/A49/A50/A51。标签/失败处理先交，续接随schema扩展独立增量。建议提交点分别 `fix: report assistant record operations truthfully`、`feat: continue assistant discussion from selected saved turns`。

### VA-16：丢块、队列、超时与观测

**依赖**：VA-02/03/05。**文件**：`APP/AssistantAudioSession.swift`、`AudioSampleRing.swift`、`AssistantSession.swift`、TTS/ledger；拟新增 `APP/AssistantObservability.swift`及测试。

1. ring生产回调只做无锁原子计数：attempted/accepted/dropped native samples；conversion/网络线程记录wire samples，单位分开。队列reset只在producer停止后发生。
2. capture AsyncStream每次yield检查enqueued/dropped/terminated；只计丢块与样本量，不记录PCM。termination立即停止upload，连续发送失败按稳定阈值进入voice故障而非无限刷错误。
3. 记录receiver队列年龄、pending raw/sent scalar、rendered/played在途samples、取消发出/确认、input receipt/Store marker、设备停止完成。
4. **拟新增单调时钟与observer seam**，墙钟仅用于记录显示；负耗时无效，无样本为N/A，观察写失败不抛进主流程。直方图/计数有界，不每token存无限events。
5. 多次source rebuild按device generation对账，旧回调不归还新预算。主要UI仅给“部分声音未收到/可打字”，技术计数进入开发者详情。

**完成条件**：A52/A53/A54；资源上限、归因、观察失败不影响主流程分别断言。建议提交点：`feat: expose bounded assistant loss and lifecycle measurements`。

### VA-17b：完整验收资产与真实评估入口

**依赖**：随全部工作包演进，不等最后才补测试。

1. §7按每个A提供具体D测试或U/R脚本；新测试均走生产组件，跨端fixture继续共用。拟新增纯manifest驱动的`AssistantReplayEvaluator`与离线runner，只消费仓库外已授权素材/事件，输出去标识聚合。
2. runner清晰分event-only/input replay/真实扬声器麦克风闭环；离线转写事件不能证明AEC、双讲或设备尾音。真实采集/模型调用的操作者与素材同意需另行授权。
3. manifest必填素材授权、设备/系统/模型/voice revision、policy、标注时间、真实输入/输出路径。仓库内仅schema、合成fixture与工具；素材路径/正文不进交付报告。
4. A59做30～60分钟代表性长会话，A60覆盖失败/休眠/设备拔出/结束；报告所有attempts、successes、failures、timeouts与分层sampleCount，不剔失败美化延迟。
5. 无样本、缺device或没执行留not_run；A01～A60的验证行可单独重跑，不以一个全套exit码代替断言证据。

**完成条件**：所有60行与其子类型有入口/断言/状态；真实报告单独存在或诚实未执行。建议提交点：`test: make assistant journey acceptance traceable by scenario`。

### VA-18：有证据的优化、文档与交付门禁

**依赖**：VA-11/13/16/17；功能变更先达到安全不变量。

1. 固定baseline policy/config/sample/设备；按§8指标识别瓶颈。候选仅限UI合批、LLM读取与TTS启动有界解耦、capture分包、预检缓存，不为全部候选预先改代码。
2. 每个优化写“假设→基线→单项改动→同配置对照→失败/资源/保真→启用或否决”。cache key含route/capability revision，变更失效；不能为了延迟跳过必要版本/数据同意。
3. 输出未优化决定也需说明证据/成本/保留理由。无R证据不宣称首音/插话改善，无性能授权不运行benchmark。
4. 更新active `docs/developers/macos-app-development.md`、设计系统和会话层技术方案中实际受影响内容；仅正文实质变更更新version/date。wire未变无需为了App动作改OpenAPI；若变则同步contracts、测试、用户API文档。
5. 更新`Package.swift`和Xcode project显式membership；生产/SwiftPM测试编同一实现。新增CLI target只在真实有runner时加入，不先造空产品。
6. 构建/安装/发布按专项release skill与独立授权；无需顺手重启服务、下载模型或改档位。完整gate按明确要求才跑。

**完成条件**：§8门禁、18包与60场景账本闭环；报告里单列代码验证、UI、声学、性能、迁移、安装状态。建议提交点：`docs: align assistant journey contracts with verified behavior`；性能改动每项独立commit。
