---
name: speechrail
description: Use SpeechRail MCP for local transcription, diarization, TTS, voice design/clone validation, and durable job recovery.
metadata:
  short-description: SpeechRail local speech-plane workflow
---

# SpeechRail MCP

Use this skill when the task needs the local SpeechRail MCP tools for ASR,
diarization, TTS, voice creation/validation, or durable jobs. It is not a
general audio-production skill and it does not grant permission to delete,
publish, download models, restart services, or upload user data.

## Operating rules

1. Call `describe` first. Treat its `effective_capabilities_v1` snapshot as
   the source of truth for readiness, voices, revisions, parameters, and jobs.
2. Refresh `describe` after a profile/model/revision conflict or an
   unavailable result. Do not reconstruct capabilities from individual REST
   routes.
3. A reference gate pass is not an output pass. `available=true` is routing
   availability, not `production_ready=true`. A VoiceDesign instruction is a
   recipe, not a clone identity. Use `allow_unverified` for audition/diagnosis
   and `require_output_pass` for formal production; the service re-checks the
   latter at admission. That check requires a current observed Base runtime;
   a cold/unknown runtime makes the evidence unevaluated, so refresh discovery
   and validate again instead of retrying blindly.
4. Use local paths or `file://` URIs for audio. Never put audio/base64 in the
   prompt or tool arguments. Realtime full-duplex remains caller-owned at
   `/v1/realtime`; MCP does not create a conversation or WebSocket session.
5. Return or open the artifact path produced by the tool. Do not paste audio,
   long transcripts, reference text, or private paths into the conversation.
6. Retry only when the error says it is retryable. Use bounded exponential
   backoff for jobs; never retry a create operation without an idempotency key.

## Route by task

| Need | Read |
|---|---|
| discover tools, capabilities, revisions | `references/discovery.md` |
| transcribe, diarize, timestamps | `references/transcription.md` |
| render speech and choose a voice | `references/synthesis.md` |
| preview, design, clone, inspect, validate, delete voices | `references/voices.md` |
| create, poll, cancel, list, or recover a job | `references/jobs.md` |
| classify a failure and choose the next action | `references/errors.md` |
| receive, retain, or clean up a generated file | `references/artifacts.md` |

## Published MCP surface

The skill covers all published tools: `describe`, `transcribe`, `synthesize`,
`preview_voice`, `create_voice`, `delete_voice`, `create_job`, `get_job`,
`cancel_job`, `get_voice`, `design_voice`, `clone_voice`, `validate_voice`,
`list_jobs`, and `get_job_result`. It also covers the read-only resources
`speechrail://capabilities`, `speechrail://voices`, and
`speechrail://models`. Use only tools actually advertised by the connected
server; the manifest is a coverage contract, not permission to invent tools.
