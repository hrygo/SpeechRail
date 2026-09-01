---
title: "SpeechRail 运行时与部署"
status: active
date: 2026-08-31
---

# SpeechRail 运行时与部署

本页说明当前实际运行组成；日常操作以[运维 Runbook](operations-runbook.md) 为准。

## 运行拓扑

```text
客户端 ── HTTP / WS ──> FastAPI（uv 环境）
                           │
                           ├─ 有界 admission queue / Resource Governor
                           ├─ 固定 ffmpeg 解码（REST ASR）
                           ├─ Qwen3 ASR worker（专用 Python）
                           │      └─ 外部 Qwen3-ASR snapshot
                           └─ Qwen3 TTS worker（专用 Python，可选）
                                  └─ 外部 VoiceDesign snapshot
```

ASR worker 仅在同时设置 `SPEECHRAIL_QWEN3_MODEL_DIR` 与 `SPEECHRAIL_QWEN3_PYTHON` 时
创建；TTS worker 仅在对应两条 TTS 路径同时设置时创建；两者都在 ASGI startup 加载。
主进程与 worker 使用长度前缀 JSON 私有协议，ASR worker 接受 16 kHz / 单声道 / PCM16 音频，
TTS worker 输出 24 kHz / 单声道 / PCM16。模型目录不在仓库内，请求路径启用离线环境变量，
不会下载模型。

## 模型与设备 profile

| profile | 模型 | device / dtype | 启动行为 |
|---|---|---|---|
| 默认 Apple Silicon | Qwen3-ASR-1.7B | `mps` / `float16` | 启动时加载一份，拒绝 CPU fallback |
| 有意 CPU 部署 | Qwen3-ASR-1.7B | `cpu` / `float32` | 启动时加载一份，性能需单独验收 |
| 未配置 runtime | 无 | 无 | 进程可启动；推理为 `503 backend_not_ready` |
| TTS runtime 成对配置 | Qwen3-TTS VoiceDesign | `mps` / `float16` 或 `cpu` / `float32` | 独立加载一份；TTS 未就绪不阻塞 ASR |
| diarization profile | Sortformer（可选 CAM++） | 由 profile/runtime 决定 | Realtime v2 opt-in；只保留有界匿名状态 |

SpeechRail 不依赖或加载 LM Studio chat/embedding 模型、Whisper 或 `voice-realtime` 组件。
WLK sidecar 仅在明确配置 endpoint 时作为外部 v2 ASR transport；不会由 SpeechRail 启动。

## 配置

从 [环境示例](../../configs/speechrail.example.env) 复制到被忽略的 `.env`。关键键如下：

| 键 | 用途 |
|---|---|
| `SPEECHRAIL_HOST` / `PORT` | 默认 `127.0.0.1:8201` |
| `SPEECHRAIL_QWEN3_MODEL_DIR` | 仓库外完整 snapshot 的绝对路径 |
| `SPEECHRAIL_QWEN3_PYTHON` | 专用 worker Python 可执行文件 |
| `SPEECHRAIL_QWEN3_TTS_MODEL_DIR` / `SPEECHRAIL_QWEN3_TTS_PYTHON` | 可选、成对配置的 TTS snapshot/runtime |
| `SPEECHRAIL_TTS_VOICE_IDS` | 服务器登记的 TTS preset 列表 |
| `SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS` | 必须为 `false`；TTS worker 仅使用外部完整 snapshot |
| `SPEECHRAIL_DEVICE` / `DTYPE` | 严格配对：`mps/float16` 或 `cpu/float32` |
| `SPEECHRAIL_MAX_QUEUE_SIZE` | 同时等待/执行任务的有界队列大小 |
| `SPEECHRAIL_MAX_UPLOAD_BYTES` | REST 上传的强制字节上限 |
| `SPEECHRAIL_MAX_REALTIME_*` | WebSocket 单帧和缓存字节上限 |
| `SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` | 一个 worker 调用的 deadline |
| `SPEECHRAIL_JOB_SPOOL_DIR` | 可选、仓库外绝对 SQLite spool；启用 `/v1/jobs` 元数据与启动恢复 |
| `SPEECHRAIL_WLK_STREAMING_URL` | 可选、无凭据的外部 `ws(s)` endpoint；SpeechRail 不启动 sidecar |
| `SPEECHRAIL_DIARIZATION_*` | 可选的 Sortformer/CAM++ profile；路径外置，状态有界且匿名 |
| `SPEECHRAIL_API_KEY` | 非 loopback 绑定必填；loopback 可为空 |
| `SPEECHRAIL_LEGACY_WLK_ENABLED` | 是否暴露当前有限 `/asr` 兼容路径 |

`SPEECHRAIL_ALLOW_MODEL_DOWNLOADS` 必须为 `false`。`allowed_origins` 与
`SPEECHRAIL_MAX_AUDIO_SECONDS` 当前为预留配置，尚未分别连接到 CORS middleware 和解码后
时长拒绝逻辑；不要把它们视为已启用的安全/容量控制。

启用 job spool 时，目录须是项目外的绝对路径，并由运行账户独占。服务以 `0700` 创建目录、
以 `0600` 创建数据库，保存的仅是 owner 指纹、任务状态和不透明输入/结果引用；不保存原始
音频或完整转写。重启会将未完成的 `running` 任务标为 `failed(worker_interrupted)`。当前
foundation 仅在部署代码显式注入受信任 `JobProcessor` 时启动 batch executor；它和 realtime
共用 Resource Governor。没有内建的 `input_ref` 路径/URL resolver，默认不读取外部引用。

## wheel 与本地安装器

发布安装与源码开发分开处理。wheel 只包含服务代码和普通依赖；ASR/TTS vendor runtime、模型
snapshot、`ffmpeg` 和 `.env` 均由本机预先准备。发布目录应同时提供 wheel、`tools/install_macos.py`、
`configs/speechrail.example.env`、plist 模板和校验文件。

在发布目录中构建并安装：

```bash
uv build --no-sources --wheel
python3 tools/install_macos.py \
  --wheel <wheel-file> \
  --env-file <private-env-file> \
  --app-home "$HOME/Library/Application Support/SpeechRail"
```

安装器默认只创建新 runtime、运行 preflight 和写入 LaunchAgent plist，不启用服务；确认需要常驻
运行时再追加 `--enable`。完整安装要求 ASR/TTS 两组 runtime 和 snapshot 均通过检查；只部署 ASR
时必须显式追加 `--asr-only`。安装器不会覆盖已有 `.env`、删除旧 runtime 或下载模型。

验证已安装 wheel，而不是源码工作树：

```bash
python3 scripts/verify_release.py \
  --wheel <wheel-file> \
  --app-home "$HOME/Library/Application Support/SpeechRail"
```

升级先安装到新的 release runtime，完成 preflight 和真实 ASR/TTS smoke 后才切换
`runtime/current` 并重启；失败时恢复旧 `current`。README 不固定发布版本，包文件名和 package
metadata 仍保留用于升级、回滚和审计的版本信息。

## 端口与进程策略

默认端口 `8201` 供 SpeechRail 与旧 WLK `8001` 并行存在。未完成
`voice-realtime` legacy parity 前，禁止把 SpeechRail 切换到 `8001`。一次只启动一个
SpeechRail 进程；每个已配置 profile 只启动一个对应 worker。多 ASGI worker 或重复服务实例
会产生多份模型载入和不可控内存压力。

需要常驻运行时使用 macOS `LaunchAgent`，而不是将 MPS 服务作为系统级 `LaunchDaemon`。
通过 `speechrail service install`、`enable`、`status`、`restart`、`disable` 和 `uninstall`
管理；`install` 不会启动模型。模板、安装步骤和回滚顺序见[运维 Runbook](operations-runbook.md)。
