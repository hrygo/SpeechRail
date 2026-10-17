# Meeting Diarization Cluster Calibration Design

## Intent

Issue #370 still has no development candidate that meets speaker attribution and coverage gates. The existing 24-policy sweep varies only SpeechRail's cross-window `SessionSpeakerMatcher`; FluidAudio's within-window clustering and VBx settings remain at their default values. This calibration adds a bounded, reproducible check of those local acoustic clustering settings before concluding that the fixed SDK path has no feasible candidate.

## Goals

- Compare a small, predeclared set of `clustering.threshold`, `warmStartFa`, and `warmStartFb` values against the same locked AISHELL-4 development sessions, audio, references, SDK revision, and model revision.
- Reuse one segmentation/embedding `prepare` result per PCM window and evaluate candidate clustering configurations serially in the same worker process.
- Screen the seven acoustic configurations with the previously best-observed matcher policy, then evaluate the full 24-policy matching grid for the top two acoustic configurations.
- Keep the existing per-meeting quality gates unchanged. The final candidate is eligible only when every development meeting passes; otherwise write no selected candidate and retain no-go.
- Keep R004 holdout sessions locked until the development candidate is frozen.

## Non-goals

- Do not modify the generated FluidAudio checkout, download or change model weights, add a model process, or alter normal production defaults during calibration.
- Do not use the holdout split for screening, selection, debugging, or parameter changes.
- Do not treat native development calibration as installed public-API acceptance, meeting ASR quality acceptance, or production certification.

## Calibration design

The acoustic screen contains seven configurations, changing one value at a time from the current community defaults: baseline `(threshold=0.60, Fa=0.07, Fb=0.8)`, threshold `0.45` and `0.75`, `Fa=0.05` and `0.09`, and `Fb=0.5` and `1.1`. All configurations keep segmentation, embedding extraction, post-processing, speaker-count behavior, model files, and SDK revision fixed.

The screen pairs each acoustic configuration with matcher grid index 11, the previously best-observed default-clustering policy. This stage is only a diagnostic ranking, not a candidate-selection gate. Rank by minimum per-meeting known accuracy, then mean known coverage, then minimum other-speaker coverage; break exact ties by the predeclared configuration order. Evaluate the top two configurations against all 24 existing matching policies in separate refinement runs, keeping `zero_vote_reembed` disabled to avoid changing a second variable.

The worker receives bounded calibration candidate JSON. For each input window it prepares the existing acoustic representation once, then invokes `OfflineDiarizerManager.cluster(_:)` with each candidate's clustering-only configuration. Managers share the already loaded CoreML model objects and are processed serially. Production inference continues using the current default configuration unless a later candidate passes the complete development gate and is explicitly carried into a frozen acceptance candidate.

## Acceptance and evidence

The existing gates remain unchanged: per meeting, known coverage at least 90%, known accuracy at least 95%, top-four minimum coverage at least 95%, and other-speaker minimum coverage at least 80% for participants with at least two seconds of reference speech. Development-only candidates that fail any session remain diagnostic. A passing development candidate must be frozen before any holdout access; final issue closure still requires the issue's independent holdout, meeting-ASR, installed API, and capability-consistency evidence.

Raw audio, references, embeddings, full candidate traces, and logs remain outside the repository. The repository stores only validated code, tests, and sanitized aggregates.
