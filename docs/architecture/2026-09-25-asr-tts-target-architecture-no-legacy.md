---
title: "SpeechRail ASR + TTS 目标架构定稿（无历史兼容）"
status: accepted
audience: "系统架构师、核心开发者、验收人员"
version: "1.0"
date: 2026-09-25
---

# SpeechRail ASR + TTS 目标架构定稿

日期：2026-09-25
产品阶段：快速迭代研发期
分析起点：hrygo/SpeechRail，PR #94，固定快照 `4c7d37eecb1b55025efc003cae92b3feaf238e14`
状态：已确认的目标架构；实现与真实性能验收按 [Issue #95](https://github.com/hrygo/SpeechRail/issues/95) 跟踪，本文不是完成报告
入库范围：方案正文和架构目录；不修改实现、公共契约、运行配置或模型安装态。

## 1. 设计立场

PR94 是可复用的工程起点，不是不可改变的架构约束。以本地 Apple Silicon 语音服务的职责正确性、交互质量、声音一致性、资源效率和可验证性为目标。

本方案替代上一版方案中的旧档位映射、配置迁移、兼容事件、双版本解析和临时过渡实现。没有老用户兼容工程，没有为了保持旧名称或测试而保留错误语义。

保留的是研发正确性要求：音色资产有版本、制品可追溯、安装可恢复、测试能证明行为。不考虑向后兼容不意味着可以静默删除本机素材，也不意味着可以省略质量验证。本文冻结目标；实现、模型操作和验收的授权仍按具体任务确定。

### 决策冻结

| 决策 | 目标 |
|---|---|
| 模型精度 | ASR/TTS 正式规格只使用 Q8 与 BF16；不使用 Q4，不新增 Q6 |
| ASR | 0.6B Q8、1.7B Q8、1.7B BF16 |
| 日常 TTS | Base 与 CustomVoice 分别执行固定自定义声音与内置说话人 |
| 音色设计 | 仅 1.7B VoiceDesign BF16，设计专用 |
| 对齐 | 独立能力 owner，Qwen3-ForcedAligner-0.6B Q8/BF16 |
| 分人 | 会话内匿名归属，CoreML Sortformer FP16；容量如实公开 |
| 交互 | 流式优先、有界状态、显式取消、唯一终态 |
| 实现形态 | 一个本地服务与统一资源治理，不采用微服务化或每请求复制模型 |
| 演进策略 | 当前契约直接切换，旧接口/字段/模式直接移除，不建立兼容桥 |

## 2. 规格、任务与能力分开

### 2.1 三档规格

TTS 全部采用 Qwen3-TTS-12Hz 系列。一次请求只运行与声音类型对应的一个 TTS 模型。

| 档位 | ASR | 固定自定义音色 | 内置说话人 |
|---|---|---|---|
| 轻快 `fast` | Qwen3-ASR 0.6B Q8 | TTS 0.6B Base Q8 | TTS 0.6B CustomVoice Q8 |
| 品质 `quality` | Qwen3-ASR 1.7B Q8 | TTS 1.7B Base Q8 | TTS 1.7B CustomVoice Q8 |
| 参考精度 `reference` | Qwen3-ASR 1.7B BF16 | TTS 1.7B Base BF16 | TTS 1.7B CustomVoice BF16 |

默认目标为 quality。reference 是精度基线和制作配置，不代表已经证明音质更好或首声更快。是否能实时运行由设备、引擎与完整组合测试决定。

ASR 与 TTS 两个规格独立保存。三个 UI 预设只是同时填写两项规格的快捷方式，不持久化一个可能与两项实际配置冲突的第三份 preset 真相。

`ASR quality + TTS fast` 是有价值的资源组合：选择它的理由是识别与合成负载不同，而不是保留旧 balanced 行为。首批认证三个同档组合及这一混合组合，其他组合按需要增加证据，不机械铺满全部排列。

`auto` 是显式启用的选档策略，不是第四档。它不能改变声音类型、丢弃请求能力或在会话中途更换模型。

### 2.2 按需辅助模块

| 能力 | 模型/实现 | 默认行为 |
|---|---|---|
| 服务端语音活动检测 | 固定版本 Silero ONNX | 仅在服务端自动断句模式启用 |
| 普通时间轴 | ForcedAligner 0.6B Q8 | 请求对齐时加载，独立于 ASR 档位 |
| 参考精度时间轴 | ForcedAligner 0.6B BF16 | 制作或精度对照任务显式选择 |
| 说话人归属 | 固定 CoreML Sortformer FP16 | 会话 opt-in，不与高档位捆绑 |
| 音色工作室 | VoiceDesign 1.7B BF16 | 进入设计作业才加载 |

12 个 Qwen 顶层制品 = 3 ASR + 6 运行 TTS + 1 VoiceDesign + 2 ForcedAligner。VAD、CoreML 分人及 tokenizer/codec 是另外登记的依赖。制品数量不是常驻模型数量。

### 2.3 任务模式

- `conversation`：流式识别和增量合成，优先交互延迟、打断与连续播放。
- `caption`：连续可修订文本；按请求补充时间轴及匿名说话人。
- `transcription`：已有音频的准确转写与可选对齐，不与实时 ASR 抢占同一 owner。
- `render`：已有文本的内容制作，固定渲染配置，优先连贯与可追溯。
- `voice_design`：候选生成、参考确认、Base 复验和注册。

任务模式定义工作流程；规格定义模型资源；辅助选项定义输出要求。不能继续用一个 profile 包办三者。

## 3. 模块化单体与能力 owner

### 3.1 责任划分

| 层 | 负责 | 不负责 |
|---|---|---|
| macOS App/其他调用方 | 麦克风、AEC、播放、LLM、文字稳定化、打断决策和业务数据 | 模型推理与运行服务复制 |
| 协议边界 | 当前 OpenAI 语音子集及 SpeechRail 扩展、格式校验、事件映射 | 推理业务、声音身份选择的隐式变换 |
| 应用编排 | TaskRequest 解析、ResolvedPlan、任务状态、取消、最终结果 | 上游库默认行为透传 |
| 能力 owner | ASR、Base、CustomVoice、Alignment、Diarization、VoiceDesign | 跨角色越权加载模型 |
| Runtime/Artifact 管理 | 权重加载与释放、缓存、制品校验、资源准入、故障恢复 | 用户对话记忆或通用 Agent 框架 |

一个 SpeechRail 服务、一个 ASGI worker；重模型使用受控 worker。每个实际已加载模型只有一个明确 owner。Base、CustomVoice、ASR 等角色可以有不同的按需 worker，但不能按用户、声音或请求复制相同权重。

VAD 等轻量组件无需为了架构对称另开重进程。Alignment 直接具备独立 owner 与生命周期，不先隐藏在 ASR 内形成临时实现；独立 owner 不等于可以未经准入同时计算。

### 3.2 三种核心数据对象

**ModelSpec**：模型角色、模型族、规模、权重/计算精度、引擎能力、语言、制品来源、hash、tokenizer/codec 依赖。

**TaskRequest**：任务、输入、所需输出、声音版本、性能或质量意图、是否允许自动选档、对齐/分人要求。

**ResolvedPlan**：执行前解析得到的不可变计划，包含全部实际制品与引擎版本、资源预约、格式、限制与配置摘要。

一次任务只使用一个冻结计划。不能在 worker 内另读一个全局 profile，导致 API 显示的规格和真实执行不一致。

`capability = 模型能力 ∩ 引擎实现 ∩ 输入/语言/音色兼容 ∩ 已验证支持范围`。installed、ready、busy 是另外的运行状态，不与 supported 混成一个布尔值。

## 4. ASR 目标实现

### 4.1 识别只有一个主链路

同一已选模型处理离线或流式识别，不部署一套小模型实时识别，再默认由大模型重跑整段来掩盖流式问题。

实时话轮由同一会话 finish/flush 确认 final。显式离线精修是另一项作业，产生新的结果版本，不能覆盖已经发出的实时 final。

批量 ASR 与流式 ASR 在同一 owner 上互斥。实时会话占用时，批量任务由显式作业队列等待，或按直接调用契约返回 backend_busy，不复制模型规避约束。

### 4.2 默认流式策略

目标默认采用 1000 ms 识别分块；500 ms 是低延迟候选，2000 ms 用于吞吐与文本稳定性对照。它们属于任务执行策略，不是三个模型档位。

默认值必须通过内容质量和负载验证才随新版本发布；不为保持旧行为而固定原来的 2000 ms。若目标不达标，应依据实验修改目标，而不是建立兼容回退。

移除仅存在于名字中的 causal/windowed 选择，以及没有对应引擎行为的 right-context 旋钮。支持什么参数由实际 adapter 明确映射并通过可观察行为测试。

不要向用户承诺“分块 1 秒就是 1 秒出字”。采集积累、推理、稳定化、端点检测和 UI 呈现分别测量。

### 4.3 文本与时间轴

内部只使用一套转写事实：可修订 hypothesis + revision，以及每个 utterance 的唯一 final。

UI 可以显示最新 hypothesis；只有已经确认的前缀才可作为追加流对外提供。不能将可能被改写的文本伪装成永久 append-only delta。

所有文本结果带 utterance identity 和对应音频区间。最终文本之后的 alignment/diarization 是附加结果，不是第二次识别。人工修改或显式重新识别产生新 transcript revision。

输入格式在边界显式协商，ASR 内核归一化为所需的 16 kHz 单声道格式。以采样点和有理数转换建立时间映射，保留重采样延迟与原始时间轴关系，不用独立累加浮点时长拼长会议。

长期识别采用有界音频环形缓冲和有限上下文。达到缓存或会话上限时显式分段/结束/报错，不能静默丢帧，也不能无限保存 PCM。

### 4.4 VAD 与提交权

每个话轮只选择一个提交责任方：调用方 manual commit，或服务端 VAD endpoint。服务端检测到 speech_stopped 不自动代表必须取消 TTS；应用策略由调用方决定。

VAD 状态会话隔离。噪声与静音误识别、尾字截断、连续长发言、数字专名及语言混合均进入验收。

### 4.5 精度与依赖

显式传入 dtype 并读回实际加载身份；分别记录权重量化、非量化张量类型、计算配置和 codec 精度。合理 FP32 累加不构成 BF16 身份错误。

禁止请求时通过默认模型名触发隐式网络访问或对齐器实例化。所有制品在任务准备阶段确定并校验。

## 5. Alignment 与 Diarization

### 5.1 独立固定文本对齐

输入是确定的 transcript revision + 精确 PCM 区间；输出是带文本 span 的时间轴，不重新进行 ASR。

从目标接口直接支持 segment 与 word/character 对齐能力，不因为 PR94 原来只允许 segment 而永久限制。实时场景的细粒度对齐在文本片段确认后异步补充，不承诺未稳定的每个字都有最终时间戳。

中文字符与英文词的粒度含义、Unicode span 计数及 Swift 转换必须写入契约。语言能力取实际模型交集；不能声称所有 ASR 语言都能对齐。

text_final、alignment_done/failed、diarization_done/failed 分别完成。纯识别不等待对齐；请求完整时间轴的作业若对齐失败不能静默返回空数组并声称全部成功。

### 5.2 会话匿名分人

使用固定的 CoreML Sortformer FP16 低延迟模型作为目标后端，理由是 Apple Silicon 原生执行和明确的流式接口，不是为保留旧代码。

该系列模型输出有四个说话人槽位；目标产品必须公开容量范围，不宣称任意人数。也不能宣称一定可靠检测到第五个说话人；只对可以判断的容量、unknown 和 overlap 状态给出诚实表示。

分人只输出会话内匿名活动和归属，不建立实名/跨会话声纹库。speaker attribution 是版本化元数据，不改写 ASR final。

文本不等待说话人归属。两者通过统一音频时间轴关联；归属未就绪时允许 unknown。

## 6. TTS 与音色设计

### 6.1 唯一声音路由

| 声音/任务 | 路线 |
|---|---|
| 内置固定 speaker | CustomVoice |
| 真人参考注册的声音 | Base |
| VoiceDesign 设计并发布的声音 | Base |
| 声音设计/设计试听 | VoiceDesign 1.7B BF16 |

同一声音在普通朗读、实时对话和文件制作中共享身份条件，不因接口和质量档位变成另一种声音。

VoiceDesign 不提供运行时直出、不按每句话重新生成参考、不在 Base 失败时回退。工作室产生的是候选资产，不是尚未确认的生产声音。

1.7B CustomVoice 的风格指令与 Base/0.6B CustomVoice 的能力不同。所需表达控制不被支持时明确拒绝，不静默忽略，不因升到 BF16 就宣称新增能力。

### 6.2 音色资产是运行时资源，而不是历史兼容负担

标准流程：描述 → BF16 Design 候选 → 参考确认 → Base 用新文本复验 → 发布 voice revision。

只有 Base 复验通过才能承诺该声音可用于相应规格与模式。参考时长依据内容和引擎验证确定，不把探针中的约 2.4 秒案例硬编码为模型上限。

永久保存原始参考及正确文本和来源记录。克隆 prompt、speaker embedding、语音 token 和预处理结果是可重建缓存，按模型/精度/引擎/预处理版本隔离。

音色版本用于新项目的重现、比较和回归，不是为了兼容老用户。项目固定 voice revision 与渲染计划后，不被全局默认更新悄悄改变。

### 6.3 真增量 TTS

在一个 utterance 内维持单一身份与生成状态。发送端与接收端独立，文本 sequence 单调，ACK 和窗口背压明确；收到其他音频/状态事件不能误发下一段。

ACK 只表示文本被接受，不表示已生成、更不表示已播放。finish 是输入结束屏障，等待已经接受的文本生成排空；waiting_for_text 不等于完成。

控制消息和终态不应被满音频队列阻塞。取消路径高优先级；每个任务只能认领一个终态，清理幂等。

真增量验收需在足够初始稳定文本下测得 PCM 早于 finish，并验证追加没有重新初始化 utterance。对短文本或长参考造成的预填充差异按实际条件报告，不机械要求每个单字输入都满足同一延迟。

### 6.4 制作模式

已有完整文本时使用完整上下文或合理段落窗口，不强行模拟实时 token 小片输入。声音身份与实时模式一致，但调度、文本窗口、采样配置可以不同并记录在渲染计划中。

长篇以句段边界建立有界窗口和可恢复片段，避免无限 KV 增长；输出按原时间线组装。多角色共享权重，不每角色复制模型。

## 7. 协议：对齐目标生态，不维护自己的旧版本

当前 OpenAI 转写文档使用 session.update 与嵌套 audio.input 结构。PR94 的 transcription_session.update 和旧字段结构不能因为已经实现就成为目标规范。[S4][R2]

对外保留一个当前 OpenAI 语音子集边界，SpeechRail 增量 TTS、hypothesis revision 和元数据功能放入明确命名空间扩展。支持的 SDK 事件和字段通过契约测试验证。不实现完整 LLM 会话、不伪造工具调用或对话记忆。

官方兼容入口按目标协议支持的音频格式校验；例如当前文档展示 24 kHz PCM。内部 ASR 16 kHz 是 adapter 的处理要求，不继续假设外部 wire 固定等于内核采样率。TTS 输出格式在开始事件明确声明。[S4]

内部使用 typed domain events，不导入 OpenAI SDK 对象作为领域模型。对外适配只是边界转换，不是另一套业务状态机。

不保留旧事件 alias、双解析器或双协议版本；App、MCP、测试与文档同批切换。Unsupported 必须明确报错，不接受后无操作。

端点/事件名称在实现前由一份契约源锁定，生成或机械校验 Python/Swift 类型及测试样例；不让各端手写相似但不一致的副本。

## 8. 资源治理与交互

### 8.1 内存和执行预算

统一计入所有已加载权重、codec、idle cache、活动 KV、队列、临时计算和安全余量。使用 total resident + incremental active peak 的口径，避免同一峰值重复计账。

为每个具体模型和任务组合建立资源画像。缺少峰值或线程安全证据时，不承诺并发。资源不足时先回收无关可重建缓存/卸载不活跃模型，然后显式排队或拒绝，而不是换声音或加载未支持模型。

### 8.2 并发与优先级

- 同一 ASR owner 的实时和批量识别互斥。
- ASR + 当前 TTS 在组合级实时验收通过后并发。
- Alignment 与 Diarization 独立 owner，是否并发仍由预算和延迟决定。
- VoiceDesign 与大批制作任务低优先级，不抢占活跃实时会话。
- 不可抢占的内核调用只在安全点让出，不能承诺不存在的瞬时 GPU 抢占。

WebSocket 双向收发不是模型全双工认证。未通过联合实时验收时，明确呈现半双工/串行能力。

### 8.3 打断

调用方负责麦克风/AEC 与 barge-in 判定。决定打断后先停旧播放并提升 playback epoch，再并行发出 LLM/TTS cancel。后端完成终态和资源释放；晚到 PCM 因 task/epoch 不匹配被丢弃。

网络到包余量和真正扬声器停止时间分别测量。声卡/AEC 问题不通过更换 ASR 大小来掩盖。

### 8.4 auto 与切档

默认使用明确 quality 配置。auto 仅在显式启用时作用，先满足语言、声音、风格和任务能力，再在已验证规格中选择资源方案。

ASR 会话期间不热切；TTS utterance 期间不热切；内容制作固定项目渲染计划。切换前验证候选与预算，等待相关 owner 安全退出，原子激活新计划。

选择结果可解释、可记录、有稳定观察窗口，避免每轮随瞬时负载抖动。没有满足能力的低档时排队/拒绝，绝不静默丢指令。

## 9. 制品与推理引擎

### 9.1 唯一制品清单

分发与加载来自同一 ModelSpec/Artifact manifest，不维护 UI、下载器和 worker 三份平行清单。每个制品固定来源 revision、文件集和 SHA256；依赖 tokenizer/codec 显式列出。

Q4、Q6 和 VoiceDesign Q8 不进入清单、配置枚举或自动策略。不虚构 PR94 原本存在 Q4 的删除工作；落实目标允许集合及拒绝测试即可。

网络访问只发生在显式模型准备作业，推理请求不下载、不跟随远程参考音频 URL、不回退云服务。

### 9.2 不把运行时 overlay 作为最终交付方式

若需要维护上游增量扩展，采用固定上游源码 + 仓库内最小补丁/受控维护分支，构建可重建的引擎 wheel，并锁定 wheel hash。

最终安装只解析到一份确定的引擎实现；不通过运行时复制文件进 site-packages、sys.path 阴影覆盖或本机遗失的临时 checkout 提供关键功能。

保留 engine conformance tests，验证文本追加、首音、采样率、参考缓存、饥饿、取消和唯一终态。补丁可向上游提交，但不以等待上游合并阻止本地可复现发布。

保持服务/私有 worker 依赖边界，按必要性使用隔离环境，不强行把不同推理库塞入一个脆弱的环境。Python/MLX/Swift 版本由实际安装、运行和 CI 结果固定，不在方案中编造新版本锁值。

## 10. 测量与验收

### 10.1 先修指标，后宣布性能

PR94 基准的起点命名、单循环 sleep、失败归类、RTF 扣间隔和到包后 headroom 都应按目标语义重写。旧数字不要求保持；它们不是新方案的性能基线承诺。[R3]

客户端记录 send first stable text、receive first playable PCM 和 playback started；服务端记录 admission、model start、waiting、generation、terminal。各端使用单调时钟，跨时钟只在建立映射后相减。

充足文本供给下测端到端 generation RTF；增量场景单独报告供给、饥饿和积压。不要从墙钟时间中盲目扣掉客户端等待：等待期间模型可能仍在工作。

有音频但最终失败的任务仍是失败。失败率与成功分布同时报告，不能把失败作为零延迟，也不能只展示最快完成的任务。

播放余量至少计算新包到达前的 previous cumulative audio - elapsed。真正欠载由播放器验证，不用网络代理值替代。

### 10.2 初始工程目标（均非已测结果）

| 指标 | 初始目标 |
|---|---|
| ASR 最后输入样本/有效 chunk 到 partial | 热态 P95 ≤ 500 ms；另报采集积累 |
| ASR commit 到 text final | 热态 P95 ≤ 500 ms |
| 语音结束到 final | 固定 endpoint 配置下 P95 ≤ 1000 ms |
| TTS 首段稳定文本发送到可播放 PCM | 热态 P95 ≤ 500 ms |
| 充足文本供给下的生成 RTF | P95 ≤ 0.8 |
| 决定打断到旧音停播 | P95 ≤ 200 ms |
| cancel 到任务资源释放 | P95 ≤ 1000 ms |
| 长稳 | 有界内存、缓存和积压，无终态竞争、旧包污染和不可恢复状态 |

这些是目标而非保证。若不达标，组合不能标为实时通过；允许明确支持 reference 的离线制作用途。

### 10.3 质量同样是硬门

ASR：中文 CER、英文 WER、中英混合、数字专名、静音误识别、噪声、长句及窗口尾部。

TTS：内容准确性、声音身份、自然度、韵律、语言、长短句、跨模式和跨档听感；不能仅用声纹得分替代盲听。

Alignment：时间误差、覆盖、文本 span、顺序和越界。Diarization：匿名归属、重叠与 unknown、容量边界。

探索阶段可用至少 30 个独立条件 × 5 次建立数据，但它不是“已证明可靠”的充分条件。正式报告按语言、声音、长度、冷/热态和负载分层，报告分位数算法、置信区间与失败数。对持续可靠性另做长时会话和反复取消测试。

ASR→固定回复测试隔离语音服务开销；真实 LLM 链路另外计入模型延迟和文本稳定窗口。端到端 P95 来自同一轮 trace，不相加各组件 P95。

## 11. 研发实施顺序

| 阶段 | 有意义的工程增量 | 完成判据 |
|---|---|---|
| P0 | ADR、当前契约、核心类型和规格职责冻结 | 没有多余 preset 真相、旧 alias 或不映射的参数 |
| P1 | ModelSpec/Artifact 与 ResolvedPlan/资源治理 | 固定制品、精度校验、角色路由、预算与拒绝语义闭合 |
| P2 | ASR 主链路与独立 Alignment/Diarization | 唯一 final、统一时间轴、辅助结果独立完成、无隐式模型 |
| P3 | Base/CustomVoice 运行与 BF16 Design 工作室 | 真增量、音色复验、缓存隔离、设计模型不能参与日常合成 |
| P4 | App/协议、播放、打断、组合调度 | 当前协议单实现、迟到包隔离、切档原子、组合准入 |
| P5 | 引擎受控制品与真实性能/质量验收 | 可重建安装、真实模型/播放器证据、声明与实测一致 |

修复计时工具和最小回归测试应贯穿前期，不等最后才发现指标不可用。可以分提交交付，但最终只有一套目标架构；分阶段研发不等于保留两套生产路径。

执行时重新读取 PR94 当时 head，避免覆盖并行修改。同一连贯工程目标继续使用同一 Draft PR；测试根据风险分层，不每个小提交都反复运行完整 gate。

本次交付只将方案提交到 PR #94 并建立跟踪；P0–P5 的实现与真实性能验收仍未由本次文档提交完成。

## 12. 明确不做的工程

不做旧档位映射、配置自动升级、旧事件 alias、双版本 API、旧 schema 读取桥、功能 flag 维持旧推理路径、为了旧测试通过而恢复错误行为。

不做通用插件市场、分布式微服务、每请求模型副本、默认第二遍大模型识别、运行时 VoiceDesign 或隐式云端回退。

不把环境恢复等同于新代码兼容旧数据。研发需要恢复时使用成套环境快照/重新初始化，不要求新版本持续理解旧格式。方案不授权自动删除任何现有素材或用户文件。

## 13. 产品呈现

任务入口：转文字、语音对话、朗读制作、音色工作室。规格设置：轻快、品质、参考精度；高级设置独立调整 ASR/TTS。时间戳和分人属于任务输出选项。

普通界面不展示 Base/CustomVoice 作为两套互相竞争的产品；通过声音选择自动解析角色。诊断页展示实际计划、引擎/制品版本、验证状态、限制和资源情况。

不把 token、dtype、KV 或 worker 状态直接作为主要用户操作文案；这些留在开发者详情。

## 14. 完成定义

完整交付同时意味着：12 个目标 Qwen 制品的角色清晰；只有当前契约和配置；ASR/辅助元数据与 TTS 身份闭合；资源、取消和播放行为正确；推理引擎可重建；能力声明有对应证据。

模型能加载、readyz 返回成功、协议 fake 测试通过、PR 正文有温态数字，都不足以单独满足上述完成定义。

## 15. 核对来源与证据边界

以下公开来源用于核对模型能力或协议，不意味着其上游示例已在 SpeechRail 的 MLX 实现中全部可用。MLX 制品及各引擎仍需独立验证。

- [S1] Qwen3-ASR 官方：离线/流式能力、独立 ForcedAligner、语言范围及词/字时间戳。https://github.com/QwenLM/Qwen3-ASR
- [S2] Qwen3-TTS 官方：模型分工、Voice Design then Clone。https://github.com/QwenLM/Qwen3-TTS
- [S3] Qwen3-TTS 官方模型卡与接口：1.7B CustomVoice 指令能力、Base/0.6B 边界。https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice ; https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/inference/qwen3_tts_model.py
- [S4] 当前 OpenAI Realtime transcription：session.update、audio.input 与 24 kHz PCM 示例。核对日期 2026-09-25。https://developers.openai.com/api/docs/guides/realtime-transcription
- [S5] CoreML Sortformer 模型卡：输出四个 speaker 槽和低延迟/离线配置。https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml
- [S6] Silero VAD：ONNX 实现与受支持音频输入。https://github.com/snakers4/silero-vad
- [R1] PR94 固定快照 AGENTS：产品边界、无历史兼容默认、单服务资源与授权规则。https://github.com/hrygo/SpeechRail/blob/4c7d37eecb1b55025efc003cae92b3feaf238e14/AGENTS.md
- [R2] 同快照 Realtime 契约：本次直接切换的历史实现起点，不作为目标约束。https://github.com/hrygo/SpeechRail/blob/4c7d37eecb1b55025efc003cae92b3feaf238e14/contracts/realtime-openai.md
- [R3] 上一轮已提供的源码分析文档：SpeechRail_ASR_TTS_Final_Plan_PR94_2026-09-25.md；本次完整读取，用于保留测量修正清单，不沿用其中的迁移、兼容或过渡设计。

上述技术判断来自文首固定 SHA 的方案核对，不冒充最新 Head 的全量代码审计。本次文档发布已另行核对 PR #94 当前 Head `d91eadd4277d1e534069aaef7abaed4012f73ebb`、仓库规则和相关文档；从该 Head 追加，不覆盖其相对分析快照新增的三个提交。本次不运行真实模型、基准、安装或 UI，不合并 PR。


## 16. 实施跟踪与文件定位

- 跟踪总单：[Issue #95](https://github.com/hrygo/SpeechRail/issues/95)。按第 11 节 P0–P5 和第 14 节完成定义推进；文档入库不代表任一完整实施阶段通过。
- 交付分支：[PR #94](https://github.com/hrygo/SpeechRail/pull/94)，`codex/tiered-streaming-tts-python314`。继续追加连贯的原子提交，保持 Draft，未获明确要求不合并、不 force-push。
- 与已有任务关联：[#82](https://github.com/hrygo/SpeechRail/issues/82) 的 ASR 操作级能力、[#83](https://github.com/hrygo/SpeechRail/issues/83) 的首个 partial 观测、[#85](https://github.com/hrygo/SpeechRail/issues/85) 的细粒度时间轴纳入相应阶段，不重复建立同范围任务。
- 原 [W0–W11 设计](../superpowers/specs/2026-09-25-tiered-streaming-tts-python314-design.md)和[执行记录](../superpowers/plans/2026-09-25-tiered-streaming-tts-python314-luna-guide.md)保留已有实现、测试和运行态的阶段证据。与本文不同的四档、运行时 VoiceDesign、旧协议和 runtime overlay 选择不再约束后续目标；本次不改写原始测试记录，也不宣称代码已切换。
- `accepted` 表示目标方案已确认，不等于运行行为已实现或通过验收。现行行为仍以对应代码、契约及有版本的实测为准；P0 在实现前锁定当前协议与类型，发生差异必须记录。
- 本文引用的会话文件 [R3] 是先前分析来源名称，不作为仓库内依赖。实施所需目标、测量修正与验收定义已经收录于本文；后续以仓库中的本文及跟踪 Issue 为准。

跟踪只使用 `Refs #95`，不以本次文档提交自动关闭实施 Issue。每个阶段勾选必须附实际 commit、定向验证和仍未验证项；完整方案完成后才能关闭总单。
