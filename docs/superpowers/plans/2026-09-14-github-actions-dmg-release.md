# GitHub Actions Unsigned DMG Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 优化 SpeechRail 的 GitHub Actions 质量门禁，并在匹配版本 tag 时发布 arm64 unsigned macOS DMG、当前构建平台 wheel 和 SHA-256 清单。

**Architecture:** CI workflow 同时作为普通 CI 和 reusable workflow，集中维护 Python 质量/测试/wheel 门禁。Release workflow 先复用 CI，再并行构建 macOS App DMG，最后由唯一的写权限 job 下载本次 run 的 artifact 并幂等发布。

**Tech Stack:** GitHub Actions、`uv`、Python 3.12、Xcode 26/macOS 26 arm64 runner、Bash、`hdiutil`、GitHub CLI。

**Spec:** `docs/superpowers/specs/2026-09-14-github-actions-dmg-release-design.md`

## Global Constraints

- Python 固定为 `>=3.12,<3.13`，使用 `uv` 与 `uv.lock`。
- `SpeechRailApp` GUI target 使用 `MACOSX_DEPLOYMENT_TARGET=26.0`、`ARCHS=arm64`。
- App 发布阶段保持 unsigned，不添加 Developer ID、notarization 或 Apple Secrets。
- GitHub Actions 的普通 CI 只拥有 `contents: read`；只有最终 `publish` job 拥有 `contents: write`。
- 不下载模型、不访问远程音频、不写入 `.env`、凭据、用户路径或真实运行时数据。
- 保留工作树中已有的 UI、配置和文档改动，不覆盖或重置它们。

---

### Task 1: Add release tag validation and DMG packaging primitives

**Files:**
- Create: `scripts/verify_release_tag.py`
- Create: `scripts/macos_app_create_dmg.sh`
- Create: `tests/test_verify_release_tag.py`
- Create: `tests/test_macos_app_create_dmg.py`

**Interfaces:**
- `verify_release_tag.py --root <repo> --tag <tag>` exits 0 only when `<tag>` equals `v` + `[project].version`.
- `macos_app_create_dmg.sh --app-path <SpeechRail.app> --version <version> --output-path <file.dmg>` validates the bundle/version and emits a verified unsigned DMG.

- [x] **Step 1: Write failing tests for tag validation and DMG guards.**

  Add tests covering matching/mismatching tags, missing version, missing App bundle, mismatched App bundle version, and non-`.dmg` output paths. The DMG test module is macOS-only because it validates `/usr/bin/plutil`, `PlistBuddy`, `hdiutil`, and `ditto`; portable workflow/script syntax checks cover non-macOS runners.

- [x] **Step 2: Run the focused tests and verify they fail.**

  Run:

  ```bash
  uv run --extra dev pytest tests/test_verify_release_tag.py tests/test_macos_app_create_dmg.py -q
  ```

  Expected: collection or subprocess failures because the new script/test modules do not exist yet.

- [x] **Step 3: Implement the tag validator.**

  Use stdlib `tomllib` to read `[project].version`, accept only an exact `v<version>` tag, print a redacted version/tag comparison, and return a non-zero exit code for missing or mismatching values.

- [x] **Step 4: Implement the unsigned DMG script.**

  Validate explicit arguments, `SpeechRail.app/Contents/Info.plist`, `CFBundleShortVersionString`, output extension and non-existing output. Create a temporary staging directory, copy the bundle with `ditto`, add an `/Applications` symlink, run `hdiutil create -format UDZO`, mount read-only, verify both entries, detach, and clean only the exact temporary directories created by the script.

- [x] **Step 5: Run the focused tests and verify they pass.**

  Re-run the focused pytest command. On macOS, include a positive temporary minimal bundle case that exercises `hdiutil`; on non-macOS, the DMG module is skipped and workflow contract tests remain runnable.

### Task 2: Consolidate Python CI and make it reusable

**Files:**
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Provides a reusable workflow callable from `release.yml`; `package-runner` defaults to `ubuntu-latest` and accepts `macos-26` for the Darwin release wheel.
- Keeps `test` as the Python matrix job and publishes a fixed-name wheel artifact from `package`.

- [x] **Step 1: Add `workflow_call`, `workflow_dispatch`, and `merge_group` triggers without changing existing push/PR scope.**
- [x] **Step 2: Split fast checks into `quality`, retaining locked `uv` setup, Ruff, Mypy, version consistency, OpenAPI lint, explicit diarization contract tests, and whitespace checks.**
- [x] **Step 3: Keep `test` on `ubuntu-latest` and `macos-15` with Python 3.12, `uv sync --locked`, wheel-before-test, and full coverage pytest.**
- [x] **Step 4: Change `macos-app` to `macos-26` and retain Swift package tests, unsigned Xcode UI tests, plist checks, and explicit arm64/macOS 26 toolchain checks.**
- [x] **Step 5: Add `package` after `quality` and the complete `test` matrix; default it to Ubuntu, accept the reusable `package-runner` input, validate wheel contents/version/SHA-256, and require the native diarization worker when the runner is macOS before uploading the artifact.**
- [x] **Step 6: Parse the workflow with a YAML parser and inspect the resulting job dependency/permission structure.**

### Task 3: Build the tag release and publish DMG artifacts

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- `verify-tag` blocks all release jobs on version/tag mismatch.
- `ci` invokes `./.github/workflows/ci.yml` with read-only contents permission.
- `build-app` emits `speechrail-macos-dmg` containing `SpeechRail-<version>-macOS-arm64.dmg`.
- `publish` is the only job with `contents: write` and publishes wheel, DMG, and `SHA256SUMS`.

- [x] **Step 1: Replace the current monolithic release job with `verify-tag`, reusable `ci` (passing `package-runner: macos-26`), `build-app`, and `publish` jobs.**
- [x] **Step 2: Make `build-app` use `macos-26`, checkout with `persist-credentials: false`, build `Release` arm64 with signing disabled, call the DMG script, and upload the artifact.**
- [x] **Step 3: Make `publish` download artifacts from the current run, verify file names against the tag version, produce one combined `SHA256SUMS`, and use `gh release view/create/upload` idempotently.**
- [x] **Step 4: Keep tokens scoped to the publish step and ensure all earlier jobs remain read-only.**
- [x] **Step 5: Validate workflow syntax, shell quoting, `needs` edges, and no remaining `softprops/action-gh-release` reference.**

### Task 4: Document unsigned DMG consumption and CI acceptance

**Files:**
- Modify: `docs/developers/macos-app-release.md`
- Modify: `docs/developers/testing-acceptance.md`

**Interfaces:**
- Developer documentation distinguishes unsigned GitHub DMG artifacts from signed/notarized distribution builds.
- Local and CI commands remain portable and do not expose private paths or credentials.

- [x] **Step 1: Add the unsigned CI DMG flow, artifact naming, arm64/macOS 26 runner choice, and Gatekeeper manual-open note.**
- [x] **Step 2: Add the reusable CI/release acceptance checks and explicitly state that GitHub DMG output is not Developer ID/notarized evidence.**
- [x] **Step 3: Review docs for secrets, absolute private paths, stale runner statements, and contradictions with the release skill.**

### Task 5: Run repository verification and review the isolated diff

**Files:**
- Verify only the files listed in Tasks 1–4; do not stage or rewrite unrelated existing changes.

- [x] **Step 1: Run focused script tests, workflow YAML/actionlint checks, and shell syntax checks.**
- [x] **Step 2: Run `uv run --extra dev pytest`, Ruff, Mypy, OpenAPI lint, `git diff --check`, and wheel content checks as available locally.** The full suite has one pre-existing failure in `tests/test_operator_docs.py` caused by unrelated modified skill files; all 1777 tests outside that check pass with the coverage gate.
- [x] **Step 3: Inspect `git diff --stat`, `git diff --name-only`, and each changed file for permissions, secret leakage, output naming, and fallback behavior.**
- [x] **Step 4: Report local evidence separately from GitHub-only evidence; do not claim a real tag Release or DMG runner execution until GitHub Actions runs it.**
