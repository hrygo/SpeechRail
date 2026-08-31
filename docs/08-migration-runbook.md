---
title: "SpeechRail 迁移 Runbook"
status: active
date: 2026-08-31
---

# SpeechRail 迁移 Runbook

本页将已验证的迁移与已实现但未获运行授权的 adapter 分开记录。任何阶段失败都应先回退
客户端配置，不修改会议、UI 或模型文件。

## QwenPaw：需按当前配置单独核验

当前客户端配置和模型运行状态必须以现场实测为准。本仓库只提供 REST 接入形状：将
`whisper_api` provider 指向 `http://127.0.0.1:8201/v1`，模型使用
`speechrail/qwen3-asr-1.7b`，完整重启后以非敏感短音频验证。此步骤需要独立授权；失败时
恢复原 URL/model 并完整重启。它不退役旧 `8001`，也不代表 Hermes 或 `voice-realtime` 已切换。

## 待执行：Hermes

先冻结 Hermes 当前 STT 配置和聊天 endpoint。只在 STT 专用环境/配置中设置：

```dotenv
STT_OPENAI_BASE_URL=http://127.0.0.1:8201/v1
STT_OPENAI_MODEL=speechrail/qwen3-asr-1.7b
```

重启 Hermes 后，验证一条语音消息以及聊天模型正常性。若任一失败，删除/恢复这两个 STT
键并重启，不修改全局 `OPENAI_BASE_URL`。本阶段完成前不得宣称 Hermes 集成已验证。

## `voice-realtime`：adapter 已实现，运行切换待授权

当前 `/asr` 不做转写，故不可切换旧 WLK `8001`。主路线已经由 ADR-0006 固定为
`/v2/realtime` 直迁移，不再以完整 WLK parity 为前置条件。

独立 `voice-realtime` 分支已实现：

1. 共享 `SpeechRailRealtimeClient`，只负责 Bearer、握手、事件解析、背压和关闭；
2. 增加 `SpeechRailStreamingTranscriber`，把逐句 completed 累积为会议/字幕 snapshot，把
   session completed 映射为 EOF final；
3. 增加 `SpeechRailConversationSTTFactory`，为语音助手创建现有 Pipecat 管道需要的 processor；
4. 断线时不续传旧 session：建立新 source epoch，按应用现有语义记录 gap；
5. 两个 adapter 均有独立 opt-in 开关，默认仍保留会议 WLK 和语音助手现有 STT。

首次启用配置（不得与影子/正式切换混为一谈）：

```dotenv
VR_SUBTITLE_BACKEND=speechrail-realtime-v2
VR_SUBTITLE_SPEECHRAIL_URL=ws://127.0.0.1:8201/v2/realtime

VR_INTERACTION_STT_BACKEND=speechrail-realtime-v2
VR_INTERACTION_SPEECHRAIL_REALTIME_URL=ws://127.0.0.1:8201/v2/realtime
```

SpeechRail 若使用 WLK 作为自己的连续 ASR backend，单独配置其外部 loopback endpoint：

```dotenv
SPEECHRAIL_WLK_STREAMING_URL=ws://127.0.0.1:8001
```

它不会启动、安装或下载该 sidecar；未设置时 v2 ASR 保留 Qwen batch flush/commit 路径。

会议端至少验收字幕、会议开始/结束、SRT、数据库 confirmed 文本、EOF、断线 gap、资源释放和
旧 WLK 回退。语音助手端至少验收 VAD/turn-taking、文本进入 LLM、原 TTS bridge、barge-in、
断线和原 STT 回退。SpeechRail 不会修改或接管 AudioHub、TTS、会议、PostgreSQL 或 UI。

影子比对只能在应用内受控复制 PCM；SpeechRail 结果不得写入正式 SRT/数据库或重复触发 LLM。

## 通用回滚

```text
停止/撤销目标客户端配置
  → 确认旧服务和原 URL 仍可用
  → 重启目标客户端
  → 用该客户端最小语音流程验证
```

保留版本、时间、错误码和 request ID；不保留音频、Base64 或完整转写。不要对任一仓库
执行破坏性 reset 来回滚运行配置。
