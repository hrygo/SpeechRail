# Meeting Diarization Preprocessing Experiment Plan

> Execute inline. Keep the holdout split locked and production defaults unchanged.

**Goal:** Determine whether denser segmentation and shorter eligible speaker-embedding spans improve speaker attribution on the locked development meetings.

**Approach:** Extend the calibration-only candidate format to carry segmentation and embedding settings. Prepare one acoustic representation per distinct preprocessing profile and serially reuse it across candidates. Compare four declared profiles, then refine the two leading profiles with the existing matcher grid.

**Validation:** Existing scorer and per-meeting acceptance gates remain unchanged. Only sanitized aggregate metrics enter the repository.

## Tasks

1. Add protocol-level preprocessing policy values with finite, bounded validation and regression coverage.
2. Configure calibration-only FluidAudio managers with the declared `segmentation.stepRatio` and `embedding.minSegmentDurationSeconds`; cache prepared evidence by preprocessing policy and clustering result by full acoustic policy.
3. Update the Python calibration screen/refinement to use the four fixed profiles, preserve manifest/model/SDK/executable locking, and prove profile identity/digests cannot be silently changed.
4. Run protocol self-test, worker build, focused Python tests, and the four-profile screen on the eight-session development split. Keep holdout unread.
5. Refine the top two profiles with the 24 matching policies only if the screen shows a measurable improvement.
6. If no profile passes, run a full-meeting offline VBx diagnostic with the same model and locked development references. Compare it with rolling output to separate local clustering/matcher losses from acoustic-model limitations.
7. When full-meeting context improves the locked metrics, screen the four declared segmentation/embedding profiles against the existing seven clustering/VBx policies. Prepare once per full-meeting preprocessing profile, then reuse that `PreparedDiarization` across the seven clustering candidates.
8. If the global factorial still fails the complete gates, compare cross-window matcher centroids from raw 256-d embeddings with centroids from the SDK's PLDA `rho128` chunk outputs. First use the locked best-observed matcher policy and global preprocessing/clustering settings; keep vectors in memory.
9. If `rho128` loses that screen, run the existing 24 matcher distance/margin/update policies on `rho128` before rejecting the representation, since those thresholds were previously selected in raw-embedding space.
10. Record sanitized aggregate results, inference cost, and no-go/pass status in the dated implementation report.

## 2026-10-17 status and next direction

- The global 4 × 7 preprocessing/clustering screen completed on all eight R003 meetings; its best observed candidate passed 2/8 meeting gates.
- The raw-vs-PLDA feature screen and 24-policy PLDA refinement completed on the same locked development manifest; PLDA refinement passed 0/8 and is not frozen.
- A pre-existing paired zero-vote on/off artifact has identical manifest, model/SDK revision, executable digest, and matcher-policy digest on both sides. Its small average gains did not increase the 0/8 gate count; its executable digest differs from the current PLDA diagnostic build, so it is directional evidence only.
- The embedding-space refinement validator had a profile-type mismatch. A regression test reproduced it before the fix; field normalization now allows the valid locked refinement summary through without changing the manifest, candidate, or scoring locks.
- Issue #370 remains no-go. Read-only research identified 3D-Speaker's Chinese/English CAM++ diarization path as a possible model-family comparison, but it is a separate PyTorch/192-D/VAD/spectral-clustering stack. The exact weight was not found in standard ModelScope cache paths or the SpeechRail diarization asset directory. Do not graft it in as fallback or treat its published aggregate AISHELL-4 DER as this project's per-meeting acceptance evidence. Any model asset staging/conversion and R003 evaluation must remain separate from this fixed-model experiment and preserve the R004 lock.

## Guardrails

- No model download, production model-loading/default change, generated checkout modification, service operation, UI automation, or holdout access.
- Diagnostic executables load the exact local model files directly; they must not call a downloader or compiler. They do not change service behavior or produce a production candidate.
- The global factorial screen reuses one prepared full-meeting acoustic representation per preprocessing profile; scorer and acceptance thresholds remain fixed.
- The matcher feature-space comparison is calibration-only, emits no embeddings over IPC or to disk, and cannot change production defaults unless the complete development gates pass.
- Do not alter the scorer or acceptance thresholds to create a pass.
- Preserve all existing worktree changes and keep calibration outputs outside the repository.
