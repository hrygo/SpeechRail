---
title: "SpeechRail 运行时与部署"
status: active
version: "3.1.0"
date: 2026-09-21
---

# SpeechRail 运行时与部署

本页说明当前实际运行组成；日常操作以[运维 Runbook](operations-runbook.md) 为准。

停启、安装和 profile 切换的唯一安全边界见 [本机 operator contract](../../.agents/skills/speechrail-local-deploy/references/operator-contract.md)；本页只描述运行时拓扑和制品布局。macOS App 的独立构建、签名、安装、清理和回滚见 [App 分发 SOP](../developers/macos-app-release.md)。

## 运行拓扑

```text
客户端 ── HTTP / WS ──> FastAPI（uv 环境）
                           │
                           ├─ 有界 admission queue / Resource Governor
                           ├─ 固定 ffmpeg 解码（REST ASR）
                           ├─ Qwen3 ASR worker（专用 Python）
                           │      └─ 外部 Qwen3-ASR snapshot
                           ├─ 可选 Swift/CoreML diarization worker（惰性启动）
                           │      └─ 外部 FluidAudio Sortformer FP16 `.mlmodelc`
                           └─ Qwen3 TTS capability workers（专用 Python，可选）
                                  ├─ 外部 VoiceDesign snapshot
                                  └─ 外部 Base clone snapshot（Quality）
```

![三档模型与 Quality 双 TTS capability 关系图](../architecture/diagrams/three-tier-model-architecture.svg)

ASR worker 仅在同时设置 `SPEECHRAIL_QWEN3_MODEL_DIR` 与 `SPEECHRAIL_QWEN3_PYTHON` 时
创建并由 ASGI lifecycle 管理；TTS capability worker 仅在对应 TTS 路径同时设置时创建，Quality
可创建 VoiceDesign 与 Base 两个独立 worker，并允许两者同时常驻。是否在 startup 还是首次请求加载权重由
`SPEECHRAIL_WORKER_LAZY_LOAD` 决定；加载后 capability 路由不会互相卸载。不同 lane 可并发，同一 lane
仍由对应 worker 串行；`SPEECHRAIL_WORKER_IDLE_TIMEOUT_SECONDS` 到期后，Quality 两个 worker 作为一个
capability group trim/close，下一次请求再惰性恢复所需 worker。
主进程与 worker 使用长度前缀 JSON 私有协议，ASR worker 接受 16 kHz / 单声道 / PCM16 音频，
TTS worker 输出 24 kHz / 单声道 / PCM16。模型目录和 diarization 权重不在仓库内；请求路径
不会下载模型。

## 三档组成与按档位精度（catalog v2）

`catalog schema_version=2` 用顶层 `precision_policy` 取代旧的“全档 8-bit”规则，并按用户定位重排三档。
其中 `light` 的 4-bit 候选在验收门 E1 未通过（公开真人语料劣化 1.38pp > 0.5pp）后已回退到 8-bit，
现行精度策略为三档均 8-bit、仅 `quality` aligner 为 bf16。档位仍然只选择权重与量化，公共 API 形状、
worker 协议、调度与进程隔离保持不变；Quality 的 VD/Base 是新增的两条 capability lane（ADR-0011；
三档组成重排见 ADR-0015）。

| profile | ASR | TTS | Aligner（分人专用） | Diarization | VAD | 安装体积 |
|---|---|---|---|---|---|---|
| `light`（Embedded） | `asr-0.6b-q8`（8-bit） | `tts-0.6b-custom-q8`（8-bit） | —（无） | ✗ | ✓ | **≈2.99 GB** |
| `balanced`（Pro Workflow） | `asr-1.7b-q8`（8-bit） | `tts-0.6b-custom-q8`（8-bit） | `aligner-q8`（8-bit） | ✓ | ✓ | **≈5.96 GB** |
| `quality`（Studio） | `asr-1.7b-q8`（8-bit） | primary `tts-1.7b-design-q8` + clone `tts-1.7b-base-q8`（两个 8-bit worker，可双常驻/并发） | `aligner-bf16`（bf16） | ✓ | ✓ | **≈10.73 GB** |

- aligner 是**分人专用制品**，不进入 `PreparedModelSet` / `prepare_models`；它由安装器与 `profile apply` 经
  `diarization_assets.prepare_diarization_assets(app_home, preset_id=..., downloader=...)` 供给到
  `app_home/diarization/<aligner-key>`（`aligner-q8` / `aligner-bf16`）。
- `light` 不供给 Sortformer 与 aligner：`prepare_diarization_assets` 返回 `None`，不写
  `SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH` / `SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR`。
- 内置 BF16 `Qwen3-ForcedAligner-0.6B` Hugging Face 常量已移除；aligner revision 与逐文件哈希随 catalog 锁定。
- 词级时间戳由 ASR 原生提供，与 aligner 无关；aligner 只在分人路径对固定正文做对齐。
- managed 三档使用 catalog 固定的 tier aligner（`balanced` → `aligner-q8`、`quality` → `aligner-bf16`）；`configs/*.example.*` 里的 `Qwen3-ForcedAligner-0.6B` 只是手工显式环境（manual explicit env）的示例占位，不是 managed 路径实际供给的资产。
- `speechrail profile apply <tier>` 按上述组成切换，顺序固定为：准备模型 → 准备可选 VAD → 准备分人制品 →
  切换 selection。分人档位写入两条分人路径键；`light` 则移除它们。

## 模型与设备 profile

| profile | 模型 | device / dtype | 启动行为 |
|---|---|---|---|
| 默认 Apple Silicon | Qwen3-ASR-1.7B | `mps` / `float16` (默认) 或 `int8` (内存优化) | 启动时加载一份，拒绝 CPU fallback；本机已验证 |
| 有意 CPU 部署 | Qwen3-ASR-1.7B | `cpu` / `float32` (默认) 或 `int8` | 启动时加载一份；性能基准待对应硬件验收 |
| 未配置 runtime | 无 | 无 | 进程可启动；推理返回 `503 backend_not_ready` |
| TTS runtime 成对配置 | Qwen3-TTS VoiceDesign + Quality Base clone capability | `mps` / `float16` 或 `cpu` / `float32`；预量化 `-8bit` 快照时解析为 `int8` | `light`/`balanced` 使用 CustomVoice；`quality` 可独立加载 VoiceDesign 与 Base 两个 worker；TTS 未就绪不阻塞 ASR；TTS 支持预量化 `-8bit` MLX 快照（`speech_tokenizer` codec 恒为 FP32、embedding/norm 为 BF16），不再要求运行时只能 float16/float32 |
| diarization profile | 私有 Swift/CoreML Sortformer FP16 worker | 活跃会话时惰性启动；仅一条连续状态链路 | `/v1/audio/transcriptions` 的 `gpt-4o-transcribe-diarize` / `diarized_json`；Realtime 通过 `session.speechrail.diarization.enabled` opt-in；只保留有界匿名状态 |

SpeechRail 不依赖或加载 LM Studio chat/embedding 模型、Whisper 或 `sona` 组件。

## 配置

从 [环境示例](../../configs/speechrail.example.env) 复制到被忽略的 `.env`。关键键如下：

| 键 | 用途 |
|---|---|
| `SPEECHRAIL_HOST` / `PORT` | 默认 `127.0.0.1:8201` |
| `SPEECHRAIL_QWEN3_MODEL_DIR` | 仓库外完整 snapshot 的绝对路径 |
| `SPEECHRAIL_QWEN3_PYTHON` | 专用 worker Python 可执行文件 |
| `SPEECHRAIL_QWEN3_TTS_MODEL_DIR` / `SPEECHRAIL_QWEN3_TTS_PYTHON` | 可选、成对配置的默认 TTS snapshot/runtime |
| `SPEECHRAIL_QWEN3_TTS_CLONE_MODEL_DIR` | Quality 独立 Base clone worker 的 snapshot；managed profile 由 catalog/selection 自动注入，手工部署时需显式配置；未配置则不声明 `supports_clone` |
| `SPEECHRAIL_TTS_VOICE_IDS` | 服务器登记的 TTS preset 列表 |
| `SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS` | 必须为 `false`；TTS worker 仅使用外部完整 snapshot |
| `SPEECHRAIL_DEVICE` / `DTYPE` | `mps`（支持 `float16` 默认 / `int8` 优化）或 `cpu`（支持 `float32` / `int8`）；`int8` 仅作用于非预量化快照的 ASR Worker；TTS Worker 不做运行时量化，默认 `float16`（mps）/ `float32`（cpu），预量化 `-8bit` 快照自动解析为 `int8` |
| `SPEECHRAIL_MAX_QUEUE_SIZE` | 同时等待/执行任务的有界队列大小 |
| `SPEECHRAIL_MAX_UPLOAD_BYTES` | REST 上传的强制字节上限 |
| `SPEECHRAIL_MAX_REALTIME_*` | WebSocket 单帧和缓存字节上限 |
| `SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` | 一个 worker 调用的 deadline |
| `SPEECHRAIL_JOB_SPOOL_DIR` | 可选、仓库外绝对 SQLite spool；启用 `/v1/jobs` 元数据与启动恢复 |
| `SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH` | 分人档位（`balanced`/`quality`）由 `profile apply` 供给到 `app_home/diarization/` 的 `SortformerNvidiaLow_v2.1.mlmodelc` bundle 绝对路径；`light` 不设置 |
| `SPEECHRAIL_DIARIZATION_WORKER_PATH` | 可选覆盖；未设置时使用 macOS wheel 内置的 `SpeechRailDiarizationWorker` |
| `SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR` | 分人档位由 `profile apply` 写入 `app_home/diarization/<aligner-key>` 的 tier 专用 aligner snapshot；私有 ASR worker 仅对固定正文调用它，不再次识别音频；`light` 不设置 |
| `SPEECHRAIL_WORKER_IDLE_TIMEOUT_SECONDS` | 可驱逐组件的空闲超时，默认 `300` 秒；`0` 禁用；Quality 的 VD/Base 作为一个 TTS 能力组一起驱逐；物理内存回收取决于运行时 |
| `SPEECHRAIL_API_KEY` | 非 loopback 绑定必填；loopback 可为空 |
| `SPEECHRAIL_LOG_DIR` | 轮转日志目录，默认 `~/Library/Logs/SpeechRail`；服务在其中写 `speechrail.log`（人读）与 `access.jsonl`（每行一个 JSON 记录），各 8 MiB × 5 份 |
| `SPEECHRAIL_METRICS_ROLLUP_DIR` | 历史指标目录；受管安装默认 `{app_home}/state/metrics-rollup`，源码检出须显式设置才启用 |
| `SPEECHRAIL_METRICS_ROLLUP_INTERVAL_SECONDS` | 摘要写入间隔，默认 `60` 秒（5–3600） |
| `SPEECHRAIL_METRICS_ROLLUP_RETENTION_DAYS` | 摘要文件保留天数，默认 `30`；按 UTC 日期文件名清理 |
| `SPEECHRAIL_METRICS_ROLLUP_ENABLED` | 设为 `false` 关闭滚动摘要 |

`SPEECHRAIL_ALLOW_MODEL_DOWNLOADS` 必须为 `false`。`allowed_origins` 与
`SPEECHRAIL_MAX_AUDIO_SECONDS` 是预留配置字段：CORS middleware 与解码后时长拒绝逻辑
不在当前能力范围，不应视为已启用的安全/容量控制。

`speechrail-zero-setup` 在空白 Mac 上按**所选档位**准备 diarization：仅当 `preset.diarization` 为真时，从固定
Hugging Face revision 下载并逐文件校验 `v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc`，并从 catalog 供给该档 aligner
（`balanced` 用 `aligner-q8`、`quality` 用 `aligner-bf16`）到 `app_home/diarization/<aligner-key>`，再把两条绝对
路径写入私有配置。`light` 档不供给任何分人制品，也不运行分人 smoke。常规 managed 升级保留已有私有配置；如需首次
手工安装，则须预先准备同一套仓库外部制品并设置两条路径。wheel 会随包安装锁定 revision 的
`SpeechRailDiarizationWorker`，通常不必设置 worker 路径；仅在受控排障或自定义 release 目录时才覆盖它。服务不会
在请求路径下载、编译或切换模型；worker 直接以 `computeUnits=.all` 加载已编译 bundle。重启后用 `/health` 与
`/v1/models` 检查 profile 是否就绪（`light` 的 `/v1/models` 不含 `gpt-4o-transcribe-diarize`）。D1 的 564 MB max
RSS 是单次 smoke 证据，不是质量、P95 或通用物理内存承诺。

启用 job spool 时，目录须是项目外的绝对路径，并由运行账户独占。服务以 `0700` 创建目录、
以 `0600` 创建数据库，保存的仅是 owner 指纹、任务状态和不透明输入/结果引用；不保存原始
音频或完整转写。重启会将未完成的 `running` 任务标为 `failed(worker_interrupted)`。部署
代码可显式注入受信任 `JobProcessor` 后启动 batch executor；它和 realtime 共用 Resource
Governor。默认部署不包含内建的 `input_ref` 路径/URL resolver，不自动读取外部引用。

## wheel 与本地安装器

发布安装与源码开发分开处理。macOS wheel 会编译并包含私有 CoreML diarization executable；其
wheel tag 因而与当前 Python/Apple Silicon 平台绑定。ASR/TTS vendor runtime、全部模型 snapshot、
`ffmpeg` 和 `.env` 仍由本机预先准备，CoreML bundle 也不打进 wheel。

managed 安装器随 wheel 发布，对用户暴露为 `speechrail install`。安装者只需要下载下来的 wheel，
不必 clone 仓库，下载目录里执行

```bash
uvx --python 3.12 --from ./speechrail-<version>-cp312-cp312-macosx_26_0_arm64.whl \
  speechrail install --preset balanced --yes --enable
```

即可完成 release staging、模型准备、preflight、LaunchAgent 与原子 `runtime/current` 切换。
内部安装实现不构成面向用户的第二入口。

### 源码到 managed runtime 的不变量（2026-09-09）

SpeechRail 的任何修复、协议变更或 worker 变更都必须先落在本源码仓库，再由源码构建 wheel；managed runtime 只消费 wheel release。禁止直接编辑 `runtime/current`、release venv 或 worker 安装目录，因为这些修改会在下一次 release 切换时丢失且无法审计。

最小发布顺序：

1. 在 SpeechRail 源码根目录完成测试、类型、lint、契约与 `git diff --check`。
2. 使用 `uv build --no-sources --wheel` 构建当前源码 wheel。
3. 按 operator contract 安全停旧服务并确认 lock 释放；再通过 wheel 自带的 `speechrail install`
   做候选 release preflight、LaunchAgent 安装和原子 `runtime/current` 切换。
4. 使用 lifecycle controller 启动新 runtime，通过 `/health`、`/readyz`、`/v1/models` 和目标 Realtime smoke 验证；任何失败都恢复旧 current/runtime。

源码构建与安装沿用下方唯一的 managed installer 示例，避免维护两份可能漂移的命令。

验证时应记录当前 release 路径、package version、health readiness 和 smoke 摘要，不记录密钥、完整参考文本、PCM 或模型绝对路径。

在发布目录中构建，并通过 wheel 自带的唯一 managed installer 安装：

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
uv build --no-sources --wheel
WHEEL="dist/speechrail-<version>-cp312-cp312-macosx_26_0_arm64.whl"
uvx --python 3.12 --from "$WHEEL" speechrail install --preset quality --yes --enable
```

managed installer 会准备新 release、执行 preflight、更新 LaunchAgent 并原子切换 `runtime/current`；
`--enable` 会通过 lifecycle controller 启动服务。启动或 smoke 失败会停止候选并恢复旧
`runtime/current`。完整安装要求当前 profile 所需的 runtime、snapshot 和可选能力全部通过检查；
私有 `.env` 可作为 managed 初始化配置输入，但不会被覆盖或写入 wheel。

升级先在候选 release 上完成 preflight，再由 installer 原子切换
`runtime/current`，随后启动并完成真实 ASR/TTS smoke；失败时恢复旧 `current`。README 不固定发布版本，包文件名和 package
metadata 仍保留用于升级、回滚和审计的版本信息。

> [!IMPORTANT]
> **profile 能力前置条件**：`balanced`/`quality` 的分人制品和 `quality` 的 Base clone 制品由当前
> managed installer 按 catalog 供给并在 preflight 校验；任一制品缺失或校验失败时，候选不会切换为
> `runtime/current`。服务不会在请求路径静默下载或降级为未声明的能力。

若 private `.env` 设置 `SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH`，managed installer 会将该
release 作为分人 profile 安装并在 preflight 中检查 CoreML bundle、wheel 内
`SpeechRailDiarizationWorker` 与 fixed-text aligner snapshot（aligner 校验由 `preset.aligner` 驱动，
`light` 无 aligner 时跳过）。切换后还须确认 `/v1/models` 包含 `gpt-4o-transcribe-diarize`；任何一项
失败都不切换 `runtime/current`，或恢复上一 release。

## app home 目录与重建边界（2026-09-21）

服务 app home 默认为 `~/Library/Application Support/SpeechRail`，也可以通过
`SPEECHRAIL_APP_HOME` 指定。它只描述 managed service 的 runtime、配置、模型和状态目录；macOS App 的会话
数据是另一条用户资产边界。当前 App 默认使用 `~/Library/Application Support/SpeechRail/sessions.sqlite3`
与同层的 `Works/`，不因服务的 `SPEECHRAIL_APP_HOME` 设置而自动迁移。

| 目录或文件 | 当前用途 | 是否可重建 | 处理原则 |
|---|---|---:|---|
| `runtime/`、`vendor/` | managed release、Python runtime 与 vendor 运行环境 | 是 | 由 wheel installer 重建，不直接编辑 |
| `models/`、`diarization/` | 模型 snapshot、CoreML bundle 与 aligner 制品 | 是 | 可重新准备；删除后必须重新下载或准备对应制品 |
| `state/`、`artifacts/`、`benchmarks/`、`app-archive/`、`app-releases/`、`app-backups/` | 运行状态、构建或验收产物（按当前流程可能不存在） | 是 | 不作为服务公共数据契约；清理前确认不再需要证据 |
| `config/.env`、selection | 私有配置与当前 profile 选择 | 可重新配置，但秘密不可恢复 | 需要保留配置时由用户自行备份；不得写入仓库或日志 |
| `~/.speechrail/custom_voices.json`、`~/.speechrail/voices/` | 当前 custom voice registry、参考音频与校验状态 | 否（删除即丢失） | 需要保留自定义音色时由用户自行备份；当前没有自动搬迁到 app home 的实现 |
| `~/Library/Application Support/SpeechRail/sessions.sqlite3` | App 会话、文字记录、纪要与记忆 | 否（删除即丢失） | 设置 → 助手 → 记录库可备份该单文件；当前备份不包含 `Works/`、配置或 custom voice |
| `~/Library/Application Support/SpeechRail/Works/` | App 作品索引与作品音频 | 否（删除即丢失） | 需要保留时由用户自行复制；当前没有完整数据区备份入口 |

当前没有正式的旧路径迁移、数据导入、完整数据区备份或 Time Machine 自动排除契约；但 App 已提供会话库单文件
备份入口。重装、升级和重建均以当前代码与 installer 行为为准；不要把单文件备份误认为完整数据区备份。

### 重装、卸载与重建

| 动作 | 当前语义 |
|---|---|
| 换服务版本（wheel 替换） | installer 准备候选 release、执行 preflight，再原子切换 `runtime/current`；失败时恢复旧 release。 |
| `speechrail service uninstall` | 按 operator contract 停止并移除 LaunchAgent；不会自动删除 app home、模型、配置或 custom voice。 |
| 重装 App | 只替换 `~/Applications/SpeechRail.app`；不改变服务 runtime 和模型。 |
| 需要干净重建 | 停止服务后，用户可删除明确选定的可重建目录，再按首装流程重新准备；删除会话库、`Works/`、配置或 custom voice 前必须先自行备份。 |

项目不承诺在旧数据格式、旧路径或旧注册表之间自动迁移。当前用户可以删除并重建运行时、模型和状态；这不等于
可以恢复已删除的会话库、作品、私有配置、custom voice registry 或参考音频。任何跨机器复制都属于用户自行
备份与恢复，不是服务提供的迁移流程。

## 端口与进程策略

默认端口 `8201` 供 SpeechRail 使用。一次只启动一个
SpeechRail 进程；每个已配置 profile 按 capability 启动对应 worker，Quality 最多两个 TTS worker。
多 ASGI worker 或重复服务实例
会产生多份模型载入和不可控内存压力。

需要常驻运行时使用 macOS `LaunchAgent`，而不是将 MPS 服务作为系统级 `LaunchDaemon`。
通过 `speechrail service install`、`enable`、`status`、`restart`、`disable` 和 `uninstall`
管理；`install` 不会启动模型。模板、安装步骤和回滚顺序见[运维 Runbook](operations-runbook.md)。
