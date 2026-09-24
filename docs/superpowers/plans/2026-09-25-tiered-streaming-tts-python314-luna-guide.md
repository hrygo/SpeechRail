---
title: "Luna 实施指南：分档稳定音色、真双向流式与 Python 3.14"
status: in_progress
audience: "Luna / SpeechRail 服务与原生 App 实施者、验收负责人"
version: "1.3"
date: 2026-09-24
---

# 1. 问题结论

**交付目标：** SpeechRail 使用标准 CPython 3.14 与经验证的新推理运行时；light/balanced 以 CustomVoice 固定 speaker、quality/extreme 以 Base clone 固定 revision，在同一次 utterance 内增量接收 LLM 文本并流式输出 PCM，支持有界状态、及时取消和逐档能力声明；SpeechRail 原生 App 完成协议、文本流和播放打断接入。

**设计依据：** `docs/superpowers/specs/2026-09-25-tiered-streaming-tts-python314-design.md`。本文在该设计基础上补齐实现符号、协议细节、前置缺陷和测试安排。现行 `contracts/` 在实现落地前仍是当前接口事实，本文拟新增接口不是已存在能力。

**可执行性状态：条件式可执行／模型可行性待确认。** W0–W3 可按步骤开始；W4 的真实模型门通过后才执行 W5–W10 的生产接入。未知的是开放模型增量条件的实际正确性与性能，不是允许实现者随意选择的产品语义。若门失败，提交失败证据和局部后端替代建议，停止依赖它的任务，不以分句重新生成替代。SpeechRail 三处既有 macOS 修改必须保留；需要写入同处时先确认来源和可分离范围，不能覆盖他人版本。

用户已明确 Sona 废弃，相关功能已集成至 SpeechRail App；不分析、修复、测试、迁移或依赖 Sona，也不把其工作区状态作为本任务阻塞。本文 v1.1 撤回 v1.0 的 Sona 客户端前置任务，改为已核实的原生 App 路径。

用户已明确授权按本指南逐阶段实施、运行对应验收并以原子 commit 交付；本轮已按 W0 冻结基线、开始 W1。该授权不扩展到模型下载、UI 自动化、服务安装/切换或远端推送，这些操作仍需满足各自的项目授权门。

# 2. 当前实现与根因

## 2.1 已核实的源码事实（2026-09-24）

| 范围 / 文件 | 现有符号 / 行为 | 必须处理的问题 |
|---|---|---|
| `pyproject.toml` | Python >=3.12,<3.13；Ruff py312；mypy 3.12 | Python 目标未升级 |
| `src/speechrail/service/bootstrap.py` | `_python_version_tuple` 只接受 3.12.x；`prepare_runtime` 的 uv 调用硬编码 3.12 | 只改项目声明仍不能准备 vendor runtime |
| `src/speechrail/service/managed_install.py` | 创建主服务 venv 时指定 3.12 | 主服务与 vendor runtime 可能版本分裂 |
| `src/speechrail/config/model_catalog.py` | `RuntimeLock`；依赖仅允许 package==version + sha256 | fork 不能直接塞 editable/git URL 绕过校验 |
| `src/speechrail/assets/runtime-lock.json` | Python 3.12.14，含 ASR/TTS requirement 摘要及文件 hash | 必须重新生成，不能只改 Python 字符串 |
| `src/speechrail/application/realtime_openai.py` | 顶层 `import audioop`；`Pcm16RateConverter`；`_input_resampler` | Python 3.13+ 移除 audioop，模块导入即受影响 |
| `src/speechrail/compatibility/openai_realtime.py` | `validate_session_update` 固定当前输入为 16 kHz，禁止未知字段 | 旧 24→16 kHz 重采样路径可能为历史残留；先做可达性检查，不引入无必要兼容包 |
| `src/speechrail/backends/qwen3_tts_worker.py` | `MlxQwenTtsEngine.synthesize/_generate`；`serve` 在 synthesize 循环内写完音频才再次 read_frame | worker 不能在同一生成期间读取后续文本/取消 |
| `src/speechrail/domain/tts_text_planner.py` | `TtsTextPlanner(max_chars=240)` | 超限块分开生成，不是连续模型状态 |
| `src/speechrail/backends/qwen3_tts.py` | `Qwen3TtsWorker.synthesize`、`Qwen3TtsCapabilityRouter`、profile lease | 保留身份快照和路由；新增增量 session 生命周期 |
| `src/speechrail/runtime/worker_process.py` | `AsyncFramedWorkerProcess` 已分 read/write/lifecycle lock | 不重写现有传输；使用 send + 单 reader，不能混用 exchange 抢 response |
| `src/speechrail/application/realtime_openai.py` | `_create_tts/_synthesize_tts/_cancel_response/_finalize_tts`；一个活动 response | 目前完整文本 create，没有 append/finish |
| `src/speechrail/domain/ports.py` | `SpeechSynthesizer.synthesize(SpeechRequest)` | 新增独立增量 port，不能把 text 弄成可变字符串冒充流式 |
| `src/speechrail/runtime/resource_governor.py` | `ResourceGovernor.reserve`、lane/resource_key | 增量 utterance 等待文本期间仍需持有并治理资源 |

**SpeechRail App 已核实的当前链路：**

- `macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift::runReply(spoken:generation:)` 消费 `LLMProvider.stream`，调用 `takeSentences` → `VoicePrompt.spokenText` → `enqueueTTS` → `sendNextTTSIfNeeded`，逐句提交独立生成；`pendingTTS`/`ttsRequestInFlight` 控制单请求串行。
- `RealtimeASRClient.swift::sendTTSCreate/cancelTTS` 已使用当前 `SpeechRailTTSCreate/SpeechRailTTSCancel`；`SpeechRailControlKit/RealtimeContractTypes.swift` 是请求 DTO 入口，现有 `RealtimeContractTests.swift` 已验证 namespace。因此不存在需要先迁移旧协议的 App 前置缺陷。
- `RealtimeASRClient` 已接收 `response.output_audio.delta`，但当前 `.responseAudio(Data)` 与 `.responseDone(status:receipt:)` 未把 response identity 传递至上层；增量模式要补充身份和序号并隔离迟到事件，不能误清新请求。
- `AssistantSession.stopSpeaking` 已先 invalidateReply、清队列、停播，再 cancelTTS；`replyGeneration` 已隔离旧 LLM delta 和落库，不应重建另一套互相冲突的代际机制。
- 默认采集播放通过 `AssistantAudioSession.swift::AudioEngineSession` 共用 engine；`enqueuePlayback/stopPlayback` 已有 playbackGeneration/pendingBuffers，但不是按音频时长限制的有界队列。`AssistantAudioPlayback.swift::PCMStreamPlayer` 是现有替代 source 的播放路径，需要同样的取消/容量语义。
- `AudioEngineSession` 目前使用 `.dataConsumed` 调度完成回调，`AssistantSession.startPipeline` 的 onPlaybackDrained 会切回 listening；不能把该回调直接当作物理播完或整轮结束。增量输入饥饿时临时排空需要与服务端终态区分。
- `LLMProvider.swift` 已使用 MacPaw/OpenAI；不为本任务手写新的 LLM transport 或搬回外部客户端。
- `Package.swift` 的 SpeechRailAppSupport 使用显式 sources，当前不包含 AssistantSession/两个助手音频实现。新增纯状态机/缓冲器必须显式登记，不能假设 swift test 自动覆盖 App 全链路。
- `scripts/macos_app_test.sh` 不转发筛选参数，默认 SpeechRailApp.xctestplan 包含 SpeechRailAppUITests。不可把给该脚本传 --unit-only 当作已有安全入口；本计划用 SwiftPM 纯测试，实际 App 构建遵循现有包装脚本。

## 2.2 现象、假设与验证边界

用户报告/目标关注跨请求声音像不同人、切句衔接和首音延迟；本次没有音频复现，不能认定所有听感问题都由同一原因造成。

可证实的机制：VoiceDesign 每次 instruction 生成不等于固定 clone；每次独立 render 没有共享同一 utterance 的生成状态；客户端提前断句和服务端 planner 叠加；升级 Python 存在 audioop 与安装器硬编码阻塞。

待实测假设：固定条件可降低身份漂移；新版 ICL 重复惩罚窗口可改善长句语速；增量文本可在目标权重/MLX 实现下维持对齐。W4/W11 对这些假设分别验证。

## 2.3 分档事实与改造差异

| 档位 | 当前 ASR / 默认 TTS / clone | 实施路径与验收 |
|---|---|---|
| light | ASR 0.6B q8 / CustomVoice 0.6B q8 / 无 clone；无 aligner、分人 | speaker 条件；CustomVoice 增量；不安装 Base |
| balanced | ASR 1.7B q8 / 同 light 的 TTS / 无 clone；aligner q8、分人 | 复用 TTS 模型探针，单独验证整档资源/延迟 |
| quality | ASR 1.7B q8 / VoiceDesign 1.7B q8 / Base 1.7B q8；aligner bf16、分人 | 稳定角色使用 Base；VoiceDesign 保留创建/试听 |
| extreme | ASR 1.7B bf16 / VoiceDesign 1.7B bf16 / Base 1.7B bf16；aligner bf16、分人 | 候选档，Base bf16 独立探针与实时门；不继承 q8 结论 |

同名内置 voice 在 CustomVoice 和 VoiceDesign 下条件不同；跨档不承诺同声。quality↔extreme 也不能绕过 voice/model revision 冲突检查或共享 prepared tensors。

# 3. 目标行为

1. LLM 第一批可朗读文本到达后启动一次 utterance；首个音频输出早于整个 LLM 回复完成。
2. 后续 append 进入同一次模型生成，不按每句话/240 字重启；采样状态和 decoder 按模型正确语义保持。
3. CustomVoice 固定 speaker，Base 固定 reference/revision；不在对话热路径创建音色或下载模型。
4. 一连接一个活动 TTS，完整文本 create 与增量 start 互斥；完成后可开启下一轮。
5. 输入关闭与输出完成分离，finish 后继续 flush；等待更多文本不等于 EOS。
6. 文本顺序、音频序号、sample offset、终态、错误和能力定义唯一；客户端不能收到取消后的旧音频。
7. 停播立即发生在客户端；服务端取消有期限并释放 utterance/cache lease，不要求每轮卸载模型。
8. 3.14 是 SpeechRail 新运行基线；旧完整 release 只用于回滚。普通 REST/完整文本 TTS 继续作为正式能力和质量基线。
9. 四档分别报告支持与验收，未支持的增量模式明确拒绝，不静默换声音、换档或分句降级。
10. 音色资产不静默迁移、覆盖或删除；App 的会议、记录库、LLM provider 接入与麦克风 ownership 不在本次无关重构范围。

# 4. 推荐解决方案

## 4.1 选型结论

采用“统一 runtime/生命周期 + 两条模型 adapter + 分档发布门”。不选仅升级依赖（不能提供 append），不选长期等待全文（不满足目标），不选无限聊天 KV（失控且不负责跨轮身份），不选第三方大框架整体替换（无必要扩大范围）。

候选为 CPython 3.14.7 + mlx-audio 0.5.6；复用上一轮官方/PyPI核查，不把候选视作已安装。模型层需要扩展时，使用窄范围受控 fork，固定 commit 构建带明确版本的 wheel；严禁永久 monkey patch 或 editable 生产依赖。

先证明 CustomVoice 和 Base ICL 双向流式，再把增量 port 接入 worker；模型能力门失败时输出可复现报告，不自行改成另一种产品语义。

## 4.2 模块边界（拟新增均显式标识）

| 路径（SpeechRail 根目录相对） | 责任 |
|---|---|
| `src/speechrail/domain/tts_stream.py`（拟新增） | 冻结 start options、输入状态/终态、限制、增量 port；不 import MLX |
| `src/speechrail/backends/qwen3_tts_incremental.py`（拟新增） | vendor 扩展 adapter；在 worker 内导入；CustomVoice/Base conditioning 差异 |
| `src/speechrail/backends/qwen3_tts_stream_host.py`（拟新增） | 同一现有 worker 进程内的控制收取/模型步进/输出队列，不增加模型进程 |
| `src/speechrail/backends/qwen3_tts_stream_client.py`（拟新增） | 父进程 session handle、单 reader 分派与 close/abort；复用 AsyncFramedWorkerProcess |
| `src/speechrail/application/tts_stream.py`（拟新增） | 资源/profile lease、request 去重、状态与 receipts，供 Realtime session 调用 |
| `tools/update_runtime_lock.py`（拟新增） | 从已解析的 `.txt` 生成 runtime-lock 摘要/hash；不下载/安装 |
| `tools/probe_tts_incremental.py`（拟新增） | 显式授权的真实探针，输出脱敏计时/状态报告到仓库外 |
| `macos/SpeechRailApp/SpeechRailApp/AssistantTTSStreamCoordinator.swift`（拟新增） | @MainActor 单轮 TTS 状态、generation/response 关联、ACK 与取消；不直接使用音频硬件 |
| `macos/SpeechRailApp/SpeechRailApp/AssistantSpeechTextBuffer.swift`（拟新增） | 稳定朗读前缀与尾部缓冲，注入 clock 可测 |
| `macos/SpeechRailApp/SpeechRailApp/AssistantPlaybackLedger.swift`（拟新增） | generation 与排队样本预算、drain/终态组合，纯状态可测 |

既有文件按 W 任务定点修改。不要为整洁拆解无关巨大模块，只有增量路径放入独立模块。生产依赖版本和 cache key 只在一处定义，不在前后端各写一套判断。

# 5. 详细实施步骤

每项执行固定顺序：核对写集 → 写能表达目标的失败测试 → 最小实现 → 运行本项测试 → 检查 diff。下列提交主题仅用于逻辑分组，不授权 git commit。所有新 API/文件名是本文拟定接口，不是现有符号。

## W0. 单仓工作区与证据冻结

**文件：** 本指南、对应设计、SpeechRail 的 AGENTS 和任务相关源码（只读）。

- SpeechRail 当前 main 有三处现有修改：`SurfaceHeaderView.swift`、`VoicePrompt.swift`、`VoicePromptTests.swift`；原设计未提交。本任务不得收进自己的变更或重置。
- 本次仅在 SpeechRail 仓库实施，不读取或修改已废弃客户端。AssistantSession/RealtimeASRClient/音频实现写入前重新检查是否出现并行改动。
- 执行者在工作记录中保存本仓库 HEAD、工作区状态、相关文件 hash、目标 Python/vendor 候选、准许执行的测试层级。无需读取 secrets、私有 env、模型目录。
- 先检查拟新增路径不存在；有同名文件时核实，不直接覆盖。本指南重名时后缀递增。

**完成条件：** 写集归属可说明；无法确认的并行改动仅阻塞相关文件，不阻塞独立工作。不得把“方案生成授权”当作实施授权。

## W1. 移除 Python 3.14 导入阻塞，保持当前输入契约

**修改：** `src/speechrail/application/realtime_openai.py`、`tests/test_realtime_openai.py`；核对 `compatibility/openai_realtime.py` 和 `contracts/realtime-openai.md`。

- 全仓定位 audioop、Pcm16RateConverter、input_sample_rate 的读写和测试。当前入口仅允许 16 kHz PCM16，转换器的 24 kHz 用例是直接单元调用；不要凭一个搜索结果就删接口。
- 在确认没有受支持的非 16 kHz 入口后，删除顶层 audioop 导入/告警抑制、Pcm16RateConverter 和 session 中不可达 resampler 状态及分支；删除/替换只验证旧转换器的测试。
- 增加当前 wire 固定输入格式回归：拒绝 sample_rate/旧嵌套 audio 字段，接受正确 PCM16，拒绝奇数字节；保留当前时间线/EOF 边界测试。
- 新增 Python 3.14 模块导入 smoke（不创建 app、不启动服务）。无旧入口时不添加 audioop-lts，也不新写重采样器。
- 如果发现真实受支持的非 16 kHz 内部消费者，停止该删除并提交调用链和契约证据；先明确该能力的独立替代设计，不无声改变采样结果。

**完成条件：** 主服务不再依赖已移除模块，当前 16 kHz wire 行为不变；未借机支持新采样率。

## W2. 统一 3.14 与可复现 runtime 供给

**修改：** `pyproject.toml`、`uv.lock`、`src/speechrail/service/bootstrap.py`、`managed_install.py`、`preflight.py`、`src/speechrail/assets/runtime/`、`runtime-lock.json`、`.github/workflows/ci.yml`、`release.yml`；新增 lock 工具与测试。

- 使用标准 CPython，项目 `>=3.14,<3.15`，classifier、Ruff target、mypy 版本同步。安装器从 validated RuntimeLock.python 获取解释器目标，禁止散落 3.14/3.14.7 两种来源。
- `_python_version_tuple` 只接受 3.14.x；uv 创建 venv、dry-run/sync/ffmpeg 供给均从同一值推导。runtime_key 必须随 Python、依赖和制品 hash 变化。
- `.in` 中将 mlx-audio 改为候选 0.5.6；其他包非必要不升级。分别生成带 hash 的 ASR/TTS锁，再验证合并解析（现有 bootstrap 使用 shared_python 同步两份锁）；不能只验证两套独立虚拟环境。
- lock 工具 CLI 拟定 `--python 3.14.7 --id <release-label>` 与 `--check`：只读 `.txt`，规范解析完整 pinned requirement（含续行 hash），生成两个 requirement 数组和精确文件 SHA256；原子写出，check 不改文件。保留现有 RuntimeLock严格校验，不允许宽松依赖。
- fork 成为必要后，W4 再生成含 fork wheel 精确版本/hash的新锁；不能把 file://工作区、git branch、editable 或不明 URL 写入正式制品。
- 仓库外新候选 venv；不运行正式 app home 的 prepare_runtime 做探针，因为它会切 current。测试使用 tmp_path 与注入 runner。
- CI保留现有平台角色，产品 arm64 macOS；Ubuntu平台无关质量门不宣称运行支持。同步计划涉及的 active 文档/技能中当前 Python 约束；历史 archive 不重写。

**测试：** `tests/test_runtime_bootstrap.py`、`test_installer.py`、`test_service_preflight.py`、`test_model_presets.py`；拟新增 `tests/test_runtime_lock_generation.py`。

**完成条件：** hash/check可复现，旧锁与新锁 key 不同，准备失败保留 current/私有配置，主服务与 vendor 的Python版本一致。wheel 存在不能替代真实导入；没有安装授权时本项停在候选锁/确定性结果，不宣称运行通过。

## W3. App 当前协议与可测试边界基线（独立于模型探针）

**核查/修改：** `macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift`、`SpeechRailControlKit/RealtimeContractTypes.swift`、`SpeechRailMacControlTests/RealtimeContractTests.swift`、`Package.swift`。

- 保持现有完整文本 `sendTTSCreate/cancelTTS` 行为，不实施不存在的旧协议迁移；以现行服务端测试与契约固定 App 请求/响应 fixture。
- 为 RealtimeASRClient 现有 receive decoder 建立可注入传输/事件解析 seam（拟新增内部 transport protocol，生产继续 URLSessionWebSocketTask，不重写网络栈）。测试不连接真实服务。
- 先补 request/response关联基线：旧done不能清空当前新request，取消后迟到audio不再向播放层发出。若现有Event case需要扩展payload，统一更新全部switch消费者和测试，不留忽略identity的兼容分支。
- 核对 AssistantSession 当前完整文本队列、replyGeneration、onPlaybackDrained 的拥有关系；记录 W9 改造范围，保留 typed/spoken/replay/stop 各入口。
- 纯测试通过 SwiftPM `SpeechRailAppSupport`，拟新增的 coordinator/buffer/ledger 文件显式加入 sources；Xcode `.pbxproj` 使用现有方式同步登记。实现时读取 xcode-project-setup 和 swift-testing 指南，不假定目录自动纳入编译。
- W3 不加载模型、不调用麦克风、不启动 App、不运行 macos_app_test.sh。新协调器使用 fake client/player/LLM delta/clock，避免单测构造 AudioEngineSession。

**完成条件：** 当前协议基线有真实契约fixture；完整文本原行为保留；新纯状态测试能在不启动UI/音频设备的条件下运行。

**执行记录：** 生产 transport 仍为 `URLSessionWebSocketTask`，仅增加内部 fake-transport seam。TTS 音频/终态携带 `request_id` 与 `response_id`；测试 fixture 按当前服务端 serializer 的 `response.created`、`response.output_audio.delta`、`response.done` 结构构造，覆盖旧 request/response 的终态与音频隔离、取消后迟到音频抑制，并核对客户端实际发出的 create/cancel 字段。验证命令 `swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests`：12 passed；`swiftc -frontend -parse` 检查 Assistant/Caption/Meeting session 文件通过；`git diff --check` 通过。SwiftPM 当前只编译显式登记的 Support/Test 源，三处 App session 文件仅做语法解析、未完成 App module typecheck；不运行 App、麦克风、真实服务或 UI 自动化。SwiftPM 仍报告 23 个非 target 文件未显式声明，这是现存 target 布局警告。

## W4. 模型层真增量证明与固定 vendor 扩展（关键门）

**拟新增：** `tools/probe_tts_incremental.py`、`tests/test_tts_incremental_probe_contract.py`；vendor本地受控checkout不在此仓库冒充已有路径。

vendor 定点范围（基于核实的 v0.5.6）：`mlx_audio/tts/models/qwen3_tts/qwen3_tts.py`、`talker.py`、`speech_tokenizer.py`，必要时新增该目录的 `incremental.py`。Qwen3TTSBatchSession 不用于代替 append。

1. 基于明确 tag/commit建立可恢复候选 checkout，不修改安装目录。具体fork远端地址、commit、wheel版本/hash必须来自实际创建结果，本文不编造；远端创建/发布另获授权。
2. 明确 CustomVoice 文本条件与 Base ICL prompt/pre-fill/trailing-text 布局，记录准确 token/position关系。不能把纯文本 token直接追加到混合声学 KV。
3. 提供 `start(options, condition)`、`append(text)`、`finish_input()`、`step(max_steps)`、`cancel()`、`close()`；step返回增量PCM、等待文本或终态。完整文本 generate可保持原入口。
4. 维护增量 tokenizer 的稳定前缀与未提交尾部；用“完整文本一次tokenize vs 任意切分后的提交序列”检验所采用策略。未来字符会改写尾部分词时延后该尾部，不重写已消费KV。
5. 暂时无文本时不能提交不可逆最终EOS；finish后按原模型合法结束机制生成。不得简单永久禁EOS造成失控。若训练/权重语义无法支持，判模型门失败。
6. 正确延续 talker、文本对齐、codec/decoder状态；code predictor按帧重置；有界步进可取消。支持范围不足时在probe报告failed，不硬凑后端。
7. 首次PCM输出后再投递后半文本，断言同一generation identity/初始prefill次数=1、输出新增内容且无重启；用fake只能验证探针逻辑，真实声音正确性必须单独验收。
8. CustomVoice q8、Base q8、Base bf16各一份报告；VoiceDesign完整文本/注册回归不得因扩展损坏。

**报告结构（拟定）：** artifact_revision、variant、quantization、vendor_commit、python、input_schedule_id、initial_prefill_count、append_after_first_pcm、terminal、timings、sample_count、peak_resource_summary、correctness_review、limitations。真实文本/音频只在获授权的仓库外制品中，不进入普通日志。

**完成条件：** 两条路径真增量和安全结束成立；若q8成立bf16未达性能，只能开放对应已验收档，四档完整目标仍未完成。失败时停止W5之后生产接入，保留W1–W3可独立交付的变化。

## W5. 增量领域 port、限制和身份租约

**拟新增：** `domain/tts_stream.py`、`tests/test_tts_stream_state.py`。**修改：** `domain/tts_reference_condition.py`、`backends/qwen3_voice_binding.py`、`tests/test_tts_reference_condition.py`、`test_tts_profile_snapshot.py`。

- 按第6节定义唯一状态/options/limits类型，不修改 SpeechRequest.text为流。
- 起始阶段复用 get_voice_registry().lease_profile(expected_revision=...)，冻结profile与model/runtime revision；不能只get后提前释放。
- CustomVoice只接合法speaker；Base只接clone；VoiceDesign不声明增量稳定角色支持。
- prepared condition以内容身份+预处理+模型/量化/tokenizer+实现版本为key；内存租约保护，取消不误释放其他使用者。普通非流式继续走现有路径，不能因为新增provider使所有版本假报supported。
- 初始限制集中在 TtsStreamLimits：append≤512 Unicode codepoints、总量≤4096、待模型消费≤2048；输入等待15s、utterance墙钟120s；待发送PCM≤1s（24kHz mono PCM16为48000 bytes）；最慢消费者等待2s。均为安全初值，不是质量最佳参数。byte与codepoint限制分别校验，拒绝bool充当整数。
- GPU KV等动态预算用模型探针声明与governor校验，不伪造全档统一MB值；缺少上限估计时增量能力不ready。模型特定max_steps基于token预算和probe结果固定于generation profile。

**完成条件：** fake状态表与身份隔离测试通过；新路径不允许盲目跨精度共享cache。

## W6. Worker双向控制与父进程session

**修改：** `backends/qwen3_tts_worker.py::serve`、`TtsWorkerEngine`、`MlxQwenTtsEngine`、`backends/qwen3_tts.py::Qwen3TtsWorker/Qwen3TtsCapabilityRouter`；拟新增第4节三个stream adapter/host/client模块。

- 保留进程start/ready握手；ready新增可验证的增量协议版本和支持variant。私有 `PROTOCOL_VERSION` 为共享ASR/TTS事实，不为TTS新增帧随意全局bump；优先在TTS握手协商 `tts_stream_protocol=1`。如果必须bump，则所有producer/consumer同步测试，不保留半套协议。
- 私有新帧拟定：`tts_stream_start/text/finish/cancel`，输出 `tts_stream_started/text_accepted/audio/done/error`，全携带 request_id/response_id及stream protocol。
- stdin reader只解帧、校验大小、入有界队列；单模型线程负责MLX状态。stdout写入不得让推理线程永远阻塞；用有界writer队列和异常通报，cancel保留优先标志。退出时join/回收，不遗留后台写线程。
- 父端对活动stream只启用一个receive dispatcher；append/finish走send，不再exchange，ACK/audio/terminal由dispatcher分发。完整文本synthesize与stream持有同一worker lease，不能并发抢读。
- 取消先协作式停止；超期只使用现有process.abort/close回收精确worker子进程，不pkill整个服务。被强制回收的worker置not-ready，后续按既有受控重启恢复。
- 保存现有24kHz PCM验证、binary payload帧、timing/delivery语义；新流不伪造句级timing。

**测试：** `tests/test_worker_protocol.py`、`test_worker_process.py`、`test_qwen3_tts_worker.py`、`test_qwen3_tts.py`；拟新增 `tests/test_tts_stream_worker.py`。模拟完整pipe收发，验证blocked read时仍可append、慢writer时cancel可处理、无second reader、一次terminal和资源回收。

## W7. 应用层资源治理与输出生命周期

**拟新增：** `application/tts_stream.py`、`tests/test_tts_stream_application.py`。**修改：** `application/services.py`、`application/tts_admission.py`、`runtime/resource_governor.py`（仅必要扩展）、`backends/qwen3_tts.py`。

- StreamController复用router.resource_key_for_voice，整个utterance持有governor.reserve、worker lease和voice lease；结束顺序为停止生成/reader→确认回收→释放引用→释放资源。
- 等待文本不释放租约、不触发idle eviction；输入超时主动终止。组级evict对活跃session明确busy，不强卸载。
- 集中状态终结，complete/cancel/error race只有一个胜者；不让后台task异常被吞掉。
- 复用render_receipts：start记录实际revision，发送成功再累加sample/bytes，终态一次收束。未发送PCM不计入“已发送”；服务端不报告播放进度。
- 新控制器不存整轮prompt日志；最多保留有界文本用于模型，terminal清理。ASR、batch冲突和跨lane规则保持既有契约。

**测试：** `test_resource_governor.py`、三组`test_qwen3_tts_capability_router*`、`test_tts_profile_snapshot.py`及新application测试。覆盖finish/cancel同时发生、等待文本时evict、参考撤销/删除租约、跨lane超预算fail-closed。

## W8. 公共协议、能力和服务器集成

**修改：** `compatibility/openai_realtime.py`、`application/realtime_openai.py`、`http/routes/system.py`、`contracts/realtime-openai.md`、`contracts/openapi.yaml`（若models/voices响应schema变化）、用户文档。

- parse_client_event加入start/text/finish，新增parser；按第6节字段精确校验。现有create/cancel字段不破坏；新start与create共享请求ID ledger和活动TTS判定。
- start通过后异步创建controller；不能在handle里await整轮生成阻塞后续append。
- `_finalize_tts`保持唯一终态机制，或由controller生成终态结果交给其发送；不能两个模块各发一遍response.done。
- 输出沿用当前 response.output_audio.*；新增namespaced输入ACK/ready及audio extension，不重新引入legacy事件。未知字段/负序号/错revision等按稳定错误码失败。
- 能力resolver同时由/models、/voices和握手消费：variant/artifact支持、active profile启用、实现版本、preflight、ready、预算/资源可用性分开；不对含多个voice的模型简单OR后声称所有voice都支持。
- stable角色模式的quality/extreme instruction声音明确not-supported并提示注册clone，不在请求里自动合成参考。完整文本VoiceDesign保留。

**测试：** `test_realtime_caller_wire.py`、`test_realtime_openai.py`、`test_websocket_contract.py`、`test_tts_voices_api.py`、`test_model_presets.py`；拟新增 `tests/test_realtime_tts_incremental.py`。包含严格旧事件rejection、新旧create互斥、voice级能力与握手一致、slow consumer、无音频finish、错误终态。

## W9. SpeechRail App 单轮增量文本、播放与打断

**修改：** `macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift`、`RealtimeASRClient.swift`、`AssistantAudioSession.swift`、`AssistantAudioPlayback.swift`、`SpeechRailControlKit/RealtimeContractTypes.swift`；拟新增 `AssistantTTSStreamCoordinator.swift`、`AssistantSpeechTextBuffer.swift`、`AssistantPlaybackLedger.swift`。

1. **请求与事件 DTO：** 在 ControlKit 新增 start/append/finish 类型，字段服从第6节；RealtimeASRClient 新增 `startTTSStream`、`appendTTSText`、`finishTTSText`（拟新增方法），继续复用 cancelTTS。单一 WebSocket receive loop 分派 ASR/TTS，不为每个 delta 创建连接或启动第二个 recv task。
2. **单轮协调器：** @MainActor coordinator注入发送、停播、enqueue、clock闭包/协议，拥有requestID/responseID、acceptedSequence、inputClosed、terminal、playbackDrained与replyGeneration。AssistantSession 保留LLM/记录库职责，所有增量TTS阶段委托协调器；不要复制一套swift端生成模型状态。
3. **接入 runReply：** 保留 LLMProvider.stream、原始reply/history/SQLite写入及generation守卫。第一批有效可朗读文本start一次，后续append；流正常完成flush文本并finish一次。增量模式不再调用takeSentences→enqueueTTS→sendNextTTSIfNeeded逐句create。完整文本replay等独立功能可保留，但禁止用户选实时模式后静默走旧队列。
4. **文本安全前缀：** 新buffer注入时间，初值150ms最大等待；数字/单位/英文尾词和跨delta Markdown结构保持稳定。当前VoicePrompt.swift有并行修改，只调用既有清洗接口或在新buffer组合，不能覆盖该文件；每片清洗不得strip掉单词间隔、泄漏半个标记。屏幕/落库用原始LLM文本，不用朗读文本回写。Swift协议字符限额按 `unicodeScalars.count`，不得用String.count（grapheme）假装Python codepoints。
5. **发送与ACK：** 文本发送worker和音频消费独立推进，但不使用无界Task/AsyncStream缓冲；上限/sequence/ACK按第6节。LLM完成事件不能越过未确认文本提前finish；空回复不start，LLM失败取消该轮TTS并显示失败，不假装completed。
6. **回包关联：** RealtimeASRClient校验当前request/response、chunk_index/sample_offset及偶数字节；事件向上层带identity/generation。取消时立刻使当前generation失效；旧started/ACK/audio/done全部隔离，旧done不清新状态。输出队列按样本计量，不能只限制包数。
7. **播放容量：** AudioEngineSession 的 pendingBuffers 改为结合纯 ledger管理queuedSamples（初值≤1s）；enqueue等待预算时允许cancel/route failure唤醒，不阻塞主actor或WebSocket所有事件。ACK/终态等控制事件不得被慢播放器堵住；播放队列满且超过期限时明确失败而非无限积压。
8. **保留已有代际：** stopSpeaking/语音插话先invalidateReply与协调器generation、停本地播放，再cancel服务端；AudioEngineSession已有playbackGeneration复用。PCMStreamPlayer现有替代source路径使用同样预算和迟到buffer规则，不额外增加播放器。
9. **区分耗尽和结束：** 现在 `.dataConsumed` 回调不能作为“用户听完”；核实AVAudioPlayerNode完成语义后使用适当回调/时钟报告播放完成。状态回到listening要求服务端terminal且该generation播放drained；输入未完或服务器仍生成时暂时drained只表示等待/欠载，不算整轮结束。取消可立即回listening。保留半双工闭麦和全双工插话的既有模式规则，不因drained间隙擅自改变ownership。
10. **生命周期：** stopCapture、断线、设备路由重建、changeVoice/replay都取消或排斥当前utterance，等待局部任务收束；声音变更只影响新轮。除非用户请求，不改变LLM请求、MacPaw/OpenAI依赖、会话持久格式、会议和提词器业务。

**拟新增 Swift 测试：** `AssistantTTSStreamCoordinatorTests.swift`、`AssistantSpeechTextBufferTests.swift`、`AssistantPlaybackLedgerTests.swift`、`RealtimeTTSStreamTests.swift`，放入 `SpeechRailMacControlTests`，只用fake和synthetic PCM。既有 `RealtimeContractTests.swift`、`LLMProviderTests.swift` 回归。

**完成条件：** LLM尚未结束时PCM已进入fake播放器；同轮一次start/finish；取消旧包不播放；临时drained不宣布完成；代码登记到SwiftPM/Xcode且经授权的包装构建验证真实AssistantSession接线。纯协调器测试不能冒称AVAudioEngine、硬件可听延迟或App交互验收。

## W10. 分档能力呈现与切换保护

**SpeechRail 修改：** `http/routes/system.py`、profile/controller相关既有实现（由`tests/test_profile_service_controller.py`、`test_profile_switch.py`定位）；macOS `ServiceAPIClient.swift::ServiceModelCapabilities/ServiceModelEntry`、`AppModel.swift`（仅确有显示需求）；App 的 `AssistantView.swift` / `SettingsAssistantPane.swift` 声音选择仅按真实需求定点修改。

- light/balanced内置speaker可进入已验收增量模式；clone保留资产但当前档明确不可用。
- quality/extreme默认VoiceDesign声音不自动提升成clone；提供明确“先准备固定音色”动作，由已有注册链路承担；不覆盖ID。
- profile切换发现活动utterance时默认返回busy/要求显式停止，不后台热切；用户明确停止后先取消并等待lease释放，再走已有switch。
- Mac DTO新增字段默认缺失=false/not_available以允许回滚服务；不把UI未知能力当成true。此是能力协商，不是维护旧macOS兼容分支。
- 不触碰SpeechRail已有修改的VoicePrompt/SurfaceHeaderView等；如必须改同处，先核实。UI修改前读取macOS设计系统；不用裸视觉常量。

**测试：** 后端四档profile/voice矩阵；Mac在已定位的`SpeechRailMacControlTests`中新增`StreamingTtsCapabilitiesTests.swift`（拟新增），仅纯DTO/映射测试，登记到现有SwiftPM测试target并按第7节使用 `swift test --filter StreamingTtsCapabilitiesTests`；实际App构建另走授权包装脚本，不调用包含UI的默认测试脚本。

## W11. 声学、性能、逐档放行与发布回滚

**前提：** 明确真实模型/性能验收授权；读取本机环境手册与speechrail-perf-benchmark。安装发布另读speechrail-release/local-deploy。不把本文当作这些操作的许可。

- 在同一规范参考与文本集下对照旧基线、新完整文本、新真增量；控制模型/量化/seed/采样/响度，分别改变变量。旧版不与新版服务同时运行。
- 每档至少覆盖短响应、长句、多句、数字单位、问句、中英混读；同文本重复，变更到达节奏。建议首轮≥30个测试条件并重复3次；报告样本数，P95不是单次观测。
- 输出全档pass/fail/not_run与原因；extreme未通过不标为正式实时档。light与balanced可共享TTS声学探针，但ASR到播放端到端与资源分别测。
- 记录首包/可听首音/RTF/欠载/取消/回收/内存趋势；不以mx allocator cached memory不归零单独认定泄漏，也不以活跃对象为零就认定内存安全。
- 新release保留旧主服务+vendor runtime+配置+selection+voice数据，失败整体回滚。客户端发现能力缺失禁用新模式，不向旧服务发新事件；没有授权不安装、不push fork、不创建发布。

**完成条件：** 第8节清单有实际证据；性能不达标则保留未完成项，不以降低阈值宣称全目标达成。

# 6. 关键实现说明

## 6.1 拟新增内部接口与唯一状态

```python
# 拟新增 domain/tts_stream.py；vendor-neutral，不导入 MLX。
@dataclass(frozen=True)
class TtsStreamOptions:
    request_id: str
    response_id: str
    voice: str
    expected_voice_revision: str | None
    expected_model_revision: str | None
    language: str
    speed: float

class IncrementalSpeechSession(Protocol):
    async def append_text(self, sequence: int, text: str) -> None: ...
    async def finish_text(self, last_sequence: int) -> None: ...
    def events(self) -> AsyncIterator[TtsStreamEvent]: ...
    async def cancel(self) -> None: ...
    async def close(self) -> None: ...

class IncrementalSpeechSynthesizer(Protocol):
    async def open_stream(self, options: TtsStreamOptions) -> IncrementalSpeechSession: ...
```

`TtsStreamEvent`拟定kind=started/text_accepted/audio/completed/cancelled/failed，audio拥有PCM、chunk_index、sample_offset；输入状态OPEN/CLOSED，输出状态STARTING/RUNNING/DRAINING/TERMINAL，终态唯一。状态类型只在domain定义，wire parser负责投影，不复制业务枚举。

append成功表示已被有界队列接纳；该文本不再可编辑，不表示已发声。ACK失败不推进accepted_sequence。初始化accepted_sequence=-1，首包sequence=0；finish.last_sequence必须等于最后ACK，空输入为-1。重复append、序号间隙、finish后append拒绝；finish重复返回错误而不重复flush。内部close幂等，公共cancel遵循当前匹配活动请求语义。

Base继续复用validate_tts_parameters的speed/instruction/seed限制，不因新流式端点绕过限制。首版不开放任意instruct/seed或客户端GPU预算。

## 6.2 拟新增wire固定形状

```json
{"type":"speechrail.tts.start","request_id":"r1","voice":"serena","speed":1.0}
{"type":"speechrail.tts.started","request_id":"r1","response_id":"resp_1","limits":{"max_append_chars":512,"max_total_chars":4096}}
{"type":"speechrail.tts.append_text","request_id":"r1","response_id":"resp_1","sequence":0,"text":"你好。"}
{"type":"speechrail.tts.text_accepted","request_id":"r1","response_id":"resp_1","sequence":0,"accepted_chars":3}
{"type":"speechrail.tts.finish_text","request_id":"r1","response_id":"resp_1","last_sequence":0}
{"type":"speechrail.tts.cancel","request_id":"r1","response_id":"resp_1"}
```

示例finish与cancel是不同操作示例，不要求顺序全部发送。start允许expected_voice_revision/expected_model_revision，未提供时由服务端冻结并在started返回实际revision；model/language从协商会话取值，禁止同时出现矛盾来源。

成功start先发当前`response.created`，再发namespaced started（已取得lease且worker接受后）；客户端等started才append。失败发生在创建response之前只发error，不伪造done；response已创建后任何失败都发一次failed终态。PCM在started之后才能发出。

PCM继续使用`response.output_audio.delta`，在`speechrail`扩展对象内带`chunk_index`、`sample_offset`；mono PCM16/24000不变，`sample_offset += len(pcm)//2`。不得增加第二条音频事件使客户端双播。完成按现行output_audio.done/response.done顺序，cancel/failed不声称正常flush完成。

拟新增稳定错误码集中注册：`tts_streaming_unsupported`、`tts_sequence_invalid`、`tts_input_closed`、`tts_input_timeout`、`tts_stream_limit_exceeded`、`tts_backpressure`；身份、未ready、busy和invalid参数复用已有语义。可恢复的错序/错字段不消费输入；超限/超时/慢消费者终止当前response，客户端不得无限重试。

总字符计数按收到的Unicode codepoints，包含空格；不得每次strip导致单词黏连。纯空白包也计入限额，未产生可朗读内容时不强制模型发声；finish空内容完成零音频，仍有唯一终态。

## 6.3 步进与取消伪代码

```text
controller start -> reserve lane + lease immutable voice + open worker stream
reader: parse command -> bounded queue; cancel sets priority flag
model owner loop:
    if cancelled/deadline: close model state; terminal once; break
    apply accepted commands in sequence (bounded work per iteration)
    if no text ready and not input_closed: wait with input deadline
    else: adapter.step(bounded_steps)
    enqueue new PCM within byte budget; slow writer timeout -> fail
writer: send frames in order; surface broken pipe to owner; never owns model state
finally: stop/join I/O -> confirm model state released -> release leases
```

网络append、模型消费、音频生产独立推进，但只有一个模型owner。cancel不能排在满音频队列后；在不可抢占的MLX操作期间只能等待有限步，超期由精确子进程abort兜底。

## 6.4 Capability与缓存的单一事实来源

拟新增每voice的 `incremental_tts` 描述：`supported`（实现与制品支持）、`available`（当前profile/preflight/readiness/预算允许）、`validation`（unverified/passed/failed）、`reason`（稳定低基数码）。release验收记录必须绑定model/runtime/generation revision；更换后不得沿用旧pass。shared模型级字段只表示存在可用路径，最终start再查该voice。

Reference cache最大条目/字节由probe测量与预算给出；缺证据不能硬编码“可同时常驻”。按模型revision独立namespace；磁盘reference文件lease保持到worker完成或abort/reap。撤销后禁止新请求，已开始请求按冻结快照结束或现有显式取消策略处理，不让文件被提前删掉。

## 6.5 当前完整文本、时序与持久化边界

保留REST和create完整文本功能，不把所有调用迁移到stateful。原planner用于完整文本；新stream不能使用bounded_sentences重启模型。不同代generation profile输出不要求PCM bitwise相同。

新stream的timing首版只承诺真实音频sample offset，不猜字/句对齐；render receipt仅摘要。PCM不落库，voice/reference路径不进入wire。无数据库迁移需求，不顺手改变App会话SQLite结构、会议记录或长期聊天数据。

## 6.6 App 新协调器接口与测试边界（拟新增）

`AssistantTTSStreamCoordinator` 使用 `@MainActor`，依赖可注入的发送/播放协议，不直接构造URLSession、LLMProvider或AVAudioEngine：

- `begin(generation:voiceRevision:modelRevision:)`：绑定AssistantSession已有replyGeneration；第一次有可朗读内容再发start。
- `appendStableText(_:generation:)`：按unicodeScalars计数，缓冲受限，串行推进sequence；ACK前不承诺服务已消费。
- `finishInput(generation:)`：等待本地已接受文本的ACK后发finish，禁止重复发。
- `handleServerEvent(_:)`：带requestID/responseID/sequence/sampleOffset的typed事件；不匹配当前generation的事件不改变状态。
- `playbackDrained(generation:)`：仅当同代terminal且队列空才能结束整轮；未完成则标记temporaryUnderrun。
- `cancel(generation:)`：先失效generation/唤醒预算等待/停播，再尽力发服务端cancel，取消失败不能恢复旧generation。

`AssistantSession` 继续负责原始LLM流、history和文本记录；coordinator只管理语音路径。`RealtimeASRClient`把共享receive loop解析出的音频及控制事件交给coordinator，ASR事件继续原路分派。将等待started/ACK的continuation按request身份存储，terminal、断线和cancel要全部resume，避免遗留挂起任务；只允许resume一次。

`AssistantPlaybackLedger` 仅记录generation、queuedSamples、input/server终态和drain，不持有AVAudioBuffer；真实播放器调度与完成时调用ledger。测试使用fake播放器记录enqueue/stop/complete顺序，不启动音频设备。`AssistantSpeechTextBuffer`接收注入clock/手动tick，测试不实际sleep150ms。

新测试重点覆盖coordinator与真实DTO/decoder。由于现有SwiftPM未包含AssistantSession与音频实现，不能以这些纯测试宣称App硬件链路通过；授权包装构建验证接线，实际播放/打断需另有真机授权与测量证据。

# 7. 测试方案

## 7.1 确定性测试表

| 测试文件 | 必须覆盖 |
|---|---|
| `tests/test_realtime_openai.py` | 删除audioop依赖后仍固定16k输入；EOF/奇数字节/旧字段拒绝 |
| `tests/test_runtime_bootstrap.py` | 3.14版本校验、hash失配、ASR/TTS合并锁、准备失败原current不变 |
| `tests/test_installer.py`、`test_service_preflight.py` | 主服务/vendor版本一致，真实探针字符串版本来源统一，fake安装不启服务 |
| `tests/test_runtime_lock_generation.py`（新增） | 续行解析、排序稳定、hash精确、check不写、未知依赖拒绝 |
| `tests/test_tts_stream_state.py`（新增） | 输入/输出正交状态、重复/间隙序号、空finish、超限、cancel竞态 |
| `tests/test_tts_reference_condition.py`、`test_tts_profile_snapshot.py` | identity/revision隔离、撤销/文件租约、未知vendor不假报支持 |
| `tests/test_tts_stream_worker.py`（新增） | 首PCM后append、读写全双工、单reader、slow writer、cancel及abort后恢复 |
| `tests/test_worker_process.py`、`test_worker_protocol.py` | 原ASR/完整TTS帧兼容、长度限制、broken pipe、无读锁死锁 |
| `tests/test_tts_stream_application.py`（新增） | resource/profile租约最终释放、terminal一次、receipt发送口径 |
| `tests/test_resource_governor.py`、capability router测试 | 跨lane准入、输入饥饿占槽期限、活跃session禁止evict、bf16预算缺失fail-closed |
| `tests/test_realtime_tts_incremental.py`（新增） | wire先后、started前append、create/start互斥、未协商、不支持voice、断连释放 |
| `tests/test_tts_voices_api.py`、`test_model_presets.py` | 四档支持矩阵、模型级/voice级区分、clone在低档不可用 |
| Swift `RealtimeContractTests.swift`、新增 `RealtimeTTSStreamTests.swift` | current wire DTO与服务器fixture一致，取消/旧response隔离，ASR事件不被抢读 |
| 新增 `AssistantTTSStreamCoordinatorTests.swift` | 同轮一个start/finish、LLM未完首音已到、错误/断线/stop状态收束 |
| 新增 `AssistantSpeechTextBufferTests.swift` | 150ms fake clock、跨delta数字/英文/Markdown、Unicode scalar限额与空白保持 |
| 新增 `AssistantPlaybackLedgerTests.swift` | 有界queuedSamples、取消唤醒、迟到completion不污染新generation、暂时drained不是terminal |
| Swift `LLMProviderTests.swift`及App包装构建 | SDK/文本链路保持、AssistantSession真实接线编译；不冒称真实音频或UI已验收 |

所有普通测试使用fake和合成PCM，不加载权重、不联网、不读真实音频。模型探针的fake通过只证明探针流程，必须标注没有声学证明。

## 7.2 命令与执行位置（计划，未执行）

以下使用可移植原生命令。进入对应仓库运行；准备解释器/依赖需实施授权，完整测试需用户明确授权，不因在计划里出现就执行。

SpeechRail：

```bash
# 完成候选锁后；会安装依赖，仅在授权实施时执行。
uv sync --locked --python 3.14.7 --extra dev
# W1/W2 最小回归
uv run --no-sync pytest --no-cov tests/test_realtime_openai.py tests/test_runtime_bootstrap.py tests/test_installer.py tests/test_service_preflight.py
# 新模块创建后才可运行
uv run --no-sync pytest --no-cov tests/test_runtime_lock_generation.py tests/test_tts_stream_state.py tests/test_tts_stream_worker.py tests/test_tts_stream_application.py tests/test_realtime_tts_incremental.py
# 既有协议/资源/音色回归
uv run --no-sync pytest --no-cov tests/test_realtime_caller_wire.py tests/test_worker_protocol.py tests/test_worker_process.py tests/test_resource_governor.py tests/test_tts_reference_condition.py tests/test_tts_profile_snapshot.py tests/test_model_presets.py
uv run --no-sync ruff check src tests tools/update_runtime_lock.py tools/probe_tts_incremental.py
uv run --no-sync mypy src
# 拟新增工具创建后：元数据由实际锁生成，不伪造hash。
uv run --no-sync python tools/update_runtime_lock.py --check
# 授权完整套件后（包含项目覆盖率门）
uv run --no-sync pytest
```

`--no-cov`仅用于局部回归避免全项目80%覆盖率对单文件测试产生误导；最终完整gate不移除覆盖率要求。不忽略失败或修改阈值使结果变绿。

SpeechRail App（仓库根目录，纯 SwiftPM 单元测试）：

```bash
# 已有测试；不生成/启动 .app，不接管窗口或音频设备。
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests
swift test --package-path macos/SpeechRailApp --filter LLMProviderTests
# 仅在新增文件已实现并登记进 Package.swift 后
swift test --package-path macos/SpeechRailApp --filter AssistantTTSStreamCoordinatorTests
swift test --package-path macos/SpeechRailApp --filter AssistantSpeechTextBufferTests
swift test --package-path macos/SpeechRailApp --filter AssistantPlaybackLedgerTests
swift test --package-path macos/SpeechRailApp --filter RealtimeTTSStreamTests
```

如需解析缺失Swift依赖，先核对执行授权与Package.resolved；测试本身不得启用真实音频/LLM网络。完整Swift套件按完整验收授权执行。实际App编译仅用 `scripts/macos_app_build.sh` 已核实参数，执行前读取release skill，避免额外安装副本；本指南不执行构建。

**禁止将 `scripts/macos_app_test.sh --unit-only` 当成可用命令。** 当前脚本不转发筛选参数，默认test plan包含UI测试。此任务不需要为了测试新纯状态机而修改/运行它；若未来必须使用Xcode测试，由执行者先实现并验证明确非UI入口（保留制品清理），任何接管前台的行为仍需当前用户单独授权。

真实探针CLI（拟新增，W4实现后可用）：`python tools/probe_tts_incremental.py --help`。必须要求显式 `--model-dir`、`--variant custom_voice|base`、`--output-dir`（仓库外）、`--schedule`、`--reference-audio/--reference-text-file`（仅Base）；拒绝不存在模型、远程URL、仓库内音频输出，不自动下载。具体执行值来自授权环境，本文不填真实私有路径；未经许可不运行。安装/服务切换只引用现有专项skill，不编造一键生产升级命令。

执行Swift筛选测试时必须确认实际执行用例数大于零；“filter未匹配、执行零测试”的退出码不算通过。新文件需同时登记到真实App编译与SwiftPM纯测试闭包，不能只添加文件而未纳入target。

## 7.3 真模型与性能矩阵

每份报告绑定Python/vendor/model/quantization/voice/generation profile revision和采样参数；分开cold/warm，记录P50/P95与样本数。固定规范参考、相同输入文本、匹配响度，比较完整文本与增量，不能只比同文本hash。

- CustomVoice q8：light/balanced共享声学基础结果；各档ASR到播放、资源独立测。
- Base q8：quality角色身份、跨句连续、参考缓存复用与取消。
- Base bf16：extreme独立上述全部；q8结果不能标记bf16已通过。
- VoiceDesign q8/bf16：参考创建、试听和普通合成回归，不要求新增量模式。
- 中英混合不代表所有语种已验收；仅声明实际覆盖语言。

# 8. 验收标准

## 8.1 工程与行为

- [ ] 新代码无audioop导入，当前16k wire不变；未引入无必要旧采样兼容。
- [ ] Python3.14主服务、vendor、MCP候选导入及相关回归有证据，锁/hash可复现。
- [ ] CustomVoice和Base在首音后仍接受文本；不是多次generate拼接。
- [ ] 协议字段、状态、错误码、能力和revision有唯一来源；App保持current wire且新增流式事件与服务端一致。
- [ ] 一轮一次start/finish；空文本、晚追加、重复序号、断线和取消都不产生幽灵声音。
- [ ] 终态一次，资源/profile/cache租约释放，现有ASR/REST/创建音色未回归。
- [ ] 每档支持矩阵有pass/fail/not_run，extreme候选状态不会被解释器升级自动解除。
- [ ] 未覆盖/删除/迁移用户音色与并行改动，未产生敏感日志。
- [ ] 所有新增任务的验证命令、时间、结果、未执行项写入交付报告。

## 8.2 初始性能目标（待实际验收，不是当前成绩）

- [ ] 温态首批可提交文本→客户端首个可播放PCM P95≤500ms，另报实际首播。
- [ ] 小窗口额外等待探索100–200ms，初始150ms；未等整轮文本。
- [ ] 排除输入饥饿后的生成RTF<1，争取≤0.7；另报真实播放欠载。
- [ ] 用户打断→本地停旧音P95≤100ms；cancel→模型活动状态释放P95≤500ms。
- [ ] 跨文本身份/可懂度不明显劣于对应固定身份完整文本基线，主观盲听与文本正确性分别记录。
- [ ] 重复create/finish/cancel/失败循环无持续增长的活跃状态，缓存驻留与泄漏分开分析。

达不到则保留未完成，不自动降标准。整体延迟分解为VAD、ASR、LLM可朗读首段、TTS与播放，不以TTS单点替代端到端。

# 9. 风险与注意事项

1. **模型可行性仍未证明。** 真增量需要条件对齐、EOS和decoder协同，不是把KV封装成对象。W4失败是合法停止条件，不允许伪造实现。
2. **App并行写入冲突。** VoicePrompt、SurfaceHeaderView及VoicePromptTests已有修改；计划不授权覆盖。新缓冲/协调器独立成文件，仅在确有必要时协调既有文件的可分离写集。
3. **协议升级。** 新增扩展不放宽旧事件拒绝矩阵；App完整文本current wire保持不变，新模式显式协商。断线不重连续传，避免重复朗读。
4. **性能。** bf16不天然优于q8，light/balanced模型相同也不保证相同端到端表现。不能复制权重进程换吞吐。
5. **runtime供应链。** 共享ASR/TTS依赖需要合并验证；fork wheel必须固定来源、版本与hash，正式发布需独立授权。CI或pip成功不足以证明Metal推理兼容。
6. **回滚与数据。** 完整旧release保留；不自动覆写voice revision或reference。若新增持久字段影响旧版读取，必须先给可逆/旁路存储设计，未完成前禁止部署。
7. **平台范围。** SpeechRail macOS26 arm64；不新增旧macOS/Intel分支。已废弃客户端及其解释器、数据库和第三方交互框架均不在本任务范围。
8. **文档边界。** 同步实质变化的当前契约与active专业文档；根README不因本任务自动重写，archive不改成当前承诺。
9. **验证权限。** 真实模型/基准/服务操作/UI各遵循现行授权。读取本机手册只在这些环境任务真正开始时触发，本指南不虚构本机资源数值。
10. **设计范围校正。** 用户明确原生App是唯一目标客户端，旧客户端协议不再是前置缺陷。实际前置工作是audioop清理、App逐句生成改造、response/generation隔离与安全纯测试入口；已同步修订设计文档，不改变分档与低延迟目标。

# 10. Luna 执行清单

- [x] **W0｜单仓只读基线与写集归属**：基线 `25d4416f`；分支 `codex/tiered-streaming-tts-python314`；README/用户文档及三处 macOS 工作区改动均保留，阶段写集与其不重叠。
- [x] **W1｜Realtime导入与采样契约**：移除不可达 `audioop`/24→16 kHz converter 与影子 sample-rate 配置；保留固定 16 kHz PCM16 wire。验收：`tests/test_realtime_openai.py` + `tests/test_realtime_caller_wire.py` 137 passed；定向 Ruff、mypy 及 diff check 通过。当前运行解释器是 3.12.14；缺失 audioop 导入由测试注入模拟，尚未证明 CPython 3.14 全依赖运行。
- [x] **W2｜统一Python/runtime锁**：项目目标与 runtime lock 统一为 CPython 3.14；bootstrap/installer/CI 与锁工具一致；合并依赖、hash、失败保留 current 测试通过。候选运行时验收见下方 W2 记录。
- [ ] **W3｜App协议与测试基线**：保持当前wire，建立传输/解析seam与response关联；SwiftPM纯测试可运行。
- [ ] **W4｜模型门**：分别提交CustomVoice q8、Base q8/bf16探针与vendor制品身份；真增量不成立则停止下游并报告。
- [ ] **W5｜领域与身份**：新增tts_stream port/state/limits；profile与reference租约、跨精度cache隔离通过。
- [ ] **W6｜worker全双工**：单模型owner、单父端reader、有界队列与协作取消；fake IPC与旧ASR/TTS回归通过。
- [ ] **W7｜应用资源与终态**：governor/profile/worker全生命周期收束；cancel/finish竞态及receipt口径通过。
- [ ] **W8｜公共协议与能力**：严格parser、current音频事件、voice级支持；四档/错误/断线矩阵通过。
- [ ] **W9｜App单轮文本流与播放取消**：AssistantSession接协调器、buffer和playback ledger；单start/finish、旧包隔离和drain状态fake测试通过。
- [ ] **W10｜分档展示与切换**：不支持声音明确阻止，活跃utterance不热切；Mac非UI能力映射与profile测试通过。
- [ ] **W11｜授权后逐档实测与发布**：质量/性能矩阵与完整回滚记录；未达标档不宣称完成；安装/提交/远端发布分别核对授权。

### W2 实施与验收记录（2026-09-24）

- 在仓库外建立 CPython `3.14.7` 候选开发环境和独立 MLX runtime 环境；按 ASR/TTS 带 hash 的 role lock 合并同步，`--only-binary :all:` 安装 47 个包。未下载或加载模型权重。
- MLX 模块导入 smoke 通过：`mlx==0.32.2`、`mlx-audio==0.5.6`、`mlx-qwen3-asr==0.3.5`。
- `uv lock --check --python 3.14.7`、`tools/update_runtime_lock.py --python 3.14.7 --id mlx-qwen-20260924-py314 --check`、zero-setup Bash/Python 语法检查通过。
- Python 3.14.7 候选环境回归：`352 passed`；`ruff check src tests tools/update_runtime_lock.py` 通过；`mypy src` 对 130 个源文件通过。测试输出有一个既有 Pydantic `mappingproxy` serializer warning，未将其误记为失败或静默屏蔽。
- **Ruling：** `requirements/shared.txt` 仅记录 ASR/TTS 锁的交集，用于 runtime 元数据与 hash 校验；它不是安装输入。当前 ASR/TTS 共用一个 Python 环境，bootstrap 对两个 role lock 在同一次 `uv pip sync` 中合并安装，因此 ASR-only/TTS-only 依赖仍会保留；交集清单不会减少实际安装包数。若要按 role 隔离依赖，需另行拆分运行环境，不属于 W2。
- **未验收：** 未在正式 app home 执行安装/切换；未加载模型，未验证 Metal 推理、真实音色、增量生成、延迟或任何档位的质量/性能。

交接报告必须区分“已改代码”“确定性已通过”“真实模型已通过”“逐档性能已通过”“尚未授权/尚未执行”。不要用一项总完成勾选掩盖模型门、App并行改动或extreme未验收。
