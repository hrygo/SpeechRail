"""Stable domain errors that can be rendered at any public transport edge."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class SpeechRailError(Exception):
    code: str
    message: str
    retryable: bool = False
    param: str | None = None


class BackendNotReadyError(SpeechRailError):
    def __init__(self) -> None:
        super().__init__("backend_not_ready", "SpeechRail inference backend is not ready", True)
