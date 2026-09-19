---
title: "PR #74 managed Realtime and overlap evidence refresh"
status: partial_external_evidence
date: 2026-09-20
---

# PR #74 managed Realtime and overlap evidence refresh

## 结论

这是现有 managed `quality` profile 上的真实 Realtime 延迟与 ASR∥TTS
调度切片。它补充 #44/#65 的阶段与资源证据，但不构成声学质量、人工听感、
真实模型身份或完整热稳定性验收。

测量时间：2026-09-20（Asia/Shanghai）。服务 release `2.7.0`、quality
generation `102`，设备为 Apple M5 Max、`arm64`、Darwin `27.0.0`、128 GiB。
测量前只发现唯一 `com.speechrail` listener，没有外部 `ESTABLISHED`
Realtime 客户端；未停止/切换服务、下载模型、修改 profile 或注册 voice。

原始 JSON 与合成 fixture 保存在仓库外 managed app home 的
`benchmarks/pr74-live-20260920/`，仓库只保存本脱敏摘要。

## Realtime warm 切片

使用官方 `bench_realtime_json.py`，warm-up 后测量 3 个 manual-turn session。
输入是 10 秒、16 kHz、mono、PCM16 的合成静音；因此 `transcript_present` 只
是协议/worker 完成事实，不是识别正确性证据。

| session | ASR commit→completed | ASR RTF | TTS first delta | TTS bytes |
|---:|---:|---:|---:|---:|
| 1 | 244.95 ms | 0.0245x | 35.21 ms | 138240 |
| 2 | 241.92 ms | 0.0242x | 36.25 ms | 138240 |
| 3 | 240.55 ms | 0.0241x | 35.63 ms | 138240 |

3/3 session 成功，资源采样 `sampling_complete=true`；该窗口的同时
`phys_footprint` 峰值为 `6832758176` bytes。结果只适合作为本机当前 warm
worker 的阶段/资源切片，不是 paced speech、CER/WER 或长时稳定性结论。

## ASR∥TTS overlap 切片

使用官方 `bench_overlap.py`，每个场景先 warm-up，`concurrency=1`、延迟
`0.5 s`；ASR fixture 同样是合成静音，TTS 使用固定安全短句。

| 场景 | 顺序 | 请求结果 | governor batch peak | `phys_footprint` peak | 采样 |
|---|---|---|---:|---:|---|
| C1 | TTS → 0.5 s → ASR | 200 / 200 | 2 | `6748118384` bytes | 12 samples / 0 errors |
| C2 | ASR → 0.5 s → TTS | 200 / 200 | 1 | `6862069104` bytes | 14 samples / 0 errors |

C1 证明当前运行态可观察到 TTS 活跃期间的 ASR∥TTS overlap；C2 中 ASR 很快
完成，不能据此推出反向公平性或优先级结论。

## 身份与限制

本轮 benchmark 输出的 `model_identity` 仍为空；`quality` profile 的配置声明
不等于实际 worker 的 model/revision identity。对 HTTP TTS 请求显式发送
`SpeechRail-Receipt-Mode: integrity` 时，managed `2.7.0` 响应没有返回
`SpeechRail-Receipt-Id`，因此本轮没有新增 #64 的 managed receipt identity
证据。

尚未覆盖：真实语音 ASR paced commit-tail、cold/switch、持续混合负载、维护任务
交接、取消清理、memory/thermal soak、clone 多音色、声学自然度、身份匹配、
ABX/人工听感，以及与当前 PR head 的 managed wheel 一致性证明。
