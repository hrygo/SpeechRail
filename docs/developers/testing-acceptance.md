---
title: "SpeechRail 测试与验收"
status: active
version: "3.3.2"
date: 2026-10-06
---

# SpeechRail 测试与验收

## 自动化门禁

提交前运行：

```bash
cd <path-to-SpeechRail>
uv run --extra dev pytest
uv run --extra dev ruff check src tests scripts hatch_build.py
uv run --extra dev mypy src
npx --yes @redocly/cli@2.52.1 lint contracts/openapi.yaml
uv run python scripts/check_openapi_contract.py
uv run python scripts/check_mcp_tool_contract.py
git diff --check
```

GitHub Actions 使用同一套锁定依赖门禁：`quality` 运行 Ruff、Mypy、版本一致性、OpenAPI lint、OpenAPI 路径对齐、MCP 工具面（`tools/list` / `resources/list` / 文档 / skill manifest）对齐、分人契约回归和差异空白检查；`test` 在 `macos-26` 的 Python 3.14.7 环境中构建一次 wheel。`scripts/ci_python_gate.sh` 让非 wheel 测试与构建并行，随后通过 `SPEECHRAIL_WHEEL_PATH` 让 wheel 测试消费该制品；两段 coverage 合并后仍强制 80% 门槛，任一段失败均阻止 artifact 上传。`swift-tests` 和 `macos-app` 使用独立的 `macos-26` arm64 runner，分别执行完整 SwiftPM 测试及 Xcode App 构建，不运行 UI 自动化或重复执行 Xcode 测试。`Gate Summary` 必须等待并验证每个选中的 job；被选中的检查意外 skip 也会失败。`package` 下载已测 wheel，只做压缩包、Darwin CoreML native worker 和 checksum 校验后上传，避免重复同步依赖和构建。普通 CI 与 tag Release 的 `package` 都使用 `macos-26`。Ubuntu 仅承载平台无关的 Quality Gates，不代表产品运行支持。CI workflow 同时支持普通 push/PR 和 Release workflow 的 `workflow_call`，Release 不重复维护 Python 检查命令。

编译缓存按平台、工具链及锁定依赖隔离，只为内容未变的跟踪输入恢复时间戳；源码修改仍触发重新编译。Xcode 构建通过仓库包装脚本执行，结束时注销并删除临时 App 包，只保留可重用编译输入与输出。uv 使用官方缓存裁剪，不继续恢复旧的整目录大缓存。耗时口径、实测范围及 `<50%` 验收条件见 [CI 效率分析](ci-efficiency.md)。

非 wheel pytest 由 `pytest-xdist` 使用两个进程按文件调度；同一测试文件的用例和 fixture 保持在同一进程，worker 自动重启关闭。`pytest-cov` 先合并两个 worker 的 coverage，wheel 阶段再追加并检查原 80% 门槛；不因并行执行而跳过用例、降低门槛或重试失败。

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
registry、worker frame 协议、snapshot preflight、Realtime current-only 的 `session.update`
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
