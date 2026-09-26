---
title: "App-Service 集成审查与 Luna 实施指导"
status: in_progress
version: "1.3"
date: 2026-09-26
baseline: "main@1116aa85"
---

# 1. 问题结论

采用“保留产品结构、收口能力和请求边界”的方案。原设计方向成立，但存在会让实现出错的关键细节，已同步修订 [设计文档](../specs/2026-09-26-app-service-integration-design.md) 至 1.4（含 readiness 门禁澄清、本机存量数据授权与核查结果及 D1 实施状态）：

| 优先级 | 已确认问题 | 修正 |
|---|---|---|
| P1 | 所有 TTS 都取 `models.tts.catalog_revision`，clone 实际使用独立 Base 制品 | pin 从选中 safe voice 的 `model.catalog_revision` 获取 |
| P1 | 保存前对临时预览的勾选被用于稍后新生成 candidate 的 machine validation | 人工确认只能绑定实际听过的 candidate/validation；D1 是跨端前置项 |
| P1 | ASR text final 被视为所有辅助结果终态 | 分开 text、alignment、diarization；会话 finish 与 item 终态不能混用 |
| P1 | “有界流”没有溢出语义，可能丢音频或终态 | 数量/字节双上限；溢出显式关闭，独立通知会话，禁止静默丢包 |
| P1 | 助手仅检查 TTS | 输入需 `realtime_transcription`，输出需选中 voice 的 `realtime_speech` |
| P2 | 将 clone idempotency 查询当注册接口 | POST `/v1/voices/clone` + 同 key GET 查询；不以列表猜测成功 |
| P2 | 三个并行 GET 被描述为原子快照 | 仅 effective snapshot 内部原子；本地 generation 不制造远端事务 |
| P2 | 作品重放/导出设计成重新合成 | 保留本地已保存音频，离线可用 |
| P2 | 原文误称 DTO/取消顺序都缺失 | 保留已有 revision/validation DTO、先停播再取消实现，增量补齐 |

方案形成时，审查仅修改设计和本方案。之后同一任务已在 `codex/app-service-integration` 工作区产生未提交的实现改动；不得把审查时的干净起点当作当前状态，也不得盲目重复下列切片。当前可确认的实现差异与验证证据见 §2.3、§8.1。本方案仍是实施指导，不等于整体验收。

**实施状态：**2026-09-26 用户补充授权“当前本机，不符合要求的存量数据均可清除”。D1 纳入目标方案，存量数据兼容不再是待确认项。当前源码定义的默认候选存储文件和资产目录不存在，本次没有需要删除的候选数据；详细核查范围见 §8.1。授权不覆盖其他数据根目录、远端或无关数据。

# 2. 当前实现与根因

## 2.1 证据与复现方式

核实日期 2026-09-26（Asia/Shanghai）。审查起点为 HEAD `1116aa85`，当时工作区干净；该提交仅添加原设计，实现基线为 `ee170d08`。这是历史审查基线，不是当前分支状态。下表记录当时的静态代码/契约证据，复现为拟编写的确定性用例，不代表已运行。

| 文件、符号 | 当前逻辑及问题复现 |
|---|---|
| `macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift`：`SpeechRailCapabilityRevisionSelector.creatorRequestOptions` | 无 snapshot 返回空 options；voice revision 可从 rich voice fallback；模型固定 `models["tts"]`。让 clone voice.model 与 models.tts revision 不同即可暴露错 pin |
| 同文件：`CapabilitySnapshotStore`、`CapabilityDiscoveryState` | 已有 generation/ETag/304 与错误状态；需复用，不能另建第二套缓存状态机 |
| `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`：`speechRequestOptions`、`refreshServiceCapabilities` | 双能力来源与可空 pin；失败后的旧显示数据必须与执行准入分离 |
| `ServiceAPIClient.swift`：`updateVoice(...expectedRevision:)` | nil 时调用旧 PATCH；用 nil revision fixture 验证旧请求被发出 |
| `CreatorServiceClient.swift`：`VoiceDesignCandidate`、`VoiceDesignValidation` | 已有 revision/publishable/validation ID；需要补充状态与模型身份等缺失投影，不是从零建 DTO |
| `AppModel.saveDesignedVoice` | 接收提前勾选的两个 Bool，create→confirm→machine validate 后自动绑定新 validation ID；临时试听并非被验证音频 |
| `src/speechrail/http/routes/voice_designs.py`：`create_candidate`、`confirm_candidate`、validate 路由 | create 不接收 speed；validate 省略文本时生成受控新文本；Base 输出没有可供 App 读取的音频资源 |
| `src/speechrail/application/voice_design.py` | reference WAV 已持久化；validation 记录 output hash，安全投影不包含私有路径 |
| `RealtimeASRClient.events`、事件解析 switch | `.unbounded`；sequence validator 只更新诊断；辅助事件直接写 map，未验证 task/epoch/revision |
| `src/speechrail/application/realtime_openai.py`：`_send_diarization_updates`、`_drain_and_finalize` | 同 metadata revision 可分片；done 是会话 finish 屏障，不是每条 ASR final 的固定后继 |
| `AssistantTTSStreamCoordinator.cancel`、`AssistantSession` | 已实现 stopPlayback 后 cancel；保留这一顺序 |
| `AppModel.playWork`、`CreativeWorkStore` | 使用保存音频；不能为了“统一服务入口”改成网络请求 |

代码路径中未发现原设计所称 `alignmentOrder`；实施应依据实际字段而不是照抄这个名称。图谱 MCP 未可用，证据通过定向源码查询获得；未进行仓库全量架构审计、远端 PR 审核或运行态诊断。

## 2.2 深层原因

发现状态、业务支持、暂时不可用、身份版本混为可选 Bool/String；缺 revision 被解释为可继续协商。音色创作的“临时选样”和“耐久候选验证”则共用保存前的人工确认状态。Realtime 将文本完成、辅助更新、连接关闭混作一种终态。应在已有客户端与状态模型边界修正，保留导航、会话引擎和作品持久化格式。

## 2.3 当前工作区与剩余验收

2026-09-26 在 `codex/app-service-integration` 上复核当前实现。此处记录提交 PR 前的工作区状态，不改写 §2.1 的历史基线；当时代码仍是未提交改动。

| 区域 | 当前实现与证据 | 剩余边界 |
|---|---|---|
| Capability、API client、CAS 与刷新 | `AppCapabilityFacade` 消费单份 effective snapshot；普通与 Realtime TTS pin 取选中 voice 的 model revision。Client 走 current-only route，AppModel 测试覆盖 stale/unknown、同 key clone、并发刷新和冲突状态。 | 当前只有 fake transport/服务证据；未连接运行中的服务。 |
| VoiceDesign D1 | reference 与 validation WAV 按 candidate revision/validation ID 读取，检查 WAV/PCM hash、大小、鉴权和 symlink；`no-store` 与 OpenAPI 已同步。创作 UI 状态要求试听后绑定 validation ID。 | 确定性 workflow/UI state 测试通过；未在实际 App 中播放真实服务返回音频。 |
| Realtime event/state | sequence/session 身份在业务 switch 前校验；连接 generation 隔离；同 metadata revision 分片合并；bounded event/audio queue 及 item 窗口均有显式上限和 overflow terminal。单 item 另限制 64 KiB transcript、1,024 alignment units、1,024 diarization spans 及约 256 KiB 合计辅助数据。 | 仅由合成事件与 fake transport 验证；未做真实会议长稳或性能验收。 |
| 会话 readiness 与本地作品 | 四类会话用 operation binding 作准入，`/readyz` 留作诊断；Assistant 保留 stop-before-cancel。作品播放仍从 `CreativeWorkStore` 读本机音频。 | 未启动 App 或服务；键盘、VoiceOver 与实际交互未手工检查。 |

本轮已复审并修复确认/发布直接读 reference path、取消状态可被迟到结果覆盖的问题；安全读取统一校验 repository 内资产身份。用户授权的本机 VoiceDesign 默认候选路径核查结果仍为无对象，未执行清理。

# 3. 目标行为

1. 任何依赖服务能力的新动作只接受 `.loaded` 且未 stale 的 `effective_capabilities_v1`。旧显示值可保留但不能准入；404/405/无效 schema 不走旧能力接口。
2. 普通 TTS 只从同一次 snapshot 构造完整 binding：canonical voice ID、voice revision、对应 voice model catalog revision、operation 参数；参数不支持就禁用该参数，unknown 不自动扩展能力。
3. 临时预览与发布流程分开：预览固定 4 slots/既有 seeds、speed=1.0；保存依赖 batch ASR、Base 复验、实际试听与 revision 守卫。普通音色试听、配音不进入 VoiceDesign。
4. 已发布目录 mutation 成功后刷新展示；刷新失败只标本地 stale，不回滚远端，也不让用户误以为 mutation 未完成。
5. 语音助手检查输入与输出；会议、字幕、提词器检查转写，辅助能力按 opt-in 单独处理。readyz 仅附加诊断，不推翻操作门禁。
6. 旧连接/旧身份不影响新 UI；有效辅助事件可以晚于 text final。流和临时 map 有界，溢出/超时有显式用户状态。
7. 作品重放/导出无需服务；语音生成失败不会影响已有作品。

# 4. 推荐解决方案

保留 `CapabilitySnapshotStore` 和现有 ControlKit DTO；在 App 增加纯值 `AppCapabilityFacade` 与不可变 request binding。当前实现将 facade 放在 `AppModel.swift`，Realtime 使用 `RealtimeCapabilityBinding`；没有新增独立 `AppCapabilityFacade.swift` 或泛化状态框架。把旧 selector 的判定统一委托给这一实现，不能保留两个独立解析器。

单独改文案无法解决错 pin 和事件错配；全量重写 App 数据层又会扩大回归面。推荐按依赖切片，每个切片有独立 fixture 和失败路径；不新增通用状态框架、不改数据库、不迁移模型。

## D1：候选试听契约（已纳入并实施于当前工作区）

建议以现有 candidate 资源为所有权边界：

| API | 请求 | 响应与约束 |
|---|---|---|
| `GET /v1/voice-designs/{candidate_id}/audio` | `SpeechRail-Expected-Candidate-Revision` 必需 | 返回当前 candidate reference `audio/wav`；revision 不符 409 |
| `GET /v1/voice-designs/{candidate_id}/validations/{validation_id}/audio` | 同一 revision header | 返回该 validation 的原始 Base 测试输出 WAV，不重新推理；校验 validation 属于 candidate/revision |

两者沿用现有 API key 策略、错误 envelope 和 request ID；返回 `Cache-Control: no-store`，禁止返回本机路径或从请求接受文件路径。不存在为 404；取消或失效候选为 409；旧 validation 没有资产时返回 409 `validation_audio_unavailable`，提示重新验证，不能重新合成后仍冒用旧 validation ID。

validation 生成成功时保存对应 WAV 到已有仓库外 candidate 资产目录，以 candidate ID + validation ID 定位；保存失败不能生成“可试听通过”的记录。保留现有 validation 数量上限，并沿用参考生成 `_MAX_REFERENCE_PCM_BYTES` 约束输出大小；资产读取在已授权 repository 根内解析，权限沿用现有私有资产写入方式。现有 `output_audio_sha256` 是 PCM hash，校验 WAV 中的 PCM，不把整个 WAV hash 混同。不为已有记录回填推理、不改其声学身份。取消只处理当前 candidate 所有资产，不扫描或删除用户其他音色。

更新 `application/voice_design.py` 的私有记录与投影时直接落实目标必需字段；旧记录缺少必要音频身份或资产时可按 §9 清除，不为其增加可空字段或旧格式读取层。满足目标契约的现有记录保留并验证 round-trip。当前默认目标目录不存在候选存量，因此本轮无清理操作；后续清理必须显式列明对象，不在请求读取或 App 启动路径中静默删除数据。

UI 顺序为：创建耐久候选 → 听其 reference/确认参考文本 → machine validate → 听当前 validation 输出 → 两项人工判断 → 提交绑定 validation ID 的 human_review → 检查 publishable/revision → publish。更换 reference、validation、模型 binding 后撤销旧勾选。监听音频播放结束只能开放人工判断入口，不能自动生成 pass。D1 完成前停在待试听，不开放 publish。

# 5. 详细实施步骤

所有相对路径以仓库根为起点；App 下文件未重复写长前缀时，指 `macos/SpeechRailApp/SpeechRailApp/`。新增文件均明确注明。

## S1：先锁定错误 pin 与 capability 状态回归，再迁移消费者

- 修改 `SpeechRailMacControlTests/ServiceContractTests.swift`：增加 clone/CustomVoice 不同 model revision、alias、缺 revision、缺 operation、旧 schema、304 无缓存、刷新失败后旧值不可执行的用例。
- 修改 `SpeechRailControlKit/ServiceContractTypes.swift`：保留 store，补充所需 typed operation 投影；不创建另一个 discovery 枚举。顶层 ASR/preview 的 status 与逐 voice speech operation 形状分别解码。
- 在 `AppModel.swift` 实现纯值 `AppCapabilityFacade`：输出 availability 与 binding。只在此解析 JSONValue；合成 model pin 必须来自匹配 voice.model。
- 修改 `AppModel.swift`：`speechRequestOptions` 改为可失败的完整 binding 获取；缺 pin 最多刷新一次，仍缺失就不发请求。迁移 `CreatorSurfaceViews.swift`、`ServiceOverviewView.swift` 的生产门禁。
- facade 与相关状态放在现有源文件，未新增 Swift source，因此不需改 `Package.swift` 或 Xcode source registration。
- 完成条件：snapshot 不可用、旧 models 声明 true 时也不开放；正常 clone pin 等于 clone artifact 而非 CustomVoice artifact。

## S2：current-only mutation 与刷新

- 修改 `CreatorServiceClient.swift`、`ServiceAPIClient.swift`：业务 CAS 方法 revision 改为非可空；移除 App 生产旧 update overload/fallback，quality-runs 不再回退旧路径。服务端旧路由不在本任务删除范围。
- 修改 `AppModel.updateVoice` 与 mutation 成功处理：保留用户编辑内容；409 显示状态已变化，先刷新再由用户重试，不自动用新 revision 覆盖。
- `refreshCapabilitySet()` 以 generation 控制提交；effective snapshot 为唯一执行依据，safe list ID 不一致只标 stale 并重取；最多一次自动重取后交给显式刷新，避免持续写入时无限循环。
- candidate create/confirm/validate/cancel 只刷新 candidate；发布、注册、音色 update/rollback/revoke/delete 才刷新目录集合。
- 更新 `AppModelTests.swift` 与 `ServiceContractTests.swift` 中的请求构造测试（fake transport，不访问真实网络）。
- 完成条件：一次远端成功 + 本地刷新失败不被显示成写入失败；晚到旧 refresh 不覆盖新结果；请求记录无旧 fallback。

## S3：clone 幂等与客户端补齐

- `CreatorServiceClient.swift` 增加 clone status、candidate list/get/cancel、pronunciation list 协议方法与 DTO；`ServiceAPIClient.swift` 按 OpenAPI 实现。candidate 读取使用 GET `/v1/voice-designs`、GET `/v1/voice-designs/{candidate_id}`，取消使用 POST `/v1/voice-designs/{candidate_id}/cancel`，不臆造 DELETE。
- clone 注册保留既有 register 方法中的 `idempotencyKey` 参数；key、voice ID、音频内容和其他表单参数在一次逻辑操作内固定。
- `AppModel.swift` 保存 in-flight registration 上下文（仅当前进程内；不新增明文日志/磁盘音频副本）。超时通过 GET status 查询，`completed + result_id` 才成功，pending 显示处理中，404/new 原 key 原 payload 重试，401/503 显式重试，409 不换 key。
- 同步 `App.swift` 中 preview/demo client 和测试 doubles，使新协议编译完整，但不要借此恢复生产 fallback。
- 完成条件：同一次注册经历超时和查询仍只有一个 logical key/voice ID；未知结果不会产生第二个 clone。pronunciation list 仅客户端补齐，无管理 UI。

## S4：候选状态与人工复核

- `CreatorServiceClient.swift` 增量补 candidate state、validation 模型身份/时间等 OpenAPI 字段，保留已有 revision、publishable、validations；未知 state 保留诊断并禁用操作。
- `AppModel.startVoiceDesignGeneration`、`saveVoiceDesignCandidate`、`saveDesignedVoice`：把一次长保存操作拆成 generation-scoped candidate 工作流。拟用本地状态 `creating/confirming/validating/awaitingReview/publishing/published/cancelling/failed`，它不替代服务 candidate state。
- `CreatorSurfaceViews.swift`：先呈现下一步动作；临时预览确认不沿用到耐久候选，实际复核后提交；取消、离开推进 generation，迟到响应仅供资源收束，不能改变新页面。
- 当前工作树已包含 §4 的两个音频读取资源、repository WAV/PCM hash 校验、OpenAPI、测试和分阶段试听 UI 改动；先核对现有实现，修复差异，不重复造接口。当前默认目标存储中没有候选文件或资产目录，故本机清理是 no-op；不得扩展为通用清理工具、迁移层或其他存储清理。
- publish 超时 GET candidate；published 则刷新目录，不能 cancel/delete 已发布结果。create 超时以相同 idempotency key 重试恢复 ID；已知未发布 candidate 才执行 cancel，失败保留可重试状态。
- 完成条件：新 revision/validation 使旧人工确认失效；机器 gate 未 pass 或资产未试听不能发布；对现有 route/client/UI 改动的回归证据齐全，且不把有限自动化结果说成 UI 人工验收。

## S5：会话 preflight 与 Realtime 生命周期

- `App.swift` 组合根：用 facade 替换四类 readiness-only closure；助手要求 ASR + TTS，其他三类要求 ASR；保留权限检查与麦克风生命周期。
- `AssistantSession.swift`、`TeleprompterSession.swift` 及其调用配置：会话捕获不可变 binding；ASR pin 用 `models.asr.catalog_revision`，TTS pin 用选中 voice.model。`session.speechrail.expected_asr_revision`/`expected_tts_revision` 与 `speechrail.tts.start.voice_revision`/`expected_model_revision` 按各自 wire 字段编码，不凭同名 Swift 属性猜测 wire key。
- `RealtimeASRClient.swift`、`SpeechRailControlKit/RealtimeContractTypes.swift`：sequence/session 验证必须在任何业务状态写入前执行；连接重新建立分配新 generation，不复用事件 validator。
- 在 `RealtimeASRClient.swift` 实现纯值 `RealtimeEventState`，负责 item identity、revision、关闭标记和辅助窗口策略；音频播放仍归已有 playback/coordinator。
- 按 §6 实现缓冲及回收；保留 `AssistantTTSStreamCoordinator.cancel` 的既有 stop→cancel，补迟到音频、cancel 失败和超时测试。
- 完成条件：旧 generation 不污染新状态，同 metadata revision 多片均保留，ASR final 后有效辅助更新仍显示；长期模拟流内存有固定上界。

## S6：呈现、监控和文档

- `ServiceOverviewView.swift`、`ModelManagementView.swift`：普通 speak 与“音色创作（按需）”分开；删除 legacy 判定，保留模型/alias discovery。
- `RuntimeMetricsSampler.swift`、`RuntimeMonitoringView.swift`：请求数按 speech/previews endpoint 分列，时长保持原 lane 口径；没有 label 不推算。不要把准备/读取 candidate 当作普通 TTS 请求。
- `docs/users/effective-capabilities.md`：修正旧的“当前全部 voice_revision=null”等过时断言，与内容寻址 revision 的代码/契约区分；明确 model pin 取对应 voice.model，不以页面历史认证作为本轮实测。
- `contracts/openapi.yaml` 删除 VoiceDesign reference-only 描述；D1 同批更新 API、DTO、测试、用户文档。
- 界面依赖设计系统 Token 与共享控件；禁用原因可见、键盘/无障碍可读。`CreativeWorkStore`、`playWork` 和导出格式保持不变。
- 完成条件：API/呈现一致、监控无假拆分、作品可离线回放；不改根 README、不改版本号或发布配置。

# 6. 关键实现说明

## 6.1 binding 的唯一来源

```text
resolveSpeech(snapshotState, voiceID, operation):
  require state == loaded and snapshot is not stale
  match exactly one voice by canonical id or alias
  require voice.available and operation object exists
  validate requested speed/output against this operation
  require non-empty voice.voice_revision
  require non-empty voice.model.catalog_revision
  return immutable binding(snapshot identity, canonical voice id, both pins)
```

失败返回 typed reason，不返回空 options。顶层 snapshot catalog revision 是内容缓存标识，不是制品 pin。status supported 不等于已加载、无 busy、质量合格或 full duplex；preview supported 也不证明整个 candidate 发布工作流可用。

## 6.2 刷新和结果未知

本地刷新 generation 是提交顺序，不是服务锁。任何 mutation 成功后先记录成功，再刷新；失败时显示“已保存，状态待刷新”，阻止新的 revision-dependent mutation。端点或认证上下文变化清缓存。304 只在同资源/同认证上下文且已有缓存时有效。

网络超时有三种不同语义：读失败可重读；幂等注册可查询/同 key 重试；publish 先 GET candidate 状态。禁止把三者统一成“重试整个按钮动作”。

## 6.3 Realtime 身份、版本和缓存

- 身份包含本地连接 generation + session_id + task_id/epoch + utterance_id；transcript/metadata revision 是身份内版本，不是无限创建新对象的 key。
- 基础 ASR completed 不带 extension revision；只按契约可用字段解析。无 hypothesis 时允许 final，辅助绑定由该 item 第一个完整、通过 span 校验的辅助事件建立；未知 item、关闭 item 不建立新缓存。
- alignment 与 diarization 维护各自 revision。旧版本丢弃；相同 metadata revision 可能为不同 sequence 的合法分片，按 sample span 累积，不能整包覆盖。重复 event sequence 属连接协议错误，不通过 metadata 逻辑掩盖。
- diarization done 是 session finish 屏障；已交付历史 attribution 由会话层持有，transport 只保留最近 128 个 item/30 秒窗口。过期先交付已知结果并标辅助不完整，再回收，不删除文字。
- 单 item 另限制 64 KiB UTF-8 transcript、1,024 alignment units、1,024 diarization spans，以及按固定 entry overhead 与字符串字节估算的 256 KiB 合计辅助数据；超限保留既有状态、发送 `realtime_item_state_overflow` 并关闭连接，不能静默截断终态。
- 初始流上限 256 events/4 MiB decoded audio，单帧也必须满足字节上限。超过任一上限触发一次本地 terminal、关闭 transport、停 playback、释放 waiter。关闭原因通过独立会话结束通道可观察，不能依赖满队列投递。
- 清理入口覆盖 normal close、协议错误、cancel、timeout 和新连接；已关闭 item 用固定容量 tombstone 或已知 item 存在性阻止重建，不能用无限 Set 解决无限 Map。
- codepoint range 对照 `unicodeScalars`；fixture 至少含非 BMP 字符与组合附加符，避免 UTF-16/Character 计数碰巧通过中文样例。

# 7. 测试方案

目标测试使用 fake transport/backend、合成文本/字节，不下载模型、不访问真实服务。已执行的有限检查见 §8.1；其余仍是计划，不得将计划中的命令写成已通过。

| 文件 | 增补用例及证明目标 |
|---|---|
| `SpeechRailMacControlTests/ServiceContractTests.swift` | clone/CustomVoice 不同 model revision；alias；未知 schema/status；snapshot loaded/failed/stale/304；request route/header、current-only CAS 与 idempotency；证明 pin 和发现状态唯一 |
| `SpeechRailMacControlTests/AppModelTests.swift` | 并发刷新、mutation 成功后刷新失败、409 保留草稿、clone 同 key、candidate 生命周期、试听门禁；证明不覆盖和不重复写 |
| `tests/test_voice_design_workflow.py` | machine pass 后仍需实际复核；D1 WAV/PCM hash、权限、revision、cancel、资产异常和确认/发布竞态 |
| `SpeechRailMacControlTests/RealtimeContractTests.swift` | current wire key、sequence/session/generation、Unicode span、item state、同 revision 多片、队列及 item overflow |
| `SpeechRailMacControlTests/AssistantTTSStreamCoordinatorTests.swift`、`RealtimeTTSStreamTests.swift` | stop-before-cancel、late PCM、cancel failure/timeout、一次 terminal、connection/request pin 相同 |
| `SpeechRailMacControlTests/CreativeWorkStoreTests.swift` | 离线音频读取/导出行为保持，不因服务 disabled 触发重新合成 |
| `tests/test_voice_design_workflow.py`（D1） | 资产与 validation revision/hash 一致；鉴权、404/409、旧记录缺资产、取消、路径越界、写失败；读取不启动 worker |
| `tests/test_capability_snapshot.py`、`test_speech_api.py`、`test_voice_revision_routes.py` | pin role 与服务校验一致；仅在相关服务行为/fixture改变时运行 |
| `tests/test_openapi_contract.py` | current endpoint/method/schema 与新增 D1 资源一致；D1 未实施不把拟定路径写进已支持 fixture |

本实现把 facade 和 Realtime item state 放在现有 Swift 文件中，测试沿用现有 suite 与 fake transport，没有新增 Swift target 登记。测试 helpers 不访问真实服务。UI 视觉、VoiceOver、真实音质和长稳均不由这些测试证明。

# 8. 验收标准

执行目录：仓库根。以下为已核对存在的验证入口；已执行项、局限和仍未执行项见 §8.1。UI 自动化、真实服务、音频、安装发布等仍需按项目规则单独授权。

```bash
git diff --check
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
swift test --package-path macos/SpeechRailApp --filter AppModelTests
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests
swift test --package-path macos/SpeechRailApp --filter AssistantTTSStreamCoordinatorTests
swift test --package-path macos/SpeechRailApp --filter RealtimeTTSStreamTests
uv run --extra dev pytest --no-cov tests/test_voice_design_workflow.py tests/test_openapi_contract.py
uv run --extra dev python scripts/check_realtime_contract.py
uv run --extra dev python scripts/check_openapi_contract.py
```

本次 Swift 回归沿用现有 test suites，没有增加独立 test target；UI 自动化仍不得因这些单元测试或计划文件而触发。

App 构建仅在授权后使用 `scripts/macos_app_build.sh --configuration Debug` 和 `--configuration Release`，不裸跑 xcodebuild。当前 `scripts/macos_app_test.sh` 固定整个 test plan、不透传过滤参数，不能把 `--only-testing` 当作其支持选项；未获逐次 UI 自动化授权时不要运行它。SwiftPM tests 不等于 App UI 构建或 UI 验收。

### 8.1 当前工作区的有限验证与本机核查

截至 2026-09-26，已有以下确定性证据：

| 检查 | 结果 | 证据边界 |
|---|---|---|
| SwiftPM 定向测试 | 27 项 `RealtimeContractTests`、89 项 AppModel/ServiceContract/ControlKit/RealtimeTTS/StreamingTTS XCTest、14 项 `TeleprompterSessionLifecycleTests`、14 项 `AssistantTTSStreamCoordinatorTests`、5 项 `CreativeWorkStoreTests` 全部通过。 | 使用 fake transport 与本地状态；不等于运行中的 App、真实服务或真实音频验收。SwiftPM 输出提示 23 个未纳入 package target 的 App 文件。 |
| `uv run --extra dev pytest --no-cov tests/test_voice_design_workflow.py tests/test_openapi_contract.py` | 23 项通过。 | 覆盖 VoiceDesign workflow 与 OpenAPI 子集；不是完整后端测试套件。 |
| `uv run --extra dev ruff check src/speechrail/application/voice_design.py src/speechrail/http/routes/voice_designs.py tests/test_voice_design_workflow.py` | All checks passed。 | 只检查本轮相关 Python 文件。 |
| `scripts/check_realtime_contract.py` | 41 fixtures、32 tracked fields，contract OK。 | 机械 fixture/schema 检查。 |
| `scripts/check_openapi_contract.py` | 39 paths、47 operations，contract OK。 | 机械 OpenAPI 子集检查。 |
| `scripts/macos_app_build.sh --configuration Debug` | `BUILD SUCCEEDED`。 | 仓库包装脚本构建当前 Swift 工作树；Xcode 提示多个匹配 destination，AppIntents metadata 因无 framework dependency 跳过。没有启动 App 或执行 UI 自动化。 |
| `git diff --check` | 通过。 | 检查跟踪文件的 whitespace/conflict marker；新建计划与 SDD 台账另检无 trailing whitespace，不证明语义正确。 |

Realtime 单 item 累积状态另受限制：transcript 64 KiB UTF-8、alignment/diarization 各 1,024 条、两类辅助数据合计约 256 KiB；超限显式报错并关闭连接。真实服务、App 手工操作、长会议稳定性、Release build、音质/性能仍为 `not_run`。

本机候选存量核查只针对当前源码默认的 VoiceDesign 路径：全局 `VoiceRegistry` 默认位于 `~/.speechrail/custom_voices.json`，候选 JSON 与资产目录从该路径派生。`~/.speechrail/voice_design_candidates.json` 和 `~/.speechrail/voice_design_candidates/` 在核查时均不存在；没有候选对象需要清除，未读取或修改其他 registry 数据。此为路径存在性核查，不是全盘扫描、schema/hash 审计或运行服务状态核验。

- [x] clone 与 CustomVoice 均使用匹配制品 pin；缺 pin 没有依赖请求。
- [x] 404/405/无效 schema/鉴权错误不触发 legacy capability 或 update/quality fallback。
- [x] 本地刷新不能用两个不同时刻的结果拼出执行 binding。
- [x] 同 key clone 重试不重复注册，409 不静默覆盖。
- [x] text final 后辅助信息正常到达；同 metadata revision 的分片无丢失。
- [x] sequence/epoch/request 隔离、队列双预算、item 累积上限与缓存回收有确定性证据。
- [x] D1 API、hash 校验、试听状态与发布门禁已实现并通过 contract/workflow 测试；真实服务音频与 UI 验收仍 `not_run`。
- [x] 当前默认候选存储路径核查为不存在，没有对象可清理；此项只对已核实路径成立，不代表其他用户数据已检查。
- [x] 作品重放和导出保持本地行为；监控只展示真实维度。
- [x] 测试与 Debug 构建有记录；运行态、UI、Release build、音质/性能明确标为 `not_run`。

# 9. 风险与注意事项

- **D1 范围：**纳入目标方案并已在当前工作区实现；本机不合规存量数据清除已获授权。本机目标路径不存在候选记录或资产，本次无对象清理。
- **缓存上限：**256/4 MiB/128/30 秒是本方案提出的起始边界，不是实测容量；用 fake-clock 与大事件测试证明有界。真实长会议体验另验收。
- **current-only：**旧服务不能满足 schema 时功能禁用；不删除服务仍公开的旧 endpoint。App 改用新语义不等于修改所有第三方客户端。
- **已有数据：**合规作品、音色和 validation 保留；不合规记录可精确清除，不伪造历史身份或自动推理迁移。旧 schema、缺必要资产、revision/hash 不一致、人工确认与实际试听不匹配可作为不合规依据；年代久、暂时 backend busy 或一次读取失败不能作为依据。
- **并行工作：**执行前重新检查 HEAD/status；如同文件有他人改动，先核实归属，不能按本方案整文件覆盖。
- **回退：**代码按切片回退；本轮没有清理或改动本机数据。若授权范围内的后续核查确实发现需清除对象，记录其对象和理由，不能声称代码回滚会恢复已清除的数据；不为旧 App 增加新格式兼容层。
- **本轮未做：**模型/档位变更、真实服务启停、安装发布、完整后端测试套件、UI 自动化、App 手工试听、Release build、音质/性能基准、数据库迁移和根 README 改写。用户之后明确授权在当前分支提交、推送并创建 PR；该授权不包含安装或发布。

## 当前本机存量数据核查结果

2026-09-26 只读核对了当前源码默认的 VoiceDesign 存储路径。全局 `VoiceRegistry` 默认使用 `~/.speechrail/custom_voices.json`，VoiceDesign 候选 JSON 与资产目录从该路径派生；`~/.speechrail/voice_design_candidates.json` 与 `~/.speechrail/voice_design_candidates/` 均不存在。没有候选对象需要清除，本次未执行任何删除或移动。

这只是默认目标路径的存在性核查，不代表已审计其他 registry 数据、schema、音频 hash、替代路径或运行服务状态。用户授权限当前本机、本次集成中经核实不符合目标契约的候选记录及其专属资产；不延伸到作品、其他音色、模型、配置或未确认的存储位置。若实施前源码中的 registry 路径变化，只核查新的明确目标路径，不做全盘搜索。

该授权仅限当前本机及本次集成涉及的数据，不授权远端/其他主机清理、模型下载、安装发布或 UI 自动化。

# 10. Luna 执行清单

- [x] 核对 `1116aa85` 后差异与工作区，按包含 D1 的方案定位实施范围；完成条件：证据与当前源码偏差已记录，未覆盖并行改动。
- [x] 在 `ServiceContractTests.swift` 锁定错 pin、unknown/stale 回归；完成条件：测试可识别旧 selector 缺陷。
- [x] 完成 facade、binding、store 消费与视图迁移；完成条件：只有一处解析 capability、clone pin 正确。
- [x] 在 client/AppModel 强制 CAS 和 current-only；完成条件：nil revision 不产生旧请求，409 保留草稿。
- [x] 完成 generation 刷新与 mutation 成功/刷新失败区分；完成条件：晚到结果不覆盖新状态，展示值不参与拼接 binding。
- [x] 补 clone status、candidate list/get/cancel、pronunciation list 及所有 stub；完成条件：现有 ServiceContract/AppModel 测试覆盖 route、header 与 state。
- [x] D1 服务资产契约、客户端试听与 fake 测试已完成；实际服务音频和 UI 手工验收仍为 `not_run`。
- [x] 核实当前默认 VoiceDesign 存量目标路径；目标 JSON 和资产目录不存在，无需清理。若实施前有效路径或本机数据发生变化，按授权重新核实，不扩大搜索范围。
- [x] 完成四类会话门禁与 revision 注入；完成条件：助手检查输入/输出，两类 TTS wire 使用同一 binding。
- [x] 完成 Realtime identity/sequence/分片、队列双预算和终态回收；完成条件：旧事件不生效，合法迟到辅助保留，fake 序列状态有界。
- [x] 保留并验证 stop→cancel、离线作品回放；完成条件：没有新网络依赖或旧音复活。
- [x] 更新服务呈现、监控口径、OpenAPI 和用户文档；完成条件：无 reference-only 误述、无 fake 原子性和假指标拆分。
- [x] 执行并记录授权范围内的最小检查；UI、运行态与 Release 未执行项明确为 `not_run`。用户之后明确要求提交 PR，当前任务按此授权完成提交、推送与 PR 创建；未安装或发布。
