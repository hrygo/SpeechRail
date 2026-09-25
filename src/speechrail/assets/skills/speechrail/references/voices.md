# Voice workflows

There are three distinct creation routes:

1. `preview_voice` auditions a transient VoiceDesign instruction; it does not
   create an identity.
2. `create_voice` persists an instruction recipe. It is not a generated
   reference and is not a Base clone.
3. `design_voice` creates a private VoiceDesign candidate. Call
   `confirm_voice_design` to fix its transcript, `validate_voice_design` with a
   different Base test text, attach identity/naturalness review only after human
   audition, then call `publish_voice_design`. Candidate generation and machine
   validation do not publish a production voice.
4. `clone_voice` registers a user-provided local reference recording through
   the reference-audio gate. A gate pass proves the reference, not synthesis.

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
