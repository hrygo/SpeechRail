---
title: "Audio stability audit: deterministic capture and lifecycle boundaries"
status: active
date: 2026-10-01
---

# Audio stability audit

## Baseline and scope

The Mac checkout was on local main `2976d481` (project version 3.5.0), ahead of
remote main `693f8dfac99043e49595a0ff2fc2b29fc8f7d08a` (3.4.0), verified with
`git ls-remote origin HEAD refs/heads/main`. This work uses an independent local
clone, branch `fix/audio-stability-audit`. The original checkout's 19 changed
paths, including a staged deletion, were not modified or copied over.

Local fixes `3998ab1e` (voice-quality notation), `ac25745d` (TTS fadeout),
`06b3570e` (ASR tail refinement), and the older `fc3b464e` stdout isolation fix
were treated as existing work, not reimplemented or counted as new defects.

No microphone/system capture, UI automation, permissions/device changes,
managed service lifecycle operations, model loading, deployment, push or PR
were performed. Synthetic buffers, fake transports and offline fixtures are the
runtime evidence. These results do not establish actual device format, acoustic
quality, long-run stability, or installed-service behavior.

## First batch: ten corrected root causes

| # | Root cause and consequence | Correction and regression |
|---|---|---|
| 1 | Assistant callback writes only the first contiguous span; wrap drops samples despite available capacity. | Write successive spans with a source offset. An 8-slot ring at cursor 6 preserves four new frames. Restoring the original one-span behavior fails 18 format combinations. |
| 2 | Assistant channel-data pointers are indexed with stride 1 for interleaved PCM. | Respect `AVAudioPCMBuffer.stride` for Float32/Int16/Int32, planar/interleaved, 1/2/3 channels. Integer mixing uses Int64. |
| 3 | Tap treats interleaved scalar count as frame count, allowing over-read; ASBD was assumed Float32. | Validate packed native Float32 ASBD and complete buffer frames, use shortest planar length, reject malformed layouts. Sentinel allocation reproduces the old frame-count error without out-of-allocation access. |
| 4 | Tap power-of-two sample capacity is not frame-aligned for 3/6 channels and strands both cursors at wrap. | Frame-aligned capacity, modulo cursor offsets, explicit channel layout for multichannel AVAudioFormat. Repeated 200-wrap synthetic scenarios and converter construction pass. |
| 5 | TTS worker terminal does not settle outstanding start/append futures, masking the cause with timeout/input_closed. | Settle all acknowledgements on worker terminal and retain the worker error. Early terminal need not reap a healthy worker. |
| 6 | Local TTS cancellation is mistaken for worker retirement; interrupted/concurrent cleanup can return before reaping. | Track observed worker terminal separately, share close and abort tasks, join cleanup before propagating cancellation. Five failure-path tests cover interrupted cancel, cancelled close, and concurrent cancel/close during reaping. |
| 7 | TTS prepare/incremental open checks historical `_started`, not live readiness after idle worker death. | Use `ready`, matching the batch path; both operations restart in the same request. |
| 8 | ASR error plus end marker requires two queue slots; one remaining slot throws and masks worker error. | Reserve terminal capacity and preserve the real error, including full queues. Test 0/62/63/64 queued events. |
| 9 | ASR close removes reader but leaves a parked event consumer waiting forever. | Publish exactly one local end marker even if cancel send fails; preserve existing queued terminal. |
| 10 | ITN regex accepts Unicode decimal digits but folding/unit guards handle only ASCII; exceptions or inflated amounts result. | Fold Unicode decimal digits only within numeric conversions, guard unit boundaries with Unicode digits. Exhaustively check Nd characters; preserve unrelated text and already-written amounts. |

The additional ASBD validation and channel-layout construction are part of the
tap layout correction, not separately counted issues. TTS start/append waiting
and close/abort variants are each counted once by root cause.

## Verification of the first batch

Mac / Python 3.14.7 / local Swift toolchain, 2026-10-01 UTC:

- Final full Python: **2839 passed**, coverage **82.13%**, 84.63 seconds.
- Full Swift Package: **423 XCTest + 395 Swift Testing passed**. No XCUITest.
- Audio-focused Python: **93 passed**; original-source red runs include
  four initial TTS failures, concurrent-abort failure, two idle restart failures,
  and 18 ITN/ASR failures (three boundary controls already passed).
- Restoring original Swift one-span behavior fails 18 assertions; restoring
  original tap frame calculation fails the sentinel test. Fixed sources were
  restored before the final full run.
- Ruff `src tests scripts hatch_build.py`: passed; Mypy `src`: passed, 155 files.
- Version consistency: 3.5.0, passed. OpenAPI path contract: 39 paths / 47 operations.
- MCP contract: 18 tools / 3 resources. Redocly 2.52.1 OpenAPI lint: passed.
- Xcode project plist and diff whitespace checks: passed. Existing test source
  membership is reused; CoreAudioTapCapture is also included in Unit Test Sources.

Commands use the existing locked development environment, with `PYTHONPATH=src`
to select this isolated checkout. The full Python suite needs an external
pytest plugin loaded before collection: it replaces `Path.home()` with a fresh
`tempfile.mkdtemp` directory and repeats that override per test. It does **not**
change HOME, runtime configuration or repository source. This avoids tests writing
the user's default logs and voice registry; local mock sockets, subprocess and
temporary packaging operations run with reviewed filesystem permissions.
The initial sandbox run was interrupted after 38 environment failures and
1375 passes; it is not reported as a code regression. Final full runs include
all tests with isolation (no test exclusions). Existing warnings remain.

Portable gate commands, after enabling equivalent temporary-home isolation:

```sh
PYTHONPATH=src:<audit-plugin-directory> python -m pytest -p speechrail_audit_isolation
python -m ruff check src tests scripts hatch_build.py
python -m mypy src
swift test --package-path macos/SpeechRailApp --skip-update
python scripts/check_version_consistency.py
python scripts/check_openapi_contract.py
python scripts/check_mcp_tool_contract.py
npx --yes @redocly/cli@2.52.1 lint contracts/openapi.yaml
git diff --check
```

## Second batch: acknowledged tail-input barrier

The eleventh corrected root cause is a confirmed tail-drain race: append A and
B, consume A's old completed event, then call `drainAndClear`. The original
`settleDeclaredItem` resets the input counter although B remains unconfirmed,
allowing clear to discard B. A fake-transport XCTest fails deterministically
against the original implementation.

An additive, opt-in commit extension now requests an input receipt using
`speechrail.request_receipt: true` and an `event_id`. The server sends
`speechrail.input_audio_buffer.committed`, with the matching `commit_event_id`
and cumulative `accepted_samples` in 24 kHz wire samples, only after previous
input and its actual transcript terminal send complete under the commit lock.
Empty, repeated and already automatically committed input also receive a
per-command receipt without inventing another transcript terminal. Default
commits and explicit false retain the existing wire behavior for older clients.

The Mac client waits for its matching receipt and exact cumulative sample
watermark before clearing. Unrelated transcript terminals cannot reset this
barrier. Missing receipts from older servers, timeout, cancellation, correlated
command errors, and malformed or incorrect watermarks close the transport
without clearing. Older servers therefore fail closed within a bounded timeout;
this does not claim successful drain compatibility with servers lacking receipts.

Independent read-only review caught two additional implementation boundaries:
ASR EOF without a sent transcript terminal, and a repeated commit after a failed
or timed-out prior commit. Both now fail without a receipt; receipt readiness is
recorded only after successful retirement. Regression tests cover both first
attempt and retry. The reviewer rechecked the corrections and reported no new
high-priority regression.

Tests cover old-A/new-B ordering, empty and duplicate commands, automatic commit,
wire sample watermarks, cancellation and disconnect, missing terminals and retry,
wrong IDs, correlated errors, and invalid boolean/string/fractional/oversized
watermarks. Protocol schema, field matrix, shared fixtures and both API documents
are updated. One pre-existing rollover test now checks session count after the
second correlated terminal instead of racing construction after the first send.

### Final combined verification

The final code state, including both batches, passed all full gates on this Mac:

- Python: **2855 passed**, coverage **82.17%**, 76.01 seconds; 708 warnings.
- Swift Package: **429 XCTest + 395 Swift Testing passed**, zero failures.
- Ruff: passed. Mypy: passed, 155 files (existing unused configuration note).
- Version: 3.5.0. OpenAPI: 39 paths / 47 operations. MCP: 18 tools / 3 resources.
- Redocly 2.52.1, Xcode project plist and diff whitespace checks: passed.

Full Python uses the same temporary-home isolation described above and runs all
tests without exclusions. Final logs are `batch2-final-python.log`,
`batch2-final-swift.log` and `batch2-openapi-lint.log` in the parent audit task
directory. The independent review's focused slice was not a full coverage gate;
these combined full-suite results are the coverage evidence. Documentation-only
completion follows the final code gate; no code changes follow it.

## Remaining investigations

- **Confirmed numeric semantic weakness**: current quality comparison scores
  `温度22.5℃` versus `温度-22.5℃` as 1.0. Local `3998ab1e` fixes notation false
  rejects, not this issue. A numeric-token/semantic policy needs separate design;
  thresholds were not weakened here.
- **External synthetic evidence, not locally revalidated**: multipart size/auth
  enforcement after parser spooling and aliasing in linear downsampling. Cloud
  researchers supplied harness/tone evidence; these are separate scoped work.
- Actual CoreAudio device/permission layouts, user-facing capture, installed
  app, real workers, performance and listening tests remain unverified.

Rollback is a revert of the local audit commits, with no runtime rollback needed.
