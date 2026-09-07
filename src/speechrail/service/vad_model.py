"""Optional Silero VAD model download for the managed setup flow.

The Silero VAD ONNX model (about 2.3 MB, MIT) is streamed from the official
``snakers4/silero-vad`` repository at a pinned commit and verified against a
locked SHA-256 digest, mirroring how catalog artifacts are handled. Unlike the
Qwen3 ASR/TTS profiles it is optional: the ``auto`` engine falls back to the
zero-dependency legacy VAD when no model is configured, so a failed or skipped
download never blocks a profile apply.
"""

from __future__ import annotations

import hashlib
import logging
import os
import tempfile
from pathlib import Path

import httpx

from speechrail.service.paths import ServiceLayout

logger = logging.getLogger(__name__)

_VAD_MODEL_DIR = "vad"
_VAD_MODEL_FILENAME = "silero_vad.onnx"
_VAD_REVISION = "867c2aa692646a1f1de3e94a15c9dd9f614c0acb"
_VAD_SHA256 = "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"
_VAD_MAX_BYTES = 8 * 1024 * 1024
_VAD_DOWNLOAD_URL = (
    "https://raw.githubusercontent.com/snakers4/silero-vad/"
    f"{_VAD_REVISION}/src/silero_vad/data/{_VAD_MODEL_FILENAME}"
)
_VAD_ENV_KEY = "SPEECHRAIL_REALTIME_VAD_MODEL_PATH"


class VadModelUnavailableError(ValueError):
    """The optional Silero VAD model could not be obtained or verified."""


def vad_model_path(app_home: Path) -> Path:
    """Return the managed on-disk path for the optional Silero VAD model."""
    return (
        ServiceLayout.for_app_home(app_home).models_root
        / _VAD_MODEL_DIR
        / _VAD_MODEL_FILENAME
    )


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _download(client: httpx.Client) -> bytes:
    """Stream and verify the pinned Silero VAD model, returning its bytes."""
    try:
        request = client.build_request(
            "GET", _VAD_DOWNLOAD_URL, headers={"Accept": "application/octet-stream"}
        )
        response = client.send(request, stream=True, follow_redirects=True)
    except httpx.HTTPError as exc:
        raise VadModelUnavailableError("VAD model download failed") from exc

    digest = hashlib.sha256()
    chunks: list[bytes] = []
    total = 0
    try:
        if response.status_code != 200:
            raise VadModelUnavailableError("VAD model download failed")
        for chunk in response.iter_bytes(chunk_size=1024 * 1024):
            data = bytes(chunk)
            total += len(data)
            if total > _VAD_MAX_BYTES:
                raise VadModelUnavailableError("VAD model exceeds the size limit")
            digest.update(data)
            chunks.append(data)
    except httpx.HTTPError as exc:
        raise VadModelUnavailableError("VAD model download failed") from exc
    finally:
        response.close()

    if digest.hexdigest() != _VAD_SHA256:
        raise VadModelUnavailableError("VAD model hash mismatch")
    return b"".join(chunks)


def _atomic_write(target: Path, content: bytes) -> None:
    """Atomically write private content, leaving no partial file behind."""
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(dir=target.parent, prefix=".silero_vad.")
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        temporary.chmod(0o600)
        temporary.replace(target)
        dir_fd = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        temporary.unlink(missing_ok=True)


def ensure_vad_model(app_home: Path, *, client: httpx.Client | None = None) -> Path | None:
    """Download and verify the Silero VAD model when it is not already present.

    Idempotent: an existing model whose hash matches the manifest is reused
    unchanged. Returns the model path on success, or ``None`` when the optional
    model could not be obtained — the caller then leaves the ``auto`` engine to
    fall back to the zero-dependency legacy VAD.
    """
    target = vad_model_path(app_home)
    if target.is_file():
        try:
            if _sha256_file(target) == _VAD_SHA256:
                return target
        except OSError:
            return None
        try:
            target.unlink()
        except OSError:
            return None

    owner = client is None
    if client is None:
        client = httpx.Client(timeout=httpx.Timeout(connect=30.0, read=120.0))
    try:
        try:
            content = _download(client)
        except VadModelUnavailableError as exc:
            logger.warning("optional Silero VAD model unavailable: %s", exc)
            return None
        _atomic_write(target, content)
        return target
    finally:
        if owner:
            client.close()


def write_vad_model_path(env_file: Path, model_path: Path) -> None:
    """Set ``SPEECHRAIL_REALTIME_VAD_MODEL_PATH`` in an env file, preserving other lines."""
    content = env_file.read_text(encoding="utf-8")
    assignment = f"{_VAD_ENV_KEY}={model_path}"
    updated: list[str] = []
    replaced = False
    for line in content.splitlines():
        if line.startswith(_VAD_ENV_KEY + "="):
            if not replaced:
                updated.append(assignment)
                replaced = True
            continue
        updated.append(line)
    if not replaced:
        if updated and updated[-1] != "":
            updated.append("")
        updated.append(assignment)
    _atomic_write(env_file, ("\n".join(updated) + "\n").encode("utf-8"))


__all__ = [
    "VadModelUnavailableError",
    "ensure_vad_model",
    "vad_model_path",
    "write_vad_model_path",
]
