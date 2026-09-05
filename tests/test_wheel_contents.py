from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from zipfile import ZipFile

_REQUIRED_WHEEL_FILES = {
    "speechrail/assets/model-catalog.json",
    "speechrail/assets/runtime-lock.json",
    "speechrail/assets/runtime/asr.txt",
    "speechrail/assets/runtime/tts.txt",
    "speechrail/backends/qwen3_worker.py",
    "speechrail/backends/qwen3_tts_worker.py",
    "speechrail/config/model_catalog.py",
    "speechrail/service/bootstrap.py",
    "speechrail/service/executable.py",
    "speechrail/service/preflight.py",
}
_BUILT_WHEEL: Path | None = None


def _wheel_for_test() -> Path:
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


def assert_wheel_contents(wheel_path: Path) -> None:
    with ZipFile(wheel_path) as archive:
        names = set(archive.namelist())

    assert "speechrail/__main__.py" in names
    assert "speechrail/cli.py" in names
    assert "speechrail/assets/model-catalog.json" in names
    assert "speechrail/assets/runtime-lock.json" in names
    assert "speechrail/assets/runtime/asr.txt" in names
    assert "speechrail/assets/runtime/tts.txt" in names
    assert "speechrail/backends/qwen3_worker.py" in names
    assert "speechrail/backends/qwen3_tts_worker.py" in names
    assert "speechrail/service/preflight.py" in names
    assert "speechrail/service/executable.py" in names
    assert "speechrail/config/__init__.py" in names
    assert any(name.endswith(".dist-info/METADATA") for name in names)
    assert not any(name.startswith("tests/") for name in names)
    forbidden_suffixes = (".env", ".log", ".wav", ".mp3", ".safetensors")
    assert not any(name.endswith(forbidden_suffixes) for name in names)
    assert not any("/Users/" in name for name in names)


def test_built_wheel_contains_runtime_only() -> None:
    assert_wheel_contents(_wheel_for_test())


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
    )
    environment = os.environ.copy()
    environment.pop("PYTHONPATH", None)
    subprocess.run(
        [sys.executable, "-c", probe, str(wheel)],
        cwd=tmp_path,
        env=environment,
        check=True,
    )
