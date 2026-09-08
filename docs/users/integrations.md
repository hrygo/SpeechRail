---
title: "SpeechRail 客户端与 SDK 接入指南"
status: active
audience: "应用开发者、客户端工程师、API 消费者"
version: "1.7.0"
date: 2026-09-08
---

# 🔌 SpeechRail 客户端与 SDK 接入指南

> SpeechRail 对外暴露严格符合 OpenAI 契约规范的 REST 与 WebSocket 接口。所有客户端应用仅需调用公共接口，无需感知底层的模型权重、环境依赖或 Worker 调度。

---

## 1. 基础连接信息

| 配置项 | 本地默认值 | 局域网模式 (LAN) | 备注 |
|---|---|---|---|
| **服务根地址 (Root URL)** | `http://127.0.0.1:8201` | `http://<lan-ip>:8201` | 基础探针地址 |
| **OpenAI Base URL** | `http://127.0.0.1:8201/v1` | `http://<lan-ip>:8201/v1` | SDK 与标准应用接入地址 |
| **Realtime WebSocket URL** | `ws://127.0.0.1:8201/v1/realtime` | `ws://<lan-ip>:8201/v1/realtime` | 全双工实时交互端点 |
| **API Key** | 留空或任意占位字符 | 必须配置 `SPEECHRAIL_API_KEY` | 通过 `Authorization: Bearer <key>` 鉴权 |

---

## 2. 官方 SDK 接入实战

### 2.1 Python OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8201/v1",
    api_key="local-mode",  # loopback 模式可填任意字符串
)

# 1. 批量文件转写 (支持 segment 与 word 时间戳)
with open("test.wav", "rb") as f:
    transcript = client.audio.transcriptions.create(
        model="whisper-1",  # 兼容别名，自动路由至 speechrail/qwen3-asr-1.7b
        file=f,
        language="zh",
        response_format="verbose_json",
        timestamp_granularities=["segment", "word"],
    )
    print("识别全文:", transcript.text)
    for seg in transcript.segments or []:
        print(f"[{seg.start:.2f}s -> {seg.end:.2f}s]: {seg.text}")

# 2. 语音合成 (TTS)
response = client.audio.speech.create(
    model="tts-1",  # 兼容别名，自动路由至 speechrail/qwen3-tts
    voice="serena",  # 九个 canonical 角色之一；也接受 OpenAI 标准 voice alias
    input="SpeechRail 正在为您提供本地语音服务。",
    response_format="wav",
)
response.stream_to_file("output.wav")
```

### 2.2 Node.js / TypeScript OpenAI SDK

```typescript
import OpenAI from "openai";
import fs from "fs";

const openai = new OpenAI({
  baseURL: "http://127.0.0.1:8201/v1",
  apiKey: "local-mode",
});

async function main() {
  // 1. ASR 转写
  const transcription = await openai.audio.transcriptions.create({
    file: fs.createReadStream("audio.mp3"),
    model: "whisper-1",
    response_format: "verbose_json",
  });
  console.log("转写文本:", transcription.text);

  // 2. TTS 合成
  const mp3 = await openai.audio.speech.create({
    model: "tts-1",
    voice: "uncle_fu",
    input: "欢迎使用 SpeechRail 实时语音引擎。",
  });
  const buffer = Buffer.from(await mp3.arrayBuffer());
  await fs.promises.writeFile("speech.mp3", buffer);
}

main();
```

---

## 3. 主流 Agent 与客户端接入实战

### 3.1 [Sona (Voice-Realtime 会议助理)](https://github.com/hrygo/sona)
Sona 是专为本地高私密环境打造的实时双工会议助理，通过 `/v1/realtime` 端点连接 SpeechRail：
- **WebSocket URL**：`ws://127.0.0.1:8201/v1/realtime`
- **核心能力**：全双工流式 ASR、Server VAD 自动断句与流式 TTS。连续 native diarization 未通过独立 gate 时不会广播；客户端应先读取 Realtime capability。
- **架构权责**：Sona 负责麦克风音频采集、会话状态机、UI 字幕渲染与 LLM 业务编排；SpeechRail 负责本地模型推理与物理内存隔离治理。

### 3.2 [Open-WebUI 个人 AI 工作台](https://github.com/open-webui/open-webui)
在 Open-WebUI 的管理员设置（Admin Settings -> Audio）中配置：
- **STT Settings**：
  - **STT Engine**：`OpenAI`
  - **OpenAI Base URL**：`http://127.0.0.1:8201/v1`
  - **STT Model**：`whisper-1`
- **TTS Settings**：
  - **TTS Engine**：`OpenAI`
  - **OpenAI Base URL**：`http://127.0.0.1:8201/v1`
  - **TTS Model**：`tts-1`
  - **TTS Voice**：`serena` (或其他系统内置音色)

*配置后，所有 Web 端的语音听写与实时语音通话 (Voice Call) 将 100% 由本地 Apple Silicon 推理，零云端 API 依赖。*

### 3.3 [LiveKit Agents / Pipecat 实时语音智能体](https://github.com/livekit/agents)
在基于 LiveKit Agents 或 [Pipecat](https://github.com/pipecat-ai/pipecat) 构建 2026 年多模态全双工智能体时，直接通过 OpenAI 兼容适配器接入：
```python
# LiveKit Agents OpenAI 语音插件示例
from livekit.plugins import openai

stt = openai.STT(
    base_url="http://127.0.0.1:8201/v1",
    api_key="local",
    model="whisper-1",
)
tts = openai.TTS(
    base_url="http://127.0.0.1:8201/v1",
    api_key="local",
    model="tts-1",
    voice="serena",
)
```

### 3.4 [OpenClaw 本地优先个人助手](https://github.com/openclaw/openclaw)
在 OpenClaw 的本地配置文件中将语音管道指向 SpeechRail：
```dotenv
OPENCLAW_STT_BASE_URL=http://127.0.0.1:8201/v1
OPENCLAW_STT_MODEL=whisper-1
OPENCLAW_TTS_BASE_URL=http://127.0.0.1:8201/v1
OPENCLAW_TTS_MODEL=tts-1
OPENCLAW_TTS_VOICE=vivian
```

### 3.5 [Cherry Studio](https://github.com/Kang-k/Cherry-Studio) 与 [Dify](https://github.com/langgenius/dify)
- **Cherry Studio**：在「设置 -> 语音」中选择 OpenAI 兼容服务，填入 Base URL `http://127.0.0.1:8201/v1`，即可一键启用本地离线语音听写与朗读。
- **Dify / FastGPT**：在应用工作流中添加「语音转文本」或「文本转语音」节点，API Endpoint 填写 `http://127.0.0.1:8201/v1`，API Key 填入 `local`。

---

## 4. cURL 命令行快速测试

```bash
# 1. 验证 ASR 文件转写
curl -X POST http://127.0.0.1:8201/v1/audio/transcriptions \
  -F "file=@sample.wav" \
  -F "model=whisper-1" \
  -F "response_format=verbose_json"

# 2. 验证 TTS 语音合成
curl -X POST http://127.0.0.1:8201/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tts-1",
    "input": "SpeechRail 语音合成测试。",
    "voice": "vivian",
    "response_format": "mp3"
  }' \
  --output test.mp3
```

## 5. 文件、播报与实时字幕的自检和恢复

发起推理前先读取 `GET /health`：文件转写检查 `asr_ready`，文本播报检查 `tts_ready`，实时字幕同时检查 `asr_ready`、`streaming_state` 与 `realtime_vad`。`/readyz=200` 只代表 ASR 或 TTS 至少一个可用。

文件转写和文本播报可使用上节的 OpenAI SDK 或 cURL 示例。实时字幕使用 `ws://127.0.0.1:8201/v1/realtime`，先发送 `session.update`，然后以 16 kHz、单声道、PCM16 little-endian 的 Base64 音频发送 `input_audio_buffer.append`，以 `input_audio_buffer.commit` 结束一段输入。以同一 `item_id` 的 `conversation.item.input_audio_transcription.completed` 作为最终字幕；`delta` 只含可追加的稳定前缀。

遇到 `backend_busy`、`queue_full` 或 `backend_timeout` 时，不重放未确认的实时音频。按 `retryable`/`retry_after` 退避，实时连接关闭后建立新会话；文件任务可改用 Jobs 并轮询。服务侧恢复顺序是 `uv run speechrail service status`、`uv run speechrail service preflight`、再读取 `/health`。完整能力与质量证据见[能力诊断与质量验收](../operations/capability-quality-acceptance.md)。
