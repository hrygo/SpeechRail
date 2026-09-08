"""Pure evidence ledger for fixed text and continuous speaker activity."""

from __future__ import annotations

from collections.abc import Callable, Iterable
from dataclasses import dataclass

from .types import ActivityFrame, ActivityUpdate, Attribution, Span, TextUnit


def union_support(unit: Span, activities: Iterable[Span]) -> float:
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


@dataclass(frozen=True, slots=True)
class AttributionPolicy:
    min_support: float = 0.60
    min_margin: float = 0.10

    def __post_init__(self) -> None:
        if not 0 <= self.min_support <= 1 or not 0 <= self.min_margin <= 1:
            raise ValueError("attribution policy values must be in [0, 1]")


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
    ) -> None:
        self._accepted_samples = accepted_samples
        self._policy = policy or AttributionPolicy()
        self._epoch: str | None = None
        self._steps: dict[int, ActivityUpdate] = {}
        self._frames: tuple[ActivityFrame, ...] = ()
        self._processed_through = 0
        self._stable_through = 0
        self._slot_labels: dict[int, str] = {}
        self._units: dict[str, _UnitState] = {}

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
        previous = self._steps.get(update.step_id)
        if previous is not None:
            if previous != update:
                raise ValueError("duplicate activity step has different payload")
            return ()
        if update.processed_through < self._processed_through:
            raise ValueError("processed watermark cannot move backwards")
        if update.stable_through < self._stable_through:
            raise ValueError("stable watermark cannot move backwards")
        if update.replace_span.start < self._stable_through:
            raise ValueError("activity update attempts to replace stable frames")
        self._steps[update.step_id] = update
        self._processed_through = update.processed_through
        self._stable_through = update.stable_through
        self._frames = tuple(
            sorted(
                (
                    *(
                        frame
                        for frame in self._frames
                        if frame.span.end <= update.replace_span.start
                        or frame.span.start >= update.replace_span.end
                    ),
                    *update.frames,
                ),
                key=lambda frame: (frame.span.start, frame.span.end),
            )
        )
        changed: list[Attribution] = []
        for state in self._units.values():
            if state.attribution.state == "final":
                continue
            next_attribution = self._evaluate(
                state.unit,
                revision=state.attribution.revision + 1,
            )
            if next_attribution != state.attribution:
                state.attribution = next_attribution
                changed.append(next_attribution)
        return tuple(changed)

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

    def _evaluate(self, unit: TextUnit, *, revision: int) -> Attribution:
        if unit.audio_span is None:
            return Attribution(unit.id, None, (), "final", "alignment_unavailable", revision)
        support = {
            slot: union_support(
                unit.audio_span,
                (frame.span for frame in self._frames if slot in frame.active_slots),
            )
            for slot in range(4)
        }
        active_slots = tuple(slot for slot, value in support.items() if value > 0)
        labels = tuple(self._label_for(slot) for slot in active_slots)
        ranked = sorted(support.items(), key=lambda item: (-item[1], item[0]))
        winner, winner_support = ranked[0]
        runner_support = ranked[1][1]
        speaker = (
            self._label_for(winner)
            if winner_support >= self._policy.min_support
            and winner_support - runner_support >= self._policy.min_margin
            else None
        )
        final = unit.audio_span.end <= self._stable_through
        return Attribution(
            unit_id=unit.id,
            speaker=speaker,
            active_speakers=labels,
            state="final" if final else "provisional",
            reason=None if speaker is not None else "insufficient_evidence",
            revision=revision,
        )

    def _label_for(self, slot: int) -> str:
        label = self._slot_labels.get(slot)
        if label is None:
            label = chr(ord("A") + len(self._slot_labels))
            self._slot_labels[slot] = label
        return label
