# TTS audio consumption window Implementation Plan

> **For agentic workers:** Execute in the current session with `executing-plans`. Preserve the preceding request-binding fix and all unrelated local changes.

**Goal:** Normal TTS output faster than playback must pause at a bounded consumption window instead of failing on the thirteenth 3,840-byte PCM chunk.

**Architecture:** The caller declares `audio_window_bytes` per `speechrail.tts.start` and returns cumulative PCM consumption through `speechrail.tts.audio_ack`. An application-layer window owns transport credits only; the caller owns playback and reports consumption from its current playback epoch. The receiver never waits for playback. Cancellation closes the window before joining the controller, and stale credits cannot affect a later request.

**Tech Stack:** Python 3.14 / asyncio, Swift 6 / MainActor, fake incremental backend and fake playback.

**Spec:** The contract below, synchronized into `contracts/realtime-openai.md` and the strict shared wire schema.

## Contract and constraints

- `audio_window_bytes` is required, even, and within `2...48_000`; it bounds sent but unconsumed PCM across the client event stream, FIFO, enqueue and playback.
- `started.audio_window_bytes` echoes the admitted window. `limits.max_pending_audio_bytes` remains a worker/transport budget; its effective chunk bound cannot exceed the consumption window.
- `speechrail.tts.audio_ack` contains `request_id` and exclusive cumulative `sample_offset`. Duplicate watermarks are idempotent; backward or future watermarks fail with `tts_audio_ack_invalid`.
- Credits are processed on the control lane. A known retired request's late credits are ignored; unknown identities are rejected.
- Window waits use the existing slow-consumer deadline. Cancel/disconnect unblock the wait, drop unsent PCM, and preserve the existing terminal/resource-reclamation barrier.
- Text ACK delivery must not wait behind the output window. Healthy playback progress may renew the text ACK inactivity deadline without acknowledging text.
- A render receipt's `delivered` boundary remains transport delivery; consumption credits do not become evidence that a user heard audio.
- Preserve all data, model selections, revisions and prior uncommitted fixes. No models, real audio, UI automation, commits or remote operations.

## Review focus

- The exact 13 × 3,840-byte burst: the producer pauses at 12 and resumes on genuine consumption.
- Cancellation and disconnect while the window is exhausted: no deadlock, no old audio or ownership leak.
- Late, duplicate, negative, Boolean and future credits: no new-request budget corruption.
- Enqueue and acknowledgement sends suspended across cancellation: all tasks remain owned; epoch checks suppress stale callbacks.
- A long response and queued text ACK: no premature finish, no text retry, bounded failure when progress stops.

## Tasks

- [x] Add public-wire burst, exhausted-window cancellation and credit-validation regression tests; run `uv run --extra dev pytest tests/test_realtime_tts_incremental.py -q --no-cov` and record RED.
- [x] Add the isolated consumption-window component, strict wire parsing, independent control routing and request-scoped lifecycle integration.
- [x] Add Swift consumption-credit tests, wire types and request wiring. Keep byte accounting across FIFO and playback, coalesce credit sends in an owned task, and preserve terminal/drain separation.
- [x] Synchronize schema, shared fixtures, field matrix and active user/developer/packaged skill documentation.
- [x] Run focused Python and Swift suites, static/contract checks, and the synthetic burst reproduction. Record actual counts and remaining verification limits.
- [x] Review the complete diff independently and resolve required findings.
- [x] Prepare wheel/App candidates through the repository release wrappers and retain source/artifact identity.
- [x] Install the combined candidates after explicit authorization, retain rollback artifacts and avoid UI automation.

## Evidence

Before the fix, the standalone reproducer using production Swift accepted 12 chunks, scheduled zero before admission ended, and failed with `46080 + 3840 > 48000 bytes`. The paced scenario accepted and consumed all 13. This is deterministic scheduling evidence, not a hardware, model-quality or long-term stability measurement.

Verification on 2026-10-05:

- RED: the new public-wire tests rejected the previously unsupported window field; the Swift consumption tests did not compile before the API existed. The healthy-playback deadline regression timed out under the old absolute deadline.
- GREEN: 198 focused Python tests and 158 focused Swift tests passed. Shared contract validation passed with 47 fixtures and 38 tracked fields; targeted Ruff, mypy, version consistency and diff checks passed.
- Independent review found a runtime/schema mismatch: audio ACKs without the required event ID were accepted. Six new invalid-ID cases failed before the fix; the parser now validates the ID and the reviewed suite passes. An additional exhausted-window disconnect test confirms bounded close, backend cleanup, resource reuse and no later old audio. The reviewer rechecked both changes and reported no remaining blockers.
- The synthetic cross-language bridge used production Python session/service and Swift coordinator/DTO/ledger code with a fake backend and fake playback. All 1,000 chunks of 3,840 bytes were sent and consumed; both maximum unconsumed counters were 46,080 bytes, final pending bytes were zero, and the outcome was completed.
- Local candidates: service wheel 3.7.1 and ad hoc Debug App 3.7.1/build 46, arm64/macOS 26.0. Wheel contents match the changed service sources and include the native worker; the standalone installer help works outside the repository. The App build and local XPC packaging gate passed, and source hashes stayed unchanged during the build.
- Realtime contract 6.0.0 requires the consumption window; the service and App must be updated together. Missing-window clients are intentionally rejected. REST/MCP one-shot synthesis is unaffected.
- Combined replacement was authorized and completed on 2026-10-05 at 10:04 +08:00. The current managed runtime contains the reviewed wheel sources; controller start, preflight, health/ready and single-listener identity checks passed. The App is installed at the standard user Applications path as 3.7.1/build 46, with matching candidate hashes, valid local XPC/signature packaging and one LaunchServices registration.
- Profile, generation, model/voice identities, private configuration, selection and model bindings are unchanged. No models were downloaded; the previous service release/wheel and build 45 App ZIP remain available for independent rollback.
- The new App was not launched. Real conversation playback, UI automation, quality/performance benchmarks, commits and remote publication were not performed; installation success does not establish real conversation or long-term stability acceptance.
