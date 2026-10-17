# Meeting Diarization Phase 1 (1–4 Speakers Sortformer & Joint SA-ASR) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify the Phase 1 (1–4 speakers) evaluation pipeline, corpus/split-lock guards, frozen candidate specification lock, and three-way decoupled/joint scoring (`CER`/`WER`, `DER`/`JER`, and speaker-attributed `cpCER`/`tcpCER`/`cpWER`/`tcpWER` + `DI-cpCER`/`DI-cpWER`) for Issue #370 without touching sealed `R004` holdout data or partitioning/using `AliMeeting Eval` as a `development` split.

**Architecture:** Keep the existing 5–6 speaker `AISHELL-4 R003` (`meeting_dynamic`) calibration and 3D-Speaker diagnostic scripts intact. Add a dedicated 1–4 speaker evaluation module (`examples/perf/probe_meeting_sortformer_1to4.py`) that validates external archive completeness (rejecting `.partial` files and unverified checksums), enforces strict split-role discipline (`development` vs `frozen_holdout` / `frozen_evaluation` so `AliMeeting Eval` can never be partitioned or used as `development`, and cannot be evaluated until a locked `development` certification receipt passes all `1, 2, 3, 4` speaker strata with the identical `candidate_spec_sha256`), bridges 16 kHz mono PCM16 audio through the protocol-v1 `CoreMLSortformerEngine` (`system_cap=4`), and reports per-session and per-speaker-count (`1, 2, 3, 4` speakers) ASR-only, diarization-only, and speaker-attributed metrics.

**Tech Stack:** Python 3.14, `pyannote.metrics==4.1`, `examples/perf/asr_quality.py`, `examples/perf/diarization_quality.py`, `src/speechrail/backends/diarization/coreml.py`, `pytest`, `ruff`, `mypy`.

---

## Context, Official Data Sources & Verified Boundaries (2026-10-17)

1. **Why AISHELL-4 `R003` Cannot Certify Phase 1 (1–4 Speakers):**
   - The reconstructed AISHELL-4 split (`manifest_sha256 = ff3df5d28862fb5c2c73f597a98d4e204248121fc39994b412cf0513968c01cd`) contains 8 `R003` development sessions, all with **5–6 session-local speaker IDs** (`0` sessions with `1–4` speakers).
   - `Sortformer` (`nvidia/diar_streaming_sortformer_4spk-v2`, `SortformerNvidiaLow_v2.1.mlmodelc`) has an architectural hard cap of 4 sigmoid outputs (`S = 4`, `system_cap = 4` in `src/speechrail/application/services.py:279`). Testing a 4-slot model on 5–6 speaker sessions conflates architectural capacity overflow with 1–4 speaker tracking accuracy.
2. **Official 1–4 Speaker Corpus Audit (Source, License, Checksum, Disk Requirements):**
   - **OpenSLR SLR119 — AliMeeting** (`https://www.openslr.org/119/`, paper `arXiv:2110.07393`):
     - **License:** `CC BY-SA 4.0` (commercial & academic use permitted with attribution and share-alike).
     - **Speaker Count Coverage:** `2–4` participants per session (`0` single-speaker `1_speaker` sessions).
     - **Official Splits & Direct URLs:**
       - `Train_Ali_near.tar.gz` (`22.85 GB`, 212 sessions, 104.75h, headset near-field): `https://speech-lab-share-data.oss-cn-shanghai.aliyuncs.com/AliMeeting/openlr/Train_Ali_near.tar.gz` — recommended `development` source for `2, 3, 4` speakers (~`48–50 GiB` peak disk to download + unpack).
       - `Train_Ali_far.tar.gz` (`73.24 GB`, 212 sessions, 104.75h, 8-ch far-field array): `https://speech-lab-share-data.oss-cn-shanghai.aliyuncs.com/AliMeeting/openlr/Train_Ali_far.tar.gz` (~`150–160 GiB` peak disk to download + unpack).
       - `Eval_Ali.tar.gz` (`3.42 GB`, 8 sessions, 4h, far + near): `https://speech-lab-share-data.oss-cn-shanghai.aliyuncs.com/AliMeeting/openlr/Eval_Ali.tar.gz` — **strictly reserved as unsplit, untuned single-shot `frozen_holdout`**.
       - `Test_Ali.tar.gz` (`8.90 GB`, 20 sessions, 10h): `https://speech-lab-share-data.oss-cn-shanghai.aliyuncs.com/AliMeeting/openlr/Test_Ali.tar.gz`.
     - **Official Checksum Availability:** OpenSLR SLR119 and Lhotse `ali_meeting.py` do **not** publish official SHA-256/MD5 strings on the SLR119 HTML page; verification requires checking OSS `Content-Length` + `Content-MD5` (`ETag`) headers, `gzip -t`, `tar -tzf`, and recording `publisher_checksum_verified: false` alongside the local SHA-256.
   - **OpenSLR SLR33 — AISHELL-1** (`https://www.openslr.org/33/`):
     - **License:** `Apache-2.0`.
     - **Role:** Single-speaker (`1_speaker` stratum) Mandarin speech control (`data_aishell.tgz`, `15 GB`) or non-overlapping single-speaker control windows derived from `AliMeeting Train` (`CC BY-SA 4.0`), because `AliMeeting` (`2–4` speakers) and `AISHELL-4` (`4–8` speakers) contain `0` single-speaker sessions.
   - **OpenSLR SLR123 — MagicData-RAMC** (`https://www.openslr.org/123/`):
     - **License:** `CC BY-NC-ND 4.0` (**NonCommercial-NoDerivatives** — excluded from commercial default certification due to NC-ND license restriction).
   - **Local Disk Space (`df -h` / `shutil.disk_usage` on `/System/Volumes/Data`):**
     - `1,858.14 GiB` total, `1,490.41 GiB` used, **`367.74 GiB` free** — sufficient for `Train_Ali_near.tar.gz` (`~50 GiB` peak) + `Eval_Ali.tar.gz` (`~8 GiB` peak).
3. **External Benchmark & Model Path Status on This Machine (Seatbelt & Connected Folders Audit):**
   - Connected Folders in this session: `[<worktree>]`.
   - Writable external directories inside the Seatbelt sandbox: `/private/tmp`, `/var/tmp`, `$HOME`（沙盒隔离目录）, and `$GEMINI_WORKSPACE_DIR`. None of these contain any `.mlmodelc` bundles, `Qwen3-ASR` weights, or meeting audio archives.
   - `$SPEECHRAIL_APP_HOME/benchmarks`: `PermissionError(errno=1): Operation not permitted` under the worktree-only Connected Folder sandbox.
   - `$SPEECHRAIL_APP_HOME/models`: `PermissionError(errno=1): Operation not permitted` under the worktree-only Connected Folder sandbox; `SortformerNvidiaLow_v2.1.mlmodelc` is inaccessible from inside the sandbox.
   - `$SPEECHRAIL_APP_HOME/benchmarks/issue370-aishell4-test-20261017/test.tar.gz`: `PermissionError(errno=1): Operation not permitted` (`R003` has 5–6 speakers; `R004` is sealed holdout).
   - `$SPEECHRAIL_APP_HOME/benchmarks/issue370-aishell4-test-20261017/reconstructed-split`: `FileNotFoundError(errno=2): No such file or directory`.
   - `$SPEECHRAIL_APP_HOME/benchmarks/issue370-alimeeting-eval-20261017/Eval_Ali.tar.gz.partial`: `PermissionError(errno=1): Operation not permitted` (incomplete `.partial` download; reserved for `frozen_holdout`).
4. **Frozen Phase 1 Candidate Specification (`candidate_spec_sha256 = 0320dcfc3a417575efe79310b326af396e06d45ca691e8ad4e5890de1653fe46`):**
   - Computed deterministically by `frozen_phase1_candidate_spec()` from `src/speechrail/assets/model-catalog.json`, `src/speechrail/assets/runtime-lock.json`, and `CoreMLSortformerEngine`:
     - `diarization`: `SortformerNvidiaLow_v2.1.mlmodelc` (`revision = ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`, `dtype = fp16`, `fluidaudio_sdk_commit = 5c19d5e12320e22bbfb7a1877b089d2665a69add`, `worker_executable_sha256 = 6db420e7b516841eae472ae67831e5ce6c2f537e68c46407db3db918c542bd06`, `sortformer_config = SortformerConfig.balancedV2_1`, `activity_threshold = 0.25`, `timeline_max_stored_seconds = 60.0`, `system_cap = 4`, `max_speakers = 4`).
     - `asr`: `mlx-community/Qwen3-ASR-1.7B-8bit` (`revision = 579e237ce6ec925252973afe835d2f98a138602f`) + `mlx-community/Qwen3-ForcedAligner-0.6B-bf16` (`revision = b8ac37cafb30fdf58d3b57910c292d3b4dee4a65`).
     - `scoring_and_quality_gates`: `der_collar_seconds = 0.0`, `comparable_der_collar_seconds = 0.25`, `tcp_collar_seconds = 5.0`, `known_coverage >= 0.90`, `known_accuracy >= 0.95`, `top_four_min_known_coverage >= 0.95`, `other_min_known_coverage = not_applicable`.
5. **Strict Holdout Protection for `AliMeeting Eval` (`Eval_Ali`):**
   - `AliMeeting Eval` (`Eval_Ali.tar.gz`) must **never** be split or used as `split_role="development"`. `validate_locked_1to4_manifest()` rejects any `development` manifest whose `dataset`, `source_split`, or fixture `id` references `Eval_Ali` / `AliMeeting_Eval` / `R004`.
   - `validate_frozen_holdout_unlock()` and `evaluate_locked_1to4_split()` block any `frozen_holdout` evaluation unless an external `development-certification.json` receipt exists with `split_role == "development"`, matching `candidate_spec_sha256`, `all_1to4_strata_observed == True`, `phase1_diarization_certified == True`, and `verdict == "go"`.

---

## Acceptance Criteria (AC)

- [x] **AC-PLAN**: Document the Phase 1 (1–4 speaker Sortformer) evaluation plan, archive/split-lock rules, three-way metric definitions (`CER`/`WER`, `DER`/`JER`, `cpCER`/`tcpCER`/`cpWER`/`tcpWER`, `DI-cpCER`/`DI-cpWER`), and `1, 2, 3, 4` speaker stratification in `docs/superpowers/plans/2026-10-17-meeting-diarization-sortformer-1to4-plan.md`, and index it in `docs/superpowers/README.md`.
- [x] **AC-CORPUS**: Implement deterministic archive, manifest, and holdout-unlock validation in `examples/perf/probe_meeting_sortformer_1to4.py` that:
  1. Rejects `.partial` archive filenames, missing files, corrupted gzip archives, or SHA-256 mismatches, and records whether `publisher_checksum_verified` is `True` or `False`;
  2. Rejects any `R004` holdout fixture, any `Eval_Ali` / `AliMeeting Eval` fixture in `split_role="development"`, any session outside `1 <= speakers_count <= 4`, duplicate fixture IDs, or repository-internal paths;
  3. Enforces `split_role` (`development` vs `frozen_holdout` / `frozen_evaluation`) so multi-candidate tuning sweeps are rejected on frozen holdout manifests and `frozen_holdout` cannot run without a passing `development` certification receipt (`validate_frozen_holdout_unlock`).
- [x] **AC-METRICS**: Implement decoupled and joint speaker-attributed evaluation in `examples/perf/probe_meeting_sortformer_1to4.py`:
  1. **ASR-only**: normalized `CER` and `WER`;
  2. **Diarization-only**: `DER`, `JER`, `comparable` (`collar=0.25, skip_overlap=True`), `known_coverage` (`>= 0.90`), `known_accuracy` (`>= 0.95`), `top_four_min_known_coverage` (`>= 0.95`), and `other_min_known_coverage_applicable = False` (`N/A` for `<= 4` speakers);
  3. **Speaker-attributed joint**: exact minimum-permutation `cpCER`, `cpWER`, time-constrained `tcpCER`, `tcpWER`, diarization-invariant `DI-cpCER`, `DI-cpWER`, and speaker-confusion deltas (`cpCER - di_cpCER`, `cpWER - di_cpWER`), keeping `"unknown"` unattributed speech in the error denominator;
  4. **Stratification**: per-speaker-count (`1, 2, 3, 4` speakers) aggregate breakdown that explicitly marks any missing speaker count as `unobserved_stratum` and `quality_gate: "no-go"`.
- [x] **AC-PROBE**: Implement the protocol-v1 `Sortformer` (`CoreMLSortformerEngine` / `ActivityFrame` 4-slot) evaluation runner (`evaluate_locked_1to4_split`), frozen candidate spec digest (`frozen_phase1_candidate_spec`), and CLI (`--mode preflight`, `--mode evaluate-development`, `--mode evaluate-frozen-holdout`), verified by deterministic unit tests in `tests/test_probe_meeting_sortformer_1to4.py` passing `pytest` (`99 passed`), `ruff check`, and `mypy`.
- [ ] **AC-REAL-EVAL** *(Unchecked / Blocked on Connected Folder Sandbox Access to `$SPEECHRAIL_APP_HOME` & Unstaged 1–4 Speaker Development Corpus)*: Unpack and verify the external 1–4 speaker `development` corpus (`AliMeeting Train` 2–4 speakers + 1-speaker control) under `$SPEECHRAIL_APP_HOME/benchmarks/`, certify `development-certification.json` across `1, 2, 3, 4` speakers, and only then run single-shot `frozen_holdout` on complete `Eval_Ali.tar.gz`.

---

### Task 1: Implement 1–4 speaker archive/manifest lock, frozen candidate spec, 3-way SA-ASR scorer, and Sortformer evaluation CLI

**Files:**
- Create/Modify: `examples/perf/probe_meeting_sortformer_1to4.py`
- Create/Modify: `tests/test_probe_meeting_sortformer_1to4.py`
- Modify: `docs/superpowers/README.md`

- [x] Write comprehensive unit tests in `tests/test_probe_meeting_sortformer_1to4.py` covering `.partial` archive rejection, checksum verification status, `R004` and `Eval_Ali`-as-development rejection, `1..4` speaker bounds, `frozen_holdout` sweep & unlock gates, `cpCER`/`tcpCER`/`cpWER`/`tcpWER`/`DI-cpCER` exact permutation & unknown-speaker penalty, `1..4` speaker stratification (`unobserved_stratum` -> `no-go`), Sortformer 4-slot frame-to-segment attribution, end-to-end `evaluate_locked_1to4_split` (`development` -> `development-certification.json` -> `frozen_holdout` -> `frozen-holdout-report.json`), and CLI `--mode preflight --require-pass` exit code `2`.
- [x] Implement `examples/perf/probe_meeting_sortformer_1to4.py` and run `pytest`, `ruff check`, `mypy`, and real CLI `--mode preflight` / `--mode evaluate-development` / `--mode evaluate-frozen-holdout` commands.
