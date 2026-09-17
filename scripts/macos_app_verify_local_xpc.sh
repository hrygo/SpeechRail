#!/usr/bin/env bash
set -euo pipefail

# Gate for the local (Debug/Release) App flavor: the App embeds
# Contents/XPCServices/com.speechrail.desktop.local-control.xpc and talks to it
# with NSXPCConnection(serviceName:). The helper pins the peer to
# `identifier "<ControlConstants.appBundleIdentifier>"` whenever its
# Info.plist sets SPEECHRAIL_ALLOW_UNSIGNED_XPC=1, so the App must ship a real
# bundle signature whose signing identifier equals its bundle identifier.
#
# Building with CODE_SIGNING_ALLOWED=NO leaves only the linker's ad-hoc
# signature behind: the signing identifier becomes PRODUCT_NAME, no resource
# seal is written, and every XPC request is rejected with
# `xpc_support_check_token ... status: -67050` (errSecCSReqFailed). The App then
# reports「控制通道不可用」. This script fails the build instead of shipping that.

APP_PATH="${1:-}"
EXPECTED_BUNDLE_IDENTIFIER="com.speechrail.desktop"
LOCAL_XPC_NAME="com.speechrail.desktop.local-control"

usage() {
  echo "usage: scripts/macos_app_verify_local_xpc.sh path/to/SpeechRail.app" >&2
}

fail() {
  local exit_code="$1"
  shift
  echo "$*" >&2
  exit "$exit_code"
}

if [[ -z "$APP_PATH" || "$APP_PATH" == -* ]]; then
  usage
  exit 2
fi
if [[ ! -d "$APP_PATH" ]]; then
  fail 1 "app bundle not found: $APP_PATH"
fi
if [[ "$(basename "$APP_PATH")" != "SpeechRail.app" ]]; then
  fail 1 "app bundle must be named SpeechRail.app: $APP_PATH"
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  fail 1 "app bundle is missing Contents/Info.plist: $APP_PATH"
fi
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null)" || {
  fail 1 "app bundle is missing CFBundleIdentifier: $APP_PATH"
}
if [[ "$BUNDLE_IDENTIFIER" != "$EXPECTED_BUNDLE_IDENTIFIER" ]]; then
  fail 1 "app bundle identifier $BUNDLE_IDENTIFIER does not match the identifier the control helper requires ($EXPECTED_BUNDLE_IDENTIFIER); keep it in sync with SpeechRailControlKit's ControlConstants.appBundleIdentifier"
fi

SIGNING_IDENTIFIER="$(/usr/bin/codesign -dvv "$APP_PATH" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p' | /usr/bin/head -1)"
if [[ -z "$SIGNING_IDENTIFIER" ]]; then
  fail 1 "app bundle carries no code signature: $APP_PATH"
fi
if [[ "$SIGNING_IDENTIFIER" != "$BUNDLE_IDENTIFIER" ]]; then
  fail 1 "signing identifier $SIGNING_IDENTIFIER does not match bundle identifier $BUNDLE_IDENTIFIER: the embedded local XPC helper rejects such a peer (errSecCSReqFailed). Build with code signing enabled (ad hoc is enough, as in Debug.xcconfig/Release.xcconfig) instead of CODE_SIGNING_ALLOWED=NO"
fi

if ! /usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
  fail 1 "app bundle code signature is not valid on disk: $APP_PATH"
fi
if ! /usr/bin/codesign --verify -R="identifier \"$BUNDLE_IDENTIFIER\"" "$APP_PATH" >/dev/null 2>&1; then
  fail 1 "app bundle does not satisfy the local XPC peer requirement (identifier \"$BUNDLE_IDENTIFIER\"): $APP_PATH"
fi

LOCAL_XPC_PATH="$APP_PATH/Contents/XPCServices/$LOCAL_XPC_NAME.xpc"
if [[ ! -d "$LOCAL_XPC_PATH" ]]; then
  fail 1 "app bundle is missing $LOCAL_XPC_NAME.xpc: the Debug/Release App controls the service only through this embedded helper (a Distribution bundle is verified by scripts/macos_app_verify_distribution.sh instead)"
fi
LOCAL_XPC_INFO_PLIST="$LOCAL_XPC_PATH/Contents/Info.plist"
if ! /usr/bin/plutil -lint "$LOCAL_XPC_INFO_PLIST" >/dev/null 2>&1; then
  fail 1 "local XPC helper Info.plist is invalid: $LOCAL_XPC_INFO_PLIST"
fi
XPC_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LOCAL_XPC_INFO_PLIST" 2>/dev/null)" || {
  fail 1 "local XPC helper is missing CFBundleIdentifier: $LOCAL_XPC_PATH"
}
if [[ "$XPC_IDENTIFIER" != "$LOCAL_XPC_NAME" ]]; then
  fail 1 "local XPC helper identifier $XPC_IDENTIFIER does not match $LOCAL_XPC_NAME"
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :XPCService:EnvironmentVariables:SPEECHRAIL_ALLOW_UNSIGNED_XPC' "$LOCAL_XPC_INFO_PLIST" 2>/dev/null)" != "1" ]]; then
  fail 1 "local XPC helper does not set SPEECHRAIL_ALLOW_UNSIGNED_XPC=1, so it no longer pins the peer to identifier \"$EXPECTED_BUNDLE_IDENTIFIER\"; update this gate together with the helper's peer policy"
fi
if ! /usr/bin/codesign --verify --strict --verbose=2 "$LOCAL_XPC_PATH" >/dev/null 2>&1; then
  fail 1 "local XPC helper code signature is not valid on disk: $LOCAL_XPC_PATH"
fi

echo "local XPC packaging verification passed: $APP_PATH (signing identifier $SIGNING_IDENTIFIER)"
