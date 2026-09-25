# Controlled engine wheel

This directory owns the single reproducible `mlx-audio` engine wheel used by
SpeechRail.  The upstream checkout is local-only and must be exactly the commit
in `engine-build.json`; the reviewed incremental modules under
`vendor/mlx-audio-incremental/src` are injected into that checkout during the
tracked build.

Prepare the pinned source once:

```bash
git clone --depth 1 --branch v0.5.6 \
  https://github.com/Blaizzy/mlx-audio.git \
  vendor/engine-build/upstream
```

Build the wheel and provenance:

```bash
uv run --extra dev python tools/build_engine_wheel.py \
  --spec vendor/engine-build/engine-build.json
```

The build pins `SOURCE_DATE_EPOCH` to the upstream commit time, stages only
tracked upstream files plus tracked incremental modules, and rejects a dirty,
mismatched, or non-origin checkout.  After the wheel is reviewed, regenerate the
runtime lock:

```bash
uv run --extra dev python tools/update_runtime_lock.py \
  --python 3.14.7 --id mlx-qwen-20260924-py314
```

The resulting wheel and `provenance.json` are committed under `dist/` and
embedded into the SpeechRail release wheel by `hatch_build.py`.  Raw upstream
checkouts, build logs, and temporary outputs are not committed.
