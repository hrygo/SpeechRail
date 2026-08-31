"""Low-cardinality in-process counters suitable for an exporter boundary."""

from __future__ import annotations

from collections import Counter


class Metrics:
    def __init__(self) -> None:
        self._counters: Counter[tuple[str, str]] = Counter()

    def increment(self, name: str, outcome: str) -> None:
        self._counters[(name, outcome)] += 1

    def snapshot(self) -> dict[str, int]:
        return {f"{name}:{outcome}": value for (name, outcome), value in self._counters.items()}
