---
title: "SpeechRail 运维 Runbook"
status: active
date: 2026-08-31
---

# SpeechRail 运维 Runbook

本 Runbook 面向在 macOS 本机运行 SpeechRail 的操作者。首发部署只支持一台机器、一个
服务进程、一个 Qwen3 worker。它不自动安装系统服务，也不会下载或移动模型。

## 上线前清单

确认 Python 3.12、`uv`、`ffmpeg`、完整的仓库外 Qwen3-ASR snapshot，以及包含
`qwen-asr`、PyTorch、NumPy 的专用 Python runtime。`.env` 只能由当前账户读取，且不应
进入 Git。

```bash
cd <path-to-SpeechRail>
cp configs/speechrail.example.env .env
```

最小真实运行配置（路径必须替换为本机实际值，不能提交）：

```dotenv
SPEECHRAIL_HOST=127.0.0.1
SPEECHRAIL_PORT=8201
SPEECHRAIL_QWEN3_MODEL_DIR=/absolute/path/outside/SpeechRail/Qwen3-ASR-1.7B
SPEECHRAIL_QWEN3_PYTHON=/absolute/path/to/qwen3-runtime/bin/python
SPEECHRAIL_ALLOW_MODEL_DOWNLOADS=false
SPEECHRAIL_DEVICE=mps
SPEECHRAIL_DTYPE=float16
SPEECHRAIL_BACKEND_READY=false
# Optional: enables durable owner-scoped job metadata, not model batch execution.
SPEECHRAIL_JOB_SPOOL_DIR=/absolute/path/outside/SpeechRail/job-spool
```

非 loopback 绑定必须配置强随机 `SPEECHRAIL_API_KEY`。当前没有 CORS 实现，且 `/asr`
无认证，因此禁止将服务或该兼容路径直接暴露到 LAN / 公网。`BACKEND_READY` 不是模型
开关；真实部署保持 `false`，由两个 Qwen 路径触发 worker startup。

`SPEECHRAIL_JOB_SPOOL_DIR` 可选；目录必须在仓库外且由当前运行账户私有。设置后服务会在
启动时恢复任务元数据，并将上次异常中断的 `running` 任务标记为
`failed(worker_interrupted)`。仅当部署代码显式注入受信任 `JobProcessor` 时才启动 batch
executor；该 processor 和 realtime 共用 Resource Governor。默认没有 `input_ref` 的路径/URL
resolver，`queued` 不会被自动解释为可读取的模型输入。

## 启动、停止与验收

```bash
cd <path-to-SpeechRail>
uv sync --extra dev
uv run speechrail
```

正常停止前台进程使用 `Ctrl-C`；不要运行多个服务实例或多个 ASGI worker，以免复制模型。
另开终端检查：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
```

`/readyz` 为 200 仅说明推理入口已配置；发布前还要用操作者拥有的非敏感短音频完成一次
REST smoke，确认 HTTP 200、非空文本和 `X-Request-ID`，随后删除音频。

## 启动时加载的模型

| 项目 | 行为 |
|---|---|
| `Qwen/Qwen3-ASR-1.7B` snapshot | 一份，加载到隔离 Qwen3 worker |
| PyTorch + `qwen-asr` | 仅专用 worker Python runtime |
| Apple Silicon device | MPS / `float16`；不允许自动 CPU fallback |
| HTTP 服务依赖 | 主 `uv` 环境中的 FastAPI 等，不加载模型权重 |

它不会加载 Whisper、第二个 ASR 模型、WLK sidecar、LM Studio chat/embedding 模型、TTS
模型或 `voice-realtime` 的会议组件。未配置 snapshot/runtime 时不会加载任何模型，推理
请求返回 `503 backend_not_ready`。

## macOS `launchd` 常驻安装

项目提供 [plist 模板](../deploy/macos/com.speechrail.plist.example)。它不是安装文件：先将
项目目录、`uv` 可执行文件和两个日志文件的 `<...>` 占位符替换为当前用户绝对路径，并
确认 `.env` 位于项目目录。然后执行：

```bash
mkdir -p "$HOME/Library/Logs/SpeechRail"
cp deploy/macos/com.speechrail.plist.example "$HOME/Library/LaunchAgents/com.speechrail.plist"
# 编辑复制后的 plist，替换所有 <...> 占位符。
plutil -lint "$HOME/Library/LaunchAgents/com.speechrail.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.speechrail.plist"
launchctl kickstart -k "gui/$(id -u)/com.speechrail"
```

查看状态与日志：

```bash
launchctl print "gui/$(id -u)/com.speechrail"
tail -f "$HOME/Library/Logs/SpeechRail/stdout.log"
tail -f "$HOME/Library/Logs/SpeechRail/stderr.log"
```

停用但保留 plist：

```bash
launchctl bootout "gui/$(id -u)/com.speechrail"
```

`LaunchAgent` 仅在用户登录后的 GUI session 运行，适合 MPS 本机服务；每次 Agent
重启都会重新加载模型。

## 故障定位

| 现象 | 首先检查 | 处理 |
|---|---|---|
| `/health` 无响应 | 进程、`launchctl print`、端口、stderr | 修正端口/服务配置后仅启动一个实例 |
| `/readyz` 为 503 | snapshot/Python 路径、权限、worker stderr | 修正外部路径；不要用 `BACKEND_READY=true` 掩盖问题 |
| snapshot 不完整 | 是否仓库外、必要文件是否齐全 | 重新获取完整同一 revision 的 snapshot |
| MPS/dtype 报错 | MPS 可用性、`mps` + `float16` 配对 | 修复 runtime；CPU 部署要同时用 `cpu` + `float32` |
| 转写 422 | 音频 Content-Type、容器、ffmpeg PATH | 使用音频文件并修复 ffmpeg 环境 |
| 转写 429/503 | 队列、worker stderr、资源压力 | 按 `retryable` / `Retry-After` 有界重试，不复制模型 |
| QwenPaw 失败 | provider URL/model、完整重启、REST curl | 先使 REST smoke 通过再检查客户端 |

排障记录只保留时间、版本、request ID、错误码、耗时、设备/dtype 与资源摘要；不要收集
API key、Authorization、音频、Base64、完整 prompt 或转写正文。

## 升级与回滚

升级以可回退的版本目录/提交为单位：停止前台服务或 `launchctl bootout`，在新版本运行
测试和真实 worker smoke，再更新服务指向并验证三项健康端点与客户端。保留原 `.env` 和
模型 snapshot；不要通过 `git reset --hard` 丢弃配置。

服务回滚为：停止新进程，恢复上一个已验证版本工作目录与 `.env`，启动后完成 REST smoke。
QwenPaw 回滚只恢复转写 provider 的 base URL/model 并完整重启。Hermes 与
`voice-realtime` 尚未迁入；未来切换须使用[迁移 Runbook](08-migration-runbook.md)，不能
假定 `/asr` 已有 WLK 转写 parity。
