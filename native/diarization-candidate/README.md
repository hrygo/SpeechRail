# Meeting diarization candidate

This isolated macOS 26 / Apple silicon CLI pins FluidAudio to revision
`503b4bd1bbf7220882de39fe8ae6716aae4132da`. It is an evaluation input, with no
production capability registration or certified speaker count. The production
native package and lock remain independent.

`swift test --package-path native/diarization-candidate` validates synthetic
probability frames without loading models.
`swift build --package-path native/diarization-candidate -c release` compiles the
CLI without running it. The SDK's optional text-normalization trait is disabled
because this executable only performs diarization. SwiftPM may still resolve
and verify the upstream binary artifact.

The CLI accepts exactly `--model <external-directory> --protocol-version 3
--preset <fast32|fast128> --compute-units <units>`. Starting it loads the model;
model execution requires an explicitly authorized evaluation window, verified
absence of another resident diarization worker, and matching artifact identity.
It never stops the service or downloads models. Only a local precompiled preset
bundle and finite 512-Float32 silence embedding are accepted. Static shapes and
FP16 I/O (Int32 lengths) are checked before inference. These runtime checks have
not been exercised against real models by the synthetic tests.

The private transport reuses the existing relative-linked packet codec. Headers
retain the 64 KiB limit; response frames use a JSON-array payload bounded to
512 KiB and 2,048 frames. Input PCM16 is mono 16 kHz, at most 16,000 samples per
append. A single sequential task owns the SDK and uses
`appendAudio/processBufferedAudio/finishStream`, with no whole-recording buffer
or SDK segment filtering. Output carries raw eight-slot probabilities at 10 ms;
Python applies strict `score > 0.5` and clips final padding to accepted samples.
The eight slots do not detect an unknown ninth person.

`examples/perf/meeting_candidate_session.py` reuses the service's session owner,
compute admission, bounded update queue, cancellation and exact-child cleanup.
Callers must supply the same governor as the ASR composition. This process-local
owner does not establish cross-process exclusion. Runtime preflight validates
SDK/preset/compute-unit identity; file-only `probe_meeting_candidate.py preflight`
still reports `not_evaluated`. Development/holdout evaluation commands remain
unavailable until source locks and evaluation gates are connected.
