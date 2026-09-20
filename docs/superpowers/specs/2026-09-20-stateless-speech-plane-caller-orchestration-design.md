---
title: "无状态 Speech Plane 与调用方助手编排设计"
status: approved
date: 2026-09-20
decision: docs/decisions/0019-stateless-speech-plane-caller-orchestration.md
supersedes:
  - docs/superpowers/specs/2026-09-20-openai-realtime-current-wire-external-llm-design.md
  - docs/decisions/0018-realtime-current-wire-external-llm.md
---

# 无状态 Speech Plane 与调用方助手编排设计

## 1. 设计结论

SpeechRail 是本机共享的无状态 Speech Plane，不是语音助手 runtime。
它提供 ASR、VAD、匿名分人、TTS 和可靠的实时音频交付；调用方负责 LLM、对话、工具、
记忆、业务决策、播放和持久化。

本设计是一次 current-only contract reset：当前没有外部用户，因此不保留任何旧版本
事件、旧字段、旧 TTS 语义、兼容 alias 或隐式降级路径。

## 2. 目标与非目标

### 目标

1. 让 `/v1/realtime` 只表达 SpeechRail 实际提供的能力。
2. 用当前 OpenAI transcription session wire 接收音频和输出转写。
3. 用清晰的 `speechrail.tts.*` 命名空间接收调用方生成的文本并返回流式音频。
4. 保留现有 sequence、clear barrier、receipt、voice revision、资源准入和错误 envelope。
5. 让 Native、REST、MCP 和文档在同一 release 中形成闭环。

### 非目标

- 不在服务端运行任何 LLM 或 external provider。
- 不在服务端保存 conversation、prompt、memory、tool registry 或用户身份。
- 不实现完整 OpenAI Realtime Conversation、tool calling、image、WebRTC 或 semantic VAD。
- 不提供旧协议 alias、不维护 legacy/current 双 wire、不增加 `/v2/realtime`。
- 不让 MCP 代理持续 WebSocket 或保存音频流。
- 不改变 `/v1/audio/*`、`/v1/voices*` 已有的独立 REST 责任，除非能力字段需要同步。

## 3. 责任矩阵

| 能力 | SpeechRail | 调用方 / Native | MCP proxy |
|---|---|---|---|
| 麦克风采集 | 不负责 | 负责 | 不负责 |
| 音频播放 / AEC | 不负责 | 负责 | 不负责 |
| PCM 解码、VAD、ASR | 负责 | 消费事件 | 请求级转写 |
| 匿名分人 | 负责 | 映射到业务语义 | `diarize` 请求 |
| TTS render | 负责 | 提交文本、播放结果 | 请求级合成 |
| LLM / prompt / history | 不负责 | 负责 | MCP 客户端负责 |
| tool calling / memory | 不负责 | 负责 | MCP 客户端负责 |
| barge-in 决策 | 提供 VAD 事实和显式 cancel | 负责策略 | 不负责 |
| 资源准入和 worker 生命周期 | 负责 | 退避 / 重连 | 映射稳定错误 |
| Realtime WebSocket | 提供 endpoint | 直连 | 不持有 |

## 4. Realtime 公共契约

### 4.1 连接语义

唯一入口为：

```text
WS /v1/realtime
```

握手完成后服务端发送 `session.created`，声明 `type="transcription"` 和实际 ASR/VAD/
diarization/TTS capability。连接只拥有 session-scoped ephemeral state；断线后不得恢复
旧 item、旧 response 或旧 sequence。

当前 OpenAI transcription session 的客户端配置使用专用转写 session wire：

```json
{
  "type": "transcription_session.update",
  "session": {
    "input_audio_format": "pcm16",
    "input_audio_transcription": {
      "model": "speechrail/qwen3-asr-1.7b",
      "language": "zh"
    },
    "turn_detection": {
      "type": "server_vad",
      "threshold": 0.5,
      "prefix_padding_ms": 300,
      "silence_duration_ms": 400
    },
    "speechrail": {
      "tts": {"enabled": true}
    }
  }
}
```

字段以当前官方 Realtime transcription reference 与项目 contract fixture 为准；未列入
fixture 的字段必须返回稳定 `invalid_request` 或 `unsupported_operation`，不得静默接受。
参考：[OpenAI Realtime transcription session client events](https://platform.openai.com/docs/api-reference/realtime-beta-client-events/transcription_session/update?lang=python)。

### 4.2 ASR 客户端事件

| 事件 | 语义 |
|---|---|
| `transcription_session.update` | 在首个 PCM 前原子更新转写 session 配置 |
| `input_audio_buffer.append` | 追加 Base64 PCM16 音频 |
| `input_audio_buffer.commit` | 提交当前 buffer 并产生转写 item |
| `input_audio_buffer.clear` | 清理未提交 buffer，并返回 clear barrier |
| `speechrail.tts.create` | 用调用方文本创建一个 TTS render response |
| `speechrail.tts.cancel` | 取消指定的 TTS render response |

不得接受以下事件作为 SpeechRail TTS 入口：

- `conversation.item.create`
- `response.create`
- `response.cancel`
- 旧的 `response.audio.*` 语义

### 4.3 ASR 服务端事件

服务端使用当前转写事件生命周期，并继续携带 SpeechRail 的顶层 `event_id`、`session_id`、
`sequence`：

```text
session.created
transcription_session.updated
input_audio_buffer.speech_started
input_audio_buffer.speech_stopped
input_audio_buffer.committed
conversation.item.input_audio_transcription.delta/*
conversation.item.input_audio_transcription.completed|failed
input_audio_buffer.cleared
error
```

转写 completed 与 TTS response 可以异步到达；客户端按 `item_id` 和 `response_id` 分别
收敛，不能假设所有 ASR 与 TTS 事件共享一个业务顺序。

### 4.4 TTS 请求和响应

`speechrail.tts.create` 输入：

| 字段 | 类型 | 约束 |
|---|---|---|
| `request_id` | string | 调用方生成；连接内唯一 |
| `text` | string | 非空，最多 4096 字符；服务端按现有 bounded planner 处理 |
| `voice` | string? | `/v1/voices` 中 `available=true` 的 voice |
| `speed` | number? | `0.25..4.0` |
| `expected_voice_revision` | string? | 用于防止音色目录变化导致错误绑定 |

每个连接同一时刻只允许一个 active TTS response。调用方需要排队时，由调用方维护队列。
服务端不保存下一句文本，不把多个请求拼成 conversation。

服务端输出：

```text
response.created
response.output_item.added
response.content_part.added
response.output_audio_transcript.delta/*
response.output_audio_transcript.done
response.output_audio.delta/*
response.output_audio.done
response.content_part.done
response.output_item.done
response.done
```

每个 TTS response 都包含：

```json
{
  "speechrail": {
    "kind": "tts",
    "orchestration": "caller",
    "request_id": "tts_req_001",
    "voice_revision": "vr_..."
  }
}
```

`response.output_audio_transcript.*` 是对调用方输入文本的交付回显，不是服务端 LLM 输出。
`response.done` 必须是唯一终态，并携带 `completed`、`cancelled` 或 `failed` 状态以及可选
的 `speechrail.render_receipt`。

### 4.5 取消和清理

`speechrail.tts.cancel` 必须：

1. 通过独立控制通道先阻止未发送的旧音频；
2. 取消 planner、TTS worker 和待发送队列；
3. 最多发送一个 `response.done(status="cancelled")`；
4. 释放 admission / worker lane；
5. 允许调用方立即开始下一次 `speechrail.tts.create`。

WebSocket disconnect、server timeout、backend failure 也必须收敛到同一个 finalizer，
但连接关闭时不再发送无法交付的终态事件。

### 4.6 稳定错误

所有错误使用现有 error envelope 并带 `request_id`：

| code | 触发条件 |
|---|---|
| `invalid_event` | JSON 或事件结构非法 |
| `unsupported_operation` | conversation、tools、旧 TTS 事件等不支持能力 |
| `tts_not_enabled` | session 未协商 caller TTS |
| `tts_request_invalid` | 文本、voice、speed 或 revision 不合法 |
| `tts_in_progress` | 同连接已有 active response |
| `tts_not_active` | cancel 目标不存在 |
| `voice_not_found` / `voice_not_available` | 音色不存在或档位不可用 |
| `backend_busy` / `queue_full` | 资源准入失败，可按 `retryable` 处理 |
| `backend_timeout` | 总 deadline 超时 |

服务端不得返回 provider、内部路径、完整 prompt、完整 transcript 或模型异常正文。

## 5. 服务端实现边界

### `compatibility`

`src/speechrail/compatibility/openai_realtime.py` 只负责：

- current transcription event 解析；
- `speechrail.tts.*` 输入校验；
- current server event 构造；
- error envelope 和字段级拒绝。

不再保留 `wire_profile`、legacy event builder 或旧 TTS event parser。

### `application`

`src/speechrail/application/realtime_openai.py` 只维护连接级 ephemeral state：

- ASR turn state；
- 当前 TTS response；
- cancel/finalizer；
- receipt、sequence 和 clear barrier。

不得出现 conversation list、LLM provider、prompt history 或跨 request 文本缓存。

### `runtime / capability`

能力快照只发布 ASR、TTS、VAD、diarization、voice、receipt 和 caller orchestration。
不得发布 server-side LLM readiness、provider model 或 provider configuration。

## 6. Native 设计

`RealtimeASRClient` 负责：

- 建立 current transcription session；
- 发送 PCM 和 commit/clear；
- 解析 ASR item；
- 发送 `speechrail.tts.create/cancel`；
- 消费 TTS audio delta、receipt、done 和 error。

`AssistantSession` 负责：

- 调用 `LLMProvider`；
- 保存本地 history / memory；
- 句子切分和 TTS 请求队列；
- 根据用户打断决定何时发送 cancel；
- 播放音频和管理 UI 状态。

不改动采集 helper 的隐私约束：PCM 不落盘，功能退出释放 capture/tap/audio engine。

## 7. MCP 设计

保留当前 9 个工具和 3 个只读资源，不新增 Realtime WebSocket handle。

需要同步：

- `DescribeResult.realtime` 增加 `orchestration=caller`、`server_llm=false`、
  `conversation_state=false`；
- `_INSTRUCTIONS` 明确实时音频直连 `/v1/realtime`；
- `speechrail-mcp` 不宣称可以提供完整语音助手；
- `docs/users/mcp-agent-integration.md` 增加 caller-owned flow。

MCP 仍然只通过 REST 读取能力和调用请求级 ASR/TTS/job；不会承载 PCM 流、播放或会话记忆。

## 8. 文档交付

必须同步：

- `contracts/realtime-openai.md`：更新为实施后的 current-only 契约；
- `docs/architecture/architecture.md`：更新拓扑和责任矩阵；
- `docs/architecture/current-boundaries.md`：删除服务端 LLM 规划性承诺；
- `docs/architecture/speechrail-mcp-proxy.md`：保持 MCP 无状态边界；
- `docs/users/integrations.md`：增加 caller ASR → LLM → TTS 流程；
- `docs/users/mcp-agent-integration.md`：更新 MCP 与 Realtime 分工；
- Native 开发文档：说明 `AssistantSession` 是 LLM owner；
- 原 external LLM spec/plan：保留历史并标记 superseded。

## 9. 验收和证据

必须分层记录：

```text
surface | declared | unit-tested | fake-loopback | native-contract | real-runtime | known-gap
```

最低验收：

1. Python parser/state tests 证明旧事件全部拒绝。
2. fake loopback 证明 ASR、TTS、cancel、clear、receipt 和 voice revision 闭环。
3. Swift pure contract tests 证明 Native 发送新事件并保留本地 LLM owner。
4. MCP tests 证明工具 schema、能力发现和 direct-WebSocket 文案一致。
5. `git diff --check`、ruff、mypy、OpenAPI lint 和授权范围内的项目 gate 通过。
6. 不以 `/readyz=200` 或单次 smoke 代替模型质量、长时稳定性或 UI 验收。

## 10. 发布、回滚和安全

这是 breaking release：服务端、Native、MCP 和文档必须作为一个 release 发布。
由于没有用户，不设置 alias 观察期、不双写、不通过 version probe 做兼容。

回滚只能整体回到上一个已知 release，不允许让新服务端和旧客户端通过“兼容模式”混跑。
本次设计不引入数据库迁移、模型下载、外部 secret 或新的运行态服务。

