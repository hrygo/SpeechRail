---
title: "SpeechRail 运行时与部署"
status: active
date: 2026-08-31
---

# SpeechRail 运行时与部署

## 1. 首发运行环境

首发目标是当前 Apple Silicon Mac 本地服务：

- macOS 14+，Apple Silicon，优先 MPS。
- Python `>=3.12,<3.13`。
- `uv` 管理虚拟环境和锁文件。
- `ffmpeg` 负责常见容器到 PCM 的安全解码。
- 模型快照在仓库外的绝对路径。
- 默认 loopback；局域网访问另行开启认证和 origin 白名单。

当前本机 LM Studio 是独立的 LLM/Embedding 服务；SpeechRail 不把 Qwen3-ASR 请求
伪装成 LM Studio `/v1/chat/completions`，也不依赖 LM Studio 的聊天模型状态。

## 2. 模型来源与缓存

本机下载模型遵循 ModelScope 优先原则：

```text
ModelScope ID: Qwen/Qwen3-ASR-1.7B
revision:      master（实际下载时记录 commit/snapshot 指纹）
```

下载和校验是运维动作，不在 HTTP 请求中完成。下载后至少核对：

1. 仓库 ID、revision 和快照绝对路径。
2. `config.json`、tokenizer、processor 和主权重完整存在。
3. 文件大小/哈希与来源清单一致。
4. runtime 启动握手报告预期 `device`、`dtype` 和 `model_loaded=true`。
5. 首次短音频 smoke 通过后才把 `/readyz` 标为 ready。

SpeechRail 默认不写 `runtime/` 或模型到仓库；`.gitignore` 已拒绝模型和音频扩展名。

## 3. Runtime profile

| profile | 用途 | 运行时 | 设备 | partial | 时间戳 |
|---|---|---|---|:---:|:---:|
| `qwen3-asr-1.7b/batch` | QwenPaw、Hermes、文件转写 | SpeechRail isolated native worker | MPS | 否 | segment |
| `qwen3-asr-1.7b/realtime` | 新 WS 和 legacy `/asr` | WLK Qwen3 streaming adapter | MPS | 是 | segment/window |
| `qwen3-asr-1.7b/cpu-fallback` | 明确授权的诊断 | 独立 profile | CPU | 取决于实现 | 不默认承诺 |

首发不允许 MPS 静默降级 CPU；CPU fallback 必须显式 profile、显式观测和独立验收。
如果两个 runtime 同时加载相同权重，模型管理器必须记录内存成本；默认优先懒加载，
由共享 admission 防止两条推理路径互相打满资源。

## 4. 建议配置

配置模板见 [`configs/speechrail.example.env`](../configs/speechrail.example.env) 和
[`configs/speechrail.example.yaml`](../configs/speechrail.example.yaml)。关键配置：

```dotenv
SPEECHRAIL_HOST=127.0.0.1
SPEECHRAIL_PORT=8201
SPEECHRAIL_API_KEY=
SPEECHRAIL_MODEL_ID=speechrail/qwen3-asr-1.7b
SPEECHRAIL_QWEN3_MODEL_DIR=/absolute/path/to/Qwen3-ASR-1.7B
SPEECHRAIL_QWEN3_PYTHON=/absolute/path/to/venv/bin/python
SPEECHRAIL_ALLOW_MODEL_DOWNLOADS=false
SPEECHRAIL_MAX_QUEUE_SIZE=8
SPEECHRAIL_MAX_UPLOAD_BYTES=536870912
SPEECHRAIL_MAX_AUDIO_SECONDS=3600
```

`SPEECHRAIL_QWEN3_MODEL_DIR` 和 `SPEECHRAIL_QWEN3_PYTHON` 的目标文件必须可读/可执行，
且模型目录不得位于仓库内。示例中的 `/absolute/path/...` 只是占位符，不能直接复制
运行。

## 5. 启动顺序

```bash
cd /Users/hrygo/Documents/SpeechRail
uv sync --extra dev
uv run speechrail
```

生产式启动顺序：

```text
读取配置
  → 校验监听/认证
  → 校验外部模型快照
  → 校验 runtime Python 和依赖
  → 启动 worker（离线环境）
  → worker identity handshake
  → 短音频 smoke
  → readyz=200
  → 接收客户端请求
```

任一 preflight 失败都保持 `/readyz=503`，不能启动后再偷偷下载或切换到不同设备。

## 6. 进程模型

- 一个 `speechrail` supervisor 进程。
- 一个 batch Qwen3 worker（顺序请求）。
- 一个 realtime WLK worker/sidecar（如果启用 realtime profile）。
- 一个 ASGI worker；不要通过 `--workers N` 复制模型。
- 队列、连接、临时文件和模型生命周期由 supervisor 统一管理。

本机服务首发使用 `parallel=1`。增加并发前必须重新测量 TTFT、RTF、峰值内存、尾延迟、
队列等待和实时余量；仅看到 CPU/GPU 有空闲不能证明并发安全。

## 7. 升级与回滚

升级前记录：

- SpeechRail 版本和 Git commit。
- 模型 snapshot ID/哈希。
- runtime 版本、Python executable 和设备。
- `/v1/models`、`/health`、`/readyz` 输出。
- 代表性短音频的文本、时延和 segment 数量。

升级采用旁路端口 `8201` 验证，确认通过后再切换到兼容端口 `8001`。回滚只需要：

1. 停止新 SpeechRail。
2. 恢复旧 WLK 监听 `8001`。
3. 保持 QwenPaw/voice-realtime 原 URL。
4. Hermes 恢复旧 `STT_OPENAI_BASE_URL`。

不删除模型、不修改原项目 branch、不覆盖原项目 runtime，保证回滚可恢复。
