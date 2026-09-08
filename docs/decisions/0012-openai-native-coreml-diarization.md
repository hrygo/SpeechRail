---
title: "ADR-0012：OpenAI 原生分人接口与唯一 CoreML 运行时"
status: accepted
date: 2026-09-08
---

# ADR-0012：OpenAI 原生分人接口与唯一 CoreML 运行时

## 决策

文件分人采用 `POST /v1/audio/transcriptions` 的 OpenAI 原生
`model="gpt-4o-transcribe-diarize"` 与 `response_format="diarized_json"`。Realtime
不伪装为 OpenAI 原生能力，使用 `session.speechrail.diarization.enabled` 一个 opt-in
开关和 `speechrail.diarization.*` 事件。

生产运行时固定为 FluidAudio CoreML FP16
`v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc`，使用私有 Swift worker、直接加载已编译 bundle
和 `computeUnits=.all`。模型 revision 为 `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`，
FluidAudio source commit 为 `5c19d5e12320e22bbfb7a1877b089d2665a69add`。release 还必须锁定
bundle hash 与第三方 notices。

不保留 NeMo、CAM++、cross-session speaker store、provider auto、精度切换或运行期 fallback。文件和 Realtime 经同一个 transport-neutral `DiarizationSession` actor 消费 `StreamingActivityPort`，不存在独立的 batch 分人后端或旧 Realtime 分人协商分支。
普通 ASR/TTS 请求不创建分人会话、不调用固定正文对齐、也不启动分人 worker。

## 依据

D1 在同一 M5 Max、同一 90 秒连续输入和同一 streaming preset 下记录 CoreML FP16 为 7.077 秒、
RTFx 12.716、max RSS 564 MB；NeMo CPU 对照为 58.549 秒、RTFx 1.537、1,862 MB。D1 不含
RTTM/UEM，且 A/B 尾部相差 160 ms，因此它只决定运行时，不通过 DER/JER、尾部、ASR 共存、P95
或两小时稳定性门。

## 后果

ADR-0007 和 ADR-0010 中与旧 SPK-E2E-1、NeMo/CAM++ 和旧 Realtime 协商面冲突的分人实现决定由
本 ADR 取代；其历史背景保留。质量发布仍以独立验收输入和真实设备报告为准。
