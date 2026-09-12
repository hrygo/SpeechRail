#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/macos/SpeechRailApp/SpeechRailApp.xcodeproj"
SCHEME="${SPEECHRAIL_MACOS_SCHEME:-SpeechRailApp}"
DESTINATION="${SPEECHRAIL_MACOS_DESTINATION:-platform=macOS}"
BUILD_SETTINGS=()

# macOS UI test runners need Xcode's normal signed build path to include the
# Testing.framework runtime dependencies. Debug.xcconfig uses ad-hoc signing,
# so this does not require a developer certificate. Set this to 0 only when an
# environment explicitly requires an unsigned test bundle.
if [[ "${SPEECHRAIL_MACOS_SIGNED_TESTS:-1}" != "1" ]]; then
  BUILD_SETTINGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi

XCODEBUILD_ARGS=(
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -testPlan SpeechRailApp \
  -destination "$DESTINATION" \
  -configuration "${SPEECHRAIL_MACOS_CONFIGURATION:-Debug}" \
)

if ((${#BUILD_SETTINGS[@]} > 0)); then
  xcodebuild "${XCODEBUILD_ARGS[@]}" "${BUILD_SETTINGS[@]}" test
else
  xcodebuild "${XCODEBUILD_ARGS[@]}" test
fi
