# Model Store Location and Preparation Closed Loop

- Date: 2026-09-24
- Status: Proposed — awaiting user review
- Scope: SpeechRail local model storage, inspection, download/reuse, and removal of unused Q4 artifacts

## Goal

Make model storage, status inspection, download, integrity verification, registration, and reuse operate on one canonical local model root. Remove only the unused Q4 artifacts; retain Q8 and BF16 artifacts and all currently supported profiles.

## Observed baseline

- The managed app home defaults to `~/Library/Application Support/SpeechRail`; model files are under its `models/` directory.
- On 2026-09-24, the managed `model status` command reported 25.3 GiB on disk. `asr-1.7b-bf16` had all 10 files and `integrity=verified`, but state `invalid`; its matching preparation record was absent. The model-store cache reuse path requires both matching registry metadata and verified files, so a physically present, valid snapshot can be downloaded again instead of adopted.
- Existing Q4 catalog artifacts are `asr-0.6b-q4` and `tts-0.6b-custom-q4`. Current `light`, `balanced`, and `quality` profiles use Q8 artifacts; those must remain unchanged.

## Design

1. **One canonical root:** resolve the effective `app_home` once at the command/control boundary and derive the model root as `<app_home>/models`. Pass this resolved location through inspection, preparation, download staging, integrity cache, registry, publication, and disk-usage reporting. No independent model-root defaults or fallback scans are allowed.
2. **Closed preparation loop:** inspect the exact artifact directory against the active locked runtime-file manifest. Treat only the artifact-root `README.md` as non-runtime documentation and exclude it from integrity checks, file counts, and registry-content matching; nested `README.md` files remain runtime files. If every expected runtime file is present and matches its locked digest, register/adopt the artifact in the preparation registry and reuse it without network transfer. If files are missing or mismatched, download under the same root's staging directory, verify the complete snapshot, atomically publish it, and update the registry. Failed or canceled transfers never become usable artifacts.
3. **Truthful status:** report the total bytes in the canonical model root separately from per-artifact usability. A directory presence alone must not imply readiness; a complete digest-verified local snapshot may be adopted without an unnecessary second transfer.
4. **Q4-only retirement:** remove the two unused Q4 artifacts from source catalog metadata, generated catalog, catalog-generation/validation tests, and current documentation. Preserve Q8 and BF16 artifacts and all four current profile definitions. Remove only the exact local Q4 artifact directories and their obsolete registry references. Do not sweep `.releases`, unrelated caches, or unknown directories as part of this change.
5. **No public API change:** keep REST/control payload schemas stable unless implementation inspection finds a necessary incompatibility; any such incompatibility must be brought back for review before implementation.

## Acceptance criteria

- Status and prepare resolve the same canonical root when given the same app home, including paths containing spaces and the supported environment override.
- A complete runtime-manifest-matching but unregistered artifact is adopted/registered and causes zero downloader calls.
- An artifact-root `README.md` is ignored only for runtime integrity, status counts, and registry-content matching; nested `README.md` files, weights, configs, and tokenizers remain strictly checked.
- Missing or digest-mismatched files are downloaded only to staging under the canonical root; successful output is verified before atomic publication and registry update.
- Cancellation/failure leaves no partial artifact reported as ready and preserves any prior valid snapshot.
- Status disk totals and artifact checks inspect the same resolved root.
- Q4 entries are absent from the active catalog and generated catalog; Q8/BF16 entries and current profile mappings remain intact.
- Local cleanup is limited to `models/asr-0.6b-q4` and `models/tts-0.6b-custom-q4` and corresponding Q4-only registry references; no mixed release snapshots are deleted.
- Focused offline tests cover path consistency, adoption, download fallback, publication rollback, and Q4 catalog validation. No real download, model load, service restart, UI automation, or release is part of acceptance.

## Risks and recovery

- Q4 local directories are removable model data. Before removal, verify their exact paths and move them to Trash or another recoverable location where supported; do not use a broad glob. Q8 data and release snapshots are out of scope.
- Registry changes must be atomic and preserve unrelated prepared entries. If migration fails, leave model files untouched and report the exact inconsistency.
- Reverting the code/catalog change restores Q4 discoverability, but not deleted Q4 bytes unless the recoverable move remains available.
