---
title: "分档音色一致性、双向流式 TTS 与 Python 3.14 升级设计"
status: accepted
audience: "SpeechRail 服务与原生 App 架构师、实施者、验收负责人"
version: "1.13"
date: 2026-09-25
---

# 分档音色一致性、双向流式 TTS 与 Python 3.14 升级设计

## 1. 目标、状态与授权边界

用户要求的是完整目标，不是以“等待整轮文本后合成”作为最终交付：保持角色音色一致，在 LLM 尚未输出完时开始发声，持续接收文本并输出音频，支持低延迟打断，同时升级 Python 与推理运行时。本设计覆盖 light、balanced、quality、extreme，明确各档的不同身份条件与验收范围。

用户已明确 Sona 废弃，功能已集成至 SpeechRail 原生 App；本方案只涉及 SpeechRail 服务、worker、MCP 与 App，不迁移、修复或依赖废弃客户端。

本文是待评审设计，不是当前能力声明，也不是逐文件执行计划。落盘授权仅用于文档；不安装依赖、下载/加载模型、修改运行态、运行真实音频/性能测试或 UI 自动化，不自动提交或推送。后续先评审本设计，再形成分模块实施计划；真实模型、服务切换、安装和 UI 测试分别遵循项目授权规则。

核心决策：

- 标准 CPython 3.14 为统一目标基线；初始候选 3.14.7，不采用 free-threaded 作为本次生产目标。
- mlx-audio 0.5.6 为基础升级候选，不把升级本身视为双向流式实现。
- light/balanced：固定 CustomVoice speaker + 单轮增量生成。
- quality/extreme：固定 Base clone revision + 单轮增量生成；VoiceDesign 负责创建/预览，不作为稳定角色的每轮生成器。
- 公共协议、生命周期与客户端交互统一，模型 conditioning、缓存、资源预算和性能参数分路径、分档验收。
- 同一段回复的生成状态有界；不跨整个聊天无限累积声学历史。

## 2. 证据范围与事实来源

核实日期：2026-09-24（Asia/Shanghai）。本地源码、catalog 与契约已复核；当前验收解释器实测为 Python 3.12.14。尚未实测 Python 3.14、managed runtime、active profile 或真实模型 readiness；不得将 catalog 声明解释为本机已安装、已启用或已验收。

### 2.1 本地来源

- `src/speechrail/assets/model-catalog.json`：四档 artifact、精度、aligner 与 diarization 声明。
- `src/speechrail/config/model_catalog.py`：quality/extreme 必须提供 Base clone；balanced/light 不得声明 clone；后两档必须使用 CustomVoice。
- `src/speechrail/backends/qwen3_voice_binding.py`：CustomVoice 固定 speaker 映射，VoiceDesign instruction 绑定，Base clone 绑定。
- `src/speechrail/backends/qwen3_tts_worker.py`：逐 planner chunk 生成、clone 固定 seed、stream=True 和重复惩罚配置。
- `src/speechrail/domain/tts_text_planner.py`、`src/speechrail/domain/tts.py`：240 codepoints planner 与切块语义。
- `src/speechrail/domain/tts_reference_condition.py`：0.4.8 prepared reference 公共接口 fail-closed。
- `pyproject.toml`、`src/speechrail/assets/runtime/{asr,tts}.in`、对应 `.txt`、`runtime-lock.json`：解释器与依赖事实。
- `contracts/realtime-openai.md`：当前显式无状态 TTS render，而非增量文本生成协议。
- `docs/architecture/quality-voice-capabilities.md`、`generated-voice-registration.md`、`docs/superpowers/specs/2026-09-23-extreme-tier-bf16-design.md`：职责和候选档边界。

### 2.2 原生 App 补充事实与范围校正

- `AssistantSession.runReply` 已消费 `LLMProvider.stream`，目前通过 `takeSentences`、`enqueueTTS`、`sendNextTTSIfNeeded` 逐句提交独立 TTS；这是本次改为单轮增量的实际入口。
- `RealtimeASRClient.sendTTSCreate/cancelTTS` 与 `RealtimeContractTypes` 已使用当前 SpeechRail namespace；无需旧客户端协议迁移。新模式需增加 start/append/finish、ACK、response/chunk/sample关联，保留ASR同连接事件。
- 默认 `AudioEngineSession` 已将采集/播放合并，拥有 playbackGeneration；`PCMStreamPlayer` 是已有替代音频source的播放路径。新增有界样本预算与取消隔离应复用它们，不增加第二套播放器。
- 当前播放回调使用 dataConsumed，不能直接证明物理播完；增量中临时drained须与服务端terminal及输入关闭组合，不能提前把助手状态置为整轮结束。
- 当前 `Package.swift` 显式source不包含AssistantSession和两个助手音频实现；新coordinator/buffer/ledger显式登记供纯测试，实际App接线通过授权包装构建另验。
- `macos_app_test.sh` 默认包含UI测试且不传递筛选参数，不作为本任务默认单测入口。SwiftPM纯测试不得访问真实音频/网络；任何UI自动化仍需独立授权。
- `application/realtime_openai.py` 顶层audioop为Python升级前置阻塞；先核查当前16k输入契约与重采样路径可达性，删除不可达旧依赖，不为了升级添加无依据的兼容包。

### 2.3 外部核查记录

本会话经官方公开 API/源码读取，未进行依赖安装或模型实测：

- Python 官方下载页：当次列出的最新 3.14 补丁为 3.14.7。
- PyPI mlx-audio 0.5.6 元数据：Python >=3.10；纯 Python 制品不等于传递依赖全部兼容。
- PyPI mlx 0.32.2、onnxruntime 1.30.0、numpy 2.5.2：存在标准 CPython 3.14 macOS arm64 wheel。完整锁定依赖图仍须验证。
- Blaizzy/mlx-audio v0.5.1 release、PR #914：ICL 重复惩罚改为近期窗口，修复已报告的长生成语速加速；PR #897 涉及 EOS 过滤；PR #895 涉及 Base 不支持 voice 参数的拒绝行为。
- v0.5.6 `mlx_audio/tts/models/qwen3_tts/continuous_batching.py`：Qwen3TTSBatchSession 是逐请求、分步推进的非流式 batch session，add 新请求不是向已有生成追加文本。
- v0.5.6 `qwen3_tts.py`：generate 接受完整 text；code predictor cache 有自身重置语义，不可与 talker 的跨时间 cache 混同。
- QwenLM/Qwen3-TTS 官方 README “Voice Design then Clone”：设计参考后复用 clone prompt 用于多句角色一致性。

以上版本是审阅时的候选快照，不要求实施时盲目追最新版；实施前复核目标制品、依赖和上游差异。性能数字不从官方展示值外推到本机。

## 3. 当前四档矩阵

| 档位 | ASR | 默认 TTS | clone capability | aligner / 分人 | 当前证据边界 |
|---|---|---|---|---|---|
| light | 0.6B q8 | CustomVoice 0.6B q8 | 无 | 无 / 关闭 | catalog 声明，不代表运行可用 |
| balanced | 1.7B q8 | CustomVoice 0.6B q8 | 无 | q8 / 开启 | 与 light 共用同一 TTS artifact |
| quality | 1.7B q8 | VoiceDesign 1.7B q8 | Base 1.7B q8 | bf16 / 开启 | 设计与克隆为不同 worker/capability |
| extreme | 1.7B bf16 | VoiceDesign 1.7B bf16 | Base 1.7B bf16 | bf16 / 开启 | 候选档；质量、延迟和资源尚未验收 |

重要区别：quality 与 balanced 共用 ASR artifact，但不是同一 TTS；light 与 balanced 共用 TTS，但 ASR 和辅助能力不同，因此端到端延迟、内存与调度不能互相代替实测。

## 4. 目标支持与分档升级策略

| 维度 | light | balanced | quality | extreme |
|---|---|---|---|---|
| Python/runtime | 统一升级 3.14 | 同左 | 同左 | 同左；不因解释器升级转正 |
| 一致性条件 | 固定内置 speaker + 模型 revision | 同 light | 固定 Base clone + voice/model revision | Base bf16 条件，独立复核 |
| 双向流式目标 | CustomVoice 路径必选 | 同 artifact 可复用模型层证据 | Base ICL 路径必选 | Base bf16 路径必选，但通过独立门才声明支持 |
| VoiceDesign | 不提供 | 不提供 | 创建参考/预览；不要求在线 append | 同 quality，但 bf16 独立验收 |
| 参考条件缓存 | 不需要 clone cache | 同 light | 需要有界模型相关缓存 | 与 q8 完全隔离 |
| 自定义 clone | 不新增、不伪装支持 | 不新增、不伪装支持 | 保留并稳定化 | 保留候选能力 |
| 资源验收 | ASR 0.6B + TTS | ASR 1.7B + aligner/分人 + TTS | 加入双 TTS lane 与 cache | 全 bf16 speech 组合的独立预算 |
| 失败策略 | 不宣称支持增量模式 | 同 light | 不降级到 VoiceDesign 冒充稳定 clone | 保持候选/不可用，不静默改 q8 |

### 4.1 Light / Balanced

现有 CustomVoice 内置 speaker 是身份条件，不需先 VoiceDesign 再 clone。不得为了统一实现而给这两档强行安装 1.7B Base，也不擅自加入 Base 0.6B 改变产品范围。

共用一个 CustomVoice 增量 adapter 和 artifact 层回归结果，但各档分别执行完整语音链路的资源与延迟验收。轻量档名称不证明其 TTS 比 balanced 更快：TTS 模型相同，实际差别可能来自整体资源占用。

### 4.2 Quality

稳定对话角色明确选择已注册 Base-bound clone。新建角色走“VoiceDesign 参考 → 参考质量门 → clone revision → 输出验收”；已有 instruction 音色不静默覆盖或转成 clone。已有内置音色在该档走 VoiceDesign instruction，不能仅凭名字承诺身份固定。

稳定对话入口遇到 instruction-only 或未准备的声音时，明确提示先创建/验证固定角色；普通完整文本合成和设计试听仍可使用 VoiceDesign，但不标记为稳定角色增量模式。首次在线对话请求不得隐式生成 canonical reference 或下载模型。

### 4.3 Extreme

共享 Base 路径代码不等于共享 q8 的测量结论。bf16 模型/参考缓存、ASR、KV、decoder 与组级驻留均单独计量；不得按权重文件大小简单倍乘推断实际内存。

通过质量门但未通过实时门时，显式呈现“完整文本合成可用、实时模式未验收/不可用”，不得静默切换 quality 或将独立短 render 拼接当作验收成功。最终四档交付要求 extreme 的实时门也完成；若不能满足，必须报告整体目标未完全达成并评审后端/目标调整，而非降低标准后宣布完成。

### 4.4 跨档切换与身份连续性

- light ↔ balanced：相同 artifact/speaker 允许复用模型层证据；当前 utterance 不热切换模型/配置。
- quality ↔ extreme：仅在已有 voice/model binding 允许时使用同一规范参考；不绕过 revision 冲突检查。跨模型需要显式 revalidate 或新 binding/revision，不能假定完全同音。不得共用 prepared tensor cache。
- CustomVoice ↔ VoiceDesign/Base：同名 ID 不表示同一个身份条件；UI/客户端必须显示切档后的可用声音与差异，不能自动用同名声线替换 clone。
- clone 在 light/balanced 下不可用时保留资产并明确拒绝，不删除、不覆盖、不映射到“相近内置声音”。
- profile 切换先完成或显式取消活动 utterance，再走既有受控切换流程；不在回复中途更换声音或精度。

## 5. 架构与对象生命周期

```text
LLM（调用方） → 文本整理/小窗口前瞻（调用方）
  → utterance.start / append_text / finish_text
  → SpeechRail 协议校验、revision 绑定、资源准入
  → worker 单一模型执行上下文
  → CustomVoice 或 Base 增量 adapter
  → codec 增量解码 → PCM 帧 → 有界网络队列
  → 调用方有界播放缓冲 → 扬声器
```

- VoiceRevision 和 reference condition 跨轮复用。
- utterance 拥有当前生成的 talker 状态、文本对齐状态、codec 历史和 decoder 状态；完成/取消/失败后释放。
- code predictor 严格遵循模型内帧内/帧间重置语义，复用分配不等于永久累积上下文。
- WebSocket connection 是传输上下文，不是无限长模型会话。
- 单服务、单 ASGI worker，不复制模型进程换吞吐；同 lane 串行，仅按已批准 profile/governor 允许跨 lane 并发。
- 不把 LLM、麦克风、播放或业务打断策略搬进 SpeechRail。

## 6. 模型可行性门：两条路径分别证明

在公开协议定稿前，为 CustomVoice 与 Base ICL 各建立最小探针，复用同一测试驱动但不互相代替结果：

1. 输入首批文本，生成首批 PCM；后续文本尚未全部到达。
2. 在音频已输出后追加文本，仍进入同一次模型生成，不重建独立 render。
3. 已提交 token 前缀稳定；不重新 tokenize 整个字符串后悄悄改变已消费前缀。
4. 暂时无文本时等待，不无限生成填充声音；finish_text 才表示输入结束。
5. 正确协调 text/acoustic 对齐、trailing-text 条件、EOS 与尾音 flush。
6. 数字/单位、中文标点、英文半词、混合语言和突发输入无系统性漏读/复读。
7. 阶段性暂停、取消、超时均能回收状态，且不污染下一请求。

依据真实模型结果决定扩展边界。首选新版 mlx-audio 上的窄范围受控 fork，固定 commit/制品/hash，通过 adapter 暴露公开接口；不在业务代码使用私有 cache 字段或 monkey patch。

若公开权重/条件路径不能可靠支持该语义，停在该门并提出后端替代设计；不以“网络流式”或 batch session 替代模型层双向流式证明。CustomVoice 通过不能推导 Base 通过，q8 通过不能推导 bf16 实时达标。

## 7. 身份条件与缓存

utterance 创建时冻结 voice revision、模型制品 revision、generation profile revision。后续音色更新只影响新 utterance，不修改正在发声的条件。

Base prepared reference key 覆盖规范音频与准确参考文本内容身份、预处理版本、tokenizer/模型/量化 revision、conditioning 模式和实现版本。缓存有容量上限、租约和淘汰；被使用的条目不提前释放；重启后不将旧 tensor 直接当作可兼容持久资产。

CustomVoice 固定 speaker binding 与模型 revision；无需伪造 clone reference。两条路径共享对象生命周期接口，不强行共享 tensor 结构。

固定 seed 用于实验复现，不是 speaker identity 的定义；准备参考成功不等于跨文本身份验证成功。保留规范参考，升级不自动重生成或覆盖音色资产。

## 8. 真流式输入、解码与长度治理

调用方维护未提交尾部缓冲和不可修改已提交前缀，避免切开数字、单位、英文词和 Markdown 结构；设置最大等待时间，不无限等待完整标点。第一自然短语尽快提交，后续持续追加，不能退化为等待整轮文本。

小窗口前瞻参数、首包与稳态解码参数按模型路径测量后定标，不以全档一个字符数硬编码。区分模型解码窗口、传输 packet 和播放缓冲，避免多层缓冲累加。

新流式路径不沿用“每 240 codepoints 重启生成”；旧完整文本 planner 保留其边界职责。长输入必须有文本、音频时长、KV/codec 历史、队列和等待上限；没有验证过的 KV 滑窗不直接启用。到达上限明确拒绝继续追加/结束策略，不能静默丢字或重启声音；超长内容由调用方显式建立下一个 utterance。

decoder 需验证 overlap、sample offset、尾帧 flush，禁止为每个 PCM packet 重置 decoder 或对整段反复归一化。统一响度处理不得在小包边界引入泵动。

## 9. 候选公共协议与状态机

以下事件属于拟议 SpeechRail 扩展，不是现有接口或 OpenAI 原生事件；正式实现同步契约、错误码、客户端与用户文档：

- `speechrail.tts.start`：提交 request identity、voice/model revision、模式与预算，绑定唯一 utterance。
- `speechrail.tts.append_text`：携带 utterance identity 与单调递增序号追加不可修改文本。
- `speechrail.tts.finish_text`：关闭输入，继续生成剩余音频和尾音。
- `speechrail.tts.cancel`：匹配活动 request/utterance，停止生成。

连接内仍限一个活动 TTS；输入开放/关闭与生成进行/结束是正交状态，允许 receiving 与 generating 同时发生。终态为 completed、cancelled 或 failed，每个 utterance 仅一次；finish_text 后追加返回明确错误。

追加序号首版采用严格顺序，重复/缺口均显式拒绝且不重复应用文本，不提供跨连接重放。音频携带序号、sample offset 与 response identity。正常终态在尾音 flush 后产生；取消后不得再向业务输出旧音频。

断线取消并释放，首版不承诺 KV 重连续传；客户端决定是否新建请求。定义输入饥饿超时、总截止时间、慢消费者处理和文本/音频队列上限。

能力必须按当前 voice 路径、active profile、artifact、adapter 实现与实际 readiness 声明。拟议区分完整文本输入、增量文本输入、音频流输出、prepared reference 与已验收实时模式；不能仅因档位名或 Python 升级统一报告支持。能力字段名称在协议实施计划中定稿。

普通 REST 完整文本合成保留为正式能力与质量基线。用户明确选择实时模式但模型不支持时 fail-closed；不静默降级为等待全文或分句拼接。

## 10. Worker、取消和资源治理

worker 的控制接收不得被整段阻塞 generate 饿死。采用控制接收与模型步进分离、单一执行上下文拥有所有可变模型状态；每有限步检查追加、取消、超时和背压。不得多线程并发修改同一 KV/decoder。

控制与音频通道均有界，取消有优先处理路径，不排在无界文本队列后；必要时扩展现有长度前缀 IPC，但不在 ASGI 进程加载模型。

Resource Governor 计入模型 resident、reference cache、活动 KV/codec、解码与发送缓冲；活跃 utterance 持有租约，短暂等文本不能被 idle eviction 卸载。长时间无输入按期限取消，而非无限占槽。

保持现有 batch ASR / streaming ASR 冲突语义。测试各档 ASR/TTS/aligner/分人组合；quality/extreme 的创建、ASR 质量检查与实时发声不能绕过既有 lane 准入。

打断顺序：客户端立即停播并清空旧缓冲 → 发送精确 cancel → 服务端停止生成并释放 → 客户端丢弃迟到旧包。服务端记录生成/发送事实，播放进度由客户端负责，不冒充可听进度。

## 11. Python 与 runtime 升级

统一目标 `>=3.14,<3.15`，替换现有 `>=3.12,<3.13`；不长期维护按档位分裂的解释器版本。标准 CPython 初始候选 3.14.7，补丁与供应方式随 release 锁定。

升级范围：主服务、ASR/TTS worker、MCP、installer/CLI、依赖锁/hashes、runtime-lock、CI/release、Ruff/mypy、XPC 启动环境与安装文档。分别解析完整依赖图，不将纯 Python wheel 或单个 cp314 wheel 当作全链路证明。

优先复用已核实兼容的模型依赖版本，仅升级有必要的组件；不要顺手升级全部包。新版 mlx-audio 的依赖变化（包括不再依赖部分 mlx-lm 路径）需审查导入和用途后决定是否调整 pin，不能机械删除。

构建仓库外独立候选 runtime，不原地改正式 venv。先确定性回归，再在明确授权下真实 worker smoke 和分档验收。过渡阶段旧 3.12 release 仅作回滚，不作为新功能长期兼容目标。遇阻塞依赖先提交证据和替代方案，不自动退到 3.13 后宣称 3.14 目标完成。

## 12. 验收矩阵与指标

### 12.1 三层证据

1. 确定性测试：fake backend，协议/队列/取消/序号/配额/能力声明/切档与缓存身份。
2. 模型验证：CustomVoice q8、Base q8、Base bf16 各自证明真增量生成；VoiceDesign q8/bf16 创建和普通合成回归。
3. 端到端声学与性能：逐档测量，包含客户端可听延迟；UI 自动化另需当前用户逐次授权。

light/balanced 共用模型探针，但分别测端到端链路；quality/extreme 不共享质量或性能 pass 标记。ASR、aligner、分人与 MCP 因解释器升级纳入受影响回归，不能只测 TTS。

### 12.2 初始目标（非实测承诺）

| 指标 | 初始验收目标与定义 |
|---|---|
| 温态首音 | 首批可提交文本到客户端首个可播放 PCM，P95 ≤500 ms；报告网络与缓冲边界 |
| 文本等待 | 小窗口额外等待初始探索 100–200 ms，不等同模型推理预算 |
| 持续速度 | RTF=生成耗时/音频时长，必须 <1，争取 ≤0.7；排除输入饥饿并另报真实播放欠载 |
| 本地停播 | 用户打断到停止旧声音 P95 ≤100 ms |
| 状态释放 | cancel 到活动模型状态释放 P95 ≤500 ms，独立于停播计时 |
| 身份 | 响度匹配的跨文本盲听/ABX，不明显劣于对应模型固定身份的完整文本基线 |
| 正确性 | 不引入系统性漏读、复读、提前 EOS 或尾音丢失 |
| 长时生命周期 | 反复完成/取消/失败后无单调增长的活跃对象和不可回收资源 |

全档使用同一指标定义，按档分别报告 P50/P95、样本数、语种、文本类别、冷/温状态、模型与 runtime revision。不得通过放宽 extreme 阈值后仍使用同一“低延迟已通过”标签；目标变更需评审。

分离端到端各段：用户结束说话、VAD 判停、ASR 完成、LLM 首段文本、TTS 首包、客户端首播。禁止拿模型首包替代整体对话延迟。

测试输入覆盖短响应/长句/多句、数字单位、中英混读、逐字符/突发/停顿输入、半词、输入结束和取消竞争、断线、慢播放、超限、profile 切换、voice revision 更新、跨精度缓存命中隔离。生成式参考质量报告不代替 Base 输出身份检查；独立声纹评估仅做匿名质量测量，不建设跨会话实名库。

真实音频与性能制品在仓库外；不记录 prompt、转写全文、原始音频、embedding 或绝对模型路径到生产日志。日志只含 request identity、低基数能力/状态、计时和资源统计。

## 13. 分阶段交付与停止条件

| 阶段 | 交付 | 通过门 / 不通过动作 |
|---|---|---|
| A：运行时基线 | 3.14 候选锁、主服务与所有 worker 兼容报告 | 完整依赖/导入/确定性回归通过；阻塞则报告依赖，不改正式运行时 |
| B：模型可行性 | CustomVoice 与 Base 分别真增量探针 | 音频已输出后仍能追加文本；失败则评审模型/后端，不继续铺公共 API |
| C：身份与 adapter | speaker/clone 双条件接口、revision 与有界缓存 | 串音色、跨精度误缓存、旧 revision 污染测试通过 |
| D：worker/资源 | 步进、IPC、取消、超时、队列、租约 | 状态机/故障注入通过，资源可回收 |
| E：协议/App | 契约、AssistantSession 文本流、RealtimeASRClient、音频播放与打断、分档能力 | 同轮单次生成，response/generation隔离；临时播放排空不误判整轮完成 |
| F：逐档验收 | 四档支持矩阵、声学与性能报告 | CustomVoice q8、Base q8、Base bf16 分开通过；extreme 不继承结论 |
| G：发布与切换 | 新 managed runtime、正式依赖锁、迁移说明 | 明确安装授权后受控切换，可整体回滚 |

A/B 均为早期门，不等 UI/协议全部完成才验证底层。可以逐档开放已验收能力，但最终完整目标要求四档矩阵都有明确结果；未达标档必须标注未完成，不能“全档升级完成”等同“全档实时支持”。

后续拆为 runtime、模型 adapter、worker/协议、客户端、验收发布五个边界清晰的实施计划，共用本文作为设计约束。未得到委派授权不创建子代理；写计划不自动提交、执行或部署。

## 14. 变更范围与回滚

预计事实入口/修改范围：

- runtime：`pyproject.toml`、`uv.lock`、`src/speechrail/assets/runtime/`、`runtime-lock.json`、`src/speechrail/service/managed_install.py`、相关 CI/发布脚本。
- 生成：`src/speechrail/backends/qwen3_tts_worker.py`、`qwen3_tts.py`、`qwen3_voice_binding.py`、prepared reference domain、受控 vendor adapter。
- 协议与资源：`src/speechrail/runtime/worker_protocol.py`、`resource_governor.py`、Realtime 实现及 `contracts/realtime-openai.md`。
- 客户端：`macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift`、`RealtimeASRClient.swift`、`AssistantAudioSession.swift`、`AssistantAudioPlayback.swift` 与 `SpeechRailControlKit/RealtimeContractTypes.swift`；保留 `LLMProvider.swift` 的现有 SDK 接入，能力/选择入口为 `ServiceAPIClient.swift`、`AppModel.swift`。
- 契约变化同步相关测试、用户文档与 active 架构；本文不直接改写现行契约或 catalog。

完整 release 包含解释器、依赖锁、服务、vendor commit 与协议能力版本；回滚成套进行，不能只退 Python 包而保留不兼容 worker。新旧 runtime 不并行启动服务；切换前核对唯一 LaunchAgent、PID、端口与 active runtime，按 release/local-deploy 流程执行。

保留原音色资产和规范参考；不静默改持久格式。新增字段若涉及旧版读写，发布前设计可逆或旁路存储；未明确数据迁移恢复策略不得执行。回滚后客户端根据旧能力禁用新模式，不发送旧服务不识别的事件，也不以另一个声音作为替代。

## 15. 实施进度（以 Luna 指南为阶段事实源）

| 阶段 | 状态 | 当前证据 / 未完成项 |
|---|---|---|
| W0 工作区基线 | complete | 基线 `25d4416f`；分支 `codex/tiered-streaming-tts-python314`；既有用户改动保留 |
| W1 Realtime / audioop | complete | 移除不可达转换器；137 项 Realtime/caller-wire 回归、定向 Ruff、mypy通过；该阶段验证时使用3.12.14，后续 W2 已独立验证3.14.7候选环境 |
| W2 Python/runtime | complete | 3.14.7候选 runtime `--only-binary` 安装47个锁定包；MLX/ASR模块导入通过；`uv lock --check`、runtime-lock `--check`、zero-setup语法检查通过；9个定向测试文件352 passed、Ruff与130-file mypy通过。1个既有 Pydantic `mappingproxy` warning；未加载模型或切换正式服务 |
| W3 App 协议基线 | complete | 保持当前完整文本 wire；生产 transport 仍用 `URLSessionWebSocketTask`，新增 fake-transport seam；TTS 事件关联 request/response identity，隔离旧终态/旧音频并抑制取消后迟到音频。按当前服务端序列化结构构造 fixture；`RealtimeContractTests` 12 passed，三处 App session 文件 `swiftc -frontend -parse` 通过，`git diff --check` 通过。SwiftPM 未 typecheck App session 文件、未做 App 构建/真实服务/音频/UI 验收；输出有 23 个非 target 文件未显式声明警告 |
| W4 模型层真增量门 | complete（q8）；bf16 catalog 门已过 | CustomVoice q8 与 Base q8 都在同一 generation 内首 PCM 后追加文本、ASR 内容全文一致；Base 需短 reference 与跨过 prefill 槽位的初始文本（`base-trailing-after-first-pcm-v1`，探针 fail-closed 校验 `prefill_target_tokens < initial_text_token_count`）。早期 Base 失败是 `--schedule` 未接线 + 长 reference 全文本预填造成的假阴性，已修正并保留原始记录。Base bf16 的 catalog `README.md` 差异已由恢复 pinned 快照解决（两件制品各 13/13 文件尺寸与 sha256 匹配，未放宽校验），模型/实时门留待 W11；vendor HEAD `851f9567ecd27ad8f210cefc866c7d01525151e4` |
| W5 领域与身份 | complete | `domain/tts_stream.py`（options/双轴 state/limits/事件/port 与集中错误码）、`PreparedReferenceKey`（内容身份+预处理+模型/量化/tokenizer/实现版本，digest 即缓存命名空间，跨精度不共享）、`VoiceBinding.supports_incremental_stream`（仅 CustomVoice speaker 与 Base clone）；15+6+44 项定向测试通过，主仓全量 2111 passed/144 skipped、coverage 81.77%、`mypy src` 131 文件通过 |
| W6 worker 双向控制与父进程 session | complete | 私有 `tts_stream_protocol=1` 协商；`StreamPump` 双线程 + 有界队列、单模型线程；`TtsStreamHost`/client 单父端 dispatcher；新增 `qwen3_tts_incremental.py` adapter（CustomVoice speaker、Base clone、VoiceDesign fail-closed）；`Qwen3TtsWorker.open_incremental_stream` 全程持 voice lease 与独占 slot，完整文本 synthesize 与 stream 串行，router 按 clone lane 路由；`tests/test_qwen3_tts_incremental_bridge.py` 10 项、`test_qwen3_tts_worker.py` 增真实 `BytesIO` pipe 端到端，联合回归 188 passed，ruff/mypy/`git diff --check` 通过。仅 fake IPC，未加载模型 |
| W7 application 资源治理与输出生命周期 | complete | `application/tts_stream.py`：`TtsStreamService.open` 按 voice lane 进入 `governor.reserve`，持 worker 租约与 vendor session（独占 worker slot + voice lease）；终态同 loop 同步认领且只有控制器 task 写 sink，终态后不投递音频、receipt 只收束一次；等待文本期间不被 idle 驱逐，`evict_warm_capability` 遇活跃 utterance 返回 `backend_busy` 而不强卸载；receipt 只在发送成功后 `accept_pcm` 并绑定实际 runtime revision；输入饥饿/墙钟/慢消费者分别以 `tts_input_timeout`/`tts_backend_failed`/`tts_backpressure` 收束。新增 11 项 application 测试，定向 114 passed、主仓全量 2308 passed/7 skipped、ruff/mypy/diff check 通过。仅 fake session，未加载模型 |
| W8 公共协议与能力 | complete | public wire 增加 `speechrail.tts.start/append_text/finish_text` 与 `speechrail.tts.started/text_accepted`，音频沿用 `response.output_audio.delta` 并带 `speechrail.chunk_index/sample_offset`；ACK 序号定为 `append_sequence`（传输层已占用 `sequence`）；`create`/`start` 共用活动判定与 request-id 账本；`tts_stream_capability.py` 由 `/v1/models`、`/v1/voices` 与握手共用且 `budget_available` 不参与 `supported`。新增 `tests/test_realtime_tts_incremental.py` 16 项，定向 252 passed、主仓全量 2324 passed/7 skipped、ruff/mypy（136 文件）/diff check 通过。仅 fake session，未加载模型 |
| W9 App 单轮增量文本与播放 | complete | ControlKit 增 start/append/finish DTO 与 started/text_accepted 解析；`RealtimeASRClient` 增流式三方法并校验 chunk_index/sample_offset/偶数字节；新增 `AssistantSpeechTextBuffer`（150 ms 三档紧急度、按 Unicode scalar 计量）、`AssistantPlaybackLedger`（1 秒样本预算、旧代隔离、暂时 drained ≠ 结束）、`AssistantTTSStreamCoordinator`（一轮一次 start/finish、ACK 未回不发 finish、背压超时明确失败）；播放完成语义由 `.dataConsumed` 改为 `.dataRendered`。`swift test` 全量 207 passed（含新增 30 项纯状态测试）；三个新增文件同时登记到 SwiftPM sources 与 Xcode 两处 Sources phase；App 全量源文件 `swiftc -typecheck` 通过。App 构建 / 真实 AVAudioEngine / 可听延迟 / UI 未验收（未授权） |
| W10–W11 | not started | 分档呈现与切换保护、逐档声学/性能与发布回滚；Base 约束为“短 reference + 跨 prefill 槽位初始文本 + 单 generation 逐帧投喂” |

W1 对导入兼容性的验收是在当时的 Python 3.12.14 环境中阻断 `audioop` 导入后执行；W2 随后在独立 CPython 3.14.7 候选环境完成依赖安装、导入与确定性回归，但不等价于正式 app home 切换或真实 Metal/模型推理验收。

W2 的 `requirements/shared.txt` 是 ASR/TTS role lock 的交集元数据，只参与 runtime identity/hash 校验，不作为安装输入。当前两种 role 共用一个 Python 环境，bootstrap 在一次 `uv pip sync` 中同时传入 `asr.txt` 与 `tts.txt`，因此 role-only 依赖仍安装；如需按 role 减少驻留依赖，必须先拆分环境并另行验证，不能把 shared 交集误解为依赖裁剪。

## 16. 评审结论与未验证项

分档差异是方案的一部分：统一 Python/runtime、协议和生命周期，分开 CustomVoice 与 Base 增量实现，分开 q8/bf16 资源与声学验收。提高档位不是天然提高一致性，也不是天然降低延迟。

W4 真实模型门（2026-09-25 修正后）表明：CustomVoice q8 与 Base q8 都能在同一 generation 内首 PCM 后追加文本并完整发声，四档统一真增量目标继续成立。Base 的前置条件是该 runtime 的 aligned ICL 布局必须把初始文本的尾部留在 trailing 队列：初始文本要跨过 prefill 槽位（`prefill_target_tokens < initial_text_token_count`），并配合短 reference；探针对该条件 fail-closed。此前“Base 只能全文本预填”的 Ruling 来自 `--schedule` 未接线加长 reference 的假阴性，已作废。Base bf16 的 catalog `README.md` 差异已由恢复 pinned 快照解决：两件 bf16 制品经仓库自带校验各 13/13 文件尺寸与 sha256 匹配，catalog 门按原规则通过，未放宽校验。剩余未决项是所有档位的声学/性能验收，以及 bf16 相对 q8 的实时门与资源收益（W11）。

W5 已把第 8/9 节的增量约束固化为 vendor-neutral 领域契约：唯一 limits/state/event 定义、必须连续的 append 序号与唯一终态、文本 codepoint 与音频字节两套独立预算，以及以内容身份+预处理+模型/量化/tokenizer/实现版本为命名空间的 prepared reference key（跨精度不共享）。W6 已在其上实现私有 adapter、worker 双线程与父进程 session：`tts_stream_protocol=1` 协商、单模型线程、单父端 dispatcher、voice lease 与独占 stream slot，以及 CustomVoice speaker / Base clone / VoiceDesign fail-closed 的条件映射。该层仍是 fake IPC 与确定性测试，真实模型、真实 worker 与 public wire 尚未验收。

W7 已把增量 utterance 的资源与输出生命周期固定在 application 层：governor reserve、worker 租约与 vendor session（独占 worker slot 与 voice lease）由同一控制器持有，终态认领是同一 event loop 上的同步写入且只有控制器 task 写 sink，所以 vendor `completed`、调用方 `cancel` 与输入/墙钟超时竞争时只有一个胜者，终态之后不会再有音频或第二次 receipt 收束；等待文本期间不释放租约（`WorkerIdleEvictor` 不会卸载），组级 `evict_warm_capability` 对活跃 utterance 明确返回 busy 而不强卸载；render receipt 只统计真正通过发送边界的 PCM，并在 start 绑定实际 runtime revision。该层仍是 fake session 与确定性测试，未接入 public wire，也未做真实 worker、取消超时、长稳或内存峰值验收。

W8 已把领域、worker 与应用层的增量能力开放到 current-only public wire：`speechrail.tts.start/append_text/finish_text` 与严格 parser 固定在兼容层，`speechrail.tts.started/text_accepted` 提供协议版本、生效 limits 与逐次 append 确认，音频继续使用 `response.output_audio.delta`（只在 `speechrail` 扩展对象里补字节精确位置），终态仍由 `_finalize_tts` 唯一认领。两处实现决策值得记录：ACK 的追加序号定名 `append_sequence`，因为传输层已给每个事件打上连接级 `sequence`，沿用同名会被静默覆盖；本段文本的 ACK 先于其 transcript 回显。能力声明改由单一 resolver 提供，`/v1/models[].capabilities.streaming_input` 只声明 `scope=per_voice` 的实现轴，`/v1/voices[].streaming` 与握手 `speech_capabilities.streaming_tts` 给出同一 voice 级裁决，`budget_available` 作为瞬时信号明确不参与 `supported`。该层仍是 fake session 与确定性测试：未加载模型、未产生真实 PCM，真实 worker、断线重连、长稳与逐档声学/延迟仍待 W11。

W9 已把增量能力接到原生 App 的助手轮次上：ControlKit 提供 start/append/finish 三个上行 DTO 与 `speechrail.tts.started/text_accepted` 的解析，`RealtimeASRClient` 复用同一条连接与唯一 receive loop，并在音频入口按 request/response 身份、`chunk_index`/`sample_offset` 连续性与偶数字节过滤（旧 response 的块静默隔离，本轮畸形块单独计数）。纯状态层拆成三件可测对象：`AssistantSpeechTextBuffer` 负责“什么时候可以交给模型”——150 ms 上限内不切开还在长的数字/单位/英文尾词与未闭合 Markdown，限额按 Unicode scalar 计；`AssistantPlaybackLedger` 负责“这一轮到底结束没有”——服务端终态与本代音频排空必须同时成立，暂时 drained 只表示欠载；`AssistantTTSStreamCoordinator` 负责一轮 utterance 的身份、序号、ACK 等待、背压与取消，LLM 结束事件不能越过未确认文本提前 `finish_text`。播放完成语义随之从 `.dataConsumed` 改为 `.dataRendered`，并新增逐块 `onPlaybackBufferRendered(frames)` 用于归还预算。`AssistantSession.runReply` 的朗读路径已不再逐句 `create`：第一批有效文本开始一次、后续追加、流结束关输入，屏幕/历史/落库仍只用原始 LLM 文本。该层经验证的是确定性状态机（`swift test` 207 passed，含新增 30 项纯状态测试）与 App 全量源文件的 `swiftc -typecheck`；未加载模型、未做 App 构建、真实 AVAudioEngine、可听延迟与 UI 验收。

W2 已验证候选依赖锁、3.14.7 MLX/ASR 模块导入及确定性回归。W4 已验证 CustomVoice q8 与 Base q8 的追加文本内容、首 PCM 与 append→next PCM（Base 条件见上）；bf16 已通过 catalog 完整性门但尚未进入模型/实时测量。尚未验证人耳 A/B、说话人相似度、自然度、真实 worker/协议、取消/重连、长稳 RTF、缓存内存预算和 bf16 相对收益。ASR 只证明内容缺失/一致，不能替代声学身份验收；质量门通过也不等于四档产品体验已验收。

本设计已获用户实施授权。进度按 Luna 指南逐阶段维护；本设计通过不代表尚未验证的运行态、声学质量或性能能力已获验收。
