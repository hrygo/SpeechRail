---
title: "PR #74 managed ASR and TTS overlap evidence"
status: partial_external_evidence
date: 2026-09-20
---

# PR #74 managed ASR and TTS overlap evidence

## 结论

这是现有 managed `quality` profile 上对 #44/#65 的一段真实调度与资源证据，
不是识别质量、音质或完整热稳定性验收。使用官方 `bench_overlap.py` 执行 TTS
与 ASR 的反向时序各一次；两种场景的请求均成功，采样完整，未改变服务配置或
LaunchAgent。

测量时间：2026-09-20（Asia/Shanghai）。运行条件为 release `2.7.0`、quality
generation `102`、单一现有服务实例。

## Fixture 与限制

- ASR 使用仓库外 1 秒合成静音 WAV，仅用于触发真实 ASR worker 和观察准入/资源；
  不用于声明转写正确性、语言识别或 RTF 质量。
- TTS 使用固定中文长文本、voice `serena`，输出 PCM；没有保存原始音频。
- benchmark 的 `model_identity` 仍为空；profile 配置声明不等同于 worker 的实际
  制品身份证明。
- 原始 JSON 与占位 WAV 留在仓库外临时目录，仓库只保留本摘要。

## 实测结果

| 场景 | 时序 | 请求结果 | governor batch peak | 资源采样 | `phys_footprint` peak | RSS peak |
| --- | --- | --- | ---: | --- | ---: | ---: |
| C1 | TTS 先，0.5 s 后 ASR | TTS 200；ASR 200 | 2 | 15 samples，0 errors | `6747757840` bytes | `6083330048` bytes |
| C2 | ASR 先，0.5 s 后 TTS | ASR 200；TTS 200 | 1 | 18 samples，0 errors | `7010721040` bytes | `6083411968` bytes |

C1 证明在当前资源与策略下，TTS 活跃期间可以观察到 ASR∥TTS 的 batch overlap，
且两请求均完成；C2 中 ASR 在延迟窗口内先完成，因此本次没有形成持续重叠，不能
被解释为反向公平性或优先级结论。

## 尚未证明的内容

本次没有执行持续负载、voice-design/quality maintenance 混合场景、取消泄漏、
thermal/soak、cold/switch 或人工听感；没有预设性能提升百分比。完整 #44/#65
验收仍需 paced commit-tail、真实维护任务、失败/取消清理、内存压力和热观察，且
必须分别记录样本数与失败率。
