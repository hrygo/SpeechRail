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
