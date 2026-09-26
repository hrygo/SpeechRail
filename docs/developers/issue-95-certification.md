---
title: "Issue #95 交付认证方案与证据索引"
status: active
audience: "SpeechRail 维护者与验收人"
version: "0.4.0"
date: 2026-09-26
---

# Issue #95 交付认证方案与证据索引

> **状态：运行态认证进行中（已获当前用户专项授权执行）。** 本文同时是 T12（P5 交付认证）的
> 执行记录与证据索引。§3 语料分层、§5.2 质量阈值、§6 盲听规则仍是**建议稿**，需要评审确认；
> 在这些数值确认之前，本文只登记**已实测**的运行态证据，不把建议值当成通过标准。
>
> 非运行态门（代码 / 契约 / 编译 / 文档静态门 + 完整 pytest 套件）已于 2026-09-26 完成并登记在 §7.1；
> 运行态认证（供应态 wheel 唯一来源、真实模型三档 warm/cold/cancel/soak、API/CLI/MCP/文档/App 静态一致性）
> 已执行并登记在 §7.2。**仍需人工验收的项**（真实播放器听感、盲听、≥2h 长稳、质量 CER/WER 语料分层）
> 在 §8 显式列出，P5 在这些人工项完成前保持未勾选。

## 1. 认证目标与边界

- 关闭条件：P0–P5 每一项都有可复核证据；缺任一项则 Issue #95 保持 open（仅 `Refs #95`）。
- 认证对象：从本分支受控构建的服务 wheel + 本机 Apple Silicon macOS 26 运行态 + 当前 12 制品矩阵。
- 不在范围：远端部署、公开分发、Developer ID / notarization、LLM 编排、实名 speaker、跨会话声纹、PCM 落盘。
- 证据纪律：原始音频、转写、日志、embedding 与 benchmark 原始 JSON 一律留在仓库外；本文件只登记
  脱敏摘要与仓库外相对位置 + digest，不写私人绝对路径、正文、prompt 或密钥。

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

### 5.2 质量（建议阈值，必须评审）

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
| 交付范围 | 未部署、未切档、未加载真实模型；`scripts/macos_app_test.sh`（含 UI 自动化）与真实设备/播放器验收未执行 | 同上 |

### 7.2 运行态登记（2026-09-26，本机实测；证据在仓库外）

环境：Apple M5 Max，物理内存 137,438,953,472 B，Darwin 27.0.0，Python 3.14.7，MLX 0.32.2。
受控 wheel：`speechrail-3.2.1-cp314-cp314-macosx_27_0_arm64.whl`，
sha256 前缀 `7e39b8dc60d09109`；runtime lock `mlx-qwen-20260924-py314`；引擎 wheel 与 lock 一致。
证据根：`~/Library/Application Support/SpeechRail/benchmarks/issue-95-certification/`
（下表 digest 为 sha256 前 16 位；原始 JSON/音频不进入仓库）。

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

运行态收尾状态：selection 恢复 `quality/quality`（schema_version 2，generation 6），
`/health.backend=asr-1.7b-q8`、`asr_runtime_revision` 非空、`/readyz.ready=true`、
`diarization_ready=true`，单一 listener `*:8201`（配置 `SPEECHRAIL_HOST=0.0.0.0` + `SPEECHRAIL_API_KEY`）。

上述均为**延迟/生命周期/资源有界性**证据；**未**覆盖语音质量 CER/WER、克隆身份相似度、自然度盲听，
也未覆盖真实声卡播放器与 ≥2h 长稳（见 §8）。

## 8. 已执行 / not_run

### 8.1 本轮已授权并执行（2026-09-26）

- 以 `speechrail install` 把受控 wheel 装入本机 managed runtime（失败/成功日志留在仓库外），
  `runtime/current` 指向 `…-7e39b8dc60d0-py3147`；运行态不再使用源码 overlay。
- 真实模型加载与推理：reference/quality/fast 三档的 warm bench 与参考档真实 smoke。
- 切档：`profile apply quality→reference→quality→fast→quality` 均由受控事务执行并内置 public-API smoke；
  结束时恢复 `quality/quality`。
- 冷启动、反复取消（×100）、短时 soak（×30 轮）与运行态收尾核对，见 §7.2。
- 静态一致性：完整 pytest（2496 passed / 1 skipped）、Swift 测试（144）、OpenAPI 路径对齐门、MCP 测试。

### 8.2 仍未执行（需人工验收或更长窗口，P5 未勾选）

- **人工听审**：§7.2 的 quality 听审样本（系统音色中/英、克隆音色中文）尚未由目标用户判定内容/身份/自然度。
- **真实声卡播放器**：未验证“决定打断→扬声器实际停音 ≤200ms”，仅有 wire 层 cancel→terminal 证据。
- **≥2h 长稳**：本轮为 30 轮短 soak；计划建议 ≥2h 或评审指定时长。
- **质量硬门**：中文 CER、英文 WER、数字/单位正确率、静音/噪声幻觉率、克隆身份相似度、对齐/分人质量等
  需按 §3 语料分层 + §5.2 阈值执行；阈值须先评审确认。
- **真实 LLM 端到端**：未接入真实 LLM 编排链路（不属于 SpeechRail 服务边界）。
- `scripts/macos_app_test.sh`（含 XCUITest / UI 自动化；会接管前台窗口与输入，需逐次明确授权）。

### 8.3 已知的内部偏差（不影响公共契约）

- `src/speechrail/assets/model-catalog.json` 与 `config/model_catalog.py` 仍保留旧的
  `presets` / `precision_policy`（`extreme`/`quality`/`balanced`/`light`）**数据与校验块**。
  运行时选择路径已按 `asr_spec`/`tts_spec` 解析，CLI / REST / MCP / App 均不接受旧档位名；
  该块仅由 catalog 校验、`tools/build_model_catalog.py` 与测试引用，**未被服务请求路径读取**。
  彻底删除它属于运行时层重构，会改变 wheel 内容并需要重新做 §7.2 的整轮认证，因此本轮不改，
  作为后续 scoped 清理项记录。

## 9. 需用户确认的决策点

1. §5.2 质量阈值与 §6 盲听维度是否采用建议稿，或改为指定标准。
2. §3 语料分层与最小样本量是否够用，或指定自有语料。
3. 是否安排 §7.2 听审样本的人工验收时间窗，以及是否需要真实声卡/≥2h 长稳验收。
4. 是否允许 UI 自动化（会接管前台窗口/焦点/输入），以及可占用的时间窗。
