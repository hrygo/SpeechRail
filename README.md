# SpeechRail

SpeechRail（声轨）是一个独立的、本地优先共享语音识别服务：用一个稳定的
API 把 Qwen3-ASR 1.7B 提供给 QwenPaw、`voice-realtime`、Hermes Agent 及其他
应用。服务名称、仓库名称和 API 契约不绑定某个客户端或模型供应商；模型运行时
可以在不改客户端的情况下替换。

> 当前状态：`0.1.0` foundation。项目已经落盘完整架构、API 契约、迁移方案、
> 接入文档和安全失败的 FastAPI 契约壳；Qwen3-ASR 推理适配器尚未从
> `voice-realtime` 迁入，因此默认转写会返回 `backend_not_ready`。这一步是有意的，
> 用来先冻结跨应用接口，再做模型迁移。

## 目标拓扑

```text
QwenPaw ───────────────┐
voice-realtime ────────┼──► SpeechRail ──► Qwen3-ASR 1.7B / MPS
Hermes Agent ──────────┘       │
                               ├─ POST /v1/audio/transcriptions
                               ├─ WS   /v1/realtime
                               └─ WS   /asr  (voice-realtime 兼容层)
```

SpeechRail 吸收 `voice-realtime` 的 ASR 能力，不吸收整个应用：

- 吸收：ASR 领域契约、Qwen3 隔离 worker、WhisperLiveKit 适配/规范化、
  能力 profile、ASR benchmark manifest 与回放思路。
- 保留在 `voice-realtime`：`AudioHub` 单一麦克风所有权、`SubtitleProxy` 的
  会议/字幕会话协调、会议状态机、Sortformer、PostgreSQL、UI、TTS 和 LM Studio
  原生聊天链路。
- 兼容：短期保留 WLK 风格 `/asr` full snapshot + 空 PCM EOF；新应用使用
  OpenAI-compatible REST 或 `/v1/realtime`。

## 当前端口策略

| 用途 | 地址 | 说明 |
|---|---|---|
| SpeechRail foundation | `127.0.0.1:8201` | 与现有 `voice-realtime` WLK `8001` 并行开发，避免抢端口 |
| 迁移后的兼容入口 | `127.0.0.1:8001` | 停止旧 WLK 后再切换，便于 QwenPaw 少改配置 |
| voice-realtime UI | `127.0.0.1:8100` | 仍由原项目拥有 |
| voice-realtime TTS bridge | `127.0.0.1:8765` | 仍由原项目拥有 |

## Quick start（foundation）

```bash
cd /Users/hrygo/Documents/SpeechRail
uv sync --extra dev
uv run speechrail
```

健康检查：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
```

模型推理启用后，客户端只需要把 base URL 指向：

```text
http://127.0.0.1:8201/v1
```

## 文档导航

- [项目总览与范围](docs/00-product-scope.md)
- [总体架构与数据流](docs/01-architecture.md)
- [公共 API 契约](docs/02-api-contract.md)
- [吸收 voice-realtime 方案](docs/03-voice-realtime-absorption.md)
- [QwenPaw / voice-realtime / Hermes 接入](docs/04-integrations.md)
- [运行时、模型与部署](docs/05-runtime-deployment.md)
- [安全、队列与可观测性](docs/06-security-observability.md)
- [测试与验收门禁](docs/07-testing-acceptance.md)
- [分阶段迁移 Runbook](docs/08-migration-runbook.md)
- [当前已知边界](docs/09-open-questions.md)
- [OpenAPI 3.1](contracts/openapi.yaml)
- [ADR 索引](docs/decisions/README.md)
- [设计规格](docs/superpowers/specs/2026-08-31-speechrail-design.md)
- [实施计划](docs/superpowers/plans/2026-08-31-speechrail-foundation.md)

## 外部契约依据

- [OpenAI Audio Transcriptions API](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)
- [OpenAI Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [Qwen3-ASR 官方仓库](https://github.com/QwenLM/Qwen3-ASR)
- [Hermes Agent transcription tools](https://github.com/NousResearch/hermes-agent/blob/main/tools/transcription_tools.py)

## 版本与兼容承诺

- `0.x`：允许实现快速迭代，但公共 API 仍按兼容优先设计。
- `1.0`：REST、Realtime 和 legacy `/asr` 的稳定行为冻结。
- 模型别名（如 `Qwen3-ASR-1.7B`、`whisper-1`）只用于迁移兼容，服务内部统一使用
  `speechrail/qwen3-asr-1.7b`。
- `whisper-1` 兼容别名不得在产品文档中冒充实际模型；新配置必须使用
  `speechrail/qwen3-asr-1.7b`。
