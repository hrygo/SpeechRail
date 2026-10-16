# Meeting Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本文仅规划；不自动下载、加载、修改运行态或提交 Git。

**Goal:** 会议超过 4 人时仍保持主要发言者身份稳定，正确区分其余参与者；短应答证据不足时保留 unknown，不能强塞进四个槽。

**Architecture:** 固定 FluidAudio SDK 的 Community-1 segmentation/embedding/PLDA＋VBx 管线处理 30 s RAM 窗，10 s hop；局部簇经时间重叠约束和有拒绝门的匹配映射到 session-scoped 匿名 ID。文字 ASR 独立定稿，归属异步更新；单个 diarization worker 只加载选定后端。

**Tech Stack:** 既有 native Swift/CoreML worker、Python ActivitySession、Resource Governor、Swift App；不升级 FluidAudio revision，不写 `.build/checkouts`，SQLite 维持 v13。

**Spec:** [设计 §5.3、§9.5、§9.7–9.8](../specs/2026-10-16-meeting-caption-asr-design.md)，依赖[共享 ASR 计划 T0/T3/T4/T7/T8](2026-10-16-meeting-caption-asr-implementation.md)。日期：2026-10-16。

## Global Constraints

- 用户事实：总参与者可能超过 4，主要发言者通常不超过 4。运行时不据此设 `numSpeakers=4`，不把参会人数直接当发言人数。
- 首选候选已经锁定 SDK API 和制品来源；本次未下载/加载，实际质量、内存和阈值仍由 D6 校准后锁定。模型文件大小不是 resident/峰值。
- embedding 只在 native worker RAM 中使用；IPC/日志/SQLite 不带向量，不建声纹库、不跨 session 识别实名。结束销毁全部原型和 PCM。
- 一个模型 worker 承接分人；会议默认选 dynamic，字幕默认不分人，显式 ≤4 人对照仍可选 Sortformer。未 ready 不静默换后端，能力与回显写清实际后端/支持上限。
- 所有同文件改动串行：主线 T4 后交 D1/D3，主线 T7 后交 D5，或合成同一 reviewable task；不得覆盖既有修复。

## Review Focus

| 失败类 | 覆盖 |
| --- | --- |
| 第五人短插话被并入主讲人、相似音色、局部簇号置换 | D2、D6 |
| 同一段 overlap 音频多次计为新独立证据，原型漂移污染 | D2、D3 |
| 稳定边界被旧窗覆盖，长时间离席后重用旧 ID 错人 | D2、D3 |
| 隐式下载/编译、缺制品但 ready、超时后提前释放 CoreML 任务 | D0、D4 |
| Python/App 固定四槽、达到人数 cap 后循环标签、恢复读新值失败 | D1、D5 |

`Files` 中省略前缀的 Python 路径均相对 `src/speechrail/`，App 文件相对 `macos/SpeechRailApp/SpeechRailApp/`，测试相对 `tests/`；跨 target 或新文件写出完整仓库路径。

## 已核对的制品与 API

SDK revision 为 `5c19d5e12320e22bbfb7a1877b089d2665a69add`；其 `OfflineDiarizerManager.initialize(models:)` 和 `process(audio: [Float])` 已核对，输出 `segments/speakerDatabase/chunkEmbeddings`，`OfflineDiarizerConfig` 有自动人数、min/max/exact 选项。**保持自动人数和 co-chunk constrained assignment**，不强制 4，不为凑人数运行 K-Means；超过系统 cap 的候选转 unknown。

2026-10-16 通过公开仓库 API 只读核对的制品来源是 [`FluidInference/speaker-diarization-coreml`](https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/7eab74f3463c736418d0eb10296261ae581146c9)，snapshot `7eab74f3463c736418d0eb10296261ae581146c9`：

| 必要制品 | 文件数 | 远端声明字节数 |
| --- | ---: | ---: |
| `Segmentation.mlmodelc/` | 5 | 6,006,888 |
| `FBank.mlmodelc/` | 5 | 1,797,068 |
| `Embedding.mlmodelc/` | 5 | 13,494,485 |
| `PldaRho.mlmodelc/` | 5 | 211,560 |
| `plda-parameters.json` | 1 | 89,416 |

以上必要推理文件合计约 20.6 MiB，仅为**远端元数据**，未进行本地字节/hash/运行识别验收。另保留该 snapshot 的 `NOTICE.md/PROVENANCE.md/provenance.json`；[模型卡](https://huggingface.co/FluidInference/speaker-diarization-coreml)标注 Community-1 制品 scoped CC-BY-4.0，应按精确 NOTICE 范围保留署名，不把同库 legacy 权重混入这份清单。模型卡公开说明历史二进制来源重建的局限，不宣称可复现构建。下载后须逐文件核验，不能仅凭仓库名。

本次不预设 ModelScope 镜像存在。获准准备时先核对是否有相同版本/格式/完整文件集且 hash 一致的镜像；不满足则说明原因后使用上述原作者源。不得把 SDK 的 ModelHub/prepareModels 接到请求路径。

## D0 — 锁定制品准备与本地加载边界

**Files:** `src/speechrail/service/diarization_assets.py`、`service/profile_commands.py`、`service/preflight.py`、`config/__init__.py`；新增 `tests/test_meeting_diarization_assets.py`，扩展 `test_service_preflight.py`。

**Consumes:** 锁定 manifest 和明确的准备请求。**Produces:** 本地已校验制品目录、path-free readiness；不自动 apply/restart。

- [ ] 沿用现有 opt-in 辅助制品准备链（目前专用于 Sortformer），增加 `meeting_dynamic` manifest；每个文件固定相对路径、大小与 SHA-256，准备使用仓库外 staging/原子替换且保留原制品。
- [ ] 新增 `diarization_dynamic_model_dir` 和 `diarization_dynamic_enabled=False`；不擅自把 diarization 放进当前仅含 Qwen 的 ModelArtifact family。预检确认四个已编译模型目录、PLDA 参数 schema、worker 可执行和固定 SDK/runtime 身份。
- [ ] native 构造器用 `MLModel(contentsOf:)` 加载已验证本地目录，FBank 按固定 SDK 路径使用 cpuOnly，其余先 all；用 `OfflineDiarizerModels(...)` 与 `initialize(models:)` 注入。禁止 prepareModels、Hub load、compileModel 或删除缓存。
- [ ] 网络调用 spy＋临时假目录测试：缺一文件/hash不符/JSON形状错/可执行缺失均 not-ready，不回退下载。实际 CoreML 加载属于 D6，不能用假文件证明模型可用。
- [ ] 运行：`uv run --no-sync pytest --no-cov tests/test_meeting_diarization_assets.py tests/test_service_preflight.py`。

**Done:** 纯逻辑和 fake 准备链通过；真实制品仅在获准准备后逐文件验证，不读取或改动未知配置。

## D1 — 去除跨层四槽假设，保留后端严格校验

**Files:** `src/speechrail/domain/diarization/types.py`、`attribution.py`、`application/realtime_auxiliary.py`、`application/services.py`、`backends/diarization/coreml.py`；新建 `src/speechrail/backends/diarization/meeting.py`；契约/能力文件与主线 T0 串行；扩展 `tests/test_diarization_attribution.py`、新建 `test_meeting_diarization_contract.py`。

**Consumes:** 连续活动区间与已协商 backend。**Produces:** 同一 ActivityUpdate/Attribution 流，不向 App 暴露 embedding。

- [ ] `ActivityFrame.scores` 改为 `tuple[float,...] | None`，`active_slots` 才是归属支持的输入；Sortformer adapter 仍严格要求 4 个 score。动态 adapter 接匿名 slot 集合，不伪造 0/1“概率”。slot 硬限 [0,31]，score 存在时还须与其维度一致。
- [ ] AttributionLedger 按已观察/声明 slot 求支持，删除 `range(4)`；空活动集合输出 unknown，不能给默认第一人。label 分配由后端策略固定：现有 Sortformer 保持原 A–D 分配语义；动态由 native D2 分配全局 slot，Python 严格映射 `slot n → S(n+1)`，不能按首次观察顺序重新编号。同一服务 session/input epoch 内单调分配、不复用；App 按 D5 加本地 scope，不能跨新 session 直接复用裸标签。
- [ ] `session.speechrail.diarization.backend` 取 `sortformer|meeting_dynamic`，新会议 App 显式请求后者；旧模式仅传 enabled 时保留原默认。回显/backend capability 独立声明 `max_speakers/system_cap/ready/reason`：`system_cap=32` 是身份容量，`max_speakers` 是已通过质量验收的每个连续分人会话参与说话人数上限；未验收时为 null 且生产 not-ready。不能把工程 cap 当质量认证人数或同时重叠发言人数。
- [ ] Services 注入后端 registry，以 session 冻结配置选择 factory；仍提供原 `ActivitySession.append/updates/finish/cancel` 接口。动态只能在声明配置与本地 ready 成立时创建；每次捕获只运行所选一种分人后端。
- [ ] 测试 5/16/32 slot、33 越界、scores None、Sortformer 错维度仍拒绝、未知 backend、同代次改 backend、旧 epoch、capability ready 不一致；所有既有四人 fixture 仍成立。
- [ ] 运行：`uv run --no-sync pytest --no-cov tests/test_meeting_diarization_contract.py tests/test_diarization_attribution.py tests/test_diarization_worker.py tests/test_capability_snapshot.py`。

**Done:** 四槽限制只留在 Sortformer adapter；内部动态活动与现有 text_revision/metadata_revision 机制能对接，公开事件仍只含匿名标签和时间证据。

## D2 — 纯 session 匹配器与防污染规则

**Files:** 新建 `native/diarization/Sources/SpeechRailDiarizationProtocol/SessionSpeakerMatcher.swift`；扩展 protocol self-test；新建合成匹配 fixture `tests/fixtures/meeting-speaker-matching.json`。

**Consumes:** 本窗局部 cluster 的归一化 centroid、非重叠支持时长/区间，以及 overlap 中已确认的匿名活动。**Produces:** local→global ID 或 unknown、原型更新、有限诊断，不输出向量。

- [ ] 确定初始工程容量：32 个身份、每身份至多 3 个 256D 原型，全局 slot 从 0 递增且不回收；只有 RAM 中保存这些向量。所有数字向量校验 finite、维度和非零范数，不能写日志。匹配统一使用归一化向量的 cosine distance `1−dot`（范围 [0,2]），身份距离取其原型的最小值；不混用 SDK AHC 的 Euclidean 阈值。
- [ ] 每窗先根据 overlap 的高支持已确认活动生成候选锚点，再做一对一最小成本匹配，加入 unmatched 虚拟节点。声学距离超过 `match_distance_max` 或第一/第二候选距离间隔小于 `match_margin_min` 时拒绝；锚点与声学证据冲突也拒绝，不能只因时间重叠就硬连。
- [ ] 两个同时活动的局部簇不能映射到同一全局 ID；首版全窗一对一保持保守，疑似同人过分裂只保留 unknown/后续窗口再验证，不自动合并已发布 ID。排序与 tie-break 固定，匹配结果与输入字典顺序无关。
- [ ] unmatched 有至少 1500 ms 唯一、非重叠语音才可创建新 ID；较短证据暂存候选并在最近 60 s 内累积，不能把重复 overlap 音频算两次。到 32 人转 `speaker_capacity` unknown，不淘汰旧 ID、也不并入最近主讲人。
- [ ] 更新原型要求至少 2000 ms 新的非重叠语音且距离门更严格 `update_distance_max < match_distance_max`，支持区间按全局样本去重。固定 `prototype_policy=anchor_farthest_v1`：首次创建身份的合格 centroid 为不可替换 anchor；新候选既须通过最近原型的 update 门，也须与 anchor 的距离不超过 match 门，阻止逐窗链式漂移。其余至多两个原型从“旧候选＋本次合格候选”中确定性选择：先取离 anchor 最远者，再取与已选集合最小距离最大者；距离并列时保留来源区间更早者、再按创建序号。向量选中后不做隐式均值漂移，只存三个代表与有界支持摘要。SDK qualityScore/cosine 不是概率 confidence，不作百分比宣传。
- [ ] 阈值没有来自本地语料的可用默认值：在 D6 开发集校准、存入版本化 `SpeakerMatchingPolicy`，至少包含 `version/prototype_policy/match_distance_max/match_margin_min/update_distance_max/minimum_new_voice_ms/minimum_update_voice_ms/candidate_retention_ms/model_snapshot/calibration_digest`。未带已校准 policy 的动态后端不可用于生产 ready；fake 使用合成易分向量与显式测试阈值，不能拿它证明真实准确。
- [ ] 测试：局部 S1/S2 每窗调换、第五人 2 s 插话、0.4 s “嗯”、两个相似声线、同人离席 20 min 后返回、overlap cannot-link、重复窗不增加支持、第四原型与距离并列时确定性保留、anchor 不替换且链式漂移被拒、恶意 NaN、cap 溢出、参数缺失。主讲人身份不能被短句带偏。
- [ ] 运行：`swift run --package-path native/diarization SpeechRailDiarizationProtocolSelfTest`。

**Done:** 匹配器完全不依赖模型、文件和网络；合成反例确定性通过。真实阈值与召回在 D6 决定，不偷偷采用 SDK streaming SpeakerManager 的不同距离阈值。

## D3 — RAM 滚动推理与活动稳定水位

**Files:** 新建 `native/diarization/Sources/SpeechRailDiarizationWorker/MeetingDiarizationWorker.swift`，修改同 target 的 `main.swift`；新增 `SpeechRailDiarizationProtocol/MeetingWindowPolicy.swift`；`backends/diarization/meeting.py`；新建 `tests/test_meeting_diarization_session.py`。

**Consumes:** 原始连续 16 kHz PCM（不是 VAD 过滤后的重播片段）。**Produces:** ActivityUpdate，水位与真实 accepted samples 一致。

- [ ] 每累计 10 s 触发一次，使用最多最近 30 s；开头用实际 10/20 s，不能把补零当输入。stable cutoff 初始为 decoded_end−10 s；停止时对剩余真实音频运行尾窗，再将已处置范围推进到 accepted。30/10 组合是待质量选择的起点。
- [ ] 单个 active 推理和一个最早到期 pending 意图，PCM 与主线环/副本一起计费；snapshot 不得跨源/epoch。模型 prepared/audioSource、chunkEmbeddings 处理后释放，只保留 D2 的有界原型/候选。
- [ ] 使用 SDK 自动人数与 constrainedAssignment；取输出 segments 的实际区间和 centroid，归一化后交 D2。可选 chunkEmbeddings 仅作为 worker RAM 诊断/校准，不发 IPC；`embeddingExportPath=nil`，不得导出。
- [ ] 私有 native IPC 为 dynamic 声明 `protocol_version=2` 和 backend，用 `active_slots` 及明确的 stable/processed 水位表达区间；Sortformer adapter 的原 v1/四分数仍独立严格校验，不把两种 payload 通过猜测混用。
- [ ] 重叠窗只替换 `[previous_stable, decoded_end)`；更早上下文只作为身份锚，不回写稳定区间。若跳 tick/积压使实际 snapshot 起点晚于 previous_stable，先将缺失范围处置为 `activity_gap` unknown，再接新窗，不能制造活动证据。新区间应用后才能推进 stable，未知也须带原因。使用真实 token alignment 和既有 attribution ledger 给文本归属，不能按整条 ASR 选多数发言人。
- [ ] append 只做有界接纳，不等待一次全窗模型推理；updates 由独立消费 task 提供。积压超过保留预算时先结束该辅助区间为 unknown/failed，不丢掉正文；不能依赖当前 5 s append 等待超时充当模型计算预算。
- [ ] fake 覆盖 10/20/30/40 s 窗形状、跳过一个计划 tick、旧窗晚到、stop 末尾 1 sample、超过环容量、推理仍忙时 cancel、source switch、stable 之后禁止改写、60 min 固定容量。
- [ ] 运行：`uv run --no-sync pytest --no-cov tests/test_meeting_diarization_session.py tests/test_diarization_session.py tests/test_realtime_auxiliary_attribution.py`，并运行 native self-test。

**Done:** 样本/水位/原型生命周期由 fake 完整证明；真正模型 quality/readiness 仍待 D6。ASR PCM 的释放边界取所有 auxiliary 借用的最早需要，不能 ASR seal 后立即删掉动态分人还需的 30 s。

## D4 — 资源、取消与诊断

**Files:** `application/services.py`、`config/__init__.py`、`service/preflight.py`、`observability/metrics.py`、`runtime/diarization_worker.py`；新增 `tests/test_meeting_diarization_resources.py`。

- [ ] 动态与 Sortformer 同时配置不表示同时驻留；会话前固定选择，正常释放精确所选 worker。仅已声明的 lane/resident 允许与 ASR/aligner 并行，未测峰值时按既有 fail-closed 串行。
- [ ] native detached CoreML task 取消不当作已经停止；close/finish ack 或精确 child reap 完成前保留资源和 PCM。与现有服务生命周期共用受管理 PID，不模糊匹配或 pkill。
- [ ] reason 有限：`identity_uncertain/speaker_capacity/activity_gap/audio_expired/model_not_ready`；区分声学 unknown、没有对齐和后台故障。只报匿名计数/阶段耗时/水位差，不含 embedding/原文/绝对目录。
- [ ] 测试缺峰值串行、lane 不一致拒绝、关闭 waiter 取消、reap 失败隔离、EOF 超时、跨 epoch 结果、一个 worker 构造计数；运行 `uv run --no-sync pytest --no-cov tests/test_meeting_diarization_resources.py tests/test_diarization_worker.py tests/test_service_preflight.py`。

**Done:** 质量验收前资源与失败出口完整，没有靠保留全部音频/embedding 规避跨窗问题。

## D5 — App 能力接线和多人展示

**Files:** `SpeakerLabeling.swift`、`MeetingSession.swift`、`MeetingSessionProductionWiring.swift`、`MeetingViewSpeakerLabeling.swift`、`macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift`；新建 `macos/SpeechRailApp/SpeechRailApp/SpeakerScopeBinding.swift`、`macos/SpeechRailApp/SpeechRailMacControlTests/MeetingSpeakerCapacityTests.swift`，同步测试/target 文件清单，与主线 T5/T7 串行。

- [ ] 将固定 `SpeakerLabeling.maxSpeakers=4` 改为会话回显的能力限制；新标签用确定性 allocator，不对 codepoint 加 32 生成标点，也不能满员后返回最后一人标签。人工“拆出”到上限必须明确拒绝，不误标。
- [ ] 新会议请求 backend=meeting_dynamic，未 ready 时明确提供“先记录文字”的功能降级；不得以 Sortformer 四槽结果冒充已启用多人分人。默认不呈现 32 个空人名行，只呈现实际匿名身份。
- [ ] 增加纯 `SpeakerScopeBinding`：一次连续捕获开始时生成 UUID scope，冻结绑定 `(record_id,connection_generation,server_session_id,input_epoch)`；服务 `S<n>` 写库为 `d<scope的32位小写hex>:S<n>`，后续同 scope 严格复用。人工拆分用 `d<scope>:U<n>` 独立递增空间，不能抢占尚未出现的服务标签。界面通过既有 display name/首次出现序号展示“说话人 1”等普通名称，不展示不透明 key。
- [ ] 重连、clear 或 source switch 重建分人后创建新 scope，保留旧行与别名但不自动认定跨 scope 同人；允许既有人工显示别名合并。引擎 32 身份 cap 按当前 scope 计算，历史 scope 的已存标签不扣新引擎容量，UI 不把整条会议历史误当一个模型槽表。scope 由既有 label 字符串承载，不引入 PCM/embedding 持久化或会话恢复协议。
- [ ] 主讲/其他参与者只在报告中按参考时长分组，UI 不擅自对四个标签加特殊身份；短句未确认先显示“未确认说话人”，正文继续正常展示与保存。
- [ ] 归属到达后按原 text/metadata revision 更新已有单元；保存使用既有字符串 label，不新增数据库枚举。旧 App 只读带 scope 的新标签、匿名显示名与来源快照必须通过临时库验证。
- [ ] 覆盖第 5、26、27、32 个 label，label 乱序/重复、cap 达到后的拆分、拆分 U1 后服务新 S5、同名显示别名、记录切换、归属迟到、5+ 列表滚动；专测重连/新 epoch 再出现 S1 不修改旧人的姓名/归属。运行 `swift test --package-path macos/SpeechRailApp --filter MeetingSpeakerCapacityTests`、主线 lifecycle suites、测试清单检查和包装 App build。

**Done:** 无四槽假设残留在动态路径；普通用户不必先设置技术参数，空模型/超限/unknown 文案清楚，schema v13 可读。

## D6 — 配对质量、制品和启用验收

- [ ] 取得制品准备和模型实测的有效授权后，按 D0 manifest 准备并核验本地完整文件/哈希及运行加载；不把本文件视为操作授权。
- [ ] 先固定 30 s/10 s，在开发集按 cosine distance 的明确单位搜索 match/update/margin：首轮候选 match 0.15/0.25/0.35/0.45、margin 0.03/0.06/0.10、update 为 match 的 0.5/0.7，均只是搜索起点。先淘汰 known 正确率不足 95% 的组合，再按总体覆盖和其他参与者最差覆盖选择；没有可行组合就 no-go。随后逐项比较最低支持和 20/30/40 s 窗、10 s hop（40 s 需重核 60 s 环与 PCM/辅助预算）。固定 policy digest 后才解锁验收集；不同时调整 ASR 与分人多个因素。
- [ ] 语料重点包含“3–4 位主讲＋2–6 位短插话”，并覆盖 ≤4、5–8、9–16 人、相似声线、远音、回声、重叠与离席返回。人工说话人参考整场统一匿名，不因切窗重标。
- [ ] 采用 spec §9.8 的整场最优映射、DER/JER/覆盖与已标正确率；额外报告主讲人 label 跳变、其他参与者被误并入主讲人、每人已标覆盖。全部 unknown 或只标主讲人不能通过。
- [ ] 初始启用要求：整体 known≥90%、known 正确率≥95%；前四位主讲 known≥95%；其他每位至少 2 s 合格发言者 known≥80%。短于 2 s/重叠单列，仍留在总体分母。真实测量前这些是目标，未达则 no-go，不事后改门。
- [ ] 与 Sortformer 比较 ≤4 人非退化；5–8 人以人工真值和主讲/短插话门为准，不能以胜过不适用的四槽模型作为唯一门。9–16 人未验证则不列入认证范围，32 cap 仍只是保护。
- [ ] 30–60 min 联合 ASR 压力测完整 resident/峰值、每 hop 计算与活动延迟、RAM/候选中心上限、停止后的最后归属与 Store/source seal。分别记录正文定稿和说话人稳定时延。
- [ ] 全部达到后，会议多人成为独立可启用能力；安装/启停/UI 按当时授权与专项 skill。回退先关闭 dynamic 能力并保留文字、未知状态和数据库记录，不复写现有身份为四槽结果。

**Done:** 主线 T8 与 D6 共同支持会议“文字＋多人归属”完成结论；如果该固定 SDK 路线不足，保留证据重新选型，不宣称交付已经完成。

## 自审与证据边界

本文依据当前代码、固定 SDK 源码、公开模型卡/API 元数据编写；新文件与测试均尚未实现。D0–D5 可使用 fake 和只读本地构造先完成，生产阈值、resident 与质量须 D6 实测。构建/运行命令执行时以锁定依赖和实际 target 清单核对；不得因计划包含命令就报告已通过。
