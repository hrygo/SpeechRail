#!/usr/bin/env bash
# Shared platform-independent Quality Gates for local checks and GitHub Actions.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BASE_REF=""
while (($# > 0)); do
  case "$1" in
    --base-ref)
      [[ $# -ge 2 && -n "$2" ]] || { echo "--base-ref requires a Git ref" >&2; exit 2; }
      BASE_REF="$2"
      shift 2
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

gate() {
  local name="$1"
  shift
  echo "::group::$name"
  "$@"
  echo "::endgroup::"
}

# Quality checks never consume the native worker. The macOS test/package gate
# builds and tests that artifact separately; do not build it during local sync.
gate "Install locked quality dependencies" \
  env SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD=1 uv sync --locked --extra dev --extra mcp
gate "Code style check (Ruff)" uv run --no-sync ruff check src tests scripts hatch_build.py
gate "Static type check (Mypy)" uv run --no-sync mypy src
gate "Check release version consistency" \
  uv run --no-sync python scripts/check_version_consistency.py
gate "Lint OpenAPI contract" npx --yes @redocly/cli@2.52.1 lint contracts/openapi.yaml
gate "Check OpenAPI path parity" uv run --no-sync python scripts/check_openapi_contract.py
gate "Check user guide contract coverage" \
  uv run --no-sync python scripts/check_user_doc_contract.py
gate "Check MCP tool surface parity" uv run --no-sync python scripts/check_mcp_tool_contract.py
gate "Check macOS test target coverage parity" \
  uv run --no-sync python scripts/check_macos_test_target_coverage.py
gate "Run CI workflow and gate regressions" \
  uv run --no-sync pytest --no-cov tests/test_github_workflows.py tests/test_ci_quality_gate.py \
    tests/test_ci_macos_build.py tests/test_macos_test_target_coverage.py tests/test_ci_changed_scope.py
gate "Run explicit diarization contract regressions" \
  uv run --no-sync pytest --no-cov tests/test_diarization_extensions.py tests/test_diarization_sdk.py

if [[ -n "$BASE_REF" ]]; then
  gate "Check committed patch whitespace" git diff --check "$BASE_REF...HEAD"
fi
gate "Check working tree whitespace" git diff --check
gate "Check staged whitespace" git diff --cached --check
echo "All quality gates passed."
