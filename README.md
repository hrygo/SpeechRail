# SpeechRail 🚂

<p align="center">
  <strong>本地常驻的高性能、隐私优先、兼容 OpenAI 协议的独立语音识别 (ASR) 与合成 (TTS) 服务</strong>
</p>

<p align="center">
  <a href="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml"><img src="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml/badge.svg" alt="CI Status" /></a>
  <a href="https://github.com/hrygo/SpeechRail/releases"><img src="https://img.shields.io/github/v/release/hrygo/SpeechRail?color=blue&label=version" alt="Latest Release" /></a>
  <img src="https://img.shields.io/badge/Python-3.12-3776AB.svg?style=flat&logo=python&logoColor=white" alt="Python 3.12" />
  <img src="https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon)-000000.svg?style=flat&logo=apple&logoColor=white" alt="macOS Apple Silicon" />
  <img src="https://img.shields.io/badge/Accelerators-MLX%20%7C%20MPS-FF6F00.svg?style=flat" alt="MLX & MPS" />
  <img src="https://img.shields.io/badge/API-OpenAI%20Compatible-412991.svg?style=flat&logo=openai&logoColor=white" alt="OpenAI Compatible" />
  <img src="https://img.shields.io/badge/Code%20Style-Ruff-000000.svg?style=flat&logo=ruff&logoColor=white" alt="Code Style Ruff" />
  <img src="https://img.shields.io/badge/Type%20Check-Mypy%20Strict-blue.svg?style=flat" alt="Mypy Strict" />
  <img src="https://img.shields.io/badge/Coverage-80.5%25-success.svg?style=flat" alt="Coverage" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg?style=flat" alt="License MIT" /></a>
</p>

---

## 📖 目录

- [✨ 核心特性](#-核心特性)
- [🏗️ 架构概览](#️-架构概览)
- [💻 硬件与环境要求](#-硬件与环境要求)
- [⚡ 性能基线与资源实测](#-性能基线与资源实测)
- [⚡ 3分钟快速上手](#-3分钟快速上手)
- [🔌 客户端与 SDK 接入](#-客户端与-sdk-接入)
- [📡 API 规范与端点](#-api-规范与端点)
- [⚙️ 配置说明](#️-配置说明)
- [🛠️ macOS 服务常驻与运维](#️-macos-服务常驻与运维)
- [🔒 安全与隐私边界](#-安全与隐私边界)
- [📚 文档导航](#-文档导航)
- [🤝 参与贡献](#-参与贡献)
- [📄 开源许可](#-开源许可)

---

## ✨ 核心特性

- 🔒 **完全离线与无状态隐私（Offline & Privacy-First）**：纯离线运行，绝不静默联网；直接加载本地模型权重，音频与文本仅在内存中有界流转、即用即弃，服务端不落盘存储源音频，保障隐私与稳定性。
- ⚡ **Apple Silicon 深度优化（MLX & MPS）**：针对 Mac 统一内存深度调优，非流式与流式 ASR 统一采用原生 `mlx-qwen3-asr` 与 MPS 加速 (`float16`/`int8`)，具备 WAV 零开销 Fast-path 直读与动态 Token 预算，极低延迟与内存占用。
- 🔌 **开箱即用的 OpenAI 协议兼容**：
  - **文件转写**：`POST /v1/audio/transcriptions`（无缝支持 OpenAI 官方 SDK、`whisper-1` 等标准别名）。
  - **语音合成**：`POST /v1/audio/speech`（支持 `tts-1` 别名，输出 24 kHz 高品质音频）。
  - **双向流式**：`WS /v1/realtime`（标准 OpenAI Realtime WebSocket 协议，支持 `client.realtime.connect`）。
- ⏱️ **端到端高精度时间戳**：原生输出句子级与词级对齐时间戳，支持 `verbose_json`、`srt`、`vtt` 及 `timestamp_granularities`，无需额外挂载外置对齐器。
- 👥 **实时声纹分割（Speaker Diarization）**：可选集成 Sortformer 与 CAM++，支持实时会议场景下的匿名说话人分离与重连声学聚类。
- 🛡️ **进程隔离与资源守护（Resource Governor）**：主服务（FastAPI）与推理后端通过二进制零拷贝 IPC 协议进行进程级隔离；内置配额管控与背压机制，多任务并发不争抢、不崩溃。

---

## 🏗️ 架构概览

SpeechRail 采用**主控调度与推理运行时强隔离**的微内核设计：主服务负责协议路由与资源管控，推理引擎在独立 Python 进程中执行，通过私有零拷贝二进制 IPC 通信。

```mermaid
flowchart TD
    Client["📱 客户端生态 (OpenAI SDK / QwenPaw / Sona / 本地脚本)"]

    subgraph Host ["🚀 SpeechRail 主服务进程 (FastAPI / ASGI :8201)"]
        direction LR
        GW["1. 协议网关<br/>(REST & WebSocket)"]
        Pipe["2. 内存音频流水线<br/>(WAV直读 / 流式解码)"]
        Gov["3. 资源守护器<br/>(Realtime抢占 / 租约锁)"]
        GW --> Pipe --> Gov
    end

    subgraph Workers ["🛡️ 独立 Python 隔离推理 Worker (零拷贝二进制 IPC)"]
        direction LR
        ASR["🎙️ Qwen3-ASR Worker<br/>(MLX / MPS 加速)"]
        TTS["🔊 Qwen3-TTS Worker<br/>(VoiceDesign 合成)"]
        Diar["👥 Diarization 引擎<br/>(Sortformer 分割)"]
    end

    Client -->|"HTTP REST / WS"| Host
    Host ==>|"全双工 IPC 管道"| Workers
```

> 📖 了解 3-Tier 音频流水线、租约锁机制与状态机的完整设计，请参阅 **[🏛️ 系统总体架构设计文档](docs/architecture/architecture.md)**。

---

## 💻 硬件与环境要求

| 组件 | 最低要求 | 推荐配置 | 备注 |
|---|---|---|---|
| **操作系统** | macOS 14 (Sonoma) | macOS 15 (Sequoia)+ | 针对 Apple Silicon 统一内存架构优化 |
| **芯片型号** | Apple Silicon M1/M2/M3/M4 系列 | M 系列 Pro / Max / Ultra | 默认使用 `mps` / `float16` |
| **统一内存** | 8 GB (0.6B INT8) / 16 GB (1.7B) | 24 GB ~ 32 GB+ | 详见下方模型选型与内存对照 |
| **系统依赖** | Python 3.12, `ffmpeg`, `uv` | 最新版 `brew` 工具链 | `ffmpeg` 必须可在系统 `PATH` 中找到 |
| **存储空间** | 15 GB 可用空间 | 30 GB+ 高速 SSD | 用于存放本地模型权重与隔离虚拟环境 |

### 🧩 支持的模型规格与选型指南

SpeechRail 支持通过指定本地权重目录加载不同规格的 Qwen3 语音模型：

| 模型类型 | 规格版本 | 显存/内存占用 (MPS/MLX) | 推荐场景 | 说明 |
|---|---|---|---|---|
| **Qwen3-ASR** (语音识别) | **1.7B** *(默认推荐)* | ~3.0 GB (FP16) / ~1.5 GB (INT8) | 会议长音频、高精度中英文/多语种混合识别 | 标点与时间戳综合效果最优，SpeechRail 默认主力 |
| **Qwen3-ASR** (语音识别) | **0.6B** *(极速/轻量)* | ~1.0 GB (FP16) / ~600 MB (INT8) | 8GB 内存设备、端侧极速流式转写、高并发场景 | 延迟极低、显存极小，完全兼容相同 Worker 协议 |
| **Qwen3-TTS** (语音合成) | **VoiceDesign** (约 1.7B) | ~3.0 GB (FP16) | 本地助手播报、多音色对话合成 | 内置 `default`, `warm`, `calm`, `bright` 等预设音色；运行时暂不支持权重量化 |

---

## ⚡ 性能基线与资源实测

> 真实测试环境：Apple M5 Max (18 核 CPU / 128GB 统一内存)，macOS 26.6.2，MLX (MPS 加速)，Qwen3-ASR-1.7B (INT8 内存量化) + Qwen3-TTS (VoiceDesign 1.7B bf16)。

### 📊 1. 真实物理显存与内存常驻 (macOS 原生 `footprint`)

| 进程组件 | 待机常驻物理内存 (Idle) | 压测峰值物理内存 (Peak) | 峰值 CPU | 显存与调度行为 |
|---|---|---|---|---|
| **主服务 (FastAPI)** | **539.1 MB** | **539.1 MB** | 0.6% | 协议路由、音频解码与资源守护 |
| **ASR Worker (Batch)** | **2,542.7 MB (~2.54 GB)** | **9,159.8 MB (~9.16 GB)** | 77.6% | INT8 内存即时量化，处理 Batch REST 转写 |
| **Qwen3 TTS Worker** | **4,941.0 MB (~4.94 GB)** | **5,313.8 MB (~5.31 GB)** | 1.1% | VoiceDesign 1.7B，应用 256MB 显存池上限管理 |
| **全系统总常驻 (Total)** | **8,022.9 MB (~8.02 GB)** | **15,012.7 MB (~15.01 GB)** | -- | 主动 Metal GC 与显存限额，无泄漏滞留 |

> 表内 ASR/TTS 测量为 **v1.5.2** 实测数据（Apple M5 Max / 128GB）。
> **v1.5.1 起 native realtime 使用独立 streaming worker（懒加载，首个 realtime 会话才启动）**，避免共享管道上
> batch 与 realtime 并发读帧导致崩溃/死锁；启用 realtime 会话时内存模型需按两个 ASR worker 重新评估。
> `sample_resources.py` 中 streaming 与 batch worker 共用 `qwen3_worker.py` 模块入口，当前按 batch 合并统计。

### 🚀 2. 推理延迟与吞吐基线

* **非流式 ASR (`POST /v1/audio/transcriptions`)**：
  * 短音频 (2.8s)：稳定延迟 **0.13s** ($RTF = \mathbf{0.05x}$)
  * 中音频 (8.6s)：平均延迟 **0.25s** ($RTF = \mathbf{0.03x}$)
  * 超长音频 (32.0s)：平均延迟 **0.86s** ($RTF = \mathbf{0.03x}$，比播放快 ~37 倍)
  * 并发吞吐 (4 线程 / 8 次请求)：吞吐量 **4.00 req/s**，P95 延迟 **1.00s**，成功率 **100%**
* **语音合成 TTS (`POST /v1/audio/speech`)**：
  * 短句 (20 字符 / 3.4s 音频)：平均耗时 **1.29s** ($RTF = \mathbf{0.37x}$)
  * 长句 (50 字符 / 8.6s 音频)：平均耗时 **3.10s** ($RTF = \mathbf{0.36x}$)
* **双向流式 WebSocket (`WS /v1/realtime`)**：
  * 流式 ASR Commit 延迟（8.6s 整段一次提交）：**2.57s ~ 2.71s** ($RTF = \mathbf{0.30x}$)
  * TTS 首包生成延迟 (TTFA)：稳定在 **73 ms ~ 78 ms** 极速直出
  * **连续 3 会话 100% 完成**：v1.5.2 修复槽位泄漏 / 断开释放 / 活跃 worker 误回收 / 读写锁死锁后，无 `backend_busy`、无死锁

> 完整测量报告与复现步骤请参阅 **[📊 v1.5.2 性能基线完整报告](docs/archive/performance/2026-09-03-v1.5.2-performance-benchmark.md)**（历史基线见 [v1.5.0 报告](docs/archive/performance/2026-09-02-v1.5.0-performance-benchmark.md)）。

---

## ⚡ 3分钟快速上手

### 1. 克隆仓库并安装服务依赖

```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail
uv sync --extra dev
```

### 2. 准备模型权重与 Worker 虚拟环境

> 💡 **模型加载原则**：SpeechRail 遵循离线设计，请先将模型权重下载到本地磁盘（如通过 ModelScope 或 HuggingFace），并准备独立的 Python 虚拟环境。

```bash
# 示例：下载 Qwen3-ASR 模型至本地目录
# /Users/yourname/models/Qwen3-ASR-1.7B

# 示例：为 ASR Worker 创建独立环境并安装推理依赖
uv venv .venv-asr --python 3.12
.venv-asr/bin/pip install torch torchaudio mlx-qwen3-asr soundfile
```

### 3. 配置 `.env`

复制示例配置文件并设置权限：

```bash
cp configs/speechrail.example.env .env
chmod 600 .env
```

编辑 `.env` 中的核心路径（填入您的真实模型目录与 Worker Python 路径）：

```env
SPEECHRAIL_HOST=127.0.0.1
SPEECHRAIL_PORT=8201
SPEECHRAIL_DEVICE=mps
# 精度：默认 float16 兼容标准权重；若需降低 ~50% 显存占用可设为 int8
SPEECHRAIL_DTYPE=float16

# ASR 推理配置（必填：Qwen3-ASR 本地目录与 Worker Python）
SPEECHRAIL_QWEN3_MODEL_DIR=/Users/yourname/models/Qwen3-ASR-1.7B
SPEECHRAIL_QWEN3_PYTHON=/Users/yourname/SpeechRail/.venv-asr/bin/python

# TTS 合成配置（可选：VoiceDesign 本地目录与 Worker Python）
SPEECHRAIL_QWEN3_TTS_MODEL_DIR=/Users/yourname/models/Qwen3-TTS
SPEECHRAIL_QWEN3_TTS_PYTHON=/Users/yourname/SpeechRail/.venv-tts/bin/python
```

### 4. 启动服务与就绪验证

```bash
# 前台启动服务
uv run speechrail serve
```

在另一终端验证服务与模型就绪状态：

```bash
# 1. 基础健康检查
curl http://127.0.0.1:8201/health

# 2. 模型就绪检查 (返回 200 即代表 Worker 加载完成)
curl http://127.0.0.1:8201/readyz

# 3. 查看可用模型及别名清单
curl http://127.0.0.1:8201/v1/models
```

---

## 🔌 客户端与 SDK 接入

### 1. cURL 命令行调用

#### 🎙️ 音频文件转写（包含句子与词级时间戳）
```bash
curl -X POST http://127.0.0.1:8201/v1/audio/transcriptions \
  -F "file=@meeting.wav" \
  -F "model=whisper-1" \
  -F "language=zh" \
  -F "response_format=verbose_json" \
  -F "timestamp_granularities[]=segment" \
  -F "timestamp_granularities[]=word"
```

#### 🔊 文本转语音 (TTS)
```bash
curl -X POST http://127.0.0.1:8201/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tts-1",
    "input": "欢迎使用 SpeechRail 本地语音服务。",
    "voice": "warm",
    "response_format": "wav"
  }' \
  --output speech.wav
```

---

### 2. 官方 OpenAI Python SDK 接入

无需修改业务代码，直接将 `base_url` 指向本地端口：

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8201/v1",
    api_key="not-needed"  # 本地 loopback 无需认证
)

# 1. ASR 文件转写
with open("meeting.wav", "rb") as audio_file:
    transcript = client.audio.transcriptions.create(
        model="whisper-1",
        file=audio_file,
        response_format="verbose_json",
        timestamp_granularities=["segment", "word"]
    )
    print("转写文本:", transcript.text)
    print("分段详情:", transcript.segments)

# 2. TTS 语音合成
response = client.audio.speech.create(
    model="tts-1",
    voice="calm",
    input="SpeechRail 为您的本地应用提供强大的低延迟语音动力。"
)
response.stream_to_file("output.mp3")
```

---

### 3. 应用与生态集成

- **QwenPaw**：在设置中选择 `whisper_api` 提供商，Base URL 设置为 `http://127.0.0.1:8201/v1`，模型使用 `speechrail/qwen3-asr-1.7b` 或 `whisper-1`。
- **Sona (实时会议)**：通过 `/v1/realtime` WebSocket 端点直连流式会议转写与说话人分离。
- **Hermes Agent**：使用标准 STT 模块直连 SpeechRail REST 接口。

---

## 📡 API 规范与端点

| 方法 | 路径 | 描述 | 支持格式 / 参数 |
|---|---|---|---|
| `GET` | `/health` | 服务存活与组件健康状态 | 返回进程状态与组件健康指标 |
| `GET` | `/readyz` | 推理引擎就绪状态检查 | 确认 ASR/TTS Worker 均已完成加载 (HTTP 200) |
| `GET` | `/v1/models` | 模型清单与别名路由 | 列出 Canonical 模型名与 `whisper-1`、`tts-1` 等兼容别名 |
| `GET` | `/v1/voices` | 可用音色列表 | 返回 `default`, `warm`, `bright`, `calm` 等预设音色 |
| `POST` | `/v1/audio/transcriptions` | OpenAI 兼容文件转写 | `json`, `verbose_json`, `text`, `srt`, `vtt` |
| `POST` | `/v1/audio/speech` | OpenAI 兼容语音合成 | `mp3`(默认), `opus`, `aac`, `flac`, `wav`, `pcm` |
| `POST/GET/DELETE` | `/v1/jobs` | 异步转写任务管理 | 提交长任务排队、状态轮询与任务取消 |
| `WS` | `/v1/realtime` | OpenAI Realtime WebSocket | 实时双向流式转写、合成与说话人分离 |

完整接口协议与错误定义请参阅 [OpenAPI 契约文件](contracts/openapi.yaml) 与 [Realtime 协议文档](contracts/realtime-openai.md)。

---

## ⚙️ 核心配置项说明

所有配置均通过环境变量或 `.env` 注入，关键配置如下：

| 配置项 | 默认值 | 说明 |
|---|---|---|
| `SPEECHRAIL_HOST` / `PORT` | `127.0.0.1:8201` | 服务绑定地址与端口 |
| `SPEECHRAIL_DEVICE` | `mps` | 推理硬件（`mps` 用于 Apple Silicon GPU/NPU 加速，或 `cpu`） |
| `SPEECHRAIL_DTYPE` | `float16` | 推理精度：默认 `float16`（开箱兼容官方权重）；低内存设备推荐配置 `int8`（显存减半且吞吐更优）。**`int8` 仅作用于 ASR Worker**；TTS Worker 始终使用 `float16`（mps）/ `float32`（cpu） |
| `SPEECHRAIL_QWEN3_MODEL_DIR` | *(必填)* | 本地 Qwen3-ASR 权重目录绝对路径 |
| `SPEECHRAIL_QWEN3_PYTHON` | *(必填)* | ASR Worker 独立的 Python 解释器绝对路径 |
| `SPEECHRAIL_QWEN3_TTS_MODEL_DIR` | *(可选)* | 本地 Qwen3-TTS 权重目录绝对路径 |
| `SPEECHRAIL_QWEN3_TTS_PYTHON` | *(可选)* | TTS Worker 独立的 Python 解释器绝对路径 |
| `SPEECHRAIL_REALTIME_ASR_BACKEND` | `disabled` | 流式后端：`disabled` 或 `native` (原生 MLX 运行时) |
| `SPEECHRAIL_DIARIZATION_MODEL_PATH` | *(可选)* | Sortformer 声纹分割模型 `.nemo` 本地路径 |
| `SPEECHRAIL_MAX_QUEUE_SIZE` | `8` | 最大等待并发任务队列数 |
| `SPEECHRAIL_MAX_UPLOAD_BYTES` | `536870912` (512MB) | 单次文件上传最大体积限制 |
| `SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` | `120` | 单次推理 Worker 超时硬截断（秒） |

完整配置字段请参考 [`configs/speechrail.example.env`](configs/speechrail.example.env)。

---

## 🛠️ macOS 服务常驻与运维

SpeechRail 内建了专为 macOS `launchd` 设计的用户级后台服务管理命令（无需 root 权限）：

```bash
# 1. 安装 LaunchAgent 配置（生成 ~/Library/LaunchAgents/com.speechrail.plist）
uv run speechrail service install

# 2. 启用并启动后台常驻服务
uv run speechrail service enable

# 3. 查看服务运行状态与 PID
uv run speechrail service status

# 4. 重启服务（重新加载模型权重）
uv run speechrail service restart

# 5. 停止服务 / 卸载服务
uv run speechrail service disable
uv run speechrail service uninstall
```

详细运维操作、Wheel 打包与故障回滚指南请参阅 [📖 运维操作手册](docs/operations/operations-runbook.md)。

---

## 🔒 安全与隐私边界

1. **绝对离线与零网络外链**：模型权重完全从本地加载，推理期间强制配置 `HF_HUB_OFFLINE=1`，绝无隐式联网请求。
2. **内存流转与即用即弃**：源音频仅在内存中流式解码与推理，不落盘产生临时文件，日志中严禁打印原始音频与转写文本。
3. **本地绑定与可控鉴权**：默认仅监听 `127.0.0.1` 本地回环接口；如需局域网暴露，需显式设置 `SPEECHRAIL_API_KEY` 并通过 `Authorization: Bearer <key>` 鉴权。

---

## 📚 文档导航

<div align="center">

| 角色门户 | 关注主题 | 文档入口 |
|:---|:---|:---|
| 🎯 **产品经理 / 业务决策** | 业务价值、应用场景、功能矩阵、规划路线 | [📖 产品全景概述](docs/product/overview.md) · [📋 产品范围](docs/architecture/product-scope.md) |
| 🏛️ **系统架构师** | 架构拓扑、进程隔离、零拷贝 IPC、状态机、ADR | [🏛️ 总体架构设计](docs/architecture/architecture.md) · [⚖️ 对标审计](docs/architecture/openai-conformance-audit.md) · [📜 ADR](docs/decisions/README.md) |
| 🔌 **API 用户 / 客户端集成** | REST / WebSocket 契约、SDK 接入、音色库、错误码 | [🔌 客户端接入指南](docs/users/integrations.md) · [📡 API 契约手册](docs/users/api-contract.md) · [⚡ Realtime 契约](contracts/realtime-openai.md) |
| 🛠️ **开发者 / 贡献者** | 快速启动、代码分层、测试金字塔、Worker 扩展 | [🛠️ 开发者指南](docs/developers/development-guide.md) · [🧪 测试验收](docs/developers/testing-acceptance.md) |
| 📦 **运维工程师 / SRE** | LaunchAgent 常驻、Wheel 发布、排障决策树、监控 | [📖 运维操作手册](docs/operations/operations-runbook.md) · [🚀 运行时部署](docs/operations/runtime-deployment.md) · [🔒 安全监控](docs/operations/security-observability.md) |

</div>

👉 查阅完整文档体系请访问 [📚 文档中心 (Docs Portal)](docs/README.md)。

---

## 🤝 参与贡献

欢迎任何形式的开源贡献！请参阅：

- 📖 **[贡献指南 (Contributing Guide)](CONTRIBUTING.md)**：开发环境搭建、编码规范与 PR 提交流程。
- 🛡️ **[行为准则 (Code of Conduct)](CODE_OF_CONDUCT.md)**：友好与包容的社区规范。
- 🔒 **[安全策略 (Security Policy)](SECURITY.md)**：漏洞披露与反馈途径。

---

## 🌟 Star History

[![Star History Chart](https://api.star-history.com/svg?repos=hrygo/SpeechRail&type=Date)](https://star-history.com/#hrygo/SpeechRail&Date)

---

## 📄 开源许可

本项目基于 [MIT License](LICENSE) 开源发布。欢迎自由使用、修改与集成。
