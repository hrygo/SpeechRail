from __future__ import annotations

import pytest
from pydantic import ValidationError

from speechrail.domain.diarization import (
    DiarizationAssignment,
    DiarizationConfig,
    DiarizationSpeaker,
    DiarizationUpdate,
)


def test_diarization_contract_accepts_anonymous_overlap_and_canonical_mapping() -> None:
    config = DiarizationConfig(enabled=True, speaker_count_hint=4, finalize=True)
    update = DiarizationUpdate(
        assignments=(
            DiarizationAssignment(
                segment_id="seg-1",
                speakers=(
                    DiarizationSpeaker(id="spk_01", confidence=0.91),
                    DiarizationSpeaker(id="spk_02", confidence=0.73),
                ),
            ),
        ),
        mapping={"spk_03": "spk_01"},
    )

    assert config.speaker_count_hint == 4
    assert update.assignments[0].primary_speaker_id == "spk_01"
    assert update.mapping == {"spk_03": "spk_01"}


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        ({"enabled": True, "speaker_count_hint": 0}, "speaker_count_hint"),
        ({"enabled": True, "speaker_count_hint": 9}, "speaker_count_hint"),
        ({"enabled": True, "speaker_count_hint": 1, "finalize": "yes"}, "finalize"),
    ],
)
def test_diarization_config_rejects_invalid_public_options(
    payload: dict[str, object], message: str
) -> None:
    with pytest.raises(ValidationError, match=message):
        DiarizationConfig.model_validate(payload)


def test_diarization_update_rejects_noncanonical_mapping_and_duplicate_speakers() -> None:
    with pytest.raises(ValidationError, match="must not map to itself"):
        DiarizationUpdate(mapping={"spk_01": "spk_01"})

    with pytest.raises(ValidationError, match="unique"):
        DiarizationAssignment(
            segment_id="seg-1",
            speakers=(
                DiarizationSpeaker(id="spk_01", confidence=0.9),
                DiarizationSpeaker(id="spk_01", confidence=0.8),
            ),
        )
