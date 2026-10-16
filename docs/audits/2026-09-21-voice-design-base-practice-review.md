---
title: "VoiceDesign 与 Base 能力及使用方式调研"
status: implemented_runtime_smoke_passed
audience: "SpeechRail 开发者与 Agent 集成维护者"
version: "1.2"
date: 2026-09-21
---

# VoiceDesign 与 Base 能力及使用方式调研

## 1. 结论与证据边界

SpeechRail 采用 VoiceDesign 创造参考声音、Base 复用参考合成新文本，符合 Qwen 官方明确展示的组合方式。问题集中在能力声明、参数适配、验收标准及错误诊断；没有证据支持推翻这条模型组合路线。

本次核实时间为 2026-09-21（Asia/Shanghai）。项目源码基线为 `5e9a9b0c`，同时存在其他任务的 App 工作区改动；本报告不审计这些 UI 改动。外部证据采用 Qwen 官方仓库、模型卡/配置、技术报告和 MLX Audio 上游源码/发布记录。只读检查本机已安装 TTS Python 包元数据与相关源码，确认 `mlx-audio 0.4.8`，与仓库 runtime lock 一致；后续已在新 managed wheel 上完成一次真实 Base clone smoke，但不等于正式质量/性能 benchmark。

最初调研未加载模型、合成音频、运行性能/质量基准、升级依赖或改变服务。用户随后授权本机调试，先做了一次失败请求并定位启动预热故障，见 §12；方案实施后又通过 managed release 做了真实短句 smoke，见 §13；两者都不构成正式质量或性能 benchmark。

前置问题与修复方向见[方案记录](../superpowers/plans/2026-09-21-voice-design-base-mcp-reliability.md)。

## 2. 模型各自负责什么

| 能力 | VoiceDesign 1.7B | Base 1.7B / 0.6B | 对 SpeechRail 的含义 |
|---|---|---|---|
| 输入条件 | 目标文本与自然语言声音描述 | 参考音频；ICL 模式同时需要对应文本 | 两套输入契约不能混用 |
| 主要职责 | 创造声音、按描述表达 | 零样本克隆、生成新内容，也可作为微调基础 | 注册生成式音色可以连接两者 |
| 持久身份 | 描述不是已验证的 speaker identity | 以固定参考为条件复用声音 | 固定 reference/revision 比每句重新设计更适合角色复用 |
| 自然语言控制 | 官方模型具备 instruction control | 官方 Base 能力表未承诺 instruction control | 不向 Base 透传情绪指令并假定生效 |
| 参考模式 | 不作为 reference-clone 后端 | 官方支持 ICL 与 speaker-only/x-vector-only | SpeechRail 当前选择 ICL 是合理子集 |
| 数值语速 | 不能由“支持描述快慢”推导出 speed 倍率支持 | 同样不能由通用函数参数推导出支持 | 必须依据实际 adapter 声明 |

模型职责与组合方向依据 [Qwen 官方模型列表和 Voice Design then Clone 示例](https://github.com/QwenLM/Qwen3-TTS#voice-design-then-clone)。官方 Base 模型卡说明：ICL 使用参考音频与转写；speaker-only 可以不提供转写，但可能降低克隆质量。[Base 模型卡](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base)

工程判断：需要一次性富表现力语音或试听声音描述时，可直接使用 VoiceDesign；需要同一角色跨句复用时，采用设计参考后 Base 克隆。已有真实录音时直接进入 Base，不必先经过 VoiceDesign。用户要求“同一音色每句任意改变情绪”时，不能把它描述为当前 Base 已具备的独立控制能力。

固定 seed 是采样控制，不是声纹身份协议；更换目标文本、参考、模型或运行时都可能改变结果。保存 instruction 和 seed 应叫作保存设计配方，不能等同保存经过声学验收的角色声音。

## 3. 推荐协作流程与本项目对应关系

推荐项目工作流：

1. 明确交付目标：一次性设计试听，或需要长期复用的角色。
2. VoiceDesign 生成候选参考，选择符合目标的声音；保留确切参考文本。
3. 对实际参考做格式、信号及文本一致性检查，生成唯一 canonical reference。
4. 创建 Base-bound revision；状态为参考通过、输出待验证。
5. Base 用这份 reference 合成不同文本，验证可懂度、音频有效性与跨文本身份。
6. 通过后固定 reference/voice revision、实际模型与运行配置用于制作。

其中“先设计参考，再建可复用 clone prompt，再生成新文本”来自官方示例；门禁、状态与 revision 绑定是针对 SpeechRail 的工程建议，不是 Qwen 模型内建的产品功能。[官方组合示例](https://github.com/QwenLM/Qwen3-TTS#voice-design-then-clone)

本地 `voice_designs.py` 已实现生成参考、原始音频分级、规范化、再次分级、阶段化 ASR 与注册，方向正确。实施前它明确返回 `synthesis_validation=unevaluated`，需要后续输出验收；当前实现已补齐独立输出验证存储、MCP 创建/验证闭环与 `require_output_pass` 服务端门禁。

## 4. 逐项对照结果

| 项目 | 当前实现 | 判断与行动 |
|---|---|---|
| 模型路由 | clone 强制 Base，设计由 VoiceDesign 处理 | 符合职责划分；保持显式失败，不静默换模型 |
| ICL 输入 | Base 公共 `generate(ref_audio, ref_text)` | 符合 MLX 公共接口；不需要为了模仿 PyTorch API 调用私有函数 |
| 参考文本 | ASR 核验后保留注册文本 | 方向正确；ASR 相似度通过并不保证逐字完全正确 |
| 参考规范化 | 服务端有界增益，loader 禁用归一化 | 合理；本机 MLX 的 ndarray 输入直接返回，未发现该路径二次归一化 |
| 参考长度 | 4–30 秒通过，2–4/30–45 秒警告；设计文本 20–240 字 | 项目策略，不是官方最优区间；应由目标语料验证 |
| 输出流式 | Base/VoiceDesign 都传 `stream=True` | 本机 MLX 支持该路径；不能单凭 stream=True 解释 backend_error |
| 语速倍率 | clone 拒绝非 1.0；其他路径继续传 speed | 声明不完整，且非 clone 存在成功但未生效风险，见 §5 |
| 语言控制 | 设计注册传 zh，worker 原样送给 vendor | 标识适配缺口，见 §6 |
| 采样 | clone temperature=0.1、top_p=0.95、惩罚至少 1.5 | 惩罚吻合 MLX ICL；低温配方需对照，不应直接定为错误或最佳 |
| 同文本重复 | PCM SHA-256 作为独立 repeatability 指标 | 不再仅因字节重现性差触发质量 reject |
| 长文本 | 每段至多 240 字，分段重新生成，token budget 有上限 | 有界运行合理，但跨段韵律和截断需要单独验收 |
| 参考缓存 | SpeechRail 波形 LRU + MLX 私有 ICL 缓存 | 有部分复用，不等同完整 prepared prompt，见 §8 |
| 错误诊断 | worker code → typed `TtsBackendError`；stderr 仅排障 | 已补稳定 code/stage/diagnostic_class；managed runtime 合法 clone smoke 通过 |
| Agent 工作流 | 指令保存、生成式 clone、验证与正式制作分开 | MCP 15 工具、3 resources 与 packaged skill 已闭环 |

本地证据：`src/speechrail/backends/qwen3_tts_worker.py`、`domain/tts.py`、`domain/tts_text_planner.py`、`domain/voice_quality.py`、`http/routes/voice_designs.py`、`http/routes/system.py`、`mcp/tools.py` 与 `mcp/server.py`。

## 5. 新发现：speed 问题覆盖整个 Qwen3-TTS adapter

本机 `mlx-audio 0.4.8` 的 Qwen3 `Model.generate` 接受 speed，但参数说明标记尚未直接支持。VoiceDesign/CustomVoice 分支没有把 speed 送给实际生成方法；Base ICL 分支也不使用它。本项目非 clone 路径只把该参数送给 vendor，检查的 REST/PCM 交付路径没有对应变速处理。因此当前不能把通用的 0.25–4.0 参数范围当成这几个模型实际可兑现的能力。[对应上游版本源码](https://github.com/Blaizzy/mlx-audio/blob/v0.4.8/mlx_audio/tts/models/qwen3_tts/qwen3_tts.py)

建议先建立真实能力声明：不支持的非默认参数明确拒绝。若以后增加保音高时间伸缩，应作为显式音频后处理能力，并验证音质、延迟和时间戳；不能冒充模型内生韵律控制。描述“慢一点”与精确 `speed=0.8` 是不同能力。

clone 当前拒绝不支持参数是正确边界；缺陷是其他路径和 MCP 没有统一兑现同一原则。这不证明语速就是该次 backend_error 的原因。

## 6. 新发现：zh 与 vendor chinese 的适配

设计注册限定 `language="zh"`；该值经过 SpeechRequest、worker IPC 后原样成为 `lang_code`。本机 vendor 的语言分支按 `config.codec_language_id` 的完整名称查找，未命中则使用没有显式 language ID 的前缀。官方配置键为 `chinese`、`english` 等，而不是 `zh`、`en`。[官方模型配置](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base/raw/main/config.json)

结论：对使用官方这组键的 snapshot，当前 zh 不会强制中文条件，而会落入未指定语言 ID 的路径。这是静态调用链证据，不是本机音质实测；它通常解释控制未生效，不能直接解释此次 backend_error。量化制品若改写了语言字典，应按实际配置重新核对。

建议 API 保留标准语言码，在 adapter 统一映射并验证；未支持语言明确拒绝。普通探针目前默认 auto，应根据验收语种显式指定；跨语言能力必须独立验收，不能因为模型支持多语种就扩大当前中文实验门的承诺。

## 7. 采样、确定性与验收

官方 Base 与 VoiceDesign 发布配置均为 temperature=0.9、top_p=1.0、top_k=50、repetition_penalty=1.05，并启用采样。这些是发布默认值，不是对任意量化/runtime 的最优证明。[Base 配置](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base/blob/main/generation_config.json)、[VoiceDesign 配置](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign/blob/main/generation_config.json)

SpeechRail clone 固定 temperature=0.1、top_p=0.95；MLX ICL 自己就把 repetition_penalty 下限提高到 1.5，所以不能机械照搬 PyTorch 的 1.05。显式设计参考使用 worker 温度默认 0.85；保存的 instruction profile 则通常使用 profile.temperature=0.1，两条设计路径也不是相同采样配方。

低温有可能减少随机变化，也有可能影响自然度与表达；本次没有声学对照，不能认定它导致故障。后续应以同一参考、相同文本集和受控 seed 比较当前配方与 MLX 默认附近配方，先只改变 temperature，再比较 top_p，避免同时改变多个因素。

原始实现曾把 PCM hash 比较结果 `output_nondeterministic` 加入可导致 reject 的 failure_codes。这衡量字节重现性，不能证明跨文本 speaker similarity；当前实现将其保留为独立 repeatability evidence，不再单独拒绝输出。[技术报告](https://arxiv.org/html/2601.15621v1)

建议分三类：

- 正确性硬门：合成完成、有效音频、无截断/严重削波、内容可懂。
- 声学质量：跨文本身份、自然度、韵律与噪声；ASR 不能替代身份评价。
- 工程重现性：相同环境下可重复程度，单独报告，不把合理随机变化自动归为坏音色。

## 8. 缓存与运行时边界

官方 PyTorch 接口允许构建并复用 voice_clone_prompt，避免重复提取参考特征；MLX 公共接口并不与它一一对应。[官方推理 API](https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/inference/qwen3_tts_model.py)

本地已正确记录这一差异：`domain/tts_reference_condition.py` 明确把完整 public prepared-condition 标记 unsupported，并承认 vendor 私有 ICL cache 存在。不能把当前实现说成“完全没有缓存”。

源码进一步显示：SpeechRail 缓存解码后的参考波形；本机 vendor 缓存 ref_codes/ref_text_ids，但仍可重新计算 speaker embedding。其私有键使用 ref_text、音频长度与求和值，不是抗碰撞内容摘要，也没有在该缓存实现中看到 LRU 边界。由此推断：不同参考可能键冲突，长期 worker 的缓存容量与失效也需要专门验证；本次未重现污染或内存增长。

建议保持公共接口边界，不直接操纵私有缓存充当正式能力。若要实现完整 prepared reference，需选择有明确生命周期的上游公共接口或受维护 adapter，并绑定参考内容 hash、voice revision、模型 revision、预处理版本与容量上限。

当前仓库固定 mlx-audio 0.4.8，官方发布页已存在后续版本；本次查看的 v0.5.0 记录不足以证明修复了此次 Base 问题。升级不能替代定位，须先检查相关差异，再做相同语料对照。[后续发布记录](https://github.com/Blaizzy/mlx-audio/releases/tag/v0.5.0)

## 9. 流式、分段与长文本

必须区分模型流式架构、流式文本输入和分块音频输出。Qwen Python wrapper 的 non_streaming_mode 不等同打开真正的流式输出；MLX 另有 stream 参数与分块解码实现。[官方 API 说明](https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/inference/qwen3_tts_model.py)、[MLX 流式说明](https://github.com/Blaizzy/mlx-audio/blob/main/docs/guides/streaming.md)

本机 MLX 0.4.8 的 _generate_icl 接受 stream、streaming_interval，因此当前调用形状有依据。正式文件制作可评估离线整段解码是否改善边界，实时场景再优先低延迟；这属于待测选择，不是已证明的修复。

SpeechRail 的 240 字 planner 与 `generation_token_budget` 属于工程约束。按字符估算音频 token，在数字展开、慢速或表现性语句上未必充分；应检测 EOS/预算耗尽，不能把正常返回但截断的 PCM 当作完成。分段重设 seed 不提供跨段声学连续性保证。

论文长语音实验使用特定微调声音及模型设置，不能直接变成本项目 12Hz Base 量化链路的十分钟稳定性承诺。应独立检查分段接缝、复读漏读、取消恢复与长时资源。[论文长语音实验](https://arxiv.org/html/2601.15621v1#S4.SS2.SSS6)

## 10. 对方案的修订与后续最小验证

优先级建议：

1. 修复请求级错误传递/分类；先获得该次失败的真实异常，停止依赖 stderr 关键词归因。
2. 核对并统一所有 Qwen TTS 的 speed 能力；补标准语言码到 vendor 名称的映射与未知语言拒绝。
3. 区分可路由、允许验证和正式制作验收；拆分字节确定性与声学质量。
4. 对照采样、分段、stream/offline 与参考长度，取得项目配方证据。
5. 补齐 MCP 创建/验证闭环，再分发配套 skill；skill 读取能力，不复制易漂移的模型限制表。

后续验证分两层：确定性回归已执行；真实验证已完成最小合法 clone smoke，正式配方对照与交付对照仍未执行：

| 验证层 | 最小范围 | 通过条件 |
|---|---|---|
| 确定性回归 | fake worker 错误码、旧 stderr、speed、zh 映射、状态与版本变化 | 参数不静默忽略、错误不串请求、未验收不误报制作通过 |
| 经授权真实验证 | 已核验参考的一条 speed=1.0 Base 短句 | 新 wheel 返回 HTTP 200、`audio/x-pcm`、153600 bytes；request ID `req_747238fb10294d998605c330702240e6` |
| 配方对照 | 固定中文短句/数字/疑问/长段，当前温度与默认附近温度 | 同时报告内容、身份、自然度；不只比较 hash |
| 交付对照 | stream/offline、跨段、cold/warm、相同 revision | 无预算截断与边界异常；记录而不预设性能门槛 |

真实验证结果应存于仓库外；报告只保留脱敏摘要、版本、参数与 request ID。若需要 speaker evaluator 或新模型，另行确认模型选择与下载范围。

## 11. 最终判断

模型组合与 ICL 方向符合官方用法；参考规范化、revision 绑定以及拒绝 clone 不支持参数的原则合理。当前实现已补齐启动预热修复、参数/语言校验、独立验证状态、错误契约、MCP 闭环和 packaged skill；真实 smoke 证明合法 Base 请求可交付音频。仍不能把单次 smoke 当作正式质量 benchmark，后续本机调试定位的 backend_error 根因见下节。

## 12. 本机调试补证：Base 使用了不适用的默认音色预热

实测时间：2026-09-21 00:19:51 +08:00。用户明确授权本机调试后，向现有唯一 managed 服务发出一次普通短句 WAV 合成请求，使用已注册 clone，speed=1.0。未创建第二服务、未切档或重启、未修改安装态代码、未重新注册音色。

- 服务：3.0.2、quality，PID 86922，端口 8201。
- request ID：`req_331e0454ab754a3bad117ff56c03436e`。
- 响应：HTTP 502，backend_error；access log 记录耗时 1570.913 ms。
- 同时间服务日志记录 worker_load_error，最终异常为 `ValueError: unsupported voice or variant: default`。
- 内层异常为 `ValueError: voice default is not a clone voice for base variant`。
- 安装态 qwen3_tts_worker.py 与当前仓库文件 SHA-256 相同，排除了该文件的安装/源码漂移。

已确认因果链：

1. Base worker 构造 MlxQwenTtsEngine，warmup 默认开启。
2. 构造函数调用通用 `_generate(..., voice="default", speed=1.0, language="auto")`，没有提供 ref_audio/ref_text。
3. `_generate` 进入非参考分支，generation_condition → resolve_binding(base, default)。default 对应系统音色，Base 绑定只接受 mode=clone，于是抛异常。
4. serve 在 engine_factory 阶段捕获异常，发送 worker_load_error；尚未返回 ready，也尚未处理用户真正的 clone 合成。
5. 父进程异常经 REST 包装为 backend_error。
6. traceback 含预热调用源码中的 speed=1.0。把该日志错误按实际 error_frame_message 组装后送入安装态 `_classify_probe_failure`，实测返回 clone_speed_unsupported，证明当前分类逻辑会把这个启动错误误判为语速错误。

本机 logging 已使用 speechrail.log 与 access.jsonl；LaunchAgent stderr.log 不是当前应用日志的完整来源。此前只检索 stderr 未找到目标异常，不能视为本机无诊断证据。

处置建议：按 model_variant 定义预热。Base 无参考时只初始化模型，不调用默认系统声音；首次合法 clone 请求承担推理初始化，或提供明确、受控且有授权的专用 clone warmup。不能为绕过预热而放宽 Base 的绑定校验或静默改走 VoiceDesign。同时修复结构化错误传递和探针分类。

最小回归：Base 默认启动不能调用 default 系统音色；真实合法 clone 请求能进入 reference 分支；含 speed 源码行的 worker_load_error 不得分类为 clone_speed_unsupported。修复部署后还需重复此次真实请求并核验音频，才能宣称恢复。

调试前服务仍为 3.0.2/quality，health=200，batch/realtime 活动数均为 0；tts_ready=true、tts_warm=false。这个状态证明 readiness 不等于 Base 能成功启动推理。本次失败请求没有改变用户音色资产。

## 13. 实施后 managed runtime 受控验收

验收时间：2026-09-21。由当前源码构建的 `speechrail-3.0.2` wheel（release hash suffix `c9d3eaebd488`）经 managed installer 切换；`downloaded_bytes=0`，quality profile 保持不变，上一 release 保留。controller 启动后新 runtime 的 `/health` 与 `/readyz` 均返回 200，服务 PID 为 56072。

使用已有 clone `qingfeng_integrity_female_20260920` 做最小真实请求：`model=speechrail/qwen3-tts`、`speed=1.0`、`language=zh`、不传 `instruction/seed`、`validation_policy=allow_unverified`。返回 HTTP 200、`audio/x-pcm`、153600 bytes，request ID 为 `req_747238fb10294d998605c330702240e6`。这证明修复后的 Base worker 能进入合法 reference 分支并完成音频交付；本次没有运行完整质量 benchmark，因此 voice 仍保持 `production_ready=false`，直到独立输出验证通过。

同一 runtime 的负向验收也符合契约：非默认 clone speed 返回 `clone_speed_unsupported`；`require_output_pass` 在输出验证尚未完成时返回 `voice_not_production_ready`。因此原始 `clone_speed_unsupported` 不是合法 speed=1.0 合成的后端根因，而是对错误启动日志/或非法 speed 场景的边界标签；原始 `backend_error` 的直接根因仍是 §12 所述 Base 使用 `default` 系统音色预热。
