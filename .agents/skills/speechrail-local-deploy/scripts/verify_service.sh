#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${SPEECHRAIL_BASE_URL:-http://127.0.0.1:8201}"
EXPECTED_PROFILE="${SPEECHRAIL_EXPECTED_PROFILE:-}"

echo "Probing SpeechRail at ${BASE_URL}..."

LISTENERS="$(lsof -nP -iTCP:8201 -sTCP:LISTEN -t 2>/dev/null || true)"
LISTENER_COUNT="$(printf '%s\n' "${LISTENERS}" | awk 'NF { count++ } END { print count + 0 }')"
if [ "${LISTENER_COUNT}" -ne 1 ]; then
    echo "FAILED: expected exactly one listener on TCP 8201, found ${LISTENER_COUNT}" >&2
    exit 1
fi
echo "OK: exactly one listener on TCP 8201 (PID ${LISTENERS})"

HEALTH_JSON="$(curl -sS --fail "${BASE_URL}/health")"
VERSION="$(printf '%s' "${HEALTH_JSON}" | jq -r '.version // empty')"
STATUS="$(printf '%s' "${HEALTH_JSON}" | jq -r '.status // empty')"
PROFILE="$(printf '%s' "${HEALTH_JSON}" | jq -r '.profile // empty')"
if [ -z "${VERSION}" ] || [ -z "${STATUS}" ]; then
    echo "FAILED: /health has no version or status" >&2
    exit 1
fi
if [ -n "${EXPECTED_PROFILE}" ] && [ "${PROFILE}" != "${EXPECTED_PROFILE}" ]; then
    echo "FAILED: expected profile ${EXPECTED_PROFILE}, got ${PROFILE:-<missing>}" >&2
    exit 1
fi
echo "OK: /health (status: ${STATUS}, version: ${VERSION}, profile: ${PROFILE:-<unset>})"

READYZ_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/readyz")"
if [ "${READYZ_STATUS}" != "200" ]; then
    echo "FAILED: /readyz returned HTTP ${READYZ_STATUS}" >&2
    exit 1
fi
echo "OK: /readyz (HTTP 200)"

MODELS_JSON="$(curl -sS --fail "${BASE_URL}/v1/models")"
MODEL_COUNT="$(printf '%s' "${MODELS_JSON}" | jq '.data | length')"
echo "OK: /v1/models (${MODEL_COUNT} models registered)"

VOICES_JSON="$(curl -sS --fail "${BASE_URL}/v1/voices")"
VOICE_COUNT="$(printf '%s' "${VOICES_JSON}" | jq '.data | length')"
echo "OK: /v1/voices (${VOICE_COUNT} voices registered)"

echo "All lifecycle and health probes passed. Run real ASR/TTS smoke before release acceptance."
