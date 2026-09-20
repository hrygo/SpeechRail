# Discovery and routing

Start with `describe`. It combines readiness, active profile, model identity,
voice entries, operation parameters, and job readiness. The three resources
are read-only views; `speechrail://capabilities` is the atomic snapshot and
should be preferred when a decision depends on more than one field.

Use `available` only to decide whether a voice can be routed on the current
profile. For clone voices also inspect `production_ready`,
`validation_state.reference`, `validation_state.synthesis`, and
`validation_state.identity`. `validated_for` records the bounded uses supported
by current evidence. Formal output evidence is bound to the voice revision,
model artifact/catalog revision, observed runtime revision and fingerprint,
reference preprocessing version, generation recipe, and validation policy.
`voice_revision` and the model catalog revision are compare-and-swap pins, not
a promise that a worker is warm. If the runtime identity is unknown or cold,
`production_ready` must remain false even when an older validation record says
pass.

Tool coverage:

- speech: `transcribe`, `synthesize`, `preview_voice`
- voices: `create_voice`, `get_voice`, `design_voice`, `clone_voice`,
  `validate_voice`, `delete_voice`
- jobs: `create_job`, `get_job`, `list_jobs`, `get_job_result`, `cancel_job`

MCP is a stateless proxy. It does not load a model, import the FastAPI app, or
own an LLM conversation. If a host exposes fewer tools than the manifest,
report the missing capability instead of using a private REST route.
