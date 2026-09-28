# SDD ledger — plan: docs/superpowers/plans/2026-09-28-voice-creation-use-e2e-luna-guide.md

Baseline: `main@0f171401`, branch `codex/voice-creation-use-e2e`.

Pre-flight: the plan is a defect-repair plan rather than a task-brief plan, so execution is grouped by S0–S7. Every behavior change follows RED → GREEN with focused tests; commits are intentionally not created because repository instructions require explicit user authorization for commits.

Task S0: in progress — verify current interfaces, write the regression counterexamples, and record any plan/code conflicts before implementation.

Task S1: complete — RED tests covered design publication evidence, wrong capability scope, and quality-run scope; GREEN unified `validated_for=["output"]` plus exact `capability_key`, scoped discovery/rich lookups, and rejected mismatched VoiceDesign capability keys.

Task S2: complete — RED tests covered cold strict synthesis, missing evidence, runtime drift, and worker pinning; GREEN added internal `expected_runtime_revision`, target-lane `prepare_voice`, shared strict admission inside existing resource admission, HTTP/job error mapping, and receipt binding to the admitted runtime.

Task S1/S2 verification: `uv run --extra dev pytest tests/test_voice_design_workflow.py tests/test_voice_quality_routes.py tests/test_voice_validation.py tests/test_voice_safe_listing.py tests/test_capability_snapshot.py tests/test_tts_role_routing.py tests/test_speech_api.py tests/test_local_file_processor.py tests/test_qwen3_tts.py tests/test_qwen3_tts_capability_router.py tests/test_qwen3_tts_capability_router_lifecycle.py -q --no-cov` → 230 passed.

Ruling: the plan's shared helper is implemented in `voice_validation_gate.prepare_validated_speech` and receives the registry explicitly; this keeps monkeypatched/test registries and the production global registry on one code path. Cost if wrong: one extra parameter at two call sites.

Ruling: runtime drift is enforced inside the worker immediately before sending the synthesis frame, not only in HTTP; the HTTP layer maps the typed backend error. Cost if wrong: a non-SpeechRail caller could opt into the internal field, but it is not exposed publicly.

Task S4: complete — App lookup-pending now replays the frozen POST; a deterministic-reject code set (invalid_name, invalid_ref_text, invalid_audio, audio_too_short, audio_too_long, voice_quality_reject) releases only the registration context, keeps the recording, and re-keys the next logical operation. Service clone/clone-validate validates name/ref_text/voice-id before journal.begin; the constant-true publication_started abort is removed; a journal.complete failure after registry commit leaves pending that a same-key replay reconciles to completed with exactly one WAV. Swift AppModelTests and tests/test_voice_quality_routes.py + test_durable_idempotency.py pass.

Task S5: complete — new src/speechrail/application/ffmpeg.py owns the bounded concurrent stdin/stdout protocol (FFmpegOutputLimitError, cleanup_ffmpeg_process, run_ffmpeg_subprocess with timeout_seconds). audio.py delegates to it while retaining its own _FFMPEG_TIMEOUT_SECONDS for existing timeout tests. domain/tts.py gains pure validate_transcoded_clone_wav as the single WAV boundary source of truth; the sync transcode_and_validate_clone_audio remains for tests and reuses it. system._transcode_clone_audio is now async with a 10s bounded transcode (45s*24kHz*2 + 64KiB output cap, audio_too_long on overflow, ffmpeg_not_found preserved as 500). Fixed a latent S2 gap: CapturingSpeechSynthesizer in test_tts_voice_clone.py lacked prepare_voice. tests/test_ffmpeg_async.py added (9 tests). Python S1-S5 regression green.

Task S3: complete — C1 fixed with a new VoiceQualityRunResponse envelope DTO (legacy_report/evidence/validation_persisted) plus `isRecordedOutputPass`; runVoiceQuality protocol/client/fake all return it. SafeVoiceEntry and CreatorVoice now decode production_ready / production_ready_reason (missing = unknown, never true). New AppModel.checkVoiceOutput drives a generation-guarded VoiceOutputCheckState (idle/running/passed/passedNotPersisted/failed/error); a pass with validation_persisted=false reads "检查已完成，但结果未保存，请重试。" and is never promoted to accepted. createSpeechRender pins require_output_pass at the client boundary; createSpeech pins allow_unverified. Voice library inspector gained 检查配音效果; clone success banner now points at 前往音色库检查. Cold discovery never disables 生成语音.

Task S6: complete — added VoiceDesignPublicationRetryStep.regenerateCandidate. A machine-rejected candidate (service state `failed`) now offers 重新生成候选 instead of a dead 重试这一步; the retry ends the publication context (new candidate/voice/idempotency identity) and reuses the existing per-slot generation. Preconditions are checked before clearing state so the action can never become a silent no-op.

Task S7: complete — openapi.yaml: documented the `output` validation dimension vs capability_key, the cold strict-admission order and its 409/503 codes, clone pending-replay recovery, and split VoiceQualityRunEnvelope out of the oneOf so the namespaced route has an envelope schema with no top-level status. Docs updated: generated-voice-registration 1.4, voice-clone-quality-gates 1.1, users/api-contract 3.9.0, macos-app-design-system 0.11.0 (new §4.4 for the quality-check states/actions).

Final verification (2026-09-28):
- Python targeted suite (13 files incl. test_ffmpeg_async, test_openapi_contract, test_tts_voice_clone): 318 passed.
- S1/S2 regression files (capability_snapshot, tts_role_routing, qwen3_tts router x2): 53 passed.
- Ruff: clean across src/speechrail and the touched tests. Mypy: clean on the 5 changed core modules.
- swift test: 317 passed. scripts/macos_app_build.sh --configuration Debug: BUILD SUCCEEDED.
- git diff --check clean; no key/Authorization/absolute-path leakage in the diff.

Not done / out of scope: no UI click-through automation was run (the plan lists it as optional and it needs per-invocation UI authorization); no real-model E2E, quality or latency acceptance; no service start/stop, tier switch, install or release; no commit was created (repository rules require explicit authorization). The working tree sits on `codex/ci-overlap-wheel-build`, not the `codex/voice-creation-use-e2e` branch named in the plan header — the same uncommitted change set, on a different branch, because the session was on this branch when the work resumed.

## Review-fix round 1 (2026-09-28)

Reviewed the whole S0-S7 diff. Three real defects found and fixed, each locked with a
regression test verified RED before the fix and GREEN after.

R1 — cancellation was converted into a backend failure. `prepare_validated_speech` wrapped
`await prepare_voice(...)` in `except BaseException`, so `asyncio.CancelledError` became a
retryable 503 `voice_validation_runtime_unavailable`. The gate runs inside the caller's TTS
admission, so this broke the plan's S2 rule that cancellation must propagate so the slot and
lease are released. Narrowed to `except Exception` (CancelledError derives from BaseException).
Test: tests/test_voice_quality_routes.py::test_strict_gate_lets_prepare_cancellation_propagate.

R2 — the strict policy could be silently dropped for formal production.
`ServiceAPIClient.createSpeech` forced `allow_unverified` unconditionally, and the protocol's
default `createSpeechRender` routes through `createSpeech`, so any creator client relying on
that fallback produced unverified deliverables — exactly the F1 defect. `createSpeech` now
honours an explicit caller policy (`options.validationPolicy ?? "allow_unverified"`), and
`AppModel.synthesizeAndSave` states `require_output_pass` at the call site as well as at the
client boundary. Tests: AppModelTests::testFormalRenderAlwaysRequestsStrictOutputValidation
plus the existing ServiceContractTests render/audition header assertions.

R3 — the runtime identity was not shape-checked. `prepare_validated_speech` accepted any
non-empty string even though `SpeechRequest.expected_runtime_revision` declares
`^rt_[0-9a-f]{64}$` and the worker really produces `rt_` + sha256 hex. Now uses the existing
`is_observed_runtime_revision`, so a malformed identity fails closed as "identity unknown".
Test: tests/test_voice_quality_routes.py::test_strict_gate_rejects_non_canonical_runtime_identity.

Also audited the test diff for weakened assertions. The one 409 -> 200 change
(test_quality_run_persists_output_validation_and_promotes_capability_state) is the F3 fix
itself; its three cold-discovery honesty assertions (unevaluated /
model_runtime_identity_unknown / production_ready False) are preserved, and the strict
rejection path stays covered by test_strict_synthesis_rejects_missing_evidence_before_synthesis.
No pre-existing assertion was dropped to make a change pass. Removed one unused fake
(DefaultRenderFallbackClient) left over from an earlier draft of the R2 test.

## Review-fix round 2 (2026-09-28)

Re-read the parts round 1 had not audited line by line: the pure-function extraction in
domain/tts.py, the new application/ffmpeg.py module and its callers, the clone transcode
route, the Swift creator surface / AppModel S6 paths, the contract and the four documents.
Three more real defects, each locked with a regression test verified RED before the fix.

R4 — the clone dry run and the clone registration disagreed on the same input. S4 added
`invalid_voice_id` (malformed or reserved target id) to `POST /v1/voices/clone` only.
`POST /v1/voices/clone/validate` — documented as the same pipeline without persistence —
had no such check, so a reserved id such as `serena` returned 200 "参考音频合格" after paying
for the whole transcode + grading pipeline, and the registration then rejected it with 400.
Extracted `_normalized_clone_voice_id` and applied it to both routes, so a preflight pass can
never green-light an input registration would reject. Test:
tests/test_voice_quality_routes.py::test_clone_routes_reject_the_same_reserved_and_malformed_voice_ids
(parametrized over both routes and both id shapes; verified RED — the validate cases returned
200 — before the fix).

R5 — the contract carried a duplicate mapping key. The S7 edit left two `description:` keys on
`VoiceValidationState.validated_for`; PyYAML keeps the last one and every drift check still
passed, so the first text was simply dead. Removed the superseded key and added a fail-closed
parse guard so the spec cannot silently drop a value again. Test:
tests/test_openapi_contract.py::test_contract_has_no_duplicate_mapping_keys (verified RED by
re-injecting the duplicate, which reported `duplicate key 'description' at line 2315`).

R6 — `invalid_voice_id` was missing everywhere that enumerates the definitive pre-commit
rejections. It is exactly such a rejection (it returns before the upload is read and before
the idempotency record opens), but the App's `definitiveCloneRejectionCodes` and the
api-contract list both omitted it, so an API client following the documented recovery rules
would have treated a correctable input error as a conflict and reused the same key. Added it
to the App set, to `docs/users/api-contract.md`, and named it explicitly in the
`POST /v1/voices/clone` prose in openapi.yaml, including the guarantee that the validate route
accepts the same ids.

Round-2 audit of the rest of the diff found no further defects and weakened no assertion: the
three removed assertions in tests/test_voice_design_workflow.py are the F3 change itself
(a 409 strict render became a 200 plus a direct check that the published evidence exists under
the exact capability binding and carries `validated_for == ["output"]`, which is strictly
stronger), and the strict rejection path stays covered separately.

Round-2 verification (2026-09-28):
- Python targeted suite (15 files): 317 passed.
- ruff check src/speechrail tests/: clean. mypy on the 5 changed core modules: clean.
- swift test: 318 XCTest + 145 swift-testing, 0 failures.
- scripts/macos_app_build.sh --configuration Debug: BUILD SUCCEEDED.
- git diff --check: clean.

Not done / out of scope (unchanged from round 1): no UI click-through automation (needs
per-invocation authorization), no real-model E2E / quality / latency acceptance, no service
start-stop, tier switch, install or release, no commit (repository rules require explicit
authorization).

## Review-e2e round 3 (2026-09-28)

The first two rounds were static: every claim about the ffmpeg boundary rested on fake
process objects, and the clone route tests monkeypatched `_transcode_clone_audio` away
entirely. This round ran the new code against real ffmpeg 9.0.2 and a real ASGI stack.
No product defect surfaced; one real coverage gap did, plus one correction to my own
earlier reasoning.

E7 — the non-seekable-WAV recovery walk was untested for real ffmpeg headers. Verified
against ffmpeg 9.0.2 on pipe output: it writes `RIFF size = 0xFFFFFFFF` *and*
`data size = 0xFFFFFFFF`, and puts an ancillary `LIST` (INFO/encoder) chunk between `fmt `
and `data`. Python's `wave` module then reports a 20-second file as **89,478 s** (~24.8 h).
`validate_transcoded_clone_wav`'s chunk walk exists precisely for this and returns the
correct 20.00 s, so the shipped behaviour is right — but the committed test
`test_transcode_accepts_pipe_wav_with_unknown_riff_sizes` builds its header with the
`wave` module, which emits `RIFF + fmt + data` and therefore never traverses an
ancillary chunk. Added `test_transcode_accepts_real_ffmpeg_pipe_wav_with_list_chunk` using
the exact real layout. Verified load-bearing: mutating the walk advance by one byte turns
both the new and the pre-existing sentinel test red, and restoring turns both green.
Correcting myself: sentinel *sizes* were already covered — the earlier "zero coverage"
claim came from grepping a hex literal that the test spells as `b"\xff\xff\xff\xff"`. What
was genuinely missing was traversal past an ancillary chunk.

Real-subprocess verification of `application/ffmpeg.py` (evidence, not committed): 11/11.
3.5 MB stdin with ~960 KB stdout concurrently (no pipe deadlock), output cap kills a real
child, timeout reaps a real child with no orphan, cancellation propagates *and* reaps,
missing binary surfaces `FileNotFoundError` for the route's `ffmpeg_not_found` mapping,
non-zero exit maps to `failure_error`, and `pgrep` confirms no orphan after the run.

Real-transcode verification of the clone route (evidence, not committed): 6/6. wav, mp3,
flac and m4a all register end to end through real ffmpeg, persist a real 24 kHz mono
asset, and the preflight grades identically to registration. An oversized upload is
refused at the read boundary with `413 audio_too_large`. The formal-render deliverable is
built by `_wav_pcm16`, not ffmpeg, so it carries exact RIFF sizes and decodes cleanly —
the 0xFFFFFFFF hazard does not reach clients.

Neither E2E script was committed: project rules require deterministic tests with fake
backends and no real audio. Only the hermetic LIST-header regression test went in.

Two harness errors worth recording so they are not mistaken for findings: a pure sine is
correctly rejected by the quality gate (`high_noise_floor`, `low_snr` — a single tone
leaves its zero crossings as a -34 dBFS floor), and this ffmpeg build has no libopus
encoder, so ogg could not be produced.

Still unverified, and not reachable without model weights or a running service: the cold
worker strict render (F3), the real runtime-revision handshake, real quality-probe
synthesis, capability-key isolation across a live tier switch, and every App UI flow.
Round 3 verification: Python targeted suite (16 files) 356 passed; ruff clean.

R8 — found by E2E, not by reading: MCP could not do strict production at all.
`SpeechRailClient.synthesize` put `validation_policy` in the JSON body of
`POST /v1/audio/speech`. The TTS body is `extra="forbid"`, and the service rejects that
field by name: "validation_policy is not accepted in the OpenAI-compatible TTS body; send
it as the SpeechRail-Validation-Policy request header instead." Proved end to end by
driving the real MCP client over the real ASGI app with `httpx.ASGITransport`:

  allow_unverified     -> 200, 24044 bytes
  require_output_pass  -> 400 unsupported_parameter
  same request via the documented header -> 200, 24044 bytes of real WAV

So `synthesize(validation_policy="require_output_pass")` failed for every caller — the one
path F1 exists to make work. This also contradicted the api-contract text this change set
itself added ("speechrail-mcp ... synthesize 自动转发上述两个 Header"): only the revision
pins were forwarded; the policy was not. Fixed to send `SpeechRail-Validation-Policy` as a
header, matching the reasoning already documented in that method's own docstring. Tests:
tests/mcp/test_client.py::test_synthesis_sends_validation_policy_as_a_header_not_a_body_field
and ::test_synthesis_omits_the_policy_header_when_unverified. Verified RED by reverting the
client (KeyError on the absent header) before restoring.

The defect predates this change set — `src/speechrail/mcp/` was untouched by S0–S7 — but
it sits directly on the F1 path and contradicts the contract the change set amended, so it
is fixed here rather than deferred.

Round 3 final verification: Python targeted suite incl. tests/mcp 469 passed; ruff clean;
mypy clean on the changed modules; the two E2E probe scripts stay out of the repo.

R9 — a published voice entry could contradict itself. `_voice_entry` combined the
availability inputs, then ran `resolve_binding`, which can still flip `available` to False;
`availability_reason` was an inline chain that never re-read the final value and ended in an
unconditional `else "available"`. A clone voice whose binding does not resolve was published
as `available: false, availability_reason: "available"`. Spotted in a real E2E registration
response, not by reading. `availability_reason` is now derived from the settled `available`,
with distinct `binding_unavailable` and `voice_not_available` reasons. The invariant is now
locked for every published entry, not just the triggering one:
`availability_reason == "available"` if and only if `available` is true. Test:
tests/test_voice_quality_routes.py::test_published_voice_entries_never_claim_available_while_unavailable
(verified RED — the reverted chain reports `available` next to `available=false`).
Pre-existing, like R8: `_voice_entry` was touched by this change set only to add
`capability_key`, but the field is public and the App renders voice availability.

Also established this round, with evidence rather than assumption:
- F1 has no bypass. Every user-facing synthesis entry point was enumerated and checked:
  `/v1/audio/speech` (buffered, PCM and streamed) goes through `prepare_validated_speech`;
  durable speech jobs go through the same helper; MCP `synthesize` now sends the policy
  header and `tools._enforce_available_voice` checks `production_ready`; the voice-design and
  quality-probe paths are auditions and the gate's own implementation respectively. Realtime
  carries no TTS synthesis at all (ASR/diarization only), so it cannot render a clone voice.
- The clone voice is absent from the effective capability snapshot while unavailable, so the
  MCP pre-check fails closed on voice lookup before the `production_ready` key matters. The
  `entry.get("production_ready") is False` test in `_enforce_available_voice` would still
  fail open on a missing key; whether a snapshot can carry a clone entry without that key is
  unverified, and the service would reject the render anyway.

Round 4 verification: Python targeted suite incl. tests/mcp 470 passed; ruff clean; mypy clean.

Round 5 (2026-09-28) — concurrency, and a documentation divergence.

R10 — the contract sentence added in R6 was wrong. Concurrent registrations of one
target voice id, driven through the real ASGI app with genuinely overlapping requests:

  A. 8 concurrent POSTs, one shared Idempotency-Key
     -> 8x201, one profile, one revision, ONE wav asset. F4/F5's central guarantee
        ("at most one acoustic asset, never a second voice") holds under real overlap.
  B. 8 concurrent POSTs, distinct keys, IDENTICAL payload, one target id
     -> 8x201, converging on one profile / one revision / one asset. No overwrite.
  C. 8 concurrent POSTs, one target id, DIVERGENT payloads
     -> 1x201 and 7x409 voice_already_exists. The winner is never overwritten.

The route deliberately compares the stored clone against the submitted payload
(`_clone_result_matches`): an identical payload converges and returns the existing voice, a
different one is rejected. The OpenAPI prose written during R6 said a different key
targeting an existing id "is rejected rather than overwriting it", which is wrong for the
identical-payload case — a caller that retried with a fresh key and the same audio would
have been told it gets a 409 when it actually converges. Corrected in contracts/openapi.yaml.
Regression test (hermetic, redirects the journal):
tests/test_voice_quality_routes.py::test_second_key_on_the_same_clone_id_converges_but_never_overwrites

Incident, self-inflicted and cleaned up: `_clone_idempotency_journal` is a module-level
singleton bound to the real `~/.speechrail/voice_clone_idempotency.json`. The first version
of the concurrency probe did not redirect it and wrote 17 `race_*` records into that file.
Restored to the 5 pre-existing records (verified by result_id, which is `clone_idem_<hash>`
or `voice_clone_<uuid>` for real registrations); backup at
/tmp/voice_clone_idempotency.backup.json. The probe now redirects the journal and asserts it
stayed in the temp dir. The committed suite was checked for the same hazard and is clean:
record count and mtime of the real journal are unchanged after running every voice, clone,
idempotency, design and MCP test.

Round 5 verification: full `pytest tests/` 2622 passed, 0 failed / 0 errors / 0 skipped;
ruff clean across src/speechrail and tests; mypy clean on the changed modules.

Round 6 (2026-09-28) — the second F1 surface, and a coverage hole that mattered.

Round 5 claimed "durable speech jobs go through the same helper", but that was read, not
run. Checking it properly: `tests/test_local_file_processor.py` had exactly one strict job
test and it was positive (a ready voice renders). `tests/test_jobs_api.py` had no
`validation_policy` case at all. `voice_not_production_ready` was covered for
`/v1/audio/speech` and for MCP, and for neither on the durable job path.

The hole is not academic. Mutating `local_file_processor` to drop the
`prepare_validated_speech` call makes the strict job silently render unverified audio —
`DID NOT RAISE`. That gate is the only thing preventing an F1 bypass on this surface, and
nothing would have caught its removal.

Added `test_processor_speech_strict_rejects_evidence_without_the_output_dimension`,
parametrized over evidence that covers only `reference` and evidence with no dimension at
all. Both must be rejected with the specific `voice_not_production_ready` code — not a
generic `job_processor_failed`, which a client would retry forever against a voice that can
never become ready — and no result artifact may be written. Verified load-bearing by
removing the gate (both cases fail) and restoring (both pass). The implementation was
correct; only the proof was missing.

Round 6 verification: full `pytest tests/` 2644 passed, 0 failed / 0 errors / 0 skipped
(37 progress lines, no F/E/s); ruff clean.

Round 7 (2026-09-28) — §8.2 acceptance-checklist reconciliation; the loop has converged.

Walked the plan's §8.2 checklist line by line against the current tree. Every F1–F7/C1
item is now backed by a test that was actually executed, and each was mutation-checked
where it guards a silent-failure mode. Two items were open when this round started:

F1, negative half — "rejection leaves no pendingDubbing audio" had no test at all:
ScriptedRenderClient only ever returned success, so nothing proved that a service-side
strict rejection (409 / missing evidence) fails to deposit an unverified "待保存" audio.
Added `testRejectedStrictRenderLeavesNoPendingDubbingAudio` (asserts nil pending, zero
works in the library, and a visible creatorMessage) and gave ScriptedRenderClient an
optional `renderError`. Verified load-bearing: injecting a preview-fallback — on strict
rejection, quietly downgrade to `createSpeech` and set that as pending, the exact F1 bug
class — turns the test RED on the pendingDubbing assertion; restoring turns it GREEN.
Implementation was already correct; only the proof was missing.

F7, "old callback must not corrupt a new context" — COVERED by an existing, executable,
mutation-verified test after all: `testLatePublishedResultDoesNotOverwriteNewPublicationGeneration`
(AppModelTests.swift:899). It holds publication A's publish call, cancels A, starts
publication B, then releases A's held call *late*, and asserts B's context survives intact
(phase still .awaitingReferenceReview, candidateID and savingSlot still B's, and A's
"第一版音色 已完成复核…" success message did NOT leak into B).

The first note here claimed this was "design-verified / not test-covered". That was wrong —
an earlier grep used the wrong terms and missed the test. Corrected after mutation-probing it.

The defense is genuinely three-layered, which is why single-layer mutations are misleading:
  1. `isCurrentVoiceDesignPublication(generation)` — per-step guard re-checked after each await;
  2. `voiceDesignSaveTask?.cancel()` in `cancelVoiceDesignPublication`;
  3. the terminal gate `isCurrentGeneration = generation == voiceDesignPublicationGeneration`
     in `finishVoiceDesignPublication` (AppModel.swift:1955), immediately before writing
     savedSlots / successMessage / phase.
Removing (1) alone, (2) alone, or even (1)+(2) together leaves the test GREEN, because the
test's assertions ride on layer (3). Only forcing layer (3) open turns it RED, with exactly
the F7 symptom: phase -> .published, savingSlot -> nil, and publication A's success message
leaking into publication B. So the test is load-bearing, just against a different (the
innermost) gate than first assumed. The view-level trigger (`handleSaveSheetDismissal` ->
`cancelVoiceDesignPublication`) is a thin wrapper over this; its SwiftUI wiring itself is
not unit-tested (would need UI automation), but the model-level invariant it relies on is.

Everything else reconciled clean: F1 strict header, F2 dual-source strict render, F3
cold-worker + runtime-change rejection (both assert no audio), F4/F5 rejection-vs-unknown
handling and completion-log recovery, F6 real-ffmpeg subprocess lifecycle, C1 envelope
decoding, safety/no-secret fixtures, regression holds, and doc/contract agreement.

Round 7 verification: full `swift test` 319 XCTest + 145 swift-testing, 0 failures;
targeted F1 tests GREEN; AppModel.swift diff is whitespace-clean and contains no mutation
residue (`git diff --check` clean). The prior full Python gate stands: 2644 passed, ruff
and mypy clean. Defect count for the whole engagement: R1–R10 fixed, R11 investigated and
disproven (VoiceProfile has no availability-reason enum; both `available` and
`binding_unavailable` are valid observed values). No new defects in this round.

Still unexecuted, all authorization-gated (see report): UI automation, real-model E2E,
quality/latency acceptance, service start/stop and profile switching, install/release, and
commit. Branch remains `codex/ci-overlap-wheel-build`, which differs from the plan header's
`codex/voice-creation-use-e2e`; noted, not reconciled.
