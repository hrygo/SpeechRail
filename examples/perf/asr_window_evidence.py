"""Independent ownership and paired quality audit for revision-window events.

Only counts, hashes and metrics leave this auditor. References and hypotheses
remain in memory; preview loss cannot remove sealed text from the score.
"""

from __future__ import annotations

import hashlib
import json
import math
import random
import re
from collections.abc import Sequence
from typing import Any, ClassVar

try:
    from .asr_quality import character_error_metrics
    from .asr_window_annotations import annotated_quality_metrics
except ImportError:  # pragma: no cover - direct CLI imports
    from asr_quality import character_error_metrics  # type: ignore[no-redef]
    from asr_window_annotations import annotated_quality_metrics  # type: ignore[no-redef]


def paired_bootstrap(
    rows: Sequence[tuple[float, float]],
    *,
    seed: int = 1717,
    draws: int = 10000,
) -> dict[str, Any]:
    if not rows or type(draws) is not int or draws < 100:
        raise ValueError("paired bootstrap requires sessions and at least 100 draws")
    deltas = [new - old for old, new in rows]
    if not all(math.isfinite(value) for value in deltas):
        raise ValueError("paired bootstrap values must be finite")
    rng = random.Random(seed)
    distribution = sorted(
        sum(rng.choices(deltas, k=len(deltas))) / len(deltas) for _ in range(draws)
    )
    return {
        "session_count": len(rows),
        "mean_delta": sum(deltas) / len(rows),
        "ci95": [distribution[int(0.025 * draws)], distribution[int(0.975 * draws)]],
        "seed": seed,
        "draws": draws,
        "resampling_unit": "whole_session",
    }


def _integer(value: object) -> int:
    if type(value) is not int or not 0 <= value <= 2**53 - 1:
        raise ValueError("invalid window integer")
    return value


def _span(value: object) -> tuple[int, int]:
    if not isinstance(value, dict) or set(value) != {"start", "end"}:
        raise ValueError("invalid window sample span")
    start, end = _integer(value["start"]), _integer(value["end"])
    if end < start:
        raise ValueError("invalid window sample order")
    return start, end


def _digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def _edit_count(expected: Sequence[Any], actual: Sequence[Any]) -> int:
    if max(len(expected), len(actual)) > 20000:
        raise ValueError("quality reference exceeds scoring bounds")
    previous = list(range(len(actual) + 1))
    for row, left in enumerate(expected, 1):
        current = [row]
        for column, right in enumerate(actual, 1):
            current.append(
                min(current[-1] + 1, previous[column] + 1, previous[column - 1] + (left != right))
            )
        previous = current
    return previous[-1]


class PublicASRError(RuntimeError):
    """Finite stage and protocol code; never carry vendor messages or text."""

    def __init__(self, error: object, *, stage: str) -> None:
        code = error.get("code") if isinstance(error, dict) else getattr(error, "code", None)
        self.code = (
            code
            if isinstance(code, str) and re.fullmatch(r"[a-z][a-z0-9_]{0,63}", code)
            else "unknown"
        )
        self.stage = stage if stage in {"configuration", "stream"} else "unknown"
        super().__init__(f"public ASR {self.stage} failed: {self.code}")


class WindowEvidenceError(ValueError):
    """Stable local audit diagnostics, with no event text or vendor message."""

    _MESSAGES: ClassVar[dict[str, str]] = {
        "same window revision changed its contents": "window_revision_conflict",
        "window revision regressed": "window_revision_regressed",
        "snapshot changed sealed text": "window_sealed_rewrite",
        "window text revision is inconsistent": "window_text_revision_conflict",
        "window barrier lacks exact terminal coverage": "window_barrier_incomplete",
    }

    def __init__(self, message: str) -> None:
        self.code = self._MESSAGES.get(message, "window_evidence_invalid")
        self.stage = "evidence"
        super().__init__(
            message if message in self._MESSAGES else "window evidence validation failed"
        )


class ASRWindowEvidence:
    def __init__(self) -> None:
        self.identity: tuple[str, int, str] | None = None
        self.revision = 0
        self.sealed_through = 0
        self.snapshots: dict[int, str] = {}
        self.transactions: set[str] = set()
        self.units: dict[str, dict[str, Any]] = {}
        self.final_ids: set[str] = set()
        self.items: dict[str, tuple[tuple[int, int], str | None]] = {}
        self.boundaries: set[str] = set()
        self.terminals: set[str] = set()
        self.texts: list[str] = []
        self.coverage_samples = dict.fromkeys(("speech", "empty", "silence", "failed"), 0)
        self.failed_items_count = 0
        self.failure_reason_counts: dict[str, int] = {}
        self.preview_count = self.revised_characters = 0
        self.first_preview_at: float | None = None
        self.last_terminal_at: float | None = None
        self.receipt_samples: int | None = None
        self.receipt_at: float | None = None

    def _units(self, value: object) -> dict[str, dict[str, Any]]:
        if not isinstance(value, list) or len(value) > 32:
            raise ValueError("invalid window units")
        result = {}
        characters = 0
        for unit in value:
            if not isinstance(unit, dict):
                raise ValueError("invalid window unit")
            uid, text = unit.get("unit_id"), unit.get("text")
            if not isinstance(uid, str) or not 0 < len(uid) <= 128 or uid in result:
                raise ValueError("duplicate or invalid window unit ID")
            if not isinstance(text, str) or len(text) > 8192:
                raise ValueError("invalid window text")
            _integer(unit.get("text_revision"))
            _span(unit.get("owned_span"))
            characters += len(text)
            result[uid] = unit
        if characters > 32768:
            raise ValueError("window text exceeds transaction bound")
        return result

    def consume(self, raw: object, received_at: float) -> None:
        try:
            self._consume(raw, received_at)
        except ValueError as exc:
            # Match only finite local invariants; never persist arbitrary text.
            if str(exc) in WindowEvidenceError._MESSAGES:
                raise WindowEvidenceError(str(exc)) from exc
            raise

    def _consume(self, raw: object, received_at: float) -> None:
        event = raw if isinstance(raw, dict) else raw.model_dump(mode="json", exclude_none=True)
        kind = event.get("type", "")
        if kind == "error":
            raise PublicASRError(event.get("error"), stage="stream")
        if kind.startswith("speechrail.transcription.window."):
            if len(json.dumps(event, ensure_ascii=False).encode()) > 262144:
                raise ValueError("window event exceeds byte bound")
            identity = (event["session_id"], _integer(event["input_epoch"]), event["window_id"])
            if self.identity is not None and self.identity != identity:
                raise ValueError("window identity changed during capture")
            revision = _integer(event.get("window_revision"))
            digest = _digest({k: v for k, v in event.items() if k not in {"event_id", "sequence"}})
            if revision in self.snapshots:
                if self.snapshots[revision] != digest:
                    raise ValueError("same window revision changed its contents")
                return
            if revision <= self.revision:
                raise ValueError("window revision regressed")
            if kind.endswith("updated"):
                units = self._units(event.get("units"))
                if _integer(event["sealed_through_sample"]) != self.sealed_through:
                    raise ValueError("preview changed the sealed frontier")
            else:
                start, end = _span(event.get("closed_span"))
                if (
                    start != self.sealed_through
                    or end <= start
                    or event["sealed_through_sample"] != end
                ):
                    raise ValueError("window seal has overlapping or missing input")
                transaction = event.get("transaction_id")
                if not isinstance(transaction, str) or transaction in self.transactions:
                    raise ValueError("duplicate window transaction")
                finals = self._units(event.get("final_units", []))
                units = self._units(event.get("remaining_units"))
                new_items = {}
                for uid, unit in finals.items():
                    item = unit.get("item_id")
                    if (
                        uid in self.final_ids
                        or not isinstance(item, str)
                        or item in self.items
                        or item in new_items
                    ):
                        raise ValueError("final window identity reused")
                    new_items[item] = (_span(unit["owned_span"]), unit["text"])
                failures = event.get("failed_items", [])
                if not isinstance(failures, list):
                    raise ValueError("invalid failed window items")
                for unit in failures:
                    item = unit["item_id"]
                    if item in self.items or item in new_items:
                        raise ValueError("failed window identity reused")
                    new_items[item] = (_span(unit["owned_span"]), None)
                    reason = unit.get("reason")
                    reason = (
                        reason
                        if isinstance(reason, str)
                        and reason
                        in {"window_review_timeout", "window_review_failed", "audio_expired"}
                        else "unknown"
                    )
                    self.failure_reason_counts[reason] = (
                        self.failure_reason_counts.get(reason, 0) + 1
                    )
                coverage = event.get("coverage")
                if not isinstance(coverage, list) or not coverage:
                    raise ValueError("window seal lacks coverage")
                cursor, covered = start, set()
                for entry in coverage:
                    a, b = _span(entry.get("span"))
                    outcome = entry.get("outcome")
                    if (
                        a != cursor
                        or b <= a
                        or b > end
                        or outcome not in {"speech", "silence", "failed"}
                    ):
                        raise ValueError("window coverage has a gap or overlap")
                    if outcome != "silence":
                        item = entry.get("item_id")
                        if item in covered or item not in new_items or new_items[item][0] != (a, b):
                            raise ValueError("window coverage does not match its text owner")
                        text = new_items[item][1]
                        if (outcome == "failed") != (text is None):
                            raise ValueError("window coverage outcome differs from text")
                        covered.add(item)
                        if text is not None:
                            self.texts.append(text)
                    # The wire contract calls an empty complete decode speech.
                    # Keep the derived empty category separate from VAD silence.
                    counted = (
                        "empty"
                        if outcome == "speech" and new_items[entry["item_id"]][1] == ""
                        else outcome
                    )
                    self.coverage_samples[counted] += b - a
                    cursor = b
                if cursor != end or covered != set(new_items):
                    raise ValueError("window coverage omits an owner or tail")
                self.items.update(new_items)
                self.final_ids.update(finals)
                self.failed_items_count += len(failures)
                self.transactions.add(transaction)
                self.sealed_through = end
            for uid, unit in units.items():
                if uid in self.final_ids or _span(unit["owned_span"])[0] < self.sealed_through:
                    raise ValueError("snapshot changed sealed text")
                old = self.units.get(uid)
                if old is not None:
                    if unit["text_revision"] < old["text_revision"] or (
                        unit["text_revision"] == old["text_revision"]
                        and unit["text"] != old["text"]
                    ):
                        raise ValueError("window text revision is inconsistent")
                    common = 0
                    for left, right in zip(old["text"], unit["text"], strict=False):
                        if left != right:
                            break
                        common += 1
                    self.revised_characters += len(old["text"]) - common
            if kind.endswith("updated"):
                self.preview_count += 1
                if self.first_preview_at is None:
                    self.first_preview_at = received_at
            self.identity, self.revision, self.units = identity, revision, units
            self.snapshots[revision] = digest
            if len(self.snapshots) > 64:
                del self.snapshots[min(self.snapshots)]
        elif kind == "speechrail.transcription.hypothesis":
            raise ValueError("legacy preview mixed into a revision window")
        elif kind == "speechrail.transcription.segment_closed":
            item = event["item_id"]
            if (
                item in self.boundaries
                or item not in self.items
                or _span(event["sample_span"]) != self.items[item][0]
            ):
                raise ValueError("window boundary mirror differs from transaction")
            self.boundaries.add(item)
        elif kind.startswith("conversation.item.input_audio_transcription."):
            if kind.endswith(("delta", "hypothesis")):
                raise ValueError("legacy preview mixed into a revision window")
            item = event.get("item_id")
            if item in self.terminals or item not in self.boundaries:
                raise ValueError("duplicate terminal or terminal before boundary")
            text = self.items[item][1]
            if kind.endswith("completed"):
                if text is None or event.get("transcript") != text:
                    raise ValueError("window terminal mirror changed text")
            elif not kind.endswith("failed") or text is not None:
                raise ValueError("window terminal failure differs from transaction")
            self.terminals.add(item)
            self.last_terminal_at = received_at
        elif kind == "speechrail.input_audio_buffer.committed":
            if (
                event.get("commit_event_id") != "benchmark-final"
                or self.receipt_at is not None
                or _integer(event.get("window_revision")) != self.revision
                or _integer(event.get("sealed_through_sample")) != self.sealed_through
                or _integer(event.get("failed_items_count")) != self.failed_items_count
            ):
                raise ValueError("window receipt differs from terminal coverage")
            self.receipt_samples, self.receipt_at = (
                _integer(event.get("accepted_samples")),
                received_at,
            )

    def score(
        self,
        reference: str | None,
        *,
        expected_wire_samples: int,
        language: str = "zh",
        annotations: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if (
            self.receipt_samples != expected_wire_samples
            or self.sealed_through != expected_wire_samples
            or self.terminals != set(self.items)
            or self.units
        ):
            raise WindowEvidenceError("window barrier lacks exact terminal coverage")
        text = " ".join(self.texts)
        if reference is None:
            return {
                "quality_gate": "unset",
                "sample_coverage_gate": "pass",
                "failed_items_count": self.failed_items_count,
                "failure_reason_counts": self.failure_reason_counts,
                "terminal_count": len(self.terminals),
                "coverage_samples": self.coverage_samples,
            }
        raw_reference = "".join(reference.split())
        raw_hypothesis = "".join(text.split())
        raw_errors = _edit_count(raw_reference, raw_hypothesis)
        result = {
            "normalized": character_error_metrics(reference, text),
            "raw": {
                "character_errors": raw_errors,
                "reference_characters": len(raw_reference),
                "cer": raw_errors / len(raw_reference) if raw_reference else None,
            },
            "terminal_count": len(self.terminals),
            "transaction_count": len(self.transactions),
            "preview_count": self.preview_count,
            "revised_characters": self.revised_characters,
            "failed_items_count": self.failed_items_count,
            "failure_reason_counts": self.failure_reason_counts,
            "coverage_samples": self.coverage_samples,
            "sample_coverage_gate": "pass",
            "failure_gate": "fail" if self.failed_items_count else "pass",
            "word_timing": "not_observed",
            "correct_to_wrong": "not_observed",
            "facts": "not_observed",
            "vocabulary_negative_control": "not_observed",
            "ui_submission_latency": "not_observed",
            "wer": "not_observed",
        }
        result.update(annotated_quality_metrics(reference, text, annotations))
        if annotations is None and language.lower().startswith("en") and reference.split():
            import unicodedata

            def tokens(value):
                return "".join(
                    c
                    for c in unicodedata.normalize("NFKC", value).casefold()
                    if not unicodedata.category(c).startswith("P")
                ).split()

            expected, actual = tokens(reference), tokens(text)
            result["wer"] = _edit_count(expected, actual) / len(expected) if expected else None
            result["word_normalization"] = "NFKC_casefold_remove_punctuation_whitespace_tokens"
        return result
