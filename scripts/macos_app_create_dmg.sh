#!/usr/bin/env bash
set -euo pipefail

APP_PATH=""
VERSION=""
OUTPUT_PATH=""

usage() {
  echo "usage: scripts/macos_app_create_dmg.sh --app-path SpeechRail.app --version VERSION --output-path FILE.dmg" >&2
}

fail() {
  local exit_code="$1"
  shift
  echo "$*" >&2
  exit "$exit_code"
}

while (($# > 0)); do
  case "$1" in
    --app-path)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      APP_PATH="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      VERSION="$2"
      shift 2
      ;;
    --output-path)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$APP_PATH" || -z "$VERSION" || -z "$OUTPUT_PATH" ]]; then
  usage
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  fail 2 "invalid release version: $VERSION"
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
if ! /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null 2>&1; then
  fail 1 "app bundle Info.plist is invalid: $INFO_PLIST"
fi

BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null)" || {
  fail 1 "app bundle is missing CFBundleShortVersionString: $APP_PATH"
}
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
  fail 1 "bundle version $BUNDLE_VERSION does not match release version $VERSION"
fi
BUNDLE_BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null)" || {
  fail 1 "app bundle is missing CFBundleVersion: $APP_PATH"
}
if [[ ! "$BUNDLE_BUILD_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  fail 1 "app bundle has invalid CFBundleVersion: $BUNDLE_BUILD_VERSION"
fi
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null)" || {
  fail 1 "app bundle is missing CFBundleIdentifier: $APP_PATH"
}
if [[ "$BUNDLE_IDENTIFIER" != "com.speechrail.desktop" ]]; then
  fail 1 "unexpected app bundle identifier: $BUNDLE_IDENTIFIER"
fi
if [[ "$OUTPUT_PATH" != *.dmg ]]; then
  fail 2 "--output-path must end with .dmg: $OUTPUT_PATH"
fi
if [[ -e "$OUTPUT_PATH" ]]; then
  fail 2 "refusing to overwrite existing DMG: $OUTPUT_PATH"
fi
OUTPUT_DIRECTORY="$(dirname "$OUTPUT_PATH")"
if [[ ! -d "$OUTPUT_DIRECTORY" ]]; then
  fail 2 "DMG output directory not found: $OUTPUT_DIRECTORY"
fi
if ! command -v hdiutil >/dev/null 2>&1; then
  fail 1 "hdiutil is required to create a macOS DMG"
fi

STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/speechrail-dmg-staging.XXXXXX")"
MOUNT_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/speechrail-dmg-mount.XXXXXX")"
MOUNTED=0
OUTPUT_CREATED=0
COMPLETED=0

cleanup() {
  if [[ "$MOUNTED" -eq 1 ]]; then
    /usr/bin/hdiutil detach "$MOUNT_DIRECTORY" >/dev/null 2>&1 || true
  fi
  if [[ "$COMPLETED" -eq 0 && "$OUTPUT_CREATED" -eq 1 ]]; then
    /bin/rm -f "$OUTPUT_PATH"
  fi
  /bin/rm -rf "$STAGING_DIRECTORY" "$MOUNT_DIRECTORY"
}
trap cleanup EXIT

/usr/bin/ditto "$APP_PATH" "$STAGING_DIRECTORY/SpeechRail.app"
/bin/ln -s /Applications "$STAGING_DIRECTORY/Applications"
OUTPUT_CREATED=1
/usr/bin/hdiutil create \
  -volname "SpeechRail $VERSION" \
  -srcfolder "$STAGING_DIRECTORY" \
  -format UDZO \
  "$OUTPUT_PATH" >/dev/null

/usr/bin/hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_DIRECTORY" \
  "$OUTPUT_PATH" >/dev/null
MOUNTED=1
if [[ ! -d "$MOUNT_DIRECTORY/SpeechRail.app" ]]; then
  fail 1 "created DMG does not contain SpeechRail.app"
fi
if [[ ! -L "$MOUNT_DIRECTORY/Applications" ]]; then
  fail 1 "created DMG does not contain the Applications symlink"
fi
/usr/bin/hdiutil detach "$MOUNT_DIRECTORY" >/dev/null
MOUNTED=0
COMPLETED=1

echo "created unsigned DMG: $OUTPUT_PATH"
