# Meeting Diarization Preprocessing Experiment

## Purpose

Issue #370 remains no-go after the current 8-session development evaluation. Cross-window matcher and clustering sweeps did not satisfy the existing per-meeting gates. This experiment tests the earlier pipeline stages that can suppress or blur short turns before matching: segmentation-window density and the minimum speech duration eligible for speaker embeddings.

## Scope and controls

- Use only the locked eight-session AISHELL-4 development split and its existing reference hashes. Keep the R004 holdout inaccessible until a development candidate is frozen.
- Keep the model files and revisions, SDK revision, 30-second audio window, 10-second hop, matching policy, clustering policy, post-processing, scorer, and all quality gates fixed during the screen.
- Compare four preprocessing profiles: current baseline (`stepRatio=0.2`, `minSegmentDurationSeconds=1.0`), dense segmentation only (`0.1`, `1.0`), short embeddings only (`0.2`, `0.0`), and both changes (`0.1`, `0.0`).
- Use the previously best-observed matcher policy for screening and the unchanged default VBx/AHC configuration (`threshold=0.6`, `Fa=0.07`, `Fb=0.8`). Refine the two ranked preprocessing profiles with the existing 24-policy matcher grid.
- Keep `zeroVoteReembed` disabled so it does not confound this ablation. Do not change production configuration, model assets, or the generated FluidAudio checkout.

## Rationale

The current offline pipeline uses `stepRatio=0.2` and omits segments shorter than one second from embedding extraction. The upstream FluidAudio benchmark documents a quality-oriented setting of `stepRatio=0.1` and `minSegmentDurationSeconds=0.0`, with improved VoxConverse DER and roughly half the throughput. SpeechRail's meeting path prioritizes attribution quality, and its locked evaluation contains short-speaker coverage failures. The local experiment determines whether this upstream quality tradeoff transfers to SpeechRail's Chinese meeting data and its session matcher.

## Acceptance

Keep the established gates unchanged and require every development meeting to pass before freezing a candidate: known coverage ≥90%, known accuracy ≥95%, top-four minimum known coverage ≥95%, and other-speaker minimum known coverage ≥80% for speakers with at least two seconds of reference speech. A profile that improves aggregate averages but fails any meeting remains diagnostic. A development pass still does not certify the holdout, public API, meeting ASR, or deployed runtime.

## Global-context diagnostic

If neither refined profile passes, run the same pinned offline model once per complete development meeting. This diagnostic bypasses rolling 30-second windows and `SessionSpeakerMatcher`; it estimates whether whole-meeting VBx clustering can improve the score with the same acoustic model. Model output is clipped to the source audio duration because the SDK reconstructs a padded final frame; overrun above one second is rejected. This mirrors the current worker's interval bounding and leaves the scorer unchanged.

If whole-meeting context materially improves results, evaluate the four declared segmentation/embedding profiles against the existing seven clustering/VBx policies. Prepare each profile once per complete meeting, then reuse its `PreparedDiarization` across the seven clustering candidates. Keep model files, scorer, and all quality gates fixed. Use the exact local compiled models and PLDA parameters; do not download or compile assets.

If the global factorial still fails the complete gates, compare rolling-window matching with `embedding256_cosine` and `plda_rho128_cosine` centroids. The second representation uses FluidAudio's existing per-chunk PLDA `rho128` outputs, averaged only within each local cluster, normalized by the existing session matcher, and kept in memory. First fix matcher policy index 11 and the best global preprocessing/clustering configuration so the screen changes only the representation. Candidate metadata may identify the representation; vectors must not cross IPC or be written to disk.

If that fixed-policy screen rejects `rho128`, run the existing 24 matcher distance/margin/update settings in `rho128` space before concluding the feature is unsuitable. Those values were selected in raw embedding space, so an unmodified threshold may not transfer. This refinement remains diagnostic and cannot change production behavior.

## Results and follow-up diagnostics (2026-10-17)

- The full-meeting 4 × 7 screen completed on all eight R003 sessions; its best observed profile/VBx combination passed 2/8 complete per-meeting gates. R004 remains unscored.
- The fixed raw-vs-`rho128` comparison selected raw 256-D cosine. All 24 PLDA-space matcher refinements were then scored; the best observed candidate had higher mean attribution accuracy than the fixed raw matcher but lower coverage, worse mean DER, and only 0/8 meeting gates. Mean per-meeting minimum coverage and worst-meeting minimum coverage are reported separately; only the per-meeting quality gates decide acceptance.
- A pre-existing paired `zeroVoteReembed` on/off experiment used the same R003 manifest, model/SDK revisions, worker digest and 24 matcher policies on both sides. The enabled side had small mean improvements but remained 0/8. Its worker digest differs from the current PLDA diagnostic build, so treat it as directional evidence only.
- The refinement path exposed a code defect: the validator compared the embedding-space dictionary with the candidate's string value. A new regression test reproduced the failure before the fix; the comparison now uses the locked profile field. The screen manifest, candidate-set digest and quality gates remain unchanged.
- Read-only model research identified 3D-Speaker's Chinese/English CAM++ diarization pipeline as a possible separate model-family comparison. It uses a different PyTorch embedding, 192-D features, VAD and spectral-clustering path, so it is not a drop-in change for the pinned CoreML/PLDA bundle. Its published aggregate AISHELL-4 DER does not establish the per-meeting gate here. No model was downloaded, converted or loaded, and no production default changed.

Interpretation:

- A material gain over rolling inference points to window-local clustering or cross-window identity reconciliation as the higher-value engineering target.
- A global clustering-policy gain points toward window-local clustering settings as another engineering lever; it does not by itself justify replacing the online window/matcher architecture.
- A global preprocessing-policy gain points toward segmentation or short-turn embedding eligibility as another engineering lever.
- A PLDA-space gain points toward the cross-window similarity feature as an engineering target; it does not certify the full-session gates.
- Similar failures after the global factorial screen, PLDA refinement and zero-vote comparison point toward model-family or architecture limits on this corpus. Investigate scorer/reference details only when a concrete scorer or reference defect is demonstrated; do not relax gates to make the aggregate pass.

## Privacy and artifacts

Audio, references, candidate frame traces, embeddings, and logs remain outside the repository. Store only a sanitized aggregate with manifests, model/SDK revisions, executable digest, tested profile values, per-profile metrics, inference timing, and no speaker labels or absolute model paths.
