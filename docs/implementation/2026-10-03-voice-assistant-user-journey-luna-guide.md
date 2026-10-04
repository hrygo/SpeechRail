---
title: "语音助手用户旅程优化：Luna 详细执行方案"
status: proposed
version: "0.1.0"
date: 2026-10-03
---

# 语音助手用户旅程优化：Luna 详细执行方案

- 原方案：[SpeechRail 语音助手：按用户旅程优化的详细可执行方案](SpeechRail_Voice_Assistant_User_Journey_Executable_Plan_2026-10-03.md)。已从 Downloads 原样移动至本目录，SHA-256：`6ecc49163cc03dbcea08f98347cba8ddfc4dbe6ca44b53bd232b17131d62ebf6`。
- 本地核验：2026-10-03，Asia/Shanghai；分析基线为 `main` 的 `be75055cc0a5f7f044ae56c955896812a1d69915`，与原方案一致。交付复核时 HEAD 为 `69000d1f`，期间新增提交仅涉及文档，业务源码基线未变；这些提交并非本轮创建。未核验远端是否存在后续提交。
- 本轮范围：原方案移动、源码与契约分析、执行方案落盘。业务代码、数据库、服务配置均未修改；测试、构建、真实模型、录音、UI 自动化、提交、推送和发布均未执行。
- 分析开始时已存在的三份未跟踪文档属于其他任务：`2026-10-03-roi-evolution-luna-guide.md`、`2026-10-03-teleprompter-user-journey-luna-guide.md`、`SpeechRail_Teleprompter_User_Journey_Executable_Plan_2026-10-03.md`。交付复核时已在上述文档提交中跟踪；本轮保留其内容，不修改或混入本任务交付。
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

原方案章节逐项对应如下；条件增强也必须记录决策与未执行原因。

| 原方案章节 | 本文件执行与验证落点 |
|---|---|
| §0 决策摘要 | §1里程碑、§5 VA-01～06优先顺序 |
| §1 当前基线与源码发现 | §2 F01～F18源码映射、§7前三个最小反例 |
| §2 产品定位、场景与完整旅程 | §3不变量与十二态、§4.2产品边界 |
| §3 首次进入、配置和开始 | VA-06～08、A16/A19/A21～A27 |
| §4 说话、打字与输入保真 | VA-03/07/09/13、A05～A08/A28～A34 |
| §5 接话、插话与取消 | VA-02/13、§6.2、A03/A04/A08/A55～A58 |
| §6 生成回复与流式朗读 | VA-10～12、§6.5、A33～A44 |
| §7 长对话、记忆与上下文 | VA-06/14、§6.6、A21～A24/A41/A45/A46/A48 |
| §8 异常、降级与恢复 | VA-04/05/07/10/16、§9回退顺序、A04/A15～A20/A47/A52～A55 |
| §9 结束、记录与继续 | VA-01/03/15、§6.3/6.7、A01/A02/A05～A07/A18/A47/A49～A51 |
| §10 UI交付规格 | §3.2十二态、VA-08/09、A25～A32及U人工清单 |
| §11 工程结构与关键不变量 | §3.1、§4.1、§6.1～6.6身份与顺序合同 |
| §12 详细工作包 | §5全部18包、§10依赖和完成定义 |
| §13 实施节奏、协作与交付顺序 | §1里程碑、§10顺序/唯一写入者/提交授权 |
| §14 60个可执行验收场景 | §7.2 A01～A60逐行入口与断言、D/U/R子状态 |
| §15 评价指标、样本设计与候选目标 | §8.3全部指标/候选值/失败分母、§8.4设备样本与隐私 |
| §16 测试与验证执行说明 | §7测试落点、§8.2定向命令/发现数量/真实验收授权 |
| §17 数据迁移、发布与回退 | §6.7事务迁移、VA-18发布门禁、§9恢复与资产保护 |
| §18 本轮不做与后续决策 | §4.2范围、VA-07/12/13/14条件增强、§9决策闭环 |
| §19 证据索引与适用边界 | §2核验来源和局限、§8实测分级；原作者在线资料不冒充本轮核验 |

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

**文件**：§7.1列明的生产路径测试、`tests/fixtures/assistant_realtime_lifecycle.json`；拟新增U/REAL验收文档和验收账本。评估工具拟新增于 `macos/SpeechRailApp/Tools/AssistantReplayEvaluator/`，其共享评估逻辑与CLI入口分文件；获得实施授权后在 `Package.swift` 声明实际target与测试依赖。

1. §7按每个A提供具体D测试或U/R脚本；新测试均走生产组件，跨端fixture继续共用。拟新增纯manifest驱动的`AssistantReplayEvaluator`与离线runner，只消费仓库外已授权素材/事件，输出去标识聚合。
2. runner清晰分event-only/input replay/真实扬声器麦克风闭环；离线转写事件不能证明AEC、双讲或设备尾音。真实采集/模型调用的操作者与素材同意需另行授权。
3. manifest必填素材授权、设备/系统/模型/voice revision、policy、标注时间、真实输入/输出路径。仓库内仅schema、合成fixture与工具；素材路径/正文不进交付报告。
4. A59做30～60分钟代表性长会话，A60覆盖失败/休眠/设备拔出/结束；报告所有attempts、successes、failures、timeouts与分层sampleCount，不剔失败美化延迟。
5. 无样本、缺device或没执行留not_run；A01～A60的验证行可单独重跑，不以一个全套exit码代替断言证据。

**完成条件**：所有60行与其子类型有入口/断言/状态；真实报告单独存在或诚实未执行。建议提交点：`test: make assistant journey acceptance traceable by scenario`。

### VA-18：有证据的优化、文档与交付门禁

**依赖**：VA-11/13/16/17；功能变更先达到安全不变量。

**文件**：`macos/SpeechRailApp/Package.swift`、`macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`、`docs/developers/macos-app-development.md`、设计系统入口及其链接的会话文档；优化代码只涉及VA-16/17证据定位到的现有组件。

1. 固定baseline policy/config/sample/设备；按§8指标识别瓶颈。候选仅限UI合批、LLM读取与TTS启动有界解耦、capture分包、预检缓存，不为全部候选预先改代码。
2. 每个优化写“假设→基线→单项改动→同配置对照→失败/资源/保真→启用或否决”。cache key含route/capability revision，变更失效；不能为了延迟跳过必要版本/数据同意。
3. 输出未优化决定也需说明证据/成本/保留理由。无R证据不宣称首音/插话改善，无性能授权不运行benchmark。
4. 更新active `docs/developers/macos-app-development.md`、设计系统和会话层技术方案中实际受影响内容；仅正文实质变更更新version/date。wire未变无需为了App动作改OpenAPI；若变则同步contracts、测试、用户API文档。
5. 更新`Package.swift`和Xcode project显式membership；生产/SwiftPM测试编同一实现。新增CLI target只在真实有runner时加入，不先造空产品。
6. 构建/安装/发布按专项release skill与独立授权；无需顺手重启服务、下载模型或改档位。完整gate按明确要求才跑。

**完成条件**：§8门禁、18包与60场景账本闭环；报告里单列代码验证、UI、声学、性能、迁移、安装状态。建议提交点：`docs: align assistant journey contracts with verified behavior`；性能改动每项独立commit。

## 6. 关键实现说明

### 6.1 身份、资源与动作归属

下表是拟落地的语义合同，具体名字可沿用已有字段；不得合并不同生命周期。

| 身份 | 生成与失效点 | 有权改变的对象 |
|---|---|---|
| conversationID/recordID | 新文字或语音场创建，结束后不复用 | 本场记录、context、history、用户行 |
| startGeneration | start/end/retry取消同步推进 | startup私有资源与发布资格 |
| deviceLeaseID | coordinator grant时生成，设备停止完成后释放 | 该功能占用、设备、计时；文字无lease |
| connectionGeneration | 每次建连生成；drain完成/关闭后撤销 | 当前transport；draining只归档尾句 |
| questionID/submissionOrdinal | 接纳输入时固定，重试不再分配问题ID | 用户行、确定顺序、回答attempt关联 |
| replyID/replyGeneration | 每次回答attempt生成 | 该回答原文、状态、保存claim |
| ttsRequestID | 每次utterance一次start生成 | matching ACK/audio/terminal与退休屏障 |
| playbackInvocationID/epoch | 每次首次朗读/重播/试听生成 | 目标turn的本次播放，不能修改另一回复 |
| storeOperationID/textRevision | 每次保存操作/正文变更生成 | 固定目标行；仅新revision可推进正文 |
| input commitID/水位marker | freeze uploader后生成 | 本connection截至水位的ASR与保存结果 |

**跨 await 统一规则**：捕获目标→调用外部操作→按捕获目标登记结果→再次比较当前目标→匹配才更新当前共享显示。身份不同不代表旧操作可不收尾；它仍必须关闭自有资源、完成旧record事务、释放自己的waiter。

共享reference compare-and-clear需使用对象/lease身份，不能只比是否nil或功能kind。reply取消是逻辑撤权，播放器停止才是本地输出屏障，terminal才是远端空闲证据。

### 6.2 接收与副作用的顺序

拟实现的伪代码：

```text
receive(envelope):
    validate conversation + connection eligibility
    if control ACK/terminal:
        resolve matching coordinator latch synchronously
        publish current-owned state only
    if speech evidence:
        validate item/revision/nonempty
        reduce partial/final in sequence
        claim one interrupt intent if predecessor still owns output
        enqueue owned interrupt effect; do not await it here
    if audio:
        validate request/epoch
        reserve bounded queue slot or fail closed
        enqueue to one audio consumer
    if final:
        register ordered persistence operation
        if draining: archive only
        else: submit next turn through the arbiter
```

effect持有session/connection/request/intent；完成后消息回归约器。取消effect、replyTask、upload、receive、音频consumer和timeout都有句柄，结束时只回收该场任务。

`withTaskGroup`竞速取消不保证子任务立即退出：不响应取消的依赖可能令group scope继续等。截止任务、continuation、底层close必须能终止对应waiter；超时后不能无限等待整个任务树。不得用遗失句柄的Task绕开问题。

手动stop回执首先确认本地屏障；远端等待另显示可恢复状态。local stop永远优先于ASR、语义判断、Store与网络。

### 6.3 结束顺序与水位

```text
active
  → ending target once-claim、拒绝新start/submit/output
  → 立即启动local playback stop屏障与old TTS取消effect（receiver继续）
  → capture stop生产并排出准入尾部
  → uploader按准入规则排空；记录累计发送wire样本
  → commit(request_receipt=true)
  → draining receiver保存matching connection的final
  → 收到并处理应用inputDrainReceipt marker
  → 等待marker前保存结果
  → seal record成功/失败
  → close transport + stopAndWait硬件 + release matching lease
  → 发布真实结束结果；成功保存才给saved recordID
```

本地停播不等待capture、uploader、远端terminal或Store；输入排空与有所有权的取消effect可并行，最终关闭前按各自结果收尾。结束后的uploader不能沿用“`isStoppingIntentionally`则丢弃所有chunk”的旧guard。改为只允许在结束边界前捕获且原策略准入的尾部；静音期间本来不应上传的PCM继续丢弃并计policyDiscard，不伪装网络drop。不把PCM存到数据库或恢复文件。

输入receipt字段已有契约，不需要修改服务。新增内部marker影响其他Event消费者时，caption/meeting/teleprompter明确忽略或复用；更新穷尽switch，不能误触发其他功能收尾。

保存marker登记顺序必须在队列归约时固定；晚到final在marker之后且超出收尾范围不得加进已封存record。断线/timeout结果分别标`input_unconfirmed`、`persistence_failed`、`device_stop_failed`，不能合成“全部成功”。

### 6.4 回复的收尾 claim 与错误单向合并

拟持久化状态（与生成状态、播放状态分别维护）：

```text
streaming
  → finalizing(claimID, targetTextRevision, termination)
  → saved(textRevision, ordinal)
  → 或 saveFailed(pendingSnapshot, error)
```

claim已存在时，第二个结束原因合并到同一目标；不得再启动第二个Store INSERT。迟到completed不覆盖interrupted/failed；正文只在revision更大时更新。新delta被逻辑撤权后不进入旧正文。

once-claim与saved不同：claim阻止重复副作用，saved需要数据库确认。失败可按相同ID/revision重试，成功只投影一次。错session/role、数据库busy/磁盘错误不能被解读为missing row。

history以turn identity组装；当前问题没有对应可用回答时不凭空造助手行，refusal保留实际可见内容和真实结果。生成完成但播放中断时保持完整原答案，并附“朗读未完成；未有可靠逐字对齐”说明。

### 6.5 预算、切分和服务限额

| 预算 | 计量 | 超限行为 |
|---|---|---|
| provider单事件 | UTF-8 bytes，按现有decoder边界配置防滥用 | 拒绝畸形/过大事件，保留此前正文；不用append512衡量 |
| Session整轮原文 | Unicode scalar/明确模型输出token上限 | 有界终止生成或明确失败，保留此前结果 |
| TTS pending原文 | Unicode scalar | 原子拒绝新输入，停止朗读并可看文字 |
| TTS单append | 清洗后Unicode scalar，与wire codepoint一致 | 按协商更小值安全拆；不拒合法大delta |
| TTS整轮sent | 清洗后实际sent scalar | 提交前预检；超限停止该utterance |
| 播放/下行音频 | 24k mono samples/PCM bytes，注明单位 | 有界背压；满则明确失败，不静默丢音 |
| 上下文请求 | 已知模型token budget；未知时明确客户端scalar/turn限制 | 裁剪完整历史turn；当前问题/固定指令过大明确拒绝 |

总budget不是把不同计量直接相加。Unicode scalar与grapheme不能混用；清洗可能缩短/扩长文本，因此raw/offered/sent/ACK各有定义。

不得在pending满时盲切可能改变数值含义的token。最终输入结束且token完整可flush；模型中断时仍未完整的token采用停止朗读+查看文字，不补零、不猜单位。

### 6.6 配置、记忆和发送范围

- runtime snapshot与Store记录分开：Store记录非秘密route/model/persona/voice信息，不落key、Authorization或完整系统prompt。
- 会话路由冻结包含协议与thinking控制；现有MacPaw/OpenAI依赖版本不因本任务升级。provider必要错误分类留在现有adapter。
- consent以明确目的地、用途、内容类别/范围建立；同地址改为发送全部历史仍需要范围确认。地址分类不是数据最终流向保证。
- 默认memory下一新场生效，当前场仍持快照时面板明确显示；用户显式“当前对话应用”才停止当前生成并重建下一轮快照。
- 假设ASR关键数值“可信概率”或语义模型可稳定保证事实是不可接受的；D仅验证策略文字、分包和状态，R验证实际模型行为。

### 6.7 拟新增 schema v2 与保护用户资产

推荐在VA-04/12/14/15共享一次**加法、事务性v2迁移**。v2接口在首个使用它的工作包一起落地；不可先发布依赖v2的调用，再把迁移留到最后。

保留现有`session.state`、`line.status`、source、ordinal、starred、timing以及旧`interrupted`数据。新增精准状态不通过重写旧Bool来猜：

| 拟新增结构 | 字段/约束 | 用途 |
|---|---|---|
| `assistant_reply_state`表 | `line_id` PK/FK；`session_id` FK；`question_line_id` nullable FK；`attempt_index`；`text_revision`；`generation_state`；`termination_code` nullable | generating/completed/interrupted/failed/refused/unknown；Store写入前确认line为该session的assistant |
| `assistant_playback_invocation`表 | `id` PK；`line_id`/`session_id` FK；voice/revision nullable；purpose；state；rendered/played证据计数；created_at/ended_at | 每次首次朗读/重播独立，失败/停止不改别的turn；无逐字对齐时不存伪造范围 |
| `assistant_continuation`表 | `session_id` PK/FK；`parent_session_id` nullable FK `ON DELETE SET NULL`；选定来源lineIDs；有界seed snapshot JSON；policy/version | 子记录继续所需的冻结选定文字；父删除不损坏子上下文 |
| `assistant_memory_provenance`表 | `memory_id` PK/FK；source line/role nullable；scope；确认时间 | 明确确认来源与作用范围；旧memory未知来源不补造 |

拟状态取值使用CHECK与decoder校验；`saveFailed`只在内存/可恢复交付中表达，不能向已失效DB写“保存失败”后就宣称恢复可靠。未保存文本复制是用户显式动作，不自动新增落盘日志。

迁移算法：

1. `user_version > supported`继续fail closed；不开库写入，不自动降级。
2. `version == 0`执行现有schemaV1，再执行v2；`version == 1`只执行v2；全部在一个BEGIN IMMEDIATE/COMMIT内，最后更新user_version。
3. v2建新增表/索引，不重新执行schemaV1、不清用户表、不改已有正文/序号/时间轴。失败ROLLBACK并保持原version。
4. 旧line无新表行：generation/playback精确状态显示unknown，旧interrupted作为历史证据呈现，不等同“全文已播放”。旧memory无provenance不假造source role。
5. 临时合成v1库含assistant/meeting/captions、star、partial、voice change、memory与孤立异常测试，校验row count/正文/关系均保留；旧库迁移失败、未来版本、二次open与空库分别回归。
6. abandoned session恢复同时标新播放invocation为interrupted/unknown并保留生成事实；不能把播放未结束统一改为生成失败。更新review/list/export取值与partial计数规则；ASR未确认partial仍不假装正式final。
7. 真实数据库备份/迁移只在以后用户授权实施运行态时执行。使用现有`SessionStore.backup(to:)`保障WAL一致性，不在运行中仅复制主sqlite文件。

v1 App回读v2会按现有future schema规则拒绝。回滚优先保留v2兼容的安全客户端、退policy；确需旧App时停止写入、先导出备份后新增内容，再恢复已验证v1备份，禁止直接覆盖导致新资产丢失。

## 7. 测试方案

### 7.1 测试落点与级别

以下测试入口缩写仅用于表格，文件仍按真实目录组织。**所有新增测试名均为拟新增，现有文件扩展不意味着现有用例已经包含对应断言。**

| 简写 | 文件/资产 | 主要责任 |
|---|---|---|
| E | 拟新增`TEST/AssistantEndRoutingTests.swift` | 助手目标动作与设备/记录隔离 |
| S | 现有`TEST/AssistantSessionTests.swift` | 生产Session完整事件流、文字/语音切换与配置 |
| RACE | 拟新增`TEST/AssistantReplyPersistenceRaceTests.swift` | Store Gate跨await、幂等与状态三方一致 |
| T | 现有`TEST/AssistantTTSStreamCoordinatorTests.swift` | 退休屏障、ACK/限额、背压和终态 |
| B | 现有`TEST/AssistantSpeechTextBufferTests.swift` | 分包、scalar、数字/词/Markdown |
| L | 现有`TEST/AssistantPlaybackLedgerTests.swift` | played/rendered、旧epoch与预算 |
| P | 拟新增`TEST/AssistantPresentationTests.swift` | 12态、动作、文字可用性、历史状态 |
| C | 拟新增`TEST/AssistantComposerPolicyTests.swift` | 草稿、模板、发送快照、followLatest |
| CTX | 拟新增`TEST/AssistantContextBuilderTests.swift` | 路由、预算、交付说明与memory数据边界 |
| DB | 现有`TEST/AssistantPersistenceTests.swift`，拟新增`AssistantStoreMigrationTests.swift` | 保存/封存失败、v1→v2、未来版本与恢复 |
| V | 现有`TEST/VoicePromptTests.swift`和`LLMProviderTests.swift` | 模态提示、拒答/中断/EOF契约 |
| O | 拟新增`TEST/AssistantObservabilityTests.swift`，现有`AudioSampleRingTests.swift` | drop/单位/时钟/无样本/观察失败 |
| U | 拟新增`docs/implementation/2026-10-03-voice-assistant-ui-acceptance.md` | 真实12态、IME、焦点、无障碍人工检查 |
| REAL | 拟新增`docs/implementation/2026-10-03-voice-assistant-real-acceptance.md`；仓库外manifest/素材 | 真实设备、模型、音频闭环与长时报告 |

D使用生产组件+fake/合成临时SQLite；U为人工操作或当前用户明确授权的前台自动化；R为另行授权的真实模型/设备/素材。下面mixed场景分别记录子结果，初始均`not_run`。

### 7.2 A01～A60完整执行与断言矩阵

| ID | 类型 | 工作包/测试入口（拟新增用例标识） | 操作与最低断言 |
|---|---|---|---|
| A01 | D/U | VA-01；E `testA01TextEndWithoutOccupancy`；U | 建纯文字场→助手结束；自身record archived、Session idle，mic/Realtime计数为0，非no-op |
| A02 | D/U | VA-01；E `testA02TextEndWhileMeetingOwnsLease`；U | 会议占用时建文字场并结束；会议lease/occupancy/phase/record/stopper均不变 |
| A03 | D | VA-02；S `testA03BargeInTerminalThroughReceiveLoop` | 正在朗读→同一流hypothesis→cancel→该流匹配terminal；不依赖timeout，连接可继续；严禁直接调用terminal handler |
| A04 | D | VA-02；S/T `testA04CancelTimeoutFailsClosed` | 分别注入cancel写失败/无terminal；local stop先完成、bounded结果、连接关闭；late audio不恢复 |
| A05 | D | VA-03；S `testA05TailFinalDuringDrainArchivesOnly` | ending后发final及receipt；尾句原record写一次、LLM/TTS计数不增，封存晚于保存 |
| A06 | D | VA-03；S/DB `testA06ReceiptCannotBypassStoreGate` | receipt已到、final写入Gate挂起；无已保存ID/成功带；释放Gate后可读archived |
| A07 | D | VA-03；S `testA07DrainClassifiesEmptyFailedAndTimeout` | timeout、failed、正常空输入、空final但有hypothesis分别测；保留已有内容，结果类别不混 |
| A08 | D | VA-02/13；S `testA08EvidenceEmptyDuplicateAndFinalOnly` | empty/blank/重复revision不cancel；final-only在前任收尾后接管，用户行一次 |
| A09 | D | VA-04；RACE `testA09LatePartialInsertKeepsNewReply` | A建partial返回Gate→接纳B→释放A；A可存，B正文/current不被旧副本覆盖 |
| A10 | D | VA-04；RACE `testA10LateFinalizeCannotClearNewReply` | A finalize await中开启B→A返回；B streaming/history/phase不清，A按ID归位一次 |
| A11 | D | VA-04；RACE `testA11ConcurrentTerminationClaimsOnce` | stop/end/provider失败争同reply；一行/一history projection，late completed不清interrupted/failed |
| A12 | D | VA-04；S `testA12ConsecutiveInputsRetirePredecessor` | 首轮生成/朗读时接纳第二问；问题顺序确定、前任终态可见、最多一个活跃TTS |
| A13 | D | VA-05；S `testA13OldRequestCannotChangeNewState` | B活动注入A audio/failed/cancelled；B phase/闭麦/error/正文不变，A音频不入队 |
| A14 | D | VA-05/12；L/S `testA14OldPlaybackEpochCannotRefundNewBudget` | B epoch下发A rendered/played；B预算与完成证据不变 |
| A15 | D | VA-05；S `testA15SupersededStartupCleansPrivateLeaseOnly` | A建档Gate→结束A→启动B→放A；只清A私有资源，B source/client/record/lease有效 |
| A16 | D/U | VA-07；S/P `testA16DeniedMicrophoneKeepsTextUsable`；U | 拒mic后typed；可生成保存、文字态、无再次权限请求 |
| A17 | D/U | VA-07；S `testA17VoiceLossKeepsTextContext`；U | voice断线，LLM/DB可用→typed；同record/history，streamFailed不挡发送 |
| A18 | D/U | VA-01；E `testA18RepeatedAndReviewedEndTargets`；U | 重复按钮/快捷键；review旧record时活跃助手明确target；once结束、不停无关lease |
| A19 | D/U | VA-07；E/S `testA19VoiceUpgradeRequiresOccupiedLeaseDecision`；U | 文字开启voice但会议占用；明确confirm，拒绝保文字，批准后reuse同record |
| A20 | D | VA-06/07；S `testA20RetryPreservesConversationMuteAndRoute` | 失败重连再重连且mute；record/ordinal/history/route/memory/mute保持 |
| A21 | D/U | VA-06；S/CTX `testA21PreferencesCannotRerouteLiveConversation`；U | 全局endpoint A→B；active仍请求A，下一新场B；显示下次生效 |
| A22 | D | VA-06；CTX/S `testA22TextAndVoiceShareContextInitialization` | 同persona/memory selection新文字与语音场；captured上下文语义一致，仅模态不同 |
| A23 | D | VA-06；S `testA23MemoryLoadFailureNeverReusesPreviousSession` | A有memory→结束，B加载throw；B空memory且有提示，不持旧数组 |
| A24 | D/U | VA-06；CTX/P `testA24ConsentTracksDestinationAndPayloadScope`；U | 首次外部发送历史/memory→拒绝/批准→换目的地/扩大范围；新同意必要，拒绝不发送 |
| A25 | D/U | VA-08；P `testA25ConfiguredDoesNotMeanVoiceReady`；U | configured但服务关的idle；无语音已就绪，typing依实际LLM/DB前提 |
| A26 | D/U | VA-08；P `testA26TextAssistantDoesNotBorrowOtherMeters`；U | 文字助手+会议计时采集；助手无他人电平/elapsed/聆听文案 |
| A27 | D/U | VA-08；P `testA27OldReviewHasNoLiveConnectionOrFreshSuccess`；U | 三天前record，模型断开；无实时已连接/刚结束，仍可读复制 |
| A28 | D/U | VA-09；C `testA28TemplateCannotSilentlyReplaceDraft`；U | 非空草稿点击示例；插入/替换/取消目标清楚，替换Undo恢复全文 |
| A29 | D/U | VA-09；C `testA29SendCompletionPreservesNewDraft`；U | send等待期间继续键入；accepted只清旧snapshot，不抹新文字；失败留稿 |
| A30 | D/U | VA-09；C/P `testA30ReadingPositionControlsFollowLatest`；U | 中部阅读时增量+新行不强滚；回最新恢复跟随，同reply尾部稳定 |
| A31 | U | VA-09；U `U31IMEAndKeyboardRouting` | 中文拼音组合/候选Return、换行、⌘Return、Esc弹窗/菜单；无误发/穿透，焦点不跳 |
| A32 | U | VA-08/09；U `U32WindowAndAccessibilityMatrix` | compact/medium/expanded、最小窗口、字号、Light/Dark、高对比、VoiceOver/Reduce Motion；发送/停止可达、文案不裁关键动作 |
| A33 | D/R | VA-10；V `testA33ModalityPreservesRequestedStructure`；REAL | 同问题键入/语音，包含代码和详细步骤；提示契约符合模态，真实输出单独检查 |
| A34 | D/R | VA-10；V `testA34CriticalRecognitionAmbiguityIsNotGuessed`；REAL | 金额/日期/否定歧义；不自动猜改关键事实，必要澄清一次一问题；无伪造置信度 |
| A35 | D | VA-11；B/T `testA35SixHundredScalarsPartitionEquivalence` | 合成600 scalar一次与6×100；均准入并按limits合法append，拼接语义相同 |
| A36 | D | VA-11；B/T `testA36UnicodeScalarAndAckAgreement` | Emoji/组合字符/扩展汉字跨delta；raw/sent/ACK codepoint一致、文字不破坏 |
| A37 | D | VA-11；B/V `testA37WordsAndWhitespaceSurviveChunking` | Hel+lo、空格独立delta、中英；词边界保留，Store/UI原始输出不变 |
| A38 | D/R | VA-11；B `testA38NumericTokensRemainFaithful`；REAL | 3.+5、负号、百分比、12+万元/亿元、版本号；值/单位/正负不变，超时不补造 |
| A39 | D | VA-11；B/T `testA39BudgetsAreAtomicAndRespectNegotiatedLimits` | 未闭合Markdown、超大事件、total超限、服务append变小；有界、分类正确、原文可看、拒绝不改旧pending |
| A40 | D/R | VA-12；L/S `testA40TerminalWaitsForPlayedEvidence`；REAL | terminal已到但设备未播完；不宣称completed，rendered/played分开；真实设备尾延迟另测 |
| A41 | D | VA-12/14；S/CTX `testA41InterruptedPlaybackDoesNotInventHeardText` | 全生成仅播前段→stop→追问；原答案保留、朗读未完成，history有交付状态而非假已听全文 |
| A42 | D/U | VA-12；S `testA42ReplayInterruptTargetsOriginalTurn`；U | 新B存在，重播旧A再stop；更新A invocation，B不被标interrupted |
| A43 | D/U | VA-12；P/S `testA43ReplayAndSoundPreviewHaveRealActions`；U | text无TTS点朗读有原因/入口；播放中测试声音经试听协调，不经typed静默路由、不叠播 |
| A44 | D | VA-12；S/DB `testA44PendingVoiceTracksActualNextRequest` | 播A切voice B，注保存失败/revision冲突；A pin不变，下一request实际生效ordinal与记录一致 |
| A45 | D | VA-14；CTX `testA45ContextBudgetKeepsCompleteRecentTurns` | 长对话budget满；固定约束/当前问保留，历史完整turn裁剪，范围可见，不无限追加 |
| A46 | D/U | VA-14；CTX/P/DB `testA46MemoryRequiresEditedConfirmation`；U | 助手建议记住→编辑/取消/确认；确认前0写，kind/source/scope明确，不自动事实化 |
| A47 | D/U | VA-03/15；DB/S `testA47SealFailureRetainsUnsavedRecovery`；U | finalizeSession throw/0行更新；无成功ID、pendingSeal/文本保留，重试/复制可用 |
| A48 | D | VA-14；CTX `testA48MemoryIsBoundedDataAndRevocationIsExplicit` | memory含忽略规则等文本/撤销；来源数据边界，按已声明scope生效，不添工具能力 |
| A49 | D/U | VA-15；P `testA49ReuseSettingsMakesNoContextPromise`；U | 当前继续动作；标用相同设置新建，只prefill；不声称history继承 |
| A50 | D/U | VA-15；CTX/DB `testA50ContinuationFreezesSelectedSourceTurns`；U | 选旧record部分完整turn→确认目的地→新建；parent/seed可读，原文不改、不自动mic；删父后子seed仍可用 |
| A51 | D/U | VA-15；DB/P `testA51RecordOperationFailureCannotLookSuccessful`；U | rename/delete/read/export失败分开；record不丢，不退出成假成功，不写假空导出 |
| A52 | D/R | VA-05/12/16；S/L `testA52DeviceGenerationRejectsLateCallbacks`；REAL | USB/蓝牙切换与旧callback；旧epoch不污染，恢复失败可typed，stop仅自有设备 |
| A53 | D | VA-16；O/S `testA53LossAndUploadFailureAreBoundedAndVisible` | ring满、yield dropped/terminated、持续append失败；计数/单位对，队列有界，无无限刷屏 |
| A54 | D | VA-16；O `testA54ObservabilityFailureAndNoSamplesAreHonest` | observer throw、时间逆序、无sample；主流程正常，无负latency/0ms/100%假数 |
| A55 | D | VA-02/10；S `testA55ProviderFailureUsesOwnedCancellationBarrier` | delta后provider失败且TTS在播，terminal延迟；local先停、统一cancel、保存片段、旧音不继续 |
| A56 | R | VA-13/17；REAL `R56TurnTakingCorpus` | 安静真人停顿、自修正、补一句、短答案；标注抢话/漏接/合并错误与新增等待，含失败分母 |
| A57 | R | VA-13/17；REAL `R57AECAndDoubleTalkByDevice` | 耳机/内置扬声器/实际USB声卡：远端独讲、近端独讲、双讲；分设备误插话/回声/截断，开关不算通过 |
| A58 | R | VA-13/17；REAL `R58NoiseBackchannelAndQuotation` | 键盘/咳嗽/噪声/嗯对/复述助手原句；非意图不过度打断、真实插话能停，复述不被回声误杀 |
| A59 | R | VA-14/16/17；REAL `R59ThirtyToSixtyMinuteConversation` | 30～60分钟多轮语音/typed；memory/queue/tasks无持续增长，budget有效，结束设备释放证据 |
| A60 | R | VA-01/03/07/17；REAL `R60FailureSleepDeviceAndEndJourney` | 连失败→恢复→休眠→拔设备→结束完整旅程；记录真实、无跨功能误停，不自动录音/重播旧内容 |

### 7.3 必补的交叉边界

除原60场景，还应随相关包补以下小型变体，不扩大真实验收范围：

- A03/A04：terminal在闩登记前到达、旧terminal之后新start、cancel effect本身被end取消；所有waiter回收。
- A05/A06：ASR final已在event stream排队但receipt返回更早；应用marker证明保存屏障，不靠Task.yield猜顺序。
- A09/A10：Store实际上提交后返回超时；幂等重试不得出现重复行或重写较新revision。
- A12：typed与ASR final同turn window同时进入、end与ask同时进入；accepted必须对应固定session与已保存问题。
- A21/A24：密钥撤销、同endpoint不同model、同route扩大history发送范围；禁自动备用provider。
- A35/A39：server总量小于清洗后输出、代码块跨TTS最大片长、未完成数字紧贴deadline；安全停止不删正文。
- A40/A52：played不回、device重建后旧rendered/played双回；完成与失败都一次，取消不假造played。
- A47/A50：迁移失败rollback、future schema只读拒绝、父record删除、seed超限、活跃record移除保护。

修复缺陷优先使原反例在未修实现上失败，再验证修复后通过。若旧行为无法通过fixture复现，报告证据限制，不把测试改成验证实现私有细节以凑通过数。

## 8. 验收标准

### 8.1 本方案交付与实现验收分开

**本方案交付可立即检查**：

- [x] 原文件在项目目录，字节/hash一致，Downloads原路径已移走。
- [x] 本文件十段齐全，原方案20章及F18/VA18/A60对应完整，所有拟新增项与已核验事实区分。
- [x] 本轮文档操作仅涉及两份语音助手方案，其他任务文档与业务文件未由本轮修改；期间新增的已有文档提交已保留。
- [x] 无测试/模型/UI/性能/安装成功的虚假声明；无秘密/真实音频/私人正文。

2026-10-03交付复核：文档结构、ID唯一性、验收类型、工作包文件/步骤/完成条件、表格、链接、路径、原文件哈希与Git差异共40项检查通过。当前未提交修改仅本执行方案，暂存区为空，差异空白检查通过。该结果仅证明本次文档交付，不计入后续A场景通过数。

**后续实现全部需实际证据**：

- [ ] M0控制、输入、输出、保存、路由不变量确定性回归通过。
- [ ] M1十二态和主动作D通过，IME/可访问性/视觉U单独记录。
- [ ] A01～A60每个子类型有not_run/pass/fail/blocked状态及证据；未跑R不得算通过。
- [ ] 新schema在合成空库/v1/future/failure/reopen验证，旧内容/序号/star/时间保留。
- [ ] 生产App与SwiftPM membership一致，当前部署目标仍macOS26+，未新增旧系统兼容分支。
- [ ] 观测单位/分母/超时正确，私密数据不上诊断。
- [ ] 文档、契约变化与实现一致；发布/安装/真实迁移按独立授权。

### 8.2 待执行命令与预期结果

以下是后续实施的命令定义。本轮仅执行只读Git状态与差异校验，**未运行Swift测试、App构建或Xcode测试**。实施者先核对当时AGENTS、Swift工具链与现有授权；命令不能包含真实凭据/素材路径。新测试文件加入target后才使用其filter。

```sh
# 仓库根目录：确认基线与任务改动
git status --short --branch
git rev-parse HEAD
git diff --check

# M0核心编排/取消/持久化，仅fake和临时合成Store
swift test --package-path macos/SpeechRailApp \
  --filter 'AssistantSessionTests|AssistantEndRoutingTests|AssistantReplyPersistenceRaceTests|AssistantPersistenceTests|AssistantTTSStreamCoordinatorTests'

# M1/M3纯展示、输入、context、提示/provider
swift test --package-path macos/SpeechRailApp \
  --filter 'AssistantPresentationTests|AssistantComposerPolicyTests|AssistantContextBuilderTests|VoicePromptTests|LLMProviderTests'

# M2文本、播放、资源、迁移
swift test --package-path macos/SpeechRailApp \
  --filter 'AssistantSpeechTextBufferTests|AssistantPlaybackLedgerTests|AssistantObservabilityTests|AudioSampleRingTests|AssistantStoreMigrationTests'
```

预期：实际发现相应测试、所有相关断言通过、无挂起任务/continuation misuse、无意外网络/权限/真实音频。不能把filter未发现测试或仅exit0算通过；报告suite和具体场景发现数量。

`.app`构建获得授权后使用：

```sh
scripts/macos_app_build.sh --configuration Debug
```

预期：包装脚本构建成功并处理临时App登记/清理，编译目标含本任务生产文件。不得裸跑`xcodebuild`。如明确获准验证Xcode单测生产membership，可用：

```sh
SPEECHRAIL_MACOS_ONLY_TESTING=SpeechRailAppTests scripts/macos_app_test.sh
```

该脚本默认testPlan包含前台UI测试，因此必须保留only-testing限定；不把此例当成本轮批准。前台UI自动化只能在当前用户逐次明确要求时按准确目标运行，先说明窗口与时长；本方案默认人工U清单。

若实际改wire：增加当前受影响的Realtime Swift/Python契约定向回归与schema检查，明确列出变更事件/字段。完整pytest、完整Swift套件、redocly下载、变异探针、benchmark不作为每个VA默认动作。新增replay CLI名字和参数当前尚不存在，工具落地时再给真实`--help`与命令，不编造可运行脚本。

### 8.3 指标定义、失败分母与候选门槛

所有指标用单调时钟；真实发言结束/插话开始由获授权素材标注。schedule时间不是设备物理出声，网络首音不是设备播放；不足证据单列approximate/N/A。

| 指标 | 起止/分母 | 必须保留的失败与证据 |
|---|---|---|
| 发送回执 | 提交→本地UI接纳/拒绝反馈 | accepted与rejected均统计，不能把模型完成算回执 |
| 语音准备 | 开始动作→实际采集且Realtime配置确认 | 冷/热/首次权限独立；权限等待与失败不隐藏 |
| 首字 | request发出→首个可展示正文 | 空白/心跳/推理不算；失败/拒答/空内容分别计 |
| 首音 | 标注用户发言结束→有效输出开始播放 | ASR final→schedule另报；设备真实出声需要R测量 |
| 手动停止 | 用户stop→local playback屏障完成 | 设备尾音另报，远端terminal等待另报 |
| 插话 | 标注近端插话开始→local停止 | 包括检测等待，不能只报cancel函数耗时 |
| 远端取消 | cancel发出→matching terminal | 写失败/timeout均入分母，禁以send完成作确认 |
| 错误插话 | 非意图样本被cancel/非意图样本 | 按回声/噪声/附和分层，并报每小时误停 |
| 漏插话 | 真插话未在固定评价窗停/真插话样本 | 评价窗与设备分层在采样前固定 |
| 尾句完整 | 有已准入尾部且正确归档/对应attempts | 空输入不纳；unconfirmed/failed/unsaved独立 |
| 文字降级 | LLM/Store满足时voice失败后typed完成/此类attempts | LLM也不可用另分类，不美化分母 |
| 内容保真 | 数字/单位/否定/专名正确单元/标注单元 | 不用总体WER掩盖金额/日期错误 |
| 保存一致 | UI称saved且可读回/相关attempts | Store/内存/history分别检查；内存恢复不是saved |
| 资源稳定 | resident、各queue、drops、active tasks、设备stop | 配置与时间一致，系统缓存增长不直接当leak |

承接原方案候选值：UI回执P95≤100ms、local手动停止P95≤150ms、纯归约单event P95≤10ms；这是**候选工程门槛、未测**。8s是现有输入drain预算起点，非结束总耗时承诺。确定性安全场景零失败与分包测试100%语义一致仅限定义测试集，不推广为现实永不失败。

首音、自然插话与新policy必须先测设备/模型基线再定阈值。比较前固定允许退化量、评价窗、样本数与分层，不看结果后改口径。报告至少含attempts/successes/failures/timeouts/sampleCount、base/head、policy、配置revision和D/U/R等级。

### 8.4 真实样本与设备执行法

1. 素材均为已授权真人互动/录音，放仓库外；普通话、英语、中英混合、慢停顿、快补充、低声、数字与技术词均有标注。
2. 至少耳机、内置扬声器、一组实际外接音频设备；设备型号、系统、ASR/TTS/model/voice revision由实测记录，方案不猜。
3. 先小样本发现严重问题，再按现象扩展。缺某设备或sample不足报告缺口；总体200事件不能替代外放仅3事件的统计。
4. A56以人工标注语音结束/意图评判抢话、丢句、合并错误；A57必须扬声器→房间→麦克风真实闭环；录音重放不能冒充AEC双讲证据。
5. A58的复述/纠正必须作为真输入保留，附和/咳嗽/键盘作为非意图分母；不靠文本相似度自动给回声真值。
6. A59监控30～60分钟的趋势、活跃任务与queue高水位；A60按失败/休眠/设备/结束逐步检查Store与实际设备释放。
7. 样本用途、保留位置、删除方式事前说明；真人分歧保留复核，零错误仍附sampleCount和不确定性。生产真实会议不是默认测试素材。

## 9. 风险与注意事项

| 风险 | 具体防护与回退 |
|---|---|
| 共享coordinator影响会议/字幕/提词器 | 目标lease+record校验，扩展返回值要更新相关调用点；有全局含义的命令保持准确名称，D隔离用例先补 |
| 接收改造引入事件乱序/Task泄漏 | 单receiver、单音频consumer、显式effect句柄；control不等远端；取消/close能解除waiter，late结果按身份对账 |
| ending过早撤连接或过晚允许新回复 | draining资格仅ASR归档；输出权立即撤销；marker前保存屏障；所有start/submit入口查生命周期 |
| 保存失败被误判missing row | 原子目标upsert、稳定错误分类、0行不成功；saveFailed保内容，幂等重试不重新生成 |
| v2迁移与旧App回滚 | 合成副本先验；真实库授权备份；事务迁移；future schema拒绝；先保留新增数据再恢复旧备份 |
| played回调增加背压或不回 | fake delayed/missing回调与device failure覆盖；有界timeout，不能补造played；若拆rendered/played要约束实际在途量 |
| 新路由/记忆同意打断使用 | 只在新目的地/发送范围扩大时说明；拒绝保稿，当前route不偷偷换；Keychain链不新建wrapper |
| 预算裁剪影响长对话 | 完整原文留库、选完整turn、范围可见；unknown model采用明确客户端限额而非虚构window |
| policy提升延迟或误杀复述 | baseline对照后开启、独立revision可退；手动stop一直直接优先；没有证据保持实验关闭 |
| UI视觉与IME无法由D证明 | U逐项人工验收或另行明确UI授权；不以离屏snapshot/状态单测宣传实机通过 |
| 原计划Git建议扩大授权 | 文档不批准commit/push/PR/merge；根AGENTS优先；获得提交授权才执行建议原子提交点 |
| 性能/质量工具触发运行态 | REAL/benchmark另行授权，使用专项skill；不自动下载/加载模型、切档、重启或安装 |

条件增强决策闭环：

- ASR-only/TTS-only/按住说话：真实独立需求与能力合同明确后，提交局部设计/测试，复用现有record/transport/播放边界；当前以文字降级、明确play说明、一问一答提供完整默认出口。
- turn aggregation/VAD提前duck：需A56～A58分层基线与固定评价窗；不采纳云端未支持事件。
- 有来源摘要：需证实预算裁剪损害继续讨论，并单独确认可发送范围；优先近期完整turn，不阻塞模型失败时继续。
- UI合批/LLM-TTS解耦/分包/预检缓存：需VA-16/17定位具体瓶颈；没有证据的优化列`deferred_evidence`和原因，不能删需求或算性能通过。

回退顺序：退实验policy→语音故障明确文字继续→TTS失败保留文字→取消未知关闭连接→保存失败保留pending与复制出口。不得回到跨会话全局误停、旧事件污染或直接丢尾句的旧路径。源码回退只作用本任务改动且保留后续他人修改；真实运行态回滚按专项流程。

## 10. Luna 执行清单

### 10.1 顺序、依赖与退出条件

本清单是未来实施交接，不是本轮执行授权。先核对目标分支、工作区与证据时效；与固定baseline不同先检查受影响符号，不重新分析整仓，也不覆盖其他任务。

| 顺序 | 工作包 | 具体完成条件 | 建议提交单元 |
|---|---|---|---|
| 1 | VA-17a | Gate/捕获/fake terminal/scalar ACK及A账本可用；生产seam不触真实资源 | 工装+关键反例 |
| 2 | VA-01 | A01/A02/A18目标结束隔离，所有助手入口统一 | 目标动作+回归 |
| 3 | VA-02 | A03/A04/A08/A55控制环可前进，retirement barrier无空隙 | effect/receiver+回归 |
| 4 | VA-03 | A05/A06/A07/A47双屏障与seal真实结果，停设备可等待 | drain/保存/释放一体 |
| 5 | VA-04 | A09～A12回复ID/revision/once/history一致，所需v2基础迁移 | 事务+迁移+回归 |
| 6 | VA-05 | A13～A15/A52迟到事件与startup不污染新代 | 所有权过滤 |
| 7 | VA-06 | A21～A24路由/记忆统一与同意，M0退出 | context snapshot |
| 8 | VA-07 | A16/A17/A19/A20同场typed恢复/升级正确 | 降级与恢复 |
| 9 | VA-08 | A25～A27与12态P覆盖，数据说明准确 | presentation+View |
| 10 | VA-09 | A28～A32入口/草稿/滚动D+U分账 | composer/阅读 |
| 11 | VA-10 | A33/A34模态提示、provider分类与既有终态回归 | prompt/adapter |
| 12 | VA-15a | A47/A49/A51标签与资产失败真实，M1退出 | 资产闭环 |
| 13 | VA-11 | A35～A39分包/预算/清洗保真 | buffer/renderer |
| 14 | VA-12 | A40～A44played、invocation、voice与试听一致 | 播放交付 |
| 15 | VA-16 | A52～A54有界计数/时钟/失败，最小部分已随M0加入 | 观测与资源 |
| 16 | VA-13 | A08必修证据；A56～A58基线后决定policy | 安全策略与实验分开 |
| 17 | VA-14 | A41/A45/A46/A48预算与记忆来源/确认 | context/memory |
| 18 | VA-15b | A50parent/seed/范围同意，旧record不改 | 明确上下文续接 |
| 19 | VA-17b | A01～A60子状态完整，A59/A60真实结果或not_run | 评估资产/报告 |
| 20 | VA-18 | 单项优化决策、文档/membership/交付门禁闭环 | 每项优化与文档分别 |

AssistantSession是主要冲突文件，默认串行owner；本轮未启动子代理。以后用户明确要求委派才用`luna_worker`，文件写owner唯一，不覆盖并行修改。

### 10.2 每个逻辑单元的执行合同

1. 定位本包现有符号、相关契约和测试；check_index_coverage有缺口时直接读变化范围。
2. 先写可复现预期的回归，再实现该包；fake不会加载模型/录音/访问网络。
3. 运行§8对应的最小相关检查，记录发现/通过/失败场景；未授权U/R保持not_run。
4. 检查diff、依赖、source membership、隐私与迁移影响；对实际正文变化同步active文档。
5. **仅在用户已明确要求提交时**：精确暂存本单元文件，检查`git diff --staged --check`、staged diff与敏感字段，创建`<type>: <why>`本地commit；记录hash。不得带入别的未跟踪方案。
6. 没有提交授权交付未提交diff与拟提交单元；没有push/PR/merge/release授权不推进远端。原方案关于临时workflow/API发布的建议不进入默认执行。

### 10.3 最终实施报告必须包含

- base/head、分支、实施日期与18包状态；对应commit hash，未提交明确标明。
- A01～A60每个D/U/R子项的真实状态、实际命令/操作、结果与证据入口。
- Store/内存/history三方一致结果；v1→v2临时库验证、真实数据操作是否发生、备份/回退条件。
- 设备停止、网络receipt、应用保存marker各自结果；无跨会话误停的明确断言。
- 模型/声学/性能的baseline与candidate对照，或未执行理由；无样本N/A。
- policy未开启/未采纳项与证据、UI人工/自动化范围、构建/安装/LaunchServices状态。
- 保留的并行改动、未验证风险、还需用户或外部条件的事项。

**本文件交付状态**：已形成完整执行与验收设计；本轮仅文档落盘和移动。所有实现、测试、真实体验、性能、迁移与发布结果均待执行，不能据本文件宣称已通过。
