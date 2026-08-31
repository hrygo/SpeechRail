---
title: "SpeechRail 总体架构"
status: active
version: "0.1.0"
date: 2026-08-31
---

# SpeechRail 总体架构

## 1. 目标拓扑

```text
┌──────────────┐    REST / OpenAI SDK       ┌─────────────────────────────┐
│ QwenPaw      │ ─────────────────────────► │                             │
├──────────────┤                            │         SpeechRail           │
│ Hermes Agent │ ─────────────────────────► │  API + session + queue       │
├──────────────┤    Realtime / legacy WS   │       │                       │
│ voice-       │ ─────────────────────────► │       ├─ batch adapter         │
│ realtime     │                            │       ├─ realtime adapter      │
└──────────────┘                            │       └─ legacy WLK adapter    │
                                            └──────────────┬────────────────┘
                                                           │
                             ┌─────────────────────────────┴────────────────┐
                             │                                               │
                    Qwen3 native worker                         WLK Qwen3 streaming
                    batch / MPS / isolated                       windowed / MPS / partial
```

两条运行时路径共享模型 profile、能力、队列、错误和观测契约；它们不共享 vendor
JSON。批量请求优先使用隔离 Qwen3 worker，实时请求优先使用当前已验证的 WLK
Qwen3 streaming 路径。模型管理器可以懒加载其中一个或两个 runtime，并由全局准入器
限制资源争用。

## 2. 分层结构

```text
speechrail/
├── api/                 # REST、Realtime、legacy WLK 入口
├── domain/              # Transcript、Segment、Capability、Error 等纯领域类型
├── runtime/             # worker lifecycle、queue、health、resource admission
├── backends/            # Qwen3 native、WLK streaming 等 adapter
├── compatibility/       # OpenAI response、Realtime events、WLK serializer
├── config/              # Pydantic settings 和判别 profile
└── observability/       # request id、metrics、redacted audit records
```

层间依赖只向内：

```text
API ─► compatibility ─► domain ◄─ backends ─► runtime
  └──────────────────────────────► observability
```

`domain` 不得导入 `voice_realtime`、FastAPI、OpenAI SDK 或 Qwen SDK。

## 3. 领域对象

### TranscriptSegment

```python
@dataclass(frozen=True, slots=True)
class TranscriptSegment:
    id: str
    start_ms: int
    end_ms: int
    text: str
    language: str | None
    speaker: str | None
```

约束：`0 <= start_ms <= end_ms`；文本非空；未获得真实词时间戳时不得插值后伪装成
word-level accuracy。

### TranscriptWindow

```python
@dataclass(frozen=True, slots=True)
class TranscriptWindow:
    session_id: str
    source_epoch: int
    partial: str
    segments: tuple[TranscriptSegment, ...]
```

`segments` 是当前窗口的 confirmed 历史，`partial` 是易失尾部。上层可以用
`source_epoch + segment.id` 做幂等去重；SpeechRail 不负责会议数据库入库。

### BackendCapabilities

```python
@dataclass(frozen=True, slots=True)
class BackendCapabilities:
    languages: frozenset[str]
    supports_partial: bool
    supports_segment_timestamps: bool
    supports_word_timestamps: bool
    supports_hotwords: bool
    supports_speaker_labels: bool
    supports_eof_flush: bool
```

任何 API 响应中出现的能力都必须来自 profile/adapter 的真实声明；不支持的能力返回
`unsupported` 或明确错误，不能用推断值填充。

## 4. 请求生命周期

### REST

```text
上传请求
  │
  ├─ 认证 / request id / multipart 校验
  ├─ 临时文件写入（大小有界，完成后删除）
  ├─ 音频解码到 16 kHz mono PCM
  ├─ batch admission queue
  ├─ Qwen3 native adapter.transcribe()
  ├─ 领域结果 → OpenAI response formatter
  └─ 返回并释放临时资源
```

### Realtime

```text
WebSocket open
  ├─ create session + validate format
  ├─ receive append / PCM frames
  ├─ bounded audio queue → realtime adapter
  ├─ emit delta events
  ├─ commit → EOF flush → completed event
  └─ close session + release queue
```

### legacy `/asr`

```text
connect → {type: config}
       → binary PCM chunks
       → {lines, buffer_transcription}
       → empty binary frame
       → {type: ready_to_stop}
```

该协议只存在于 `compatibility/wlk.py`；核心领域层不产生 WLK `FrontData`。

## 5. 并发与资源模型

- 默认单个 ASR runtime 一个推理槽位；HTTP 并发请求进入有界队列。
- 实时会话按 session FIFO 读取音频；单 session 的 chunk 顺序不可重排。
- REST 默认可排队，超出队列返回 `429 queue_full`；实时连接超出容量直接返回
  `1013`/协议错误，不让音频无限堆积。
- batch 与 realtime 使用共享 `InferenceAdmission`。实时请求优先级高于批量请求，
  但不抢占已经进入模型调用的 batch。
- 只运行一个 Uvicorn worker。需要多实例时必须显式分配不同模型/端口并重新评估
  统一队列和内存。
- `parallel=1` 是本机首发配置；吞吐优化必须以真实模型 smoke + latency/RTF
  数据为依据，不能只提高 HTTP worker 数。

## 6. 配置与模型分离

```text
环境变量 / 配置文件
  ├─ 服务监听、认证、CORS、限额
  ├─ active profile = qwen3-asr-1.7b
  ├─ batch runtime = qwen3-native / mps
  └─ realtime runtime = wlk-qwen3-streaming / mps

外部模型缓存
  ├─ Qwen/Qwen3-ASR-1.7B snapshot
  └─ WhisperLiveKit vendor checkout / venv
```

模型权重和 vendor checkout 不进仓库，不放到请求体，不在请求期间下载。配置只接收
绝对路径，并在启动 preflight 时核对文件完整性和 runtime identity。

## 7. 失败与恢复

| 失败点 | 行为 |
|---|---|
| 模型快照缺失 | 服务启动保持 not ready；不隐式下载 |
| runtime 加载失败 | `/readyz` 返回 503；记录脱敏错误和指纹 |
| 单次音频非法 | 400/422；不影响其他 session |
| 队列已满 | 429，带 `Retry-After`；不丢已接受的 session |
| 推理超时 | 408/504；释放 worker；必要时熔断并重新 preflight |
| realtime 断线 | 释放该 session；客户端按 request/session 策略重连 |
| legacy WLK 序列化失败 | 发送兼容 error，禁止把 vendor traceback 发给客户端 |
| 迁移切换失败 | 不提交 active profile，恢复旧服务 URL/端口 |

## 8. 进程与所有权

SpeechRail 的 supervisor 管理自身的 API 和模型 worker。`voice-realtime` 仍管理
自己的 UI、AudioHub、会议、TTS 和 LM Studio；它只作为 SpeechRail 的客户端。

切换完成前可以采用：

```text
旧 WLK :8001  ──► voice-realtime / QwenPaw（回退）
SpeechRail :8201 ──► Hermes / QwenPaw shadow smoke
```

切换后：

```text
SpeechRail :8001 ──► QwenPaw + voice-realtime legacy /asr
SpeechRail :8201 ──► 新客户端或 staging
```

同一端口不允许两个 supervisor 同时监听。
