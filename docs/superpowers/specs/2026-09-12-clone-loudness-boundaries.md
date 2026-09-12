---
title: "Clone frozen-gain boundary repair candidate"
status: draft
date: 2026-09-12
---

# Clone frozen-gain boundary repair candidate

Related: [SpeechRail #34](https://github.com/hrygo/SpeechRail/issues/34).
Base: `9dec75bed02bddecd4be56d0b5491c4b772f0a32`.
This is a code-review candidate, not a release or a completed audio-quality gate.

## Evidence and scope

The original controller blob is `5b4efa934b32c0cf2b5d5802229d45b53e708193`.
Its original 13 controller tests pass in isolation, but frozen-mode synthetic
inputs reproduce four boundaries: silence consumes calibration, one impulse
can establish calibration, one peak scales a whole block, and one above-gate
sample can switch an entire near-silent block from unity to the full gain.
The initial 22 new regression cases produce 10 failures and 12 passes on that
unmodified controller. These are deterministic synthetic cases, not estimates
of the incidence in model output or proof of the user's listening experience.

The worker already selects `freeze_gain_after_calibration=True`. This change
keeps that constructor, `process(bytes) -> bytes`, `reset()`, stats keys, PCM16
sample rate/order/count, clone-only routing, and the private 200 ms worker
framing unchanged. It does not alter model weights, sampling, reference audio,
reference cache, the public capability name, or the managed runtime. The legacy
dynamic branch remains available; its existing tests remain, apart from updating
the frozen-mode test to compare settled levels after causal calibration.

## Candidate algorithm

Calibration uses complete 10 ms media-time frames, independently of process
calls. A frame needs RMS above `silence_rms` and at least 20% above-gate samples
(at least two samples); this rejects isolated spikes but is not a speech VAD.
Accumulate `calibration_ms` of eligible frames (default 200 ms), then use the
median frame power to select the bounded request gain; calibration additionally
requires at least three eligible frames, so a `calibration_ms` below one 10 ms
analysis frame cannot lock a gain from a single frame. A signal whose frames
never reach 20% occupancy (for example a low-duty high-energy pulse train) never
becomes eligible: collection never starts, the deadline never arms, and the
request stays at unity in the `waiting` state. Until calibrated, emit unity
gain, still subject to sample-peak protection. Leading silence does not start
the collection deadline. Once collection begins, insufficient evidence after
`max(1 second, 5 * calibration_ms)` falls back to unity for the request. This
bounds the statistics without storing or buffering audio. Short inputs also
remain at unity rather than receiving an untrustworthy boost.

A 20 ms exponential time constant moves the applied base gain toward its
locked target. Once locked, no amplitude gate bypasses that gain: zeros stay
zero, and near-silent samples receive the same base gain as the rest of the
request. This prevents transport-block noise-gate toggling; it is not noise
suppression and can amplify an existing low-level background along with speech.

A separate sample-peak attenuation state uses immediate attack and exponential
release (new internal config `limiter_release_ms=100`). A peak does not modify
samples already output. Release continues across calls instead of returning to
unity at a 200 ms boundary. Encoding uses the floor of the configured ceiling in
PCM16 units, so integer rounding cannot exceed that sample-peak ceiling. Peak
stats count process calls containing an above-ceiling pre-limiter sample; they
are not a transport-independent measure of acoustic quality.

The causal policy adds no lookahead delay or buffered tail and preserves byte
count on every call. It is intentionally NOT advertised as a smooth-attack or
true-peak limiter. Immediate attack may distort transients. If listening or
fixed-window measurements reject that trade-off, a bounded lookahead design
with explicit flush/cancel semantics is required before this issue can close.

## Trade-offs that block production acceptance

- The first roughly 200 ms of eligible speech remains at unity, then the base
  gain ramps. Quiet onsets and short acknowledgments need explicit listening
  and first-audible-audio acceptance. Do not describe this as zero perceptual
  latency or assume the original RMS target is met on every short request.
- A sparse onset can select unity fallback; median frame power and the 20%
  eligibility threshold are candidate heuristics, not validated speech labels.
- Immediate limiter attack is peak-safe but may introduce transient distortion;
  cross-call release is not a proof of artifact-free audio.
- `_to_pcm()` still precedes this controller. Possible float clipping before
  PCM16 conversion is not repaired or claimed absent by this patch. Add a
  dedicated float-boundary diagnostic/test before closing the broader issue.
- Per-sample Python work needs a target-machine latency/CPU comparison.

## Validation

Local evidence: Linux x86_64, Python 3.13.5, isolated source/test slice, no model
or project startup imported. After this candidate: 50 controller tests pass.
Python 3.12 syntax parsing and `git diff --check` pass. The selected deterministic
legacy dynamic fixture produces byte-identical output before and after the
change. None of this replaces execution on the repository-required Python 3.12.

The sandbox has no Python 3.12, Ruff or mypy installed; direct GitHub DNS lookup
fails. Therefore the complete repository suite, Ruff, mypy, OpenAPI lint,
Ubuntu/macOS CI, managed wheel, actual MLX inference and speaker playback are
not claimed as passed here. PR/CI results must be recorded separately.

Run the focused tests in the supported environment:

```bash
uv run --extra dev pytest --no-cov tests/test_tts_loudness.py tests/test_tts_loudness_frozen.py tests/test_tts_voice_clone.py
```

Then run all gates from `docs/developers/testing-acceptance.md`. Validate current
managed quality runtime against multiple clones/texts, pauses, soft and strong
onsets, short/long utterances, cancellation and reference-cache behavior.
Compare raw and controlled copies of the SAME generated signal with fixed
media-time windows, not network delta lengths. RMS dBFS, perceptual loudness,
sample peak, and true peak remain separate metrics. Old builtin jump baselines
of about 10 dB and 34.6 dB are not interchangeable without matching windows,
speech eligibility, content and aggregation.

History remains in `docs/archive/performance/2026-09-08-clone-tts-loudness-acceptance.md`
and the issue discussion. Do not change historical measurements to imply that
this candidate has passed a real-model matrix. Sona#10 owns physical playback;
SpeechRail#34 owns server PCM and need not wait for all #44 architecture work.

## References and rollback

- [FFmpeg alimiter](https://ffmpeg.org/ffmpeg-filters.html#alimiter): bounded
  lookahead, attack/release, delay and EOF flush are explicit design choices.
- [W3C dynamics processing](https://www.w3.org/TR/webaudio-1.0/#dynamicscompressornode-processing):
  lookahead introduces latency. These references do not validate this candidate.

Rollback is a revert of this focused commit followed by the normal managed
release process, when deployment is separately authorized. This PR does not
change `main`, deploy, or automatically close #34.
