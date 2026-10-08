---
title: "SpeechRail 测试与验收"
status: active
version: "3.3.9"
date: 2026-10-08
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
执行 Ruff、Mypy、版本一致性、OpenAPI lint、用户文档、MCP、macOS 测试清单及分人契约回归，
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

GitHub Actions 使用同一套锁定依赖门禁：`quality` 运行 Ruff、Mypy、版本一致性、OpenAPI lint、OpenAPI 路径对齐、MCP 工具面（`tools/list` / `resources/list` / 文档 / skill manifest）对齐、分人契约回归和差异空白检查；`test` 在 `macos-26` 的 Python 3.14.7 环境中构建一次 wheel。`scripts/ci_python_gate.sh` 让非 wheel 测试与构建并行，随后通过 `SPEECHRAIL_WHEEL_PATH` 让 wheel 测试消费该制品；两段 coverage 合并后仍强制 80% 门槛，任一段失败均阻止 artifact 上传。`swift-tests` 和 `macos-app` 使用独立的 `macos-26` arm64 runner，分别执行完整 SwiftPM 测试及 Xcode App 构建，不运行 UI 自动化或重复执行 Xcode 测试。`Gate Summary` 必须等待并验证每个选中的 job；被选中的检查意外 skip 也会失败。`package` 下载已测 wheel，只做压缩包、Darwin CoreML native worker 和 checksum 校验后上传，避免重复同步依赖和构建。普通 CI 与 tag Release 的 `package` 都使用 `macos-26`。Ubuntu 仅承载平台无关的 Quality Gates，不代表产品运行支持。CI workflow 同时支持普通 push/PR 和 Release workflow 的 `workflow_call`，Release 不重复维护 Python 检查命令。

编译缓存按平台、工具链及锁定依赖隔离，只为内容未变的跟踪输入恢复时间戳；源码修改仍触发重新编译。Xcode 构建通过仓库包装脚本执行，结束时注销并删除临时 App 包，只保留可重用编译输入与输出。uv 使用官方缓存裁剪，不继续恢复旧的整目录大缓存。耗时口径、实测范围及 `<50%` 验收条件见 [CI 效率分析](ci-efficiency.md)。

非 wheel pytest 由 `pytest-xdist` 使用两个进程按文件调度；同一测试文件的用例和 fixture 保持在同一进程，worker 自动重启关闭。`pytest-cov` 先合并两个 worker 的 coverage，wheel 阶段再追加并检查原 80% 门槛；不因并行执行而跳过用例、降低门槛或重试失败。

音色的流程、并发和路由测试使用 fake backend；仅显式导入 `voice_test_fixtures` 的模块会自动启用音高 fixture，每个用例后恢复真实函数，避免每次状态机断言都重复执行昂贵的自相关计算。真实音高估计仍由专门的声学门禁测试验证，输入质量和流程安全断言继续执行；这些流程测试不代表真实模型质量验收。

版本 tag release 还会并行构建 unsigned arm64 DMG。发布前核对 tag、App bundle 版本、App 架构、DMG 可挂载内容和 wheel/DMG checksum；最终 Release 资产为 wheel、`SpeechRail-<version>-macOS-arm64.dmg` 和 `SHA256SUMS`。GitHub 上生成的 DMG 不做 Developer ID、notarization 或 staple，因此不能替代本机正式分发验收。

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
| installer / zero-setup 传双 spec，分人供给按显式 aligner 门控 smoke | `tests/test_installer.py`（`test_managed_install_adds_diarization_when_configured`、`test_managed_install_without_diarization_assets_omits_diarization_config`）、`tests/test_video_podcast_skill_install.py`（`test_zero_setup_without_aligner_skips_diarization_smoke`、`test_zero_setup_with_aligner_runs_diarization_smoke`）|

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
