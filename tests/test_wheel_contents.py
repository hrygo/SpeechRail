from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
import sys
from pathlib import Path
from zipfile import ZipFile

import pytest

_REQUIRED_WHEEL_FILES = {
    "speechrail/assets/model-catalog.json",
    "speechrail/assets/runtime-lock.json",
    "speechrail/assets/runtime/asr.txt",
    "speechrail/assets/runtime/tts.txt",
    "speechrail/assets/vendor/engine/dist/mlx_audio-0.5.6-py3-none-any.whl",
    "speechrail/assets/vendor/engine/dist/provenance.json",
    "speechrail/backends/qwen3_worker.py",
    "speechrail/backends/qwen3_tts_worker.py",
    "speechrail/config/model_catalog.py",
    "speechrail/service/bootstrap.py",
    "speechrail/service/executable.py",
    "speechrail/service/managed_install.py",
    "speechrail/service/preflight.py",
}
_BUILT_WHEEL: Path | None = None


def _wheel_for_test() -> Path:
    configured_wheel = os.environ.get("SPEECHRAIL_WHEEL_PATH")
    if configured_wheel:
        wheel = Path(configured_wheel).resolve()
        assert wheel.is_file(), f"configured wheel does not exist: {wheel}"
        return wheel

    global _BUILT_WHEEL
    if _BUILT_WHEEL is not None:
        return _BUILT_WHEEL
    before = {
        wheel.resolve(): (wheel.stat().st_mtime_ns, wheel.read_bytes())
        for wheel in Path("dist").glob("*.whl")
    }
    subprocess.run(["uv", "build", "--no-sources", "--wheel"], check=True)
    wheels = sorted(Path("dist").glob("*.whl"))
    assert wheels, "failed to locate built wheel in dist/"
    changed = [
        wheel
        for wheel in wheels
        if before.get(wheel.resolve())
        != (wheel.stat().st_mtime_ns, wheel.read_bytes())
    ]
    assert changed, "uv build did not produce a new wheel"
    _BUILT_WHEEL = max(changed, key=lambda wheel: wheel.stat().st_mtime_ns).resolve()
    return _BUILT_WHEEL


def test_configured_wheel_path_skips_rebuild(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    wheel = tmp_path / "speechrail-test.whl"
    wheel.write_bytes(b"test artifact")
    monkeypatch.setenv("SPEECHRAIL_WHEEL_PATH", str(wheel))

    def fail_build(*args: object, **kwargs: object) -> None:
        raise AssertionError("configured wheel path must skip uv build")

    monkeypatch.setattr(subprocess, "run", fail_build)

    assert _wheel_for_test() == wheel.resolve()


def assert_wheel_contents(wheel_path: Path) -> None:
    with ZipFile(wheel_path) as archive:
        names = set(archive.namelist())

    assert "speechrail/__main__.py" in names
    assert "speechrail/cli.py" in names
    assert "speechrail/assets/model-catalog.json" in names
    assert "speechrail/assets/runtime-lock.json" in names
    assert "speechrail/assets/runtime/asr.txt" in names
    assert "speechrail/assets/runtime/tts.txt" in names
    assert (
        "speechrail/assets/vendor/engine/dist/"
        "mlx_audio-0.5.6-py3-none-any.whl"
    ) in names
    assert "speechrail/assets/vendor/engine/dist/provenance.json" in names
    assert not any("mlx-audio-incremental/src/" in name for name in names)
    assert "speechrail/backends/qwen3_worker.py" in names
    assert "speechrail/backends/qwen3_tts_worker.py" in names
    assert "speechrail/service/managed_install.py" in names
    assert "speechrail/service/preflight.py" in names
    assert "speechrail/runtime/executable.py" in names
    assert "speechrail/config/__init__.py" in names
    assert any(name.endswith(".dist-info/METADATA") for name in names)
    assert not any(name.startswith("tests/") for name in names)
    forbidden_suffixes = (".env", ".log", ".wav", ".mp3", ".safetensors")
    assert not any(name.endswith(forbidden_suffixes) for name in names)
    assert not any("/Users/" in name for name in names)


def test_built_wheel_contains_runtime_only() -> None:
    assert_wheel_contents(_wheel_for_test())


def test_built_wheel_embeds_the_pinned_controlled_engine() -> None:
    wheel = _wheel_for_test()
    engine_name = "mlx_audio-0.5.6-py3-none-any.whl"
    engine_asset = f"speechrail/assets/vendor/engine/dist/{engine_name}"
    provenance_asset = "speechrail/assets/vendor/engine/dist/provenance.json"

    with ZipFile(wheel) as archive:
        engine_bytes = archive.read(engine_asset)
        provenance = json.loads(archive.read(provenance_asset))
        lock = json.loads(archive.read("speechrail/assets/runtime-lock.json"))

    assert hashlib.sha256(engine_bytes).hexdigest() == lock["engine_wheel"]["sha256"]
    assert provenance == lock["engine_wheel"]
    with ZipFile(io.BytesIO(engine_bytes)) as engine:
        names = set(engine.namelist())
    assert "mlx_audio/tts/models/qwen3_tts/incremental.py" in names
    assert "mlx_audio/tts/models/qwen3_tts/incremental_backend.py" in names
    assert "mlx_audio/tts/models/qwen3_tts/incremental_probe.py" in names
    assert not any("__pycache__" in name or name.endswith(".pyc") for name in names)


def test_wheel_imports_workers_and_runtime_modules_outside_checkout(tmp_path: Path) -> None:
    wheel = _wheel_for_test().resolve()

    probe = (
        "import sys\n"
        "sys.path.insert(0, sys.argv[1])\n"
        "import speechrail\n"
        "assert str(speechrail.__file__).startswith(sys.argv[1])\n"
        "import speechrail.service.preflight\n"
        "import speechrail.backends.qwen3_worker\n"
        "import speechrail.backends.qwen3_tts_worker\n"
        "import speechrail.config.model_catalog\n"
        "import speechrail.service.bootstrap\n"
        "import speechrail.service.managed_install\n"
    )
    environment = os.environ.copy()
    environment.pop("PYTHONPATH", None)
    subprocess.run(
        [sys.executable, "-c", probe, str(wheel)],
        cwd=tmp_path,
        env=environment,
        check=True,
    )
