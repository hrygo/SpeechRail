from speechrail.compatibility.presenters import legacy_snapshot
from speechrail.compatibility.wlk import normalize_snapshot


def test_wlk_snapshot_is_normalized_before_legacy_presentation() -> None:
    window = normalize_snapshot(
        {
            "lines": [{"start": "00:00:01.2", "end": 2.5, "text": " hello ", "speaker": 2}],
            "buffer_transcription": "draft",
            "vendor_trace": "must not cross the boundary",
        },
        source_epoch=4,
    )

    assert window.segments[0].start_ms == 1200
    assert window.segments[0].speaker == "2"
    assert legacy_snapshot(window) == {
        "type": "partial",
        "lines": [{"start": 1.2, "end": 2.5, "text": "hello", "speaker": "2"}],
        "buffer_transcription": "draft",
    }
