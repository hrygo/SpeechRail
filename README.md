# SpeechRail 🚂

<p align="center">
  <strong>专为 Apple Silicon Mac 打造的本地 ASR / TTS 常驻服务，提供工业级 OpenAI 兼容接口。</strong><br>
  <em>把高端语音转写与合成模型装进你的 Mac，保护隐私，拒绝云端账单与网络延迟。</em>
</p>

<p align="center">
  <a href="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml"><img src="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/hrygo/SpeechRail/releases"><img src="https://img.shields.io/github/v/release/hrygo/SpeechRail?label=release" alt="Release" /></a>
  <img src="https://img.shields.io/badge/Python-3.12-3776AB.svg?logo=python&logoColor=white" alt="Python 3.12" />
  <img src="https://img.shields.io/badge/macOS-Apple%20Silicon%20(M--Series)-000000.svg?logo=apple" alt="Apple Silicon M-Series" />
  <img src="https://img.shields.io/badge/API-OpenAI%20compatible-412991.svg?logo=openai&logoColor=white" alt="OpenAI compatible" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License" /></a>
</p>

---

## 💡 为什么需要 SpeechRail？

当你为个人桌面 Agent、AI 会议助手、本地播客或视频配音添加语音能力时，通常面临两难：
- **调用商业云端 API（如 OpenAI Whisper / TTS）**：音频上传涉及隐私泄露风险、网络延迟高、产生持续调用账单。
- **直接在应用进程内加载模型**：PyTorch/MLX 内存占用不可控、容易泄露崩溃，不同工具重复加载导致系统卡顿甚至 OOM。

**SpeechRail 的解法**：作为一个优雅的**本地常驻语音基础设施 (Daemon)**，只需一条端口，全机所有 Agent 与客户端均可即插即用：

- 🔒 **数据零离机与强隐私**：默认仅监听 `127.0.0.1:8201`，无外呼、不写盘暂存音频、无数据回传。
- 🔌 **OpenAI 协议原生替换**：完整实现 `whisper-1`（文件转写）、`tts-1`（语音合成）与 `/v1/realtime`（双工流式 ASR/TTS），任何支持配置 `OPENAI_BASE_URL` 的客户端均可无缝切换。
- 🛡️ **物理进程隔离架构**：HTTP/WS 宿主服务与重型 AI Worker 物理进程分离，通过专有 IPC 管道通信。Worker 崩溃不拖垮服务，彻底告别显存与内存泄漏。
- 🎚️ **三档资源平滑调节 (Quality / Balanced / Light)**：针对 8GB 到 128GB 的 Apple Silicon 芯片深度优化，对外暴露统一接口，按需一键热切换档位。
- 🎙️ **9 种跨档高自然度音色**：原生集成 Qwen3-TTS 语音能力，支持自然语言定制音色（VoiceDesign）与多格式导出。

---

## ⚡ 快速上手 (Quick Start)

### 硬件与运行环境前置要求
- **硬件架构**：必须为配备 **Apple Silicon (M1/M2/M3/M4/M5)** 的 Mac。*(注：由于底层深度依赖 Apple Silicon 统一内存与 MLX Metal 加速，暂不支持 Intel x86_64 Mac)*。
- **操作系统**：macOS 14.0 (Sonoma) 及以上。
- **Python 版本**：项目核心与 MLX Worker 锁定 **Python 3.12**。但**您无需手动配置 Python**：安装引擎内置了版本自愈机制，无论您的 Mac 当前是系统自带的 3.9、Homebrew 的 3.13 还是没有 Python，脚本均会自动拉取隔离的官方 CPython 3.12 并平滑无缝切换。

> [!TIP]
> **在全新 / 空白 MacBook 上？** 我们提供了项目级自动化指南 Skill：[`speechrail-zero-setup`](.agents/skills/speechrail-zero-setup/SKILL.md)。
> 涵盖芯片架构检测、Xcode CLT、Homebrew、`ffmpeg`、Python 3.12 自动准备到模型权重拉取校验与常驻服务的从 0 到 1 完整闭环。

---

### 方式 1：推荐一键受管安装 (Managed Setup)

无需手动下载数 GB 的模型文件或管理复杂的外部虚拟环境，使用内置的自动化部署引擎，自动检测本机物理内存，从 ModelScope 拉取校验完备的量化模型，构建隔离的 MLX 运行时并配置 LaunchAgent 常驻服务：

```bash
# 1. 克隆代码仓库
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail

# 2. 一键全自动引导安装 (适用于全新/空白 Mac，自动搞定基座工具与 Python 3.12)：
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh

# （亦可直接使用任意 python3 运行安装引擎，内置引擎会自动准备 Python 3.12 并重执行切换）：
# python3 .agents/skills/speechrail-zero-setup/scripts/zero_setup.py
```

安装完成后，服务将在后台常驻运行（端口 `8201`），且在 App Home 自动生成了可双击打开的 `SpeechRail 设置.command` 用于随时交互式调整档位。

---

### 方式 2：显式自定义环境运行 (Explicit Env)

若需接入已下载的外部自定义权重或自建独立虚拟环境：

1. **准备模型与 Worker 环境**：将外部模型 Snapshot 放置于仓库外部（如 `~/models/`），并准备包含 MLX / PyTorch 依赖的独立 Worker 虚拟环境。
2. **配置私有 `.env` 并启动**：

```bash
cp configs/speechrail.example.env .env
chmod 600 .env
```

在 `.env` 中指定外部绝对路径：
```ini
# ASR 运行时配置（必填）
SPEECHRAIL_QWEN3_MODEL_DIR=/Users/yourname/models/Qwen3-ASR-1.7B
SPEECHRAIL_QWEN3_PYTHON=/Users/yourname/venvs/speechrail-worker/bin/python

# TTS 运行时配置（可选，成对配置）
SPEECHRAIL_QWEN3_TTS_MODEL_DIR=/Users/yourname/models/Qwen3-TTS
SPEECHRAIL_QWEN3_TTS_PYTHON=/Users/yourname/venvs/speechrail-tts-worker/bin/python
```

启动服务：
```bash
uv run speechrail serve
```

在另一个终端验证就绪探针（HTTP 200 即为完全就绪）：
```bash
curl -i http://127.0.0.1:8201/readyz
```

---

## 🔐 认证与网络安全 (Authentication & Network)

SpeechRail 采用**本地优先、外部强制鉴权**的安全模型（由 `SPEECHRAIL_API_KEY` 控制）：

| 运行场景 | 绑定地址 (`SPEECHRAIL_HOST`) | API Key 配置 (`SPEECHRAIL_API_KEY`) | 客户端调用说明 |
|---|---|---|---|
| **本机默认开发** | `127.0.0.1` / `localhost` / `::1` | **留空**（默认） | 客户端鉴权处于放行状态。OpenAI SDK 可传入任意占位符（如 `api_key="local"` 或 `api_key="none"`） |
| **局域网 / 代理暴露** | `0.0.0.0` 或局域网 IP | **必填**（未配置启动将直接报错拒绝） | 所有业务端点均强制校验 HTTP 请求头 `Authorization: Bearer <your-key>`（不接受 URL query 参数，防日志泄露） |

> [!NOTE]
> `/health`、`/readyz`、`/v1/models`、`/v1/voices` 为系统只读端点，始终免鉴权开放供本地探针检测。

---

## 💻 客户端接入示例 (Drop-in Replacement)

### 1. 官方 OpenAI Python SDK

只要把 `base_url` 指向 SpeechRail 即可无缝切换：

```python
from openai import OpenAI

# 默认 loopback 监听下，api_key 传占位符即可；若服务端配置了 API Key，需填写真实值
client = OpenAI(
    base_url="http://127.0.0.1:8201/v1",
    api_key="local",
)

# 1. 语音转文字 (ASR)
with open("meeting.wav", "rb") as audio:
    transcript = client.audio.transcriptions.create(
        model="whisper-1",       # 自动调度本地 Qwen3-ASR
        file=audio,
        response_format="verbose_json",
        timestamp_granularities=["segment", "word"],
    )
    print("转写结果:", transcript.text)

# 2. 文字转语音 (TTS)
speech = client.audio.speech.create(
    model="tts-1",           # 支持 tts-1 / tts-1-hd
    voice="cherry",          # 支持 cherry, serena, ethan, chelsie 等 9 种内置音色
    input="你好，我是运行在你 Mac 本地的工业级语音助手 SpeechRail。",
    response_format="wav",   # 支持 wav / mp3 / opus / aac / flac / pcm
)
speech.stream_to_file("output.wav")
```

### 2. 标准 cURL 命令行调用

无需任何 SDK，直接通过系统 `curl` 即可完成转写与合成：

```bash
# ASR: 语音文件转文字
curl http://127.0.0.1:8201/v1/audio/transcriptions \
  -H "Authorization: Bearer local" \
  -F "file=@meeting.wav" \
  -F "model=whisper-1" \
  -F "response_format=json"

# TTS: 文字合成音频文件
curl http://127.0.0.1:8201/v1/audio/speech \
  -H "Authorization: Bearer local" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tts-1",
    "input": "SpeechRail 已完全就绪，正在本地为您提供极速语音合成服务。",
    "voice": "cherry",
    "response_format": "wav"
  }' \
  --output output.wav
```

### 3. 主流桌面客户端即插即用

任何支持自定义 OpenAI 接口地址的 AI 客户端均可直接接入：

| 客户端 | 接口地址 (Base URL) | API Key | ASR 模型 | TTS 模型 |
|---|---|---|---|---|
| **Cherry Studio** | `http://127.0.0.1:8201/v1` | `local` | `whisper-1` | `tts-1` |
| **NextChat / ChatGPT-Next-Web** | `http://127.0.0.1:8201/v1` | `local` | `whisper-1` | `tts-1` |
| **Chatbox** | `http://127.0.0.1:8201/v1` | `local` | `whisper-1` | `tts-1` |
| **Dify / FastGPT** | `http://127.0.0.1:8201/v1` | `local` | `whisper-1` | `tts-1` |
| **Sona / QwenPaw / Hermes** | `http://127.0.0.1:8201/v1` | `local` | `whisper-1` | `tts-1` |

---

## 🎛️ 三档模型预设与 9 种内置音色矩阵

SpeechRail 对外暴露统一的 API 契约，内部通过轻巧的档位平滑匹配不同规格的 Mac 硬件。通过 `SpeechRail 设置.command` 或命令行即可一键无感切换：

### 1. 硬件分档矩阵

| 预设档位 (Profile) | ASR 引擎 | TTS 引擎 | 目标机型与最低物理内存 | 典型总内存常驻 (RAM) |
|---|---|---|---|---|
| 🟢 **`light` (轻量档)** | Qwen3-ASR-0.6B (4-bit) | Qwen3-TTS-0.6B CustomVoice (4-bit) | 8GB 基础款 Mac (Air / Mini) | ~3.8 GB |
| 🟡 **`balanced` (平衡档)** | Qwen3-ASR-1.7B (4-bit) | Qwen3-TTS-1.7B CustomVoice (4-bit) | 16GB / 24GB 主流 Mac (Pro / Max) | ~4.7 GB |
| 🟣 **`quality` (画质/高保真档)** | Qwen3-ASR-1.7B (8-bit) | Qwen3-TTS-1.7B VoiceDesign (8-bit) | 32GB+ 旗舰款 Mac (Max / Ultra) | ~9.2 GB |

> [!TIP]
> 无论切换到哪一档，API 端点、错误码、协议信封与音色名称均保持 100% 相同，客户端调用代码无需任何修改。

### 2. 9 种跨档高自然度音色

系统内置 9 种经过声学微调的优质音色，全档位无差别通用：

| 语音名称 (`voice`) | 角色与音质特点 | 适用场景 |
|---|---|---|
| `cherry` | 活泼亲和的年轻女声（默认音色） | 个人助理、日常对话、短视频旁白 |
| `serena` | 专业稳重、节奏沉静的知性女声 | 新闻播报、科技解说、长文朗读 |
| `ethan` | 磁性低沉、充满信赖感的男声 | 有声书叙事、商业讲座、纪录片解说 |
| `chelsie` | 温暖明亮、富有共情力的女声 | 情感陪伴、生活 Vlog、故事分享 |
| `danny` | 阳光清脆、吐字干脆的青年男声 | 运动健身、游戏互动、口播带货 |
| `ryan` | 成熟厚重、广播级质感的男中音 | 品牌广告、正式公告、课程讲解 |
| `vivian` | 优雅轻柔、咬字细腻的温柔女声 | 冥想引导、睡前故事、诗歌朗诵 |
| `bella` | 节奏明快、富有感染力的少女声 | 动漫二次元、趣味互动、儿童读物 |
| `jennifer` | 严谨从容、商务风格的中英双语女声 | 国际会议、外语教学、客户咨询 |

---

## 📊 真实性能基准实测 (Apple M5 Max)

以下数据来源于 Apple M5 Max (128GB Unified Memory) 上的最新真实基准测试（引自 [v1.7.0 性能基准报告](docs/archive/performance/2026-09-05-v1.7.0-performance-benchmark.md)），绝不造假：

| 测试项目 | Light 档实测 | Balanced 档实测 | Quality 档实测 |
|---|---|---|---|
| **ASR 转写延迟 (P50)** | **148 ms** | **184 ms** | **233 ms** |
| **ASR 实时率 (RTF)** | **0.021** (超实时 47 倍) | **0.026** (超实时 38 倍) | **0.033** (超实时 30 倍) |
| **TTS 首包生成延迟 (P50)** | **162 ms** | **206 ms** | **282 ms** |
| **TTS 实时率 (RTF)** | **0.082** (超实时 12 倍) | **0.098** (超实时 10 倍) | **0.134** (超实时 7.5 倍) |
| **守护进程物理内存常驻** | 3.82 GB | 4.71 GB | 9.24 GB |

---

## 🛠️ 常驻服务管理 (LaunchAgent)

通过 `bootstrap_mac.sh` 或 `zero_setup.py` 安装后，SpeechRail 会自动作为 macOS 标准用户级守护进程（`LaunchAgent`）开机自启。你可以随时通过 CLI 管理服务状态：

```bash
# 查看常驻服务当前运行状态与 PID
uv run speechrail service status

# 重启常驻服务
uv run speechrail service restart

# 停止或卸载常驻服务
uv run speechrail service stop
uv run speechrail service uninstall
```

---

## 🏛️ 架构设计与物理隔离边界

```text
       OpenAI SDK / HTTP 客户端 / WebSocket
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  FastAPI 宿主服务 (Host Service)                             │
│  - 纯 Python 异步网关 (端口 8201)                              │
│  - 零重型显存依赖，负责路由、鉴权、限流与协议状态机               │
│  - Resource Governor (有界音频队列，防止突发流量冲垮内存)          │
└──────────────────────────┬──────────────────────────────────┘
                           │ 专属 IPC 有界管道 (Framed Pipe)
        ┌──────────────────┴──────────────────┐
        ▼                                     ▼
┌─────────────────────────────┐   ┌─────────────────────────────┐
│ 独立的 ASR MLX Worker 物理进程│   │ 独立的 TTS MLX Worker 物理进程│
│ - 隔离的 MLX 权重与独立虚拟环境 │   │ - 独立 VoiceDesign/Custom   │
│ - Batch 与 Streaming 互斥保护 │   │ - 音频流式分块无锁返回       │
└─────────────────────────────┘   └─────────────────────────────┘
```

> **设计取舍与安全边界**：
> - **物理隔离**：宿主服务与 AI 推理进程物理隔离，即使 MLX 推理发生未捕获异常或显存崩溃，宿主网关仍稳定在线，并能自动回收重置 Worker。
> - **专注核心**：SpeechRail 专注于稳定、可靠的本地 ASR / TTS 基础设施，不承担麦克风采集、播放、会议持久化或复杂的多 Agent 状态编排（这些职责属于前端客户端）。

---

## 📚 完整文档中心

| 读者角色 | 推荐入口与文档说明 |
|---|---|
| 🚀 **小白 / 快速搭建** | [空白 Mac 从零搭建指南 (`speechrail-zero-setup`)](.agents/skills/speechrail-zero-setup/SKILL.md) · [常见排障指南](docs/operations/troubleshooting.md) |
| 🔌 **API 开发者** | [用户与客户端集成](docs/users/README.md) · [OpenAI 兼容契约详解](docs/users/api-contract.md) · [OpenAPI 规范文件](contracts/openapi.yaml) |
| 🛠️ **系统运维** | [运维中心](docs/operations/README.md) · [受管运行时部署](docs/operations/runtime-deployment.md) · [LaunchAgent 配置](docs/operations/service-management.md) |
| 🧪 **代码贡献者** | [开发者中心](docs/developers/README.md) · [本地测试与验收套件](docs/developers/testing-acceptance.md) |
| 📐 **架构师** | [系统架构全景](docs/architecture/README.md) · [边界与设计权衡](docs/architecture/current-boundaries.md) · [ADR 架构决策记录](docs/decisions/README.md) |

---

## 🤝 参与贡献

我们欢迎社区各种形式的贡献与反馈！
- 提交代码前请仔细阅读 [贡献指南 (CONTRIBUTING.md)](CONTRIBUTING.md)。
- 发现安全漏洞请遵循 [安全策略 (SECURITY.md)](SECURITY.md) 私下联络。
- 交流请遵守 [行为准则 (CODE_OF_CONDUCT.md)](CODE_OF_CONDUCT.md)。

---

## 📄 开源许可证

SpeechRail 采用宽松友好的 [MIT License](LICENSE) 授权开源。您可以自由用于个人助手或商业集成。
