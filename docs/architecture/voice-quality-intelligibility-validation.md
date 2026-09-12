---
title: "克隆音色输出可懂度与 ASR 复核设计"
status: active
audience: "SpeechRail/Sona 维护者、质量工程与架构评审者"
version: "1.1"
date: 2026-09-12
---

# 克隆音色输出可懂度与 ASR 复核设计

## 1. 目的

现有数字信号门禁可以拒绝空输出、近静音、削波和重复运行的不确定输出，但**不能证明生成内容是可懂语音，也不能可靠区分正常语音与幅度正常的随机噪声**。

因此 Quality 音色验收需要增加独立于 TTS 的文本/可懂度证据。首选复用 SpeechRail 已有 ASR，而不是继续堆叠幅度阈值。

本文同时记录当前实现与仍需目标机校准的边界。`quality-runs` 已在信号门通过后，顺序调用现有 Batch ASR 对 6 类固定 probe 的首个有效样本做回转录；真实 Apple Silicon 的时延、内存与阈值仍需校准。

## 2. 关键约束：不得无治理地并行 Base TTS 与 ASR

Quality reference clone 由 Qwen3-TTS Base 承担。Base 与 VoiceDesign 由 capability router 分别持有在两个独立 worker 中；它们可以在各自 lane 并发，但 TTS 与 ASR 仍必须遵守 governor 和阶段边界。

质量复测如果在每个 TTS probe 刚生成完就立即调用 ASR，会产生两个问题：

1. Base worker 仍处于 warm/resident 状态，ASR 可能与其竞争统一内存与 Metal 计算资源；
2. 质量门会绕过现有 Resource Governor / heavy-overlap 决策，形成与正常运行时不同的隐式并行路径。

因此禁止采用：

```text
probe-1 TTS -> ASR
probe-2 TTS -> ASR
...
```

## 3. 推荐阶段化流水线

```text
Phase A: TTS probe generation
  6 fixed probes × repetitions
  -> signal validity
  -> per-probe PCM digest
  -> bounded temporary PCM set

Phase B: release TTS workers before ASR
  -> complete active VoiceDesign/Base streams
  -> release both TTS lanes
  -> close/evict the router group when policy requires
  -> honor Resource Governor

Phase C: ASR validation
  -> resample 24 kHz PCM16 to ASR canonical 16 kHz PCM16
  -> batch transcription
  -> normalized text comparison
  -> per-probe intelligibility score

Phase D: aggregate quality decision
  -> signal validity
  -> determinism evidence
  -> transcript/intelligibility evidence
  -> identity evidence (independent speaker encoder, when available)
  -> final VoiceQualityReport
```

## 4. 文本比较

ASR 输出不得用原始字符串完全相等作为唯一判据。中文 probe 至少需要统一：

- Unicode 规范化；
- 全角/半角标点；
- 空白；
- 常见数字与单位表达；
- SpeechRail 已有 ITN 能力可覆盖的等价表达。

建议报告两个维度：

- `transcript_match`：0..1 的规范化相似度；
- `transcript_failure_code`：稳定低基数错误码，如 `transcript_mismatch` / `transcription_unavailable`。

当前 reference quality 已有 `transcript_match` 与 `transcript_mismatch` 语义，输出复核应复用同一命名体系，避免建立第二套质量语言。

## 5. 资源与生命周期

ASR 复核必须满足：

1. 不在 TTS worker 生命周期锁或未释放的 TTS reservation 内启动 ASR；
2. 不自行创建绕过 `AppServices` 的额外 ASR worker；
3. 使用现有 `batch_transcriber`/`transcribe` 依赖；
4. 接受现有 admission/governor 的拒绝与超时；
5. 临时 PCM 有明确上限，验收完成后释放，不写磁盘；
6. ASR 不可用时报告“未评估”，不得把“未评估”伪装成通过。
7. 超长输出、异常、取消或消费者提前结束时，显式关闭整条生成器链；对应子 worker 的 abort/reap 与参考租约释放完成后，才能放开对应 TTS lane。不能依赖垃圾回收代替关闭。
8. eviction 获取 router 生命周期锁和释放 worker 的等待必须共享原请求的绝对 deadline，不能在 TTS 与 ASR 两阶段之间形成无界等待。
9. 验证器异常仅记录稳定错误码和 request ID；禁止输出 vendor 异常正文或 traceback，防止转写、参考内容和本地路径进入日志。

## 6. 当前实现与阈值边界

当前 `quality-runs` 已实现：

- Phase A 在 `BATCH_TTS` governor reservation 内完成固定 probe 合成、信号门和重复 digest；
- 只保留每类 probe 的首个有效 PCM 作为回转录样本；
- Phase A 结束并释放 TTS reservation 后，若 capability router 支持显式 eviction，则先释放当前 warm TTS 模型；
- Phase C 独立进入 `BATCH_ASR` reservation，并复用现有 `batch_transcriber` 与 `AdmissionQueue`；
- 24 kHz mono PCM16 使用有界线性重采样转换到 16 kHz，再按已知 probe 文本计算 Unicode/ITN 归一化后的字符编辑相似度；
- 六类 probe 取最小 `transcript_match`，当前 provisional 门为：`>=0.92 pass`、`0.80..0.92 warn`、`<0.80 reject`；
- ASR 未配置或验证器异常时报告 `unevaluated` / `transcription_unavailable`，绝不冒充 pass；队列饱和与 deadline 超时保持运行时 429/503 语义。

上述 0.92/0.80 是工程初始值，不是已校准的人类感知阈值。真实 Apple Silicon 语料验收必须覆盖数字、日期、单位、长短句和噪声反例，再决定是否调整。

## 7. 验收标准

代码回归与目标机验收分别覆盖以下项目：

- 干净正确语音：六类 probe 均达到校准后的 transcript-match 门；
- 随机噪声：不能通过文本一致性门；
- 可听但读错/漏字/复读：被 transcript mismatch 捕获；
- 数字、日期、百分比和单位：ITN 后不产生系统性误杀；
- ASR 不可用/超时：报告明确的 unavailable 状态；
- Base TTS 与 ASR 的峰值内存不因质量复测形成未治理叠加；
- 质量复测时延有上限并记录分阶段耗时。

## 8. 与 Sona 的边界

Sona 只消费最终质量报告和稳定错误码，不实现第二套 ASR 质量算法。Sona 可以把失败原因转成用户可理解的重录/重试建议，但模型调度、重采样、文本规范化和质量判定属于 SpeechRail。
