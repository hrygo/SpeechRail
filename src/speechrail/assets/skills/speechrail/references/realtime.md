# Caller-owned Realtime transcription

This is protocol guidance for clients that connect directly to
`ws://127.0.0.1:8201/v1/realtime`. It is not an MCP tool. The MCP
`transcribe` tool remains request/response and does not create a WebSocket
session or stream partial events.

Use the Realtime extension when a client owns live audio capture, session
state, and UI (for example, a teleprompter or live captions). The caller
still owns LLM orchestration, playback, conversation history, and barge-in.
The authoritative wire contract is
`contracts/realtime-openai.md`.

## Negotiate before sending audio

Send the transcription options in `session.update` before the first
`input_audio_buffer.append`:

```json
{
  "type": "session.update",
  "session": {
    "audio": {
      "input": {
        "format": {"type": "audio/pcm", "rate": 24000},
        "transcription": {"model": "speechrail/qwen3-asr-1.7b"}
      }
    },
    "speechrail": {"task": "transcription"}
  }
}
```

Wait for `session.updated` and use the echoed effective values. If the server
returns `error`, fail the session setup; do not start audio with an unconfirmed
option.

- The only supported input is 24 kHz mono PCM16; other rates and codecs are
  rejected rather than silently reinterpreted.
- Server-side endpointing is opt-in on `session.speechrail.endpointing`
  (`{"mode": "server_vad", ...}`); leave it out to drive turns with an explicit
  `input_audio_buffer.commit`.
- Alignment, diarization and TTS are separate `session.speechrail` opt-ins and
  never turn on implicitly.

These options are session-scoped. After the first accepted PCM frame they cannot
be changed; the server returns `invalid_state`. Unknown fields or unsupported
values are errors, not silently ignored.

## Partial semantics

`speechrail.transcription.hypothesis` is the latest mutable hypothesis for one
`utterance_id`. It carries a monotonic `revision`, the full `text`, the
`sample_span`, and `stable_prefix_codepoints`:

For one `utterance_id`:

- replace the stored text; never concatenate hypotheses;
- accept only a strictly newer `revision`;
- deduplicate repeated `event_id` values and ignore stale revisions;
- allow an empty hypothesis as a valid replacement;
- treat `conversation.item.input_audio_transcription.completed` as the
  terminal authoritative transcript and do not let a late partial move the
  item afterward.

`conversation.item.input_audio_transcription.delta` is different: it carries
only the *provable* stable prefix as append-only text. A client may append a
delta, but must never append after a rewrite it did not receive; wait for the
terminal `completed` event instead. When stability cannot be proven the server
sends only a hypothesis, never a guessed delta.

The hypothesis is provisional recognition, not a final reading fact. A
teleprompter should apply its own bounded matching and monotonic-position
policy; it should not infer the reading position from text length or ask an LLM
to make every realtime position update.

`completed`/`failed` close the ASR turn. The extension changes partial delivery
only; it does not add server-side LLM, conversation, TTS playback, or MCP state.
