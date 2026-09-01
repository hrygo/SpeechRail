# SpeechRail

SpeechRail（声轨）是面向本机应用的独立 ASR/TTS 运行时。它以稳定的 OpenAI-compatible
REST 与 Realtime v2 接口提供语音转写和文本转语音，并将模型运行、队列、认证与观测从
QwenPaw、`voice-realtime`、Hermes Agent 等客户端中分离出来。

## 当前状态

`0.1.0` 已具备可运行的本地 Qwen3-ASR 文件转写链路和 Qwen3-TTS VoiceDesign 链路：
服务按配置分别加载外部 ASR/TTS snapshot 到隔离 worker，Apple Silicon 默认使用 MPS /
`float16`，请求不会下载模型。TTS 公共模型 ID 固定为 `speechrail/qwen3-tts`，preset
固定为 `default`、`warm`、`bright`、`calm`。

下列边界同样重要：

| 能力 | 状态 | 说明 |
|---|---|---|
| `POST /v1/audio/transcriptions` | 可用 | 文件转写，支持 `json`、`verbose_json`、`text`、`srt`、`vtt` |
| `GET /health`、`/readyz`、`/v1/models`、`/v1/voices` | 可用 | 存活、ASR/TTS 独立就绪状态、模型与 preset 身份检查 |
| `POST /v1/audio/speech` | 契约可用 | OpenAI-compatible 整句 TTS；仅在配置外部 TTS runtime 后可推理 |
| `POST/GET/DELETE /v1/jobs` | 可用 | owner-scoped durable job 元数据；执行器需由部署注入受信任 processor |
| `WS /v2/realtime` | 契约可用 | ASR partial/completed 与 TTS audio delta、取消和背压；真实模型闭环仍需部署验收 |
| `WS /v1/realtime` | 有限可用 | 收集 PCM 后在一次 `commit` 时批量转写；当前不产生增量 delta |
| `WS /asr` | 兼容骨架 | 只保留握手 `config` 与空 PCM EOF → `ready_to_stop`，尚不能替代旧 WLK 转写 |
| QwenPaw、Hermes Agent | 未在本分支复验 | REST 接入方法已文档化；不得据此改动当前客户端配置 |
| `voice-realtime` | adapter 已实现 | 会议/字幕、语音助手和 TTS 均通过 v2；确定性回归已覆盖，真实模型闭环需部署验收 |
| `launchd` 服务安装 | 可用 | `speechrail service` 管理用户级 LaunchAgent；安装与启用均为显式操作 |

不要把 `whisper-1` 兼容别名误认为后端模型；新配置使用
`speechrail/qwen3-asr-1.7b`。

## 快速开始

前提：Python 3.12、`uv`、`ffmpeg`、完整的外部 Qwen3-ASR snapshot，以及包含
`qwen-asr` 与 PyTorch 的专用 ASR Python runtime。启用 TTS 时，另需包含 `mlx_audio`
的专用 TTS Python runtime 和完整 VoiceDesign snapshot。模型与 runtime 均不进入本仓库。

```bash
cd <path-to-SpeechRail>
uv sync --extra dev
cp configs/speechrail.example.env .env
# 编辑 .env：填写本机外部模型 snapshot 与专用 Python 的绝对路径。
uv run speechrail
```

将服务注册为登录后常驻的 macOS 用户服务时，先完成 `.env` 配置，再执行：

```bash
uv run speechrail service install
uv run speechrail service enable
```

`install` 只生成当前用户的 LaunchAgent plist，`enable` 才会启动模型进程。服务操作与回滚见
[运维 Runbook](docs/operations/operations-runbook.md)。

`SPEECHRAIL_QWEN3_MODEL_DIR` 和 `SPEECHRAIL_QWEN3_PYTHON` 同时配置后，服务会在启动阶段
预检并加载 ASR worker；TTS 对应配置为 `SPEECHRAIL_QWEN3_TTS_MODEL_DIR` /
`SPEECHRAIL_QWEN3_TTS_PYTHON`。任一已请求但未就绪的能力都会安全返回
`503 backend_not_ready`。生产/日常使用不要把 `SPEECHRAIL_BACKEND_READY` 设为 `true`，
它只保留给无真实后端的契约测试。

另开一个终端验证：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl http://127.0.0.1:8201/v1/voices
```

`/readyz` 通过后，用自己的非敏感短音频发起一次转写：

```bash
curl -X POST http://127.0.0.1:8201/v1/audio/transcriptions \\
  -F 'file=@sample.wav' \\
  -F 'model=speechrail/qwen3-asr-1.7b' \\
  -F 'language=zh' \\
  -F 'response_format=json'
```

启用 TTS 时，另用 `/v1/audio/speech` 请求 `speechrail/qwen3-tts`、登记的 preset 和
`response_format=pcm`，确认返回 24 kHz PCM16；不要记录输入文本或输出音频。

完整配置、服务化安装、故障处理和回滚见[运维 Runbook](docs/11-operations-runbook.md)。

## API 一览

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/health` | 进程存活、版本及 ASR/TTS 独立就绪状态 |
| `GET` | `/readyz` | 至少一个已配置 ASR/TTS 推理入口可接受请求 |
| `GET` | `/v1/models` | canonical ASR/TTS 模型 ID 与兼容别名 |
| `GET` | `/v1/voices` | SpeechRail 登记的 TTS preset 目录 |
| `POST` | `/v1/audio/transcriptions` | OpenAI-compatible multipart 文件转写 |
| `POST` | `/v1/audio/speech` | OpenAI-compatible 整句 TTS（`wav` / `pcm`） |
| `POST` / `GET` / `DELETE` | `/v1/jobs` / `/v1/jobs/{id}` | durable ASR/TTS job 生命周期 |
| `WS` | `/v2/realtime` | 新客户端的 ASR/TTS Realtime v2 |
| `WS` | `/v1/realtime` | 16 kHz/单声道/PCM16 的 commit 后批量转写 |
| `WS` | `/asr` | 仅旧客户端迁移期间的有限 EOF 协议 |

REST 的准确字段、响应格式、错误码以 [OpenAPI 契约](contracts/openapi.yaml) 为准；v2 的
状态机与限制以 [Realtime v2 契约](contracts/realtime-v2.md) 为准。

## 给不同读者的入口

- 使用服务或接入客户端：[用户与集成指南](docs/04-integrations.md)
- 开发服务、测试或变更契约：[开发指南](docs/10-development-guide.md)
- 安装、运行、排障、升级或回滚：[运维 Runbook](docs/11-operations-runbook.md)
- 了解能力边界与未完成迁移：[当前边界](docs/09-open-questions.md)
- 查看已接受的 ASR/TTS 目标架构：[最终设计](docs/superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md)
- 浏览全部资料：[文档中心](docs/README.md)

## 安全与数据边界

- 默认只绑定 `127.0.0.1`；非 loopback 绑定必须配置 Bearer API key。
- 非 loopback 的 REST 与 `/v2/realtime` WebSocket 都要求 `Authorization: Bearer <key>`；
  key 不进入 URL、配置示例或普通日志。
- 模型 snapshot 必须是仓库外绝对路径；服务不会在请求中下载模型或访问远程音频 URL。
- 上传音频只在内存中处理，`ffmpeg` 以固定参数解码；不把音频、完整转写、提示词或密钥写入日志。
- `/asr` 当前未实现认证，禁止将其暴露到 LAN 或公网。

## 版本与兼容

`0.x` 期间优先保持 REST 向后兼容；破坏性 API 变更使用 `/v2` 并提供迁移说明。`/asr`
是临时兼容面，不是新客户端接口，也没有确定的删除日期——删除必须以
`voice-realtime` 完成替代方案与回滚演练为前提。

## 许可与变更记录

- [变更记录](CHANGELOG.md)
- [架构决策记录](docs/decisions/README.md)
- [项目范围](docs/00-product-scope.md)
