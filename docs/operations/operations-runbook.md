---
title: "SpeechRail 运维 Runbook"
status: active
date: 2026-08-31
---

# SpeechRail 运维 Runbook

本 Runbook 面向在 macOS 本机运行 SpeechRail 的操作者。首发部署只支持一台机器、一个
服务进程、每个已配置 profile 一个隔离 worker。它不自动安装系统服务，也不会下载或移动模型。

## 上线前清单

确认 Python 3.12、`uv`、`ffmpeg`、完整的仓库外 Qwen3-ASR snapshot，以及包含
`qwen-asr`、PyTorch、NumPy 的 ASR runtime。启用 TTS 另需一个可导入 `mlx_audio` 的专用
Python runtime 与本机 MLX Qwen3-TTS VoiceDesign snapshot。`.env` 只能由当前账户读取，且不应
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
# Optional external local WLK sidecar; leave commented until its independent smoke passes.
# SPEECHRAIL_WLK_STREAMING_URL=ws://127.0.0.1:8001
# Optional Realtime v2 diarization profile. Sortformer enables online anonymous labels;
# CAM++ additionally enables bounded cross-reconnect anonymous remaps.
# SPEECHRAIL_DIARIZATION_MODEL_PATH=/absolute/path/outside/SpeechRail/diar_streaming_sortformer_4spk-v2.nemo
# SPEECHRAIL_DIARIZATION_EMBEDDING_MODEL_PATH=/absolute/path/outside/SpeechRail/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx
# SPEECHRAIL_DIARIZATION_MAX_BUFFER_BYTES=8388608
# SPEECHRAIL_DIARIZATION_MAX_GROUPS=64
# SPEECHRAIL_DIARIZATION_GROUP_TTL_SECONDS=900
# SPEECHRAIL_DIARIZATION_SIMILARITY_THRESHOLD=0.8
# Optional external TTS runtime; both paths are required before its worker starts.
# SPEECHRAIL_QWEN3_TTS_MODEL_DIR=/absolute/path/outside/SpeechRail/Qwen3-TTS-VoiceDesign
# SPEECHRAIL_QWEN3_TTS_PYTHON=/absolute/path/to/qwen3-tts-runtime/bin/python
# SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS=false
# SPEECHRAIL_TTS_VOICE_IDS=["default","warm","bright","calm"]
# SPEECHRAIL_TTS_WARMUP_ON_START=true
```

非 loopback 绑定必须配置强随机 `SPEECHRAIL_API_KEY`。当前没有 CORS 实现，且 `/asr`
无认证，因此禁止将服务或该兼容路径直接暴露到 LAN / 公网。`BACKEND_READY` 不是模型
开关；真实部署保持 `false`，由各 profile 成对配置的外部路径触发 worker startup。

`SPEECHRAIL_JOB_SPOOL_DIR` 可选；目录必须在仓库外且由当前运行账户私有。设置后服务会在
启动时恢复任务元数据，并将上次异常中断的 `running` 任务标记为
`failed(worker_interrupted)`。仅当部署代码显式注入受信任 `JobProcessor` 时才启动 batch
executor；该 processor 和 realtime 共用 Resource Governor。默认没有 `input_ref` 的路径/URL
resolver，`queued` 不会被自动解释为可读取的模型输入。

`SPEECHRAIL_WLK_STREAMING_URL` 也是可选项。配置后，`/v2/realtime` transcription session
会连接已运行的外部 WLK endpoint，并在服务内归一化 partial/completed 事件；SpeechRail 不
管理该进程。两条 TTS 外部路径同时配置后会启动一个隔离 worker；该 runtime 必须已安装兼容
依赖并具有完整 local snapshot，服务本身始终设置离线环境变量。

## wheel 本地安装

开发者使用 `uv sync`；分发安装使用 wheel 和仓库外的本地安装器。安装器负责创建用户私有 app
home、专用 venv、配置副本和 LaunchAgent；它不下载或复制模型，也不覆盖已有 `.env`。

```bash
cd <release-directory>
uv build --no-sources --wheel
python3 tools/install_macos.py \
  --wheel <wheel-file> \
  --env-file <private-env-file> \
  --app-home "$HOME/Library/Application Support/SpeechRail"
```

安装器默认不启用服务。只有在 preflight 通过后，才使用 `--enable` 让它注册并启动 LaunchAgent；
若只需要 ASR，必须明确使用 `--asr-only`。安装后使用发布验收脚本检查当前 runtime：

```bash
python3 scripts/verify_release.py \
  --wheel <wheel-file> \
  --app-home "$HOME/Library/Application Support/SpeechRail"
```

升级必须先在新的 runtime 中安装 wheel、执行 preflight 和真实 ASR/TTS smoke，再切换
`runtime/current`、重新写入 plist 并执行 `service restart`。若新 runtime 未通过检查，保留旧
`current` 和已加载服务；回滚只恢复旧 runtime 指针并重启，不删除模型、配置或用户数据。

## 启动、停止与验收

```bash
cd <path-to-SpeechRail>
uv sync --extra dev --extra diarization
uv run speechrail
```

正常停止前台进程使用 `Ctrl-C`；不要运行多个服务实例或多个 ASGI worker，以免复制模型。
另开终端检查：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl -i http://127.0.0.1:8201/v1/voices
```

`/readyz` 为 200 仅说明推理入口已配置；发布前还要用操作者拥有的非敏感短音频完成一次
REST ASR smoke，确认 HTTP 200、非空文本和 `X-Request-ID`，随后删除音频。启用 TTS 后，使用
`POST /v1/audio/speech` 请求 `speechrail/qwen3-tts`、登记 voice 和 `response_format=pcm`，确认
HTTP 200、非空且偶数字节的 24 kHz PCM16；不得记录输入文本或输出音频。

`/v1/voices` 是独立的 preset 目录路由；按当前代码，即使 TTS worker 未 ready 也应返回 HTTP 200，
并在条目中标记 `available=false`。如果运行态返回 404，先核对请求的 base URL、`8201` 端口、运行中的进程
和服务是否已重启；这不是缺少 TTS runtime 配置的直接表现。Creator 等客户端要完成 TTS 合成，必须在
SpeechRail 的 `.env` 中同时配置 `SPEECHRAIL_QWEN3_TTS_MODEL_DIR` 与 `SPEECHRAIL_QWEN3_TTS_PYTHON`，
然后重启服务；缺少任一配置时，`/v1/audio/speech` 预期返回 `503 backend_not_ready`。

## 启动时加载的模型

| 项目 | 行为 |
|---|---|
| `Qwen/Qwen3-ASR-1.7B` snapshot | 配置 ASR 路径时加载一份到隔离 Qwen3 worker |
| MLX Qwen3-TTS VoiceDesign snapshot | 仅在两条 TTS 外部路径都配置时加载一份到隔离 worker；公开 preset 为 `default`、`warm`、`bright`、`calm` |
| WLK sidecar | 从不由 SpeechRail 启动；仅配置 endpoint 时作为 v2 流式 ASR transport |
| Sortformer diarization snapshot | 仅配置 `SPEECHRAIL_DIARIZATION_MODEL_PATH` 后按首个 diarization session 惰性载入；仅产生匿名 label |
| CAM++ embedding snapshot | 仅同时配置 CAM++ 路径和 Sortformer profile 时，按首次需要短片段 embedding 的请求惰性载入；只保留有界短期匿名质心 |
| PyTorch + `qwen-asr` | 仅专用 worker Python runtime |
| Apple Silicon device | MPS / `float16`；不允许自动 CPU fallback |
| HTTP 服务依赖 | 主 `uv` 环境中的 FastAPI 等，不加载模型权重 |

它不会加载 Whisper、LM Studio chat/embedding 模型或 `voice-realtime` 的会议组件。未配置
对应 snapshot/runtime 时不会加载该 profile；请求会安全返回 `503 backend_not_ready`。

## 说话人分离 profile

Realtime v2 transcription 客户端显式设置 `diarization.enabled=true` 才启用。Sortformer 缓冲
PCM 的上限由 `SPEECHRAIL_DIARIZATION_MAX_BUFFER_BYTES` 强制；超过上限返回
`buffer_limit_exceeded`。CAM++ 不保存 embedding；仅当客户端提供不透明 `group_id` 时，服务在
`MAX_GROUPS` 和 `GROUP_TTL_SECONDS` 限制内保留匿名归一化质心，并在 commit 前发出可选 remap。
不要把 `group_id` 设置为姓名、邮箱、会议标题或数据库主键。

真实模型验收必须使用操作者有权处理的评测音频，至少记录实时延迟、DER/JER、重连 label
稳定率与人工更正率；不把音频、embedding、转写原文或 group ID 写入日志。发现质量退化时，
先移除两条 diarization 模型路径并重启服务；此操作只关闭该可选 profile，不影响 ASR/TTS。

## macOS `launchd` 常驻安装

SpeechRail 提供 `LaunchAgent` CLI；它只管理当前登录用户的 GUI session，适合 MPS 本机服务，
不是 root `LaunchDaemon`，也不在登录前运行。先确认项目目录中的 `.env` 已配置并且当前
`.venv` 已通过 `uv sync` 创建。安装命令使用当前 `.venv` 的 Python 和当前目录作为工作目录，
不把 `.env`、API key、模型路径或音频复制进 plist：

```bash
cd <path-to-SpeechRail>
uv run speechrail service install
```

`install` 仅写入 `$HOME/Library/LaunchAgents/com.speechrail.plist` 和私有日志目录，**不会**
启动服务或加载模型。完成 plist 检查后显式启用：

```bash
plutil -lint "$HOME/Library/LaunchAgents/com.speechrail.plist"
uv run speechrail service enable
uv run speechrail service status
```

日常状态、重启、停用和卸载：

```bash
uv run speechrail service status
uv run speechrail service restart
uv run speechrail service disable       # 停止但保留已生成的 plist
uv run speechrail service uninstall     # 停止、卸载并删除 plist
```

服务日志位于 `$HOME/Library/Logs/SpeechRail/stdout.log` 和 `stderr.log`。当升级依赖、移动
工作目录或重建 `.venv` 时，执行 `disable` → 在新工作目录运行 `install` → `enable`，以免
已加载的 launchd job 继续引用旧 Python。`launchctl print "gui/$(id -u)/com.speechrail"` 仅用于
CLI 无法提供足够诊断时的恢复排障。每次服务进程重启都会重新加载已配置模型。

项目仍保留 [plist 模板](../../deploy/macos/com.speechrail.plist.example) 供审计或手工恢复；
模板中的占位符必须替换为当前账户绝对路径，且其 `ProgramArguments` 必须使用 Python module
入口，不能恢复为 shell 或 `uv run`。

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
| diarization 不可用 | Sortformer/CAM++ 路径、`uv sync --extra diarization`、stderr | 修复外部路径或依赖；不要以单 speaker 结果替代失败 |
| label 重连不稳定 | group TTL/容量、短片段比例、评测指标 | 调整受控阈值并重新评测；不要扩大 PCM/embedding 留存 |

排障记录只保留时间、版本、request ID、错误码、耗时、设备/dtype 与资源摘要；不要收集
API key、Authorization、音频、Base64、完整 prompt 或转写正文。

## 升级与回滚

升级以可回退的版本目录/提交为单位：停止前台服务或 `launchctl bootout`，在新版本运行
测试和真实 worker smoke，再更新服务指向并验证三项健康端点与客户端。保留原 `.env` 和
模型 snapshot；不要通过 `git reset --hard` 丢弃配置。

服务回滚为：停止新进程，恢复上一个已验证版本工作目录与 `.env`，启动后完成 REST smoke。
QwenPaw 回滚只恢复转写 provider 的 base URL/model 并完整重启。`voice-realtime` adapter
已经实现但未完成真实切换；启用、影子、回滚均须使用[迁移 Runbook](migration-runbook.md)，
不能假定 `/asr` 已有 WLK 转写 parity。
