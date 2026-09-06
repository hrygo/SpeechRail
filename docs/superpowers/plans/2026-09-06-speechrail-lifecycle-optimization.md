# SpeechRail Lifecycle Optimization Implementation Plan

> **For agentic workers:** Execute this plan task-by-task with test checkpoints.

**Goal:** Prevent stale or unmanaged SpeechRail processes from being mistaken for a successful profile switch, and make release cutovers validate the exact prepared runtime.

**Architecture:** Keep the single per-port `flock` as the source of truth, add non-secret owner metadata for safe diagnostics, and route controller stop/start through the same bounded stop, exact-kill, and lock-release protocol. Tighten the existing public smoke probe using the model metadata already exposed by `/v1/models`; do not change the backwards-compatible OR semantics of `/readyz`.

**Tech Stack:** Python 3.12, FastAPI, `fcntl.flock`, macOS LaunchAgent, pytest, `uv`.

**Spec:** Current lifecycle rules in `.agents/skills/speechrail-local-deploy/` and `.agents/skills/speechrail-release/`.

## Global Constraints

- Keep one SpeechRail service process and one ASGI worker.
- Preserve short graceful stop followed by exact process-group `SIGKILL`.
- Never use `pkill`, `killall`, broad process matching, or secrets in owner metadata.
- Keep existing public `/readyz` compatibility; strict capability checks belong to the release smoke probe.
- Do not modify unrelated working-tree changes.

### Task 1: Protect lifecycle recovery from status failures

**Files:**
- Modify: `src/speechrail/runtime/server_lock.py`
- Modify: `src/speechrail/service/profile_switch.py`
- Test: `tests/test_server_lock.py`
- Test: `tests/test_profile_service_controller.py`

- [ ] Add tests for owner metadata and a held port lock when `launchctl status` is unavailable.
- [ ] Implement owner metadata read/write and exact validated owner resolution.
- [ ] Make controller stop fail closed or exact-kill a validated owner instead of returning solely because status failed.
- [ ] Run focused lifecycle tests.

### Task 2: Tighten profile smoke identity

**Files:**
- Modify: `src/speechrail/service/profile_smoke.py`
- Test: `tests/test_profile_smoke.py`

- [ ] Add failing tests for missing profile, wrong artifact, wrong variant, and incomplete readiness.
- [ ] Require the prepared profile and both prepared model identities in smoke responses.
- [ ] Keep fresh TTS regeneration only for empty ASR transcripts.
- [ ] Run focused smoke tests.

### Task 3: Make managed install refuse an active service

**Files:**
- Modify: `tools/install_macos.py`
- Test: `tests/test_installer.py`

- [ ] Add an injectable per-port lock directory for deterministic installer tests.
- [ ] Check the configured service port before switching `runtime/current` and before enabling the service.
- [ ] Keep existing fresh-install behavior when no service owns the port.
- [ ] Run installer tests.

### Task 4: Align durable SOPs

**Files:**
- Modify: `.agents/skills/speechrail-zero-setup/SKILL.md`
- Modify: `docs/operations/README.md`
- Modify: `docs/operations/operations-runbook.md`
- Modify: `docs/operations/runtime-evaluation.md`

- [ ] Remove raw `service disable/enable/restart` as the release cutover procedure.
- [ ] Point operators to the controller-backed lifecycle and explicit downtime model.
- [ ] State that `install_managed` must run only with the port lock free.

### Task 5: Verify and save a release checkpoint

- [ ] Run focused tests, full pytest, ruff, mypy, OpenAPI lint, plist lint, and `git diff --check`.
- [ ] Review the diff for unrelated changes and secrets.
- [ ] Commit only the lifecycle optimization files in an atomic commit.

