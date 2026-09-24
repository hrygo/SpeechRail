# Model Store Closed Loop and Q4 Retirement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Ensure local model status, preparation, verified reuse, and download all resolve one `app_home/models` root, and retire only the unused Q4 artifacts and their exact local directories.

**Architecture:** Add one shared model-root resolver used by preparation, inspection, and disk accounting. Let preparation adopt an existing artifact only after verifying every locked manifest file, then atomically write the current registry entry; otherwise retain the existing staged-download and verified-publication transaction. Remove the two unused Q4 artifacts from the catalog source and generated asset, preserve Q8/BF16 profiles, and move only the exact Q4 data directories to Trash after validation.

**Tech Stack:** Python 3.12, Pydantic catalog models, `uv`, pytest, JSON catalog generator, Swift/Foundation only if needed for recoverable macOS Trash movement.

**Spec:** `docs/superpowers/specs/2026-09-24-model-store-closed-loop.md`

## Global Constraints

- Python `>=3.12,<3.13`; use `uv` and PEP 621.
- Canonical model root is `<resolved app_home>/models`; preserve loopback-only service behavior and public payload schemas.
- No model downloads, model loading, service restart, UI automation, or release as part of implementation or acceptance.
- Retire only `asr-0.6b-q4` and `tts-0.6b-custom-q4`; preserve all Q8/BF16 artifacts and current profiles.
- Local cleanup is limited to the two exact Q4 directories and exact Q4-only registry references; never sweep `.releases`, caches, or unknown directories.
- Preserve existing unrelated working-tree changes; do not pull/rebase the branch or edit files outside this plan's write set.

## Review Focus

1. **App-home paths containing spaces:** storage, integrity checks, and disk totals still resolve the same `<app_home>/models`; pin this in Task 1.
2. **Verified but unregistered snapshot:** reuse only after the active catalog manifest fully verifies every file, then register it without a downloader call; pin this in Task 2.
3. **Missing or digest-mismatched files:** fall back to staged download and never mark the partial destination ready; preserve existing rollback behavior in Task 2 tests.
4. **Path escape or symlinked model root:** retain existing fail-closed path validation and symlink policy; add/retain a regression assertion in Task 1.
5. **Q4 cleanup boundary:** remove no Q8/BF16 directories or mixed release snapshots; verify exact targets before Trash movement in Task 4.

---

### Task 1: Centralize model-root resolution and align status accounting

**Files:**
- Modify: `src/speechrail/service/model_store.py`
- Modify: `src/speechrail/service/model_commands.py`
- Test: `tests/test_model_store.py`
- Test: `tests/test_model_commands.py`

**Interfaces:**
- Produce `model_store_root(app_home: Path) -> Path`, which validates/resolves the app home using the existing `_resolve_app_home` policy and returns its `models` child.
- `prepare_models`, `inspect_prepared_artifacts`, and `model_status_payload` must use this resolver rather than independently deriving the model directory.

- [x] **Step 1: Add a failing resolver/status-root test**

```python
app_home = tmp_path / "SpeechRail Home"
assert model_store_root(app_home) == app_home.resolve() / "models"
```

Add a `model_commands` test that creates a small file below this root, calls `model_status_payload`, and asserts `disk.model_bytes` counts that file while artifact checks inspect the same root.

- [x] **Step 2: Run the focused tests and confirm failure**

Run: `uv run --extra dev pytest --no-cov tests/test_model_store.py tests/test_model_commands.py -q`
Expected: the new shared-root test fails because the resolver is not yet used by all stages.

- [x] **Step 3: Implement the shared root helper and use it in each path**

```python
def model_store_root(app_home: Path) -> Path:
    return _resolve_app_home(app_home) / "models"
```

Use the helper for preparation staging/final destinations, inspection destinations, and `model_commands` disk byte totals. Do not add a second environment-variable lookup; keep the existing CLI/app-home resolution authoritative.

- [x] **Step 4: Run focused tests and check traversal/symlink cases**

Run: `uv run --extra dev pytest --no-cov tests/test_model_store.py tests/test_model_commands.py -q`
Expected: PASS; existing path-escape and model-root-symlink protections continue to fail closed.

### Task 2: Adopt fully verified local artifacts instead of downloading again

**Files:**
- Modify: `src/speechrail/service/model_store.py`
- Test: `tests/test_model_store.py`

**Interfaces:**
- `_cache_path` may return an unregistered canonical `models/<artifact.key>` directory only when `_verify_snapshot` confirms the complete active artifact manifest; an exact registered path is reusable only when its source revision, source set, and file manifest match the active artifact; metadata-only model_id/quantization changes with identical content reuse verified bytes.
- If the registry identifies the canonical destination as a prior publication for a different source/content identity, `prepare_models` moves it to the existing `.releases/<operation_id>/<artifact.key>` backup before download, restores it on failure/cancellation, and updates historical registry paths only after successful publish. Public payload shapes remain unchanged.

- [x] **Step 1: Add the failing orphan-adoption test**

Use the existing `_prepare`, `TrackingDownloader`, fixture catalog, and runtime lock. Prepare once to create a valid snapshot, remove only `state/model-preparations.json`, then prepare again:

```python
downloads_before = len(downloader.streams)
await _prepare(tmp_path, catalog, lock, downloader)
assert len(downloader.streams) == downloads_before
```

Also assert the adopted preset resolves through `resolve_prepared_models` after the second prepare. Add a neighboring digest-mismatch case proving it still downloads and verifies a replacement. Extend the revision-mismatch test with a downloader assertion that the previous registered destination has already moved to `.releases` before the fetch, then force a hash/size failure and assert the original bytes are restored and registry paths remain unchanged.

- [x] **Step 2: Run the focused test and confirm the regression**

Run: `uv run --extra dev pytest --no-cov tests/test_model_store.py -q -k 'orphan or unregistered or mismatch'`
Expected: the unregistered valid snapshot currently triggers downloader calls and fails the new assertion.

- [x] **Step 3: Extend verified cache discovery, not trust-by-existence**

Change `_cache_path` to accept a complete manifest-verified snapshot only when its exact destination has no registry ownership or a matching current artifact identity. For a registry-owned stale destination, move it to the operation release backup before downloading; on any transfer, verification, or cancellation failure restore it and leave the registry unchanged. On successful publication update previous registry paths to the backup before storing the new entry. Keep symlink rejection, safe paths, and atomic publication.

- [x] **Step 4: Run cache, mismatch, failure, cancellation, and rollback regression tests**

Run: `uv run --extra dev pytest --no-cov tests/test_model_store.py -q`
Expected: PASS, including existing repeat-prepare, shared-cache, hash-mismatch, cancellation, and publication-rollback tests.

### Task 3: Retire Q4 artifacts from source catalog and current docs

**Files:**
- Modify: `tools/model-catalog.metadata.json`
- Modify: `src/speechrail/assets/model-catalog.json` (regenerate; do not hand-edit independently)
- Modify: `tools/fetch_catalog_artifacts.py`
- Modify: `docs/operations/capability-quality-acceptance.md`
- Modify: `docs/decisions/0015-tier-user-positioning-and-precision-policy.md`
- Test: `tests/test_model_catalog_builder.py`
- Test: `tests/test_model_commands.py`

**Interfaces:**
- The active model catalog no longer advertises `asr-0.6b-q4` or `tts-0.6b-custom-q4`; all four profile IDs and their current Q8/BF16 mappings remain intact.

- [x] **Step 1: Add a failing catalog assertion**

```python
catalog = load_catalog()
keys = {artifact.key for artifact in catalog.artifacts}
assert "asr-0.6b-q4" not in keys
assert "tts-0.6b-custom-q4" not in keys
assert {preset.id for preset in catalog.presets} == {"light", "balanced", "quality", "extreme"}
```

Assert the existing light/balanced/quality profile mappings remain Q8 and the extreme mapping remains BF16.

- [x] **Step 2: Run catalog tests and confirm the expected failure**

Run: `uv run --extra dev pytest --no-cov tests/test_model_catalog_builder.py tests/test_model_commands.py -q`
Expected: fail because the production catalog still contains the two Q4 entries.

- [x] **Step 3: Remove only the two Q4 metadata/source entries and regenerate**

Delete the two Q4 records from `tools/model-catalog.metadata.json` and the matching `NEW` entry from `tools/fetch_catalog_artifacts.py`. Regenerate the packaged catalog with:

```bash
uv run python tools/build_model_catalog.py tools/model-catalog.metadata.json --output src/speechrail/assets/model-catalog.json
```

Update the current acceptance summary so it records the historical Q4 evaluation while stating that those artifacts are now retired. Do not rewrite the dated 2026-09-11 historical measurement report.

- [x] **Step 4: Run catalog generation and validation tests**

Run: `uv run --extra dev pytest --no-cov tests/test_model_catalog_builder.py tests/test_model_commands.py tests/test_model_presets.py -q`
Expected: PASS; generated catalog validates and no current profile references Q4.

### Task 4: Move only installed Q4 model directories to Trash and verify

**Files / local data:**
- Local data: `~/Library/Application Support/SpeechRail/models/asr-0.6b-q4`
- Local data: `~/Library/Application Support/SpeechRail/models/tts-0.6b-custom-q4`
- Local state: `~/Library/Application Support/SpeechRail/state/model-preparations.json` only if a current record explicitly references either retired key

**Interfaces:**
- No new public interface. Cleanup is a one-time, exact-path migration after code and catalog tests pass.

- [x] **Step 1: Recheck exact local targets and current registry references**

Use read-only listing and JSON inspection to confirm each target is a real directory under the canonical model root, not a symlink, and identify any Q4-only registry references. Abort local cleanup if app home or target identity differs from the plan.

- [x] **Step 2: Move only present exact Q4 directories to macOS Trash**

Use a recoverable `FileManager.trashItem(at:resultingItemURL:)` operation for each confirmed exact target. Do not use `rm`, wildcards, recursive sweeps, or touch `.releases`, Q8, BF16, or cache directories. If Trash movement fails, leave the directory untouched and report it.

- [x] **Step 3: Remove only confirmed Q4 artifact references from the registry, atomically**

If the fresh registry contains either retired artifact key, preserve every unrelated prepared record and atomically remove only those exact artifact entries; if no Q4 reference exists, do not rewrite the registry.

- [x] **Step 4: Verify exact cleanup outcome**

Re-list both target paths, confirm they are absent from the live model root, verify Q8/BF16 directories remain, and re-run read-only managed `model status`. Do not restart the service or trigger model preparation.

### Task 5: Integrated verification and review

**Files:** all implementation, test, and current-document files listed above.

- [x] Run: `uv run --extra dev pytest --no-cov tests/test_model_store.py tests/test_model_commands.py tests/test_model_catalog_builder.py tests/test_model_presets.py -q`
Expected: all focused offline tests pass without downloads, model loading, or service operations.

- [x] Run: `git diff --check` and inspect only this plan's intended diff; confirm no Q8/BF16 catalog entries or mappings changed and no unrelated edits were overwritten.
- [x] Review the implementation against the spec and current working-tree changes before reporting completion. Do not commit, push, publish, or run UI automation unless separately requested.

## Self-review

- Spec coverage: canonical path helper and disk accounting are Task 1; manifest-verified adoption and registration are Task 2; catalog/source/docs retirement is Task 3; exact local Q4 cleanup is Task 4; offline regression and diff verification are Task 5.
- No placeholders: each task names its files, interfaces, tests, commands, expected outcomes, and bounded cleanup targets.
- Type consistency: the shared helper is `model_store_root(app_home: Path) -> Path`; callers supply the existing absolute `app_home` and derive one `models` root.
- Review focus cases map to explicit tests/guards in Tasks 1, 2, and 4.
