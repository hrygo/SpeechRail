---
title: "SpeechRail TTS 完整迁移与跨项目整洁架构设计"
status: review-requested
date: 2026-09-01
review: user-approved-scope-and-approach
---

# SpeechRail TTS 完整迁移与跨项目整洁架构设计

## 1. 决策摘要

本次采用 **Scope A：只迁移原 `voice-realtime` 的 TTS 完整链路**。SpeechRail 成为
TTS 模型、合成会话、音频格式、队列、取消、鉴权和可观测性的唯一运行时所有者；
`voice-realtime` 仍拥有 LLM、Pipecat 对话编排、播放、打断、回声处理、会议、UI 和
PostgreSQL。

传输采用 **Realtime v2 原生链路 + REST 兼容试听链路**：

1. 语音助手生产链路使用 `WS /v2/realtime`，以文本增量换取有序 PCM 音频 chunk；
2. UI 试听、重播和诊断使用 `POST /v1/audio/speech`，复用同一 TTS 应用用例，不复制
   一套生成逻辑；
3. `voice-realtime` 以出站 adapter 消费 SpeechRail，不把模型 SDK 或 SpeechRail
   内部实现引入业务层；
4. 新链路通过真实模型、取消、背压、播放和 UI 冒烟后，退役旧 `tts_bridge`、
   `vr-bridge` 运行路径。

这是迁移规格，不是代码完成声明。规格审阅通过后，才进入实施计划和代码修改。

## 2. 已验证的当前基线

### 2.1 模型和运行时

原 `voice-realtime` TTS bridge 的默认后端是：

- 实际模型快照：`mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16`；
- 模型类型：`voice_design`；
- 运行时：`mlx_audio.tts.utils.load`；
- 输出：单声道、24 kHz、signed little-endian PCM16；
- 默认温度、top-p、重复惩罚和 streaming interval 需要在迁移中保持可配置且有默认值。

SpeechRail 对外的稳定逻辑模型名保持为 `speechrail/qwen3-tts`。逻辑模型名不暴露
本地快照路径，也不要求消费者绑定 vendor SDK。模型快照仍是外部绝对路径；默认不下载，
也不在请求期间访问网络。

当前 SpeechRail TTS worker 使用 `qwen_tts`/Torch 风格的 CustomVoice 调用，而原 bridge
使用 MLX VoiceDesign 调用。这不是可直接复用的实现：若只把旧配置或 endpoint 改名，
会丢失 `instruct` voice profile、流式 chunk、归一化和取消语义。因此迁移必须替换
worker backend，而不是只改客户端 URL。

### 2.2 原链路

```text
Pipecat / LM Studio 文本
  → ChineseClauseTextAggregator
  → LocalBridgeTTSService
  → voice-realtime tts_bridge HTTP
  → MLX Qwen3-TTS VoiceDesign
  → PCM16 24 kHz
  → TTSStateObserver / AudioHub / playback
```

旧 bridge 还提供 `/health`、`/v1/voices`、`/v1/voice` 和 `/v1/audio/speech`，并在
`voice-realtime` 的 `run-all` 脚本中作为独立进程启动。旧服务用 `alloy` 作为 Pipecat
占位 voice，再映射到当前 preset；这只是兼容细节，不应成为 SpeechRail 公共 voice ID。

### 2.3 当前 SpeechRail 差距

当前 SpeechRail 已有 TTS REST/v2 外形、端口和 fake backend 测试，但仍存在以下迁移缺口：

- worker 不是原 MLX VoiceDesign backend；
- voice registry 只有默认 voice，未迁移四个 preset 的 description/instruct；
- worker 还没有与 v2 response cancellation 对齐的取消和 stale-output 隔离；
- `/v1/voices` 尚未成为公共能力；
- `/readyz`、v2 speech session 的 voice 校验和 commit/cancel 生命周期仍需补齐；
- `voice-realtime` 的实时 TTS 仍走本地 bridge，不能仅通过修改 OpenAI base URL 迁移，
  因为 Pipecat 默认会发送 `gpt-4o-mini-tts` 和 `alloy`，与 SpeechRail 契约不匹配。

## 3. 范围和非目标

### 3.1 本次范围

- 将 MLX Qwen3-TTS VoiceDesign adapter、预置 voice profile、文本归一化和 PCM 后处理
  迁入 SpeechRail infrastructure/application 边界；
- 补齐 SpeechRail REST 与 Realtime v2 TTS 的端到端生命周期；
- 在 `voice-realtime` 增加共享的 SpeechRail transport client 和 Pipecat TTS adapter；
- 把语音助手 pipeline、试听/replay、voice selector、健康探针和启动配置切到 SpeechRail；
- 完整验证从 LM Studio 文本到实际扬声器播放、取消和 UI 试听的闭环；
- 在新链路验收后删除或停用旧 bridge 的主动调用、启动和 TTS 模型依赖。

### 3.2 明确不迁移

- 麦克风、扬声器、播放缓冲和 barge-in/interrupt 决策；
- LLM、LM Studio 会话、Agent、prompt 和对话持久化；
- 会议生命周期、说话人 diarization、SRT、PostgreSQL 和会议 UI；
- `voice-realtime` 的 ASR 领域语义。已有 SpeechRail ASR adapter 只在需要共享 transport
  时做最小重构；
- 语音克隆、任意 voice sample 或自由文本 speaker embedding；
- 自动下载、加载、卸载或更换本机模型配置。

本次架构验收聚焦 TTS 代码路径和两个项目之间的边界，不以重构无关会议/LLM/设备代码为
前置条件。`voice-realtime` 中现有的生命周期、重连和资源清理控制流环不属于 TTS 迁移
对象；它们不应促使 SpeechRail 接管这些领域。

## 4. 统一 TTS 契约

### 4.1 公共身份和音频格式

| 字段 | 决策 |
|---|---|
| 逻辑 model | `speechrail/qwen3-tts` |
| 实际 backend | MLX Qwen3-TTS `voice_design` profile |
| 输出 | mono, 24,000 Hz, signed little-endian PCM16 |
| REST format | `pcm` 或 `wav`；WAV 只增加标准容器，不改变采样格式 |
| Realtime format | 只发送原始 PCM16 24 kHz chunk |
| voice | 服务端登记的 preset ID；不接收声纹样本 |
| language | 默认 `auto`，在 REST 和 speech session 中保持一致 |
| speed | `0.25..4.0`，默认值沿用原 bridge |

四个首发 voice profile 的公开 ID 和指令固定为：

| ID | VoiceDesign instruct |
|---|---|
| `default` | `自然清晰的中文女声，语气平和亲切，语速适中，适合日常对话。` |
| `warm` | `温暖柔和的中文女声，语速略慢，语气舒缓，适合阅读与陪伴场景。` |
| `bright` | `明亮活泼的中文女声，音调偏高，语气轻快，适合播报与讲解。` |
| `calm` | `沉稳平静的中文男声，语速平稳，语气专业，适合资讯播报。` |

`alloy` 只作为 `voice-realtime` 内部的历史兼容别名，发送给 SpeechRail 前归一化为
`default`，不出现在 SpeechRail 的 voice registry。该别名的退役日期暂定为
**2026-10-31**；实施时必须在配置和迁移说明中保留该日期，过期后以稳定错误拒绝。

### 4.2 REST 兼容试听

SpeechRail 提供：

```text
GET  /v1/voices
POST /v1/audio/speech
```

`/v1/voices` 返回 voice ID、description、默认标记和当前可用状态。`/v1/audio/speech`
要求 `model == speechrail/qwen3-tts`，`voice` 必须属于当前 registry，支持 `input`、
`response_format`、`speed` 和 `language`；未支持字段必须以统一错误 envelope 拒绝，
不能静默忽略。

REST 与 v2 共享同一个 TTS application use case 和 backend port。REST 的完整输出可以
聚合为 WAV；`pcm` 响应必须保持 24 kHz PCM16。长文本也必须经过有界的 clause/chunk
策略，不能把无界 waveform 直接堆进内存；沿用当前 SpeechRail 的公共输入上限，并在
每次 backend generation 前施加与原 bridge 等价的单段 token 上限。

### 4.3 Realtime v2 speech session

```text
session.update { type: "speech", model, voice, language, audio_format }
  → 0..N × speech_input.append
  → 0..N × [response.created
             → 0..N × response.audio.delta
             → response.audio.completed/cancelled]
  → 0..N × speech_input.flush
  → speech_input.commit
  → session.completed
```

约束如下：

- `session.created` 回显实际 `model`、voice、language、采样率、声道和 sample width；
- `append` 接收 UTF-8 文本增量；服务端只在安全 clause 边界开始合成；
- `flush` 强制输出当前可读文本但保持 session 可继续；`commit` 处理剩余文本并终结 session；
- 一个 session 同时最多一个 active response，所有 response 和 audio chunk 有单调 sequence；
- `response.cancel` 必须按 response ID 生效，发送 `response.audio.cancelled` 后不得再发布
  该 response 的 audio delta；
- 在 committed session 中，response 终态后必须发布唯一 `session.completed`；取消不能遗留
  永不终结的 session；
- 输出使用有界队列和背压。慢消费者达到上限时发布稳定、可重试属性明确的错误，并释放
  worker/会话资源；不得无界缓存；
- 断线、session.cancel 和 worker 重启必须释放活动 generation，旧 response 的结果不得进入
  后续 session。

错误统一包含 `type: "error"`、稳定 `code`、`request_id`、`retryable`，并遵循
`contracts/realtime-v2.md` 的事件 envelope 和顺序定义。

## 5. 两个项目的整洁架构边界

### 5.1 SpeechRail

```text
domain
  VoiceProfile / SpeechRequest / AudioChunk / SpeechSynthesizer port
      ↑
application
  synthesize speech / list voices / realtime session orchestration
      ↑
adapters
  REST route / WebSocket route / request validation / event serialization
      ↑
infrastructure
  worker supervisor / framed IPC / MLX Qwen3-TTS adapter / audio post-process
```

依赖规则：

- domain 不 import FastAPI、Pydantic、httpx、Pipecat、`mlx_audio`、`numpy` 或 vendor SDK；
- application 只依赖 domain port，不知道 MLX、Torch、模型快照路径或进程管理；
- REST/WS adapter 只做输入输出映射、鉴权、request ID 和错误映射，不承载合成算法；
- MLX、`mlx_audio`、`numpy` 和进程 IPC 只存在于 infrastructure worker 边界；
- composition root 负责把 profile、worker 和 adapter 组装起来；测试使用 fake
  `SpeechSynthesizer`，不能用隐式全局模型；
- worker 的模型路径来自已校验的外部绝对路径，日志只记录逻辑 profile 和脱敏资源摘要。

### 5.2 `voice-realtime`

```text
interaction / meeting / UI application logic
  → local SpeechRail ports (TTS client / voice catalog / health)
  → outbound adapters
      ├─ shared SpeechRail v2 transport + envelope validation
      ├─ SpeechRailStreamingTranscriber (现有 ASR 端口)
      └─ SpeechRailPipecatTTSService (新增 TTS 端口)
  → WebSocket/HTTP network
```

迁移后的 TTS 代码规则：

- `LocalBridgeTTSService` 不再是生产 pipeline 的实现；Pipecat 只依赖一个能产生
  `TTSAudioRawFrame` 的 TTS service；
- SpeechRail v2 的连接、session/request ID、sequence、错误、取消和关闭逻辑由共享的
  出站 transport 负责；ASR 与 TTS 各自有 adapter，不能用一个万能 adapter 抹平不同生命周期；
- UI server 是 delivery adapter，只代理 REST、健康和 voice catalog，不直接 import MLX、
  TTS engine 或 worker；control layer 只改变应用选择的 preset，不调用已退役的全局
  `/v1/voice` 热切换服务；
- `voice-realtime` 不持有 SpeechRail 模型路径、模型 cache、TTS vendor dependency 或
  worker 生命周期；部署 supervisor 负责分别启动和监控两个项目；
- 播放、AudioHub、TTSStateObserver、回声抑制、meeting store 和 PostgreSQL 继续位于
  应用侧，SpeechRail 只返回音频和协议事件。

### 5.3 跨项目依赖图

```text
LM Studio token/text
  → voice-realtime clause aggregator
  → voice-realtime SpeechRailPipecatTTSService
  → SpeechRail v2 client
  → SpeechRail /v2/realtime speech session
  → SpeechRail application/session governor
  → SpeechRail MLX worker
  → external Qwen3-TTS VoiceDesign snapshot
  → response.audio.delta
  → TTSAudioRawFrame
  → existing observer / AudioHub / playback

UI preview/replay
  → voice-realtime REST proxy
  → SpeechRail /v1/audio/speech
  → same application use case and worker
```

任何反向依赖（SpeechRail import `voice_realtime`、写会议数据库、调用 LM Studio 或操作
播放设备）都视为架构验收失败。

## 6. 分阶段迁移方案

### Phase 1：SpeechRail TTS domain 和契约

- 固化 `VoiceProfile` registry、`speechrail/qwen3-tts`、24 kHz PCM16 和 REST/v2 字段；
- 将原 bridge 的文本 normalization、动态 token budget、voice instruct 和 PCM 后处理
  变成可测试的 application/domain policy；
- 增加 `/v1/voices`、component readiness 和错误/请求 ID 文档；
- 先用 fake backend 固化顺序、voice、格式、上限和取消测试。

### Phase 2：SpeechRail MLX worker

- 在 SpeechRail infrastructure 中实现外部 Python worker，复用原 MLX VoiceDesign 语义；
- worker handshake 声明 logical model、backend kind、sample rate 和协议版本；
- 支持 request ID、bounded output、cooperative cancel；backend 无法及时中断时，supervisor
  必须隔离旧 generation 并安全重启 worker，不能把迟到音频送入下一请求；
- 只使用预先存在的外部 snapshot，下载开关默认为 false；不在测试或请求中联网。

### Phase 3：SpeechRail REST/v2 闭环

- 将 REST 与 v2 都接到同一 application use case；
- 修正 speech session 的 voice registry 校验、commit-after-cancel、session.cancel、
  response terminal event、背压和资源清理；
- 加入 fake backend 的完整状态机、慢消费者、worker 重启和重复 request ID 测试；
- 以真实 snapshot 做受控本机冒烟，记录首 chunk、RTF、峰值内存和音频可播放性，不宣称
  未测出的性能指标。

### Phase 4：`voice-realtime` 出站 adapter 和 pipeline

- 从现有 ASR adapter 提取中性的 SpeechRail realtime transport；保留 ASR 的领域 adapter；
- 实现 SpeechRail TTS client 和 Pipecat service，复用 `ChineseClauseTextAggregator` 的
  安全边界，但把网络和协议解析放在 adapter；
- 将 pipeline 的 `LocalBridgeTTSService` 替换为 SpeechRail TTS service；实现 cancel、
  cleanup、TTSAudioRawFrame、24 kHz 元数据和 playback 侧 observer 的完整映射；
- 仅在 `voice-realtime` adapter 内把 `alloy` 归一化为 `default`，并记录退役日期。

### Phase 5：UI、部署与退役

- UI 的 `/v1/voices`、试听/replay、health probe 和 voice control 指向 SpeechRail；
- `run-all` 不再启动 `vr-bridge` 或下载 TTS 模型，只检查外部 SpeechRail readiness；
- 新链路真实验收后移除旧 bridge 的主动引用、`VR_BRIDGE_*` 运行配置、TTS-only cache
  resolver 和 TTS-only dependency；会议侧仍保留其需要的模型下载和运行时；
- 保留一个发布周期的 endpoint/client 回滚配置；确认回滚窗口结束后再删除兼容代码。

每个 Phase 都应有独立提交、测试证据和可逆配置。任何一个阶段失败，都先回退该阶段，
不得在两个项目中留下双重 TTS owner。

## 7. 回滚策略

- 代码回滚以两个仓库的原子提交为单位；SpeechRail 和 `voice-realtime` 的切换提交必须
  记录对应关系，避免只回滚消费者而请求仍指向新 endpoint；
- 发布期间通过 `SPEECHRAIL_TTS_REST_URL`、`SPEECHRAIL_TTS_REALTIME_URL` 和旧 bridge
  compatibility flag 选择 provider；默认值切回旧 bridge 即可恢复语音助手，不改模型文件；
- 新 worker 或真实模型异常时，健康探针必须让 voice-realtime 停止把新请求送入未 ready
  服务；已有播放只由应用侧按 interrupt/cleanup 策略处理；
- 不删除旧模型 snapshot，不覆盖用户未提交改动，不在回滚中执行下载或全局 cache 清理；
- 只有新链路通过发布周期验收后，才允许删除旧 bridge 文件和 TTS-only dependency。

## 8. 验收门

### 8.1 SpeechRail

- 单元/集成：四个 voice profile、文本清洗、标点补全、动态 token 上限、NaN/静音裁剪、
  fade/PCM16/WAV、采样率校验和稳定错误；
- REST：鉴权、request ID、`/v1/models`、`/v1/voices`、PCM/WAV 非空且可解析、非法
  model/voice/format、输入上限和 worker 未 ready；
- v2：合法/非法事件顺序、append/flush/commit、response sequence、按 response ID cancel、
  cancel 后无新 delta、commit 后唯一 session.completed、session.cancel、背压和资源释放；
- worker：handshake、真实 MLX VoiceDesign output、异常退出、重启、旧 generation 隔离、
  无网络下载和无原文/音频日志；
- 项目门禁：focused tests、full pytest、`ruff check`、`mypy`、OpenAPI validation 和
  Realtime contract validation。

### 8.2 `voice-realtime`

- shared transport：握手、鉴权、envelope、sequence、超时、关闭和 server error 映射；
- Pipecat adapter：文本 clause 到 v2 events、audio delta 到 `TTSAudioRawFrame`、24 kHz
  元数据、cancel/cleanup、迟到 chunk 丢弃和 observer 状态；
- pipeline：LM Studio 输出能驱动实时音频，打断后不继续播放旧 response，ASR/meeting
  链路不回归；
- UI：voice list、试听、重播、服务状态、控制 voice 和断线错误都指向 SpeechRail；
- 运行：`run-all` 不拉起旧 bridge，外部 SpeechRail 未 ready 时诊断明确；
- 项目门禁：backend pytest、`mypy`、`ruff check`、UI test/build，以及旧 bridge 主动引用
  的精确搜索结果。

### 8.3 真实本机闭环

在已存在且已授权的 MLX 模型 snapshot 和配置好的 TTS worker Python 环境下执行：

```text
SpeechRail ready
  → REST /v1/voices
  → REST /v1/audio/speech (pcm + wav)
  → v2 session.update/append/flush/commit
  → response.audio.delta
  → voice-realtime Pipecat frame
  → AudioHub/playback
  → response.cancel / playback interrupt
```

必须同时验证短文本、中文标点、四个 preset 至少各一次、连续两句、取消和恢复；记录
模型逻辑 ID、backend/runtime、首个 audio chunk、RTF、峰值内存、输出采样率和播放结果。
如果本机缺少可运行的 MLX 依赖或 snapshot，必须把该项标为未完成，不以 fake backend
测试代替真实模型闭环，也不得擅自下载模型。

## 9. 已知取舍和待审阅事项

1. 当前已接受的 `2026-08-31-speechrail-asr-tts-runtime-design.md` 曾写入
   `speechrail/tts-default-zh`；当前代码、示例配置和本规格统一使用
   `speechrail/qwen3-tts`。实施前应把旧规格补一条更正记录，而不是同时支持两个公共
   logical ID。
2. 原 bridge 使用可中断的后台生成线程，但底层 MLX 调用未必立即响应 stop event；本规格
   要求 supervisor 隔离迟到 output，必要时重启 worker，并把取消延迟作为可观测指标。
3. v2 是生产实时链路，REST 只承担试听/重播/诊断兼容；若未来需要批量 TTS，应新增 job
   resource，不把长文本聚合到实时 WebSocket 或无界 REST 内存。
4. voice profile 的文字描述属于产品契约，后续若要新增 voice 必须 additive 地加入
   registry、契约、UI 和验收，不修改既有 voice 的含义。

本规格与 [SpeechRail 公共 ASR/TTS 运行时设计](2026-08-31-speechrail-asr-tts-runtime-design.md)、
[OpenAPI 契约](../../../contracts/openapi.yaml)、[Realtime v2 契约](../../../contracts/realtime-v2.md)
和 [ADR-0006](../../decisions/0006-public-asr-tts-runtime.md) 配套使用。规格审阅通过后，
按阶段创建实施计划；实现完成前不得把本文件的目标状态当作当前运行状态。
