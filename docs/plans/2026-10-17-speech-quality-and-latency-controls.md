---
title: "语音质量与延迟可控性：方案设计"
status: active
version: "1.3.0"
date: 2026-10-17
audience: "后端与 macOS App 核心开发者、产品决策者"
---

# 语音质量与延迟可控性：方案设计

本方案设计三项能力与一项测量：**P1 文本规范化（TN）**、**P2 ASR 重复坍缩**、**P4 延迟指标外露**、**P3 分块边界质量（先测量后决策）**。来源是三方交叉分析（[VoiceStudio 代码级复核](../audits/2026-10-17-voicestudio-capability-reaudit.md)、[ElevenLabs 吸收方案](../audits/2026-10-17-speechrail-elevenlabs-absorption-plan.md)）中两家竞品同时投入的方向。

## 0. 定位前提（决定设计取向）

SpeechRail 是**本地优先的语音创作与会话工作站**，不是纯协议层：一套本机引擎同时支撑创作与会话，并把这套能力以 OpenAI 兼容协议对外开放。

功能面以 `macos/SpeechRailApp/SpeechRailApp/AppRoute.swift` 为准（15 个页面，快捷键 `⌘1`–`⌘0`）：

| 组 | 页面 | 实质 |
|---|---|---|
| 创作 | 配音台（`dubbing`） | 文稿 → 语音，含历史作品与返修；**不做视频与对口型** |
| 创作 | 音色设计 / 克隆 / 音色库 | 描述生成、参考音频复刻、可复用音色管理 |
| 创作 | 有声书 | **导入 TXT 电子书** → 全书人物分析 → 配声确认 → 逐章制作 → 收听 → 导出（M4B / 分章 MP3） |
| 会话 | 语音助手 | 实时对话，原始音频不留存 |
| 会话 | 会议 | 实时转写、说话人标注、纪要生成、本机知识库与记录库 |
| 会话 | 实时字幕 | 屏幕字幕带 + 记录库回看/搜索/导出 |
| 会话 | AI 提词器 | 独立舞台窗口，按讲话进度自动跟读 |
| 引擎 | 总览 / 运行监控 / 模型组合 / 诊断 / 开发者文档 | 服务状态、5 分钟实时 + 30 天历史、识别×配音组合、可照做的修复动作、接入文档 |

由此得到三条判断：

- **与 VoiceStudio 是同品类竞争**（桌面端内容生产工具），不是"运行时 vs 套件"。差异在**功能重心**而非品类：它偏视频配音、翻译、字幕对齐与多引擎选择；我们偏**原生 macOS 的会话场景**（会议纪要、实时字幕、提词器跟读）与**引擎透明**（模型组合、诊断、监控都是产品页面）。
- **电子书目前只支持 TXT**（`AudiobookTXTImporter`），没有 EPUB。这是产品能力边界，不是本方案的实现范围，但会直接影响"电子书"这条卖点的说服力——见 §8。
- **差异化不在功能数量，而在一个引擎同时服务批量生产与会话**：同一套 ASR/TTS 被配音台、有声书、会议、字幕、提词器共享，不重复加载模型、不出本机、无账号与额度。

关键推论：**批量场景会掩盖低级错误，会话场景藏不住。** 一本书里念错三个数字，用户未必发现；字幕里数字念错、静音处冒出循环文本、首字晚半秒，用户当场感知。本方案因此优先修"会话暴露、批量同样受益"的问题。

### 0.1 四项工作对功能面的影响

| | 配音台 | 有声书 | 助手 | 会议 | 字幕 | 提词器 |
|---|---|---|---|---|---|---|
| P1 TN | 直接 | 直接 | 直接 | — | — | — |
| P2 坍缩 | — | — | 直接 | 直接 | 直接 | 直接 |
| P3 分块边界 | 长文 | — | 直接 | — | — | — |
| P4 延迟指标 | — | — | 直接 | — | 直接 | 直接 |

P1 影响三条创作路径，P2 影响四条会话路径——这也是两者排在最前的原因。提词器同时受 P2（跟读用的 ASR 文本）与 P4（跟读延迟）影响，是唯一被两项覆盖的页面。


## 1. 设计原则

1. **改写必须可审计**：任何对用户文本的改写都要能回答"原文第几字节变成了什么"。ElevenLabs 同时返回 `Alignment` 与 `NormalizedAlignment` 印证了这条在商用产品里可行。
2. **默认不改变既有输出**：TN 与坍缩都必须可关闭，且关闭时行为与现在逐字节一致。
3. **失败要显式**：宁可"没转"（保持原文），不可"转错"（改变语义）。VoiceStudio 的 TN 也是这条原则。
4. **先测再改**：没有基线数字就不上实现。

## 2. P1：TTS 文本规范化

### 2.1 现状与真正的难点

现有 `normalize_tts_text`（`src/speechrail/domain/tts.py:252-256`）只剥 Markdown 与 emoji，不处理数字、时刻、缩写。

难点不在"把 `3:30` 换成 `three thirty`"，而在**坐标**：

- `prepare_render`（`src/speechrail/application/render_preparation.py:64`）先经发音集得到 `spoken.text`，再用 `_timing_plan`（同文件 `:39-61`）判断显示映射状态；
- 该函数在"规范化改变了显示坐标且没有发音集"时，返回 `unavailable` + `normalization_changed_display_coordinates`；
- `display_mapping_status` 会被带进时间轴输出（`src/speechrail/application/tts_timings.py:21,178`、`http/routes/audio.py:1819`）。

**所以：如果 TN 只替换文本而不产出映射，依赖显示坐标的 TTS 播放路径（配音台试听与返修的文本定位、复用同一映射的其它 TTS 回放）会直接降级为 `unavailable`。** 这是本项设计的核心约束，不是实现细节。

### 2.2 方案

新增纯函数模块 `src/speechrail/domain/tts_text_normalization.py`：

```
normalize_for_speech(text: str, *, language: str) -> NormalizedText
    .text        # 展开后的文本
    .spans       # tuple[NormalizationSpan(raw_start, raw_end, out_start, out_end, rule)]
    .rule_counts # dict[str, int] 供观测与回执
```

规则集按**保守优先**排序，首版只做四类（都能用确定性规则判定）：

| 规则 | 例 | 反例（保持原样） |
|---|---|---|
| 时刻 | `3:30` → `三点半` / `three thirty` | `1:2:3`（时间码，判定不明） |
| 数字 | `2026` → 按语言读法展开 | 千分位与小数混用、编号 `A-12` |
| 称谓缩写 | `Dr.` → `Doctor` | 句末 `Dr.`（可能是句号） |
| 符号 | `&` → `and`/`和` | 数学/编程上下文 |

每类规则必须能**只增不改**地关闭；未知语言走"不展开"而不是猜。

### 2.3 与发音集的组合顺序

顺序固定为 **TN → 发音集**，理由：用户在词典里写的 surface 通常是"已经展开后的词"（`three thirty` 而不是 `3:30`）。组合时把发音集的 `SpokenText.spans` 与 TN 的 `spans` 复合，得到一条 raw→final 的完整链；任一环节缺失映射，整体降级为 `unavailable`（保持现有语义，不假装映射成功）。

### 2.4 契约影响

- `/v1/audio/speech` 与 Realtime TTS：新增可选请求字段 `text_normalization: "off" | "safe"`，默认 `off`（**默认不改变现有行为**）。
- 时间轴输出：`display_mapping_status` 允许在开启 TN 后仍为 `mapped`；`mapping_reason` 新增 `normalization_spans` 枚举值。
- 回执：`rule_counts` 进回执摘要（只计数，不含原文），沿用现有"不记录完整 prompt/转写"的红线。

### 2.5 验收

1. 关闭 TN 时，输出与当前逐字节一致（回归基线）。
2. 开启后，`display_mapping_status` 不得从 `identity`/`mapped` 降为 `unavailable`。
3. 每条规则的"反例"必须保持原文，且计入 `rule_counts` 的 `skipped`。
4. 单元测试覆盖：时刻/数字/缩写/符号四类正例与反例，中英各一组。
5. 端到端：同一段文本在开启前后合成，时间戳数量与顺序不变。

## 3. P2：ASR 重复坍缩

### 3.1 方案

新增 `src/speechrail/domain/transcript_cleanup.py`，纯函数：

```
collapse_repetitions(text: str, *, min_run: int = 6) -> CollapseResult
    .text            # 坍缩后文本
    .collapsed_runs  # 被合并的连续重复段数
    .collapsed_chars # 减少的字符数
```

两遍扫描（与 VoiceStudio 同构，但阈值与语义由我们定义）：

1. **词级**：同一 token（去标点、小写后比较）连续出现 ≥ `min_run` 次；
2. **字符级**：2–60 字符的子串紧邻自身重复 ≥ `min_run` 次，覆盖多词循环与不分词文字。

阈值取 6：修辞性重复（"不不不不不"五次）保留，识别故障（循环二十遍）合并。

### 3.2 插入点

在 `TranscriptResult`（`src/speechrail/domain/contracts.py:71`）构造前，对 final 文本应用；partial 不处理（partial 本来就会被替换）。新增字段：

- `TranscriptResult.repetition_collapsed: int = 0`
- Realtime final 事件携带同名字段

**只对 final 生效、只报告计数、默认开启**——理由：循环文本没有任何合法用途，而"默认关闭"等于把已知缺陷留给所有调用方。这一点与 TN 相反，TN 会改变语义，坍缩只删除明显故障。

### 3.3 验收

1. 五次以内的重复原样保留；六次及以上合并为一次。
2. 中英文、无空格文字均覆盖；不跨段落合并。
3. 坍缩计数出现在回执与 Realtime final 中，且不包含原文。
4. 关闭开关存在，关闭后行为与当前一致。

### 3.4 落地修正

设计与实现有四处偏差，都是实现过程中被真实用例逼出来的，记录下来以免后续误读：

1. **插入点从"构造前"改成"端口边界"**：坍缩放在 `Qwen3BatchTranscriber`（`transcribe` / `transcribe_stream`）而不是每处 `TranscriptResult(...)` 构造点。REST、任务、MCP、本地文件处理共用同一出口，放在端口上才能保证"每个调用方看到同一份干净转写"；放在构造点则需要每处记得调用。
2. **段落内不再按标点切分**：`\n\n` 是唯一的段落边界。按标点切会把"句内重复"和"句间重复"区分开，但识别故障的循环经常正好跨越标点（"好的。好的。好的。"），切分会漏掉最常见的形态。
3. **尾部的残缺副本计入 run**：回路几乎总是在音频结束处被截断，最后一份副本常常是半个单元。不承认它是 run 的成员，恰好漏掉最该被删掉的乱码尾巴。
4. **`min_run=2` 被显式拒绝**：2 意味着"任何双词重复都被合并"，而正常口语里"that that"是修正语。参数下界为 2（`Field(ge=2)`），`collapse_repetitions(min_run=1)` 抛 `ValueError`。

另外，回执（HTTP `/v1/audio/transcriptions`）目前只计数进 `TranscriptResult.repetition_collapsed`，**尚未**出现在响应体字段里——realtime final 事件已经携带，REST 侧是否需要外露待与前端一起定。

## 4. P4：延迟指标外露

现状：`speechrail_tts_ttfa_seconds` 直方图与 ASR `rtf` 已在 `src/speechrail/observability/metrics.py:36,522,557` 定义，但**只在服务端**，调用方看不到；更糟的是 `record_ttfa` 在 `src/speechrail/` 内**没有任何调用点**——直方图定义了一个从未被写入的序列。

方案：把每次 utterance 的 `ttfa_ms`、`rtf`、`audio_ms` 放进 `speechrail.tts.completed`（`src/speechrail/application/realtime_tts.py` 的终态构造处），`/v1/audio/speech` 以响应头返回同名字段。字段命名、取整与单位统一收敛在 `src/speechrail/observability/latency.py`，HTTP 与 Realtime 两条路径共用同一个构造函数。

约束：

- 指标是**观测值**，不得参与准入或质量判定；
- 关闭时不产生额外计时开销（用已存在的计时点，不新增 `perf_counter` 调用链）；
- 字段命名与既有 metrics 名一致，避免两套词汇。

### 4.1 落地时对原方案的两处修正

原方案说“`/v1/audio/speech` 以响应头返回同名字段”，落地时发现这条对**流式**响应不可能成立：响应头在第一个字节之前就要发出，而 `audio_ms` 与 `rtf` 要等最后一个 chunk 才知道。于是按“宁可缺席，不可猜”拆开：

| 响应形态 | `ttfa_ms` | `audio_ms` / `rtf` |
|---|---|---|
| 流式（`pcm`、`mp3`/`opus`/`aac`/`flac`） | 响应头 | 不发布 |
| 整段缓冲（`wav`） | 响应头 | 响应头 |

这不是能力缩水，而是**把“何时可知”写进契约**：调用方看到缺头就知道“这次没测到”，不会误读成 0。Realtime 路径没有这个限制——终态事件发生在合成结束之后，三项齐全。

第二处修正：约束里的“关闭时不产生额外计时开销”没有做成开关。实际成本是每个 utterance **两次** `time.monotonic()`（`start` 时一次、首段音频一次），相对于数百毫秒的合成量级可以忽略；加一个配置开关换来的分支复杂度高于它节省的开销。若将来确需关闭，关掉的是“是否发布字段”，wire format 不变。

### 4.2 计时点选择

`ttfa` 的起点是 `RenderOperation.start_delivery()`（`src/speechrail/application/render_operation.py`），终点是 `pcm()` 生成器**首次 yield** 之前。把终点放在生成器内部而不是 `deliver()` 里，是因为三条交付路径（流式、容器编码、整段缓冲）都会消费同一个生成器，放在内部才能让三条路径共享同一个计时点，而不是各写一份。

`rtf` 在两个路径上都是**墙钟时间 / 音频时长**，不是纯推理时间：Realtime 路径包含等待调用方消费窗口的时间，HTTP 路径包含编码时间。这是调用方真正体验到的比值，但它只是模型速度的**下界**，契约里已明确写明，避免被当成模型基准。

### 4.3 未纳入字段责任表

`contracts/realtime-field-matrix.json` 要求每条字段在一个 positive fixture 里**实际存在**，而这些字段是可选且依赖运行时测量结果的。因此三者只进 schema 的 `properties`，不进责任表；这是有意选择，不是遗漏。

## 5. P3：分块边界质量（先测量，不先实现）

两家竞品对同一个问题给了两种解法：ElevenLabs 用 `chunk_length_schedule`（默认 `[120,160,250,290]` 字符，缓冲越多音质越好、延迟越高），VoiceStudio 用交叉淡化拼接。我们两样都没有。受影响的是两条路径：**配音台的长文合成**（一次性交付，接缝处易听出断裂）与**语音助手的流式播报**（逐句追加，接缝密度最高）。

**但先证明问题存在。** 测量设计：

1. 取 5 段真实文本（含中英、含标点与数字），每段分别按 8/16/32/64 字切分；
2. 每种切分合成后，检查接缝处：静音间隙长度分布、相邻块首尾基频跳变、能量阶跃；
3. 与"整段一次合成"的同一文本对比，量化差异；
4. 若接缝处三项指标与整段合成无显著差异 → **P3 关闭，不改协议**；若显著 → 再在"缓冲调度"与"交叉淡化"之间选，前者改语义、后者改音频。

测量脚本放 `tools/`，不进入产品路径，不加载新模型。

## 6. 契约与兼容

- 新增字段均为可选且有默认值；关闭时与现状一致。
- 不保留旧字段别名；不引入 `/v2`。
- 同步更新 `docs/users/api-contract.md`、`contracts/realtime-openai.md`、`contracts/realtime-events.schema.json` 与共享 fixtures。

## 7. 落地顺序与回退

1. **P4**（最小、纯增益，先落地验证回执链路）→ 2. **P2**（独立模块，无坐标问题）→ 3. **P1**（涉及映射复合，风险最高）→ 4. **P3 测量**（只读）。

**进度**：P4 已落地（见 §4.1–§4.3）。改动面：新增 `src/speechrail/observability/latency.py`；`render_operation.py` 记录计时点并补上从未被调用的 `record_ttfa`；`realtime_tts.py` + `openai_realtime.py` 在终态携带观测值；`routes/audio.py` 三条响应路径按“何时可知”发布响应头；`realtime-events.schema.json` 增加三个可选属性。回退只需撤销这三处 header/字段，wire 上没有旧别名要清理。

**进度**：P2 已落地（见 §3.1–§3.4）。改动面：新增 `src/speechrail/domain/transcript_cleanup.py`（纯函数，两遍扫描：词级 + 子串级）；`TranscriptResult.repetition_collapsed` 计数；坍缩发生在 `Qwen3BatchTranscriber` 的端口边界（REST、任务、MCP、本地文件处理共用同一出口），以及 realtime 的 final 构造处；`Settings.asr_repetition_collapse_enabled` / `asr_repetition_collapse_min_run` 提供开关与阈值。回退只需关开关，wire 字段保持可选，不清理旧别名。

每步单独提交、单独可回退；P1 的开关默认关闭，回退只需关开关而不必回滚代码。

## 8. 风险与未决

- **P1 的语言覆盖**：中文数字与量词组合（"第 3 章第 12 页"）规则量远大于英文，首版可能只覆盖安全子集，需明确"不展开"的边界并写进契约。
- **P1 与发音集的顺序**已定为 TN 先，但若用户词典里写了 `3:30`，将不再命中；需在文档中显式说明，或提供"词典优先"的开关（成本更高，暂不做）。
- **P2 的阈值** 6 是启发式，需用真实会议素材验证误伤率，未验证前不得对外宣称"消除循环"。
- **P3 的结论依赖测量**，本方案不预设结论。
- **电子书格式（产品决策，不在本方案范围）**：有声书当前只接受 TXT（`AudiobookTXTImporter`），EPUB 与带图排版的书不支持。VoiceStudio 侧同样以文本为主，但它把"电子书"作为卖点更早、入口更显眼。是否支持 EPUB 影响的是产品承诺，而不是语音质量，因此单列待决，不与 P1–P4 混做。
- **配音台的边界**：我们做"文稿→语音"，不做视频与对口型；VoiceStudio 的配音是视频级。这是有意取舍，但文案与帮助文档不应暗示我们能处理视频。

## 9. 本次审查修正了什么

v1.0.0 的定位段写于功能面核对之前，存在三处不准确，已在本版修正：

1. **漏掉了配音台**：原表述把创作组概括为"配音台、音色设计、音色库、有声书"，却在下游结论里把配音列为"不做"，前后矛盾。实际配音台是独立页面（`⌘1`），有历史作品与返修。
2. **夸大了显示映射的受益面**：原文写"字幕高亮、提词器跟读会降级"，但字幕与提词器走 ASR 时间轴，与 TTS 的 `display_mapping` 无关；真正受影响的是配音台试听/返修的文本定位。
3. **电子书被写成既有能力而未标注边界**：当前只有 TXT 导入，没有 EPUB；写"我们也有电子书"而不说格式，会在对比里失分。

同时补了 §0.1 的影响矩阵，把"为什么 P1/P2 排前面"从直觉改成可核对的覆盖关系。
