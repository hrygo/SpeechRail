#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${SPEECHRAIL_BASE_URL:-http://127.0.0.1:8201}"

echo "========================================="
echo "Probing SpeechRail at ${BASE_URL}..."
echo "========================================="

echo -n "1. Checking /health: "
HEALTH_JSON=$(curl -s --fail "${BASE_URL}/health" || echo "FAIL")
if [ "${HEALTH_JSON}" != "FAIL" ]; then
    VERSION=$(echo "${HEALTH_JSON}" | jq -r .version)
    STATUS=$(echo "${HEALTH_JSON}" | jq -r .status)
    echo "OK (status: ${STATUS}, version: ${VERSION})"
else
    echo "FAILED"
    exit 1
fi

echo -n "2. Checking /readyz: "
READYZ_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/readyz" || echo "500")
if [ "${READYZ_STATUS}" = "200" ]; then
    echo "OK (HTTP 200)"
else
    echo "FAILED (HTTP ${READYZ_STATUS})"
    exit 1
fi

echo -n "3. Checking /v1/models: "
MODELS_JSON=$(curl -s --fail "${BASE_URL}/v1/models" || echo "FAIL")
if [ "${MODELS_JSON}" != "FAIL" ]; then
    MODEL_COUNT=$(echo "${MODELS_JSON}" | jq '.data | length')
    echo "OK (${MODEL_COUNT} models registered)"
else
    echo "FAILED"
    exit 1
fi

echo -n "4. Checking /v1/voices: "
VOICES_JSON=$(curl -s --fail "${BASE_URL}/v1/voices" || echo "FAIL")
if [ "${VOICES_JSON}" != "FAIL" ]; then
    VOICE_COUNT=$(echo "${VOICES_JSON}" | jq '.data | length')
    echo "OK (${VOICE_COUNT} voices registered)"
else
    echo "FAILED"
    exit 1
fi

echo "========================================="
echo "All health probes passed successfully!"
echo "========================================="
