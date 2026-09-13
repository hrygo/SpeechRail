#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/macos/SpeechRailApp/SpeechRailApp.xcodeproj"
CONFIGURATION="Debug"
ACTION="build"
EXPORT_OPTIONS=""
EXPORT_PATH=""

while (($# > 0)); do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { echo "--configuration requires a value" >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --archive)
      ACTION="archive"
      shift
      ;;
    --export-options)
      [[ $# -ge 2 ]] || { echo "--export-options requires a value" >&2; exit 2; }
      EXPORT_OPTIONS="$2"
      shift 2
      ;;
    --export-path)
      [[ $# -ge 2 ]] || { echo "--export-path requires a value" >&2; exit 2; }
      EXPORT_PATH="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$ACTION" == "archive" ]]; then
  ARCHIVE_PATH="$ROOT_DIR/build/SpeechRail.xcarchive"
  xcodebuild \
    -project "$PROJECT" \
    -scheme SpeechRailApp \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    archive
  if [[ -n "$EXPORT_OPTIONS" ]]; then
    [[ -n "$EXPORT_PATH" ]] || { echo "--export-path is required with --export-options" >&2; exit 2; }
    xcodebuild \
      -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportOptionsPlist "$EXPORT_OPTIONS" \
      -exportPath "$EXPORT_PATH"
  fi
else
  DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/speechrail-macos-build.XXXXXX")"
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

  cleanup_build_artifacts() {
    "$LSREGISTER" -u \
      "$DERIVED_DATA/Build/Products/$CONFIGURATION/SpeechRail.app" \
      >/dev/null 2>&1 || true
    /bin/rm -rf "$DERIVED_DATA"
  }

  trap cleanup_build_artifacts EXIT

  xcodebuild \
    -project "$PROJECT" \
    -scheme SpeechRailApp \
    -configuration "$CONFIGURATION" \
    -sdk macosx \
    -derivedDataPath "$DERIVED_DATA" \
    build
fi
