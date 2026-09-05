---
title: "SpeechRail 客户端与 SDK 接入指南"
status: active
audience: "应用开发者、客户端工程师、API 消费者"
version: "1.6.9"
date: 2026-09-05
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

## 3. 常见应用接入配置

### 3.1 QwenPaw 桌面智能体
在 QwenPaw 的语音设置页面配置：
- **Provider Type**：`Whisper API` / `whisper_api`
- **Base URL**：`http://127.0.0.1:8201/v1`
- **Model**：`speechrail/qwen3-asr-1.7b` 或 `whisper-1`
- **API Key**：留空或任意占位字符

> [!IMPORTANT]
> 修改配置后需**完全重启 QwenPaw** 以使新 Base URL 生效；无需修改聊天模型的 Endpoint。

### 3.2 Sona (Voice-Realtime 会议助理)
Sona 通过 `/v1/realtime` 端点连接 SpeechRail：
- **WebSocket URL**：`ws://127.0.0.1:8201/v1/realtime`
- **能力特性**：流式全双工 ASR、Server VAD 自动断句、Sortformer 匿名说话人分离、流式逐句 TTS。

### 3.3 Hermes Agent
在 Hermes 的独立 STT 配置文件中配置：
```dotenv
STT_OPENAI_BASE_URL=http://127.0.0.1:8201/v1
STT_OPENAI_MODEL=speechrail/qwen3-asr-1.7b
```

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
