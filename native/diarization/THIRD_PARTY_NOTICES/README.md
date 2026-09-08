# Third-party notices

`SpeechRailDiarizationWorker` links against FluidAudio at source commit
`5c19d5e12320e22bbfb7a1877b089d2665a69add` from
`https://github.com/FluidInference/FluidAudio`. FluidAudio is distributed under
Apache License 2.0; the complete license text is included in
`FluidAudio-LICENSE`.

The separately acquired CoreML model bundle is not copied into this repository.
Its source revision and required file hashes are pinned in
`src/speechrail/backends/diarization/coreml.py` and must be checked during
release preflight.
