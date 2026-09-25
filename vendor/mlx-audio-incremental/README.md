# mlx-audio incremental Qwen3-TTS overlay

This directory is the **source of truth** for the SpeechRail incremental
Qwen3-TTS extension. It is an additive overlay on the hash-pinned upstream
`mlx-audio` release, not a fork: upstream files are never edited.

## What it adds

| File | Responsibility |
|---|---|
| `incremental.py` | Vendor-neutral state machine: cumulative text buffer with a protected consumed prefix, per-frame text/EOS/pad decision, one append-only session driver. |
| `incremental_backend.py` | MLX integration for `Qwen3TTS`: one prefill, retained talker KV cache, code-predictor cache and vocoder streaming state. |
| `incremental_probe.py` | `open_probe_session(...)` entry point plus `__speechrail_vendor_commit__`. |

`__speechrail_vendor_commit__` is a SHA-256 over `incremental.py` and
`incremental_backend.py`, truncated to 40 hex characters. Any logic change
changes the identity, which is what the offline probe records as
`vendor_commit`.

## Deployment form

The overlay is deployed by copying the three modules next to the upstream
package inside the vendor runtime, i.e. into
`site-packages/mlx_audio/tts/models/qwen3_tts/`. The pinned SPI that must keep
working is declared on the SpeechRail side:

- `src/speechrail/backends/qwen3_tts_incremental.py` — constructs
  `Qwen3TtsIncrementalBackend(...)` and `IncrementalSessionDriver(...)` and
  wraps the driver as `IncrementalModelSession`.
- `tools/probe_tts_incremental.py` — drives `open_probe_session(...)` through
  the `ProbeSession` protocol.

## Two layout rules that are easy to get wrong

1. **The prefill forward pass is the first frame.** Upstream samples the first
   codec frame from the prefill itself and only starts reading the trailing
   text queue on the following frame. A driver that consumes one text token for
   the prefill frame drops that token and shifts the whole utterance by one
   frame.
2. **The Base ICL prefill is the official streaming layout**
   (`non_streaming_mode=False`): the text stream `[ref_text][target_text]` is
   *added* position by position to `[codec_bos][ref_codec]`. Upstream's
   `_prepare_icl_generation_inputs` only implements the non-streaming overlay
   (all text in the prefill, concatenated with the codec block), which cannot
   be continued and is not used here.

## Verification

Deterministic state-machine coverage lives in
`tests/test_tts_incremental_vendor_state.py` (no MLX import, no model load).

Real-model gates are run with `tools/probe_tts_incremental.py` against local
model snapshots and a local reference clip; reports and audio stay outside the
repository. The gate requires a single prefill, append after the first PCM, new
audio after the append, and a terminal event.
