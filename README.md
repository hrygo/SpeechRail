# SpeechRail 🚂

<p align="center">
  <strong>在 Apple Silicon Mac 上运行的本地 ASR / TTS 服务，提供 OpenAI 兼容 API。</strong>
</p>

<p align="center">
  <a href="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml"><img src="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/hrygo/SpeechRail/releases"><img src="https://img.shields.io/github/v/release/hrygo/SpeechRail?label=release" alt="Release" /></a>
  <img src="https://img.shields.io/badge/Python-3.12-3776AB.svg?logo=python&logoColor=white" alt="Python 3.12" />
  <img src="https://img.shields.io/badge/macOS-Apple%20Silicon-000000.svg?logo=apple" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/API-OpenAI%20compatible-412991.svg?logo=openai&logoColor=white" alt="OpenAI compatible" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License" /></a>
</p>

SpeechRail 为桌面 Agent、会议工具和本地应用提供一个常驻语音入口。音频、模型和推理均留在本机；客户端通过标准 `whisper-1`、`tts-1` 和 `/v1/realtime` 接入，无需感知本机选择的性能档位。

## 为什么使用 SpeechRail

- **本地与私密**：默认只监听 `127.0.0.1:8201`，请求路径不下载模型，不保存源音频或完整转写。
- **OpenAI 兼容**：支持文件转写、语音合成和 Realtime ASR/TTS 子集，可直接使用 OpenAI SDK。
- **一套架构，三种资源档位**：档位只改变模型权重与量化组合，API、worker 协议和调度保持一致。
- **适合长期常驻**：模型进程隔离、有界队列、超时、背压和原子档位切换保护本机资源。
- **可观测、可回退**：公开健康、模型、音色和指标端点；wheel release 与 profile 切换均保留回退路径。

## 当前能力

| 能力 | 公共入口 | 状态与边界 |
|---|---|---|
| 文件 ASR | `POST /v1/audio/transcriptions` | OpenAI multipart；支持 `json`、`verbose_json`、`text`、`srt`、`vtt` |
| 流式 ASR/TTS | `WS /v1/realtime` | OpenAI Realtime 兼容子集；只承载语音，不伪装 LLM 对话与工具调用 |
| TTS | `POST /v1/audio/speech` | `mp3`、`opus`、`aac`、`flac`、`wav`、`pcm` |
| 音色目录 | `GET /v1/voices` | 九个跨档角色；按当前权重声明 `available`、`variant` 和能力 |
| 自定义音色 | `POST/DELETE /v1/voices` | SpeechRail 扩展；仅 VoiceDesign 档可合成自然语言设计的音色 |
| 本机服务 | `speechrail service ...` | macOS 用户级 LaunchAgent；单实例、原子 wheel 替换 |

机器可读接口以 [`contracts/openapi.yaml`](contracts/openapi.yaml) 和 [`contracts/realtime-openai.md`](contracts/realtime-openai.md) 为准。

## 三档模型

档位是部署状态，API 调用方不提交 `quality`、`balanced` 或 `light`。

| 档位 | ASR | TTS | 适用场景 |
|---|---|---|---|
| `quality` | Qwen3-ASR 1.7B q8 | Qwen3-TTS 1.7B VoiceDesign q8 | 质量与自然语言音色设计优先 |
| `balanced` | Qwen3-ASR 1.7B q8 | Qwen3-TTS 0.6B CustomVoice q8 | 保留 1.7B ASR，降低 TTS 内存与延迟 |
| `light` | Qwen3-ASR 0.6B q8 | Qwen3-TTS 0.6B CustomVoice q8 | 8GB Apple Silicon 目标组合 |

九个 canonical 角色为 `serena`、`vivian`、`uncle_fu`、`dylan`、`eric`、`ryan`、`aiden`、`ono_anna`、`sohee`。`quality` 使用固定 VoiceDesign 配方复现角色，`balanced/light` 映射到同名 CustomVoice speaker；角色语义一致，跨权重不承诺声纹完全相同。自定义 VoiceDesign 音色在低档保留但显示为 `available=false`，切回 `quality` 后恢复。

```bash
speechrail profile list
speechrail profile status
speechrail profile apply balanced --yes
speechrail profile rollback --yes
```

档位切换会短暂停服。`profile apply` 在公共 ASR/TTS smoke 失败时执行一次有界回退。

## 快速开始

要求：Apple Silicon、macOS 14+、Python `>=3.12,<3.13`、[`uv`](https://docs.astral.sh/uv/) 和 `ffmpeg`。模型 snapshot 与 vendor runtime 位于仓库外。

```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail
uv sync --extra dev
cp configs/speechrail.example.env .env
chmod 600 .env
```

在 `.env` 中填写 ASR/TTS snapshot 与专用 Python 的绝对路径，然后启动：

```bash
uv run speechrail serve
```

另开终端检查服务：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl http://127.0.0.1:8201/v1/voices
```

`readyz=200` 只表示入口就绪；部署验收还应使用一段真实短音频完成 ASR/TTS smoke。受管安装、模型准备和 LaunchAgent 操作见[运行时部署](docs/operations/runtime-deployment.md)与[运维手册](docs/operations/operations-runbook.md)。

## OpenAI SDK 示例

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8201/v1", api_key="local")

with open("meeting.wav", "rb") as audio:
    transcript = client.audio.transcriptions.create(
        model="whisper-1",
        file=audio,
        response_format="verbose_json",
        timestamp_granularities=["segment", "word"],
    )

speech = client.audio.speech.create(
    model="tts-1",
    voice="serena",
    input="欢迎使用 SpeechRail。",
    response_format="wav",
)
speech.write_to_file("speech.wav")
```

更多 cURL、QwenPaw、Sona、Hermes Agent 与 Realtime 示例见[客户端接入指南](docs/users/integrations.md)。

## 性能与资源

2026-09-05 在同一台 Apple M5 Max / 128GB 主机上，以相同公共 API 串行测得：

| 档位 | ASR 热态 RTF（中 / 英） | TTS 热态 RTF | 最大同时物理占用 |
|---|---:|---:|---:|
| `quality` | 0.0346 / 0.0353 | 0.2676 | 7000.3 MB |
| `balanced` | 0.0332 / 0.0330 | 0.2303 | 5877.4 MB |
| `light` | 0.0249 / 0.0240 | 0.2272 | 4484.2 MB |

这些数字用于本机横向比较，不等同于 M1 Air 8GB 发布验收。测量口径、准确率代理和限制见[三档可行性报告](docs/archive/performance/2026-09-05-three-tier-feasibility.md)，历次结果见[性能归档](docs/archive/performance/README.md)。

## 架构边界

```text
OpenAI client
    │ HTTP / WebSocket
    ▼
FastAPI host ── 有界音频处理 / Resource Governor / 协议状态机
    │ framed IPC
    ├── 共享 ASR worker（batch 与 streaming 模式互斥）
    ├── TTS worker（VoiceDesign 或 CustomVoice）
    └── 可选匿名 diarization adapter
```

SpeechRail 不负责麦克风、扬声器、播放、会议持久化、UI、LLM 编排或实名声纹库。完整设计与决策见[架构文档](docs/architecture/README.md)和 [ADR](docs/decisions/README.md)。

## 文档

| 读者 | 入口 |
|---|---|
| API 使用者 | [用户与集成](docs/users/README.md) · [API 契约说明](docs/users/api-contract.md) |
| 运维人员 | [运维中心](docs/operations/README.md) · [运行时部署](docs/operations/runtime-deployment.md) |
| 开发者 | [开发者中心](docs/developers/README.md) · [测试与验收](docs/developers/testing-acceptance.md) |
| 架构评审 | [架构中心](docs/architecture/README.md) · [当前边界](docs/architecture/current-boundaries.md) |
| 全部文档 | [文档中心](docs/README.md) |

## 参与贡献

提交变更前请阅读[贡献指南](CONTRIBUTING.md)。安全问题按[安全策略](SECURITY.md)私下报告；社区行为遵循[行为准则](CODE_OF_CONDUCT.md)。

SpeechRail 采用 [MIT License](LICENSE)。
