---
title: "克隆音色输出可懂度与 ASR 复核设计"
status: proposed
audience: "SpeechRail/Sona 维护者、质量工程与架构评审者"
version: "1.0"
date: 2026-09-12
---

# 克隆音色输出可懂度与 ASR 复核设计

## 1. 目的

现有数字信号门禁可以拒绝空输出、近静音、削波和重复运行的不确定输出，但**不能证明生成内容是可懂语音，也不能可靠区分正常语音与幅度正常的随机噪声**。

因此 Quality 音色验收需要增加独立于 TTS 的文本/可懂度证据。首选复用 SpeechRail 已有 ASR，而不是继续堆叠幅度阈值。

本文只定义下一阶段架构与资源边界；在完成 Apple Silicon 资源验证前，不把 ASR 复核声明为当前已上线能力。

## 2. 关键约束：不得无治理地并行 Base TTS 与 ASR

Quality reference clone 由 Qwen3-TTS Base 承担。Base 与 VoiceDesign 已通过 capability router 使用单个互斥的大模型槽。

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

Phase B: release/switch TTS capability
  -> complete active Base stream
  -> release capability lock
  -> close/evict Base when policy requires
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

1. 不在 TTS capability lock 内启动 ASR；
2. 不自行创建绕过 `AppServices` 的额外 ASR worker；
3. 使用现有 `batch_transcriber`/`transcribe` 依赖；
4. 接受现有 admission/governor 的拒绝与超时；
5. 临时 PCM 有明确上限，验收完成后释放，不写磁盘；
6. ASR 不可用时报告“未评估”，不得把“未评估”伪装成通过。

## 6. 为什么不在当前 PR 中直接上线

当前 PR 首先修复模型职责与可证实的质量门缺陷：

- reference clone -> Base；
- VoiceDesign 保留为 prompt voice creation；
- 6 类固定 probe 全覆盖；
- 静音/削波拒绝；
- 固定种子下的重复 PCM 确定性验证；
- Quality 双模型按需互斥生命周期。

ASR 输出复核需要额外完成 24 kHz -> 16 kHz 重采样口径、heavy-overlap/内存验证以及真实 Apple Silicon 性能测试。先写清边界再实现，避免为了“拒绝噪声”引入未经治理的新重模型重叠。

## 7. 验收标准

进入实现阶段后至少验证：

- 干净正确语音：六类 probe 均达到校准后的 transcript-match 门；
- 随机噪声：不能通过文本一致性门；
- 可听但读错/漏字/复读：被 transcript mismatch 捕获；
- 数字、日期、百分比和单位：ITN 后不产生系统性误杀；
- ASR 不可用/超时：报告明确的 unavailable 状态；
- Base TTS 与 ASR 的峰值内存不因质量复测形成未治理叠加；
- 质量复测时延有上限并记录分阶段耗时。

## 8. 与 Sona 的边界

Sona 只消费最终质量报告和稳定错误码，不实现第二套 ASR 质量算法。Sona 可以把失败原因转成用户可理解的重录/重试建议，但模型调度、重采样、文本规范化和质量判定属于 SpeechRail。
