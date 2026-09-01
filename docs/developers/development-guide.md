---
title: "SpeechRail 开发指南"
status: active
date: 2026-08-31
---

# SpeechRail 开发指南

本指南面向修改 SpeechRail 本身的开发者。它不包含模型权重、本机 `.env`、音频或任何
客户端私有配置。

## 1. 开发前提与本地启动

项目固定使用 Python `>=3.12,<3.13` 与 `uv`。HTTP 服务依赖仓库的 `uv` 环境；真实
Qwen3-ASR/TTS 运行在各自配置的独立 Python 中，隔离模型厂商依赖。

```bash
cd <path-to-SpeechRail>
uv sync --extra dev
uv run speechrail
```

无真实模型配置时，应用仍可启动，且可运行所有确定性契约测试；推理接口将返回
`503 backend_not_ready`。需要实机推理时，按[运行时与部署](../operations/runtime-deployment.md)
准备外部 snapshot 与 Python runtime，再在未提交的 `.env` 中设置路径。

## 2. wheel 与本地安装器

源码开发的 `uv sync` 不等于发布安装。发布 wheel 时使用：

```bash
uv build --no-sources --wheel
```

然后在干净 venv 中安装 wheel，或将 wheel 与 `tools/install_macos.py` 一起交给本机安装器。
wheel 只包含 `speechrail` 服务包；模型权重、vendor runtime、`.env`、音频和日志必须留在外部。
安装器必须先完成 preflight，再按用户明确选择决定是否启用 LaunchAgent。不要从源码目录导入
模块来代替干净 wheel 验收。

## 3. 目录与责任边界

| 目录 | 责任 |
|---|---|
| `src/speechrail/app.py` | FastAPI 边界、请求验证、认证、音频解码、队列接入与 WS 路由 |
| `src/speechrail/domain/` | 与客户端无关的 ASR/TTS 结果、请求和校验模型 |
| `src/speechrail/backends/` | Qwen3 ASR/TTS、WLK/diarization profile、snapshot 预检和私有 worker 协议 |
| `src/speechrail/realtime/` | `/v1/realtime` 与 `/v2/realtime` 会话状态、帧上限和事件渲染 |
| `src/speechrail/compatibility/` | OpenAI/WLK 等窄兼容序列化；不得污染领域模型 |
| `src/speechrail/runtime/` | 有界 admission queue、Resource Governor、jobs 与 diarization 协调 |
| `contracts/` | 公共 REST 与 WebSocket 的事实来源 |
| `tests/` | 无模型依赖的契约、安全与边界测试 |

SpeechRail 不拥有麦克风、会议、播放、UI、PostgreSQL、LLM chat orchestration 或客户端
prompt。不要从 `voice-realtime` 复制这些职责进来。

## 4. 当前模型运行方式

当 `SPEECHRAIL_QWEN3_MODEL_DIR` 与 `SPEECHRAIL_QWEN3_PYTHON` 都存在时，
`create_app()` 创建一个 ASR `Qwen3Worker`；当 TTS model/runtime 两条路径同时存在时，
再创建一个独立 TTS worker。ASGI startup 分别启动并校验它们；worker 在启动帧中检查
完整 snapshot、离线环境、设备和 dtype，随后顺序执行各自请求。当前 profile：

- 模型：`Qwen/Qwen3-ASR-1.7B`，公共 ID `speechrail/qwen3-asr-1.7b`；
- Apple Silicon：`mps` + `float16`；worker 明确禁止 MPS 自动回退 CPU；
- CPU：仅 `cpu` + `float32`；
- 上传容器经固定 `ffmpeg` 参数转换为 `s16le` / 16 kHz / 单声道 PCM；
- 真实 worker 每次只保有一个模型实例。不要通过多 ASGI worker 复制模型。
- TTS 公共 ID 为 `speechrail/qwen3-tts`，只接受服务器登记的 `default`、`warm`、`bright`、`calm` preset，输出 24 kHz 单声道 PCM16 或 WAV；
- Realtime v2 的 transcription/speech 使用独立状态机和资源 lane；可选 diarization 只保留有界匿名 session state。

模型路径必须是仓库外绝对路径。`validate_snapshot()` 会检查必须文件；请求路径不会执行
下载。模型升级和依赖升级先在独立 runtime 做 smoke，再更新运行清单，不能静默替换。

## 5. 契约变更流程

1. 先更新 `contracts/openapi.yaml`、`contracts/realtime.md` 或 `contracts/realtime-v2.md`，再修改路由/事件代码与测试。
2. 可选请求字段、可选响应字段和新端点可以作为 `/v1` 的兼容扩展。
3. 删除字段、改变类型、错误码语义或 WS 状态机需要 `/v2`、迁移说明与兼容期。
4. 所有公共错误保持 `error.message/type/code/request_id/retryable` envelope；不要暴露
   traceback、路径、密钥、音频或完整文本。
5. alias 只能映射到同一后端 profile。新客户端必须使用 canonical model ID；不要把
   `whisper-1` 当作真实模型。

更新 realtime 文档时务必区分目标协议与当前行为。v1 不发送 delta 且每个会话在第一次
commit 后结束；v2 可按 backend 能力发送 ASR partial/completed 或 TTS audio delta，但不能
把未通过真实 smoke 的 backend 写成已验收能力。

## 6. 测试与质量门禁

每次行为或契约变更至少执行：

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
```

测试须保持确定性：使用 fake backend、构造的 PCM 或脱敏 fixture，不下载模型、不访问
网络、不提交音频。真实 Qwen3 smoke 是额外验收而不是单元测试前提。详细矩阵见
[测试与验收](testing-acceptance.md)。

## 7. 文档与提交

- 代码、接口、配置键或运行行为变更必须同步更新 README、相应 `docs/`、契约和
  `CHANGELOG.md`；重大架构决定添加 ADR。
- 文档示例用 `<path-to-SpeechRail>`、`/absolute/path/outside/SpeechRail/...` 等占位符，
  不写本机路径、wrapper、token 或终端历史。
- 提交前检查工作树，避免把 `.env`、模型文件、音频、转写、缓存和外部 runtime 纳入 Git。
- 以单一主题组织提交；完成前以 `git diff --check` 与上述门禁验证实际变更。
