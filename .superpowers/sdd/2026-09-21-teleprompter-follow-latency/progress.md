# SDD ledger — plan: docs/superpowers/plans/2026-09-21-teleprompter-follow-latency.md

Pre-flight: current worktree is `feat/teleprompter-core-preparation`, not `main`/`master`; existing unrelated dirty files are preserved.

Pre-flight shared interfaces:

- Task 1 → Task 2: Task 1 adds diagnostics around the realtime event path; Task 2 adds snapshot events. Diagnostics must remain additive and must not make snapshot delivery depend on metrics.
- Task 2 → Task 3: Task 2 adds session transcription options to the public realtime configuration; Task 3 carries the resolved chunk duration through the ASR factory and worker. The option must be validated at the session boundary before worker dispatch.
- Task 2 → Task 4: Task 2 adds snapshot events and client decoding; Task 4 consumes replacement-text semantics and revision high-water marks. Final events remain terminal and authoritative.
- Task 3 → Task 5: Task 3 exposes effective chunk duration for real acceptance evidence; Task 5 reports it beside model/vendor/runtime identity.

Ruling: the referenced `subagent-driven-development` scripts are absent from the available skill filesystem, while the current branch and worktree were explicitly selected for implementation earlier in this task. Execute inline in this worktree and retain this ledger as the progress record; cost if wrong: the plan's optional fresh-brief/reviewer automation cannot run, so final review will be a self-review.

Task 1 — partial complete: added low-cardinality realtime partial outcome metrics plus local monotonic capture→send, event queue-age, and alignment measurements. A real local Realtime protocol probe now runs against the installed service with a 1-second silent PCM fixture; it verifies negotiation, snapshot delivery, completion, and revision invariants only. Cross-process calibration, human speech quality, and p95 claims remain unverified.

Task 2 — complete: added snapshot serializer, session negotiation/echo, per-item revisions, App decoding, replacement semantics, and focused service/client tests.

Task 3 — complete: added `RealtimeTranscriptionOptions`; carried the resolved session chunk through the ASR factory and Qwen3 worker; used the same value for server flush thresholds; covered ordinary/manual paths and post-audio mutation rejection.

Task 4 — deterministic implementation complete: added revision high-water, event-ID dedupe, replacement handling, final barrier, strict monotonic movement, and a narrowly gated unique near-anchor exact snapshot fast path. The existing two-evidence gate remains the default; only the deterministic eight-token/unique/near-anchor case bypasses it. Long-turn rolling alignment regression coverage remains green.

Task 5 — deterministic and installed-state verification complete: `uv run pytest --no-cov -q` passed; `swift test --package-path macos/SpeechRailApp` passed with 138 XCTest cases plus 71 Swift Testing cases in 10 suites; the Xcode App Debug build, Xcode `SpeechRailAppTests` unit-test target, `ruff`, both `mypy` targets, and `git diff --check` passed. The test target was corrected to stop compiling App-only SwiftUI sheets as test sources. The managed runtime was replaced from the current source wheel, the service was restarted and verified healthy, and the signed App bundle was installed and verified. Human speech/live UI quality and UI automation remain unverified.

Additional lifecycle hardening: `RealtimeASRClient.connect()` now waits for `transcription_session.updated` (or fails closed on server error/timeout), and TeleprompterSession negotiates this before starting the audio source.

Final review ruling: self-review performed against protocol, lifecycle, concurrency, privacy, and test coverage dimensions. No subagent reviewer was available because the referenced helper scripts are absent. Existing dirty worktree changes were preserved; no commit, push, deployment, or migration was performed.

Installation-state evidence (2026-09-21, pre-replacement): managed preflight and health were healthy, but a real local Realtime smoke using `snapshot + 500ms` returned `invalid_speechrail_extension` before audio processing. The installed managed runtime therefore predated this protocol extension.

Post-install evidence (2026-09-21): the current source wheel was installed as the managed runtime while retaining the previous release. The service restarted as a single `com.speechrail` LaunchAgent, reported `health=ok` and `ready=true`, and continued serving port 8201 with the quality profile. The real local probe using `snapshot + 500ms` completed successfully with `transcription_session.updated`, one `speechrail.transcription.snapshot`, and one completed event; `revision_regressions=0`, `snapshot_gap.count=0`, and the probe used only a 1-second silent PCM fixture. Afterward, `speechrail_realtime_active_sessions=0` and both governor request classes were zero.

The App was built with signing enabled, passed `scripts/macos_app_verify_local_xpc.sh` and strict code-sign verification, and was installed at the managed user App path with the previous bundle retained in the temporary rollback directory. No foreground launch or UI automation was performed.

Final verification follow-up (2026-09-21): a clean SwiftPM rebuild fixed and verified the Swift string-interpolation, duplicate local binding, and optional observation-context issues exposed by the fresh compiler; the App target also required the `timeout`/`observationContext` argument order to be corrected. After those fixes, SwiftPM passed 138 XCTest cases plus 71 Swift Testing cases in 10 suites, Xcode `SpeechRailAppTests` passed with exit 0, and a clean signed App build was reinstalled and re-verified. The generated `-Xcc` compiler cache was moved out of the repository; no source-generated cache remains in the worktree.
