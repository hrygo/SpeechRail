# 服务端 Issue #138–#145 交付记录

日期：2026-10-03
分支：`codex/server-issues-138-145`（基线 `main` @ `fe95b7836c69e32613ada0fe067a6a6f996973ad`）
方案：[2026-10-03-server-issues-138-145-luna-guide.md](./2026-10-03-server-issues-138-145-luna-guide.md)

## 1. 交付状态

八项缺陷已完成修复、测试、契约与文档同步。第 4、8 节保留实现阶段的历史证据；
本轮集成验收与 3.5.5 发布准备见第 9 节。PR 检查、主干合并和 Issue 关闭状态
以 GitHub 对应记录为准，不由历史测试结果推断。

## 2. Issue → 修改 → 测试 → 结果

| Issue | 修改（文件 / 符号） | 回归测试 | 结果 |
|---|---|---|---|
| [#142](https://github.com/hrygo/SpeechRail/issues/142) | `application/alignment.py` 新增 `_spoken_text_is_covered`，在 `validate_alignment` 扩展 gap 前校验未匹配区间不含口语字符 | `test_alignment_spoken_projection.py`：`test_missing_spoken_token_fails_closed`、`test_missing_trailing_and_leading_tokens_fail_closed`、`test_missing_number_token_fails_closed` | 先失败（返回 `failure=None`）后通过；3 条把缺词当成功的旧 fixture 改为完整覆盖 |
| [#143](https://github.com/hrygo/SpeechRail/issues/143) | `http/routes/audio.py` 建立单一绝对期限 `expires_at`，对齐/分人后处理经 `await_until` 与 `alignment_admission`；`http/routes/voice_designs.py::confirm_candidate` 在 `OSError` 之前捕获 `TimeoutError` | `test_transcription_api.py`：`test_aligner_timeout_is_a_stable_retryable_backend_timeout`、`test_alignment_shares_the_request_deadline_instead_of_restarting_it`、`test_alignment_admission_full_returns_backend_busy`；`test_voice_design_workflow.py`：`test_confirm_asr_timeout_is_a_retryable_backend_timeout` | 4 条先失败（500 无 request ID / 422）后通过 |
| [#140](https://github.com/hrygo/SpeechRail/issues/140) | `runtime/local_file_processor.py::_transcribe` 固定 `include_timestamps=False`，timestamps 走 `align_transcript_timeline`；`application/services.py` 共享同一个 `AlignmentAdmission` | `test_local_file_processor.py`：`test_job_timestamps_come_from_the_independent_aligner`、`test_job_without_timestamps_never_calls_the_aligner`、`test_job_timestamps_require_a_configured_aligner`、`test_job_timestamps_fail_the_job_when_alignment_is_unresolved` | 先失败（对齐器 0 次调用 / 空 segments）后通过 |
| [#141](https://github.com/hrygo/SpeechRail/issues/141) | `runtime/local_file_processor.py::_synthesize` 改用 `tts_delivery.iter_validated_audio`，`TTSDeliveryError` 映射 `job_processor_failed` | `test_local_file_processor.py`：`test_processor_speech_rejects_malformed_streams_without_an_artifact`（5 参数化）、`test_processor_speech_accepts_a_valid_multi_chunk_stream` | 先失败（一字节制品仍判成功）后通过 |
| [#139](https://github.com/hrygo/SpeechRail/issues/139) | `application/voice_design.py`：`update_with_validation_audio` 不再接受调用方构造的 candidate，锁内读最新并合并（`_merge_validation`）；新增 `VoiceDesignValidationLimitError`、`review_state_for`；`http/routes/voice_designs.py` 的人工听审同样在 `repository.update` 回调内按 ID 合并 | `test_voice_design_workflow.py`：`test_concurrent_validations_both_persist_their_record`、`test_repeating_a_machine_validation_keeps_the_human_verdict`、`test_the_validation_limit_refuses_instead_of_evicting_a_returned_record` | 先失败（两个 200 只留一条）后通过 |
| [#138](https://github.com/hrygo/SpeechRail/issues/138) | `http/routes/voice_designs.py::_candidate_validation` 增加 `transcript_numbers_match` 硬门槛，`_validation_id` 纳入策略版本与转写哈希；`application/voice_design.py` 新增 `validation_policy_revision` / `transcript_numbers_match` 字段、`has_current_machine_pass`，`passing_validation` 要求当前策略；`domain/voice_validation.py` 定义 probe set；`application/voice_validation_gate.py` 排除已退役 probe set | `test_voice_design_workflow.py`：`test_numeric_misread_fails_machine_validation_and_blocks_publication`、`test_a_retired_text_fidelity_record_is_kept_but_revalidatable`；`test_voice_validation_residency.py`：`test_legacy_voice_design_output_evidence_is_not_production_evidence`、`test_current_voice_design_output_evidence_still_admits` | 先失败（`machine_status=pass`、旧证据仍准入）后通过 |
| [#145](https://github.com/hrygo/SpeechRail/issues/145) | `http/routes/audio.py::diarized_events` 的 delta 带上同源的 `segment_id` | `test_diarization_sdk.py::test_native_diarized_sdk_stream_uses_standard_sse_events`；`tests/openai-sdk-node/diarization.test.mjs` 新增 Node 用例 | 先失败（`segment_id` 为 `None`）后通过 |
| [#144](https://github.com/hrygo/SpeechRail/issues/144) | `http/routes/audio.py` 四项明确不支持的选项由 422 改为 400；`contracts/openapi.yaml` 补 502 与 SSE/校验字段；`docs/users/api-contract.md` 同步并升版 | 新增 `tests/test_audio_error_contract.py`（7 例）；更新 `test_transcription_api.py`、`test_openai_diarized_batch.py` 状态断言与 `test_diarization_sdk.py` 异常类型 | 先失败（422 / 契约缺 502）后通过 |

跨入口闭环新增 `tests/test_server_workflow_integration.py`（4 例）：同一冻结文本经 REST 与
任务入口得到同一条时间轴且 ASR 从未被要求原生时间戳；对齐不真实时两端一致拒绝；非法 TTS
流在任务入口不落制品；不请求时间戳的转写完全不触碰 aligner。

## 3. 契约与文档

- `contracts/openapi.yaml`：`/v1/audio/transcriptions` 补 `502`；SSE 事件说明补 `segment_id`
  语义；`VoiceDesignValidationProjection` 补 `transcript_numbers_match` 与
  `validation_policy_revision`（含 `additionalProperties: false` 同步）。
- `docs/users/api-contract.md` 升版 3.12.0 → 3.13.0（date 2026-10-03）：区分“明确不支持
  的选项（400）”与“畸形输入（422）”，补 502 与四项 400 错误码，补 delta/segment 关联、
  数字硬门槛、策略版本、32 条上限与旧 probe set 的重新校验路径。
- 兼容性判据来自官方 SDK 的实际模型：Python `openai` 3.20.0 的
  `TranscriptionTextDeltaEvent.segment_id` 与 `TranscriptionTextSegmentEvent.id`；
  Node `openai` 7.10.0 的类型声明同样标注 `segment_id` 仅在
  `gpt-4o-transcribe-diarize` 下出现。

## 4. 验证证据

全部为确定性测试（fake backend，无真实模型、音频或网络），2026-10-03 在
`/Users/hrygo/Documents/SpeechRail` 执行：

| 检查 | 命令 | 结果 |
|---|---|---|
| 完整 Python 套件 | `uv run --extra dev pytest -p no:randomly -q` | exit 0，3007 passed / 1 skipped |
| 覆盖率门禁 | 同上 | 82.33%（门槛 80%） |
| 静态检查 | `uv run --extra dev ruff check src tests scripts` | All checks passed |
| 类型检查 | `uv run --extra dev mypy src` | 155 个源文件无问题 |
| 契约一致性 | `uv run --extra dev python scripts/check_openapi_contract.py` | OK（39 paths / 47 operations） |
| 文档一致性 | `uv run --extra dev python scripts/check_user_doc_contract.py` | OK（21 documented error codes / 9 model aliases） |
| Node 官方 SDK | `npm --prefix tests/openai-sdk-node test` | 2 passed / 0 failed |
| 差异空白 | `git diff --check` | 通过 |

1 条 skipped 为 `test_spoken_char_rule_mirrors_the_pinned_aligner`，需安装
`mlx_qwen3_asr` 才能与 vendor 的 `is_kept_char` 对拍；本机未安装该 vendor，按项目约束未
自动下载。其余 3007 条全部实际执行并通过。

## 5. 影响范围

- **行为变更（对外可见）**：三项转写/合成选项与 known-speaker 的状态码 422 → 400；
  `/v1/audio/transcriptions` 新增 502；diarized SSE delta 新增 `segment_id`；
  VoiceDesign validation 投影新增两个字段；VoiceDesign 发布的 probe set 由
  `voice_design_base_v1` 升为 `voice_design_base_v2`。
- **数据兼容**：旧私有候选记录缺少新字段时按 v1 策略读取，不会因 `extra=forbid` 整库不可用；
  候选的参考音频、validation 音频与历史 revision 一律不删除、不改写。
- **准入变化**：此前由 v1 文本门禁写入 `voice_design_base_v1` 的已发布音色，其
  `production_ready` 会转为 false，严格合成（`require_output_pass`）将拒绝，直到重新跑一次
  quality-run。普通 `allow_unverified` 语义不变。
- **未变更**：Realtime 协议、LLM 编排、macOS 控制面、模型档位与资源预算；任务 runner 的
  governor 与任务期限未重复获取。

## 6. 剩余风险

- 本轮全部为 fake backend 的确定性验证。**真实模型下的音色质量、延迟、吞吐与长时稳定性
  未测**，不能据此宣称性能或质量验收通过；按目标约定另行安排。
- 未做真实 UI 自动化、App 构建、安装与发布验证。
- Node SDK 用例验证的是官方 SDK 对事件字段的解析契约；服务端行为由 Python 官方 SDK 用例
  直接覆盖，两者不互相替代。
- `_spoken_text_is_covered` 会让此前被静默吸收的 aligner 漏词转为显式失败。若某台机器上的
  vendor aligner 确实漏词，症状从“时间轴不准”变为“请求返回 502/任务失败”——这是期望行为，
  但上线后可能暴露此前被掩盖的产出质量差异。

## 7. 回退

- 代码按逻辑主题提交；需要回退时创建逆向提交，并同步测试、契约与文档，无需数据迁移。
- 禁止用 `git reset --hard` 或 `git checkout --` 清除工作区。
- 代码回退后，`voice_design_base_v2` 记录仍可被旧代码读取（probe set 只是普通字符串字段）；
  新字段在旧代码中会被忽略。恢复有缺陷的 v1 准入不是可接受的默认回退，优先停用受影响的
  严格合成路径并保留证据。
- 若需回到 422 语义，只需回退 `http/routes/audio.py` 的四处状态码与相应测试，契约与文档
  需一并回退，不可只改一侧。

## 8. #139 并发专项加固（2026-10-03）

用户指定继续处理 #139 后，在保留上述未提交修复的基础上复核事务边界。本节是追加验证，
第 4 节的完整套件结果属于专项加固之前的历史证据，不能替代本节的定向验证。

### 修复结论

保留既有 `RLock` 和 sibling file lock，TTS/ASR 推理在锁外执行；每次持久化事务读取最新
candidate，再校验 revision/state、合并一条结果并保存 JSON/WAV。单 candidate 仍允许多个
请求重叠；只有成功响应的结果必须均可读，期间状态变化的请求明确返回 409。

本轮新增修正：

- `VoiceDesignCandidate.require_validation_writable` 统一状态与 revision 约束，
  供开始机器校验、人工听审和机器结果提交三个锁内写入点使用。竞争写入造成
  `published / cancelled / failed` 时，不允许旧请求恢复候选状态。
- 人工听审在事务内重新核验当前机器证据，再从最新 validation 构造更新，不使用
  锁外快照覆盖记录。
- 开始新校验复用 `review_state_for`，保留已有完整听审的 `publishable`。
  后续 backend timeout 不会降级既有通过状态。
- 同 ID 机器事实冲突改为 `409 voice_design_revision_conflict`；已有试听资产身份冲突
  返回 `409 validation_audio_unavailable`。原来的未捕获异常反例已被稳定 envelope 覆盖，
  包含 request ID，不覆盖原记录或原资产。
- 机器合并和人工听审保留最新 `updated_at`，重复旧结果不再使候选更新时间倒退。
- OpenAPI 补充并发、幂等、终态和容量语义，并声明 `validations.maxItems=32`；
  用户 API 文档由本轮既有的 3.13.0 更新为 3.13.1。

### 并发与持久化证据

`tests/test_voice_design_workflow.py` 覆盖以下实际行为：

- 两个 ASGI 异步校验，以 Events 分别控制先后完成和逆序完成；同步点位于
  `_transcribe_pcm` 释放 ASR lane 之后，不以 sleep 控制时序，也不会持有串行 lane 等待。
  首个结果人工听审与第二个结果提交交错后，两条 ID 和听审结论均保留。
- 新建 repository 实例重读 JSON；两条返回 ID 对应的 REST WAV 均能读取，
  WAV/PCM hash 与记录和各自合成输出一致。这里验证的是持久化重读，未启动真实服务进程。
- 校验等待期间通过真实 API 取消、发布、人工拒绝或编辑参考文本；待完成校验均返回 409，
  不撤销新状态、不恢复旧 revision、不产生新试听资产。
- 在 route 快照与仓库事务之间注入竞争终态写入，分别验证机器与人工模式的锁内拒绝。
  这是事务边界反例，不宣称单 ASGI loop 的同步人工听审会自然让出执行权。
- 两个独立 repository 实例通过线程同时争抢第 32 个名额：恰好一成功、一容量冲突，
  已有 31 条全部保留，失败方没有新资产，成功方以及全部旧 WAV 均可校验读取。
  满额后，同 ID 的幂等重试仍成功并保留人工结论与最新更新时间。
- 新资产和既有资产两种保存失败路径均保留原 JSON/WAV；仅本次新建资产回滚。

专项补充共复现 10 个失败反例，并在修复后转绿。核验时间为 2026-10-03，
所有测试均使用 fake backend、合成 PCM 和临时目录，不涉及真实模型或用户音频：

| 检查 | 命令 | 实测结果 |
|---|---|---|
| 相关回归 | `uv run --extra dev pytest -p no:randomly --no-cov -o addopts=--strict-markers -q tests/test_voice_design_workflow.py tests/test_voice_design_registration.py tests/test_voice_design_diagnostics.py tests/test_voice_validation_residency.py tests/test_server_workflow_integration.py --tb=short` | 106 passed，63.76s |
| API 交错场景强化后复验 | `uv run --extra dev pytest -p no:randomly --no-cov -o addopts=--strict-markers -q tests/test_voice_design_workflow.py -k inflight_validation --tb=short` | 4 passed / 44 deselected，6.29s |
| 相关静态检查 | `uv run --extra dev ruff check src/speechrail/application/voice_design.py src/speechrail/http/routes/voice_designs.py tests/test_voice_design_workflow.py` | All checks passed |
| 相关类型检查 | `uv run --extra dev mypy src/speechrail/application/voice_design.py src/speechrail/http/routes/voice_designs.py` | 2 个源文件无错误 |
| OpenAPI 一致性 | `uv run --extra dev python scripts/check_openapi_contract.py` | OK（39 paths / 47 operations） |
| 用户文档一致性 | `uv run --extra dev python scripts/check_user_doc_contract.py` | OK（21 error codes / 9 model aliases） |
| 差异空白 | `git diff --check` | 通过 |

本轮未重复执行完整套件和覆盖率门禁，不将第 4 节历史覆盖率扩展为专项加固后的覆盖率。
没有新增存储字段或迁移用户数据，没有启停服务、部署、commit、push 或关闭远端 Issue。
回退仅逆向处理本节新增的逻辑补丁并同步相关测试、契约和文档，保留上一轮所有其他修复。

## 9. 集成验收与 3.5.5 发布准备（2026-10-03）

### 最终回归

本轮验收发现参考 confirm 的数字规则尚未完整执行：错误数字仍能返回 200。
新增错误数字和等价中文数字两个反例后，confirm 同时应用相似度及数字门槛；
拒绝路径保持候选 JSON 和全部 WAV 不变。该修正属于 #138 的完整闭环。

#139 新增的并发用例已整理到 `tests/test_voice_design_concurrency.py`，复用既有 fake
helpers；第 8 节记录的旧路径与历史命令保持原样。整理时遗漏的 `EDITED_TEXT` 导入已补齐，
最终完整套件实际执行了修订、发布、取消和人工拒绝四种在途竞争场景。

| 检查 | 最终实测结果 |
|---|---|
| 完整 Python 套件 | 3030 passed / 1 skipped；JUnit：3031 tests / 0 failures / 0 errors，143.872s |
| 覆盖率 | 82.11%，通过 80% 门槛 |
| Ruff | `src tests scripts hatch_build.py tools examples/perf` 与 benchmark fixture 脚本全部通过 |
| Mypy | `src` 的 155 个源文件通过 |
| OpenAPI / 用户文档 / MCP | 39 paths / 47 operations；21 error codes / 9 model aliases；18 tools / 3 resources，全部一致 |
| OpenAPI lint | Redocly CLI 2.52.1 通过 |
| Node 官方 SDK | 2 passed / 0 failed |
| 服务/App 版本一致性 | 服务所有镜像及 App 三处 MARKETING_VERSION 均为 3.5.5 |
| plist / 项目元数据 | LaunchAgent example 与 App project.pbxproj 通过 |
| 发布说明回归 | 15 个用例通过；真实发布基线为 v3.4.0 |
| 改为 3.5.5 后的版本相关回归 | 87 passed / 0 skipped；覆盖版本、App 契约、安装入口、发布校验与说明 |
| 差异空白 | `git diff --check` 通过 |

完整套件执行命令为：

```bash
env -u SPEECHRAIL_API_KEY uv run --no-sync pytest -p no:randomly -q \
  --junitxml=dist/pre-release-4.0.0/pytest.xml
```

完整套件执行时初步版本为 4.0.0；重新评估后采用 3.5.5，原始证据目录原样移到
`dist/pre-release-3.5.5/`，并重新通过版本一致性及 87 条版本相关回归。
3.5.5 的完整远端验收以 PR 的必需 CI 检查为准。

全部测试使用 fake backend、合成 PCM、临时存储。唯一跳过项仍为 vendor `is_kept_char`
对拍；没有下载模型或安装 vendor 来消除跳过项。测试还报告 SQLite 未关闭连接的
`ResourceWarning`，未造成测试失败；本轮不据此宣称长期资源稳定性通过。

### 版本与发布材料

- 服务准备 `3.5.5` PATCH：400 分类恢复既有契约，数字及旧证据门槛修复验证漏洞；
  App 仅同步版本镜像，build number 40 → 41。用户 API 文档自身版本为 3.13.2。
- `uv.lock` 仅改变 SpeechRail 自身版本；不升级依赖、修改真实配置或迁移用户数据。
- 2026-10-03 核验：GitHub 最新正式发布为 `v3.4.0`，没有 `v3.5*` 标签。
  发布脚本新增已发布标签输入，发布 workflow 从 GitHub 获取标签；
  说明正文仍取自 CHANGELOG，并包含 v3.4.0 之后尚未发布的 3.4.x、3.5.x 记录。
- `dist/pre-release-3.5.5/` 保存本轮测试证据、生成的 release notes 和候选 wheel；
  制品的源 commit、版本、内容检查和 SHA-256 由同目录发布准备清单记录，不提交二进制。
- 主干保护要求线性历史及 `Quality Gates`、`Test (macos-26 / Python 3.14.7)`、
  `macOS App Build & Tests` 三项检查；合并使用通过检查的 PR HEAD，不绕过保护。

该版本完成代码合并与发布准备后，正式 tag、GitHub Release、App DMG、签名/公证、
安装、服务切换和真实模型质量/性能验收仍是独立步骤。本轮没有启停服务或接管 UI。
