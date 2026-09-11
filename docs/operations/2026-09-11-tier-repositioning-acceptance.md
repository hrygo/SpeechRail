---
title: "SpeechRail v2.3.2 三档重定位验收报告 (TIER-REPOS-E)"
status: active
type: acceptance_report
category: tier-repositioning
version: "2.0.0"
date: 2026-09-11
---

# SpeechRail v2.3.2 三档重定位验收报告 (TIER-REPOS-E)

本报告记录 2.3.0 引入、2.3.1 修复、2.3.2 收口的三档按用户定位重排（`light`/`balanced`/`quality`、aligner 按档位供给、分人能力按档位声明）后，Workstream E 验收门 E1–E6 在**本机 managed 服务**上的实测结果。

关键收口：`light` 的 0.6B **4-bit 方案经 E1 在公开真人语料实测未通过**（相对 8-bit 基线劣化 1.38pp > 0.5pp 阈值），依计划「未过即回退上一精度」**回退为 8-bit**（`asr-0.6b-q8` + `tts-0.6b-custom-q8`）；`asr-0.6b-q4` / `tts-0.6b-custom-q4` 制品保留在 catalog 但不被任何档位引用。三档现行精度策略均 8-bit，仅 `quality` aligner 为 bf16。

原始 JSON、日志与合成音频保存在仓库外 `$HOME/Library/Application Support/SpeechRail/benchmarks/20260911-tier-repositioning-e7/`；Git 只保留本脱敏汇总。报告不含原始音频、转写文本、API key、PID 或绝对路径。

## 一眼结论

| 门 | 结果 | 证据 |
|---|---|---|
| E1 ASR 精度（0.6B q4 vs q8） | **FAILED → light 回退 q8** | 公开真人语料实测：en WER +1.25pp、zh CER +1.46pp、总体 **+1.38pp** > 0.5pp 阈值，见 E1 节 |
| E2 TTS 质量（q4 vs q8） | **不适用（N/A）** | `light` 已回退 q8，q4 TTS 不再供给；原 q4-vs-q8 客观对比随之作废，见 E2 节 |
| E3 分人/对齐（aligner-q8 vs bf16） | **pass（未劣化；覆盖 4/11）** | 公开 VoxConverse（CC BY 4.0）：aligner-q8 DER 2.40% vs aligner-bf16 5.04%；cpCER 0.0/0.0，见 E3 节 |
| E4 资源包络（light q8 复测） | **pass** | `light`(q8) idle 3.184 GiB / peak 3.808 GiB，低于 8 GB 包络，`gate_complete=True` |
| E5 切换闭环 | **pass** | 2.3.2 上 `quality → balanced → light → balanced → quality` 完成并断言，结束于 `quality`，单 listener |
| E6 能力诚实 | **pass** | `light` 不声明 `gpt-4o-transcribe-diarize` 且 `diarization_ready=false`；`balanced`/`quality` 声明且 ready |

## 测量身份与可比性

| 项目 | 值 |
|---|---|
| 发布版本 | `2.3.2` |
| 提交 | `7a52390`（wheel 构建源；本报告随后单独提交） |
| wheel | `speechrail-2.3.2-cp312-cp312-macosx_26_0_arm64.whl` |
| wheel SHA-256 | `9e5c8b3136ee6575c4da8356cd02c4ec945947e1a0cb53f276682578ed69897d` |
| wheel 可复现性 | **可复现**：`dist/`、隔离 `build-a/`、`build-b/` 三次构建 SHA-256 一致 |
| runtime target basename | `speechrail-2.3.2-cp312-cp312-macosx_26_0_arm64-9e5c8b3136ee` |
| verify_release | **7/7 OK**（wheel / cli / plist / health / readyz / models / voices） |
| 硬件 / 内存 | Apple M5 Max / 128 GB |
| macOS / Python | macOS 26.6.2 (25G83) / CPython 3.12.14（managed runtime） |
| 运行态 | 单一 managed 服务，单 listener，`readyz=200`，终态 `quality` generation 93 |
| 鉴权 | loopback + 私有 `config/.env` API key；ASR/TTS/`/metrics` 走鉴权路径 |
| 采样口径 | E4 用仓库 `examples/perf/sample_resources.py`，`footprint -p <pid> -f bytes`，同 tick 当前 footprint 求和（`max_tick_span=0.165s`） |
| 公开语料授权 | E1 LibriSpeech test-clean、FLEURS cmn_hans_cn；E3 VoxConverse —— 均 **CC BY 4.0**，经用户同意使用并记录授权 |

## 三档身份表（E6）

| tier | `/health.profile` | ASR artifact（bits） | TTS artifact（bits） | `gpt-4o-transcribe-diarize` | `diarization_ready` |
|---|---|---|---|---|---|
| `light` | light | `asr-0.6b-q8`（8） | `tts-0.6b-custom-q8`（8） | 不声明 | false |
| `balanced` | balanced | `asr-1.7b-q8`（8） | `tts-0.6b-custom-q8`（8） | 声明 | true |
| `quality` | quality | `asr-1.7b-q8`（8） | `tts-1.7b-design-q8`（8） | 声明 | true |

身份取自 `/health` 与 `/v1/models` 的实际声明，不依据计划或目录名推断。`light` 的 `/health.diarization.code` 为 `diarization_not_configured`；`balanced`/`quality` 分人均 ready 且对 API 声明。`quality` 另有 `supports_clone/instruction/preview=true`（`voice_design`），`light`/`balanced` 均为 false（`custom_voice`）。

## E5 切换闭环

在 2.3.2 release 上执行 `quality → balanced → light → balanced → quality`，每段：先确认外部客户端隔离，再 `profile apply <tier> --app-home <app-home> --yes`，有界等待 `/readyz=200`，断言 `/health.profile` 等于目标档后才记录。每跳 `ok=true`（`http_health`/`http_models`/`http_readyz`/`profile`/`asr_artifact`/`tts_artifact`/`bits_8`/`diarization_ready`/`diarize_alias` 全部通过）。

| 步骤 | `/health.profile` | ASR / TTS | `diarization_ready` | 别名 `gpt-4o-transcribe-diarize` |
|---|---|---|---|---|
| `quality`（起始） | quality | `asr-1.7b-q8` / `tts-1.7b-design-q8` | true | 声明 |
| `→ balanced` | balanced | `asr-1.7b-q8` / `tts-0.6b-custom-q8` | true | 声明 |
| `→ light` | light | `asr-0.6b-q8` / `tts-0.6b-custom-q8` | **false** | **不声明** |
| `→ balanced` | balanced | `asr-1.7b-q8` / `tts-0.6b-custom-q8` | true | 声明 |
| `→ quality`（总结） | quality | `asr-1.7b-q8` / `tts-1.7b-design-q8` | true | 声明 |

每次 `profile apply` 均以 `Profile applied and public API smoke passed.` 结束。全过程保持单一 listener，未出现第二实例；闭环结束停在 `quality`。

## E4 资源包络（三档）

预热一次 ASR + TTS 使 worker 常驻后，用仓库采样器在同 tick 内对 gateway + 全部受管 worker 求和 `phys_footprint`。`light` 因 2.3.2 精度由 4-bit 改为 8-bit，**在 2.3.2 上重新采样**；`balanced`/`quality` 模型与精度自 2.3.0 未变，沿用其测量值。

| tier | 包络 | 常驻（idle）MB | 同 tick 峰值 MB | 峰值 GiB | ticks（complete/total） | 结论 |
|---|---:|---:|---:|---:|---:|---|
| `light`（2.3.2, q8） | ≤ 8 GB | 3260.9 | 3899.9 | 3.808 | 11/11 | pass |
| `balanced`（2.3.0, q8） | ≤ 16 GB | 4797.4 | 5436.1 | 5.31 | 11/11 | pass |
| `quality`（2.3.0, q8/bf16） | ≤ 32 GB | 5857.4 | 6548.7 | 6.40 | 9/9 | pass |

`light` 从 q4（2.3.0 实测峰值 3.37 GiB）升至 q8 后峰值增至 3.808 GiB，仍显著低于 8 GB 包络。进程集合为 gateway + `batch-asr` + `tts`；分人 worker 为合法短生命周期、按需懒加载，本轮采样窗口内未常驻，故未计入峰值。已知遗留的 `speechrail-mcp` 代理进程按 SOP 排除（命令行不匹配任何受管 worker 角色）。

## E1 ASR 精度（0.6B q4 vs q8）— FAILED，light 回退 q8

**结果**：**FAILED**。在公开真人语料上，`light` 的 0.6B 4-bit ASR 相对 8-bit 基线劣化 1.38pp，超过 0.5pp 阈值；依计划 Workstream E「每档必须全过；未过则该档回退上一精度」，`light` 回退为 8-bit。

**方法**：使用独立于 SpeechRail TTS 的公开真人语料——en：`openslr/librispeech` test-clean（CC BY 4.0，50 条，393.7 s）；zh：`google/fleurs` `cmn_hans_cn` test（CC BY 4.0，41 条，460.2 s）。分别以 `asr-0.6b-q4` 与 `asr-0.6b-q8` 转写，中文按字符级 CER、英文按词级 WER，对参考单元数做长度加权聚合。

| 语言 | q4 加权错误率 | q8 加权错误率 | 绝对增量 | 门限 |
|---|---:|---:|---:|---|
| en（WER） | 0.0405（42/1036） | 0.0280（29/1036） | **+1.25 pp** | ≤ 0.5 pp |
| zh（CER） | 0.0677（97/1432） | 0.0531（76/1432） | **+1.46 pp** | ≤ 0.5 pp |
| 总体 | 0.0563 | 0.0425 | **+1.38 pp** | **未通过** |

**处置**：`light` 由 `asr-0.6b-q4` + `tts-0.6b-custom-q4` 回退为 `asr-0.6b-q8` + `tts-0.6b-custom-q8`；`asr-0.6b-q4` / `tts-0.6b-custom-q4` 保留在 catalog（可加载）但不被任何档位引用。决策同步见 `docs/decisions/0015-tier-user-positioning-and-precision-policy.md` 的「修订（2026-09-11，E1 之后）」。

**限制**：两档均在同一公开真人集合上比较，样本量（en 50 / zh 41）足以区分 1.38pp 级差异，但不构成对全部口音、噪声与远场场景的普遍结论。

## E2 TTS 质量（q4 vs q8）— 不适用（N/A）

`light` 回退 q8 后，`tts-0.6b-custom-q4` 不再被任何档位供给，E2 的「light q4 vs q8」对比随之作废。此前在客观指标口径下记录的 q4-vs-q8 差异（`voice_quality_v1`）**不再作为产品门控**，仅保留为仓库外 `e2/` 历史证据。

**MOS / ABX / 人工自然度**：这些档位从未做过人工听测，按 SOP 记为 `unset`，本报告不编造任何 MOS 或偏好分数。

## E3 分人/对齐（aligner-q8 vs aligner-bf16）— pass（未劣化）

**结果**：**pass（未劣化）**。在同一批公开参考上，`aligner-q8`（`balanced`）的 DER 不高于 `aligner-bf16`（`quality`）。

**语料**：`diarizers-community/voxconverse`（CC BY 4.0，含真人音频与 ground-truth RTTM）。确定性选择规则：dev split 中全部恰好 2 说话人的片段，各取一段 ≤28 s 窗口（滑动 28 s / 1 s 步进，要求两说话人均在场、最大化较小说话人的最长独白，再最大化覆盖语音，最后取最早偏移），共 11 段、窗口合计 308 s。参考 RTTM/UEM 由 ground-truth turn 生成；假设 RTTM 由服务 `diarized_json` 段转写。

| tier（aligner） | DER | miss | FA | confusion | cpCER | 覆盖 |
|---|---:|---:|---:|---:|---:|---:|
| `balanced`（`aligner-q8`） | 0.0240 | 0.0095 | 0.0145 | 0.0 | 0.0 | 4/11 |
| `quality`（`aligner-bf16`） | 0.0504 | 0.0095 | 0.0397 | 0.0011 | 0.0 | 4/11 |
| 差值（q8 − bf16） | **−2.64 pp** | — | — | — | 0.0 pp | — |
| 门限 | ≤ 1.0 pp | | | | ≤ 0.5 pp | |

`balanced`/`quality` 的失败片段集合完全一致（7/11 相同），说明差异来自 aligner 精度而非随机失败。

**覆盖限制（须与结论同时阅读）**：11 段真实双说话人片段中仅 **4 段**被服务产出假设（104.84 s 参考语音），其余 **7 段**在两档上均被服务以 `502 diarization_unresolved` 拒绝（见「运维发现」）。判决建立在 104.84 s 之上，且 DER 差值由单一差异片段（`…-088`：q8 0.0503 vs bf16 0.1661）驱动，**统计稳健性有限**。

**cpCER 口径**：公开 VoxConverse parquet 不含转写文本，故 cpCER 采用「保持 ASR 文本不变」的构造——参考单元带 ground-truth speaker 标签、假设单元带服务 label，二者共用同一冻结段文本，仅测**字符加权的说话人归因**，不是独立转写文本的 CER。

**collar**：任务默认 `collar=0.0`；`collar=0.25` 因工具内置 custom-DER 与 pyannote 一致性自检在片段 `…-088` 上抛 `RuntimeError` 而无法评分，两档统一用 0.0。

**历史对照**：此前用合成 TTS 多说话人语料尝试 E3 时，服务稳定拒收（`diarization_unresolved`/`diarization_invalid_output`），但对真实短单说话人片段返回 200 —— 说明 2.3.x 分人路径本身无回归，合成语料不可作为 E3 真值。

## 运维发现

**（1）分人档安装/升级阻断（已在 2.3.1 修复）**：2.3.0 的 `tools.install_macos.install_managed(..., enable=True)` 只供给 preset 的 ASR/TTS，**不供给该档 aligner snapshot**，直接安装分人档并 `enable` 会 fail-closed（`aligner snapshot is missing: aligner-bf16`）；更严重的是既有分人档从旧 release 升级时构成「新 wheel preflight 对旧 selection fail-closed、而供给 aligner 的 `profile apply` 又委托旧 runtime」的循环。修复（2.3.1，commit `89ee79f`）：`install_managed` 在 `preset.diarization` 且未显式传入 `diarization_assets` 时，自行按档供给 aligner **后才**写配置与 preflight，供给失败按既有事务回滚。本轮 2.3.2 升级即经该路径完成并 `verify_release` 7/7。

**（2）真实双说话人片段高拒绝率（2.3.2 新增观察，未修复）**：公开 VoxConverse 的 11 段真实 2 说话人窗口中，**7 段（63.6%）**被生产严格归因策略以 `502 diarization_unresolved` 拒绝，且 `balanced`/`quality` 拒绝集合相同。这与 aligner 精度无关，属服务对真实对话语音（重叠/附和/背景噪声）的归因严格度限制。**E3 判决仅覆盖被接受的 4 段**；该拒绝率是后续分人质量工作的独立输入，不在本报告修复范围内。

## Gate 汇总

| Gate | 结果 | 证据 / 原因 |
|---|---|---|
| E1 ASR 精度（公开真人语料） | **FAILED → light 回退 q8** | en +1.25pp、zh +1.46pp、总体 +1.38pp > 0.5pp 阈值 |
| E2 TTS 质量 | N/A | `light` 已回退 q8，q4 TTS 不再供给；MOS/ABX `unset` |
| E3 分人对齐 | pass（未劣化） | aligner-q8 DER 2.40% vs aligner-bf16 5.04%（Δ−2.64pp ≤ 1.0pp）；cpCER 0.0；覆盖 4/11 |
| E4 资源包络 | pass | light(q8) 峰值 3.808 GiB ≤ 8 GB；balanced/quality 沿用 5.31 / 6.40 GiB；`gate_complete=True` |
| E5 切换闭环 | pass | `quality→balanced→light→balanced→quality` 全跳断言通过，单 listener，结束于 `quality` |
| E6 能力诚实 | pass | 三档 `/v1/models` 与 `diarization_ready` 均如实声明 |

## 限制与未验证

- E1 结论基于公开真人语料（en 50 / zh 41 条），足以区分 1.38pp 级差异，但不覆盖全部口音/噪声/远场场景。
- E3 仅覆盖 4/11 片段、104.84 s；DER 差值由单一片段驱动，统计稳健性有限；cpCER 为归因代理口径，非独立转写 CER。
- E2 仅保留历史客观指标；MOS/ABX/人工自然度、跨文本身份相似度、跨重启一致性均为 `unset`。
- E4 为单轮、单机测量；`light` 在 2.3.2 复测，`balanced`/`quality` 沿用 2.3.0 值（模型与精度未变）。这些数值不是跨机器内存承诺，也非「常驻内存保证」。
- 未执行 Realtime、吞吐、cold start、长时 soak；本报告范围仅为 E1–E6。
- 真实双说话人对话的 7/11 拒绝率（运维发现 2）未在本轮修复，E3 覆盖限制即由此而来。

## 复现

原始证据位于仓库外 `$HOME/Library/Application Support/SpeechRail/benchmarks/20260911-tier-repositioning-e7/`（`e1-public/`、`e3-public/`、`release-232/` 等）。

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"

# 三档切换与断言（每档一次，串行；切换前先隔离外部客户端）
uv run speechrail profile apply <light|balanced|quality> --app-home "$APP_HOME" --yes
uv run speechrail profile status --app-home "$APP_HOME"
curl -s http://127.0.0.1:8201/health
curl -s http://127.0.0.1:8201/v1/models
curl -s http://127.0.0.1:8201/v1/voices

# E4：预热后同 tick 采样 gateway + 全部 worker 的 phys_footprint
uv run python examples/perf/sample_resources.py \
  --audio "<repo-external 10s ASR fixture>" --mode all --n 4 --warmup
```

E1 公开语料测量：仓库外 `benchmarks/20260911-tier-repositioning-e7/e1-public/e1_public_harness.py`（LibriSpeech / FLEURS 下载与转写，直连生产 `qwen3_worker`，比较 `asr-0.6b-q4` 与 `asr-0.6b-q8` 的加权 CER/WER）。E3：`e3-public/` 下的 `prepare_e3_public.py` / `capture_e3.py` / `build_summary.py`（VoxConverse 取材、假设捕获、`tools/evaluate_diarization_e2e.py` 打分）。发布：`release-232/`（wheel sha、`verify_release` 输出、E5 逐跳快照、E4 采样、E6 能力表、终态）。

`voice_quality_v1` 客观指标使用 `speechrail.domain.voice_quality_metrics.compute_output_quality_metrics`，输入为 24 kHz PCM16 mono；合成经由鉴权公共 API（`serena`），不落库到 Git。
