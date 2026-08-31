---
title: "SpeechRail 产品范围"
status: active
version: "0.1.0"
date: 2026-08-31
---

# SpeechRail 产品范围

SpeechRail 是一项本地优先的共享语音识别服务：一次加载、管理 Qwen3-ASR runtime，向
多个应用提供稳定的转写接口。英文技术标识为 `speechrail`，中文名为“声轨”。

## 服务拥有的责任

- Qwen3-ASR snapshot 预检、隔离 worker、设备/dtype 身份和有界推理准入；
- OpenAI-compatible 文件转写、健康、模型清单及统一错误 envelope；
- 当前有限的 Realtime 和 legacy 兼容协议；
- 认证配置、request ID、无正文的运行诊断边界。

## 不属于服务的责任

- 麦克风、扬声器、TTS、回声消除；
- 会议状态、UI、SRT、PostgreSQL、Sortformer、AudioHub；
- QwenPaw/Hermes 的 prompt、会话、权限和聊天模型；
- LM Studio 的 chat/embedding 运行时。

这些职责仍由各消费应用拥有。SpeechRail 不能 import 或托管 `voice-realtime` 的会议/UI
模块来实现所谓“集成”。

## 目标用户与当前适配度

| 用户 | 需求 | 当前状态 |
|---|---|---|
| QwenPaw | 上传录音并获得文本 | 已使用 `whisper_api` 完成本机 smoke |
| OpenAI-compatible 客户端 | multipart 文件转写 | 已实现 REST 契约 |
| Hermes Agent | 使用独立 STT endpoint | 文档化，尚未真实验收 |
| `voice-realtime` | partial 字幕/会议 EOF | 尚未迁移；不能使用当前 `/asr` 替换 WLK |
| 新 WebSocket 客户端 | 发送 PCM 后获得最终文本 | 可用，但没有 partial streaming |

## 不变的产品约束

- 模型 snapshot 在仓库外；服务和请求不下载模型、不读取远程音频 URL。
- 默认只监听 loopback；非 loopback 需要 key，额外网络防护须在实现后再启用。
- 音频/转写默认瞬态，不能提交或记录其原始内容。
- 公共模型 ID 为 `speechrail/qwen3-asr-1.7b`；兼容 aliases 不改变真实后端身份。
- 0.x 优先采用兼容扩展；破坏性变更使用 `/v2` 和迁移说明。
