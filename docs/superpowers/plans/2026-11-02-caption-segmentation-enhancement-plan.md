---
title: "实时字幕分级断句与语义续接增强计划"
status: proposed
version: "1.2.0"
date: 2026-11-02
author: "SpeechRail Team"
---

# 实时字幕分级断句与语义续接增强计划

**目标：** 减少实时字幕在分句换气处的碎段、陈旧预览导致的提前收口和跨段语义断裂，同时限制段落继续增长；保留原始定稿、音频边界和翻译生命周期。

**架构：** 服务端以 VAD 为必要条件，将有样本依据的标点作为软水位区的辅助信号；客户端在既有段落投影中处理关联句式和阅读预算。音频分段、语义段落与屏幕换行分别承担职责。

**技术栈：** Python 3.14、现有单 ASR worker、16kHz kernel PCM、Swift / macOS 26+；不增加模型、依赖或后台服务。

**执行说明：** 本文件是待评审方案，不代表实施、质量认证或运行态变更已获授权。实施时按 `executing-plans` 逐任务推进；每项先补反例、确认失败原因，再实现并定向验证。不自动 commit、push、安装、启停服务或执行前台 UI 自动化。

**设计依据：** [前置分段与续接计划](2026-11-02-caption-segmentation-and-rollover-continuity-plan.md)、[实时字幕重构计划](2026-10-25-app-targeted-realtime-captions-redesign.md)、[测试与验收](../../developers/testing-acceptance.md)。本文件包含本次补充设计和实施任务；与较早计划的参数叙述冲突时，现状以本次源码核查为准。

## 1. 调研结论与证据边界

核验日期：**2026-11-02**。本次查阅官方资料、Git 历史和当前工作区源码；未运行真实模型、性能基准、App 构建或 UI 测试。

### 1.1 当前实现

基线为当前分支 `feat/caption-segmentation-rollover` 的 `65f0f61f`；相关前置提交为 `972d9e17`。提交存在只说明实现进入本分支，不证明 PR 已合并、正式安装或真实场景问题已彻底解决。

| 对象 | 源码核实事实 | 对本计划的影响 |
| --- | --- | --- |
| [ASRScenePreset.swift](../../../macos/SpeechRailApp/SpeechRailApp/ASRScenePreset.swift) | caption：预览 500ms、段预算 14,000ms、静音 650ms、`fullSegment` | 本轮保留这些预设；不再次扩大上下文 |
| [realtime_asr.py](../../../src/speechrail/application/realtime_asr.py) | 软水位公式为 `min(8000, max(5000, int(effective_ms * 0.55)))`；满足 `effective_ms >= 8000 && stop_frames > 5` 才启用 | 14s 预算对应 7.7s 软水位；这套启用条件并非 caption 独有 |
| [Realtime 契约](../../../contracts/realtime-openai.md) 的 ASR 策略约束 | 场景预设由客户端选择，服务端不依据 `task` 推断策略 | 分级参数须保持服务中立；不能暗加 caption 专属分支 |
| 同上 | caption 常规 `ceil(650/32)=21` 帧；标点 4 帧；无标点 `min(21, max(12, int(21*0.85)))=17` 帧 | 实际分别为 672ms、128ms、544ms；“≥384ms”只是公式的一部分，不是统一值 |
| [speech_admission.py](../../../src/speechrail/realtime/speech_admission.py) | 标点提示是布尔值；软水位区同时提高退出概率阈值到 entry/stop 两阈值均值 | 不能只测纯静音；还须覆盖阈值之间的弱语音 |
| [ports.py](../../../src/speechrail/domain/ports.py)、[qwen3_worker.py](../../../src/speechrail/backends/qwen3_worker.py)、[qwen3_streaming.py](../../../src/speechrail/backends/qwen3_streaming.py) | `StreamingAsrEvent.sample_watermark` 已存在；是本段已解码的 16kHz 样本末端，非接收进度、24kHz wire 游标或标点时间戳 | 复用已有内部证据；缺失时不得伪造截止点 |
| [CaptionParagraph.swift](../../../macos/SpeechRailApp/SpeechRailApp/CaptionParagraph.swift) | 最多 3 个 `Line`、音频/观察时长最多 28s、间隔最多 1.2s；短碎片和强未完成词尾已有规则 | `maximumLines` 是 ASR 记录数，不能解释为屏幕行数 |
| [CaptionSession.swift](../../../macos/SpeechRailApp/SpeechRailApp/CaptionSession.swift) | 完整句等待 200ms、普通分句 320ms、截断/短碎片/强未完成尾部 750ms；定时收口后进入段落翻译 | 只改 `score` 不足以保证下一条 final 到来前段落仍开放 |
| [CaptionTranslator.swift](../../../macos/SpeechRailApp/SpeechRailApp/CaptionTranslator.swift) | `CaptionLanguageDetector` 面向中文免翻译路由，兼有语言识别；当前合并额外比较 `isChinese` 与已知 `sourceLanguage` | 它不保证严格语种隔离；英文、日文、韩文同属非中文，短文本也可能误判 |
| `CaptionParagraph.append` | `sourceText` 保留原行标点并用空格连接；`displaySourceText` 去掉段内接缝标点；正式 `Line` 仍独立保存 | 任何新规则不得改写原行正文、时间、ID 或归属证据 |

图谱核查使用 generation `2026-11-02T13:38:03Z`，相关路径已执行覆盖检查。`CaptionSession.swift` 和生命周期测试有局部解析缺口，已直接读取缺口与相关调用范围；图谱覆盖仅为辅助证据，不作全仓完整性声明。

### 1.2 外部依据及可采用范围

| 官方资料 | 可确认事实 | 本项目采用方式与限制 |
| --- | --- | --- |
| [Google StreamingRecognitionResult](https://docs.cloud.google.com/speech-to-text/docs/reference/rest/v2/StreamingRecognitionResult) | 区分可修改 interim、final、稳定度与结果截止偏移 | 借鉴“文本状态与音频进度分别表达”；不能据此推断 Live Transcribe 的私有断句算法或本项目已有稳定度 |
| [FunASR 在线 SDK](https://github.com/modelscope/FunASR/blob/main/runtime/docs/SDK_tutorial_online.md) | 2-pass 采用实时识别和句末离线纠错，并输出标点 | 佐证预览/定稿职责分离；不引入 FunASR、多模型并行或照搬其延迟参数 |
| [Apple NLTagger](https://developer.apple.com/documentation/naturallanguage/nltagger)、[availableTagSchemes](https://developer.apple.com/documentation/naturallanguage/nltagger/availabletagschemes(for:language:))、[lexicalClass](https://developer.apple.com/documentation/naturallanguage/nltagscheme/lexicalclass) | 提供分词和词性标注；可用 scheme 按设备、语言和 token unit 查询；同一 tagger 不可并发跨线程使用 | 词性是辅助信号，不是句法完整性证明；不承诺中文必有特定 tag，不承诺 <0.2ms 或零驻留内存 |
| [Netflix 简中字幕规范](https://partnerhelp.netflixstudios.com/hc/en-us/articles/215986007-Chinese-Simplified-Timed-Text-Style-Guide) §1/10/14/19 | 通常每行 16 字、最多两行；成人最高 9 字/秒，SDH 有例外 | 这是 Netflix 定时字幕交付要求。仅借鉴阅读负担观念，不能推出实时悬浮窗统一 36–40 字或固定两行 |
| [Google Live Transcribe](https://support.google.com/accessibility/android/answer/9158064?hl=en)、[Apple Live Captions](https://support.apple.com/guide/mac-help/get-live-captions-of-spoken-audio-mchldd11f4fd/mac) | 公开说明实时转写、显示及可用范围 | 未提供本计划所需的标点停顿阈值或词性合并算法；不将产品介绍当成算法验证 |

**工程判断：** 分级标点值得试验；0.5s 提示时效、256ms 分句停顿、38 字软预算和关联词加分都是本项目候选参数，尚无真实语料证据。删除“工业 SOTA 已验证”“彻底解决”“零内存”等无依据承诺。

### 1.3 历史约束

> 🧠 **From Hindsight memory (会议准确性与实时字幕回溯修正落地)** — 历史方案区分即时预览、定稿和近期可修改窗口；跨段修正需要音频边界证据，局部回归通过不能代表字幕端到端质量门通过。

本轮源码已核实已有样本水位和段落投影；不据历史页面中的旧预设值或验收报告判断当前参数、安装状态与质量。实验性 revision window 的启用与认证不在本计划范围。

## 2. 范围、约束与方案取舍

- 本次交付只修改本计划；以下任务均未执行。
- 后续实施复用现有单 worker、VAD、有界音频缓冲和段落翻译，不下载模型，不增加 LLM 断句或云端调用。
- 不增加 OpenAPI、WebSocket 字段或 close reason；保留 `vad`、`budget_rollover`、`client_commit` 的既有意义。内部 Python 接口可以直接更新全部调用者，不保留旧布尔参数 alias。
- 不改 SQLite schema，不迁移或批量重组历史记录。新会话仍按既有流程保存行及段落关联；影响仅为新增段落的分组、展示和翻译粒度。
- 保留 `maximumLines=3`、`maximumDuration=28`、`maximumGap=1.2`；真实说话人变化、明确语种变化、时长与容量边界始终优先。
- 不把标点当独立切段命令，不把词性当语法证明，不把软字数预算当屏幕尺寸保证。长单条 final 不在此任务内强拆，也不虚构字符到音频的时间映射。
- 遵循[设计系统](../../developers/macos-app-design-system.md)的展示与计算边界；算法预算不是视觉 Token。若后续改字号、宽高、控件或实际换行，另按 Token 和 UI 验证规则实施。

| 选项 | 收益与成本 | 建议 |
| --- | --- | --- |
| 仅扩静态词表 | 改动小，不能解决提示时序和计时器抢先收口 | 不单独采用 |
| 样本门控＋分级停顿＋有界规则重组 | 复用现有证据，确定性测试可覆盖，涉及 Python 与 Swift | 主方案，T1–T4 顺序实施 |
| 默认引入 NLTagger | 可能泛化，也引入语言可用性、误合并和执行域问题 | T5 独立探索，不作为主方案前置条件 |

## 3. 服务端设计

### 3.1 提示的内部契约与坐标

拟将 `set_punctuation_boundary_hint` 更新为：

```python
def set_punctuation_boundary_hint(
    self,
    kind: Literal["terminal", "clause"] | None,
    *,
    sample_watermark: int | None,
) -> None: ...
```

该方法接收**会话绝对 16kHz kernel 样本坐标**。Owner 负责转换：`absolute_end = item.start_kernel + event.sample_watermark`；禁止传 wire 游标、当前接收进度或事件抵达时钟。`None` 表示撤销，不是“沿用上次标点”。

Owner 在修改 admission 提示前同时检查：当前 generation 相符、`item is self._asr_item`、item 尚未关闭且未 terminal。旧 item 的事件可以继续按原契约完成自身终态，但不得修改新段 admission。有效相对水位必须为正且不超出该 item 已送入的 kernel 音频范围；越界不 clamp 成“新鲜”。

Admission 保存有界状态：最新水位、标点类型、最后一个 VAD 判为语音的帧末端。使用提示必须满足：

1. 当前为 ACTIVE/HANGOVER，已进入软水位区；水位属于当前段且不超出已处理帧末端。
2. `0 <= frame_end_sample - absolute_end <= 8000`，包含等号；超过一个样本即过期。8000 样本为候选 500ms TTL，不是推理延迟实测。
3. `absolute_end >= last_speech_frame_end`：解码至少覆盖最近语音帧。恢复说话后，覆盖恢复前音频的旧提示失效，即使仍在 TTL 内。
4. 水位严格回退的事件忽略，不能覆盖更新提示；同水位按同一 backend 的有序事件流更新，允许标点被撤回。无水位、空文本或无标点的当前事件撤销标点，不以缺证据启用快切。
5. `reset`、新激活、关闭、`advance_segment_start`、clear/会话替换均清理提示与相关比较基线；rollover 不能继承旧段提示。

`sample_watermark` 是解码输入上界，**不是标点的逐词声学对齐**。上述规则保守拒绝未覆盖最新语音的提示，可能降低提示命中率；不能宣称消除所有模型标点误判。若 500ms 预览节奏导致快切很少触发，应记录命中和拒绝分布，不能放宽到使用接收水位或绕过最新语音校验。

### 3.2 标点分类与三级帧数

从 partial 末端去除空白及连续闭合引号/括号（`”’」』）》】)］]}"'`），再分类；全由空白或闭合符号组成时为无提示。分类使用轻量 ITN 之前的文本，避免数字归一化制造或吞掉标点边界。

- terminal：`。！？!?`；ASCII `.` 仅在会话显式指定中文且前一个 Character 为汉字时采用，auto/unknown 或数字/Latin token 后均保守作无提示，避免 `3.14`、`Dr.`、`U.S.` 造成快切。不为该判断新增语言推理调用。
- clause：`,，;；:：、`。
- `…`、连续 `...`、破折号属于歧义延续符号，本轮不触发标点快切；不简单将省略号归入 terminal 或 clause。

| 场景 | 软水位前 | 新鲜 terminal | 新鲜 clause | 无可用提示 |
| --- | --- | --- | --- | --- |
| caption，650ms 静音请求（`stop_frames=21`） | 原常规 21 帧 | 4 帧 / 128ms | 8 帧 / 256ms | 原公式 17 帧 / 544ms |
| 其他已有软水位场景（比例下限公式） | 原规则 | `min(stop_frames, max(4, stop_frames // 5))` 帧 | `min(stop_frames, max(8, (stop_frames * 2) // 5))` 帧 | `min(stop_frames, max(12, int(stop_frames * 0.85)))` 帧 |
| 未启用软水位/手动 commit | 原规则 | 不新增快切 | 不新增快切 | 原规则 |

这是共享内核的候选配置。中立 `SpeechAdmission` 接收 `terminal_stop_frames`、`clause_stop_frames`，不识别 App 场景；Owner 沿用现有预算/静音条件，按比例下限公式（`terminal = min(stop_frames, max(4, stop_frames // 5))`、`clause = min(stop_frames, max(8, (stop_frames * 2) // 5))`）注入分级参数，既保持 caption（21 帧）的 `4 / 8 / 17` 帧不变，又为长静默场景（如 meeting/duplex 29 帧 → `5 / 11 / 24` 帧、turn-taking 38 帧 → `7 / 15 / 32` 帧）保留比例化气口裕度。同时在软水位区进入静默挂起的第 2 帧（64ms），若最新标点水位尚未覆盖最后语音帧且未刷新音频累计达 `>= 4096` 字节（128ms），触发单次机会性 `asr.flush()` 以对齐句末标点水位。

所有有效阈值不超过常规 `stop_frames`，且满足 terminal ≤ clause ≤ 无提示 ≤ 常规；无软水位配置时全部禁用。保留 VAD 双阈值、预卷、尾帧和硬预算行为。`stop_frames` 很小时不能因三级配置反而延迟原收口。

32ms 帧有量化效应：4 帧是 128ms，不能写“120ms 必切”；6 帧 192ms 的逗号停顿不切，第 8 帧才切。弱语音在 soft threshold 附近仍可能被判作停顿，单纯调整帧数不能证明该风险已消除。

## 4. 客户端设计

### 4.1 统一边界分析

在 `CaptionParagraph.swift` 内增加小型值类型 `CaptionBoundaryEvidence: Equatable, Sendable`，保存 `strongIncomplete`、`correlativePair`、`continuation`、`standaloneReply`；由 `CaptionParagraphAssembler.boundaryEvidence(previous: String, next: String?) -> CaptionBoundaryEvidence` 返回。`next` 为可选，尚未到达时只能分析左侧。合并分析传入 `lastLineSourceText` 与新行，计时分析传入 `lastLineSourceText` 与 nil；同一证据供 `score`、`shouldMerge`、`flushDelayMilliseconds` 使用，避免三处词表和优先级漂移。

`CaptionParagraph` 增加非持久化的 `lastLineSourceText`，init/append 时同步；关联词配对检查上一条原行的最后 128 个 Character，不扫描整个历史段落。下一条只检查去除句首空白/引号后的前 24 个 Character。左侧只取最后一个内部终结标点之后的内容，末端 ASR 补出的句号可以先剥离；跨内部完整句的旧关联词不参与。

候选配对明确列出：`一边→一边`、`一方面→另一方面`、`不仅/不但→而且/还`、`虽然/尽管→但是/但/却`。右侧必须位于该前缀窗口内的起始位置；`还`、`但` 等短词只在左侧存在对应 opener 时给关联加分。左侧 opener 之后已出现对应 closer 时不再建立待配对关系。`所谓→不过`、`哪怕→也`、`宁可→也不` 暂不设强配对，避免评价、让步或偏好句式的泛化误判。

独立短回答先采用明确的完整匹配集合：去末端标点后等于 `好的`、`是的`、`走吧`、`行了`，且原行带终结标点时，标记 `standaloneReply`。非 rollover 时，该标记优先于短碎片和“的/了”词尾规则：按完整句等待 200ms、不自动并入后续行；rollover 仍保留截断处理。这是修正既有启发式的局部负例，不把所有短句都视为完整回答。

配对命中暂加 4 分（候选工程值），不越过说话人、明确语言、间隔、时长和行数硬限制。已知语言按规范化 code 比较；unknown 不制造语言事实，现有中文/非中文启发式仅维持原用途，本轮不扩展为全语种检测重构。

### 4.2 收口与翻译生命周期

仅“存在 opener”不代表句子未完。缺少后半配对时，不能把所有包含“一边/虽然”的完整句一律延长为 750ms；本轮保持现有 200/320/750ms 基础策略，左侧是否悬空仍按既有 `strongIncompleteEnding` 判定，并优先应用 §4.1 的独立回答例外；不另设模糊的“句法未闭合”推断。

- 配对加分只对**仍开放**的段落有效；不承诺跨任意 final 延迟合并，也不重开已翻译/封存的段落。
- `CaptionSession.scheduleParagraphFlush` 沿用可取消任务；追加行后取消旧任务、重算证据和剩余容量；关闭段落合并或达到 3 行立即收口。
- 后续行未在等待窗口内到达时按原策略独立起段，不无限等待、不轮询模型。暂停、结束、切记录和取消必须回收定时任务。
- 翻译关闭时原文仍立即可见；翻译开启时每个最终分组只触发一次 Stage 2。旧翻译回包不得覆盖已更新的段落；失败不能只导出第一行或丢失后续正文。

如果真实数据表明 final 抵达间隔普遍超出 750ms，另行评估“等待下一条 partial/segment_closed”的生命周期方案；本计划不暗增等待上限或将模型耗时当静音间隔。

### 4.3 阅读软预算

保留 `softMaxCharacterCount = 38`，但定义为**候选段落展示文本的 Swift Character 数**，包括标点、实际拼接空格与 emoji；用现有 `joinedSource` 规则先构造候选显示文本再计数。它是易解释的软预算，不是汉字数、Unicode scalar 数、终端列宽或字体测量值；英文与中英混排的适配须单列评估。

`shouldMerge` 按以下顺序决策：

1. 检查说话人、明确语言、3 行、28s、1.2s 等硬边界，以及 §4.1 的独立回答优先规则。
2. 计算共享边界证据和现有合并分数。
3. 候选文本超过 38 Character，且左侧是带终结标点的完整句、非 rollover、非短碎片、非强未完成、无关联配对且无明确 continuation 时，另起段。
4. 其余按语义评分决定。38 为包含边界：等于不阻断；超过但有连续性证据仍可合并，最终由 3 行和 28s 约束增长。

不截断、删字、压缩原文或插入虚构时间；单条长 final 原样保留。已有《沙丘》连续性反例需继续保护，也要新增真实完整长句的负例。软预算生效不等于悬浮窗“两行以内”：字体、窗口宽度、译文长度和双语模式都独立影响布局，本轮不新增像素级换行承诺。

### 4.4 可选 NLP 探索

`NLTagger` 暂不进入默认路径。后续若继续：先查询 `.word`/指定语言的 `.lexicalClass`，缺失或无 tag 时返回 unknown，且不调用 `requestAssets` 自动下载；反向枚举最后有效词，跳过空白、标点和闭合引号，不直接对末字符作词性判断。

词性本身最多提供弱加分，不能单独跨完整句边界或触发 750ms 等待；“好的。”“是的。”“走吧。”“行了。”中的助词不等于悬空。tagger 放入单一串行执行域，返回 Sendable 值，结果带段落 ID/修订身份；过期或取消丢弃。不为 async 壳在 MainActor 内执行同步 NLP，不跨线程共享实例，不按 partial 频率调用。

先以注入 tagger 的 fake 测试证明决策，再单独记录各语言实际 scheme/tag、冷暖耗时及内存。无收益则保留规则方案。任何 <0.2ms 或收益目标均须实测支持，不能作为当前验收事实。

## 5. 实施任务与定向验证

以下命令是**后续实施入口，本次未运行**。使用现有环境，缺依赖时先报告，不隐式下载。每项先用精确新测试名定向观察预期失败，再运行列出的相关回归；核对实际发现的用例和断言，不能把退出码 0 当作测试已执行。

### T1：样本对齐与陈旧提示隔离

**文件：** 修改 `src/speechrail/realtime/speech_admission.py`、`src/speechrail/application/realtime_asr.py`；测试 `tests/test_speech_admission.py`、`tests/test_realtime_asr_control.py`。

**输入/输出：** 消费已有 `StreamingAsrEvent.sample_watermark`；输出 §3.1 的新提示方法与有界校验状态。domain event、worker 协议和公开事件无需新增字段。

- [x] 新增 `test_boundary_hint_uses_absolute_kernel_samples`：item 起点 16000、相对水位 8000，提示必须落在 24000，不能是 8000 或 36000。
- [x] 新增 `test_boundary_hint_expiry_and_speech_frontier`：age 8000 可用、8001 无效；未来、缺失、回退水位及未覆盖最近语音帧时不得快切；同水位撤回标点立即生效。
- [x] 新增 `test_closed_item_partial_cannot_hint_new_segment`：rollover 后旧 final 未返回，旧 partial 仍不得影响新段；覆盖 clear、新 epoch、reset、finish、下一次激活。
- [x] 更新旧布尔接口的全部调用和直接测试；实现坐标转换、item 身份检查、状态清理，不修改原终态和 commit receipt。
- [x] 运行：`uv run --no-sync pytest tests/test_speech_admission.py tests/test_realtime_asr_control.py -q`。预期新旧反例全通过，音频样本不重不漏，不能仅断言私有字段。

### T2：标点分级与共享场景回归

**文件：** 同 T1；测试追加 `tests/test_realtime_multiscene_asr.py`。

**输入/输出：** 使用 T1 的可信提示；Owner 分类并注入两个帧数，Admission 仅执行中立参数，输出既有 `end` 决策。

- [x] 新增 `test_caption_boundary_tiers_use_exact_frame_counts`：soft zone 内，terminal 第 3 帧不切、第 4 帧切；clause 第 6/7 帧不切、第 8 帧切；无提示第 16 帧不切、第 17 帧切。
- [x] 新增 `test_punctuation_classifier_rejects_ambiguous_endings`：覆盖闭合引号、连续闭合符号、空文本、`3.14`、`Dr.`、`U.S.`、省略号和破折号；ASCII 点按 §3.2 保守分类。
- [x] 新增 `test_soft_boundary_requires_vad_pause`：连续高概率语音即使带标点也不切；覆盖 0.35/0.425/0.5 附近和软水位前后，保护弱语音与原双阈值语义。
- [x] 新增多场景参数化反例：相同 ASR/VAD 策略切换 `task` 时必须得到相同分级阈值；按各客户端预设验证 clause 为 `min(stop_frames, 8)`，其余停顿公式不变。短预算、小 `stop_frames`、手动 commit、硬 rollover 与尾部不足 512 样本均遵守原生命周期。
- [x] 实现后运行：`uv run --no-sync pytest tests/test_speech_admission.py tests/test_realtime_asr_control.py tests/test_realtime_multiscene_asr.py -q`。

### T3：关联词、统一证据与收口一致性

**文件：** 修改 `macos/SpeechRailApp/SpeechRailApp/CaptionParagraph.swift`，必要时修改同目录 `CaptionSession.swift`；测试 `macos/SpeechRailApp/SpeechRailMacControlTests/CaptionSessionLifecycleTests.swift`。

**输入/输出：** 提供 §4.1 的 `CaptionBoundaryEvidence`、`boundaryEvidence(previous:next:)` 和非持久化 `lastLineSourceText`；不改正式 `Line` 的持久化含义。

- [x] 新增配对正例和反例：`虽然画面很好。/但是节奏拖沓。`、`一方面画面出色。/另一方面配乐平庸。`；对照无 opener、opener 在上一完整句、完整结构在左侧已结束、超出扫描窗口、换人/换语言/超过硬边界，不能仅因出现短词就强合并。
- [x] 覆盖原有 dangling-but、PS5、短碎片、《沙丘》续接反例；新增“好的/是的/走吧/行了”独立应答负例，不默认延长完整句。
- [x] 使用受控调度/既有 harness 条件等待测试：窗口内追加仅一次收口，超时后不重开；追加取消旧任务；暂停/结束/关闭合并无遗留 timer。不得靠固定 sleep 证明并发完成。
- [x] 覆盖翻译开/关、过期回包、Stage 2 失败、段落导出和保存正文完整性；展示去接缝标点不改写 `sourceText` 或正式行。
- [x] 实现后运行：`swift test --package-path macos/SpeechRailApp --skip-update --enable-swift-testing --filter CaptionSessionLifecycleTests`。确认新 XCTest 实际发现并执行，不启动前台窗口。

### T4：软预算与完整性回归

**文件：** 同 T3，复用共享证据；如需抽取 `joinedSource`，仅开放为内部纯函数，不新增公共 API。

**输入/输出：** `softMaxCharacterCount=38`；合并决策按 §4.3，计数与最终展示拼接使用同一函数。

- [x] 表驱动覆盖候选显示文本计数恰为 38 和 39；完整句在 39 时另起段，rollover/强未完成/短碎片/关联配对/明确 continuation 分别允许软超限。
- [x] 覆盖中英混排、英文空格、emoji/组合字符、单条超过 38 的长 final、连续三段各 20 字；所有非标点正文完整保留，3 行和 28s 硬限仍生效。
- [x] 保存/导出回归：分组变化不重排行 ID、序号、时间和归属，不改写历史记录，不把语义段落时间包装成逐字时间。
- [x] 运行 T3 的 Swift 定向命令；实现后按实质变化同步 [Realtime 契约](../../../contracts/realtime-openai.md)、[API 用户文档](../../users/api-contract.md) 的相关行为说明，保持现有事件 schema；修改前复核文档实际章节。

### T5：NLP 可行性探索（独立、可不实施）

- [x] 按 §4.4 在仓库外或隔离测试中记录可用 scheme 与正反例；不修改默认生产路径、不请求系统资产下载。
  - **隔离实测记录（macOS 26.5 SDK / Apple Silicon，不调用 `requestAssets`）**：
    - **可用 Scheme**：`NLTagger.availableTagSchemes(for: .word, language:)` 仅在 `zh-Hans`（`Language`/`Script`/`TokenType`/`LexicalClass`）与 `en`（含 `LexicalClass`/`Lemma`）下提供 `.lexicalClass`；`ja`、`ko`、`zh-Hant` 均返回 `has_lexical_class = false`（仅 `Language`/`Script`/`TokenType`）。
    - **正反例标注对比**：`能让我看出一身鸡皮疙瘩，但。` 末词 `但` 标为 `Conjunction`，英文 `on the.` / `because,` 标为 `Determiner` / `Preposition`（均已被静态 `strongIncompleteEnding` 覆盖）；而悬空结构助词 `而在河谷镇的。` 与独立完整短答 `好的。`、`是的。` 的末词 `的` 均被标为同一 `Particle`，无法区分悬空定语与完整应答；列表引导语 `…有的说。` 末词 `说` 标为 `Verb`，专名同位语 `…的PS5。` 末词 `5` 与完整句 `走吧。`/`行了。`/`看过了。` 均标为 `OtherWord`。
    - **冷热耗时与内存增量（单 Actor 串行复用实例）**：冷启动 `0.99~1.44 ms`，热态 `P50 = 0.365 ms`、`P95 = 1.657 ms`、`Max = 2.724~3.425 ms`，首次加载词性资产后进程 RSS 增加约 `+3.3 MB`（`3,392~3,408 KB`）。
    - **结论**：`NLTagger` 在日/韩/繁中下缺失 `.lexicalClass`，在简中下无法区分悬空 `的` 与句末语气/应答 `的` 且无法识别 `有的说`/`PS5` 等高频口语断口，同时引入约 `3.3 MB` 常驻内存与 `1.66 ms` P95 耗时；按 §4.4“无收益则保留规则方案”，不接入默认生产路径。
- [x] 若证据支持接入，先补充本计划中的执行域、缓存容量、取消身份和测试文件清单，再评审接入；此时不得直接将 `.particle` 当强合并证据。（实测无净收益，保持规则方案，不进入生产路径）
- [x] 实际质量/性能测量须另获明确授权，沿用项目基准规则；主方案不以该项通过为完成条件。

## 6. 验收分层与发布条件

### 6.1 Review Focus

1. **旧 item / 错坐标 / future 水位**：不能污染新段或通过负 age 校验；由 T1 反例固定。
2. **标点被撤回及恢复说话**：不能沿用旧提示，仍需真实 VAD 停顿；由 T1/T2 覆盖。
3. **短词碰撞与正常短回答**：不能因 `也/但/的/了` 将独立句强绑；由 T3 正反例成对覆盖。
4. **计时器先封口与迟到翻译**：合并评分不保证段落仍开放；由 T3 生命周期回归覆盖。
5. **软预算反向切碎与长单行漏字**：连续性允许软超限，硬边界仍有效；由 T4 覆盖。

### 6.2 最小确定性检查

后续实施至少完成 T1–T4 定向回归及相关 lint/type check；新增 Swift 文件时同步 SwiftPM/Xcode target 并运行 `uv run --no-sync python scripts/check_macos_test_target_coverage.py`。仅修改既有文件也需核对所在 target。差异检查使用 `git diff --check`；当前未跟踪文档须另检查内容，不能被该命令漏掉。

不将 `scripts/ci_local_gate.sh --fast --base-ref origin/main` 列为本任务默认验收：它会扩大到多类检查，部分步骤可能构建。完整 gate、真实 worker、App 构建、安装与运行态验收按后续明确授权执行；产出 `.app` 时只用仓库包装脚本。

### 6.3 真实效果验证（尚未执行）

只有获得明确质量/性能验收授权后，才固定基线/候选、输入 manifest/hash、模型与预热状态作配对比较；开发调参材料与独立留出材料分开。原始音频、完整转写和 trace 放仓库外，报告只保留匿名统计与必要的合成反例。

- 样本按快语速中文解说、正常独立短句、成对复句、中英混排、英文缩写/数字、背景音及弱语音分层；同时纳入单条长 final 与长时间无气口。
- 人工标注可接受/不可接受切点与应分开/应合并关系，报告误切率、误合并率、样本量和逐场差异；没有标注时不伪造精度。
- 分开记录首个非空预览、音频停顿到 segment close、final 到达、App 原文出现、段落收口和译文完成。`sample_watermark` 不是字词显示时间；没有 UI 时钟就不能宣称端到端显示 P95。
- 报告提示有效/过期/未覆盖最新语音的比例、段长分布、软预算超限比例及原因、硬 rollover 比例。误切减少但误合并增加必须一起呈现。
- 开发阶段准入要求：定稿非标点内容和有效样本区间不丢不重；独立短句与跨说话人反例零新增错误；标注语料中的目标误切下降、误合并数量不增加。任何条件不满足则不进入安装发布；统计结果只适用于所测材料。
- 4/8 帧配置仅允许在相关有效提示和 VAD 停顿同时成立时起效；首字与译文延迟的实测 P50/P95、样本量及相对基线变化必须报告。在配对基线和允许退化范围冻结前，不宣布质量门通过，也不凭感觉继续扩大 14s/28s 上限。

真实最小窗口、双语长文本、滚动、焦点和 Escape 验证须由当前用户消息单独明确授权，并先说明占用窗口与时长。源码、离屏尺寸和构建不能替代真实交互；这项未完成时不得报告视觉验收通过。

## 7. 风险、回退与交付记录

- **严格时序校验使快切命中率下降：** 保留原无提示停顿路径和硬预算，不以伪造水位换命中率；先看配对结果再判断方案收益。
- **分句阈值变长增加 final 延迟：** 4→8 帧的理论差为 128ms，仅指符合条件时的 VAD 累计帧差，不等于端到端延迟增量上界；排队、模型和客户端等待单列观测。
- **共享场景受影响：** 服务端分句门控同样影响满足启用条件的会议、助手和提词器。T2 必须验证 task 中立性；真实验收还需各场景的短停顿反例，任一出现退化都不能只凭字幕收益发布共享内核。
- **关联规则与预算相互抵消：** 共享证据、明确优先级，记录超限原因；不为追求 38 字破坏悬空短语，也不承诺绝不超限。
- **默认翻译粒度改变：** 新分组可能改变请求次数和上下文；测试结果、真实质量和费用/吞吐影响分别报告，不用算法单测替代翻译质量结论。
- **回退：** 代码交付按 T1/T2、T3、T4 分逻辑主题保存差异；未经授权不自动提交。未发布时撤销本任务对应补丁即可，保留其他改动；已安装时按 release skill 恢复上一服务/App 制品，不覆盖 SQLite、模型或私有配置。现有 Preset 没有本计划新增参数，不能声称已可通过预设热切换。

本次调研交付状态：已核对源码和官方资料，已完善计划；T1–T5、确定性回归、真实语料、性能、UI、安装及运行态变更均未执行。当前文件原为未跟踪文档，保留其 Git 状态，不自动暂存。
