# 会议转录与分人实施计划

> **For agentic workers:** 使用 `executing-plans` 按任务逐项执行；复用当前授权，步骤不扩大下载、模型运行、安装或发布权限。每项产出可评审 diff，未经明确要求不自动提交。

**Goal:** 固定现有 Qwen ASR，提升 SpeechRail 转录真实性、分人归属、用户体验、性能与资源效率；以真实开发片段持续验证产品改进，评测工具只补足必要证据。

**Architecture:** 正文与说话人活动分别计算，按样本时间证据归属。分人会话只有一个权重 owner，计算通过独立 governor lane；候选先在隔离 native probe 评测，通过后才更新主服务和公共能力。

**Tech Stack:** Python `>=3.14,<3.15`、Swift/CoreML、Apple Silicon macOS 26+；候选 FluidAudio `v0.17.7`，FP16；pytest fake backend、独立 pyannote/MeetEval scorer。

**Spec:** [会议转录与分人：调研与设计](../specs/2026-10-18-meeting-asr-diarization-research-design.md)。用户于 2026-10-18 批准实施，并授权在同一 PR 提交方案和持续实施；评分策略已获批准，新模型仍未生产认证。进度与验证见[实施记录](../../implementation/2026-10-18-meeting-diarization-handoff-audit.md)。

## Global Constraints

- ASR 固定现有 Qwen，不替换为其他 ASR 或联合转录/分人模型；MOSS-Transcribe-Diarize 候选停止，不下载、安装或实跑。分人链路独立优化，不能以更换 ASR 绕过质量目标。
- 一个服务、一个 ASGI worker，同一已加载权重只有一个 owner；同分人 lane 串行。
- 运行时 PCM/模型缓存仅存有界 RAM，不持久化 PCM、embedding 或跨会话身份；真实评测语料、参考、日志与结果均在仓库外。
- 请求路径不下载、编译或访问远程模型；候选编译与准备在请求外完成。
- 保留 19 项接手改动；同一文件只由一个执行者写入，发现来源不明的并行修改先停写核实。
- 不因模型具有八槽而写 `max_speakers=8`；认证绑定模型、策略、语料与 scorer。
- 不覆写旧评测收据、不偷看留出调参，不用 temporal oracle 冒充 DI-cpWER。
- 本计划不包含 App 视觉改造、数据库迁移或 UI 自动化；如实际需要，按新范围处理。

## Review Focus

1. 后处理改变输出但候选身份未变：T1 必须有摘要变化和跨配置收据拒绝测试。
2. 短插话和 overlap 被丢出分母或错误并入主讲：T2/T5 保留总量与逐人失败，不能以 min-turn 过滤掩盖。
3. chunk 已释放计算 lane 但旧 worker 仍持有权重：T3 覆盖两个会话交错、回收失败、迟到关闭。
4. 分人失败隔离 ASR、FIFO 队头阻塞独立 lane：T3 验证两方向故障及同 lane FIFO。
5. 开发结果、固定 ASR sidecar、机制模拟被当作生产联合认证：T6/T7 分别绑定真实运行身份、留出与安装态证据。

## 顺序与独立交付

分人主线为 `T0 → T1 → T2 → T3 → T4 → T5 → T6 → T7`；ASR 工作线 T8 在 T2/T5 的数据与评分准备好后进行。T8 若改变 ASR，须先重跑 T6，再进入 T7。T7 内部顺序为生产候选接线/构建（默认关闭）→摘要变化时复验开发/共存→冻结身份→一次性留出→安装态验收，留出后不重建受认证的 worker。

T1/T2 是认证可信性基础，T3 是独立资源修复；三者可以先交付，不等新模型。T4/T5 完成后若无合格候选，后续认证停止。任何开发结论都不能替代 T7；#370 的 ASR 10% 改善目标独立跟踪。

## T0：固定接手基线与实验边界

**Files:** 读取现有 Git diff、原评测记录、ADR-0012/0016/0022；创建 `docs/implementation/2026-10-18-meeting-diarization-handoff-audit.md`（实施时）；更新该目录 README。

**Interfaces:** 向 T1–T8 提供接手 commit、每项未提交修改的摘要、待评候选清单和逐项证据状态，不提供用户私有配置值。

- [ ] 检查 `git status --short --branch`、worktree/分支差异和未提交文件；先生成仓库外 patch 与新增文件的可恢复副本。复制现有授权范围内源文件，不备份无关私人目录。
- [ ] 把最新 `main` 与接手修改逐文件比较，制定保留式整合；新分支使用 `codex/` 前缀。清楚处理源改动归属前不 checkout、rebase 或整文件覆盖。
- [ ] 记录 `E0..E5` 现状：现有代码和部分机制测试已报告；真实并发 A/B、footprint、版本回滚未验；旧质量报告保持 no-go。
- [ ] 在新输出前冻结 C0/C1/C2、语料追加规则、参考标签风格和 scorer；产品门语义未批准时只能做诊断，不能签发 go。
- [ ] 将设计 §5.5 的延迟预算、§6.4 的必过门和 §6.5 的扩样/停止规则写成可审阅 policy；批准后固定摘要。缺层、null、证据不足和试验失败不能签发通过。
- [ ] 在预算冻结前核对实际 ASR 窗口/封存周期的延迟下界；ASR 与分人水位迟到分别记录。联合预算不可达时先提出具体策略/预算修订，不能等看完候选结果再改门槛。
- [ ] 验证：逐项清单能回溯到文件/产物；原有未提交内容均可恢复，未进行运行态动作。

## T1：让有效配置成为候选身份

**Files:** 创建 `examples/perf/meeting_evaluation_identity.py`、`tests/test_meeting_evaluation_identity.py`；修改 `examples/perf/probe_meeting_sortformer_1to4.py`、`tests/test_probe_meeting_sortformer_1to4.py`。

**Interfaces:** 新增冻结 dataclass `MeetingCandidateSpec`，包含 `implementation_id/adapter_sha256/sdk_revision/worker_sha256/model_revision/model_files_sha256/dtype/preset/compute_units/decoder/attribution/scorer`；preset、decoder、scorer 为仅含 JSON 值的完整映射。`candidate_digest(spec: MeetingCandidateSpec) -> str` 使用排序 canonical JSON；`validate_execution_identity(spec: MeetingCandidateSpec, observed: Mapping[str, object]) -> None` 不匹配即拒绝。收据 `schema_version=2`，分别绑定最终 development manifest、预定 holdout manifest、scorer-policy 与运行策略；依赖单向，不把收据自身摘要纳入 candidate/manifest。

- [ ] 写失败用例 `test_consolidation_changes_digest`、`test_threshold_and_preset_change_digest`、`test_dict_order_does_not_change_digest`：输出行为参数变化必改摘要，键序变化不改摘要。
- [ ] 写 `test_actual_worker_mismatch_fails_before_inference`、`test_dev_receipt_cannot_unlock_other_decoder`、`test_legacy_receipt_cannot_unlock_new_experiment`；断言在模型调用前拒绝。
- [ ] RED：开发/留出 manifest 不同仍按各自锁验证；收据字段不存在循环摘要。attempt 在推理前原子落盘，重复执行者拒绝；worker 重编译/重签或 adapter 改变不能复用原收据。
- [ ] 运行上述定向测试确认 RED，再接线实际生效的配置、worker/model 校验和新收据。历史 `frozen_phase1_candidate_spec` 与旧收据保留作只读解释，不能签发新认证。
- [ ] 再次运行同组测试确认 GREEN，并复核不带 consolidation 的旧诊断输出仍可解释；本次新版本不沿用旧摘要。
- [ ] 验证命令：`uv run --no-sync pytest tests/test_meeting_evaluation_identity.py tests/test_probe_meeting_sortformer_1to4.py --no-cov`。

## T2：拆开产品门、标准指标与 oracle 诊断

**Files:** 创建 `examples/perf/meeting_quality_metrics.py`、`tests/test_meeting_quality_metrics.py`；修改 `examples/perf/diarization_quality.py`、旧 probe 及其测试。八人新 runner 消费本任务接口，不复制四人 scorer。

**Interfaces:** `score_meeting_quality(reference, hypothesis, *, duration: float, policy: Mapping[str, object]) -> dict[str, object]` 输出 `legacy_nonoverlap/product_all_regions/standard_metrics/diagnostics`，各自带明确分母、版本和可用性。`policy` 必须完整声明 recall/precision 门、top4/other、scorer 与 token 化，不在函数内偷偷填生产默认值。缺标签、空分母或未覆盖层返回 null/not_observed，不能通过门。

- [ ] RED：`test_overlap_contributes_to_speaker_time_denominator`，两位参考同时讲话 1 秒，Dref=2 speaker-seconds；仅正确输出一位时 recall=0.5，不为 1。
- [ ] RED：`test_extra_speaker_and_reference_silence_reduce_precision`、`test_unknown_and_empty_reference_cannot_pass`、`test_subsecond_interjection_stays_in_denominator`。假设额外标签计错，未知不映射为真值。
- [ ] RED：`test_temporal_oracle_is_not_reported_as_dicp`、`test_eight_speaker_cp_matches_reference_assignment`、`test_time_constraint_changes_tcp_without_changing_cp`。人工小样本覆盖重复词、错时间、交叉说话和 unmapped speaker。
- [ ] RED：标准 cp/tcp/DI-cp 保留全部 unknown stream 原文、遵循官方 assignment；产品 speaker-time 匹配排除 unknown，并另报 unknown 文本比例。标准得分优良不能使全 unknown 通过产品门；重叠主 CER 无合法参考规则时返回 not_observed。
- [ ] 在 Python 3.14 隔离 scorer 环境先验证 `pyannote.metrics==4.1`、`meeteval==0.4.3` 的实际安装、导入和最小 cp/tcp/greedy DI-cp；记录完整 lock/制品摘要，不污染服务运行依赖。失败则报告兼容性阻塞，不降低项目 Python 基线；必须换版本时在新输出前更新身份。char-token 版单独命名。
- [ ] 旧 temporal oracle 改诊断名称，不重算/覆写历史结果；历史 cp−oracle 差值不再报告为已验证的标准分人误差增量。
- [ ] RED：旧门与全区间门并行；pooled 与宏平均不能互代，逐人失败不被平均掩盖。下界未达门槛属于证据不足，null/缺层不能通过，认证上限不能跨缺失人数层。
- [ ] RED：bootstrap 按来源组以 seed=1717 重采样 10,000 次、取双侧 percentile 95% 区间；配对模型共用抽样索引，重复窗口不增加独立样本数。
- [ ] RED：≤4 人对 C0 的 DER/cpCER 不退化点差及配对区间判定；选型差异区间跨 0 不能自动判等价，只有预定 1pp DER 非劣界满足后才允许优先更快者。
- [ ] GREEN：`uv run --no-sync pytest tests/test_meeting_quality_metrics.py tests/test_meeting_diarization_quality.py tests/test_probe_meeting_sortformer_1to4.py --no-cov`。
- [ ] 验证新 policy 的语义与正式质量文档一致；现行 #370 门值不降低。设计 §6.4 的全区间门作为新增必过项，单独更新 ADR/契约后冻结，不重命名或覆写旧 known 指标。

## T3：修复分人 owner、故障隔离与排队

**Files:** 创建 `src/speechrail/runtime/diarization_owner.py`、`tests/test_diarization_owner.py`；修改 `runtime/resource_governor.py`、`backends/diarization/{coreml,meeting}.py`、`application/services.py`；扩展 `tests/test_diarization_lane.py`、`tests/test_meeting_diarization_session.py`、已有 CoreML session 和 governor 测试。

**Interfaces:** `DiarizationSessionOwner.claim(epoch: str) -> int` 在事件循环内同步原子认领；已占用抛现有 queue/busy 错误，隔离抛 `GovernorLaneIsolatedError`。`release(generation: int, *, reaped: bool) -> None` 仅精确 owner 可释放，`reaped=False` 保持隔离/引用，迟到 generation 不能释放新 owner。owner 与 worker close 责任只设在一个 session 关闭入口。Governor 新增 `quarantine_diarization_lane() -> None`；不扩展公共 API。

- [ ] RED：两个 session 交错 append；第二个在创建/启动模型前 busy，worker factory 仅调用一次。chunk 之间 lane 空闲也不能创建第二份权重；旧四槽与会议路径共用 gate。
- [ ] RED：`test_diarization_close_failure_isolates_only_diarization_when_overlap_allowed`、infer 失败后 close 再失败、ASR quarantine 反方向测试；`allow_heavy_overlap=False` 时所有轴 fail-closed。
- [ ] RED：隔离唤醒已排队 waiter；重复 cancel/finish；close 确认前禁止新 owner；旧 generation 迟到释放不影响新会话。
- [ ] RED：模型 load、infer、finalize 均在分人计算预留下执行；cancel 中途退出、回收失败后仍计入失联资源占用。资源上界可信时只隔离自身 lane；上界不可信时全体 fail-closed，不因 async context 退出就假释放资源。
- [ ] RED：`test_busy_diarization_waiter_does_not_block_independent_batch_asr`，同时覆盖相反顺序、同 lane FIFO、deadline/取消后队列清空、realtime 预留与 aging。仅被占用 lane 阻塞的前项可被独立 lane 越过，不能任意重排。
- [ ] 实现最小 owner 和独立 quarantine，修正两处 `quarantine_asr_lane()`；统一 `lane_available` 与实际规则。核实常驻互斥后才能使用 streaming/dynamic footprint 的 max；不满足就分别声明并求和。
- [ ] GREEN：定向 fake 回归及原 governor/应用组合回归；同时检查 pending/active/隔离状态、准确子进程回收和 lane 计数，不只检查任务返回。
- [ ] 验证命令：`uv run --no-sync pytest tests/test_diarization_owner.py tests/test_diarization_lane.py tests/test_diarization_overlap_policy.py tests/test_meeting_diarization_session.py tests/test_diarization_worker.py tests/test_diarization_sdk.py tests/test_diarization_session.py tests/test_resource_governor.py tests/test_application_composition.py --no-cov`。

## T4：隔离的 CoreML 八人候选 probe

**Files:** 创建 `native/diarization-candidate/Package.swift`、`Package.resolved`、`Sources/MeetingDiarizationCandidate/main.swift`；创建 `examples/perf/probe_meeting_candidate.py` 与 `tests/test_probe_meeting_candidate.py`。复用私有 packet codec 和领域 ActivityFrame，不修改第三方 checkout。

**Interfaces:** CLI 提供 `preflight/evaluate-development/evaluate-frozen-holdout`，接收显式外部 `--manifest/--model-directory/--output-directory/--candidate-spec`；只有 preflight 默认只读。runner 的 session 接口仍是 `append(start_sample, pcm16)/finish(through_sample)/cancel()/updates()`，输出统一样本时钟 ActivityUpdate；T1 负责身份，T2 负责评分，runner 不自创门。

- [ ] RED：以 fake packet producer 验证 8 维有限概率、slot<8、非法维度/NaN/epoch/watermark 被拒绝；不规则分包与一个 sample 尾包不超 accepted_samples。
- [ ] RED：finish 吐齐尾帧、repeat finish 不重复、cancel 在回收前不释放 owner；无模型网络访问。已知 manifest 人数/显式请求约束超过认证范围时标为范围外或依契约拒绝；未知人数音频不得承诺自动检出第九人，不能将八槽输出当溢出检测器。
- [ ] RED：C1/C2 固定 `score > 0.5`，恰好 0.5 不活动；10ms 帧、跨 chunk 连续段及 <200ms 插话保留，尾帧裁到 accepted_samples。禁止隐式继承 SDK `minDurationSeconds=0.2`，如用 segments 则显式设 0；关闭 min-turn/bridge/ghost，并纳入身份。
- [ ] 原生包锁定 `v0.17.7` 对应 revision `503b4bd1bbf7220882de39fe8ae6716aae4132da`，仅使用本地 `Nemotron3Models.load(config:directory:)`；Swift actor/单 task 独占 diarizer。
- [ ] 接 `appendAudio/processBufferedAudio/finishStream`，每 chunk 计算与前端缓冲分开；禁止 `processComplete` 收集整场 PCM。缓冲不足/消费者慢时有界失败，不静默丢样本。
- [ ] 单一 runner 内复用 T3 的 owner 与计算租约，原生模型加载前取得 owner，精确回收后释放。真实 probe 只在明确评测窗口执行，先确认服务侧没有在用或驻留的分人 worker；进程内 owner 不构成跨进程互斥。若需服务内共存验收，使用 T6 同一组合根的 harness，不另开一套服务。不得由 probe 擅自停现有服务。
- [ ] 固定 C1 fast32、C2 fast128，FP16、模型与静态形状匹配；全部参数交给 T1。没有获准下载/模型运行时只交付 fake/preflight，不冒称候选可运行。
- [ ] GREEN：`uv run --no-sync pytest tests/test_probe_meeting_candidate.py --no-cov`；获准构建时执行该 native 包的 `swift build -c release` 并保存 executable 摘要。该命令仅产出 CLI，不产 App；主服务 Package.resolved 在此阶段不变。

## T5：开发数据与有限候选对照

**Files:** 创建 `examples/perf/prepare_meeting_evaluation_manifest.py`、`tests/test_meeting_evaluation_manifest.py`；复用已有语料准备工具。manifest、split-lock、音频和人工参考只写仓库外。

**Interfaces:** 输出 schema=2 manifest：`source_meeting_id/derived_from/channel/reference_label_policy/independence_level` 及各制品摘要；不含真实身份。split-lock 与收据单向引用 manifest 和 candidate，不引入互相包含的循环摘要。

- [ ] RED：同会议不同窗口/通道跨 split 被拒绝；冻结 Eval_Ali/test/R004 不能作 development；缺人数层不认证；自然单人和派生单轨有不同标签。
- [ ] RED：仅更换参考风格/人工校验版本或 scorer policy 就改身份；无语音、短插话、reference overlap 保留分母。
- [ ] RED：追加只按固定来源池及 6/12/18/24 检查点进行；该层全部未淘汰候选和 C0 对照使用相同前缀、共同扩样，不能用不同样本数作配对排序。点值失败不复活，证据不足按规则停止；留出组数由共同开发终点决定，执行中不得追加。
- [ ] 按设计 §6.2 的先验规则形成首批数据；已有 dev-v2 四条作诊断组。人工审查源标签，不能按 C1/C2 输出修改真值。全局人身份无法核实时明确只保证 meeting-disjoint。
- [ ] 在获准真实质量评测后，使用同 PCM、参考、ASR sidecar 与 scorer 跑 C0/C1/C2；多模型串行加载，上一 exact child 确认退出后再启动下一候选。
- [ ] 以会议组配对统计选唯一候选；满足产品门和 ≤4 人对 C0 不退化门后，按设计 §6.5 的主 DER、预定非劣界及择优顺序选型。差异跨 0 不能当等价；失败/样本不足保持 no-go，不补阈值搜索。
- [ ] 验证 fake 命令：`uv run --no-sync pytest tests/test_meeting_evaluation_manifest.py --no-cov`。真实执行命令由 T4 CLI 的 `--help` 生成并写入脱敏报告，含确切 candidate/manifest/scorer 摘要、退出状态与逐场结果；本计划不虚构尚未实现的参数调用成功。

## T6：测真实共存而非 sleep 模拟

**Files:** 创建 `examples/perf/bench_asr_diarization_overlap.py`、`tests/test_asr_diarization_overlap_harness.py`；实施时创建带日期的仓库内脱敏报告，原始结果在仓库外。按需修订 ADR-0022 和旧计划的验收状态。

**Interfaces:** harness 接实际 ASR callable 与 T4 candidate session，使用同来源 PCM、同分包；模式为 `asr-only/diarization-only/serial/overlap`，记录 `queue/load/infer/finalize/close/footprint`、ASR 正文摘要和质量，输出 schema 与配置身份。A=serial、B=overlap，单路基线另测；不得读取旧 sidecar 当作本轮 ASR。

- [ ] RED：fake 双路负载证明串行不交叠、重叠只在策略获准时发生；失败、超时或只完成一路必须判失败；缺真实 ASR provenance 不能签发质量不变。
- [ ] RED：metrics 记录真实时钟，不把输入缓冲延迟/queue wait 写成纯 infer；单路基线、ABBA block、冷/热状态和候选身份不齐全则报告 invalid。未输出/超时区间不能从延迟分母丢弃；同时报告逐会议 P95 和最慢会议。
- [ ] RED：按 1× PCM 时钟测稳定标签和 finish 延迟；超 30 秒/15 秒单次时限终止分人并保留正文，watermark 前标签不得当稳定标签记账；离线快放结果不能签发延迟通过。
- [ ] 用户明确授权 benchmark 与模型运行后，每个拟声明冷/热条件总计至少 8 个 ABBA block，均衡分到至少 8 个独立来源组，同一来源重复先组内汇总；运行时长按设计 §7 事前核算。同时更换模型的实验另列。T8 改变 ASR 或 T7 构建改变执行字节后重跑，不能复用旧共存收据。
- [ ] 测 exact PID/后代的 footprint，不能用 RSS×2；有界队列、PCM、worker 全部纳入。设置 resident 声明前按 local-deploy skill 核对运行态，不能在 harness 中静默改 `.env`。
- [ ] 事前冻结相对 P95 容忍和绝对产品门：建议 ASR 相对串行 ≤+5%、分人相对单独运行 ≤+10%，同时稳定标签 P95≤15 秒、finish P95≤5 秒。并发收益主量固定为尾音到双路均定稿的延迟，串行减并发的配对区间下界须 >0，不在结果后改用排队指标。并发未过但串行过绝对门时，按串行策略进入 T7；两者都失败则 no-go。
- [ ] fake 验证：`uv run --no-sync pytest tests/test_asr_diarization_overlap_harness.py --no-cov`。真实报告必须给实际运行命令、负载、配对区间、质量和内存；只运行 fake 时 E3 仍未验。

## T7：冻结生产候选、留出与安装态交付

**Files:** 新 ADR（实施时分配未占用编号）；`native/diarization/Package.swift`、`Package.resolved`、worker/adapter/composition/asset catalog、release 打包入口（复用认证制品）；`contracts/{realtime-openai.md,realtime-events.schema.json,openapi.yaml}`、相关用户/运维文档；Python/Swift 能力和协议测试。相关 Swift 入口为 `SpeechRailControlKit/RealtimeContractTypes.swift`、`SpeechRailApp/MeetingSessionProductionWiring.swift`，按实际调用影响定位补全。

**Interfaces:** 保留公共后端键 `meeting_dynamic`，改为通过认证的 meeting streaming 实现；`system_cap=8`，认证前 `max_speakers=null`/not-ready，认证后填已证明的连续人数上限。`system_cap` 枚举加入 8；公共 `max_speakers` 已允许从 1 起，保留该语义并检查内部校准/证书是否残留“至少 5 人”的假设。旧策略文件不被当作新模型认证，失败显式说明。worker 维度/时间粒度由实际 backend identity 校验，不全局把所有旧四维检查改成宽松 32 维。生产候选先在仓库/外部 staging 构建并保持默认关闭，不提前安装或改运行态。

- [ ] 前置：唯一候选已通过开发门，T6 已选定可过绝对门的 serial/overlap 策略，新产品 scorer-policy/ADR 已明确。仅有原型通过不能直接认证生产制品。
- [ ] RED：收据与任一 runtime/scorer/policy 摘要不匹配即拒绝；cap8/maxnull 一致；第9人不被认证；ASR 正文在分人失败时完整保留；新旧连接匿名 label 不串会话。
- [ ] RED：认证 worker/adapter 打包前后字节一致，打包不得触发隐式重编译/重签；留出只有唯一候选和已锁定 C0/A0 对照，不能临时加入第二模型。C0 的旧 SDK/制品保持独立固定。
- [ ] 留出前把冻结的 SDK/model/decoder 接入生产代码，同步契约、测试、文档和 notices，并构建待验生产 worker/adapter；需签名时先完成已获准签名。默认关闭，不安装、不启动服务。改变字节/配置时，让生产候选重新通过同一最终开发集与 T6，签发对应新收据；只做接线不再调声学参数。
- [ ] 连同 T8 的最终 ASR 及 serial/overlap 策略冻结联合身份；每层留出组数在执行前固定为 `max(12, 2 × 共同 development 组数)`，不超过 48。ASR 不改进而仅交付分人时，显式绑定 A0，#370 保持未完成。不能在已暴露留出上继续调 ASR 再作为新认证。
- [ ] 留出开始前原子认领并持久化一次性 attempt。成功/失败均消费；仅预定义基础设施故障可按原候选重试，不因声学失败、超时或换参重跑。缺人数层则范围仍未认证。
- [ ] 获准真实评测后，以冻结生产制品执行独立留出；通过后才签发证书与生产 ready。留出失败保留默认关闭，不安装。留出后不得重编译/重签 worker 或修改 adapter 并沿用旧认证。
- [ ] 获准构建/安装时按 release skill 封装 wheel，复用并核验已认证 worker/adapter 的相同字节和配置，再执行安装态评测，使用现有唯一 managed runtime；打包步骤不得重新构建 worker，不得裸跑 App xcodebuild 或顺手安装另一副本。
- [ ] 获准联合长稳窗口后完成既有 30–60 分钟和两小时专项门，检查晚加入、短插话、长静音、finish/cancel、内存增长与保存恢复；未覆盖项保留未验，不用 smoke 替代。
- [ ] 获准版本回滚后恢复上一 managed release 和原私有配置，确认唯一服务/worker、能力与串行策略恢复；不覆盖用户数据库。该过程失败则记录实际状态，不宣称完成。
- [ ] 验证只运行相关 fake/契约/Python/Swift 测试；完整 gate、真实模型、安装、UI 自动化分别按当前授权执行。最终报告分列：代码完成、开发通过、独立留出通过、安装通过和仍未通过的 #370 条件。

## T8：独立定位并改善 ASR 正文损失

**Files:** 创建 `examples/perf/probe_meeting_asr_quality.py`、`tests/test_probe_meeting_asr_quality.py`；复用 T1/T2 身份和评分接口。实际 ASR 修复文件在单变量诊断定位后确定，不先改模型/分块配置。

**Interfaces:** 输入固定外部 manifest、实际 ASR candidate-spec，输出原始正文 CER/WER、错误分类、时间戳/归属诊断和执行身份；不依赖分人输出重写正文。诊断基线与可上线候选分开，官方 vLLM 示例不能当 MLX 能力证明。

- [ ] RED：旧 sidecar 不冒充本次实际 ASR；ForcedAligner 仅改时间戳不能计正文收益；规范化前后分别记录，不能删难字或关键事实降低 CER。
- [ ] RED：基线与候选须同 PCM/参考/token 化；缺帧、截断、重复、超时、null 分母保持失败；没有参考文本进入 prompt/context。
- [ ] RED：A0 的 CER 为 0 时相对改善不可定义，不能报告无穷收益或达成 10%；缺主参考不能用任意重叠转写顺序生成通过结论。
- [ ] 冻结实际 A0；对照同权重的生产流式与有界长块诊断，区分切块/VAD 损失、decode 截断、声学替换和评分差异。错误归因只看开发集，原始内容保留在仓库外。
- [ ] 每个短循环只登记一项已定位的 Qwen 管线修复，以同源实跑决定保留或淘汰；不更换ASR模型，不引入联合转录替代路线，不穷举模型/阈值或重复已无收益的精度对照。
- [ ] 候选须相对 CER 点改善 ≥10%、95% 配对区间支持正收益，关键事实单独人工复核；ASR 改变后重跑 T6，再与分人唯一候选联合冻结进入 T7。未过门可显式绑定 A0、独立交付已认证部分，#370 保持未完成。
- [ ] fake 验证：`uv run --no-sync pytest tests/test_probe_meeting_asr_quality.py --no-cov`。真实运行使用明确授权的外部数据与当前 adapter；没有运行就只交付诊断工具，不宣称 10% 已达。

## 规模与交付判定

分人主线工程估计 7–12 人日，ASR 归因工具另估 1–2 人日、实际 ASR 修复待归因后另估；语料与标注另计。依据与不确定性见设计 §8。实施者每次收尾记录实际改动、验证命令/日期/结果和回退，不以 todo 打勾证明验收。

实施先覆盖 T0–T3：先让证据可信、分人失败不拖垮转录；T4 以后按可复现候选和阶段条件推进。若无合格候选，成果是可信的 no-go 和可独立交付的资源修复，不能关闭质量问题。
