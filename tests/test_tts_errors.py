from __future__ import annotations

from speechrail.domain.tts_errors import TtsBackendError, from_worker_frame


def test_worker_load_error_is_structured_without_stderr_text() -> None:
    failure = from_worker_frame(
        {
            "type": "error",
            "code": "worker_load_error",
            "stderr_tail": "private model path and allocator traceback",
        },
        fallback_code="worker_start_failed",
        stage="initialize",
    )

    assert failure.code == "worker_load_error"
    assert failure.public_code == "tts_initialization_failed"
    assert failure.stage == "initialize"
    assert str(failure) == "worker_load_error"
    assert "private" not in str(failure)


def test_clone_parameter_error_is_not_reclassified_from_message_text() -> None:
    failure = from_worker_frame(
        {
            "type": "error",
            "code": "clone_speed_unsupported",
            "message": "speed=1.25 is unsupported",
            "stderr_tail": "speed appears in a traceback",
        },
        fallback_code="worker_inference_error",
        stage="infer",
    )

    assert isinstance(failure, TtsBackendError)
    assert failure.code == "clone_speed_unsupported"
    assert failure.public_code == "clone_speed_unsupported"
    assert failure.stage == "validate"
    assert failure.retryable is False
    assert str(failure) == "clone_speed_unsupported"
