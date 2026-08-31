---
title: "SpeechRail 运行时与部署"
status: active
date: 2026-08-31
---

# SpeechRail 运行时与部署

本页说明 `0.1.0` 的实际运行组成；日常操作以[运维 Runbook](11-operations-runbook.md)
为准。

## 运行拓扑

```text
客户端 ── HTTP / WS ──> FastAPI（uv 环境）
                           │
                           ├─ 有界 admission queue
                           ├─ 固定 ffmpeg 解码（REST）
                           └─ 单一 Qwen3 worker（专用 Python）
                                  └─ 外部 Qwen3-ASR-1.7B snapshot
```

worker 仅在同时设置 `SPEECHRAIL_QWEN3_MODEL_DIR` 与
`SPEECHRAIL_QWEN3_PYTHON` 时创建，并于 ASGI startup 加载。主进程与 worker 使用长度
前缀 JSON 私有协议，worker 只接受 16 kHz / 单声道 / PCM16 音频。模型目录不在仓库内，
请求路径启用离线环境变量，不会下载模型。

## 模型与设备 profile

| profile | 模型 | device / dtype | 启动行为 |
|---|---|---|---|
| 默认 Apple Silicon | Qwen3-ASR-1.7B | `mps` / `float16` | 启动时加载一份，拒绝 CPU fallback |
| 有意 CPU 部署 | Qwen3-ASR-1.7B | `cpu` / `float32` | 启动时加载一份，性能需单独验收 |
| 未配置 runtime | 无 | 无 | 进程可启动；推理为 `503 backend_not_ready` |

SpeechRail 不依赖或加载 LM Studio 模型、Whisper、WLK sidecar、TTS、embedding、第二个
ASR 模型或 `voice-realtime` 组件。

## 配置

从 [环境示例](../configs/speechrail.example.env) 复制到被忽略的 `.env`。关键键如下：

| 键 | 用途 |
|---|---|
| `SPEECHRAIL_HOST` / `PORT` | 默认 `127.0.0.1:8201` |
| `SPEECHRAIL_QWEN3_MODEL_DIR` | 仓库外完整 snapshot 的绝对路径 |
| `SPEECHRAIL_QWEN3_PYTHON` | 专用 worker Python 可执行文件 |
| `SPEECHRAIL_DEVICE` / `DTYPE` | 严格配对：`mps/float16` 或 `cpu/float32` |
| `SPEECHRAIL_MAX_QUEUE_SIZE` | 同时等待/执行任务的有界队列大小 |
| `SPEECHRAIL_MAX_UPLOAD_BYTES` | REST 上传的强制字节上限 |
| `SPEECHRAIL_MAX_REALTIME_*` | WebSocket 单帧和缓存字节上限 |
| `SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` | 一个 worker 调用的 deadline |
| `SPEECHRAIL_JOB_SPOOL_DIR` | 可选、仓库外绝对 SQLite spool；启用 `/v1/jobs` 元数据与启动恢复 |
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

## 端口与进程策略

默认端口 `8201` 供 SpeechRail 与旧 WLK `8001` 并行存在。未完成
`voice-realtime` legacy parity 前，禁止把 SpeechRail 切换到 `8001`。一次只启动一个
SpeechRail 进程和一个 worker；多 worker 进程会产生多份模型载入和不可控内存压力。

需要常驻运行时使用 macOS `LaunchAgent`，而不是将 MPS 服务作为系统级 `LaunchDaemon`。
模板、安装步骤和卸载步骤见[运维 Runbook](11-operations-runbook.md)。
