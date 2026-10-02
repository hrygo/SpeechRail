# Voice workflows

There are four distinct creation routes:

1. `preview_voice` auditions a transient VoiceDesign instruction; it does not
   create an identity.
2. `create_voice` persists an instruction recipe. It is not a generated
   reference and is not a Base clone. It also is **not** a synthesis voice: an
   instruction candidate has no runtime route, so `synthesize` rejects it with
   `voice_design_task_required`. Treat it as a stored draft, not a deliverable.
3. `design_voice` creates a private VoiceDesign candidate. Call
   `confirm_voice_design` to fix its transcript, `validate_voice_design` with a
   different Base test text, attach identity/naturalness review only after human
   audition, then call `publish_voice_design`. Candidate generation and machine
   validation do not publish a production voice.
4. `clone_voice` registers a user-provided local reference recording through
   the reference-audio gate. A gate pass proves the reference, not synthesis.

Route 3 is the only one that ends in a synthesizable voice.

## Preview and design run the same model

`preview_voice` and `design_voice` run the **same** VoiceDesign weights and are
deterministic for a given `seed`, so a preview is a faithful audition of what the
design lane will produce — prosody and delivery rate carry over, and screening a
recipe with `preview_voice` is a valid way to choose it.

Two things still differ, and neither is a model difference:

- `preview_voice` pins `language="zh"`, matching `design_voice`. Both are
  zh-only, so a preview never drifts from the candidate it stands in for.
  When calling `POST /v1/voices/previews` directly (not via MCP), pass
  `language="zh"` explicitly: the endpoint default is `auto` for OpenAI
  compatibility, and any other language forks the same recipe across the
  preview and design lanes.
- A **stored** candidate's audio is canonicalized (leading/trailing silence
  trimmed, gain normalized). Its total duration is therefore shorter than the
  preview of the same recipe. Compare speech-active delivery rate, not
  wall-clock duration.

## Finding the design lane

Design is a tier-independent, on-demand lane. It is **not** the active `tts`
model and is not selected by the active tier:

- `models.voice_design` in `describe().effective_capabilities` reports whether a
  design artifact is bound. `models.tts.variant` is only ever `custom_voice` or
  `base` — never read a design verdict from it.
- `operations.voice_design` reports the design operation and whether publishing
  to Base is available.
- `GET /health` → `tts_design` reports *residency*, not availability:
  `state: "cold"` with `configured: true` means the lazy worker is not loaded and
  will load on first design request. Reading health never loads a worker.

The capability state keeps `reference`, `synthesis/output`, and `identity`
separate. A successful output probe never promotes identity; when identity
assessment is unavailable it remains `unevaluated`. `validated_for` records
the bounded use cases supported by stored evidence.

Use `get_voice` for one safe detail and `validate_voice` for bounded synthesis
probes on the current revision. Require a persisted synthesis pass before a
final production render. Use `delete_voice` only for an explicitly named user
voice; system voices and voices in use may be protected. Idempotency keys are
recommended for design/clone creation and required before retrying an unknown
create outcome.

Reference audio and text are sensitive. Pass them through the local file
boundary and the named tool only; do not echo them into chat or invent a
stable identity from repeatability alone.
