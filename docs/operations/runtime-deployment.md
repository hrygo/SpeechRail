---
title: "SpeechRail 运行时与部署"
status: active
date: 2026-09-11
---

# SpeechRail 运行时与部署

本页说明当前实际运行组成；日常操作以[运维 Runbook](operations-runbook.md) 为准。

停启、安装和 profile 切换的唯一安全边界见 [本机 operator contract](../../.agents/skills/speechrail-local-deploy/references/operator-contract.md)；本页只描述运行时拓扑和制品布局。

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
                           └─ Qwen3 TTS worker（专用 Python，可选）
                                  └─ 外部 VoiceDesign snapshot
```

ASR worker 仅在同时设置 `SPEECHRAIL_QWEN3_MODEL_DIR` 与 `SPEECHRAIL_QWEN3_PYTHON` 时
创建并由 ASGI lifecycle 管理；TTS worker 仅在对应两条 TTS 路径同时设置时创建。是否在
startup 还是首次请求加载权重由 `SPEECHRAIL_WORKER_LAZY_LOAD` 决定。
主进程与 worker 使用长度前缀 JSON 私有协议，ASR worker 接受 16 kHz / 单声道 / PCM16 音频，
TTS worker 输出 24 kHz / 单声道 / PCM16。模型目录和 diarization 权重不在仓库内；请求路径
不会下载模型。

## 三档组成与按档位精度（catalog v2）

`catalog schema_version=2` 用顶层 `precision_policy` 取代旧的“全档 8-bit”规则，并按用户定位重排三档。
其中 `light` 的 4-bit 候选在验收门 E1 未通过（公开真人语料劣化 1.38pp > 0.5pp）后已回退到 8-bit，
现行精度策略为三档均 8-bit、仅 `quality` aligner 为 bf16。档位仍然只选择权重与量化，公共 API 形状、
worker 协议、调度与并发保持不变（ADR-0011；三档组成重排见 ADR-0015）。

| profile | ASR | TTS | Aligner（分人专用） | Diarization | VAD | 安装体积 |
|---|---|---|---|---|---|---|
| `light`（Embedded） | `asr-0.6b-q8`（8-bit） | `tts-0.6b-custom-q8`（8-bit） | —（无） | ✗ | ✓ | **≈2.99 GB** |
| `balanced`（Pro Workflow） | `asr-1.7b-q8`（8-bit） | `tts-0.6b-custom-q8`（8-bit） | `aligner-q8`（8-bit） | ✓ | ✓ | **≈5.96 GB** |
| `quality`（Studio） | `asr-1.7b-q8`（8-bit） | primary `tts-1.7b-design-q8` + on-demand clone `tts-1.7b-base-q8`（均 8-bit） | `aligner-bf16`（bf16） | ✓ | ✓ | **≈10.73 GB** |

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
| TTS runtime 成对配置 | Qwen3-TTS VoiceDesign | `mps` / `float16` 或 `cpu` / `float32`；预量化 `-8bit` 快照时解析为 `int8` | 独立加载一份；TTS 未就绪不阻塞 ASR；本机已验证；TTS 支持预量化 `-8bit` MLX 快照（`speech_tokenizer` codec 恒为 FP32、embedding/norm 为 BF16），不再要求运行时只能 float16/float32 |
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
| `SPEECHRAIL_QWEN3_TTS_CLONE_MODEL_DIR` | Quality 可选 Base clone snapshot；managed profile 由 catalog/selection 自动注入，手工部署时需显式配置；未配置则不声明 `supports_clone` |
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
| `SPEECHRAIL_WORKER_IDLE_TIMEOUT_SECONDS` | 可驱逐组件的空闲超时，默认 `300` 秒；`0` 禁用；物理内存回收取决于运行时 |
| `SPEECHRAIL_API_KEY` | 非 loopback 绑定必填；loopback 可为空 |

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
`ffmpeg` 和 `.env` 仍由本机预先准备，CoreML bundle 也不打进 wheel。发布目录应同时提供 wheel、
`tools/install_macos.py`、`configs/speechrail.example.env`、plist 模板和校验文件。

### 源码到 managed runtime 的不变量（2026-09-09）

SpeechRail 的任何修复、协议变更或 worker 变更都必须先落在本源码仓库，再由源码构建 wheel；managed runtime 只消费 wheel release。禁止直接编辑 `runtime/current`、release venv 或 worker 安装目录，因为这些修改会在下一次 release 切换时丢失且无法审计。

最小发布顺序：

1. 在 SpeechRail 源码根目录完成测试、类型、lint、契约与 `git diff --check`。
2. 使用 `uv build --no-sources --wheel` 构建当前源码 wheel。
3. 使用 `tools.install_macos.install_managed` 安装候选 release；installer 负责 preflight、LaunchAgent 切换、公共 smoke 和失败回退。
4. 通过 `/health`、`/readyz`、`/v1/models` 和目标 Realtime smoke 验证后，才把 `runtime/current` 指向新 release。

源码构建与安装沿用下方唯一的 managed installer 示例，避免维护两份可能漂移的命令。

验证时应记录当前 release 路径、package version、health readiness 和 smoke 摘要，不记录密钥、完整参考文本、PCM 或模型绝对路径。

在发布目录中构建并通过唯一 managed installer 安装：

```bash
uv build --no-sources --wheel
uv run python - <<PY
import os
from pathlib import Path
import httpx
from speechrail.service.modelscope import ModelScopeDownloader
from tools.install_macos import install_managed

app_home = Path(os.environ.get("SPEECHRAIL_APP_HOME", Path.home() / "Library/Application Support/SpeechRail"))
preset = os.environ.get("SPEECHRAIL_PRESET", "quality")
wheel = sorted(Path("dist").glob("speechrail-*.whl"))[-1]
with httpx.Client(timeout=httpx.Timeout(connect=30, read=300, write=30, pool=30)) as client:
    install_managed(
        wheel,
        app_home=app_home,
        preset_id=preset,
        downloader=ModelScopeDownloader(client=client),
        enable=True,
    )
PY
```

managed installer 会准备新 release、执行 preflight、更新 LaunchAgent 并按事务完成启动与公共 smoke；
启用或 smoke 失败会停止候选并恢复旧 runtime/current。完整安装要求 ASR/TTS 两组 runtime 和 snapshot
均通过检查；私有 `.env` 可作为 managed 初始化配置输入，但不会被覆盖或写入 wheel。

验证已安装 wheel，而不是源码工作树：

```bash
python3 scripts/verify_release.py \
  --wheel <wheel-file> \
  --app-home "$HOME/Library/Application Support/SpeechRail"
```

升级先安装到新的 release runtime，完成 preflight 和真实 ASR/TTS smoke 后才切换
`runtime/current` 并重启；失败时恢复旧 `current`。README 不固定发布版本，包文件名和 package
metadata 仍保留用于升级、回滚和审计的版本信息。

> [!IMPORTANT]
> **分人档升级的 aligner 前置条件**：对 `balanced`/`quality`，安装步骤的前提是该档 aligner snapshot
> （`aligner-q8` / `aligner-bf16`）已经存在。若目标 app home 尚无该档 aligner，新 wheel 的 preflight
> 会在候选 release 启用前 fail closed；此时用于供给 aligner 的 `profile apply <tier>` 也执行不了，形成循环。
> `install_managed` 正在修复为自行按档位供给 aligner（见 2.3.1）；在具体安装版本具备该行为之前，操作者
> 必须先确保目标档位资产已存在（例如用一个能够供给的 runtime 先执行 `speechrail setup` /
> `profile apply <tier>`），再切换新 release。

> [!IMPORTANT]
> **quality 档升级的 Base clone snapshot 前置条件**：`quality` preset 声明了 `tts_clone` artifact；
> 若该 Base clone snapshot 缺失或未供给，`resolve_selection` 会在启动前 fail closed，服务不会以
> `backend_not_ready` 降级形态启动。从仅 VoiceDesign 的旧 quality 部署升级时，操作者必须先供给
> `tts_clone` 制品（managed profile apply 会执行该供给），再重启或切换 release。

若 private `.env` 设置 `SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH`，managed installer 会将该
release 作为分人 profile 安装并在 preflight 中检查 CoreML bundle、wheel 内
`SpeechRailDiarizationWorker` 与 fixed-text aligner snapshot（aligner 校验由 `preset.aligner` 驱动，
`light` 无 aligner 时跳过）。切换后还须确认 `/v1/models` 包含 `gpt-4o-transcribe-diarize`；任何一项
失败都不切换 `runtime/current`，或恢复上一 release。

## 端口与进程策略

默认端口 `8201` 供 SpeechRail 使用。一次只启动一个
SpeechRail 进程；每个已配置 profile 只启动一个对应 worker。多 ASGI worker 或重复服务实例
会产生多份模型载入和不可控内存压力。

需要常驻运行时使用 macOS `LaunchAgent`，而不是将 MPS 服务作为系统级 `LaunchDaemon`。
通过 `speechrail service install`、`enable`、`status`、`restart`、`disable` 和 `uninstall`
管理；`install` 不会启动模型。模板、安装步骤和回滚顺序见[运维 Runbook](operations-runbook.md)。
