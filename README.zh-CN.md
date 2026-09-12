# SpeechRail 🎙️

<p align="center">
  <strong>专为 Apple Silicon Mac 打造的生产级本地 ASR / TTS 语音服务底座</strong><br>
  <em>双进程物理隔离 · 空闲自动卸载 · 纯离线零延迟 · 100% 数据私密 · 1:1 兼容 OpenAI 协议</em>
</p>

<p align="center">
  <a href="https://github.com/hrygo/SpeechRail/releases"><img src="https://img.shields.io/github/v/release/hrygo/SpeechRail?color=3776AB&label=release" alt="Release" /></a>
  <img src="https://img.shields.io/badge/macOS-Apple%20Silicon%20(M--Series)-000000.svg?logo=apple&logoColor=white" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/Python-3.12-3776AB.svg?logo=python&logoColor=white" alt="Python 3.12" />
  <img src="https://img.shields.io/badge/API-OpenAI%20v1%20Compatible-412991.svg?logo=openai&logoColor=white" alt="OpenAI Compatible" />
  <img src="https://img.shields.io/badge/Inference-Apple%20MLX-F58220.svg" alt="MLX Inference" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="README.md">English</a> | <strong>简体中文</strong>
</p>

<p align="center">
  🤝 <strong>为 <a href="https://github.com/hrygo/sona">Sona</a> 打造</strong><br>
  <em>为 Sona 提供私有、本地、实时 ASR/TTS 与可选的 OpenAI 兼容匿名讲话人分离能力。</em>
</p>

---

## 💡 为什么需要 SpeechRail？

当你为个人桌面 Agent、本地会议转录助手、播客剪辑或各种 AI 工具添加语音能力时，通常面临两难：
- **调用商业云端 API（如 OpenAI Whisper / TTS）**：每分钟音频都在上传云端，面临隐私泄露隐患；公网抖动带来数百毫秒额外延迟；高频调用产生持续且高昂的账单。
- **本地应用重复加载模型**：不同桌面应用各自加载模型导致内存爆炸，显存泄漏与异常容易直接拖垮宿主进程。

**SpeechRail 的解法**：作为一个**在 macOS 后台静默常驻的高性能本地语音 Daemon**，单端口监听，本机及局域网所有客户端与 Agent 即插即用：

- 🔒 **数据零离机与强隐私**：默认绑定本地环回（`127.0.0.1`），亦支持内网受控暴露。音频纯内存处理不落盘，全链路本地私有推理，绝无任何数据外呼与云端泄露。
- 🔌 **OpenAI 协议 1:1 无缝替换**：完整实现 `whisper-1`（文件转录）、`tts-1`（语音合成）与 `/v1/realtime`（低延迟双工流式 ASR/TTS），客户端改一行 `base_url` 即可接入。
- 🛡️ **进程隔离架构**：HTTP 网关、MLX ASR/TTS Worker 与原生 CoreML 分人 Worker 都运行在独立进程，通过私有帧化 IPC 通信。Worker 崩溃不会拖垮网关。
- 🍃 **可配置空闲卸载 (Idle Eviction)**：默认 **300 秒**无活动后，按生命周期配置释放常驻模型权重。卸载后的物理内存取决于档位、运行时和分配器，不承诺固定的待机内存数值。
- 👥 **可选多人讲话人分离 (Speaker Diarization)**：`gpt-4o-transcribe-diarize` 返回 OpenAI 风格、会话范围的匿名标签 `diarized_json`。它使用锁定的 FluidAudio CoreML FP16 Sortformer Worker；Realtime 通过 `session.speechrail.diarization.enabled` 显式开启扩展。
- 🎚️ **动态三档用户定位**：按用户场景分为 **Embedded（`light`）/ Pro Workflow（`balanced`）/ Studio（`quality`）** 三档，覆盖 8GB 到 128GB 的 Apple Silicon 芯片，三档统一使用 8-bit 权重（仅 `quality` 的 aligner 保持 bf16），一键无感热切换。
- 🎙️ **9 种跨档高质量内置音色**：原生集成 Qwen3-TTS 语音能力，涵盖中文、英语、粤语、日语、韩语等丰富声学角色。
- 🛡️ **质量门控音色克隆**：`quality` 档支持从参考音频 + 朗读脚本文本克隆自定义音色（`POST /v1/voices/clone`），可在不落库的情况下预检参考音频质量（`POST /v1/voices/clone/validate`），并可对任意已注册音色执行有界质量探针（`POST /v1/voices/{voice_id}/quality-runs`）。三者共用 `voice_quality_v1` 报告契约，详见[克隆音色质量门禁与自量保障契约](docs/architecture/voice-clone-quality-gates-and-contract.md)。

---

## ⚖️ 核心方案对比

| 核心特性 | **SpeechRail 🎙️ (本地常驻基础设施)** | **商业公有云 API (如 OpenAI)** |
|---|---|---|
| **数据隐私** | 🔒 **100% 本机私有推理，数据零离机**（默认本地免密直连，支持内网鉴权暴露，绝不上云） | ❌ 音频必须上传云端，面临合规与泄露风险 |
| **长期调用成本** | 💰 **$0（一次安装，全机及内网无限量免费调用）** | 💸 按音频时长/Token 持续计费，高频使用昂贵 |
| **网络环境依赖** | ⚡ **纯离线本地计算，0 公网延迟，断网可用** | ⚠️ 依赖稳定外网与跨境链路，受网络抖动影响 |
| **全机复用与内存管理**| 🍃 **单常驻 Daemon 供全机共享，可配置空闲卸载权重；实际占用以基准为准** | 统一云端网关，无本地模型负载 |
| **系统健壮性** | 🛡️ **网关与推理 Worker 物理进程隔离，异常自动拉起** | 依赖外部云服务商 SLA 与网络状态 |
| **OpenAI 协议兼容** | ✅ **原生 1:1 兼容 (`whisper-1` / `tts-1` / `/v1/realtime`)** | ✅ 官方标准协议规范 |

---

## ⚡ 5 分钟极速上手

### 硬件与系统要求

- **硬件架构**：配备 **Apple Silicon M 系列芯片** 的 Mac（暂不支持 Intel x86_64 Mac）。
- **操作系统**：macOS 14.0 (Sonoma) 及以上。
- **Python 环境**：锁定 **Python 3.12**（部署脚本会自动拉取隔离的官方运行时并自愈切换，无需手动安装配置）。
- **全新 Mac 零配置指南**：针对全新/空白 MacBook 的自动化安装 SOP 详见 [`speechrail-zero-setup`](.agents/skills/speechrail-zero-setup/SKILL.md)。

---

### 方式 1：推荐一键受管安装

使用全自动部署引擎，自动检测本机物理内存，从 ModelScope 镜像拉取校验完备的量化模型，在独立隔离沙箱构建 MLX Worker 并配置开机自启常驻服务：

```bash
# 1. 克隆代码仓库
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail

# 2. 一键引导安装 (适用于全新/空白 Mac，自动搞定环境与依赖)：
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh

# （亦可直接使用任意 python3 启动安装引擎，内置自愈机制会自动准备 Python 3.12 并平滑重执行）：
# python3 .agents/skills/speechrail-zero-setup/scripts/zero_setup.py
```

安装完成后：
1. 服务将作为 macOS `LaunchAgent` 在后台默默常驻（监听端口 `8201`）。
2. 在 App Home 自动生成了可双击打开的 `SpeechRail 设置.command`，方便随时图形化切换档位。

---

### 方式 2：显式自定义环境运行

若您是高阶开发者，需要接入本地已有的自定义模型权重或自建虚拟环境：

```bash
# 1. 配置私有环境变量
cp configs/speechrail.example.env .env
chmod 600 .env

# 2. 在 .env 中填入外部模型的绝对路径与独立 Worker 的 Python 解释器
# SPEECHRAIL_QWEN3_MODEL_DIR=/Users/yourname/models/Qwen3-ASR-1.7B
# SPEECHRAIL_QWEN3_PYTHON=/Users/yourname/venvs/worker/bin/python

# 3. 启动前台服务
uv run speechrail serve
```

在另一个终端验证就绪探针（返回 HTTP 200 即为完全就绪）：
```bash
curl -i http://127.0.0.1:8201/readyz
```

---

## 🔐 认证与网络安全策略

SpeechRail 遵循**本地零摩擦、对外硬防护**的安全设计：

- **本地回环（默认）**：绑定 `127.0.0.1`，无需配置密钥。客户端免密直连，OpenAI SDK 传入任意占位 key（如 `api_key="local"`）即可。
- **局域网 / 远程暴露**：绑定 `0.0.0.0` 或指定网卡 IP 时，**必须显式配置 `SPEECHRAIL_API_KEY`**（未配置时启动直接报错拦截）。所有业务请求必须在 Header 中携带 `Authorization: Bearer <key>`，禁止在 URL Query 中传 key 以防止日志泄露。

*注：`/health`、`/readyz`、`/v1/models`、`/v1/voices` 为系统健康与发现探针端点，始终免鉴权开放。*

---

## 💻 客户端全生态即插即用

任何支持自定义 OpenAI 接口地址（`OPENAI_BASE_URL`）的应用，都可以将 SpeechRail 作为底层语音引擎。

### 1. Python (OpenAI SDK)

下方分人示例需要先配置本地 CoreML bundle；macOS wheel 已内置原生 Worker（见[可选讲话人分离模型](#3-可选讲话人分离模型)）。

```python
from openai import OpenAI

# 指向本地 SpeechRail 端口，免密模式传入任意占位 key 即可
client = OpenAI(
    base_url="http://127.0.0.1:8201/v1",
    api_key="local",
)

# 🎙️ 语音转文字 (ASR)
with open("speech.wav", "rb") as audio_file:
    transcript = client.audio.transcriptions.create(
        model="whisper-1",  # 自动调度本地 Qwen3-ASR
        file=audio_file,
        response_format="verbose_json",
        timestamp_granularities=["segment", "word"],
    )
    print("转录文本:", transcript.text)

# 👥 多人会议转录与发言人区分 (Speaker Diarization)
with open("meeting.wav", "rb") as audio_file:
    meeting = client.audio.transcriptions.create(
        model="gpt-4o-transcribe-diarize",  # 调度本地 CoreML 分人 Worker
        file=audio_file,
        response_format="diarized_json",  # 返回带 speaker 标签的分段转写
    )
    for seg in meeting.segments:
        print(f"[{seg.speaker}] {seg.text}")

# 🔊 文字转语音 (TTS)
speech = client.audio.speech.create(
    model="tts-1",  # 支持 tts-1 / tts-1-hd
    voice="serena",  # 内置 serena (默认), vivian, uncle_fu 等 9 种优质音色
    input="你好，我是运行在你的 Mac 本地的高性能语音助手 SpeechRail。",
    response_format="wav",  # 支持 wav / mp3 / opus / aac / flac / pcm
)
speech.stream_to_file("output.wav")
```

---

### 2. TypeScript / Node.js (OpenAI SDK)

```typescript
import fs from "node:fs";
import OpenAI from "openai";

const openai = new OpenAI({
  baseURL: "http://127.0.0.1:8201/v1",
  apiKey: "local",
});

async function main() {
  // 1. 语音合成 (TTS)
  const response = await openai.audio.speech.create({
    model: "tts-1",
    voice: "serena",
    input: "SpeechRail 已完全就绪，正在本地极速为您提供语音服务。",
  });
  const buffer = Buffer.from(await response.arrayBuffer());
  await fs.promises.writeFile("speech.mp3", buffer);

  // 2. 语音转写 (ASR)
  const transcription = await openai.audio.transcriptions.create({
    file: fs.createReadStream("speech.mp3"),
    model: "whisper-1",
  });
  console.log("转写结果:", transcription.text);

  // 3. 原生讲话人分离：无需 SpeechRail 专用 SDK。
  const meeting = await openai.audio.transcriptions.create({
    file: fs.createReadStream("meeting.wav"),
    model: "gpt-4o-transcribe-diarize",
    response_format: "diarized_json",
    chunking_strategy: { type: "server_vad" },
  });
  console.log("分人转写:", meeting);
}

main();
```

---

### 3. cURL 命令行直接调用

无需安装任何 SDK，直接使用终端命令：

```bash
# 语音转文字 (ASR)
curl http://127.0.0.1:8201/v1/audio/transcriptions \
  -H "Authorization: Bearer local" \
  -F "file=@meeting.wav" \
  -F "model=whisper-1" \
  -F "response_format=json"

# 文字转语音 (TTS)
curl http://127.0.0.1:8201/v1/audio/speech \
  -H "Authorization: Bearer local" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tts-1",
    "input": "SpeechRail 已完全就绪，正在本地为您提供极速语音合成服务。",
    "voice": "serena",
    "response_format": "wav"
  }' \
  --output output.wav
```

---

### 4. 主流 Agent 与桌面 AI 客户端接入表

| 客户端 / Agent 平台 | 接口地址 (Base URL / Endpoint) | API Key | 协议类型 | 推荐接入模型与能力 |
|---|---|---|---|---|
| **[Sona](https://github.com/hrygo/sona)** | `ws://127.0.0.1:8201/v1/realtime` | `local` | WebSocket | 全双工流式 ASR + VAD + 声纹分离 + 流式 TTS |
| **[Open-WebUI](https://github.com/open-webui/open-webui)** | `http://127.0.0.1:8201/v1` | `local` | REST | `whisper-1` (语音听写) / `tts-1` (实时语音通话) |
| **[LiveKit](https://github.com/livekit/agents) / [Pipecat](https://github.com/pipecat-ai/pipecat)** | `ws://.../v1/realtime` 或 `/v1` | `local` | WS / REST | 实时全双工多模态 Voice Agent 管道与流水线 |
| **[Cherry Studio](https://github.com/Kang-k/Cherry-Studio)** | `http://127.0.0.1:8201/v1` | `local` | REST | `whisper-1` (语音输入) / `tts-1` (文字朗读) |
| **[OpenClaw](https://github.com/openclaw/openclaw)** | `http://127.0.0.1:8201/v1` | `local` | REST | `whisper-1` (语音指令) / `tts-1` (状态播报) |
| **[Dify](https://github.com/langgenius/dify) / FastGPT** | `http://127.0.0.1:8201/v1` | `local` | REST | `whisper-1` / `tts-1` (Agentic 知识库工作流) |

*注：以上为本机默认免密调用示例。若跨局域网接入，请将 `127.0.0.1` 替换为目标 Mac 内网 IP，并将 `local` 替换为您在服务端配置的 `SPEECHRAIL_API_KEY`。*

---

## 🎛️ 三档模型预设与 9 种跨档内置音色

SpeechRail 对外暴露统一 API 契约，内部按**用户场景**分为 **Embedded（`light`）/ Pro Workflow（`balanced`）/ Studio（`quality`）** 三档，而非单纯缩放模型大小。按档位精度策略让三档统一使用 8-bit 权重（仅 `quality` 的 aligner 保持 bf16 未量化）：

### 1. 硬件分档矩阵

| 预设档位 (Profile) | ASR 模型权重 | TTS 模型权重与变体 | Aligner / 分人 | 最低物理内存推荐 | 安装体积 (v2) | 活跃最大占用 (pre-v2) | 稳定占用 (pre-v2) | 空闲待机 (Idle) |
|---|---|---|---|---|---|---|---|---|
| 🟢 **`light`（Embedded 嵌入档）** | Qwen3-ASR 0.6B（`asr-0.6b-q8`，8-bit） | Qwen3-TTS 0.6B CustomVoice（`tts-0.6b-custom-q8`，8-bit） | ✗ 无 aligner / 无分人 | 8GB 基础款 Mac (Air / Mini) | **≈2.99 GB** (2986.6 MB) | **~4.4 GB** | **~4.1 GB** | **取决于运行时** (按配置卸载) |
| 🟡 **`balanced`（Pro Workflow 工作流档）** | Qwen3-ASR 1.7B（`asr-1.7b-q8`，8-bit） | Qwen3-TTS 0.6B CustomVoice（`tts-0.6b-custom-q8`，8-bit） | ✓ `aligner-q8` + Sortformer | 16GB / 24GB 主流 Mac (Pro / Max) | **≈5.96 GB** (5955.3 MB) | **~6.0 GB** | **~5.5 GB** | **取决于运行时** (按配置卸载) |
| 🟣 **`quality`（Studio 工作室档）** | Qwen3-ASR 1.7B（`asr-1.7b-q8`，8-bit） | 主 TTS：VoiceDesign 1.7B（`tts-1.7b-design-q8`）；按需克隆：Base 1.7B（`tts-1.7b-base-q8`），均为 8-bit | ✓ `aligner-bf16` + Sortformer | 32GB+ 旗舰款 Mac (Max / Ultra) | **≈10.73 GB** (≈10729.6 MB) | **需重新实测** | **需重新实测** | **取决于运行时** (按配置卸载) |

*占位说明：`活跃最大占用` / `稳定占用` 两列沿用此前全 q8 档位的实测值（pre-v2），在新的按档位精度策略下仅具方向性。按档位精度的重新实测尚未完成，这些数值不是新档位的实测结果；`安装体积` 列为 v2 catalog 实测体积。*

- **按档位精度策略**：三档统一使用 8-bit 权重——`light`（`asr-0.6b-q8` / `tts-0.6b-custom-q8`）、`balanced`（`asr-1.7b-q8` / `tts-0.6b-custom-q8`）、`quality`（`asr-1.7b-q8` / 主 `tts-1.7b-design-q8` / 克隆 capability `tts-1.7b-base-q8`）——仅 `quality` 的 aligner 保持 bf16。4-bit 的 `asr-0.6b-q4` / `tts-0.6b-custom-q4` light 方案经评估后未采纳：验收门 E1 在公开真人语料上测得 0.6B 4-bit ASR 相对 8-bit 基线劣化 1.38pp，超过 0.5pp 阈值。三档对外 API 契约完全一致；4-bit 制品仍保留在 catalog 中，但已不再被任何档位使用。
- **权重共享关系**：`balanced` 与 `quality` 共享同一个 1.7B ASR 制品；`balanced` 与 `light` 共享同一个 0.6B CustomVoice 8-bit 制品（`tts-0.6b-custom-q8`）。
- **可配置空闲卸载 (Idle Eviction)**：默认空闲超时为 **300 秒**，可通过 `SPEECHRAIL_WORKER_IDLE_TIMEOUT_SECONDS` 修改，设为 `0` 可禁用；卸载后的实测物理内存取决于运行时与档位。
- **Quality 音色创造边界**：`quality` 独享两类能力——自然语言创造音色由 **VoiceDesign 1.7B** 负责；参考音频克隆由 **Base 1.7B** 负责。`balanced` / `light` 使用 CustomVoice 0.6B，不声明这两类创建能力。
- **Base 按需加载**：Base 作为 Quality 的 `tts_clone` 制品安装，但不在服务启动时预热。capability router 在一个逻辑 TTS 槽内互斥切换 VoiceDesign ↔ Base；切换前关闭另一 worker，避免有意让两套 1.7B TTS 权重同时常驻，代价是 capability switch 冷启动。
- **质量门控音色克隆**：`POST /v1/voices/clone` 将参考音频 + 准确参考文本绑定到 Base public clone 路径。当前 synthesis 门禁已覆盖全部 6 类固定 probe，可拒绝静音/削波输出，并用固定 seed 下的重复 PCM 比较验证确定性；但绿色报告仍**不能**证明文本可懂度、任意噪声拒绝或跨文本 speaker identity，这些需要分阶段 ASR 与独立声纹证据。详见 [Quality 音色能力架构](docs/architecture/quality-voice-capabilities.md) 与 [输出可懂度 / ASR 复核设计](docs/architecture/voice-quality-intelligibility-validation.md)。

### 2. 9 种跨档系统内置音色

SpeechRail 在全档位下统一预置了 9 种经过声学微调的优质音色角色（接口与角色 ID 跨档保持一致，原生兼容 OpenAI 官方别名如 `alloy` -> `serena`, `echo` -> `eric`, `fable` -> `uncle_fu` 等）。

但请注意：**底层生成机制按档位和 capability 区分**——`balanced` / `light` 由 **CustomVoice (0.6B)** 驱动；`quality` 的普通/提示词音色由 **VoiceDesign (1.7B)** 驱动，而 reference clone 使用按需加载的 **Base (1.7B)**。用户可根据实际业务需要，在“绝对声线稳定性”与“丰富情感表现力”之间做针对性选择：

#### ⚖️ VoiceDesign 与 CustomVoice 核心差异与选型建议

| 比较维度 | 🟡 / 🟢 `balanced` / `light` (CustomVoice) | 🟣 `quality` (VoiceDesign) | 选型与适用场景建议 |
|---|---|---|---|
| **底层实现** | 固化 Speaker Embedding 权重 (物理常量) | 自然语言 Instruction 与声学提示驱动拟合 | CustomVoice 结构固化；VoiceDesign 算法拟合 |
| **声线稳定性 (Identity)** | 🔒 **极高 (近 100% 同一人一致性)**<br>跨不同长文本、不同语境音色完全恒定 | 🎨 **良好 (相同输入 100% 确定性复现)**<br>跨极端差异文本时偶有微小情绪/声调发散 | 长篇朗读、新闻播报、严肃客服选 **CustomVoice**；<br>允许或需要自然语调起伏选 **VoiceDesign** |
| **情感张力与表现力** | 规范、平稳、标准，情绪起伏小 | 丰富、生动、富有自然呼吸感与戏剧表现力 | 故事旁白、游戏 NPC、虚拟陪伴智能体首选 **VoiceDesign** |
| **开放自定义扩展** | 仅限 9 个固定角色，不支持自由创造 | 🌟 **支持自然语言 Prompt 任意创造新声线** | 需要探索或定制独一无二的新角色时必选 **`quality`** |
| **硬件内存与吞吐** | 极轻量 (~4.4-6.0GB 峰值, pre-v2)，推理极速 | 1.7B 高精度 (~6.9GB 峰值, pre-v2)，算力开销略高 | 8GB/16GB Mac 推荐前者；32GB+ 旗舰 Mac 畅享后者 |

> 深入对比数据与声学嵌入实测详见专题架构文档：[VoiceDesign 能力优势与音色稳定性边界](docs/architecture/voicedesign-capability-and-stability.md)。

#### 🎙️ 系统内置 9 大跨档官方角色清单

| 音色 ID (`voice`) | 角色名称 | 声音画像与特点 | 最佳适用场景 |
|---|---|---|---|
| `serena` | 温柔中文女声 (默认) | 温暖柔和的年轻中文女声，音色亲切自然，语气平和 | 个人桌面助理、日常交谈、短视频配音 |
| `vivian` | 明亮中文女声 | 明亮清脆的年轻中文女声，略带锋利质感，语气轻快 | 新闻资讯、长文朗读、科技解说 |
| `uncle_fu` | 醇厚中文男声 | 成熟稳重的中文男声，音色低沉醇厚，语速平稳从容 | 有声小说、商务讲座、纪录片旁白 |
| `dylan` | 北京青年男声 | 清晰自然的年轻男声，带自然北京口音，语气轻松直接 | 运动健身、游戏互动、口播带货 |
| `eric` | 成都活力男声 | 活泼明亮的年轻中文男声，略带沙哑质感和自然四川口音 | 情感陪伴、趣味互动、生活 Vlog |
| `ryan` | 动感英语男声 | 富有活力和节奏感的英语男声，发音清晰，表达有推动力 | 英语演讲、品牌广告、正式公告 |
| `aiden` | 阳光美式男声 | 阳光自然的美式英语年轻男声，中频清晰，语气友好 | 国际会议、外语教学、日常对话 |
| `ono_anna` | 轻快日语女声 | 轻盈灵动的年轻日语女声，语气俏皮自然，节奏明快 | 动漫二次元、虚拟主播、日语伴读 |
| `sohee` | 温暖韩语女声 | 温暖柔和的韩语女声，情感丰富，表达自然亲切 | 影视解说、韩语学习、情感电台 |

### 3. 可选讲话人分离模型

针对会议纪要、多人访谈和双工讨论等场景，SpeechRail 在本地 CoreML profile 就绪后提供可选的讲话人切分与会话级匿名标签能力。该能力仅 `balanced` / `quality` 档提供；`light`（Embedded）不含 aligner 与分人，因此不声明 `gpt-4o-transcribe-diarize`：

| 核心组件 | 底层模型架构 | 职责与能力边界 | 活跃推理开销 (Active RAM) | 客户端调用入口 |
|---|---|---|---|---|
| **时序切分引擎** | **FluidAudio CoreML FP16 Sortformer** (`SortformerNvidiaLow_v2.1.mlmodelc`) | 原生 Swift Worker 直接加载已编译 bundle，最多四个匿名讲话人 | **D1 峰值 RSS 564 MB** | `model="gpt-4o-transcribe-diarize"` 与 `response_format="diarized_json"` |

- **运行时与范围**：生产只有一个分人运行时：私有 Swift Worker 中的 FluidAudio CoreML FP16。它直接加载锁定的已编译 bundle，请求路径不会下载、编译、切换精度、调用 NeMo/CAM++ 或回退。
- **实测资源**：D1 在 M5 Max 固定 90 秒 streaming 输入上耗时 7.077 秒（RTFx 12.716），峰值 RSS 564 MB。该 smoke 不证明 DER/JER、长会话行为或通用内存上限。
- **Realtime 扩展**：`session.speechrail.diarization.enabled=true` 开启命名空间扩展。它输出不可变正文与 `speechrail.diarization.updated` 归属更新，并在 `speechrail.diarization.finish` 后以 `speechrail.diarization.done` 结束。
- **配置**：设置绝对路径 `SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH` 与 `SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR`。macOS wheel 已携带 `SpeechRailDiarizationWorker`；`SPEECHRAIL_DIARIZATION_WORKER_PATH` 仅用于受控排障覆盖。未配置分人路径时，普通 ASR/TTS 调用不受影响，也不会启动分人 Worker。aligner 是分人专用制品，由 catalog 按档位供给（`balanced` 为 `aligner-q8`，`quality` 为 `aligner-bf16`）；它不用于词级时间戳，词级时间戳由 ASR 原生提供。
- **离线端到端评测套件**：内置 `tools/evaluate_diarization_e2e.py`，支持基于全局最优二分匹配（Kuhn-Munkres）的 DER、Collar/Overlap 容差与 unknown 惩罚字级归属错误率（SACER）计算。

---

## 📊 真实性能基准实测 (Apple M5 Max)

> **v1.13.0 已于 2026-09-08 完成三档实测**：`quality → balanced → light → quality`；冷态、ASR/TTS warm N=5、当前 OpenAI Realtime（每档连续 3 session）、server-VAD 功能闭环与完整物理 footprint 采样均通过。独立 CER/WER、VAD FAR/FRR、MOS/ABX、讲话人分离质量、speaker embedding 与长时 soak 仍为 `unset`。
>
> 完整的脱敏报告见 [v1.13.0 性能与质量基准](docs/archive/performance/2026-09-08-v1.13.0-performance-benchmark.md)。ASR 与 v1.11.0 复用同一 fixture，可作方向性对照；TTS 使用不同固定文本，Realtime 本轮验证 current 嵌套音频 wire profile，均不作严格纵向结论。
>
> **v2 档位/精度说明**：catalog 的按档位精度策略为三档统一 8-bit 权重（仅 `quality` 的 aligner 为 bf16）；经评估的 4-bit `light` 方案已被验收门 E1 否决，不再使用。下方 v1.13.0 的全 q8 数值与该 8-bit 策略方向性可比；原有数值保持不变，保留其 v1.13.0 出处。

| 评测指标 | 🟢 Light 档（v1.13.0） | 🟡 Balanced 档（v1.13.0） | 🟣 Quality 档（v1.13.0） | 评测口径与场景 |
|---|---|---|---|---|
| **ASR 10s warm RTF p50** | **0.016** | **0.028** | **0.027** | 实际 9.36s fixture，warm N=5；越低越快 |
| **TTS short warm RTF p50** | **0.233** | **0.246** | **0.299** | 实测 PCM 时长，warm N=5；文本仅适用于 v1.13.0 |
| **最大同时物理占用** | **5.39 GB** (5385.0 MB) | **6.30 GB** (6304.7 MB) | **7.51 GB** (7512.6 MB) | 同一 tick `phys_footprint`，采样完整 |
| **预热常驻物理占用** | **4.09 GB** (4088.6 MB) | **5.48 GB** (5483.5 MB) | **6.74 GB** (6742.2 MB) | 权重 fault-in 后 |
| **Realtime ASR commit p50** | **238.2 ms** | **348.6 ms** | **373.6 ms** | 16kHz PCM16、current nested profile、连续 3 session，终态成功 3/3 |
| **Realtime TTS first delta p50** | **25.0 ms** | **26.1 ms** | **38.4 ms** | `response.output_audio.delta`，连续 3 session |

> `balanced` 与 `light` 使用 `CustomVoice`，`quality` 使用 `VoiceDesign`。共享 worker 冲突会稳定返回 `backend_busy`，不把它计为可用的并发 batch 吞吐。

---

## 🏛️ 物理隔离架构与设计哲学

```mermaid
flowchart TD
    Client["客户端应用 (Sona / OpenAI SDK / WebUI / LiveKit)"]

    subgraph HostService["FastAPI 宿主守护网关 (Port: 8201)"]
        direction TB
        subgraph Ingress["1. 协议接入与音频管道"]
            Router["REST / WS 路由、鉴权与错误 Envelope"]
            Pipeline["内存音频流水线\n(WAV Fast-Path 直读 / ffmpeg 管道流式解码, 128MB 门禁)"]
        end
        subgraph Core["2. 运行时调度与协同核心"]
            App["应用服务与 Realtime 会话"]
            Governor["AdmissionQueue + ResourceGovernor\n(Realtime 容量预留、Batch FIFO/Aging、\n可配置 ASR∥TTS 重计算重叠)"]
            Ledger["AttributionLedger 归属账本\n(16 kHz 采样时钟, 不可变单元)"]
            DiarizeEngine["可选分人 Port\n(FluidAudio CoreML FP16 Swift Worker)"]
            Evictor["WorkerIdleEvictor\n(默认 300 秒；可配置)"]
        end
        Router -->|音频上传| Pipeline --> App
        Router -->|系统、音色、任务、WS 控制| App
        App --> Governor
        App <--> Ledger
        App <--> DiarizeEngine
        App -. 活动与生命周期 .-> Evictor
    end

    subgraph SubprocessSandboxes["独立子进程沙箱 (物理进程强隔离)"]
        direction LR
        ASRWorker["Qwen3-ASR Worker\n(MLX / Metal 独立子进程)"]
        TTSWorker["Qwen3-TTS capability slot\n(Quality: VoiceDesign ↔ Base clone；其他: CustomVoice)"]
        DiarizationWorker["分人 Worker\n(FluidAudio / CoreML FP16)"]
    end

    Client <== "HTTP REST / 全双工 WS" ==> Router
    App <== "长度前缀 JSON + 原始二进制 IPC" ==> ASRWorker
    App <== "长度前缀 JSON + 原始二进制 IPC" ==> TTSWorker
    App <== "长度前缀 JSON + 原始 PCM IPC" ==> DiarizationWorker
    Evictor -. 尝试释放常驻权重 .-> ASRWorker
    Evictor -. 尝试释放常驻权重 .-> TTSWorker
    Evictor -. Worker 生命周期 .-> DiarizationWorker
```

#### 核心架构原则与设计不变量

1. **子进程物理隔离（故障爆炸半径最小化）**：Qwen3-ASR 与 Qwen3-TTS 在独立子进程中运行。主进程使用“长度前缀 + JSON metadata + 可选原始二进制 payload”的私有协议；原始 PCM 在此跳不经 Base64，但该协议并非严格零拷贝。Worker 故障与 FastAPI 主进程隔离，对外通过带 `request_id` 的标准错误 Envelope 返回。
2. **纯内存零磁盘音频流水线**：请求音频在内存中经三级防护流式处理：Tier 1 WAV 快速通道（无转码切片直读）、Tier 2 管道级内存 `ffmpeg` 流式解码（适配 MP3/Opus/FLAC 等容器）、Tier 3 128MB 硬上限门禁。源音频、中间 PCM、声纹特征向量与转写文本均不落盘，全链路本地闭环，严禁网络静默外呼。
3. **协同空闲驱逐**：`WorkerIdleEvictor` 按配置的 idle 与 standby 超时管理外部 Worker。待机物理内存以实际基准为准，不作为架构承诺。
4. **会话级分人边界**：批量分人只输出匿名 label。命名空间 Realtime 扩展使用 16 kHz 会话时钟，后续归属更新不改写转写正文。
5. **单机共享并发**：`ResourceGovernor` 为 Realtime 预留容量，并让 Batch 以 FIFO 加 aging 规则等待；它不抢占已经进入 Worker 的工作。模式冲突稳定返回 busy 错误，而不是复制模型进程。ASR∥TTS 重计算重叠是可配置、按预算判定的策略（默认 `SPEECHRAIL_ALLOW_HEAVY_OVERLAP=auto`，启用组件未声明常驻峰值前 fail-closed）：重叠轴仅 ASR∥TTS，TTS∥TTS 与 ASR∥ASR 仍返回 `backend_busy`，不复制 Worker。
6. **严格职责分离与边界清晰**：SpeechRail 专注于提供纯粹的本地推理运行时、协议转换、资源护栏与会话级匿名标签（`speaker_0`, `speaker_1`）。麦克风硬件调用、扬声器播放、会议议程与数据库持久化、实名声纹库映射、UI 交互以及 LLM 业务编排由调用方应用（如 [Sona](https://github.com/hrygo/sona)）全权负责。

---

## 🛠️ 守护进程管理 (LaunchAgent)

SpeechRail 遵循 macOS 标准的用户级守护进程机制，通过原生命令随时管控：

```bash
# 查看常驻服务当前运行状态与 PID
uv run speechrail service status

# 重启守护服务
uv run speechrail service restart

# 停止或卸载守护服务
uv run speechrail service stop
uv run speechrail service uninstall
```

---

## ❓ 常见问题

<details>
<summary><strong>Q1: 我的电脑装的是 Python 3.13 或 3.9，会有版本冲突吗？</strong></summary>

**完全不会。** 安装脚本与引导工具内置了自动环境隔离与自愈逻辑。它不会修改您的系统全局 Python，而是通过 `uv` 自动拉取一套官方独立的 CPython 3.12 并在沙箱中运行，两者完全隔离、互不干扰。
</details>

<details>
<summary><strong>Q2: 为什么暂不支持 Intel (x86_64) 架构的 Mac？</strong></summary>

SpeechRail 的核心性能来自于 Apple MLX 框架对 **Apple Silicon 统一内存（Unified Memory Architecture）与 Metal GPU** 的深度调优。Intel Mac 没有统一内存架构，MLX 官方目前完全不提供 x86_64 预编译支持。若您使用 Intel Mac，建议使用轻量的 `whisper.cpp` 或通过网络接入另一台 Mac 上的 SpeechRail 服务。
</details>

<details>
<summary><strong>Q3: 为什么本机调用时不需要配置 API Key？</strong></summary>

为了给个人桌面开发提供极致的“开箱即用”体验，SpeechRail 默认仅监听本地环回接口 `127.0.0.1`，此时放行本地调用。一旦您在配置中将监听地址开放至局域网（如 `0.0.0.0`），服务会强制校验 `SPEECHRAIL_API_KEY`，未配置将直接拒绝启动。
</details>

<details>
<summary><strong>Q4: 切换模型档位时需要重新下载所有模型吗？</strong></summary>

不需要。所有模型权重在下载后都会持久化保存在受管目录中。当您在 `light`、`balanced`、`quality` 之间切换时，已下载过的档位会直接秒级复用本地缓存。
</details>

<details>
<summary><strong>Q5: 如何开启多人会议讲话人分离 (Speaker Diarization)？它占用多少内存？</strong></summary>

讲话人分离是可选的原生能力。安装 macOS wheel 后，设置 `SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH`（锁定的 `SortformerNvidiaLow_v2.1.mlmodelc` bundle）与 `SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR` 的绝对路径。wheel 已内置 Swift Worker；`SPEECHRAIL_DIARIZATION_WORKER_PATH` 仅用于受控覆盖。请求路径不会下载或编译模型。
- **内存占用**：D1 在 M5 Max 单条固定 90 秒输入上测得峰值 RSS 564 MB；其他设备和输入需独立测量。
- **API**：文件转录使用 OpenAI 分人模型和 `diarized_json`。Realtime 通过 `session.speechrail.diarization.enabled=true` 开启，扩展仅携带匿名、会话级标签。
</details>

---

## 📚 完整文档中心

| 读者角色 | 推荐入口与文档说明 |
|---|---|
| 🚀 **小白 / 快速搭建** | [空白 Mac 从零搭建指南 (`speechrail-zero-setup`)](.agents/skills/speechrail-zero-setup/SKILL.md) · [运维排障手册](docs/operations/operations-runbook.md) |
| 🔌 **API 开发者** | [用户与客户端集成指南](docs/users/README.md) · [OpenAI 兼容契约详解](docs/users/api-contract.md) · [OpenAPI 规范](contracts/openapi.yaml) |
| 🛠️ **系统运维** | [运维中心](docs/operations/README.md) · [受管运行时部署说明](docs/operations/runtime-deployment.md) · [分人验收报告](docs/operations/speaker-diarization-e2e-acceptance-2026-09-06.md) · [安全与可观测性](docs/operations/security-observability.md) |
| 🧪 **代码贡献者** | [开发者中心](docs/developers/README.md) · [本地测试与验收套件](docs/developers/testing-acceptance.md) |
| 📐 **架构评审** | [系统架构全景](docs/architecture/README.md) · [Quality 音色创造、克隆与稳定化能力](docs/architecture/quality-voice-capabilities.md) · [音色克隆工程设计](docs/architecture/voice-cloning-design-and-handoff.md) · [克隆音色质量门禁与自量保障契约](docs/architecture/voice-clone-quality-gates-and-contract.md) · [当前边界与权衡](docs/architecture/current-boundaries.md) · [架构决策记录 (ADRs)](docs/decisions/README.md) |

---

## 🤝 参与贡献与许可证

- 提交代码前请阅读 [贡献指南 (CONTRIBUTING.md)](CONTRIBUTING.md)。
- 漏洞报告请参阅 [安全策略 (SECURITY.md)](SECURITY.md)。
- 社区交流请遵守 [行为准则 (CODE_OF_CONDUCT.md)](CODE_OF_CONDUCT.md)。

SpeechRail 采用宽松友好的 [MIT License](LICENSE) 授权开源。您可以自由用于个人创作或商业软件集成。
