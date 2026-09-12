#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="Distribution"
EXPORT_OPTIONS=""
EXPORT_PATH=""

while (($# > 0)); do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { echo "--configuration requires a value" >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
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

if [[ "$CONFIGURATION" != "Distribution" ]]; then
  echo "archive requires --configuration Distribution so local XPC mode cannot enter a release archive." >&2
  exit 2
fi

if [[ -z "${SPEECHRAIL_TEAM_ID:-}" ]]; then
  echo "SPEECHRAIL_TEAM_ID is required for a Distribution archive; local builds do not need it." >&2
  exit 2
fi

args=(--configuration "$CONFIGURATION" --archive)
if [[ -n "$EXPORT_OPTIONS" ]]; then
  [[ -n "$EXPORT_PATH" ]] || { echo "--export-path is required with --export-options" >&2; exit 2; }
  args+=(--export-options "$EXPORT_OPTIONS" --export-path "$EXPORT_PATH")
fi

"$ROOT_DIR/scripts/macos_app_build.sh" "${args[@]}"
