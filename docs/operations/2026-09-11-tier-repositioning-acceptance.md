---
title: "SpeechRail v2.3.0 三档重定位验收报告 (TIER-REPOS-E)"
status: active
type: acceptance_report
category: tier-repositioning
version: "1.2.0"
date: 2026-09-11
---

# SpeechRail v2.3.0 三档重定位验收报告 (TIER-REPOS-E)

本报告记录 2.3.0 三档按用户定位重排（`light` 4-bit、`balanced`/`quality` 8-bit、`quality` aligner 保持 bf16、aligner 按档位供给、分人能力按档位声明）后，Workstream E 验收门 E1–E6 在**本机 managed 服务**上的实测结果。所有行为变更前的状态以 `contracts/` 与 active 文档为准；本报告只承载本轮实测、契约身份与明确标注的未验证项。

原始 JSON、日志与合成音频保存在仓库外 `$HOME/Library/Application Support/SpeechRail/benchmarks/20260911-tier-repositioning-e7/`；Git 只保留本脱敏汇总。报告不含原始音频、转写文本、API key、PID 或绝对路径。

## 一眼结论

| 门 | 结果 | 证据 |
|---|---|---|
| E1 ASR 精度（0.6B q4 vs q8） | **UNVERIFIED-BLOCKING（仅代理语料）**；正式真人语料仍 `unset` | 6 条独立 macOS `say` 语料直连生产 ASR worker：q4=q8=0.0556，绝对增量 0.0pp ≤ 0.5pp，见 E1 节 |
| E2 TTS 质量（q4 vs q8） | **pass**（客观指标）；MOS/ABX `unset` | 同一 `serena` 音色、同一短句/长文，`voice_quality_v1` 客观指标已测，见 E2 节 |
| E3 分人/对齐（aligner-q8 vs bf16） | **UNVERIFIED-BLOCKING** | 已用构造式多说话人参考实测尝试，服务稳定拒收合成语料（`diarization_unresolved`/`diarization_invalid_output`）；缺授权真人参考 RTTM/UEM，见 E3 节 |
| E4 资源包络（三档） | **pass** | 同 tick `phys_footprint` 峰值 3.37 / 5.31 / 6.40 GiB，均低于 8/16/32 GB 包络，`gate_complete=True` |
| E5 切换闭环 | **pass** | `quality → balanced → light → balanced → quality` 完成并断言，闭环结束于 `quality` |
| E6 能力诚实 | **pass** | `light` 不声明 `gpt-4o-transcribe-diarize` 且 `diarization_ready=false`；`balanced`/`quality` 声明且 ready |

## 测量身份与可比性

| 项目 | 值 |
|---|---|
| 发布版本 | `2.3.0` |
| 提交 | `16af6fb` |
| wheel | `speechrail-2.3.0-cp312-cp312-macosx_26_0_arm64.whl` |
| wheel SHA-256 | `0615b023385378f966f8653d91cf61b140cf1510fce7ac12352ca0e54fc87987` |
| runtime target basename | `speechrail-2.3.0-cp312-cp312-macosx_26_0_arm64-0615b0233853` |
| 硬件 / 内存 | Apple M5 Max / 128 GB |
| macOS / Python | macOS 26.6.2 (25G83) / CPython 3.12.14（managed runtime） |
| 运行态 | 单一 managed 服务，单 `127.0.0.1:8201` listener，`readyz=200` |
| 鉴权 | loopback + 私有 `config/.env` API key；ASR/TTS 走鉴权路径，`/metrics` 只读取 governor 计数 |
| 采样口径 | E4 用仓库 `examples/perf/sample_resources.py`，`footprint -p <pid> -f bytes`，同 tick 当前 footprint 求和；E1 直连生产 `qwen3_worker` IPC，不回退 HTTP 第二实例 |

可比性限制：本报告是本轮单机、单次实测；E2 的两档输出时长不同，因此是"同输入不同档位"的客观指标对比，不是同一 PCM 的 A/B。MOS/ABX 从未对这些档位测量，一律标 `unset`。

## 三档身份表（E6）

| tier | `/health.profile` | ASR artifact（bits） | TTS artifact（bits） | `gpt-4o-transcribe-diarize` | `diarization_ready` |
|---|---|---|---|---|---|
| `light` | light | `asr-0.6b-q4`（4） | `tts-0.6b-custom-q4`（4） | 不声明 | false |
| `balanced` | balanced | `asr-1.7b-q8`（8） | `tts-0.6b-custom-q8`（8） | 声明 | true |
| `quality` | quality | `asr-1.7b-q8`（8） | `tts-1.7b-design-q8`（8） | 声明 | true |

身份取自 `/health` 与 `/v1/models` 的实际声明，不依据计划或目录名推断。`light` 的 `/health.diarization.code` 为 `diarization_not_configured`，`/v1/models` 列表不含分人模型；`balanced`/`quality` 分人均 ready 且对 API 声明。

## E5 切换闭环

本轮执行 `quality → balanced → light → balanced → quality`，每段：先确认外部客户端隔离（`lsof` 无 `ESTABLISHED`、`/metrics` 两类 governor active requests 均为 0），再 `profile apply <tier> --app-home <app-home> --yes`，有界等待 `/readyz=200`，断言 `/health.profile` 等于目标档后才测量。`quality→balanced`（generation 76）与 `balanced→light`（generation 77）在本轮更早完成，随后 `light→balanced`、`balanced→quality` 补全闭环，结束 generation 79：

| 步骤 | 断言结果 |
|---|---|
| `quality → balanced` | `/health.profile=balanced`，`asr-1.7b-q8` + `tts-0.6b-custom-q8`，分人 ready，gen 76 |
| `balanced → light` | `/health.profile=light`，`asr-0.6b-q4` + `tts-0.6b-custom-q4`，分人不配置，gen 77 |
| `light → balanced` | `/health.profile=balanced`，分人 ready，`readyz=200` |
| `balanced → quality` | `/health.profile=quality`，分人 ready，`readyz=200` |

每次 `profile apply` 均以 "Profile applied and public API smoke passed." 结束；`profile status` 最终为 `quality (generation 79, ASR=asr-1.7b-q8, TTS=tts-1.7b-design-q8)`。全过程保持单一 listener，未出现第二实例。

## E4 资源包络（三档）

预热一次 ASR + TTS 使 worker 常驻后，用仓库采样器在同 tick 内对 gateway + 全部受管 worker 求和 `phys_footprint`。worker 为懒加载时采样器每 tick 重新发现进程；`light`/`balanced`/`quality` 的采样 `complete_ticks == ticks`、`missing=0`、`gate_complete=True`，无 RSS 回退。

| tier | 包络 | 常驻（idle）MB | 同 tick 峰值 MB | 峰值 GiB | ticks（complete/total） | 结论 |
|---|---:|---:|---:|---:|---:|---|
| `light` | ≤ 8 GB | 2711.3 | 3455.0 | 3.37 | 11/11 | pass |
| `balanced` | ≤ 16 GB | 4797.4 | 5436.1 | 5.31 | 11/11 | pass |
| `quality` | ≤ 32 GB | 5857.4 | 6548.7 | 6.40 | 9/9 | pass |

进程集合为 gateway + `batch-asr` + `tts`。分人 worker 为合法短生命周期且按需懒加载，本轮采样窗口内未常驻，故未计入峰值；相对 8/16/32 GB 包络仍有充足余量。已知遗留自 2.2.2 release 的 `speechrail-mcp` 代理进程按 SOP 要求排除：其命令行不匹配任何受管 worker 角色，采样器角色分类天然不计入本表。

## E2 TTS 质量（`light` q4 vs `balanced` q8）

同一 `serena` 音色、同一固定短句与同一固定长文，分别在各档合成，取 24 kHz PCM16 mono，调用 `speechrail.domain.voice_quality_metrics.compute_output_quality_metrics`。下表为客观指标（`active_rms_dbfs` / `peak_dbfs` / `chunk_jump_p95_db` / `clipping_ratio` / 实际音频时长），`delta = balanced_q8 − light_q4`：

| 文本 | 指标 | light q4 | balanced q8 | Δ |
|---|---|---:|---:|---:|
| 短句 | active_rms_dbfs | -28.9634 | -24.8988 | +4.0646 dB |
| 短句 | peak_dbfs | -14.7924 | -8.6375 | +6.1549 dB |
| 短句 | chunk_jump_p95_db | 8.5444 | 8.1441 | -0.4003 dB |
| 短句 | clipping_ratio | 0.0 | 0.0 | 0.0 |
| 短句 | audio_seconds | 4.64 | 3.44 | -1.20 s |
| 长文 | active_rms_dbfs | -22.8161 | -27.6286 | -4.8124 dB |
| 长文 | peak_dbfs | -6.2017 | -9.7294 | -3.5278 dB |
| 长文 | chunk_jump_p95_db | 10.0512 | 9.8515 | -0.1996 dB |
| 长文 | clipping_ratio | 0.0 | 0.0 | 0.0 |
| 长文 | audio_seconds | 25.52 | 18.24 | -7.28 s |

两档均无削波（`clipping_ratio=0`），`deterministic=true`（单探针下 `successful_probe_count==probe_count`）。方向说明：q8 在短句上更响，在长文上更轻，且长/短文均更短；这些是响度与时长层面的客观差异，不是感知质量结论。两档输出并非同一 PCM，时长差异使 RMS/峰值不能直接当作"音质"优劣。

**MOS / ABX / 人工自然度**：这些档位从未做过人工听测，按 SOP 记为 `unset`，本报告不编造任何 MOS 或偏好分数。

## E1 ASR 精度（0.6B q4 vs q8）— UNVERIFIED-BLOCKING（仅代理语料）

**结果**：`UNVERIFIED-BLOCKING（仅代理语料）`。相对增量门仅在该**合成代理语料**集合上满足，不构成本门 gate pass，也不构成本机正式的人声质量结论。

**方法**：用与 SpeechRail TTS 无关的 macOS `say` 生成 6 条独立语料（zh×3、en×3），`ffmpeg` 转 16 kHz mono PCM16，直接驱动生产 `speechrail.backends.qwen3_worker`（`--dtype int8`，`PYTHONPATH` 指向 managed release site-packages，无需第二 HTTP 实例），分别对 `asr-0.6b-q4` 与 `asr-0.6b-q8` 转写；中文按字符级 CER、英文按词级 WER，并对参考单元数做长度加权聚合。

| 档位 | 加权错误率（6 条） | 逐条（q4 = q8） |
|---|---:|---|
| `asr-0.6b-q4` | 0.0556 | zh 0.0000 / 0.0556 / 0.0000；en 0.0769 / 0.1429 / 0.1786 |
| `asr-0.6b-q8` | 0.0556 | 同上，逐条与 q4 完全一致 |
| 绝对增量 | **0.0 pp** | 门限 ≤ 0.5 pp → 满足 |

**限制**：语料为合成语音、仅 6 条，且 zh/en 逐条误差相同，说明该集合对本模型偏易、区分度有限；它证明 q4 相对 q8 **无可见劣化**，但不能替代 SOP 要求的"版本固定、人工核对的独立真人语料"。正式人声 CER/WER 仍记为 `unset`。

## E3 分人/对齐（aligner-q8 vs aligner-bf16）— UNVERIFIED-BLOCKING（已实证）

**结果**：`UNVERIFIED-BLOCKING`。

**已做的闭合尝试**：构造式参考——用 macOS `say` 拼接已知 speaker turn 的双说话人音频（4 个 turn，间隔 0.4 s 静音），据此生成 by-construction 的 `reference_rttm` / `uem` / `reference_text_json`，并与 `tools/evaluate_diarization_e2e.py` 要求的 manifest 对齐。运行态观察：

- 合成双说话人音频（混合语种与纯中文两种版本）经公共 `gpt-4o-transcribe-diarize` 均稳定返回 `502 diarization_unresolved`（"Diarization could not resolve every transcript segment"）。
- D1 的 90 s 合成 voiceover（`preset_voiceover_16k_mono.wav`）在补齐 `chunking_strategy=server_vad|auto` 后返回 `502 diarization_invalid_output`（"Diarization backend returned an invalid result"）。
- 对照：真实短单说话人片段（`asr-zh.wav`、`asr-en.wav`）经分人路径返回 `200`、各 1 段、speaker `A`——说明 **2.3.0 分人路径本身工作正常、无回归**，失败局限于合成 TTS 多说话人语料无法被 Sortformer/aligner 稳定归因。

**具体原因**：`tools/evaluate_diarization_e2e.py` 需要外部 manifest，条目必须带 `reference_rttm`、`hypothesis_rttm`、`uem`；在 app home 与仓库外均无任何 `.rttm`/`.uem` 或含 `reference_turns`/`hypothesis_turns` 的 manifest。D1 目录只有 `preset_timeline.json`/`preset_segments_meta.json` 合成时间线 metadata，其 `comparison-report.md` 亦明确写：没有 RTTM/UEM，preset timeline 不能充当真值，DER 为 `N/A`。合成的多说话人假设又无法由服务产出，因此不产生 DER/SACER 数字，也不把它伪装成对齐质量结论。

**闭环所需**：经授权的参考 RTTM/UEM（真人或多说话人真值）与对应运行 manifest（reference/hypothesis 成对、标注 `split` 与 `license`），再以固定 `collar` 运行 `tools/evaluate_diarization_e2e.py` 比较两档 aligner 的 DER 与 cpCER。合成 TTS 语料不能替代。

## Gate 汇总

| Gate | 结果 | 证据 / 原因 |
|---|---|---|
| E1 ASR 精度（代理） | UNVERIFIED-BLOCKING（仅代理语料） | 6 条独立 `say` 语料，q4=q8=0.0556，Δ0.0pp ≤ 0.5pp；仅代理，不构成 gate pass |
| E1 ASR 精度（真人语料） | unset | 无版本固定、人工核对的独立真人语料 |
| E2 TTS 质量（客观） | pass | `voice_quality_v1` 指标已测，q4/q8 差异见 E2 表 |
| E2 MOS/ABX | unset | 从未对这两档做人工听测 |
| E3 分人对齐 | UNVERIFIED-BLOCKING | 无授权参考 RTTM/UEM；合成多说话人语料被服务稳定拒收（已实证） |
| E4 资源包络 | pass | 3.37 / 5.31 / 6.40 GiB，均低于包络，`gate_complete=True` |
| E5 切换闭环 | pass | 闭环结束于 `quality`，generation 79，单 listener |
| E6 能力诚实 | pass | 三档 `/v1/models` 与 `diarization_ready` 均如实声明 |

## 运维发现（已根因，记录为已知约束）

`tools.install_macos.install_managed(..., enable=True)` 只供给 preset 的 ASR/TTS 模型，**不供给该档位的分人 aligner snapshot**。因此直接安装分人档（`balanced`/`quality`）并 `enable`，新服务会以 `aligner snapshot is missing: aligner-bf16` fail-closed，直到随后执行一次 `speechrail profile apply <tier>` 供给 aligner 才能启动。

**缓解（已应用）**：安装后追加一次 `profile apply <tier>`。这正是 `docs/operations/migration-runbook.md`「三档重排与 aligner 供给升级（catalog v2）」记载的两步升级流程，本轮所有切档均按此执行。

**后续建议（不在本轮改动代码）**：二选一——让 `install_managed` 在 `enable=True` 时自行按档位供给 aligner，或让 preflight 在 cutover 前对缺失 aligner 直接判失败，避免出现"安装成功但服务起不来"的中间态。本轮不改代码。

## 限制与未验证

- E1 不是 gate pass：仅用合成代理语料得出相对增量，按 `UNVERIFIED-BLOCKING（仅代理语料）` 记录；真人语料 CER/WER 为 `unset`。
- E3 为 `UNVERIFIED-BLOCKING`，未产生 DER/SACER 数字；已实证合成多说话人语料不可用，且确认 2.3.0 分人路径在真实短音频上无回归。
- E2 只测客观输出指标；MOS/ABX、人工自然度、跨文本身份相似度、跨重启一致性均为 `unset`。
- E4 是单轮、单机测量；分人 worker 懒加载，未常驻采样窗口，未计入峰值。这些数值不构成跨机器的通用内存承诺，也非"常驻内存保证"。
- 未执行 Realtime、吞吐、cold start、长时 soak；本报告范围仅为 E1–E6。

## 复现

原始证据位于仓库外 `$HOME/Library/Application Support/SpeechRail/benchmarks/20260911-tier-repositioning-e7/`（`e1/`、`e2/`、`e3/`、`e4/`、`logs/`）。

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"

# 三档切换与断言（每档一次，串行；质检前先隔离外部客户端）
uv run speechrail profile apply <light|balanced|quality> --app-home "$APP_HOME" --yes
uv run speechrail profile status --app-home "$APP_HOME"
curl -s http://127.0.0.1:8201/health
curl -s http://127.0.0.1:8201/v1/models
curl -s http://127.0.0.1:8201/v1/voices

# E4：预热后同 tick 采样 gateway + 全部 worker 的 phys_footprint
uv run python examples/perf/sample_resources.py \
  --audio "<repo-external 10s ASR fixture>" --mode all --n 4 --warmup
```

E1 代理测量：停服后运行仓库外 harness `benchmarks/20260911-tier-repositioning-e7/e1/e1_cer_wer.py`，它用 `say` 生成独立语料并直连生产 `qwen3_worker` 比较 `asr-0.6b-q4` 与 `asr-0.6b-q8` 的 CER/WER（结束后重启服务）。

`voice_quality_v1` 客观指标使用 `speechrail.domain.voice_quality_metrics.compute_output_quality_metrics`，输入为 24 kHz PCM16 mono；E2 合成经由鉴权公共 API（`serena`），不落库到 Git。
