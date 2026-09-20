# Durable jobs

Use `create_job` for bounded asynchronous recovery. `transcription` consumes
an allowed local audio input; `speech` consumes an allowed UTF-8 text input.
Pass an absolute local path or `file://` URI that the worker's allowlist can
read; this is not a remote URL and speech input is not the text itself.
Use only the params accepted by the job kind and the live capability schema.
Do not put arbitrary payloads or audio bytes into params.

Speech jobs may set `validation_policy` to `allow_unverified` or
`require_output_pass`; use the latter for formal production and let the
service re-check the current clone binding. The binding includes the observed
runtime identity and recipe/preprocessing policy; a cold or unknown Base
runtime fails closed as `voice_not_production_ready` rather than selecting an
older pass.

For create retries, supply an `idempotency_key`; the same owner/key/payload
returns the same job and a changed payload returns a conflict. `list_jobs` is
owner-scoped and paginated; keep the opaque cursor intact. Poll `get_job` with
bounded backoff (1/2/4/8 seconds, capped at 10 seconds) and stop at the
caller deadline. A timeout leaves the job ID in an unknown state; inspect it
before creating another job.

When the job is `completed`, call `get_job_result`. It materializes the result
on the MCP host as a file; use the returned media type and path. `cancel_job`
is a request, not proof that a running worker already stopped. Preserve the
job ID and report the actual terminal state.
