# ADR-0001：把共享 ASR 做成独立 SpeechRail 服务

## Status

Accepted

## Date

2026-08-31

## Context

QwenPaw、`voice-realtime` 和 Hermes Agent 都需要语音转文字，但它们的应用生命周期、
UI、会议数据和 Agent 配置不同。把 ASR 继续放在 `voice-realtime` 的综合进程里，会让
其他应用依赖其端口、分支、Python 环境和 WLK 内部协议。

## Decision

创建独立产品/项目/服务 `SpeechRail`，统一拥有 ASR runtime、公共 API、认证、队列、
健康检查和兼容层。应用只作为客户端接入。

## Alternatives considered

### 继续使用 voice-realtime:8001

改动最小，但 QwenPaw/Hermes 会绑定会议应用的发布和故障域，无法独立升级。

### 每个应用内嵌 Qwen3-ASR

短期简单，长期会重复加载模型、重复处理音频格式和错误，且无法统一资源准入。

### 通过 LM Studio 提供 ASR

LM Studio 适合作为本机 LLM/Embedding 服务；当前本机稳定使用面并不是 Qwen3-ASR
公共转写契约，不能把 ASR 依赖到聊天 API 语义上。

## Consequences

- 需要维护一个独立服务和版本生命周期。
- 多个客户端共享认证、限流、观测和模型管理。
- `voice-realtime` 需要在迁移完成后停止自带 WLK server。
- 旧 `/asr` 兼容层会增加一段过渡维护成本，但可以降低切换风险。
