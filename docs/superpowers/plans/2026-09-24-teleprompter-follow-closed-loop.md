# Teleprompter Follow Closed-Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore reliable script-follow behavior from microphone audio through Realtime ASR events to the teleprompter stage, including realistic ASR wording, Chinese ITN forms, short utterances, temporary detours, and observable recovery.

**Architecture:** Keep SpeechRail's stateless Speech Plane and the macOS app's caller-owned follow state. Add a canonical text layer shared by script and ASR inputs, replace hard trailing-token admission with bounded monotonic fuzzy alignment, and make partial/final evidence drive a hysteretic follow state. Extract the event-to-follow adapter so the same reducer is tested with realistic wire events and used by `TeleprompterSession`.

**Tech Stack:** Swift 6.2, macOS 26, Swift Testing/XCTest, Foundation string/Unicode APIs, existing `SpeechRailControlKit` Realtime contract types, fake deterministic ASR events. No new runtime dependency is required for the first implementation.

**Spec:** `docs/developers/macos-app-teleprompter.md`; `docs/decisions/0020-teleprompter-workflow-reliability.md`; `contracts/realtime-openai.md`

## Global Constraints

- Keep Python `>=3.12,<3.13`; macOS deployment target remains `26.0`; Apple Silicon `arm64` only.
- Keep `/v1/realtime` as the current-only Speech Plane contract. The app owns microphone capture, playback, speech UI, LLM orchestration, and script business state.
- Keep ASR text bounded and in memory for the active run only. Do not persist complete transcripts, PCM, Base64, embeddings, or absolute model paths in logs, fixtures, or reports.
- Do not change service lifecycle, model loading, profile selection, or network exposure in this work.
- Public behavior changes must update the affected contract/tests and active user/developer documentation. Do not add compatibility aliases for old wire fields.
- No UI automation, real microphone smoke, model download, service restart, installation, publishing, or benchmark is authorized by this plan. Visual acceptance is a separate user-authorized activity.
- Preserve uncommitted and parallel work. Never use `git checkout --`, `git reset --hard`, or whole-file overwrite to remove another session's edits.

## Implementation File-Boundary Ruling — 2026-09-24

Keep the canonicalizer in the existing `TeleprompterNormalizer.swift`, and keep the Realtime adapter and follow presentation mapping beside the reducer in `TeleprompterFollowController.swift`; extend the already registered test files rather than adding Swift files or PBX references. The Xcode project uses explicit source membership, so co-location avoids adding project metadata without changing the planned public interfaces. The SwiftPM support target includes `RealtimeASRClient.swift` because the adapter consumes its event type. The local canonicalizer also accepts the common `〇` digit in year strings to preserve client-side alignment; this is a narrow prior-character-equivalence extension, not a change to server ITN behavior.

## Current Evidence

### Contract and test declarations

- `contracts/realtime-openai.md` declares `speechrail.transcription.snapshot` as a replaceable, revisioned partial full text and `conversation.item.input_audio_transcription.completed` as the frozen final transcript.
- `RealtimeContractTests.swift` verifies `partial_mode=snapshot`, `chunk_duration_ms=500`, and current-only session fields for the teleprompter path.
- `tests/test_itn.py` pins the server's Chinese year, percent, decimal, and unit ITN behavior. The client canonicalizer must use these cases as parity fixtures rather than inventing a second unrelated grammar.
- `TeleprompterPositionTests` and `TeleprompterFollowControllerTests` currently prove idealized behavior for mostly literal input, not realistic ASR variants or the full wire reducer.

### Source-derived root causes

- `TeleprompterAligner.swift:92-95` rejects fewer than three normalized tokens.
- `TeleprompterAligner.swift:131-142` requires `input.last` to be exactly equivalent to the script token at each candidate end. One ASR substitution at the tail removes every candidate.
- `TeleprompterFollowController.swift:100-159` requires confidence `>=0.88`, at least five matches, and prior growth evidence before provisional movement.
- `TeleprompterFollowController.swift:162-201` rolls a provisional position back to the item anchor when final alignment fails.
- `realtime_openai.py:1610` and `itn.py:93-120` normalize server final text through ITN, while `TeleprompterAligner.swift:176-179` only maps individual Chinese digit characters.
- `TeleprompterAnalysis.swift:72` and `TeleprompterPreparationPrompts.swift:869` keep `matchPhrases` empty; the aligner does not consume the field.
- `Package.swift:38-103` excludes `RealtimeASRClient.swift` and `TeleprompterSession.swift` from the package test target, so the actual event-to-follow closure is not compiled in the focused test suite.

## File Structure

| File | Responsibility |
|---|---|
| `macos/SpeechRailApp/SpeechRailApp/TeleprompterNormalizer.swift` | Existing source-indexed tokenization plus canonical units for script and ASR text, numeric/ITN equivalence, and UTF-16 ranges |
| `macos/SpeechRailApp/SpeechRailApp/TeleprompterAligner.swift` | Bounded monotonic fuzzy matching and ambiguity scoring over canonical units |
| `macos/SpeechRailApp/SpeechRailApp/TeleprompterFollowController.swift` | Partial/snapshot/final reducer, provisional evidence, hysteresis, re-anchoring, and non-persistent diagnostics |
| `macos/SpeechRailApp/SpeechRailApp/TeleprompterFollowController.swift` | Follow-state reducer, shared Realtime event adapter, presentation-state labels, hysteresis, and bounded transient diagnostics |
| `macos/SpeechRailApp/SpeechRailApp/TeleprompterSession.swift` | Use the shared adapter and publish transient follow state to the stage |
| `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageView.swift` | Show user-language listening/matching/recovery status without displaying or persisting the full ASR transcript |
| `macos/SpeechRailApp/Package.swift` | Compile the pure canonicalizer, aligner, controller, adapter, and their tests; keep unrelated app/network files excluded |
| `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterNormalizerTests.swift` | Numeric, punctuation, Unicode, and ITN equivalence tests |
| `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterAlignerTests.swift` | Realistic ASR variants, short fragments, ambiguity, and source-coordinate tests |
| `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift` | Partial/final state, hysteresis, rollback, detour, and re-anchor tests |
| `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift` | Partial/final state, adapter wire closure, presentation labels, detour, and re-anchor regression tests |
| `tests/test_itn.py` | Keep server ITN behavior pinned while the Swift canonicalizer mirrors the same cases |
| `docs/developers/macos-app-teleprompter.md` | Update user-visible behavior, limits, diagnostics, and acceptance guidance |

## Review Focus

- **ITN-equivalent speech:** `二零二六年` / `2026年`, `百分之五十` / `50%`, `三点一四` / `3.14`, and `十个人` / `10个人` must reach the same canonical alignment without moving the displayed UTF-16 range incorrectly.
- **ASR tail variation:** a final phrase with one substituted, omitted, repeated, or filler token must still advance to a nearby unique script location.
- **Short phrases:** one- and two-unit utterances must work near the current anchor but must not jump to a repeated phrase elsewhere in the script.
- **Provisional correction:** a noisy partial may preview progress, but one mismatching final must not erase all prior progress; a sustained detour must enter free-play and later re-anchor.
- **Wire closure:** snapshot revision replacement, completed final correction, late old finals, repeated event IDs, and `failed`/`closed` transitions must use the same reducer in tests and production.
- **Privacy and coordinates:** diagnostics may expose counts/confidence/state but not full transcript; emoji and supplementary-plane characters must keep correct source ranges.

---

### Task 1: Canonical text units and ITN equivalence

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterNormalizer.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterNormalizerTests.swift`, `tests/test_itn.py`

**Interfaces:**
- Consumes: `TeleprompterSourceRange`, `TeleprompterNormalizer.indexedTokens`.
- Produces: `TeleprompterCanonicalizer.Unit` with `value: String`, `range: TeleprompterSourceRange`, and `isNumeric: Bool`; `TeleprompterCanonicalizer.units(_ text: String) -> [Unit]`; `TeleprompterCanonicalizer.values(_ text: String) -> [String]`.
- Contract: equal canonical values mean the two spans are safe to compare for follow matching; ranges always refer to UTF-16 offsets in the input string. The accepted numeric cases must stay behaviorally compatible with `src/speechrail/domain/itn.py` and `tests/test_itn.py`.

- [x] **Step 1: Write the failing tests**

```swift
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterCanonicalizerTests {
    @Test func mapsItnNumericEquivalents() {
        #expect(TeleprompterCanonicalizer.values("二零二六年")
                == TeleprompterCanonicalizer.values("2026年"))
        #expect(TeleprompterCanonicalizer.values("百分之五十")
                == TeleprompterCanonicalizer.values("50%"))
        #expect(TeleprompterCanonicalizer.values("三点一四")
                == TeleprompterCanonicalizer.values("3.14"))
        #expect(TeleprompterCanonicalizer.values("十个人")
                == TeleprompterCanonicalizer.values("10个人"))
    }

    @Test func preservesSourceRangesAcrossUnicodeAndFillerRemoval() {
        let units = TeleprompterCanonicalizer.units("😀嗯，今天 number")
        #expect(units.map(\.value).contains("今天"))
        #expect(units.map(\.value).contains("number"))
        #expect(units.allSatisfy { $0.range.end > $0.range.start })
    }

    @Test func keepsDistinctWordsDistinct() {
        #expect(TeleprompterCanonicalizer.values("相机参数")
                != TeleprompterCanonicalizer.values("相机设置"))
    }
}
```

- [x] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterCanonicalizerTests`
Expected: FAIL because `TeleprompterCanonicalizer` is not defined.

- [x] **Step 3: Add the minimal canonicalizer**

Add `TeleprompterCanonicalizer` beside the indexed tokenizer in `TeleprompterNormalizer.swift`, with a deterministic scanner. It must first parse numeric expressions into one unit, then pass the remaining text through `TeleprompterNormalizer.indexedTokens`. Numeric canonical values use a fixed grammar, not locale formatting:

```swift
import Foundation

public enum TeleprompterCanonicalizer {
    public struct Unit: Equatable, Sendable {
        public let value: String
        public let range: TeleprompterSourceRange
        public let isNumeric: Bool
    }

    public static func values(_ text: String) -> [String] {
        units(text).map(\.value)
    }

    public static func units(_ text: String) -> [Unit] {
        CanonicalScanner.units(in: text)
    }
}
```

`CanonicalScanner.units(in:)` must be implemented in the same file as a private state machine that emits numeric and non-numeric units in original source order. Non-numeric text is passed through `TeleprompterNormalizer.indexedTokens` and prefixed with `t:`. Numeric spans use these exact normal forms:

- Arabic or Chinese digit sequences become `n:<decimal>`.
- `三点一四` and `3.14` become `n:3.14`.
- `百分之五十`, `百分之五`, and `50%` become `n:0.5`.
- `十个人` and `10个人` produce `n:10` plus `t:个`; `十二` becomes `n:12`, not `n:102`.
- A numeric span owns the complete source range, including the Chinese phrase or Arabic punctuation that formed it.
- Unknown or ambiguous digit prose falls back to `t:` units and never throws.

The parser should expose only the four public functions above; keep its grammar local and deterministic rather than introducing a third-party dependency.

- [x] **Step 4: Run the focused tests**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterCanonicalizerTests`
Expected: PASS.

- [x] **Step 5: Run existing normalizer tests**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterNormalizerTests`
Expected: PASS; existing source-range and filler behavior remains unchanged.

- [x] **Step 6: Run server ITN parity tests**

Run: `uv run pytest tests/test_itn.py -q`
Expected: PASS. If the client adds a new canonical form, add the equivalent server/client fixture in the same change instead of allowing one side to drift.

- [ ] **Step 7: Commit**

```bash
git add macos/SpeechRailApp/SpeechRailApp/TeleprompterNormalizer.swift macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterNormalizerTests.swift
git commit -m "feat: canonicalize teleprompter ITN variants"
```

---

### Task 2: Remove trailing-token hard admission from the aligner

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterAligner.swift:86-180`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterAlignerTests.swift`

**Interfaces:**
- Consumes: `TeleprompterCanonicalizer.values`, `TeleprompterAligner.Script`, `TeleprompterAligner.Position`.
- Produces: existing `TeleprompterAligner.Match`; callers keep using `position`, `startPosition`, `confidence`, `matchedCount`, `isUniqueExactContinuation`, and `isUniqueNearAnchor`.

- [x] **Step 1: Add failing realistic-ASR tests**

Add these cases to `TeleprompterAlignerTests`:

```swift
@Test func toleratesSubstitutedTailAndShortInput() throws {
    let segments = try TeleprompterSegmenter.segment(sourceText: "现在介绍相机设置。最后导出照片。")
    let aligner = TeleprompterAligner()
    let substituted = aligner.locate(
        transcript: "现在介绍相机参数",
        segments: segments,
        anchor: .init(segmentIndex: 0, utf16Offset: 0)
    )
    #expect(substituted.position?.segmentIndex == 0)
    let short = aligner.locate(
        transcript: "继续",
        segments: try TeleprompterSegmenter.segment(sourceText: "欢迎。继续。"),
        anchor: .init(segmentIndex: 0, utf16Offset: 2)
    )
    #expect(short.position != nil)
}

@Test func itnVariantsShareTheSameScriptPosition() throws {
    let segments = try TeleprompterSegmenter.segment(sourceText: "我们在二零二六年把成功率提高到百分之五十。")
    let result = TeleprompterAligner().locate(
        transcript: "我们在2026年把成功率提高到50%",
        segments: segments,
        anchor: .init(segmentIndex: 0, utf16Offset: 0)
    )
    #expect(result.position?.segmentIndex == 0)
    #expect(result.confidence >= 0.72)
}
```

- [x] **Step 2: Run the tests to verify the failure mode**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterAlignerTests`
Expected: FAIL on `toleratesSubstitutedTailAndShortInput` and `itnVariantsShareTheSameScriptPosition`.

- [x] **Step 3: Replace tokenization and candidate admission**

Change `Script.Token.value` construction and `locate(transcript:segments:anchor:)` to use `TeleprompterCanonicalizer.values`. Keep the bounded window and semi-global DP, but replace lines 131-142 with end-cell scoring:

```swift
let minimumMatches = max(1, min(3, input.count - 1))
let candidates = (1...window.count).compactMap { end -> Candidate? in
    let cell = previous[end]
    guard cell.matches >= minimumMatches else { return nil }
    return Candidate(
        end: end,
        start: cell.start,
        confidence: max(0, 1 - cell.cost / Double(max(input.count, 1))),
        matches: cell.matches
    )
}
.sorted {
    if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
    return abs(lower + $0.end - anchorIndex) < abs(lower + $1.end - anchorIndex)
}
```

Retain the existing competitor margin and `uniqueExactContinuation` guard. For one- or two-unit inputs, require either `isUniqueNearAnchor` or a confidence margin over the nearest competing end; a repeated short phrase elsewhere must return `Match(position: nil, ...)`.

- [x] **Step 4: Run the focused aligner tests**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterAlignerTests`
Expected: PASS, including the old literal, repeat, and unrelated-speech cases.

- [x] **Step 5: Check Unicode coordinates**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPositionTests`
Expected: PASS. Add a supplementary-plane assertion if the existing emoji case does not cover the returned end position.

- [ ] **Step 6: Commit**

```bash
git add macos/SpeechRailApp/SpeechRailApp/TeleprompterAligner.swift macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterAlignerTests.swift
git commit -m "fix: align teleprompter ASR variants without tail exact-match"
```

---

### Task 3: Hysteretic partial/final follow state

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterFollowController.swift:68-281`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift`

**Interfaces:**
- Consumes: `TeleprompterAligner.Match`, `TeleprompterCanonicalizer.values`, `TeleprompterRunMode`.
- Produces: `TeleprompterFollowController.followState`, `lastMatchConfidence`, `lastMatchedCount`, `candidatePosition`, `partialPreview`; existing `receivePartial`, `receiveSnapshot`, `receiveCompleted`, `pause`, `resume`, `move`, and `enterManual` signatures remain source-compatible.

- [x] **Step 1: Write failing state-machine tests**

```swift
@Test func partialCanPreviewForwardWithoutImmediateFinalRollback() throws {
    let segments = try script()
    var controller = TeleprompterFollowController()
    controller.receiveSnapshot(itemID: "a", revision: 1, text: "今天我们介绍相机",
                               segments: segments)
    let previewPosition = controller.position
    controller.receiveCompleted(itemID: "a", transcript: "今天我们介绍相机设置",
                                segments: segments)
    #expect(controller.position.utf16Offset >= previewPosition.utf16Offset)
    #expect(controller.followState == .tracking)
}

@Test func sustainedDetourEntersFreePlayAndLaterReanchors() throws {
    let segments = try script()
    var controller = TeleprompterFollowController()
    controller.receiveCompleted(itemID: "a", transcript: "我先回答观众问题",
                                segments: segments)
    controller.receiveCompleted(itemID: "b", transcript: "这个问题和稿件无关",
                                segments: segments)
    #expect(controller.followState == .freePlaying)
    controller.receiveCompleted(itemID: "c", transcript: "最后演示照片导出",
                                segments: segments)
    #expect(controller.followState == .tracking)
    #expect(controller.currentIndex == 2)
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterFollowControllerTests`
Expected: FAIL because `followState` does not exist and rollback behavior is too aggressive.

- [x] **Step 3: Add state and hysteresis**

Add a small public state enum and diagnostics fields:

```swift
public enum TeleprompterFollowState: Equatable, Sendable {
    case waitingForSpeech
    case listening
    case tracking
    case catchingUp
    case freePlaying
    case paused
    case manual
}
```

Use a private `lastConfirmedPosition` and `lowConfidenceStreak`. Introduce an injectable `TeleprompterFollowPolicy` instead of scattering numeric gates: its initial defaults are `provisionalMinimumConfidence = 0.72`, `provisionalMinimumMatches = 2`, `freePlayAfterMisses = 2`, and `reanchorMargin = 0.12`; final acceptance continues to use `TeleprompterAligner.Configuration.minimumConfidence`. These are implementation starting points to calibrate with real ASR variants, not quality claims. A snapshot may move `position` provisionally when the match is forward and either unique near the anchor or exceeds the policy gate. A final match confirms the position; an isolated final mismatch keeps the last confirmed position for one item and increments `lowConfidenceStreak`. Two consecutive mismatches enter `freePlaying`, clear transient history, and retain the last confirmed position. A later unique forward or anchor-local match returns to `tracking` and re-anchors. Existing event deduplication, retired-item ordering, and manual/pause invalidation remain unchanged.

- [x] **Step 4: Run focused follow tests**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterFollowControllerTests`
Expected: PASS, including old ordering, repeated-event, long-turn, and manual-position cases.

- [x] **Step 5: Run canonicalizer and aligner tests together**

Run: `swift test --package-path macos/SpeechRailApp --filter 'TeleprompterCanonicalizerTests|TeleprompterAlignerTests|TeleprompterFollowControllerTests'`
Expected: PASS. The global coverage gate may still report a focused-run coverage failure; use case results and exit diagnostics to distinguish that from test failures.

- [ ] **Step 6: Commit**

```bash
git add macos/SpeechRailApp/SpeechRailApp/TeleprompterFollowController.swift macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift
git commit -m "fix: stabilize teleprompter partial and final follow state"
```

---

### Task 4: One shared Realtime event adapter

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterFollowController.swift` to add the shared adapter beside the reducer
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterSession.swift:1527-1589`
- Modify: `macos/SpeechRailApp/Package.swift:38-104` to remove `RealtimeASRClient.swift` from `exclude` and list it in `sources`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift`

**Interfaces:**
- Consumes: `RealtimeASRClient.Event`, `RealtimeEventMetadata`, `TeleprompterFollowController`.
- Produces: `TeleprompterRealtimeFollowAdapter.apply(_ event: RealtimeASRClient.Event, metadata: RealtimeEventMetadata, segments: [TeleprompterSegment], to controller: inout TeleprompterFollowController) -> TeleprompterRealtimeFollowOutcome`.
- Outcome values: `.aligned`, `.previewed`, `.ignored`, `.terminalFailure`.

The adapter must reconcile by `item_id`, not arrival rank. A snapshot replaces the current item text according to its revision; a completed event freezes that item's transcript. Completion events from different speech turns may arrive out of order, so a late final from an older item must never undo a newer confirmed position.

- [x] **Step 1: Write wire-event tests**

```swift
@Test func snapshotCompletedSequenceDrivesFollowPosition() throws {
    let segments = try TeleprompterSegmenter.segment(sourceText: "欢迎来到今天的直播。最后演示照片导出。")
    var controller = TeleprompterFollowController()
    var adapter = TeleprompterRealtimeFollowAdapter()
    let metadata = RealtimeEventMetadata(eventID: "e1", sessionID: "s", sequence: 1)
    _ = adapter.apply(.partialSnapshot(itemID: "i", revision: 1, text: "欢迎来到"),
                      metadata: metadata, segments: segments, to: &controller)
    let outcome = adapter.apply(.completed(itemID: "i", transcript: "欢迎来到今天的直播", units: []),
                                metadata: .init(eventID: "e2", sessionID: "s", sequence: 2),
                                segments: segments, to: &controller)
    #expect(outcome == .aligned)
    #expect(controller.currentIndex == 0)
}
```

Add cases for revision replacement (never append), duplicate `eventID`, late old final, `failed`, and `closed`. These cases must construct `RealtimeASRClient.Event` directly and assert controller state; no socket or live service is used.

- [x] **Step 2: Run the test to verify the adapter is missing**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterRealtimeFollowAdapterTests`
Expected: FAIL because `TeleprompterRealtimeFollowAdapter` is not defined.

- [x] **Step 3: Extract the reducer**

Move the `switch envelope.payload` mapping for `speechStarted`, `partial`, `partialSnapshot`, `completed`, `failed`, and `closed` from `TeleprompterSession.handle` into the adapter. The adapter must pass `metadata.eventID` to `receivePartial`/`receiveSnapshot`/`receiveCompleted`; it must not log or persist transcript text.

`TeleprompterSession.handle` then calls the adapter and `syncFollowState()` exactly once per relevant event. Keep backend error handling (`backend_busy`, `lastFailure`, `enterManual`) in the session because it owns UI and lifecycle state.

- [x] **Step 4: Run adapter tests**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterRealtimeFollowAdapterTests`
Expected: PASS.

- [x] **Step 5: Build the package**

Run: `swift build --package-path macos/SpeechRailApp`
Expected: PASS. `RealtimeASRClient.swift` is included because the adapter consumes its public `Event`; do not add `TeleprompterSession.swift`, `MicrophoneCapture.swift`, or unrelated app files to the test target. The tested reducer remains pure and deterministic and does not open a socket.

- [ ] **Step 6: Commit**

```bash
git add macos/SpeechRailApp/SpeechRailApp/TeleprompterFollowController.swift macos/SpeechRailApp/SpeechRailApp/TeleprompterSession.swift macos/SpeechRailApp/Package.swift macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift
git commit -m "test: cover teleprompter realtime follow event closure"
```

---

### Task 5: Minimal user-facing follow feedback

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterSession.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageView.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift`

**Interfaces:**
- Consumes: `TeleprompterFollowState`, `TeleprompterFollowController.lastMatchConfidence`, `lastMatchedCount`, `partialPreview`.
- Produces: `TeleprompterSession.followState`, `followStatusText`; stage displays only user-language status and progress, never a full ASR transcript.

- [x] **Step 1: Add presentation-state tests**

```swift
@Test func statusLabelsDistinguishWaitingTrackingAndFreePlay() {
    #expect(TeleprompterFollowPresentation.statusText(for: .waitingForSpeech) == "等待声音请开讲…")
    #expect(TeleprompterFollowPresentation.statusText(for: .tracking) == "跟读咬合")
    #expect(TeleprompterFollowPresentation.statusText(for: .freePlaying) == "自由发挥中")
    #expect(TeleprompterFollowPresentation.statusText(for: .catchingUp) == "正在跟上稿件")
}
```

- [x] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterFollowControllerTests`
Expected: FAIL because `TeleprompterFollowPresentation` is not defined.

- [x] **Step 3: Add presentation mapping**

Add `TeleprompterFollowPresentation` to `TeleprompterFollowController.swift` or a small adjacent pure file. Map `waitingForSpeech`, `listening`, `tracking`, `catchingUp`, `freePlaying`, `paused`, and `manual` to ordinary user language. `syncFollowState()` publishes `followState` and `followStatusText`; it must not copy `partialPreview` into persistent state or logs.

Update the existing `statusCapsule` in `TeleprompterStageView.swift` to consume `session.followStatusText` and `session.followState`, preserving semantic design tokens and accessibility labels. Do not add a raw recognition transcript, confidence number, token count, model name, or protocol event name to the primary stage UI.

- [x] **Step 4: Run focused presentation and follow tests**

Run: `swift test --package-path macos/SpeechRailApp --filter 'TeleprompterFollowControllerTests|TeleprompterStageSettingsTests'`
Expected: PASS.

- [x] **Step 5: Build the App target**

Run: `xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -configuration Debug build`
Expected: PASS. This verifies the SwiftUI target without UI automation.

- [ ] **Step 6: Commit**

```bash
git add macos/SpeechRailApp/SpeechRailApp/TeleprompterSession.swift macos/SpeechRailApp/SpeechRailApp/TeleprompterStageView.swift macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift
git commit -m "feat: expose teleprompter follow recovery status"
```

---

### Task 6: Contract, documentation, and acceptance matrix

**Files:**
- Modify: `docs/developers/macos-app-teleprompter.md`
- Modify: `contracts/realtime-openai.md` only if the implementation changes wire behavior
- Test: existing `tests/test_realtime_openai.py`, `tests/test_realtime_caller_wire.py`, and Swift focused tests

- [x] **Step 1: Run server contract regression**

Run: `uv run --extra dev pytest tests/test_realtime_openai.py tests/test_realtime_caller_wire.py tests/test_itn.py -q --no-cov`
Expected: PASS. If the global coverage gate rejects a focused run, report that separately; do not treat coverage threshold failure as a behavioral test failure.

- [x] **Step 2: Run the complete Swift package tests**

Run: `swift test --package-path macos/SpeechRailApp`
Expected: PASS. Record any pre-existing failures rather than changing unrelated code.

- [x] **Step 3: Update active documentation**

Document the actual behavior and its limits: text-based follow tolerates ASR/ITN variants and short utterances, uses transient diagnostics, and is phrase-level rather than word-timestamp-accurate. Document that full live word-by-word tracking requires a future timestamp/forced-alignment capability and is not promised by this change.

Use the OpenAI production checklist as the acceptance taxonomy: test representative production audio and each target language; include numbers, dates, currency, email addresses, product names, and domain terms; track empty, truncated, and delayed transcripts separately from recognition/edit-distance metrics; and define how the UI revises provisional text when later snapshots correct it.

- [x] **Step 4: Record acceptance evidence**

The release report must separate:
- deterministic fake-event tests;
- server contract tests;
- Swift package and App-target builds;
- unverified real-microphone, real-ASR, visual, and long-run behavior.

Do not claim acoustic quality, latency, or live follow acceptance from unit tests or `/readyz=200`.

- [ ] **Step 5: Commit documentation only when behavior is verified**

```bash
git add docs/developers/macos-app-teleprompter.md contracts/realtime-openai.md
git commit -m "docs: define teleprompter follow closed-loop limits"
```

## Best-Practice Research Findings

**Retrieval date:** 2026-09-24. External pages and release metadata were fetched from their public sources; repository metadata and release timestamps are reported as observed, not as proof of quality.

| Source | Evidence retrieved | Applicability to SpeechRail |
|---|---|---|
| [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription) | Official guidance says streaming returns incremental deltas and a final transcript after committing an audio turn; delta text can be revised; completion ordering across turns is not guaranteed; use `item_id` to reconcile. The production checklist calls for representative production audio, language coverage, numbers/dates/currency/email/product/domain evaluation, and separate tracking of empty, truncated, and delayed transcripts. | Adopt the event semantics and acceptance taxonomy. Do not copy its `gpt-live-transcribe` 24 kHz/client-VAD configuration into SpeechRail; local `contracts/realtime-openai.md` remains authoritative for the 16 kHz/server-VAD/current-only subset and the SpeechRail snapshot extension. |
| [Apple Speech documentation](https://developer.apple.com/documentation/speech) | Apple exposes live/prerecorded speech recognition, alternative interpretations, confidence levels, time-coded input, and a separate VAD module. | Relevant to a possible future native fallback or confidence source, but not a current replacement for the shared SpeechRail service. Do not add Apple Speech in this change. |
| [WhisperX](https://github.com/m-bain/whisperX), release [v3.8.6](https://github.com/m-bain/whisperX/releases/tag/v3.8.6) published 2026-05-25 | Word-level timestamps are produced with wav2vec2 forced alignment. The project explicitly says raw Whisper timestamps are utterance-level and can be off by seconds; VAD is a separate preprocessing stage; out-of-vocabulary numeric strings can fail to align. | Confirms that word-level cursor timing needs acoustic alignment and language-specific models. Keep this plan phrase-level; do not infer exact word timing from text similarity. |
| [stable-ts](https://github.com/jianfch/stable-ts) | Describes cross-attention + dynamic-time-warping word timestamps, VAD/silence adjustment, regrouping, and word location/refinement. Its tagged release metadata is old (2.0.0, 2023-03-17) while the repository has 2026 activity, so use it as an algorithm reference only. | Supports a future timestamp-stabilization layer with hysteresis and silence/gap adjustment. Do not add the package to the Swift app or treat its old release as current production guidance. |
| [PyTorch TorchAudio forced alignment tutorial](https://pytorch.org/audio/stable/tutorials/forced_alignment_tutorial.html) | The tutorial's alignment pattern is: frame-wise label probabilities → trellis → most likely path. It points to `torchaudio.functional.forced_align` and notes TorchAudio APIs are transitioning toward TorchCodec. | Use the trellis/path idea if a future ASR/CTC adapter exposes emissions. Do not adopt the deprecated API surface now. |
| [CTC-Segmentation](https://github.com/lumaku/ctc-segmentation), [paper](https://arxiv.org/abs/2007.09127) | The package aligns transcript tokens to CTC probabilities with dynamic programming and returns utterance start/end/confidence. It is explicitly not standalone: it needs a neural network with CTC output. | A future word/phrase timing lane should be gated on available CTC emissions or forced-alignment output. Text-only final transcripts cannot provide those timings. |
| [Montreal Forced Aligner](https://github.com/MontrealCorpusTools/Montreal-Forced-Aligner), release [v3.4.2](https://github.com/MontrealCorpusTools/Montreal-Forced-Aligner/releases/tag/v3.4.2) published 2026-08-20 | MFA performs forced alignment with Kaldi and cites *Montreal Forced Aligner and the state of speech-to-text alignment in 2026* (Interspeech 2026). | Use as the benchmark/implementation reference for a future offline or local acoustic alignment lane. It is not a reason to add a Kaldi/Conda dependency to the current macOS follow path. |
| [NeMo-text-processing](https://github.com/NVIDIA/NeMo-text-processing) | Provides text normalization and inverse text normalization with grammar/WFST customization and production-oriented pipelines. | Supports a bounded, deterministic ITN-equivalence layer with explicit grammar tests. Do not introduce the full Python/WFST runtime into the Swift client. |
| [WeTextProcessing](https://github.com/wenet-e2e/WeTextProcessing), release [v1.2.0](https://github.com/wenet-e2e/WeTextProcessing/releases/tag/v1.2.0) published 2026-06-10 | Chinese TN/ITN tooling exposes configurable rules, `enable_0_to_9`, cache invalidation by rule/configuration fingerprint, and examples for `二点五` / `2.5`. | Supports parity fixtures and explicit rule boundaries for Chinese numerals. The current SpeechRail `apply_light_itn` remains the runtime source of truth; mirror its tested subset rather than importing a heavyweight dependency. |
| [OpenAI Whisper](https://github.com/openai/whisper), release [v20250625](https://github.com/openai/whisper/releases/tag/v20250625) | The README describes multilingual ASR and language-dependent WER/CER performance; Whisper's native timestamps are not the target word-level alignment mechanism. | Require Chinese and representative domain evaluation. Do not use Whisper's utterance timestamps as teleprompter cursor truth. |

## Research-Driven Plan Refinements

1. **Partial text is provisional by contract.** `speechrail.transcription.snapshot` must remain revisioned replacement text. The UI may preview progress, but `completed` is the confirmation boundary; the controller must reconcile by `item_id` and tolerate out-of-order completions.
2. **No word-level promise in this iteration.** OpenAI live transcription does not return word timestamps or confidence, and WhisperX/CTC/MFA show that reliable word timing requires acoustic forced alignment. The current plan therefore targets phrase/character-range follow and records word-level tracking as a separate capability requiring a timestamp/CTC contract.
3. **ITN parity beats a second general normalizer.** Extend the Swift canonicalizer only for the tested server ITN subset and mirror `tests/test_itn.py` cases. If broader normalization is later required, evaluate NeMo/WeTextProcessing offline and record the rule/version boundary before exposing it to runtime.
4. **Thresholds become policy, not hidden constants.** The follow controller uses injectable policy values and records only aggregate diagnostics. Tuning must use representative Chinese/English audio and the OpenAI production checklist, not synthetic exact matches.
5. **Latency and accuracy are separate acceptance dimensions.** The current `chunk_duration_ms=500` is a latency-biased starting point. Report partial age, final age, empty/truncated/delayed counts, and match recovery separately from alignment correctness.

## Self-Review

- The plan covers canonicalization, aligner admission, follow-state recovery, wire closure, UI feedback, and documentation.
- Every implementation task has a failing-test step, concrete interfaces, and a verification command.
- The plan intentionally does not promise word-level timing; it leaves that as an explicit future capability boundary.
- The plan does not authorize UI automation, real microphone use, service/model changes, installation, publishing, or deletion.
