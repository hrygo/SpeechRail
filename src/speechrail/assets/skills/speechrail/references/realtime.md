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
    "speechrail": {
      "task": "transcription",
      "asr": {
        "preview_interval_ms": 1000,
        "max_segment_ms": 20000,
        "finalization": "full_segment"
      }
    }
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
- Pin ASR with `session.speechrail.expected_asr_revision`. TTS voice and model
  identity belong to each `speechrail.tts.start` (`voice`, `voice_revision`,
  `expected_model_revision`); they never inherit from the session or a prior
  utterance. The removed session field `expected_tts_revision` is rejected.
- The optional `session.speechrail.asr` object selects a vendor-neutral policy.
  `preview_interval_ms` defaults to 1000 and accepts integer values from 100 to
  5000. `max_segment_ms` defaults to 20000, accepts 1000 to 30000, and must be
  at least the preview interval. `finalization` is `full_segment` by default or
  `streaming_finalize`. An explicit positive `final_deadline_ms` cannot exceed
  the request timeout; when omitted, the request timeout applies. Send integer
  JSON number tokens, not booleans or decimal-form values. Unknown fields and
  unsupported enum values are rejected. `session.updated` echoes the effective
  `effective_max_segment_ms`, the minimum of request, service, capability, and
  decoder limits.
- Every `speechrail.tts.start` requires an even `audio_window_bytes` in `2...1440000`;
  `started` echoes it. Return `speechrail.tts.audio_ack` with this request ID and
  cumulative PCM16 `sample_offset` only after releasing local audio capacity.
  The sender pauses at this consumption window instead of treating healthy fast
  generation as overflow. Worker `limits.max_pending_audio_bytes` is a separate
  transport budget. Duplicate consumption watermarks are idempotent; backward or
  future watermarks fail with `tts_audio_ack_invalid`. Consumption is not evidence
  that a user heard the audio. Cancel and credits use the independent control lane.
  Upgrade direct WebSocket clients together with the service; the current contract
  has no start mode without consumption flow control. REST/MCP render is unchanged.

These options are session-scoped. After the first accepted PCM frame they cannot
be changed; the server returns `invalid_state`. Unknown fields or unsupported
values are errors, not silently ignored.

For each frozen non-empty segment, `speechrail.transcription.segment_closed`
reports the item, its half-open `[start, end)` span in 24 kHz wire samples, and
one reason: `vad`, `client_commit`, or `budget_rollover`. The optional
`commit_event_id` appears only for a client commit. A budget rollover is an ASR
segment boundary; the caller decides when a business turn ends.

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

If a client has already accepted a hypothesis for one `utterance_id`, it must
treat that full-text snapshot as the display source and suppress later deltas
for the same item; otherwise a rewrite plus append produces duplicated text.

The hypothesis is provisional recognition, not a final reading fact. A
teleprompter should apply its own bounded matching and monotonic-position
policy; it should not infer the reading position from text length or ask an LLM
to make every realtime position update.

`completed`/`failed` close the ASR turn. A terminal produced by an explicit
client `input_audio_buffer.commit` echoes the commit `event_id` as
`commit_event_id`. When ending a recording, wait for the terminal with the
matching id so an older in-flight terminal cannot satisfy the tail barrier.
The extension changes partial delivery only; it does not add server-side LLM,
conversation, TTS playback, or MCP state.

`alignment.enabled` and `diarization.enabled` are independent opt-ins. Alignment
alone retains the bounded PCM and emits `speechrail.alignment.done/failed`
after each ASR final; it does not require diarization. Diarization finalization
waits for in-flight alignment of frozen text before sealing the ledger, so a
final never lands in a sealed session without its attribution.
