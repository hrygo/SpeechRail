"""Immutable policy and bounded state for explicitly negotiated ASR windows."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import asdict, dataclass, replace
from itertools import pairwise
from typing import Literal
from uuid import uuid4

from speechrail.domain.audio_timeline import SampleSpan

WindowScene = Literal["meeting", "caption"]
WINDOW_MODE = "revision_window_v1"
MAX_PCM_BYTES = 16 * 1024 * 1024
MAX_WINDOW_UNITS = 32
MAX_UNIT_CODEPOINTS = 8192
MAX_WINDOW_CODEPOINTS = 32768
MAX_EVENT_BYTES = 256 * 1024
MAX_SAFE_INTEGER = 2**53 - 1


def require_integer(value: object, *, minimum: int = 0, maximum: int = MAX_SAFE_INTEGER) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError("window integer is outside the supported range")
    return value


def require_identifier(value: object) -> str:
    if not isinstance(value, str) or not 1 <= len(value) <= 128:
        raise ValueError("window identifier must contain 1–128 codepoints")
    return value


@dataclass(frozen=True, slots=True)
class WindowPolicy:
    preview_interval_ms: int
    owned_ms: int
    review_grace_ms: int
    left_context_ms: int
    max_decode_ms: int
    pcm_budget_bytes: int = MAX_PCM_BYTES
    finalization_budget_ms: int = 5000

    def __post_init__(self) -> None:
        for name, value in asdict(self).items():
            require_integer(
                value, minimum=0 if name in {"review_grace_ms", "left_context_ms"} else 1
            )
        if self.owned_ms + self.review_grace_ms + self.left_context_ms > self.max_decode_ms:
            raise ValueError("window context exceeds the decoder budget")
        if self.max_decode_ms > 30_000 or self.pcm_budget_bytes > MAX_PCM_BYTES:
            raise ValueError("window policy exceeds the hard resource limit")

    @classmethod
    def for_scene(cls, scene: object) -> WindowPolicy:
        if scene == "caption":
            return cls(500, 4000, 8000, 2000, 14000)
        if scene == "meeting":
            return cls(1500, 20000, 2000, 2000, 24000, finalization_budget_ms=15000)
        raise ValueError("window scene must be meeting or caption")

    def to_wire_dict(self) -> dict[str, int]:
        return asdict(self)


def require_span(span: SampleSpan, *, nonempty: bool = True) -> None:
    require_integer(span.start)
    require_integer(span.end)
    if span.end < span.start or (nonempty and span.length == 0):
        raise ValueError("window span must be ordered and nonempty")


@dataclass(frozen=True, slots=True)
class WindowIdentity:
    session_id: str
    input_epoch: int
    window_id: str

    def __post_init__(self) -> None:
        require_identifier(self.session_id)
        require_integer(self.input_epoch)
        require_identifier(self.window_id)


@dataclass(frozen=True, slots=True)
class OwnedBlock:
    unit_id: str
    span: SampleSpan
    reason: str


@dataclass(frozen=True, slots=True)
class WindowUnit:
    unit_id: str
    text: str
    text_revision: int
    owned_span: SampleSpan
    state: Literal["preview", "reviewed"] = "preview"

    def __post_init__(self) -> None:
        require_identifier(self.unit_id)
        require_integer(self.text_revision)
        require_span(self.owned_span)
        if not isinstance(self.text, str) or len(self.text) > MAX_UNIT_CODEPOINTS:
            raise ValueError("window unit exceeds the codepoint budget")
        if self.state not in ("preview", "reviewed"):
            raise ValueError("invalid window unit state")


@dataclass(frozen=True, slots=True)
class FinalWindowUnit(WindowUnit):
    item_id: str = ""
    review_scope: Literal["contextual", "owned_only"] = "contextual"

    def __post_init__(self) -> None:
        WindowUnit.__post_init__(self)
        require_identifier(self.item_id)
        if self.state != "reviewed" or self.review_scope not in ("contextual", "owned_only"):
            raise ValueError("only a qualified review can become final")


@dataclass(frozen=True, slots=True)
class FailedWindowItem:
    item_id: str
    owned_span: SampleSpan
    recovery_text: str
    reason: str


@dataclass(frozen=True, slots=True)
class WindowCoverage:
    span: SampleSpan
    outcome: Literal["speech", "silence", "failed"]
    reason: str | None = None
    item_id: str | None = None


@dataclass(frozen=True, slots=True)
class WindowSnapshot:
    identity: WindowIdentity
    window_revision: int
    audio_span: SampleSpan
    sealed_through_sample: int
    units: tuple[WindowUnit, ...]


@dataclass(frozen=True, slots=True)
class WindowSeal:
    identity: WindowIdentity
    window_revision: int
    transaction_id: str
    closed_span: SampleSpan
    sealed_through_sample: int
    final_units: tuple[FinalWindowUnit, ...]
    failed_items: tuple[FailedWindowItem, ...]
    remaining_units: tuple[WindowUnit, ...]
    coverage: tuple[WindowCoverage, ...]


@dataclass(frozen=True, slots=True)
class WindowDecodeRequest:
    identity: WindowIdentity
    attempt_id: str
    kind: Literal["preview", "review"]
    input_span: SampleSpan
    pcm16: bytes
    language: str | None = None
    context: str = ""

    def __post_init__(self) -> None:
        require_identifier(self.attempt_id)
        require_span(self.input_span)
        if self.kind not in ("preview", "review"):
            raise ValueError("invalid window decode kind")
        if not isinstance(self.pcm16, bytes) or len(self.pcm16) != self.input_span.length * 2:
            raise ValueError("window PCM does not match the declared sample span")
        if self.input_span.length > 30 * 16000:
            raise ValueError("window decode exceeds 30 seconds")
        if self.language is not None and not isinstance(self.language, str):
            raise ValueError("invalid window language")
        if not isinstance(self.context, str) or len(self.context) > 512:
            raise ValueError("window context exceeds its budget")


@dataclass(frozen=True, slots=True)
class WindowDecodeObservation:
    """Per-attempt decoder evidence; absent vendor values remain unknown.

    The decode budget bounds the whole hypothesis. The generation budget is
    the actual vendor call budget after any retained preview prefix is deducted.
    Generated token counts exclude that prefix and precede output postprocessing.
    """

    kind: Literal["preview", "review"]
    decode_max_new_tokens: int
    generation_max_new_tokens: int | None = None
    finish_reason: str | None = None
    truncated: bool | None = None
    generated_token_count: int | None = None

    def __post_init__(self) -> None:
        if self.kind not in ("preview", "review"):
            raise ValueError("invalid window observation kind")
        require_integer(self.decode_max_new_tokens, minimum=1)
        if self.generation_max_new_tokens is not None:
            require_integer(
                self.generation_max_new_tokens, minimum=1, maximum=self.decode_max_new_tokens
            )
        if self.finish_reason is not None and (
            not isinstance(self.finish_reason, str) or not 1 <= len(self.finish_reason) <= 64
        ):
            raise ValueError("invalid window observation finish reason")
        if self.truncated is not None and type(self.truncated) is not bool:
            raise ValueError("invalid window observation truncation")
        if self.generated_token_count is not None:
            require_integer(
                self.generated_token_count,
                maximum=self.generation_max_new_tokens or self.decode_max_new_tokens,
            )

    @classmethod
    def from_wire_dict(cls, value: object) -> WindowDecodeObservation:
        if not isinstance(value, dict) or not {"kind", "decode_max_new_tokens"} <= value.keys():
            raise ValueError("invalid window observation")
        if value.keys() - cls.__dataclass_fields__.keys():
            raise ValueError("unexpected window observation fields")
        # Construction performs the same strict validation used by engine results.
        return cls(**value)


@dataclass(frozen=True, slots=True)
class WindowDecodeResult:
    identity: WindowIdentity
    attempt_id: str
    input_span: SampleSpan
    text: str
    language: str | None
    complete: bool
    observation: WindowDecodeObservation | None = None

    def __post_init__(self) -> None:
        require_identifier(self.attempt_id)
        require_span(self.input_span)
        if not isinstance(self.text, str) or len(self.text) > MAX_UNIT_CODEPOINTS:
            raise ValueError("window result exceeds the codepoint budget")
        if type(self.complete) is not bool:
            raise ValueError("window result requires explicit completeness")
        if self.observation is not None and not isinstance(
            self.observation, WindowDecodeObservation
        ):
            raise ValueError("invalid window decode observation")


class WindowLedger:
    """Pure sample ownership ledger; no clock, I/O or implicit acoustic decisions.

    A caller may authorize silence only through its VAD retained frontier.
    Reviews use compare-and-set parents and cannot rewrite a sealed prefix.
    """

    def __init__(self, identity: WindowIdentity, policy: WindowPolicy | None = None) -> None:
        self.identity = identity
        self.policy = policy or WindowPolicy.for_scene("caption")
        self.accepted_samples = 0
        self.sealed_through_sample = 0
        self.window_revision = 0
        self._units: tuple[WindowUnit, ...] = ()
        self._blocks: dict[str, OwnedBlock] = {}
        self._scopes: dict[str, Literal["contextual", "owned_only"]] = {}
        self._active_id: str | None = None
        self._block_start = 0

    def append(self, span: SampleSpan) -> None:
        require_span(span)
        if span.start != self.accepted_samples:
            raise ValueError("window input must be continuous")
        self.accepted_samples = span.end
        self.window_revision += 1

    def _validate_units(self, units: Sequence[WindowUnit]) -> tuple[WindowUnit, ...]:
        ordered = tuple(sorted(units, key=lambda unit: unit.owned_span.start))
        if len(ordered) > MAX_WINDOW_UNITS or len({u.unit_id for u in ordered}) != len(ordered):
            raise ValueError("window units exceed limits or contain duplicate identities")
        if sum(len(u.text) for u in ordered) > MAX_WINDOW_CODEPOINTS:
            raise ValueError("window snapshot exceeds its codepoint budget")
        cursor = self.sealed_through_sample
        for unit in ordered:
            if unit.owned_span.start < cursor or unit.owned_span.end > self.accepted_samples:
                raise ValueError(
                    "window units overlap, rewrite final text or exceed accepted input"
                )
            cursor = unit.owned_span.end
        return ordered

    def preview(self, span: SampleSpan, text: str) -> WindowUnit:
        require_span(span)
        old = next((u for u in self._units if u.unit_id == self._active_id), None)
        if old is not None and old.owned_span.start != span.start:
            raise ValueError("active preview origin changed before block close")
        uid = old.unit_id if old is not None else "unit_" + uuid4().hex
        revision = (old.text_revision + (old.text != text)) if old else 1
        unit = WindowUnit(uid, text, revision, span)
        updated = self._validate_units([u for u in self._units if u.unit_id != uid] + [unit])
        if updated != self._units:
            self._units = updated
            self.window_revision += 1
        self._active_id = uid
        return unit

    def close_block(self, end: int, reason: str, *, start: int | None = None) -> OwnedBlock:
        require_integer(end)
        if reason not in ("vad", "client_commit", "budget_rollover"):
            raise ValueError("invalid window block close reason")
        unit = next((u for u in self._units if u.unit_id == self._active_id), None)
        begin = start if start is not None else unit.owned_span.start if unit else self._block_start
        require_integer(begin)
        if not begin < end <= self.accepted_samples or end - begin > self.policy.owned_ms * 16:
            raise ValueError("closed block exceeds accepted input or the owned budget")
        if unit is None:
            unit = self.preview(SampleSpan(begin, end), "")
        elif unit.owned_span != SampleSpan(begin, end):
            unit = self.preview(SampleSpan(begin, end), unit.text)
        block = OwnedBlock(unit.unit_id, unit.owned_span, reason)
        self._blocks[unit.unit_id] = block
        self._active_id = None
        self._block_start = end
        return block

    def settle_closed_preview(self, unit_id: str, text: str) -> WindowUnit:
        """Finish a queued preview without changing a closed block's ownership."""
        if unit_id not in self._blocks:
            raise ValueError("closed preview parent is retired or sealed")
        old = next(u for u in self._units if u.unit_id == unit_id)
        unit = replace(old, text=text, text_revision=old.text_revision + (old.text != text))
        updated = self._validate_units([unit if u.unit_id == unit_id else u for u in self._units])
        if updated != self._units:
            self._units = updated
            self.window_revision += 1
        return unit

    def accept(
        self,
        candidate: Sequence[WindowUnit],
        expected_parents: Mapping[str, int],
        *,
        identity: WindowIdentity,
        review_scope: Literal["contextual", "owned_only"] = "contextual",
    ) -> None:
        if (
            identity != self.identity
            or not expected_parents
            or review_scope not in ("contextual", "owned_only")
        ):
            raise ValueError("window review has a stale identity or invalid parents")
        parents = sorted(
            (u for u in self._units if u.unit_id in expected_parents),
            key=lambda u: u.owned_span.start,
        )
        if len(parents) != len(expected_parents) or any(
            u.text_revision != expected_parents[u.unit_id] or u.unit_id not in self._blocks
            for u in parents
        ):
            raise ValueError("window review parents changed or are not closed")
        if any(a.owned_span.end != b.owned_span.start for a, b in pairwise(parents)):
            raise ValueError("review parents do not cover a continuous owned interval")
        units = sorted(candidate, key=lambda u: u.owned_span.start)
        if (
            not units
            or any(u.state != "reviewed" for u in units)
            or units[0].owned_span.start != parents[0].owned_span.start
            or units[-1].owned_span.end != parents[-1].owned_span.end
            or any(a.owned_span.end != b.owned_span.start for a, b in pairwise(units))
        ):
            raise ValueError("review must completely replace its parents without gaps")
        old_by_id = {u.unit_id: u for u in parents}
        units = [
            replace(u, text_revision=old_by_id[u.unit_id].text_revision + 1)
            if u.unit_id in old_by_id
            and u.text != old_by_id[u.unit_id].text
            and u.text_revision <= old_by_id[u.unit_id].text_revision
            else u
            for u in units
        ]
        updated = self._validate_units(
            [u for u in self._units if u.unit_id not in expected_parents] + units
        )
        for parent in parents:
            self._blocks.pop(parent.unit_id)
            self._scopes.pop(parent.unit_id, None)
        for unit in units:
            self._blocks[unit.unit_id] = OwnedBlock(
                unit.unit_id, unit.owned_span, "budget_rollover"
            )
            self._scopes[unit.unit_id] = review_scope
        self._units = updated
        self.window_revision += 1

    def _closing(self, through: int) -> tuple[WindowUnit, ...] | None:
        require_integer(through)
        if through == self.sealed_through_sample:
            return None
        if through < self.sealed_through_sample or through > self.accepted_samples:
            raise ValueError("invalid terminal frontier")
        if any(u.owned_span.start < through < u.owned_span.end for u in self._units):
            raise ValueError("terminal frontier would cut an owned unit")
        return tuple(u for u in self._units if u.owned_span.end <= through)

    def _finish(
        self,
        through: int,
        final: tuple[FinalWindowUnit, ...],
        failed: tuple[FailedWindowItem, ...],
        coverage: Sequence[WindowCoverage],
    ) -> WindowSeal:
        closed = SampleSpan(self.sealed_through_sample, through)
        for unit in self._units:
            if unit.owned_span.end <= through:
                self._blocks.pop(unit.unit_id, None)
                self._scopes.pop(unit.unit_id, None)
                if self._active_id == unit.unit_id:
                    self._active_id = None
        self._units = tuple(u for u in self._units if u.owned_span.end > through)
        self.sealed_through_sample = through
        self._block_start = max(through, self._block_start)
        self.window_revision += 1
        return WindowSeal(
            self.identity,
            self.window_revision,
            "tx_" + uuid4().hex,
            closed,
            through,
            final,
            failed,
            self._units,
            tuple(coverage),
        )

    def seal(self, through: int, *, allow_silence: bool = False) -> WindowSeal | None:
        units = self._closing(through)
        if units is None:
            return None
        if any(u.state != "reviewed" or u.unit_id not in self._scopes for u in units):
            raise ValueError("unreviewed text cannot be sealed")
        finals = tuple(
            FinalWindowUnit(
                u.unit_id,
                u.text,
                u.text_revision,
                u.owned_span,
                "reviewed",
                "item_" + uuid4().hex,
                self._scopes[u.unit_id],
            )
            for u in units
        )
        coverage: list[WindowCoverage] = []
        cursor = self.sealed_through_sample
        for unit in finals:
            if unit.owned_span.start > cursor:
                coverage.append(
                    WindowCoverage(
                        SampleSpan(cursor, unit.owned_span.start), "silence", "vad_not_admitted"
                    )
                )
            coverage.append(WindowCoverage(unit.owned_span, "speech", item_id=unit.item_id))
            cursor = unit.owned_span.end
        if cursor < through:
            coverage.append(
                WindowCoverage(SampleSpan(cursor, through), "silence", "vad_not_admitted")
            )
        if not allow_silence and any(c.outcome == "silence" for c in coverage):
            raise ValueError("silence requires an explicit admission frontier")
        return self._finish(through, finals, (), coverage)

    def fail(self, through: int, reason: str) -> WindowSeal | None:
        units = self._closing(through)
        if units is None:
            return None
        require_identifier(reason)
        failed: list[FailedWindowItem] = []
        cursor = self.sealed_through_sample
        for unit in units:
            if cursor < unit.owned_span.start:
                failed.append(
                    FailedWindowItem(
                        "item_" + uuid4().hex, SampleSpan(cursor, unit.owned_span.start), "", reason
                    )
                )
            failed.append(
                FailedWindowItem("item_" + uuid4().hex, unit.owned_span, unit.text, reason)
            )
            cursor = unit.owned_span.end
        if cursor < through:
            failed.append(
                FailedWindowItem("item_" + uuid4().hex, SampleSpan(cursor, through), "", reason)
            )
        if len(failed) > MAX_WINDOW_UNITS:
            raise ValueError("failure transaction exceeds the item budget")
        return self._finish(
            through,
            (),
            tuple(failed),
            [WindowCoverage(item.owned_span, "failed", reason, item.item_id) for item in failed],
        )

    def snapshot(self) -> WindowSnapshot:
        return WindowSnapshot(
            self.identity,
            self.window_revision,
            SampleSpan(self.sealed_through_sample, self.accepted_samples),
            self.sealed_through_sample,
            self._units,
        )
