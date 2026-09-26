---
title: "SpeechRail macOS App 接入最新服务与 VoiceDesign 职责收口"
status: reviewed
audience: "SpeechRail macOS App 设计、开发、评审与验收人员"
version: "1.4"
date: 2026-09-26
baseline: "main@1116aa85 (实现基线 ee170d08)"
---

# SpeechRail macOS App 接入最新服务与 VoiceDesign 职责收口

## 1. 结论摘要

Issue 95 服务分支已经包含大量 App 接线，当前问题不是“App 还没有接新服务”，而是部分页面、会话和客户端仍保留旧能力语义或旧 endpoint 回退，导致同一个服务事实存在两套解释。本轮采用分层 current-only 收口，保留现有导航、页面组织和会话引擎，不重写 App。

核心决策：

- App 生产路径只以 `GET /v1/speechrail/capabilities` 返回的 `effective_capabilities_v1` 为能力、操作参数、可用性和 revision pin 的事实源。
- `/v1/models` 只用于模型与别名发现，不再作为 App 能力门禁来源。
- `/v1/voices` 继续作为展示和编辑所需的 rich 音色资源；`/v1/speechrail/voices` 用于安全 availability、operation 和 revision。
- VoiceDesign 只用于音色创作作业：候选生成、设计期试听、Base 复验和发布。普通 HTTP TTS、Realtime TTS、音色库试听、配音台和作品重放均不得依赖 VoiceDesign。
- 已有音色修改与版本变更统一使用 CAS，clone 注册使用幂等键；成功后刷新 rich voice list、effective snapshot 和 safe voice projection。
- Realtime 会话按具体 operation 门禁；`/readyz` 只能说明进程通常可用，不能替代 `realtime_speech` 或 `realtime_transcription` 的能力判定。
- 删除 App 生产路径中的 legacy capability fallback、旧 voice update fallback 和旧 quality-runs fallback。
- 修复 Realtime 的 epoch/revision 隔离、有界事件流与独立辅助终态回收；保留并回归验证现有停播后取消顺序。

本文定义目标行为及其审查基线；后续分阶段实施状态、验证证据和未验收范围见配套 [Luna 实施方案](../plans/2026-09-26-app-service-integration-luna-guide.md)。当前工作区已有跨端实现和有限确定性验证，但这不代表真实服务、真实音频、UI 或发布验收完成。2026-09-26 用户补充授权：限当前本机，本次集成中不符合目标契约的存量数据可清除；无需为这些数据保留兼容层或迁移路径。§7.5 的候选试听契约纳入目标方案，不再作为待确认项；授权边界和本机核查结果见 §18。

## 2. 目标、成功标准与非目标

### 2.1 目标

1. 让 App 对服务能力只有一个可验证、可缓存、可测试的解释入口。
2. 把 VoiceDesign 从普通 TTS 能力中移出，恢复到“音色创作期间的候选生成器”职责。
3. 让音色修改、注册、发布和删除后的有效能力、revision 与 UI 状态同步收敛。
4. 让助手、会议、字幕和提词器在启动前按实际 Realtime operation 判断可用性，并丢弃跨 epoch、跨 utterance、旧 revision 的事件。
5. 补齐 App 对当前服务 API 的必要覆盖，移除旧 endpoint 与旧字段回退。
6. 让服务状态、运行监控、开发者文档中的呈现与真实职责一致。

### 2.2 成功标准

- 在 App 中搜索 capability 门禁时，不再出现 `/v1/models.capabilities`、`supportsInstruction` 或 `supportsPreview` 作为生产判定。
- 当 effective snapshot 缺失、无效或读取失败时，需要能力的入口显示“未知/不可确认”，不会猜测可用，也不会静默读取旧 endpoint。
- VoiceDesign 相关调用只能从音色创作页或创作流程内部发起；普通音色试听和重新生成走 `/v1/audio/speech`，已有作品重放与导出读取已保存音频。
- 音色 update 永远携带 `expected_revision`；revision 缺失时先刷新，不会悄悄调用旧 `/v1/voices/{id}` PATCH。
- Realtime 收到旧 epoch、旧 transcript revision、旧 metadata revision 或不匹配 utterance 的对齐/分人事件时直接丢弃。
- `RealtimeASRClient.events()` 为有界缓冲；终态后不保留已完成 item 的 alignment/diarization 缓存。
- 运行监控能分别展示 `/v1/audio/speech` 与 `/v1/voices/previews` 的请求计数；无法按来源拆分的音频秒数明确标注为 TTS lane 总量，不制造假拆分。

### 2.3 非目标

- 不重写 App 导航、页面结构、视觉语言或会话状态机。
- 不把 LLM、录音、播放、会议编排或业务数据库职责搬进 SpeechRail。
- 不在本设计阶段改模型、profile、运行服务、安装 App 或执行 UI 自动化。
- 不为旧 App 字段、旧 capability endpoint 或远档位兼容保留长期过渡层。
- 不实现跨 App 重启恢复音色创作草稿的首期主路径。

## 3. 基线与证据

核实日期：2026-09-26（Asia/Shanghai）。

静态审查基线为 `main@1116aa85`；其父提交 `ee170d08` 是实现基线，审查开始时工作区干净、main 领先 origin/main 一个提交。该基线描述最初审查时的代码，不代表当前工作区；本表是当时的源码、契约和文档证据，不以历史 PR 说明替代源码证据。后续实施状态见配套 Luna 方案。

| 证据 | 当前事实 | 对本设计的意义 |
|---|---|---|
| `macos/SpeechRailApp/SpeechRailApp/AppModel.swift` | 同时保存 `effectiveCapabilities` 与 legacy `serviceCapabilities`，并在 snapshot 不支持时回退 `/v1/models`。 | 必须移除双事实源，由 capability facade 统一解释。 |
| `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift` | 音色创作门禁读取 `supportsInstruction` 与 `supportsPreview`。 | VoiceDesign 门禁必须改读 `voice_preview`/创作 operation，而不是普通 TTS 声明。 |
| `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift` | 能力矩阵仍读 legacy 投影，并把语音设计放成 TTS 能力行。 | 服务状态需改为“音色创作（按需）”或仅在开发者详情中呈现。 |
| `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift` | update voice 在缺少 revision 时回退旧 endpoint；quality-runs 在 404/405 时回退旧路径。 | 生产路径必须 current-only。 |
| `macos/SpeechRailApp/SpeechRailApp/App.swift` | 助手、字幕、提词器、会议的 readiness 只检查 `/readyz`。 | 会话启动前需增加 operation 级门禁。 |
| `macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift` | event stream 无界；alignment/diarization 缓存未按终态清理；解码未校验 epoch/revision。 | 必须增加有界缓冲、版本校验和终态回收。 |
| `contracts/realtime-openai.md` | 明确要求丢弃旧 epoch、旧 revision 与不完整降级回包。 | App 当前实现未完全覆盖契约，属于确认的接线缺口。 |
| `contracts/openapi.yaml` | VoiceDesign 描述仍写 active selection “currently the reference spec”。 | 与“任何 TTS spec 都可按需进入设计作业”的当前定位冲突，需要跨端契约清理。 |
| `docs/users/effective-capabilities.md` | 已声明 VoiceDesign 只在 `voice_design` 作业中运行，且与档位无关。 | 作为 App 唯一能力事实源的服务端文档依据。 |
| `src/speechrail/http/routes/audio.py`、`application/realtime_openai.py` | 按选中音色的 runtime role / mode 选择制品后校验 model revision。 | pin 应取 `snapshot.voices[匹配音色].model.catalog_revision`；不能固定为 `models.tts`。 |
| `CreatorServiceClient.swift`、`AppModel.saveDesignedVoice` | 已有 revision、publishable、validation DTO 与 create→confirm→validate→publish；人工布尔值在 machine validation 前传入。 | 增补生命周期和实际试听绑定，不能误称整个 DTO/发布流程缺失。 |
| `AssistantTTSStreamCoordinator.cancel`、`AssistantSession` | 已先停本地播放再 cancel。 | 保留实现，验证迟到音频和失败路径，不重复重写。 |
| `CreativeWorkStore.swift` | 作品保存音频文件，提供读取/导出路径。 | 重放与导出不依赖服务、当前音色 revision 或模型 readiness。 |

本表是当前代码和文档的静态审计结果，不代表 App 已执行真实服务、真实音频或 UI 验收。

## 4. App 功能覆盖矩阵

| App 功能 | 当前主要服务面 | 本轮目标 |
|---|---|---|
| 语音助手 | `/v1/realtime`，`realtime_transcription` + caller-owned `realtime_speech` | 同时检查输入转写和输出合成；固定对应 revision；保持 24 kHz mono PCM16 wire。 |
| 会议助手 | `/v1/realtime`，`realtime_transcription`，可选 alignment/diarization | 启动前按 `realtime_transcription` 判断；按 epoch/revision 隔离辅助事件。 |
| 字幕带 | `/v1/realtime`，`realtime_transcription`，alignment/diarization | 同会议门禁；hypothesis 快照与 append-only delta 分开；终止后释放缓存。 |
| 提词器 | `/v1/realtime`，`realtime_transcription` | 同会议门禁；不依赖 `/readyz` 推断会话语义可用。 |
| 音色创作 | `/v1/voice-designs`，`/v1/voices/previews`，`voice_preview` | VoiceDesign 仅在此流程出现；候选生命周期、取消和发布状态完整。 |
| 音色库 | `/v1/voices`，`/v1/speechrail/voices`，`/v1/audio/speech` | rich list 用于展示；safe projection 用于可用性；普通试听只走 HTTP speech。 |
| 音色修改 | `/v1/speechrail/voices/{voice_id}` | 强制 CAS；成功后刷新三类快照。 |
| 音色克隆 | `/v1/voices/clone/*`，`/v1/speechrail/voices/clone/idempotency` | 增加 idempotency 接线，保证超时重试安全。 |
| 配音台 | `/v1/audio/speech` | 仅使用已发布 Base clone/CustomVoice，不使用 VoiceDesign runtime voice。 |
| 作品重放与导出 | `CreativeWorkStore` 已保存音频 | 离线重放/导出；只有用户明确重新生成才调用 HTTP speech，不自动覆盖作品。 |
| 服务状态 | `/health`，`/v1/speechrail/capabilities`，`/v1/speechrail/voices` | 能力只读 effective snapshot；VoiceDesign 单列为按需创作，不混入普通 TTS。 |
| 模型管理 | `/v1/models`，`/v1/speechrail/capabilities` | `/v1/models` 只做模型/别名发现；加载与可用性读 snapshot 和 readiness。 |
| 运行监控 | `/metrics` | 拆分明细请求计数；音频秒数仅在 endpoint 维度可用时拆分，否则明确合并口径。 |
| 诊断与开发者文档 | `/health`，capability snapshot，OpenAPI | 移除 VoiceDesign 普通 TTS 语义和 legacy capability 文案。 |

## 5. 目标架构

```text
GET /v1/speechrail/capabilities
        │
        ▼
CapabilitySnapshotStore  ── ETag / generation / request token
        │
        ▼
AppCapabilityFacade
  ├─ availability
  ├─ supported operations
  └─ revision pins
        │
        ├──────────────► Views: visibility, disabled state, user copy
        ├──────────────► AppModel: speech requests and mutation refresh
        └──────────────► Sessions: preflight gate and expected revisions

/v1/models              ─────► model and alias discovery only
/v1/voices              ─────► rich voice display/edit resource
/v1/speechrail/voices   ─────► safe availability/operations/revisions
/v1/audio/speech        ─────► normal HTTP synthesis
/v1/voices/previews     ─────► VoiceDesign creation audition only
/v1/realtime            ─────► operation-gated ASR/TTS wire
```

### 5.1 `AppCapabilityFacade`

新增一个纯 App 能力 facade，最好是可独立测试的 value type；它只消费不可变的有效快照和 discovery state，不负责网络请求，也不持有 UI 文案状态。

建议接口：

```swift
struct AppCapabilityFacade {
    func voiceCreationAvailability() -> CapabilityAvailability
    func httpSpeechAvailability(voiceID: String) -> CapabilityAvailability
    func realtimeAvailability(operation: RealtimeOperation, voiceID: String?) -> CapabilityAvailability
    func voiceRevisionPin(voiceID: String, operation: String) -> String?
    func modelRevisionPin(operation: String, voiceID: String?) -> String?
    func supportedOperation(_ operation: String) -> Bool
}
```

约束：

- `CapabilityAvailability` 至少区分 `available`、`unavailable(reason)`、`unsupported`、`unknown`、`checking`、`failed(reason)`，不能压成单个 Bool；discovery 状态继续复用 `CapabilityDiscoveryState`。
- `voiceRevisionPin` 和 `modelRevisionPin` 只在对应 voice、model 和 operation 都可证明可用时返回非空值。
- facade 是 `JSONValue` 操作对象的唯一解析点；视图和会话不直接遍历 capability JSON。
- `voice_preview.status=supported` 只证明临时生成能力；耐久创建还依赖 batch transcription，Base 复验依赖 clone 制品。保存动作须分别检查这些依赖，不能把 preview supported 映射成整个发布工作流可用。
- capability snapshot 的请求代次、ETag 和 304 处理继续由 `CapabilitySnapshotStore` 负责。
- `/v1/speechrail/voices` 的安全投影可用于窗口内原子展示，但不能与另一时刻的 capability snapshot 拼成一个假原子状态。
- `voice_preview`、`realtime_transcription` 是顶层 `operations` 的带 status 条目；`http_speech`、`realtime_speech` 是逐音色操作对象，没有统一的顶层 status。分别解析，不要求所有操作都存在 `.status == supported`。
- 合成 binding 从一次 snapshot 的匹配 voice（含 alias）同时提取 voice revision、该 voice 的 `model.catalog_revision` 与对应参数域。`models.tts_clone` 与 `models.tts` 可不同；顶层 `catalog_revision`、`snapshot_id`、`runtime_revision` 都不能代替 model pin。

### 5.2 客户端边界

- `ServiceAPIClient` 只实现当前服务 HTTP 契约，不保留 legacy 路由 fallback。
- `CreatorServiceClient` 只表达创作域动作，并把能力 fail-closed 结果交给 UI。
- `AppModel` 负责组合 discovery、voice catalog、mutation refresh 和会话门禁，不自己解释 `supportsInstruction` / `supportsPreview`。
- Realtime 客户端负责 wire 解析、版本隔离和连接内状态；会话层负责用户可见状态和任务语义。

## 6. 唯一能力事实源

### 6.1 事实源职责

| 来源 | 允许用途 | 禁止用途 |
|---|---|---|
| `GET /v1/speechrail/capabilities` | 操作是否 supported、参数范围、availability、voice/model revision、profile/selection 摘要 | 获取 rich voice 正文或编辑字段。 |
| `/v1/models` | 模型 ID、别名、基础模型发现 | 判定某个 operation 或 voice 是否可用。 |
| `/v1/voices` | 音色名称、描述、instruction、参考正文、编辑状态 | 作为全局能力门禁或安全可用性唯一来源。 |
| `/v1/speechrail/voices` | 安全 availability、operations、revision、最小披露窗口 | 替代 rich voice 编辑资源。 |

### 6.2 current-only 规则

1. App 启动、页面进入和 mutation 后刷新能力时，只请求 effective capabilities。
2. 404、405、schema 不识别、鉴权失败、未就绪和网络失败都是显式状态，不得回退 `/v1/models`。
3. snapshot 不可确认时，任何需要该 operation 的启动动作 fail-closed。
4. `/v1/speechrail/voices` 与 effective snapshot 不一致时，重新刷新；不能从 rich list 或用户现有音色反推服务能力。
5. 依赖 capability 的 UI 文案只区分“可用、未知/检查中、当前不支持、读取失败”，不把未知说成不支持。
6. revision pin 缺失时，需要固定身份的调用先刷新 snapshot；刷新后仍缺失则拒绝发送依赖性请求。

### 6.3 刷新和竞态

- 所有 discovery 请求继续带 generation 或 request token，旧请求不得覆盖新快照。
- mutation 成功后统一 `refreshCapabilitySet()`：
  - rich voice list；
  - `/v1/speechrail/capabilities`；
  - `/v1/speechrail/voices`。
- 三类刷新可以并行获取，以一个本地 generation 提交 UI 更新；这不构成服务端事务。所有门禁和 pin 只取一次 effective snapshot。safe list 的 `snapshot_id` 不一致时标为待刷新，不与 snapshot 拼接；rich list 无共同版本屏障，只提供展示数据，不能宣称三份 GET 严格原子。
- 保存端点、凭据或 service instance 变化时清空对应缓存与 ETag，推进 generation；失败后保留旧显示值只能标 stale，不能继续准入新请求。
- 304 只复用响应值，不跳过 mutation 后的 generation 校验。

## 7. VoiceDesign 定位与创作生命周期

### 7.1 定位

VoiceDesign 是音色创作期的候选生成器，不是普通 TTS 路由，也不是稳定对话角色的每轮生成器。它只处理 `voice_design` 作业，最终发布出去的是一个耐久 Base clone；发布后该音色作为普通已发布音色使用。

用户可以继续看到“音色创作”或“创作音色”，生产 UI 不暴露 `VoiceDesign` 制品名。服务状态、模型管理、监控和开发者详情可以显示内部名，但必须清楚标记为按需创作能力。

### 7.2 允许与禁止

| 场景 | 允许的接口/路径 | 明确禁止 |
|---|---|---|
| 音色创作候选生成 | `/v1/voices/previews` | 以普通 TTS request 伪装候选生成。 |
| 音色创作候选保存 | `/v1/voice-designs` 创建、确认、验证、发布 | 直接把临时 preview 注册成普通 voice。 |
| 临时设计期试听 | `/v1/voices/previews`，只在创作流程内 | 把临时 preview 的试听确认转用为耐久候选的人工验证。 |
| 保存前 Base 复验 | VoiceDesign candidate validate，使用不同测试文本 | 用同一参考文本复验后宣称发布候选已通过。 |
| 已发布音色试听 | `/v1/audio/speech` | 用 `/v1/voices/previews` 播放已发布音色。 |
| 配音台 | `/v1/audio/speech` | VoiceDesign instruction 作为运行时 voice。 |
| 作品重放/导出 | 已保存音频；重新生成才用 `/v1/audio/speech` | 依赖临时 runtime ID，或静默重新合成已有作品。 |
| Realtime TTS | `/v1/realtime` 的 `realtime_speech` | 在没有已发布 Base/CustomVoice binding 时使用 VoiceDesign。 |

### 7.3 候选生命周期

1. 创作页生成 4 个临时候选，使用固定 slot 1–4 与 seed 101/202/303/404。
2. 每个临时候选调用 `/v1/voices/previews`，结果只在内存保存；取消、失败或离开创作页后清理。
3. 用户选定候选并填写名称后，App 用 instruction、reference text、seed 创建耐久 candidate。当前 create 契约无 speed；本轮可发布候选的临时预览固定 speed=1.0，不发送未知字段。相同 seed 不证明两次生成的音频相同。
4. 耐久 candidate 必须 acquire 明确的 candidate ID、revision 和服务端状态；列表、详情和取消通过 `/v1/voice-designs` 的 list/get/cancel 覆盖。
5. 保存流程必须用与参考文本不同的 Base 测试文本执行 machine validation。请求省略/null `test_text` 是合法行为，服务会替换受控文本；不得把“请求省略”误判成“有效测试文本为空”。客户端显式提供文本时执行边界检查，服务端负责最终校验。
6. 人工身份与自然度复核必须在用户听过当前耐久候选及该 validation 的 Base 输出后提交，并绑定 machine validation ID、candidate revision 和 capability key。revision/validation 改变即清除旧确认。读取资源和身份校验见 §7.5；只有实际听过当前音频后才开放人工复核，禁止沿用保存前的勾选自动生成新 validation 的 pass。
7. publish 必须携带当前 `expected_candidate_revision`。成功后刷新 rich voice list、effective snapshot 和 safe voices。
8. 当前 App 会话内的用户取消或退出会取消已知且未发布的 candidate；瞬时失败保留当前 candidate ID 供重试。取消响应丢失不等于服务取消成功，必须 GET 核实；publish 结果未知先 GET，已 published 不再 cancel。create 超时使用同一 key/payload 恢复结果，禁止盲目新建。跨 App 重启恢复不作为首期 UI 主路径。

### 7.5 实际试听证据与 D1 契约

在审查基线 `main@1116aa85` 静态核实：`voice_designs.py` 返回安全 candidate/validation 投影；reference WAV 已由 repository 管理，Base validation 仅记录 `output_audio_sha256`，没有提供 App 读取其音频的路由。基线中的 previews 会重新生成，因此不能补足人工复核证据。当前工作区已实现下述 D1 资源，并在 repository、OpenAPI、Swift client、创作流程与确定性测试中接入；这不替代真实服务上的音频试听和 UI 验收。

追加最小只读候选 reference/validation WAV 资源，并让机器验证保存对应的有界输出资产；资产与 candidate revision/validation ID 绑定、按现有鉴权读取、禁止任意路径输入，不返回私有路径。reference WAV 校验整文件 hash；validation WAV 同时校验 WAV hash 与 PCM hash。现有客户端在请求中固定 candidate revision；资源返回 `Cache-Control: no-store`。机器 validation 与人工复核记录分开，人工结果绑定实际听过的 validation ID。

当前代码与单元测试覆盖以下顺序：创建耐久候选 → 听其 reference/确认参考文本 → machine validate → 听当前 validation 输出 → 两项人工判断 → 提交绑定 validation ID 的 human_review → 检查 publishable/revision → publish。更换 reference、validation、model binding 后撤销旧确认；播放结束只开放人工判断入口，不能自动生成 pass。真实服务音频和 UI 手工验收仍未运行，见配套方案 §8.1。原“候选音频读取延期”决策取消：这是人工复核有效性的前置条件，必须随发布闭环交付。

### 7.4 可视化与文案

- 普通 TTS 成功不应改变音色创作可用性；音色创作失败也不应影响音色库试听。
- 服务状态的普通能力区移除“语音合成 · 语音设计”行。
- 若需要展示创作能力，单独显示“音色创作（按需）”，原因文案说明“需要生成候选时加载”，不参与普通 TTS readiness。
- 开发者详情可以展示 `/v1/voices/previews`、`voice_design` 和 candidate revision，但不能回写为普通 speak 能力。

## 8. 音色与 revision 一致性

### 8.1 修改协议

`AppModel.updateVoice` 必须改为使用 `/v1/speechrail/voices/{voice_id}` 的 CAS 更新：

- 请求必须携带 `expected_revision`。
- App 不得在缺少 revision 时回退 `/v1/voices/{id}` PATCH。
- App 更新前先读取或刷新 safe voice projection。
- `409 revision conflict` 是正常可恢复冲突：刷新 voice 与 capability，保留编辑内容，提示用户基于最新 revision 重试。
- `unsupported`、`unknown` 和 `unavailable` 分别映射为不同 UI 状态，不统一显示成“网络错误”。

### 8.2 统一刷新范围

影响已发布音色目录的操作成功后触发同一 refresh transaction：

- create
- publish
- register
- update
- rollback
- revoke
- delete
- clone registration

candidate create/confirm/validate/cancel 只刷新对应 candidate；它们不自动改变已发布目录，不必每一步重取三类列表。上列 create 指已发布音色创建。

刷新对象：

1. `/v1/voices` rich list；
2. `/v1/speechrail/capabilities`；
3. `/v1/speechrail/voices` safe projection。

统一刷新失败时不回滚已经完成的远端 mutation，但 UI 必须标记本地状态陈旧，并阻止依赖 revision 的继续操作，直到刷新成功。

### 8.3 revision pin

- 普通 HTTP speech：发送前必须取得有效 snapshot，并同时携带选中 voice revision 与该 voice 的 model catalog revision。缺失任一 pin 先刷新一次，仍缺失则 fail-closed；不得继续空 options 或从 rich voice 补 pin。
- Realtime TTS：在 session 配置和每个 helper TTS request 上使用同一有效 revision binding。
- mutation：使用 candidate/voice 的 CAS revision，不复用 speech pin。
- 同一 connection 中的 Realtime revision 不热切换；需要切换时先结束或取消活动 utterance。

### 8.4 clone 幂等

- clone 注册保留现有 POST `/v1/voices/clone` 并携带 `Idempotency-Key`；`GET /v1/speechrail/voices/clone/idempotency` 仅查询该 key 的结果，不能向它 POST 注册。
- 创建幂等 key 后，超时重试必须使用同一 key 和同一 payload。
- App 不根据“请求超时”自行判断注册失败；以同 key 查询结果。`completed` 且 result_id 非空才确认成功，`pending` 保留待确认状态；404/new 可用原 key 与原 payload 重试；409 payload conflict 禁止自动换 key。safe voice list 只能刷新展示，不能证明某个幂等操作成功。
- pronunciation sets 的 list surface 作为 Client parity 补齐；是否增加 UI 编辑入口由需求方另行决定。

## 9. Realtime 会话门禁与版本隔离

### 9.1 operation 门禁

| 会话 | required operation | 启动前判定 |
|---|---|---|
| 语音助手 | `realtime_transcription` + `realtime_speech` | ASR 输入可用，同时 voice、对应 TTS model revision 与 PCM 输出参数已声明；不以双向 socket 宣称 full duplex。 |
| 会议助手 | `realtime_transcription` | ASR model revision 可用，turn detection 与采样率约束满足。 |
| 字幕带 | `realtime_transcription` | 同会议；alignment/diarization 是独立可选能力。 |
| 提词器 | `realtime_transcription` | 同会议，并满足提词器跟随所需输入格式。 |

`/readyz` 是进程级诊断，不是独立的会话准入门禁。准入以同一份有效 capability snapshot 中所需 operation 的状态和完整 revision binding 为准：`ready=true` 不代表 operation 已支持、已认证或当前没有 busy；`ready=false` 或 readiness 查询失败也不能单独否决一个已验证的 operation binding。若 capability snapshot 缺失、过期或 operation 不可用，则无论 `/readyz` 状态如何都不得启动；服务端运行时 admission 仍可返回 `backend_busy` 等明确结果。

### 9.2 wire 约束

- App wire 固定 24 kHz mono PCM16。
- 16 kHz 只属于服务端内核转换，不在 App 会话层暴露为可选 wire format。
- voice/model revision 在会话建立或首次 TTS 前确定；服务不匹配时 fail-closed。

### 9.3 事件身份与 revision

ASR 辅助状态以 connection generation、`session_id`、`task_id`、`epoch`、`utterance_id` 为身份；以下 revision 是该身份内的版本计数，不能把每个 revision 都当新缓存键：

- `task_id`
- `epoch`
- `utterance_id`
- `transcript_revision`
- `metadata_revision`

规则：

- hypothesis 是可改写快照，必须整段替换，不能当 append-only delta。
- official transcription delta 只接受可证明的稳定前缀；否则只保留 hypothesis。
- alignment 和 diarization 是独立终态。alignment failure 不把 transcript 标失败；diarization failure 只降级 speaker label。
- 旧 epoch、旧 transcript revision、旧 metadata revision 或不匹配 utterance 的 alignment/diarization 事件必须丢弃。
- alignment units 必须对应冻结的 transcript revision；当前 revision 不一致时不能合并展示。
- 连接级 sequence 在解码后的业务投递前验证；缺失、缺口、回退或 session 变化结束该连接，不能只写 diagnostic 后继续。hypothesis 使用自身 `revision`；ASR completed 没有 task/epoch/revision 字段，不得强行要求其携带。
- 无 hypothesis 的 final 合法：按当前连接/item 建立冻结文本，首个完整辅助事件建立该 item 的 task/epoch/revision binding；后续不得更换。须先通过 sequence、item、文本 codepoint span 校验。Swift 范围使用 `unicodeScalars`，不能用 UTF-16 或 `String.count` 替代服务 codepoint。
- alignment 与 diarization 分别维护 metadata revision；不能相互压制。服务 `_send_diarization_updates` 会把同一 metadata revision 拆成多个不同 sequence 的事件；接受同 revision 的后续分片并按 span 合并，不能简单 `<=` 去重或整包覆盖。TTS 使用 connection generation + request_id + task_id、chunk_index/sample_offset 与 playback generation，不要求套用 ASR utterance/revision 字段。

### 9.4 缓存、流与终态

- `RealtimeASRClient.events()` 使用有界队列，限制 256 个事件和合计 4 MiB 解码音频；任一超限结束连接并经独立关闭路径通知会话失败、停播放，不能静默丢 PCM/delta/terminal，也不能把溢出错误继续塞进满队列。数量上限与字节上限同时有效。
- ASR text final 仅冻结文本；辅助仍在处理时保留当前 item。alignment done/failed 与 diarization 会话 done/failed 各自收束，全部相关终态完成后交付并清理。最多保留 128 个辅助 item、每个最多等待 30 秒；超限/超时交付已知归属并标记辅助不完整后回收，不能把它解释为 ASR 失败。
- 单 item 累积上限为 64 KiB UTF-8 transcript、1,024 alignment units、1,024 diarization spans，以及按 entry 固定开销与字符串 UTF-8 字节估算的 256 KiB 辅助数据总量。超限保留已接受状态、显式发送 `realtime_item_state_overflow` 并关闭连接，不截断或静默丢弃终态。
- 注意当前 diarization done 是 `speechrail.diarization.finish` 后的会话级屏障，不保证每 item 都收到 done。持续更新时按有界窗口交付已有 attribution 后回收 transport 缓存，历史文字/已交付归属由会话层保留；30 秒是本地等待预算，不是服务端 SLA。不能等会话 done 才清所有历史 item，不能把每个 updated 当 done。
- 审查基线使用 `alignmentUnitsByItem` / `diarizationSpansByItem`，未发现原文所称 `alignmentOrder`；当前实现由 `RealtimeEventState` 统一管理 revision tracking、分片与有界 tombstone。最终合并值交付会话层后再删除，迟到终态不能重建 item。
- 连接关闭、超时、失败和重连均走同一清理函数，避免只清一个 map。
- 终态和错误事件优先于已失效的音频或 metadata；陈旧数据不能重新激活 UI。

### 9.5 打断顺序

用户打断或新回复抢占时：

1. 立即停止本地播放并丢弃旧 playback generation；
2. 发送 `speechrail.tts.cancel`；
3. 忽略取消后到达的旧 request/response 音频；
4. 服务端终态只收束一次 active TTS 状态。

播放层不能等待服务端 cancel 成功后才停旧音。

## 10. API Client 覆盖缺口

| 能力 | 当前 App 状态 | 本轮设计 |
|---|---|---|
| `/v1/voice-designs` list/get/cancel | 未完整覆盖。 | 增加完整 candidate surface，支持离开、取消和恢复状态。 |
| `/v1/speechrail/voices/clone/idempotency` | 未接线。 | 接入 clone 幂等结果查询；注册仍走 POST `/v1/voices/clone`。 |
| `/v1/speechrail/pronunciation-sets` list | 未完整覆盖。 | Client parity 补齐；UI 后续决定。 |
| `/v1/speechrail/voices/{id}` update | 有 CAS client，但调用方仍可走 fallback。 | 生产路径强制 CAS，删除 fallback。 |
| `/v1/speechrail/voices/{id}/quality-runs` | 有旧路径 fallback。 | 删除旧路径，只保留当前契约。 |
| VoiceDesign candidate 状态 | 已有 revision、publishable、validations；缺少完整服务端投影与读取/取消接线。 | 增量补齐 state、validation 模型身份等字段；未知状态 fail-closed，不重造已有模型。 |
| Realtime TTS revision pin | 部分实现了 voice/model revision。 | 统一由 facade 生成并在连接、request 和测试中验证。 |
| HTTP speech revision pin | selector 可返回空 options，且 model pin 固定读 `models.tts`。 | 强制同 snapshot 的 voice/model binding，覆盖 clone/CustomVoice 不同制品。 |

Client 错误必须保留稳定的 service code、request ID 和 revision/conflict 信息；视图不展示原始 JSON 或未经处理的内部字段。

## 11. 状态呈现与用户文案

### 11.1 Capability 状态

| 服务事实 | UI 状态 | 用户动作 |
|---|---|---|
| operation supported、voice available | 可用 | 允许开始。 |
| operation unsupported | 当前不支持 | 引导切换 profile/模型；不反复重试。 |
| snapshot checking | 正在确认 | 禁用并显示检查中。 |
| snapshot failed/unauthorized/notReady | 暂时无法确认 | 提供刷新或服务状态入口。 |
| voice unknown/revoked | 不可用 | 刷新音色与服务状态。 |
| revision conflict | 状态已变化 | 刷新后让用户重试，不覆盖远端。 |

### 11.2 服务状态

- 普通 TTS 行只描述 HTTP/Realtime 普通合成。
- “音色创作（按需）”独立一行，原因区分设计制品不存在、设计 lane busy、服务端声明未知。
- `voice_design` 不再作为普通“语音合成”能力行出现。
- `voice_design` 出现在常驻 worker 列表中时，文案说明“候选生成时按需加载”，不暗示普通 speak 常驻。

### 11.3 运行监控

- 请求计数分别读取 `/v1/audio/speech` 与 `/v1/voices/previews` 的 endpoint label。
- 若 metrics 没有提供按 endpoint 拆分的音频秒数，UI 只显示“TTS lane 总时长（含设计试听）”，不按请求数比例估算。
- TTS lane latency、RTF 和 voice-class histogram 保持现有聚合口径；没有 label 时不伪造按创作/普通合成的拆分。
- 对 `/v1/voice-designs` 作业本身的监控可以在后续有明确指标后加入，本设计不要求 App 从请求计数推断作业时长。

### 11.4 开发者文档

- `/v1/models` 仅列为模型发现。
- `voice_design` 仅在“音色创作”章节出现，列出 candidate lifecycle 与 preview endpoint。
- effective capabilities 作为唯一能力门禁来源。
- 删除 “supportsInstruction/supportsPreview 决定 App 是否提供设计”的说明。
- 旧 endpoint fallback 不写入用户文档或示例。

## 12. 实施切片

### Slice 1：Capability facade 与 current-only API client

交付：

- `AppCapabilityFacade` 及纯单元测试。
- `ServiceModelCapabilityClient` 从生产依赖链移除。
- `refreshServiceCapabilities` 的 legacy projection 与 fallback 删除。
- 视图改读 facade，不直接解析 `JSONValue`。

验收：snapshot 缺失/无 schema/404/409/网络失败时状态不误判可用，且没有任何生产路径读取 `/v1/models.capabilities`。

### Slice 2：VoiceDesign 创作生命周期

交付：

- 创作门禁改读 effective snapshot 的 `operations.voice_preview.status`。
- `/v1/voices/previews` 只由音色创作流程经 AppModel/client 调用，视图不直接持有网络客户端。
- 发布前实际试听依赖 D1；未完成不得把 Slice 2 标为交付完成。
- candidate list/get/cancel、revision、publishable 和 validation typed DTO。
- 保存时耐久 candidate + Base 新文本复验 + 人工复核绑定 revision。

验收：普通试听、配音台、作品重放均不调用 preview endpoint；取消与离开后临时状态清理；publish revision mismatch 可恢复且不会误发布。

### Slice 3：普通 TTS、音色库和 mutation refresh

交付：

- update voice 强制 CAS，删除旧 fallback。
- rich list、effective snapshot 和 safe voice projection 的统一 refresh。
- HTTP speech 的 voice/model revision pin。
- clone idempotency 接线。

验收：revision 冲突不会覆盖远端；mutation 后三类状态一致；超时重试不会重复 clone。

### Slice 4：Realtime epoch/revision 与 operation gate

交付：

- 助手、会议、字幕、提词器分别按 operation 门禁。
- alignment/diarization 校验 task/epoch/utterance/revision。
- event stream 有界。
- 终态清理与停播后取消顺序。

验收：旧事件注入不会更新当前 UI；长模拟事件序列不会无限增长；取消旧播放不会让 stale audio 复活。

### Slice 5：服务状态、监控、模型、诊断和文档

交付：

- VoiceDesign 从普通 TTS 能力行移出。
- endpoint 级请求统计拆分。
- developer API 列表与文案 current-only。
- OpenAPI、effective capability 和 App 文档的跨端清理登记。

验收：服务状态不把 VoiceDesign 当普通 speak；监控不伪造 endpoint 拆分；开发文档不再引用旧 capability 判定。

### Slice 6：Design Token、键盘、VoiceOver、Reduce Motion 与音频生命周期

交付：

- 新增 UI 使用现有 `SpeechRailDesignTokens` 语义 Token。
- capability 状态、候选卡片、检查器和禁用原因具备键盘与 VoiceOver 语义。
- Reduce Motion 下有替代过渡。
- 离开页面、取消和终态释放音频任务及缓存。

验收：不新增裸视觉常量；禁用操作具有可访问原因；无未释放播放/生成任务。

### Slice 7：契约测试、单元测试、构建与发布验收

交付：

- ControlKit fixture 与 decoding 测试。
- App capability/session/state 单元测试。
- Debug/Release App 构建验证。
- 真实服务、真实音频和 UI 验收分别按授权执行。

验收：确定性测试、构建和人工验收结果分别记录；没有执行的项目明确写 `not_run`，不能用单元测试替代真实音频或 UI 结论。

## 13. 验证策略

### 13.1 确定性验证

- `AppCapabilityFacade` 的状态矩阵、revision pin 和 unknown/fail-closed。
- VoiceDesign candidate revision、conflict、cancel、publishable、validation 投影。
- voice update CAS 与 refresh transaction。
- Realtime epoch/revision 过滤、hypothesis replace、alignment/diarization 独立终态。
- bounded stream、终态 map 清理和取消顺序。
- endpoint metric 解析与缺失维度时的降级文案。

### 13.2 契约验证

- `/v1/speechrail/capabilities` schema 与 operation parsing。
- `/v1/voice-designs` list/get/cancel response。
- `/v1/speechrail/voices` safe projection。
- `/v1/speechrail/voices/clone/idempotency`。
- `/v1/speechrail/pronunciation-sets` list。
- Realtime event version/revision fixtures。

### 13.3 构建与运行态验证

- App 构建使用仓库包装脚本，避免残留可被 LaunchServices 识别的额外副本。
- 真实服务 smoke、模型加载、真实音频、安装和 UI 自动化均需单独授权；未授权时只记录为未验证。
- UI 自动化不得因本 spec 的存在自动执行。

### 13.4 验收矩阵

| 验收项 | 证据要求 | 失败条件 |
|---|---|---|
| 唯一能力事实源 | 代码搜索、测试、请求记录 | 任一生产路径回退 `/v1/models.capabilities`。 |
| VoiceDesign 隔离 | API 调用测试与 UI 路径测试 | 普通试听/重放调用 `/v1/voices/previews`。 |
| revision 一致性 | CAS 测试、冲突测试、snapshot 测试 | 无 revision 仍更新，或旧刷新覆盖新状态。 |
| Realtime 隔离 | 旧 epoch/revision fixture、终态清理测试 | 旧事件改变当前 UI，或缓存无界增长。 |
| API 完整性 | client contract test | list/get/cancel、clone idempotency、pronunciation list 仍缺失。 |
| 状态呈现 | UI state tests、文档审阅 | VoiceDesign 被显示为普通 TTS。 |
| 质量门 | 构建与授权后的实测记录 | 仅凭静态检查宣称服务或音质完成。 |

## 14. 跨端契约与文档清理

以下内容不是 App 单端文案问题，必须在实现计划中登记为跨端变更：

1. `contracts/openapi.yaml` 删除 VoiceDesign 仅在 reference spec 的描述，改为与档位无关的按需设计制品。
2. `docs/users/effective-capabilities.md` 与 OpenAPI 统一声明：VoiceDesign 只服务 `voice_design` 作业，普通 Base/CustomVoice 路由拒绝 Design runtime voice。
3. 服务状态和监控的内部名映射统一：`voice_design` 必须标为音色创作，而不是普通 TTS。
4. `contracts/openapi.yaml` 中能力的认证与 readiness 说明必须与 effective capability snapshot 的实际语义一致。
5. 如有服务端新增 metrics label 或 voice-design 作业指标，先在公共契约和诊断文档定义，再让 App 读取；App 不从请求次数外推服务端事实。
6. OpenAPI、用户文档、测试和 App DTO 必须同一次变更更新，不能只改前端显示。

## 15. 备选方案与取舍

### 方案 A：只改文案和门禁

保留双事实源和旧 fallback，只把 VoiceDesign 文案改掉，并让部分页面读新 snapshot。

不选原因：revision、Realtime 版本隔离和旧 endpoint 回退仍是真实缺陷；该方案会把架构问题留到下一次发布。

### 方案 B：分层 current-only 收口

保留导航、页面和会话引擎，在客户端边界、AppModel、capability facade 和 Realtime state 层收口。

选中原因：改动范围可控，能直接消除双事实源和职责漂移，也能为后续 UI 改进提供稳定契约。

### 方案 C：全量重写 App 数据层和导航

重建所有 feature model、页面和 session ownership。

不选原因：当前问题集中在服务契约、revision 和事件隔离，不在导航结构；全量重写收益低、回归风险高，还会扩大未授权范围。

## 16. 默认决策与明确延期项

### 16.1 默认决策

1. 音色创作保留 4 个临时预览（speed=1.0）。保存时创建耐久 candidate，并用不同测试文本在 Base 路径复验；不假定重新生成与临时预览相同。
2. 临时 candidate 在当前 App 会话内取消、失败或离开时清理；list/get/cancel Client surface 必须存在，但跨 App 重启恢复不进入首期 UI 主路径。
3. 普通 HTTP TTS 的 model revision 使用 effective snapshot 中选中 voice 的 `model.catalog_revision`；voice revision 取同一个安全条目。
4. Realtime helper TTS 使用和 session 相同的 revision binding；不因单次请求或重连静默切换到最新 revision。
5. `/v1/models` 保留模型和别名发现，不删除该 endpoint；只删除它作为 App capability 判定来源的用法。

### 16.2 明确延期项

- D1 是必须交付的前置项，不属于延期范围；未完成前不开放人工复核发布闭环。
- 跨 App 重启的创作草稿恢复 UI。
- pronunciation sets 的管理 UI；本轮只补齐 Client surface parity。
- VoiceDesign 作业级监控指标；本轮只要求普通 HTTP 与设计 preview 的请求计数不混淆。

## 17. 回退与发布边界

- 设计文档提交只影响仓库文档，不改变运行态、App 安装或服务 profile。
- 实现按 Slice 1–7 分批提交，每个 slice 保持可回归；不要在未完成 capability facade 前删除旧调用点。
- 删除 fallback 前先在测试中证明 current-only 路径能够处理旧服务返回的失败状态；失败状态应 fail-closed，而不是伪装可用。
- App 发布包必须成对验证服务契约版本、App DTO 和 revision pin；无法确认时禁用对应入口，不回退旧协议。
- 回滚实现时回到上一层 App 与控制面提交；已按 §18 清除的数据不会因代码回滚自动恢复。合规数据及无关模型目录、私有配置不在清理范围。

## 18. 审查结果与实施边界

2026-09-26 的设计审查以源码、契约和测试入口静态核对为主；当时没有运行测试、构建、模型、服务或 UI 自动化。后续同一任务已进行部分实现验证，当前证据列在配套 Luna 方案 §8.1；此处审查基线和目标设计不应被误读为最新实现状态。已更正 clone model pin、幂等查询语义、非原子刷新、ASR 辅助终态、已有 DTO 与取消顺序的事实描述，并保留作品离线重放。

配套 Luna 方案已落盘，无需再生成另一份泛化计划。用户于 2026-09-26 补充授权：“当前本机，不符合要求的存量数据均可清除。”据此取消因旧数据兼容产生的 D1 待确认项；当前实施没有发现可清理对象，未执行删除。

本机只读核查（2026-09-26）：当前源码中的全局 `VoiceRegistry` 使用默认 `~/.speechrail/custom_voices.json`，VoiceDesign 候选存储与资产目录由该注册表路径派生；对应的 `~/.speechrail/voice_design_candidates.json` 和 `~/.speechrail/voice_design_candidates/` 均不存在，因此没有发现可分类或清除的候选记录/资产，也未执行删除。此结论仅说明目标路径不存在，不代表检查或验证了其他用户数据。实施和测试进度见 Luna 方案 §8.1。

若后续在授权范围内发现候选存量数据，按以下规则判定，无需对已明确属于范围内的数据重复确认：

1. 仅限当前本机、本次 App-Service 集成涉及的存量数据；以目标 schema、revision/hash 一致性、资产完整性和人工复核证据为判定标准，不以“创建时间早”作为删除理由。
2. 可清除经核实缺少必要字段/资产、revision 或 hash 不一致、误绑定人工确认、无法满足目标契约的记录及其专属派生资产。有效数据不受影响；若删除会使其他记录失效，先核对引用关系，精确列明需要一起清理的对象。
3. 先解析实际数据根目录并生成脱敏清单，记录对象类型、ID、不合规原因和引用关系；禁止通配清空 app home、共享目录、模型、凭据或无关项目数据。归属或不合规性无法核实的对象保持原状并报告。
4. 只清理清单内已证实不合规、归属明确的记录及其专属派生资产；不新增迁移层或通用清理工具，不扩展到无关目录。服务启停等运行态操作仍遵循独立授权。
5. 清理后核实保留记录可读且没有悬空引用，并报告实际清理数量和依据。数据清理与代码回滚分开记录。
6. 该授权不扩展至远端或其他机器，也不自动授权安装发布、UI 自动化、模型下载或无关运行态变更。
