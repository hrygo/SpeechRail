"""One vocabulary for per-utterance latency observations.

These numbers describe what a render or an utterance actually did. They are
**observations**: they never feed admission, retry, budget or quality
decisions, and a missing value is normal rather than an error. The same field
names are used in the Realtime terminal event and in the HTTP response
headers so callers never have to learn two vocabularies for one measurement.

All three fields are optional on the wire:

* ``ttfa_ms`` — request accepted to the first audio byte available to the
  caller. Known before a streamed body starts, so it can travel in headers.
* ``audio_ms`` — delivered audio duration. Only known once delivery ends.
* ``rtf`` — wall-clock time divided by audio duration. Only known once
  delivery ends. On an incremental path this includes any time spent waiting
  for the consumer, so it is a lower bound on model speed, not a model
  benchmark.
"""

from __future__ import annotations

import math
from collections.abc import Mapping

TTFA_FIELD = "ttfa_ms"
AUDIO_FIELD = "audio_ms"
RTF_FIELD = "rtf"

#: Wire name for every observation that can travel in an HTTP header. Field
#: names stay snake_case in JSON payloads; headers use the house style.
LATENCY_HEADERS: dict[str, str] = {
    TTFA_FIELD: "SpeechRail-Ttfa-Ms",
    AUDIO_FIELD: "SpeechRail-Audio-Ms",
    RTF_FIELD: "SpeechRail-Rtf",
}


def latency_fields(
    *,
    ttfa_sec: float | None,
    audio_sec: float,
    inference_sec: float,
) -> dict[str, int | float]:
    """Render the shared observation payload; never raise on odd timings.

    A clock that steps backwards, a zero-length render or a missing first
    audio timestamp must degrade to "no observation", never to a negative
    number that a caller would read as a real measurement.
    """

    fields: dict[str, int | float] = {}
    if ttfa_sec is not None and math.isfinite(ttfa_sec) and ttfa_sec >= 0:
        fields[TTFA_FIELD] = round(ttfa_sec * 1000)
    if math.isfinite(audio_sec) and audio_sec > 0:
        fields[AUDIO_FIELD] = round(audio_sec * 1000)
        if math.isfinite(inference_sec) and inference_sec >= 0:
            fields[RTF_FIELD] = round(inference_sec / audio_sec, 4)
    return fields


def latency_headers(fields: Mapping[str, int | float]) -> dict[str, str]:
    """Convert observations to response headers, skipping anything unmeasured."""

    return {
        LATENCY_HEADERS[name]: str(value)
        for name, value in fields.items()
        if name in LATENCY_HEADERS
    }
