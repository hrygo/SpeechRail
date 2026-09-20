# SDD ledger — plan: docs/superpowers/plans/2026-09-20-stateless-speech-plane-caller-orchestration.md

Setup: Native inline execution selected earlier by the user. Worktree is the shared SpeechRail checkout on branch main; the user explicitly authorized implementation and acceptance in the current goal.

Setup: Spec `docs/superpowers/specs/2026-09-20-stateless-speech-plane-caller-orchestration-design.md` and plan `docs/superpowers/plans/2026-09-20-stateless-speech-plane-caller-orchestration.md` were read. Baseline commit is `c6549384`.

Ruling: The documented executing-plans helper scripts and fresh reviewer package are unavailable in this environment. Use this ledger, direct git checks, and a separate final self-review; report that limitation.

Ruling: The user explicitly requested completion and acceptance, so automated Python/Swift pure tests, static checks, build checks, and fake loopback validation are authorized. UI automation remains excluded because the project hard constraint requires a separate explicit UI-automation request.

Pre-flight: Task 1 defines the canonical Realtime client event vocabulary and Swift factories; Task 2 consumes it in Python parser/state-machine tests; Task 3 consumes the same names in Native client code; Task 4 consumes the resulting capability names in MCP; Tasks 5–6 consume all implementation outputs for documentation and release evidence. Shared interfaces are intentionally sequential and will be edited serially.

Tasks:
- Task 1: complete — current-only parser, session/TTS contract factories, strict rejection matrix, and connection-scoped TTS request IDs implemented.
- Task 2: complete — Python Realtime, VAD, diarization, admission, benchmark and caller-wire tests migrated to current-only semantics; focused suites pass.
- Task 3: complete — Native `RealtimeASRClient`, `AssistantSession`, ControlKit factories and pure Swift contract tests use caller-owned LLM/TTS queue/barge-in.
- Task 4: complete — MCP `describe().realtime` reports caller orchestration, `server_llm=false`, `conversation_state=false`; instructions explicitly exclude Realtime handles and server-side assistant state.
- Task 5: complete — current-only contract, architecture, user, MCP and Native documentation are synchronized; stale active Realtime audit/spec documents are explicitly marked `superseded`.
- Task 6: complete — release metadata is `3.0.0`, examples/benchmarks/tests are migrated, and the implementation passed the authorized verification set below.

Verification evidence (2026-09-20, Asia/Shanghai):
- `uv run --extra dev pytest`: `2072 passed, 1 skipped, 1 warning` in 134.20s; coverage `81.79%`.
- Focused Realtime/capability/MCP suites: passed.
- `uv run --extra dev ruff check src tests`: passed.
- `uv run --extra dev mypy src`: passed for 124 source files.
- `npx @redocly/cli lint contracts/openapi.yaml`: passed.
- `uv run python scripts/check_version_consistency.py`: passed; all locations `3.0.0`.
- `plutil -lint deploy/macos/com.speechrail.plist.example`: passed.
- `xcodebuild` selected pure `SpeechRailAppTests` (`RealtimeContractTests`, `LLMProviderTests`, `AgentCoreTests`): passed.
- `scripts/macos_app_build.sh --configuration Debug`: `BUILD SUCCEEDED` for `SpeechRailApp` on arm64/macOS 26.0 target.
- `git diff --check`: passed.

Acceptance boundary: no UI automation, real model/audio smoke, service install, or runtime mutation was executed. The Xcode test scheme is `SpeechRailApp`; the plan's stale `SpeechRailMacControlTests` name was corrected by using the actual scheme. Swift 6.4 build blockers found during acceptance were fixed minimally (`Codable`/temporary container encoding, testability, `JSONValue` pattern matching, and `@retroactive` conformance).
