# SpeechRail Agent Guide

## Project scope

SpeechRail is the independent local speech-recognition service shared by
QwenPaw, `voice-realtime`, Hermes Agent and future applications. It owns the
public ASR API, runtime lifecycle, model adapters, queueing, authentication,
observability and compatibility boundaries.

It does not own microphones, speakers, TTS, meeting persistence, UI state,
LM Studio chat orchestration, or application-specific prompts. Those remain in
the consuming applications.

## Non-negotiable boundaries

- Python `>=3.12,<3.13`; use `uv` and PEP 621 metadata.
- Public file transcription is OpenAI-compatible at `/v1/audio/transcriptions`.
- New streaming clients use `/v1/realtime`; legacy `voice-realtime` clients may
  use `/asr` until the migration is complete.
- Loopback binding is the default. LAN binding requires an API key and an
  explicit allowed-origin policy.
- Model snapshots are external absolute paths. Do not download models during a
  request or silently access the network.
- Audio is transient by default. Do not persist source audio or raw transcript
  bodies in logs.
- The public model name is model-independent. `qwen3-asr-1.7b` is a backend
  profile, not a reason to rename the service or API.
- Do not copy `voice-realtime`'s meeting, UI, TTS, LM Studio or PostgreSQL
  ownership into this repository.

## Contract rules

- Treat `contracts/openapi.yaml` and the realtime event contract as the source
  of truth before implementation.
- Use one stable error envelope on all public endpoints and include a request ID.
- Additive changes are preferred. Breaking changes require `/v2` and a migration
  note; compatibility aliases must have an explicit deprecation date.
- Validate external inputs at the API boundary and validate vendor responses in
  adapters before producing domain events.

## Verification

Before claiming a change is complete, run the focused test, full test suite,
`ruff check`, `mypy`, and OpenAPI validation. If a model-backed test is not
available locally, state that limitation and keep the test deterministic with a
fake backend.

## Sensitive data

Never commit API keys, local credential files, full environment files, audio,
model weights, or unredacted transcript fixtures. Use placeholders in examples.
