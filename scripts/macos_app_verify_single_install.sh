#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
EXPECTED_BUNDLE_IDENTIFIER="com.speechrail.desktop"
TEST_RUNNER_BUNDLE_IDENTIFIER="com.speechrail.desktop.uitests.xctrunner"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

usage() {
  echo "usage: scripts/macos_app_verify_single_install.sh path/to/SpeechRail.app" >&2
}

fail() {
  echo "$*" >&2
  exit 1
}

if [[ -z "$APP_PATH" || "$APP_PATH" == -* ]]; then
  usage
  exit 2
fi
if [[ ! -d "$APP_PATH" || "$(basename "$APP_PATH")" != "SpeechRail.app" ]]; then
  fail "installed SpeechRail.app not found: $APP_PATH"
fi
if [[ ! -x "$LSREGISTER" ]]; then
  fail "LaunchServices registry tool not found: $LSREGISTER"
fi

EXPECTED_PATH="$(cd "$APP_PATH" && pwd -P)"
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null)" || {
  fail "installed App is missing CFBundleIdentifier: $APP_PATH"
}
if [[ "$BUNDLE_IDENTIFIER" != "$EXPECTED_BUNDLE_IDENTIFIER" ]]; then
  fail "unexpected App bundle identifier: $BUNDLE_IDENTIFIER"
fi

LC_ALL=C "$LSREGISTER" -dump 2>/dev/null | /usr/bin/awk \
  -v app_id="$EXPECTED_BUNDLE_IDENTIFIER" \
  -v runner_id="$TEST_RUNNER_BUNDLE_IDENTIFIER" \
  -v expected_path="$EXPECTED_PATH" '
  function flush_record() {
    if (bundle_id == app_id && path ~ /\.app$/ && !(path in seen_apps)) {
      seen_apps[path] = 1
      app_paths[++app_count] = path
    }
    if (bundle_id == runner_id && path ~ /\.app$/ && !(path in seen_runners)) {
      seen_runners[path] = 1
      runner_paths[++runner_count] = path
    }
  }
  /^---/ {
    flush_record()
    path = bundle_id = ""
    next
  }
  /^path:/ {
    path = substr($0, index($0, ":") + 1)
    sub(/^[[:space:]]+/, "", path)
    sub(/[[:space:]]+\(0x[[:xdigit:]]+\)$/, "", path)
  }
  /^identifier:/ {
    bundle_id = substr($0, index($0, ":") + 1)
    sub(/^[[:space:]]+/, "", bundle_id)
  }
  END {
    flush_record()
    if (app_count == 1 && app_paths[1] == expected_path && runner_count == 0) {
      print "unique SpeechRail.app registration verified: " app_paths[1]
      exit 0
    }
    printf "expected one %s registration at %s; found %d\n", app_id, expected_path, app_count > "/dev/stderr"
    for (i = 1; i <= app_count; i++) printf "App: %s\n", app_paths[i] > "/dev/stderr"
    if (runner_count > 0) {
      printf "unexpected UI test runner registrations: %d\n", runner_count > "/dev/stderr"
      for (i = 1; i <= runner_count; i++) printf "Runner: %s\n", runner_paths[i] > "/dev/stderr"
    }
    exit 1
  }
'
