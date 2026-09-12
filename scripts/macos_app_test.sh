#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/macos/SpeechRailApp/SpeechRailApp.xcodeproj"
SCHEME="${SPEECHRAIL_MACOS_SCHEME:-SpeechRailApp}"
DESTINATION="${SPEECHRAIL_MACOS_DESTINATION:-platform=macOS}"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -testPlan SpeechRailApp \
  -destination "$DESTINATION" \
  -configuration "${SPEECHRAIL_MACOS_CONFIGURATION:-Debug}" \
  test
