---
title: "ADR-0015：三档用户定位与按档位精度策略"
status: accepted
date: 2026-09-11
---

# ADR-0015：三档用户定位与按档位精度策略

## 修订（2026-09-11，E1 之后）

本 ADR 的 light 4-bit 决策在验收门 E1 未通过后回退。本节记录修订后的事实，**不重写原决策历史**；
下方「决策」保持原文，其被取代的条目已就近标注。

- **E1 结果**：在公开真人语料上，light 的 0.6B 4-bit ASR 相对其 8-bit 基线劣化 **1.38pp**
  （en WER +1.25pp、zh CER +1.46pp），超过 0.5pp 阈值，E1 **FAILED**。依据实施计划
  「每档必须全过；未过则该档回退上一精度」，light 回退至上一精度。
- **现行 light 组成**：ASR `asr-0.6b-q8`（8-bit）+ TTS `tts-0.6b-custom-q8`
  （8-bit CustomVoice），无 aligner、无分人，安装体积 **2986.6 MB ≈ 2.99 GB**
  （`asr-0.6b-q8` 1010.8 MB + `tts-0.6b-custom-q8` 1973.6 MB + VAD 2.3 MB）。
- **现行按档位精度策略**：三档均为 8-bit，仅 `quality` 的 aligner 为 `"bf16"`。
  `balanced` = `asr-1.7b-q8` + `tts-0.6b-custom-q8` + `aligner-q8`；
  `quality` = `asr-1.7b-q8` + `tts-1.7b-design-q8` + `tts-1.7b-base-q8` + `aligner-bf16`。
- **现行 Quality TTS 运行语义**：`tts-1.7b-design-q8` 是 `voice_design` lane，
  `tts-1.7b-base-q8` 是 `voice_clone` lane；两个独立 worker 可双常驻、跨 lane 并发，
  同一 lane 串行，空闲冷却后按 Quality capability group 回收并惰性恢复。
- **q4 制品保留但不再使用**：`asr-0.6b-q4` 与 `tts-0.6b-custom-q4` 仍在 catalog 中，
  可继续加载，但不被任何档位引用。
- **门控影响**：E2（TTS q4 vs q8）不再对 light 构成门控；light 已回到 8-bit 组合。

## 背景

ADR-0011 把三档设计成"同一能力按内存缩小/放大"：三档都取 `asr-0.6b`/`asr-1.7b` 的
8-bit 权重，并对 catalog preset 施加"必须 8-bit"与 `balanced.tts == light.tts`
的共享约束，把 4-bit 降级留作同一档位的候选（ADR-0011 §2、§8）。这种定位没有回答
不同用户要什么：8GB 基础机、会议/播客工作流与创作/R&D 需要的是不同能力组合，而不是
同一条能力曲线上的三个点。与此同时，forced aligner 只在分人路径被引用，词级时间戳
由 ASR 原生 `timestamp_granularities` 提供。因此 aligner 是分人专用制品，而不是 ASR
或词级时间戳的依赖。

## 决策

1. catalog `schema_version` 1→2；三档按用户定位重排，而非同一能力的缩放：
   - 🟢 `light` — Embedded（8GB 基础机）：ASR `asr-0.6b-q4`（4-bit）、TTS
     `tts-0.6b-custom-q4`（4-bit CustomVoice），**无 aligner、无分人**，安装体积 ≈2.41GB。
     **〔此项已被 2026-09-11 修订取代：E1 未通过，light 回退 `asr-0.6b-q8` +
     `tts-0.6b-custom-q8`（8-bit），安装体积 ≈2.99GB；见「修订」节。〕**
   - 🟡 `balanced` — Pro Workflow（16–24GB）：ASR `asr-1.7b-q8`、TTS
     `tts-0.6b-custom-q8`、aligner `aligner-q8`，分人开启，≈5.96GB。
   - 🟣 `quality` — Studio（32GB+）：ASR `asr-1.7b-q8`、TTS `tts-1.7b-design-q8`、
     aligner `aligner-bf16`，分人开启，≈7.63GB。
     **〔此处记录的是原始默认 VoiceDesign 路径；Quality 的独立 Base clone capability
     由 2026-09-12 后续 amendment 补充，现行组成见「修订」节。〕**
2. 解除"全档 8-bit"铁律，改由每档 `precision_policy` 声明精度
   （`model_catalog.ModelCatalog.precision_policy`，`TierPrecision`：light 为 4-bit，
   balanced/quality 为 8-bit，quality aligner 为 `"bf16"`）。4-bit 是显式档位决策，
   不是静默降级；质量门未通过则该档回退上一精度。
   **〔其中 light 4-bit 部分已被 2026-09-11 修订取代；现行精度策略为三档均 8-bit、仅
   `quality` aligner 为 `"bf16"`，见「修订」节。〕**
3. `ModelPreset` 增加 `aligner: str | None` 与 `diarization: bool`（`ModelPreset.aligner` /
   `ModelPreset.diarization`）。aligner 升为 catalog 一等制品
   （`family=qwen3_forced_aligner`、`variant=aligner`），但它是**分人专用资产**：由
   `diarization_assets.prepare_diarization_assets(app_home, *, preset_id, downloader)`
   按档位供给到 `app_home/diarization/<aligner-key>`，**不进入 `PreparedModelSet` /
   `prepare_models`**，因此没有 `prepared_id` 或 registry 迁移。
4. `config.selection.resolve_selection` 按档位覆盖 `qwen3_aligner_model_dir`：light 置
   `None` 并同时清空 `diarization_coreml_model_path`；balanced/quality 指向对应 aligner
   目录，若快照缺失则 fail closed（`SelectionError: aligner snapshot is missing`）。
5. 能力如实声明：`gpt-4o-transcribe-diarize` 仅在分人就绪（balanced/quality）时出现在
   `/v1/models`，light 不声明；词级时间戳由 ASR 原生提供，三档一致，不依赖 aligner。

**Supersedes:** ADR-0011 §2（三档组成）与 §8（4-bit 仅作同档候选）。ADR-0011 其余决策
（统一 runtime、仅权重分档、可恢复本地切换、资源保护）继续有效。
**修订说明（2026-09-11）：** light 的 4-bit 决策已在 E1 未通过后回退到 8-bit，因此 §8 的
4-bit 候选未被采纳；本 ADR 对三档用户定位、aligner 分人一等制品与按档位精度策略的取代仍然有效。

## 迁移

- 无 `prepared_id`/registry 迁移（aligner 不进入 prepared-set）。
- 部署新 release 后执行一次 `profile apply <tier>`，按档位供给该档 aligner（light 关闭分人）。
- 旧 `diarization/Qwen3-ForcedAligner-0.6B` 在新设计下不再被引用，可在 `profile apply`
  后按 runbook 清理。
- 顺序为"先供给、后重启"：`resolve_selection` 的目录守卫在 aligner 缺失时报清晰错误，
  而不是半启动。

## 回滚

- 归档/单档回退：把 `precision_policy` 指回更高精度，重跑 catalog 构建并执行
  `profile apply`（q8/bf16 制品保留）。
- 全量回退：按 ADR-0014 回退到上一 managed release，可直接生效。

## 后果

- 三档从"同能力大小档"变为按用户定位的差异化产品；light 安装体积较旧设计约减少
  2.65GB，balanced 约减少 0.56GB，quality 基本持平。
- 4-bit 的 light ASR/TTS 与量化 aligner 的可加载性/质量必须由独立质量门与真机验收决定，
  未通过即回退上一精度。**（2026-09-11 修订：E1 实测 light 0.6B 4-bit ASR 劣化 1.38pp >
  0.5pp 阈值，未通过，light 已回退 `asr-0.6b-q8` + `tts-0.6b-custom-q8`；现行三档均 8-bit，
  仅 `quality` aligner 为 bf16。）**
- `precision_policy` 与 `preset.aligner/diarization` 成为 catalog 契约的一部分，测试须按
  精度策略与分人门控校验。
- 公共 API 形状、worker IPC、调度与并发不变；分人供给仅在 install / `profile apply`
  触发，请求路径不下载模型。

## 参考

- [实施计划（rev.2）](../superpowers/plans/2026-09-11-tier-user-repositioning-and-precision-policy.md)
- [ADR-0011：统一语音运行时与仅权重分档](0011-unified-runtime-model-tiers.md)
- [ADR-0014：源码构建与 managed runtime 发布不变量](0014-source-built-managed-runtime.md)
- 代码：`src/speechrail/config/model_catalog.py`（`ModelCatalog.precision_policy`、
  `ModelPreset.aligner`/`ModelPreset.diarization`）、
  `src/speechrail/service/diarization_assets.py`（`prepare_diarization_assets`）、
  `src/speechrail/config/selection.py`（`resolve_selection`）
