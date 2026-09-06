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
  <em>为 Sona 提供私有、本地、实时 ASR/TTS 与多人讲话人分离能力。</em>
</p>

---

## 💡 为什么需要 SpeechRail？

当你为个人桌面 Agent、本地会议转录助手、播客剪辑或各种 AI 工具添加语音能力时，通常面临两难：
- **调用商业云端 API（如 OpenAI Whisper / TTS）**：每分钟音频都在上传云端，面临隐私泄露隐患；公网抖动带来数百毫秒额外延迟；高频调用产生持续且高昂的账单。
- **本地应用重复加载模型**：不同桌面应用各自加载模型导致内存爆炸，显存泄漏与异常容易直接拖垮宿主进程。

**SpeechRail 的解法**：作为一个**在 macOS 后台静默常驻的高性能本地语音 Daemon**，单端口监听，本机及局域网所有客户端与 Agent 即插即用：

- 🔒 **数据零离机与强隐私**：默认绑定本地环回（`127.0.0.1`），亦支持内网受控暴露。音频纯内存处理不落盘，全链路本地私有推理，绝无任何数据外呼与云端泄露。
- 🔌 **OpenAI 协议 1:1 无缝替换**：完整实现 `whisper-1`（文件转录）、`tts-1`（语音合成）与 `/v1/realtime`（低延迟双工流式 ASR/TTS），客户端改一行 `base_url` 即可接入。
- 🛡️ **双物理进程隔离架构**：HTTP 网关与重型 MLX 推理引擎运行在不同物理进程中，通过高效 IPC 管道通信。Worker 崩溃绝不拖垮网关。
- 🍃 **智能两阶段空闲卸载 (Idle Eviction)**：推理完毕后，默认 **5 分钟无请求自动卸载模型权重并释放显存**，常驻待机内存仅约 **50 MB**，绝不霸占 Mac 宝贵内存。
- 👥 **原生多讲话人分离 (Speaker Diarization)**：集成 NeMo Sortformer 与 CAM++ 声纹模型，自动区分并标注不同发言人（如 `speaker_0`, `speaker_1`），轻松驾驭多人会议与访谈；支持批量 `diarized_json` 与 `/v1/realtime` 流式持续分人扩展（`speechrail.diarization.v1`），践行“正文先固定，归属后更新”与结束落库屏障。
- 🎚️ **动态三档资源匹配**：针对 8GB 到 128GB 的 Apple Silicon 芯片深度调优（Light / Balanced / Quality），一键无感热切换。
- 🎙️ **9 种跨档高质量内置音色**：原生集成 Qwen3-TTS 语音能力，涵盖中文、英语、粤语、日语、韩语等丰富声学角色。

---

## ⚖️ 核心方案对比

| 核心特性 | **SpeechRail 🎙️ (本地常驻基础设施)** | **商业公有云 API (如 OpenAI)** |
|---|---|---|
| **数据隐私** | 🔒 **100% 本机私有推理，数据零离机**（默认本地免密直连，支持内网鉴权暴露，绝不上云） | ❌ 音频必须上传云端，面临合规与泄露风险 |
| **长期调用成本** | 💰 **$0（一次安装，全机及内网无限量免费调用）** | 💸 按音频时长/Token 持续计费，高频使用昂贵 |
| **网络环境依赖** | ⚡ **纯离线本地计算，0 公网延迟，断网可用** | ⚠️ 依赖稳定外网与跨境链路，受网络抖动影响 |
| **全机复用与内存管理**| 🍃 **单常驻 Daemon 供全机共享，空闲自动卸载权重 (~50MB)** | 统一云端网关，无本地模型负载 |
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
        model="gpt-4o-transcribe-diarize",  # 调度本地 NeMo Sortformer 讲话人分离引擎
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

SpeechRail 对外暴露统一 API 契约，内部通过轻巧的分档组合适配不同配置的 Apple Silicon Mac。全档位严格采用 **8-bit (q8)** 高精度量化权重：

### 1. 硬件分档矩阵

| 预设档位 (Profile) | ASR 模型权重 | TTS 模型权重与变体 | 最低物理内存推荐 | 活跃最大占用 (Peak) | 稳定占用 (Steady) | 空闲待机 (Idle) |
|---|---|---|---|---|---|---|
| 🟢 **`light` (轻量档)** | Qwen3-ASR 0.6B (q8) | Qwen3-TTS 0.6B CustomVoice (q8) | 8GB 基础款 Mac (Air / Mini) | **~4.4 GB** | **~4.1 GB** | **~50 MB** (自动卸载) |
| 🟡 **`balanced` (平衡档)** | Qwen3-ASR 1.7B (q8) | Qwen3-TTS 0.6B CustomVoice (q8) | 16GB / 24GB 主流 Mac (Pro / Max) | **~6.0 GB** | **~5.5 GB** | **~50 MB** (自动卸载) |
| 🟣 **`quality` (高保真档)** | Qwen3-ASR 1.7B (q8) | Qwen3-TTS 1.7B VoiceDesign (q8) | 32GB+ 旗舰款 Mac (Max / Ultra) | **~6.9 GB** | **~6.6 GB** | **~50 MB** (自动卸载) |

- **全档 8-bit 高精度量化**：全档位模型严格保证 8-bit 量化精度，拒绝低位量化带来的音频失真与发音崩塌。
- **权重高效复用**：`balanced` 与 `quality` 共享同一个 1.7B ASR 模型；`balanced` 与 `light` 共享同一个 0.6B CustomVoice TTS 模型。
- **智能两阶段空闲卸载 (Idle Eviction)**：默认 5 分钟无请求时自动触发冷卸载释放显存与内存，常驻待机仅占用约 **~50 MB**，新请求秒级懒拉起。
- **音色设计边界**：仅 `quality` 档支持通过自然语言设计自定义新音色（VoiceDesign）；在 `balanced`/`light` 档下，自定义音色会自动声明为 `available=false`，切回 `quality` 自动恢复。

### 2. 9 种跨档系统内置音色

SpeechRail 在全档位下统一预置了 9 种经过声学微调的优质音色角色（接口与角色 ID 跨档保持一致，原生兼容 OpenAI 官方别名如 `alloy` -> `serena`, `echo` -> `eric`, `fable` -> `uncle_fu` 等）。

但请注意：**同一角色在不同档位下的底层生成机制不同**——`balanced` / `light` 由 **CustomVoice (0.6B)** 驱动，而 `quality` 档由 **VoiceDesign (1.7B)** 驱动。用户可根据实际业务需要，在“绝对声线稳定性”与“丰富情感表现力”之间做针对性选择：

#### ⚖️ VoiceDesign 与 CustomVoice 核心差异与选型建议

| 比较维度 | 🟡 / 🟢 `balanced` / `light` (CustomVoice) | 🟣 `quality` (VoiceDesign) | 选型与适用场景建议 |
|---|---|---|---|
| **底层实现** | 固化 Speaker Embedding 权重 (物理常量) | 自然语言 Instruction 与声学提示驱动拟合 | CustomVoice 结构固化；VoiceDesign 算法拟合 |
| **声线稳定性 (Identity)** | 🔒 **极高 (近 100% 同一人一致性)**<br>跨不同长文本、不同语境音色完全恒定 | 🎨 **良好 (相同输入 100% 确定性复现)**<br>跨极端差异文本时偶有微小情绪/声调发散 | 长篇朗读、新闻播报、严肃客服选 **CustomVoice**；<br>允许或需要自然语调起伏选 **VoiceDesign** |
| **情感张力与表现力** | 规范、平稳、标准，情绪起伏小 | 丰富、生动、富有自然呼吸感与戏剧表现力 | 故事旁白、游戏 NPC、虚拟陪伴智能体首选 **VoiceDesign** |
| **开放自定义扩展** | 仅限 9 个固定角色，不支持自由创造 | 🌟 **支持自然语言 Prompt 任意创造新声线** | 需要探索或定制独一无二的新角色时必选 **`quality`** |
| **硬件内存与吞吐** | 极轻量 (~4.4-6.0GB 峰值)，推理极速 | 1.7B 高精度 (~6.9GB 峰值)，算力开销略高 | 8GB/16GB Mac 推荐前者；32GB+ 旗舰 Mac 畅享后者 |

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

针对会议纪要、多人访谈和双工讨论等场景，SpeechRail 原生集成了高性能多讲话人时序切分与角色分离能力：

| 核心组件 | 底层模型架构 | 职责与能力边界 | 活跃推理开销 (Active RAM) | 客户端调用入口 |
|---|---|---|---|---|
| **时序切分引擎** | **NVIDIA NeMo Sortformer** (`diar_streaming_sortformer_4spk-v2`) | 在线/离线流式切分不同发言人时间边界，支持最多 4 人重叠语音分离 | **+约 0.5 GB** (500 MB) | `model="gpt-4o-transcribe-diarize"` 或 `response_format="diarized_json"` |
| **声纹特征提取 (可选)** | **3D-Speaker CAM++** (`3dspeaker_speech_campplus_sv_zh-cn_16k-common`) | 提取 16kHz PCM 声纹特征向量，跨会话短时重聚类，确保发言人归一 | **极轻量** (~数十 MB) | 会话内断线重连或长会议平滑映射 |

- **活跃内存开销**：启用并在处理多人会议转录时，额外常驻约 **+0.5 GB** 物理内存（未配置模型时零额外开销）。
- **统一空闲卸载**：深度接入 `EvictableWorker` 机制，**连续 5 分钟无调用自动触发冷卸载释放全部权重与显存**，常驻待机内存回落至 **~50 MB**。
- **端到端持续分人扩展 (SPK-E2E-1)**：针对多人连续会议，在 `/v1/realtime` 中提供 `speechrail.diarization.v1` 扩展。采用“**正文先固定，归属后更新**”范式与全局整数采样时标（16 kHz session samples），根治跨分钟时钟漂移和二次文字篡改；配合客户端 `finalize` 结束屏障，确保所有归属补丁落库后方触发最终纪要（详见 [端到端设计](docs/architecture/speaker-diarization-e2e-design.md) 与 [验收报告](docs/operations/speaker-diarization-e2e-acceptance-2026-09-06.md)）。
- **与消费端 Sona 100% 接线**：已与 [Sona](https://github.com/hrygo/sona) 桌面会议助手完成全链路接线，支持流式补丁更新、人工改名优先仲裁与纪要终态落库屏障。
- **离线端到端评测套件**：内置 `tools/evaluate_diarization_e2e.py`，支持基于全局最优二分匹配（Kuhn-Munkres）的 DER、Collar/Overlap 容差与 unknown 惩罚字级归属错误率（SACER）计算。
- **按需可选安装**：执行 `uv sync --extra diarization` 安装可选依赖并在配置中启用即可。

---

## 📊 真实性能基准实测 (Apple M5 Max)

以下数据来源于 Apple M5 Max (128GB Unified Memory) 上的串行真实基准测试（引自 [v1.8.0 性能、架构与发布验收报告](docs/archive/performance/2026-09-06-v1.8.0-performance-benchmark.md)），真实可复现；历史基线仍保留在归档中：

| 评测指标 | 🟢 Light 档实测 | 🟡 Balanced 档实测 | 🟣 Quality 档实测 | 评测口径与场景 |
|---|---|---|---|---|
| **ASR 中文 RTF (均值)** | **0.0204** (约 49 倍实时) | **0.0295** (约 34 倍实时) | **0.0300** (约 33 倍实时) | 独立 macOS fixture，N=5；延迟 p50、RTF 均值 |
| **ASR 英文 RTF (均值)** | **0.0229** (约 44 倍实时) | **0.0339** (约 30 倍实时) | **0.0362** (约 28 倍实时) | 独立英文 fixture，N=5；延迟 p50、RTF 均值 |
| **TTS 生成 RTF (均值)** | **0.2372** (约 4.2 倍实时) | **0.2467** (约 4.1 倍实时) | **0.2690** (约 3.7 倍实时) | 统一中文文本、`default` 音色，N=5；延迟 p50 |
| **最大同时物理占用** | **~4.7 GB** (4709.7 MB) | **~6.3 GB** (6305.9 MB) | **~7.3 GB** (7282.2 MB) | 同一 tick `phys_footprint` 较大值 |
| **稳定物理占用** | **~4.1 GB** (4147.1 MB) | **~5.5 GB** (5542.8 MB) | **~6.7 GB** (6668.2 MB) | 持续工作稳定态物理内存 |
| **空闲卸载待机内存** | **~50 MB** | **~50 MB** | **~50 MB** | 5 分钟无请求自动卸载释放 Worker |

---

## 🏛️ 物理隔离架构与设计哲学

```mermaid
flowchart TD
    Client["客户端应用 (Sona / OpenAI SDK / WebUI / LiveKit)"]

    subgraph HostService["FastAPI 宿主守护网关 (Port: 8201)"]
        direction TB
        subgraph Ingress["1. 协议接入与音频管道"]
            Router["路由分发与统一 Envelope (/v1/audio/*, /v1/realtime)"]
            Pipeline["内存音频流水线\n(WAV Fast-Path 直读 / ffmpeg 管道流式解码, 128MB 门禁)"]
        end
        subgraph Core["2. 运行时调度与协同核心"]
            Governor["Resource Governor\n(优先级队列调度 & WorkerLeaseLock)"]
            Ledger["AttributionLedger 归属账本\n(16 kHz 采样时钟, 不可变单元)"]
            Evictor["WorkerIdleEvictor\n(5 分钟无调用权重与显存冷卸载)"]
        end
        Router --> Pipeline --> Governor
        Governor <--> Ledger
        Governor -. 闲置监控 .-> Evictor
    end

    subgraph SubprocessSandboxes["独立子进程沙箱 (物理进程强隔离)"]
        direction LR
        ASRWorker["Qwen3-ASR Worker\n(MLX / Metal 独立子进程)"]
        TTSWorker["Qwen3-TTS Worker\n(VoiceDesign / CustomVoice MLX)"]
    end

    subgraph InServiceEngine["进程内受管引擎 (按需受管卸载)"]
        DiarizeEngine["讲话人分离引擎 (可选)\n(NeMo Sortformer + CAM++)"]
    end

    Client <== "HTTP REST / 全双工 WS" ==> Router
    Governor <== "私有 Framed 二进制零拷贝 IPC" ==> ASRWorker
    Governor <== "私有 Framed 二进制零拷贝 IPC" ==> TTSWorker
    Governor <== "会话级连续流式协调" ==> DiarizeEngine
    Evictor -. 自动卸载释放权重 .-> ASRWorker
    Evictor -. 自动卸载释放权重 .-> TTSWorker
    Evictor -. 自动卸载释放权重 .-> DiarizeEngine
```

#### 核心架构原则与设计不变量

1. **子进程物理隔离（故障爆炸半径最小化）**：重型 MLX 模型执行引擎（Qwen3-ASR 与 Qwen3-TTS）在独立子进程中运行，通过私有 Framed 二进制 IPC 管道与网关通信。任何 Metal GPU 显存异常或底层 C++ 崩溃均被严格限制在子进程内；FastAPI 网关保持在线并自动平滑拉起新 Worker，对外返回带可追溯 `request_id` 的标准错误 Envelope。
2. **纯内存零磁盘音频流水线**：请求音频在内存中经三级防护流式处理：Tier 1 WAV 快速通道（无转码切片直读）、Tier 2 管道级内存 `ffmpeg` 流式解码（适配 MP3/Opus/FLAC 等容器）、Tier 3 128MB 硬上限门禁。源音频、中间 PCM、声纹特征向量与转写文本均不落盘，全链路本地闭环，严禁网络静默外呼。
3. **协同空闲驱逐与绿色休眠**：网关内置的 `WorkerIdleEvictor` 统一监控外部 IPC Worker 与进程内受管引擎的租约状态。连续 5 分钟无业务请求时，自动触发权重冷卸载并归还全部 Metal/MPS 显存与物理内存，常驻待机内存回落至约 50 MB，不留任何孤儿后台进程。
4. **“正文先固定，归属后更新”时序不变量（SPK-E2E-1）**：实时分人严格遵循不可变时序范式。ASR commit 产生的正文为权威文本，归属单元（`attribution_units`）锚定于 16 kHz 全局整数采样时钟；后续分人精细聚类仅通过异步事件（`speechrail.diarization.update`）增量修正发言人归属，绝不二次篡改已固定文字与时间戳，彻底根治跨分钟时钟漂移；配合客户端 `finalize` 结束屏障，确保全部归属补丁落库后再触发最终纪要。
5. **单机单卡共享并发与租约锁（WorkerLeaseLock）**：作为单人桌面环境下多应用的共享底座，通过 `WorkerLeaseLock` 和通道优先级（Realtime 优先抢占，Batch 排队）实现有序互斥调度，模式冲突时稳定返回 `backend_busy`，坚决不通过复制模型进程来盲目换取并发，杜绝显存雪崩。
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

讲话人分离属于按需扩展能力。您只需执行 `uv sync --extra diarization` 安装配套依赖，并在 `.env` 中指定 NVIDIA NeMo Sortformer 权重文件路径（`SPEECHRAIL_DIARIZATION_MODEL_PATH`）。
- **内存占用**：未配置时为 **0 MB**；启用并处理多人转录时，宿主额外占用约 **0.5 GB** 物理内存。
- **自动卸载**：同样深度接入系统空闲驱逐器，**连续 5 分钟无调用自动释放全部权重**，完全归还内存，绝不长期霸占系统资源。
</details>

---

## 📚 完整文档中心

| 读者角色 | 推荐入口与文档说明 |
|---|---|
| 🚀 **小白 / 快速搭建** | [空白 Mac 从零搭建指南 (`speechrail-zero-setup`)](.agents/skills/speechrail-zero-setup/SKILL.md) · [运维排障手册](docs/operations/operations-runbook.md) |
| 🔌 **API 开发者** | [用户与客户端集成指南](docs/users/README.md) · [OpenAI 兼容契约详解](docs/users/api-contract.md) · [OpenAPI 规范](contracts/openapi.yaml) |
| 🛠️ **系统运维** | [运维中心](docs/operations/README.md) · [受管运行时部署说明](docs/operations/runtime-deployment.md) · [分人验收报告](docs/operations/speaker-diarization-e2e-acceptance-2026-09-06.md) · [安全与可观测性](docs/operations/security-observability.md) |
| 🧪 **代码贡献者** | [开发者中心](docs/developers/README.md) · [本地测试与验收套件](docs/developers/testing-acceptance.md) |
| 📐 **架构评审** | [系统架构全景](docs/architecture/README.md) · [分人端到端设计](docs/architecture/speaker-diarization-e2e-design.md) · [当前边界与权衡](docs/architecture/current-boundaries.md) · [架构决策记录 (ADRs)](docs/decisions/README.md) |

---

## 🤝 参与贡献与许可证

- 提交代码前请阅读 [贡献指南 (CONTRIBUTING.md)](CONTRIBUTING.md)。
- 漏洞报告请参阅 [安全策略 (SECURITY.md)](SECURITY.md)。
- 社区交流请遵守 [行为准则 (CODE_OF_CONDUCT.md)](CODE_OF_CONDUCT.md)。

SpeechRail 采用宽松友好的 [MIT License](LICENSE) 授权开源。您可以自由用于个人创作或商业软件集成。
