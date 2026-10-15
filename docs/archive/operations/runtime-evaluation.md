---
title: "SpeechRail 运行时评估：mlx-qwen3-asr 端到端、性能与清理"
status: superseded
version: "1.4.0"
date: 2026-09-26
---

> 本文状态为 `superseded`。上文数字与 E1 结果是其记录日期下的历史测量；当前能力与启用门禁以
> [能力诊断与质量验收](capability-quality-acceptance.md) 和 [运行时与部署](runtime-deployment.md) 为准。

# SpeechRail 运行时评估

> 本文是历史运行评估与方法参考，不定义当前 release、模型、Realtime wire 或安装状态。当前事实以代码、contracts
> 和 active 运维文档为准；本文中的实测版本、性能数字和模型路径不得直接外推到当前环境。

本报告记录 SpeechRail 将 Qwen3-ASR 后端迁移到 Apple Silicon 原生 MLX 运行时
`mlx-qwen3-asr` 之后的端到端、性能与架构清理实测。评估对象为本机
`127.0.0.1:8201`（release `speechrail-1.1.0-...`，`asr_ready=true`、`tts_ready=true`）。

> §1–§6 是迁移期（release `1.1.0`）的历史实测，其中涉及 aligner 的表述属于当时的评估上下文。当前 catalog v2
> 已把 aligner 明确为**分人专用**制品、词级时间戳改由 ASR 原生提供；按档位精度策略下的评估框架见 §7，§7 不
> 替换或重算上文任何历史数字。

## 1. 后端迁移背景

原 ASR worker 使用 vendor 包 `qwen-asr`（官方，pin `transformers==4.57.6`）与
`qwen3_asr_causal`；服务主 venv 因 diarization（`nemo-toolkit`）安装
`transformers 5.16.1`，经 `offline_environment` 的 `PYTHONPATH` 遮蔽 worker 后，
`qwen-asr` 的 `@check_model_inputs()` 兼容补丁在 `check_model_inputs(func)` 新签名下
崩溃（`TypeError`），导致服务启动失败、崩溃循环。

迁移到 `mlx-qwen3-asr`（moona3k，Apple Silicon 原生 MLX，无 PyTorch/transformers
运行时依赖）后，batch 与 streaming 两个 worker 均改用它，直接加载本机
`Qwen/Qwen3-ASR-1.7B`（`thinker.*` 原始权重），彻底绕开该依赖冲突。

## 2. 端到端（E2E）实测

| 维度 | 结果 |
|---|---|
| batch ASR 格式 | `json` / `verbose_json`（含 `language`、`usage`、`segments`）/ `text` / `srt` / `vtt` 均正确（后三者带时间戳，见 §4.1）|
| 错误 envelope | 非法 `response_format` → `422` + 统一 envelope（`invalid_response_format`）+ `request_id`；缺文件 → `422 validation_error` |
| TTS | 4 个 preset（`default`/`warm`/`bright`/`calm`）× `pcm` 均 HTTP 200 |
| Realtime（openai SDK）| `client.realtime.connect(model="whisper-1")` 连接成功；`setup=33ms`、ASR commit→completed=`2564ms`、TTS first_delta=`55ms`、转写正确 |

## 3. 性能实测

| 指标 | 结果 |
|---|---|
| batch 短音频 2.3s | mean `0.50s`，RTF `0.22x` |
| batch 长音频 16.2s | mean `2.06s`，RTF `0.13x`；长文本转写近似逐字准确 |
| 并发（4 workers × 8）| 全成功，`2.23 req/s`，RTF `0.19x`，无溢出 |
| TTS | mean `1.32s`，RTF `0.32x` |
| 背压（24 并发）| `200:8` / `429:16`，`retry_after=1`（Resource Governor 生效）|
| 内存 | 进程 RSS 合计约 `6 GB` + MLX 统一内存权重；系统空闲 `95%`（128 GB）|

## 4. 未验证项复核

### 4.1 srt/vtt 时间戳 —— 已启用（按需）

batch worker 按 `response_format` 决定是否计算时间戳：`srt`/`vtt`/`verbose_json` 传入
`return_timestamps=True`（加载 `Qwen/Qwen3-ForcedAligner-0.6B`），`json`/`text` 走快速路径
（不触发 aligner）。实测 `srt`/`vtt` 均产出**逐字/逐词带时间戳 cue**（如
`你 0.0-0.16s`、`こんにちは 0.08-0.88s`）；`json`/`srt` 单请求均约 `0.5s`（无额外 aligner
开销）。`verbose_json` 现含 `segments`。

### 4.2 Realtime 流式 segments / 时间戳 —— mlx 流式仅文本

`mlx-qwen3-asr` 的 streaming 只输出 `state.text`（partial/final），无逐词时间戳。
故 `/v1/realtime` 的 `completed` 事件 `segments=[]`；partial 与最终文本可靠。
时间戳需单独的 streaming 对齐方案（如分句后 batch align），非当前能力。

### 4.3 实时多语言 —— 已放开

mlx 转写/流式原生支持 30+ 语言。已放开 `NativeRealtimeFactory._SUPPORTED_LANGUAGES`
与 batch worker 的 `LANGUAGES` 映射，覆盖全部 mlx 语言（码+名）。实测：batch
强制 `ja`/`fr`、realtime `language=ja` 均正确转写。短音频（约 0.7s）自动检测可能误判
语言（模型 auto-detect 局限），强制语言可规避。

### 4.4 Realtime 会话释放（边界）

若 realtime WS 连接异常断开而 session 未显式释放，`NativeRealtimeFactory` 的
`_active` 会话会残留，导致后续实时会话返回 `realtime streaming backend busy`，
直至服务重启。属既有健壮性边界（客户端应正常关闭或服务端需在断连时强制释放）。

### 4.5 版本号

未 bump（`1.1.0` 不变）：公开契约未变，内部 ASR 引擎实现变更。如需正式发布/tag
可另走 release 流程。

## 5. 架构清理

| 项 | 结果 |
|---|---|
| 死依赖 | worker venv 卸载迁移后失活的 `qwen-asr`、`qwen3-asr-causal`；已确认 `mlx_qwen3_asr` 仍可导入 |
| 未用缓存 | 删除先前下载但未使用的 `Qwen3-ASR-1.7B-hf`（约 3.8 GB）|
| docs 同步 | `README.md`、`docs/operations/operations-runbook.md`、`configs/speechrail.example.env` 中 `qwen-asr`/PyTorch 措辞 → `mlx-qwen3-asr`；`docs/archive/` 与 ADR 历史保留 |

质量门禁：`ruff` / `mypy` / `redocly` / `git diff --check` 全绿，`pytest` 231 通过；
清理后服务重启，`ready`/`asr_ready`/`tts_ready` 均 `true`。

## 6. 剩余风险 / 回退

- **依赖属性**：`mlx-qwen3-asr` 为社区实现（moona3k），非 Qwen 官方；MLX 为非官方
  Apple Silicon 路径，非 CUDA。
- **回退**：源码 `git checkout -- src/speechrail/backends/qwen3_worker.py
  src/speechrail/backends/qwen3_streaming_worker.py`；文档 `git checkout -- README.md
  configs/speechrail.example.env docs/operations/operations-runbook.md`；服务
  `service stop` → 恢复 `runtime/current` → `service start`；worker venv 死依赖
  可 `uv pip install qwen-asr==0.0.6 qwen3-asr-causal==0.1.0` 复原。

## 7. 当前规格评估框架（三档 specs，2026-09-26）

> 本节定义当前目录的评估口径，不报告新测量结果。`light` 的 4-bit 回退结论是 2026-09-11 的历史 E1 结果；
> `reference` 的高精度制品按裁定继承同族 8-bit 档位的门禁证据，本轮不做性能或质量复测。

三档各有独立精度绑定，ASR 与 TTS 可分别选档，评估必须按实际组合分别记录，不得跨档套用单一数字：

| spec | ASR | TTS 角色 | Aligner（分人 opt-in） | 评估重点 |
|---|---|---|---|---|
| `fast` | `asr-0.6b-q8` | `tts-0.6b-custom-q8` + `tts-0.6b-base-q8` | `aligner-q8` | 8-bit ASR CER/WER 与 TTS 客观质量；4-bit 组合已评估并回退（E1 未过）|
| `quality` | `asr-1.7b-q8` | `tts-1.7b-custom-q8` + `tts-1.7b-base-q8` | `aligner-bf16` | 1.7B 8-bit 的 ASR/TTS 质量、首包、RTF 与常驻峰值 |
| `reference` | `asr-1.7b-bf16` | `tts-1.7b-custom-bf16` + `tts-1.7b-base-bf16` + `tts-1.7b-design-bf16` | `aligner-bf16` | bf16 组合的 CER/WER、TTS、分人、同 tick `phys_footprint`、冷载与首包；本轮按继承证据登记，未实测处为 `UNVERIFIED` |

评估口径：

- **精度策略**：`fast`、`quality` 的 ASR/TTS 为 8-bit，`reference` 为 bf16；aligner 由显式 opt-in 点名供给
  （`aligner-q8` / `aligner-bf16`）。`fast` 的 4-bit 组合已完成历史评估并在
  E1 未通过（公开真人语料 1.38pp > 0.5pp）后回退 `asr-0.6b-q8` + `tts-0.6b-custom-q8`。§3 的 q8 数字仍是
  release `1.1.0` 的历史实测，只能作为**方向性参考**，不能替代当前 specs 矩阵下按组合重新实测的结论。
- **TTS capability 口径**：评估时须分别记录 `custom_voice` / `base`（`reference` 另含 `voice_design`）各 worker 的常驻状态、各 lane
  的 RTF/P95、跨 lane 并发结果以及 capability group 冷却后的恢复延迟；不能跨精度档套用测量。
- **aligner 变体**：aligner 不随档位自动供给，评估须报告实际点名的变体；未供给时不做分人评估。batch 的 word-level
  timestamps 由 ASR 原生提供，不依赖 aligner；Realtime 当前只承诺 segment timestamps，因此不把
  streaming word-level 能力列入 aligner 评估。
- **未测即 `unset`**：没有相应可审查证据的 RTF、物理内存与分人 DER/SACER 必须记为
  `unset`，直到按[能力诊断与质量验收](capability-quality-acceptance.md) 的门完成并留存聚合证据。
  `reference` 的质量、资源与延迟按继承裁定登记、未在本机单独实测，不得标为 PASS。
- 不得把 §2/§3 的历史数字、`readyz=200` 或模型存在当作当前组合的性能或质量结论。
