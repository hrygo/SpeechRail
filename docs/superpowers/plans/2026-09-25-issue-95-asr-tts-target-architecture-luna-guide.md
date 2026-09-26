---
title: "Issue #95：ASR/TTS 目标架构 Luna 实施方案"
status: proposed
audience: "Luna、核心开发者、评审与验收人员"
version: "1.0"
date: 2026-09-25
---

# 1. 问题结论

> **实施状态（2026-09-26 追加）**：本方案已实施，执行与证据记录在
> [Issue #95 交付认证与证据索引](../../developers/issue-95-certification.md)（含 §1.1 的 P0–P5 逐门状态）：
> P0–P4 有可复核证据；P5 因公开语料数字 / 单位门（90%）、≥2h soak 两门与人工听审未完成而保持未勾选。
> 本文件保留为原始实施方案，§8.2 与 §10 的勾选框不再单独维护，以认证文档为准。

## 1.1 任务与交付边界

**目标**：落实 Issue #95 已接受的三档解耦、设计专用、当前协议与无历史兼容架构，不把现有 PR94 工程推倒重写。

**规格依据**：`docs/architecture/2026-09-25-asr-tts-target-architecture-no-legacy.md`（accepted）。该文档冻结产品方向；本方案补齐当前源码差距、实现决策、依赖顺序、测试与证据门。以下“拟新增”类型、字段、路径与协议细节是本方案提出的实现约定，不是当前已存在的能力。

**技术栈**：Python `>=3.14,<3.15`、uv、Pydantic、FastAPI、受控 MLX worker、SwiftUI/AppKit、Apple Silicon macOS 26+；保留单本地服务、单 ASGI worker。不在方案阶段升级 SDK、修改版本锁或安装任何制品。

**执行方式**：未来获准实施后，由执行者按任务逐项执行 `executing-plans`；不得因“Luna”一词启动子代理或切换模型。每个任务先补失败回归、再实现、再定向验证。提交、推送、真实模型操作、构建安装及 UI 自动化均按当次授权处理。

本轮授权仅为分析与方案落盘。没有修改业务代码、现行契约、运行配置或 GitHub 状态，没有跑产品测试、下载模型、安装、切档、构建 App 或接管 UI。

## 1.2 证据基线与状态纠正

- 核实日期：**2026-09-25，Asia/Shanghai**；源码取样与方案分析约 16:19–16:37。
- 工作区：`main`；分析基线 `3c2003c7cadbc02dfee75a787af7ea5f46018904`；分析开始与写入前均无已有工作区改动。
- GitHub Issue #95：open，读取时无评论；#82、#83、#85 均 open。
- **PR #94 已于 2026-09-25 14:08:08 +08:00 合并**，merge commit `c0a439560192b18ed26f028675889a878362ec93`。PR 正文及架构文档中“保持 Draft、继续追加 PR94”的记录已经过时，不能作为执行指令。后续应从实施时核实的新基线开展，不更新已合并 PR、不将本总单自动关闭。
- 当前分支已经包含后续 soak、App 构建记录和提词器改动；本轮没有重跑，不继承为新目标通过证据，也不覆盖这些改动。
- 未提供 Codebase Memory MCP，使用有范围的文件检索、符号定位和源码读取。**这不是全库审计**，不声称图谱覆盖或所有调用点已穷尽。
- 已访问 OpenAI 官方 Realtime transcription 指南；网页工具未返回正文，转用只读 HTTP 获取并提取结构。确认示例使用 `session.update`、`session.type=transcription`、`audio.input.format={type:audio/pcm,rate:24000}`，保留 `input_audio_buffer.append/commit` 和转写 delta/completed。官方页面模型特有限制不自动成为本地 Qwen 能力。本轮没有向 OpenAI 发送音频或调用推理 API。

源码、契约与测试是“当前实现证据”；accepted 文档和本方案是“目标”；PR 中的性能数字是“历史记录”；真实 dtype、音质、并发与长稳仍需后续认证。

## 1.3 总体判断

#95 是跨契约、配置、模型 owner、音色资产、App 和供应链的实施总单。建议按 **P0–P5、12 个可独立评审任务**推进，而非一次大改后统一验收。

可立即开展不依赖模型的类型、解析器、fake 回归和指标修复。缺失制品 revision/hash、受控引擎 wheel、真实组合峰值与质量证据是后续明确的门槛，不能填占位 hash、猜测能力或用旧测试结果绕过。

# 2. 当前实现与根因

## 2.1 文件级差距表

| 范围 | 当前源码事实 | 根因及处理 |
|---|---|---|
| 规格绑定 | `config/model_catalog.py::PresetId` 与 `service/profile_store.py::SelectionRecord.preset` 为 extreme/quality/balanced/light；`config/selection.py::active_model_catalog` 按目录及 preset 配对判定 clone/diarization | preset 同时承担资源规格、声音角色和辅助能力；改为独立 ASR/TTS 选择与任务输出选项，保留 selection 原子事务而非旧字段 |
| 制品 | `assets/model-catalog.json` 实际 **10 项**：3 ASR、3 运行 TTS、2 Design、2 aligner | 目标是 12 项：去掉 `tts-1.7b-design-q8`，新增 0.6B Base Q8、1.7B CustomVoice Q8/BF16；不是“删除现有 Q4” |
| dtype | `backends/qwen3_worker.py::Qwen3Engine.__init__` 调用 `Session(model=str(model_dir))`，未传 dtype；CLI dtype choices 只有 float16/float32/int8 | 配置请求与实际加载缺乏闭环。不能据 BF16 目录名判定运行身份；loader、非量化张量与 worker 握手需要同一身份验证 |
| ASR 参数 | `Qwen3Engine.open_session` 将 left context 与 right-context 合成 `max_context_sec`；默认 chunk_sec=2.0 | 现有旋钮不能表示独立右上下文算法。收敛到引擎真实支持的 chunk/context 参数，不保留伪 causal/windowed 语义 |
| ASR final | `_handle_commit` 先 finish_streaming，再按 want_segments 调 `align_session_audio`，最后发 completed | 用户 final 延迟耦合对齐耗时/失败；改为文本唯一 final，辅助结果异步附加 |
| Alignment owner | `application/services.py` 装配 `FixedTextAligner(asr_worker)`；`qwen3_worker.py` 内维护 `_forced_aligner` 与 `_align_buffers` | 应用适配器已有独立接口，但模型 owner 仍在 ASR 内；复用 `validate_alignment`，直接拆出真正独立 owner |
| TTS 角色 | `Qwen3TtsCapabilityRouter` 以 primary/clone 组织；quality preset primary 为 Design Q8，reference 对应旧 extreme Design BF16 | 应改为按 `TaskRequest + voice revision` 选唯一角色；普通内置声音 CustomVoice、自定义声音 Base，Design 不参与日常路由 |
| 注册门 | `http/routes/voice_designs.py::register_design` 生成参考、声学检查、ASR transcript match 后调用 `create_cloned_profile`；该路径未在发布前用 Base 合成新文本 | “参考可用”不等于“Base 可复现身份”；增加候选确认与 Base 新文本复验，保留已有幂等 journal/发布锁 |
| Realtime | `compatibility/openai_realtime.py` 接受 `transcription_session.update`、平铺 input_audio_format；ASR 固定 16k；Swift `RealtimeASRClient.sampleRate=16000` | 当前 wire 与目标语义不同；边界切换到当前 session/audio 结构，wire 24k 与内核 16k 解耦 |
| 能力 | `application/capability_snapshot.py::build_capability_snapshot` 是纯快照组装，依赖 active.profile/tts/tts_clone；支持状态与 runtime 状态已有部分结构 | 复用纯函数、ETag、音色质量信息；从 plan/manifest/认证事实补齐 ASR 操作矩阵，不再按档推断辅助支持 |
| 资源 | `ResourceGovernor` 已有 bounded queue、reserve、keyed TTS lanes；`model_budget.py::ComponentFootprint` 仍以 ASR/TTS/diarization 汇总 | 保留调度与租约语义，换为唯一模型 owner 的 resident + incremental peak；不能只看连接双向就宣称并发 |
| 打断 | `AssistantTTSStreamCoordinator.cancel` 已 invalidate generation；`stopPlaybackNow` 通过未等待 Task 调用 stop，再执行 sendCancel | 已有旧包隔离可复用，但异步安排停播不等于停播 barrier 已先完成；加入可测试的停止确认与终态隔离 |
| 基准 | `examples/perf/bench_tts_streaming.py` submitted_at 在 start 前；收发同循环并 sleep；每轮可能被音频事件推进下一片；recv 后才检查 deadline；RTF 扣 gap；headroom 使用新包到达后累计值 | 实测口径可能偏差，先修 harness、保留旧报告并标口径差异，之后重测 |
| 引擎交付 | `service/bootstrap.py` 的 `_vendor_overlay_entries`、overlay 目标校验与 lock 的 vendor_overlays 实际参与安装验证 | 当前可追踪 overlay 是阶段工程，不是目标交付；用固定上游源码+最小补丁构建唯一引擎 wheel |

表内路径未写前缀的 Python 文件均相对 `src/speechrail/`。

## 2.2 必须复用的实现

- `domain/tts_stream.py::TtsStreamStateMachine`：输入/输出状态、sequence、pending byte/codepoint 限制、唯一终态。
- `application/tts_stream.py::StreamController`：`_claim/_settle/_shutdown`、deadline、receipt、取消和释放顺序。
- `backends/qwen3_tts_stream_client.py`、`qwen3_tts_stream_host.py`、`qwen3_tts_incremental.py`：单 owner、有界通信、协作取消、旧 request 隔离；按新 plan 补身份，不另造第二套状态机。
- `domain/tts_reference_condition.py::PreparedReferenceKey` 已含内容身份、预处理、模型 revision、quantization、tokenizer 和 implementation version。优先补齐缺失身份，不替换成更弱的 voice_id 缓存。
- `runtime/asr_mode.py`、`worker_lease.py`、`resource_governor.py`：同 owner batch/stream 互斥、活跃租约和释放语义。
- `application/diarization/alignment.py::validate_alignment` 及 `domain/diarization/*`：固定文本、codepoint span、sample timeline、版本化归属；独立对齐类型可从原目录迁出，但不留下双定义。
- `AssistantPlaybackLedger`、`AssistantTTSStreamCoordinator`：ACK 与播放账本分离、generation 隔离，定向修正而非重写。

## 2.3 深层原因

“profile”成为跨层隐含事实来源：决定模型、声音类型、aligner、分人和资源预算；协议对象又与应用编排相混合。即使单点测试通过，也不能证明公开能力、实际 worker 和计时口径一致。解决核心是 **一次解析、冻结计划、角色唯一 owner、边界映射、证据绑定**，不是重新命名四个档位。

# 3. 目标行为

## 3.1 唯一规格与角色矩阵

| spec | ASR | voice=内置 speaker | voice=固定自定义 revision |
|---|---|---|---|
| fast | 0.6B Q8 | 0.6B CustomVoice Q8 | 0.6B Base Q8 |
| quality（默认） | 1.7B Q8 | 1.7B CustomVoice Q8 | 1.7B Base Q8 |
| reference | 1.7B BF16 | 1.7B CustomVoice BF16 | 1.7B Base BF16 |

- ASR/TTS 两项独立保存；组合快捷选项不持久化第三份 preset。
- auto 为显式策略，默认禁用。先满足能力，再在认证集合内选资源；不改声音、丢指令或中途换模型。未有认证证据时明确不可用，不假装自动工作。
- VAD、Alignment、Diarization 按任务 opt-in，不随规格绑定。Design 仅 1.7B BF16、仅设计作业。
- 首批组合认证是三种同档组合和 `ASR quality + TTS fast`；每个组合分别记录所用 TTS 角色，Base 通过不代表 CustomVoice 通过。
- 运行 catalog 禁止 Q4/Q6/Design Q8；不删除用户本地历史文件，也不提供旧名称映射。

## 3.2 输出与状态不变量

1. 一次 task 绑定不可变 plan、engine/artifact revision、voice revision、selection generation。
2. 一个 ASR utterance 一次 text final；alignment/diarization done/failed 不改写 final。
3. hypothesis 可修订，带递增 revision；只有已稳定前缀可映射为官方 append-only delta。无法证明稳定时只发扩展 snapshot，最终发 completed。
4. ASR 内核 16k mono；官方兼容 PCM wire 24k mono PCM16 little-endian；输入转换维护有状态重采样和整数采样时间轴。
5. sequence 初值 0，连续递增；ACK 仅表示接受；finish 固定最后已接受序号并排空；cancel 优先，唯一 terminal，清理幂等。
6. supported/unsupported/unknown 与 installed/ready/busy 分开；未认证能力、未知预算不得宣称实时并发。
7. 发现只读、不启 worker、不联网；推理不下载、不读取远程音频 URL、不回退模型/云端。
8. 打断先使旧 epoch 无效并完成本地停播屏障，再发后端取消；后端错误不恢复旧播放。

# 4. 推荐解决方案

## 4.1 采用模块化单体与渐进替换

保留既有 HTTP/MCP/App 边界及单服务；在领域层建立规格、任务、执行计划。替换旧装配入口，而不是在 worker 内追加另一个全局 profile reader。允许开发分支分阶段提交，但**不得部署半套新客户端+旧服务，或用双解析器维持混合状态**。

备选比较：

- 仅重命名 profile：改动小但耦合、角色错误和能力失真均保留，拒绝。
- 先抽象框架再全量重写：风险高、取消/缓存回归大，拒绝。
- **推荐：契约先冻结 → 核心计划与供应链基础 → owner/路由定向改造 → 同批协议/App 切换 → 真机认证**。每步有 fake 测试；对外发布只交付闭环的当前路径。

## 4.2 文件职责（拟新增）

| 新文件 | 唯一职责 |
|---|---|
| `src/speechrail/domain/model_spec.py` | SpecTier、ModelRole、ModelSpec、精度/依赖标识；不加载模型 |
| `src/speechrail/domain/task_plan.py` | TaskRequest、ResolvedPlan、PlanModel、格式/辅助输出要求；不可变数据 |
| `src/speechrail/application/plan_resolver.py` | 唯一请求→计划解析与能力匹配；无下载/加载副作用 |
| `src/speechrail/runtime/model_owner.py` | owner key、租约、单实例注册、加载握手/失效；复用 worker_process |
| `src/speechrail/domain/alignment.py` | 固定文本对齐 port 与公共领域类型，从 diarization 解耦 |
| `src/speechrail/backends/qwen3_alignment_worker.py` | 独立 ForcedAligner 进程与加载身份 |
| `src/speechrail/backends/qwen3_alignment.py` | 对齐客户端、有限队列、取消与 worker 生命周期 |
| `src/speechrail/application/alignment.py` | 迁移/复用 FixedTextAligner 与 span 校验，不发起 ASR |
| `src/speechrail/domain/audio_timeline.py` | 整数 sample span、有理数映射与重采样 delay 元数据 |
| `src/speechrail/application/voice_design.py` | 候选→确认→Base 验证→发布作业，HTTP 只做边界 |
| `contracts/realtime-events.schema.json` | 当前 Realtime 与扩展 wire 的机器可验证唯一 schema |
| `tests/fixtures/realtime-current/` | Python/Swift 共用正反例、未知字段与不支持事件用例 |
| `scripts/check_realtime_contract.py` | schema、Python/Swift payload 共用 fixture 校验入口 |
| `tools/build_engine_wheel.py` | 固定上游源码、patch hash、构建锁、wheel hash 和 provenance |

新增单元文件均在第 7 节给出。若实施时发现同职责已有实现，优先扩展已有文件并在执行记录更新映射，不能盲目新建平行实现。

# 5. 详细实施步骤

每项任务均按“失败回归 → 最小实现 → 定向测试 → diff/契约审查”执行；任何提交/运行态动作另受授权约束。

## T01 / P0：锁定当前 wire 与跨端样例

**修改**：`contracts/realtime-openai.md`、`contracts/openapi.yaml`、`docs/users/api-contract.md`、`docs/users/effective-capabilities.md`；新增 schema、共享 fixtures 与检查脚本。

1. 建立公开字段追踪表：字段→validator→TaskRequest→adapter 实际行为→拒绝测试；不存在消费者的参数删除或明确拒绝。
2. 冻结 session.update 嵌套结构、PCM 格式、错误 envelope/request ID、patch 缺省/显式 null 语义。模型 ID 采用 SpeechRail 注册值，不能借用官方云模型名宣称实现。
3. 冻结第 6 节拟议 SpeechRail 扩展。旧 transcription_session.update、平铺输入格式、旧 spec 和假参数作为拒绝样例，不加 alias。
4. Python 与 Swift 读取同一 fixture；不必引入大规模代码生成器，但 schema 与双端编码/解码必须机械校验。
5. 保留 MCP REST 代理边界，只同步其真实工具输入/发现类型，不给 MCP 增加 WebSocket 隧道。

**完成条件**：规范、样例和字段追踪闭合；新正例和旧形状反例均有测试目标。此时仅完成 P0 的契约设计部分，不能因文档变更就勾选整个 P0。

## T02 / P0–P1：核心类型与独立选择

**修改**：`config/model_catalog.py`、`config/selection.py`、`config/profiles.py`、`config/__init__.py`、`service/profile_store.py`、`profile_commands.py`、`profile_switch.py`、`application/services.py`；新增 model_spec/task_plan/plan_resolver。

1. 引入三个 spec 与六个 owner 角色，精度和 artifact 不由规格名字猜测。
2. selection 新 schema（建议 v2）仅保存 asr_spec、tts_spec、auto 策略与 generation；辅助输出在 TaskRequest。旧 selection 报明确错误，给出重新配置说明；**不自动覆写旧文件、不映射 light/balanced/extreme**。
3. 保留 profile_store 的 prepare/activate/rollback journal 与 generation CAS，替换 payload，而非重写事务。CLI 可保留 `profile` 命令组作为操作名称，但只接受新字段；不能继续接受旧 preset 参数。
4. 默认 quality/quality 只用于没有选择记录的新配置；检测到旧记录时不能静默忽略再当首次启动。
5. resolver 先验证 task/语言/voice/能力，再选 artifact 和 owner，输出不可变 plan；REST、Realtime、jobs、Design 都通过同一 resolver。
6. 删除 `active_model_catalog` 的目录名匹配→preset→clone/分人支持推断；目录只是私有定位，身份来自 manifest/preflight/加载握手。

**边界**：plan 中保存资源需求画像及 budget revision；实时 lease 由 admission 在执行时获得，不将过期 lease 持久化。等待过程中 generation 改变则重新解析/拒绝，不把旧计划绑定新 owner。

7. 同步 `service/managed_install.py`、`diarization_assets.py`、`profile_smoke.py` 与安装/首装文档的配置生成逻辑：安装器只准备用户明确请求的制品，不因新默认或新能力矩阵自动下载全部模型；辅助制品供给按任务准备选项而非旧preset。修改代码与fake测试不等于授权执行安装。

**完成条件**：任意 ASR/TTS 选择能无歧义解析；相同输入得到相同计划摘要；未知 voice/revision/旧 selection 明确拒绝；纯 resolver 不启动进程、不联网。

## T03 / P1：12 制品与受控引擎基础

**修改**：`assets/model-catalog.json`、`assets/runtime-lock.json`、`config/model_catalog.py`、`tools/build_model_catalog.py`、`service/model_store.py`、`model_commands.py`、`preflight.py`、`bootstrap.py`；新增 wheel builder 和构建 provenance（拟 `vendor/engine-build/`）。

1. 保留现有 9 个符合目标的条目；删除 active manifest 中的 Design Q8；新增 0.6B Base Q8、1.7B CustomVoice Q8/BF16 共 3 个。12=10−1+3，VAD/CoreML/tokenizer/codec 独立依赖登记，不混入该数量。
2. 每项记录不可变 source revision、完整文件集、size/hash、角色、权重量化/非量化 dtype、engine 能力、语言及 tokenizer/codec 依赖。不填空 hash，不用 floating main。
3. 缺失制品只先定义模型需求和 resolver 失败测试；在获得模型准备授权并验证来源之前，不能伪造生产 catalog 条目。优先可校验的 ModelScope 来源，必要时说明后回到官方源。
4. 读取固定引擎源码确认 ASR Session 的 dtype/aligner 参数；若 API 不支持，采用受控最小补丁和显式 loader，不能写假 kwargs 或调用后再强行标记 dtype。
5. 从固定上游源码及 `vendor/mlx-audio-incremental/` 中必要增量实现制作可审查补丁；版本、源码/patch/build-input hash 与 wheel hash 进入 lock。所有依赖解析仍 hash-pinned。
6. 最终 bootstrap 只安装被锁定 wheel；删除 vendor_overlays 安装/校验路径与 lock schema 字段。测试可用临时 fake wheel，不在当前本机服务里试装。

**依赖/门槛**：供应链基础提前到 P1，不能等 P5 才发现目标 dtype/增量 API 不可构建；P5 负责真实性认证。若制品或上游固定源码拿不到，停在该任务证据门，继续不依赖它的 fake/协议工作。

**完成条件**：manifest 目标角色集合精确；wheel builder 有可重建输入和离线安装验证设计；正式 release 不再使用 overlay。可重建成功只能在真正构建并检查后登记。

## T04 / P1：统一 owner、资源与能力快照

**修改**：`runtime/registry.py`、`worker_process.py`、`worker_lease.py`、`model_budget.py`、`resource_governor.py`、`asr_mode.py`、`application/services.py`、`capability_snapshot.py`、`tts_stream_capability.py`、`http/routes/capabilities.py`；新增 model_owner。

1. owner key 使用模型 artifact identity+engine revision+compute config，不按 voice/request 创建权重副本；两个声音共享 Base owner，只隔离参考条件与 utterance 状态。
2. 未加载/加载中/ready/busy/draining/failed 状态与引用计数明确；并发获取同 key 只启动一次。重启后 ready 必须重新握手，不能沿用旧 generation。
3. 预算采用所有 resident+唯一共享依赖+活动增量 peak+队列/临时工作空间+安全余量；通过 schema 明确各字段是否已包含，防止重复计账。
4. 缺峰值/组合认证时禁止重计算并发。连单任务内存可容纳都无法确认时拒绝，而非无限加载；串行不等于无预算。
5. 保留 ASR batch/stream 互斥、TTS 同 owner 串行、控制消息高优先级、bounded 等待及 batch aging。Design/render 不抢占活跃交互。
6. #82 纳入 capability snapshot：REST 转写、对齐转写、Realtime、jobs 分别给真实输入限制、粒度、语言、输出能力与就绪原因。模型/engine/voice/认证/selection generation 变化使 ETag 失效；busy 不应使“支持能力”枚举变形。

**完成条件**：重复请求不会复制模型；cancel/error/timeout 各路径 lease 恰好释放一次；发现不加载模型；未认证组合不报告全双工。

## T05 / P2：ASR 加载、流式策略与唯一 final

**修改**：`backends/qwen3_worker.py`、`qwen3_streaming.py`、`qwen3_shared.py`、`qwen3_native.py`、`domain/contracts.py`、`application/realtime_openai.py`、`observability/metrics.py`。

1. 先加 Session loader spy：请求 BF16 时必须被正确映射到引擎且加载报告吻合；Q8 snapshot 不再量化；不允许从 BF16 临时量化充当已认证 Q8 制品。
2. CLI/private worker identity 扩展表达权重量化、非量化 dtype、compute config、engine revision、codec identity；删无实际消费的字段和旧 dtype fallback 推断。
3. 采用 task streaming.chunk_duration_ms，候选允许 500/1000/2000；目标默认 1000，实际发布前必须质量/负载验收。真实 max_context 参数按引擎语义命名；删除 causal/windowed 与独立 right-context 假旋钮。
4. `_handle_commit` 只完成识别并发 text final/finished；慢/失败 aligner 不阻塞此路径。空文本也要有确定 final 语义与唯一 item 终态，不能让客户端永久等待。
5. hypothesis revision、稳定前缀与 final 使用一套转写事实；不默认跑第二次 ASR。manual/VAD 每个 utterance 只一个 commit owner，重复 commit/endpoint 不产生双 final。
6. #83：记录 admitted-sample→first-hypothesis、worker partial、socket send 完成；每 turn 最多记录一次。无 partial 直接 final 的 first partial 为 missing，不是 0。可见时刻由 App 记录，服务端不能冒充 UI。

**完成条件**：fake loader/worker 可证明配置生效；迟到对齐/取消不改写 final；批量与流式仍共享同 ASR owner；精度实测仍单列未认证。

## T06 / P2：采样时间轴与独立 Alignment/Diarization

**修改**：`application/diarization/alignment.py`（迁出职责后删除或移除生产引用，不保留 alias）、`diarization/session.py`、`diarization/transcribe.py`、`domain/diarization/types.py`、`runtime/alignment_admission.py`、`runtime/diarization_admission.py`、`application/services.py`、`backends/qwen3_worker.py`；新增第 4 节 alignment/timeline 文件。

1. 先定义统一 sample span：[start,end)，主轴为该 session 原始 wire rate；内部 16k 的映射显式带 source rate、目标 rate、sample origin 与 resampler delay。
2. 有状态重采样按连续输入处理，不逐包重置；计数使用整数/有理数，转换只在边界舍入。取消/新 epoch 清除滤波器状态。
3. 独立 alignment owner 接收 frozen text revision、精确 PCM span 和 language，不执行识别；ASR worker 删除 aligner 实例化、align_text frame 与长期 `_align_buffers` 责任。
4. 音频保留改为有界 ring+短期 pin；辅助任务持有 span lease，完成/失败/cancel 释放。buffer 超限显式错误/分段，不静默丢音；PCM 不写盘。
5. 将当前 `qwen3_worker.py::MAX_PCM_BYTES` 的40MiB保护上限迁入统一limits，不能因抽离owner丢掉已有上限；session/auxiliary队列上限继续取现有验证器与配置，公开capability引用同一值。40MiB不是每角色可各占一份的总预算，所有pin/队列实际内存仍统一计账。
6. 复用 `validate_alignment`，支持 segment 与 word/character。中文按实际对齐器返回的汉字边界、英文按其词边界；不能把模型 phrase 均分伪装 character。无对应粒度证据则 unsupported。
7. Unicode span 是**原始 frozen 文本的 codepoint [start,end)**；不自动正规化后仍沿用原偏移。Swift 通过 unicodeScalars 转 String/UTF-16；组合字符、emoji、重复词和标点有 fixture。
8. 对齐失败发独立状态，不用 [] 成功。Realtime final 仍成功；需要完整时间轴的 job 返回 failed 并可携带已完成 transcript 的结果引用。
9. 分人沿用 CoreML owner 与 session-scoped label；公开四槽上限、unknown/overlap/元数据 revision，不声称能检测第五人。辅助结果验证 task/epoch/utterance/transcript revision，旧结果丢弃。

10. 同步 `contracts/diarization/v1/` 的 schema/fixtures：保留仍正确的匿名归属语义，按当前协议修正session配置、final与辅助结果关联；编号为v1不自动意味着需要维持旧wire，也不为本次更名制造双版本。

**完成条件**：ASR 不加载 aligner；独立重启/失败不污染 final；采样映射长序列无累计漂移；语言交集与能力声明一致；#85 有实际粒度契约而非仅放开参数。

## T07 / P3：TTS 三档六规格与音色 revision

**修改**：`backends/qwen3_tts.py::Qwen3TtsCapabilityRouter`、`qwen3_voice_binding.py::resolve_binding`、`domain/tts_reference_condition.py`、`domain/tts.py`、`application/tts_admission.py`、`tts_stream_capability.py`、`runtime/registry.py`、`application/render_receipts.py`。

1. 路由从 primary/clone 改为 plan role；内置 speaker 只能 CustomVoice；clone/设计发布 revision 只能 Base。Design 仅由 voice_design 任务引用。
2. Base 缺失/voice revision 未验证时明确拒绝，不回退 Design/内置 speaker。0.6B 与 Base 不支持的表达参数拒绝；1.7B CustomVoice 的指令能力也须 engine 实际支持才开启。
3. 一个 voice revision 固定原始参考内容身份、正确文本和创建来源；运行缓存绑定 artifact/engine/precision/tokenizer/codec/preprocessing。已有 PreparedReferenceKey 字段足够时直接复用，codec 未被完整身份覆盖才新增。
4. quality/fast/reference 与 stream/render 支持分别绑定验证记录；验证一个组合不自动证明全部规格。切档后旧缓存不能借用。
5. render 固定 plan+voice revision，不强拆为实时 token 流；有界段落窗口与断点记录引用固定身份，不在数据库持久化 PCM。

**完成条件**：六个运行角色选择的参数化测试通过；voice ID 相同也不能跨 engine/precision 污染；能力与真实路由一致，Design 不进入普通 synthesize/open_stream。

## T08 / P3：设计候选、确认、Base 复验与发布

**修改**：`http/routes/voice_designs.py`、`domain/voice_creation.py`、`domain/voice_validation.py`、`application/voice_validation_gate.py`、`runtime/registry.py`、`mcp/tools.py`、`mcp/models.py`；新增 application/voice_design。

1. 建立候选生命周期：generated → confirmed → validating → publishable → published；cancelled/failed 是失败终态。候选不出现在可用生产 voice 列表。
2. REST 目标资源（拟新增）为 `/v1/voice-designs` 候选创建、`/{id}/confirm`、`/{id}/validate`、`/{id}/publish`；沿用现有 jobs/idempotency 框架，不另造 durable job 引擎。列表/读取仅返回安全元数据；试听沿既有受限本地资产通道，不接受任意路径/远程 URL。
3. confirm 固定候选和 transcript revision；编辑参考文本产生新候选 revision 并清除旧验证，不允许只改文字但复用验证。
4. validate 用**不同于参考文本**的受控测试文本调用目标 Base plan；保留现有声学/转写校验并加入身份与质量证据。自动数值不能替代自然度/身份听审；人工听审由当次用户确认，不自动标通过。
5. 发布最低要求：明确确认的参考 + 至少一个目标 Base spec/mode 的完整通过记录；只将通过集合声明可用，其余 unavailable/unknown。不要求每个声音先跑遍所有模式，也不将一次通过泛化。
6. publish 在锁内校验 candidate/revision/evidence 未变，原子创建不可变 voice revision；取消、重复 publish 与崩溃恢复不能产生半发布或两个 revision。
7. MCP `create_voice` 不再承诺 instruction 一步发布：调整到候选/确认/验证/发布实际工具流程并同步契约、App；移除旧直接发布语义，不在后台代用户确认。
8. 原始参考资产仅仓库外保存；已有声音/素材不自动转换、删除或冒认新格式，通过只读不可用原因提示用户重新确认/发布。

**完成条件**：Base 新文本验证失败永远不会注册生产声音；idempotency 重试不重复生成/发布；失败不破坏原资产；未经确认不能发布。

## T09 / P3：增量状态机与测量口径修复

**修改**：现有 `domain/tts_stream.py`、`application/tts_stream.py`、`backends/qwen3_tts_stream_{client,host}.py`、`qwen3_tts_incremental.py`；`examples/perf/bench_tts_streaming.py`、`bench_tts_stream_lifecycle.py`。

1. 保留状态机与 owner；plan/voice revision 固定整轮。追加不重新 prepare reference、不重建 utterance；引擎 fake spy 断言 open=1、append=N、finish=1。
2. ACK 精确匹配 request/task/sequence；音频/状态包不能释放文字窗口。finish 以最后 accepted sequence 为屏障，waiting_for_text 不触发完成。
3. 音频队列满不能阻塞 cancel/terminal；保留 `on_sent` 预算归还语义，以及已结束 request 的有界记忆、未知外来 id fail-closed。
4. harness 拆独立 sender/receiver，sender 等 ACK credit 而不是“收到任意事件”；interval sleep 不能阻塞收音。
5. 传输层 receive 必须可中断 timeout，外层单调 deadline 含握手/发送/收取/cleanup；不能仅 recv 返回后检查时间。
6. 按第 6 节更正 first PCM/RTF/headroom/失败分母，并增加 first_pcm_before_finish、utterance initialization count、terminal/resource release 分开的证据。

**完成条件**：回归钉住 phantom ACK、永久不 recv、出音后失败、新包掩盖 underrun 四类问题；旧报告原样保留并标“旧口径，不继承认证”。

## T10 / P0、P4：协议单栈切换、边界重采样与 App/MCP

**修改**：`compatibility/openai_realtime.py`、`application/realtime_openai.py`、`http/routes/realtime_openai.py`、`http/routes/audio.py`、`mcp/{models,client,tools}.py`；Swift `SpeechRailControlKit/RealtimeContractTypes.swift`、`ServiceContractTypes.swift`、`SpeechRailApp/RealtimeASRClient.swift`、`MicrophoneCapture.swift`、`AssistantAudioSession.swift`、`AssistantTTSStreamCoordinator.swift`、`TeleprompterRealtimeClientProtocol.swift`；相关调用方及共享 fixtures。

1. 用 T01 schema 替换唯一 parser/serializer；不并存 transcription_session.update 和 session.update。
2. Realtime 默认只支持本方案声明的 24k PCM16 mono；G.711/其他格式没有实现就明确拒绝，不接受后按 16k 误读。REST 上传的 codec 解码边界保持自身契约，不一刀切改为 24k。
3. App 麦克风 native→24k wire，服务边界→16k ASR；TTS started 声明输出格式，播放器按协商格式而非猜测。AEC/采集本地逻辑不搬到后端。
4. 官方转写增量与 snapshot revision 分开解码；caption/meeting/teleprompter 不能将 snapshot 当永久 append。App 重连增加 epoch，pending auxiliary 结果必须匹配。
5. TTS 输出使用第 6 节 SpeechRail namespace；统一替换 coordinator、bench、SDK fixture、文档。不将本地 TTS 伪装为完整 LLM response。
6. 保留 MacPaw/OpenAI 已覆盖传输与业务边界；非标准扩展集中 adapter，不能为改 wire 重写整个 OpenAI SDK。

7. 发布前对运行代码、测试、examples、正式用户文档与 `src/speechrail/assets/skills/speechrail/` 做旧名称/旧wire定向检索；每个命中分类为“应移除生产路径/应更新消费者/有意保留拒绝测试/历史记录”，不对历史文档全局替换。同步内置skill导出的API/MCP示例，防止安装产物继续教客户端发旧协议。

**完成条件**：同一共享 fixture 通过 Python/Swift；旧协议明确拒绝；所有当前客户端与工具同批适配；请求不支持字段均产生稳定错误而非 no-op。

## T11 / P4：原子切档、播放屏障与制作固定计划

**修改**：`service/profile_switch.py`、`profile_store.py`、`application/services.py`；Swift `AppModel.swift`、`ProfilePickerView.swift`、`ModelManagementView.swift`、`AssistantSession.swift`、`AssistantTTSStreamCoordinator.swift`、`AssistantPlaybackLedger.swift`、`CreativeWorkStore.swift`、`SpeechRailDesignTokens.swift`（确有新视觉值时）、`docs/developers/macos-app-design-system.md`。

1. 快捷组合只写两项 specs；高级项独立调整。普通用户显示轻快/品质/参考精度，技术角色与 dtype 放诊断；保留既有导航，不因任务概念重做所有页面。
2. switch 流程：只读校验候选/制品/预算 → CAS 标记 draining → 阻止新相关任务 → 等待相关 owner 安全退出 → 原子激活 generation → 新 owner ready/身份确认 → commit。失败还原前一 selection/runtime 绑定并明确状态。
3. prepare 阶段不为了验证候选而在旧 resident 上同时加载第二份超预算权重；新模型加载放安全 handoff，失败走已保留的恢复路径。
4. ASR session/TTS utterance/render active 时不能偷偷热切；UI 显示忙碌及下一步，不隐式中断。auto 只在新任务边界依据认证和预算稳定选择，本次选择写入 plan。
5. coordinator 先 invalidate epoch、清空本地队列，再 await playback stop barrier，随后并行取消 LLM/TTS；等待后端取消超时不恢复旧音。终态回报与 playback drain 分离，晚到 dataRendered 回调不得修改新 epoch 账本。
6. render 项目保存 voice revision 与 plan digest/材料引用。全局默认变化不修改已有项目；确需刷新为新 plan 由显式用户操作产生新 render revision。

**完成条件**：切档失败无半激活；新旧任务隔离；纯 Swift 测试验证停播 barrier 先于网络 cancel；现有项目数据不被删除，视图遵守 Token/键盘/无障碍规范。

## T12 / P5：交付认证与证据登记（需专项授权）

**修改/产物**：`docs/developers/testing-acceptance.md`、`docs/users/effective-capabilities.md`、相关用户 API/MCP 文档、`docs/operations/README.md`；拟新增 `docs/developers/issue-95-certification.md` 存脱敏摘要和结果索引。原始音频、转写、日志与 benchmark 原始文件在仓库外。

1. 先检查 wheel 安装/import 来源唯一、版本与 hash 符合锁，重建 inputs 可追踪；不靠 runtime overlay 或临时 checkout。
2. 12 制品逐项核验依赖、snapshot 哈希与加载后 precision 身份；只验证任务需要模型，不因为 12 项清单就同时常驻 12 项。
3. 分别认证四组合×实际 TTS role；冷/热、语言、短/长、voice revision、ASR/VAD/对齐/分人条件分层，不把若干 p50 当作整体 P95。
4. 根据第 8 节做延迟、内容质量、实际播放器、长稳、cancel、失败恢复测试。先 ASR→固定回复隔离服务，再测真实 LLM 端到端。
5. 记录 commit/engine/model/codec/voice/device/任务配置/样本数/分位算法/置信区间/失败数。性能未达标不得标实时通过；reference 可据真实证据仅声明 render 支持。
6. 完成证据绑定后才更新能力认证集合；P0–P5 缺任何关键证据均保持总单未完成。只使用 Refs #95，不能由 PR 合并自动关闭。

**完成条件**：功能、供应链、设备/组合、播放器和质量证据全部闭合。没有当次专项授权时，交付代码与 not_run 清单即停，不自行部署/基准/UI。

# 6. 关键实现说明

## 6.1 核心类型约定（拟新增，非当前源码）

```python
SpecTier = Literal["fast", "quality", "reference"]
ModelRole = Literal["asr", "tts_base", "tts_custom_voice", "voice_design", "alignment", "diarization"]
TaskKind = Literal["conversation", "caption", "transcription", "render", "voice_design"]

# 所有领域对象 frozen；不保存用户正文到日志/公开摘要。
ModelSpec(
    spec_id, role, tier, artifact_key, artifact_revision,
    weight_precision, compute_config, engine_revision,
    dependency_ids, languages, implemented_capabilities,
)
TaskRequest(
    task_id, kind, asr_spec, tts_spec, selection_generation,
    voice_revision, input_format, required_outputs,
    alignment_options, diarization_options, allow_auto,
)
ResolvedPlan(
    plan_id, task_id, selection_generation,
    models, voice_revision, input_format, kernel_format, output_format,
    limits, required_outputs, resource_profile_revision,
    capability_evidence_revision, digest,
)
```

- `models` 是需要的角色列表，普通 TTS 恰好一个 Base 或 CustomVoice；ASR-only 不带 TTS；Design 作业的候选生成与 Base 验证是不同子阶段计划，不并行常驻所有模型。
- ModelSpec 的固定资源事实来自 manifest，supported 来自模型/engine/输入/验证交集；ready/busy 单独由 registry 提供。
- plan digest 用 canonical JSON，仅含非敏感执行身份；不包含 transcript、prompt、参考路径或正文 hash 等可泄漏内容。
- 内部运行上下文可定位本地素材和绝对模型目录，对外只给安全 artifact ID/revision、plan ID 和错误原因。
- `resolve → admit → acquire owners → verify identity → execute → claim terminal → stop/close → release`；任一步失败都从同一 finally 清理，terminal 与资源释放分别可观察。

## 6.2 当前协议与扩展命名（P0 固化提案）

当前官方转写 shape（model 值只是占位说明，实施 fixture 用已注册 SpeechRail model ID）：

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": {"type": "audio/pcm", "rate": 24000},
        "transcription": {"model": "<registered-speechrail-model>"},
        "turn_detection": null
      }
    },
    "speechrail": {"task": "caption", "alignment": {"enabled": false}, "diarization": {"enabled": false}}
  }
}
```

- 更新确认使用 session.updated；连接 session.created 的详细 schema 在 T01 对照官方 reference 固化。新增字段必须有实际行为，不复制当前云模型的所有字段。
- 本方案首批官方子集 `audio.input.turn_detection` 仅支持 null/manual。SpeechRail 服务端 VAD 使用明确扩展 `session.speechrail.endpointing={mode:server_vad,...真实支持参数}`；两者互斥，非 null 官方 turn detection 未实现时 unsupported。这样不将本地 Silero 冒充官方云模型能力。若实施选择扩大官方 VAD 子集，必须先补其语义/事件契约，不能直接透传。
- append/commit/clear 及官方转写 delta/completed/failed 只实现声明的 ASR 子集；兼容模型 ID/参数都来自 manifest 与 schema。
- 扩展 snapshot 建议 `speechrail.transcription.hypothesis`，包含 task_id/epoch/utterance_id/revision/text/sample_span。不靠覆写官方 delta 实现可修订文字。
- 辅助事件为 `speechrail.alignment.done/failed`、`speechrail.diarization.updated/done/failed`；包含 transcript_revision、metadata_revision、sample span、codepoint span 及 status；final 正文不再出现修改版本。
- 保留增量输入 `speechrail.tts.start/append_text/finish_text/cancel` 与 `started/text_accepted` 名称；新输出统一为 `speechrail.tts.audio.delta` 和 `speechrail.tts.completed/cancelled/failed`，不继续生成假 conversation/LLM response 生命周期。此命名是**拟议直接切换**，不是已存在 wire。
- TTS start 带 request_id、voice revision、任务模式；服务回 started 包含 task_id/plan_id、output_format、limits；后续输出必须带 task_id/request_id、chunk_index/sample_offset，base64 PCM 只在 wire，禁止入日志。
- terminal 必须恰好一个，不再同发 response.done 与 speechrail terminal。App、MCP 的相关 REST 元数据、bench 和测试同批更新，不保留旧输出 alias。
- 明确拒绝名单包括旧 update、旧音频平铺字段、旧四档名、Design runtime voice、Q4/Q6/Design Q8、假上下文开关与不支持表达参数。现有 SpeechRail 必需扩展不是因“自定义”而删除，而是核对真实语义后保留/收敛。

## 6.3 辅助结果与终态分离

```text
ASR utterance: collecting → committing → text_final | failed | cancelled
Alignment:    not_requested | pending → done | failed | cancelled
Diarization:  not_requested | running → done | failed | cancelled
```

ASR text_final 是文本结果终态，不表示用户要求的全套 job 已完成。Realtime 用户立即收到 final，辅助随后送达；完整转写 job 等待 required_outputs 全部满足，任一必需辅助失败则 job failed。终态中可安全引用已经完成的 transcript，不输出“成功+空数组”假全量结果。

final 之前取消：不再发 final。final 之后取消辅助：保留已发 final，辅助独立 cancelled。新 epoch 不接纳旧 task 的任何文本、元数据或 PCM。

## 6.4 测量公式与失败语义

- `tts_first_pcm_ms = receive_first_nonempty_valid_pcm - send_first_stable_text`；另报 start→started，不混作首声。
- `generation_rtf = (terminal_time - first_stable_text_send_time) / generated_audio_duration`，在“充足文本供给”条件单独统计，包含必要首段开销。worker model-active 时间另报为独立指标，不假定墙钟减 gap 等于计算耗时。
- 真实流式供给另报 sender gap、server waiting_for_text、积压与首音；不得任意扣除客户端等待。
- 第 i 个包到达前的 headroom：`previous_cumulative_samples / rate - (arrival_i - playback_proxy_start)`。默认 proxy_start 为首可播放包到达；不把新包样本加进去后再检查。
- 最坏 headroom 报 min/低分位或正向 deficit，不用越大越差的 P95 混淆方向；网络 proxy 与声卡 underrun 分开。
- 成功分布只包含 terminal=completed 且协议/PCM 有效的样本；部分出音后失败、超时、异常断连全部计入 total/failure。取消测试的预期 cancelled 单独归类，不混入普通合成成功数。
- 记录 first_pcm_time、finish_sent_time，并验证足够初始文本下 first_pcm < finish_sent；单字/长参考预填充不强套此门槛，不将 2.4 秒硬编码为参考上限。
- recv deadline 覆盖永久沉默与慢 trickle；超时主动中断传输、清理任务并有限等待，不能遗留后台 reader 占下一个 utterance。
- cancel→terminal 与 cancel→lease released 分开，后者才比较 ≤1000ms。不同端时钟没有映射时不直接相减；端到端 P95 来自同轮 trace，不能相加局部 P95。

# 7. 测试方案

## 7.1 已有测试的定向修改

| 测试文件（均相对仓库根） | 新增/调整断言 |
|---|---|
| `tests/test_model_presets.py`、`test_model_catalog_builder.py`、`test_model_identity.py` | 三 spec×角色精确集合、12项来源/依赖完整、无Design Q8/Q4/Q6；不要删掉所有旧测试来制造绿灯 |
| `tests/test_profile_store.py`、`test_profile_selection.py`、`test_profile_commands.py`、`test_profile_switch.py` | selection v2、旧格式明确错误、双spec组合、CAS并发、候选失败恢复、不覆盖旧用户文件 |
| `tests/test_resource_governor.py`、`test_asr_mode.py`、`test_tts_stream_application.py` | 同 owner互斥、不同voice共享、未知peak fail-closed、取消释放一次、queued cancel不泄漏、Design不抢占 |
| `tests/test_capability_snapshot.py`、`test_tts_stream_capability_matrix.py` | supported与ready/busy分离、ASR操作矩阵、语言交集、ETag失效、发现无启动/网络 |
| `tests/test_qwen3_worker.py`、`test_qwen3_worker_limits.py`、`test_qwen3_streaming.py` | dtype显式透传/身份不符拒绝、不隐式aligner、chunk/context真实消费、final不等辅助、空final、重复commit/VAD |
| `tests/test_diarization_alignment.py`、`test_alignment_admission.py` | Unicode/标点/重复词、越界/逆序/无覆盖拒绝、异步失败不改final、取消旧revision隔离、按请求而非按档启用 |
| `tests/test_qwen3_tts_capability_router.py`、`test_qwen3_tts_capability_router_lifecycle.py`、`test_qwen3_tts_capability_router_availability.py` | 六规格路由、Design runtime禁止、Base不可用不回退、共享权重、角色独立就绪 |
| `tests/test_tts_reference_condition.py`、`test_voice_revision_contract.py`、`test_voice_validation.py` | 引擎/量化/codec/预处理/voice revision任一变化使缓存与证据隔离，不同task共享合格只读条件 |
| `tests/test_voice_design_registration.py` | 未确认/未Base复验不能publish、ASR参考自检不是Base复验、不同测试文本、幂等/重复发布/崩溃、失败保留素材 |
| `tests/test_tts_stream_state.py`、`test_tts_stream_application.py`、`test_tts_stream_client.py`、`test_tts_stream_worker.py`、`test_tts_incremental_vendor_state.py` | finish/cancel竞争、音频队列满取消、on_sent归还、未知id拒绝/已结束id隔离、每轮只初始化一次 |
| `tests/test_realtime_openai.py`、`test_realtime_caller_wire.py`、`test_realtime_tts_incremental.py`、`test_websocket_contract.py` | 新session形状、24k/16k边界、旧wire拒绝、snapshot≠delta、独立辅助、TTS唯一namespace终态 |
| `tests/test_bench_tts_streaming.py`、`test_bench_tts_stream_lifecycle.py` | 音频不能推进ACK窗口；sleep不阻塞接收；阻塞recv超时；到包前负余量；partial audio后failed计失败；RTF不扣gap |
| `tests/test_runtime_bootstrap.py`、`tests/mcp/test_sdk_contract.py` | 锁定wheel且唯一import、无overlay安装、MCP候选与发布流程契约同步 |
| `macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift`、`RealtimeTTSStreamTests.swift` | 共用fixture、旧事件拒绝、协商格式、snapshot revision与旧epoch隔离 |
| 同目录 `AssistantTTSStreamCoordinatorTests.swift`、`AssistantPlaybackLedgerTests.swift`、`StreamingTtsCapabilitiesTests.swift`、`AppModelTests.swift` | 停播屏障→cancel顺序、迟到渲染回调、ACK≠播放、两项spec与无第三preset、不可用原因 |

## 7.2 拟新增测试

- `tests/test_task_plan.py`：冻结对象、canonical digest、voice/能力拒绝、auto只能从认证集合选择、generation重解析、无IO。
- `tests/test_model_owner.py`：并发acquire单实例、引用计数、加载失败/身份错/重启、lease释放时机、同制品共享依赖计账。
- `tests/test_audio_timeline.py`：24k→16k分包连续性、非整包、长时整数时钟、delay补偿、边界舍入、重置隔离；使用合成信号而非真实音频。
- `tests/test_alignment_worker.py`：独立协议/进程、无ASR导入、只接固定文本、有限队列、timeout/cancel/崩溃恢复。
- `tests/test_voice_design_workflow.py`：候选确认/验证/发布状态表与并发幂等；复用fake TTS/ASR，不加载模型。
- `tests/test_realtime_current_schema.py`：共享schema/fixture全覆盖、unknown字段反例与Python payload一致。
- `tests/test_engine_wheel_build.py`：临时小型fake package检验源码/补丁摘要与固定构建输入，不自动联网构建真实引擎。
- `macos/SpeechRailApp/SpeechRailMacControlTests/AudioTimelineTests.swift`：codepoint→UTF16、整数采样映射；新增文件按Package.swift显式sources配置检查归属。

## 7.3 容易漏掉的五类输入

1. **音频包夹在ACK之间**：不得提前append或finish；由T09 harness测试负责。
2. **已出PCM后失败**：不得计成功或将延迟平均成零；T09统计测试负责。
3. **text final后辅助失败/旧epoch回包**：不改final、不污染新会话；T06/T10负责。
4. **相同voice跨spec/engine与参考文本编辑**：不能复用旧缓存/认证；T07/T08负责。
5. **切换时旧owner未退出/播放stop排队**：不能半激活、不能旧音继续播放；T04/T11负责。

## 7.4 不在本轮执行的验证

所有产品测试、完整gate、真模型、硬件音频、真实UI均未执行。本方案只提出验收方法。fake通过不证明真实dtype、字符对齐质量、身份听感、实时并发或长稳；Swift纯测试不能证明实际扬声器停播和无障碍观感。

# 8. 验收标准

## 8.1 定向命令（计划，实施获准后在仓库根运行）

以下命令基于当前仓库工具及已有测试路径核对，**本轮未执行**。新增文件完成后再加入对应命令；依赖同步/构建若会扩大网络或运行态范围，先按项目规则处理。

```bash
# 选择/制品/治理
uv run --extra dev pytest --no-cov tests/test_model_presets.py tests/test_model_identity.py tests/test_profile_selection.py tests/test_profile_store.py tests/test_profile_switch.py tests/test_resource_governor.py tests/test_capability_snapshot.py

# ASR/辅助
uv run --extra dev pytest --no-cov tests/test_qwen3_worker.py tests/test_qwen3_worker_limits.py tests/test_qwen3_streaming.py tests/test_asr_mode.py tests/test_diarization_alignment.py tests/test_alignment_admission.py

# TTS/音色/增量
uv run --extra dev pytest --no-cov tests/test_tts_stream_state.py tests/test_tts_stream_application.py tests/test_tts_stream_worker.py tests/test_tts_stream_client.py tests/test_tts_reference_condition.py tests/test_voice_design_registration.py tests/test_voice_revision_contract.py

# 协议/harness（不是运行真实基准）
uv run --extra dev pytest --no-cov tests/test_realtime_openai.py tests/test_realtime_caller_wire.py tests/test_realtime_tts_incremental.py tests/test_bench_tts_streaming.py tests/test_bench_tts_stream_lifecycle.py tests/mcp/test_sdk_contract.py

# 纯Swift定向测试，不启动App/UI
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests
swift test --package-path macos/SpeechRailApp --filter AssistantTTSStreamCoordinatorTests
swift test --package-path macos/SpeechRailApp --filter AssistantPlaybackLedgerTests

# 静态检查；新增契约脚本在T01实现后才可运行
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
uv run --extra dev python scripts/check_realtime_contract.py
git diff --check
```

最小预期：所选测试无失败；不存在“跳过关键场景”等价通过；Ruff/Mypy/契约检查无错误；新测试在修复前能表达真实回归。定向 pytest 使用 `--no-cov` 避免全局80%覆盖阈值误判局部运行。

完整套件仅在明确授权后执行 `uv run --extra dev pytest`（仓库addopts含覆盖率，要求≥80%）。App编译须另按release skill与 `bash scripts/macos_app_build.sh --configuration Debug`；不要裸跑会产出.app的xcodebuild。`scripts/macos_app_test.sh` 属于前台UI授权范围，**不作为本方案默认执行步骤**。

## 8.2 分阶段可勾选门

- [ ] P0：schema、Python、Swift、MCP/文档形状一致；所有公开参数有真实行为或拒绝；旧wire无alias；T01+T02+T10联合满足，不只看文档。
- [ ] P1：12项模型及独立依赖锁定；三spec独立选择；唯一owner与计划；identity握手；未知预算/未认证并发fail-closed；无隐式下载。
- [ ] P2：同一ASR主链路、唯一final、独立Alignment、语言/Unicode/sample契约、有界PCM、匿名分人；#82/#83/#85分别有证据。
- [ ] P3：六运行规格路由、Design BF16设计专用、参考确认与Base复验、voice revision/cache隔离、真增量/ACK/唯一terminal通过。
- [ ] P4：当前单协议、wire/kernel采样率边界、原子切档、停播屏障/epoch、固定render计划；实际播放器证据另附。
- [ ] P5：受控wheel唯一实现，制品与加载身份、组合/设备/质量/长稳/恢复认证完整。

## 8.3 初始真实工程目标（未实测）

| 指标 | 目标 |
|---|---|
| ASR有效chunk最后输入→partial | 热态P95≤500ms，另报采集积累 |
| commit→text final | 热态P95≤500ms |
| 语音结束→final | 固定endpoint下P95≤1000ms |
| 首段稳定文本发送→可播放PCM | 热态P95≤500ms |
| 充足文本供给generation RTF | P95≤0.8 |
| 决定打断→实际旧音停止 | P95≤200ms |
| cancel→任务资源释放 | P95≤1000ms |
| 长稳 | 内存/缓存/队列有界、反复取消无污染、异常可恢复 |

质量硬门覆盖：中文CER、英文WER、混合/数字/静音/噪声、TTS内容/身份/自然度、Alignment误差/覆盖/越界、分人匿名归属/重叠/容量。目标文档未冻结这些质量指标的数字阈值，**不得由Luna臆造通过标准**：P5运行前提出语料分层、盲听规则与各项阈值，经评审确认后执行；这是认证入口条件，不阻塞上述代码实施。

至少30独立条件×5次可作为探索设计，不能当作已证明可靠。必须分层记录失败率和置信区间；缺实际播放器/长稳/质量任一证据不能关闭总单。

# 9. 风险与注意事项

1. **协议直接破坏性切换**：旧App、脚本、SDK fixture将失败。这是已接受方向，但必须同批更新当前消费者，不能悄悄切服务后再补App；release恢复通过整套旧release+选择快照，不通过新代码接受旧alias。
2. **持久化数据不等于历史接口**：旧selection明确拒绝可行；旧voice/项目/素材不得删除。新增voice revision或render plan字段若涉及现有存储结构，先备份并写无损读取/显式重新确认流程，不以“无兼容”授权破坏数据。
3. **制品缺口是事实门**：三项缺失模型的可用源、hash与完整依赖尚未核实；不能承诺可安装或已认证。若不可取得，记录阻塞，不换Q4/Q6或用Design替代。
4. **ASR显式dtype需核对引擎源码**：本轮只确认项目未传入，未证明上游当前构造器支持哪种关键字。T03检查固定源码，T05适配；不能凭示例猜测API。
5. **Protocol reference还需字段级冻结**：本轮已验证官方指南的核心shape，不宣称审完全部reference。T01把事件schema、错误与缺省值定成检查样例；不导入完整LLM能力。
6. **精度/资源/质量**：Q8/BF16是身份，不是速度/声音质量排名；未知peak不是0。按调用图不代表真实性能已认证。
7. **历史记录不改写**：PR94、W0–W11、40-cycle soak/App构建记录保留日期与版本。本轮分析发现harness问题不等于那些运行从未发生，但不能将其数字沿用到新口径。
8. **并行改动**：实施开始先核对HEAD/工作区；同文件变更不可安全分离时停写核实。不checkout/reset还原、不整文件覆盖、不force-push。
9. **范围限制**：不新增LLM编排服务、实名speaker、跨会话声纹、PCM数据库；不重做提词器布局、作品编辑器或全App导航；不顺带改根README。相关API与MCP用户文档必须更新。
10. **授权**：本方案不授权下载/加载/切服务/安装/发布/UI。真正进行本机运行态或模型验证前读取环境手册及对应专项skill；本轮仅源码分析无需探测硬件/本机模型。
11. **回退**：代码回退仅针对本任务已明确记录的原子变更并经授权；运行态回退复用managed installer/profile事务及保留release，不能pkill、手改plist或全局重置LaunchServices。
12. **认证方案待评审**：质量数值门槛、真实缺失制品和wheel认证尚未闭合。本文可指导代码实施，但不是无条件发布/关闭Issue的批准书。

## 9.1 证据定位

- GitHub 事实：`hrygo/SpeechRail#95`、`#82`、`#83`、`#85` 及 PR `#94` 的API读取；Issue #95与PR #94评论读取均为空。
- 已接受规格：`docs/architecture/2026-09-25-asr-tts-target-architecture-no-legacy.md`。
- 当前源码：第2节路径与符号；均基于文首HEAD，不依赖PR旧快照猜测。
- 开发/验收入口：`docs/developers/testing-acceptance.md`、`docs/developers/macos-app-development.md`、`docs/developers/macos-app-design-system.md`、`.github/workflows/ci.yml`、`macos/SpeechRailApp/Package.swift`、`scripts/macos_app_build.sh`。
- 官方协议核实入口（2026-09-25只读读取）：`https://developers.openai.com/api/docs/guides/realtime-transcription`。仅据其确认核心结构，不将其特定云模型能力外推为SpeechRail承诺。

# 10. Luna 执行清单

执行前：读取本方案与accepted规格；核对分支/HEAD/工作区、子目录规则和授权。若实际代码已前进，按本方案证据锚点比对，不重复已有工作。

- [ ] **T01**：在contracts与共享fixtures冻结当前wire、字段行为表与反例；schema/双端机械校验入口存在。此任务不单独代表P0完成。
- [ ] **T02**：在domain/config/service建立独立双spec、不可变TaskRequest/ResolvedPlan和selection事务；旧格式明确拒绝且不覆写数据。
- [ ] **T03**：catalog完成12角色集合；缺失制品有真实hash/revision；受控引擎wheel构建与lock取代overlay。未获模型准备授权时停在制品门，不能填假值。
- [ ] **T04**：registry/governor统一owner与预算；capability从计划与证据计算；用fake验证无模型复制、无lease泄漏、发现只读。
- [ ] **T05**：ASR显式精度、真实chunk/context参数、唯一final与首partial指标；慢对齐不影响text final。
- [ ] **T06**：Alignment独立worker与生命周期，采样/Unicode/metadata revision契约闭合；#85按实际粒度能力声明。
- [ ] **T07**：TTS六规格唯一角色路由；Design不进入日常；voice revision、缓存和render身份不可漂移。
- [ ] **T08**：设计候选确认→Base新文本验证→原子发布；fake覆盖失败/取消/重复/崩溃；旧资产保留。
- [ ] **T09**：复用增量状态机，修ACK/timeout/RTF/headroom/失败统计；fake证明一轮单初始化与PCM早于finish的可测条件。
- [ ] **T10**：Python/App/MCP/bench/文档同批切到唯一当前协议；24k边界与16k内核转换、snapshot与delta分离；T01+T02+T10满足P0闭环。
- [ ] **T11**：App双spec/原子切档、停播屏障、旧epoch隔离与固定render plan；纯测试通过不冒称真机停播达标。
- [ ] **T12**：取得专项授权与质量阈值评审后进行供应链/设备/组合/播放器/长稳认证；逐阶段附commit、时间、测试摘要和not_run项。
- [ ] **交付复核**：只报告实际通过的阶段；未授权不提交/推送/安装/运行UI；仍缺任何P0–P5证据时保持#95 open，仅Refs关联。

**本轮交付结论**：完成的是当前源码差距分析与实施方案；产品实施、产品测试和真实认证均未在本轮执行。
