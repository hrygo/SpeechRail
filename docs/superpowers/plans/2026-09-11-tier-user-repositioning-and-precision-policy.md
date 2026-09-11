# 三档用户定位重排与按档位精度策略 — 实施计划（rev.2 · 审查修订版）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Status:** ready（rev.2）

**Goal:** 把三档从"按内存的同一能力大小档"重排为**按用户的差异化档**；解除"全档 8-bit"铁律，改为**按档位精度策略**；aligner 作为**分人专用制品**按档位供给；diarization 按档位门控。

**Architecture:** 保持"一套 MLX runtime + 每模型一 worker + 仅换权重与量化"（ADR-0011）。在其上：① catalog 增 `precision_policy` 与 `preset.diarization` / `preset.aligner`；② aligner 升为 catalog 一等制品，但**不进入 `PreparedModelSet` / `prepare_models`**（避免 2→3 元重构与 prepared_id 迁移）；③ aligner 与 Sortformer 同属"分人供给"，由 `diarization_assets` 按档位供给；④ `resolve_selection` 依档位覆盖 `qwen3_aligner_model_dir` 与 `diarization_coreml_model_path`。不改公共 API 形状、worker IPC、调度与并发。

**Tech Stack:** Python 3.12, `uv`, pytest, Ruff, mypy, pydantic v2, MLX, Markdown 验收记录。

**Supersedes:** ADR-0011 §2（三档组成）与 §8（4-bit 仅作同档候选）。新建 ADR-0015；在 ADR-0011 标注 `tier composition superseded by 0015`。

---

## 0. 修订说明（rev.1 审查发现 → 本版处置）

四路独立审查（Momus / Oracle×2 / deep）共发现 5 BLOCKER + 若干 MAJOR。本版逐条修正：

| 审查发现 | 本版处置 |
|---|---|
| **B1 aligner 被误当作 word_timestamps 依赖** | 澄清：aligner **仅服务分人**；word_timestamps 由 ASR 原生提供（`timestamp_granularities`）。**light 不再含 aligner/Sortformer** |
| **B2 抓取脚本不可执行**（排除集错、缺 Recursive、多修订即崩） | 重写脚本：`Recursive=true`；排除集 `{.gitattributes, configuration.json}`（**保留 README.md**）；仅接受单修订仓库 |
| **B3 计划内顺序错误**（A3 断言 v2 早于 A4 重建目录） | 重排：**先生成 catalog，再跑 v2 契约测试** |
| **B4 体积错误**（tts-1.7b-custom-q4=1765MB 实为 2312MB） | **弃用该制品**；balanced 改用既有 `tts-0.6b-custom-q8`；体积按实测重算 |
| **B5 迁移/回滚不成立** | aligner 不进 `PreparedModelSet` → `_prepared_id`/registry **不变**；`resolve_selection` 加目录存在性守卫；明确"先供给、后重启"顺序 |
| M1 能力发布点引用错误 | 改指真实位置：`http/routes/system.py` + `application/services.py::diarization_status`；**不新增 capability** |
| M2 preflight aligner 校验被嵌套 | 改为按 `preset.aligner` 驱动（light 无 aligner 时跳过；balanced/quality 校验） |
| M3 model_store 2→3 硬编码 | **取消**该改动（aligner 不进入 prepared-set） |
| M4 zero_setup 无条件跑分人 smoke | 按 `preset.diarization` 门控 |
| M5 测试爆炸半径低估 | 完整枚举（见 §4 + Workstream A–C） |
| M6 验收门不可证伪 | 改为可证伪（见 Workstream E） |
| M7 内部一致性（"8 个制品"等） | 修正为 8 个（5 复用 + 3 新增），保留的 2 个备用仍计入 |
| M8 文档遗漏 `README.zh-CN.md` 等 | 补入 D-table |

> **对既有决策的更正**：上一轮"接受 aligner-4bit 给 light 档"基于"aligner 提供词级时间戳"的错误前提。核实后 aligner 仅分人使用，**light 档无需 aligner**（词级时间戳仍可用，由 ASR 提供）。若仍希望 light 支持分人，则 light = 上述 + `aligner-4bit` + Sortformer（体积 ≈3.65GB，见 §2.5 备选）。

---

## 1. 核实事实（带证据）

### 1.1 aligner 的真实依赖（决定性）

- `text_aligner` **仅在分人路径**被引用：`src/speechrail/http/routes/audio.py:733/764/772/780/1082-1089`、`src/speechrail/application/realtime_openai.py:374/1064`。
- 词级时间戳来自 **ASR 原生** `result.words`：`src/speechrail/application/transcript_merge.py:172/208/295`、`src/speechrail/backends/qwen3_native.py:494`；API 参数 `timestamp_granularities`（`http/routes/audio.py:704`、`http/formatters.py:16/44`、`compatibility/openai_realtime.py:756`）。
- `validate_forced_aligner_snapshot` **仅在 `aligner_model_dir is not None` 时调用**（`backends/qwen3_native.py:202`）→ aligner 可选。
- `diarization_status` 在 `CoreMLSortformerEngine` 但 aligner 为空时报 `diarization_alignment_not_configured`（`application/services.py:227`）。

**结论：aligner ⊂ diarization。light（无分人）不需要 aligner，且缺失它不影响 ASR。**

### 1.2 制品锁定数据（ModelScope，`Recursive=true` 实测）

| key | repository | revision | 总字节 | MB | 修订数 |
|---|---|---|---|---|---|
| **新增** `asr-0.6b-q4` | `mlx-community/Qwen3-ASR-0.6B-4bit` | `70ccd0ba0c24b0c78efc313ce81c1c78c64a3dd7` | 712,782,000 | 712.8 | 1 |
| **新增** `aligner-q8` | `mlx-community/Qwen3-ForcedAligner-0.6B-8bit` | `998b617c695f61865d444c62051fe51030acef6f` | 1,276,476,700 | 1276.5 | 1 |
| **新增** `aligner-bf16` | `mlx-community/Qwen3-ForcedAligner-0.6B-bf16` | `b8ac37cafb30fdf58d3b57910c292d3b4dee4a65` | 1,840,063,671 | 1840.1 | 1 |
| 复用 `asr-1.7b-q8` | （既有一等制品） | — | 2,467,857,511 | 2467.9 | — |
| 复用 `tts-0.6b-custom-q4` | （既有） | — | 1,693,603,219 | 1693.6 | — |
| 复用 `tts-0.6b-custom-q8` | （既有） | — | 1,973,573,869 | 1973.6 | — |
| 复用 `tts-1.7b-design-q8` | （既有） | — | 3,080,139,348 | 3080.1 | — |
| 备用 `asr-0.6b-q8` | （既有，保留不引用） | — | 1,010,772,242 | 1010.8 | — |
| ~~弃用~~ `tts-1.7b-custom-q4` | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit` | **2 个修订** | 2,312,060,216 | **2312.1** | 2 → 不可 pin |

固定项：Sortformer CoreML **235MB**、VAD `silero_vad.onnx` **2,327,524B**。

### 1.3 catalog 文件集约定（既有 5 制品实测）

- **包含**：`README.md`、`config.json`、`chat_template.json`（ASR/aligner）、`generation_config.json`、`merges.txt`、`vocab.json`、`tokenizer_config.json`、`preprocessor_config.json`、`model.safetensors`、`model.safetensors.index.json`、`speech_tokenizer/*`（TTS）。
- **不包含**：`.gitattributes`、根级 `configuration.json`（`speech_tokenizer/configuration.json` 保留）。

### 1.4 关键符号位置

| 位置 | 说明 |
|---|---|
| `src/speechrail/config/model_catalog.py:287` | 现"preset 必须 8-bit"规则 |
| `src/speechrail/config/model_catalog.py:24/25` | `Family` / `Variant` 字面量 |
| `src/speechrail/config/model_catalog.py:203-210` | `ModelPreset`（现仅 id/asr/tts） |
| `tools/build_model_catalog.py:21/39/286/311` | `_SCHEMA_VERSION` / `_PRESET_FIELDS` / `_normalise_preset` / `expected_top_level` |
| `src/speechrail/config/selection.py:52/20-49` | `resolve_selection` / `ActiveModelCatalog` |
| `src/speechrail/service/preflight.py:415-461` | `diarization_configured` 块与 `diarization_aligner_snapshot` |
| `src/speechrail/application/services.py:214-255/324/385/466` | `diarization_status` 与 aligner 消费 |
| `tools/install_macos.py:239-266/71/503` | `_managed_config`/`DiarizationInstallPaths`/校验 |
| `.agents/skills/speechrail-zero-setup/scripts/zero_setup.py:395-421` | 分人供给与分人 smoke |

---

## 2. 冻结设计

### 2.1 三档矩阵

| | 🟢 `light` — Embedded | 🟡 `balanced` — Pro Workflow | 🟣 `quality` — Studio |
|---|---|---|---|
| 用户 | 嵌入/8GB 基础机 | 会议/播客/访谈、16–24GB | 创作者/R&D、32GB+ |
| ASR | `asr-0.6b-q4` | `asr-1.7b-q8` | `asr-1.7b-q8` |
| TTS | `tts-0.6b-custom-q4` | `tts-0.6b-custom-q8` | `tts-1.7b-design-q8` |
| Aligner | **—（无）** | `aligner-q8` | `aligner-bf16` |
| Diarization | ✗ | ✓ Sortformer | ✓ Sortformer |
| VAD | ✓ | ✓ | ✓ |
| 安装体积 | **≈2.41GB** | **≈5.96GB** | **≈7.63GB** |
| 对今日 | **−2.65GB** | **−0.56GB** | ±0 |

### 2.2 体积算式（实测）

- light = 712.8 + 1693.6 + 2.3(VAD) = **2408.7MB**
- balanced = 2467.9 + 1973.6 + 1276.5 + 235 + 2.3 = **5955.3MB**
- quality = 2467.9 + 3080.1 + 1840.1 + 235 + 2.3 = **7625.4MB**

### 2.3 能力矩阵（API 声明契约）

| 能力 | light | balanced | quality |
|---|---|---|---|
| batch / realtime / segment+word timestamps | ✓ | ✓ | ✓ |
| diarization | ✗ | ✓ | ✓ |
| translation | ✓ | ✓ | ✓ |
| voice design / clone | ✗ | ✗ | ✓ |

> 说明：`word_timestamps` 由 ASR 原生提供，**与 aligner 无关**，三档均有。diarization 由 `services.diarization_ready` 动态声明（light 无 CoreML 路径 → 别名不出现在 `/v1/models`）。

### 2.4 设计决策

- **D1**：`ModelPreset.aligner: StrictStr | None`（light 为 `null`）、`ModelPreset.diarization: bool`。
- **D2**：`precision_policy` 顶层字段，`aligner` 取值为 `StrictInt | Literal["bf16"] | None`（`null`=该档无 aligner；`"bf16"`=未量化）。
- **D3**：**aligner 不进 `prepare_models` / `PreparedModelSet`** → `_prepared_id` 与 registry **零迁移**；aligner 由 `diarization_assets` 依 catalog 供给到 `app_home/diarization/<aligner-key>`。
- **D4**：`resolve_selection` 依 `preset.aligner` / `preset.diarization` 覆盖 `qwen3_aligner_model_dir` 与 `diarization_coreml_model_path`（light 置 `None`）。
- **D5**：只解除两条判定——"preset 必须 8-bit" 与 `balanced.tts == light.tts` 共享强制；**保留** `quality.tts.variant==voice_design` 与 `balanced/light.tts.variant==custom_voice`（不放松）。
- **D6**：`recommend_profile` 保留阈值但降级为"内存兜底建议"（档位以用户选择为准）。
- **D7**：catalog `schema_version` 1→2（新增顶层字段与 preset 字段）。

### 2.5 备选（若要求 light 支持分人）

light + `aligner-q4`（模型另需 `mlx-community/Qwen3-ForcedAligner-0.6B-4bit`）+ Sortformer → 体积 ≈ 712.8+1693.6+971.3+235+2.3 = **3615MB ≈ 3.62GB**。默认**不采用**；若采用，需把 `aligner-q4` 一并纳入 §3 生成清单并单独过 E3 门。

---

## Global Constraints

- 档位只选择权重与量化（ADR-0011 §3）；本计划新增的**能力门控仅限分人制品是否供给**，不改 VAD/分段/上下文/缓存/并发/调度/温度。
- API 如实声明能力；light 无分人时不得声明 `gpt-4o-transcribe-diarize`。
- 不静默降级：4-bit 档位是显式选择；质量门未过则该档回退上一精度。
- 请求路径不得下载模型；`prepare_models` 与分人供给仅在 install / `profile apply` 触发。
- 所有制品 revision 为 40 位不可变 commit，逐文件锁定 `size`+`sha256`。
- 不改 `docs/archive/**`；运行时变更须经 managed release（ADR-0014）。

---

## Workstream A — 模型目录（顺序已修正）

> **顺序要求**：A1 生成元数据 → A2 builder 扩展 → **A3 先重建 catalog（原 A4）** → A4 再改 v2 契约测试并运行。

### Task A1: 生成新增制品锁定元数据

**Files:** Create `tools/model-catalog.metadata.json`；Create `tools/fetch_catalog_artifacts.py`

- [ ] **Step 1: 写抓取脚本（已修正）**

  ```python
  #!/usr/bin/env python3
  """Fetch immutable metadata for NEW SpeechRail catalog artifacts (ModelScope)."""
  from __future__ import annotations
  import json, sys, urllib.request

  # 与既有 5 制品一致：剔除 .gitattributes 与根级 configuration.json；保留 README.md 与 *.index.json
  EXCLUDE_EXACT = {".gitattributes", "configuration.json"}
  NEW = [
      ("asr-0.6b-q4", "mlx-community/Qwen3-ASR-0.6B-4bit",              "qwen3_asr",             "asr",     (4, 64, "mlx")),
      ("aligner-q8",  "mlx-community/Qwen3-ForcedAligner-0.6B-8bit",    "qwen3_forced_aligner",  "aligner", (8, 64, "mlx")),
      ("aligner-bf16","mlx-community/Qwen3-ForcedAligner-0.6B-bf16",    "qwen3_forced_aligner",  "aligner", (None, None, "none")),
  ]

  def files(repo: str) -> list[dict]:
      url = (f"https://modelscope.cn/api/v1/models/{repo}/repo/files"
             "?Revision=master&Recursive=true")
      req = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
      with urllib.request.urlopen(req, timeout=40) as r:
          return (json.load(r).get("Data") or {}).get("Files") or []

  def main() -> None:
      out = []
      for key, repo, family, variant, (bits, gs, fmt) in NEW:
          fs = files(repo)
          revs = sorted({f["Revision"] for f in fs})
          if len(revs) != 1:
              raise SystemExit(f"{repo}: expected one canonical revision, got {revs}")
          rev = revs[0]
          entries = [
              {"path": f["Path"], "size": f["Size"], "sha256": f["Sha256"]}
              for f in fs
              if f.get("Type") != "tree"
              and f["Path"] not in EXCLUDE_EXACT
              and f.get("Sha256")
          ]
          out.append({
              "key": key, "model_id": repo, "revision": rev,
              "family": family, "variant": variant,
              "quantization": {"bits": bits, "group_size": gs, "format": fmt},
              "files": entries,
              "sources": [{"provider": "modelscope", "repository": repo, "revision": rev}],
          })
      json.dump(out, sys.stdout, ensure_ascii=False, indent=2); sys.stdout.write("\n")

  if __name__ == "__main__":
      main()
  ```

- [ ] **Step 2: 抓取并核对**

  ```bash
  uv run python tools/fetch_catalog_artifacts.py > /tmp/new.json
  ```
  锚点核对：`asr-0.6b-q4.model.safetensors = 708236945`、`aligner-q8.model.safetensors = 1271924386`、`aligner-bf16.model.safetensors = 1835539240`；文件路径集合须与既有 `asr-0.6b-q8`（含 `README.md`、`model.safetensors.index.json`；不含 `.gitattributes`、根级 `configuration.json`）逐项一致。

- [ ] **Step 3: 合并为完整 builder 输入（共 8 个制品）**

  复用 5（`asr-0.6b-q8` 备用、`asr-1.7b-q8`、`tts-0.6b-custom-q4`、`tts-0.6b-custom-q8`、`tts-1.7b-design-q8`）的元数据**由现有 `src/speechrail/assets/model-catalog.json` 反推**（仓库内无既有元数据文件，builder 无调用点——须在计划中如实说明），加新增 3，写入 `tools/model-catalog.metadata.json`，并写入 `precision_policy` 与 `presets`：

  ```json
  "presets": [
    {"id":"light","asr":"asr-0.6b-q4","tts":"tts-0.6b-custom-q4","aligner":null,"diarization":false},
    {"id":"balanced","asr":"asr-1.7b-q8","tts":"tts-0.6b-custom-q8","aligner":"aligner-q8","diarization":true},
    {"id":"quality","asr":"asr-1.7b-q8","tts":"tts-1.7b-design-q8","aligner":"aligner-bf16","diarization":true}
  ],
  "precision_policy": {
    "light":{"asr":4,"tts":4,"aligner":null},
    "balanced":{"asr":8,"tts":8,"aligner":8},
    "quality":{"asr":8,"tts":8,"aligner":"bf16"}
  }
  ```

### Task A2: 扩展 builder

**Files:** Modify `tools/build_model_catalog.py`；Test `tests/test_model_catalog_builder.py`

- [ ] **Step 1** `_PRESET_FIELDS` → `{"id","asr","tts","aligner","diarization"}`；`_normalise_preset` 返回类型改 `dict[str, object]`，校验 `diarization` 为 bool、`aligner` 为 str|None。
- [ ] **Step 2** `expected_top_level` 增 `precision_policy`，新增 `_normalise_precision_policy`（键恰为三档；`asr/tts` 正整数，`aligner` 正整数或 `"bf16"` 或 null）。
- [ ] **Step 3** `_SCHEMA_VERSION` 1→2；`build_catalog` 返回体**必须包含 `precision_policy`**；`presets` 注解改 `list[dict[str, object]]`。
- [ ] **Step 4** 测试：缺 `aligner`/`diarization` 的 preset 失败；非法 `precision_policy` 失败；合法输入产出 v2。

### Task A3: 重建 catalog（**先于**契约测试）

- [ ] **Step 1**
  ```bash
  uv run python tools/build_model_catalog.py tools/model-catalog.metadata.json \
    --output src/speechrail/assets/model-catalog.json
  ```
- [ ] **Step 2** 确认 `schema_version==2`、8 个制品、三档引用正确。

### Task A4: catalog 模型与校验 + 契约测试

**Files:** Modify `src/speechrail/config/model_catalog.py`；Test `tests/test_model_presets.py`、`tests/test_model_identity.py`

- [ ] **Step 1** `Family` + `qwen3_forced_aligner`；`Variant` + `aligner`；`validate_identity`：`qwen3_forced_aligner` 必须 `variant==aligner`。
- [ ] **Step 2** `ModelPreset` 增 `aligner: StrictStr | None`、`diarization: StrictBool`。
- [ ] **Step 3** 新增 `TierPrecision`（`asr: StrictInt`,`tts: StrictInt`,`aligner: StrictInt | Literal["bf16"] | None`）与 `ModelCatalog.precision_policy: Mapping[PresetId, TierPrecision]`。
- [ ] **Step 4** `_SCHEMA_VERSION` 1→2；重写 `validate_catalog`：删除 8-bit 规则与 `balanced.tts==light.tts`；按 `precision_policy` 校验三制品 bits（`null`⇒无 aligner；`"bf16"`⇒bits 为 None；int⇒相等）；保留 voice_design/custom_voice 变体规则。
- [ ] **Step 5** 测试改造（**完整**）：
  - `_catalog_payload()` 增加 `aligner`/`diarization` 与 aligner 制品；
  - 重写 `test_load_catalog_contains_complete_eight_bit_presets` → `..._matches_tier_precision_policy`；
  - 重写 `test_preset_relationships_keep_weight_changes_only`（移除 `balanced.tts==light.tts`）；
  - **重写 `test_catalog_rejects_four_bit_default_tts`（L265）** → q4 现应合法；
  - **修 `test_catalog_rejects_bad_reference`（L229）** 的内联 preset（补 aligner/diarization）；
  - `test_preset_cannot_override_execution_policy` 补新字段仍断言 `extra=forbid`。
- [ ] **Step 6** `uv run --extra dev pytest --no-cov tests/test_model_presets.py tests/test_model_identity.py tests/test_model_catalog_builder.py -q`

---

## Workstream B — 选择、分人供给与运维命令

### Task B1: `resolve_selection` 依档位覆盖 aligner 与分人

**Files:** Modify `src/speechrail/config/selection.py`；Test `tests/test_profile_selection.py`

- [ ] **Step 1** `ActiveModelCatalog` 增 `aligner: str | None`、`diarization: bool`；`active_model_catalog` 从 `settings.qwen3_aligner_model_dir.name` 与 preset 推导。
- [ ] **Step 2** `resolve_selection`（用现有变量 `expected_preset`，非 `active`）追加：

  ```python
  if expected_preset.aligner is None:
      updates["qwen3_aligner_model_dir"] = None
      updates["diarization_coreml_model_path"] = None
  else:
      aligner_dir = (resolved_app_home / "diarization" / expected_preset.aligner)
      if not aligner_dir.is_dir():
          raise SelectionError(f"aligner snapshot is missing: {expected_preset.aligner}")
      updates["qwen3_aligner_model_dir"] = aligner_dir
      if not expected_preset.diarization:
          updates["diarization_coreml_model_path"] = None
  ```

- [ ] **Step 3** 测试：`test_selection_overlays_aligner_dir_by_preset`、`test_light_selection_clears_aligner_and_diarization`；更新既有用例，使其在需要时创建 aligner 目录。
- [ ] **Step 4** `uv run --extra dev pytest --no-cov tests/test_profile_selection.py -q`

### Task B2: `diarization_assets` 按档位供给（读 catalog）

**Files:** Modify `src/speechrail/service/diarization_assets.py`；Test `tests/test_installer.py`、`tests/test_service_preflight.py`

- [ ] **Step 1** 删除内置 `_ALIGNER_*` BF16 常量；改为从 catalog 读取 `preset.aligner` 对应制品（revision+files）并供给到 `app_home/diarization/<aligner-key>`（沿用现有哈希校验/原子发布）。
- [ ] **Step 2** 签名 `prepare_diarization_assets(app_home, *, preset_id, downloader)`；`preset.diarization is False` → 直接返回 `None`（不下载、不写路径）。
- [ ] **Step 3** 测试：light 不产生 Sortformer/aligner 目录、不写 `SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR`；balanced/quality 分别供给 `aligner-q8`/`aligner-bf16`。
- [ ] **Step 4** `uv run --extra dev pytest --no-cov tests/test_installer.py tests/test_service_preflight.py -q`

### Task B3: preflight

**Files:** Modify `src/speechrail/service/preflight.py`

- [ ] **Step 1** `diarization_aligner_snapshot` 改为**按 `settings.qwen3_aligner_model_dir is not None` 驱动**（light 为 None → 跳过并记 "no aligner configured"）；balanced/quality 校验 `("config.json",)` + `WEIGHT_FILE_SETS`。
- [ ] **Step 2** `diarization_configured` 仍以 CoreML 路径为准（light 无 → 可选未配置）。

### Task B4: 运维命令与档位建议

**Files:** Modify `src/speechrail/service/profile_commands.py`；Test `tests/test_profile_commands.py`

- [ ] **Step 1** `list_profiles` 的 `download_bytes` 纳入 aligner 与 Sortformer（按 `preset.diarization`/`preset.aligner`）。
- [ ] **Step 2** `model_changes` 纳入 `aligner`。
- [ ] **Step 3** `recommend_profile` docstring 改为"内存兜底建议"（保留 10/16 阈值，不改行为）。
- [ ] **Step 4** 更新 `test_catalog_lists_exact_three_tiers_and_balanced_to_light_only_changes_asr`（新矩阵下 `balanced.tts != light.tts`；`model_changes(balanced, light)` 应含 `asr`/`tts`/`aligner`）。
- [ ] **Step 5** `uv run --extra dev pytest --no-cov tests/test_profile_commands.py -q`

### Task B5: `profile apply` 增补分人供给

**Files:** Modify `src/speechrail/service/profile_commands.py`（`apply_profile`）

- [ ] **Step 1** `apply_profile(preset)` 增加 `prepare_diarization(preset, app_home)` 步骤（复用 `_prepare_profile` 的 downloader），实现"切换档位即切换/关闭分人"。
- [ ] **Step 2** `light` 时清空 aligner/CoreML 环境（由 B1 的 `resolve_selection` 覆盖 + 供给层返回 None）。
- [ ] **Step 3** 测试：三档互切后分人状态正确（light 关闭、balanced/quality 开启）。

### Task B6（显式声明，不改动）

- `src/speechrail/service/model_store.py` 的 `prepare_models`/`PreparedModelSet`/`_prepared_id`/`resolve_prepared_selection` **保持不变**（aligner 不进 prepared-set）。因此**无 registry/prepared_id 迁移**。

---

## Workstream C — 安装器与 zero-setup

### Task C1: 按档位供给与门控

**Files:** Modify `tools/install_macos.py`、`.agents/skills/speechrail-zero-setup/scripts/zero_setup.py`；Test `tests/test_installer.py`、`tests/test_video_podcast_skill_install.py`

- [ ] **Step 1** `zero_setup`：`prepare_diarization_assets(resolved_app_home, preset_id=selected_preset, downloader=downloader)`；light 得 `None`。
- [ ] **Step 2** `_managed_config`：`diarization_assets` 为 `None` 时不写 CoreML/aligner 两键（保持既有 guard）。
- [ ] **Step 3** **分人 smoke 按档位门控**：`preset.diarization` 为 False 时跳过 `_run_diarization_smoke_test`。
- [ ] **Step 4** `install_macos.py:503` 的 `aligner_model_dir.is_dir()` 校验在 `diarization_assets is None` 时跳过。
- [ ] **Step 5** 更新 `test_video_podcast_skill_install.py` 的 `prepare_diarization_assets` monkeypatch 签名。

### Task C2: SKILL 文档契约

**Files:** Modify `.agents/skills/speechrail-zero-setup/SKILL.md`

- [ ] 更新供给说明（按档位；light 无分人/aligner）；**保留** `operator-contract.md` 链接、不含 `run_all_benchmarks.py`、不含 `export SPEECHRAIL_API_KEY=`。
- [ ] `uv run python scripts/check_operator_docs.py`（现已通过，改动后须仍通过）。

---

## Workstream D — 文档更新计划（完整清单）

> `docs/archive/**` 不改。`test_operator_docs` 须保持绿。

| # | 文件 | 变更 |
|---|---|---|
| D1 | `README.md` L41 / L264 / **L274** / L270-272 / L275-294 / L330-343 | 特性条；删"All tiers strictly 8-bit"（L264、L274 两处）；三档表；共享关系；基准加注 |
| D2 | **`README.zh-CN.md`** 同上锚点 | 中文版同步（rev.1 遗漏） |
| D3 | `AGENTS.md` **L41 与 L42** | 档位规则 + 精度策略 + 分人门控（L41"档位对调用方透明"须显式修正） |
| D4 | `docs/decisions/0015-tier-user-positioning-and-precision-policy.md`（新建） | 记录决策；supersede ADR-0011 §2/§8 |
| D5 | `docs/decisions/README.md`、`docs/decisions/0011-*.md` | 增 0015 行；0011 标注 supersede 范围 |
| D6 | `docs/product/overview.md` | 三档用户画像 + 能力矩阵 |
| D7 | `docs/architecture/architecture.md`、`current-boundaries.md`、**`voice-cloning-design-and-handoff.md`** | 档位/精度/分人边界 |
| D8 | `docs/operations/runtime-deployment.md`、`migration-runbook.md`、`capability-quality-acceptance.md`、**`runtime-evaluation.md`** | preset/体积/迁移/验收/评估 |
| D9 | `docs/developers/testing-acceptance.md` | 测试清单 |
| D10 | `docs/users/api-contract.md`、`docs/users/integrations.md` | 能力矩阵（分人门控；word timestamps 由 ASR 提供） |
| D11 | `configs/speechrail.example.env`、`configs/speechrail.example.yaml` | aligner/CoreML 键按档位可选 |
| D12 | `.agents/skills/speechrail-zero-setup/SKILL.md` | 见 C2 |
| D13 | `docs/superpowers/README.md` | 索引已存在（rev.2 同路径，无需改） |

- [ ] 逐项更新；每项后跑关联校验；最后 `uv run --extra dev pytest --no-cov tests/test_operator_docs.py -q`。

---

## Workstream E — 验收门（可证伪）

> 每档必须全过；未过则该档回退上一精度。**若某门缺乏工具，必须先补齐工具或显式标注 `UNVERIFIED-BLOCKING`，不得留空阈值。**

- [ ] **E1 ASR 精度**：对固定 fixture 集，light `0.6B q4` vs `0.6B q8` 的 **CER/WER 绝对增幅 ≤ 0.5pp**；命令与报告路径写入验收记录。
- [ ] **E2 TTS 质量**：用既有 `voice_quality_v1` 客观指标（`tests/test_voice_quality_metrics.py` 同源工具）比较 `tts-0.6b-custom-q4` vs `q8`，指标不劣化超过既定阈值（**不使用** README 从未测过的 MOS/ABX）。
- [ ] **E3 分人/对齐**：`tools/evaluate_diarization_e2e.py` 上 `aligner-q8` vs `aligner-bf16` 的 **DER/SACER 不劣化**（阈值写入记录）；无需词级边界工具（词级时间戳不依赖 aligner）。
- [ ] **E4 资源包络**：三档实测 `phys_footprint` 分别 ≤ light 8GB / balanced 16GB / quality 32GB 目标包络。
- [ ] **E5 切换闭环**：`quality → balanced → light → quality` 热切换，每步 `/health` 正确、分人状态正确。
- [ ] **E6 能力诚实**：light 的 `/v1/models` **不含** `gpt-4o-transcribe-diarize`；balanced/quality 含且可用。
- [ ] **E7 记录**：`docs/operations/<日期>-tier-repositioning-acceptance.md`，仅存聚合证据，不落原始媒体/文本。

---

## Migration（简化：无 prepared_id 迁移）

1. 既有安装升级后，`profile apply <tier>` 会按档位供给 aligner（light 关闭分人）。
2. 既有 `diarization/Qwen3-ForcedAligner-0.6B`（旧 BF16）在新设计下不再被引用；`migration-runbook` 指引其在 `profile apply` 后清理。
3. **顺序**：先部署新 release 并执行一次 `profile apply`（供给新 aligner），再重启服务；`resolve_selection` 的 `is_dir()` 守卫会在 aligner 缺失时报清晰错误而非半启动。
4. 无 selection schema 变更（aligner 由 preset 派生）；无 `_prepared_id` 变更。

## Rollback

- 归档/单档回退：改 `precision_policy` 指向更高精度并重跑 A3 + `profile apply`（q8/bf16 制品保留）。
- 全量回退：按 ADR-0014 回退到上一 managed release（含 `diarization/Qwen3-ForcedAligner-0.6B`）；因无 prepared_id 迁移，回退可直接生效。

## Commit 计划（原子）

1. `feat(catalog): add aligner artifacts, precision policy, and tier presets`
2. `feat(profile): overlay aligner/diarization by tier with existence guard`
3. `feat(diarization): provision aligner per tier from catalog`
4. `feat(installer): tier-scoped diarization provisioning and gated smoke`
5. `test: update catalog/selection/installer contract suites`
6. `docs(tier): reposition tiers by user persona and per-tier precision`
7. `docs(adr): add ADR-0015 superseding ADR-0011 tier composition`

每提交后跑 focused tests；最后跑全量门：

```bash
uv run --extra dev pytest --no-cov -q
uv run ruff check
uv run mypy src
uv run python scripts/check_operator_docs.py
```

## Risks

- **R1 4-bit 质量**：light ASR/TTS 4-bit 未实测 → E1/E2 收口，未过即回退 q8。
- **R2 量化 aligner 可加载性**：`ForcedAligner` 能否加载 `aligner-q8`（mlx 量化快照）未验证 → 列为 E3 前置；失败则 balanced 用 `aligner-bf16`。
- **R3 备选方案**：若采用 §2.5（light 含分人），需额外验证 `aligner-q4`。
- **R4 schema v2 破坏面**：所有构造 preset/`ModelPreset` 的测试须同步（B/A4 已列；另 `test_cli.py`、`test_app_contract.py`、`test_model_store.py`、`test_profile_switch.py`、`test_profile_smoke.py` 的 fixture 需补 aligner/diarization）。
- **R5 文档行号漂移**：D 表锚点以实施时文件为准再审。
