"""Pure evidence ledger for fixed text and continuous speaker activity."""

from __future__ import annotations

from bisect import bisect_left, bisect_right
from collections.abc import Callable, Iterable
from dataclasses import dataclass, replace
from hashlib import blake2b
from itertools import accumulate
from math import fsum, isfinite

from speechrail.domain.audio_timeline import CORE_SAMPLE_RATE, SampleSpan

from .types import ActivityFrame, ActivityUpdate, Attribution, TextUnit


def union_support(unit: SampleSpan, activities: Iterable[SampleSpan]) -> float:
    """Return the fraction of ``unit`` covered by the union of activity spans."""

    if unit.end == unit.start:
        raise ValueError("cannot calculate support for a zero-length unit")
    clipped = sorted(
        (max(unit.start, activity.start), min(unit.end, activity.end))
        for activity in activities
        if activity.end > unit.start and activity.start < unit.end
    )
    covered = 0
    previous_end = unit.start
    for start, end in clipped:
        if end <= previous_end:
            continue
        covered += end - max(start, previous_end)
        previous_end = end
    return covered / (unit.end - unit.start)


def bracket_fill_speaker_labels(
    attributions: Iterable[Attribution | None],
) -> dict[str, str | None]:
    """Fill final unknowns bracketed by the same final speaker.

    The caller supplies one frozen ASR item in text order. A contiguous run of
    final ``insufficient_evidence`` units can inherit a label only when the
    units immediately before and after the run are final and carry the same
    known anonymous label. Provisional units, every other unknown reason and
    item edges stop the run, so this rule cannot bridge degraded evidence or a
    second transcription item. The activity evidence and ``active_speakers``
    remain unchanged; this is a deterministic projection of final context.
    """

    ordered = tuple(attributions)
    fillable = tuple(
        attribution is not None
        and attribution.speaker is None
        and attribution.state == "final"
        and attribution.reason == "insufficient_evidence"
        for attribution in ordered
    )
    labels = {
        attribution.unit_id: attribution.speaker
        for attribution in ordered
        if attribution is not None
    }
    index = 0
    while index < len(ordered):
        if not fillable[index]:
            index += 1
            continue
        run_start = index
        while index < len(ordered) and fillable[index]:
            index += 1
        run_end = index
        if run_start == 0 or run_end == len(ordered):
            continue
        previous = ordered[run_start - 1]
        following = ordered[run_end]
        if (
            previous is None
            or following is None
            or previous.state != "final"
            or following.state != "final"
            or previous.reason is not None
            or following.reason is not None
            or previous.speaker is None
            or previous.speaker != following.speaker
        ):
            continue
        for attribution in ordered[run_start:run_end]:
            assert attribution is not None
            labels[attribution.unit_id] = previous.speaker
    return labels


@dataclass(frozen=True, slots=True)
class AttributionPolicy:
    min_support: float = 0.60
    min_margin: float = 0.10
    continuity_gap_seconds: float = 0.50

    def __post_init__(self) -> None:
        if not 0 <= self.min_support <= 1 or not 0 <= self.min_margin <= 1:
            raise ValueError("attribution policy values must be in [0, 1]")
        if (
            not isfinite(self.continuity_gap_seconds)
            or self.continuity_gap_seconds < 0
        ):
            raise ValueError("continuity gap must be finite and non-negative")


@dataclass(slots=True)
class _UnitState:
    unit: TextUnit
    attribution: Attribution


class AttributionLedger:
    """Serial, session-scoped attribution state with monotonic watermarks."""

    def __init__(
        self,
        *,
        accepted_samples: Callable[[], int],
        policy: AttributionPolicy | None = None,
        label_mode: str = "sortformer",
    ) -> None:
        self._accepted_samples = accepted_samples
        self._policy = policy or AttributionPolicy()
        if label_mode not in {"sortformer", "meeting_dynamic"}:
            raise ValueError("unknown diarization label mode")
        self._label_mode = label_mode
        self._epoch: str | None = None
        self._steps: dict[int, bytes] = {}
        self._latest_step = -1
        self._compacted_before = 0
        self._frames: tuple[ActivityFrame, ...] = ()
        self._frame_index: tuple[tuple[int, ...], tuple[int, ...]] | None = None
        self._processed_through = 0
        self._stable_through = 0
        self._slot_labels: dict[int, str] = {}
        self._units: dict[str, _UnitState] = {}
        # Final, known labels and the end of the most recent final unit. This
        # small amount of state survives activity compaction so a continuous
        # voice can keep its label without rescanning unrelated history.
        self._continuity_label: str | None = None
        self._continuity_end = 0

    @property
    def processed_through(self) -> int:
        return self._processed_through

    @property
    def stable_through(self) -> int:
        return self._stable_through

    def register(self, item_id: str, units: tuple[TextUnit, ...]) -> tuple[Attribution, ...]:
        """Register immutable units and return their current attribution snapshots."""

        if not item_id:
            raise ValueError("item_id must not be empty")
        emitted: list[Attribution] = []
        for unit in units:
            if unit.id in self._units:
                raise ValueError(f"duplicate text unit id: {unit.id}")
            attribution = self._evaluate(unit, revision=1)
            self._units[unit.id] = _UnitState(unit=unit, attribution=attribution)
            self._advance_continuity(self._units[unit.id])
            emitted.append(attribution)
        return tuple(emitted)

    def apply(self, update: ActivityUpdate) -> tuple[Attribution, ...]:
        """Apply one activity replacement and return changed speaker revisions."""

        accepted = self._accepted_samples()
        if update.processed_through > accepted:
            raise ValueError("processed watermark exceeds accepted audio")
        if self._epoch is None:
            self._epoch = update.epoch
        elif update.epoch != self._epoch:
            raise ValueError("activity update belongs to a stale epoch")
        fingerprint = blake2b(repr(update).encode(), digest_size=16).digest()
        previous = self._steps.get(update.step_id)
        if previous is not None:
            if previous != fingerprint:
                raise ValueError("duplicate activity step has different payload")
            return ()
        if update.step_id <= self._latest_step:
            raise ValueError("activity step is older than the replay window")
        if update.processed_through < self._processed_through:
            raise ValueError("processed watermark cannot move backwards")
        if update.stable_through < self._stable_through:
            raise ValueError("stable watermark cannot move backwards")
        if update.replace_span.start < self._stable_through:
            raise ValueError("activity update attempts to replace stable frames")
        self._steps[update.step_id] = fingerprint
        self._latest_step = update.step_id
        while len(self._steps) > 64:
            self._steps.pop(next(iter(self._steps)))
        previous_stable = self._stable_through
        self._processed_through = update.processed_through
        self._stable_through = update.stable_through
        if (
            not update.frames
            and update.replace_span.start == update.replace_span.end
            and update.stable_through == previous_stable
        ):
            return ()
        retained: list[ActivityFrame] = []
        for frame in self._frames:
            if (
                frame.span.end <= update.replace_span.start
                or frame.span.start >= update.replace_span.end
            ):
                retained.append(frame)
                continue
            if frame.span.start < update.replace_span.start:
                retained.append(
                    replace(frame, span=SampleSpan(frame.span.start, update.replace_span.start))
                )
            if frame.span.end > update.replace_span.end:
                retained.append(
                    replace(frame, span=SampleSpan(update.replace_span.end, frame.span.end))
                )
        self._frames = tuple(
            sorted(
                (
                    *retained,
                    *update.frames,
                ),
                key=lambda frame: (frame.span.start, frame.span.end),
            )
        )
        self._frame_index = None
        changed: list[Attribution] = []
        for state in self._units.values():
            if state.attribution.state == "final":
                continue
            span = state.unit.audio_span
            if (
                span is not None
                and span.end > self._stable_through
                and not span.overlaps(update.replace_span)
            ):
                continue
            next_attribution = self._evaluate(
                state.unit,
                revision=state.attribution.revision,
            )
            if next_attribution != state.attribution:
                state.attribution = replace(
                    next_attribution, revision=state.attribution.revision + 1
                )
                changed.append(state.attribution)
                self._advance_continuity(state)
        return tuple(changed)

    @property
    def retained_counts(self) -> dict[str, int]:
        return {"frames": len(self._frames), "steps": len(self._steps), "units": len(self._units)}

    def expire_before(self, sample: int) -> tuple[Attribution, ...]:
        expired = []
        for state in self._units.values():
            if (
                state.unit.audio_span is not None
                and state.unit.audio_span.end <= sample
                and state.attribution.state != "final"
            ):
                state.attribution = Attribution(
                    state.unit.id,
                    None,
                    (),
                    "final",
                    "activity_retention_expired",
                    state.attribution.revision + 1,
                )
                expired.append(state.attribution)
        return tuple(expired)

    def compact(self, before_sample: int) -> None:
        if before_sample < self._compacted_before or before_sample > self._stable_through:
            raise ValueError("invalid attribution compaction frontier")
        pending = [
            state.unit.audio_span.start
            for state in self._units.values()
            if state.attribution.state != "final" and state.unit.audio_span is not None
        ]
        frontier = min([before_sample, *pending])
        retained = tuple(frame for frame in self._frames if frame.span.end > frontier)
        if len(retained) != len(self._frames):
            self._frame_index = None
        self._frames = retained
        self._units = {
            uid: state
            for uid, state in self._units.items()
            if state.attribution.state != "final"
            or (state.unit.audio_span is not None and state.unit.audio_span.end > frontier)
        }
        self._compacted_before = frontier

    def terminate_pending(self, reason: str) -> tuple[Attribution, ...]:
        """Finalize only unresolved units as anonymous unknowns."""

        changed: list[Attribution] = []
        for state in self._units.values():
            if state.attribution.state == "final":
                continue
            final = Attribution(
                unit_id=state.unit.id,
                speaker=None,
                active_speakers=(),
                state="final",
                reason=reason,
                revision=state.attribution.revision + 1,
            )
            state.attribution = final
            changed.append(final)
        return tuple(changed)

    def _intersecting_frames(self, span: SampleSpan) -> tuple[ActivityFrame, ...]:
        index = self._frame_index
        if index is None:
            starts = tuple(frame.span.start for frame in self._frames)
            # Ends need not be ordered: an earlier long frame can enclose many
            # later short frames. Prefix maxima retain that overlapping evidence.
            ends = tuple(accumulate((frame.span.end for frame in self._frames), max))
            index = self._frame_index = (starts, ends)
        starts, ends = index
        first = bisect_right(ends, span.start)
        last = bisect_left(starts, span.end)
        return tuple(frame for frame in self._frames[first:last] if frame.span.end > span.start)

    def _evaluate(self, unit: TextUnit, *, revision: int) -> Attribution:
        if unit.audio_span is not None and unit.audio_span.start < self._compacted_before:
            return Attribution(unit.id, None, (), "final", "activity_history_evicted", revision)
        if unit.audio_span is None:
            return Attribution(unit.id, None, (), "final", "alignment_unavailable", revision)
        frames = self._intersecting_frames(unit.audio_span)
        support = {
            slot: union_support(
                unit.audio_span,
                (frame.span for frame in frames if slot in frame.active_slots),
            )
            for slot in sorted(
                set(self._slot_labels).union(
                    slot for frame in frames for slot in frame.active_slots
                )
            )
        }
        active_slots = tuple(slot for slot, value in support.items() if value > 0)
        labels = tuple(self._label_for(slot) for slot in active_slots)
        ranked = sorted(support.items(), key=lambda item: (-item[1], item[0]))
        winner, winner_support = ranked[0] if ranked else (-1, 0.0)
        runner_support = ranked[1][1] if len(ranked) > 1 else 0.0
        speaker = (
            self._label_for(winner)
            if winner >= 0
            and winner_support >= self._policy.min_support
            and winner_support - runner_support >= self._policy.min_margin
            else None
        )
        final = unit.audio_span.end <= self._stable_through
        missing_reasons = {
            frame.reason
            for frame in frames if frame.reason is not None
        }
        unknown_reason = next(
            (
                reason
                for reason in (
                    "activity_gap",
                    "audio_expired",
                    "model_not_ready",
                    "speaker_capacity",
                    "identity_uncertain",
                )
                if reason in missing_reasons
            ),
            "insufficient_evidence",
        )
        if speaker is None and unknown_reason == "insufficient_evidence":
            probability_winner = self._probability_winner(unit.audio_span, support, frames)
            if probability_winner is None:
                probability_winner = self._interior_pause_winner(unit.audio_span, frames)
            if probability_winner is not None:
                speaker = self._label_for(probability_winner)
            elif final:
                speaker = self._continuous_speaker(unit.audio_span, support)
        return Attribution(
            unit_id=unit.id,
            speaker=speaker,
            active_speakers=labels,
            state="final" if final else "provisional",
            reason=None if speaker is not None else unknown_reason,
            revision=revision,
        )

    def _interior_pause_winner(
        self, span: SampleSpan, frames: tuple[ActivityFrame, ...],
    ) -> int | None:
        """Keep one voice's word across an interior pause, without filling activity.

        Both word edges must contain the same sole active speaker. Silence can
        reduce whole-word coverage without introducing another speaker, but
        missing evidence, open edges, overlap and low scores remain unknown.
        """
        slots = {slot for frame in frames for slot in frame.active_slots}
        if len(slots) != 1:
            return None
        slot = next(iter(slots))
        if slot not in frames[0].active_slots or slot not in frames[-1].active_slots:
            return None
        previous_end = span.start
        active_duration = 0
        weighted_scores: list[float] = []
        for frame in frames:
            start, end = max(span.start, frame.span.start), min(span.end, frame.span.end)
            if start != previous_end or frame.reason is not None or frame.scores is None:
                return None
            previous_end = end
            if slot in frame.active_slots:
                duration = end - start
                active_duration += duration
                weighted_scores.append(duration * frame.scores[slot])
        if previous_end != span.end or not active_duration:
            return None
        return (
            slot
            if fsum(weighted_scores) / active_duration >= self._policy.min_support
            else None
        )

    def _probability_winner(
        self, span: SampleSpan, support: dict[int, float], frames: tuple[ActivityFrame, ...],
    ) -> int | None:
        """Resolve ambiguous activity with independent, duration-weighted scores.

        Scores are support for each speaker, not a distribution over speakers.
        Missing or overlapping evidence cannot be counted as extra confidence.
        """
        eligible = tuple(
            slot for slot, value in support.items()
            if value > 0 and value >= self._policy.min_support
        )
        if len(eligible) < 2:
            return None
        previous_end = span.start
        for frame in frames:
            start, end = max(span.start, frame.span.start), min(span.end, frame.span.end)
            if frame.scores is None or start < previous_end:
                return None
            previous_end = end
        duration = span.end - span.start
        ranked = sorted(
            (
                (slot, fsum(
                    (min(span.end, frame.span.end) - max(span.start, frame.span.start))
                    * frame.scores[slot]
                    for frame in frames
                    if frame.scores is not None and slot in frame.active_slots
                ) / duration)
                for slot in eligible
            ),
            key=lambda item: (-item[1], item[0]),
        )
        winner, score = ranked[0]
        if score >= self._policy.min_support and score - ranked[1][1] >= self._policy.min_margin:
            return winner
        return None

    def _label_for(self, slot: int) -> str:
        label = self._slot_labels.get(slot)
        if label is None:
            label = (
                f"S{slot + 1}"
                if self._label_mode == "meeting_dynamic"
                else chr(ord("A") + len(self._slot_labels))
            )
            self._slot_labels[slot] = label
        return label

    def _advance_continuity(self, state: _UnitState) -> None:
        """Remember the latest final label without changing finalized units."""

        span = state.unit.audio_span
        if span is None or state.attribution.state != "final":
            return
        if span.start < self._continuity_end:
            return
        if any(frame.reason is not None for frame in self._intersecting_frames(span)):
            # A degraded interval may be missing activity, so it cannot carry
            # a speaker label into the next unit even if coverage still looked
            # unambiguous for this one.
            self._continuity_label = None
            self._continuity_end = span.end
            return
        if state.attribution.speaker is not None:
            self._continuity_label = state.attribution.speaker
        elif state.attribution.reason != "insufficient_evidence":
            # A degraded or unavailable interval ends the continuity run. A
            # merely insufficient unit keeps the prior label for the next
            # adjacent unit, matching the bounded evidence window.
            self._continuity_label = None
        self._continuity_end = span.end

    def _continuous_speaker(
        self,
        span: SampleSpan,
        support: dict[int, float],
    ) -> str | None:
        """Carry a final label across an adjacent unknown unit when still active.

        The previous label is only a prior: the same speaker must still cover
        the current unit's activity at the normal support floor. A pause longer
        than ``continuity_gap_seconds`` ends the run, and degraded evidence is
        never filled.
        """

        label = self._continuity_label
        if label is None:
            return None
        gap = span.start - self._continuity_end
        if gap > int(self._policy.continuity_gap_seconds * CORE_SAMPLE_RATE):
            return None
        slot = next(
            (slot for slot, value in self._slot_labels.items() if value == label),
            None,
        )
        if slot is None or support.get(slot, 0.0) < self._policy.min_support:
            return None
        return label
