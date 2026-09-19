"""Bounded render receipts for verifiable service-side audio delivery."""

from __future__ import annotations

import hashlib
import threading
import time
from dataclasses import dataclass, field
from typing import Literal, Protocol
from uuid import uuid4

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
    output_format: str
    sample_rate: int
    channels: int
    boundary: str
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

    def _evict_locked(self) -> None:
        while len(self._order) > self._max_entries:
            victim_index = next(
                (
                    index
                    for index, receipt_id in enumerate(self._order)
                    if self._entries[receipt_id].status != "pending"
                ),
                None,
            )
            if victim_index is None:
                raise RuntimeError("render receipt store is full of pending entries")
            receipt_id = self._order.pop(victim_index)
            self._entries.pop(receipt_id, None)

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
        output_format: str,
        sample_rate: int,
        channels: int = 1,
        boundary: str = "pcm16_pre_transport",
    ) -> str:
        if sample_rate <= 0 or channels <= 0:
            raise ValueError("invalid audio format")
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
            output_format=output_format,
            sample_rate=sample_rate,
            channels=channels,
            boundary=boundary,
        )
        with self._lock:
            self._entries[receipt_id] = state
            self._order.append(receipt_id)
            self._evict_locked()
        return receipt_id

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
        self._finish(receipt_id, status="completed")

    def cancel(self, receipt_id: str) -> None:
        self._finish(receipt_id, status="cancelled", error_code="cancelled")

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
                "audio": {
                    "format": state.output_format,
                    "pcm_sample_rate": state.sample_rate,
                    "channels": state.channels,
                    "integrity_boundary": state.boundary,
                    "sample_count": state.sample_count,
                    "pcm_sha256": digest,
                },
                "error_code": state.error_code,
                "created_at": state.created_at,
                "completed_at": state.completed_at,
            }
