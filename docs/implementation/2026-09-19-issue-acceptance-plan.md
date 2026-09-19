---
title: "SpeechRail issue acceptance implementation ledger"
status: active
date: 2026-09-19
---

# Single-PR implementation and acceptance plan

## Scope and evidence rules

Repository: `hrygo/SpeechRail`. Starting main: `28755de8cc51046f25ce75c7869fe1bacd34752d`.
Verified source tree: `d32177770d60d89ba96b7964fda10d77b14e713b` (690 tracked files).
One integration branch/PR, incremental atomic commits; no automatic merge, deployment,
model download, voice registration, or issue closure. The existing managed runtime is not modified.

All 15 open issues at this baseline are in scope. Closed issues are regression baselines,
not new feature requests. Completion means meeting the issue's actual acceptance criteria,
not adding an interface, obtaining HTTP 200, or passing synthetic tests.

Evidence classes: **source**, **synthetic/contract**, **Python 3.12 CI**, **macOS UI**,
**managed model measurement**, **human acoustic evaluation**. One cannot substitute for
another. Missing evidence remains pending. Conditional optimizations require the stated
measurement before changing policy. No performance percentages will be invented.

## Dependency order and acceptance matrix

| Issue | Baseline finding | Implementation/acceptance work | Independent evidence gate |
|---|---|---|---|
| #34 | Frozen gain already has credible 10 ms frames, bounded calibration and sample limiter; old issue body predates this code | Rerun frozen F1-F4, reset, fragmentation, cancellation and worker integration regressions; preserve dynamic path | Current multi-clone/text managed PCM matrix; transient distortion, latency and listening |
| #44 | Existing governor, telemetry, budgets and batch windows are not proof of fair execution | E1/E2/E3 measurement/default alignment first; then E4/E5/E13 scheduling and E11a memory; E6 independent | Cold/warm paced and commit-tail distributions, real contention, memory and thermal observations; E7-E12 remain conditional, E14 no large mixed refactor |
| #53 | UI-test composition uses the default persistent work store, allowing prior/user state to leak | Debug-only empty-store fixture plus empty-state/navigation UI regression, keep populated test | Isolated macOS UI execution; no desktop automation on user's machine |
| #62 | Existing discovery reports variant but has no atomic cross-object snapshot or precise parameter domains | Versioned read-only effective snapshot; single registry read; stable catalog hash and per-service epoch; explicit unknown identities | Profile/voice matrix, update/restart/concurrency, no inference/download, privacy, legacy compatibility |
| #63 | Registry already leases immutable audio; aliases and process-local idempotency do not ensure durable immutable identity | Revision history/CAS and resolved lease pin, transactional bounded idempotency, pre-PCM mismatch rejection | Restart/crash/write-failure/concurrent creation and revocation; no false legacy revision |
| #64 | Chunk validator and Realtime done exist; raw HTTP EOF alone is weak evidence | Negotiated receipt with defined count/hash boundary and resolved identity; terminal failure/cancel handling | Slow/disconnected clients, premature EOF, malformed chunks, deadline/cancel; not proof of audible or correctly read text |
| #65 | HTTP TTS uses BATCH_TTS; governor already has lanes/aging | Bounded negotiated purpose/budget through the same governor; safe maintenance handoff and cancellation | Mixed workload progress, same-lane serialization, co-resident budget, actual cleanup before capacity release |
| #66 | Waveform cache is not a prepared reference-condition cache | Audit pinned vendor public API; immutable port and explicit unsupported fallback; only implement cache if API supports it | Controlled precompute counters, bytes/entry bounds, single flight and isolation; real quality/performance separately |
| #67 | Quality v1 exists but repeatability is not identity | Add dimensioned versioned evidence without rewriting v1; bind actual execution identity or unknown | Reference-only/no-ASR states, independent identity/repeatability, honest unevaluated listening |
| #68 | Clone rejects instructions, non-1 speed, caller seed | Keep honest unsupported expression capability; document neutral fixed-identity fallback and falsifiable experiments | Matched identity/listening/latency A/B before any native-expression claim |
| #69 | FIFO commit/clear exists, previous_item_id is null | Bounded reference turn collector and combined contract tests; errors/gaps/cancel never become successful clear | Fake-ASR wire rollover/late-tail tests; no acoustic correctness claim |
| #70 | Generic normalization has no versioned lexicon | Explicit immutable pronunciation rules, deterministic conflict handling, span/hash audit, negotiated integration | Numbers/negation/URL/email/code/mixed language; revision/revoke and unchanged legacy behavior |
| #71 | Legacy voice discovery includes private reference text via several fields | Safe structured descriptor projection with no inferred personal traits; explicit compatibility/source-detail policy | Safe discovery and MCP consumption, no private text/path, snapshot consistency |
| #72 | Worker is the actual bounded sentence planner, not the documented realtime splitter | Versioned immutable text planner with source spans, lossless boundaries and common worker use | URL/decimal/abbreviation/quotes/mixed text; native context unsupported unless proven; real prosody/TTFA/RTF |
| #73 | Existing aligner has a different sample domain from TTS | Optional honest chunk-level sidecar, only finer alignment with verified implementation; integrate planner/receipt | Sample conservation, exact coordinate conversion, lexicon span mapping, partial/cancel; measured timing accuracy |

Execution groups: (1) regression/measurement foundation; (2) #62/#71 capability and
safe discovery; (3) #63 identity then #64 terminal receipts; (4) #70/#72/#73 text
planning and timing; (5) #65/#44 scheduling; (6) #66/#67/#68 evidence-gated quality
and performance. #53 is independent. All increments stay in this PR.

## Closed issue regression map

Closed #5/#7/#8/#9/#10/#11/#12: cold start, cancellation, preview/capability,
Silero/EOF/turn lifecycle and realtime acceptance baselines.
Closed #13/#16/#17/#18/#19: MCP, rate conversion, protocol profiles, bounded
planner/cache/deadline and diagnostic/diarization contracts.
Closed #30/#35/#36: registry/runtime safety, resource observations, voice quality.
Closed #39/#40/#41/#42/#43: job positions, safe errors, bounded retries, fairness,
owner-scoped job discovery. Closed #49/#50: SDK field names and TTS documentation.
These stay covered by existing tests; historical measurements retain their dates and limits.

## Required validation and stop conditions

- Targeted deterministic tests for each increment, then required full Python 3.12
  pytest/coverage, Ruff, Mypy, version consistency, Redocly and git diff checks.
- Validate the current PR head, not a prior green main commit. Level A ref/SHA
  verification on every publication; Level B diff and CI at milestones; Level C
  all required checks and base drift before calling the PR merge-ready.
- The initial container is Linux/Python 3.13.5. A Python 3.12 install attempt failed
  at GitHub DNS resolution. Local 3.13 results are supplementary, never labelled
  the project's Python 3.12 gate. Source acquisition used a pinned existing Actions
  artifact; no credentials were requested or copied into the container.
- macOS/MLX, real audio, constrained-memory and human listening evidence must be
  obtained separately; unavailable evidence prevents final issue acceptance.

## CHANGE_LEDGER

### Increment 1 — manual ASR consumer barrier

Files: `src/speechrail/realtime/turn_collection.py`,
`tests/test_manual_turn_collection.py`, this plan.

New bounded consumer collects committed item IDs in service order and terminal
text once per item. It requires an explicit close state plus cleared, rejects
sequence gaps/conflicting duplicates/missing terminals, ignores old epochs, and
prevents append during close. It never treats clear after a failure as success.
No server event or standard request is changed. Empty successful input stays empty.

Local command: `PYTHONPATH=src python -m pytest tests/test_manual_turn_collection.py tests/test_tts_loudness.py -q --no-cov`.
Result: **25 passed, Python 3.13.5**, synthetic/contract only. The initial new-test
collection failed because the new module did not exist; this is a feature scaffold
check, not a reproduction of a defect in the existing server. Wire integration,
Python 3.12 gates and final #69 acceptance are still pending.

Additional unchanged-baseline check: `tests/test_tts_loudness_frozen.py`: **39 passed**
on Python 3.13.5. This confirms the current synthetic F1-F4 regression suite, not
the managed-model/latency/listening acceptance of #34.

### Increment 2 — effective capability snapshot and safe discovery

Adds `/v1/speechrail/capabilities`, `/v1/speechrail/voices` and `/v1/speechrail/voices/{voice_id}` from one detached
registry generation. Each voice resolves against its captured profile and actual
configured lane, rather than looking up mutable registry data a second time.
Read-only epochs/content validators, per-operation parameter domains, explicit
unknown/unsupported states, conditional GET and safe descriptor/quality projections
are included. Configured model metadata is NOT promoted to observed worker identity;
legacy voices retain `voice_revision=null`, and conditional synthesis remains unsupported.

MCP `describe` exposes the atomic namespaced capability result separately from legacy observations;
legacy voice lists use an allowlist before entering Agent context. Only missing routes
or unknown schemas fall back; auth/storage errors remain errors. `/v1/voices` retains
its historical source-detail projection for compatibility; this privacy boundary and
migration are documented, not silently called a universal owner-access fix.

Tests first reproduced private/nested legacy metadata disclosure, missing namespaced discovery access,
and a malformed quality status crash. Result after implementation: **112 passed**
(`tests/test_capability_snapshot.py tests/mcp`, Python **3.12.14**), including the
three-profile/nine-voice-mode matrix and OpenAPI schema validation. Ruff over
`src tests scripts hatch_build.py` and Mypy over 114 source files passed.

The Python 3.12 toolchain limitation was resolved using an isolated Actions export
of the repository's locked development dependencies (run `35417347586`, uv 0.12.13,
lock SHA256 `3a4a96b64a754b270ed05d6b1bd5d4cede0aca7dedacb072f034365f89b8d8ec`).
No model runtime was installed or service deployed. An initial full local suite
attempt reached completion with three environment failures: this Linux image lacks
`/bin/zsh` for the macOS launcher, and two wheel tests could not resolve Hatchling
because package-index DNS is unavailable. These are NOT recorded as passed gates;
current-head CI and packaging evidence remain required. The initial published
commit's Ubuntu/macOS tests, macOS App and package checks succeeded; they do not
validate this later increment until it is published and checked separately.

### Increment 3 — isolated populated and empty macOS Works fixtures

Code inspection corrected the initial #53 finding: App's UI-test composition used
the default real `CreativeWorkStore`, so persisted user/previous-test state could
control whether the list appeared. Debug UI-test composition now always creates a
unique temporary store; default fixtures seed one synthetic silent work, and
`--ui-test-empty-works` leaves it empty. Failure cannot fall back to user storage.
Release composition ignores these fixture flags and retains the real store.

Adds an empty-state UI scenario checking the title, absence of work rows, navigation
to Dubbing, and return to an unchanged empty view. Existing populated/export scenario
is preserved. This Linux environment cannot compile SwiftUI or execute XCUITest;
macOS CI evidence is required. No UI automation was run on the user's desktop.
The existing populated test can skip lower-pane assertions on small CI displays;
a green job must not be described as proof that skipped assertions executed.

### Increment 4 — manual ASR wire conformance and current realtime contract

Connects the collector to the actual WebSocket handler with fake ASR: multi-rollover
commit order, repeated identical text in different items, tail completion, clear
following append failure, empty turns, and a terminal preceding backend commit ack.
The collector cannot finish before the ordered clear/resource teardown. All **106**
manual collector + Realtime handler tests passed on Python 3.12.14; Ruff passed.
The public contract now specifies the single-writer closure window and evidence
limits. It also corrects stale descriptions of the currently used bounded worker
planner, independent Quality TTS lanes, and failed response.done terminal state.
No field was added to the ordinary OpenAI WebSocket event schema.

### Increment 5 — versioned immutable bounded TTS planner

The common Qwen worker now wraps the existing acoustic splitter in `TtsTextPlanner`
(`tts_bounded_v1`): immutable request-local chunks, normalized Unicode-codepoint
spans, input digest, boundary kind, and a privacy-safe policy/count summary.
Boundaries and spoken input are exactly equivalent to the existing splitter; no
additional silence, native context conditioning, target KV sharing, or model calls
are introduced. REST/Realtime/preview share this worker. Capability discovery
advertises the actual policy; its catalog revision changes when policy changes.

Coordinates intentionally refer to normalized input, not raw HTTP input. Raw-to-spoken
span mapping (#70), completion receipts (#64), metrics integration, timing (#73),
and multi-mode naturalness/latency measurements remain separate, unfulfilled gates.
The planner does not log input text or its digest. An initial new policy regression
found that catalog revision missed a planner-version change; that was corrected.

Validation: planner, splitter, Qwen worker, clone and capability snapshot suite,
Python 3.12.14: **98 passed**. Ruff and Mypy checked the changed source/tests.
The test validates exact normalized-text conservation and boundary metadata, not
acoustic continuity or raw-text meaning preservation.

### Publication ledger at this milestone

One Draft PR: #74, `feat/issue-acceptance-20260919` -> `main`. Initial real upstream
base remains `28755de8cc51046f25ce75c7869fe1bacd34752d`. Published increments:

| Increment | Remote commit | Verified tree |
|---|---|---|
| 1 | `7a04b3db7922083a9277d796724a6f46527b9f50` | `b9f0abe85ecf99251781278c88c8e9545ad3f973` |
| 2 | `16fdfc4ee814f8273f4fe46f4ab9221b5e63375a` | `d340650b55e28fdf0ba6a31ece4ff1d479de78c7` |
| 3 | `1d4fade67ede7d22bc3c0c1daac0d916c0a14513` | `80b6b5b719fda213abeee5d196d2c7aa1d746bc1` |
| 4 | `34b2d8b678246db7ea419137d4258270bad343c0` | `bc694c257aa4fd7cb93da10c02d6d4934979ca33` |
| 5 | `983de74e91f068f3ad3dd4b365386a5549d5d903` | `db5680fdabecaea6ca4515238557e38704f4465c` |
| 6 | `ca5b98b3041e4682a56491b406e282ad9732481d` | `2daf6c1c78f722563b7b71598b1a77dcfb6f8c98` |

Each tree was matched to the locally tested source before the feature ref moved.
The isolated bridge used standard Actions authorization and a disposable branch;
transport contents/workflows are not part of the feature PR. Local snapshot commit
IDs are not represented as upstream commit IDs. No user service was changed.

### Increment 6 — preserve the leased VoiceDesign recipe across private IPC

Reproduced a real #63 subset: the parent leases a voice profile, but the old child
resolved its alias again for instruction and seed/temperature, including between
bounded text chunks. A fake model updated the registry after its first chunk and
observed mixed old/new recipes in one synthesis. This is distinct from scaffolding
failures for the new decoder helper, and does not require running a real model.

The parent now passes the leased recipe on the existing private local pipe. A
strict `profile_snapshot_version=1` handshake prevents an old worker from silently
ignoring the pin: persisted VoiceDesign requests fail before the synth frame/PCM
when support is absent. The worker validates an exact, bounded recipe schema and
uses the same immutable profile for every text chunk. Legacy private frames also
resolve the profile once per request. Clone reference leases and public request
schemas are unchanged. No private recipe is added to discovery or logs.

Tests cover alias changes while waiting for the worker lock, updates between
acoustic chunks, instruction/seed/temperature consistency, strict handshake types,
malformed snapshot rejection before engine execution, and recovery on the next
valid private request. Validation: `tests/test_tts_profile_snapshot.py`,
`tests/test_qwen3_tts.py`, `tests/test_qwen3_tts_worker.py`,
`tests/test_tts_voice_clone.py`: **75 passed, Python 3.12.14**. Ruff over the full
configured scope and Mypy over 115 source files passed. No acoustic claim is made.

This is NOT full #63 acceptance. Durable revision history, alias CAS, durable
owner/operation/payload-bound creation idempotency, restart/crash recovery,
revocation, and atomic expected model/voice revision synthesis are unimplemented.
Capability discovery correctly continues to report conditional synthesis as
unsupported and unknown immutable revisions as null.

Additional identity audit: `model_identity._fingerprint` hashes tensor metadata
(names, dtypes, shapes and byte extents), not weight payload bytes. The existing
`shape:` fingerprint must not be relabelled as an immutable model artifact revision.
Also, selection of a routing lane and acquiring the actual voice lease remain
separate operations; this patch does not claim an atomic cross-lane/model revision pin.

Increment 5 was published as `983de74e91f068f3ad3dd4b365386a5549d5d903`, tree
`db5680fdabecaea6ca4515238557e38704f4465c`, with a verified fast-forward of #74.
At the last CI observation for that head, Quality Gates and Ubuntu tests/coverage
passed; macOS tests/App were still running. Those results are not evidence for
this subsequent increment until its own published head is checked.


### Increment 7 — close the ASR failure-barrier regression matrix

Adds actual-handler tests for both commit exceptions and hung-terminal deadlines,
followed by FIFO clear. Both return `backend_timeout`, release the factory slot,
and leave the reference collector failed with no final transcript. Adds explicit
bounded event/item/text exhaustion and late terminal/clear after failure, cancel
or disconnect. These complement rollover, empty turn, duplicate, epoch, sequence,
append-during-close, and existing inbound queue-overflow regressions.

Manual collector + actual Realtime handler suite: **114 passed, Python 3.12.14**.
One combined, deduplicated run covering profile snapshots, Qwen adapters/worker,
clone leases, worker lifecycle, manual ASR, effective capabilities, all MCP tests,
planner, frozen/dynamic loudness and diarization compatibility: **424 passed**.
This is a targeted regression milestone, not the entire repository coverage gate.

## Acceptance status at the seven-increment checkpoint

**The requested all-issue acceptance is NOT complete.** Missing implementation and
missing external evidence are distinct. No issue has been automatically closed,
no merge/deployment was performed, and the PR remains Draft. A green CI run alone
will not close the real-model or human-evaluation gates.

| Issue | Delivered in this PR | Still required before full acceptance |
|---|---|---|
| #34 | Existing frozen-gain regression rerun; no redundant algorithm rewrite | Current multi-clone/model PCM, distortion, latency and human listening evidence |
| #44 | Baseline audit and corrected planner/lane documentation | E1/E2/E3 measurements and remaining scheduling/memory work; conditional items only after their measurement gates |
| #53 | Isolated temporary UI stores; populated fixture retained; explicit empty-state/navigation test | Confirm current-head macOS execution and distinguish any skipped assertions |
| #62 | Atomic safe read-only discovery, nine-case profile/mode matrix, parameter domains, cache/epoch semantics | Actual execution revision identity and atomic conditional synthesis integration with #63; vendor-dependent domains remain unknown |
| #63 | Reproduced and fixed leased recipe loss between parent/child and acoustic chunks | Durable history, alias CAS, durable creation idempotency, revision/model pin, restart/crash/revoke races; these are unimplemented, not hardware-only blockers |
| #64 | Existing delivery/terminal boundary audit only | Negotiated HTTP/Realtime integrity receipts, actual resolved identity and count/hash lifecycle; unimplemented |
| #65 | Existing governor/lane baseline audit only | Negotiated purpose/budget, maintenance handoff and mixed-workload/cancellation acceptance; unimplemented |
| #66 | Honest unsupported prepared-condition cache in discovery | Pinned vendor public-port audit, cache/invalidation/single-flight implementation where supported and controlled measurements |
| #67 | Safe projection of existing quality states | Versioned multi-dimensional evidence bound to actual revisions; identity vs repeatability and human/ASR missing-evidence cases; unimplemented |
| #68 | Native clone expression remains explicitly unsupported; no silent parameter acceptance | Explicit fixed-identity fallback contract and matched-identity listening/latency experiments; not an implemented native expression feature |
| #69 | Reference consumer, contract documentation and deterministic actual-handler acceptance matrix implemented | Current-head repository gates; no claim of acoustic transcription accuracy is required or made |
| #70 | Dependencies and boundaries documented | Versioned pronunciation lexicon, conflicts/revocation, raw-to-spoken span mapping and semantic-preservation corpus; unimplemented |
| #71 | Safe v2 voice catalogue and MCP allowlisted projection | Legacy v1 source-detail migration/owner-access policy; v1 still has private source fields for compatibility |
| #72 | Immutable versioned common planner, normalized-text spans, stable acoustic input | Raw-text mapping, context/pause policy, receipt/metrics integration and actual naturalness/TTFA/RTF evidence |
| #73 | Discovery correctly reports unsupported; sample-domain mismatch identified | Optional timing sidecar, sample-domain conversion and lexicon/source mapping, partial/cancel acceptance; unimplemented |

### Next implementation boundaries

Keep #74 as the only integration PR. Continue from its current real remote head,
not a local synthetic commit. First finish #63 on the existing registry/lease
transaction boundary; publish history and idempotency atomically, and never treat
`shape:` model metadata as weight-content identity. Then #64 can bind terminal
receipts to that actual execution identity without altering raw PCM bodies or
claiming that transport completion proves audible/correct content.

After those P0 dependencies, implement #70's immutable raw-to-spoken mapping before
#73 timing, preserving #72's common planner. #65 must use the existing governor;
#44 policy changes require the stated measurement evidence. #66/#67/#68 require
separate identity, reference-conditioning, intelligibility and listening evidence,
not a global synthetic quality score. External runtime changes/model downloads and
user-desktop automation remain outside this repository-only implementation run.


## #44 E5 / E13 bounded-yield checkpoint

Implemented on the shared Qwen ASR owner without adding a second model worker.

### Execution boundary

- The existing synchronous `AsrModeGate` remains the final batch/streaming
  mutual-exclusion guard.
- A shared asynchronous `AsrModeScheduler` now sits above that gate.
- Long batch transcription owns one persistent logical `AsrBatchTicket`, but
  acquires the batch mode only for one bounded ~30 s inference window at a time.
- After a successful window, batch releases the mode lease and yields the event
  loop before requeueing the same logical ticket.
- A realtime request already waiting at that safe boundary receives streaming
  mode before the batch task's next window unless the head batch task has aged
  past the configured fairness threshold.
- An already-active streaming session is never hard-preempted. This change does
  not claim Metal/kernel preemption and does not interrupt live model state.

### Fairness state

The same logical ticket survives all batch windows and retains:

- first enqueue time;
- cumulative queue wait;
- successfully completed service-window count;
- last successful progress time.

Requeueing therefore cannot reset a long job's age indefinitely. An aged batch
head blocks new streaming joiners after the current active streaming leases
finish, allowing sustainable mixed traffic to make background progress.

### Cancellation and correctness

- cancelled batch waiters are removed from the scheduler queue;
- failed windows do not increment progress;
- existing transcript merger/window IDs and bounded transport retry semantics are
  preserved;
- the scheduler has a legacy synchronous-gate fallback for injected/testing
  workers that do not expose the new scheduler.

### Observability

The metrics/resource snapshot exposes only fixed low-cardinality facts:

- pending streaming requests;
- pending batch logical tasks;
- head batch cumulative wait;
- head batch completed service windows;
- head batch seconds since progress.

No task ID, request ID, transcript text, audio content or client identity becomes
a metric label.

### Current evidence scope

Automated mixed-load regression proves that a 65 s / three-window batch request
can complete window 0, yield to an already-waiting realtime reservation, and
resume windows 1–2 after realtime releases the shared mode. Scheduler unit tests
also cover aged-batch anti-starvation and cancelled-waiter cleanup.

This is code/protocol evidence. Current-head Ubuntu/macOS CI and real MLX mixed-load
latency distributions remain required before declaring E5/E13 fully accepted.


## #34 frozen loudness algorithm checkpoint

The current production frozen-gain path now has deterministic code-level coverage
for the previously reproduced F1–F4 boundaries:

- leading silence does not consume the credible calibration window;
- a single impulse cannot establish request gain;
- peak limiting attacks sample-by-sample and releases across process() calls instead
  of attenuating an entire 200 ms block and immediately resetting;
- a near-threshold sample cannot toggle a whole chunk between bypass and full gain;
- processing is invariant to transport partitioning and preserves sample count;
- short/insufficient calibration stays at unity rather than locking unreliable gain;
- reset clears calibration, ramp and limiter state.

Calibration uses fixed media-time analysis frames, a minimum active fraction and a
median of multiple eligible frame powers. The first credible frame arms a bounded
collection deadline; silence before that does not age the request into fallback.

The known remaining quantization boundary is now observable without changing acoustic
behavior: before float output is converted to PCM16, the worker records a bounded
`float_overrange` delivery event whenever finite model samples exceed |1.0|.
The metric contains no amplitude, sample sequence, text, voice ID or reference data.

This evidence does NOT prove that the real MLX model commonly emits overrange floats,
nor does it prove subjective transient quality. Moving the limiter into the float
domain remains conditional on real-model evidence because doing so would change the
acoustic contract.

Current code-level acceptance therefore covers the reproduced algorithm defects;
multi-clone/multi-text MLX measurements, first-audio/service-output timings, and
listening evidence remain required for final #34 closure.


## Current-head reconciliation — 2026-09-19

The seven-increment sections above are historical checkpoints. They remain useful
as an audit trail, but the current remote head has continued the same single-PR
integration and supersedes the earlier “unimplemented” entries where the changes
below are now present. This section does not convert synthetic evidence into
managed-runtime or human-acoustic evidence.

The reconciliation implementation checkpoint was `db117796b42bc86b3623cbdd03c3722808cd1fe3`;
the later ledger commit, deadline-test stabilization and runtime-default documentation
are now followed by implementation head `34194a083c925239a92b504e1d1bd967b6c63be0`.

### Implementation deltas since the seven-increment checkpoint

- **#34**: the frozen clone loudness path now has explicit regression cases for
  leading silence, isolated transients, cross-block peak release and near-gate
  samples in `tests/test_tts_loudness.py`; the existing production controller
  remains request-scoped and length-preserving. This closes the reproduced F1–F4
  code boundary, not the managed multi-voice or listening gate.
- **#53**: the two macOS UI tests that targeted the ambiguous “服务状态” label now
  select the unique `overview` accessibility identifier. Current-head CI run
  `35450728000` passed the macOS App Build & Tests job; this remains CI evidence,
  not a local UI-automation run.
- **#63**: custom voices now persist content-addressed `vr_` revisions and bounded
  revision history, support expected-revision CAS update/rollback/revoke/delete
  behavior, preserve reader leases across changes, and keep legacy records at
  `revision=null`. Voice-design and clone creation use separate durable,
  owner/operation/key/fingerprint journals; pending records survive restart and an
  uncertain registry write remains pending instead of silently retrying publication.
  Recovery validates the stored result against the canonical request payload.
- **#64**: HTTP and negotiated Realtime receipts record the resolved voice/catalog
  identity, pre-transport PCM sample count and SHA-256, and explicit completed,
  cancelled or error terminals. Empty audio can no longer become `completed`.
  Runtime model identity remains `null` until a worker can substantiate it.
- **#65**: purpose and bounded latency-budget headers use the existing governor;
  quality/voice maintenance now acquires a wildcard TTS reservation, which waits
  for all keyed capability lanes before eviction. Same-lane serialization,
  interactive fairness and cancellation cleanup remain governor responsibilities.
- **#44**: the active documentation now records source release `2.7.0`, labels the
  managed `2.3.2` benchmark as historical evidence, and aligns the example
  `SPEECHRAIL_REALTIME_MAX_SESSIONS=3` with the `Settings` default. E1/E3 and
  real scheduling, memory and thermal measurements remain pending.
- **#70**: versioned pronunciation sets now provide deterministic conflict/revoke
  handling, protected URL/email/code spans, raw→normalized→spoken hashes and
  bounded raw-span projections. The optional v1 header applies a pinned set while
  keeping ordinary OpenAI requests unchanged.
- **#73**: the optional HTTP chunk sidecar is validated against the planner and the
  actual delivered PCM sample count; mismatches become `unavailable` rather than a
  false complete timeline. Normalization changes, backend absence, cancellation
  and partial/error delivery retain explicit downgrade states.
- **#66/#67/#68/#71/#72**: the pinned vendor reference-condition cache remains
  explicitly unsupported; quality evidence is dimensioned and revision-bound with
  identity/repeatability/naturalness kept separate; clone expression remains an
  explicit unsupported capability with neutral fixed-identity behavior; the safe
  namespaced voice catalog remains the default new integration surface while the
  legacy detail route is retained as a documented compatibility projection; and
  the common bounded planner is used for pronunciation-aware timing/receipt
  summaries without claiming native cross-sentence conditioning.

### Current deterministic validation

On Python **3.12.14**, the joint issue-focused regression set covering revisions,
durable idempotency, voice-quality routes, render receipts, timing, pronunciation,
governor maintenance, streaming, Realtime, planner and frozen loudness contains
**549 tests: all passed, 0 skipped**. The voice-quality route tests use per-test
temporary idempotency journals so rerunning the suite cannot read a developer's
default `~/.speechrail` journal. This is local source/synthetic evidence; the full
repository gate and current-head macOS App job also passed in CI run
`35451951303`.

### 2026-09-20 managed model measurement: partial TTS warm slice

在现有 managed `quality` profile（release `2.7.0`、generation `102`）上完成了一次
受限的真实 TTS warm 测量。官方 `bench_profiles.py` 结果为 6/6 TTS fixtures HTTP
200 且 `inference_observed=true`，资源采样完整；另以 `bench_tts.py` 对固定中文短句、
中文长句和英文文本各重复 5 次，得到平均耗时分别为 0.63 s、2.13 s、1.28 s，
continuous RTF 分别为 0.28x、0.27x、0.27x，`phys_footprint` 峰值为
`3997618232` bytes。完整去标识化摘要见
[`2026-09-20-pr74-tts-warm-evidence.md`](2026-09-20-pr74-tts-warm-evidence.md)。

这只是 managed-model 性能切片：官方结果保持 `release_pass=false`，实际
`model_identity` 为空，cold/local_quality/quality/switch、ASR/Realtime、声学质量、
人类听感和身份匹配仍未验证；因此没有将任何 issue 标记为完成。

### 2026-09-20 managed model measurement: ASR∥TTS overlap slice

使用官方 `bench_overlap.py` 在同一 managed `quality` generation 102 上完成了一次
真实 ASR∥TTS 调度切片：C1（TTS 先、0.5 s 后 ASR）和 C2（ASR 先、0.5 s 后 TTS）
均为 200；C1 观察到 governor batch peak `2`，C2 因 ASR 在延迟窗口内结束而为
`1`。两个场景的资源采样均完整、无 sampler error，`phys_footprint` 峰值分别为
`6747757840` 与 `7010721040` bytes。去标识化摘要见
[`2026-09-20-pr74-overlap-evidence.md`](2026-09-20-pr74-overlap-evidence.md)。

ASR fixture 是外置合成静音，只能证明真实 worker 的调度/资源路径，不证明识别质量；
持续负载、维护任务公平性、取消清理、thermal/soak、model identity 和人工听感仍未
验证，不能将此切片写成 #44/#65 完成。

### Remaining acceptance gates

The PR remains open. No merge, deployment, model download, voice registration or
issue closure was performed. Current-head CI is green; final acceptance still
requires managed Apple-Silicon measurements for #34/#44/#65/#72, actual
worker/runtime identity evidence for #62/#63/#64/#67, vendor/runtime cache
evidence for #66, matched identity/listening experiments for #68, and the
human/acoustic portions of #34/#67/#72/#73. These gates are intentionally not
inferred from fake backends, HTTP success, or the deterministic test count.
