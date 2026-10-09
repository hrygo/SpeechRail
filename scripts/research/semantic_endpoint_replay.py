"""Offline boundary-policy research; no model, service, audio file or production hook."""

from __future__ import annotations

import json
from dataclasses import dataclass

from speechrail.realtime.speech_admission import SpeechAdmission

FRAME_MS = 32
STOP_FRAMES = 13  # production ceil(400 / 32)
HOLD_FRAMES = 10
INCOMPLETE_SUFFIXES = ("如果", "但是", "嗯", "and")


@dataclass(frozen=True)
class Trace:
    name: str
    first_frames: int = 20
    gap_frames: int = 16
    second_frames: int = 20
    text: str = ""
    text_delay_ms: int = 0  # availability relative to baseline endpoint
    expected_segments: int = 1


TRACES = (
    Trace("short_pause_incomplete", text="如果"),
    Trace("short_pause_complete", text="完成。", expected_segments=2),
    Trace("filler_then_continuation", text="嗯"),
    Trace("standalone_affirmation", text="嗯", second_frames=0),
    Trace("interruption_same_suffix", text="如果", expected_segments=2),
    Trace("transient_noise", first_frames=2, second_frames=0, expected_segments=0),
    Trace("sustained_noise", first_frames=4, second_frames=0, expected_segments=0),
    Trace("mixed_known_suffix", text="and"),
    Trace("mixed_unknown_suffix", text="请 wait"),
    Trace("late_partial", text="如果", text_delay_ms=400),
    Trace("missing_partial", text=""),
    Trace("pause_beyond_cap", text="如果", gap_frames=30),
)


def baseline(trace: Trace) -> tuple[list[int], list[int]]:
    """Replay the current production admission state machine with synthetic scores."""
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=3,
        stop_frames=STOP_FRAMES,
        prefix_samples=4800,
        frame_samples=512,
        sample_rate=16000,
    )
    probabilities = (
        [0.9] * trace.first_frames
        + [0.1] * trace.gap_frames
        + [0.9] * trace.second_frames
        + [0.1] * (STOP_FRAMES + HOLD_FRAMES)
    )
    starts: list[int] = []
    ends: list[int] = []
    for index, probability in enumerate(probabilities):
        # Zero PCM is a transport placeholder, not an acoustic signal or recording.
        decisions = gate.push(b"\0" * 1024, start_sample=index * 512, probability=probability)
        for decision in decisions:
            if decision.kind == "start":
                starts.append((index + 1) * FRAME_MS)
            elif decision.kind == "end":
                ends.append((index + 1) * FRAME_MS)
    assert len(starts) == len(ends)
    assert not gate.finish()
    return starts, ends


def candidate(trace: Trace, starts: list[int], ends: list[int]) -> list[int]:
    """Shadow lexical plan: hold only the first boundary, never discard admitted text.

    This compares a hypothetical decision policy over admission facts. It does
    not merge ASR sessions or implement a production audio-buffer lifecycle.
    The synthetic partial is available at the first baseline endpoint or absent.
    """
    if not ends or trace.text_delay_ms > 0 or not trace.text.endswith(INCOMPLETE_SUFFIXES):
        return ends.copy()
    deadline = ends[0] + HOLD_FRAMES * FRAME_MS
    # Onset uses actual debounced admission time, not an oracle future timestamp.
    if len(starts) > 1 and starts[1] <= deadline:
        return ends[1:]
    return [deadline, *ends[1:]]


def run() -> dict[str, object]:
    rows: list[dict[str, object]] = []
    for trace in TRACES:
        starts, ends = baseline(trace)
        planned = candidate(trace, starts, ends)
        baseline_error = len(ends) - trace.expected_segments
        candidate_error = len(planned) - trace.expected_segments
        # Delay compares the last commit decision on the same synthetic timeline.
        rows.append(
            {
                "name": trace.name,
                "expected_segments": trace.expected_segments,
                "baseline_segments": len(ends),
                "candidate_segments": len(planned),
                "baseline_error": baseline_error,
                "candidate_error": candidate_error,
                "first_admission_ms": starts[0] if starts else None,
                "last_commit_delta_ms": planned[-1] - ends[-1] if ends else 0,
            }
        )
    return {
        "scope": "synthetic probabilities and supplied partials; not ASR quality or latency",
        "frame_ms": FRAME_MS,
        "baseline_hangover_ms": STOP_FRAMES * FRAME_MS,
        "maximum_extra_hold_ms": HOLD_FRAMES * FRAME_MS,
        "maximum_extra_pcm16_bytes": HOLD_FRAMES * 512 * 2,
        "baseline_error_traces": sum(row["baseline_error"] != 0 for row in rows),
        "candidate_error_traces": sum(row["candidate_error"] != 0 for row in rows),
        "rows": rows,
    }


def verify_counterexample() -> None:
    """Same observable facts cannot satisfy both independent turn annotations."""
    continuation, interruption = TRACES[0], TRACES[4]
    first = baseline(continuation)
    second = baseline(interruption)
    assert first == second
    assert continuation.text == interruption.text
    assert continuation.expected_segments != interruption.expected_segments
    assert candidate(continuation, *first) == candidate(interruption, *second)


if __name__ == "__main__":
    verify_counterexample()
    print(json.dumps(run(), ensure_ascii=False, indent=2))
