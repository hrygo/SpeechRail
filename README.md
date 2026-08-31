# SpeechRail

SpeechRail（声轨）是面向本机应用的独立语音识别服务。它以稳定的 OpenAI-compatible
接口提供 Qwen3-ASR，并将模型运行、队列、认证与观测从 QwenPaw、`voice-realtime`、
Hermes Agent 等客户端中分离出来。

## 当前状态

`0.1.0` 已具备可运行的本地 Qwen3-ASR 文件转写链路：服务启动时加载一个外部
Qwen3-ASR-1.7B snapshot 到隔离 worker，Apple Silicon 默认使用 MPS / `float16`，请求
不会下载模型。2026-08-31 已完成本机 REST 与 QwenPaw 中文短音频冒烟。

下列边界同样重要：

| 能力 | 状态 | 说明 |
|---|---|---|
| `POST /v1/audio/transcriptions` | 可用 | 文件转写，支持 `json`、`verbose_json`、`text`、`srt`、`vtt` |
| `GET /health`、`/readyz`、`/v1/models` | 可用 | 存活、配置就绪与模型身份检查 |
| `WS /v1/realtime` | 有限可用 | 收集 PCM 后在一次 `commit` 时批量转写；当前不产生增量 delta |
| `WS /asr` | 兼容骨架 | 只保留握手 `config` 与空 PCM EOF → `ready_to_stop`，尚不能替代旧 WLK 转写 |
| QwenPaw | 已验证 | 使用现有 `whisper_api` provider 指向 SpeechRail |
| Hermes Agent、`voice-realtime` 迁移 | 未验证 | 保持各自现有服务，按 Runbook 单独验收与回滚 |
| `launchd` 服务安装 | 提供操作步骤 | 尚未在本机自动安装或启用 |

不要把 `whisper-1` 兼容别名误认为后端模型；新配置使用
`speechrail/qwen3-asr-1.7b`。

## 快速开始

前提：Python 3.12、`uv`、`ffmpeg`、完整的外部 Qwen3-ASR snapshot，以及包含
`qwen-asr` 与 PyTorch 的专用 Python runtime。模型与 runtime 均不进入本仓库。

```bash
cd <path-to-SpeechRail>
uv sync --extra dev
cp configs/speechrail.example.env .env
# 编辑 .env：填写本机外部模型 snapshot 与专用 Python 的绝对路径。
uv run speechrail
```

`SPEECHRAIL_QWEN3_MODEL_DIR` 和 `SPEECHRAIL_QWEN3_PYTHON` 同时配置后，服务会在
启动阶段预检并加载一个 Qwen3 worker；任何一项缺失时，文件转写安全返回
`503 backend_not_ready`。生产/日常使用不要把 `SPEECHRAIL_BACKEND_READY` 设为 `true`，
它只保留给无真实后端的契约测试。

另开一个终端验证：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
```

`/readyz` 通过后，用自己的非敏感短音频发起一次转写：

```bash
curl -X POST http://127.0.0.1:8201/v1/audio/transcriptions \\
  -F 'file=@sample.wav' \\
  -F 'model=speechrail/qwen3-asr-1.7b' \\
  -F 'language=zh' \\
  -F 'response_format=json'
```

完整配置、服务化安装、故障处理和回滚见[运维 Runbook](docs/11-operations-runbook.md)。

## API 一览

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/health` | 进程存活、版本及已配置后端身份 |
| `GET` | `/readyz` | 推理入口是否已配置；仍应以真实短音频确认模型可工作 |
| `GET` | `/v1/models` | canonical 模型 ID 与兼容别名 |
| `POST` | `/v1/audio/transcriptions` | OpenAI-compatible multipart 文件转写 |
| `WS` | `/v1/realtime` | 16 kHz/单声道/PCM16 的 commit 后批量转写 |
| `WS` | `/asr` | 仅旧客户端迁移期间的有限 EOF 协议 |

REST 的准确字段、响应格式、错误码以 [OpenAPI 契约](contracts/openapi.yaml) 为准；两个
WebSocket 的真实状态机与限制以 [Realtime 契约](contracts/realtime.md) 为准。

## 给不同读者的入口

- 使用服务或接入客户端：[用户与集成指南](docs/04-integrations.md)
- 开发服务、测试或变更契约：[开发指南](docs/10-development-guide.md)
- 安装、运行、排障、升级或回滚：[运维 Runbook](docs/11-operations-runbook.md)
- 了解能力边界与未完成迁移：[当前边界](docs/09-open-questions.md)
- 浏览全部资料：[文档中心](docs/README.md)

## 安全与数据边界

- 默认只绑定 `127.0.0.1`；非 loopback 绑定必须配置 Bearer API key。
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
