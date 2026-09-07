from __future__ import annotations

import hashlib
from pathlib import Path

import httpx
import pytest

from speechrail.service import vad_model


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def test_vad_model_path_is_managed_models_root(tmp_path: Path) -> None:
    assert vad_model.vad_model_path(tmp_path) == (
        tmp_path / "models" / "vad" / "silero_vad.onnx"
    )


def test_ensure_vad_model_downloads_verifies_and_places(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    content = b"fake-silero-weights"
    monkeypatch.setattr(
        vad_model, "_VAD_DOWNLOAD_URL", "https://example.invalid/silero_vad.onnx"
    )
    monkeypatch.setattr(vad_model, "_VAD_SHA256", _sha256(content))

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url == "https://example.invalid/silero_vad.onnx"
        return httpx.Response(200, content=content)

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        path = vad_model.ensure_vad_model(tmp_path, client=client)

    assert path == vad_model.vad_model_path(tmp_path)
    assert path.is_file()
    assert path.read_bytes() == content


def test_ensure_vad_model_is_idempotent_without_network(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    content = b"already-present"
    target = vad_model.vad_model_path(tmp_path)
    target.parent.mkdir(parents=True)
    target.write_bytes(content)
    monkeypatch.setattr(vad_model, "_VAD_SHA256", _sha256(content))

    # No client is injected; a matching model must skip any network I/O.
    path = vad_model.ensure_vad_model(tmp_path)

    assert path == target
    assert target.read_bytes() == content


def test_ensure_vad_model_replaces_corrupt_model(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    good = b"fresh-weights"
    target = vad_model.vad_model_path(tmp_path)
    target.parent.mkdir(parents=True)
    target.write_bytes(b"corrupt")
    monkeypatch.setattr(
        vad_model, "_VAD_DOWNLOAD_URL", "https://example.invalid/silero_vad.onnx"
    )
    monkeypatch.setattr(vad_model, "_VAD_SHA256", _sha256(good))

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=good)

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        path = vad_model.ensure_vad_model(tmp_path, client=client)

    assert path == target
    assert target.read_bytes() == good


def test_ensure_vad_model_returns_none_on_download_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        vad_model, "_VAD_DOWNLOAD_URL", "https://example.invalid/silero_vad.onnx"
    )

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, text="unavailable")

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        assert vad_model.ensure_vad_model(tmp_path, client=client) is None

    assert not vad_model.vad_model_path(tmp_path).exists()


def test_ensure_vad_model_returns_none_on_hash_mismatch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        vad_model, "_VAD_DOWNLOAD_URL", "https://example.invalid/silero_vad.onnx"
    )
    monkeypatch.setattr(vad_model, "_VAD_SHA256", _sha256(b"expected"))

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"tampered")

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        assert vad_model.ensure_vad_model(tmp_path, client=client) is None

    assert not vad_model.vad_model_path(tmp_path).exists()


def test_write_vad_model_path_sets_key_preserving_other_lines(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text(
        "SPEECHRAIL_PORT=8201\nSPEECHRAIL_HOST=127.0.0.1\n", encoding="utf-8"
    )
    model = tmp_path / "models" / "vad" / "silero_vad.onnx"

    vad_model.write_vad_model_path(env_file, model)

    text = env_file.read_text(encoding="utf-8")
    assert "SPEECHRAIL_PORT=8201\n" in text
    assert "SPEECHRAIL_HOST=127.0.0.1\n" in text
    assert f"SPEECHRAIL_REALTIME_VAD_MODEL_PATH={model}\n" in text


def test_write_vad_model_path_replaces_existing_assignment(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text(
        "SPEECHRAIL_REALTIME_VAD_MODEL_PATH=/old/path\nSPEECHRAIL_PORT=8201\n",
        encoding="utf-8",
    )
    model = tmp_path / "models" / "vad" / "silero_vad.onnx"

    vad_model.write_vad_model_path(env_file, model)

    text = env_file.read_text(encoding="utf-8")
    assert f"SPEECHRAIL_REALTIME_VAD_MODEL_PATH={model}\n" in text
    assert "/old/path" not in text
    assert "SPEECHRAIL_PORT=8201\n" in text
