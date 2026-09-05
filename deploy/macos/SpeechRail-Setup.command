#!/bin/zsh
set -eu

APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
RUNTIME_PYTHON="$APP_HOME/runtime/current/.venv/bin/python"

if [[ ! -x "$RUNTIME_PYTHON" ]]; then
  print -u2 "SpeechRail is not installed at: $APP_HOME"
  exit 1
fi

exec "$RUNTIME_PYTHON" -m speechrail setup --app-home "$APP_HOME"
