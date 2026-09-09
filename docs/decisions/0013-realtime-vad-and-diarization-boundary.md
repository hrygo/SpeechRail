---
title: "ADR-0013：Realtime endpointing 与 continuous diarization activity 分离"
status: accepted
date: 2026-09-09
---

# ADR-0013：Realtime endpointing 与 continuous diarization activity 分离

## 决策

SpeechRail 将 Realtime 音频处理拆成两个独立但共享样本时钟的职责：

1. `server_vad` endpointing 由一个 VAD scorer 和 `SpeechAdmission` 状态机负责。当前 quality managed runtime `auto` 解析为 Silero；`SpeechAdmission` 是起止、迟滞、prefix 和 hangover 的状态机，不是第二个独立 VAD。
2. continuous diarization activity 由 CoreML Sortformer session 负责。它接收连续 PCM，生成 speaker evidence 与 revision，不能决定 ASR item 何时 commit，也不能修改 canonical completed text。
3. generic `server_vad` contract 保留 `threshold=0.5`、`prefix_padding_ms=300`、`silence_duration_ms=400` 默认值；调用方可以显式传递业务策略。Sona subtitle 使用 `0.65/300ms/400ms`，meeting 使用 `0.65/300ms/900ms`。
4. `manual` turn detection 不启动 server VAD；语音助手等由客户端负责回合的调用方可以使用 manual + 显式 commit。

## 背景

endpointing 解决“何时结束一段转写”，diarization 解决“这一段由谁说”。将二者混成一个窗口会让会议长停顿、快速换人和 speaker revision 互相影响；把 client VAD 和 server VAD 同时开启则会造成双重 commit、空 item、尾部丢字和时序难以恢复。

## 后果

- VAD 参数的变更只影响 item 边界，不应被解释为 speaker accuracy 变更；分人质量要单独以 DER/JER、unknown ratio、revision latency 和真实语料验收。
- 16kHz/512-sample 帧为 32ms，因此 `400ms/900ms` 停止窗口实际量化到约 `416ms/928ms`。
- `/health.realtime_vad` 独立报告 VAD 子能力；顶层 `/readyz=200` 不能证明 server VAD 可用。
- 使用源码、测试和当前 runtime health 作为事实源；历史 VAD 方案中的统一默认值或旧模型实现不再覆盖本 ADR。
