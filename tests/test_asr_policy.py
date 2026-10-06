from __future__ import annotations

from dataclasses import FrozenInstanceError
from typing import Any

import pytest
from pydantic import ValidationError

from realtime_wire import DEFAULT_ASR_MODEL, session_update
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    apply_session_update,
    transcription_segment_closed,
)
from speechrail.domain.asr_policy import ASRPolicy, resolve_effective_max_segment_ms
from speechrail.domain.ports import RealtimeTranscriptionOptions, StreamingAsrEvent


def _with_asr_policy(policy: dict[str, object]) -> dict[str, Any]:
    event = session_update(task="transcription")
    event["session"]["speechrail"]["asr"] = policy
    return event


def test_asr_policy_defaults_are_immutable_and_round_trip() -> None:
    policy = ASRPolicy()

    assert policy.preview_interval_ms == 1_000
    assert policy.max_segment_ms == 20_000
    assert policy.finalization == "full_segment"
    assert policy.final_deadline_ms is None
    assert policy.rollback_tokens == 5
    with pytest.raises(FrozenInstanceError):
        policy.preview_interval_ms = 500  # type: ignore[misc]
    assert ASRPolicy.from_mapping({}) == policy


def test_asr_policy_rollback_tokens_round_trip() -> None:
    assert ASRPolicy.from_mapping({"rollback_tokens": 0}).rollback_tokens == 0
    assert ASRPolicy.from_mapping({"rollback_tokens": 10}).rollback_tokens == 10


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("preview_interval_ms", True),
        ("preview_interval_ms", 100.0),
        ("preview_interval_ms", 99),
        ("preview_interval_ms", 5_001),
        ("max_segment_ms", False),
        ("max_segment_ms", 20_000.0),
        ("max_segment_ms", 999),
        ("max_segment_ms", 30_001),
        ("final_deadline_ms", True),
        ("final_deadline_ms", 10_000.0),
        ("final_deadline_ms", 0),
        ("rollback_tokens", True),
        ("rollback_tokens", 5.0),
        ("rollback_tokens", -1),
        ("rollback_tokens", 33),
    ],
)
def test_asr_policy_rejects_invalid_numeric_values(field: str, value: object) -> None:
    with pytest.raises(ValueError):
        ASRPolicy.from_mapping({field: value})


def test_asr_policy_rejects_unknown_fields_and_finalization() -> None:
    for value in (
        {"unknown": 1},
        {"finalization": "full"},
        {"finalization": True},
        {"preview_interval_ms": "1000"},
    ):
        with pytest.raises(ValueError):
            ASRPolicy.from_mapping(value)


def test_asr_policy_requires_segment_budget_to_cover_preview_interval() -> None:
    with pytest.raises(ValueError, match="max_segment_ms"):
        ASRPolicy(preview_interval_ms=1_001, max_segment_ms=1_000)


def test_final_deadline_inherits_request_timeout_and_cannot_exceed_it() -> None:
    inherited = ASRPolicy()
    assert inherited.effective_deadline_ms(request_timeout_ms=8_000) == 8_000

    explicit = ASRPolicy(final_deadline_ms=4_000)
    assert explicit.effective_deadline_ms(request_timeout_ms=8_000) == 4_000
    with pytest.raises(ValueError, match="request timeout"):
        ASRPolicy(final_deadline_ms=8_001).effective_deadline_ms(request_timeout_ms=8_000)
    for invalid_timeout in (True, 0, 1.5):
        with pytest.raises(ValueError):
            inherited.effective_deadline_ms(request_timeout_ms=invalid_timeout)


def test_effective_segment_budget_takes_the_smallest_hard_limit() -> None:
    policy = ASRPolicy(max_segment_ms=20_000)

    assert resolve_effective_max_segment_ms(
        policy,
        service_max_segment_ms=16_000,
        capability_max_segment_ms=8_000,
        decoder_max_segment_ms=30_000,
    ) == 8_000
    assert resolve_effective_max_segment_ms(
        policy,
        service_max_segment_ms=24_000,
        capability_max_segment_ms=None,
        decoder_max_segment_ms=30_000,
    ) == 20_000


@pytest.mark.parametrize("limit", [True, 8_000.0, 0, 999])
def test_effective_segment_budget_rejects_invalid_limits(limit: object) -> None:
    with pytest.raises(ValueError):
        resolve_effective_max_segment_ms(
            ASRPolicy(),
            service_max_segment_ms=limit,
            capability_max_segment_ms=None,
            decoder_max_segment_ms=30_000,
        )


def test_realtime_options_carry_policy_and_effective_retention_budget() -> None:
    policy = ASRPolicy(max_segment_ms=8_000)

    assert RealtimeTranscriptionOptions(asr_policy=policy).effective_max_segment_ms is None
    options = RealtimeTranscriptionOptions(
        asr_policy=policy,
        effective_max_segment_ms=4_000,
    )
    assert options.effective_max_segment_ms == 4_000
    with pytest.raises(ValueError):
        RealtimeTranscriptionOptions(asr_policy=policy, effective_max_segment_ms=8_001)


def test_streaming_asr_event_has_strict_decoded_sample_watermark() -> None:
    for watermark in (0, 1, 16_000):
        event = StreamingAsrEvent(
            kind="partial",
            text="draft",
            sample_watermark=watermark,
        )
        assert event.sample_watermark == watermark

    for watermark in (True, 1.0, -1):
        with pytest.raises(ValidationError):
            StreamingAsrEvent(
                kind="partial",
                text="draft",
                sample_watermark=watermark,
            )


def test_session_update_parses_policy_and_echoes_effective_limits() -> None:
    event = _with_asr_policy(
        {
            "preview_interval_ms": 800,
            "max_segment_ms": 20_000,
            "finalization": "full_segment",
        }
    )
    response, config = apply_session_update(
        event,
        session_id="sess-asr-policy",
        asr_model=DEFAULT_ASR_MODEL,
        registered_asr=frozenset({DEFAULT_ASR_MODEL}),
        request_timeout_ms=12_000,
        service_max_segment_ms=18_000,
        capability_max_segment_ms=8_000,
        decoder_max_segment_ms=30_000,
    )

    assert config["asr_policy"] == ASRPolicy(
        preview_interval_ms=800,
        max_segment_ms=20_000,
        finalization="full_segment",
    )
    assert config["effective_max_segment_ms"] == 8_000
    assert response["type"] == "session.updated"
    echoed = response["session"]["speechrail"]["asr"]
    assert echoed == {
        "preview_interval_ms": 800,
        "max_segment_ms": 20_000,
        "finalization": "full_segment",
        "rollback_tokens": 5,
        "final_deadline_ms": 12_000,
        "effective_max_segment_ms": 8_000,
    }


def test_unrelated_session_update_preserves_existing_asr_policy() -> None:
    policy = ASRPolicy(
        preview_interval_ms=600,
        max_segment_ms=8_000,
        finalization="streaming_finalize",
    )
    _, current_config = apply_session_update(
        _with_asr_policy(
            {
                "preview_interval_ms": 600,
                "max_segment_ms": 8_000,
                "finalization": "streaming_finalize",
            }
        ),
        session_id="sess-asr-policy",
        asr_model=DEFAULT_ASR_MODEL,
        registered_asr=frozenset({DEFAULT_ASR_MODEL}),
        request_timeout_ms=12_000,
        service_max_segment_ms=18_000,
        capability_max_segment_ms=8_000,
        decoder_max_segment_ms=30_000,
    )

    response, config = apply_session_update(
        session_update(task="transcription"),
        session_id="sess-asr-policy",
        asr_model=DEFAULT_ASR_MODEL,
        registered_asr=frozenset({DEFAULT_ASR_MODEL}),
        current_config=current_config,
        request_timeout_ms=12_000,
        service_max_segment_ms=18_000,
        capability_max_segment_ms=8_000,
        decoder_max_segment_ms=30_000,
    )

    assert config["asr_policy"] == policy
    assert config["effective_max_segment_ms"] == 8_000
    assert response["session"]["speechrail"]["asr"] == {
        "preview_interval_ms": 600,
        "max_segment_ms": 8_000,
        "finalization": "streaming_finalize",
        "rollback_tokens": 5,
        "final_deadline_ms": 12_000,
        "effective_max_segment_ms": 8_000,
    }


def test_session_update_rejects_invalid_policy_atomically() -> None:
    original: dict[str, object] = {"task": "caption", "kept": True}
    event = _with_asr_policy(
        {
            "preview_interval_ms": 2_000,
            "max_segment_ms": 1_000,
            "finalization": "full_segment",
        }
    )

    with pytest.raises(RealtimeAdapterError) as failure:
        apply_session_update(
            event,
            session_id="sess-asr-policy",
            asr_model=DEFAULT_ASR_MODEL,
            registered_asr=frozenset({DEFAULT_ASR_MODEL}),
            current_config=original,
            request_timeout_ms=12_000,
        )

    assert failure.value.code == "asr_policy_invalid"
    assert original == {"task": "caption", "kept": True}


def test_session_update_rejects_unknown_asr_fields() -> None:
    event = _with_asr_policy({"unexpected": 1})

    with pytest.raises(RealtimeAdapterError) as failure:
        apply_session_update(
            event,
            session_id="sess-asr-policy",
            asr_model=DEFAULT_ASR_MODEL,
            registered_asr=frozenset({DEFAULT_ASR_MODEL}),
        )

    assert failure.value.code == "asr_policy_invalid"


def test_session_update_rejects_deadline_beyond_request_timeout() -> None:
    event = _with_asr_policy(
        {
            "final_deadline_ms": 5_001,
        }
    )

    with pytest.raises(RealtimeAdapterError) as failure:
        apply_session_update(
            event,
            session_id="sess-asr-policy",
            asr_model=DEFAULT_ASR_MODEL,
            registered_asr=frozenset({DEFAULT_ASR_MODEL}),
            request_timeout_ms=5_000,
        )

    assert failure.value.code == "asr_policy_invalid"


def test_session_update_requires_timeout_context_for_explicit_deadline() -> None:
    event = _with_asr_policy({"final_deadline_ms": 5_000})

    with pytest.raises(RealtimeAdapterError) as failure:
        apply_session_update(
            event,
            session_id="sess-asr-policy",
            asr_model=DEFAULT_ASR_MODEL,
            registered_asr=frozenset({DEFAULT_ASR_MODEL}),
        )

    assert failure.value.code == "asr_policy_invalid"


def test_segment_closed_uses_nonempty_half_open_wire_sample_span() -> None:
    event = transcription_segment_closed(
        item_id="item-asr-1",
        sample_span=(12, 24_012),
        reason="client_commit",
    )

    assert event == {
        "type": "speechrail.transcription.segment_closed",
        "item_id": "item-asr-1",
        "sample_span": {"start": 12, "end": 24_012},
        "reason": "client_commit",
    }
    for span in ((0, 0), (2, 1), (-1, 2), (True, 2), (0, 1.5)):
        with pytest.raises(ValueError):
            transcription_segment_closed(
                item_id="item-asr-1",
                sample_span=span,  # type: ignore[arg-type]
                reason="vad",
            )


@pytest.mark.parametrize("reason", ["vad", "budget_rollover"])
def test_segment_closed_without_client_commit_rejects_commit_id(reason: str) -> None:
    with pytest.raises(ValueError):
        transcription_segment_closed(
            item_id="item-asr-1",
            sample_span=(0, 24_000),
            reason=reason,
            commit_event_id="evt-commit-1",
        )


def test_client_commit_segment_may_omit_or_include_commit_id() -> None:
    without_id = transcription_segment_closed(
        item_id="item-asr-1",
        sample_span=(0, 24_000),
        reason="client_commit",
    )
    with_id = transcription_segment_closed(
        item_id="item-asr-1",
        sample_span=(0, 24_000),
        reason="client_commit",
        commit_event_id="evt-commit-1",
    )

    assert "commit_event_id" not in without_id
    assert with_id["commit_event_id"] == "evt-commit-1"
