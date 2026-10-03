"""Bounded render receipts for verifiable service-side audio delivery."""

from __future__ import annotations

import hashlib
import threading
import time
from dataclasses import dataclass, field, replace
from typing import Literal, Protocol
from uuid import uuid4

from speechrail.backends.model_identity import is_observed_runtime_revision
from speechrail.domain.render_recipe import RenderRecipe

ReceiptStatus = Literal["pending", "completed", "cancelled", "error"]


class _Hasher(Protocol):
    def update(self, data: bytes) -> None: ...
    def hexdigest(self) -> str: ...


@dataclass(slots=True)
class _ReceiptState:
    receipt_id: str
    request_id: str
    response_id: str | None
    voice_id: str
    voice_revision: str | None
    model_artifact: str | None
    model_source: str | None
    model_variant: str | None
    model_catalog_revision: str | None
    model_runtime_revision: str | None
    plan_id: str | None
    plan_digest: str | None
    window_index: int | None
    checkpoint_id: str | None
    output_format: str
    sample_rate: int
    channels: int
    boundary: str
    text_summary: dict[str, object] | None = None
    planner_summary: dict[str, object] | None = None
    recipe: RenderRecipe | None = None
    created_at: float = field(default_factory=time.time)
    status: ReceiptStatus = "pending"
    completed_at: float | None = None
    sample_count: int = 0
    error_code: str | None = None
    _hasher: _Hasher = field(default_factory=hashlib.sha256, repr=False)


class RenderReceiptRegistry:
    """Thread-safe bounded receipt store containing metadata and hashes only."""

    def __init__(self, *, max_entries: int = 512) -> None:
        if max_entries < 1:
            raise ValueError("max_entries must be positive")
        self._max_entries = max_entries
        self._lock = threading.RLock()
        self._entries: dict[str, _ReceiptState] = {}
        self._order: list[str] = []

    def _make_room_locked(self) -> None:
        while len(self._order) >= self._max_entries:
            victim_index = next(
                (
                    index
                    for index, existing_id in enumerate(self._order)
                    if self._entries[existing_id].status != "pending"
                ),
                None,
            )
            if victim_index is None:
                raise RuntimeError("render receipt store is full of pending entries")
            existing_id = self._order.pop(victim_index)
            self._entries.pop(existing_id, None)

    def begin(
        self,
        *,
        request_id: str,
        response_id: str | None = None,
        voice_id: str,
        voice_revision: str | None,
        model_artifact: str | None,
        model_source: str | None,
        model_variant: str | None,
        model_catalog_revision: str | None,
        model_runtime_revision: str | None,
        plan_id: str | None = None,
        plan_digest: str | None = None,
        window_index: int | None = None,
        checkpoint_id: str | None = None,
        output_format: str,
        sample_rate: int,
        channels: int = 1,
        boundary: str = "pcm16_pre_transport",
        text_summary: dict[str, object] | None = None,
        planner_summary: dict[str, object] | None = None,
        recipe: RenderRecipe | None = None,
    ) -> str:
        if sample_rate <= 0 or channels <= 0:
            raise ValueError("invalid audio format")
        if window_index is not None and (type(window_index) is not int or window_index < 0):
            raise ValueError("render window index must be a non-negative integer")
        if checkpoint_id is not None and not checkpoint_id.strip():
            raise ValueError("render checkpoint id must not be blank")
        receipt_id = f"rr_{uuid4().hex}"
        state = _ReceiptState(
            receipt_id=receipt_id,
            request_id=request_id,
            response_id=response_id,
            voice_id=voice_id,
            voice_revision=voice_revision,
            model_artifact=model_artifact,
            model_source=model_source,
            model_variant=model_variant,
            model_catalog_revision=model_catalog_revision,
            model_runtime_revision=model_runtime_revision,
            plan_id=plan_id,
            plan_digest=plan_digest,
            window_index=window_index,
            checkpoint_id=checkpoint_id,
            output_format=output_format,
            sample_rate=sample_rate,
            channels=channels,
            boundary=boundary,
            text_summary=dict(text_summary) if text_summary is not None else None,
            planner_summary=(
                dict(planner_summary) if planner_summary is not None else None
            ),
            recipe=recipe,
        )
        with self._lock:
            self._make_room_locked()
            self._entries[receipt_id] = state
            self._order.append(receipt_id)
        return receipt_id

    def bind_model_runtime_revision(self, receipt_id: str, revision: str) -> bool:
        """Bind one observed worker revision while the receipt is still pending."""
        if not isinstance(revision, str) or not revision:
            raise ValueError("runtime revision must be a non-empty string")
        with self._lock:
            state = self._entries[receipt_id]
            if state.status != "pending":
                return False
            if state.model_runtime_revision is not None:
                if state.model_runtime_revision != revision:
                    raise RuntimeError("render receipt runtime revision mismatch")
                return True
            state.model_runtime_revision = revision
            if state.recipe is not None and state.recipe.engine_revision is None:
                state.recipe = replace(state.recipe, engine_revision=revision)
            return True

    def bind_observed_sampling(
        self,
        receipt_id: str,
        *,
        seed_policy: str,
        observed_sampling_parameters: dict[str, object],
    ) -> bool:
        """Bind the sampler the worker reported while the receipt is pending.

        Sampling facts are observed after the audio exists, so they arrive
        after `begin`. Binding them late is what lets a recipe that was partial
        at request time become complete without ever guessing a seed.
        """

        if not isinstance(seed_policy, str) or not seed_policy:
            raise ValueError("seed policy must be a non-empty string")
        # `seed_policy` and `observed_sampling_parameters["seed_policy"]` are the
        # same fact stored twice — the payload is the worker's own report, and
        # both land in the canonical recipe, so both are covered by the digest.
        # Two copies of one claim that disagree would let a summary attest to
        # "the seed was fixed" and "the sampler was unseeded" at once, and the
        # recipe would still read as complete. Production callers pass one
        # observation to both, but the invariant belongs here rather than in
        # every caller.
        reported = observed_sampling_parameters.get("seed_policy")
        if reported is not None and reported != seed_policy:
            raise ValueError("seed policy contradicts the observed sampler")
        with self._lock:
            state = self._entries[receipt_id]
            if state.status != "pending":
                return False
            if state.recipe is None or state.recipe.seed_policy is not None:
                return False
            state.recipe = replace(
                state.recipe,
                seed_policy=seed_policy,
                observed_sampling_parameters=dict(observed_sampling_parameters),
            )
            return True

    def accept_pcm(self, receipt_id: str, pcm16: bytes) -> None:
        if len(pcm16) % 2:
            raise ValueError("PCM16 receipt input must contain whole samples")
        with self._lock:
            state = self._entries[receipt_id]
            if state.status != "pending":
                raise RuntimeError("render receipt is already terminal")
            state._hasher.update(pcm16)
            state.sample_count += len(pcm16) // 2

    def _finish(
        self,
        receipt_id: str,
        *,
        status: ReceiptStatus,
        error_code: str | None = None,
    ) -> None:
        with self._lock:
            state = self._entries[receipt_id]
            if state.status == "pending":
                state.status = status
                state.error_code = error_code
                state.completed_at = time.time()

    def complete(self, receipt_id: str) -> None:
        with self._lock:
            state = self._entries[receipt_id]
            if state.status == "pending" and state.sample_count == 0:
                state.status = "error"
                state.error_code = "empty_audio"
                state.completed_at = time.time()
                return
        self._finish(receipt_id, status="completed")

    def cancel(
        self,
        receipt_id: str,
        *,
        error_code: str = "cancelled",
    ) -> None:
        self._finish(
            receipt_id,
            status="cancelled",
            error_code=error_code,
        )

    def fail(self, receipt_id: str, error_code: str) -> None:
        self._finish(receipt_id, status="error", error_code=error_code)

    def find_by_request_id(self, request_id: str) -> dict[str, object]:
        """Return the newest receipt associated with one public request ID."""

        with self._lock:
            for receipt_id in reversed(self._order):
                if self._entries[receipt_id].request_id == request_id:
                    return self.get(receipt_id)
        raise KeyError(request_id)

    def get(self, receipt_id: str) -> dict[str, object]:
        with self._lock:
            state = self._entries.get(receipt_id)
            if state is None:
                raise KeyError(receipt_id)
            digest = state._hasher.hexdigest()
            return {
                "receipt_id": state.receipt_id,
                "request_id": state.request_id,
                "response_id": state.response_id,
                "status": state.status,
                "voice": {
                    "id": state.voice_id,
                    "revision": state.voice_revision,
                },
                "model": {
                    "artifact": state.model_artifact,
                    "source_model": state.model_source,
                    "variant": state.model_variant,
                    "catalog_revision": state.model_catalog_revision,
                    "runtime_revision": state.model_runtime_revision,
                },
                # A render fixes one plan, one voice revision, and one bounded
                # paragraph window.  Receipts keep only these identities and a
                # PCM digest: raw audio is never persisted here.
                "plan": {
                    "plan_id": state.plan_id,
                    "plan_sha256": state.plan_digest,
                    "window_index": state.window_index,
                    "checkpoint_id": state.checkpoint_id,
                },
                # What this render actually executed. Absent means this path
                # never assembled one, which is not the same as "no recipe".
                "recipe": (
                    state.recipe.to_dict() if state.recipe is not None else None
                ),
                "audio": {
                    "format": state.output_format,
                    "pcm_sample_rate": state.sample_rate,
                    "channels": state.channels,
                    "integrity_boundary": state.boundary,
                    "sample_count": state.sample_count,
                    "pcm_sha256": digest,
                },
                "text": (
                    dict(state.text_summary)
                    if state.text_summary is not None
                    else None
                ),
                "planner": (
                    dict(state.planner_summary)
                    if state.planner_summary is not None
                    else None
                ),
                "error_code": state.error_code,
                "created_at": state.created_at,
                "completed_at": state.completed_at,
            }


def bind_observed_runtime_revision(
    registry: RenderReceiptRegistry,
    receipt_id: str,
    *,
    synthesizer: object,
    voice: str,
) -> bool:
    """Bind an optional worker identity without changing the synthesis port."""
    revision = observed_runtime_revision_for_synthesizer(synthesizer, voice)
    if revision is None:
        return False
    try:
        return registry.bind_model_runtime_revision(receipt_id, revision)
    except Exception:
        return False


def bind_observed_sampling(
    registry: RenderReceiptRegistry,
    receipt_id: str,
    *,
    synthesizer: object,
    response_id: str,
) -> bool:
    """Bind what the worker reported it sampled with, without touching audio.

    Best-effort by design: a synthesizer that cannot report its sampler leaves
    the recipe partial instead of failing a render that already produced audio.
    """

    take = getattr(synthesizer, "take_sampling_observation", None)
    if not callable(take):
        return False
    try:
        observation = take(response_id)
    except Exception:
        return False
    if observation is None:
        return False
    try:
        return registry.bind_observed_sampling(
            receipt_id,
            seed_policy=observation.seed_policy,
            observed_sampling_parameters=observation.recipe_payload(),
        )
    except Exception:
        return False


def observed_runtime_revision_for_synthesizer(
    synthesizer: object,
    voice: str,
) -> str | None:
    """Read an optional worker identity without changing the synthesis port."""
    resolver = getattr(synthesizer, "runtime_revision_for_voice", None)
    if not callable(resolver):
        return None
    try:
        revision = resolver(voice)
    except Exception:
        # Receipt metadata is best-effort and must not turn a valid audio chunk
        # into a failed synthesis if a mutable voice registry changes mid-stream.
        return None
    if not isinstance(revision, str) or not is_observed_runtime_revision(revision):
        return None
    return revision
