---
title: "SpeechRail macOS App 最新公共契约对齐"
status: superseded
audience: "SpeechRail macOS App 开发者与维护者"
version: "0.1.0"
date: 2026-09-20
superseded_by: docs/superpowers/specs/2026-09-20-stateless-speech-plane-caller-orchestration-design.md
---

# SpeechRail macOS App 最新公共契约对齐

> 本草案已被 2026-09-20 的 current-only 无状态 Speech Plane 方案取代。文中 legacy fallback、旧
> Realtime wire 和“保留旧入口”的内容仅供历史追溯；当前 Native、服务端和 MCP 均以
> [无状态 Speech Plane 与调用方编排设计](2026-09-20-stateless-speech-plane-caller-orchestration-design.md)
> 为唯一依据。

## 1. 目标

将 `macos/SpeechRailApp` 从“覆盖少量 legacy REST + Realtime 子集”提升到与当前 SpeechRail 公共契约一致的控制面客户端：

1. REST 侧统一覆盖服务状态、原子能力发现、安全 Voice 目录、Voice 版本/质量/发音词表管理、语音合成响应元数据、转写、任务和现有 Voice 创建/克隆流程。
2. Realtime 侧覆盖当前 `/v1/realtime` 契约中的模型版本锁定、render receipt 协商、事件序列完整性、`commit → clear` 录音关闭栅栏和 busy 语义。
3. 将服务端的稳定错误 envelope、request ID、ETag/304、请求/响应 headers 和未知字段/枚举的兼容策略收敛到可测试的 Swift 契约层。
4. 让 UI 使用原子 `effective_capabilities_v1` 和安全 Voice 视图作为发现真相；编辑器或明确的管理操作才读取详细 Voice 数据。

本规格只定义 App 对现有公共契约的适配，不改变服务端路由、字段语义、模型加载方式或运行态部署。

## 2. 事实来源与边界

截至 2026-09-20，事实来源按项目约定排序：当前代码与测试、`contracts/`、标记为 active 的 `docs/`，最后才是归档材料。当前仓库 `contracts/openapi.yaml` 版本为 `2.7.0`；Realtime 行为以 `contracts/realtime-openai.md` 为准。

当前服务端代码已经存在以下公共入口：

- 状态与基础发现：`/health`、`/readyz`、`/metrics`、`/v1/models`、`/v1/voices`。
- 原子发现：`/v1/speechrail/capabilities`、`/v1/speechrail/voices`、`/v1/speechrail/voices/{voice_id}`。
- 音频：`/v1/audio/transcriptions`、`/v1/audio/speech`、preview、receipt、timing。
- Voice 管理：design、clone、revision/CAS、rollback、revoke、pronunciation set、quality run，以及现有兼容 alias。
- 任务：`/v1/jobs` 及其查询、删除、结果入口。
- Realtime：唯一 WebSocket `/v1/realtime`。

OpenAPI、active 文档和服务端实现目前仍有少量路径/字段演进差异，例如 quality-run 同时存在 namespaced 与 legacy alias、Voice 安全列表的原因枚举比 OpenAPI 更丰富、健康响应已有运行时 revision 语义而 App 尚未建模。实施时不能以旧 App 的 DTO 反推服务端契约；应以服务端当前实现和契约联合核对，并对未知字段和未知枚举做前向兼容。

本工作区已有以下并行未提交改动：`README.md`、`README.zh-CN.md`、若干 `docs/` 文件，以及 `AssistantView.swift`、`DeveloperDocsContent.swift`、`SessionDesignSurface.swift`。它们不属于本规格提交，后续实施必须逐处核对后再合并，禁止整文件覆盖。

## 3. 范围

### 3.1 REST 客户端契约

建立一套可复用的、与 UI 解耦的 contract/transport 层，覆盖：

- `HealthResponse`、`ReadyResponse`、`Model`、`ModelCapabilities`、`RuntimeMetrics`；
- `EffectiveCapabilitySnapshot`、`ConfiguredModelIdentity`、`SafeVoiceList`、`SafeVoiceEntry`、`SafeVoiceDescriptor`；
- 详细 Voice、Voice revision、quality report/run、pronunciation set、clone/design/preview；
- `SpeechRequest`、`RenderReceipt`、`TtsTimingResource`、转写请求/结果；
- `JobCreateRequest`、`Job`、`JobList`；
- 稳定错误 envelope 与通用请求元数据。

客户端必须保留服务端的字段语义：`service_instance_epoch`、`catalog_revision`、`snapshot_id`、`voice_revision`、`runtime_revision`、`availability_reason`、`assurance` 和 `operations` 不得被压缩成单个布尔值或由 UI 自行推断。

### 3.2 Realtime 客户端契约

`RealtimeASRClient` 及其会话使用方覆盖：

- Bearer 鉴权、`model` query、ASR/TTS alias；
- `session.update` 中的 VAD、languages、prompt、keywords、timestamp granularity、known speakers；
- `session.speechrail.model_revision.expected`；
- `session.speechrail.render_receipts.enabled`；
- 所有服务端事件的 `event_id`、`session_id`、单调 `sequence`；
- ASR audio buffer 生命周期的 `append`、`commit`、等待已提交 item 完成、`clear`、关闭；
- response audio 的 legacy/nested 兼容形状、`response.done` 中的 receipt；
- `speechrail.busy_reason`、`retryable`、`retry_hint`。

### 3.3 UI 与 AppModel

- AppModel 的服务发现主状态改为原子 capability snapshot + safe Voice catalog。
- 保留旧 `serviceCapabilities` 和 `/v1/models` 映射，作为 legacy/独立模型展示的兼容视图；不能用多个非原子 GET 拼出伪 snapshot。
- Voice 选择、实时会话和 Creator 相关 UI 读取安全字段；只有明确的编辑/管理页面才请求详细 Voice 或 revision 数据。
- 现有 control-plane 约束不变：App 不加载模型、不直接执行 `launchctl`，音频只存在于会话生命周期，PCM 不落盘。

## 4. 非目标

- 不修改 Python 服务、OpenAPI、Realtime 文档或服务端路由；若实施中发现契约文件确实落后于当前实现，另起契约同步变更，不在 App 对齐提交中静默改写。
- 不新增服务端能力，不下载、加载、卸载模型，不改变 active profile 或 LaunchAgent。
- 不把 jobs、receipt、timing 或质量报告自动扩展成新的产品页面；本阶段先提供可靠的类型化 transport 和现有 UI 所需的状态。
- 不把 reference text、instruction、文件路径、完整质量原始数据、PCM、Base64、Authorization 或 API key 放入日志、App 持久化或 UI 安全目录。
- 不为旧 macOS 增加兼容 UI；遵守项目的 macOS 26.0+ App 基线。
- 不运行未经当前用户逐次授权的 UI 自动化测试、XCUITest、录屏或窗口接管。

## 5. 设计

### 5.1 分层

采用四层边界：

1. **Contract types**：纯 Codable/值类型，只表达公共契约，不依赖 SwiftUI、URLSession 或 AppModel。
2. **HTTP/WebSocket transport**：负责 URL、headers、状态码、ETag、鉴权、解码、稳定错误和响应元数据；不决定 UI 文案或业务 fallback。
3. **Application services**：负责 discovery snapshot 缓存、Voice 管理、receipt/timing 查询、Realtime 会话状态和并发取消。
4. **AppModel/UI**：只消费稳定的 view model 和显式状态，不直接拼接协议字段，不从名称/版本字符串推断能力。

`ServiceAPIClient` 可以继续作为组合入口，但需要将“请求构造”“响应元数据”“契约解码”拆成可单测的组件。现有 `ServiceDiagnosticsClient`、`ServiceModelCapabilityClient`、`SpeechRailCreatorClient`、Realtime session 抽象应保留兼容入口，避免一次性破坏现有 fake transport 和 UI 构造器。

### 5.2 通用 HTTP 语义

每个请求返回或内部携带以下信息：HTTP status、headers、解码后的 body、request ID、ETag、服务端错误 code/message/retryable。非 2xx 统一解码稳定 error envelope；无法解码时保留 status 和最小安全摘要。

- 自动附带 Bearer 鉴权，但从不把 token 写入 URL、日志或错误文本。
- 对支持缓存的 discovery 资源发送 `If-None-Match`；收到 `304` 时仅在本地存在同一资源的有效缓存时复用，否则返回明确的 cache-miss/contract error。
- 记录并向上层传递 `ETag`、`SpeechRail-Receipt-Id`、`SpeechRail-Timing-Id`、request ID 等非敏感 headers。
- `Content-Type` 由服务端响应决定；不能把所有音频响应强制当成 `audio/wav`。当前 UI 的 WAV 播放行为只在实际 MIME 与解码器允许时启用。
- 未知 JSON 字段忽略；未知 enum 解码为 `.unknown(rawValue:)` 或等价的非致命值；缺少契约要求的关键字段时返回结构化 `invalidContract`，不以默认值掩盖。

### 5.3 原子能力发现与缓存

`/v1/speechrail/capabilities` 是跨对象发现的唯一主入口。AppModel 保存完整 snapshot 及其 `service_instance_epoch`、`catalog_revision`、`snapshot_id`、ETag 和加载时间，并把 `/v1/speechrail/voices` 视为安全展示/筛选目录，而不是再次拼接 capability snapshot 的来源。

状态至少区分：`idle`、`loading`、`loaded`、`notSupported`、`notReady`、`unauthorized`、`invalidContract`、`failed`。其中：

- 旧服务返回 404/405 或明确不识别新 discovery schema 时，可保留 `/v1/models` 的 legacy capability 展示，并将原子 snapshot 标为 unavailable；不得通过分别读取多个旧 endpoint 伪造原子一致性。
- 401/403、存储错误、服务端明确错误或 revision conflict 不得静默降级成 legacy 成功。
- 新 snapshot 到达前继续展示上一个完整 snapshot，并标记刷新状态；不能用半更新的 models/voices 组合覆盖旧快照。
- snapshot 的 `available` 只表示契约层可用性，不等于 warm、质量通过或当前请求一定成功。

Safe Voice catalog 只消费安全字段：id、name、aliases、mode、available、availability reason、variant、revision、assurance、model、descriptors、operations、受控 quality summary、snapshot ID。reference text、instruction、路径和完整质量细节必须留在 detail/editor 边界。

### 5.4 Speech、receipt、timing 与转写

`POST /v1/audio/speech` 的请求 builder 支持当前契约的 `voice` string 或 `{id}`、model、input、response format、language、instructions、stream format，以及以下可选 `SpeechRail-*` headers：

- `SpeechRail-Expected-Voice-Revision`
- `SpeechRail-Expected-Model-Revision`
- `SpeechRail-Pronunciation-Set`
- `SpeechRail-Receipt-Mode`
- `SpeechRail-Timing-Mode`
- `SpeechRail-Purpose`
- `SpeechRail-Latency-Budget-Ms`

响应统一解析音频 body 和 receipt/timing response headers。Receipt/timing ID 存在时，应用服务层提供显式查询入口，不把异步 pending 当成 completed，也不把 `available=false` 当作失败。`POST /v1/audio/transcriptions` 使用 multipart builder，并在 API 边界保留 timestamps/diarized/languages 等字段。

### 5.5 Voice 管理与版本语义

保留现有 design、clone、preview 流程，同时补齐：

- `POST /v1/voices` 与现有 `/v1/voices/designs` 的区别；
- detail 中的 `revision`、`revoked`、quality、creation、availability reason；
- revision 列表、CAS update、rollback、revoke；
- pronunciation set 的 revision、revoke、delete；
- namespaced quality-run 与 legacy quality-run alias 的同一 typed operation。

Voice 更新请求必须显式携带 expected revision（若契约要求），遇到 conflict 返回可区分的 revision conflict，不能用本地旧对象覆盖服务端新版本。质量报告只在字段齐全且状态允许时展示“通过”；缺少实测数据时显示 unknown/pending，不由客户端推断质量。

### 5.6 Realtime 会话与录音关闭

Realtime 事件先解码公共 envelope，再路由到 ASR、TTS、diarization 或错误事件。保存每个会话的 `session_id`、最近 `sequence`、event IDs 和 integrity 状态；出现回退、跳号或 session 不一致时记录非敏感诊断并让上层决定是否结束会话，不静默重排事件。

逻辑录音关闭流程固定为：

1. 停止采集并停止继续 append；
2. 发送 `input_audio_buffer.commit`；
3. 等待所有已提交 item 完成或进入明确错误状态；
4. 发送 `input_audio_buffer.clear`；
5. 在完成必要的 receipt/timing 收集后关闭 WebSocket。

`clear` 本身不是成功 receipt。若某一步超时，向上层报告具体阶段（commit、item completion、clear 或 close），不把连接关闭伪装为服务端已完成。

`session.update` 仅发送用户/功能实际启用的选项；model revision 和 render receipt 是显式 capability negotiation。服务端返回 legacy/nested response audio 时都能解码，`response.done` 中的 receipt 进入同一 receipt 状态流。

## 6. 失败、鉴权与隐私

- 错误模型至少保留 `code`、`message`、`retryable`、`request_id`、HTTP status；Realtime busy 还保留 `busy_reason`、`retry_hint`。
- `backend_not_ready`、`backend_busy`、`model_revision_mismatch`、`voice_revision_mismatch`、`voice_revoked`、`invalid_request`、`unauthorized` 等状态必须可供 UI/会话层区分。
- 只对契约明确可重试且 `retryable=true` 的操作执行有限重试；mutation 默认不自动重放，除非有明确 idempotency key。
- `Idempotency-Key` 只用于契约定义的 design/clone/相关 mutation；不自行扩展语义。
- 日志只记录 endpoint 类别、status、request ID、稳定 error code 和脱敏的 revision/snapshot 标识；不记录 token、完整 prompt、完整转写、音频、Base64、实名 speaker、路径或完整用户输入。

## 7. 兼容与迁移

1. `/v1/models`、legacy `/v1/voices`、legacy quality-run 路径和现有 Creator 协议继续保留，作为兼容/管理入口，不删除当前 UI 依赖。
2. 新增字段以 additive decode 为主；未知字段/枚举不能导致整页失败，关键字段缺失才进入 `invalidContract`。
3. 新发现接口不可用时只降级“发现视图”，不降级鉴权、revision CAS、mutation 错误，也不把 detail 多次读取伪造成 atomic snapshot。
4. Realtime 的旧事件形状继续支持，但新事件统一填充公共 envelope；旧服务没有 sequence 时显示 integrity unknown，不伪造连续序号。
5. Creator fake/client protocol 采用兼容扩展：新能力以新的 service/application 接口或有默认实现的方法加入，现有 `UITestCreatorClient` 不因未实现新 endpoint 而失去编译能力。
6. 迁移期间旧 UI 若只需要名称列表，可以消费 safe catalog；需要 instruction/reference 或编辑字段时显式进入 detail 请求。

## 8. 测试策略

实施阶段先写失败的契约/回归测试，再实现：

- Codable fixture：完整 effective snapshot、safe Voice list、health/ready、receipt/timing、quality/revision、job、稳定 error envelope，以及未知字段/枚举。
- Request builder：路径、query、JSON、multipart、Bearer、Idempotency-Key、`SpeechRail-*` headers 和不泄露 secret 的日志摘要。
- HTTP transport：200、304 cache hit/cache miss、401/403、409 revision conflict、422、429、503、非 JSON 错误、MIME/response headers。
- AppModel/discovery：原子 snapshot 替换、旧快照保留、legacy fallback 边界、ETag、取消和并发刷新。
- Realtime：公共 envelope、sequence 回退/跳号、legacy/nested audio、receipt、busy error，以及 `commit → completion → clear` 顺序和超时阶段。
- 现有服务 readiness/Creator fake 适配测试。

本阶段不自动运行 UI automation；是否运行 Swift package tests、Xcode build、完整 Python gate 或公共 smoke，需要后续由用户明确授权并按项目规则执行。每次实施完成时单独报告已运行和未运行的验证。

## 9. 预期文件边界

具体文件由后续实施计划确认，预计包括：

- `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift` 及新的 contract/transport 类型文件；
- `CreatorServiceClient.swift`、`RealtimeASRClient.swift`、`ServiceDiagnosticsTypes.swift`；
- `AppModel.swift`、`App.swift` 与三类 session 的 discovery/realtime 接线；
- `Package.swift` 和对应纯 Swift 测试 target（若需要把协议 codec 纳入可测试模块）；
- 不自动覆盖当前已有并行改动的文档和 SwiftUI 文件。

实施会按可回退的小提交拆分：先纯类型/transport，再 discovery/AppModel，再 Creator/receipt/jobs，最后 Realtime/session 栅栏。每个阶段保持旧入口可用，避免在一次提交中同时改变网络语义和 UI 状态机。

## 10. 回退与风险

- 主要风险是服务端实现、OpenAPI 和 active 文档的演进不同步。处理方式是保留未知值、显式 contract error、记录 request ID，并以当前服务端代码/测试为运行事实；不通过宽松默认值掩盖差异。
- 主要兼容风险是旧 runtime 不认识新 discovery 或 Realtime 扩展。处理方式是 capability-gated negotiation 和仅限发现视图的 legacy fallback。
- 主要状态风险是 receipt/timing/Realtime 事件异步到达顺序变化。处理方式是 typed pending/completed/error 状态、sequence integrity 和明确的关闭栅栏。
- 回退时可按提交边界恢复到旧客户端；不需要删除服务端数据、模型或用户 Voice。任何运行态回退必须另按发布/运维流程执行，不在 App 代码改动中自动触发。

## 11. 验收标准

实施完成后必须满足：

1. App 能解码并展示当前有效的 `effective_capabilities_v1` 与 safe Voice catalog，并保留 snapshot/ETag/revision 语义。
2. App 能正确处理 200/304、稳定 error envelope、request ID、鉴权错误、backend busy/not ready、revision conflict 和未知字段/枚举。
3. `/v1/audio/speech` 可按契约发送可选 headers，并解析音频 MIME、receipt/timing headers；不会把所有响应硬编码为 WAV。
4. Voice detail、revision、quality、pronunciation、design/clone/preview、transcription、jobs 的 transport DTO 与实际服务端 schema 对齐，且兼容现有 alias。
5. Realtime 能协商 model revision/render receipts，验证公共事件元数据，支持 receipt 和 busy 语义，并严格执行 `commit → completion → clear`。
6. 现有 legacy capability、Creator fake、服务状态 UI 和不依赖新 endpoint 的会话保持可编译、可运行的兼容行为。
7. 不新增 PCM/secret/完整文本持久化，不改变 App 作为 control plane 的边界。
8. 完成后有新鲜、可复现的构建/测试证据；未授权的 UI automation 和未运行的验收项明确列出，不以计划或退出码代替证据。
