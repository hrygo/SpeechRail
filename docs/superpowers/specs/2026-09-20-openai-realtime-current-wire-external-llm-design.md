---
title: "OpenAI Realtime current wire 与外部 LLM 设计"
status: superseded
date: 2026-09-20
superseded_by: docs/decisions/0019-stateless-speech-plane-caller-orchestration.md
---

# OpenAI Realtime current wire 与外部 LLM 设计

> **已废止（2026-09-20）**：本文档在实施前被 ADR-0019 取代。不要按本文档增加
> 服务端外部 LLM、conversation history 或 provider port；请改读
> [无状态 Speech Plane 与调用方编排设计](2026-09-20-stateless-speech-plane-caller-orchestration-design.md)。

## 目标

将 SpeechRail `/v1/realtime` 从 legacy/current 混合的 ASR/TTS 子集，收敛成一个可验证的
当前 OpenAI Realtime wire，并提供可选的服务侧外部 LLM，使标准客户端可以完成：

```text
audio input → realtime ASR → conversation item → external LLM → text/audio output
```

本设计不承诺旧版 SpeechRail Realtime 事件兼容，也不把 SpeechRail 的私有扩展伪装成
OpenAI 标准能力。

## SpeechRail 自有能力保留边界

Realtime wire 重整不删除、不迁移、不弱化以下已有能力：

| 能力 | 保留入口/边界 | 本次影响 |
|---|---|---|
| 音色列表、详情、metadata CRUD | `/v1/voices*` | 不改 REST schema；继续返回实际档位与可用性 |
| VoiceDesign | `/v1/voices/designs`、`/v1/voices/previews` | 不改质量档门禁、seed、preview 和注册语义 |
| Base reference clone | `/v1/voices/clone*` | 不改参考音频不可变、quality gate、`speed=1.0` 约束 |
| 音色绑定 | `resolve_binding` 与 TTS capability router | Realtime 仍按当前 session voice 解析实际 variant/worker |
| voice revision | render receipt / TTS request pin | 继续用于响应级身份和可回溯性，不进入标准 OpenAI wire |
| SpeechRail 扩展 | `speechrail.*` namespaced fields/events | 继续 opt-in；标准 SDK 应忽略未使用的扩展 |

这意味着“删除 legacy wire”不等于删除 SpeechRail 音色能力；删除对象仅是旧版 OpenAI
事件/字段和重复的协议分支。

## 非目标

- 不引入第二个 `/v2/realtime` 公共入口。
- 不在服务内置或下载 LLM 权重。
- 首版不实现 tools、image、WebRTC、semantic VAD 或多模态输入。
- 不把外部 LLM 的完整 prompt、原始音频、API key 或完整转写写入日志。
- 不用单元测试结果代替官方 SDK 的真实 WebSocket 验证。

## 当前 wire 范围

### 会话

服务只接受当前嵌套形状：

```json
{
  "type": "session.update",
  "session": {
    "type": "realtime",
    "model": "gpt-realtime",
    "output_modalities": ["audio"],
    "audio": {
      "input": {
        "format": {"type": "audio/pcm", "rate": 24000},
        "turn_detection": {"type": "server_vad"}
      },
      "output": {
        "format": {"type": "audio/pcm"},
        "voice": "alloy"
      }
    }
  }
}
```

`type="transcription"` 只启用 ASR，不创建语言模型 response。旧 flat 字段如
`modalities`、`input_audio_format`、`output_audio_format` 和旧 TTS transcript event
不再作为公共输入/输出。

### 事件生命周期

首版必须保证每条生命周期内部有序，但不能把 ASR completed 与 response 事件强行排成一条
全局序列。OpenAI SDK 类型明确允许输入音频转写异步完成，`conversation.item.input_audio_transcription.completed`
可以早于或晚于 response 事件到达；客户端必须按 `item_id`、`response_id` 和事件类型分别收敛。

会话启动顺序：

```text
session.created
conversation.created
session.updated
```

输入 item 顺序：

```text
input_audio_buffer.committed
conversation.item.added
conversation.item.input_audio_transcription.delta/*
conversation.item.input_audio_transcription.completed|failed
conversation.item.done
```

Response 顺序：

```text
response.created
response.output_item.added
response.content_part.added
response.output_audio_transcript.delta/done   # audio modality
response.output_audio.delta/done              # audio modality
response.output_text.delta/done               # text modality
response.content_part.done
response.output_item.done
response.done
```

空 commit 仍然完成确定性空 item 闭环；错误必须通过统一 `error` envelope 返回，且不能
把外部 provider 的原始异常文本暴露给客户端。

### 能力边界

| 能力 | 首版状态 | 行为 |
|---|---|---|
| `type="transcription"` | 支持 | ASR completed/failed，不调用 LLM |
| `type="realtime"` + `output_modalities=["text"]` | 支持 | 外部 LLM 文本流 |
| `type="realtime"` + `output_modalities=["audio"]` | 支持 | 外部 LLM 文本流经句子 planner 后进入 TTS |
| `manual` turn detection | 支持 | 由客户端 commit/response.create 驱动 |
| `server_vad` | 支持 | 使用现有 SpeechAdmission/VAD 语义 |
| `semantic_vad` | 首版不支持 | 返回稳定 unsupported，不映射成 server VAD |
| tools/image/WebRTC | 首版不支持 | 返回稳定 unsupported |

音频 response 的 voice 选择仍由 SpeechRail voice catalog、档位能力和 `resolve_binding`
决定；外部 LLM 只生成文本，不拥有音色资产，也不能绕过 clone/VoiceDesign 的能力门禁。

## 外部 LLM 接口

新增 vendor-neutral port，建议保持在独立模块中：

```python
@dataclass(frozen=True, slots=True)
class RealtimeMessage:
    role: Literal["system", "user", "assistant"]
    text: str


@dataclass(frozen=True, slots=True)
class RealtimeLLMRequest:
    response_id: str
    model: str
    instructions: str
    conversation: tuple[RealtimeMessage, ...]
    output_modality: Literal["text", "audio"]


@dataclass(frozen=True, slots=True)
class RealtimeLLMDelta:
    response_id: str
    text: str


@dataclass(frozen=True, slots=True)
class ProviderReadiness:
    ready: bool
    code: str
    model: str | None
```

The port is:

```python
class RealtimeLanguageModel(Protocol):
    async def stream(
        self, request: RealtimeLLMRequest
    ) -> AsyncIterator[RealtimeLLMDelta]: ...

    async def cancel(self, response_id: str) -> None: ...

    def readiness(self) -> ProviderReadiness: ...
```

`RealtimeLLMRequest` 只包含已验证的文本 conversation、instructions、外部 model、
response ID 和输出 modality；不包含 PCM。Responses adapter 必须验证每个 SSE JSON，
只消费 `response.output_text.delta`、终态和错误事件。

服务配置只保存 provider、base URL、model、secret reference 和 timeout 等非秘密元数据；
secret value 由 composition 层解析，不能进入 Settings repr、日志或 capability snapshot。

## 兼容性验收

兼容性采用三层证据：

1. Python contract tests：验证 schema、状态机、错误和 fake provider。
2. Loopback integration：用 fake ASR、fake LLM、fake TTS 启动真实 ASGI WebSocket 服务。
3. Official SDK black box：使用 `openai-node@7.19.0` 的 `OpenAIRealtimeWebSocket`，连接
   loopback 服务，验证官方 SDK 可以发送事件、接收并解析事件、完成文本和音频 response。

SDK harness 必须覆盖：

- current nested `session.update`；
- text item + `response.create`；
- PCM append/commit → transcription completed；
- audio response 的 transcript/audio delta；
- `response.cancel` 后收到 cancelled response；
- provider 未配置和非法事件的 error event；
- 未出现 legacy event 名称；
- response.done 的 output/status 非空且可被官方 SDK 事件类型消费。

默认 `npm test` 只跑无网络、无真实模型的 deterministic SDK encoding/contract tests；
`npm run test:realtime` 必须显式指定 loopback base URL 和 key，缺少环境时失败而不是 skip。

## 持续校准

每一轮实现都更新同一份证据矩阵，字段固定为：

```text
surface | declared | unit-tested | fake-loopback | official-sdk | real-runtime | known-gap
```

任何一项从 `declared` 变为 `supported` 前，必须补对应测试和实际输出样本；OpenAI 文档或
官方 SDK 事件类型变化时，先更新矩阵和设计，再改代码。未通过 SDK 黑盒门禁时，文档只能称为
“OpenAI-compatible subset under test”，不能称为“OpenAI SDK compatible”。
