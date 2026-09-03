from __future__ import annotations

import importlib.util
import plistlib
import subprocess
import sys
from pathlib import Path
from zipfile import ZipFile

_SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "verify_release.py"
_SPEC = importlib.util.spec_from_file_location("speechrail_test_release", _SCRIPT_PATH)
assert _SPEC is not None and _SPEC.loader is not None
verify_release = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = verify_release
_SPEC.loader.exec_module(verify_release)


def _wheel(path: Path) -> None:
    with ZipFile(path, "w") as archive:
        for name in (
            "speechrail/__main__.py",
            "speechrail/cli.py",
            "speechrail-1.6.2.dist-info/METADATA",
        ):
            archive.writestr(name, "")


def _app_home(tmp_path: Path) -> Path:
    app_home = tmp_path / "SpeechRail"
    python = app_home / "runtime" / "current" / ".venv" / "bin" / "python"
    python.parent.mkdir(parents=True)
    python.touch()
    plist = tmp_path / "com.speechrail.plist"
    with plist.open("wb") as handle:
        plistlib.dump(
            {
                "Label": "com.speechrail",
                "ProgramArguments": [str(python), "-m", "speechrail", "serve"],
                "WorkingDirectory": str(app_home),
            },
            handle,
        )
    return app_home


def _http(responses: dict[str, tuple[int, object]]):
    def get(path: str) -> tuple[int, object]:
        return responses[path]

    return get


def test_verify_release_accepts_clean_runtime_and_ready_http_endpoints(tmp_path: Path) -> None:
    wheel = tmp_path / "speechrail.whl"
    _wheel(wheel)
    app_home = _app_home(tmp_path)
    plist = tmp_path / "com.speechrail.plist"
    responses = {
        "/health": (200, {"asr_ready": True, "tts_ready": True, "ready": True}),
        "/readyz": (200, {"ready": True}),
        "/v1/models": (200, {"data": [{"id": "speechrail/qwen3-asr-1.7b"}]}),
        "/v1/voices": (200, {"data": [{"id": "default", "available": True}]}),
    }

    result = verify_release.verify_release(
        wheel=wheel,
        app_home=app_home,
        plist_path=plist,
        runner=lambda command: subprocess.CompletedProcess(command, 0, stdout="", stderr=""),
        http_get=_http(responses),
    )

    assert result.ok is True
    assert all(check.ok for check in result.checks)


def test_verify_release_rejects_unready_health(tmp_path: Path) -> None:
    wheel = tmp_path / "speechrail.whl"
    _wheel(wheel)
    app_home = _app_home(tmp_path)
    plist = tmp_path / "com.speechrail.plist"
    responses = {
        "/health": (200, {"asr_ready": True, "tts_ready": False, "ready": False}),
        "/readyz": (503, {"ready": False}),
        "/v1/models": (200, {"data": []}),
        "/v1/voices": (200, {"data": []}),
    }

    result = verify_release.verify_release(
        wheel=wheel,
        app_home=app_home,
        plist_path=plist,
        runner=lambda command: subprocess.CompletedProcess(command, 0, stdout="", stderr=""),
        http_get=_http(responses),
    )

    assert result.ok is False
    assert next(check for check in result.checks if check.name == "health").ok is False
