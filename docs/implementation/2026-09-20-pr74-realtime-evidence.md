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

## paced Realtime 切片

为补充 E1 的第二种测量模式，在同一 managed `quality` 服务上使用 macOS
系统 `Tingting` 生成一段已知中文短语，再转换为 16 kHz、mono、PCM16。音频
与原始 AIFF 均保存在仓库外的同一 benchmark 目录，未写入仓库；这是真实声学
输入的协议测量，但不是人工录音，也不构成 CER/WER 或自然度证据。

手动 turn 以 20 ms chunk 按媒体时间线发送，先完成 1 个 paced warm-up，再测量
5 个 sequential session。音频长度为 `6.895 s`；以 PCM16 振幅阈值 `400` 定义
的最后 active sample 位于 `6.710 s`，因此以下 `last-speech` 数字是可复核的
activity-threshold proxy，不冒称人工标注的语音边界。

| 指标 | p50 | p95 | min–max | 成功 |
|---|---:|---:|---:|---:|
| commit → transcription completed | `120.73 ms` | `124.57 ms` | `110.49–125.37 ms` | 5/5 |
| activity proxy → transcription completed | `7172.12 ms` | `7177.99 ms` | `7166.22–7178.43 ms` | 5/5 |
| TTS first audio delta | `43.42 ms` | `43.91 ms` | `42.82–44.03 ms` | 5/5 |

每个 session 均有非空 transcript；TTS 完整输出为 `107520` bytes。第一项是
post-commit service tail，第二项包含近 6.7 秒的 paced media timeline，不能互相
替代。该切片补充了 E1 的 paced 输入与 commit-tail 分布，但没有覆盖 cold/switch、
并发公平、热稳定性、人工语音识别质量或当前 PR head 的 managed wheel 一致性。

## 受保护 metrics 快照

在同一服务上通过鉴权 `/metrics` 做了只读核对。当前 managed `2.7.0` 实际
暴露的 Realtime phase histogram 包含 `asr_admission`（累计 58 次）、
`tts_admission`（累计 53 次）和 `send`（累计 3871 次）；这些是服务累计值，
不是上面 3 个 session 的独立样本。标签只包含固定 phase 与 histogram bucket，
没有 request ID、文本或音频内容。

本次快照未出现 `asr_commit_ack`、`asr_terminal_wait` 或 governor queue
wait/release histogram。当前 PR 源码虽包含更完整的 phase 集合，但 managed
release 没有证明已经安装该观测契约；因此不能用这份旧 runtime metrics 快照
宣称当前 PR 的 E3a 已完成。

## 身份与限制

本轮 benchmark 输出的 `model_identity` 仍为空；`quality` profile 的配置声明
不等于实际 worker 的 model/revision identity。对 HTTP TTS 请求显式发送
`SpeechRail-Receipt-Mode: integrity` 时，managed `2.7.0` 响应没有返回
`SpeechRail-Receipt-Id`，因此本轮没有新增 #64 的 managed receipt identity
证据。

尚未覆盖：cold/switch、持续混合负载、维护任务交接、取消清理、memory/thermal
soak、clone 多音色、声学自然度、身份匹配、ABX/人工听感，以及与当前 PR head 的
managed wheel 一致性证明。
