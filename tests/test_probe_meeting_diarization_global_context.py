from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "examples" / "perf"))

from probe_meeting_diarization_global_context import (
    _clip_segments_to_duration,
    _validate_probe_payload,
)


def test_global_probe_payload_accepts_ordered_anonymous_segments() -> None:
    payload = {
        "schema_version": 1,
        "results": [
            {
                "audio_loading_runtime_seconds": 0.1,
                "preprocessing_profiles": [
                    {
                        "preprocessing_index": 0,
                        "preparation_runtime_seconds": 12.5,
                        "candidates": [
                            {
                                "candidate_index": 0,
                                "runtime_seconds": 0.3,
                                "segments": [
                                    {"start": 0.1, "end": 1.2, "speaker": "S1"},
                                    {"start": 1.2, "end": 1.8, "speaker": "S2"},
                                ],
                            }
                        ],
                    }
                ],
            }
        ],
    }

    result = _validate_probe_payload(
        payload,
        expected_count=1,
        expected_preprocessing_count=1,
        expected_candidate_count=1,
    )

    assert result == payload["results"]


@pytest.mark.parametrize(
    "payload",
    [
        {"schema_version": 1, "results": []},
        {
            "schema_version": 1,
            "results": [
                {
                    "audio_loading_runtime_seconds": 0.1,
                    "preprocessing_profiles": [
                        {
                            "preprocessing_index": 0,
                            "preparation_runtime_seconds": 1.0,
                            "candidates": [
                                {
                                    "candidate_index": 0,
                                    "runtime_seconds": 0.3,
                                    "segments": [
                                        {"start": 0.0, "end": 1.0, "speaker": "Speaker 1"}
                                    ],
                                }
                            ],
                        }
                    ],
                }
            ],
        },
        {
            "schema_version": 1,
            "results": [
                {
                    "audio_loading_runtime_seconds": 0.1,
                    "preprocessing_profiles": [
                        {
                            "preprocessing_index": 0,
                            "preparation_runtime_seconds": 1.0,
                            "candidates": [
                                {
                                    "candidate_index": 0,
                                    "runtime_seconds": 0.0,
                                    "segments": [],
                                }
                            ],
                        }
                    ],
                }
            ],
        },
    ],
)
def test_global_probe_payload_rejects_wrong_scope_or_non_anonymous_data(payload) -> None:
    with pytest.raises(ValueError):
        _validate_probe_payload(
            payload,
            expected_count=1,
            expected_preprocessing_count=1,
            expected_candidate_count=1,
        )


def test_global_probe_clips_sdk_padding_to_the_exact_audio_duration() -> None:
    segments = [
        {"start": 0.1, "end": 1.0, "speaker": "S1"},
        {"start": 9.8, "end": 10.118, "speaker": "S2"},
    ]

    clipped, count = _clip_segments_to_duration(segments, duration=10.0)

    assert clipped == [
        {"start": 0.1, "end": 1.0, "speaker": "S1"},
        {"start": 9.8, "end": 10.0, "speaker": "S2"},
    ]
    assert count == 1


def test_global_probe_rejects_segments_more_than_one_second_past_audio_end() -> None:
    with pytest.raises(ValueError, match="exceeds the supported SDK tail-padding bound"):
        _clip_segments_to_duration(
            [{"start": 9.0, "end": 11.01, "speaker": "S1"}], duration=10.0
        )
