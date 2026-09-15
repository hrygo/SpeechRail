# benchmarks 原始制品清理记录（2026-09-15）

> 状态：已执行。仓库外 `benchmarks/` 原始制品整体退役，本文件是仓库内的对应记录与重新获取路径说明。
> 范围：`<app-home>/benchmarks/`，34 个条目 / 5.2 GB（v1.7.0 → v2.4.0 实测批次）。
> 测量：2026-09-15（Asia/Shanghai）；清理前 855 GiB 可用 → 清理后 860 GiB（释放 5323 MiB）。
> 依据：结论已由本目录成文报告承接；原始 JSON 可用 perf-benchmark 流程重跑生成，但**不等价于复原**。

`<app-home>` = `~/Library/Application Support/SpeechRail`（本机 managed app home，仓库外）。

## 清理范围与判定

清理前 `benchmarks/` 共 **34 个条目 / 5.2 GB**。其中报告类证据（`json`/`md`/`log`/`csv`/`txt`）只有 **22 MB**，其余约 5.2 GB 均为可再生的实验副产物：

| 类别 | 体量 | 可恢复性 |
|---|---:|---|
| 报告类（28 个批次，365 文件） | 22 MB | 结论由本目录成文报告承接；原始 JSON 可重跑生成 |
| 公开数据集（E7/E3 parquet） | ~2.3 GB | 上游可重新下载（已核实可达） |
| 生成音频（TTS 候选、fixtures） | 1.74 GB / 6113 个 wav+pcm | 过程产物，由对应流程重跑生成 |
| 模型 staging 副本（`.nemo`/`.mlmodelc`） | 674 MB | live 副本仍在 `<app-home>/diarization/`；上游可重下 |
| 工具 venv（`tools-venv`） | 213 MB | 用 `uv` 重建 |
| 其余（rttm/py/pyc/pcm 等） | 余量 | 中间产物 |

判定依据：这些批次全部早于当前 `v2.6.x` 两代以上，且 99.6% 的体量是可重下或可重算的输入与过程产物，而非结论。

## 清理清单（34 条）

| 条目 | 体量 | 性质 |
|---|---:|---|
| `20260905-184852` | 1.4M | 早期过程批次 |
| `20260905-v1.7.0-basic` | 40K | 报告 |
| `20260905-v1.7.0-full` | 196M | 报告 + 大批 fixtures |
| `20260905-v1.7.1-patch` | 28K | 报告 |
| `20260905-v1.8.0-smoke-tts.pcm` | 132K | 原始 PCM |
| `20260905-v1.8.0-voice-recipe-search` | 1.4G | TTS 音色配方搜索，5184 个候选 wav |
| `20260905-v1.8.0-voice-search-smoke` | 4.7M | 过程 smoke |
| `20260906-v1.10.0` | 7.3M | 报告 |
| `20260906-v1.8.0-release` | 40K | 报告 |
| `20260906-v1.8.0-voice-recipe-baseline-holdout` | 18M | 音色配方 holdout |
| `20260906-v1.8.0-voice-recipe-holdout` | 18M | 音色配方 holdout |
| `20260906-v1.8.1-patch` | 24K | 报告 |
| `20260906-v1.9.0` | 8.0K | 报告 |
| `20260906-v1.9.1` | 4.0K | 报告 |
| `20260906-v1.9.2` | 4.0K | 报告 |
| `20260907-operator-efficiency` | 80K | 报告 |
| `20260907-operator-hardening` | 32K | 报告 |
| `20260907-v1.11.0-full` | 80K | 报告 |
| `20260908-d1-diarization-runtime-smoke` | 727M | 分人选型研究：`.nemo` + CoreML + `fluidaudiocli` + 报告 |
| `20260908-v1.13.0-full` | 72K | 报告 |
| `20260908-v1.13.1-patch` | 40K | 报告 |
| `20260909-v2.0.2-full` | 320K | 报告 |
| `20260909-v2.0.3-full-stack` | 7.4M | 报告 |
| `20260909-v2.0.3-full-stack-v2` | 9.2M | 报告 |
| `20260909-v2.0.3-three-tier` | 248K | 报告 |
| `20260909-v2.0.3-three-tier-final` | 328K | 报告 |
| `20260909-v2.1.0` | 524K | 报告 |
| `20260910-v2.2.0` | 412K | 报告 |
| `20260910-v2.2.1` | 152K | 报告 |
| `20260911-tier-repositioning-e7` | 2.6G | E7 档位重定位：voxconverse parquet 数据集为主 |
| `20260911-v2.2.2` | 116K | 报告 |
| `20260911-v2.4.0` | 512K | 报告 |
| `20260911-v2.4.0-ab` | 1.0M | 报告 |
| `tools-venv` | 213M | 基准工具 Python venv |

## 仓库外指针

仓库内约 46 处 `benchmarks/<批次>/` 指针（主要在 `docs/archive/`，另有 1 处在 active 的 `docs/operations/2026-09-11-tier-repositioning-acceptance.md`）指向的原始制品已按本记录**有意退役**，非遗失。

## 重新下载 / 再生成

### 数据集（E3：voxconverse）

```bash
uv run --with huggingface_hub python - <<'PY'
from huggingface_hub import hf_hub_download
for sh in ["dev-00000-of-00005","dev-00001-of-00005","dev-00002-of-00005",
           "dev-00003-of-00005","dev-00004-of-00005"]:
    hf_hub_download("diarizers-community/voxconverse", f"data/{sh}.parquet",
                    repo_type="dataset")
PY
```

### 数据集（E1：公开人类 ASR 语料）

| 语言 | 数据集 | 来源 | 许可 |
|---|---|---|---|
| en | LibriSpeech `test-clean` | `https://www.openslr.org/resources/12/test-clean.tar.gz` | CC BY 4.0 |
| zh | `google/fleurs` `cmn_hans_cn` split `test` | `https://huggingface.co/datasets/google/fleurs` | CC BY 4.0 |

### 模型

```bash
# NVIDIA Sortformer（NVIDIA Open Model License）
uv run --with huggingface_hub python - <<'PY'
from huggingface_hub import hf_hub_download
hf_hub_download("nvidia/diar_streaming_sortformer_4spk-v2.1",
                "diar_streaming_sortformer_4spk-v2.1.nemo")
PY
```

FluidAudio CoreML 模型（`SortformerNvidiaLow_v2.1.mlmodelc`）来自 `FluidInference/FluidAudio`，本次验证过的版本为 commit `5c19d5e12320e22bbfb7a1877b089d2665a69add`；当时通过 `tools/fluidaudiocli` 转换。

**live 模型未受影响**：仍在 `<app-home>/diarization/SortformerNvidiaLow_v2.1.mlmodelc`；本次清理的只是 benchmarks 内的 staging 副本。

### 工具环境与报告再生成

`tools-venv` 是基准工具的普通 uv 环境，按流程重建即可；`fluidaudiocli` 从上述 FluidAudio 版本重建。报告按 `.agents/skills/speechrail-perf-benchmark/SKILL.md` 的流程重跑对应档位，生成新的 `manifest.json` / `<profile>-http.json` / `<profile>-realtime.json` / `aggregate.json`。

## 证据边界

- **重跑不等于复原**：环境、模型版本、采样策略或 profile 定义变化都会导致数字差异。历史结论应引用本目录对应报告，不要与重跑结果混用。
- 原始 JSON 与资源采样日志已清理，**无法精确复现当时数字**；以成文报告中的汇总值为准。
- 当时实测环境为 Apple M5 Max / 128 GiB / macOS 26.6.2 / Python 3.12.14；重跑须声明实际环境。
- 各数据集许可独立（CC BY 4.0、NVIDIA Open Model License 等），重新下载后仍受原条款约束。