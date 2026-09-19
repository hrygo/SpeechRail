---
title: "Issue #66 — Qwen3-TTS prepared reference condition vendor audit"
status: active
date: 2026-09-19
---

# Decision

SpeechRail MUST NOT expose a prepared-reference-condition cache for the currently
pinned Qwen3-TTS runtime.

This is an explicit unsupported result, not an inference from missing documentation.

## Pinned runtime

SpeechRail's managed TTS runtime pins:

- `mlx-audio==0.4.8`
- `mlx==0.32.2`
- `mlx-lm==0.31.3`

Sources in this repository:

- `src/speechrail/assets/runtime/tts.in`
- `src/speechrail/assets/runtime/tts.constraints`
- `src/speechrail/assets/runtime/tts.txt`
- `src/speechrail/assets/runtime-lock.json`

## Vendor source audit

Audited upstream tag/release: `Blaizzy/mlx-audio v0.4.8`.

Public Qwen3-TTS clone generation still accepts the raw reference pair
`ref_audio + ref_text`. The reusable ICL preparation is private:
`Model._prepare_icl_generation_inputs(...)`.

The model also owns a private `self._icl_cache`. In v0.4.8 its key is built from:

```text
(ref_text, (ref_audio.size, float(ref_audio.sum())))
```

and its value contains private prepared tensors such as reference codec tokens and
reference text tokens.

Relevant upstream evidence:

- release: https://github.com/Blaizzy/mlx-audio/releases/tag/v0.4.8
- pinned source:
  https://github.com/Blaizzy/mlx-audio/blob/v0.4.8/mlx_audio/tts/models/qwen3_tts/qwen3_tts.py
- v0.4.4 release history records introduction of the Qwen3-TTS ICL cache:
  https://github.com/Blaizzy/mlx-audio/releases/tag/v0.4.4

## Why SpeechRail does not adapt the private cache

The private vendor cache does not satisfy SpeechRail's public correctness boundary:

1. there is no public prepared-condition object/API to create, retain, validate, or
   pass back into generation;
2. the cache is an implementation detail and may change between vendor releases;
3. its observed key is not a cryptographic content identity;
4. the model-owned dictionary does not expose the explicit byte/entry budget,
   eviction, identity binding, or invalidation semantics required by Issue #66;
5. binding SpeechRail to private tensor shapes/helpers would turn a vendor upgrade
   into an implicit protocol change.

Therefore the existing waveform/reference file reuse MUST NOT be relabeled as a
prepared-condition cache, and the private vendor `_icl_cache` MUST NOT be treated as
SpeechRail's cache.

## Implemented boundary

`speechrail.domain.tts_reference_condition` defines:

- immutable `PreparedReferenceCondition`;
- `PreparedReferenceProvider` protocol;
- pinned `PreparedReferenceSupport` descriptor;
- `UnsupportedPreparedReferenceProvider` which fails closed.

Safe capability discovery publishes the pinned `mlx-audio==0.4.8` audit result and
continues to report the capability as unsupported.

## Future enablement gate

A later vendor/runtime upgrade may switch this capability to supported only after a
new audit proves a stable public reusable-condition API. That future implementation
must independently provide bounded entries/bytes, single-flight construction,
content/voice/model identity binding, invalidation, cancellation isolation, and real
latency/memory/quality measurements.

No performance percentage or cache-hit improvement is claimed by this checkpoint.
