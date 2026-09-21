# Errors and recovery

Every tool error has a stable code, retryability, and an action hint. Apply
the category before retrying:

- parameter/voice/revision errors: fix the request or refresh discovery;
- `voice_not_production_ready`: validate the current clone; do not render;
- `backend_busy`/`queue_full`: bounded backoff, no tight loop;
- `backend_timeout`: inspect the request/job state before retrying;
- worker initialization or deterministic clone-parameter errors: do not retry
  blindly; report the code and inspect readiness/parameters;
- `job_not_ready`/`idempotency_pending`: retain the handle and poll later;
- `voice_store_unavailable`/`connection_error`: retry only under the caller's
  deadline and with a key for create operations.
- `tts_initialization_failed`, `tts_inference_failed`, and `output_invalid` are
  stable backend/output classes; they are not automatic retry signals unless
  the error explicitly says `retryable=true`.

Never parse traceback or stderr text to decide whether clone speed is
unsupported. Never turn a failed registration or validation into a successful
voice record. Do not hide a conflict by changing the voice ID automatically.
