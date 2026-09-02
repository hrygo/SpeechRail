---
title: "SpeechRail 迁移 Runbook"
status: active
date: 2026-08-31
---

# SpeechRail 迁移 Runbook

本页记录当前机器已验证的迁移状态与人工恢复步骤。运行配置变更不修改会议、UI、TTS 或模型文件。

## QwenPaw：已切换并核验

QwenPaw 保持 `whisper_api` 接入形状，已指向 `http://127.0.0.1:8201/v1`，模型为
`speechrail/qwen3-asr-1.7b`。已完整重启 QwenPaw 并通过 `/api/workspace/transcribe` 使用真实
本地模型完成非空转写验收。provider 的历史显示名不构成后端路由或回退路径。

## 待执行：Hermes

先冻结 Hermes 当前 STT 配置和聊天 endpoint。只在 STT 专用环境/配置中设置：

```dotenv
STT_OPENAI_BASE_URL=http://127.0.0.1:8201/v1
STT_OPENAI_MODEL=speechrail/qwen3-asr-1.7b
```

重启 Hermes 后，验证一条语音消息以及聊天模型正常性。若任一失败，删除/恢复这两个 STT
键并重启，不修改全局 `OPENAI_BASE_URL`。本阶段完成前不得宣称 Hermes 集成已验证。

## 本机唯一 ASR 切换记录（2026-08-31）

本机 SpeechRail 已以仓库外 ModelScope `Qwen/Qwen3-ASR-1.7B` snapshot、MPS/float16 和
专用离线 Python worker 在 `127.0.0.1:8201` 启动；legacy `/asr` 已禁用，未配置 WLK sidecar。
QwenPaw 保持 `whisper_api`，其唯一转写 endpoint 为 `http://127.0.0.1:8201/v1`，模型为
`speechrail/qwen3-asr-1.7b`。sona 的字幕/会议与交互均显式配置
`speechrail-openai-realtime` 和 `ws://127.0.0.1:8201/v1/realtime`。legacy `/asr` 与
`/v1/realtime/legacy` 端点在 v1.0.0 已移除。

已完成 REST、QwenPaw workspace 转写、Realtime session commit 和 Pipecat VAD turn 的本机真实
模型冒烟。验收只记录成功状态、request ID、时延和非空断言；不保存音频或转写正文。

## `sona`：已切换并核验

主路线已由 ADR-0009 固定为 `/v1/realtime` OpenAI Realtime 兼容协议。当前 SpeechRail legacy `/asr` 已禁用，
没有为 SpeechRail 配置 WLK sidecar，也没有活动的 ASR fallback。legacy `/asr` 与
`/v1/realtime/legacy` 端点在 v1.0.0 已移除。

`sona` 使用以下已实现的边界：

1. 共享 `SpeechRailRealtimeClient`，只负责 Bearer、握手、事件解析、背压和关闭；
2. 增加 `SpeechRailStreamingTranscriber`，把逐句 completed 累积为会议/字幕 snapshot，把
   session completed 映射为 EOF final；
3. 增加 `SpeechRailConversationSTTFactory`，为语音助手创建现有 Pipecat 管道需要的 processor；
4. 断线时不续传旧 session：建立新 source epoch，按应用现有语义记录 gap；
5. Pipecat turn processor 忽略 Realtime 的 `input_audio_buffer.ack` 控制事件，只将转写事件映射为文本帧。

当前启用配置（旧 backend 开关已删除，以下为实际生效键）：

```dotenv
VR_SUBTITLE_SPEECHRAIL_URL=ws://127.0.0.1:8201/v1/realtime

VR_INTERACTION_SPEECHRAIL_REALTIME_URL=ws://127.0.0.1:8201/v1/realtime
VR_INTERACTION_SPEECHRAIL_TTS_REST_URL=http://127.0.0.1:8201/v1
VR_INTERACTION_SPEECHRAIL_TTS_MODEL=speechrail/qwen3-tts
VR_INTERACTION_TTS_VOICE=default
VR_INTERACTION_TTS_LANGUAGE=auto
```

已使用真实本地 PCM 验证 Realtime `session.update → append → commit → transcription.completed`，
并通过 Pipecat VAD turn 验证最终文本进入现有语音助手管道。TTS 已迁为 SpeechRail Realtime/REST：
`sona` 保留 Pipecat、播放、回声、persona、会议、PostgreSQL 与 UI，仅消费
SpeechRail 返回的 PCM 和公开 preset。SpeechRail 不接管 AudioHub、LLM、会议、PostgreSQL 或 UI。

多人会议另需在 SpeechRail 启用本地 Sortformer profile。`sona` 的 meeting adapter
会请求 `diarization.enabled`、传入应用派生的不透明 group ID，并消费 completed segment 的
匿名 `speaker`/`speakers` 与 commit 前的 remap；缺少 profile 时以
`SPEECHRAIL_DIARIZATION_UNAVAILABLE` fail closed，不会降级为单 speaker 会议。CAM++ 只用于
短 TTL 内的匿名重连归并，姓名、人工改名和 PostgreSQL 事务仍归 meeting application。

此状态是**运行时唯一切换**；旧 `vr-bridge` 的 console entry、TTS 专属依赖、模型缓存模块和
旧 TTS 源码已退役。ASR 的历史兼容配置仍按各自 deprecation 计划处理。

## 通用回滚

```text
停止 SpeechRail 或目标客户端
  → 从本次迁移的私有时间戳备份恢复相应配置
  → 重启目标客户端
  → 用该客户端最小语音流程验证
```

恢复备份是人工回退操作，不是运行时自动 fallback。保留版本、时间、错误码和 request ID；
不保留音频、Base64 或完整转写。不要对任一仓库执行破坏性 reset 来回滚运行配置。
