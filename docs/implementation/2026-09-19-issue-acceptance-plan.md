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
| #53 | Works fixtures always populate local work storage | Debug-only empty-store fixture plus empty-state/navigation UI regression, keep populated test | Isolated macOS UI execution; no desktop automation on user's machine |
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
