#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s AUDIO_FILE\n' "$0" >&2
  exit 2
fi

audio_file=$1
base_url=${SPEECHRAIL_BASE_URL:-http://127.0.0.1:8201/v1}
model=${SPEECHRAIL_MODEL:-speechrail/qwen3-asr-1.7b}
api_key=${SPEECHRAIL_API_KEY:-local-not-used}

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${api_key}" \
  -F "file=@${audio_file}" \
  -F "model=${model}" \
  -F 'language=zh' \
  -F 'response_format=verbose_json' \
  "${base_url%/}/audio/transcriptions"
printf '\n'
