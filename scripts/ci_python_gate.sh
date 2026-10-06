#!/usr/bin/env bash
# Build one wheel while checkout tests run; wheel tests consume that exact wheel.
set -uo pipefail
set +e

shopt -s nullglob
mkdir -p dist
existing=(dist/speechrail-*.whl)
if [[ "${#existing[@]}" -ne 0 ]]; then
  echo "::error::CI requires a clean dist directory; refusing to test a stale wheel"
  exit 1
fi

build_log="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/speechrail-wheel-build.log"
env -u SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD \
  uv build --no-sources --wheel >"$build_log" 2>&1 &
build_pid=$!
cleanup() {
  if [[ -n "$build_pid" ]]; then
    kill -TERM "$build_pid" 2>/dev/null || true
    wait "$build_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# The wheel fixture otherwise invokes a second uv build on the same .build tree.
# Defer only this file, then combine both coverage datasets before enforcing 80%.
uv run --no-sync pytest --cov=src --ignore=tests/test_wheel_contents.py \
  -n 2 --dist loadfile --max-worker-restart=0 \
  --cov-report= --cov-fail-under=0 --durations=20
suite_status=$?

if wait "$build_pid"; then build_status=0; else build_status=$?; fi
build_pid=""
cat "$build_log"
if [[ "$build_status" -ne 0 ]]; then
  echo "::error::wheel build failed with exit code $build_status"
  exit "$build_status"
fi

wheels=(dist/speechrail-*.whl)
if [[ "${#wheels[@]}" -ne 1 ]]; then
  echo "::error::build must produce exactly one wheel"
  exit 1
fi
export SPEECHRAIL_WHEEL_PATH="$PWD/${wheels[0]}"
uv run --no-sync pytest tests/test_wheel_contents.py --cov=src \
  --cov-append --cov-fail-under=80
wheel_status=$?
if [[ "$suite_status" -ne 0 ]]; then exit "$suite_status"; fi
if [[ "$wheel_status" -ne 0 ]]; then exit "$wheel_status"; fi
printf 'SPEECHRAIL_WHEEL_PATH=%s\n' "$SPEECHRAIL_WHEEL_PATH" >> "${GITHUB_ENV:-/dev/null}"
