"""Private eight-slot probe packet contract; no production capability claim.

The native streaming candidate will emit causal 10 ms probability frames.
Validation here is independent of the older four-slot adapter.
"""

from __future__ import annotations

import math
from collections.abc import Mapping

from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.diarization.types import ActivityFrame, ActivityUpdate

SDK_REVISION = "503b4bd1bbf7220882de39fe8ae6716aae4132da"
FRAME_SAMPLES = 160
SLOTS = 8


def _integer(value: object) -> int:
    if type(value) is not int or value < 0:
        raise ValueError("candidate sample/step must be a nonnegative integer")
    return value


def candidate_activity_update(
    response: Mapping[str, object],
    *,
    epoch: str,
    step_id: int,
    processed: int,
    accepted: int,
    operation: str,
) -> ActivityUpdate:
    """Validate every raw frame before clipping only the final padded tail.

    Returned frames are stable, never revised and never silence-filled while
    the model is still buffering context. This does not detect a ninth person.
    """
    _integer(step_id)
    _integer(processed)
    _integer(accepted)
    if (
        not isinstance(epoch, str) or not epoch
        or operation not in {"append", "finish"} or processed > accepted
        or not isinstance(response, Mapping)
    ):
        raise ValueError("invalid candidate request state")
    if (
        type(response.get("protocol_version")) is not int
        or response["protocol_version"] != 3
        or response.get("backend") != "nemotron3_candidate"
        or response.get("sdk_revision") != SDK_REVISION
        or response.get("epoch") != epoch
        or response.get("operation") != operation
        or response.get("ok") is not True
    ):
        raise ValueError("candidate packet identity mismatch")
    endpoint = _integer(response.get("processed_through"))
    stable = _integer(response.get("stable_through"))
    padded_end = ((accepted + FRAME_SAMPLES - 1) // FRAME_SAMPLES) * FRAME_SAMPLES
    if (
        endpoint % FRAME_SAMPLES
        or not processed <= endpoint <= padded_end
        or stable != endpoint
        or (operation == "append" and endpoint > accepted)
        or (operation == "finish" and endpoint != padded_end)
    ):
        raise ValueError("candidate watermark is invalid")
    raw_frames = response.get("frames")
    if not isinstance(raw_frames, list) or len(raw_frames) > 2048:
        raise ValueError("candidate frames must be bounded")
    cursor = processed
    frames = []
    for raw in raw_frames:
        if not isinstance(raw, Mapping) or "active_slots" in raw:
            raise ValueError("candidate must emit probabilities, not invented slot labels")
        start, end = _integer(raw.get("start")), _integer(raw.get("end"))
        scores = raw.get("scores")
        if (
            start != cursor or end != start + FRAME_SAMPLES or end > endpoint
            or not isinstance(scores, list) or len(scores) != SLOTS
            or any(type(s) not in {float, int} or not 0 <= s <= 1 or not math.isfinite(s)
                   for s in scores)
        ):
            raise ValueError("candidate frame coverage or eight-slot probabilities are invalid")
        if start < accepted:
            frames.append(ActivityFrame(
                span=SampleSpan(start, min(end, accepted)),
                scores=tuple(float(score) for score in scores),
                active_slots=frozenset(slot for slot, score in enumerate(scores) if score > 0.5),
            ))
        cursor = end
    if cursor != endpoint:
        raise ValueError("candidate omitted frames before its watermark")
    actual_end = min(endpoint, accepted)
    return ActivityUpdate(
        epoch=epoch, step_id=step_id, replace_span=SampleSpan(processed, actual_end),
        frames=tuple(frames), processed_through=actual_end, stable_through=actual_end,
    )
