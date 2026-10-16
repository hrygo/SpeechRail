"""Alignment failures remain attributable without recording request contents."""

from __future__ import annotations

import asyncio
import logging

import pytest

from speechrail.domain.alignment import InvalidAlignmentOutputError
from speechrail.observability.alignment import (
    alignment_failure_message,
    log_alignment_failure,
)
from speechrail.observability.metrics import Metrics


def test_alignment_failure_metrics_bound_unknown_reasons() -> None:
    metrics = Metrics()
    metrics.record_alignment_failure("text_mismatch")
    metrics.record_alignment_failure("alignment_time_resolution_insufficient")
    metrics.record_alignment_failure("private transcript /private/model")
    rendered = metrics.render_prometheus()
    assert 'speechrail_asr_alignment_failures_total{reason="text_mismatch"} 1' in rendered
    assert (
        'speechrail_asr_alignment_failures_total'
        '{reason="alignment_time_resolution_insufficient"} 1'
    ) in rendered
    assert 'speechrail_asr_alignment_failures_total{reason="alignment_failed"} 1' in rendered
    assert "private" not in rendered


def test_alignment_failure_log_records_only_safe_metadata(caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.WARNING):
        log_alignment_failure(
            code="text_mismatch",
            stage="validation",
            audio_samples=16_000,
            expected_audio_samples=16_001,
            text_characters=2,
            span_start_sample=32_000,
            transcript_revision=1,
            exception=RuntimeError("private transcript /private/model Bearer secret"),
        )
    assert "code=text_mismatch" in caplog.text
    assert "stage=validation" in caplog.text
    assert "audio_samples=16000" in caplog.text
    assert "expected_audio_samples=16001" in caplog.text
    assert "span_start_sample=32000" in caplog.text
    assert "text_characters=2" in caplog.text
    assert "exception_type=RuntimeError" in caplog.text
    assert "private" not in caplog.text
    assert "secret" not in caplog.text
    assert all(record.exc_info is None for record in caplog.records)


def test_alignment_failure_message_does_not_echo_untrusted_codes() -> None:
    assert "text" in alignment_failure_message("text_mismatch").lower()
    message = alignment_failure_message("alignment_time_resolution_insufficient")
    assert "resolution" in message.lower()


@pytest.mark.parametrize(
    ("start", "end", "expected_start", "expected_end"),
    [(-0.01, 0.6, -160, 9600), (0.1, 0.52, 1600, 8320),
     (0.1, 1e300, 1600, 1_000_000_000)],
)
def test_out_of_bounds_log_includes_bounded_timestamp_range(
    start: float, end: float, expected_start: int, expected_end: int,
    caplog: pytest.LogCaptureFixture,
) -> None:
    from speechrail.application.alignment import FixedTextAligner
    from speechrail.domain.alignment import AlignmentRequest
    from speechrail.domain.audio_timeline import SampleSpan

    class Client:
        async def align_text(self, pcm: bytes, *, text: str, language: str | None):
            return (("fixture", start, end),)

    request = AlignmentRequest(
        task_id="task", epoch="epoch", utterance_id="item", transcript_revision=1,
        pcm16=bytes(16_000), span=SampleSpan(32_000, 40_000),
        text="fixture", language="en",
    )
    with caplog.at_level(logging.WARNING):
        result = asyncio.run(FixedTextAligner(Client()).align(request))
    assert result.failure == "alignment_out_of_bounds"
    assert "expected_audio_samples=8000" in caplog.text
    assert f"timestamp_min_start_sample={expected_start}" in caplog.text
    assert f"timestamp_max_end_sample={expected_end}" in caplog.text
    assert "fixture" not in caplog.text
    assert "private" not in alignment_failure_message("private transcript /private/model")


@pytest.mark.parametrize(
    ("error_type", "expected_code"),
    [(RuntimeError, "alignment_worker_failed"), (OSError, "alignment_worker_failed"),
     (TimeoutError, "alignment_timeout"), (ValueError, "alignment_failed"),
     (InvalidAlignmentOutputError, "invalid_alignment")],
)
def test_worker_exception_is_classified_without_recording_its_body(
    error_type: type[Exception],
    expected_code: str,
    caplog: pytest.LogCaptureFixture,
) -> None:
    from speechrail.application.alignment import FixedTextAligner
    from speechrail.domain.alignment import AlignmentRequest
    from speechrail.domain.audio_timeline import SampleSpan

    class Client:
        async def align_text(
            self, pcm: bytes, *, text: str, language: str | None
        ) -> tuple[tuple[str, float, float], ...]:
            raise error_type("private transcript /private/model")

    request = AlignmentRequest(
        task_id="task", epoch="epoch", utterance_id="item", transcript_revision=1,
        pcm16=b"\x00\x00" * 800, span=SampleSpan(0, 800), text="fixture", language="en",
    )
    with caplog.at_level(logging.WARNING):
        result = asyncio.run(FixedTextAligner(Client()).align(request))
    assert result.failure == expected_code
    assert "stage=worker" in caplog.text
    exception_name = "ValueError" if issubclass(error_type, ValueError) else error_type.__name__
    assert f"exception_type={exception_name}" in caplog.text
    assert "private" not in caplog.text
    assert all(record.exc_info is None for record in caplog.records)


@pytest.mark.parametrize(
    ("mode", "expected_code"),
    [
        ("text_mismatch", "text_mismatch"),
        ("explode", "alignment_failed"),
        ("mismatched_pcm", "alignment_pcm_mismatch"),
    ],
)
def test_realtime_alignment_failure_has_a_reason_counter_and_safe_log(
    mode: str, expected_code: str, caplog: pytest.LogCaptureFixture
) -> None:
    from speechrail.application.realtime_auxiliary import (
        RealtimeAuxiliaryOwner,
        RealtimeAuxiliaryPorts,
    )
    from speechrail.application.realtime_state import AsrIdentity, FrozenTranscript
    from speechrail.config import Settings
    from speechrail.domain.alignment import AlignmentRequest, AlignmentResult
    from speechrail.runtime.alignment_admission import AlignmentAdmission
    from speechrail.runtime.diarization_admission import DiarizationAdmission

    class Input:
        identity = AsrIdentity(generation=1, epoch=1, item_id="next", transcript_revision=0)

        async def wait_finals(self) -> None:
            pass

    class Aligner:
        async def align(self, request: AlignmentRequest) -> AlignmentResult:
            if mode == "explode":
                raise RuntimeError("private transcript /private/model")
            return AlignmentResult(
                task_id=request.task_id,
                epoch=request.epoch,
                utterance_id=request.utterance_id,
                transcript_revision=request.transcript_revision,
                units=(),
                failure="text_mismatch",
            )

    async def scenario() -> tuple[list[dict[str, object]], Metrics]:
        events: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> int:
            events.append(event)
            return len(events)

        metrics = Metrics()
        owner = RealtimeAuxiliaryOwner(
            ports=RealtimeAuxiliaryPorts(
                Aligner(), None, AlignmentAdmission(), DiarizationAdmission(),
                metrics, lambda: True, lambda: "ready",
            ),
            settings=Settings(qwen3_model_dir=None, qwen3_python=None),
            task_id="task",
            session_id="session",
            send=send,
            config=lambda: {},
            input_source=Input(),
        )
        await owner.configure(alignment=True, diarization=False)
        owner.start_alignment(FrozenTranscript(
            task_id="task", epoch=1, generation=1, item_id="original",
            transcript="safe fixture", transcript_revision=1,
            item_start_wire=0, item_end_wire=1_200,
            item_start_kernel=0, item_end_kernel=800,
            pcm16=b"\x00\x00" * (799 if mode == "mismatched_pcm" else 800),
            overflow=False, degraded_reason=None,
        ))
        await owner._wait_for_pending_alignment()
        await owner.close()
        return events, metrics

    with caplog.at_level(logging.WARNING):
        events, metrics = asyncio.run(scenario())
    failed = next(event for event in events if event["type"] == "speechrail.alignment.failed")
    assert failed["error"]["code"] == expected_code
    assert failed["error"]["message"] == alignment_failure_message(expected_code)
    assert (
        f'speechrail_asr_alignment_failures_total{{reason="{expected_code}"}} 1'
    ) in metrics.render_prometheus()
    assert f"code={expected_code}" in caplog.text
    assert "audio_samples=" in caplog.text
    assert "expected_audio_samples=800" in caplog.text
    assert "private" not in caplog.text
    assert "safe fixture" not in caplog.text
    assert all(record.exc_info is None for record in caplog.records)
