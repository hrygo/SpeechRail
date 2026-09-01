---
title: "吸收 voice-realtime 的方案"
status: superseded
date: 2026-08-31
---

# 吸收 `voice-realtime` 的方案

> 状态说明：本文保留 2026-08-31 的原始吸收设计，已被 [ADR-0007](../../decisions/0007-public-speaker-diarization.md)
> 与[迁移 Runbook](../../operations/migration-runbook.md)取代；其中“Sortformer 留在 `voice-realtime`”的结论不再有效。
> Qwen3 native worker 已独立实现；WLK streaming adapter、legacy snapshot parity 和
> `voice-realtime` 侧的改动均尚未实施。当前 `/asr` 仅支持 config/EOF 骨架，不能据此切换
> 旧服务。实际执行顺序见 [迁移 Runbook](../../operations/migration-runbook.md)。

## 1. 核心结论

SpeechRail 吸收的是“ASR 基础设施能力”，不是把 `voice-realtime` 整个仓库复制成
第二个综合应用。两者关系最终应是：

```text
voice-realtime = 音频采集 / 会议 / UI / TTS / 应用编排
SpeechRail      = ASR runtime / queue / public API / compatibility
```

现有 `voice-realtime` 在 2026-08-31 核对为 `1.4.0`，当前开发分支为
`feature/physical-output-audio`。它的字幕服务默认使用 WLK `8001`，并已经拥有
ASR 领域契约和 Qwen3 隔离 worker；这些是迁移输入，不能继续以 `voice_realtime.*`
作为 SpeechRail 的内部依赖。

## 2. 吸收矩阵

| 来源 | SpeechRail 处理 | 目标位置 | 原因 |
|---|---|---|---|
| `src/voice_realtime/asr/contracts.py` | 端口 | `src/speechrail/domain/contracts.py` | 去掉对会议 `TranscriptWindow` 的依赖 |
| `src/voice_realtime/asr/profiles.py` | 端口并重命名 | `src/speechrail/config/profiles.py` | 只保留 ASR runtime 字段 |
| `src/voice_realtime/asr/registry.py` | 端口 | `src/speechrail/runtime/registry.py` | 独立能力门禁 |
| `src/voice_realtime/asr/adapters/qwen3_native.py` | 端口并去应用耦合 | `src/speechrail/backends/qwen3_native.py` | batch 推理和 worker lifecycle |
| `src/voice_realtime/asr/workers/qwen3_native_worker.py` | 端口并改 worker module | `src/speechrail/backends/qwen3_worker.py` | 独立 Python/依赖/模型隔离 |
| `src/voice_realtime/asr/adapters/wlk.py` | 端口 | `src/speechrail/backends/wlk_streaming.py` | 将 WLK full snapshot 规范化 |
| `src/voice_realtime/subtitles/events.py` | 仅提取 wire parser | `src/speechrail/compatibility/wlk.py` | legacy serializer/parser 边界 |
| `src/voice_realtime/asr/presenters.py` | 端口兼容函数 | `src/speechrail/compatibility/presenters.py` | 重建旧字幕 payload |
| `scripts/build-asr-public-proxy-v2.py` | 评估逻辑端口 | `benchmarks/` | 保存 manifest/可复现回放思路 |
| `docs/benchmarks/asr/` | 选择性复制报告索引 | `docs/evidence/` | 不复制音频、模型或大体积产物 |
| `voice_realtime.meeting.*` | 不吸收 | 留在 `voice-realtime` | 会议事实源与业务生命周期 |
| `voice_realtime.ui.*` | 不吸收 | 留在 `voice-realtime` | UI、AudioHub 和模式协调 |
| `voice_realtime.tts_bridge.*` | 不吸收 | 留在 `voice-realtime` | TTS 与 ASR 是不同产品边界 |
| `voice_realtime.interaction.*` | 不吸收 | 留在 `voice-realtime` | Agent/LLM/prompt 不是 ASR 服务职责 |
| PostgreSQL / Sortformer | 不吸收 | 留在 `voice-realtime` | 数据持久化和说话人分离由会议应用拥有 |

## 3. 必须解除的耦合

### 3.1 领域对象

当前 ASR 契约导入 `voice_realtime.meeting.models.TranscriptWindow`。迁移时改为
SpeechRail 自己的 `TranscriptSegment`/`TranscriptWindow`，字段只保留：

```text
session_id, source_epoch, segment_id,
start_ms, end_ms, text, language, speaker(optional), partial
```

会议数据库字段、speaker mapping、SRT 归档和 UI reducer 不得回流到公共服务。

### 3.2 Worker module

当前 Qwen3 worker 命令通过 `voice_realtime.asr.workers.qwen3_native_worker` 启动。
SpeechRail 必须改为自己的 module，并保留以下安全行为：

- 绝对模型目录和绝对 Python executable。
- 模型快照必须在仓库外，文件清单完整后才能启动。
- worker 环境设置 `HF_HUB_OFFLINE=1`、`TRANSFORMERS_OFFLINE=1`、
  `PYTORCH_ENABLE_MPS_FALLBACK=0`。
- 启动握手返回 `device`、`dtype`、`model_loaded`；MPS 请求不接受静默 CPU 回退。
- worker stderr 只保留脱敏尾部；客户端只收到稳定错误码。
- 一个长生命周期 worker 顺序处理请求，避免每个音频重复加载模型。

### 3.3 WLK 协议

当前 `SubtitleStream` 构造 `/asr?language=...&mode=full`，并把空 PCM 当作 EOF。
SpeechRail 需要在自身的 WLK compatibility 层重现这些可观察行为，但内部输出
必须先进入通用 `TranscriptWindow`，再序列化成 `lines`/`buffer_transcription`。

## 4. voice-realtime 的最终改造点

SpeechRail 完成 parity 后，`voice-realtime` 只需做三类小改动：

1. `SubtitleProxy` 支持外部 SpeechRail URL；默认仍可以指向 `/asr`，逐步切到
   `/v1/realtime` adapter。
2. `scripts/run-all.sh` 增加 `VR_SUBTITLE_MANAGED=false`/等价配置，使其不再启动
   自己的 WLK 子进程；SpeechRail 由独立 supervisor 启动。
3. 删除或冻结重复的 Qwen3 worker/公开代理启动代码，保留 benchmark 和兼容测试
   直到迁移验收结束。

不能通过让 SpeechRail import `voice_realtime` 来“复用”实现；那会把综合应用的
依赖、版本和发布周期重新引入公共服务。

## 5. 保留的 voice-realtime 责任

| 责任 | 仍由谁拥有 | SpeechRail 提供什么 |
|---|---|---|
| 麦克风单源采集 | `AudioHub` | 接收 PCM，不打开麦克风 |
| 会议 capture lease | `SubtitleProxy`/`MeetingSession` | 稳定 session/segment 事件 |
| EOF 与会议封存 | 会议应用 | `completed`/`ready_to_stop` 能力 |
| Sortformer | `voice-realtime` | 可选 speaker 字段，不做会议映射 |
| SRT / PostgreSQL | `voice-realtime` | `verbose_json` 或 realtime segments |
| 回声抑制 | interaction pipeline | 纯 ASR 服务不吞掉音频帧 |
| TTS 与 LLM | voice-realtime / LM Studio | SpeechRail 不接管 |

## 6. 迁移后验收

迁移不能只检查 HTTP 200，必须逐项比对：

- 相同 PCM chunk 序列下，legacy `lines` 的顺序、时间戳、speaker 和文本等价。
- 空 PCM EOF 后收到 `ready_to_stop`，且尾句不丢失。
- WLK 断线重连时，`source_epoch` 递增，消费方可去重，不产生重复会议段。
- `voice-realtime` 的字幕、会议 confirmed 文本、SRT 和数据库写入行为不回退。
- 旧服务可通过端口切换恢复，且 SpeechRail 不写入旧项目的 runtime 目录。
