# SDD ledger — plan: docs/superpowers/plans/2026-09-21-voice-design-base-mcp-reliability.md

Execution scope: implement docs/superpowers/specs/2026-09-21-speechrail-mcp-complete-reliability-design.md in the current worktree. Existing macOS App and unrelated documentation changes are preserved.

Ruling: do not create commits during this run — the repository instructions require explicit user authorization before committing; keep changes reviewable in the current worktree.

Pre-flight: shared interfaces — A produces structured TTS errors consumed by B/C/D; B produces shared request validation consumed by REST/jobs/MCP; C changes effective voice projection consumed by D/E; D defines the MCP tool set and manifest consumed by E/F/G; E produces packaged skill resources consumed by F/G.

Task A: done — Base startup/warmup now skips `default` for clone-only Base; worker semantic codes cross the IPC boundary as `TtsBackendError` and HTTP/quality classification no longer parses stderr text. Focused Qwen3-TTS, quality, speech API and profile tests pass.
Task B: done — shared language/parameter policy is applied at the Qwen adapter, REST, MCP, and durable-job boundaries; focused REST/MCP/job/Qwen tests pass.
Task C: done — capability and legacy voice projections now separate reference/output validation, persist independent quality-run output evidence with revision/model binding, mark stale/unrun output as not production-ready, and retain structured probe failure classification. `allow_unverified` and `require_output_pass` are enforced consistently at REST, MCP, and job boundaries.
Task D: done — MCP now publishes the original nine tools plus six voice/job/result tools, three resources, strict synth/job schemas, revision-aware validation, local artifact delivery, and durable job idempotency.
Task E: done — wheel-packaged `speechrail` skill, manifest and routed references cover all 15 tools and 3 resources; skill validator and package-resource tests pass.
Task F: done — `speechrail agents install|status|update|uninstall` installs the packaged skill and Codex MCP entry with atomic writes, receipts, drift/conflict detection, safe uninstall, and explicit session-restart state.
Task G: done — OpenAPI, active MCP architecture/user docs and server instructions now describe
the 15-tool/3-resource surface, output validation response variants, job artifact media types,
strict parameters, and the Codex installer. Ruff, mypy, `git diff --check`, wheel inspection,
skill validation, and full pytest passed (`2108 passed, 1 skipped, 1 warning`, coverage
`81.15%`).

Managed runtime acceptance (2026-09-21): the latest wheel was installed through the managed
installer with `downloaded_bytes=0`, quality profile was retained, and the old release was
preserved. `runtime/current` now points to the wheel release ending `c9d3eaebd488`; controller
start succeeded, `/health` and `/readyz` returned 200, and the active PID was 56072. The existing
clone `qingfeng_integrity_female_20260920` returned HTTP 200 and 153600 bytes for a real Base
request at `speed=1.0`, with request ID `req_747238fb10294d998605c330702240e6`. Negative gates
also behaved as designed: non-default clone speed returned `clone_speed_unsupported`, while
`require_output_pass` returned `voice_not_production_ready` before output validation. No Codex
client config was written, no model was downloaded, no commit was created, and no formal quality
benchmark was run.
