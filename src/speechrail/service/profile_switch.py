"""Stopped-service model profile switching with one bounded rollback."""

from __future__ import annotations

import contextlib
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol

from speechrail.service.model_store import (
    PreparedModelSet,
    resolve_prepared_models,
    resolve_prepared_selection,
)
from speechrail.service.profile_store import ProfileStore


class ServiceController(Protocol):
    """Start and stop the one local SpeechRail service instance."""

    def stop(self) -> None: ...

    def start(self) -> None: ...


class PublicSmokeProbe(Protocol):
    """Validate one running model pair through the public API."""

    def run(self, prepared: PreparedModelSet) -> None: ...


PreparedIdResolver = Callable[[str, Path], PreparedModelSet]
SelectionResolver = Callable[[Mapping[str, object], Path], PreparedModelSet]


@dataclass(frozen=True, slots=True)
class ApplyResult:
    """Stable, path-free outcome for a local profile operation."""

    status: Literal["unchanged", "committed", "rolled_back", "not_ready"]
    operation_id: str | None
    error_code: str | None


def _resolve_prepared_id(prepared_id: str, app_home: Path) -> PreparedModelSet:
    return resolve_prepared_models(prepared_id, app_home=app_home)


def _resolve_selection(
    selection: Mapping[str, object], app_home: Path
) -> PreparedModelSet:
    return resolve_prepared_selection(selection, app_home=app_home)


def _selection(prepared: PreparedModelSet, generation: int) -> dict[str, object]:
    return {
        "schema_version": 1,
        "preset": prepared.preset,
        "generation": generation,
        "asr": prepared.asr.key,
        "tts": prepared.tts.key,
        "runtime_lock_id": prepared.runtime_lock_id,
    }


def _matches(selection: Mapping[str, object], prepared: PreparedModelSet) -> bool:
    return (
        selection.get("preset") == prepared.preset
        and selection.get("asr") == prepared.asr.key
        and selection.get("tts") == prepared.tts.key
        and selection.get("runtime_lock_id") == prepared.runtime_lock_id
    )


def _mark_not_ready(store: ProfileStore, operation_id: str) -> None:
    try:
        store.mark(operation_id, "NOT_READY")
    except (OSError, RuntimeError, TypeError, ValueError):
        return


def _mark_rolling_back(store: ProfileStore, operation_id: str) -> None:
    try:
        store.mark(operation_id, "ROLLING_BACK")
    except (OSError, RuntimeError, TypeError, ValueError):
        return


def _rollback(
    *,
    store: ProfileStore,
    operation_id: str,
    previous: Mapping[str, object] | None,
    previous_prepared: PreparedModelSet | None,
    service: ServiceController,
    smoke: PublicSmokeProbe,
    service_touched: bool,
) -> ApplyResult:
    """Restore the previous selection and service once, without retry loops."""
    try:
        if service_touched:
            # Selection recovery must still run. A subsequent start/smoke
            # determines whether the single service is healthy again.
            with contextlib.suppress(Exception):
                service.stop()
        _mark_rolling_back(store, operation_id)
        store.rollback(operation_id)
        if service_touched and previous is not None:
            if previous_prepared is None:
                raise RuntimeError("previous profile was not verified")
            service.start()
            smoke.run(previous_prepared)
        return ApplyResult(
            status="rolled_back",
            operation_id=operation_id,
            error_code="profile_switch_failed",
        )
    except BaseException as exc:
        _mark_not_ready(store, operation_id)
        if not isinstance(exc, Exception):
            raise
        return ApplyResult(
            status="not_ready",
            operation_id=operation_id,
            error_code="profile_rollback_failed",
        )


def apply_prepared_profile(
    prepared_id: str,
    *,
    app_home: Path,
    service: ServiceController,
    smoke: PublicSmokeProbe,
    store: ProfileStore | None = None,
    prepared_resolver: PreparedIdResolver = _resolve_prepared_id,
    selection_resolver: SelectionResolver = _resolve_selection,
) -> ApplyResult:
    """Apply one verified ASR/TTS pair while the single service is stopped."""
    resolved_home = app_home.resolve()
    prepared = prepared_resolver(prepared_id, resolved_home)
    profile_store = store or ProfileStore(resolved_home)
    previous = profile_store.recover()
    if previous is not None and _matches(previous, prepared):
        return ApplyResult(status="unchanged", operation_id=None, error_code=None)
    previous_prepared = (
        selection_resolver(previous, resolved_home) if previous is not None else None
    )

    previous_generation = 0
    if previous is not None:
        generation = previous["generation"]
        if type(generation) is not int:
            raise ValueError("previous profile generation is invalid")
        previous_generation = generation
    candidate = _selection(prepared, previous_generation + 1)
    operation_id = profile_store.begin(previous, candidate)
    service_touched = False
    try:
        profile_store.mark(operation_id, "VERIFIED")
        profile_store.mark(operation_id, "STOPPING")
        service_touched = True
        service.stop()
        profile_store.mark(operation_id, "SWITCHING")
        profile_store.stage_candidate(operation_id)
        service.start()
        smoke.run(prepared)
        profile_store.mark(operation_id, "SMOKING")
        profile_store.commit(operation_id)
        return ApplyResult(status="committed", operation_id=operation_id, error_code=None)
    except BaseException as exc:
        result = _rollback(
            store=profile_store,
            operation_id=operation_id,
            previous=previous,
            previous_prepared=previous_prepared,
            service=service,
            smoke=smoke,
            service_touched=service_touched,
        )
        if not isinstance(exc, Exception):
            raise
        return result


__all__ = [
    "ApplyResult",
    "PublicSmokeProbe",
    "ServiceController",
    "apply_prepared_profile",
]
