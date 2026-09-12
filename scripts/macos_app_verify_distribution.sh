#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || "$APP_PATH" == -* ]]; then
  echo "usage: scripts/macos_app_verify_distribution.sh path/to/SpeechRailApp.app" >&2
  exit 2
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "app bundle not found: $APP_PATH" >&2
  exit 2
fi

AGENT_PATH="$APP_PATH/Contents/Resources/SpeechRailControlAgent"
AGENT_PLIST="$APP_PATH/Contents/Library/LaunchAgents/com.speechrail.desktop.control.plist"
FRAMEWORK_ROOT="$APP_PATH/Contents/Frameworks"
if [[ ! -f "$AGENT_PATH" || ! -f "$AGENT_PLIST" ]]; then
  echo "app bundle is missing the control agent or LaunchAgent plist" >&2
  exit 1
fi
for framework in SpeechRailControlKit.framework SpeechRailControlAgentCore.framework; do
  if [[ ! -d "$FRAMEWORK_ROOT/$framework" ]]; then
    echo "app bundle is missing $framework" >&2
    exit 1
  fi
done

/usr/bin/plutil -lint "$AGENT_PLIST"
BUNDLE_PROGRAM="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$AGENT_PLIST")"
if [[ "$BUNDLE_PROGRAM" != "Contents/Resources/SpeechRailControlAgent" ]]; then
  echo "LaunchAgent plist must use BundleProgram for the bundled control agent" >&2
  exit 1
fi
if /usr/bin/plutil -extract EnvironmentVariables.SPEECHRAIL_ALLOW_UNSIGNED_XPC raw -o - "$AGENT_PLIST" >/dev/null 2>&1; then
  echo "Distribution bundle must not contain the local unsigned XPC development switch" >&2
  exit 1
fi

if ! /usr/bin/otool -l "$AGENT_PATH" | /usr/bin/grep -F '@executable_path/../Frameworks' >/dev/null; then
  echo "control agent is missing its bundle-relative framework rpath" >&2
  exit 1
fi

SIGNATURE_INFO="$(/usr/bin/codesign -dvv "$APP_PATH" 2>&1)"
if [[ "$SIGNATURE_INFO" == *"TeamIdentifier=not set"* ]]; then
  echo "Distribution bundle must carry a Developer ID signing team" >&2
  exit 1
fi
if [[ "$SIGNATURE_INFO" != *"flags="*"runtime"* ]]; then
  echo "Distribution bundle must enable Hardened Runtime" >&2
  exit 1
fi

CODE_PATHS=("$APP_PATH" "$AGENT_PATH")
while IFS= read -r -d '' path; do
  CODE_PATHS+=("$path")
done < <(
  find "$APP_PATH/Contents" \( -type d -name '*.framework' -o -type d -name '*.app' -o -type d -name '*.xctest' \) -print0
)

while IFS= read -r -d '' path; do
  CODE_PATHS+=("$path")
done < <(
  find "$APP_PATH/Contents" -type f -perm -111 -print0
)

printf '%s\n' "${CODE_PATHS[@]}" | /usr/bin/sort -u | while IFS= read -r path; do
  [[ -e "$path" ]] || continue
  /usr/bin/codesign --verify --strict --verbose=2 "$path"
done

echo "Distribution bundle verification passed: $APP_PATH"
