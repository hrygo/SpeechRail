# ADR-0019：无状态 Speech Plane 与调用方助手编排

## Status

Accepted

## Date

2026-09-20

## Context

SpeechRail 的产品边界是单机共享 ASR/TTS 基础设施，而不是一个通用 Agent runtime。
当前 macOS App 已经在调用方持有 `LLMProvider`、会话历史、persona、memory 和播放策略；
服务端只需要提供音频采集后的转写、语音合成、VAD、匿名分人、资源准入和可验证的流式交付。

前一份 ADR-0018 试图把 `/v1/realtime` 扩展成“current wire + 服务端可插拔外部 LLM”。
该方向会把 conversation history、prompt、provider、网络凭据和取消链路引入 SpeechRail，
扩大隐私边界和运行时复杂度，也与项目既有的应用所有权边界冲突。

当前没有需要保护的外部用户。可以在一个协调发布中直接重置 Realtime 公共契约，
不需要维护旧事件、旧字段或兼容 alias。

## Decision

### 1. SpeechRail 只实现无状态 Speech Plane

服务端负责：

- ASR、VAD、可选匿名分人；
- TTS render、音频流、取消、receipt、voice revision；
- worker 生命周期、资源准入、背压、鉴权和能力发现；
- REST、WebSocket 和 MCP 的协议适配。

服务端不负责：

- LLM、conversation history、prompt、persona、memory；
- tool calling、Agent loop、业务决策；
- 跨连接身份、持久化 PCM 或完整 prompt/transcript；
- 任何外部 LLM provider、provider key、provider base URL 或 provider 网络调用。

连接内允许存在短生命周期的音频 buffer、VAD 状态、ASR item、当前 TTS response、
sequence、clear barrier、receipt 和 voice revision；连接关闭后这些状态全部释放。

### 2. `/v1/realtime` 直接重置为 current-only 契约

- `/v1/realtime` 仍是唯一 Realtime 入口；不新增 `/v2/realtime`。
- 只接受当前 OpenAI transcription session wire 及明确的 `speechrail.*` 扩展。
- 删除 legacy/current 双分支、旧 flat 字段、旧事件名和旧 TTS 事件组合。
- 不提供 `conversation.item.create + response.create` 的 TTS 语义。
- 不提供 `response.cancel` 的兼容 alias；TTS 取消统一使用 `speechrail.tts.cancel`。
- 不提供任何旧客户端 fallback、旧版本 alias 或隐式协议降级。

### 3. 调用方通过命名空间 TTS 事件驱动合成

调用方先使用当前 transcription session 获取 ASR 结果，再自行调用 LLM，最后提交：

```json
{
  "type": "speechrail.tts.create",
  "request_id": "tts_req_001",
  "text": "你好，今天有什么可以帮你？",
  "voice": "serena",
  "speed": 1.0,
  "expected_voice_revision": "vr_..."
}
```

取消统一为：

```json
{
  "type": "speechrail.tts.cancel",
  "request_id": "tts_req_001",
  "response_id": "resp_001"
}
```

服务端可以复用 `response.created`、`response.output_item.*`、
`response.content_part.*`、`response.output_audio.*`、
`response.output_audio_transcript.*` 和 `response.done` 作为音频生命周期事件，
但必须增加 `speechrail.kind = "tts"` 和 `speechrail.orchestration = "caller"` 标识。
这些事件表示 TTS render，不表示服务端产生了 LLM response。

### 4. Native App 继续拥有复杂助手能力

`AssistantSession` 保留 `LLMProvider`、history、memory、persona、tool orchestration、
句子切分和播放队列。`RealtimeASRClient` 只负责把 ASR 音频和 caller-generated text
交给 SpeechRail，并消费音频事件、receipt、sequence 和 clear barrier。

Caption 和 Meeting 路径只启用 ASR，不自动启用 caller TTS。
barge-in 由 App 根据 VAD 事件和播放状态决定；服务端不自行推断业务意图。

### 5. MCP 保持独立、无状态的 REST proxy

`speechrail-mcp` 保留离线/请求级工具：能力发现、转写、合成、音色管理和 job。
MCP 不持有 Realtime WebSocket、不创建语音助手 session、不代理持续 PCM 流。
实时语音由调用方直连 `/v1/realtime`；复杂 Agent 能力由 MCP 客户端自身实现。

### 6. 同步发布而不是兼容迁移

服务端、Native、MCP、契约和文档在同一项工作中一起更新。旧协议不再接受，
因此不建立 alias、双读、双写、版本探测或隐式降级路径。
回滚以整体 release commit 为单位，不允许新服务端与旧 Native 混跑作为兼容策略。

## Alternatives Considered

### 服务端接入外部 LLM

- 优点：任意 Realtime 客户端可以直接获得完整 conversation。
- 缺点：引入 provider、网络、凭据、prompt、history、取消链路和隐私责任。
- 拒绝：这不是 SpeechRail 的职责，且调用方已经拥有该能力。

### 保留旧协议 alias

- 优点：降低迁移瞬时风险。
- 缺点：维护两套语义，继续把 TTS 伪装成 conversation，并阻碍协议收敛。
- 拒绝：当前没有用户，兼容收益为零。

### 新增 `/v2/realtime`

- 优点：可以同时保留旧 `/v1`。
- 缺点：增加入口和文档分叉，OpenAI 客户端需要额外 URL 配置。
- 拒绝：当前无用户，直接重置唯一入口更清晰。

### 通过 MCP 持有实时音频 session

- 优点：Agent 可以把实时能力看成工具。
- 缺点：MCP tool call 不适合长期双工 PCM、实时取消和播放生命周期。
- 拒绝：MCP 继续服务发现和请求级能力，Realtime 由调用方直连。

## Consequences

- 这是一次有意的破坏性 Realtime 契约重置，发布版本必须按项目版本策略体现 breaking change。
- `contracts/realtime-openai.md`、Native contract types、Python parser/state machine、MCP 文档和测试必须同步变更。
- 不再需要服务端 LLM port、provider adapter、provider secret 配置和 provider readiness。
- 调用方需要实现完整的 LLM/Agent orchestration，但这与现有 Native 架构一致。
- 服务端状态机更小、隐私边界更清晰、网络依赖更少，TTS/ASR 可以独立演进。
- 未经过官方当前 wire fixture、fake loopback 和 Native contract tests 的能力，不得写入当前契约。
