---
title: "SpeechRail 产品范围"
status: active
version: "0.1.0"
date: 2026-08-31
---

# SpeechRail 产品范围

## 一句话定位

SpeechRail 是一个面向本机和可信局域网的共享语音识别基础服务：一次加载和管理
Qwen3-ASR 能力，向多个应用提供稳定、可替换运行时的标准 API。

中文产品名为“声轨”，英文技术标识统一使用 `speechrail`。

## 目标用户

1. QwenPaw：录音结束后上传文件，得到一段文本。
2. `voice-realtime`：实时字幕和会议录音，需要 partial、confirmed、时间轴、EOF
   冲刷和重连兼容。
3. Hermes Agent：通过 OpenAI-compatible STT 配置转写语音消息和桌面语音输入。
4. 后续应用：只依赖公共 API，不需要了解 Qwen3-ASR、WhisperLiveKit、MPS 或
   本机模型路径。

## 产品能力边界

### SpeechRail 拥有

- ASR 模型 profile、加载和生命周期。
- 批量/文件转写。
- 实时转写连接、会话、背压和 EOF 语义。
- OpenAI-compatible REST API。
- OpenAI Realtime 风格转写 WebSocket。
- `voice-realtime` 旧 WLK `/asr` WebSocket 兼容层。
- 认证、限流、请求 ID、健康检查、运行状态和指标。
- 运行时/模型指纹和不含正文的审计信息。

### SpeechRail 不拥有

- 麦克风采集和扬声器播放。
- TTS、回声消除和打断策略。
- 会议状态机、会议 UI 和 PostgreSQL 会议事实源。
- Sortformer/CAM++ 说话人分离的业务决策。
- QwenPaw、Hermes 或其他 Agent 的 prompt、会话和权限。
- LM Studio 的聊天模型、推理链和 thinking 策略。

## 核心成功标准

| 维度 | 标准 |
|---|---|
| 接入 | OpenAI SDK 可直接调用；QwenPaw/Hermes 无需自定义 SDK |
| 实时 | 能发送 16 kHz mono s16le PCM，收到 partial 和 final 事件 |
| 兼容 | 旧 `voice-realtime` 的 `/asr`、空 PCM EOF、full snapshot 行为保持可用 |
| 隔离 | 模型路径、模型依赖和运行时不进入消费方代码 |
| 安全 | 默认只监听 loopback；LAN 模式必须有 Bearer key |
| 隐私 | 默认不持久化音频，不在日志记录 API key 或完整转写正文 |
| 可回退 | 任一迁移阶段都能通过端口/URL 切回旧 WLK |
| 可追溯 | 每次模型调用可以关联 request ID、backend、device、dtype、版本和耗时 |

## 术语

| 术语 | 定义 |
|---|---|
| batch transcription | 上传完整音频文件后返回完整文本；对应 REST |
| realtime transcription | 发送连续音频块并接收 partial/final；对应现代 WS |
| legacy WLK | 当前 `voice-realtime` 使用的 `/asr` full snapshot 协议 |
| backend profile | 模型 + 运行时 + 设备 + 参数的不可变配置 |
| adapter | 将 vendor/运行时协议转换为 SpeechRail 领域事件的窄边界 |
| compatibility alias | 为旧客户端保留的模型名或路径；必须记录弃用策略 |

## 明确的产品取舍

- 名称不包含 Qwen、Whisper、Hermes 或 `voice-realtime`，避免模型/客户端绑定。
- 公共接口只表达“转写”，不暴露 `TranscriptionEngine`、worker pipe、WLK `FrontData`
  等实现细节。
- 第一阶段只做语音转文字；TTS、翻译、摘要、说话人分离作为消费者或后续独立能力。
- 默认一台机器一个 SpeechRail 服务实例；服务内部对推理进行有界排队，不用多个
  Uvicorn worker 复制模型。
- 默认模型为 `speechrail/qwen3-asr-1.7b`；模型别名用于兼容，不改变实际模型身份。
