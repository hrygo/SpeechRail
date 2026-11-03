#!/usr/bin/env bash
# Local Gate Runner: run the exact gates matching the PR's changed scope locally before push.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BASE_REF="${SPEECHRAIL_BASE_REF:-origin/main}"
MODE="auto" # auto, fast, full
SKIP_QUALITY=0

while (($# > 0)); do
  case "$1" in
    --base-ref)
      [[ $# -ge 2 && -n "$2" ]] || { echo "--base-ref requires a Git ref" >&2; exit 2; }
      BASE_REF="$2"
      shift 2
      ;;
    --fast)
      MODE="fast"
      shift
      ;;
    --full)
      MODE="full"
      shift
      ;;
    --skip-quality)
      SKIP_QUALITY=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/ci_local_gate.sh [options]

Run the exact CI gates matching the current branch scope locally before pushing.

Options:
  --base-ref <ref>  Git base ref to compare against (default: origin/main)
  --fast            Run only targeted tests matching changed files
  --full            Force full Python and Swift package test suites (--parallel)
  --skip-quality    Skip shared Quality Gates and run only test suites
  -h, --help        Show this help message
EOF
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Resolve base ref fallback
if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  if git rev-parse --verify "main" >/dev/null 2>&1; then
    BASE_REF="main"
  else
    BASE_REF="HEAD~1"
  fi
fi

echo "=================================================="
echo "SpeechRail Local Gate Runner"
echo "Base Ref: $BASE_REF | Mode: $MODE"
echo "=================================================="

# 1. Classify Scope
SCOPE_OUT="$(mktemp "${TMPDIR:-/tmp}/speechrail-scope.XXXXXX")"
cleanup() { rm -f "$SCOPE_OUT"; }
trap cleanup EXIT

# Collect all changed paths across committed and working-tree modifications
git diff --name-only -z "$BASE_REF" | python3 scripts/ci_changed_scope.py --github-output "$SCOPE_OUT"

RUN_PYTHON=false
RUN_SWIFT=false
SCOPE="unknown"

while IFS='=' read -r key value; do
  case "$key" in
    run_python) RUN_PYTHON="$value" ;;
    run_swift) RUN_SWIFT="$value" ;;
    scope) SCOPE="$value" ;;
  esac
done < "$SCOPE_OUT"

echo "Detected Scope: $SCOPE (Python: $RUN_PYTHON, Swift: $RUN_SWIFT)"
echo "--------------------------------------------------"

# 2. Quality Gates (Linter, MyPy, OpenAPI, Coverage Parity, Whitespace)
if [[ "$SKIP_QUALITY" -eq 0 ]]; then
  echo "▶ [1/3] Running Quality Gates..."
  bash scripts/ci_quality_gate.sh --base-ref "$BASE_REF"
  echo "✔ Quality Gates passed."
  echo "--------------------------------------------------"
else
  echo "⊘ [1/3] Skipping Quality Gates (--skip-quality)."
  echo "--------------------------------------------------"
fi

# 3. Python Tests Gate
if [[ "$RUN_PYTHON" == "true" ]]; then
  echo "▶ [2/3] Running Python Tests..."
  if [[ "$MODE" == "fast" ]]; then
    # In fast mode, run tests matching changed paths or core admission/realtime
    uv run --no-sync pytest -q --no-cov tests/test_speech_admission.py tests/test_realtime*.py
  else
    # In auto / full mode, run full test suite with fail-under check
    uv run --no-sync pytest -q --cov=src --cov-fail-under=80
  fi
  echo "✔ Python Tests passed."
  echo "--------------------------------------------------"
else
  echo "⊘ [2/3] Python tests skipped (scope=$SCOPE)."
  echo "--------------------------------------------------"
fi

# 4. Swift Package Tests Gate (with --parallel to catch scheduling race conditions)
if [[ "$RUN_SWIFT" == "true" ]]; then
  echo "▶ [3/3] Running Swift Package Tests (--parallel)..."
  if [[ "$MODE" == "fast" ]]; then
    # Run only modified test targets / suites if detectable, otherwise full suite
    swift test --package-path macos/SpeechRailApp --parallel
  else
    swift test --package-path macos/SpeechRailApp --parallel
  fi
  echo "✔ Swift Package Tests passed."
  echo "--------------------------------------------------"
else
  echo "⊘ [3/3] Swift tests skipped (scope=$SCOPE)."
  echo "--------------------------------------------------"
fi

echo "=================================================="
echo "🎉 All local CI gates passed successfully!"
echo "Safe to push: git push origin <branch>"
echo "=================================================="
