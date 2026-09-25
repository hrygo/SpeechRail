---
title: "VoiceDesign 能力优势与音色稳定性边界"
status: active
audience: "架构师、TTS 质量负责人、Sona Voice Studio 开发者"
version: "2.4"
date: 2026-09-26
---

# VoiceDesign 能力优势与音色稳定性边界

## 1. 能力定位

VoiceDesign 的优势是**开放式音色创造**：调用方可以用自然语言描述年龄感、音高、口音、情绪、韵律和角色气质，而不局限于固定 speaker。它非常适合 Sona 的“描述声音”入口。

但 VoiceDesign 不再承担 SpeechRail 的 reference voice cloning。当前职责是：

- `reference` 的 VoiceDesign 1.7B BF16：提示词音色设计，只服务设计作业，普通 synthesize 不接受 Design 音色；
- 每个 TTS spec 的 Base（`fast`/`quality` 为 8-bit，`reference` 为 bf16）：参考音频克隆，由独立 capability worker 承担；允许与其他角色按预算并发，所在 capability group 冷却后可一起回收并在下一次请求时惰性恢复；
- 每个 TTS spec 的 CustomVoice：固定内置 speaker，普通合成与普通实时 TTS 的默认角色（`fast` 0.6B，`quality`/`reference` 1.7B）；
- Prompt voice 如果后续需要“跨任意文本始终像同一个人”，走 **VoiceDesign → canonical reference → Base stabilization**，而不是反复让 VoiceDesign 对每段目标文本重新拟合身份。

完整架构见 [Quality / Reference 档音色创造、克隆与稳定化能力架构](quality-voice-capabilities.md)。`reference` 的 bf16 制品按用户裁定继承同族 8-bit 档位已通过的门禁证据，未在本机逐项复测，也不从 BF16 dtype 推断质量效果或资源峰值。

## 2. 为什么要分离创造与复现

“设计一个有特点的声音”和“在不同内容上复现同一个 speaker”是两种不同的优化目标：

| 目标 | 最合适的主能力 | 主要评价 |
|---|---|---|
| 创造新声线 | VoiceDesign | 描述符合度、自然度、表现力 |
| 复现参考 speaker | Base clone | speaker similarity、跨文本一致性、可懂度 |
| 固定内置角色 | CustomVoice | 一致性、吞吐、资源占用 |
| 创建后稳定复用 | VoiceDesign → Base | 创造符合度 + 跨文本 identity |

旧实现用 VoiceDesign 私有 ICL 方法承接 reference clone，会把“模型内部能够接受参考上下文”误解为“这是该模型最合适、最稳定的 speaker clone contract”。2026-09-12 起，这条路径不再是 SpeechRail 架构基线。

## 3. 按角色绑定的能力与并发

catalog 为每个 TTS spec 绑定 `tts_custom_voice` 与 `tts_base` 两个角色，`reference` 另绑定只用于设计作业的 `voice_design`：

| TTS spec | 内置声音 `tts_custom_voice` | 参考克隆 `tts_base` | 提示词设计 `voice_design` |
|---|---|---|---|
| `fast` | CustomVoice 0.6B q8 | Base 0.6B q8 | — |
| `quality` | CustomVoice 1.7B q8 | Base 1.7B q8 | — |
| `reference` | CustomVoice 1.7B bf16 | Base 1.7B bf16 | VoiceDesign 1.7B bf16 |

三个角色是独立 governor lane，可以按预算并发；同一 lane 由对应 worker 的私有 lock 串行。精度身份不等于质量排名：`reference` 的 bf16 制品按用户裁定继承同族 8-bit 档位已通过的门禁证据，未在本机逐项复测。

运行时使用按角色的 capability router。懒加载模式下每个角色在首次使用时加载，加载后在同一任务内不因角色切换而反复换模；`WorkerIdleEvictor` 在冷却后以 capability group 为单位整体驱逐 TTS worker，下一次请求再按需恢复，避免连续请求在角色之间反复换模。

## 4. Prompt-created voice 当前边界

本 PR 保持兼容：已有 prompt-created profile 仍直接由 VoiceDesign 合成，不自动修改 voice asset。

当前已通过 `/v1/voice-designs` 提供候选生命周期：确认参考、用不同文本进行 Base 复验、
完成人工听审后再原子发布全新 Base-bound clone，并保存来源 hash，原音色不变。
VoiceRevision 的持久化历史、CAS update、rollback、revoke 和 delete 已由 registry 提供；
候选或机器验证完成都不等于输出声纹验收通过，不能将发布视为整体声学完成：

```text
instruction
  → VoiceDesign 生成候选 canonical reference
  → 质量门 + 显式人工听审
  → Base 建立新 VoiceRevision，并进入可回滚的 revision 历史
  → 后续目标文本由 Base 复现
```

该动作必须：

- 创建新 revision，而不是覆盖旧 profile，并保留旧 revision 的回滚/撤销语义；
- 记录 canonical text/audio hash、preprocessing version、model revision；
- 通过 CAS 约束更新、回滚和撤销；
- 用 holdout 文本验证 speaker identity，不能仅用同一文本重复 hash；该声学验收当前仍需独立执行。

## 5. 稳定性证据边界

历史 VoiceDesign recipe 搜索、三档音色评测仍可作为“为什么需要稳定化”的证据，但不能反过来证明 Base 路径已经通过新验收。旧数据和过程归档保留在：

- [三档音色稳定性研究](../archive/archive/2026-09-05-v1.7.0-full-three-tier-acceptance.md)
- [VoiceDesign recipe 搜索验收](../archive/process/archive/2026-09-06-voicedesign-recipe-search.md)
- [VoiceDesign 音色稳定性 ROI 评估](../archive/process/archive/2026-09-05-voicedesign-stability-roi.md)

当前不得宣称：

- 任意 VoiceDesign instruction 都能跨文本保持同一 speaker identity；
- 同文本确定性等于跨文本同一人；
- Base capability 接入后无需真实参考音频 A/B 就已经解决全部漂移；
- 声纹稳定自动意味着专业播报韵律。

## 6. 与专业表达的关系

Speaker identity 与 prosody 需要独立评价。用户自己的参考可能包含停顿、语速和表达习惯；高质量克隆不应强迫用户先成为专业播音员。

Quality 后续可引入“自然播报”模式，对 Base conditioning 方式或其他后端做身份/表达解耦实验。任何 VoxCPM2/voice-conversion 类候选都必须先经过 speaker leakage、自然度、首音延迟、RTF、内存和离线依赖验收，不能因为支持 instruction 就直接成为默认路径。

## 7. 参考资料

- [Qwen3-TTS 官方仓库](https://github.com/QwenLM/Qwen3-TTS)
- [Qwen3-TTS Base 模型](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base)
- [SpeechRail Quality / Reference 档音色能力架构](quality-voice-capabilities.md)
- [SpeechRail 音色克隆架构设计与工程交接](voice-cloning-design-and-handoff.md)
