# Changelog

## [Unreleased]

## [3.5.6] - 2026-10-03

### Changed

- 打包进 wheel 的 `speechrail` skill 资产与当前 MCP/服务端行为对齐
  （`skill-manifest.json` 版本升至 `1.4.0`）：`references/errors.md` 新增
  “明确不支持的 400 错误码”与“音色设计通道”两类恢复指引，覆盖
  `stream_unsupported`、`chunking_strategy_unsupported`、
  `unsupported_parameter`、`stream_format_unsupported`、`transcript_mismatch`、
  `voice_design_machine_validation_required`、
  `voice_design_validation_limit_reached`、`validation_audio_unavailable`
  和 `voice_design_revision_conflict`；`references/voices.md` 补充
  `production_ready` 判定与修复路径（`synthesis_validation_not_run` 只能由
  `validate_voice` 的真实质量运行修复，没有可置位的开关）、`require_output_pass`
  严格准入、文本数字保真门（`transcript_numbers_match` /
  `validation_policy_revision`）与 32 条验证保留上限。仅文档资产，无公共
  API 行为变化。

### Fixed

- `scripts/check_mcp_tool_contract.py` 不再只比较工具名与数量：新增对
  `errors.md` 的语义校验，要求每个会改变调用方行为的稳定错误码都在打包
  skill 中被讲解，堵住“工具面已对齐但行为指引过时”这类静默漂移。

## [3.5.5] - 2026-10-03

### Changed

- 将明确不支持的音频选项统一为 HTTP 400：
  `stream_unsupported`、`chunking_strategy_unsupported`、
  `unsupported_parameter` 和 `stream_format_unsupported`。
  依赖旧 422 分类的调用方需改为处理 `BadRequestError`；
  畸形输入继续返回 422。OpenAPI 同步声明转写输出无效时的 502。
- VoiceDesign 验证投影新增 `transcript_numbers_match` 和
  `validation_policy_revision`。创作验证使用
  `voice_design_text_fidelity_v2`，发布证据使用 `voice_design_base_v2`；
  旧 v1 记录与音频继续保留，但不再接受人工提升或作为严格合成的通过依据。
  受影响的旧音色需重新执行质量验证；升级不会删除或迁移用户音频。
  这些变更修复既有契约和验证缺陷，本版本按 PATCH 准备；调用方仍需核对上述公开影响。

### Fixed

- **#138**：候选参考确认和 Base 新文本复验均应用既有的数字精确门禁，
  高相似度的错误数字不能通过；等价口语数字仍可接受。
  机器拒绝不能经身份/自然度听审升级为发布通过，旧证据也不能绕过当前策略。
- **#139**：并发 Base 复验在仓库锁内读取最新候选并合并单条结果，
  保留每个成功返回的验证 ID、WAV 和人工结论。人工听审重新核验当前证据，
  在途请求不能恢复已发布、取消、失败或修订后的候选。满 32 条时明确拒绝
  新结果，同 ID 幂等重试仍可成功；保存失败仅回滚新建资产。
  重新验证失败不会降级已有完整通过状态，旧结果重试不再倒退更新时间。
- **#140**：durable ASR job 始终以 text-only 调用 ASR，时间戳由独立 aligner
  从冻结正文求得；缺少能力或对齐失败时明确失败。REST 与 job 共享对齐准入，
  `timestamps + diarize` 复用分人时间轴，避免重复对齐或隐式模型解析。
- **#141**：durable TTS 复用共享 AudioChunk 验证器，拒绝奇数字节、
  序号缺口/重复和 response ID 换流；非法输出不会生成成功制品。
- **#142**：对齐结果必须覆盖全部可朗读字符。漏词、否定词或数字不再借用
  相邻 token 的时间戳；合法标点与空白仍按冻结正文保留。
- **#143**：REST ASR 和后续对齐/分人共享绝对期限，超时返回可重试的
  `backend_timeout` JSON 和 request ID；VoiceDesign confirm 的 TimeoutError
  优先于 OSError 分类，避免误报候选输入无效。
- **#144**：统一音频实现、错误契约、用户文档及 Python SDK 异常断言。
- **#145**：原生 diarized SSE 的 `transcript.text.delta.segment_id` 与后续
  `transcript.text.segment.id` 一致，Python 和 Node 官方 SDK 可明确关联文本片段。
- 发布流程按 GitHub 已发布标签选择比较基线，并收录中间尚未发布版本的
  CHANGELOG 段落，避免 3.5.x 记录被漏掉或链接指向不存在的标签。

### 验收范围

- 服务端确定性回归使用 fake backend、合成 PCM 与临时存储；
  完整代码、类型、契约、文档及制品门禁结果见本版本验收记录。
- 真实模型质量、性能与长时稳定性不由上述回归结果证明。
  本轮不包含本机安装、服务切换或 UI 自动化验收。

## [3.5.4] - 2026-10-02

### Fixed

- 修复 VoiceDesign 设计通道**整体不可达**：`models["tts"].variant` 结构上只会是
  `custom_voice` 或 `base`（`REQUIRED_SPEC_BINDINGS` 不含 `voice_design`，设计是
  与档位无关的按需制品），而 MCP 的设计类工具要求该变体等于 `voice_design`——
  一个任何部署都无法满足的判断。结果是 `design_voice` / `create_voice` /
  候选校验 / 发布全部被永久拒绝，同一时刻 `POST /v1/voice-designs` 却能正常出
  候选，design → Base 发布路径无法经 MCP 走通。快照新增与 `tts` 平级的
  `models.voice_design` 与 `operations.voice_design`，准入改判设计制品可解析性；
  `/v1/models` 的 `supports_preview` / `supports_instruction` 改读设计通道，
  消除 `describe()` 顶层 `preview_supported:false` 与
  `operations.voice_preview.status:supported` 的自相矛盾。

- 连带修正三处同源误判：`instructions` 在 `/v1/audio/speech` 对任何音色都会被
  拒绝，却对 design 音色报 `supported`；design-only 音色宣告 `available: true`
  但合成必然 400 `voice_design_task_required`，其 `timing_sidecar` /
  `conditional_synthesis` 也按 binding 可解析而非可服务判定。一律改以
  `runtime_role` 为准，并在契约补 `voice_design_task_required` 原因值。

- `preview_voice` 钉 `language="zh"`，与 `design_voice` 一致；此前默认 `auto` 会让
  同一配方在两条通道分叉（实测 8.88s / 7.52s）。

### 澄清（实测结论，与既有 issue 的描述不同）

- preview 与 design 运行**同一份** VoiceDesign 权重，对同一 `seed` 逐位确定，
  韵律**可以**跨通道迁移。此前观察到的「语速 3.71 vs 2.01 syll/s」是**总时长**
  假象：真实成因是 `language` 默认值不同，加上候选音频规范化会裁剪首尾静音。
  按语音有效时长复测，两通道仅差约 3%（4.82s / 4.98s）。
- `health.tts_design` 的 `state:"cold"` + `configured:true` 是**准确**声明，契约
  已写明「读 health 永不加载 worker，冷但已配置即可按需加载」。不应据 `ready`
  判断设计通道可用性。

### 回归测试

- 既有 4 个用例靠伪造 `tts.variant=voice_design` 断言「instruction 音色可合成」，
  该状态任何部署都无法产生，且与 REST 契约直接矛盾，是本缺陷长期潜伏的原因；
  已改为钉住真实行为。快照矩阵测试此前未绑定设计制品，同样未覆盖生产配置。

## [3.5.3] - 2026-10-02

### Fixed

- 修复 Realtime 的 `alignment` 开关**静默吞掉全部结果**：`alignment.done` 与
  `alignment.failed` 一个都不会发出，客户端开启后只能无限等待。陈旧性守卫原本把
  `item_id` 与 `transcript_revision` 也当作抑制条件，但这两者恰好会在 commit 清理
  里被重置（`_reset_turn_observability()` 把 revision 归零、随即推进 item id），
  而对齐任务就调度在这个时刻前后——真机实测**每一个**结果都因此被判 stale
  （`fixed_text_stale` 9/9）。守卫本意是拒绝跨连接的陈旧结果，而事件本身带
  `utterance_id` 与 `transcript_revision`、契约也要求客户端自行丢弃旧 revision，
  因此改为只在 `task_id`/`epoch` 变化（即连接已失效）时抑制，且此时**仍发
  `alignment.failed`**，不再静默返回。晚到的结果照常送达，但不再推进下一轮的
  `metadata_revision`、也不再回写分人账本。

  连带修好分人归属：契约承诺「已 frozen 的文本不会出现有 final 无归属」，而
  在途对齐结果此前必被丢弃，该保证实际不成立。

  回归测试显式复现 commit 清理后的时序（既有 realtime 用例用同步 fake，
  对齐任务总能抢在清理前跑起来，覆盖不到这个竞态）。

## [3.5.2] - 2026-10-02

### Fixed

- 修复可懂度数字门禁的两类**误杀**：逐位念长数字串时用于区分 1/7、0/O、3/8 的
  澄清字（`幺`=1、`丁`=3、`尜`=9）此前被当作非数字丢弃，于是「幺幺零」只剩 `0`，
  与 `110` 判不等——报警电话念对了却被拒；澄清字现只在长度 ≥3 的数字串内折叠，
  `园丁`、`幺妹`、`一点丁点` 不受影响（`一点丁点` 的 `一丁` 是量词不是十三，
  两字串正是歧义区）。另修前导零：`09` 与 `9` 现在按数值相等，只剥整数部分，
  `0.05` 与 `0.5` 仍然不等。

  依据是 43 条对抗性数字探针的受管 TTS → 受管 ASR → 实际门禁函数实测。
  这批实测同时**推翻了 #127 原有的判断**：换对抗语料后 `numbers_exact=False`
  出现 11/41，惩罚项改变判定 6 次，其中 2 次正是 issue 原文描述的
  「字符相似度过 0.92 但数字错了」，故 `numbers_exact` 予以保留。

  余下两处已知缺陷（斜杠/连字符丢弃致参考侧粘连、三段数 `3.5.1` 被抽成
  `['3.5','1']` 因而漏放）需重写数字 run 的定义，属契约变更，记于 #131。

## [3.5.1] - 2026-10-02

### Fixed

- 修复带标点或数字的语音拿不到任何时间戳：`verbose_json`、`srt`、`vtt`
  以及说话人分离的对齐此前会把常规英文与含数字的中文整段判成
  `502 timestamp_alignment_unavailable / text_mismatch`。对齐器切的是语音而不是
  排版——它按空白切词并只保留字母、数字和撇号，于是 `3:45` 变成 `345`、
  `forty-two` 变成 `fortytwo`，这些 token 并不是原文的子串，朴素的子串查找
  必然落空。改为先字面匹配、失败再退化到去标点投影上匹配并映射回原文码点：
  偏移仍然逐码点指向调用方已发布的冻结文本，排版差异不再被误判成文本不一致。
  词粒度的判定同步改用对齐器自身的可保留字符集——厂商保留撇号，旧的全角标点
  禁令会把 `don't` / `it's` 这类普通英文词判成 `granularity_unsupported`。
  被剥掉的标点归还给它原本所属的那个 token，否则它会漏进下一个词的前导间隙，
  对外读成 `". on"`、`", two"`。字面命中路径维持既有规则不变（未读出的排版归
  后一个词），emoji 的归属由既有测试钉住。
  回归用例取自真实 `mlx_qwen3_asr` 的 tokenizer 输出而非手写近似。

- 修复 bf16 对齐器永远无法加载：`_normalize_dtype` 只认字符串，而 MLX 的 dtype
  是枚举对象（`str()` 得到 `mlx.core.bfloat16`），于是每个 bf16 aligner 都被判为
  「未上报 dtype」而拒绝加载。整条对齐路径（含说话人分离）此前从未真正跑通，
  既有测试传的是字符串 `"mlx.core.bfloat16"`，正好把这个缺陷盖住了。

- 修复 REST 时间戳请求整段 500：ASR 侧曾隐式带上 `include_timestamps=True`，
  而厂商在开启时间戳时会无条件解析其默认的 `Qwen/Qwen3-ForcedAligner-0.6B`
  仓库；该仓库不在本地缓存，worker 又运行在 `HF_HUB_OFFLINE=1` 下，
  于是每个带时间戳的转写都以不透明的 500 收场。改为 ASR 只出文本，时间戳
  交由本就已接线的独立 `FixedTextAligner` 在冻结文本上计算——与同一路由中
  说话人分离所用的是同一个 owner，且不会让 ASR 的物理 owner 混用 aligner 身份。

- 修复音色设计在缺少 `reference` 块时按非空断言崩溃：`VoiceQualityReport.reference`
  已是可选字段，调用方未同步，导致本轮改动引入的必现崩溃。

### Changed

- 把 14 处散落的裸写视觉常量收进既有 token 家族（`Icon.statusDotSize`、
  `Icon.liveIndicatorDotSize`、`Icon.axisLabelFrame`、`Icon.artifactFrame`、
  `Icon.dismissButtonFrame`、`Icon.segmentJumpFrame`、`Typography.iconMicroSemibold`、
  `Typography.iconMediumSemibold`、`Typography.iconMedium`、
  `Layout.waveformBarAreaHeight`、`Layout.personaEditorMinimumHeight`、
  `Layout.inputLevelMeterHeight`），**取值一律保持原样**：本轮只改声明位置，
  不改渲染结果。收敛过程中暴露出一个此前没人注意的分裂——同一个「实心圆点」
  语义同时存在 `Icon.statusDotSize`(8) 与 `Menu.menuBarStatusDotSize`(6) 两个尺寸
  且互不相通；本轮不合并，统一到哪个值需要真机比对，仍记为未验证。
  Debug 与 Release 均 `BUILD SUCCEEDED`。未做桌面视觉走查、VoiceOver、
  Reduce Motion 复核，对比度真机结论仍为未验证。

- 修复中文数量级在探针文本比对中不被当作数字：`normalize_transcript_for_match`
  的数字归一化只逐字覆盖 `零`–`九`，`二十二`、`五千三百` 这类含数量级词的读法会以
  字符形式进入编辑距离，逐字忠实的合成因此被扣分（`二十二度` 对 `22度` 仅 0.09）。
  新增 `resolve_chinese_magnitudes`：含数量级词的中文数字串按位值求值成阿拉伯数字，
  不含量位词的位序串（`三六九`、`二零二六`）仍按位翻译——`_chinese_to_int`
  本就区分这两类。`百分之` 由 `分之` 前瞻排除，否则 `百分之九十九` 会被读成
  `100分之99`。
- 修复 `production_ready` 随 TTS worker 常驻状态翻转：同一音色、同一
  `voice_revision`、同一份合成证据 `run_id`，冷态下被判
  `model_runtime_identity_unknown` 而 `production_ready: false`，合成一次把 worker
  叫醒后即变成 `true`。`qwen3_tts.runtime_revision` 只在 worker 常驻且 ready 时
  返回值，于是运行期身份被错误地绑到了 worker 占用上——变的是判定，不是证据。
  只读上报路径现在在没有常驻 worker 时改用证据记录自带的运行期身份，且只在它
  具备规范形态**并且**其指纹能由自身绑定维度重算出来时才采信，否则仍然 fail closed。
  生产合成路径不变：`prepare_validated_speech` 仍会启动 worker、观测实时身份并把
  `expected_runtime_revision` 钉在请求上，worker 常驻时报出不同运行期身份仍照旧
  判定证据失效。
- 修复 `quality-runs` 报告的 `reference` 子块恒为全 0 占位：这是**输出门禁**，从不评估参考音频，却下发 `duration_seconds: 0.0`、`noise_floor_dbfs: 0.0`、`estimated_snr_db: 0.0` 等值，而这些 0 对每一项参考指标都恰好是最差读数——单看报告会得出「参考音频 0 秒、噪声 0、信噪比 0」，方向完全反了。同一份报告的判定不受影响（该路径不调 `grade_reference_quality`），但消费方直接读该字段会系统性偏悲观地误读。现在该字段显式下发 `null`。没有选择回填音色档案里克隆当时的参考报告：那会把「本次未测量」表述成「本次测得」，且数值可能已过时。参考侧的真实结果仍由 `clone/validate` 在克隆时测出，经 `GET /v1/voices/{voice_id}` 的 `validation_state.reference` 下发。`VoiceQualityReport.reference` 因此在契约中改为可空（`oneOf: [VoiceQualityReference, null]`），`policy_version` 不变——判定逻辑未改，无需使既有证据失效。
- 修复可懂度门禁抓不住「念错数字」：字符编辑距离对数字失灵。`numbers_punct` 有 44 个字符，把 `22.5℃` 念成 `25℃` 只造成一处替换，相似度 0.9375，照旧高于 `pass` 所需的 0.92；`9月9日` 念成 `9月19日` 是 0.9697。门禁因此对数字类发音错误几乎无感知，而依赖 `production_ready=true` 的正式合成可能带着错误的数字播报出去。新增 `transcript_numbers_match`：两侧归一化后逐位比对数字串，完全一致才算通过。逐条 `probe_scores[]` 新增 `numbers_exact`（不含数字的 probe 为 `null`，与「查过且不符」区分），聚合时该条记 0 分。逐条 `transcript_match` 仍如实上报真实字符相似度，所以判定既关得住漏放又能归因到具体 probe。适用性由 probe 文本是否含数字决定而非硬编码 probe id——`pause_markers` 的「第一点/第二点」归一化后同样带数字，因此也受约束，念错序数一样会被抓住。归一化先行，所以 `二十二点五` 与 `22.5` 是同一个数字，不会误判。`policy_version` 不变：阈值与判定流程未改，只是同一条 probe 多了一道数字校验。
- 精简 MCP server `instructions`：该字段在 initialize 时随每个会话下发，其中成段的操作规程与 `assets/skills/speechrail/` 里的权威文本重复，等于让每个会话的首轮上下文重复付费一次而收益为零。规程下沉后只保留能力陈述、边界，以及「读错会做出错误动作」而非「只是慢一点」的断言（`available=true` 不等于 `production_ready=true`、参考门禁不等于输出门禁、机器验证不替代人工试听、MCP 不建会话），末尾指向 `speechrail` 技能。`clone_speed_unsupported` 此前只存在于该字段，技能侧并无对应文本，因此先把「Base clone 固定 speed=1.0、这是能力不匹配而非瞬时错误、不要换 speed 重试」补进`references/errors.md`，再从 `instructions` 移除。回归用例锁住双向：规程不得回流，高代价断言不得删。

## [3.5.0] - 2026-10-01

### Fixed

- 修复音色质量输出门禁把所有克隆音色判为 `transcript_mismatch 0.76`：
  `synthesis.transcript_match` 是六条固定探针的 `min()`，而其中两条探针的文本含有
  TTS 根本不发音的排版符号，逐字忠实的合成也会被扣分，于是这一条差异把所有音色
  一票否决。实测（3.4.2 运行时，voice `wom-d2888cc51194ee2e`）两条元凶是：
  - `pause_markers` 的 `……`。TTS 不发音、ASR 也不会返回，而 NFKC 把 `……` rewrite
    成 `......`，`.` 又是保留的语义符号（`22.5` 需要它），于是 25 字参考里凭空多出
    6 个字符误差，`min()` 聚合被压到 **0.76**（`<0.80`，直接 `reject`）；
  - `numbers_punct` 的 `22.5℃`。TTS 读出「摄氏度」，ASR 原样写回，两侧只差记法，
    该条被压到 **0.9091**（低于 `pass` 所需的 0.92）。

  归一化现在折叠口语单位（`摄氏度`→`°C`）并丢弃成串省略号（`\.{2,}`，单个点保留
  给小数）。实测同一条真实 ASR 输出下 `min()` 聚合由 0.76 回到 1.0，四个音色
  （三个克隆 + 一个系统）结果一致。回归测试改用真实 ASR 实际输出而非手写理想文本
  —— 早先用理想文本会放过真实 ASR 根本过不去的探针。
- 质量报告新增 `synthesis.probe_scores`，按固定探针集顺序逐条下发
  `probe_id` 与该条 `transcript_match`。此前只给 `min()` 聚合值，无法区分
  「整体不可懂」和「某条探针文本不适配」，排障只能看到四个音色同分而看不到是哪条
  探针拖的。
- 修复发布流程能把版本漏 bump 的 wheel 当成成功安装装上去：`speechrail install`
   在 `/readyz` 返回 200 之后还会比对运行中服务 `/health` 自报的 `version` 与正在
   安装的 wheel 版本，不一致即 fail closed 并退出 1。此前 `Settings.version` 的
   硬编码默认值（`src/speechrail/config/__init__.py`）漏 bump 时，构建、preflight、
   `/readyz` 和安装全部显示成功，而服务自报的是上一个版本号。
- `check_version_consistency.py` 移进 release skill 的构建代码门（原先只在打 tag
   前出现），并且 `pytest` 现在直接校验真实仓库树
   （`test_repository_tree_version_is_consistent`）——此前该脚本的测试全部跑在
   合成的 `tmp_path` 树上，只能证明检查器本身可用，无法发现当前 checkout 不一致。

### Added

- `VoiceQualitySynthesis.probe_scores` 进入 `contracts/openapi.yaml` 的
  `VoiceQualitySynthesis`，作为向后兼容的新增响应字段下发。

## [3.4.2] - 2026-09-30

### Fixed

- 修复语音助手播放回答时末尾出现突兀杂音：Realtime 流式 TTS 的最后一个 codec 帧
  停在模型收尾的那一刻，常常落在元音中间、样本值很大，扬声器把这个跳变听成一声
  "咔哒"。实测同一句话 8/8 都在非零振幅处直接切断，末尾静音 0 ms；批式
  `/v1/audio/speech` 因为一直对最后一块做 5 ms 淡出，0/8 出现。现在流式在终态前
  补一段同样长度的淡出斜坡，斜坡从实际发出的最后一个样本值起步，因此是延续波形
  而不是另起一段；它作为一帧普通音频发出，`chunk_index` 与 `sample_offset` 保持连续，
  合成期间不扣留任何音频，短句不会被推迟。

## [3.4.1] - 2026-09-30

### Fixed

- 修复单句语音无法定稿：Realtime 流式 ASR 在 commit 时几乎必然整体失败成
  `worker_inference_error`，客户端只收到 `transcription.failed` 而从不收到
  `conversation.item.input_audio_transcription.completed`，因此已经识别出来的文字
  无法进入后续 LLM/TTS。根因是 vendor 在尾块解码没有新增文字时会走一次 tail refine，
  以已加载的 model 对象调用 `transcribe()`，导致 tokenizer 解析退回上游默认 repo id，
  离线环境下抛 `LocalEntryNotFoundError`。精修只用于补回漏字，committed text 本身
  已完整，现在关闭该分支。句中留有停顿时尾块会带出新文字而不进精修，所以此前表现为
  偶发成功。
- 修复流式 ASR 丢弃 worker 诊断细节：`error_frame_message()` 提供的 stderr 尾巴此前
  只有 `qwen3_native`、`qwen3_alignment`、`qwen3_shared` 三个后端在用，流式后端是唯一
  不记录的一处，导致这类失败只显示 `exception_type=None` 而看不到真实异常。现在
  stderr 尾巴进入服务端日志，Realtime `error.code` 仍保持短机器码。
- 修复语音助手「切换对话记录」卡顿：打开一条记录此前分四次串行读库并分四次更新
  SwiftUI 状态，界面逐段跳变；现在改为一次快照读、一次状态更新。
- 修复语音助手把已经识别出来的一句话静默吞掉：服务端返回空 final 时，客户端此前
  直接丢弃可见文字且不提示，用户看到「说完话文字一闪就没了」。现在保留该句并以
  `partial` 状态留在对话流，同时给出「这一句没能识别完整，请再说一次」的提示；
  该句不进入 LLM/TTS，因为未定稿文本可被后续改写，不适合作为权威输入。

### Changed

- Realtime 契约 4.2.0 → 4.3.0：补充第三条语音准入语义——空 final 不等于用户没有说话，
  客户端必须区分「没有语音」与「有语音但未能定稿」。

## [3.4.0] - 2026-09-30

### Added

- 支持用 `config/model_locations.json` 把指定制品绑定到 operator 自选的外部模型目录
  （例如 oMLX 统一管理的 `~/.omlx/models/<leaf>`）。未声明的制品行为完全不变；声明后
  SpeechRail 只读校验、不下载不写入，外部副本单列 `disk.external_bytes`。同一 key 同时存在
  外部绑定与受管副本时状态判为 `invalid` 并 fail-closed，删除该文件即完全回滚。
- `/health` 新增独立的 `tts_design`：报告 VoiceDesign 这一惰性能力自身的 `configured`、
  `ready`、`state` 与 `last_error`。读取健康检查不会加载模型，设计 lane 失败也不再牵连
  普通 TTS 的可用状态；一次成功重试即清除 `last_error`。
- TTS 错误 envelope 新增可选 `worker` 归因对象（`role`、`stage`、`attempt_id`，以及已观测到的
  `exit_code` 和允许列表中的 `exception_type`），用于把失败定位到具体 worker 与阶段，同时不
  返回原始 stderr、vendor 异常正文、模型路径或请求文本。

### Fixed

- 修复 TTS worker 的 stdout 可能污染 IPC 帧的问题：Python `print` 与原生 fd 1 输出现在统一
  转到 stderr，二进制协议改用独立描述符。此前 vendor 或依赖在加载、生成过程中的一行普通
  输出就足以让 `/v1/voices/previews` 持续返回 503 `tts_transport_failed`。
- 修复 VoiceDesign 失败不可归因：启动握手失败此前一律记为 `deliver` 阶段，EOF、帧大小、
  帧解码与管道关闭也没有区分。现在按真实阶段与安全原因分类，长单行 stderr 也按 16 KiB
  有界环形缓冲截取，不再被整行丢弃。
- 修复音色试听把资源准入记到默认系统音色 lane 的问题：预览改为保守的 `tts` 准入；候选创建
  与候选 Base 验证统一使用 TTS 错误映射（初始化/传输 503、推理/输出 502、参数 400），
  不再各自返回不一致的状态码。
- 修复进程内音色解析不认识未发布 VoiceDesign 候选的问题：`get_voice_profile` 与
  `VoiceRegistry.get_profile` 现在与 `lease_profile` 一致地解析临时 profile，未发布候选不再
  被误判为 `unknown preset voice`。

## [3.3.4] - 2026-09-28

### Fixed

- 修复语音助手断句过于频繁：Realtime 各场景的静音断句窗口此前散落为硬编码裸数字（语音
  助手与提词器 400 ms、会议 900 ms），助手说一句话里的自然停顿就会被提前切断。现在按场景
  统一取预设：语音助手轮次 1200 ms、语音助手全双工 900 ms、会议助手 900 ms、实时字幕
  400 ms、AI 提词器 400 ms。
- 修复语音助手「关闭推理」名不副实：端点若拒绝所选兼容模式的思考控制字段，此前会静默去掉
  该字段重发，生成出的内容并未真正关闭推理。现在探测与生成两处都直接失败并提示调整模型
  兼容模式，不再交付一份名不副实的结果。

## [3.3.3] - 2026-09-28

### Fixed

- 修复语音助手端到端链路的 19 项缺陷（App D01–D11、服务端 B01–B08）：回复身份与收尾
  不再随打断漂移，`stopCapture` 期间的落库竞态不会让 `partial` 行永不转 `final`；
  重连后按连接代次丢弃旧连接的晚到事件；Realtime 的 ASR 准入、TTS 终态与
  `session.update` 在并发下有确定语义，`session.update` 改为候选状态构建成功后一次性
  发布，不再留下部分生效的会话状态。
- 修复正式配音与正式制作的输出验收：正式路径强制严格验收并绑定运行身份，拒绝后不留
  待保存音频。
- 修复 macOS App 运行监控页趋势图刻度越域与单帧采样漂移，并固化崩溃指令级证据。

## [3.3.2] - 2026-09-28

### Fixed

- 修复客户端结束录音后可能拿不到尾句终态：Realtime 的 `input_audio_buffer.commit` 与后续
  `transcription.completed` / `failed` 之间没有可观察的关联，调用方只能凭到达顺序猜测，
  一次在途的 VAD 终态就会被误判成自己那次提交的终态。服务端在终态上回显提交方的
  `event_id`（`commit_event_id`），契约升到 `4.1.0`；VAD 或 rollover 产生的终态不带该字段。
- 修复词级对齐与分人耦合：`session.speechrail.alignment.enabled` 此前必须同时开启
  diarization 才生效（PCM 缓冲与对齐 epoch 都挂在分人开关下），单独开启对齐静默无效。
  两者现在各自独立生效，且都只能在首个音频帧之前改变。
- 移除 `session.speechrail.alignment.precision`（`q8` / `bf16`）：单服务单 worker 的边界不允许
  按连接重建对齐模型，这个开关此前接受了却无法兑现。对齐精度改由 active profile 在进程启动时固定。
- 修复 `speechrail.diarization.finish` 的封存竞态：封存前会先等齐当前 item 尚在进行的对齐任务，
  已 frozen 的文本不再出现「有 ASR final、无归属」的结果；等待超过
  `realtime_diarization_drain_deadline_seconds` 时按 `finalization_timeout` 降级。
- 修复非法 Realtime 事件之后会话资源不释放：事件解析失败时直接抛出，会话的 PCM 缓冲、
  对齐任务与准入名额都留在原处。
- 修复持久化转写任务不执行分人：`POST /v1/jobs` 的分人参数此前只写进任务元数据，
  执行器既没有分人引擎也没有对齐器，转写悄悄退化成单人单轨。执行器现在真正挂载分人引擎、
  固定文本对齐器与独立的 `DiarizationAdmission`；MCP 的分人转写工具同步对齐真实 REST 契约。
- 修复分人能力缺失时的失败时机：请求要等到转写跑完、产出已落盘后才因缺分人能力失败。
  现在在转写开始前就以 `diarization_unavailable` 拒绝，不浪费一次推理。
- 修复异步任务产物释放不可恢复也不受界：`DELETE /v1/jobs/{job_id}` 与 TTL 过期此前先把
  `result_ref` 置空再谈清理，删除失败或进程中断就留下无人认领的产物目录。新增
  `runtime/job_artifacts.py` 统一判定产物归属：先删本地产物树、成功后才释放引用，失败按
  `cleanup_after` 退避重试并有批次上限；解析拒绝绝对路径、`..`、跨 job 引用与符号链接目录。
- 修复幂等重放时 durable 幂等键未完成的问题：`POST /v1/jobs` 带 `Idempotency-Key` 重放命中
  已存在的任务时不再直接返回，幂等记录会补写完成；补写不可用时返回可重试的
  `503 idempotency_store_unavailable`，而不是让调用方拿不到键状态。
- 修复 macOS App 运行监控页在宽窗口下的布局：趋势图与运行组件改为并排且两张卡等高，
  组件行吸收剩余高度向下铺开；窄窗口仍回退到趋势整宽、组件落到下方的竖排。

## [3.3.1] - 2026-09-28

### Fixed

- 修复 macOS App 语音助手 / 会议 / 实时字幕一律连不上服务的问题：服务端 Realtime 传输层的事件 `sequence` 先自增再打戳, 首个 `session.created` 成了 `1`, 与契约 §5「sequence 从 0 连续递增」不符。App 的序列号校验按契约要求首个事件必须为 `0`, 于是把每个新连接都判成缺口并立即关闭, 表现为「语音服务事件顺序或身份无效」。服务端改为先打戳再自增, 恢复 0-based 连续编号。
- `ManualTurnCollector` 的起始哨兵由 `0` 改为 `-1`。它的 `start_sequence` 表示**已消费**的最后一个序号, 下一个事件必须是 `start_sequence + 1`; 在 0-based wire 上「尚未消费任何事件」的默认值只能是 `-1`。此前该参考消费者与被测服务端一起停在 1-based, 使编号缺陷无法被测试发现。
- 修复词级对齐在过期结果上抛异常：`dd041b35` 新增了 `record_alignment_event("fixed_text_stale")` 调用点, 却没把该标签登记进 `_ALIGNMENT_EVENTS` 有界集合, 记录函数因此抛 `ValueError`。抛出点位于**错误处理路径**, 于是本应按契约降级为 `speechrail.alignment.failed` 的情形变成异常, 日志留下 traceback 且对齐静默丢失。补齐标签登记, 并新增一条交叉守卫测试: 扫描全部 `record_alignment_event` 调用点, 任何未登记的标签都在测试期失败。
- 修复助手朗读打断时泄漏后台任务：`cancelServerBounded()` 用两个无句柄的 `Task` 竞速「网络取消」与「超时」, 闩只放行一次, 因此**每次取消都必然漏掉一个任务**; 后端不回话时那个网络任务会一直挂到进程结束。`fail()` 与 `stopPlaybackNow()` 同样是发出去就不管的无句柄任务。三个位置改为保留句柄, 并由 `invalidate()` 统一取消, 与既有的 `pumpTask` 约定一致。

## [3.3.0] - 2026-09-27

### Added

- macOS 模型管理界面支持混合档位组合：三张快捷组合卡之外新增「分别调整识别与配音」，下载 / 应用统一提交一对 `asr_spec`/`tts_spec`，混合组合按两档制品并集显示总量。
- 新增 MCP 工具面对齐门 `scripts/check_mcp_tool_contract.py`，校验 `tools/list` / `resources/list` 与用户指南、Proxy 契约文档、`skill-manifest.json` 一致，并接入 CI 与验收清单。
- 新增用户文档对齐门 `scripts/check_user_doc_contract.py`：校验契约中的每条路径都出现在 API 契约手册、手册标准错误码表中的每个 code 都有实现、服务实际下发的每个模型别名都被手册点名，并接入 CI。
- `scripts/check_openapi_contract.py` 改为直接比对路由表（递归展开 FastAPI 的 `_IncludedRouter`），并新增成功状态码与 security scheme 校验。

### Changed

- 服务在 `GET /openapi.json`、`/docs` 与 `/redoc` 提供 `contracts/openapi.yaml` 本身，不再发布 FastAPI 生成的近似契约；生成结果缺少错误响应、Bearer 方案与 SpeechRail 扩展，客户端据此生成的客户端会与真实行为不符。契约随 wheel 一同发布（`speechrail/assets/openapi.yaml`），为此新增运行时依赖 `pyyaml`。
- `POST /v1/voices`、`POST /v1/voices/clone`、`POST /v1/voice-designs` 与 `POST /v1/voice-designs/{candidate_id}/publish` 的路由装饰器补齐 `status_code`，使生成视图与契约一致。
- macOS App 与服务版本统一升级到 3.3.0，App build 升至 35。

### Removed

- 移除旧档位（`extreme`/`balanced`/`light`）体系：删除 `PresetId`、`ModelPreset`、`TierPrecision`、
  `ModelCatalog.preset()`、`precision_policy`、legacy `prepare_models()` 及 catalog / 元数据中的
  `presets` 块；模型选择统一为 ASR / TTS 两项独立 spec（`fast`/`quality`/`reference`），旧档位名在
  API / CLI / MCP / App 上明确拒绝。

### Fixed

- 修复 macOS App 模型页无法展示各档位与模型：`model catalog` / `model status` 的机器输出绕过了 envelope，直接打印 payload，前者因此把 ModelCatalog 文档版本 `2` 放在 `schema_version` 上，控制 Agent 按控制面 schema 校验后判定输出非法，模型页只剩失败横幅。现在这两条命令统一经 `_print_machine` 输出，envelope 版本由 CLI 掌握，payload 无法再改写它。
- 模型目录档位摘要的克隆 Base 权重字段与服务的 `tts_base` 对齐（此前 App 按 `tts_clone` 解码，恒为 nil，「支持（含克隆）」永远不显示）。
- 模型页补齐任务级按需能力：分人（`required_by: ["diarization"]`）与音色创作（`["voice_design"]`）不再绑定档位，此前不进入任何档位表、在页面上完全不可见，且分人小节因读一个服务早已不再下发的档位标志而永不出现。现在两者各自单列，分人补上来自 `/health` 的运行态；新增「语音活动检测」小节展示 VAD 引擎与就绪状态。
- 修复音色设计（VoiceDesign）被错误绑定到 `reference` 档的问题：设计制品现在是唯一、与档位无关的按需模块，任何 ASR/TTS 档位都能进入设计作业；macOS App 的能力显示同步改为按目录里是否存在设计制品判定。
- 模型完整性校验将制品根目录 `README.md` 视为非运行时文档；已有匹配的权重、配置与 tokenizer 可直接登记复用，不再因文档差异触发重新下载。

## [3.2.1] - 2026-09-24

### Changed

- macOS App 与服务版本统一升级到 3.2.1，App build 升至 32。

### Fixed

- 修复提词器跟读链路、分段切换和舞台控制状态，恢复实时跟读与工作区菜单的一致性。
- 统一模型存储与选择校验，移除已退役的 Q4 权重目录，避免错误模型被选择。
- 修复 App 重复注册与安装副本识别，确保本机只登记一个正式安装。
- 保持设置页连接反馈和运行监控布局稳定，补齐 macOS 回归测试目标。

## [3.2.0] - 2026-09-23

### Added

- 增加 BF16 `extreme` 候选档位；模型目录与 OpenAPI 明确描述未量化权重精度和档位所需的 CoreML 分人资产，macOS App 展示档位、模型及当前可用能力。MCP 只报告当前档位能力，不负责切换档位。
- 改进提词稿整理与跟读流程，补充字幕延迟观测，并简化舞台阅读界面。

### Changed

- 统一 macOS 控制台、语音、会议和提词器页面的主要导航与交互控件，提升跨页面操作的一致性。
- macOS App 与服务版本统一升级到 3.2.0，App build 升至 31。

### Fixed

- 修复 App 服务能力发现与音色预览控制；正确解析安全音色描述符。

### Known limitations

- `extreme` 候选档位的质量、资源和延迟仍待验证；本次发布不代表其已通过质量或性能验收。

## [3.1.3] - 2026-09-21

### Fixed

- 使用 `self.sourceRange(for:source:)` 消除局部变量遮蔽，兼容 Xcode 26.6 的提词器 App 编译与测试目标。
- macOS App 与服务版本统一升级到 3.1.3，App build 升至 25。

## [3.1.2] - 2026-09-21

### Fixed

- 补齐提词器第二处 `TeleprompterSourceRange` 构造的显式类型，避免 Xcode 26.6 在 App 构建与测试目标中触发 Swift 类型推断失败。
- macOS App 与服务版本统一升级到 3.1.2，App build 升至 24。

## [3.1.1] - 2026-09-21

### Fixed

- 为提词器选区的 `TeleprompterSourceRange` 构造补充显式类型，兼容 Xcode 26.6 / macOS 26.5 的 Swift 类型推断。
- macOS App 与服务版本统一升级到 3.1.1，App build 升至 23。

## [3.1.0] - 2026-09-21

### Added

- 新增 AI 提词稿的有界整理、可恢复重试、跟读延迟观测和脱敏 JSONL 日志/metrics，覆盖 Chat、Responses、流式与后台轮询路径。
- 新增任意 OpenAI-compatible endpoint/model ID 配置，并支持 OpenCode Go 与本机模板兼容模式。

### Changed

- SpeechRail 所有 LLM 模式不主动开启 thinking；通用模式使用标准关闭字段，provider 拒绝后最多省略控制字段重试一次。
- macOS App 与服务版本统一升级到 3.1.0，App build 升至 22。

## [3.0.2] - 2026-09-20

### Changed

- 完善 AI 提词器用户旅程：AI 朗读标注保持可选，准备页明确区分开始跟读与只打开舞台，AI 建议待确认时要求用户确认或明确跳过。
- 跟读舞台增加当前阅读切片强调、进度反馈、开始/暂停/继续语义和手动校正提示，降低直播中的状态误判。

### Fixed

- 修复 AI 建议待确认时可能误用旧跟读版本开始的问题；跳过建议现在会明确生成原稿跟读版。

## [3.0.1] - 2026-09-20

### Fixed

- 修复 Release 页 DMG 里那个 App「控制通道不可用」：Release workflow 用 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` 构建，App 只剩 linker 写进二进制的 ad-hoc 签名（签名标识为 `PRODUCT_NAME`、没有 `Contents/_CodeSignature/CodeResources`），而内嵌 `com.speechrail.desktop.local-control.xpc` 的 peer 策略要求 `identifier "com.speechrail.desktop"`，于是 XPC 校验以 `errSecCSReqFailed`（`xpc_support_check_token ... status: -67050`）拒绝每个控制请求：App 显示「控制通道不可用」、诊断页报「操作未完成」，而 REST 只读信息仍正常。workflow 现在沿用 `Release.xcconfig` 的 ad hoc 签名（`CODE_SIGN_IDENTITY=-`，不需要证书），并新增打包门禁 `scripts/macos_app_verify_local_xpc.sh`：签名标识必须等于 bundle identifier、签名必须在盘上有效、local XPC helper 必须存在且带 `SPEECHRAIL_ALLOW_UNSIGNED_XPC=1`，任一项不满足就在构建后立刻失败、不再生成 DMG。

## [3.0.0] - 2026-09-20

### Breaking

- Realtime 重置为 current-only、无状态 Speech Plane：客户端只发送 `transcription_session.update`、音频 buffer 事件和 `speechrail.tts.create/cancel`；旧 `session.update`、conversation text item、`response.create/cancel`、`response.audio.*` 与双 wire profile 均明确拒绝，不提供 alias 或 `/v2` 迁移层。
- SpeechRail 不再承担服务端 LLM、conversation history、memory、persona、tool calling、播放或 barge-in 策略；调用方/Native 负责完整助手编排，MCP 仍只代理无状态 REST，不持有 Realtime handle。

### Changed

- Native `AssistantSession` 以本地 LLM/history/memory 为编排根，按本地句子队列逐条提交 caller-owned TTS；VAD speech facts 不再由服务端自动取消 TTS。
- MCP `describe()` 显式发布 `orchestration=caller`、`server_llm=false`、`conversation_state=false`、`websocket_path=/v1/realtime` 与 `mcp_realtime=false`。

## [2.7.0] - 2026-09-17

### Added

- 安装入口随 wheel 发布：managed 安装器从仓库脚本 `tools/install_macos.py` 迁入包内 `speechrail.service.managed_install`，并暴露为 `speechrail install --preset <tier> --yes [--enable]`。只下载 release 的用户现在只需要 wheel 与 `uvx --python 3.12`，就能完成 release staging、按档位准备并逐文件校验模型、preflight 和原子 `runtime/current` 切换；`--enable` 再注册并启动 `com.speechrail`。命令拒绝版本与自身不一致的 wheel（否则 installer 会与被安装的代码脱节），默认只安装不启动。`tools/install_macos.py` 保留为兼容外壳，只重导出同一实现，不新增第二条安装路径。
- CI 在 macOS 打包阶段用刚构建的 wheel 真实执行 `speechrail install --help`，"release 可独立安装"因此有回归门，而不只是文档承诺。
- `install_managed(...)` 增加可选 `progress` 回调，安装过程可按阶段回报进度。
- `speechrail install --enable` 现在会轮询 `/readyz` 再报告结果：就绪时打印服务地址与 HTTP 200，超时不算失败，而是打印 preflight 与 curl 排查命令；命令结尾固定打印已安装 runtime 的 `speechrail` CLI 路径和双击即可换档位的 `SpeechRail 设置.command` 路径。
- `speechrail install` 开始前给出下载计划：只读本机登记表（新增公开查询 `registered_prepared_artifacts()`），模型已登记时打印 `expect no download`，否则列出待下载制品与上限；过程中把原始事件渲染成 `Reusing verified model …` / `Downloading … 30% (0.9 GiB / 2.9 GiB)`（每 10% 一行，不再逐块刷屏），结束后打印本次实际下载量。`--json` envelope 相应增加 `downloaded_bytes` 与 `reused_artifacts`。

### Changed

- macOS App 对齐到 2.7.0（build 17）。
- [安装与首次使用](docs/users/installing-speechrail.md) 改为 release wheel 优先：安装、升级、卸载都用已安装 runtime 自带的 CLI，clone 仓库的零配置流程下沉为 2.6.6 及更早版本的路径。根 `README.md` 与 [运行时与部署](docs/operations/runtime-deployment.md) 同步，后者的安装示例改用 `speechrail.service.managed_install`。
- `speechrail install` 的首次使用门槛按实测反馈收紧：只有一个 app home 时省略 `--preset` 会沿用已安装档位（不再被内存推荐改档），缺 `uv` 时在准备模型前直接给出安装地址，两类阻塞失败（服务在运行、显式档位与已装档位冲突）翻译成可直接复制执行的命令而不是原始 installer 错误。
- [安装与首次使用](docs/users/installing-speechrail.md) 补上"升级不会重新下载已校验模型"的判定依据（`prepared_id` = 档位 + runtime lock + 逐文件 sha256）、`runtime/releases` 旧目录不会自动清理及各档位实际磁盘占用口径。

### Fixed

- 修复 v2.7.0 tag 触发的 Release 在 `Create and verify unsigned DMG` 失败、导致 `publish` 被跳过：App 的 `MARKETING_VERSION` 仍停在 2.6.6，而 `scripts/macos_app_create_dmg.sh` 要求 bundle 版本等于 tag 版本。App 已对齐到 2.7.0（build 17），并把 `MARKETING_VERSION`（App Debug / Release / Distribution 三个 build configuration）纳入 `scripts/check_version_consistency.py`——同类漏 bump 今后会在仓库门禁和本地预检就失败，不会等到 tag 之后才暴露。
- 修复滚动指标写入者在停止时漏计已落盘的一行：`flush()` 把阻塞追加交给工作线程执行，而 `stop()` 的取消只会让 `await` 抛错，线程本身停不下来——那一行照样写进文件，`written` 却不再递增，两边此后一直相差一行。2.6.6 里加的 0.02 秒等待没有消除这个窗口，只是换个方向暴露（主 CI 上出现 `assert 4 == 3`）。现在 `flush()` 把取消交给调用方之前先等这次追加结束：文件行数与计数器按构造一致，测试也去掉了那个固定等待。
- 修复 `uv` 失败分类失配：`install_managed` 原先按字面量判断 `command[0] == "uv"`，CLI 传入绝对路径后所有 `uv venv` / `uv pip install` 失败都会被误报成「installed service command failed」；现在按可执行文件名判断，失败信息仍指向真正出错的 `uv`。

## [2.6.6] - 2026-09-17

### Fixed

- 修复 macOS UI 测试停在重设计之前的断言，tag 触发的 Release 因此无法发布：三条用例仍在检查旧侧栏分组名「服务」（现为「引擎」）、旧页首文案「确认本机语音服务能否使用」（页首现在取 `AppRoute.overview.pageSubtitle`）、只有「查看检查明细」展开后才存在的诊断两栏清单，以及已搬进「服务」页签的「最低系统」。现在用例按当前设计走：诊断页从「未发现问题」结论面板展开清单，设置窗口断言「通用」页签自己的小节。受此影响，v2.6.4 与 v2.6.5 的 tag 都没产出 GitHub Release——v2.6.4 没有对应的 Release run，v2.6.5 的 run 在复用 CI 的 `macOS App Build & Tests` 上失败、`publish` 被跳过；v2.6.6 一并交付这两个版本的内容。
- 修复 macOS 指标解析无法被 SwiftPM 测试覆盖：`RuntimeMetricsSampler.labelValue` 改为 `public`，`ControlKitTests` 按服务端真实 JSON 形状补齐时延分位、并发与 worker 解析用例（+578/−8）。
- 修复 `tests/test_observability.py` 的滚动指标轮询用例偶发失败：取消 task 与最后一次落盘竞争，断言时行数偶尔比实际写入少一行；现在等最后一次写入完成后再断言。

### Changed

- 依赖更新（dev extra，运行时依赖未变）：`openai` 2.54.0 → 3.13.0（依赖树里 `distro` / `tqdm` 换成 `httpx2`）、`ruff` 0.16.5 → 0.16.7。
- macOS App 对齐到 2.6.6（build 16）。

## [2.6.5] - 2026-09-16

### Added

- 服务侧新增滚动指标摘要：每 60 秒向 `{app_home}/state/metrics-rollup/YYYY-MM-DD.jsonl` 追加一行区间 JSON（请求与失败数、合成/识别次数与音频秒数、时延分位、并发峰值、排队拒绝与 worker 驱逐、观测内存、worker 与 ready 状态），按 UTC 日期分文件、默认保留 30 天。`/metrics` 仍是进程内累计值、重启归零，超过单次 scrape 跨度的问题现在由这份历史回答。
- macOS App 新增「音色克隆」页面（`VoiceCloneView`）：参考音频录制（`VoiceRecordingController` + 本地 `AudioReferenceCheck` 门控）、提词稿选项、克隆接口调用与进度回执；`/v1/voices/clone` / `validate` / `quality-runs` 的调用封装在 `CreatorServiceClient`。
- macOS App 新增「开发者文档」页面（`DeveloperDocsView` + `DeveloperDocsContent`）：把「怎么接进本机语音能力」放在应用里，目录列按 Figma 4x 帧画成淡青底圆角块，正文渲染富文本 block（段落 / 要点 / 端点 / 代码块 / 复制）。

### Fixed

- 修复结构化 `http_access` 记录从不落盘：服务此前没有安装任何 logging handler，`~/Library/Logs/SpeechRail/*.log` 里 `grep http_access` 永远为零，排障只能用无时间戳、无耗时的 uvicorn 原始行。现在服务自行写入两份带轮转的文件（各 8 MiB × 5 份，目录 `0700`、文件 `0600`）：`speechrail.log` 为人读行并追加 `key=value` 结构化字段，`access.jsonl` 每个记录一行 JSON；uvicorn 自带 access 行关闭以免重复，日志目录不可写时退回控制台输出。
- 修复 `physical_footprint` 观测恒为不可用：进程枚举把采样器自己启动的瞬时 `ps` 子进程也当成服务进程，采样时它已退出，于是每次聚合都判为不完整，`/metrics` 的 `physical_footprint_bytes` 永远是 `null`（监控页的内存读数因此永远为空）。现在排除该瞬时子进程，读数恢复为真实的服务进程树聚合值，无法完整采样时仍如实返回 `null` + `physical_footprint_complete=false`。
- 修复 macOS 开发者文档目录列出现双重选中效果：系统 `List` 选中材质画在 `listRowBackground` 之下，原来的圆角块只铺了 `surface/railTint` 没铺底色，周围露出整行强调色带。现在选中行先铺一层与卡片同值的 `Color.field` 盖住系统层，圆角块叠在上面，选中反馈只剩一处。

### Changed

- macOS App 对齐到 2.6.5（build 14），并把运行监控页接到服务落盘的历史：时间窗从「App 内存采样的 1 分钟 / 5 分钟 / 本次会话」扩展出「服务落盘的 1 小时 / 24 小时 / 7 天 / 30 天」，读 `{app_home}/state/metrics-rollup/*.jsonl` 后按时长聚合成桶（1 小时跨度 60 秒一个点，30 天跨度 12 小时一个点）。结论句、六格数字、两张趋势图与卡页脚的空档 / 重启次数 / 内存峰值都按当前窗口走，历史在服务重启甚至停服期间仍然可见。App 不新增公共接口，直接读文件；目录按 `SPEECHRAIL_METRICS_ROLLUP_DIR`（环境变量或 `config/.env`）覆盖，日志目录同理，覆盖值缺失时回退到服务默认约定。

## [2.6.4] - 2026-09-15

### Fixed

- 修复 macOS 侧边栏导航使用自定义设计 token 而非系统原生组件，现改用 `NavigationLink` + `Label` 并新增 ⌘1-⌘8 路由快捷键。
- 修复安装器生成的 console script 硬编码 Python 绝对路径，导致 `runtime/current` 切换后 MCP 客户端（Codex、Antigravity 等）加载旧版代码；现在 entry point 委托给 `runtime/current` 动态解析。
- 修复 `speechrail service preflight` 不传 `--app-home` 时回退到 `Path.cwd()` 而非默认 app home，导致配置文件检查误报 missing。

### Changed

- 侧边栏状态指示器和导航行简化为系统 `Color` 和标准 `Label`，减少自定义绘制。
- App 控制面 UI/UX 重设计规范（`docs/design/2026-09-15-macos-uiux-redesign/`）作为迁移目标纳入仓库。
- 开发者详情开关（⌘⌥I）和路由快捷键菜单命令加入 App 菜单栏。


## [2.6.3] - 2026-09-14

### Fixed

- 修复 tag 触发的 Release 流水线无法发布：`.github/workflows/ci.yml` 与 `release.yml` 声明了相同的 concurrency group 表达式，而 reusable workflow 中 `github.workflow` 会解析为调用方名称，导致被调用的 CI 以 `cancel-in-progress` 取消同一 group 内的 caller 运行，`ci` job 从未创建、`publish` 被跳过。现为 `ci.yml` 改用独立的 `ci-${{ github.ref }}` group（直接运行时的 supersede 语义不变）。受此影响，v2.6.2 的 tag 未能产出 GitHub Release。

## [2.6.2] - 2026-09-14

### Changed

- 依赖更新：`onnxruntime` 提升至 1.30.0，并同步 github-actions 组（`astral-sh/setup-uv` 10.1.0、`actions/download-artifact` 8.0.1）。

### Fixed

- 修复 macOS 控制台在 Release 配置下编译失败：`ControlCenterWindowActivator` 仅在 `#if DEBUG` 下声明却被无条件引用，导致 tag 触发的 unsigned DMG 构建以 exit 65 中断并阻塞 GitHub Release；现将引用与声明同门控，Debug 行为不变。

## [2.6.1] - 2026-09-14

### Added

- 新增音色读取与更新接口 `GET /v1/voices/{voice_id}` 和 `PATCH /v1/voices/{voice_id}`，并在 OpenAPI 中登记 `VoiceProfile` 与 `UpdateVoiceRequest`。
- 新增 macOS 自定义音色库管理控制面：音色创建、预览注册反馈与库内生命周期操作均已接入受约束的控制链路。
- `/metrics` JSON 视图新增真实 runtime 资源观测与调度策略事实（`RuntimeMetrics`、`RuntimeRequestCounts`、`RuntimeHistogramSummary`、`RuntimeResourceSnapshot`），并明确 RTF 序列仅在分母为正时发出。
- 新增 tag 触发的 GitHub Actions 发布流程：在 arm64 runner 上构建 unsigned macOS DMG，并随 wheel 与 `SHA256SUMS` 发布到 GitHub Release。

### Changed

- macOS 控制台统一窗口 chrome、侧栏与设计 token，对齐品牌 logo 视觉语言。
- 模型管理视图区分“目标档位”与“活动中档位”、“存在”与“使用”，并让不可用控制动作按能力门禁禁用。
- 创作工作区与诊断视图改为结论优先、状态可解释的布局；服务状态、诊断恢复与运行监控闭环。

### Fixed

- 侧栏改用原生 macOS 导航语义，修复控制中心窗口激活与侧栏路由不可点击的问题。
- 菜单栏 popover 在打开控制中心窗口前先关闭，避免 UI 断言与导航被遮挡。
- voice design capability 在缺失时 fail-closed，控制面消息统一脱敏。
- 恢复 SwiftPM 与 operator docs 的 CI 门禁回归。
- 模型与分人制品完整性校验引入持久化 sha256 缓存（按 `size` + `mtime_ns` 命中），避免每次 inspect 重复读取大文件；缓存落在 app home `state/` 下并以 0600 原子写入。

## [2.6.0] - 2026-09-13

### Added

- 新增 macOS 26 SpeechRail 管理控制台工作区，分离创作入口与服务入口，保留配音台、音色创作、音色库和我的作品，并补充运行监控、诊断与模型管理视图。
- 新增模型下载、完整性校验、准备中断恢复和版本不匹配引导；所有模型准备操作都需要显式确认，运行时仍保持模型制品仓库外管理。
- 新增 Signal Loom 视觉语言和统一设计 token，覆盖窗口层级、颜色、排版、间距、状态信号、图表与品牌图标高光。

### Changed

- macOS 控制面统一采用以结论为先、状态可解释、普通用户与开发者分层的工作区结构；开发者 Inspector 只展示脱敏运行元数据。

### Fixed

- 修复 `/v1/audio/speech` 运行时 OpenAPI 将二进制音频响应误报为 `application/json` 的问题；请求校验错误在仅有一个字段失败时现在会安全返回对应 `param`，不暴露原始输入。
- MCP REST 错误转为工具错误时保留安全的 `param` 字段，并修正工具契约附录中已实现工具数量与破坏性标注的陈旧描述。
- 修复 macOS Developer Inspector 在 macOS 26 `Form` 语义合并后无法逐项访问的问题，保留其内部辅助功能子元素。

### Documentation

- 更新 MCP 集成指南：区分 Codex 本机 `stdio` 安装与 ChatGPT Web 通过远程 HTTPS MCP endpoint / Secure MCP Tunnel 的连接方式，并补充 ChatGPT 的本地文件与音频产物边界。
- 归档原始 macOS 设计包，并补充管理控制台、服务模块、运行监控、模型下载和 macOS 26 设计系统文档。

## [2.5.2] - 2026-09-13

### Fixed

- 同步 Realtime 分人扩展的 v1 JSON Schema、fixtures 与回归测试至运行时已发布的 `speechrail.diarization.updated` / `.done` / `.finish` 事件，修复契约校验和客户端结束屏障仍引用已退役名称的问题。

## [2.5.1] - 2026-09-13

### Fixed

- 修复 macOS 控制面与 managed runtime 的机器输出协议版本不一致导致启动、停止、重启和档位操作全部显示 `managed command failed` 的问题。

### Changed

- macOS 控制应用统一使用 `SpeechRail` 产品名并随 patch 发布品牌 icon，保持控制面与 managed runtime 同步发布。

## [2.5.0] - 2026-09-13

### Added

- 新增 Quality-only `POST /v1/voices/designs`：VoiceDesign 生成有界参考，经规范化和无提示 ASR 核验后，create-only 注册新 Base 音色；记录模型/seed/hash 来源，明确输出验收仍为 `unevaluated`，不迁移或覆盖旧音色。
- 音色质量复测新增本地 Batch ASR 内容复核：六类探针各取一个有效样本，缺少验证器时返回 `unevaluated` / `transcription_unavailable`；文本相似度阈值仍需真实语料校准。
- Quality TTS capability 新增锁定的 Qwen3-TTS Base 1.7B 8-bit `tts_clone` 制品；安装/切档、preflight 与 `/v1/models` 统一按 catalog 声明 reference-clone 能力。
- 新增 `Qwen3TtsCapabilityRouter`：Quality 使用独立的 VoiceDesign/Base TTS worker；两条 capability lane 可双常驻、可并发，同一 worker 仍串行，并保留 router 级 idle eviction 与冷驱逐后懒加载。

### Changed

- reference-audio clone 从 VoiceDesign 私有 ICL 调用迁移到 Base 的公开 reference-generation 接口；VoiceDesign 仅承担 prompt voice design，不再作为 clone fallback。
- `ResourceGovernor` 新增 capability-aware TTS reservation：Quality 的 `voice_design` 与 `voice_clone` 可并发，未知/同一 lane 继续保守串行；Quality heavy-overlap 预算按可能常驻的 TTS worker 数计算。
- README、公共 API 契约与架构文档同步新的 Quality 双 capability、Sona 两条音色创建链路、后续 VoiceDesign → canonical reference → Base 稳定化路线及当前质量门禁限制。

### Fixed

- 修复质量探针超限、流式调用提前结束时的生成器关闭与模型生命周期顺序；重复启动不会旁路加载或关闭另一 TTS capability。
- ASR 前模型 eviction 受统一绝对 deadline 约束；验证器异常不再把原始错误正文和 traceback 写入日志。

## [2.4.0] - 2026-09-11

### Added

- 新增可选的重计算重叠（ASR∥TTS）能力：`SPEECHRAIL_ALLOW_HEAVY_OVERLAP`（`auto`/`true`/`false`，默认 `auto`）与 `SPEECHRAIL_ASR_RESIDENT_BYTES` / `SPEECHRAIL_TTS_RESIDENT_BYTES` / `SPEECHRAIL_DIARIZATION_RESIDENT_BYTES`；仅在显式声明 worker 常驻字节且合计不超过本机物理内存预算时放行 ASR 与 TTS 的重计算重叠，未声明或超预算时 `auto` 保持 fail-closed。

### Changed

- `ResourceGovernor` 的重计算重叠由硬编码关闭改为按声明字节 + 预算判定，默认行为不变（仍 fail-closed）；`SPEECHRAIL_ALLOW_HEAVY_OVERLAP=true` 强制放行并绕过预算，由操作者显式承担内存风险。

## [2.3.2] - 2026-09-11

### Fixed

- `light` 档精度回退：验收门 E1 在公开真人语料（LibriSpeech test-clean + FLEURS cmn_hans_cn，CC BY 4.0）上实测 0.6B 4-bit ASR 相对 8-bit 基线劣化 **1.38pp**（en WER +1.25pp、zh CER +1.46pp），超过 0.5pp 阈值；依计划「未过即回退上一精度」，`light` 由 `asr-0.6b-q4` + `tts-0.6b-custom-q4` 回退为 `asr-0.6b-q8` + `tts-0.6b-custom-q8`（均 8-bit）。`asr-0.6b-q4` / `tts-0.6b-custom-q4` 制品保留在 catalog 但不被任何档位引用。

### Changed

- 三档精度策略统一为 8-bit（仅 `quality` 的 aligner 保持 bf16）；`light` 安装体积约 2.99 GB，catalog 与全部 active 文档同步更新。
- 验收记录更新：E1 由「仅代理语料」改为公开真人语料实测并触发 `light` 回退；E3 以公开 VoxConverse（CC BY 4.0）收口，aligner-q8 vs aligner-bf16 未劣化（DER 2.40% vs 5.04%），并如实记录 4/11 覆盖限制。

## [2.3.1] - 2026-09-11

### Fixed

- `install_managed(..., enable=True)` 现按目标档位自行供给分人 aligner（`aligner-q8`/`aligner-bf16`）后再写配置与执行 preflight，修复既有分人档从旧 release 升级时"新 wheel preflight 对旧 selection fail-closed、而 `profile apply` 又依赖新 runtime"的循环失败；供给失败按既有事务回滚，`resolve_selection` 的 fail-closed 守卫不变。
- `ModelCatalog.precision_policy` 现可安全深拷贝（`copy.deepcopy` / `model_copy(deep=True)`），JSON 序列化形状不变。
- `profile apply` 的 env 写入现能识别 `export KEY=...` 与 `KEY = ...` 形式并原地替换，不再追加重复键。

### Changed

- 文档：验收记录将 E1 记为 `UNVERIFIED-BLOCKING（仅代理语料）`；补齐分人档安装/升级的 aligner 前置条件说明；刷新陈旧版本基线。

## [2.3.0] - 2026-09-11

### Added

- 三档按用户定位重排并显式声明各自能力：`light`（Embedded）为 4-bit、不分人；`balanced`（Pro Workflow）为 8-bit 并对齐器 `aligner-q8`；`quality`（Studio）为 8-bit 并对齐器 `aligner-bf16`。
- 分人能力改为按档位声明：仅 `balanced`/`quality` 对外提供 `gpt-4o-transcribe-diarize`；`light` 不声明分人、也不供给 aligner。
- `profile apply` 按目标档位供给 aligner 等档位专属制品。

### Changed

- 模型精度改为按档位的 `precision_policy`，取代此前“三档统一 8-bit”的规则；`light` 使用 4-bit ASR/TTS。
- aligner 改为 catalog 中 diarization-scoped 资产，不再进入 `PreparedModelSet`，因此无需 `prepared_id` 迁移；词级时间戳仍由 ASR 原生提供，不依赖 aligner。

## [2.2.2] - 2026-09-11

### Fixed

- 修复 `speechrail-mcp` 代理在 managed runtime 下启动即崩溃（宿主报 `MCP error -32000: Connection closed`）：`mcp` 依赖上限从 `<2` 被自动放宽到 `<3` 后，安装态解析到 mcp 2.2.0，而代码仍使用 v1 的 `FastMCP` API（`mcp.server.fastmcp` 在 v2 已删除）。
- 将 `speechrail-mcp` 迁移到 MCP Python SDK v2：`FastMCP` → `MCPServer`，`ToolError` 由 `mcp.server.fastmcp.exceptions` 移至 `mcp.server.mcpserver.exceptions`；工具注册、`stdio`/`streamable-http` 传输与 `ToolError → is_error` 语义保持不变。

### Dependencies

- `mcp` 约束收紧为 `>=2,<3`；`uv.lock` 解析 `mcp 1.29.1 → 2.2.0`，新增 `httpx2`/`httpcore2`/`mcp-types`/`opentelemetry-api`/`truststore`，移除 `httpx-sse`。

### Verification

- 全量 pytest 1535 passed/1 skipped（覆盖率 82.33%）；ruff/mypy/redocly/plutil/git diff --check 通过；真实 stdio `initialize` + `tools/list` 握手返回全部 9 个工具。

## [2.2.1] - 2026-09-10

### Fixed

- 解耦 worker 启动握手超时与稳态帧 IO 超时——`WorkerProcessSpec` 新增 `handshake_timeout_seconds`（缺省回落 `io_timeout_seconds`，生产行为不变），`AsyncFramedWorkerProcess.exchange(handshake=True)` 使用握手超时，`Qwen3SharedWorker.start()` 的 ready 握手不再复用 50ms 级帧超时；修复真实子进程 worker 测试在 CI 满载下的握手 `TimeoutError` 时序 flake。

### Verification

- 全量 pytest 1532 passed/1 skipped；ruff/mypy/redocly/git diff --check 通过；8× CPU 负载下连续 6 轮通过。

## [2.2.0] - 2026-09-10

### Added

- 落地 durable job 执行闭环：新增 owner 维度的 `GET /v1/jobs` 列表（`limit`/`cursor` 分页）、`GET /v1/jobs/{id}`（返回队列位置与 `eta_seconds`/`deadline`）和 `GET /v1/jobs/{id}/result`；`error_message` 脱敏；引入有界重试（`attempts` 与 `max_job_attempts`）与跨 kind 公平调度。
- diarization realtime 全部事件新增 `event_version: 1`；`conversation.item.input_audio_transcription.completed` 新增 `diagnostics` 对象（`alignment.status`/`alignment.reason`/`unit_count`）；diarization v1 JSON schema 现将这些字段标记为必填。

### Perf

- jobs 表新增 `(state, updated_at, id)` 与 `(owner, updated_at)` 索引，消除随任务历史增长的全表扫描；`recover_interrupted` 在重试预算耗尽时记录有界 `error_message`，并要求显式传入 `max_attempts`。

### Fixed

- 修复 real-child 音频子进程测试在全量套件 CPU 负载下的偶发超时（放宽测试侧看门狗）。

### Dependencies

- 开发依赖升级：mcp `>=1.12,<3`、openai `>=2.0,<4.0`。

## [2.1.1] - 2026-09-10

### Fixed

- 修复 ASR shared worker 空闲永不淘汰（常驻内存）的根因：`Qwen3SharedWorker.trim_memory()` 经 `send()` 发送 trim 帧时无条件刷新 `last_active` 空闲时钟，导致 `WorkerIdleEvictor` 的 standby 降内存动作每 ~60 秒重置自己的空闲计时，链式抵消冷淘汰 (300s idle eviction)。`send()` 新增 `touch_last_active` 参数，trim_memory 传 `False` 不视为活动。
- 修复 `WorkerIdleEvictor` 冷淘汰与 `force_evict` 的 idle 戳记录时序：在 `close()` 完成后才盖章，避免 `Qwen3SharedWorker.close()` 结尾刷新自身 `last_active` 使已被淘汰的死进程在下一 tick 复活为 `active`（worker_status 指标误报、重复调度空淘汰）。
- 补齐回归测试：`trim_memory` 不刷新空闲时钟、真实请求仍刷新；真实 shared worker + evictor 全流程 standby→cold 且淘汰状态不复活。

### Verification

- 新增 3 个回归测试（`tests/test_qwen3_shared.py` ×2、`tests/test_worker_lease.py` ×1）；全套 pytest、ruff、mypy、OpenAPI redocly lint、`git diff --check` 通过。
- 本轮为 bug 修复 patch，按用户要求跳过性能基准；真实模型 smoke 见发布证据 ledger。

## [2.1.0] - 2026-09-09

### Added

- 新增音色克隆质量门控：`POST /v1/voices/clone` 接入 `voice_quality_v1` 参考音频门禁，不达标返回 `400 voice_quality_reject` 并附同级 `quality_report`；克隆接口支持 `Idempotency-Key` 幂等去重（进程内、有界 128 条，键含音频与脚本 SHA-256）。
- 新增 `POST /v1/voices/clone/validate`：仅校验不注册，任何结果一律返回 `200` + `VoiceQualityReport`，便于注册前预检。
- 新增 `POST /v1/voices/{voice_id}/quality-runs`：对已注册音色执行有界固定脚本质量探针（`voice_quality_v1_zh`，`runs` 1..3），区分 `probe_failed` / `clone_speed_unsupported` / `output_invalid` 失败码；`include_audio` 声明未实现并返回 `422 include_audio_unsupported`。
- `VoiceProfile` 增加可选 `quality` 字段（仅已评估克隆音色携带）；旧客户端与预置音色不受影响，缺失即视为未评估。

### Fixed

- 质量探针对空输出（零音频 chunk）不再误计为成功，避免出现 `status=pass` 但 `successful_probe_count=0` 的矛盾报告，统一归类为 `output_invalid`。
- 克隆幂等命中已删除音色时不再泄漏裸 `500`：快路径与锁内镜像查找均将过期条目视为未命中，删除后重新注册。
- 域层失败码枚举补齐 `clone_speed_unsupported` / `output_invalid`，与 OpenAPI 九码契约一致，`from_dict` 回读不再静默丢弃合成侧失败码。

### Verification

- `1441 passed, 1 skipped`；`ruff`、`mypy`（102 文件）、OpenAPI redocly lint、`git diff --check` 全通过。
- 三路严格复审通过（代码正确性 / 实测 QA / 契约同步），新增回归测试覆盖空探针、过期幂等与失败码回读。
- 真实模型三档 smoke 与性能基准见本轮发布验收报告；派生质量（MOS/ABX）与长时资源不在本轮门禁内。

## [2.0.4] - 2026-09-09

### Added

- 增加 Realtime `response.create` 的 namespaced TTS speed 扩展，并保持标准 OpenAI envelope 兼容。
- 增加全链路内存场景 benchmark runner 与资源证据保护，缺失观测时 fail closed。

### Fixed

- 修复 diarization revision 队列丢失 revision 1、bounded backlog 跳号和 EOF 对齐问题。
- 修复 `speaker=null` 状态非法落入 `tentative/stable`、ForcedAligner 零时长 token 使整段 timing 降级，以及 EOF unknown 覆盖已有 speaker patch 的问题。
- 稳定 clone ICL 推理：请求级确定性 seed、低温度/top-p、repetition penalty、校准后响度冻结、峰值保护与参考音频信号校验；非 `1.0` clone speed 明确返回不支持。

### Verification

- `1357 passed, 1 skipped`，覆盖率 `82.24%`；`mypy` strict 与 `ruff` 全通过。
- quality managed runtime `/health`：ASR/TTS/diarization ready，`auto → silero`，`speech_admission_enabled=true`。
- Sona 字幕重入、会议 EOF 水位屏障和 clone 稳定性联合复验已记录；DER/JER、长时资源与主观音质仍不在本版本门禁内。

## [2.0.3] - 2026-09-09

### Fixed

- 带 `--app-home` 的 service CLI 会自动使用 active managed runtime，避免从源码环境执行 preflight 造成 bundled worker 误判，并将失败提示改为准确的“service state unchanged”。
- 带 `--app-home` 的 `profile`/`setup` 状态变更命令同样转交 active managed runtime，避免源码包路径导致切档 preflight 误报。
- benchmark、CLI diagnose、MCP 与本机性能脚本统一自动发现 managed `config/.env` 中的 API key；benchmark 在首个推理前发现 `401` 时立即停止，不再产生整批无鉴权请求。
- Realtime benchmark 在异常路径也会关闭 WebSocket，并仅输出转写存在性与长度，避免残留 session 和敏感转写影响后续验收。
- CI 在 Linux 跳过 macOS CoreML worker 构建，并在 macOS 15 runner 上执行原生 wheel 构建，避免跨平台构建失败。

## [2.0.2] - 2026-09-08

### Fixed

- managed Apple Silicon wheel 直接锁定并安装 `onnxruntime==1.29.0`，修复配置 Silero 模型时 `server_vad` 会话因应用 runtime 缺少 ONNX runtime 而失败的问题。
- managed install preflight 现在使用候选 release 的应用 Python 检查 `onnxruntime` 与 Silero 模型；`/health`、成功的 `/readyz` 和 `/metrics` 独立报告 `realtime_vad.ready/code/message`，避免把 VAD 子能力故障误报为整个服务离线。
- 克隆音色的流式响度校准在校准窗口跨 chunk 时保持平滑增益过渡，避免首块和边界处的音量突变。

## [2.0.1] - 2026-09-08

### Fixed

- Sortformer 在 EOF 时补足私有右上下文并裁回真实 PCM 时间轴，避免尾部已讲话 token 因未覆盖的最终帧而使 `diarized_json` 返回 `diarization_unresolved`。
- CoreML diarization worker 现在有界排空 stderr，并将子进程传输故障映射为稳定的 `diarization_invalid_output`，避免管道反压和私有诊断内容泄露。
- 本机 managed 首装会准备并校验 CoreML Sortformer 与 Qwen3 ForcedAligner；已修复的活动阈值与音色克隆流式块处理随此 patch 一同交付。

## [2.0.0] - 2026-09-08

### Added

- 在 OpenAI-compatible `/v1/realtime` 中新增唯一的 `session.speechrail.diarization.enabled` opt-in；固定转写正文通过 `speechrail.diarization.updated` 异步补充匿名、会话内的 A–D 归属，并以 `finish` / `done` 完成尾部屏障。
- `POST /v1/audio/transcriptions` 的 `diarized_json` 支持匿名分人结果与 SSE 流式交付；CoreML FP16 讲话人分离 worker 通过受控 IPC 与 Python 服务隔离运行。

### Changed

- 分人领域改为独立的 application/domain/backend/runtime 边界；文本对齐、准入控制、归属 revision 和可观测性均以不可变转写正文为基础。
- OpenAI SDK 兼容调用保持标准请求形状；仅需要讲话人分离的调用方额外发送 namespaced opt-in。

### Removed

- 移除 NeMo Sortformer、CAM++、跨会话 group/centroid、旧 batch overlay，以及 `speechrail.diarization.v1`、`input_audio_transcription.diarization`、`speaker_count_hint`、`group_id`、`speechrail.diarization.update` / `finalized` 等旧协议路径。

### Migration

- 升级前按 [迁移手册](docs/operations/migration-runbook.md) 移除旧 diarization 配置和事件处理；需要实时归属时改在首个 PCM 前发送新的 session opt-in。

## [1.13.1] - 2026-09-08

### Fixed

- 为 HTTP 请求记录补充稳定的可归因结果，并公开 TTS warm/cold 状态，便于定位首次请求延迟。
- 将 TTS 排队、推理和流式传输纳入单一 deadline，避免超时请求继续占用共享 worker。
- 资源治理在模型峰值缺少可信测量时 fail closed，避免并发模型装载突破内存边界。
- 自定义音色注册表、WAV 文件与 lease 采用受限路径、原子写入和持久化租约，删除冲突返回可重试的 `409 voice_in_use`。

## [1.13.0] - 2026-09-08

### Added

- Realtime transcription 支持当前 OpenAI session 形状、24 kHz PCM 有状态适配、逐 turn `item_id` 与只追加的稳定 partial；current wire profile 发送 `response.output_audio.delta`。
- 新增安全的能力诊断（`/health`、MCP describe、`speechrail diagnose`）、外部 benchmark manifest 和连续 diarization 的 fail-closed capability gate。

### Changed

- Realtime 接收、排队、推理和发送采用有界字节/时长预算与总 deadline；慢消费者、非法事件和取消均有稳定恢复路径与低基数阶段指标。
- ASR 对齐缓冲改为按需捕获；REST、Realtime 与 preview 共享 TTS 文本规划，克隆参考缓存受容量、版本和失效规则约束。

### Fixed

- TTS 取消先尝试协作停止，未确认停止时才执行有界 abort/reload；worker 恢复测试拆分请求与传输超时，消除慢速 macOS runner 的时序竞态。

## [1.12.0] - 2026-09-07

### Added

- 新增 `speechrail-mcp` 入口与无状态 MCP 代理（`speechrail-mcp`），为 OpenAI SDK / Sona / OpenClaw 等客户端提供零配置 agent 访问，并同步 MCP server/client/tools。
- Realtime 增加 schema-aware Silero VAD v5/v6：`realtime_vad_engine` 默认 `auto`，配置了 `SPEECHRAIL_REALTIME_VAD_MODEL_PATH` 时解析到 Silero ONNX，否则回退零依赖旧引擎。
- `speechrail setup` 在网络可达时自动下载固定 `silero_vad.onnx`（约 2.3 MB，MIT）并做 schema check；不可达时记录 warning 并保留旧引擎回退。
- `service` 新增 VAD 模型下载与管理命令，profile 命令同步支持 VAD 资源。

### Fixed

- 修复 `auto` 引擎解析为 silero 时被误判为 shadow VAD 而拒绝的问题。
- `_atomic_write` 增加关闭后 `fsync directory`，提升元数据持久化可靠性，写盘失败不再静默丢弃。

## [1.11.0] - 2026-09-07

### Fixed

- 统一 `service start/stop/restart` 与 profile 切换的 bounded lifecycle；status 不可用时只有经过 lock owner、PID 和命令行校验的旧实例才允许恢复。
- managed installer 在切换 `runtime/current` 前确认端口 singleton lock 已释放；profile smoke 严格校验 profile、ASR/TTS readiness 和实际 artifact identity。
- `/health` 新增 `asr_state`、`tts_state`、`streaming_state` 生命周期状态，`tts=cold_evicted` 或 worker 失效不再被布尔就绪位掩盖。
- 系统路由对 `POST/DELETE /v1/voices` 与 `/v1/voices/clone` 应用 bearer 鉴权，与 audio/jobs 路由一致；配置 API key 后未授权写入返回 401。
- 语音克隆元数据改为原子写入（temp + fsync + rename）并设 `0600`，写盘失败不再静默吞错，同时消除孤儿 WAV 与半写 JSON 风险。
- HTTP 请求指标中间件改为纯 ASGI 包裹完整 body 发送，流式响应时长不再被低估。
- TTS 指标改用有界的 `voice_class`（system/custom/clone）标签，避免用户自定义 voice ID 造成无界时间序列。

## [1.10.0] - 2026-09-06

### Added

- 为 Realtime ASR 增加 speech admission 与 neural VAD，静音或非语音输入不再进入转写提交路径，降低空结果和幻觉转写。
- 增加 controller-backed `service start`、`stop`、`restart` 入口，并将单实例 lock、精确旧进程恢复、严格 profile smoke 和安全安装切换固化到本机发布流程。

### Fixed

- 修复 profile 切换期间旧 listener、错误 runtime 或 worker 尚未释放导致的 `worker_load_error` 自动回滚，发布和切换现在会在端口 lock 释放后才启动候选实例。
- 更新 cartoon-avatar 示例的 avatar profile、voice binding 和 playback progress 交互，保持示例状态与 SpeechRail 音色能力一致。

## [1.9.2] - 2026-09-06

### Fixed

- Wait for the previous managed process to release the per-port singleton lock before starting a profile candidate, preventing launchd stop/start races from misrouting smoke probes or causing `worker_load_error` during tier switches.

## [1.9.1] - 2026-09-06

### Fixed

- 防止同一用户在同一端口启动多个 SpeechRail 进程；profile smoke 现在会拒绝验收到错误 profile，避免旧进程或资源竞争把切换误报为 `worker_load_error` 并让其他用户不可用。

## [1.9.0] - 2026-09-06

### Added

- 新增 `POST /v1/voices/previews`，为 `quality` / `voice_design` 档提供不创建 VoiceProfile 的自然语言音色试听；`/v1/models` 同步公开 `supports_preview`、`supports_clone` 与 `supports_instruction`。

### Changed

- 标准 `POST /v1/audio/speech` 保持 `voice` 必填和 OpenAI `instructions` 兼容语义，声音设计 instruction 改由独立预览契约通过类型化 worker 请求传递。

## [1.8.1] - 2026-09-06

### Changed

- 补充 `video-podcast` 技能、`autobiography-video` 与 `cartoon-avatar` 示例及媒体验收工具，完善本地创作工作流的可复现材料。
- 收紧 GitHub Actions release workflow 的默认权限，固定 action 版本，并使同名 Release 的 wheel 上传可幂等重试。

### Fixed

- 将 Qwen3 shared worker 的握手测试超时从 `0.05s` 调整为 `1.0s`，降低 CI 时序抖动；不改变运行时协议或服务行为。

## [1.8.0] - 2026-09-06

### Added

- **SPK-E2E-1 完整说话人分离架构**：在 `/v1/realtime` 中新增 opt-in 的 `speechrail.diarization.v1` 扩展；以全局整数采样时钟和“正文先固定、归属后更新”为基础，提供不可变 `attribution_units`、有界连续流状态、跨会话 speaker centroid/link、异步归属修订事件，以及客户端结束屏障 `speechrail.diarization.finalize` 与服务端终态 `speechrail.diarization.finalized`。连续 native 能力由 `supports_stream` gate 控制，未通过验证时 fail closed。
- **说话人分离离线验收套件**：新增 JSON Schema/fixtures、E2E 评测工具与 DER、Collar/Overlap、SACER 指标测试，覆盖 canonical completed delivery、revision 单调性、`unknown` 降级和 finalize 一致性。
- **零样本音色克隆 API**：新增 `GET /v1/voices/clone/prompts` 精选朗读文案和 `POST /v1/voices/clone`，支持上传参考音频、参考文本与自定义音色 ID，并以受控权限持久化本地音频和元数据。
- **Quality 档 ICL 音色生成**：`quality` 档将克隆音色的参考音频与文本安全传递至 Qwen3-TTS Worker，使用原生 VoiceDesign ICL 生成路径。
- **VoiceDesign 角色配方优化**：为自定义 VoiceDesign 音色支持显式 seed，固定本轮九角色的既有配方，并以独立 holdout 记录稳定性边界；未通过的候选不写回生产配置。

### Changed

- 音色契约新增 `mode`、`ref_text`、`duration_seconds` 与 `supports_clone` 能力声明；`balanced`/`light` 按当前 CustomVoice 权重明确拒绝不支持的克隆请求。
- 自定义音色注册表支持跨进程元数据热重载，并对上传大小、时长、ID、路径、目录和文件权限执行有界校验。

### Fixed

- 修复 `AttributionLedger` 在注册对齐不可用（`unavailable`）或晚到（`late`）单元时未即时产生定态结果导致事件丢失的生命周期漏洞，现在立即下发 `unknown` 或 `stable` 归属更新并受 `revision > 0` 保护。
- 资源采样器在执行 `--warmup` 后重新发现受管进程，确保懒加载期间新启动的 ASR/TTS worker 进入同 tick `phys_footprint` 集合，避免漏计 worker 仍错误显示完整 gate。
- 修复 ffmpeg 管道输出的 WAV 使用未知 RIFF/data 长度时被误判为超长音频，真实 2–45 秒参考音频现在按实际 PCM payload 校验。

## [1.7.1] - 2026-09-05

### Fixed

- Profile 切换的公共 TTS→ASR smoke 仅在 HTTP、request ID 和响应结构均有效但转写为空时，重新生成音频并有界重试，最多三次；其他协议、后端和资源错误仍立即回滚，减少 CustomVoice 随机输出造成的误回滚而不放宽 fail-closed 边界。

## [1.7.0] - 2026-09-05

### Added

- **三档统一运行时**：新增 `quality`、`balanced`、`light` 三档受管模型组合；三档复用同一服务架构、worker 协议和 lock-keyed vendor runtime，只改变已校验的 ASR/TTS 权重与量化。`speechrail setup` 与 `profile list|status|apply|rollback` 支持停服切换、公共 ASR/TTS smoke 和一次有界回退。
- **不可变模型制品与本机安装**：ModelScope 制品按 revision、大小和 SHA-256 锁定，安装器将 wheel、共享 vendor runtime、模型与 selection 分离保存，原子切换 `runtime/current`，并安装双击设置入口。
- **九个跨档预置角色**：公开 `serena`、`vivian`、`uncle_fu`、`dylan`、`eric`、`ryan`、`aiden`、`ono_anna`、`sohee`。`quality` 使用固定 VoiceDesign 配方，`balanced/light` 映射同名 CustomVoice speaker；旧 ID 与 OpenAI voice 名保留为 alias。

### Changed

- `/health`、`/v1/models`、`/v1/voices` 和 Realtime session 事件从同一次启动 selection 发布实际 profile、artifact、variant、quantization 与 voice capabilities；档位仍对 OpenAI API 调用方透明。
- batch 与 streaming ASR 由一个物理 worker owner 统一管理并显式互斥；冲突通过 REST/Realtime 稳定返回 `backend_busy`，不复制模型进程。
- 上传解码、ASR 分窗与增量拼接、长文本 TTS、容器编码、IPC 状态和 Resource Governor 均改为有界路径；取消、超时与 worker 传输失败有明确清理或单次安全恢复。

### Fixed

- 修复 managed wheel 在标准 `uv` 解释器 symlink、当前 macOS wheel 解析、`uv pip sync` 清单参数、共享 Python/ffmpeg 激活、installed-host preflight 和 LaunchAgent bootout/bootstrap 时序下的安装失败。
- CustomVoice worker identity、VoiceDesign preset 参数、跨档音色 availability 与 profile smoke 现按当前权重严格校验；自定义 VoiceDesign 音色在低档 fail closed，切回 `quality` 后恢复。
- profile 切换的 TTS→ASR 公共 smoke 改用更长的固定普通话句子，降低短音频偶发空转写导致的安全回退；仍保持单次推理与 fail-closed。

## [1.6.9] - 2026-09-05

### Added

- **预置音色固化与 Seed 采样锁定**：为系统默认音色（`default`, `warm`, `bright`, `calm`）分配专属固定 Seed（`42`, `1024`, `2048`, `4096`），推理采样温度设定为 `0.1`，根治流式切句换人与跨轮音色漂移；系统音色标记 `is_system: true` 受只读保护。
- **自然语言创建音色 (Voice Design API)**：新增 `POST /v1/voices` 接口，支持使用自然语言描述音色特征（Prompt），自动分配固定 Seed 并持久化至 `~/.speechrail/custom_voices.json`。
- **自定义音色删除与管理**：新增 `DELETE /v1/voices/{voice_id}`，对系统预置音色拦截返回 403 Forbidden；`/v1/audio/speech` 和 WebSocket `/v1/realtime` 自适应支持所有自建音色。

### Fixed

- **TTS 独立合成片段首块淡入补齐**：Qwen3-TTS worker 现在只对每次合成的首个非空
  PCM 块应用一次 5 ms fade-in，并保留最终块 fade-out；中间流式块不做逐块音量处理，
  避免实时分句在静音到非零首样本之间产生 click，同时保持 REST/Realtime 契约不变。

## [1.6.8] - 2026-09-05

### Fixed

- 文件转写接受标准 multipart `timestamp_granularities[]`，保留旧非方括号字段；
  混用时合并并统一校验。OpenAPI 的 verbose 响应允许按请求只返回 `words` 或 `segments`。
- WAV fastpath 在重采样分配前检查输出大小与时长，拒绝无效采样率，避免低采样率输入先膨胀再报超限。
- `ffmpeg` 编解码使用有界管道读写；解码超限提前终止，超时或取消时清理管道并回收进程。
  容器编码增加 15 秒超时和 128 MiB 输出上限，失败保持 `audio_encode_failed`。
- batch aging 到期主动重新检查准入条件，并唤醒队列后继；保持 FIFO、容量上限和取消清理。
- Qwen3 时间分段跳过非法文本和非有限/负时间戳，统一保证 20 ms 最小时长；
  英文词间空格计入 40 字符合并上限，并修复相关静态类型错误。
- Qwen3 worker 校验流式会话数值参数，损坏启动帧返回稳定错误；commit 推理或对齐失败
  仅终结当前会话，成功、空结果和失败均释放会话状态及对齐缓存。
- 批量 PCM 上限与 128 MiB IPC 的预留规则对齐，消除 40 MiB 旧限额拒绝默认时长范围内
  长音频的问题；实时 append 和单会话对齐缓存仍保持 40 MiB。

### Performance

- worker 同步帧读取在完整首读时直接复用结果，减少中间复制；支持分片 header，保持截断检查与协议格式。
  局部对照数据和验证边界见[优化记录](docs/archive/process/2026-09-05-bounded-runtime-optimization.md)。

## [1.6.7] - 2026-09-05

### Fixed

- **diarization 模型空闲自动卸载**：`NemoSortformerEngine` 现实现 `EvictableWorker`
  协议（`alive`/`last_active`/`async close`）并纳入 `WorkerIdleEvictor`。分人模型
  首次使用后 ~0.5GB 主服务常驻不再永久占用：空闲即卸载，下一次分人请求经加载锁
  惰性重载；in-flight 推理持局部引用不受卸载影响。`EvictableWorker` 标记
  `@runtime_checkable` 以便组装期类型收窄。
- **Realtime ASR reader 静默死亡可见**：`_drain_asr_events` 的
  `except Exception: pass` 改为记录异常日志并发送 `transcription_failed`
  （`backend_error`），客户端不再在 reader 死亡后误认为 ASR 仍存活。
- **Realtime 客户端事件队列有界**：`client_events` 上限 64 个事件。handler 停滞
  （如被阻塞的后端调用卡住）时，溢出将关闭会话（close 1013 `event queue overflow`）
  而非无界堆积 base64 音频。
- **`/v1/models` 补 OpenAI `created` 字段**：全部 Model 条目补 `created: 0`
  （契约 `required` 与响应示例同步），严格解析的 OpenAI SDK 客户端不再缺字段。
- **批量 ASR worker 崩溃后自动重建（单次重试）**：`Qwen3Worker.transcribe` 此前在 worker
  进程死亡后因 `_identity` 未重置而对后续所有请求持续失败，只能等 300s 空闲卸载兜底。
  现在传输层故障（坏管道/截断帧/帧失步）会关闭并重建 worker 后重试一次；推理超时则
  kill worker 并直接映射 `503 backend_timeout`（不重跑超时推理）；语义错误帧（如
  `worker_start_failed`）不受影响照常上抛。TTS worker 原有 stream `finally` 自愈路径保持不变。
- **Realtime commit 无超时导致会话槽永久泄漏**：`Qwen3StreamingSession.commit` 的
  `_finished.wait()` 无超时，worker 挂起（无 EOF、无错误帧）会永久卡死会话并占用
  streaming 槽与 governor 预留。现按 worker timeout 包 `asyncio.wait_for`；应用层
  `_commit_audio` 在 commit 失败时完整 teardown（reader 任务、ASR 会话、factory 槽位、
  governor 预留），映射 `error.code=backend_timeout`，下一个 append 可立即开新会话。
- **Server VAD `speech_ended` 丢弃当前 chunk 尾部音频**：`_append_audio` 原先在
  append 之前处理 VAD 事件，检出 `speech_ended` 即 commit 并 `return`，导致触发
  事件的该 chunk 从未进入 ASR/diarization。现调整为先建会话并 append 音频、再处理
  VAD 事件，句尾 chunk 不再丢失。
- **worker 帧上限与 `SPEECHRAIL_MAX_AUDIO_SECONDS` 矛盾**：`MAX_FRAME_BYTES`（64MB）
  使超过约 33 分钟的音频在完整解码后必报 `worker_frame_invalid`。上限提升至 128MB
  （容纳默认 3600s PCM16 + JSON 头冗余），且 `Settings` 启动期校验
  `max_audio_seconds * 32_000 + 4096 <= MAX_FRAME_BYTES`，矛盾配置直接启动失败而非
  请求中途报错。

### Changed

- **`create_breath_pause` 结果缓存**：realtime TTS 每句重复生成的静音 PCM 按
  `(sample_rate, pause_ms)` 以 `lru_cache` 缓存，消除逐句重复分配。
- **批量 REST 接入 ResourceGovernor**：`/v1/audio/transcriptions` 与 `/v1/audio/speech`
  此前绕过 governor，realtime 预留容量对最大负载不生效。现分别走
  `BATCH_ASR` / `BATCH_TTS`（governor 外层 + admission 内层，deadline 均为
  `SPEECHRAIL_REQUEST_TIMEOUT_SECONDS`），governor 队列溢出映射 `429 queue_full`
  + `Retry-After: 1`，与 admission 溢出一致。
- **实现 batch aging（消费 `SPEECHRAIL_BATCH_AGING_SECONDS`）**：此前该配置无消费者，
  realtime 持续等待时 batch 会无限饿死。现等待超过 aging 阈值的 batch 请求允许占用
  realtime 预留车道（FIFO 保持在 batch 类内），realtime 优先级在阈值内不变。
- **`AdmissionQueue` 改为 token 队列**：原「先 `locked()` 检查再 `acquire`」存在竞态
  （偶发放行第 9 个请求并无界等待，deadline 不覆盖排队）。token 队列使满员判定原子化：
  满即拒（`429 queue_full`），不再有无界等待；deadline 语义（只约束 operation）不变。
- **Sortformer 首载加锁**：`NemoSortformerEngine._load_local_model` 增加
  `threading.Lock` 双检锁，防止并发首个分人请求各自 restore 一份模型（瞬时内存翻倍）。
- **jobs spool SQLite busy timeout**：连接统一 `timeout=5.0`，并发 `claim_next` 的
  `BEGIN IMMEDIATE` 锁冲突改为短等待而非直接抛 `database is locked`。

## [1.6.6] - 2026-09-04

### Fixed

- **流式说话人分离端到端生效（ADR-0010）**：流式 `completed` 事件原先硬编码空 `segments`，
  导致 WS 层 `annotate()` 从不执行、带 `speaker` 的
  `conversation.item.input_audio_transcription.segment` 事件从不下发（sona 侧表现为
  「说话人恒为 `speaker:0`」）。现在 worker 为每个流式会话维护有界 PCM 缓冲，commit 且
  `want_segments=True`（app 侧按是否启用 diarization 门控）时复用批量
  `transcribe(return_timestamps=True)` 对累积音频做词级强制对齐，产出真实
  `{text, start_ms, end_ms}` 分段随 `completed` 返回（批路径秒制经
  `_to_streaming_segments` 换算为毫秒制）。对齐失败 fail-closed 返回空分段，不伪造 speaker。
- **Sortformer 空格分隔活动解析（批量 diarization 不再 502）**：`_parse_activities`
  原先用 `ast.literal_eval` 解析 Sortformer `.diarize()` 输出，实测输出为空格分隔字符串
  （如 `"0.000 2.320 speaker_0"`），解析抛 SyntaxError → HTTP 502。新增
  `_parse_activity_token` / `_speaker_index` 支持空格分隔与 Python 字面量两种格式，
  非法输入仍 fail-closed 抛 `diarization_invalid_output`。

## [1.6.5] - 2026-09-03

### Fixed

- **ASR/streaming 预量化快照 dtype 自动解析**：新增共享 `resolve_backend_dtype`（`qwen3_native`），统一 ASR、streaming 与 TTS 三处 wiring。快照 `config.json` 声明 `quantization` 时一律自动解析为 `int8` 直接加载，不再依赖 `SPEECHRAIL_DTYPE`。此前 ASR/streaming 仅跟随 `SPEECHRAIL_DTYPE`，`-8bit` 快照配默认 `float16` 会触发 `backend_identity_mismatch` 启动失败。
- **内存即时量化失败不再谎报 int8**：`Qwen3Engine` 在 `quantize_model` 抛错时按实际加载精度上报身份（fail-closed on truth），避免 fp16 权重冒充 int8；`_resolve_engine_dtype` 纯函数化，量化失败会映射为清晰的 `backend_identity_mismatch`。
- **后端身份校验纪律统一**：TTS 主进程身份校验改为精确 `dtype` 匹配（原为恒真的枚举成员检查）；`Qwen3StreamingBackendConfig` 补齐 MPS/CPU dtype 组合校验，streaming worker 起始握手补齐 device/dtype 校验。

## [1.6.4] - 2026-09-03

### Added

- **预量化 8bit 快照支持**：ASR 与 TTS 均可在配置指向 `mlx-community` 的 `-8bit` 快照时直接加载，避免 worker 启动时的 bf16→fp16 深拷贝与整树量化瞬时占用。ASR 加载峰值 9.58 GB → 3.44 GB；TTS 加载峰值 4.58 GB → 3.18 GB（-31%）。双 8bit 真同时峰值约 6.0 GB（v1.6.3 约 7.9 GB）。
- **ASR 解码 token 预算次线性增长**：`_dynamic_budget(audio_sec, cap)` = `min(cap, max(32, audio_sec*6+24))`，长音频解码尾保持小、短音频仍有下限；实测完整转写无截断。
- **资源采样器真同时峰值统计**：`sample_resources.py` 改为逐采样 tick 取当前 footprint 之和的最大值，不再对逐进程 all-time high-water 做算术求和。

### Changed

- **预量化快照跳过二次量化**：`qwen3_worker` / `qwen3_native` 检测到快照已配 `quantization` 时跳过内存 int8 量化，底层权重以 int8 加载（`speech_tokenizer` codec 恒为 FP32；text/codec/speaker embedding 与 norms 保持 BF16），并正确上报 int8 身份；`qwen3_tts_worker` / `service/preflight` 同步支持单文件量化权重布局。
- **量化检测统一入口**：新增共享 `snapshot_is_quantized`（`qwen3_native`），ASR worker、TTS worker、`services.py` 三处统一调用，消除两份重复实现；TTS 后端配置 dtype 现由快照是否预量化决定（`int8`），与 worker 上报身份一致。
- **`SPEECHRAIL_MLX_MEMORY_LIMIT_MB` 说明更正**：该限额只约束 Metal 缓存池/GC 触发，不封顶加载期活跃分配；文件转写峰值主要来自加载期 cast+量化，非配置限额。

## [1.6.3] - 2026-09-03

### Fixed

- **`_clear_metal_cache` 调用已弃用 API**：优先调用有效的 `mx.clear_cache()`（mlx≥0.32 中 `mx.metal.clear_cache` 已弃用但仍存在），此前分支排序错误会导致 Metal 缓存滞留、空闲 worker 常驻虚高。
- **streaming worker 未继承 int8 与 Metal 内存限额**：native realtime 拉起的 streaming worker（`Qwen3StreamingBackendConfig`）此前不传 `--dtype`/`--cache-limit-mb`，回落为 float16 且缓存无界，常驻内存偏高。现与 batch 一致向前传递 `settings.dtype` 与 Metal 限额。

## [1.6.2] - 2026-09-03

### Added

- **零依赖 Prometheus / OpenMetrics 指标引擎**：`GET /metrics` 默认输出 Prometheus 文本（`text/plain; version=0.0.4`），`Accept: application/json` 返回结构化视图。引擎提供 `Counter`、`Gauge`、`Histogram`（标准 `_bucket{le}`/`_sum`/`_count`），全部基于 Python 标准库、线程安全，不引入重依赖。
- **HTTP RED 指标**：新增轻量中间件自动记录 `speechrail_http_requests_total{endpoint,method,status}` 与 `speechrail_http_request_duration_seconds`；`endpoint` 归一为路由模板，未匹配路由折叠为 `<unmatched>` 以保低基数。
- **领域专用指标**：`speechrail_asr_processed_audio_seconds_total`、`speechrail_asr_inference_duration_seconds`、`speechrail_asr_rtf`、`speechrail_tts_generated_audio_seconds_total{voice}`、`speechrail_tts_input_characters_total{voice}`、`speechrail_tts_inference_duration_seconds`、`speechrail_tts_ttfa_seconds`。
- **Realtime 会话与打断指标**：`speechrail_realtime_sessions_total`、`speechrail_realtime_active_sessions`（gauge）、`speechrail_realtime_bargein_events_total`、`speechrail_realtime_vad_speech_events_total{event}`。
- **资源调度与 Worker 生命周期指标**：`speechrail_governor_active_requests`、`speechrail_governor_pending_requests`、`speechrail_governor_queue_rejections_total{class,reason}`、`speechrail_worker_status{component,state}`、`speechrail_worker_evictions_total{component,phase}`、`speechrail_health_status{component}`。

### Changed

- **解码后音频时长强制拒绝**：`SPEECHRAIL_MAX_AUDIO_SECONDS`（默认 `3600`）现已在 `_decode_pcm` 解码后强制时长校验，超限返回 `400 audio_too_long`（此前仅作为配置字段未生效）。

### Fixed

- **`trim_memory` 帧失步**：worker 侧处理 `trim_memory` 不再写回 `memory_trimmed` 确认帧（主进程为 fire-and-forget，回包会污染下一个 transcribe/synthesize 的请求/响应帧对齐），修复空闲 warm-standby 后首次真实推理帧错位。
- **Realtime active_sessions 泄漏**：`record_realtime_session_start()` 移至握手解析成功之后，与 `finally` 中的 `record_realtime_session_end()` 严格成对，握手失败路径不再导致 gauge 单调上涨。

## [1.6.1] - 2026-09-03

### Added

- **Realtime 流式 Partial Delta 驱动与增量切片计算 (Issue #7)**：在推流达到窗口阈值（`qwen3_streaming_chunk_sec * 32,000` 字节）时自动调用 `asr.flush()`，并基于历史文本计算真正的增量 delta 切片，彻底杜绝打字机文本重复累加。
- **Realtime 超长流式防溢出自动结转 (Issue #7)**：推流累积超出 `max_realtime_buffer_bytes` 时自动触发分段 commit 结转，音频零丢失且避免被 `buffer_too_large` 锁死。

### Changed

- **WORKER 默认懒加载 + 空闲自动卸载**：`SPEECHRAIL_WORKER_LAZY_LOAD` 默认为 `false` → `true`。服务启动不再预热所有 worker（ASR ~2.5 GB + TTS ~5 GB 常驻在懒加载下为 0），首个请求按需拉起并阻塞等待模型就绪。`WorkerIdleEvictor` 已有两阶段待机（`warm_standby_timeout=60s` trim 缓存→`idle_timeout=300s` 冷卸载）对全部 worker 生效，请求持有 `WorkerLeaseLock` 时不卸载；流式 batch 与 realtime 共用同一 Evictor 实例。
- **空闲卸载防抖**：新增 `SPEECHRAIL_WORKER_MIN_UPTIME_SECONDS`（默认 `60`）与 `SPEECHRAIL_WORKER_WARM_STANDBY_TIMEOUT_SECONDS`（默认 `60`）。worker 刚加载（懒加载首建或回收后重建）后 `60s` 内不受空闲时长影响而被误回收（vLLM `min_uptime_s` / cudabroker `ACTIVE_GRACE_SECONDS` 类比），避免间歇请求下的 thrash；行为仅在显式配置时生效（`WorkerIdleEvictor` 组件默认 `0.0`，已有测试保持 `min_uptime=0` 语义）。
- **Realtime 并发上限默认值 2→3**：`SPEECHRAIL_REALTIME_MAX_SESSIONS` 默认为 `3`（原 `2`，范围 `1-8` 不变），`streaming_worker.start()` 增加并发锁避免冷启动时多会话竞争 `start` 帧。默认上限提升后，`concurrent_realtime_smoke.py --sessions 2` 在懒加载冷启动 + 工厂计数窗口下稳定通过（此前 2 并发 + 冷启动时偶现 `backend_busy`）。
- **Worker 空闲防抖配置**：`worker_min_uptime_seconds` 与 `worker_warm_standby_timeout_seconds`（均 `0.0–86_400`），与既有 `worker_idle_timeout_seconds` 组成完整的可调生命周期三参数。

### Fixed

- **Realtime 空缓冲 Commit 容错 (Issue #7)**：移除原先抛出 `invalid_state` 致命错误，空音频 commit 幂等下发 `committed` 与空 `completed`，平滑完成状态闭环并保持会话可用。
- **Realtime WebSocket 断开防护与日志降噪 (Issue #7)**：全链路拦截 `(WebSocketDisconnect, RuntimeError)`，优雅退出循环，根除客户端异常关闭时的红字堆栈报警。

## [1.6.0] - 2026-09-03

### Added

- **Realtime 多会话并发（共享权重引擎）**：`/v1/realtime` 现在支持同时多个
  WebSocket 会话共享单个 streaming worker。worker 引擎从单会话状态升级为
  `dict[session_id, StreamingState]`（`mlx_qwen3_asr.Session` 的流式 API 为
  纯函数式，`init_streaming`/`feed_audio`/`finish_streaming` 均显式传递 state，
  权重只加载一次、各会话状态完全隔离）；worker 所有会话响应帧回声
  `session_id`，主进程侧 `Qwen3StreamingWorker` 增加单 reader dispatcher 按
  `session_id` 将帧路由到各会话队列——两条会话读循环不再互相偷帧。
- **Realtime 并发上限可配置**：新增 `SPEECHRAIL_REALTIME_MAX_SESSIONS`
  （默认 `2`，范围 `1-8`）。`NativeRealtimeFactory` 由单 `_active` 槽位改为
  会话 dict + 上限；达到上限时新会话的 `input_audio_buffer.append` 返回
  `backend_busy`（错误语义沿用既有契约，session 保持可用）。worker 侧另有
  `MAX_ACTIVE_STREAMING_SESSIONS=8` 的协议级防御上限。
- **多会话冒烟示例**：`examples/perf/concurrent_realtime_smoke.py` 可同时打开
  N 个 realtime 会话并验证路由隔离与 batch 同期可用。

### Fixed

- **streaming dispatcher 空闲超时不再判死**：`Qwen3StreamingWorker._dispatch_loop`
  调用 `receive()` 底层受 `io_timeout`（默认等于 `request_timeout_seconds`=120s）约束，
  共享 streaming worker 空闲超过该窗口读超时后，dispatcher 会把空闲静默误判为
  worker 故障并广播 `worker_unavailable` 且自身永久退出；`_ready` 仍为 True 导致
  `start()` 无法重建，此后所有新会话的 `session.open` 应答无人路由，`connect()`
  挂起至超时、客户端最终得到空结果。现在空闲读超时按正常静默处理（继续分发），
  仅真实 worker 故障（EOF/协议错误）才退出并重置就绪标志。
- **断开/取消不再泄漏 realtime 会话槽**：`realtime_openai.py` 的
  `input_audio_buffer.append` 路径此前只在 `except Exception` 中释放 governor 预留
  与 factory 槽位，`CancelledError`（客户端断开时取消挂起的 `connect()`）会直接穿透
  ——槽位被永久占用（尚未赋值 `self._asr` 时 `session.close()` 也无法回收），累计 2
  个泄漏会话后所有后续会话 `backend_busy`。现在清理路径捕获 `BaseException`（含
  `CancelledError`），先释放资源再原样向上传递；`Qwen3StreamingSession.connect()`
  同样在取消时注销会话队列。
- **基准工具修正**：`bench_realtime`/冒烟不稳定抖动导致 4 次误判死锁；`wait_for_idle.py`
  新增 GPU 感知的空闲等待门，`sample_resources.py` 解析 `vm_stat` 页大小不再硬编码
  4096。

## [1.5.2] - 2026-09-03

### Fixed

- **Realtime 会话槽位永不泄漏**：此前 `input_audio_buffer.append` 触发 `connect()`
  失败（如 worker 管道 BrokenPipe）时，只有 `RuntimeError` 会触发槽位清理，
  `BrokenPipeError`/`OSError` 直接穿透导致 `NativeRealtimeFactory` 的单一会话槽
  和 governor 预留容量永久占用，后续所有 realtime 会话持续 `backend_busy` 直到
  进程重启。`create()`/`connect()` 现在捕获全部异常并总是释放槽位与容量。
- **Realtime 断开立即释放槽位**：WS 路由由单循环串行处理改为 receive/handle
  双 task；客户端在后台 `commit()` 阻塞期间断线时，被阻塞的 handler 会被取消，
  `session.close()` 与工厂释放必然执行，不再等到后端应答才释放槽位；意外 handler
  异常转为 `backend_error` 事件而非静默泄漏。
- **streaming worker 活跃会话不再被空闲回收**：`Qwen3StreamingWorker` 与
  `Qwen3Worker` 此前不维护 `last_active`，`WorkerIdleEvictor` 会在会话持有期间把
  worker 当作空闲收回，下一个 `commit` 得到 `worker_not_started`。两者现在在每次
  帧 IO 刷新 `last_active`，活跃会话的读循环持续续期。
- **worker 传输读写锁分离，消除 parked-reader 死锁**：`AsyncFramedWorkerProcess`
  原先单一锁同时保护读写；streaming 会话的读循环持有锁停在 `readexactly` 等待
  下一帧时，同会话的 `append`/`commit` 写入会等同一把锁永久阻塞（batch 与 realtime
  叠加必现、realtime-only 偶发）。读/写改用独立锁，`exchange` 仅在单个请求/响应
  期间短持双锁。

## [1.5.1] - 2026-09-02

### Fixed

- **Worker 加载/推理失败底层原因不再被吞**：ASR/TTS worker 的加载与推理 `except Exception`
  捕获处现打印完整 traceback 到 stderr；主进程传输层在错误帧上附加 worker stderr 尾巴，
  客户端异常与其合并（`error_frame_message`），lifespan 启动失败额外记录 `logger.exception`。
  `~/Library/Logs/SpeechRail/stderr.log` 不再只有孤立的 `Application startup failed`——模型
  加载内存峰值、MPS 状态等根因可直接定位。

## [1.5.0] - 2026-09-02

### Added

- **Realtime 流式分句 TTS 先行生成与音频平滑**：引入 `StreamingSentenceSplitter` 实现增量句子切分与流式下发，结合 5ms 线性淡入淡出 `apply_crossfade` 与 80ms 呼吸停顿 `create_breath_pause`，消除分句爆音与卡顿。
- **服务端轻量 VAD 与全双工 Barge-in 打断**：实现实时音频能量/过零率语音检测器 `VoiceActivityDetector`，支持 3 帧（$\ge 96\text{ms}$）防抖与 300ms 起声预触发缓冲；在 `server_vad` 模式下自动触发会话隔离的 Barge-in 全双工打断。
- **三级快速内存音频解码与 128MB 熔断**：实现 16kHz mono WAV 零拷贝透传、非 16kHz/双声道 WAV 纯内存快速重采样混音（$<1\text{ms}$）、以及沙箱 FFmpeg 128MB 内存熔断与 15s 超时保护。
- **双阶段分级待机与防竞态互斥锁**：实现 `WARM_STANDBY`（180s 显存缓存释放）与 `COLD_EVICTED`（900s 进程回收）状态机，配合 `WorkerLeaseLock` 租约锁防止并发请求与淘汰竞态。
- **动态热词注入与轻量 ITN 规整**：新增 `compose_hotword_prompt` 动态热词提示词合成与 `apply_light_itn` 轻量逆文本规整（年份、百分比、小数、量词单位规整）。

## [1.4.0] - 2026-09-02

### Fixed

- **OpenAI Realtime 端点对齐**：握手解析 `?model=` 并在 `session.created` 回显，未知模型或
  diarize 无 profile 时以 `model_not_found` + close 4004 拒绝；流式后端 `RuntimeError`
  （不支持语言 / busy）包装为稳定 error 事件并释放预留容量；`input_audio_buffer.committed`
  先于转写终结事件下发；`input_audio_transcription.prompt`（≤2000）透传至流式会话；
  服务端事件 `event_id` 统一生成，error envelope 透传触发方 `client_event_id`；
  compat 注入的 `gpt-4o-transcribe-diarize` 不再出现在 `/v1/models`。
- **Realtime TTS 事件名对齐 OpenAI 标准**：`response.output_audio.{delta,done}` 与
  `response.output_audio_transcript.{delta,done}` 更名为 `response.audio.*` /
  `response.audio_transcript.*`，assistant 输出 content part 类型由自造的
  `output_audio` 改为标准 `audio`。消费方（sona `tts.py`）需与新版本同步部署。
- **Realtime voice 别名链**：`session.update.voice` 与 `response.create.response.voice` 现与
  REST 走同一别名归一化（13 个 OpenAI 标准名 → 4 preset）并校验注册 preset 成员；未知 voice
  在配置入口快速失败为 `voice_not_found`，非字符串/空白为 `invalid_voice`；
  `model_not_found` 错误消息对客户端输入截断至 200 字符。
- **Realtime 流式会话槽位泄漏**：`input_audio_buffer.append` 触发的 `connect()` 失败现在会
  关闭孤儿流式会话并归还 factory 槽位，`backend_busy` 不再持续到进程重启。
- **TTS 空输出语义**：后端未产出任何音频 chunk 时六种 `response_format` 统一返回
  `502 audio_encode_failed`（此前返回空的 200 主体或仅含包头容器）。

### Changed

- **REST transcription `verbose_json` 合规**：segment `id` 由自造字符串改为整数序号；
  Whisper 风格置信度字段（`seek`/`tokens`/`temperature`/`avg_logprob`/`compression_ratio`/
  `no_speech_prob`）以显式 `null` 输出而非伪造值；`language` 统一小写。领域契约
  `TranscriptSegment.id` 与 `DiarizationAssignment.segment_id` 同步改为非负整数。
- **`/v1/audio/speech` 格式对齐**：`response_format` 默认值由 `wav` 改为 `mp3`（OpenAI 默认），
  新增 `mp3`/`opus`/`aac`/`flac` 容器（固定 ffmpeg argv remux）；`pcm` 保持流式，
  `wav` 保持进程内包头；`input` 长度上限按 OpenAI 标准收紧为 4096 字符。

### Added

- **OpenAI 标准 voice 别名**：接受 13 个 OpenAI 标准 voice 名（`alloy`/`ash`/`ballad`/`cedar`/
  `coral`/`echo`/`fable`/`marin`/`nova`/`onyx`/`sage`/`shimmer`/`verse`），映射到 4 个服务端
  preset；`/v1/voices` 新增 `aliases` 字段公布映射关系。
- `contracts/openapi.yaml` 同步锁定以上契约形状。

## [1.3.1] - 2026-09-02

### Added

- **WAV/PCM 零开销 Fast-path 直读**：纯 Python 结构化解析 16kHz Mono 16-bit WAV 头直接提取 PCM 字节，
  针对标准音频彻底绕过 `ffmpeg` 子进程派生，前置处理延迟减少 15~35ms。
- **ASR 动态 Token Budget 自适应**：在 `Qwen3Engine.transcribe` 中依据音频时长动态设定解码 Token 预算上限，
  短语音指令（1~3 秒）端到端耗时降低 20%~30%，彻底杜绝尾部静音发散与幻觉循环。
- **内部进程通信二进制零拷贝帧 (Binary IPC Frame)**：内部管道（`stdin`/`stdout`）升级为二进制混合帧，
  彻底去除内部 Base64 二次编解码与内存拷贝，IPC 吞吐与传输耗时降低 60%，外部 OpenAI 规范 100% 保持兼容。

### Fixed

- 修复 `Qwen3Worker` 与 `Qwen3TtsWorker` 中的 MLX 类型注解与 `EvictableWorker` 接口一致性。
- 清理冗余的 `qwen3_streaming_worker.py`，保持代码库与测试覆盖率（>80.5%）整洁统一。
- 修复 `round()` 整数转换冗余与长行格式规范。

## [1.3.0] - 2026-09-02

### Changed

- **统一 ASR Worker 架构**：消除 batch 与 streaming 之间的双重 Worker 进程与模型实例重复加载，
  合并为单例 `Qwen3Worker`，直接削减 ~8.5 GB 物理显存冗余。
- **MLX Metal 显存治理**：在 ASR / TTS 推理及会话生命周期结束后显式调用 `_clear_metal_cache()`，
  防止 Apple Silicon 统一内存分配池无节制膨胀。

### Added

- **Worker 动态生命周期治理 (Idle Eviction & Lazy Load)**：引入 `WorkerIdleEvictor`，
  支持配置 `SPEECHRAIL_WORKER_IDLE_TIMEOUT_SECONDS`（默认 300s）自动卸载空闲 Worker 释放显存；
  支持 `SPEECHRAIL_WORKER_LAZY_LOAD` 惰性预热。
- **8-bit (INT8) 模型量化支持**：配置系统与 Worker 启动协议支持 `SPEECHRAIL_DTYPE=int8`。
- **真实显存测量工具与基准校准**：升级 `sample_resources.py` 为使用系统级 `footprint` 工具抓取物理显存，
  并确立 100% 真实真机性能与显存基线。

## [1.2.0] - 2026-09-02

### Changed

- 迁移 Qwen3-ASR 后端到 Apple Silicon 原生 MLX 运行时 `mlx-qwen3-asr`，移除
  `qwen-asr`/`qwen3_asr_causal` 依赖并消除与 transformers 的版本冲突；
  batch 与 realtime worker 均改用 MLX。

### Added

- `srt`/`vtt`/`verbose_json` 按需产出带时间戳 segments（强制对齐器 `Qwen3-ForcedAligner-0.6B`）。
- batch 与 realtime 支持 mlx 全部 30+ 语言（可强制语言与自动检测）。

### Fixed

- `service preflight` 的 ASR runtime 检查改为导入 `mlx_qwen3_asr`（修复迁移后 qwen-asr
  死引用导致 wheel 安装 preflight 失败）。

## [1.1.0] - 2026-09-02

### Added

- 增加可选 Sortformer/CAM++ diarization profile 的配置校验、运行时 readiness 和 service preflight。
- `/health` 与成功的 `/readyz` 返回匿名 diarization 状态；`/v1/models` 仅在 profile ready 时发布
  `gpt-4o-transcribe-diarize`。

### Changed

- diarization runtime 未安装或 snapshot 不可用时，Realtime 在 `session.update` 阶段 fail closed，
  不再等到 `commit` 才暴露部署问题。
- active 配置、OpenAPI、架构和运维文档统一为唯一 `/v1/realtime` 公共入口。

### Known limitations

- 真实 diarization 的 DER/JER、时延、峰值内存和会议端到端闭环仍需按部署环境单独验收。
- 非 loopback 的 TLS、CORS、Origin、网段限制和速率限制仍未完整实现。

## [1.0.0] - 2026-09-02

### Added

- OpenAI Realtime 兼容端点 `/v1/realtime`（ASR/TTS 子集）：标准 `openai` SDK 的
  `client.realtime.connect(model="whisper-1")` 可直接接入，连续会话已通过本机真实 smoke。
- 模型名统一：`/v1/models` 列出 canonical 与全部 OpenAI 标准 alias（`whisper-1`、
  `tts-1`、`gpt-4o-transcribe`、`gpt-4o-mini-tts` 等），alias 带 `resolves_to` 标注。
- `/v1/realtime` `response.create` 支持 response 参数体中的 `voice` 选择。
- 性能基准脚本目录 `examples/perf/`（generate_audio、bench_asr/tts/realtime、probe_queue、
  sample_resources），并记录本机实测基准（REST ASR RTF 0.06-0.09x、TTS RTF 0.34-0.36x、
  Realtime 连续会话、worker 内存 1.96/1.96/4.76 GB）。

### Changed

- 移除 legacy `WS /asr` 与 `WS /v1/realtime/legacy` 端点及相关代码、契约、配置和测试；
  对应契约归档到 `docs/archive/realtime-legacy-contract.md`。
- 移除外部 WLK streaming 后端（`SPEECHRAIL_WLK_STREAMING_URL`、
  `realtime_asr_backend=wlk`）；实时流式 ASR 只使用本地 Qwen3 `native` 后端。
- 正式文档改写为终态、正向陈述，以实测证据替代待验收表述；能力矩阵与边界文档同步。
- AGENTS.md 新增文档 metadata 规则：`version`/`date` 仅随正文实质变更更新。

### Fixed

- Realtime v1/v2 流式 ASR 会话结束后释放 backend slot，修复连续会话
  `realtime streaming backend busy` 断连问题。

### Known limitations

- `/v2/realtime` 已在 1.0.0 移除，仅保留 OpenAI Realtime 兼容 `/v1/realtime` 作为标准接入面。
- 真实 TTS/diarization 的质量、时延、峰值内存和客户端闭环需按运维/验收文档单独确认。
- 非 loopback 的 TLS、CORS、Origin、网段限制和速率限制仍未完整实现。

## [0.1.0] - 2026-08-31

### Added

- 创建 SpeechRail 独立项目和 Python 3.12 包骨架。
- 冻结 OpenAI-compatible REST、Realtime WebSocket 与 WLK legacy 兼容边界。
- 写入 `sona` 吸收矩阵、QwenPaw/Hermes/sona 接入方案、
  运行时安全边界、迁移 Runbook、测试门禁和 ADR。
- 添加可测试的领域模型、模型 alias/capability registry、长度前缀 Qwen3 worker 协议、
  离线/MPS snapshot preflight、Realtime 状态机、WLK snapshot compatibility renderer、
  有界 admission queue、统一 REST formatter 与隐私安全观测边界。
- 接通 `json`、`verbose_json`、`text`、`srt`、`vtt` REST formatter，以及现代 Realtime
  与 legacy `/asr` 的有序协议测试路径。
- 默认服务现在会在配置外部 snapshot 与专用 Python runtime 后启动单一 Qwen3 worker，
  使用固定 `ffmpeg` argv 解码上传音频，并验证 worker 的 MPS/float16 身份。
- 完成本机 Qwen3 worker 的 REST smoke，以及 QwenPaw `whisper_api` provider 指向
  SpeechRail 后的中文短音频 smoke。
- 新增按用户、开发和运维职责组织的文档、macOS `launchd` 模板及运行/迁移边界说明。

### Known limitations

- WLK sidecar、Hermes 与 `sona` 的真实切换/回滚仍待分别按 Runbook 验收。
- 没有配置 snapshot 或专用 runtime 的部署仍安全返回 `backend_not_ready`；本机 runtime
  配置保留在被忽略的 `.env`，不提交绝对模型路径或任何凭据。
- `/v1/realtime` 当前是 commit 后 batch 转写，没有 delta；legacy `/asr` 仅有 config/EOF
  骨架，不能替代旧 WLK。`sona` 未被修改。
