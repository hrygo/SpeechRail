# SpeechRail

SpeechRail（声轨）是面向本机应用的独立 ASR/TTS 运行时。它以稳定的 OpenAI-compatible
REST 与 Realtime v2 接口提供语音转写和文本转语音，并将模型运行、队列、认证与观测从
QwenPaw、`voice-realtime`、Hermes Agent 等客户端中分离出来。

## 当前状态

当前已具备可运行的本地 Qwen3-ASR 文件转写链路；Qwen3-TTS VoiceDesign 的代码与契约已实现，
配置外部 runtime/snapshot 后可运行。服务按配置分别加载外部 ASR/TTS snapshot 到隔离 worker，Apple Silicon 默认使用 MPS /
`float16`，请求不会下载模型。TTS 公共模型 ID 固定为 `speechrail/qwen3-tts`，preset
固定为 `default`、`warm`、`bright`、`calm`。

下列边界同样重要：

| 能力 | 状态 | 说明 |
|---|---|---|
| `POST /v1/audio/transcriptions` | 可用 | 文件转写，支持 `json`、`verbose_json`、`text`、`srt`、`vtt` |
| `GET /health`、`/readyz`、`/v1/models` | 可用 | 存活、ASR/TTS 独立就绪状态和模型身份检查 |
| `GET /v1/voices` | 当前代码已注册 | 返回 TTS preset 目录；TTS worker 未就绪时条目可标记 `available=false`。运行态 404 应先核对服务进程、端口/base URL 和重启状态 |
| `POST /v1/audio/speech` | 已实现（需配置） | OpenAI-compatible 整句 TTS；仅在配置外部 TTS runtime 后可推理 |
| `POST/GET/DELETE /v1/jobs` | 可用 | owner-scoped durable job 元数据；执行器需由部署注入受信任 processor |
| `WS /v2/realtime` | 部分实现 | ASR partial/completed 与 TTS audio delta、取消和背压；真实模型闭环仍需部署验收 |
| `WS /v1/realtime` | 有限可用 | 收集 PCM 后在一次 `commit` 时批量转写；当前不产生增量 delta |
| `WS /asr` | 兼容骨架 | 只保留握手 `config` 与空 PCM EOF → `ready_to_stop`，尚不能替代旧 WLK 转写 |
| QwenPaw | 已完成本机 smoke（2026-08-31） | 使用 `whisper_api` 接入 `/v1`；再次切换前仍须按用户文档复验 |
| Hermes Agent | 未验收 | 已提供 STT 专用配置方法；不得修改其全局聊天 endpoint |
| `voice-realtime` | v2/REST adapter 已实现 | ASR 通过 v2，TTS 通过 v2/REST；会议、播放、UI、数据库和 LLM 仍由调用方拥有，真实闭环需部署验收 |
| `launchd` 服务 CLI | 已实现（macOS） | `speechrail service` 显式管理当前用户 LaunchAgent；不会自动安装或启用 |

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
# 前台运行；按 Ctrl-C 停止。
uv run speechrail serve
```

前台运行与 macOS 常驻是两种运行方式。停止前台实例并完成 `.env` 配置后，如需注册为登录后常驻的
当前用户服务，执行：

```bash
uv run speechrail service install
uv run speechrail service enable
```

`install` 写入当前用户的 LaunchAgent plist 和私有日志目录，但不会启动服务；`enable` 才会加载并启动
模型进程。完整服务操作与回滚见[运维 Runbook](docs/operations/operations-runbook.md)。

服务 CLI 仅支持 macOS：

| 命令 | 用途 |
|---|---|
| `uv run speechrail service install` | 写入 LaunchAgent plist 和日志目录，不启动服务 |
| `uv run speechrail service enable` | 加载并启动已安装的 LaunchAgent |
| `uv run speechrail service status` | 查询当前用户的 `launchctl` 状态 |
| `uv run speechrail service restart` | 重启已加载的服务 |
| `uv run speechrail service disable` | 停止并卸载服务，保留 plist |
| `uv run speechrail service uninstall` | 停止服务并删除 plist，不删除 `.env`、模型或外部 runtime |

`SPEECHRAIL_QWEN3_MODEL_DIR` 和 `SPEECHRAIL_QWEN3_PYTHON` 同时配置后，服务会在启动阶段
预检并加载 ASR worker；TTS 对应配置为 `SPEECHRAIL_QWEN3_TTS_MODEL_DIR` /
`SPEECHRAIL_QWEN3_TTS_PYTHON`，两条都配置后再重启服务。任一已请求但未就绪的推理能力都会安全返回
`503 backend_not_ready`。`/v1/voices` 是独立的 preset 目录路由，按当前代码即使 TTS 未就绪也应返回
目录并标记 `available=false`；如果实际返回 404，先确认客户端访问的是当前 SpeechRail 进程和 `8201` 端口，
再重启服务。Creator 等客户端的 TTS 合成仍必须先补齐两条 TTS 配置并重启。生产/日常使用不要把
`SPEECHRAIL_BACKEND_READY` 设为 `true`，它只保留给无真实后端的契约测试。

另开一个终端验证：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl -i http://127.0.0.1:8201/v1/voices
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

完整配置、服务化安装、故障处理和回滚见[运维 Runbook](docs/operations/operations-runbook.md)。

## wheel + 本地安装

需要把服务交给另一台本机时，使用 wheel 和随附的 macOS 安装器。wheel 不包含模型、vendor
runtime、`.env` 或音频；安装器会创建用户私有 runtime，完成 preflight 后再按参数决定是否启用
LaunchAgent。

```bash
uv build --no-sources --wheel
python3 tools/install_macos.py \
  --wheel <wheel-file> \
  --env-file <private-env-file> \
  --app-home "$HOME/Library/Application Support/SpeechRail" \
  --enable
```

安装前应先准备并在 `.env` 中配置 ASR/TTS 的外部绝对路径。只启用 ASR 时显式添加
`--asr-only`；默认的完整安装要求 ASR 和 TTS 均通过 preflight。安装后执行：

```bash
python3 scripts/verify_release.py \
  --wheel <wheel-file> \
  --app-home "$HOME/Library/Application Support/SpeechRail"
```

升级和回滚步骤见[运行时与部署](docs/operations/runtime-deployment.md)。

## API 一览

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/health` | 进程存活、版本及 ASR/TTS 独立就绪状态 |
| `GET` | `/readyz` | 至少一个已配置 ASR/TTS 推理入口可接受请求 |
| `GET` | `/v1/models` | canonical ASR/TTS 模型 ID 与兼容别名 |
| `GET` | `/v1/voices` | SpeechRail 登记的 TTS preset 目录；未就绪时仍可返回 `available=false` |
| `POST` | `/v1/audio/transcriptions` | OpenAI-compatible multipart 文件转写 |
| `POST` | `/v1/audio/speech` | OpenAI-compatible 整句 TTS（`wav` / `pcm`） |
| `POST` / `GET` / `DELETE` | `/v1/jobs` / `/v1/jobs/{id}` | durable ASR/TTS job 生命周期 |
| `WS` | `/v2/realtime` | 新客户端的 ASR/TTS Realtime v2 |
| `WS` | `/v1/realtime` | 16 kHz/单声道/PCM16 的 commit 后批量转写 |
| `WS` | `/asr` | 仅旧客户端迁移期间的有限 EOF 协议 |

REST 的准确字段、响应格式、错误码以 [OpenAPI 契约](contracts/openapi.yaml) 为准；v2 的
状态机与限制以 [Realtime v2 契约](contracts/realtime-v2.md) 为准。

## 给不同读者的入口

- 使用服务或接入客户端：[用户与集成文档](docs/users/README.md)
- 开发服务、测试或变更契约：[开发者文档](docs/developers/README.md)
- 安装、运行、排障、升级或回滚：[运维文档](docs/operations/README.md)
- 了解服务边界与数据流：[架构文档](docs/architecture/README.md)
- 查看已接受的架构决策：[ADR 索引](docs/decisions/README.md)
- 浏览全部资料：[文档中心](docs/README.md)

## 安全与数据边界

- 默认只绑定 `127.0.0.1`；非 loopback 绑定必须配置 Bearer API key。
- 非 loopback 的 REST 与 `/v2/realtime` WebSocket 都要求 `Authorization: Bearer <key>`；
  key 不进入 URL、配置示例或普通日志。
- 模型 snapshot 必须是仓库外绝对路径；服务不会在请求中下载模型或访问远程音频 URL。
- 上传音频只在内存中处理，`ffmpeg` 以固定参数解码；不把音频、完整转写、提示词或密钥写入日志。
- `/asr` 当前未实现认证，禁止将其暴露到 LAN 或公网。

## 兼容策略

REST 接口优先保持向后兼容；破坏性 API 变更使用 `/v2` 并提供迁移说明。`/asr`
是临时兼容面，不是新客户端接口，也没有确定的删除日期——删除必须以
`voice-realtime` 完成替代方案与回滚演练为前提。

## 许可与变更记录

- [变更记录](CHANGELOG.md)
- [架构决策记录](docs/decisions/README.md)
- [项目范围](docs/architecture/product-scope.md)
