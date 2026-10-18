---
title: "SpeechRail 测试与验收"
status: active
version: "3.3.29"
date: 2026-10-18
---

# SpeechRail 测试与验收

## 自动化门禁

本地与 GitHub 的平台无关 `Quality Gates` 共用同一入口：

```bash
cd <path-to-SpeechRail>
# PR 验证前先同步 base ref；这里检查已提交差异及当前暂存/未暂存修改。
bash scripts/ci_quality_gate.sh --base-ref origin/main
```

该入口使用 `uv sync --locked --extra dev --extra mcp`，随后以 `--no-sync`
执行 Ruff、Mypy、版本一致性、OpenAPI lint、用户文档、MCP、macOS 测试清单、macOS 路由契约及分人契约回归，
任一步失败立即返回失败。质量检查不构建 native worker；真实制品仍由 Python 测试/打包门禁构建。
不指定 `--base-ref` 时只检查当前工作区与暂存区空白，不能证明已提交的 PR 差异通过。

质量门禁通过不等于所有 CI job 通过。按改动范围另外运行对应测试或构建：

```bash
uv run --extra dev pytest
swift test --package-path macos/SpeechRailApp
bash scripts/macos_app_build.sh --configuration Debug
```

`macos_app_build.sh` 在创建构建产物前也执行测试清单检查，避免新增 SwiftPM 测试未加入
Xcode 单测 target 却得到本地 App 构建成功。SwiftPM 测试、App target 构建和 Xcode 测试清单
是不同检查；PR #341 的差异分析与证据见 [本地与 GitHub CI 一致性](ci-local-parity.md)。

包含 Swift Testing 的定向运行显式传 `--enable-swift-testing`，并核对输出中实际发现的 suite 与用例数；退出码 0 或只有 XCTest 汇总不能证明新 suite 已执行。App 性能回归按[性能观测与回归](macos-app-performance.md)检查容量、操作次数、保存回执和取消到实际退出，不用 CI 墙钟或一次 CPU 读数作性能结论。真实音频/模型基准和接管前台的 UI 自动化分别取得相应授权；纯模型锚点测试不代替实际滚动、选择和复制交互。

GitHub Actions 使用同一套锁定依赖门禁：`quality` 运行 Ruff、Mypy、版本一致性、OpenAPI lint、OpenAPI 路径对齐、MCP 工具面（`tools/list` / `resources/list` / 文档 / skill manifest）对齐、分人契约回归和差异空白检查；`test` 在 `macos-26` 的 Python 3.14.7 环境中构建一次 wheel。`scripts/ci_python_gate.sh` 让非 wheel 测试与构建并行，随后通过 `SPEECHRAIL_WHEEL_PATH` 让 wheel 测试消费该制品；两段 coverage 合并后仍强制 80% 门槛，任一段失败均阻止 artifact 上传。`swift-tests` 和 `macos-app` 使用独立的 `macos-26` arm64 runner，分别执行完整 SwiftPM 测试及 Xcode App 构建，不运行 UI 自动化或重复执行 Xcode 测试。`Gate Summary` 必须等待并验证每个选中的 job；被选中的检查意外 skip 也会失败。`package` 下载已测 wheel，只做压缩包、Darwin CoreML native worker 和 checksum 校验后上传，避免重复同步依赖和构建。普通 CI 与 tag Release 的 `package` 都使用 `macos-26`。Ubuntu 仅承载平台无关的 Quality Gates，不代表产品运行支持。CI workflow 同时支持普通 push/PR 和 Release workflow 的 `workflow_call`，Release 不重复维护 Python 检查命令。

编译缓存按平台、工具链及锁定依赖隔离，只为内容未变的跟踪输入恢复时间戳；源码修改仍触发重新编译。Xcode 构建通过仓库包装脚本执行，结束时注销并删除临时 App 包，只保留可重用编译输入与输出。uv 使用官方缓存裁剪，不继续恢复旧的整目录大缓存。耗时口径、实测范围及 `<50%` 验收条件见 [CI 效率分析](ci-efficiency.md)。

非 wheel pytest 由 `pytest-xdist` 使用两个进程按文件调度；同一测试文件的用例和 fixture 保持在同一进程，worker 自动重启关闭。`pytest-cov` 先合并两个 worker 的 coverage，wheel 阶段再追加并检查原 80% 门槛；不因并行执行而跳过用例、降低门槛或重试失败。

音色的流程、并发和路由测试使用 fake backend；仅显式导入 `voice_test_fixtures` 的模块会自动启用音高 fixture，每个用例后恢复真实函数，避免每次状态机断言都重复执行昂贵的自相关计算。真实音高估计仍由专门的声学门禁测试验证，输入质量和流程安全断言继续执行；这些流程测试不代表真实模型质量验收。

版本 tag release 还会并行构建 unsigned arm64 DMG。发布前核对 tag、App bundle 版本、App 架构、DMG 可挂载内容和 wheel/DMG checksum；最终 Release 资产为 wheel、`SpeechRail-<version>-macOS-arm64.dmg` 和 `SHA256SUMS`。GitHub 上生成的 DMG 不做 Developer ID、notarization 或 staple，因此不能替代本机正式分发验收。

### 会议评测来源锁

`examples/perf/prepare_meeting_evaluation_manifest.py` 读取仓库外的 schema 2 catalog，核对来源声明和本地制品摘要，生成 `development.json`、`holdout.json`、`diagnostic.json` 与 `split-lock.json`。它不解码音频、不推理、不下载文件，不提供质量或人数认证。旧 `prepare_meeting_corpus.py` 的 schema 1 输出可提供已核验的音频/参考摘要，但必须补齐下列来源信息，不能直接当作新认证 manifest。

catalog 顶层仅含 `schema_version=2`、`independence_level`、`sources` 和 `fixtures`：

| 对象 | 必需字段和语义 |
|---|---|
| `sources` | 以匿名来源 ID 为键；每项含 `dataset`、`partition`、`recording_sha256`、`derived_from`（直接父来源 ID 列表）、`global_speaker_ids`（已知全局人员的匿名 SHA-256 ID 列表；未知为空） |
| `fixtures` | 每项含匿名 `id`、`source_meeting_id`、`derived_from`（完整祖先 ID 排序列表）、非负 `channel`、`split`、`sample_kind`、`scene`、`speakers_count`、非空 `transform`、非空 `reference_label_policy`、`artifacts` |
| `split` / `scene` | 分别为 `development` / `holdout` / `diagnostic`，以及 `near` / `far` |
| `sample_kind` | `natural_single`、`natural_meeting`、`continuous_excerpt`、`derived_single_track` 或 `derived_mix`；派生重混音/单轨，以及单人连续截取仅作 diagnostic，不充当自然单人认证数据 |
| `artifacts` | 必需 `pcm`、`activity_reference`、`text_reference`，各含相对 catalog 所在目录的 `path` 与实际文件 `sha256`；可选 `asr_sidecar` 还须带 `producer_identity_sha256` 和 `timing_evidence_sha256` |
| `independence_level` | 缺完整全局人员声明时只能是 `meeting-disjoint`；`speaker-disjoint` 要求涉及的全部来源声明非空全局人员 ID。声明仍须人工核实，不代表工具从声音证实身份 |

来源、祖先、相同原始录音摘要及已知全局人员连接成组。holdout 不与 development/diagnostic 共享组或 PCM；同组的开发诊断视图可以并存，但不增加独立组数。相同 PCM 若被声明为不同组，工具拒绝，要求先纠正来源。`test`、`Eval_Ali`、`R004`、`holdout` partition、Eval_Ali dataset 及来源 ID 中的 R004 标记均作为封存来源，约束传递到派生组，不得进入开发或诊断。工具只能核对已声明的来源关系，无法自动发现未声明的人员或隐瞒的派生关系。

固定 seed=1717 的组顺序、参考规则、处理变换、通道、scorer policy 和制品摘要进入 manifest。`split-lock.json` 使用 `canonical_digest` 的规范 JSON SHA-256，不能用格式化文件的原始字节摘要代替。默认要求连续 1–4 人层：每层开发来源至少 6 组，预锁留出池至少 `max(12, 2 × 开发池可用的最大检查点)`（检查点为 6/12/18/24） 组；不足时输出 `readiness=insufficient_sources`。`source_pool_locked` 仅代表声明来源池可供后续调度，`certified_max_speakers` 始终为 `null`。每层 6/12/18/24 的共同前缀筛选与一次性留出须由后续执行器实施；准备工具不签开发收据、不消费留出。

```bash
uv run --no-sync python examples/perf/prepare_meeting_evaluation_manifest.py \
  --catalog /path/to/catalog.json --output-dir /path/to/new-lock-directory
```

输入制品必须在 catalog 目录内，拒绝符号链接和路径逃逸；输出目录必须位于仓库外且尚不存在，不覆盖已有锁。输出 manifest 保留相对路径，后续执行器须显式使用原 catalog 目录作为 artifact root，并重新核对文件摘要。CLI 验证错误不打印私有路径。确定性测试使用人工文件：`PYTHONPATH=src:examples/perf uv run --no-sync pytest tests/test_meeting_evaluation_manifest.py --no-cov`。

`meeting_candidate_schedule.CommonPrefixSchedule` 消费已锁定的单个人数层来源顺序、manifest/scorer 摘要和 C1/C2 身份；1–4 人还必须有 C0，5–8 人不虚构四槽 C0 对照。初次请求 6 组，仅在 6/12/18/24 检查。每轮必须提交 C0 及全部存活候选、相同顺序的完整来源前缀和匹配的候选摘要。点值失败永久淘汰，区间证据不足时所有存活候选共同扩样；C0 的绝对门失败不淘汰对照。缺观察停止比较，不丢失败组后继续；到上限或无下一完整前缀时终止，只有在当前共同前缀已通过的候选仍可进入后续选型。

调度状态为不可变快照，恢复时以独立载入的来源/候选锁为基准重放每轮校验，不接受改身份、改变组顺序、复活候选或在终止后追加。`eligible_across_strata` 对所有连续人数层取同一候选的交集，拒绝跨层混用候选/scorer/manifest；pending、缺失或无共同候选不能形成完整人数范围。调度器只处理上游评分结论，不运行模型、不选择 DER 排名、不签收据；实际执行器仍须核实评分报告、来源和运行身份，完成产品延迟及独立留出。对应确定性测试为 `tests/test_meeting_candidate_schedule.py`。

### 会议候选活动与正文证据

`meeting_candidate_evidence.CandidateEvidence` 复用生产 `AttributionLedger` 与显式归属策略，以 session-scoped `S1`–`S8` 标签连接实际活动和 ASR 完成项。输入不包含参考文字、参考 speaker 或参考边界；`CompletedText` 必须带实际已接受音频中的整数样本区间，sequence 连续。

没有词时间证据时，完成项按整个实际 ASR 区间作 utterance 归属；有词证据时逐词归属，拒绝缺文字覆盖、越界、缺时间或把整句重复时间冒充词时间。字符切片保留所有原始空白、标点和正文，不插值时间、不改写文本。歧义 overlap 和已淘汰的历史保留原文并输出 unknown 及原因；未知不强行归给主讲。

活动必须是连续、稳定、不可回改的样本区间。跨 chunk 同 slot 活动合并成连续区间，同时保留 overlap 和 10ms 插话；无 min-turn、bridge、ghost 或 VAD 删除。默认 RAM 历史为 60 秒，待归属文字最多 262,144 字符，ledger 单元最多 4,096 个，活动帧最多 8,192 个，限制进入候选身份。稳定历史按水位压缩，旧完成项不能凭缺失历史恢复身份。

完成必须覆盖全部已接受音频且无未归属单元。中止或不完整 finish 将待处理原文以 unknown 发出，只关闭已实际处理的活动区间，不给未处理尾音补造活动。重复 finish/cleanup 幂等。`SpeakerSpan` 与 `AttributedText` 分别供时间评分与文字评分；完整事件只能进入仓库外原始评测制品，报告和日志不含原文。单独归属机制通过不代表真实模型或生产质量通过；fake 测试为 `tests/test_meeting_candidate_evidence.py`。

### 会议候选有界回放

`meeting_candidate_runner.run_candidate_stream` 接收有界 PCM iterator、调用方的 `activity_factory`、`FixedTextReplay` 和异步原始制品 sink。factory 必须复用同一组合根的 governor/owner；运行器不创建另一服务或 governor，也不提供跨进程排他。每包最多 16,000 个 PCM16 样本，活动消费者在输入期间持续运行，不等整场供给完再读更新；慢 sink 有时限，失败、总 deadline 或取消会加入消费者退出，并调用共享 exact-child lease 回收。回收未确认返回 `candidate_cleanup_incomplete`，不能作为成功或空闲资源。

`iter_wav_pcm` 只读仓库外的 16kHz、mono、PCM16 WAV，格式与空输入在打开 worker 前校验，单次最多读一秒。文件读取在线程中完成，取消时先加入当前读取再关闭文件；不收集整场 PCM。调用方仍须用来源锁在执行前后核对文件摘要和真实运行身份。

`FixedTextReplay` 是有一项前瞻的生产者顺序 iterator；`ScheduledText` 的 `ready_after_sample` 与 `finish_only` 控制 ASR 完成项何时可进入归属，不向模型注入参考文字或边界。它用于 C0/C1/C2 固定 ASR 对照，不能代替当次真实 ASR 推理。每批完成项最多 4,096 个、262,144 字符，不接受超过实际 accepted samples 的时间；完整原始事件只写仓库外 sink，摘要仅保留计数和文字摘要。

`input_mode=throughput` 用于尽快重放；`realtime` 按累计整数样本的 1× 时钟供给，记录输入迟到，测试注入时钟显式标为 `injected`。阶段事件记录 ASR 文字可用、活动水位、append 总耗时及 finish 边界。注入 `PhaseTrace` 的 session 另提供实际 admission/load/request/reap 边界，定义见下节。固定 sidecar 的 `clock_scope=diarization_with_fixed_asr_sidecar`、`joint_asr_latency_observed=false`、稳定标签 P95=`null`，不能用于 15 秒联合产品门。

完成摘要的 `complete` 只证明供给/处理覆盖与原文字符保留。运行器自身不认证文件、ASR sidecar 或 runtime 身份，相关 verified 字段均为 false，`certification_eligible=false`、`verdict=diagnostic`、`certified_max_speakers=null`。锁定来源与身份检查、评分/调度接线、开发/留出 CLI、真实双路时钟和收据签发由后续执行器完成。候选 spec 已绑定这套归属配置、ledger 和回放源码，变更须重新生成 spec；预检仍不执行 worker。

fake 测试为 `tests/test_meeting_candidate_runner.py`，包含单项队列的供给/消费、真实 session 类与 fake worker 的 owner 集成、失败隔离、取消、慢 sink、deadline、提前关闭、样本时钟和 WAV 边界。它们不证明模型质量、实际 1× 负载或真实 footprint。

### 分人阶段耗时观测

`CoreMLActivitySession` 和 `open_candidate_session` 可接收可选 `PhaseTrace`。默认关闭，不读取时钟；启用后只在 RAM 写入固定标签和数值，不在计算租约内执行 sink、文件 I/O 或异步制品回调。注入 clock 必须同步且不阻塞，只用于诊断或测试。runner 在每次 append、finish 及清理后排空事件，sink 失败不能返回成功，精确 child 清理优先完成。

`compute_queue` 从请求计算租约到实际准入；`load` 包含真实 worker start/preflight；`infer/finalize` 分别覆盖实际 append/finish 请求；`close` 覆盖加入 start、精确 child 关闭及 owner 释放或隔离确认。它们包含 IPC 与 native 等待，不是 accelerator kernel 时间；取消时区间可能重叠，不得直接求和当总计算耗时。事件包含 operation、through_sample、host monotonic 起止、duration、completed/cancelled/failed 和 clock_source，不含正文、音频、路径或身份。

默认最多缓存 256 项；调用方可配置 1–65,536 项。未及时排空导致溢出、非法/倒退/抛错时钟会永久标记观测不完整，不阻断模型执行及回收。`complete` 仅表示 trace 无丢失、无未结束 span 且有事件；`required_phases_observed` 还要求五类阶段均有 completed 记录。runner 的 `phase_trace_observed` 合并这两个条件，不能证明实际模型身份或成功质量。注入时钟标为 `injected`，固定 sidecar 的联合时钟和 P95 仍未观察。fake 回归见 `tests/test_diarization_phase_trace.py`。

### 固定 ASR sidecar 输入

`meeting_asr_sidecar.open_asr_sidecar` 将来源 manifest 中的 `asr_sidecar` descriptor 接到 `FixedTextReplay`。调用方提供仓库外 artifact root、锁定的 PCM SHA-256 和实际总样本数；descriptor 字段严格为 `path/sha256/producer_identity_sha256/timing_evidence_sha256`。路径相对 root，不接受符号链接或目录逃逸；文件限 256 MiB、每行 65,536 bytes、正文记录最多 100,000 项。文件内容仅用于外部评测，不进入报告或日志。

格式为 UTF-8 JSONL，每行必须以换行结束，不接受重复键。第一行为以下字段构成的 header：

| 字段 | 值或含义 |
|---|---|
| `schema_version` | 整数 `1` |
| `kind` | `fixed_asr_sidecar` |
| `sample_rate` | 整数 `16000` |
| `pcm_sha256` | 同一锁定 PCM 文件的摘要 |
| `producer_identity_sha256` | 与 manifest 相同的冻结 ASR 生产者身份摘要 |
| `timing_evidence_sha256` | 与 manifest 相同的有序时间证据摘要 |
| `timing_algorithm` | `sha256_timing_row_digests_v1` |

后续各行严格包含 `sequence/text/start_sample/end_sample/ready_after_sample/finish_only/units`。sequence 从 0 连续；样本位置为整数，`0≤start<end≤ready_after_sample≤total_samples`，单项实际 ASR 区间不超过 30 秒。生产者可用时刻非递减，进入 finish 阶段后不能恢复 append 阶段。允许没有正文行：它表示已观察到空识别，不能当成缺失 sidecar。

`units=[]` 明确按整句归属。有实际词证据时，每项严格包含 `text_start/text_end/start_sample/end_sample`，以原文字符偏移与实际样本时间描述；拒绝词外漏字、越界、空区间和重复整句时间网格。输入不含 speaker、参考边界或参考正文，不接收额外字段。匿名 unit ID 由读取器生成，正文空白与标点原样保留。

`timing_digest` 定义确定性摘要：SHA-256 初始输入为 ASCII 的算法名及一个 NUL byte；随后依序追加每个正文行除 `text` 外全部字段的 canonical JSON SHA-256 原始 32 bytes。canonical JSON 使用 `sort_keys=True/separators=(",", ":")/allow_nan=False`。header 不进入此摘要，避免自引用；整个 JSONL 的文件 SHA-256 另由 descriptor 锁定。摘要绑定时间与字符偏移，不能通过只更新正文文件摘要掩盖时间改变。

读取器先以有界逐行扫描验证全部记录、内容及时间摘要，再从同一个打开的 descriptor 回放；每次读取与 EOF 校验文件身份和修改状态。未读到有效 EOF、部分消费、替换文件或读取中修改都不能取得 proof。正常 context 退出要求完整消费；异常退出关闭文件并保留原异常。打开/预检为同步文件 I/O，执行器应在线程中完成；runner 的 `ready/finish/close` 在线程执行，取消须加入在途读取后再关闭 source。

proof 只声明 `bytes_and_timing_verified=true`，保持 `producer_provenance_verified=false`、`joint_asr_latency_observed=false` 和 `certification_eligible=false`。它验证文件与预登记关联，不证明生产者声明为真、PCM 实际解码身份、当次 ASR 时钟或模型运行身份。CLI、评分/调度与来源真实性验证仍由锁定执行器负责；该库不能解锁留出。fake 回归见 `tests/test_meeting_asr_sidecar.py`。

### 开发集回放与检查点执行

`meeting_development_fixture.evaluate_development_fixture` 接收 schema 2 development manifest、对应 split-lock、评分 policy、fixture ID、候选摘要、外部 artifact/output 目录和调用方的 `activity_factory`。它核对 manifest/source catalog/scorer 摘要和作用域，验证评分依赖版本、自然样本分类、文件摘要及完整 WAV，再构造第一个 worker；不接受 holdout manifest。WAV 是已按 manifest 记录的来源通道和变换准备好的单声道制品，执行器不另行选轨或重混音。所有 PCM 预检与回放均逐包有界，不保存整场音频。

活动参考与正文参考分别为 UTF-8 JSON 文件，最多各 16 MiB、100,000 段；不接受重复键。顶层严格包含 `schema_version=1/sample_rate=16000/total_samples/segments`，三个数值均为整数且总样本数须与 WAV 相同。每段严格包含 `start_sample/end_sample/speaker`，正文参考另含非空 `text`；半开样本区间非空且位于实际 WAV 范围，参考 speaker 预先匿名为 `R1`–`R8`。活动参考不得含正文，正文时间不得代替连续活动边界。文件准备与人工参考核验须在执行候选前完成。

参考只进入评分器；`activity_factory()` 不接收 manifest、参考文字、标签或边界，固定 ASR 只来自独立 sidecar。实际输出事件分别转换为活动区间和带标签正文，交给 `score_meeting_quality`。执行前后及报告提交前均校验全部输入文件摘要和 inode/大小/修改状态；失败、修改、慢 sink、预算超限和取消不能生成完成结果。sidecar 打开/完整预检、回放读取、评分与制品写入均在线程执行并加入取消清理；取消发生在 context entry 时也须关闭已经打开的文件。

每个输出目录独占创建、权限 `0700`；`attempt.json/events.jsonl/result.json/failure.json` 权限 `0600`。原文只进入仓库外 `events.jsonl`；该文件限 256 MiB，活动和文字评分各限 100,000 段。先写并同步 `result.partial.json`，完成最终输入核验后以不覆盖已有文件的原子 link 提交 `result.json`；取消或失败留下 attempt/partial/failure 供审计，不能据此继续签收据或覆盖重跑。结果只含匿名 ID、制品/政策摘要、计数、评分、诊断时钟和来源条件，不含正文与绝对路径。

`evaluate_development_checkpoint` 消费不可变 `CommonPrefixSchedule` 的 pending request 和固定候选摘要/工厂映射。1–4 人包含 C0，5–8 人不伪造四槽对照；完整预检共同前缀后，串行执行每个存活候选的全部来源组及其同层 fixture，上一 session 回收确认后才构造下一 session。完整配对完成后，按来源组计算产品汇总及对 C0 的 DER/cpCER 配对不退化门，并分别报告 near/far；缺场景明确 `not_observed`。任何部分失败不生成 `checkpoint.json`，也不修改原 schedule；成功时返回下一不可变状态，后续扩样继续遵循共同前缀与不可复活规则。

检查点预检只跨会议保留文件指纹，不持有整个来源池的参考正文；逐场评分后只保留脱敏结果。该执行器验证实际输入与输出覆盖，并连接产品门和调度，仍不证明 activity factory 的真实制品/SDK/运行身份、生产者来源、跨进程排他或联合延迟。`runtime_identity_verified=false/certification_eligible=false/verdict=diagnostic/certified_max_speakers=null` 保持明确；调度的 `passed` 仅表示该共同检查点的评分门通过，不代表唯一候选选型或产品认证。生产组合根须启用并导出阶段观测；联合 ASR 时钟、开发收据签发、跨层选型及共同检查点/留出 CLI 仍需接线。fake 测试为 `tests/test_meeting_development_fixture.py`。

### 候选原生开发入口

`probe_meeting_candidate.py preflight` 只读取候选 spec 和本地文件，不启动 worker。`evaluate-development` 显式执行一个冻结 development fixture 的 C0/C1/C2 原生候选，接 `evaluate_development_fixture` 的来源验证、归属、评分和独占制品写入。控制 JSON 限 16 MiB、必须为对象，拒绝重复字段、非有限数、符号链接和非普通文件。`evaluate-frozen-holdout` 不提供；该入口不替代 C0/C1/C2 共同检查点，不签开发收据或人数认证。

入口要求显式 `--service-port`，使用与 serve 相同的 per-user/per-port 内核锁。必须传入拟排他的实际服务端口；它不能探测或排除其他端口的自定义实例，也不自动启停服务。端口被持有时，在构造 worker 前失败。锁 FD 由精确 child 继承，父进程只关闭自己的 FD，不调用 LOCK_UN；child 未退出时仍阻止同端口 serve/evaluation。未修改服务锁元数据或生产默认 transport；普通服务不传继承 FD。

执行前核对 worker/model/adapter/scorer 字节及文件状态，finish、cancel 与评分后再核验；修改后恢复原内容也因 inode/ctime 等变化而失败。C1/C2 的实际 native preflight 必须确认 SDK、preset、compute units 和 shape，运行中每个 packet 继续校验。C0 固定使用生产四槽 FP16 模型、balancedV2_1、compute units=all、>=0.25 活动阈值和无 consolidation 的解码；模型必须匹配生产固定哈希与 MIL 签名，完整模型目录字节也进入身份锁。C0 通过生产 CoreMLActivitySession 解码，额外拒绝非连续四槽概率覆盖、非法数值或未覆盖 EOF。C0 protocol 1 的 preflight 只声明 ok，不证明 SDK、配置、shape 或构建来源，不能据此升级 runtime_identity_verified。共享串行 governor/owner、精确回收和 `PhaseTrace` 均启用；文件核验和外部 sink 在计算租约外执行。

`candidate_execution` 是封闭的脱敏字段集：记录配置端口排他、原生握手、文件核验及回收确认；不接受额外文字/路径或将 bool 改为整数。模型 revision 来源、真实联合 ASR 与生产认证保持 false，顶层 `runtime_identity_verified/certification_eligible` 也保持 false。摘要与 `result.json` 相同；失败不能落 completed 结果。finish 墙钟包含评测文件核验开销，固定 sidecar 和本入口的 realtime 供给均不能作为真实联合 P95 基准。

下列是需要真实模型/音频运行授权的入口示例；常规 fake 验证不执行它。所有变量均指向已准备的仓库外制品，SERVICE_PORT 为实际拟排他的服务端口：

```bash
PYTHONPATH=src:examples/perf uv run --no-sync python examples/perf/probe_meeting_candidate.py \
  evaluate-development --candidate-spec "$CANDIDATE_SPEC" --worker "$CANDIDATE_WORKER" \
  --model-directory "$MODEL_DIRECTORY" --manifest "$DEVELOPMENT_MANIFEST" \
  --split-lock "$SPLIT_LOCK" --scorer-policy "$SCORER_POLICY" \
  --artifact-root "$ARTIFACT_ROOT" --output-directory "$OUTPUT_DIRECTORY" \
  --fixture-id "$FIXTURE_ID" --service-port "$SERVICE_PORT" --input-mode throughput
```

fake 验证见 `tests/test_meeting_candidate_execution.py` 与 `tests/test_diarization_worker.py`；包含合成 WAV/文字、fake IPC 以及不加载模型的锁继承子进程，不证明 CoreML 模型、真实 footprint 或质量达标。C0 spec 由 meeting_c0.static_c0_spec 只读构造，model-directory 指向含 SortformerNvidiaLow_v2.1.mlmodelc 的外部目录；同一 CLI 按冻结 implementation_id 分派，未知实现拒绝。C0 只参加 ≤4 人质量对照，超过四人不能认证。跨层选型、真实来源与联合身份、收据及留出仍待接线；C0 fake 回归另见 tests/test_meeting_c0.py。

### 原生共同检查点入口

`probe_meeting_candidate.py evaluate-checkpoint` 使用独立初始控制锁，接通 `CommonPrefixSchedule` 与 `evaluate_development_checkpoint`，每次执行一个共同前缀检查点。入口不自动跑完全部检查点，不签开发收据、不打开留出集，也不选择跨层唯一胜者。

初始 JSON 控制锁使用 schema_version=1，字段集严格封闭：

- `speakers_count`：1–8 的整数；来源组顺序取冻结 manifest 对应层。
- `service_port`：本轮持续持有排他锁的实际服务端口。
- `manifest`、`split_lock`、`scorer_policy`：各为 `{ "path": "/outside/path.json", "sha256": "<canonical-sha256>" }`。摘要使用 `meeting_evaluation_identity.canonical_digest`，并非 JSON 文件的逐字节 SHA-256。
- `artifact_root`：显式绝对路径，指向已准备的仓库外素材根。
- `candidates`：固定 C0/C1/C2，每项恰含 `spec`、`worker`、`model_directory`；`spec` 使用同样的 path/sha256 descriptor，另外两项为绝对路径。C0 必须是固定四槽对照，C1 为 fast32、C2 为 fast128，角色和 scorer 身份不能互换。

所有控制 JSON 使用有界严格读取；拒绝未知字段、重复键、非有限数、符号链接和非普通文件。全部注册候选的文件身份和全部共同前缀来源在首 worker 前完成预检。大于四人时仍保留初始三候选锁与制品核对，但不构造 C0；已淘汰候选也不执行。实际存活集合由不可变调度状态计算，不能通过 CLI 自选。

一轮共用一个端口租约、串行 governor 和 owner；各 fixture 复用单场入口的原生握手、阶段观测、评分和精确回收。慢摘要校验在计算租约外执行，完成提交前核对输入、控制与候选文件状态，拒绝异步校验期间可观察的变更。文件状态检查不是跨进程、跨文件的绝对原子认证，输出继续保持 diagnostic，SDK/生产者/联合身份的证据限制与单场入口一致。

以下命令须先获得真实模型/音频运行授权；常规 fake 回归不执行它：

```bash
PYTHONPATH=src:examples/perf uv run --no-sync python examples/perf/probe_meeting_candidate.py \
  evaluate-checkpoint --checkpoint-lock "$CHECKPOINT_LOCK" \
  --output-directory "$CHECKPOINT_OUTPUT" --input-mode throughput
```

恢复时使用同一独立初始锁，把上轮 `checkpoint.json` 的 `schedule` 对象单独保存为外部 JSON，并增加 `--resume-schedule "$RESUME_SCHEDULE"`。恢复会重新核对候选、来源、manifest、scorer 与有限历史，终止状态不能继续；每轮输出目录必须新建且独占。可改写的恢复文件只用于诊断调度，不作为可信收据或认证。任一 fixture、校验或回收失败都不提交 checkpoint.json；先前已完成的单场制品仍可用于排障。fake 回归见 `tests/test_meeting_checkpoint_execution.py`。

### 跨人数层的开发候选选择

`meeting_candidate_selection.select_development_candidate` 是离线诊断入口，接收独立初始 schedules、冻结 development manifest/scorer policy 和最后已完成的共同 checkpoint。声明人数上限要求1到该上限所有连续层均为 passed；恢复有限历史后取各层合格候选的交集，任一层已淘汰的候选不能复活。C1/C2及低人数层C0身份须跨层一致。每层只使用其最终共同前缀，逐项核对全部冻结fixture、场景、来源组、候选、sidecar与评分身份；不追加排名数据，不把重复报告当独立来源。

主排名为collar=0且包含overlap的DER，来自独立scorer报告的错误量/参考量，而非只信任报告率。先合并同一来源、同一场景的片段分子分母，再对来源会议组、near/far场景和人数层等权；cpCER同样合并后用于DER完全相同的同分判定。缺任一要求场景或合格候选DER时不生成排名。候选参考分母须配对一致，缺cpCER不能掩盖DER分母不一致。

配对bootstrap固定seed1717、10000次；按来源在全部人数层×场景中的覆盖模式分块抽取整个来源会议组，同源的跨层片段及near/far共同抽样，保留冻结设计和场景权重。单独片段不能增加独立N，单来源分块不提供可信区间。报告candidate−DER最优者的95%区间与1个百分点非劣界，区间跨0不解释为等价。

当前checkpoint不提供可验证的稳定标签分布和峰值footprint，二者明确not_observed，不使用自报verified或处理耗时替代。因此选择保守依次采用DER、完全同分时cpCER；仍同分或缺同分证据时按固定候选顺序并标注不确定，不按未经观察的“更快”改选。报告绑定selector实现/固定选择策略及每层checkpoint摘要，仍只给出开发诊断候选，不证明已执行质量门、真实运行身份、最大人数或生产认证；所有认证字段保持false/null，真实延迟/footprint和可信收据仍需后续接线。fake回归见 `tests/test_meeting_candidate_selection.py`。

选择命令只读取已完成的外部JSON，不需要模型、worker或服务端口：

```bash
PYTHONPATH=src:examples/perf uv run --no-sync python examples/perf/probe_meeting_candidate.py \
  select-development --selection-lock "$SELECTION_LOCK" --output-directory "$SELECTION_OUTPUT"
```

独立selection lock顶层必须恰含schema_version=1、required_max（1–8整数）、manifest、scorer_policy和strata。manifest/policy都是`{"path":"<absolute-json-path>","sha256":"<canonical-json-sha256>"}`；strata恰含`"1"`到声明上限的键，每层恰含同格式的initial_schedule与checkpoint两个descriptor。initial_schedule必须来自输出前冻结的原始schedule、rounds为空，不从checkpoint倒造。全部JSON使用绝对路径，拒绝重复键、额外字段、bool代整数、符号链接和非普通文件；单文件至多16MiB、全部输入合计至多32MiB。

`meeting_selection_execution` 在加载、排名后、写出后核对全部输入和直接执行/评分依赖源码的摘要及文件状态，所有异步校验完成后再同步核对stamps、无await提交selection.json。修改后恢复字节也因文件状态改变失败；取消加入评分线程，不提交完成结果。输出目录必须是仓库外新目录（0700），结果与partial/failure文件为0600，错误不回显路径/内容；保留未知或既有输出，失败可留partial/failure，不覆盖它们重试。报告只补充输入字节一致性与控制/执行器摘要，不签发development receipt，不解锁holdout，也不升级认证。fake回归见 `tests/test_meeting_selection_execution.py`。

### ASR 正文诊断重放

`probe_meeting_asr_quality` 是 development 诊断库，不提供模型发现、下载、安装态探测或留出执行入口。调用方须先核验外部 manifest/split、来源组和主参考，再构造 `AsrCase`；该对象冻结 SHA-256 身份、16kHz mono PCM16、主参考及重叠顺序，单次输入最多十分钟。它在 RAM 持有这段输入，不能作为生产有界流管线或完整会议采集器。

`replay_production_windows` 连接当前 `AsrWindowCoordinator → WindowAsrSession.decode`，输入只含 PCM 与样本范围。调用方注入当前 VAD/admission、EOF drain 和边界 review adapter；录证器核对实际调用 PCM、attempt/result identity、完整性和封存覆盖。只评分 sealed 正文，不用 preview 替代定稿。延迟 pre-roll 用 retained frontier 表达；未决尾音不当作已确认静音。`replay_long_blocks` 以固定音频网格切分，每块最多 30 秒、context 为空，不使用参考文字或边界形成输入；与生产对照时必须同权重/精度，始终为诊断。

评分身份绑定工具源码、raw/normalized token 化、重叠顺序、编辑路径同分规则与汇总定义；分包、窗口和时限另有 replay policy 摘要。规范化为 NFKC/casefold，CER 保留 Unicode L/N/M；混合 WER 按中文字符和 ASCII 字母数字词分词，raw WER 按空白分词，不冒充独立英文子集验收。插、删、替统计按最短编辑路径，同分依次 diagonal/delete/insert，不能据此证明声学原因。

同一 case 的重复先平均错误数，同源片段再合并分子/分母，最后每个独立来源组等权计算主 CER。≥10% 相对点改善和 candidate−baseline 配对 95% 区间上界<0 使用同一来源组等权估计量；seed/重采样复用冻结 policy。全体 pooled CER 单列，重复和片段不增加独立 N。基线 CER=0、缺无歧义主参考、缺真实 decode、缺帧/重复/超时/截断或未观察 token-limit 均不能通过。关键事实人工复核独立记录，时间戳变化不能计为正文改善。

`RuntimeObservation` 调用前后字段匹配只得到 `execution_identity_matches`，不证明可信来源。没有可信生产评测组合根时保持 `runtime_identity_verified=false/certification_eligible=false/a0_execution=not_observed`；fake 或自报 runtime origin 不升级认证。顺序 feeder 逐包 flush intents，不等价独立 1× 采集/P95 基准；非法、非有限或倒退 clock 拒绝，注入 clock 明示 injected。取消加入 session 关闭，错误输出脱敏，摘要不含原文、PCM 或绝对模型路径。独立 overlap ORC、可信实际 A0、真实错误归因和质量改善仍待后续接线/实测。fake 回归见 `tests/test_probe_meeting_asr_quality.py`。

ready 帧的窗口 cap 来自 engine 实际动态预算字段，而非重复 CLI 入参；0 的既有默认预算语义报告为512。它只补充内部有效配置观测，不证明模型文件字节、vendor package 来源或实际 A0。类型须为32–2048整数，拒绝 bool、字符串和越界值；未提供保持 null，不强制推断。生产 WindowDecodeResult 可携带内部 WindowDecodeObservation，经 window.result 私有 RPC 保留每次 preview/review 的实际 decode_max_new_tokens、generation_max_new_tokens、finish_reason、truncated 和 generated_token_count。decode budget 是 engine 调用入参；preview generation budget 是扣除复用 prefix 后实际传给生成器的 remaining_tokens，token count 在 header strip / prefix merge 前取实际返回 tokens 长度。review 的内部 generation budget 和 count 无可验证观察，保持 null。finish/truncated 缺失保持 null，拒绝类型强制转换、非法范围、额外字段和错误 kind；缺整个 observation 也保持未知。该内部元数据不进入公共 Realtime 契约，不改变解码策略，也不自动升级实际 A0。回归见 test_asr_window.py、test_qwen3_window.py、test_qwen3_stream_decoder.py。

正文诊断报告使用 schema 2，ASR scorer 身份为 asr-body-v2；旧报告须重新执行，不能沿用旧门。RuntimeObservation 只提供调用前后身份与 origin，移除自报 token_limit_hit 入参。每个实际 decode 都记录匿名 attempt 摘要、preview/review、样本范围、实际预算和可见完成元数据；最多4096次，超额在调用下一个 decoder 前失败。仅全部 attempt 明确 finish_reason=eos、truncated=false 且实际 decode budget 不超过冻结上限时，截断证据门才可通过；缺观测、kind 错配、未知终止状态、任一 preview/review 截断均不能被后续成功 review 掩盖。review 的 generation budget/count 仍可为 null，不推断厂商内部行为。未知 finish reason 只输出 other，不回显厂商字符串。报告包含有界逐次记录与其摘要、观察/缺失/未知计数；compare_asr_runs 重新检查记录、计数、范围和摘要，不只信任 quality_evidence_valid。合成执行可以通过诊断证据门，但不能获得生产身份、质量改善或人数认证。

### ASR 开发来源与主参考

`meeting_asr_source.load_locked_asr_case` 复用共同会议 development manifest/split/scorer 的来源验证，读取一个 fixture 的 16kHz mono PCM16 WAV，并构造最多十分钟的不可变 `AsrCase`。现有活动参考、分人文字参考及固定 ASR sidecar 仍按共享来源规则核对，但不进入 ASR 请求，也不作为主参考文字。该入口属于共用会议评测，依赖同一 scorer 环境；它不是独立通用音频导入器。

调用方另传冻结主参考 descriptor（相对 artifact root 的 `path` 与文件字节 `sha256`）。主参考 JSON 必须恰含：

```json
{
  "schema_version": 1,
  "fixture_id": "M0",
  "manifest_sha256": "<canonical-development-manifest-sha256>",
  "pcm_sha256": "<wav-file-sha256>",
  "overlap_order": "unambiguous",
  "main_reference": "<frozen-primary-transcript>"
}
```

`overlap_order` 只能为 unambiguous/ambiguous，主参考可为 null；缺失或歧义不会按时间戳、speaker 顺序或候选输出补造。主参考正文上限10000字符；拒绝额外字段、错误来源/fixture/WAV绑定、重复键、符号链接和非普通文件。主参考应在查看候选输出前冻结；文件一致性不能证明人工来源或冻结时点。

`evaluate_locked_asr_case` 接收已加载来源和负责关闭会话的 replay callback；调用前、退出时 joined 校验全部来源，返回前同步核对文件状态，并确认结果的 case/candidate 摘要。取消也等待来源复核；修改后恢复字节仍因文件状态变化失败。返回的 source_validation 只报告字节核对，human_reference_provenance_verified/source_catalog_provenance_verified 继续 false；它不升级 runtime_identity_verified、实际 A0 或认证。callback 抛出的普通错误统一脱敏。主参考与PCM留在RAM，不写入报告或仓库；fake回归见 `tests/test_meeting_asr_source.py`。

### 正式 Realtime session 的 ASR 诊断重放

`meeting_realtime_asr_replay.replay_realtime_session` 接受已经构造且 ready 的 `AppServices`、冻结 case/spec 和身份观察 callback，调用实际 `OpenAIRealtimeSession` 的 start/update/append/commit/close。仅在 dataclasses.replace 快照装饰 window factory；共享 worker、Resource Governor、准入与生命周期沿用调用方对象。正式 VAD、speech admission、边界复核和 EOF 处理均走生产路径；核对 session.updated、实际 window/language/context 与有效 VAD/admission 配置。它不负责模型启动、下载、服务操作或封存留出。

wire 固定为24kHz PCM16，kernel 为16kHz。为保留锁定 kernel 字节，此诊断按当前线性 resampler 的逆嵌入将样本对 `(a,b)` 编为 `(a,b,b)`，奇数尾样本只保留一次；这不是声学重采样或真实24kHz采集。分包经过实际生产 resampler，逐 decode 核对原 case PCM；随机/极值、奇偶长度、任意 wire 包边界和 EOF flush 均有合成回归。映射版本及相关生产源文件摘要进入 replay policy，不能推广为其他 resampler 的等价输入。

输入由独立生产者和消费者经1–64包有界队列传递，每包至多一秒；throughput 尽快供给，realtime 按累计 wire 样本以1×时钟供给。队列满、协议失败、缺覆盖或超时均失败，不静默丢帧或重试。TaskGroup 加入两个任务后，等待生产 session.close 清理当前有界 decode；取消同样先加入清理再传播，不强取消共享 worker。总输入 deadline 不包含可能仍需等待的当前 decode 清理预算，因此不能把它当绝对墙钟上限。注入时钟明示 injected；该诊断不提供真实采集延迟或P95认证。

只取有界 sealed 正文评分，逐 attempt 记录沿用 schema 2。实际 Qwen3 engine 通过 ready 私有帧报告 window_decode_max_new_tokens，经 shared owner 严格校验后只在该代 ready 期间暴露给 window factory；关闭、失效或重启清除，缺字段保持未知。formal replay 观察到该值时要求它与冻结 max_tokens 完全一致，并在 replay policy 中绑定、退出时重核；没有观测的 factory 仍只按调用方上限作诊断。每次真实 budget 继续由 observation 证明且不超过冻结上限；streaming 配置不等于共享 window owner 的有效 cap。缺观测保持未知。replay policy 绑定实现/配置摘要、有效策略、输入模式、包/队列与时限；前后身份字段匹配仍只是调用方声明，runtime_identity_verified/certification_eligible 保持 false，a0_execution 为 not_certified。

可将该 callback 交给 `evaluate_locked_asr_case`，贯通共享 development 来源、显式主参考、实际 session、评分与退出后文件核对；会话关闭后修改参考也不能返回 source proof。摘要不含正文、PCM、Base64 或绝对路径。fake 回归见 `tests/test_meeting_realtime_asr_replay.py` 与 `tests/test_meeting_asr_source.py`；实际 A0 生产字节证明、真实质量与延迟仍需独立授权和验收。

### 有声书外置小说语料回归

常规 `AudiobookImportTests`、`AudiobookSourceTests` 使用小型虚构文本，验证漏章、合集层级、重复标题、重复正文确认和 CRLF 预算，不依赖真实小说，可在 CI 中运行。`tests/test_audiobook_corpus_runner.py` 仅验证工具的启用与跳过策略，也不读取小说、不调用 Swift 或模型。

五本完整小说保留在仓库外。仓库仅维护回归代码和 `scripts/audiobook_text_corpus_manifest.json` 中的文件名、SHA-256、大小与章节期望，不包含小说正文，不自动下载语料。完整解析回归由 Python 入口显式启用：

```sh
python3 scripts/check_audiobook_text_corpus.py --run \
  --corpus /path/outside-repository/novel-corpus \
  --output-directory /path/outside-repository/empty-results
```

也可设置 `SPEECHRAIL_RUN_AUDIOBOOK_CORPUS=1` 与 `SPEECHRAIL_AUDIOBOOK_CORPUS_DIR`。未启用、目录不可用或五本文件不完整时，入口输出 `status=skipped` 并返回 0；`CI` 或 `GITHUB_ACTIONS` 为真时无条件跳过，即使传入 `--run`。真实语料回归不接入 CI。完整文件的指纹与清单不一致、输入在验证期间改变或构建失败时返回 2，回归断言失败返回 1。

`AudiobookTextCorpusTool` 经 Swift Package 引用生产 `SpeechRailAppSupport`，对五本书各执行八种编码/换行组合；核对预先记录的目录顺序、重复提示、字节保真、完整来源覆盖、字符顺序和 160 scalar 上限。编码变体仅在内存生成。统计与日志写入仓库外，不输出书稿全文，不访问 AI/TTS、用户作品库或前台 UI；此结果不代表语音质量或性能验收。

### AI 提词器变异验证（**按需触发，不进常规门禁**）

Swift 侧的定向变异验证由 `scripts/swift_mutation_probe.py` + `scripts/teleprompter_swift_mutations.json`
承担，跑在 `.github/workflows/teleprompter-mutation.yml`。**这条 workflow 只有 `workflow_dispatch`：**
它对每条变异真实改一次源码、重跑整套 `swift test`，耗时以小时计（runner 上限设为 120 分钟），
且运行期间工作区一直是脏的。挂在 push／pull_request 上会拖慢每一次提交，并让长跑互相取消。
**常规门禁仍然只有 `ci.yml`；需要刷新变异证据时在 Actions 页手工触发。**

退出码即结论，改动脚本前先读它自己的文档串：

| 退出码 | 含义 | 允许的引用 |
|---|---|---|
| 0 | 基线全绿、`sanity` 变异被杀，且每条变异的实测与 spec 的 `expect` 一致 | 可以引用全部读数 |
| 1 | 有变异不再符合 spec 声明（读数变了，或 `rationale` 过期） | **不可**引用任何读数，先修 spec 或修被测代码 |
| 2 | 基线不绿或 `sanity` 未被杀 | **不可**引用任何读数；探针拒绝解读是有意的 |

本地跑法与 CI 相同，且**退出码必须取自探针本身**：

```bash
cd <path-to-SpeechRail>
python3 scripts/swift_mutation_probe.py scripts/teleprompter_swift_mutations.json > probe.log 2>&1
echo "exit=$?"
```

**不要把探针接管道**（`| tail`、`| tee`）：那样 `$?` 取到的是最后一个管道的退出码，而它永远成功。
阶段报告 §2.51 记的就是这一次自我 mistake——曾据此把 `exit 1` 写成 `exit 0`。

### 「先改状态、后可能失败」静态扫描（**按需触发，不进常规门禁**）

`tools/scan_state_before_failure.py` 列出「改了状态、后面有 `try`／`throw`／`guard ... else`」
的 Swift 函数，分成 `unprotected`（此后没有 `catch`／`defer`）与 `guarded`（有，但**不代表
回滚写全了**）。这是阶段报告 §2 第 43 条那次一次性扫描的可复用版本（issue #121）；50 个真缺陷
里有 41 个属于这一族。

```bash
tools/scan_state_before_failure.py --self-check          # 先证明分类不是恒真
tools/scan_state_before_failure.py macos/SpeechRailApp/SpeechRailApp
```

**输出是候选，不是结论；零命中不等于干净。** 引用「某处扫过没有命中」之前必须先跑
`--self-check`（阶段报告 §2.52 记着扫描器在自己身上恒真过的一次）。脚本按花括号配对切函数体、
不做完整解析，已知的假阳性类别与逐条排除结论写在它自己的文档串里。

官方 Node SDK 的分人 multipart wire contract 单独锁定在 `tests/openai-sdk-node/`，不参与服务的
运行时依赖：

```bash
npm ci --prefix tests/openai-sdk-node --ignore-scripts --no-audit --no-fund
npm test --prefix tests/openai-sdk-node
```

测试使用 fake backend 和合成/脱敏数据，不加载模型、不访问网络，也不提交真实音频。确定性测试通过不等于真实模型质量、性能、长时稳定性或客户端体验通过。
至少覆盖：模型选择、ASR/TTS 错误 envelope、上传限制、队列、REST 响应格式、voice
registry、worker frame 协议、snapshot preflight、Realtime ASR/TTS 契约的 `session.update`
（`session.type=transcription`、24 kHz 输入与 `session.speechrail.*` 选项）、
`input_audio_buffer.append/commit/clear`、`speechrail.tts.*` 顺序、TTS chunk 顺序与背压，
以及 VAD/EOF 边界行为；旧 Realtime 事件必须由 rejection matrix 明确拒绝。

## 真实 worker smoke

在完整外部 snapshot 和 runtime 配置下：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl http://127.0.0.1:8201/v1/voices
curl -X POST http://127.0.0.1:8201/v1/audio/transcriptions \
  -F 'file=@sample.wav' \
  -F 'model=speechrail/qwen3-asr-1.7b' \
  -F 'language=zh' \
  -F 'response_format=verbose_json'
curl -X POST http://127.0.0.1:8201/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"speechrail/qwen3-tts","input":"SpeechRail smoke test.","voice":"default","response_format":"pcm"}' \
  -o /tmp/speechrail-smoke.pcm
```

验收 HTTP 状态、非空文本/偶数字节音频、`X-Request-ID`、模型设备/dtype 与预期 profile。
测试音频和 `/tmp/speechrail-smoke.pcm` 由操作者本地保存，结束后删除；提交/报告只保留最小
结果摘要而非文本、音频或 PCM。

### ASR 标点质量对照

`examples/perf/benchmark_http.py` 与 `examples/perf/realtime_asr_benchmark.py` 的外部 manifest
可在原有 CER/WER 参考之外，成对提供 `punctuation_reference_text` 和
`punctuation_reference_kind`。后者只接受 `human_punctuation_annotation`（人工标点转写）
或 `human_reading_prompt`（人工朗读稿）；两种参考应分别汇总，朗读稿不代表逐音频人工转写。
原有文字参考仍为必填，标点参考去除标点并做 NFKC/casefold 后必须与其文字内容一致。
参考文本只用于本地评分，不发送给服务，也不写入结果摘要或日志。

评分将字母、数字及 Unicode mark 字符做确定性的 Levenshtein 对齐，以字符位置匹配
逗号、句号、问号和叹号，报告各类 support、TP/FP/FN 与 micro precision/recall/F1。
全角形式归一化；顿号、引号、括号及省略号不计入这四类。没有标点支持时不虚构满分；
超过对齐容量上限时返回未评分原因和空分数。该方法只衡量上述四类标点，不衡量其他排版
或句读形式。必须同时查看字符错误率，避免把错误转写上的标点分数当成完整质量结论。

当前没有经场景对照确认的标点阈值，`punctuation_gate` 始终为 `unset`；标点分数只作
描述性证据。资源专用样本不做质量评分，原有终态、输入覆盖、预算和上传回执验收门保持
独立。原始音频、人工参考、转写和 benchmark 制品仍保存在仓库外。

### ASR 定向诊断与配对

真实质量诊断先固定待检验因素、制品、模型/精度、参考、策略、输入字节和请求顺序。
`bench_realtime_json.py --asr-manifest` 可重复指定 `--asr-fixture-id`；
执行顺序保持 manifest 原顺序，warmup 使用所选第一个素材。
未知、重复或空选择在客户端与凭据初始化前拒绝；不指定时执行全池。
选择结果保存来源 manifest 摘要、实际 wire PCM 摘要和独立范围，
缩小池不代表完整验收覆盖。

`asr_segment_error_diagnostics.run_diagnostic_probe()` 只接受质量模式、正整数
次数、明确的布尔 warmup 和包含有效 `max_segment_ms` 的 ASR policy，
在模型请求前校验。它沿用公共事件、receipt、水位、覆盖、预算和质量断言，
仅添加脱敏文字诊断。终态、最后预览分别记录原输出摘要和 CER 规范化摘要；
标点 gold 另记录精确摘要。文字对齐选择一种最优路径，
字符位置不构成声学时间定位；输出不包含参考或转写正文。

离线 `asr_focus_analysis.py --baseline ... --candidate ... --output ...`
要求两份完成的真实分段诊断，核验请求身份/顺序、连续重复、
参考、有效策略、时长、覆盖和已记录的实际 wire PCM 摘要；
逐次展示字符错误差值、预览/终态变化和重复一致性。
标点差值须同时核验 gold 精确摘要及评分口径；缺失或不同标为
`not_comparable`。历史缺少原输出摘要时标为 `not_observed`，不回填。
制品、模型与方法身份由实验冻结及独立审计另行核验，
工具本身的 `measurement_identity_gate` 和完整 `acceptance_gate` 不自动通过。

初筛按观察家族选代表，全部退化仍保留。固定配置已重复一致时，
只有新假设、变量或修复才启动额外测量；单因素初筛后仅确认影响决定的素材，
再保护其余独立风险及未用于调参的素材。候选确定后才执行必要完整验收。
字符错误与各类标点分别判定，平均改善不抵消新增退化；
gold 不得进入模型 context 或生产输出选择。

### ASR 客户端计时观测

`examples/perf/realtime_asr_benchmark.py` 输出 schema 2。每个请求记录最后一包
append 调用起止、名义回放结束、回放等待返回、commit 调用起止、最后终态及
receipt 的相对单调时间，并保留最后上传的 wire 样本区间。
`first_preview_seconds` 仍从 paced 回放起点计算；以下三个字段分别使用不同起点：

- `last_upload_to_last_terminal_seconds`：最后终态接收减去最后 append 返回。
- `nominal_playback_end_to_last_terminal_seconds`：最后终态接收减去回放起点与 wire 时长。
- `commit_to_last_terminal_seconds`：最后终态接收减去 commit 调用开始。

上述差值保留负值：终态可能先于上传返回、名义回放结束或 commit 到达。
`barrier_seconds` 为 receipt 接收减去 commit 调用开始。所有观测位于
`timing_observations`，定义位于 `timing_definitions`；缺失、非有限、
布尔伪装与不可能的时钟顺序拒绝。上传返回不证明服务端已接收，名义回放结束
不证明声音已播放，声学语音结束固定标记 `not_observed`。
旧 `last_audio_to_final_seconds` 已移除，不用截零值冒充末语音时延。

WAV 入口同时核对声明帧数与实际 PCM 字节数，拒绝尾部截断和半个 PCM16
采样帧，避免以不完整素材产生看似通过的输入覆盖证据。
确定性反例位于 `tests/test_realtime_asr_timing.py`，可单独运行：

```bash
uv run --no-sync pytest --no-cov tests/test_realtime_asr_timing.py tests/test_realtime_asr_benchmark.py tests/test_asr_quality_metrics.py
```

schema 1 历史结果保留原始定义；旧审计器不得接受 schema 2 或向旧结果补写新观测。
新结果须以支持 schema 2 的审计器和相同工具版本配对，另记源码 digest；
这些客户端观测不能证明声学时延或场景绝对门通过。

生产 Session 回放的 `SessionReplaySummary` 使用 schema 6，其
`timing_observations` 与上述 Python schema 2 独立。原 schema 5 的
`final_after_last_audio_ms` 已移除。新对象以显式 fake capture 起点记录相对毫秒，
区分最后一次 source yield 返回、`RealtimeASRClient.append` 调用起止、
最后终态接收和 `drainAndClear` 调用起止；最后 append 的 24kHz
半开样本区间另存于 `last_append_sample_span_24k`。
名义采集结束由实际已 yield 样本数计算，包含夹具的合成尾静音，不表示声学结束。

`source_yield_to_last_terminal_ms`、`append_return_to_last_terminal_ms` 与
`nominal_capture_end_to_last_terminal_ms` 分别从这三个起点计算有符号差值。
缺少观测时保持 optional，不以构造时钟或零值代替；JSON 中缺失的 optional 字段
表示未观测。`observations_complete` 只表示这些客户端观测齐全。
声学结束、服务端 append 接收、内部 commit 发送和 receipt 接收时刻均明确标为
`not_observed`；drain 返回不能代替其中任何时刻。时钟逆序或空/无效上传区间拒绝。
schema 5 历史证据保持原样；新监督器须显式校验 schema 6。
确定性计时反例位于已有回放门测试文件，可运行：

```bash
swift test --package-path macos/SpeechRailApp --filter ASRSessionReplayTimingTests
```

### 生产 Session 回放的采样退出协调

对显式启用 `SPEECHRAIL_ASR_SESSION_E2E=1` 的生产 Session 回放，
外部资源监督器可同时提供以下三个变量：

- `SPEECHRAIL_ASR_SESSION_SAMPLER_RUN_ID`：本次运行的 canonical 小写 UUID。
- `SPEECHRAIL_ASR_SESSION_SAMPLER_READY`：消费者 ready JSON 的绝对路径。
- `SPEECHRAIL_ASR_SESSION_SAMPLER_RELEASE`：监督器 release JSON 的绝对路径。

两个 marker 与结果文件须为不同文件，位于同一个现有仓库外目录；已有 marker、
部分配置、相对路径、路径冲突与仓库内目录均拒绝。三个变量均为空时不启用协调。

消费者在排空、释放、结果写入及原有验收断言后，原子发布且不覆盖 ready：
`{"schema_version":1,"run_id":"<本次 UUID>","consumer_finished":true}`。
监督器须先停止并 join 采样线程，保存原始资源材料，成功后才原子发布且不覆盖
release：`{"schema_version":1,"run_id":"<同一 UUID>","sampler_stopped":true}`，
随后等待消费者实际退出。消费者限时等待最多 30 秒；错误 UUID、格式或字段、
非普通文件、超大 marker、超时与取消均失败，取消不转换为成功。

marker 只协调进程退出顺序，不表示质量、消费者或资源门通过。原有失败结果、
不完整资源和非零退出码必须原样保留；异常路径仍须由监督器回收消费者。
握手的确定性回归位于现有 `ASRProductionSessionReplayGateTests.swift`，
Xcode 与 SwiftPM 使用同一测试文件。可单独运行：

```bash
swift test --package-path macos/SpeechRailApp --filter ASRSessionReplaySamplerHandshakeTests
```

定向测试使用临时 marker 与替身状态，不加载模型或接管 UI。真实长会资源门须另以
同一消费者 binary、监督器、素材与驻留口径配对重测，不能用确定性测试改写旧失败。

## 规格选择与分人供给测试清单

当前档位契约是**三档规格 + 双 spec**（`fast`/`quality`/`reference`，ASR 与 TTS 各自选择），
分人是**任务级 opt-in**，不再由档位继承。以下确定性测试文件覆盖该契约：

| 关注点 | 测试文件与代表用例 |
|---|---|
| 发布矩阵：12 个制品、12 个 `(tier, role)` 绑定（VoiceDesign 是不绑档位的按需制品），catalog 拒绝缺口或越界 | `tests/test_model_catalog_contract.py`（`test_catalog_specs_match_the_required_role_matrix`、`test_quality_clone_source_is_pinned_to_modelscope`）、`tests/test_model_catalog_builder.py`（`test_build_catalog_normalizes_artifacts_and_sorts_files`）|
| selection v2：只按显式 artifact key 解析、不再从目录名推断、旧记录拒绝 | `tests/test_spec_selection.py`（`test_selection_resolves_only_from_the_explicit_v2_spec_fields`、`test_active_catalog_never_infers_identity_from_directory_names`、`test_legacy_selection_is_rejected_before_paths_are_used`）|
| 每个档位都能解析到 catalog 绑定制品；缺 Base 或绑定制品 fail closed | `tests/test_spec_selection.py`（`test_every_target_spec_resolves_to_catalog_bound_artifacts`、`test_selection_requires_the_base_clone_snapshot`）、`tests/test_profile_selection.py`（`test_missing_asr_model_directory_raises_error`、`test_unavailable_bound_artifact_raises_error`）|
| 制品准备落在 `models/<artifact_key>`，异步、原子发布、逐文件校验 | `tests/test_model_store.py`（`test_prepare_streams_locked_files_and_publishes_atomic_registry`、`test_download_async_streams_close_once_on_success_and_hash_failure`、`test_metadata_change_gets_new_identity_and_reuses_verified_files`）|
| 分人供给只认显式 aligner：产物 / 不产物 / 复用 / 损坏 / 未知档 | `tests/test_installer.py`（`test_prepare_diarization_assets_provisions_aligner_q8`、`test_prepare_diarization_assets_reuses_verified_directory`、`test_prepare_diarization_assets_rejects_corrupt_existing_directory`、`test_prepare_diarization_assets_unknown_aligner_raises`）|
| 三档申请与推荐：内存推荐只有建议语义、未知档位拒绝、失败不切档 | `tests/test_profile_commands.py`（`test_catalog_lists_three_spec_tiers_with_explicit_bindings`、`test_recommendation_uses_memory_only`、`test_apply_rejects_unknown_spec_tier`、`test_prepare_failure_keeps_previous_selection_and_skips_switch`）|
| `profile apply` 只在 opt-in 时写分人键，供给失败显式报错 | `tests/test_profile_commands.py`（`test_apply_without_diarization_opt_in_skips_auxiliary_assets`、`test_diarization_writes_env_for_explicit_aligner`、`test_diarization_prepare_failure_is_explicit`）|
| preflight aligner 门控：未设置时跳过、缺 CoreML 时仍校验、不完整 snapshot 拒绝 | `tests/test_service_preflight.py`（`test_preflight_skips_aligner_snapshot_when_aligner_dir_unset`、`test_preflight_checks_aligner_snapshot_without_coreml_bundle`、`test_preflight_rejects_incomplete_aligner_snapshot`）|
| installer / zero-setup 传双 spec，分人供给按显式 aligner 门控 smoke | `tests/test_installer.py`（`test_managed_install_adds_diarization_when_configured`、`test_managed_install_without_diarization_assets_omits_diarization_config`）|

这些测试使用 fake backend 与脱敏 fixture，不加载真实模型、不下载 aligner。`reference` 档的高精度制品
继承同族 8-bit 档位的门禁证据，未在本机逐项复测；能力认证集合见
[Issue #95 交付认证](issue-95-certification.md)。

## 集成验收矩阵

| 客户端/接口 | 当前状态 | 通过条件 |
|---|---|---|
| REST curl | 已完成本机 smoke | health / readyz / models 正常，短音频得到结果 |
| REST TTS | 契约与 fake backend 已覆盖 | `/v1/voices` 返回已登记音色的真实 binding variant，短文本返回 24 kHz PCM/WAV；真实 runtime 需另验收 |
| QwenPaw `whisper_api` | 已完成本机 smoke | provider 指向 `8201/v1`、应用完整重启、短中文音频有文本 |
| OpenAI SDK | 可按兼容契约接入 | multipart 调用和错误处理符合 OpenAPI |
| Hermes Agent | 待验收 | STT 专用 base URL/model 生效且不改变聊天 endpoint |
| `/v1/realtime` | 协议测试 | update → append → commit → 一次 completed；不要求 delta |
| `/v1/realtime` ASR/TTS | fake backend 协议测试 | OpenAI 事件顺序、取消、背压、terminal event 和 diarization 边界；真实 worker 需另验收 |
| `sona` adapter | 确定性边界已覆盖 | ASR/TTS 真实音频、播放和回滚 smoke 通过；不以 legacy `/asr` 作为替换结论 |

每次发布保存命令、时间、版本/commit、测试摘要、OpenAPI lint、设备/dtype、request ID 与
未验证风险。命令退出码不能单独替代 API 响应或客户端行为证据。


## 有声书工坊专项测试与验收交接

有声书工坊（T01–T14）的 Python 媒体导出测试、13 个 SwiftPM 模块测试套件、Xcode 构建检查与桌面真机验收清单见 [有声书工坊测试与验收交接手册](audiobook-workshop-testing-handover.md)。
