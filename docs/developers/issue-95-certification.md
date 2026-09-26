---
title: "Issue #95 交付认证方案与证据索引"
status: active
audience: "SpeechRail 维护者与验收人"
version: "0.8.0"
date: 2026-09-26
---

# Issue #95 交付认证方案与证据索引

> **状态：运行态认证已执行，等待人工听感验收。** 本文同时是 T12（P5 交付认证）的执行记录与证据索引。
> §3 语料分层、§5.2 质量阈值、§6 盲听规则原为**建议稿**；当前用户于 2026-09-26 给出“全部授权”，
> 据此把建议稿采用为本轮验收口径（见 §5.2、§9），并把实测结果按该口径如实登记：延迟 / 取消 / 实时性
> 通过，数字 / 单位门 **未达** 95% 口径（§7.2 列出反例，不粉饰）。
>
> 非运行态门（代码 / 契约 / 编译 / 文档静态门 + 完整 pytest 套件）已于 2026-09-26 完成并登记在 §7.1；
> 运行态认证（供应态 wheel 唯一来源、真实模型三档 warm/cold/cancel、真实声卡停音、公开语料质量门、
> ≥2h 长稳 soak、API/CLI/MCP/文档/App 静态一致性）已执行并登记在 §7.2。**仍需人工验收的项**
> （听感 / 盲听、数字单位门 90% 的接受或整改决定、本机自动化模式可用的 UI 自动化时间窗）在 §8 显式列出，
> P5 在这些人工项完成前保持未勾选。

## 1. 认证目标与边界

- 关闭条件：P0–P5 每一项都有可复核证据；缺任一项则 Issue #95 保持 open（仅 `Refs #95`）。
- 认证对象：从本分支受控构建的服务 wheel + 本机 Apple Silicon macOS 26 运行态 + 当前 12 制品矩阵。
- 不在范围：远端部署、公开分发、Developer ID / notarization、LLM 编排、实名 speaker、跨会话声纹、PCM 落盘。
- 证据纪律：原始音频、转写、日志、embedding 与 benchmark 原始 JSON 一律留在仓库外；本文件只登记
  脱敏摘要与仓库外相对位置 + digest，不写私人绝对路径、正文、prompt 或密钥。

### 1.1 P0–P5 逐门状态（2026-09-26 复核）

门定义见 [目标架构 §11](../architecture/2026-09-25-asr-tts-target-architecture-no-legacy.md)。下表把每门映射到本文件的证据位置；
**只登记实际通过的阶段**，未通过项不粉饰。

| 门 | 通过标准（摘要） | 证据 | 状态 |
|---|---|---|---|
| P0 | ADR、契约、核心类型与规格职责冻结；无多余 preset 真相、旧 alias 或不映射的参数 | `check_openapi_contract`(37/45) / `check_realtime_contract`(41/32) / `check_mcp_tool_contract`(18/3) / `check_macos_route_contract`(14×4)；旧 preset 与 alias 删除（§8.3） | ✅ 有证据 |
| P1 | ModelSpec/Artifact 与 ResolvedPlan/资源治理；固定制品、精度校验、角色路由、预算与拒绝语义闭合 | catalog 13 绑定 `assert_target_spec_bindings`；`tests/test_spec_selection.py`、`test_model_store.py`、`test_resource_governor.py`、`test_model_budget.py`（含在 §7.1 的 2470 passed 套件） | ✅ 有证据 |
| P2 | ASR 主链路与独立 Alignment/Diarization；唯一 final、统一时间轴、无隐式模型 | `tests/test_asr_mode.py`、`test_alignment_worker.py`、`test_diarization_*.py`、`test_openai_diarized_batch.py`；运行态 `/readyz` 与 `diarization_ready=true`（§7.2） | ✅ 有证据 |
| P3 | Base/CustomVoice 运行与 BF16 Design 工作室；真增量、音色复验、缓存隔离 | `tests/test_qwen3_tts_custom_voice.py`、`test_qwen3_tts_voice_design.py`、`test_voice_design_workflow.py`、`test_tts_voice_clone.py`、`test_voice_bindings.py`；reference BF16 真实推理（§7.2） | ✅ 有证据 |
| P4 | App/协议、播放、打断、组合调度；当前协议单实现、迟到包隔离、切档原子、组合准入 | `swift test`（XCTest 227 + swift-testing 144）；`test_realtime_current_schema.py`、`test_realtime_vad_bargein.py`、`test_profile_switch.py`；App Debug 构建通过；真实声卡停音 p95 21ms（§7.2） | ✅ 有证据 |
| P5 | 引擎受控制品与真实性能/质量验收；可重建安装、真实模型/播放器证据、声明与实测一致 | 受控 wheel 构建与复装（§7.1、§7.2）；三档 warm/cold/cancel、真实声卡、公开语料、≥2h soak（§7.2）。**未通过**：数字/单位 90%（<95%）、soak 1/5200 stale audio 与 footprint 12.5% | ⛔ 未通过（裁定项见 §8.2） |

## 2. 测量身份（每次运行必须登记）

| 字段 | 说明 |
|---|---|
| commit | 本分支完整 SHA |
| wheel 版本 / sha256 | 受控构建产物；安装来源唯一 |
| runtime lock id | 与 `runtime-lock.json` 一致 |
| engine revision | 引擎 wheel 固定 revision 与 patch/build 输入 hash |
| 模型制品 | 每个 `artifact_key` + `revision` + 加载后 precision 身份回读 |
| selection / plan | `asr_spec`+`tts_spec`、voice revision、plan digest |
| 设备 / macOS / 内存 | 机型、系统版本、物理内存 |
| 任务配置 | 采样率、chunk/context、输出格式、endpointing、对齐/分人开关 |
| 样本与统计 | 语料分层、样本数、重复次数、分位算法、置信区间、失败数 |

## 3. 语料分层（建议稿，待确认）

### 3.1 ASR

| 分层 | 覆盖点 | 建议最小样本 |
|---|---|---|
| 中文短句（≤10s） | 日常口语、专有名词 | 30 条 × 3 次 |
| 中文长段（≥60s） | 长上下文、稳定前缀滚动 | 10 段 × 3 次 |
| 英文短句 / 段落 | 英文 WER、数字与货币 | 30 条 × 3 次 |
| 中英混合 | 语码切换 | 20 条 × 3 次 |
| 数字 / 单位 / 日期 | 数字规范化 | 20 条 × 3 次 |
| 静音 / 纯噪声 / 低信噪比 | 空结果、不产生幻觉文本 | 10 条 × 3 次 |
| 重复取消 / 打断 | 无污染、可恢复 | 10 轮 × 3 次 |

### 3.2 TTS

| 分层 | 覆盖点 | 建议最小样本 |
|---|---|---|
| 中文短句 / 长段 | 内容正确性、韵律 | 30 + 10 条 |
| 英文 / 中英混合 | 发音与切分 | 20 条 |
| 数字 / 多音字 / 生僻字 | 读法正确性 | 20 条 |
| 系统音色 / 克隆音色 | 身份一致性、亮度 | 每类 ≥3 个 voice revision |
| 增量流式 | 首包延迟、断点续读、取消 | 与 §5 一致 |

### 3.3 Alignment / Diarization

| 分层 | 覆盖点 | 建议最小样本 |
|---|---|---|
| 词/字级对齐 | 时间戳误差、覆盖、越界 | 30 条 |
| 多说话人（2–4 人） | 匿名归属、重叠、切换 | 10 段 |
| 容量边界 | 超长会话、句数上限 | 2 段长会话 |

## 4. 组合与设备矩阵

在**同一台**已授权机器上，至少覆盖（每个单元格按实际产物可用性展开，缺产物记 `blocked` 而非跳过）：

| 组合 | ASR | TTS 角色 | 冷启动 | 热态 | 长短文 |
|---|---|---|---|---|---|
| 轻快 | `asr-0.6b-q8` | `tts-0.6b-custom-q8` / base | ✓ | ✓ | ✓ |
| 品质 | `asr-1.7b-q8` | `tts-1.7b-custom-q8` / base | ✓ | ✓ | ✓ |
| 参考 | `asr-1.7b-bf16` | `tts-1.7b-custom-bf16` / base | ✓ | ✓ | ✓ |
| 参考 + 声音设计 | 同上 | `tts-1.7b-design-bf16`（候选生成 → Base 复验 → 发布） | — | ✓ | 10 条 |

说明：默认不要求 12 项同时常驻；只加载当前任务需要的模型，峰值按资源画像 fail-closed 串行。

## 5. 指标与阈值（建议稿，待评审确认）

延迟类目标沿用计划 §8.3 的「初始真实工程目标（未实测）」；此处只把它们固化成可执行口径，
并补齐质量 / 长稳 / 播放器的**建议**阈值。**所有数值在评审确认前都不是通过标准。**

### 5.1 延迟（热态，样本 ≥30，报 p50/p95）

| 指标 | 建议目标 | 口径 |
|---|---|---|
| ASR 有效 chunk 最后输入→partial | p95 ≤ 500ms | 另报采集积累 |
| commit→text final | p95 ≤ 500ms | 与 partial 分离 |
| 语音结束→final | p95 ≤ 1000ms | 固定 endpointing |
| 首段稳定文本发送→可播放 PCM | p95 ≤ 500ms | `speechrail-perf/tts-streaming/2` |
| 充足文本供给 generation RTF | p95 ≤ 0.8 | 不扣客户端 gap |
| 决定打断→实际旧音停止 | p95 ≤ 200ms | 真机播放器 |
| cancel→任务资源释放 | p95 ≤ 1000ms | 含后端取消超时路径 |

### 5.2 质量（本轮按用户“全部授权”采用下列口径）

> 2026-09-26 当前用户对 T12 给出“全部授权”，据此把下列建议阈值采用为本轮验收口径，不再等待单独评审。
> 采用口径**不等于放宽**：实测未达阈值时如实登记为未通过（见 §7.2 数字 / 单位门 90%）。

| 指标 | 建议目标 | 备注 |
|---|---|---|
| 中文 CER | ≤ 8%（清晰朗读） | 噪声分层单列，不并入均值 |
| 英文 WER | ≤ 12% | 同上 |
| 数字/单位正确率 | ≥ 95% | 按条判定 |
| 静音/纯噪声幻觉率 | ≤ 5% 条数 | 出现空结果计通过 |
| TTS 内容正确率 | ≥ 98% 条数 | 人工核对朗读文本 |
| 克隆音色相似度 p05 | 由评审给定基线 | 相对同一 voice revision 的稳定下限 |
| 自然度盲听（MOS/ABX） | 由评审给定 | 见 §6 |
| 对齐时间戳误差 | 中位 ≤ 50ms，p95 ≤ 150ms | 覆盖 ≥95%，无越界 |
| 分人匿名归属 | 由评审给定 | 只判匿名标签一致性，不做实名 |

### 5.3 长稳与恢复

| 指标 | 建议目标 |
|---|---|
| 连续运行 | ≥ 2h 或评审指定时长，内存/缓存/队列有界，无单调增长 |
| 反复取消 | ≥ 100 轮无污染、无泄漏、可继续服务 |
| 异常恢复 | 注入后端错误/超时后能回到 ready，不半激活 |
| 切档回滚 | 失败时完整回到前一 selection 与运行态 |

## 6. 盲听规则（建议稿）

- 盲听人：至少 1 名目标用户；如有多名，分别记录不合并。
- 随机化：同一文本的不同档位/音色随机顺序，不标注档位与精度。
- 保留样本：固定一组锚点样本（跨批次不变）用于校准，其余为随机样本。
- 维度：内容正确（对/错）、身份一致（同一人/不同人）、自然度（1–5 或 ABX 二选一）。
- 规则：先登记判定再揭盲；只报通过率/分布与置信区间，不报单条主观结论。
- 存证：盲听原始记录留在仓库外，只回填摘要与 digest。

## 7. 证据登记与结果索引

### 7.1 非运行态证据（2026-09-26 Asia/Shanghai，本机实测）

实现范围：分支 `codex/issue-95-target-architecture`。运行态证据（§7.2）绑定提交
`76f4eec84743ca54055ea1566e2efaee284b26fc`（dtype 透传修复后的受控 wheel）。本文所在提交在其后，
仅追加契约/文档/测试/证据脚本，未改动服务运行时行为（wheel 内运行时与 §7.2 一致）。
以下 §7.1 均为 fake / 静态 / 编译证据，**不证明**真实 dtype 加载、音质、字符对齐质量、实时并发或长时稳定性；
真实证据见 §7.2。

| 门 | 结果 | 证据位置 |
|---|---|---|
| 静态 / 契约 / 编译 | 通过：计划 §8.1 四组定向验收合计 **571 passed**（207 / 82 / 123 / 159）；`ruff` 全绿；`mypy src` 148 文件无错；Realtime 契约 41 fixtures / 32 tracked fields；文档与版本一致性 ok；`swift test` 144 tests / 15 suites；`scripts/macos_app_build.sh` **BUILD SUCCEEDED** | 账本 `.superpowers/sdd/2026-09-25-issue-95-asr-tts-target-architecture-luna-guide/progress.md` |
| OpenAPI 路径对齐 | 通过：新增 `scripts/check_openapi_contract.py` 校验运行时路由与 `contracts/openapi.yaml` 路径/方法一一对应；补齐 6 条此前未文档化路径（`/v1/speechrail/pronunciation-sets` 系列、`/v1/speechrail/voices/clone/idempotency`、`/v1/speechrail/voices/{voice_id}/quality-runs`）。运行时 37 路径 / 45 操作全部有契约，`@redocly/cli` lint 有效 | `scripts/check_openapi_contract.py`、`tests/test_openapi_contract.py`、`contracts/openapi.yaml` |
| 供应链（受控引擎 wheel） | 通过：固定上游 revision + overlay/patch 摘要校验，连续两次重建 byte-identical；`runtime-lock.json` 写入 `engine_wheel` pin。**未在本机安装该 wheel** | `vendor/engine-build/engine-build.json`、`src/speechrail/assets/runtime-lock.json` |
| 制品 | 通过：catalog 装载时 `assert_target_spec_bindings()` 对 13 个 `(tier, role)` 绑定精确匹配；缺失制品按授权异步准备完成并逐文件 size / SHA-256 校验为 `verified`（准备记录与制品在仓库外） | 同上；`src/speechrail/assets/model-catalog.json` |
| T04 owner 抽象 | `runtime/model_owner.py` 与 `tests/test_model_owner.py`（13 passed）是 T04 规格产出的 owner / lease 抽象与其 fake 验证面；生产侧「唯一 owner」由按 plan role 绑定的 TTS capability router + 进程级 drain 承担，**未接入** `application/services.py`（不做 live hot-swap） | 账本「2026-09-26 T04 收口复核 Ruling」 |
| 完整回归套件 | 通过：`uv run --extra dev pytest`（含 `--extra mcp`）→ **2496 passed / 1 skipped / 0 failed**，覆盖率 81.41%（≥80 门通过）；新包含 OpenAPI 路径对齐门 | 同上；`tests/test_openapi_contract.py` |
| 完整回归套件（旧档位清理后复跑） | 通过：**2470 passed / 1 skipped / 0 failed**，覆盖率 **81.45%**；计数下降来自删除 20 个旧 preset / precision 用例（`test_model_catalog_contract.py`、`test_model_catalog_builder.py`）与重写 `test_model_store.py`，净增 3 个 MCP 工具面用例 | `tests/test_mcp_tool_contract.py` |
| MCP 工具面对齐门（新增） | 通过：新增 `scripts/check_mcp_tool_contract.py`，校验 `tools/list`（18）与 `resources/list`（3）同时等于用户指南、Proxy 契约文档与 `skill-manifest.json`；已接入 CI `quality` job 与 `docs/developers/testing-acceptance.md` 门禁清单；stdio 真实联调 18 tools / 3 resources | `scripts/check_mcp_tool_contract.py`、`tests/test_mcp_tool_contract.py` |
| App 管理界面（档位组合适配） | 通过：`ModelManagementView` 新增「分别调整识别与配音」高级项，下载 / 应用统一提交一对 `SpecSelection`（`asr_spec`/`tts_spec`），混合组合按两档制品并集显示「组合总大小」；`SpeechRailControlKit` 新增 `ModelCatalogSnapshot.artifacts(for:)` 与 `remainingDownloadUpperBound(for: SpecSelection)`，**新增 3 条 `ControlKitTests` 单测**；`swift test` XCTest 227 / 0 failures + swift-testing 144 tests / 15 suites，`scripts/macos_app_build.sh --configuration Debug` **BUILD SUCCEEDED** | `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`、`macos/SpeechRailApp/SpeechRailControlKit/ServiceDiagnosticsTypes.swift`、`macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift` |
| 交付范围（本节时点） | 此行为本节撰写时的状态：当时未部署、未切档、未加载真实模型。其后已由用户“全部授权”覆盖并实际执行：managed 轮换、真实模型加载、切档、真实声卡与开放语料质量门见 §7.2，UI 自动化结果见 §8.1 | 同上；§7.2、§8 |

### 7.2 运行态登记（2026-09-26，本机实测；证据在仓库外）

环境：Apple M5 Max，物理内存 137,438,953,472 B，Darwin 27.0.0，Python 3.14.7，MLX 0.32.2。
受控 wheel：`speechrail-3.2.1-cp314-cp314-macosx_27_0_arm64.whl`，
sha256 前缀 `7e39b8dc60d09109`；runtime lock `mlx-qwen-20260924-py314`；引擎 wheel 与 lock 一致。
证据根：`~/Library/Application Support/SpeechRail/benchmarks/issue-95-certification/`
（下表 digest 为 sha256 前 16 位；原始 JSON/音频不进入仓库）。

> **受控 wheel 轮换（2026-09-26 12:03）**：旧档位清理改变了 catalog 内容（§8.3），因此重建并重装 wheel：
> sha256 前缀 `bb54128ed0de7be8`，`runtime/current` 原子切换到 `…-bb54128ed0de-py3147`，
> 上一 release `…-7e39b8dc60d0-py3147` 保留为回退点。wheel 与当前源码的唯一差异是
> `service/preflight.py` 的注释文本（AST 完全一致，证据 `wheel-vs-source-preflight-diff.txt`），
> 无运行时行为差异。下表 `76f4eec8` 行为旧 wheel 证据，`4fa658f8` 行为重装后的复测证据。

| 日期 | commit | 阶段 | 组合 | 结果 | 报告文件 | digest |
|---|---|---|---|---|---|---|
| 09-26 | `76f4eec8` | reference 真实 smoke | reference/reference | ASR 中英短/长全部返回正确文本；`asr_runtime_revision=rt_3326859f…`（修复前为 null）；TTS system/custom_voice/clone 三类均产出有效 PCM | `smoke-real-reference.json` | `02b5c2a6e11c2eef` |
| 09-26 | `76f4eec8` | reference warm（30 fixture） | reference/reference | ASR 15 条 0 失败（RTF p50 0.20 / max 0.33）；TTS 15 条 0 失败（RTF p50 0.79 / max 1.61） | `bench-reference-warm.json` | `83bb1bdcdbfc0c4c` |
| 09-26 | `76f4eec8` | quality warm（30 fixture） | quality/quality | ASR 15 条 0 失败（RTF p50 0.028）；TTS 15 条 0 失败（RTF p50 0.26） | `bench-quality-warm.json` | `08e1d56fbf02d60a` |
| 09-26 | `76f4eec8` | fast warm（30 fixture） | fast/fast | ASR 15 条 0 失败（RTF p50 0.029）；TTS 15 条 0 失败（RTF p50 0.25） | `bench-fast-warm.json` | `5489c97602d9be19` |
| 09-26 | `76f4eec8` | reference cold 启动 | reference/reference | stop→start→ready 11.38s；冷态 ASR 1.52s、TTS 首字节 5.18s；warm ASR p50 0.94s / TTS 首字节 p50 1.03s；`tts_warm=false`、`asr_runtime_revision=null` 证明冷态 | `cold-start-reference.json` | `d9c5cbee6079748d` |
| 09-26 | `76f4eec8` | quality cold 启动 | quality/quality | start→ready 11.45s；冷态 ASR 0.88s、TTS 首字节 4.37s；warm ASR p50 0.34s / TTS p50 1.01s | `cold-start-quality.json` | `aab3a9a7ed7a51c5` |
| 09-26 | `76f4eec8` | fast cold 启动 | fast/fast | start→ready 10.77s；冷态 ASR 0.60s、TTS 首字节 1.88s；warm ASR p50 0.092s / TTS p50 0.40s | `cold-start-fast.json` | `01ff4cd4fc1cc994` |
| 09-26 | `76f4eec8` | reference 反复取消 ×100 | reference/reference | 100/100 收到 `cancelled`，0 stale audio；cancel→terminal p95 63ms、next-start p95 66ms（目标 ≤500 / ≤1000ms） | `cancel-reference-100.json` | `f264b36eb0aa7498` |
| 09-26 | `76f4eec8` | reference soak ×30 轮 | reference/reference | 30 完成 + 30 中断，0 失败；空闲取消稳定返回 `tts_not_active`；phys_footprint 14.03GB→14.18GB（cycle 区间 14.18–14.43GB，有界非单调） | `soak-reference-30.json` | `2244448bde7efc1e` |
| 09-26 | `76f4eec8` | quality 人工听审样本 | quality/quality | 系统音色中/英 + 克隆音色中文各 1 段，供人工听感验收（未自评通过） | `listen-quality-serena-zh.wav` / `-en.wav` / `listen-quality-clone-zh.wav` | `a0ce9b00f2dc8e1a` / `c240594c95955909` / `a918dcc8a1492a3c` |
| 09-26 | `76f4eec8` | 真实声卡停音（设备级） | 不依赖 profile | “决定打断→扬声器实际停音”真机测量：30 trials，p50 **17ms** / p95 **21ms** / max 21ms（阈值 200ms）→ 通过；源码 `sound_stop_latency.c` | `sound-stop-latency.json` | `bc36cf199c595631` |
| 09-26 | `76f4eec8` | quality 公开语料质量门 | quality/quality | 300 请求（100 条 × 3：FLEURS zh/en、自合成 zh/en/中英混合、数字单位、静音+粉噪），58.3s，0 请求失败。clean-zh CER **6.47%** ≤ 8% ✓；clean-en WER **4.36%** ≤ 12% ✓；**数字/单位 54/60 = 90% < 95% ✗**；静音/纯噪声按解析脚本口径幻觉 0%，但 30/30 实际输出填充词 `嗯。`（记为良性填充，非空结果） | `quality/asr-quality.json`、`quality/manifest.json`、`quality/run_quality_asr.py` | `70550a92953a3651` / `32424d3a7a191047` / `ee4ff848270a866b` |
| 09-26 | `4fa658f8` | 受控 wheel 重装（旧档位清理后） | quality/quality | `speechrail install --asr-spec quality --tts-spec quality --yes --enable` 原子切换至新 release；`/readyz=200`、`/health.profile=quality/quality`、`backend=asr-1.7b-q8`、`diarization_ready=true`、单 listener；模型 0 下载（复用 3 个已校验 snapshot） | `install-20260926-1215.log` | `15b2b506f7be4669` |
| 09-26 | `4fa658f8` | reference warm 复测（30 fixture） | reference/reference | ASR 15 条 0 失败（RTF p50 0.132 / max 0.178）；TTS 15 条 0 失败（RTF p50 0.327 / max 0.334） | `bench-reference-warm-r2.json` | `120178780f50fe30` |
| 09-26 | `4fa658f8` | quality warm 复测（30 fixture） | quality/quality | ASR 15 条 0 失败（RTF p50 0.033 / max 0.045）；TTS 15 条 0 失败（RTF p50 0.263 / max 0.280） | `bench-quality-warm-r2.json` | `afec4646cf608162` |
| 09-26 | `4fa658f8` | fast warm 复测（30 fixture） | fast/fast | ASR 15 条 0 失败（RTF p50 0.021 / max 0.026）；TTS 15 条 0 失败（RTF p50 0.232 / max 0.240） | `bench-fast-warm-r2.json` | `8ad525b1dbeffed2` |
| 09-26 | `4fa658f8` | 三档 cold 复测 | reference / quality / fast | start→ready 10.79 / 10.78 / 10.76s；冷态 ASR 0.914 / 0.464 / 0.381s、TTS 首字节 1.99 / 1.72 / 2.01s；warm ASR p50 0.548 / 0.137 / 0.087s | `cold-start-reference-r2.json` / `-quality-` / `-fast-` | `1ce3db387eab3435` / `ae946e33c642bd43` / `7c5b90549f57615a` |
| 09-26 | `4fa658f8` | reference 反复取消 ×100 复测 | reference/reference | 100/100 收到 `cancelled`、100/100 证明 release、**0 stale audio**；cancel→terminal p50 38ms / p95 40ms，next-start p95 42ms（目标 ≤500 / ≤1000ms） | `cancel-reference-100-r2.json` | `d3953da8d5aa5f76` |
| 09-26 | `4fa658f8` | quality 公开语料质量门复测 | quality/quality | 300 请求、136.4s、0 请求失败；clean-zh CER **6.47%** ✓、clean-en WER **4.36%** ✓、**数字/单位 54/60 = 90% ✗**（与首轮完全相同的 2 个条目）；静音/噪声解析口径幻觉 0% | `quality/asr-quality-r2.json` | `08db44d7fc3e0510` |
| 09-26 | `4fa658f8` | quality ≥2h 长稳 soak | quality/quality | 5200 循环 / **2h09m**（12:53:32→15:03:04）：完成 5200、中断 5200、空闲取消 5200 全部 `tts_not_active`；**1 次 `cycle4511_stale_audio`**；footprint 3.489–3.988 GB → 分析脚本 9 门中 **2 门未通过**（见下） | `soak-quality-2h-clean.json`、`soak-quality-2h-clean.analysis.json` | `9e4ccd5e10bccc13` / `d40fd76dfe9b8a71` |

**质量门反例（如实登记，不放宽阈值）**：数字/单位门 60 条中 6 条未通过（2 个条目各 3 次复现）——

- `synth-zh-number-10`：ref `航班MU5101将在晚上7点40分起飞。` → hyp `航班MU五千一百零一将在晚上7.410分起飞。`
  （“7点40分”被转录为 `7.410分`，且航班号被读成中文数字）。
- `synth-en-number-06`：ref `Call 13800138000 to reach customer support.` → hyp
  `Call one three eight zero zero one three eight zero zero …`（11 位手机号漏掉 1 位）。

两条均为模型读/写数字的真实偏差，不是脚本解析缺陷；`run_quality_asr.py` 的数字归一（中文数字、`幺`、
英文数字、逐位串）修复后仍复现。静音/纯噪声层没有 VAD，30 条全部返回 `嗯。`；解析口径按“>2 清理字符”
计幻觉数，故记 0%，但**不得**表述为“无幻觉”。

**长稳 soak 判定（如实登记，不放宽阈值）**：5200 循环 / 2h09m 未发现泄漏或单调增长——
`footprint_not_monotonic` 与 `footprint_second_half_not_growing` 通过，`worker_evictions_total`
全程保持 2，`realtime_active_sessions` 每循环回到 1（客户端连接自身未泄漏），`idle_cancel_codes`
5200/5200 为 `tts_not_active`。但分析脚本 9 门中 **2 门未通过**：

1. `no_cycle_failures`：1 次 `cycle4511_stale_audio`（5200 次中断中 0.019%）。口径是「发出 cancel 后仍
   收到 PCM delta 帧」；触发点在首个音频帧之后，因此该事件包含「cancel 已发出、但帧已在途」这一类竞态。
   同轮单独的 `cancel-reference-100-r2.json` 为 100/100、0 stale audio。
2. `footprint_bounded`（`(max-min)/max < 10%`）：实测 **12.5%**（3.489–3.988 GB）。该门由本轮分析脚本
   设定，采样点覆盖推理进行中的峰值（空闲 3.49–3.65 GB，推理峰值 ≈3.99 GB）；另两门内存趋势门均通过，
   因此该差异更像「采样相位」而非增长，但按登记口径仍记为未通过，是否改为「空闲基线 + 峰值分列」口径
   由目标用户裁定。

结论：**长稳门未通过**，P5 保持未勾选（见 §8.2 的裁定项）。高精度 `reference` 档的真实推理由本表
`bench-reference-warm-r2.json` 与 `cold-start-reference-r2.json` 复测覆盖。

运行态收尾状态（2026-09-26 15:23 复核）：selection 恢复 `quality/quality`（schema_version 2，
generation 11，复测期间多次 `profile apply` 单调递增），`runtime/current` 指向 `…-bb54128ed0de-py3147`，
`/health.backend=asr-1.7b-q8`、`asr_runtime_revision` 非空、`/readyz.ready=true`、
`diarization_ready=true`，单一 listener `*:8201`（配置 `SPEECHRAIL_HOST=0.0.0.0` + `SPEECHRAIL_API_KEY`）。

上述为**延迟/生命周期/资源有界性**证据，并已补上真实声卡停音与公开语料质量门；质量门数字 / 单位层实测
未达 95% 口径（反例见上）。**未**覆盖克隆身份相似度与自然度盲听，本机“自动化模式”暂不可用导致 UI 自动化
未能执行，二者见 §8。长稳 soak 的证据与连接台账约束见下方 8.3 与 §7.2 追加行。

## 8. 已执行 / not_run

### 8.1 本轮已授权并执行（2026-09-26）

- 以 `speechrail install` 把受控 wheel 装入本机 managed runtime（失败/成功日志留在仓库外），
  `runtime/current` 指向 `…-7e39b8dc60d0-py3147`；运行态不再使用源码 overlay。
- 真实模型加载与推理：reference/quality/fast 三档的 warm bench 与参考档真实 smoke。
- 切档：`profile apply quality→reference→quality→fast→quality` 均由受控事务执行并内置 public-API smoke；
  结束时恢复 `quality/quality`。
- 冷启动、反复取消（×100）、短时 soak（×30 轮）与运行态收尾核对，见 §7.2。
- 真实声卡停音：`sound_stop_latency.c` 直驱 48kHz 设备，30 trials 测“决定打断→扬声器实际停音”
  p50 17ms / p95 21ms（阈值 200ms），见 §7.2。
- 公开语料质量门：FLEURS zh/en + 自合成中英/混合/数字/静音噪声，100 条 × 3 = 300 请求，一次跑完 58.3s、
  0 请求失败；CER/WER 通过、数字 / 单位门 90% 未通过，见 §7.2（不放宽阈值）。
- 旧档位清理后重建 wheel（sha256 前缀 `bb54128ed0de7be8`）并重装，`runtime/current` 切换到
  `…-bb54128ed0de-py3147`（旧 release 保留为回退点）；随后整轮复测：三档 warm、三档 cold、
  reference 反复取消 ×100、quality 公开语料质量门，见 §7.2。
- ≥2h 长稳 soak（quality，5200 循环 / 2h09m）已执行并登记；**判定未通过**（1 次 `cycle4511_stale_audio`
  与 footprint 12.5% 口径），见 §7.2 与 §8.2 的裁定项；连接台账约束见 §8.3。
- `scripts/macos_app_test.sh`（含 XCUITest）：已按授权运行 3 次。App 单元测试 0 失败（xcodebuild 报
  `217 executed`，Swift Testing 报 `144 tests / 15 suites`）；**XCUITest 未执行**——本机 “enabling
  automation mode” 无法完成，runner 主线程阻塞在 `-[XCTestDriver _prepareTestConfigurationAndIDESession]`
  （采样 `ui-test-stuck-sample-20260926-*` 留证），故未产生任何 UI 断言结果。
- 静态一致性：完整 pytest（2496 passed / 1 skipped）、Swift 测试（144）、OpenAPI 路径对齐门、MCP 测试。
- App 管理界面适配新档位组合架构：`ModelManagementView` 从「单一快捷档位」扩到「快捷组合 + 分别调整 ASR/TTS」，
  下载 / 应用提交同一对 `asr_spec`/`tts_spec`；ControlKit helper 与 3 条单测随附。App 侧为编译 / 单测证据，
  **未做桌面 UI 自动化**（自动化模式不可用，见下），实际观感仍需人工走查（§8.2）。

### 8.2 仍未执行（需人工验收或更长窗口，P5 未勾选）

- **人工听审 / 盲听**：§7.2 的 quality 听审样本（系统音色中/英、克隆音色中文）尚未由目标用户判定内容 /
  身份 / 自然度；克隆身份相似度、自然度盲听（§5.2、§6）需目标用户听审。
- **数字 / 单位门 90% 的处置**：实测 54/60，未达 95%；需目标用户决定“接受为已知限制”还是“进入整改”。
- **长稳 soak 两门未通过（需裁定）**：① 5200 次中断中出现 **1 次 stale audio**（0.019%）——需决定视为
  「在途帧」竞态并在客户端丢弃、还是按缺陷开单整改；② footprint `(max-min)/max` 实测 **12.5%**（阈值
  10%）但趋势门全通过——需决定沿用当前口径（记未通过）还是改为「空闲基线 + 推理峰值分列」口径。
- **UI 自动化时间窗**：本机自动化模式暂不可用，需在可启用 automation mode 的会话重跑 `macos_app_test.sh`。
- **真实 LLM 端到端**：未接入真实 LLM 编排链路（不属于 SpeechRail 服务边界）。

### 8.3 已知的内部偏差（不影响公共契约）

- **单连接 TTS request id 台账上限**：`OpenAIRealtimeSession._claim_tts_request` 对每个 WebSocket 连接维护
  去重台账，去重上限 `_MAX_TTS_REQUEST_IDS = 256`；台账只增不减，达上限后空闲 `speechrail.tts.start`
  返回 `tts_request_invalid`（“ledger is full; start a new WebSocket connection”）。该上限由 main 上的
  `16c57cf0` 引入，**不是本轮回归**，也未写入公开契约。影响：单连接超过约 256 个不同 TTS request id
  后必须重连（每 utterance 约消耗 1 个 id）。本轮据此把 soak harness 改为按 `--reconnect-every`（默认 50）
  周期重连，使 ≥2h 长稳测试反映合规客户端行为；是否把上限改为可回收（in-flight 去重）属运行时变更，
  会改变 wheel 并需重跑整轮认证，作为后续 scoped 项记录。
- **旧档位残留已删除（2026-09-26）**：`presets` / `precision_policy`（`extreme`/`quality`/`balanced`/`light`）
  已从 `src/speechrail/assets/model-catalog.json`、`tools/model-catalog.metadata.json`、
  `src/speechrail/config/model_catalog.py`（`PresetId` / `ModelPreset` / `TierPrecision` /
  `ModelCatalog.preset()`）与 `tools/build_model_catalog.py` 的校验中移除；`service/model_store.py` 的
  legacy `prepare_models()` 与 `preset` 字段也一并删除，registry 字段改为 `selection`。运行时选择路径本就
  按 `asr_spec`/`tts_spec` 解析，CLI / REST / MCP / App 不接受旧档位名。因该删除改变了 catalog 内容，
  受控 wheel 已重建（`…-bb54128ed0de…`）并重跑 §7.2 的整轮运行态认证。

## 9. 需用户确认的决策点

1. §5.2 质量阈值与 §6 盲听维度：**已处置**——用户 2026-09-26 给出“全部授权”，据此采用建议稿为本轮口径
   （采用不等于放宽，数字 / 单位门实测未达即登记为未通过）。
2. §3 语料分层与最小样本量：**已处置**——用户授权使用公开权威语料与自合成素材；本轮采用 FLEURS zh/en +
   自合成分层（100 条 × 3），原始音频 / 转写留在仓库外。
3. 听审样本人工验收时间窗与真实声卡 / ≥2h 长稳：**部分处置**——真实声卡停音与 ≥2h 长稳本轮已执行（§7.2）；
    ≥2h soak 判定为**未通过**（stale audio 1/5200、footprint 口径 12.5%），处置待第 6 条裁定；
    听审样本的人工听感仍待目标用户时间窗（§8.2）。
4. UI 自动化授权与时间窗：**已处置**——用户已授权；但本机 automation mode 无法启用导致 XCUITest 未执行，
   需在可启用该模式的会话重跑（§8.2）。
5. **待用户决定**：数字 / 单位门 90%（54/60）是接受为已知限制，还是进入数字读 / 写整改。
6. **待用户决定**：长稳 soak 的 2 个失败门——① `cycle4511_stale_audio` 1/5200 视为在途帧竞态（客户端丢弃）
   还是开单整改；② footprint 门改用「空闲基线 + 峰值分列」口径重算，还是沿用当前 10% 硬门并保持未通过。
