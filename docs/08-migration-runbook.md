---
title: "SpeechRail 迁移 Runbook"
status: active
date: 2026-08-31
---

# SpeechRail 迁移 Runbook

本页将已完成的 QwenPaw 切换与未开始的 Hermes / `voice-realtime` 迁移分开记录。任何阶段
失败都应先回退客户端配置，不修改会议、UI 或模型文件。

## 已完成：QwenPaw 旁路切换

在 SpeechRail 保持 `127.0.0.1:8201`、旧 WLK 保持原端口的前提下，已完成：

1. 配置 QwenPaw `whisper_api` provider 的 base URL 为 `http://127.0.0.1:8201/v1`；
2. 将模型设置为 `speechrail/qwen3-asr-1.7b`；
3. 完整重启 QwenPaw；
4. 通过 QwenPaw 中文短音频 smoke。

这不是旧 `8001` 服务的退役，也不代表 Hermes / `voice-realtime` 已切换。QwenPaw 回退只需
恢复其原 provider URL/model 并完整重启，然后用短音频确认。

## 待执行：Hermes

先冻结 Hermes 当前 STT 配置和聊天 endpoint。只在 STT 专用环境/配置中设置：

```dotenv
STT_OPENAI_BASE_URL=http://127.0.0.1:8201/v1
STT_OPENAI_MODEL=speechrail/qwen3-asr-1.7b
```

重启 Hermes 后，验证一条语音消息以及聊天模型正常性。若任一失败，删除/恢复这两个 STT
键并重启，不修改全局 `OPENAI_BASE_URL`。本阶段完成前不得宣称 Hermes 集成已验证。

## 待执行：`voice-realtime`

当前 `/asr` 不做转写，故不可切换旧 WLK `8001`。迁移只能在独立的
`voice-realtime` 分支实施，并选择以下之一：

- 实现 `SpeechRailRealtimeAdapter`：将 AudioHub 的 PCM 转为 update/append/commit，消费
  一次 completed；它目前不适合要求 partial 字幕的会议体验。
- 先在 SpeechRail 实现真实 legacy `/asr` adapter，使用旧 consumer fixtures 验收
  `lines`、`buffer_transcription`、EOF、错误和认证，再安排端口切换。

无论路线，至少完成字幕、会议开始/结束、SRT、数据库 confirmed 文本、断线、资源释放和
旧端口回退演练，才可停止旧 WLK。SpeechRail 不会修改该项目的 AudioHub、TTS、会议、
PostgreSQL 或 UI。

## 通用回滚

```text
停止/撤销目标客户端配置
  → 确认旧服务和原 URL 仍可用
  → 重启目标客户端
  → 用该客户端最小语音流程验证
```

保留版本、时间、错误码和 request ID；不保留音频、Base64 或完整转写。不要对任一仓库
执行破坏性 reset 来回滚运行配置。
