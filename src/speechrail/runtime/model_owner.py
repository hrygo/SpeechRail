"""Single-instance model owners keyed by immutable model identity.

One owner exists per artifact identity + engine revision + compute config.
Voice selection, request identity and task identity never create a second copy
of the same weights; they only vary the reference condition or utterance state
inside the lease.  This module never loads or downloads a model by itself: the
caller supplies the loader, and loading only happens while a lease is acquired.
"""

from __future__ import annotations

import asyncio
import enum
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from contextlib import asynccontextmanager
from dataclasses import dataclass
from types import MappingProxyType
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from speechrail.config.model_catalog import ModelArtifact


class OwnerState(enum.StrEnum):
    """Lifecycle of one resident model owner."""

    UNLOADED = "unloaded"
    LOADING = "loading"
    READY = "ready"
    BUSY = "busy"
    DRAINING = "draining"
    FAILED = "failed"


class ModelOwnerError(RuntimeError):
    """Base class for owner lifecycle failures."""


class ModelOwnerNotRegisteredError(ModelOwnerError):
    """A lease was requested for an owner key that was never registered."""


class ModelOwnerIdentityError(ModelOwnerError):
    """A loaded model reported an identity that differs from its owner key."""


class ModelOwnerDrainingError(ModelOwnerError):
    """A new lease was requested while the owner is draining."""


@dataclass(frozen=True, slots=True)
class ModelOwnerKey:
    """Identity that decides whether two requests may share one resident model."""

    artifact_key: str
    artifact_revision: str
    engine_revision: str
    compute_config: str

    def __post_init__(self) -> None:
        for name in ("artifact_key", "artifact_revision", "engine_revision", "compute_config"):
            value = getattr(self, name)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{name} must be a non-empty string")

    @property
    def stable_id(self) -> str:
        """Return a stable, loggable owner identifier without local paths."""

        return "|".join(
            (
                self.artifact_key,
                self.artifact_revision,
                self.engine_revision,
                self.compute_config,
            )
        )

    @classmethod
    def from_artifact(
        cls,
        artifact: ModelArtifact,
        *,
        engine_revision: str,
        compute_config: str,
    ) -> ModelOwnerKey:
        """Derive an owner key from a resolved catalog artifact identity.

        Voice selection, request identity and task identity never enter the key:
        two voices that resolve to the same artifact share one owner, and only
        the reference condition and utterance state vary inside the lease.
        """

        revision = getattr(artifact, "revision", None)
        if not isinstance(revision, str) or not revision.strip():
            raise ValueError("artifact.revision must be a non-empty string")
        return cls(
            artifact_key=artifact.key,
            artifact_revision=revision,
            engine_revision=engine_revision,
            compute_config=compute_config,
        )

    def identity(self) -> Mapping[str, str]:
        return MappingProxyType(
            {
                "artifact_key": self.artifact_key,
                "artifact_revision": self.artifact_revision,
                "engine_revision": self.engine_revision,
                "compute_config": self.compute_config,
            }
        )


class ModelOwner:
    """Own one resident model, its identity handshake and its lease count."""

    def __init__(
        self,
        key: ModelOwnerKey,
        *,
        load: Callable[[], Awaitable[object]],
        verify: Callable[[object], Mapping[str, object]] | None = None,
        close: Callable[[object], Awaitable[None]] | None = None,
    ) -> None:
        self._key = key
        self._load = load
        self._verify = verify
        self._close = close
        self._state = OwnerState.UNLOADED
        self._model: object | None = None
        self._active = 0
        self._load_lock = asyncio.Lock()
        self._idle = asyncio.Event()
        self._idle.set()

    @property
    def key(self) -> ModelOwnerKey:
        return self._key

    @property
    def state(self) -> OwnerState:
        return self._state

    @property
    def active_leases(self) -> int:
        return self._active

    @property
    def model(self) -> object | None:
        return self._model

    async def _ensure_loaded(self) -> None:
        if self._state is OwnerState.DRAINING:
            raise ModelOwnerDrainingError(f"owner is draining: {self._key.stable_id}")
        if self._model is not None and self._state in {OwnerState.READY, OwnerState.BUSY}:
            return
        async with self._load_lock:
            if self._state is OwnerState.DRAINING:
                raise ModelOwnerDrainingError(f"owner is draining: {self._key.stable_id}")
            if self._model is not None and self._state in {OwnerState.READY, OwnerState.BUSY}:
                return
            self._state = OwnerState.LOADING
            try:
                model = await self._load()
                self._require_identity(model)
            except BaseException:
                self._model = None
                self._state = OwnerState.FAILED
                raise
            self._model = model
            self._state = OwnerState.READY

    def _require_identity(self, model: object) -> None:
        if self._verify is None:
            return
        reported = {str(k): str(v) for k, v in self._verify(model).items()}
        expected = dict(self._key.identity())
        if reported != expected:
            raise ModelOwnerIdentityError(
                "loaded model identity does not match the requested owner"
            )

    @asynccontextmanager
    async def lease(self) -> AsyncIterator[Any]:
        """Acquire one lease, loading the model once on first use."""

        await self._ensure_loaded()
        self._active += 1
        self._idle.clear()
        self._state = OwnerState.BUSY
        try:
            yield self._model
        finally:
            self._active = max(0, self._active - 1)
            if self._active == 0:
                self._idle.set()
                if self._state is OwnerState.BUSY:
                    self._state = OwnerState.READY

    async def begin_drain(
        self,
        *,
        timeout: float | None = None,  # noqa: ASYNC109 - caller owns the deadline
    ) -> None:
        """Reject new leases, wait for active ones, then unload the model.

        A drained owner is retired: it stays in ``DRAINING`` and never serves a
        new lease, so a replaced identity cannot silently resurrect old weights.
        Use ``stop`` for a reusable unload and a fresh handshake instead.
        """

        self._state = OwnerState.DRAINING
        if self._active:
            await asyncio.wait_for(self._idle.wait(), timeout)
        await self._unload(retired=True)

    async def stop(self) -> None:
        """Stop the owner and allow a later lease to re-handshake from scratch."""

        await self._unload()

    async def _unload(self, *, retired: bool = False) -> None:
        model = self._model
        self._model = None
        self._state = OwnerState.DRAINING if retired else OwnerState.UNLOADED
        if model is not None and self._close is not None:
            await self._close(model)


class ModelOwnerRegistry:
    """Explicit owner lookup; no path, directory name or voice inference."""

    def __init__(self) -> None:
        self._owners: dict[ModelOwnerKey, ModelOwner] = {}

    def register(self, owner: ModelOwner) -> None:
        if owner.key in self._owners:
            raise ValueError(f"duplicate model owner: {owner.key.stable_id}")
        self._owners[owner.key] = owner

    def owner(self, key: ModelOwnerKey) -> ModelOwner:
        try:
            return self._owners[key]
        except KeyError as exc:
            raise ModelOwnerNotRegisteredError(
                f"model owner is not registered: {key.stable_id}"
            ) from exc

    def by_artifact(self, artifact_key: str) -> tuple[ModelOwner, ...]:
        return tuple(
            owner for key, owner in self._owners.items() if key.artifact_key == artifact_key
        )

    @asynccontextmanager
    async def acquire(self, key: ModelOwnerKey) -> AsyncIterator[Any]:
        async with self.owner(key).lease() as model:
            yield model

    def states(self) -> Mapping[ModelOwnerKey, OwnerState]:
        return MappingProxyType({key: owner.state for key, owner in self._owners.items()})

    async def drain_artifact(
        self,
        artifact_key: str,
        *,
        timeout: float | None = None,  # noqa: ASYNC109 - caller owns the deadline
    ) -> None:
        for owner in self.by_artifact(artifact_key):
            await owner.begin_drain(timeout=timeout)

    async def stop_all(self) -> None:
        for owner in tuple(self._owners.values()):
            await owner.stop()


__all__ = [
    "ModelOwner",
    "ModelOwnerDrainingError",
    "ModelOwnerError",
    "ModelOwnerIdentityError",
    "ModelOwnerKey",
    "ModelOwnerNotRegisteredError",
    "ModelOwnerRegistry",
    "OwnerState",
]
