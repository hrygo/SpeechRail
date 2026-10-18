---
title: "SpeechRail 测试与验收"
status: active
version: "3.3.53"
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

评分 policy 的 `statistics.fixture_aggregation` 必须固定为 `one_execution_per_fixture_source_totals_v1`。每个唯一 fixture 仅允许一次执行，重复 fixture 不作为独立重复测量。同一来源的不同片段先累加正确量、参考量与预测量，再计算 pooled speaker-time 和等会议 macro 比率；DER/cpCER 先按来源累加错误量与参考量，再以来源组配对计算区间，不能平均片段错误率或用片段数稀释来源权重。bootstrap 的独立单位仍为来源会议组。旧 policy 缺少该身份时拒绝；所有受其摘要约束的 manifest、候选 spec、schedule 与 checkpoint 必须重新冻结并重算，不复用旧通过结论。

检查点预检只跨会议保留文件指纹，不持有整个来源池的参考正文；逐场评分后只保留脱敏结果。该执行器验证实际输入与输出覆盖，并连接产品门和调度，仍不证明 activity factory 的真实制品/SDK/运行身份、生产者来源、跨进程排他或联合延迟。`runtime_identity_verified=false/certification_eligible=false/verdict=diagnostic/certified_max_speakers=null` 保持明确；调度的 `passed` 仅表示该共同检查点的评分门通过，不代表唯一候选选型或产品认证。生产组合根须启用并导出阶段观测；真实联合 ASR 时钟、可信开发收据签发及留出执行仍需接线；共同检查点和跨层离线选择入口见下文。fake 测试为 `tests/test_meeting_development_fixture.py`。

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

fake 验证见 `tests/test_meeting_candidate_execution.py` 与 `tests/test_diarization_worker.py`；包含合成 WAV/文字、fake IPC 以及不加载模型的锁继承子进程，不证明 CoreML 模型、真实 footprint 或质量达标。C0 spec 由 meeting_c0.static_c0_spec 只读构造，model-directory 指向含 SortformerNvidiaLow_v2.1.mlmodelc 的外部目录；同一 CLI 按冻结 implementation_id 分派，未知实现拒绝。C0 只参加 ≤4 人质量对照，超过四人不能认证。跨层离线选择见下文；真实来源与联合身份、收据及留出仍待接线；C0 fake 回归另见 tests/test_meeting_c0.py。

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

`meeting_candidate_selection.select_development_candidate` 是离线诊断入口，接收独立初始 schedules、冻结 development manifest/scorer policy 和最后已完成的共同 checkpoint。声明人数上限要求1到该上限所有连续层均有已完成且非空的合格候选集合：调度状态可为 passed，或共同扩样至24组后为 evidence_exhausted 且仍存在已合格候选。证据耗尽的候选本身不获得资格；pending、缺来源或空合格集合不能选型。恢复有限历史后取各层合格候选的交集，任一层已淘汰的候选不能复活。C1/C2及低人数层C0身份须跨层一致。每层只使用其最终共同前缀，逐项核对全部冻结fixture、场景、来源组、候选、sidecar与评分身份；不追加排名数据，不把重复报告当独立来源。

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

比较器在汇总前复核 normalized CER：参考量与 S/D/I/总错误量必须为非 bool 的有界非负整数，参考量非零，S+D 不超过参考量，错误总数等于 S+D+I，计数推导的预测长度遵循单次评分的10000 token 上限；characters.error_rate 与 normalized.cer 均须等于错误量/参考量，并匹配冻结编辑同分规则。同一 case 的配对及重复记录必须使用相同参考分母。合法的插入错误可使 CER 大于1，不作裁剪；缺主参考仍为未观察且不通过。此校验只证明计数与比率自洽，不证明参考或模型来源。

同一 case 的重复先平均错误数，同源片段再合并分子/分母，最后每个独立来源组等权计算主 CER。≥10% 相对点改善和 candidate−baseline 配对 95% 区间上界<0 使用同一来源组等权估计量；seed/重采样复用冻结 policy。全体 pooled CER 单列，重复和片段不增加独立 N。基线 CER=0、缺无歧义主参考、缺真实 decode、缺帧/重复/超时/截断或未观察 token-limit 均不能通过。关键事实人工复核独立记录，时间戳变化不能计为正文改善。

`RuntimeObservation` 调用前后字段匹配只得到 `execution_identity_matches`，不证明可信来源。没有可信生产评测组合根时保持 `runtime_identity_verified=false/certification_eligible=false/a0_execution=not_observed`；fake 或自报 runtime origin 不升级认证。顺序 feeder 逐包 flush intents，不等价独立 1× 采集/P95 基准；非法、非有限或倒退 clock 拒绝，注入 clock 明示 injected。取消加入 session 关闭，错误输出脱敏，摘要不含原文、PCM 或绝对模型路径。独立 overlap ORC、可信实际 A0、真实错误归因和质量改善仍待后续接线/实测。fake 回归见 `tests/test_probe_meeting_asr_quality.py`。

ready 帧的窗口 cap 来自 engine 实际动态预算字段，而非重复 CLI 入参；0 的既有默认预算语义报告为512。它只补充内部有效配置观测，不证明模型文件字节、vendor package 来源或实际 A0。类型须为32–2048整数，拒绝 bool、字符串和越界值；未提供保持 null，不强制推断。生产 WindowDecodeResult 可携带内部 WindowDecodeObservation，经 window.result 私有 RPC 保留每次 preview/review 的实际 decode_max_new_tokens、generation_max_new_tokens、finish_reason、truncated 和 generated_token_count。decode budget 是 engine 调用入参；preview generation budget 是扣除复用 prefix 后实际传给生成器的 remaining_tokens，token count 在 header strip / prefix merge 前取实际返回 tokens 长度。review 的内部 generation budget 和 count 无可验证观察，保持 null。finish/truncated 缺失保持 null，拒绝类型强制转换、非法范围、额外字段和错误 kind；缺整个 observation 也保持未知。该内部元数据不进入公共 Realtime 契约，不改变解码策略，也不自动升级实际 A0。回归见 test_asr_window.py、test_qwen3_window.py、test_qwen3_stream_decoder.py。

正文诊断报告使用 schema 2，ASR scorer 身份为 asr-body-v2，并绑定实现源码摘要；实现或比较规则变化后，旧报告及候选 spec 须重新冻结和执行，不能沿用旧门。RuntimeObservation 只提供调用前后身份与 origin，移除自报 token_limit_hit 入参。每个实际 decode 都记录匿名 attempt 摘要、preview/review、样本范围、实际预算和可见完成元数据；最多4096次，超额在调用下一个 decoder 前失败。仅全部 attempt 明确 finish_reason=eos、truncated=false 且实际 decode budget 不超过冻结上限时，截断证据门才可通过；缺观测、kind 错配、未知终止状态、任一 preview/review 截断均不能被后续成功 review 掩盖。review 的 generation budget/count 仍可为 null，不推断厂商内部行为。未知 finish reason 只输出 other，不回显厂商字符串。报告包含有界逐次记录与其摘要、观察/缺失/未知计数；compare_asr_runs 重新检查记录、计数、范围和摘要，不只信任 quality_evidence_valid。合成执行可以通过诊断证据门，但不能获得生产身份、质量改善或人数认证。

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

`input_mode=shared_pcm` 必须同时提供外部 `pcm_frames`，其他mode拒绝该参数。共享输入不重新计时或读取旧sidecar：逐包核对PcmChunk的整数序列、连续样本区间、原case PCM字节、有限且一致的源时钟元数据；EOF必须覆盖全case。逆嵌入跨包保留至多一个奇数kernel样本，最后再flush，不能逐包独立丢失配对状态。一个源包拆成多个wire包时，内部队列满先给ready消费者一次调度机会，仍满则失败，不等待queue.put容量、不移动共同源时钟。源自取消转为失败，取消并加入另一条重放任务；外部取消仍等待session与源迭代器清理。

共享源的 `diagnostics.input_clock=external_shared_source_unverified`：帧中的时间是调用方元数据，必须结合共同供给报告才能区分真实monotonic和注入clock，不能因未注入本函数clock而冒称真实时钟。`diagnostics.shared_pcm` 只记录已核对的帧数/样本数；ASR重放自身不提供分人活动发布、footprint或P95证明。该库入口不自动提供联合评测CLI或可信收据，wire逆嵌入仍非真实24k采集。

只取有界 sealed 正文评分，逐 attempt 记录沿用 schema 2。实际 Qwen3 engine 通过 ready 私有帧报告 window_decode_max_new_tokens，经 shared owner 严格校验后只在该代 ready 期间暴露给 window factory；关闭、失效或重启清除，缺字段保持未知。formal replay 观察到该值时要求它与冻结 max_tokens 完全一致，并在 replay policy 中绑定、退出时重核；没有观测的 factory 仍只按调用方上限作诊断。每次真实 budget 继续由 observation 证明且不超过冻结上限；streaming 配置不等于共享 window owner 的有效 cap。缺观测保持未知。replay policy 绑定实现/配置摘要、有效策略、输入模式、包/队列与时限；前后身份字段匹配仍只是调用方声明，runtime_identity_verified/certification_eligible 保持 false，a0_execution 为 not_certified。

可将该 callback 交给 `evaluate_locked_asr_case`，贯通共享 development 来源、显式主参考、实际 session、评分与退出后文件核对；会话关闭后修改参考也不能返回 source proof。摘要不含正文、PCM、Base64 或绝对路径。fake 回归见 `tests/test_meeting_realtime_asr_replay.py` 与 `tests/test_meeting_asr_source.py`；实际 A0 生产字节证明、真实质量与延迟仍需独立授权和验收。

### 私有 ASR 运行组合与加载前冻结

`meeting_asr_runtime.prepare_frozen_asr_runtime` 是显式模型加载库入口，调用前必须已有真实模型运行授权；导入模块不启动模型，也不提供自动发现、下载、留出或 managed service 操作。它使用生产 `build_app_services` 构造私有 ASR/aligner 对象，不借用正在运行的服务，不启动 RuntimeLifecycle；voice registry 仅构造未打开对象，不读取用户音色库。设置必须显式提供 ASR 模型、aligner 与 worker Python，并排除 TTS、分人和 durable job 配置；私有副本关闭 idle eviction。

调用方以 `RuntimeDependencyRoots(host=..., asr=..., aligner=...)` 分别声明三个解释器角色的绝对依赖路径。加载前冻结实际 ASR/aligner 模型目录、必要 VAD 模型、宿主及两个 worker 解释器、生产/评测 Python 源码和声明的依赖文件；目录包含现存 bytecode 与 native library，不推断依赖完整性。目录符号链接拒绝，文件符号链接同时绑定链接状态和目标字节。冻结后、准备后和回放后核对完整目录项、摘要及文件状态，修改后恢复也拒绝；任何读取或目录遍历失败均拒绝继续。

私有 worker transport 设置 `PYTHONDONTWRITEBYTECODE=1` 并纳入配置摘要；不修改宿主全局解释器标志。宿主导入若改变声明的依赖目录，同样判定文件不稳定，不静默忽略新 bytecode。Silero 使用宿主进程共享缓存：拒绝已存在的对应模型 cache key，保护模型文件，但不清空全局缓存，不宣称本次调用独占或释放该缓存。

ready 后绑定同一生产 window factory、shared owner、ASR generation、实际进程对象、ready 结构身份、有效窗口 cap 与配置。aligner 未暴露 generation，仅核对原 client/transport/process 对象和 ready identity。`candidate_spec()` 从冻结文件和实际 ready 配置形成诊断比较身份，sdk_revision 字段使用 `filesystem-closure:` 摘要绑定完整具名文件集合、两个 worker 的完整环境及有效配置，不冒充已导入 SDK 版本；`evaluate()` 贯通 `LockedAsrCase → evaluate_locked_asr_case → replay_realtime_session`，每次回放前后复核，单 handle 不允许并行回放。退出先加入准备或正在进行的回放，再关闭私有创建的两个 child；替换的未知 worker/process 不按假定所有权关闭，清理未确认则失败。

私有root同时绑定原services与NativeWindowAsrFactory中的实际Governor对象，任一被替换即失败。`governor`属性只在有效handle上返回该对象；`evaluate(..., pcm_frames=frames, governor=shared)` 只接受同一对象和正式session计划，不接受缺Governor、其他Governor、无流却传Governor或长块计划配流。其来源/字节/owner/generation及关闭后校验沿用普通重放；共同输入等待仍计入外层回调区间。Governor对象相同不证明DIA的预算声明、实际联合生产身份或并发净收益。此接线是显式库入口，现有单场ASR CLI不隐式创建共同输入源；相关源码闭包/spec与重放身份变化后须重新冻结和执行，不沿用旧报告认证。

`proof()` 的 preload/post-prepare/post-replay 字段只描述具名文件稳定性与对象核对。`loaded_model_bytes_verified/actual_imports_verified/source_import_bytes_verified` 保持 false；ready revision 是结构指纹，不能作为权重字节证明，依赖声明也不证明实际 import resolution。结果继续 `runtime_identity_verified=false/certification_eligible=false`，实际 A0、质量改善与 P95 仍需独立证据。fake 回归见 `tests/test_meeting_asr_runtime.py`。

### 锁定 ASR 单场开发执行

正式单场入口要求先登记预期 candidate spec，再执行来源锁回放；不能把本次转写完成后测得的 spec 直接登记为 A0。需要采集身份时，调用方须另获模型运行授权，以不接收 fixture、不回放音频、不评分的私有 root 生成候选草案，再独立冻结执行锁。此入口不提供自动选模型、改配置或重试失败候选的选项。

```bash
PYTHONPATH=src:examples/perf uv run --no-sync python examples/perf/probe_meeting_asr_development.py \
  evaluate-development --asr-lock "$ASR_LOCK" --output-directory "$ASR_OUTPUT"
```

`meeting_asr_execution.execute_asr_development` 的 schema 2 控制锁必须恰含 schema_version、replay、fixture_id、service_port、artifact_root、manifest、split_lock、scorer_policy、primary_reference、settings、dependencies、candidate_spec。manifest/split_lock/scorer_policy/settings/candidate_spec 各为绝对 JSON 路径与 canonical SHA-256 descriptor；primary_reference 使用前述相对 artifact root 路径与文件字节摘要。dependencies 恰含 host/asr/aligner 三个角色的显式绝对路径数组。JSON 单文件16MiB、总量32MiB；拒绝未知字段、重复键、非有限数、控制/参考文件的符号链接及非普通文件，不提供 holdout 入口。显式 worker Python 与依赖文件允许普通文件符号链接，由 runtime 同时保护链接和目标；模型/依赖目录不允许符号链接，模型真实路径必须在仓库外。

`replay` 通过不可变 `AsrReplayPlan` 显式选择诊断路径。正式 Realtime 模式恰含 `mode=formal_realtime_session_diagnostic`；同权重长块模式恰含 `mode=bounded_long_block_diagnostic/block_seconds/decode_timeout_seconds`，块长为1–30秒非bool整数，每次decode时限为0到300秒之间的有限正数，不接受bool。长块只按音频样本固定网格，context为空，不使用参考正文、活动边界或分人输出形成输入。旧schema 1执行锁拒绝，不能隐式选择正式路径；必须先重新登记schema 2的计划和相关候选身份。

两个模式复用相同冻结生产owner/config与来源守卫。长块在同一已ready window factory创建诊断session，由既有replay_long_blocks关闭；root加入回放后再清理ASR/aligner。模型candidate身份描述冻结模型与配置，mode及长块预算由独立控制锁、diagnostic_replay和replay_policy_sha256绑定；同一权重的两条路径不被解释为同一生产行为。执行器拒绝结果mode或长块policy与计划不符。长块结果仅用于定位切块/VAD/上下文损失，不构成可上线候选、实际A0或延迟认证；两模式仍需关闭后核验才能提交。

settings 只从控制文档的显式值和代码默认值构造，关闭 environment/dotenv/secrets sources，拒绝未知字段和服务密钥；环境变量也不能通过 legacy validator 补值或改变判断。服务端口必须与 settings.port 一致，host 为127.0.0.1。执行前先验证 development 来源和独立主参考，再获取同一用户/声明端口的排他锁；两个私有 ASR/aligner child 显式继承锁 FD。锁持续到两个 child 退出，父级仅 close、不执行 LOCK_UN；该锁不证明其他端口没有实例。

同一次加载前文件冻结先核对预登记 spec 的 closure/config 与静态文件部分，ready 后再核对完整 spec，匹配后才允许正式回放。锁的稳定语义绑定用户、端口和角色，不以瞬时 FD 数值定义候选；运行内另核对具体 FD/file identity。退出时加入回放与两个 child 清理，再完整复核关闭期间文件和配置。`verify_closed()` 可在成功退出后异步复核，`verify_commit()` 只在确认回收及完整核对后提供同步最终守卫，失败或取消不能获得可提交状态。

输出使用仓库外新0700目录、0600文件；只保存匿名诊断摘要，不保存正文、PCM、路径或环境值。partial 写入后再次加入控制、来源与已关闭 runtime 的全量核验，全部 await 之后同步检查三者，再无 await 硬链提交 result.json。失败、取消、来源变更或回收未确认均不提交完成结果，不覆盖既有输出。完成只证明预登记身份匹配且诊断执行结束，不签可信收据，不升级加载来源、实际 A0、CER改善或认证；runtime/certification 字段继续 false。相关 fake 回归见 `tests/test_meeting_asr_execution.py`、`tests/test_probe_meeting_asr_development.py`。

### ASR 离线开发对照

`meeting_asr_comparison.execute_asr_comparison` 只读取预登记的脱敏JSON结果，不打开音频、参考正文、模型或留出，不启动worker，也不探测服务。它接通现有 `compare_asr_runs`，不另设CER估计量或修改候选参数。

```bash
PYTHONPATH=src:examples/perf uv run --no-sync python examples/perf/probe_meeting_asr_development.py \
  compare-development --comparison-lock "$ASR_COMPARISON_LOCK" --output-directory "$ASR_COMPARISON_OUTPUT"
```

schema 1 comparison lock 恰含 `schema_version/cases/scorer_policy/baseline/candidate/key_facts_review`。`cases` 为事前冻结的1–1024个唯一case，每项包含 `AsrCase.identity()` 的六个摘要及 `expected_samples`；case摘要须与其组成字段一致，scorer须与当前实现相符，样本数为非bool整数且不超过十分钟。这个列表定义本次诊断范围，不能从已完成结果中挑选后冒充事前登记或整个人数范围认证。它不重新核验原始manifest、主参考、PCM或生产者真实性。

`scorer_policy` 为绝对JSON路径与canonical SHA-256 descriptor。两组各恰含 `candidate_sha256/replay_policy_sha256/mode/reports`，事前固定各自身份，reports包含每个case恰好一份descriptor。mode仅允许 production_window、bounded_long_block_diagnostic、formal_realtime_session_diagnostic；同组必须一致。正式单场执行结果可原样输入。重复或缺场、错误候选/重放/来源身份、样本数不符、holdout、自报runtime或certification为true均拒绝。该入口不提供重复执行合并；单次case不能通过重复报告增加独立N。人工关键事实状态只接受not_observed/pass/fail，属于声明，不能单独证明人工核验来源。

控制与报告JSON单文件限16MiB、总量32MiB，拒绝重复键、非有限数、未知控制字段、相对路径、叶符号链接和非普通文件。评分、写partial之后加入输入与执行源码全量校验，再同步核对文件状态、输出目录身份、partial内容与状态，无await提交comparison.json；失败和取消不提交完成结果，取消须等待评分线程退出。目录必须为仓库外新0700目录，文件0600，既有输出不覆盖，错误只保存固定码。

结果记录控制与执行实现摘要、case数量和现有来源组配对诊断统计，不回显输入路径或正文。`verdict=diagnostic/runtime_identity_verified=false/certification_eligible=false/quality_gate=fail` 固定；development_text_gate仅是声明输入下的文字诊断门，不签收据、不证明实际A0或CER产品验收。CLI属于ASR执行源码身份，接线变化后相关candidate spec与控制锁须重新冻结。fake回归见 `tests/test_meeting_asr_comparison.py` 与 `tests/test_probe_meeting_asr_development.py`。

### ASR 与分人四模式调度核心

`bench_asr_diarization_overlap.run_workload_schedule` 提供 asr-only、diarization-only、serial、overlap 的异步调度库，不提供模型发现、真实评测CLI或文件写出。调用方提供事前获准、已绑定来源的ASR/分人回调；所选模式以外的回调必须缺省。每个回调接收同一个显式ResourceGovernor，并负责把实际计算交给它、等待所属推理和session清理后再返回或传播取消；库不能从参数传递证明回调确实遵循了这些约束。

两个联合模式都同时启动两路回调。serial要求Governor的allow_heavy_overlap明确false，由实际计算准入串行，不能把整场ASR跑完后再启动分人当作串行基线；overlap要求overlap_enabled为bool true且Governor明确允许交叠。启动前拒绝已有活动/排队计算、retained分人资源、计算拒绝或相关lane不可用；不改Governor配置，不预留整场计算租约，也不能据此证明预算声明来源或跨进程排他。

回调报告须声明完成且无失败：接受complete=true、status=completed或quality_evidence_valid=true之一，出现的其他完成字段也须一致。报告只作有限JSON快照和摘要，最大16MiB；快照/散列在线程执行并加入取消清理，原文、PCM与路径不进入调度输出。这个完成声明不替代质量门或真实生产者证明。每路回调在独立任务中执行，可返回任意受支持的Awaitable；回调自行取消属于失败，立即取消并等待另一条路清理，不等待总deadline才处理。任何失败、自取消、超时、非法/倒退时钟或部分完成均不返回schedule_completed结果；外部重复取消须等待所有已启动回调和散列线程退出。执行deadline默认900秒、最大7200秒，不包含其后不可放弃的清理等待；回调吞掉deadline取消也不能提交完成。

输出区间为宿主回调开始至返回，包含其自身清理，非kernel推理时间。clock明确区分monotonic/injected；schedule_completed只证明调度结束。runtime_identity_verified、certification_eligible、same_source_verified、worker_reaping_verified、compute_overlap_observed、joint_latency_observed保持false，quality_gate/footprint/p95保持not_observed。

完整T6还需将共同PCM供给接入真实ASR正文与分人watermark及稳定发布，补齐确切进程footprint、冷/热ABBA block、按来源组配对统计和生产身份核验。回调墙钟、合成任务的交叠或Governor准入测试不能替代这些证据。确定性回归见 `tests/test_asr_diarization_overlap_harness.py`；它只使用asyncio、实际Governor和fake计算，不打开音频或加载模型。

### 会议评测共同 PCM 供给

`bench_asr_diarization_overlap.run_pcm_workload_schedule` 在四模式调度核心外提供一个共同的16kHz mono PCM16供给源。调用方传入已加载的不可变bytes与预登记SHA-256，回调签名为 `(governor, frames)`；源摘要在线程校验，frames是有界异步迭代器，回调必须完整读至结束并负责自身推理/session的joined清理。原始PCM不进入返回报告、日志或对象repr。库不打开文件、不构造模型、不提供真实执行CLI。

输入为正数个完整样本，最大600秒；每包1–16000样本、总包数不超过65536，默认320样本。每路队列1–64包、默认8包，共享同一个不可变分包；缺失或额外回调按模式拒绝。所有所需消费者进入首次读取后确定供给原点，按每包样本末端相对原点的固定deadline等待，最后不足整包的尾样本保留。等待消费者或源摘要校验的时间仍包含在外层回调总区间内，不伪装成推理时间。

`max_lateness_seconds` 必须显式事前提供，有限正数且不超过1秒；这是供给调度预算，不是稳定标签或finish产品门。提前供给、迟到超预算、倒退/非法时钟、任一路队列满或未读至结束都使整体失败；不丢包、不因反压移动供给原点、不按结果放宽预算。失败、超时、自取消与外部重复取消加入供给、消费与源摘要线程，结束后关闭迭代器并释放源/排队引用，不能在作用域外继续读取。

`pcm_feed` 记录源/策略摘要、样本与包数、宿主供给原点/末包计划与实际时刻、最大迟到、各路交付样本数/队列峰值及排队时长。默认monotonic与注入clock/sleep明确区分并进入策略摘要；注入时钟只能作为合成证据。共同源交付不证明模型实际接受/消费了全部样本，更不证明麦克风采集、活动稳定发布或真实计算交叠。model_acceptance_verified、microphone_capture_verified和外层runtime/certification/joint_latency/compute_overlap标记保持false；quality/footprint/p95仍未观察。生产适配器与真实阶段观测就绪前不签共存收据。确定性回归见 `tests/test_meeting_pcm_feed.py`。

`meeting_activity_workload.run_shared_activity_stream` 接收同一原始PCM与外部frames，使用与正式ASR重放相同的 `PcmSequenceVerifier` 检查实际字节、连续样本、包序列和源时钟元数据，EOF必须完整覆盖来源。它委托候选runner消费活动，不二次计时，不构造Governor或模型。返回 `input_mode=shared_pcm`、`input_clock=external_shared_source_unverified` 与已核对帧/样本计数；结束、失败或取消后关闭外部迭代器。

候选runner未提供 `text_replay` 或 `text_channel` 时明确表示仅观察活动：`asr_text_source=not_observed`、`asr_text_sha256=null`、`clock_scope=diarization_activity_only`，不能用空sidecar冒充本次ASR正文。固定sidecar模式仍单独报告 `fixed_sidecar`，与live channel互斥。每个通过因果覆盖校验的稳定活动帧向外部sink发布 `stable_activity_frame`，包含样本区间、session-scoped匿名slot、step及接收时的 `observed_at_seconds`；sink实际交付时刻仍为 `elapsed_seconds`。评分用的闭合speaker区间可持续到finish，不能以它的关闭时刻替代稳定帧观测。两个时刻均相对runner宿主起点；需要结合共同源时钟与最终产品发布路径才可计算联合延迟，不能直接生成稳定标签P95。活动消费者自取消使执行失败并取消输入；外部重复取消等待活动回收、来源关闭及制品复核结束。

`NativeCandidateRun.evaluate_shared_pcm` 是原生候选的显式库入口。传入Governor必须与创建owner时捕获的对象一致，并在构造session前及执行/制品复核后检查；同一handle的并行共享执行和已占用分人owner被拒绝。它复用既有session、端口继承、native preflight及制品检查，并在精确child回收后返回候选执行观察。原始输入、sink和共同供给作用域仍由调用方明确提供，没有新增自动执行CLI。C0与候选adapter源码闭包包含共享活动与PCM校验模块；闭包变化要求重新冻结spec和重新执行，不能沿用旧结果。Governor对象一致不证明资源预算、加载字节或最终ASR/分人联合身份。

`meeting_live_text.LiveTextChannel` 提供单producer、单reader的有界live正文观察通道。默认最多64个排队item和10000字符，分别可显式设置为1–4096和1–10000；整个case仍最多4096个item、10000字符、600秒，每个实际owned span不超过30秒。重复producer、队列或字符预算超限、非法/倒退时钟、文字序列或样本区间异常使通道永久失败并释放排队正文。发布使用非阻塞操作，不等待DIA消费、不延后PCM供给；失败/关闭后的发布返回false，不阻断ASR独立评分正文。通道报告只含计数、预算与状态，不保留报告正文；timed observation的repr也不包含文字。

正式ASR重放显式接收 `text_channel`，只转发实际生产session sealed final_units中非空正文，并将owned_span准确映射至16k kernel样本。预览、参考、silence与coverage本身不产生文字，句级跨度不伪装成词级对齐。ASR正常完成且质量证据有效后发送明确EOF；启动异常、取消或无效结果使通道失败并唤醒reader。observer失败仍可保留独立ASR评分结果，但不能作为联合通过证据。排队预算与是否启用live进入重放policy；私有ASR root仅在formal shared_pcm与同一Governor绑定下接受此通道，root后验失败也使通道失效。

`run_shared_activity_stream` 和 `NativeCandidateRun.evaluate_shared_pcm` 可接收同一live channel。独立text pump等待DIA实际accepted_samples覆盖文字末端后才注册，输入EOF仍不足则失败；必须收到ASR明确EOF并完成文字守恒、DIA finish与清理后才返回完成。此模式报告 `asr_text_source=live_sealed_session`、`clock_scope=diarization_with_live_asr_observer`。`asr_text_ready.producer_observed_at` 为通道clock的绝对观察时刻，`elapsed_seconds`为DIA runner相对起点的sink交付时刻，不能直接相减冒充产品延迟；通道clock区分monotonic/injected。DIA失败会关闭observer；通用调度器仍取消失败lane的其他任务，ASR优先的诊断降级须使用下述独立live pipeline入口。

live通道不证明实际来源/生产字节或最终联合身份；必须在全部作用域结束后核对其最终状态，ASR报告中的快照不证明reader随后完整读完。产品稳定标签发布、共同起点、footprint、ABBA与真实质量仍未验证，runtime/certification/joint latency标记保持false，人数认证与P95未观察。相关fake回归见 `tests/test_meeting_live_text.py`、`tests/test_meeting_candidate_runner.py` 与 `tests/test_meeting_candidate_execution.py`。源码闭包变化后重新冻结spec与重放controls/report，不沿用旧认证。

### 会议 live 诊断降级

`meeting_live_pipeline.run_live_meeting_pipeline` 将共同输入、独立sealed正文和DIA观察组合为显式库入口，支持serial或显式启用的overlap；不提供模型发现、CLI、真实执行或生产服务接线。ASR回调接收 `(governor, frames, channel, body)`，DIA回调接收 `(governor, frames, channel, sink)`，两者必须加入各自native/session清理。实际ASR重放和私有root显式接受 `sealed_body`；私有root仍只允许formal/shared PCM与同一Governor，后验失败使正文记录失效。

`SealedBody` 独立于observer的关闭/失败，按真实sealed非空final unit记录句级正文与owned span；最多600秒、4096个unit和10000字符，单unit跨度不超过30秒。非法序列/时间、非空或可变units、重复finish及使用失败记录均拒绝。ASR有效完成后才能读取items与摘要；摘要只含完整状态、样本数、字符数和文字摘要。它只在本次作用域内保留文字，不落盘，pipeline退出后清除引用；失败或取消的ASR不能借部分正文形成“成功降级”。

DIA relay始终读完共同源的分人支路，另以1–64包、默认8包的有界队列交给实际DIA。模型启动失败、自取消、无效结果、队列溢出或finish超时会停用DIA、取消并加入其清理，但relay继续排空来源，使ASR继续接收完整PCM。relay交付量不等于模型接受量。finish期限从共同源最后样本的目标时刻开始，默认15秒且只可显式设置为有限正数、不超过15秒，覆盖ASR尾部等待、实际DIA结束和稳定标记交付，不能在模型结束时提前撤销，也不等relay EOF或ASR最终复核才开始计时。超时取消实际DIA和稳定发布任务并加入清理，relay仍排空、ASR仍独立继续；native回收和完整正文可能在期限后完成，因此取消请求不是端到端硬上限通过证明。

实际DIA报告先冻结为不可变快照，摘要与归属判定使用同一快照，字符计数必须为非bool整数。若DIA完整结束、live channel明确读至EOF且未失败、归属正文摘要/注册及输出字符数均匹配独立ASR正文、实际sink逐条完成的正文与稳定标记摘要及序列/span全部一致、共同源/ASR sealed/DIA稳定覆盖完整且无未完成或失败交付，则只报告 `live_attribution_complete=true`；其中仍可能包含unknown，不代表说话人正确或质量通过。否则在全部回调清理后向外部sink发送一次 `asr_body_snapshot`：`replaces_all_attribution=true`，包含完整原ASR正文和实际句级时间，所有speaker为null、state为unknown，替换此前归属而非追加重复文字。此时 `asr_preserved_as_unknown=true`、`joint_verdict=no-go`，不能通过改成unknown绕过质量门。ASR、来源核验或最终sink失败则整体失败，不报告成功保留。

sink调用有独立owned task和有限期限，默认5秒且不超过5秒；自取消及吞掉超时取消仍失败。外部重复取消加入relay、实际DIA调用、source hash/报告摘要线程及native清理，之后释放PCM队列与正文引用。报告只有摘要、状态、策略与宿主供给信息，不含快照原文或异常私有内容。`workloads.diarization` 的complete/digest描述joined relay作用域，实际DIA报告摘要另为 `diarization_report_sha256`，不得混作模型成功；worker_reaping_verified仍false。

pipeline policy冻结模式、所有deadline、DIA队列预算、降级语义及共同PCM策略摘要；相关源码摘要在执行前后复核。它不证明回调来源、实际加载字节、最终联合身份或生产降级。quality仍not_observed、certification/runtime/joint latency仍false；产品稳定标签发布、共同起点、footprint、ABBA与真实质量需独立验收。确定性回归见 `tests/test_meeting_live_pipeline.py`，只使用合成PCM和fake模型RPC。

### 会议共同宿主计时观察

`meeting_timing.MeetingTiming` 由live pipeline使用同一clock记录源包被ASR取走、验证后的ASR closed coverage（包括无文字区间）、DIA稳定水位sink进入/完成、实际文字sink进入/完成，以及ASR回调完成、DIA输入EOF和清理作用域结束。源原点从包的样本末端目标时刻反推，与共同feed报告严格核对；时钟须有限且不倒退，样本和序列必须为非bool整数。注入clock保留injected标记，不升级为真实采集或时钟认证。

每条文字只存序列、样本区间、known布尔、文字摘要及宿主时刻，不存原文/PCM/embedding。实际sink完成记录须与独立sealed正文逐条匹配；漏句、改字、重复或错误span不能用DIA报告中的守恒计数掩盖。缺失/无效unit、额外unit、未完成与失败sink分别计数；失败记录保留未完成时刻。计数描述实际交付尝试，发生unknown全量替换时不能把此前known计数解释为最终有效归属。

总计最多98304条记录，其中ASR sealed独占最多65536条、DIA水位/文字/稳定标记共用最多32767条，另预留一次最终unknown快照；最多64个开放sink ticket。DIA预算耗尽使其观察失败，不占用ASR或降级快照容量。策略冻结schema与各预算，正式重放、C0及候选源码闭包包含timing模块，旧锁/报告需重新冻结执行。

独立joined任务在实际正文sink成功返回、ASR sealed水位与已交付DIA稳定水位都越过句末后，发布一次 `stable_text`。标记只含原正文sequence、句级span、匿名speaker与粒度，不重复发送原文；unknown仍是未知归属。按句末样本组织有界待发布堆，不在每个PCM包上全扫历史。全部sink调用串行，稳定任务失败/自取消/超时取消分人并保留独立ASR正文；最终unknown替换前加入稳定发布作用域，避免晚到标记覆盖降级。重复外部取消仍加入sink清理。此为诊断库事件，未接生产服务/App。

scorer policy与 `meeting_latency_policy.latency_policy()` 冻结相同阈值及采样口径，缺字段或变更权重/quantile被拒绝。`sealed_owned_span_duration_v1` 对所有实际非空sealed ASR unit按owned span样本时长加权，以句末样本目标时刻为起点，以双水位覆盖后稳定标记sink成功返回为完成；P95取累计权重首次达到95%的观测值，不插值。缺失/无效标记及unknown保留原权重为正无穷失败，用null报告不可得分位值，任一未完成或超过30秒的unit均no-go；15秒P95边界含等号。各会议分别报告并检查最慢会议，不跨会议混池稀释慢例。实际ASR删除由独立ASR质量门核对，不补造句段或从参考向运行时注入文字/边界。

`timing_observations.latency_diagnostics` 给出上述宿主稳定发布P95、期望/失败样本权重、硬上限失败数及单会议finish秒数。finish从最后源样本目标时刻至最终交付确认、ASR回调和DIA joined作用域结束的最晚时刻，包括清理及必要的最终unknown快照；缺完整证据时finish_unresolved=true，不能丢弃该会议。finish每次执行只有一个观测。跨来源统计口径预登记为同一来源组先取全部执行最大值，再按来源组等权取P95并检查最慢来源；缺失执行使该来源保留原权重按正无穷失败。单执行入口只记录本次值，跨来源聚合由FinishCohort执行；单例超过5秒记录target_exceeded、超过15秒记录hard_failed。

这些数值和diagnostic_pass只描述宿主sink，不能证明麦克风1×采集、App/UI显示、真实生产字节或产品稳定发布验收。记录schema为2；顶层两个认证P95仍null、latency_gate=not_evaluated、certification_eligible=false。生产稳定/finish硬期限及回收验收、真实进程footprint、ABBA、最终联合身份及真实质量需独立完成；诊断取消与事后no-go不替代真实硬上限通过证据。相关确定性回归见 `tests/test_meeting_timing.py`、`tests/test_meeting_live_pipeline.py` 和 `tests/test_meeting_quality_metrics.py`。

### 会议诊断硬期限控制

独立deadline任务与稳定发布任务一起加入pipeline作用域。ASR向独立SealedBody追加实际sealed unit时，同步登记该unit的sequence、真实span及文字摘要，最多4096项；不等DIA开始或输出文字才登记，也不存第二份原文。等待堆按句末样本排序，稳定标记完成且与该独立证据匹配后才移出；没有文字交付的unit仍有期限。稳定期限固定为该句末样本目标时刻加30秒，ASR迟到使登记时期限已经过去时，立即停用DIA而不取消ASR。尚未由ASR sealed产生的未来句段无法预知，不能据此宣称其已获延迟保障；ASR封存周期仍须先做可达性审查。

finish期限为源原点加全部源样本时长再加finish预算，因而不会因relay EOF迟到或ASR复核迟到而顺延。模型已结束但稳定sink卡住仍受同一期限约束。控制器使用共同宿主clock计算期限，以event-loop timer等待；各自独立的事件通知避免稳定发布与监控互相清除通知。注入clock跳变通过进度通知重新检查，冻结注入clock仍有实际event-loop等待期限，报告明确标记timer触发而不把它当真实clock认证。

超时保留首次原因 `stable_label_timeout` 或 `diarization_finish_timeout`，记录期限、观察时刻与是否由event-loop timer唤醒；停用DIA并取消其实际operation及稳定publisher，两者清理必须加入后才允许unknown全量替换。sink交付自取消、取消吞掉、重复外部取消仍遵循owned task清理规则。监控在timer唤醒后先重读完成证据；迟到的监控不能把期限内已完成的交付误判超时，超过期限才完成的稳定标记仍会被识别。只有诊断触发记录，不上调worker_reaping_verified、runtime或certification；回收等待、ASR最终正文及unknown快照不保证在触发时刻完成。相关fake回归见 `tests/test_meeting_live_pipeline.py` 与 `tests/test_meeting_timing.py`。

### 会议 finish 来源队列

`meeting_latency_cohort.FinishCohort` 只处理已生成的宿主metadata，不打开音频、参考内容、模型或留出。构造时核对schema 2 development manifest、split lock、source catalog及scorer policy摘要，固定ASR/分人候选身份、serial或overlap模式、人数层与6/12/18/24组共同来源前缀。预登记必须覆盖选中前缀内的每个fixture及每次重复（1–8次、总计最多4096次）；每个来源须有fixture，每个fixture重复的PCM/样本数/策略须一致。同一PCM不能声明为独立来源组。控制映射保存为不可变快照，后改调用方对象不改变队列。

模型输出前可用 `CommonPcmFeed.policy()` 获取已知源参数，用 `live_pipeline_policy()` 冻结完整执行策略；这两个函数不证明PCM摘要已验证、模型可用或运行已发生。`finish_configuration()` 从策略中移除来源特有的PCM摘要/样本总长，保留clock类型、16k采样率、分包、队列与最大供给迟到等设置；该共同配置摘要也必须预登记，不能把不同来源误当不同调度设置，或在移除来源信息时连同队列/分包一起漏掉。每条执行另锁完整pipeline策略摘要、实际PCM摘要、样本数及fixture摘要，execution ID由上下文和该登记计算，队列摘要同时锁定聚合源码。

`observe(execution_sha256, report)` 接受现有live pipeline报告，核对执行身份、完整策略和共同配置、来源hash/样本/原点、记录schema及未认证标记；根据稳定标记/最终快照确认和ASR/DIA joined里程碑重算finish，不只相信摘要里的秒数。逐条核对已确认文字与稳定标记的sequence、owned span、文字摘要和known状态，检查正文确认及连续ASR/DIA水位先于稳定标记，覆盖须到达源末端；从标记确认重新计算按span时长加权的稳定P95与硬上限，不只信任stable_gate。结束里程碑不能早于源末端及对应覆盖确认。unknown、缺失/重复文字、未完成交付或最终替换快照不能靠summary布尔值冒充完整；降级、未解决finish及失败执行保留failed状态。这些核对不提供独立ASR主参考或采集证明。完整报告最多16MiB，输出仅摘要与标量；控制/报告没有实际来源、忠实解码、生产字节、真实clock或独立执行的权威证明。源码变化拒绝继续复用原队列。

`aggregate(observations)` 拒绝未知/重复execution、跨队列或篡改的observation，以及同一报告摘要在不同执行中重复使用。每个预登记来源先取全部fixture和重复执行的最慢finish，再按来源组等权使用离散逆CDF计算P95，并保留最慢来源；派生fixture更多的来源不增加独立统计权重。任一缺失或failed执行使该来源保留原权重为正无穷，JSON用null表达该来源及最差值；即使单个缺失来源占比不足5%而P95仍有限，也不能通过hard gate。P95≤5秒、各来源单次上限≤15秒且没有缺失/失败才给diagnostic_pass，边界含等号。

队列输出包括期望/观察/缺失执行数、失败来源数、逐来源结果、P95/最慢值及输入observation集合摘要；不输出原文、PCM、speaker实名或路径。它不计算质量、并发净收益或可信区间，不解锁模型执行、留出或发布；runtime_identity_verified/certification_eligible保持false、人数认证为null。调用方仍须先完成来源/参考审查、串行质量及其他联合门，不能把元数据自洽当作质量或真实P95认证。确定性回归见 `tests/test_meeting_latency_cohort.py`，含模型输出前冻结→实际pipeline合成输入→来源聚合的接线测试。

### 会议 ABBA 预登记与宿主账本

`meeting_abba.AbbaLedger` 在任何候选输出前接收已审查的development来源池摘要、attempt、ASR/分人候选、scorer与共同workload策略摘要，以及8–24个来源的fixture/PCM摘要、样本数和共同feed设置。每来源仅一份fixture，组/fixture/PCM不得重复；来源字段仅摘要和样本数，不包含音频、文字或路径。此库只锁定调用方声明的身份，不重新验证完整catalog、独立主参考、来源独立性或生产模型字节。

每个明确声明的cold/warm条件均衡分配1–8个block/来源；每块固定顺序为ASR-only、diarization-only、serial、overlap、overlap、serial。前两次是独立单路基线，不能由双路结果推算。条件适用于每次执行，不能把整个block首个运行是冷启动当作其余运行的冷启动证据；实际冷/热准备仍由后续受控执行器证明。登记记录固定来源、顺序、共同配置、源码和latency policy摘要及各run ID，后改调用方参数不改变冻结计划。

`registration()` 给出joint及含单路基线的最低PCM供给预算，不包括加载、预热、清理、人工质量复核及生产候选复验。8个来源、cold/warm各1块、5分钟片段共96次供给，最低8小时；其中64次joint供给为5小时20分钟。该预算不授权真实模型运行。

`observe()` 按登记顺序消费 `run_pcm_workload_schedule` 的宿主报告，核对mode、声明条件、时钟、PCM/feed摘要、完整单/双路lane和已交付样本，拒绝时序矛盾、源供给倒序、报告复用及认证标志升级。下一次源原点不得早于上一次已验证的callback/report校验结束及joint最终确认；只晚于EOF但仍与清理或稳定交付重叠时拒绝。接收端不执行负载，不打开模型/音频/参考，不证明回调使用了已声明模型或实际冷热状态。`fail()` 明确保留失败位置，未观察执行仍保留missing；缺单路或任一ABBA位置不得丢弃整个block后只分析成功记录。

ABBA登记schema 2可选启用joint明细分析：调用方须同时预登记所有来源serial/overlap的完整pipeline policy及各模式共同配置摘要，另给跨模式共同配置摘要。`joint_comparison_configuration()` 只去掉mode和overlap_enabled，保留其余来源无关pipeline/feed设置，拒绝两模式同时改变超时、分包、队列或实现策略等变量。摘要仅锁声明，不提供生产模型身份的权威证明。未登记joint策略时不计算收益，不能事后凭单独finish秒数补填。

启用joint时，`observe()` 将live pipeline报告交给与FinishCohort共用的 `validate_finish_report()`，核对双水位、正文/稳定标记及确认时序、重算稳定门和finish。结构错误拒绝且不前进；有效但失败的joint执行以failed位置保留。该校验器接收已冻结的期望参数，本身不替代来源catalog审查或runtime attestation。

每个条件独立生成 `conditions.<condition>.joint_finish`：同来源同模式的全部ABBA重复先取最慢finish，再来源等权取离散逆CDF P95；主点量为serial P95减overlap P95。以来源组配对bootstrap，PCG64 seed=1717、10,000次，两个模式共用同一批来源索引；差值取2.5%/97.5%的linear percentile区间。估计量、重复聚合、RNG、区间方法及NumPy版本在输出前进入plan摘要；源码或版本变化拒绝复用。独立N只按来源组计，冷/热不合并成一个区间。各模式同时报告最慢来源、5秒P95及15秒单次硬上限门。

任一单路基线、ABBA位置缺失或failed，该来源保留权重为正无穷，两个模式的区间不计算；即使24组仅一组失败而P95仍有限，也不得通过绝对门。`benefit_supported` 只表示宿主诊断区间下界大于0，不能越过质量、稳定/finish绝对门、ASR/DIA相对门、精确footprint和真实身份前置。不能用含整段供给/清理的callback elapsed替代尾音到双路确认。

工作负载schedule报告schema 2包含同一宿主clock的 `schedule_origin_at`，各lane的 `started_at_seconds/ended_at_seconds/validated_at_seconds` 相对该原点，`elapsed_seconds` 仍仅为callback进入到返回；validated在joined报告摘要校验后取时，不把它混入纯callback耗时。ABBA拒绝旧schema、缺原点/校验时刻、校验早于返回或返回早于源末端。共同PCM报告提供最后样本目标时刻，绝不从整段elapsed减一个假设音频长度来猜尾部延迟。

latency/scorer policy的 `relative_sampling` 在输出前固定每执行一个lane尾部观测：ASR使用宿主callback返回（调用方须已joined模型/会话清理），overlap相对serial；DIA-only使用callback加joined报告校验完成时刻，joint使用已校验的actual dia_scope_closed，不能拿relay/外层回调报告时刻代替。作用域里程碑不得晚于相应外层callback返回/校验。两种DIA边界均包含各自声明的清理/报告验证成本，但不声称是纯infer或真实worker回收。

`conditions.<condition>.relative_lane_tail` 同来源同模式全部重复先取最慢值，再来源等权离散P95；cold/warm各自报告。ASR overlap P95≤serial P95×1.05、DIA overlap P95≤DIA-only P95×1.10才给各自diagnostic_pass。任何单路或ABBA位置失败/缺失均保留原来源权重为正无穷并no-go，不能用少于5%的失败让有限P95绕过门。零基线时，候选也为零才可通过，ratio保持null，禁止除零或替换分母。无joint策略/时序绑定时相对门not_observed，不借未验证的scope补值。相对门与绝对稳定/finish门、主收益区间和质量/footprint/身份门并列，任何单项通过都不自动选择overlap。

schedule schema和scorer摘要变化后，旧控制锁、候选spec及ABBA计划需重新冻结执行；不能沿用旧报告认证。

`summary()` 顶层仍仅有invalid或complete_metadata，不签发生产质量、并发认证或调度选择；selected_schedule及跨条件primary_benefit_interval_seconds保持null，quality/footprint未观察，condition setup/runtime/certification保持false。确定性测试覆盖预输出冻结、48次四模式PCM scheduler及48次单路/联合live pipeline合成接线、配对常数差、重复最慢值、冷/热分离和缺失分母；未使用真实音频或模型。

### 会议显式进程树 footprint 单次读取

`meeting_process_snapshot.MacProcessReader` 显式构造后才加载macOS系统libproc；`read(pid)` 在同一次 `proc_pid_rusage(RUSAGE_INFO_V0)` 中取得原始启动absolute-time token和整数 `ri_phys_footprint` 字节值，退出/zombie、缺失或失败返回不可读。启动token保持其原始时钟单位，不作为秒级lstart或纳秒时间使用。后代枚举仅调用指定父PID的 `proc_listchildpids`，返回值按PID数量处理，错误或缓冲饱和失败。接口和布局依据 [Apple resource.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h) 与 [libproc实现](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)，并经本机SDK静态断言验证结构大小及关键字段偏移；代码不运行命令名扫描、读取命令行/环境、转换RSS或控制进程。

`collect_process_snapshot(roots, reader, ...)` 由调用方传入本attempt内现存owned handle对应的 `ProcessKey(pid, start_abstime)`，最多16个根、总进程默认/上限64。遍历后代，嵌套根去重，不重复累计；按后代到父级的第二遍核验启动token和子进程集合。缺失、PID复用、循环、多个父关系、枚举变化、预算耗尽、时钟非法或已完成读操作跨度超限均拒绝返回完整样本，不用零填失败项。它核对传入生命周期和祖先关系，不验证根所有权、可执行文件/模型身份或跨boot身份。

结果仅包含PID、启动token、物理字节、一次读取区间和该区间的逐进程读数总和。默认允许跨度1秒、配置上限5秒；这是结束后的有效性检查，不能中断正在进行的内核调用，也不形成硬墙钟超时。顺序读取不是原子快照，两遍核验不能发现所有短命进程/瞬时变化，采样间峰值亦未覆盖；atomic_snapshot_verified/peak_footprint_verified/worker_reaping_verified/certification_eligible始终false。

此入口不自动开启后台监控，也未接入ABBA的footprint门。受控runner须绑定精确owner，并显式使用下述阶段观察器；不得把单次读数或各进程不同时间的最大值之和用作真实峰值或resident声明。现有通用 `ProcessResourceMonitor` 保持其独立行为，不作为该入口的发现器。

确定性测试使用注入libproc和进程树。另有仅对验证脚本自身的单次原生只读smoke，确认FFI、生命周期一致与物理字段可读；它不采样SpeechRail/模型进程、不运行会议负载、不提供E3或峰值证据。

### 会议进程树阶段观察

`meeting_process_observer.observe_process_phases` 在同步构造时复制根生命周期和预登记阶段序列，在显式进入异步上下文时才启动采样。调用方提供reader和当次owned根；观察器不发现、启动或回收模型。首次读取尝试完成后才交还控制权，失败样本仍保留。每个观察器使用独立单线程executor，原生读取不占用ASR事件循环；退出通过共享 `join_cleanup` 等待已开始的读取与executor线程结束，重复取消不能遗留线程。读取跨度预算不能中断原生调用，退出可能等待该调用返回，不承诺硬墙钟截止。

阶段槽位可重复，按注册顺序逐一推进，最多64槽；允许cold_start、steady_state、silence_recovery、overlap、finish和cancel。实际阶段边界由受控runner标记，不从模式名推断冷/热状态。结束或预算耗尽后拒绝新阶段标记。示例中的 `owned_roots`、`reader` 和负载函数均由已授权的runner提供：

```python
from meeting_process_observer import observe_process_phases

context = observe_process_phases(
    roots=owned_roots,
    reader=reader,
    phases=("cold_start", "steady_state", "finish"),
)
async with context as observation:
    await controlled_load()
    observation.advance_phase("steady_state")
    await controlled_workload()
    observation.advance_phase("finish")
    await controlled_finish()
resource_report = observation.report()
```

策略限制为每次最多4096个样本、每样本最多64进程、采样间隔0.01–5秒、读跨度0.001–5秒。间隔在前次读取返回后计算，不补发积压tick，不假设均匀采样。报告保留逐次宿主起止、读跨度、逐进程 `[pid, start_abstime, phys_footprint_bytes]`、失败和跨阶段记录；observer_span包含派发、读取及事件循环恢复等待，不等于CPU开销或已隔离的测量扰动。跨阶段读取不计入任一阶段覆盖；未进入/无有效样本的阶段保留空值，失败不填零，预算耗尽或监控故障保持incomplete_metadata，reader来源变化亦拒收。

全部注册槽有有效样本且无读取失败、预算耗尽和监控故障时，状态仅为complete_metadata。每阶段最大值只是有效顺序样本总和的已观察最大值；报告始终不宣称原子快照、真实峰值、worker回收、运行身份或认证通过。阶段报告含进程元数据，真实制品保留在仓库外，不进入公开审计。ABBA footprint仍为not_observed；精确owner/负载接线、完整场景矩阵、测量扰动及授权实跑仍需单独验证，不据此修改resident声明。

### 已就绪私有 owner 的资源绑定

`FrozenAsrRuntime.capture_process_scope(reader=...)` 从仍有效的私有ASR/aligner owner取得两个实际子进程对象；`NativeCandidateRun.capture_process_scope(reader=...)` 仅在原生分人会话已预检且owner仍占用时绑定实际transport。分人入口核对原governor、owner对象、generation和attached child、transport、artifact与端口guard；ASR入口复用原有就绪配置、generation和进程对象校验。未启动、替换、隔离或已关闭的owner不能登记，不通过命令名或历史PID发现目标。两者都要求显式reader，不启用默认原生读取。

共同入口 `capture_owned_process_scope` 保留确切句柄对象及其live状态，用专用线程取得启动token并进行进程树两遍复核；登记及线程退出均通过join_cleanup等待，结束后再次核对原owner。返回的scope不转移进程生命周期所有权。`scope.observe(...)` 将owner guard接入阶段观察器：每次读取前后及观察关闭时，在事件循环上核对同一对象、PID、存活状态和reader来源；失败计入scope_guard_failures，拒收该读数或使报告incomplete_metadata，不能因为先前有成功样本而继续宣称完整。guard不在原生读取线程访问事件循环所属状态。

调用顺序如下；`runtime` 已由调用方在明确授权的窗口准备，观察上下文必须先于runtime关闭：

```python
scope = await runtime.capture_process_scope(reader=reader)
async with scope.observe(phases=("steady_state",)) as observation:
    await controlled_workload()
resource_report = observation.report()
```

这种scope从已就绪句柄开始，明确拒绝cold_start阶段。ASR两根不包含宿主VAD、PCM/队列或原生分人，分人一根不包含宿主和ASR；采样前的加载、进程回收后的区间亦未覆盖。它们不能分别取峰再相加、不能组合成T6总内存认证，也不证明登记前的启动历史、加载字节或无采样间瞬时变化。完整共存harness的宿主根、加载至回收的全生命周期、finish/cancel与完整场景矩阵仍待接线；ABBA footprint、峰值/回收/运行身份认证仍未观察。资源helper已进入ASR冻结源码闭包及C0/fast候选adapter身份，旧候选spec/controls须重新冻结，不能沿用旧收据。

合成验证命令（不执行原生reader、模型或音频）：

```sh
PYTHONPATH=src:examples/perf uv run --no-sync pytest \
  tests/test_meeting_process_owner.py \
  tests/test_meeting_process_observer.py tests/test_meeting_process_snapshot.py \
  tests/test_profile_metrics.py tests/test_resource_sampling.py --no-cov
```

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
