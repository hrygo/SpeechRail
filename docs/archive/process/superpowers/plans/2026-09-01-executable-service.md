# SpeechRail Executable Service Implementation Plan

> **For agentic workers:** Execute task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a testable `speechrail` executable and macOS user-service lifecycle for one local SpeechRail process.

**Architecture:** Keep the HTTP/model lifecycle unchanged. Add a macOS `launchd` adapter that renders XML with `plistlib`, writes a per-user plist atomically, and invokes `launchctl` through a narrow subprocess seam. The CLI delegates `serve` to the existing ASGI app and delegates service lifecycle commands to this adapter.

**Tech Stack:** Python 3.12; standard-library `argparse`, `pathlib`, `plistlib`, `subprocess`; FastAPI/Uvicorn; pytest.

**Spec:** User-approved 2026-09-01 conversation design: native `speechrail` executable; `LaunchAgent` rather than `LaunchDaemon` for local Apple Silicon/MPS; explicit install/enable lifecycle; no automatic installation, model download, or model activation.

## Global Constraints

- Do not alter REST or Realtime public contracts.
- Support only a macOS user `LaunchAgent`; reject other platforms.
- Run exactly `sys.executable -m speechrail serve`; do not invoke a shell, `uv run`, or multiple ASGI workers.
- Read `.env` from the repository work directory. Never serialize API keys, model paths, audio, or transcripts into the plist.
- Use `ProcessType=Interactive`, restart throttling, and user-owned logs. Do not create a root service or manage WLK.
- Do not overwrite the current documentation-reorganization changes.

---

### Task 1: LaunchAgent adapter

**Files:** Create `src/speechrail/service/__init__.py`, `src/speechrail/service/launchd.py`, and `tests/test_launchd_service.py`.

**Interfaces:** `LaunchAgentDefinition.to_plist() -> bytes`; `LaunchAgentManager.install() -> Path`; lifecycle methods `enable`, `disable`, `restart`, `status`, and `uninstall` that use an injected command runner.

- [ ] Write failing tests asserting XML-safe plist output, absolute paths, current-Python `ProgramArguments`, absence of `EnvironmentVariables`, restart policy, atomic/idempotent install, exact `gui/<uid>` commands, and platform rejection.
- [ ] Run `uv run --extra dev pytest tests/test_launchd_service.py -q --no-cov`; confirm it fails because the adapter is absent.
- [ ] Implement the smallest adapter. Render `Label=com.speechrail`, `ProgramArguments=[python, "-m", "speechrail", "serve"]`, `RunAtLoad=true`, `KeepAlive={"SuccessfulExit": false}`, `ThrottleInterval=10`, `ProcessType="Interactive"`, and explicit stdout/stderr paths with `plistlib`.
- [ ] Re-run the focused suite; commit as `feat: add macos launchagent service adapter`.

### Task 2: Executable CLI

**Files:** Create `src/speechrail/cli.py` and `tests/test_cli.py`; modify `src/speechrail/__main__.py`.

**Interfaces:** `main(argv: Sequence[str] | None = None) -> int`; commands `serve` and `service install|enable|disable|restart|status|uninstall`; omitted command remains backward-compatible with `serve`.

- [ ] Write failing tests with a fake manager: `service install` calls only `install`; lifecycle commands delegate exactly once; `serve` calls Uvicorn with the `Settings` host/port; expected service/config errors return `1` with a redacted stderr message.
- [ ] Run `uv run --extra dev pytest tests/test_cli.py -q --no-cov`; confirm RED.
- [ ] Implement an `argparse` command tree and dependency seam. Do not catch `KeyboardInterrupt`; do not start models during help or service management.
- [ ] Run both focused suites; commit as `feat: add speechrail service cli`.

### Task 3: Templates and documentation

**Files:** Modify `deploy/macos/com.speechrail.plist.example`, `README.md`, `docs/operations/operations-runbook.md`, `docs/operations/runtime-deployment.md`, and `docs/developers/testing-acceptance.md`.

- [ ] Add a failing structural template test that parses the checked-in plist and asserts the same process, restart, and interactive policies as the managed service.
- [ ] Run the focused test and confirm RED because the existing template has unconditional `KeepAlive` and no throttle.
- [ ] Align the template and document portable `speechrail service install`, explicit `enable`, health smoke, `status`, `restart`, `disable`, and `uninstall`. State that install only writes the plist and enabling starts the model process; retain manual `launchctl` only for recovery diagnostics.
- [ ] Run focused tests and `git diff --check`; commit as `docs: document managed speechrail service lifecycle`.

### Task 4: Quality gate

- [ ] Review all changes for secrets, shell interpolation, root service behavior, multiple ASGI workers, and public-contract drift.
- [ ] Run `uv run --extra dev pytest`, `uv run --extra dev ruff check src tests`, `uv run --extra dev mypy src`, `npx @redocly/cli lint contracts/openapi.yaml`, and `git diff --check`.
- [ ] Run `uv run speechrail --help` and `uv run speechrail service --help`; confirm they render without starting a model worker.
- [ ] Commit only corrections required by review/verification.
