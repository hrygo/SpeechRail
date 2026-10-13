"""Read-only protocol facts shared by the connection's owned use cases."""

from __future__ import annotations

from collections.abc import Mapping
from copy import deepcopy
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any


class RealtimeConfiguration:
    """Root publishes one configuration; use cases receive only snapshot()."""

    def __init__(self, config: Mapping[str, Any]) -> None:
        self.replace(config)

    def replace(self, config: Mapping[str, Any]) -> None:
        self._values = deepcopy(dict(config))

    def snapshot(self) -> Mapping[str, Any]:
        return MappingProxyType(deepcopy(self._values))


@dataclass(frozen=True, slots=True)
class AsrIdentity:
    generation: int
    epoch: int
    item_id: str
    transcript_revision: int


@dataclass(frozen=True, slots=True)
class FrozenTranscript:
    task_id: str
    epoch: int
    generation: int
    item_id: str
    transcript: str
    transcript_revision: int
    item_start_wire: int
    item_end_wire: int
    item_start_kernel: int
    item_end_kernel: int
    pcm16: bytes
    overflow: bool
    degraded_reason: str | None
