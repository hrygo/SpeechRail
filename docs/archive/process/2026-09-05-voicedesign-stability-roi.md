# VoiceDesign 音色稳定性 ROI 评估

> 日期：2026-09-05
> 状态：研究完成，待按本报告的预注册门执行优化实验
> 决策范围：SpeechRail `quality` 使用 Qwen3-TTS 1.7B VoiceDesign q8；不改变 OpenAI API 调用方式

## 结论

在继续使用 VoiceDesign 权重的前提下，最高 ROI 不是继续微调单个采样参数，而是进行一次离线的“角色 instruction × seed”校准，并把选中的完整生成配方固化为版本化资产。它没有额外运行时内存和延迟成本，预计能改善九个预置角色的跨文本分离；是否达到“听起来始终是同一个人”，必须用预注册 embedding 门和人工 ABX 决定。

VoiceDesign 的定位应是**创造声线和角色**。CustomVoice 的定位应是**稳定复用官方固定 speaker**。二者解决的问题不同：

- VoiceDesign 接收自然语言描述，不需要参考音频，可以设计九个固定 speaker 之外的性别、年龄、音高、共鸣、口音、情绪和韵律组合。
- CustomVoice 使用训练时固化的 speaker identity，更适合跨文本保持一个人；0.6B 版本只有九个 speaker，当前 `balanced/light` 不执行自然语言 VoiceDesign instruction。
- 要同时获得“任意设计”和“长期固定身份”，Qwen 官方推荐 VoiceDesign 生成参考片段，再由 Base checkpoint 创建可复用 voice-clone prompt；这不是单独使用 VoiceDesign 权重即可获得的保证。

## 当前实测基线

完整方法和原始证据见 [v1.7.0 三档完整本机验收与音色稳定性研究](../performance/2026-09-05-v1.7.0-full-three-tier-acceptance.md)。以下为母语文本集，每档 9 角色 × 3 文本 × 3 次：

| 指标 | `quality` VoiceDesign 1.7B | `balanced` CustomVoice 0.6B | `light` CustomVoice 0.6B |
|---|---:|---:|---:|
| 同文本 PCM hash | 每组 1 个 | 每组 3 个 | 每组 3 个 |
| 跨重启同输入 | 27/27 完全一致 | 未要求字节一致 | 未要求字节一致 |
| within-role cosine p05 / median | 0.4902 / 0.7853 | 0.6308 / 0.8278 | 0.6749 / 0.8273 |
| between-role cosine p95 | 0.7122 | 0.4561 | 0.4553 |
| separation margin p05 / median | -0.0026 / 0.1116 | 0.2079 / 0.4215 | 0.3133 / 0.4489 |
| 最近中心准确率 | 88.89% | 100% | 100% |

这说明固定 seed 与低温采样已经解决“相同输入不能复现”的问题，但没有解决“换文本后 speaker identity 仍属于同一簇”。VoiceDesign 每次根据 instruction 和目标文本共同生成声学结果；文本语义与韵律也参与声线形成。

本机性能代价为：

| 指标 | `quality` | `balanced` | quality 组合差异 |
|---|---:|---:|---:|
| TTS 长句 RTF p50 | 0.2642 | 0.2349 | 约 +12.5% |
| 最大同时物理占用 | 6943.9 MB | 6085.9 MB | 约 +858 MB |
| 九角色回读 CER mean | 7.57% | 9.98% | quality 低 2.41 个百分点，仅作可懂度代理 |

这里比较的是 `1.7B VoiceDesign` 与 `0.6B CustomVoice` 的完整档位组合，不能把全部差异单独归因于 VoiceDesign 模式。

## VoiceDesign 的实际优势

### 1. 开放式角色创造

官方模型接口的 VoiceDesign 输入只有目标文本、语言和自然语言 `instruct`；无需现成 speaker 或参考音频。它适合游戏角色、故事旁白、虚构人物、一次性情绪表演和用户描述型音色。[Qwen3-TTS 官方模型卡](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice)明确区分：VoiceDesign 根据描述设计声线，CustomVoice 提供九个固定优质音色，Base 负责参考音频克隆。

### 2. 控制维度高于当前低档

VoiceDesign 能把音色属性和表达属性一起写入 instruction。当前 `balanced/light` 使用 0.6B CustomVoice，只能选择九个 speaker；官方能力矩阵没有给 0.6B CustomVoice 标记 instruction control。1.7B CustomVoice 可以在固定 speaker 上做风格控制，但仍不能创建九个 speaker 之外的新身份。

### 3. 官方 instruction-following 表现强

[Qwen3-TTS Technical Report](https://arxiv.org/abs/2601.15621) 的 InstructTTSEval 结果如下：

| 模型与任务 | 中文 APS / DSD / RP | 英文 APS / DSD / RP |
|---|---:|---:|
| 12Hz 1.7B VoiceDesign，创建新声线 | 85.2 / 81.1 / 65.1 | 82.9 / 82.4 / 68.4 |
| 12Hz 1.7B CustomVoice，编辑目标 speaker | 83.0 / 77.8 / 61.2 | 77.3 / 77.1 / 63.7 |

两个结果属于同一基准的不同任务，不能当成严格的同任务优劣对比。它们说明 VoiceDesign 的优势是“描述与声音一致、能按描述创建”，没有证明其 speaker identity 比 CustomVoice 稳定。

### 4. 不需要用户录制真人参考音频

对虚构角色而言，VoiceDesign 避免采集、保存和管理真人参考录音，也减少同意、删除和误用真人声纹的产品负担。用户如果只想表达“温柔、低沉、有北京口音的青年男声”，描述比准备高质量参考音频更直接。

## ROI 排序

下表为工程决策序位。收益与成本采用 1–5 的序数评分，用于排序，不是财务预测。

| 方案 | 跨文本身份收益 | 实施成本 | 运行时成本 | 能力影响 | ROI | 决策 |
|---|---:|---:|---|---|---|---|
| A. 固化全部 RNG 与配方版本，seed 失败即报错 | 1–2 | 1 | 无 | 无 | 高 | 必做可靠性门 |
| B. 离线联合搜索 instruction × seed | 3–4 | 2 | 无 | 无 | **最高** | 立即执行 |
| C. 创建音色时生成候选，用户试听后 pin seed | 2–3 | 2 | 只增加创建时推理 | 改善可控性 | 高 | 自定义音色采用 |
| D. 减少长文本独立生成段数 | 1–2 | 2 | 可能增加单次内存/首段延迟 | 无 | 中 | 单独 A/B 后决定 |
| E. 预置角色改为 1.7B CustomVoice | 4 | 2 | 未在本机实测 | 失去开放式新音色 | 条件性高 | 仅在固定角色优先时 |
| F. VoiceDesign 生成锚点，再用 Base clone prompt | 5 | 4 | 增加 Base 权重、存储与切换成本 | 同时保留创作与持久身份 | 中高 | 战略方案 |
| G. 每角色 Base SFT | 5 | 5 | 训练、版本和分发成本高 | 固定角色最强 | 低 | 当前不做 |

### A. 确定性硬化

当前实现已为系统角色固定 seed 和 `temperature=0.1`，但 seed 调用异常会被吞掉。正确边界是：

1. 固定主模型与 subtalker 的所有随机源、`temperature`、`top_p`、`top_k`、`repetition_penalty`、模型 revision 和 runtime lock。
2. 任何随机源无法设置时 fail closed，不能悄悄退化成随机输出。
3. 返回或内部记录 `voice_recipe_version`，使音频问题能追溯到不可变配方。

这项工作主要防止未来退化。当前相同输入已经完全复现，因此单靠它无法显著提高跨文本相似度。

### B. instruction × seed 离线校准

当前九个 seed 是固定值，但没有证据显示它们是角色稳定性的最优点。VoiceDesign 的 seed 会选择不同的声学实现，因此应把 seed 当作模型参数校准，而不是任意常量。

建议每个角色准备：

- 3 个只描述身份的 instruction 变体；
- 16 个候选 seed；
- 6 条校准文本：母语短句、长句、数字、问句、情绪中性句、跨语言句；
- 2 次重复，并保留独立验证文本。

总量为 `9 × 3 × 16 × 6 × 2 = 5184` 条。按当前短句生成速度，属于约 1–2 小时的一次性本机计算；最终线上请求没有额外成本。目标函数按顺序优化：失败率、ASR 回读、within-role p05、separation margin p05、角色间混淆，最后由小规模 ABX 选择 Pareto 候选。

instruction 应只固定身份属性：年龄区间、性别呈现、音高范围、共鸣位置、音色纹理、气声程度、口音与基础语速。临时情绪、场景和表演强度不写入系统角色身份，避免模型把情绪变化解释成换人。

### C. 自定义音色的试听与 pin

自然语言描述本身存在多解。同一个“温暖年轻女声”可以合理对应很多人。创建自定义 VoiceDesign 音色时生成 3–4 个候选并保存各自 seed，让用户选中一个后固化完整 recipe，比服务端随机挑一个更符合用户对“这个人”的主观定义。

之后相同 voice ID 始终使用已选 recipe。API 调用方仍只传标准 `voice`，profile 和 seed 对调用方透明。试听与 pin 能固定用户选中的解释，但仍不能单独保证该 seed 在所有文本上保持同一 speaker，必须继续经过跨文本门。

### D. 长文本生成边界

当前长文本会按边界拆成多次独立 VoiceDesign generation。每段都重新由 instruction 与当前文本塑造声音，可能产生段间身份变化。可以测试提高单次安全文本上限或让较短相邻句共用一次 generation，但必须同时测峰值内存、首包延迟、漏句和取消响应。没有 A/B 证据前不改现有 240 字符安全边界。

### F. VoiceDesign → Base anchor

Qwen 官方给出的持久角色方案是：

1. VoiceDesign 根据描述生成满意的参考片段；
2. 1.7B Base 从参考音频和匹配文本创建 `voice_clone_prompt`；
3. 后续所有内容复用该 prompt，不重复提取。

官方公开实现把 `generate_voice_design` 限定为 `voice_design` 模型，把 `create_voice_clone_prompt` 与 `generate_voice_clone` 放在 Base 模型路径：[官方推理接口](https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/inference/qwen3_tts_model.py)。因此不能把 VoiceDesign 模型中的私有内部方法能运行，直接当作受支持的持久克隆能力。

对 SpeechRail 单机允许停服切换的边界，可选择：平时运行 Base 负责持久角色；用户创建新音色时停服加载 VoiceDesign，生成锚点后切回 Base。这样避免同时驻留两个 1.7B TTS，但会增加模型磁盘、创建时间、切换事务和新失败面。它只有在“跨文本必须像同一人”成为核心产品要求时才值得实施。

## 预注册验收门

先冻结门值，再执行 prompt/seed 搜索，避免根据结果挑有利指标。建议相对当前母语集：

| 指标 | 当前 | 第一阶段目标 |
|---|---:|---:|
| nearest-centroid accuracy | 88.89% | ≥98% |
| within-role p05 | 0.4902 | ≥0.60 |
| separation margin p05 | -0.0026 | ≥0.10 |
| ASR 回读 CER p95 | 20.0%（统一中文压力集） | 不高于当前且失败为 0 |
| TTS RTF / 最大物理占用 | 当前基线 | 回归不超过预先冻结噪声带，建议 5% |
| 人工 ABX | 未测 | 3 人、每角色至少 3 组，same-person 判断 ≥80% |

校准文本与最终验证文本必须隔离。达到自动门后才执行 ABX；自动门失败则不通过人工主观选择掩盖。

## 决策规则

1. 先实施 A+B+C；它们保留当前三档架构和 API，运行时资源不增加。
2. 若达到预注册门，继续保留 VoiceDesign 作为 `quality` 预置与自然语言自定义音色实现。
3. 若未达到门，停止细调采样参数，把 VoiceDesign 明确定位为 creative voice；需要持久身份的角色使用 CustomVoice 或 Base clone。
4. 若产品确认“任意声线”和“同一人”都属于核心要求，再立项 F，并单独测 Base q8 的内存、切换时间、参考音频安全和三档降级行为。

## 证据限制

- 当前 speaker embedding 是固定 WeSpeaker 模型的诊断结果，尚无人工 MOS/ABX。
- 官方 VoiceDesign 与 CustomVoice 的 InstructTTSEval 数字属于不同任务，只能支持能力定位，不能证明同任务绝对优劣。
- prompt/seed 搜索的收益是待验证假设；本报告已给出预注册门，不把预期写成完成事实。
- 1.7B CustomVoice 和 1.7B Base 尚未在当前 SpeechRail 本机组合中测量内存与速度。
