---
title: "SpeechRail 总体架构"
status: active
version: "0.1.0"
date: 2026-08-31
---

# SpeechRail 总体架构

## 当前实现

```text
QwenPaw / OpenAI SDK ── multipart ──> FastAPI app
                                         │
                                  request ID / auth / queue
                                         │
                                  fixed ffmpeg decode
                                         │
                                  Qwen3Worker subprocess
                                         │
                              external Qwen3-ASR-1.7B snapshot
```

主进程负责 HTTP/WS 边界、输入验证、格式化和有界 admission queue。Qwen3 worker 是一个
长生命周期专用 Python 子进程，经私有长度前缀 JSON 协议顺序处理 PCM 请求。它在启动时
预检 snapshot、离线设置与设备/dtype；Apple Silicon profile 固定 MPS/`float16`。

核心目录：

| 目录 | 当前责任 |
|---|---|
| `app.py` | API 路由、上传解码、错误和 WebSocket 边界 |
| `backends/` | Qwen3 worker、snapshot 验证与离线 runtime |
| `domain/` | 转写结果模型 |
| `runtime/` | queue 与 worker protocol |
| `realtime/` | WebSocket 状态机 |
| `compatibility/` | WLK config / EOF 等窄兼容呈现 |
| `config/` | 环境变量 Settings |

## 接口数据流

REST：`multipart audio/*` → 内存有界读取 → `ffmpeg` PCM → queue → worker → formatter。
处理过程不落盘上传音频。

Realtime：`update` → 0..N `append` → `commit` → queue → worker → 一次 `completed`。
当前没有 delta，不适合作为低延迟字幕后端。

Legacy：连接 → `config` → 空二进制帧 → `ready_to_stop`。当前不转写，也不认证。

## 未来目标（非当前行为）

真实 WLK adapter、持续 partial、legacy snapshot、Realtime adapter、持久化 metrics 和
LAN 安全层属于后续工作。它们不能从架构图或早期设计推断为已启用；具体门禁见
[当前边界](09-open-questions.md) 与 [迁移 Runbook](08-migration-runbook.md)。

`voice-realtime` 继续拥有 AudioHub、会议、TTS、数据库、UI 与 LM Studio；SpeechRail
只提供 ASR API/runtime，不接管这些应用职责。
