# Meeting Diarization Model Family Experiment

## Purpose

Issue #370 remains no-go after fixed-model algorithm screens. Whole-meeting context, denser segmentation, and shorter embedding eligibility improved aggregate diarization, but the best locked R003 candidate passed only 2 of 8 per-meeting quality gates. This experiment compares a Mandarin-focused CAM++ model family and its official full-meeting VAD/clustering pipeline against those results before changing production code or questioning the scorer.

## Candidate and rationale

Use the official [ModelScope 3D-Speaker repository](https://github.com/modelscope/3D-Speaker) at a recorded immutable Git commit. Its diarization pipeline uses a 192-dimensional CAM++ embedding model, 16 kHz / 80-bin FBank features, Chinese FSMN VAD, and spectral clustering. The upstream repository reports 10.30% DER on AISHELL-4; that aggregate is a candidate signal only and does not establish SpeechRail's stricter per-meeting gates.

The official inference path can optionally add pyannote overlap segmentation, which requires a Hugging Face access token. This experiment does not read or use that token and runs the official no-overlap mode. Any missed overlap remains counted by the locked primary DER/JER scorer and is reported separately.

## Scope and controls

- Use only the eight sessions in the locked AISHELL-4 R003 development manifest. Validate its SHA-256 and split lock before processing; never enumerate, read, or score R004.
- Pin and record the 3D-Speaker Git commit, ModelScope model IDs and revisions, dependency lock, executable digest, and inference device.
- Use automatic speaker-count estimation. Do not pass `speaker_num` or any other reference-derived information to the candidate.
- Run one session at a time in one isolated process. Keep the source checkout, virtual environment, ModelScope cache, audio, references, RTTM predictions, and detailed per-session output outside the repository.
- Score with the existing `score_diarization` implementation and `pyannote.metrics==4.1`: one whole-session mapping, collar 0, overlap included in DER/JER. Keep custom gates unchanged: known coverage ≥90%, known accuracy ≥95%, top-four minimum known coverage ≥95%, and every other speaker with at least 2 seconds of reference speech ≥80% known coverage.
- Require all eight development sessions to pass every gate before freezing a candidate. Continue reporting short turns, overlap, and unknown attribution. If any meeting fails, retain no-go and do not open R004.
- Do not alter the production CoreML worker, service profile, model defaults, public API, scorer, or acceptance thresholds. Do not modify the generated FluidAudio checkout.

## Acceptance and limits

The comparison is useful if it establishes whether a different Mandarin speaker model plus whole-session clustering clears the unchanged R003 gates and gives measured local runtime evidence. A lower mean DER or a published upstream score is insufficient. The no-overlap path is expected to incur penalties on overlapped speech; those errors are part of the candidate's measured behavior, not grounds to remove overlap from scoring.

An R003 pass permits the existing locked workflow to prepare an R004 evaluation; it does not certify the production runtime. A model or environment that cannot be staged reproducibly is recorded as an engineering feasibility failure, not a reason to weaken the evaluation.

## Privacy and artifacts

Do not place audio, reference annotations, speaker labels, absolute model paths, full logs, or per-session predictions in the repository. The repository report may contain sanitized aggregate metrics, model/revision identifiers, timings, and gate counts only.

## R003 automatic-cluster-count follow-up

The official CAM++ candidate completed on 2026-10-17 but passed 0/8 complete per-meeting gates. Automatic clustering predicted fewer speakers than the locked references in all eight sessions (2–6 predictions for 5–6 reference speakers). The isolated `mer_cos=0.8` to `None` ablation changed neither predicted counts nor any per-session metric, so post-clustering cosine merge is not the cause of this undercount.

The pinned upstream `filter_minor_cluster` implementation reassigns every cluster with at most four embeddings to a larger cluster center. Setting `min_cluster_size=0` changed neither predicted speaker counts nor any per-session metric. Lowering spectral sparsification `pval` from `0.012` to `0.003` changed no predicted count and only one session's DER by 0.2 percentage points in the wrong direction. Raising the global eigengap search floor `min_num_spks` from 1 to 4 changed one session from two to five predicted speakers but worsened its DER and did not change coverage; `oracle_num` remained unset. Replacing spectral clustering with upstream AHC at `fix_cos_thr=0.4` overclustered the eight sessions to 4–13 speakers (references: 5–6), lowered mean known accuracy to 84.41%, and passed 0/8 complete gates. The final clustering family, upstream UMAP-HDBSCAN with `n_neighbors=20`, `n_components=60`, `min_samples=20`, `min_cluster_size=4`, Euclidean metric, automatic counts, and UMAP `random_state=0`, completed R003 with mean DER 28.34%, mean JER 58.44%, mean known coverage 77.05%, mean known accuracy 95.47%, and 0/8 complete gate passes. It predicted 2–4 speakers per session against 5–6 references; HDBSCAN noise label `-1` was treated as unassigned speech without changing the scorer. The result does not justify opening R004 or changing production settings.
