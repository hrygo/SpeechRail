from __future__ import annotations

import hashlib

import pytest

from speechrail.application.render_receipts import RenderReceiptRegistry


def _begin(registry: RenderReceiptRegistry, request_id: str = "req-1") -> str:
    return registry.begin(
        request_id=request_id,
        response_id="resp-1",
        voice_id="narrator",
        voice_revision="vr_" + "a" * 32,
        model_artifact="tts-artifact",
        model_source="source-model",
        model_variant="base",
        model_catalog_revision="catalog-1",
        model_runtime_revision=None,
        output_format="pcm",
        sample_rate=24_000,
    )


def test_completed_receipt_hashes_exact_pcm_boundary() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry)
    chunks = (b"\x01\x00\x02\x00", b"\x03\x00")
    for chunk in chunks:
        registry.accept_pcm(receipt_id, chunk)
    registry.complete(receipt_id)

    receipt = registry.get(receipt_id)
    assert receipt["status"] == "completed"
    assert receipt["voice"] == {
        "id": "narrator",
        "revision": "vr_" + "a" * 32,
    }
    audio = receipt["audio"]
    assert isinstance(audio, dict)
    assert audio["integrity_boundary"] == "pcm16_pre_transport"
    assert audio["sample_count"] == 3
    assert audio["pcm_sha256"] == hashlib.sha256(b"".join(chunks)).hexdigest()
    assert receipt["model"]["runtime_revision"] is None


@pytest.mark.parametrize(
    ("finish", "status", "error_code"),
    [
        ("cancel", "cancelled", "cancelled"),
        ("fail", "error", "backend_timeout"),
    ],
)
def test_non_success_terminal_receipts_never_look_completed(
    finish: str,
    status: str,
    error_code: str,
) -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry)
    registry.accept_pcm(receipt_id, b"\x00\x00" * 4)
    if finish == "cancel":
        registry.cancel(receipt_id)
    else:
        registry.fail(receipt_id, error_code)

    receipt = registry.get(receipt_id)
    assert receipt["status"] == status
    assert receipt["error_code"] == error_code
    assert receipt["audio"]["sample_count"] == 4


def test_odd_pcm_is_rejected_without_advancing_integrity_state() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry)
    with pytest.raises(ValueError, match="whole samples"):
        registry.accept_pcm(receipt_id, b"\x00")
    receipt = registry.get(receipt_id)
    assert receipt["audio"]["sample_count"] == 0
    assert receipt["audio"]["pcm_sha256"] == hashlib.sha256(b"").hexdigest()


def test_terminal_receipt_rejects_late_audio() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry)
    registry.complete(receipt_id)
    with pytest.raises(RuntimeError, match="terminal"):
        registry.accept_pcm(receipt_id, b"\x00\x00")


def test_find_by_request_id_returns_latest_receipt() -> None:
    registry = RenderReceiptRegistry()
    first = _begin(registry, request_id="shared")
    registry.complete(first)
    second = _begin(registry, request_id="shared")
    registry.fail(second, "backend_error")
    assert registry.find_by_request_id("shared")["receipt_id"] == second
    with pytest.raises(KeyError):
        registry.find_by_request_id("missing")


def test_bounded_store_evicts_only_terminal_receipts() -> None:
    registry = RenderReceiptRegistry(max_entries=2)
    first = _begin(registry, request_id="first")
    registry.complete(first)
    second = _begin(registry, request_id="second")
    third = _begin(registry, request_id="third")

    with pytest.raises(KeyError):
        registry.get(first)
    assert registry.get(second)["status"] == "pending"
    assert registry.get(third)["status"] == "pending"


def test_store_full_of_pending_receipts_fails_closed() -> None:
    registry = RenderReceiptRegistry(max_entries=1)
    first = _begin(registry, request_id="first")
    with pytest.raises(RuntimeError, match="full of pending"):
        _begin(registry, request_id="second")
    assert registry.get(first)["status"] == "pending"
