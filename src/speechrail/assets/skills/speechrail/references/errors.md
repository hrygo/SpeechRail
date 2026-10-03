# Errors and recovery

Every tool error has a stable code, retryability, and an action hint. Apply
the category before retrying:

- parameter/voice/revision errors: fix the request or refresh discovery;
- `voice_not_production_ready`: validate the current clone; do not render;
- `backend_busy`/`queue_full`: bounded backoff, no tight loop;
- `backend_timeout`: inspect the request/job state before retrying;
- worker initialization or deterministic clone-parameter errors: do not retry
  blindly; report the code and inspect readiness/parameters;
- `job_not_ready`/`idempotency_pending`: retain the handle and poll later;
- `voice_store_unavailable`/`connection_error`: retry only under the caller's
  deadline and with a key for create operations.
- `tts_initialization_failed`, `tts_inference_failed`, and `output_invalid` are
  stable backend/output classes; they are not automatic retry signals unless
  the error explicitly says `retryable=true`.

- `clone_speed_unsupported`: Base clone is fixed at `speed=1.0`. This is a
  capability mismatch, not a transient error — never retry it by sending a
  different speed, and never read it as "the voice is broken".

## Understood but unsupported (400)

These four codes mean the server parsed the request and refuses it *by
design*. They are not transient and not a client bug to retry around:

- `stream_unsupported`: `stream=true` was passed to a plain transcription.
  Streaming is only available on anonymous-diarization requests. Rewrite the
  request (drop `stream`, or use `response_format=diarized_json`).
- `chunking_strategy_unsupported`: `chunking_strategy` was passed to a plain
  transcription. It is only accepted on diarization requests, with values
  `auto` / `server_vad` (or the OpenAI `chunking_strategy[type]` form).
- `unsupported_parameter`: a known-speaker parameter
  (`known_speaker_names` / `known_speaker_references`) reached a diarization
  request. SpeechRail never maps anonymous labels to real identities or
  cross-session voiceprints, so remove the field rather than renaming it.
- `stream_format_unsupported`: `stream_format=sse` was passed to
  `/v1/audio/speech`. The endpoint returns a complete audio body and never
  degrades into SSE chunks — retrying with the same field cannot succeed.

A 422-oriented "retry with fewer parameters" heuristic misroutes all four.
The correct response is to rewrite the request once, from the documented
OpenAI-compatible subset, not to loop.

## Voice design lane

- `transcript_mismatch`: the re-transcribed reference disagrees with the
  (possibly edited) `reference_text` on the *numbers*. High character
  similarity is not enough — reading `500` as `900` is one substitution and
  still passes similarity, so numbers are compared value-by-value. Fix the
  reference text, then re-confirm; the candidate and its audio are left
  unchanged by the rejection.
- `voice_design_machine_validation_required`: the candidate has no complete
  machine pass on the current revision (or only v1 similarity evidence, which
  is no longer a publish basis). Run `validate_voice_design` with a Base test
  text different from the reference.
- `voice_design_validation_limit_reached`: the candidate already keeps 32
  validations, the retention cap. Nothing is silently evicted and previously
  returned validation IDs stay valid. Re-submitting the *same* ID with the
  same machine facts is idempotent and still succeeds; do not delete or
  renumber validations to make room.
- `validation_audio_unavailable`: the saved audition WAV for a validation is
  missing or its identity/hash does not match the record. The stored asset and
  record are preserved. Do not regenerate audio and pass it off as the old
  validation's output — ask for a fresh `validate_voice_design` run instead.
- `voice_design_revision_conflict`: the candidate was published, cancelled,
  failed, or its revision changed while the request was in flight (or a
  same-ID machine-fact conflict). The service does not restore the old state
  and does not write new audition assets. Re-read the candidate and decide
  from its current revision rather than forcing the old one through.

Never parse traceback or stderr text to decide whether clone speed is
unsupported. Never turn a failed registration or validation into a successful
voice record. Do not hide a conflict by changing the voice ID automatically.
