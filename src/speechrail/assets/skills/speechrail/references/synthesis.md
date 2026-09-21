# Synthesis

Choose a voice from the current capability snapshot, then call `synthesize`.
Use the returned artifact path and revision pins. Do not assume a system voice
and a user clone have the same controls.

- VoiceDesign/custom voice paths may expose speed/instruction/seed according
  to the live schema.
- Base clone voices require the capability-declared fixed speed and reject
  VoiceDesign instructions and caller seeds. Never try to compensate by
  sending unsupported options.
- Language aliases are normalized by the service; the live operation schema
  remains authoritative.
- `validation_policy=allow_unverified` is the default for audition/diagnosis;
  it may render an available clone while returning its validation summary.
  Use `validation_policy=require_output_pass` for formal production. The
  service checks the current voice/model binding again, so an agent-side check
  alone is not sufficient.
- For a clone under `require_output_pass`, require `production_ready=true`. If
  it is false, inspect `validation_state.synthesis` and its reason. Run
  `validate_voice` when output evidence is missing or stale, then call
  `describe` again; if the current runtime identity is still unknown, do not
  treat the old pass as a production gate.

`AudioArtifact` identifies the MCP host, byte count, optional request ID and
voice/model revisions. A path is local to that host; do not assume it is
reachable from another machine.

On `voice_revision_conflict` or `model_revision_conflict`, refresh discovery,
reselect the voice, and make a new explicit decision. Delete only artifacts
created by the current request after the host has finished with them.
