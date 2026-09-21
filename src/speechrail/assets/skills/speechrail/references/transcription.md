# Transcription

Use `transcribe` with `audio_ref` pointing to a local file or `file://` URI.
The proxy rejects remote URLs and inline base64. Choose `timestamps` for
verbose segments/words, or `diarize` for anonymous speaker labels; diarization
requires `describe().readiness.diarization=true` and the two output modes are
not combined.

Pass a language only when known. Preserve the returned text and timestamps as
an artifact or application value; do not paste long or private transcripts
into agent context. A speaker label is session-scoped and anonymous, not a
person identity. For large/slow inputs use a transcription `create_job` whose
`input_ref` is the allowed local input file.

This tool does not expose live partials. If the caller owns a live WebSocket
and needs mutable transcription for a teleprompter or live captions, use the
direct Realtime guidance in `references/realtime.md`; do not try to encode
audio chunks or a WebSocket handle in an MCP tool argument.
