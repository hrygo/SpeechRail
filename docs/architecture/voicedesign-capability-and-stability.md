---
title: "VoiceDesign 能力优势与音色稳定性边界"
status: active
version: "1.1.0"
date: 2026-09-06
---

# VoiceDesign 能力优势与音色稳定性边界

本文把 Qwen3-TTS 的官方能力说明、SpeechRail 当前实现和本机验收数据放在一起，明确 VoiceDesign 适合解决什么问题，以及目前不能作出什么承诺。

## 结论先行

VoiceDesign 已核实的核心优势是**开放式创造**：调用方可以用自然语言描述音色、年龄感、音高、口音、情绪和韵律，生成预置 speaker 之外的新声线。它特别适合虚构角色、故事旁白、游戏人物和用户描述型音色。

VoiceDesign 的描述能力不等于跨文本的 speaker identity 稳定性。已有质量验收表明，`quality` 对相同文本可以稳定复现；当前运行态为 `quality/1.8.0`，但现有跨文本 embedding 结果还不足以声明“九个角色始终是同一个人”。因此当前产品边界是：

- `quality` 用于需要开放式 VoiceDesign 的角色音色；
- `balanced/light` 用固定的 0.6B CustomVoice speaker，优先保证已注册 speaker 的复用稳定性；
- 如果同时要求“任意设计”和“跨文本始终同一个人”，采用官方的 VoiceDesign 生成锚点、再由 Base checkpoint 创建可复用 clone prompt 的路径；这不是当前 `quality` 运行时已经提供的稳定性保证。

2026-09-06 已完成一次 9 角色的 `instruction × seed` 联合搜索和独立 holdout。搜索本身全部成功，但选中候选的联合 `separation margin p05=-0.2126`，低于预注册的 `0.10`；与当前 recipe 的同 holdout 对照还使 readback CER p95 从 `8.76%` 上升到 `20.97%`。因此本轮不写回生产角色配置，结论仍是“创造能力已验证，身份稳定性未达标”。

## 1. 上游能力核实

以下结论来自 Qwen3-TTS 官方 README、官方推理接口和技术报告，而不是项目内部推断。

| 能力 | 官方接口或模型说明 | 对项目的含义 |
|---|---|---|
| 开放式音色创造 | `generate_voice_design(text, instruct)` 接收目标文本和自然语言 `instruct`；该路径不要求 `ref_audio`。 | 可以用文字组合描述型音色，不局限于预置 speaker。 |
| 自然语言控制 | 官方说明覆盖 timbre、emotion、prosody 等维度，并明确 VoiceDesign 支持用户提供的描述。 | 可以表达“年龄感、音高、口音、情绪、节奏”等角色设定。 |
| 固定音色复用 | 官方模型表将 CustomVoice 描述为 9 个 premium timbres；0.6B CustomVoice 的表项没有 instruction-control 标记。 | `balanced/light` 适合固定的九个 speaker，不应伪装成同等级的开放式 VoiceDesign。 |
| 可复用克隆 | Base 路径提供 `create_voice_clone_prompt` 和 `generate_voice_clone`；官方还给出“Voice Design then Clone”流程，用 VoiceDesign 短参考音频创建可复用 clone prompt。 | 这是“创造 + 稳定身份”的官方组合方案，但会增加 Base 权重、参考音频和 prompt 管理成本。 |

技术报告证明了 VoiceDesign 的 description-to-voice 创造能力；它没有替 SpeechRail 的跨文本身份验收提供通过证据。两类能力必须分开测量。

## 2. 在 SpeechRail 中的落地

### 当前运行态

2026-09-06 对本机服务做了核验：

- 服务版本：`1.8.0`，profile：`quality`；
- TTS 模型：`tts-1.7b-design-q8`，variant：`voice_design`；
- `/v1/voices` 返回九个 canonical role，均为可用的 VoiceDesign 角色并声明 `supports_instruction: true`；
- `/health`、`/readyz` 为 ready，`tts_ready: true`；恢复后的真实 TTS 与 ASR smoke 均返回 200 和非空结果。

九个初始角色已经存在并可用于 `quality/1.8.0`：

| canonical role | 当前角色意图 |
|---|---|
| `serena` | 温暖柔和的年轻中文女声 |
| `vivian` | 明亮清脆的年轻中文女声 |
| `uncle_fu` | 成熟稳重、低沉醇厚的中文男声 |
| `dylan` | 清晰自然、带北京口音的年轻中文男声 |
| `eric` | 活泼明亮、带自然四川口音的年轻中文男声 |
| `ryan` | 有活力和节奏感的英语男声 |
| `aiden` | 阳光自然的美式英语年轻男声 |
| `ono_anna` | 轻盈灵动、节奏明快的日语年轻女声 |
| `sohee` | 温暖柔和、情感丰富的韩语女声 |

角色的实际 profile、seed 和温度以当前代码为准，见 [`VoiceProfile` 与系统角色注册](../../src/speechrail/domain/tts.py)；模型绑定见 [`qwen3_voice_binding.py`](../../src/speechrail/backends/qwen3_voice_binding.py)。本文不复制完整 instruction，避免文档与运行时代码出现双份配置。

## 3. 当前实测能证明什么

本节引用 [三档音色稳定性研究](../archive/archive/2026-09-05-v1.7.0-full-three-tier-acceptance.md) 的已保存结果；原始音频、embedding 和 benchmark 制品仍在仓库外。

| 指标 | `quality` VoiceDesign | `balanced` CustomVoice | `light` CustomVoice |
|---|---:|---:|---:|
| 相同文本跨重启复现 | `27/27` | `27/27` | `27/27` |
| within-role cosine p05 / median | `0.4902 / 0.7853` | `0.6308 / 0.8278` | `0.6749 / 0.8273` |
| between-role cosine p95 | `0.7122` | `0.4561` | `0.4553` |
| separation margin p05 / median | `-0.0026 / 0.1116` | `0.2079 / 0.4215` | `0.3133 / 0.4489` |
| nearest-centroid accuracy | `88.89%` | `100%` | `100%` |

相同文本的 `27/27` 说明当前确定性设置能复现相同输入的输出；它不能证明换一段文本后仍然是同一个人。当前 `quality` 的 nearest-centroid accuracy 为 `88.89%`，低于预注册目标 `≥98%`；`within-role p05` 和 `separation margin p05` 也尚未同时达到 `≥0.60` 和 `≥0.10` 的目标。

人工 ABX 尚未执行。`instruction × seed` 联合搜索已经执行，但独立 holdout 未通过 separation margin 和可懂度回归门槛。因此当前不能宣称 VoiceDesign 已达到 CustomVoice 的跨文本同一人稳定性。

2026-09-06 搜索与 holdout 的详细结果见 [VoiceDesign recipe 搜索验收](../archive/process/archive/2026-09-06-voicedesign-recipe-search.md)。

## 4. 产品声明边界

可以声明：

- VoiceDesign 为自然语言描述提供了开放式音色创造能力；
- SpeechRail 的 `quality` 档位承载这项创造能力，并已注册九个可复用的初始角色设定；
- 当前相同输入的确定性复现已经通过现有测试范围。

不能声明：

- 任意 VoiceDesign instruction 都能跨文本保持同一 speaker identity；
- 当前九个 VoiceDesign 角色已经达到 `balanced/light` 的身份稳定性；
- 仅凭 embedding 或相同文本 hash 就完成了“同一个人”的人工听感验收。

## 5. ROI 后续动作：第二项执行结果

这里的“按 ROI 执行初始九角色设置”**不是新增九个角色**。九个初始角色已经上线；第二项是对每个已有角色做一次离线配方筛选。本轮已经完成：

1. 为同一个角色准备 3 个只强调身份特征的 instruction 变体；
2. 为每个 instruction 试 16 个 seed；
3. 因此每个角色有 `3 × 16 = 48` 个候选配方；
4. 用 6 段校准文本、每段重复 2 次生成，共完成 `9 × 3 × 16 × 6 × 2 = 5184` 次生成，并计算跨文本稳定性；
5. 对自动 selector 选出的 9 个候选，用 3 段未参与搜索的 holdout 文本、每段重复 3 次，共完成 `81` 条独立验证；
6. holdout 未通过联合身份门槛，故**不写回**角色配置，线上仍使用当前九个 recipe。

搜索的详细 winner 只记录 `variant + seed` 和汇总指标，不在本文复制完整 instruction；原始 WAV、embedding 和 summary 保存在仓库外的 benchmark 目录。公开的 `WeSpeaker CNCeleb ResNet34-LM` 只作为 embedding 评测模型依据，本轮没有把公开原始音频复制进项目。

若需求只是“让最初九个角色在线可用”，这部分已经完成，不需要先做 5184 次实验。

## 6. 验收门槛与回退

继续优化 VoiceDesign 前，预注册门槛为：nearest-centroid accuracy `≥98%`、within-role cosine p05 `≥0.60`、separation margin p05 `≥0.10`，并由 3 人、每角色至少 3 组 ABX 得出“同一人”判断率 `≥80%`。本轮 holdout 为 `100% / 0.6037 / -0.2126`；自动门未全通过，因此没有执行 ABX，也不能用人工主观选择掩盖分离度失败。

本轮 search winner 未写回；当前 nine-role seed/instruction 保持不变。按 ROI 决策，应停止继续盲调 VoiceDesign，固定角色改用 CustomVoice；若必须保留开放式创造，则评估官方的 VoiceDesign → Base clone 方案，并单独验收它的资源、参考音频管理和回退路径。

## 7. 依据

- [Qwen3-TTS 官方 README](https://github.com/QwenLM/Qwen3-TTS)：模型能力表、九个官方 speaker、VoiceDesign 接口和 Voice Design then Clone 流程。
- [Qwen3-TTS 官方推理接口](https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/inference/qwen3_tts_model.py)：`generate_voice_design`、`create_voice_clone_prompt` 和 `generate_voice_clone` 的参数与模型路径说明。
- [Qwen3-TTS Technical Report](https://arxiv.org/abs/2601.15621)：description-based voice control 与 novel voice creation 的研究说明。
- [Qwen3-TTS CustomVoice 模型卡](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice)：官方九个 speaker 和 CustomVoice 能力说明。
- [VoiceDesign 音色稳定性 ROI 评估](../archive/process/archive/2026-09-05-voicedesign-stability-roi.md)：本项目的 ROI、预注册门槛和未完成项。
- [三档音色稳定性研究](../archive/archive/2026-09-05-v1.7.0-full-three-tier-acceptance.md)：本项目三档实测数据和资源边界。
