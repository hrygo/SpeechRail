---
title: "SpeechRail 总体架构"
status: active
version: "1.4.0"
date: 2026-09-02
---

# SpeechRail 总体架构

## 当前实现

```text
QwenPaw / OpenAI SDK ── multipart ──> FastAPI app <── JSON/WS ── sona
                                          │
                                   request ID / auth / queue
                              ┌───────────┴───────────┐
                              │                       │
                       WAV Fast-path / ffmpeg   speech session
                              │                       │
                       Qwen3 ASR worker        Qwen3 TTS worker
                              │                       │
                    external ASR snapshot   external VoiceDesign snapshot
```

主进程负责 HTTP/WS 边界、输入验证、WAV Fast-path 直读、格式化和有界 admission queue。Qwen3 worker
是一个长生命周期专用 Python 子进程，经私有二进制零拷贝混合帧协议顺序处理 PCM 请求。它在启动时
预检 snapshot、离线设置与设备/dtype；Apple Silicon profile 支持 MPS/`float16` 与 `int8` 动态量化。

核心目录：

| 目录 | 当前责任 |
|---|---|
| `app.py` | 组合根、API 路由注册、错误和生命周期 |
| `application/` | Realtime OpenAI 用例、diarization 协调和跨传输交付 |
| `backends/` | Qwen3 worker、Sortformer/CAM++、snapshot 验证与离线 runtime |
| `domain/` | vendor-neutral 转写、TTS 与 diarization 模型 |
| `runtime/` | queue、governor 与 worker protocol |
| `http/routes/` | REST 与唯一 `/v1/realtime` transport 边界 |
| `compatibility/` | OpenAI alias、事件和格式化兼容呈现 |
| `config/` | 环境变量 Settings |

## 接口数据流

REST：`multipart audio/*` → 内存有界读取 → `ffmpeg` PCM → queue → worker → formatter。
处理过程不落盘上传音频。

Realtime transcription：`session.update` → 0..N PCM `append` → `commit` → ASR worker →
transcription events。Realtime speech：`session.update` → text `append` → `commit` → TTS worker →
ordered audio delta；两类会话共享 auth、event envelope、backpressure 和 cancel 边界。

可选 diarization 在 transcription session 内使用匿名、session-scoped acoustic state；
profile 未 ready 时在 `session.update` 阶段 fail closed，不伪造 speaker label。

## 范围外能力

持久化 metrics 导出、解码后音频时长限制和完整 LAN CORS/Origin 防护不在当前能力范围；
它们不能从架构图或早期设计推断为已启用。启用前须先实现、测试并更新契约与边界文档，
门禁见[当前边界](current-boundaries.md) 与 [迁移 Runbook](../operations/migration-runbook.md)。

`sona` 继续拥有 AudioHub、会议、播放、数据库、UI 与 LM Studio；SpeechRail
拥有 ASR/TTS API/runtime，但不接管这些应用职责。
