---
title: "SpeechRail 产品范围"
status: active
version: "1.1.0"
date: 2026-09-02
---

# SpeechRail 产品范围

SpeechRail 是一项本地优先的共享 ASR/TTS 运行时：一次管理外部模型 runtime，向多个应用
提供稳定的转写与语音合成接口。英文技术标识为 `speechrail`，中文名为“声轨”。

## 服务拥有的责任

- Qwen3-ASR snapshot 预检、隔离 worker、设备/dtype 身份和有界推理准入；
- Qwen3-TTS VoiceDesign snapshot 预检、隔离 worker、preset、设备/dtype 身份和有界推理准入；
- OpenAI-compatible 文件转写、健康、模型清单及统一错误 envelope；
- OpenAI-compatible 整句 TTS、preset 目录与 24 kHz PCM/WAV 输出；
- OpenAI Realtime 兼容 `/v1/realtime`，作为唯一实时 ASR/TTS 入口；
- 可选 Sortformer/CAM++ diarization profile 的配置、readiness 和匿名 session 状态；
- 认证配置、request ID、无正文的运行诊断边界。

## 不属于服务的责任

- 麦克风、扬声器、播放队列、回声消除与打断策略；
- 会议状态、UI、SRT、PostgreSQL、AudioHub 和 speaker display-name 映射；
- QwenPaw/Hermes 的 prompt、会话、权限和聊天模型；
- LM Studio 的 chat/embedding 运行时。

这些职责仍由各消费应用拥有。SpeechRail 不能 import 或托管 `voice-realtime` 的会议/UI
模块来实现所谓“集成”。

## 目标用户与当前适配度

| 用户 | 需求 | 当前状态 |
|---|---|---|
| QwenPaw | 上传录音并获得文本 | 已使用 `whisper_api` 完成本机 smoke |
| OpenAI-compatible 客户端 | multipart 文件转写 | 已实现 REST 契约并通过真实 smoke |
| Hermes Agent | 使用独立 STT endpoint | 配置方法已文档化；真实 Hermes smoke 待验收 |
| `voice-realtime` | ASR 字幕/会议 EOF + TTS 播放 | 已接入 `/v1/realtime`；客户端确定性回归已覆盖，真实模型端到端闭环待部署验收 |
| 新 WebSocket 客户端 | 发送 PCM 后获得最终文本 | 可用；流式 partial 取决于所配置后端 |

## 不变的产品约束

- 模型 snapshot 在仓库外；服务和请求不下载模型、不读取远程音频 URL。
- 默认只监听 loopback；非 loopback 需要 key。TLS、CORS、网段限制与速率限制不在当前能力
  范围，启用前须先实现并更新契约。
- 音频/转写默认瞬态，不能提交或记录其原始内容。
- 公共模型 ID 为 `speechrail/qwen3-asr-1.7b` 与 `speechrail/qwen3-tts`；OpenAI 标准名
  （`whisper-1`、`tts-1` 等）作为兼容 aliases 归一化到 canonical，不改变真实后端身份。
- 1.x 优先采用兼容扩展；破坏性变更使用 `/v2` 和迁移说明。
