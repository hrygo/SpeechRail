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

Send the transcription options in `transcription_session.update` before the
first `input_audio_buffer.append`:

```json
{
  "type": "transcription_session.update",
  "session": {
    "speechrail": {
      "transcription": {
        "partial_mode": "snapshot",
        "chunk_duration_ms": 500
      }
    }
  }
}
```

Wait for `transcription_session.updated` and use the echoed effective values.
If the server returns `error`, fail the session setup; do not start audio
with an unconfirmed option. The public values are:

- `partial_mode`: `delta` (default) or `snapshot`;
- `chunk_duration_ms`: `500`, `1000`, or `2000` (default `2000`).

Both options are session-scoped. After the first PCM frame they cannot be
changed; the server returns `invalid_state`. Unknown fields or unsupported
values are errors, not silently ignored. For a teleprompter, start with
`snapshot` and `500`; validate quality and resource cost for the target
language before changing the product default.

## Partial semantics

`delta` is append-only: each
`conversation.item.input_audio_transcription.delta` contains only new stable
text. A client must not append a delta after a rewrite that it did not
receive; wait for the terminal completed event.

`snapshot` sends the latest mutable hypothesis as a complete replacement:

```json
{
  "type": "speechrail.transcription.snapshot",
  "item_id": "item_...",
  "content_index": 0,
  "revision": 3,
  "text": "这是当前最新的识别全文"
}
```

For one `item_id`:

- replace the stored text; never concatenate snapshots;
- accept only a strictly newer `revision`;
- deduplicate repeated `event_id` values and ignore stale revisions;
- allow an empty snapshot as a valid replacement;
- treat `conversation.item.input_audio_transcription.completed` as the
  terminal authoritative transcript and do not let a late partial move the
  item afterward.

The snapshot is provisional recognition, not a final reading fact. A
teleprompter should apply its own bounded matching and monotonic-position
policy; it should not infer the reading position from text length or ask an
LLM to make every realtime position update.

`completed`/`failed` still close the ASR turn. The extension changes partial
delivery and ASR flush cadence only; it does not add server-side LLM,
conversation, TTS playback, or MCP state.
