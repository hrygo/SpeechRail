# Meeting Diarization Model Family Experiment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evaluate the official Mandarin-focused 3D-Speaker CAM++ diarization pipeline on the locked AISHELL-4 R003 development split with SpeechRail's existing scorer and gates.

**Architecture:** Add a deterministic Python 3.14 wrapper that validates the external R003 manifest, prepares an external audio-list, and scores anonymous RTTM output through the existing `score_diarization` function. A separate Python 3.11 runner imports the pinned external 3D-Speaker checkout, loads its models once, and processes the eight sessions serially. Keep model weights, runtime environment, source checkout, audio, references, predictions, and detailed results outside the repository; publish only a sanitized aggregate report.

**Tech Stack:** Python 3.14 for the repository-side wrapper and scorer; isolated Python 3.11 environment for upstream PyTorch/3D-Speaker inference; ModelScope model snapshots; pytest with fake runner outputs.

**Spec:** `docs/superpowers/specs/2026-10-17-meeting-diarization-model-family-experiment.md`

## Global Constraints

- Process only the locked eight-session R003 AISHELL-4 development manifest; keep R004 unscored.
- Do not pass oracle speaker counts or reference-derived values to the candidate.
- Keep the scorer at `pyannote.metrics==4.1`, collar `0`, overlap included, and existing per-meeting gates unchanged.
- Keep model assets, third-party source, environments, audio, references, detailed outputs, and logs outside the repository.
- Do not change production CoreML behavior, service state, public API, or generated FluidAudio files.

## Review Focus

1. A manifest whose bytes, split lock, or fixture hashes drift must fail before model launch.
2. Any R004 fixture or non-eight-session manifest must be rejected before audio access.
3. No oracle speaker count, Hugging Face token, or hidden reference data may reach the model process.
4. RTTM overlap, empty predictions, padded tail frames, and malformed intervals must be handled without changing the scoring denominator.
5. Tool output, errors, and repository reports must not expose audio text, speaker identities, or absolute model/audio paths.

---

### Task 1: Add a locked external-candidate scorer wrapper

**Files:**
- Create: `examples/perf/probe_meeting_diarization_3d_speaker.py`
- Create: `examples/perf/diarization_3d_speaker_runner.py`
- Create: `tests/test_probe_meeting_diarization_3d_speaker.py`
- Reuse: `examples/perf/calibrate_meeting_diarization.py::_validate_locked_development_manifest`
- Reuse: `examples/perf/diarization_quality.py::score_diarization`

**Interfaces:**
- Consumes: a locked external R003 manifest, immutable 3D-Speaker checkout path, external Python executable, and a new external output directory.
- Produces: validated anonymous RTTM intervals and an external detailed result file; prints only sanitized aggregate progress and summary.
- Parser: `_parse_rttm(path: Path, *, duration: float, expected_record_id: str, allow_noise_label: bool = False) -> tuple[list[JsonDict], int, int]` maps upstream numeric cluster IDs to deterministic anonymous labels, checks the generated record ID, clips only bounded tail padding, and counts candidate-specific HDBSCAN `-1` noise rows as unassigned intervals.
- Runner input: JSON rows containing only generated anonymous output IDs and the corresponding external WAV paths; no speaker counts or reference paths are passed to it.

- [x] Write failing tests for locked-manifest validation, R004 rejection, external-path enforcement, RTTM parsing, tail clipping, empty output scoring, and rejection of malformed or non-anonymous labels.
- [x] Run `SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD=1 uv run --no-sync pytest --no-cov tests/test_probe_meeting_diarization_3d_speaker.py`; the initial collection failed with `ModuleNotFoundError` for the absent module.
- [x] Implement the wrapper so it uses automatic speaker-count estimation, runs one session at a time, redirects upstream verbose output away from logs, and scores every session through the existing function.
- [x] Run the focused wrapper, scoring, and calibration tests; all deterministic tests pass with no scorer changes.

### Task 2: Stage and run the isolated official model pipeline

**Files:**
- External temporary environment and 3D-Speaker checkout only; no model/source assets under the repository.

**Interfaces:**
- Consumes: the Task 1 wrapper, pinned official Git commit, CAM++ `iic/speech_campplus_sv_zh_en_16k-common_advanced@v1.0.0`, and Chinese FSMN VAD `iic/speech_fsmn_vad_zh-cn-16k-common-pytorch@v2.0.4`.
- Produces: one anonymous RTTM prediction and sanitized timing/score record per locked R003 session, stored externally.

- [x] Record the official 3D-Speaker commit and verify the upstream license and the exact model IDs/revisions before staging.
- [x] Create an isolated Python 3.11 environment and download model snapshots through the official ModelScope tool; verify required weight/config files and hashes outside the repository.
- [x] Run the eight locked R003 sessions serially in one process with the official no-overlap pipeline, automatic speaker counts, and no access token; confirm the run emitted exactly eight predictions and no R004 audio/reference scoring.
- [x] Preserve model versions, source commit, environment lock, Python executable digest, and inference device in external result metadata.

### Task 3: Compare quality and document the model/code decision

**Files:**
- Modify: `docs/implementation/2026-10-17-meeting-diarization-global-context-report.md`
- Modify: `docs/superpowers/README.md`

**Interfaces:**
- Consumes: the sanitized external Task 2 scores and timings.
- Produces: aggregate comparison against the existing fixed-model baseline, a clear R003 pass/no-go, and next model/algorithm direction.

- [x] Verify all eight per-meeting gate rows, top-four and other-speaker minima, overlap/short-turn accounting, mean and worst-session DER/JER, and local inference runtime.
- [x] Update the dated report with only aggregate metrics, exact candidate/model revisions, limits, and whether every R003 gate passed; omit session IDs, raw audio, labels, logs, and absolute paths.
- [x] Keep no-go and R004 sealed because at least one R003 gate fails; do not claim production certification.
- [x] Run `git diff --check` and focused deterministic tests; inspect the report for paths, audio text, labels, and secrets.

### Task 4: Diagnose automatic speaker undercount after the official candidate

**Evidence and hypothesis:** The pinned official pipeline completed R003 with 0/8 complete quality-gate passes. Its anonymous RTTM predictions contained fewer speakers than the locked references in all eight sessions. The official source config applies post-clustering cosine merging at `mer_cos=0.8`; this is the first isolated algorithm variable to test.

**Files:**
- Modify: `examples/perf/diarization_3d_speaker_runner.py`
- Modify: `examples/perf/probe_meeting_diarization_3d_speaker.py`
- Modify: `tests/test_probe_meeting_diarization_3d_speaker.py`
- Modify: the dated implementation report after scoring

**Interfaces:**
- Inputs remain the same locked eight R003 WAVs and reference hashes.
- Candidate changes only `CommonClustering.mer_cos` from `0.8` to `None`; CAM++ and FSMN VAD revisions, automatic speaker count, spectral eigen-gap selection, minor-cluster size, scorer, and gates remain fixed.
- Output is a separate external execution lock, RTTM set, sanitized predicted-speaker counts, per-session metrics, and runtime.

- [x] Add a runner option for disabling the cosine merge and record the effective cluster policy in external metadata.
- [x] Add deterministic tests for default and disabled merge behavior; preserve the Python 3.11 virtualenv symlink when launching its interpreter so the isolated dependencies remain active.
- [x] Run the same eight R003 sessions and compare anonymous predicted-speaker counts and all existing per-session gates; all counts and per-session metrics were unchanged.
- [x] Keep R004 sealed and no-go because all eight sessions still fail complete gates.
- [x] Inspect the pinned `filter_minor_cluster` implementation; it reassigns all clusters with at most four embeddings to larger centers, so test this behavior next without changing scoring or speaker-count inputs.

### Task 5: Isolate minor-cluster reassignment

**Evidence and hypothesis:** The cosine-merge ablation had no effect. The pinned `CommonClustering.filter_minor_cluster` reassigns every cluster of four or fewer embeddings to a larger cluster center, which can erase short or infrequent speakers.

**Files:**
- Modify: `examples/perf/diarization_3d_speaker_runner.py`
- Modify: `examples/perf/probe_meeting_diarization_3d_speaker.py`
- Modify: `tests/test_probe_meeting_diarization_3d_speaker.py`
- Modify: the dated implementation report after scoring

**Interfaces:**
- Use the same locked eight R003 sessions, model cache, and inference device.
- Change only `CommonClustering.min_cluster_size` from `4` to `0`; restore `mer_cos=0.8`, retain automatic speaker counts, and keep all other model and spectral settings, scorer, and gates fixed.
- Produce a separate external execution lock, RTTM predictions, sanitized predicted-speaker counts, per-session metrics, and runtime.

- [x] Add the isolated option and validate/record the effective cluster policy.
- [x] Add deterministic tests for default and zero minor-cluster thresholds.
- [x] Run all eight R003 sessions; setting `min_cluster_size=0` changed no predicted counts or metric records.
- [x] Retain no-go and keep R004 sealed because all existing gates still fail.

### Task 6: Isolate spectral sparsification on R003

**Evidence and hypothesis:** Disabling cosine merge and minor-cluster reassignment individually had no effect. The CAM++ pipeline still underestimates speaker count, so test the spectral graph's `pval` sparsification while keeping its eigen-gap estimator and every other setting fixed.

**Files:**
- Modify: `examples/perf/diarization_3d_speaker_runner.py`
- Modify: `examples/perf/probe_meeting_diarization_3d_speaker.py`
- Modify: `tests/test_probe_meeting_diarization_3d_speaker.py`
- Modify: the dated implementation report after scoring

**Interfaces:**
- Use the same locked R003 audio and references, CAM++/VAD revisions, and inference devices.
- Change only spectral `pval` from `0.012` to `0.003`; keep automatic speaker count, `mer_cos=0.8`, `min_cluster_size=4`, scorer, and gates fixed.
- Record the exact spectral policy and write results to a separate external run directory.

- [x] Add and validate the bounded `pval` override in the isolated runner metadata.
- [x] Add deterministic tests for the default and candidate `pval` values.
- [x] Run all eight R003 sessions; `pval=0.003` changed no predicted speaker count and changed only one session's DER by 0.2 percentage points for the worse.
- [x] Keep R004 sealed because all complete quality gates still fail.

### Task 7: Isolate the spectral eigen-gap search floor

**Evidence and hypothesis:** Cosine-merge and minor-cluster ablations did not alter predictions. Lowering `pval` changed no speaker count, which suggests the eigen-gap search's lower bound may exclude the real speaker-count range.

**Files:**
- Modify: `examples/perf/diarization_3d_speaker_runner.py`
- Modify: `examples/perf/probe_meeting_diarization_3d_speaker.py`
- Modify: `tests/test_probe_meeting_diarization_3d_speaker.py`
- Modify: the dated implementation report after scoring

**Interfaces:**
- Use the same locked eight R003 sessions and fixed CAM++/VAD and scoring pipeline.
- Change only `SpectralCluster.min_num_spks` from 1 to 4 for every session; `oracle_num` remains `None`, so eigen-gap selection still chooses the per-session count.
- Keep `pval=0.012`, `mer_cos=0.8`, `min_cluster_size=4`, and all quality gates fixed.

- [x] Add and validate the bounded global lower-bound option in external execution metadata.
- [x] Add deterministic tests for `min_num_spks=1` and `4`, including that `oracle_num` remains unset.
- [x] Run all eight R003 sessions; one meeting changed from two to five speakers and DER worsened, while seven counts and all coverage values remained unchanged.
- [x] Keep R004 sealed because every complete gate still fails.

### Task 8: Compare the upstream AHC clusterer

**Evidence and hypothesis:** Independent spectral policy changes have not materially improved the undercount. The pinned 3D-Speaker source also provides `AHCluster`, an automatic threshold-based method using cosine distance and average linkage.

**Files:**
- Modify: `examples/perf/diarization_3d_speaker_runner.py`
- Modify: `examples/perf/probe_meeting_diarization_3d_speaker.py`
- Modify: `tests/test_probe_meeting_diarization_3d_speaker.py`
- Modify: the dated implementation report after scoring

**Interfaces:**
- Keep the same locked R003 inputs, CAM++ embeddings, FSMN VAD, `mer_cos=0.8`, `min_cluster_size=4`, scorer, and gates.
- Replace spectral clustering with `AHC` using the upstream class default `fix_cos_thr=0.4`; do not supply oracle speaker counts.
- Record the effective cluster type and threshold in a separate external execution lock.

- [x] Add the bounded cluster-type option and validate/record the AHC threshold.
- [x] Add deterministic tests for spectral default and AHC candidate construction.
- [x] Run all eight R003 sessions; AHC predicted 4–13 speakers against 5–6 references and lowered mean known accuracy to 84.41%.
- [x] Keep R004 sealed because no AHC session passed all gates.

### Task 9: Evaluate upstream UMAP-HDBSCAN clustering

**Evidence and hypothesis:** Spectral clustering undercounts speakers while AHC with a fixed cosine cutoff overclusters them. The pinned upstream source has a third automatic-count method, UMAP-HDBSCAN, which can test whether density-based grouping separates speaker manifolds more reliably.

**Files:**
- Modify: `examples/perf/diarization_3d_speaker_runner.py`
- Modify: `examples/perf/probe_meeting_diarization_3d_speaker.py`
- Modify: `tests/test_probe_meeting_diarization_3d_speaker.py`
- Modify: the dated implementation report after scoring

**Interfaces:**
- Keep R003 inputs, CAM++ embeddings, FSMN VAD, postprocessing, scorer, and quality gates fixed.
- Use upstream UMAP-HDBSCAN defaults `n_neighbors=20`, `n_components=60`, `min_samples=20`, `min_cluster_size=4`, and metric `euclidean`; set UMAP `random_state=0` for reproducibility and keep automatic speaker count.
- Treat upstream HDBSCAN noise label `-1` as unassigned speech in the evaluation adapter; leave `score_diarization` and all quality gates unchanged.
- Write a separate external execution lock and predictions.

- [x] Add and validate the bounded UMAP-HDBSCAN cluster type, effective parameters, and fixed seed in runner metadata.
- [x] Add deterministic tests for UMAP-HDBSCAN backend construction, random-state scoping, metadata validation, and HDBSCAN noise parsing.
- [x] Run all eight R003 sessions; UMAP-HDBSCAN predicted 2–4 speakers against 5–6 references, produced mean DER/JER 28.34%/58.44%, and passed 0/8 complete gates.
- [x] Treat the five `-1` rows as unassigned speech; keep the scorer and gates unchanged. UMAP-HDBSCAN lowered mean DER by 0.65 percentage points versus spectral but increased mean JER by 4.46 points and mean runtime by about 55%.
- [x] Record the model family as no-go; keep R004 sealed and leave production settings unchanged.

