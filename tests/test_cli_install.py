"""The release-asset install entry point: ``speechrail install``.

A downloader-only user has the wheel but no source checkout.  These tests keep
the command thin and honest: it resolves exactly one local wheel, refuses a
wheel that cannot match the running code, and delegates the real work to the
single packaged installer.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Any
from zipfile import ZipFile

import pytest

from speechrail import __version__, cli
from speechrail.cli import main
from speechrail.service import managed_install, profile_commands
from speechrail.service.installer_errors import InstallerError
from speechrail.service.managed_install import InstallResult
from speechrail.service.profile_store import ProfileStore


def _write_wheel(directory: Path, version: str) -> Path:
    """Write the smallest file that is still a real wheel with METADATA."""
    wheel = directory / f"speechrail-{version}-py3-none-any.whl"
    with ZipFile(wheel, "w") as archive:
        archive.writestr(
            f"speechrail-{version}.dist-info/METADATA",
            f"Metadata-Version: 2.3\nName: speechrail\nVersion: {version}\n",
        )
    return wheel


@pytest.fixture
def install_calls(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> list[dict[str, Any]]:
    """Capture installer calls instead of downloading models or touching runtime/current."""
    calls: list[dict[str, Any]] = []

    def fake_install_managed(wheel: Path, **kwargs: Any) -> InstallResult:
        calls.append({"wheel": wheel, **kwargs})
        app_home = Path(kwargs["app_home"])
        return InstallResult(
            app_home=app_home,
            runtime_python=app_home / "runtime/current/.venv/bin/python",
            plist_path=Path.home() / "Library/LaunchAgents/com.speechrail.plist",
            enabled=bool(kwargs["enable"]),
            prepared_id="prepared-balanced",
            runtime_key="runtime-test",
        )

    monkeypatch.setattr(managed_install, "install_managed", fake_install_managed)
    monkeypatch.chdir(tmp_path)
    # Never read the developer's real selection from the default app home.
    monkeypatch.setattr(cli, "_default_app_home", lambda: tmp_path / "app-home")
    return calls


def test_install_requires_exactly_one_local_wheel(
    install_calls: list[dict[str, Any]], capsys: pytest.CaptureFixture[str]
) -> None:
    assert main(["install", "--yes"]) == 1
    assert "speechrail" in capsys.readouterr().err
    assert install_calls == []


def test_install_uses_the_local_wheel_and_stays_disabled_by_default(
    install_calls: list[dict[str, Any]], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    wheel = _write_wheel(tmp_path, __version__)
    app_home = tmp_path / "Application Support" / "SpeechRail"

    exit_code = main(
        [
            "install",
            "--yes",
            "--asr-spec",
            "fast",
            "--tts-spec",
            "fast",
            "--app-home",
            str(app_home),
        ]
    )
    assert exit_code == 0

    assert len(install_calls) == 1
    call = install_calls[0]
    assert call["wheel"] == wheel
    assert call["app_home"] == app_home
    assert call["asr_spec"] == "fast"
    assert call["tts_spec"] == "fast"
    assert call["auto"] == "off"
    assert call["enable"] is False
    assert callable(call["progress"])
    assert "not started" in capsys.readouterr().out


def test_install_starts_the_service_only_when_asked(
    install_calls: list[dict[str, Any]], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _write_wheel(tmp_path, __version__)

    assert main(["install", "--yes", "--asr-spec", "fast", "--tts-spec", "fast", "--enable"]) == 0

    assert install_calls[0]["enable"] is True
    assert "registered and started" in capsys.readouterr().out


def test_install_refuses_a_wheel_that_cannot_match_this_code(
    install_calls: list[dict[str, Any]], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _write_wheel(tmp_path, "0.0.1")

    assert main(["install", "--yes"]) == 1

    assert "0.0.1" in capsys.readouterr().err
    assert install_calls == []


def test_install_requires_confirmation_before_any_mutation(
    install_calls: list[dict[str, Any]], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _write_wheel(tmp_path, __version__)

    assert main(["install", "--asr-spec", "fast", "--tts-spec", "fast"]) == 1

    assert install_calls == []
    assert "Cancelled." in capsys.readouterr().out


def test_install_recommends_specs_when_none_are_given(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_wheel(tmp_path, __version__)
    monkeypatch.setattr(
        profile_commands, "recommend_selection", lambda _: ("quality", "fast")
    )

    assert main(["install", "--yes"]) == 0

    assert install_calls[0]["asr_spec"] == "quality"
    assert install_calls[0]["tts_spec"] == "fast"


def test_install_keeps_the_preset_the_app_home_already_committed_to(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An upgrade must not restart the memory recommendation lottery."""
    _write_wheel(tmp_path, __version__)
    app_home = tmp_path / "SpeechRail"
    ProfileStore(app_home).initialize(
        {
            "schema_version": 2,
            "asr_spec": "fast",
            "tts_spec": "fast",
            "auto": "off",
            "generation": 1,
            "runtime_lock_id": "runtime-v1",
        }
    )
    monkeypatch.setattr(
        profile_commands, "recommend_selection", lambda _: ("quality", "quality")
    )

    assert main(["install", "--yes", "--app-home", str(app_home)]) == 0

    assert install_calls[0]["asr_spec"] == "fast"
    assert install_calls[0]["tts_spec"] == "fast"
    assert "kept from the installed service" in capsys.readouterr().out


def test_install_emits_one_machine_envelope(
    install_calls: list[dict[str, Any]], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _write_wheel(tmp_path, __version__)

    assert main(["install", "--yes", "--asr-spec", "fast", "--tts-spec", "fast", "--json"]) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "install"
    assert payload["status"] == "committed"
    assert payload["asr_spec"] == "fast"
    assert payload["tts_spec"] == "fast"
    assert payload["auto"] == "off"
    assert payload["enabled"] is False
    assert payload["downloaded_bytes"] == 0
    assert payload["reused_artifacts"] == []


def test_install_says_when_local_snapshots_are_already_registered(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The header must answer "will this download my models again?" up front."""
    _write_wheel(tmp_path, __version__)
    monkeypatch.setattr(cli, "_install_download_plan", lambda _home, _asr, _tts: ((), 0))

    assert main(["install", "--yes", "--asr-spec", "fast", "--tts-spec", "fast"]) == 0

    assert "expect no download" in capsys.readouterr().out


def test_install_names_the_artifacts_it_still_has_to_fetch(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write_wheel(tmp_path, __version__)
    monkeypatch.setattr(
        cli,
        "_install_download_plan",
        lambda _home, _asr, _tts: (("tts-1.7b-base-q8",), 2 * 1024**3),
    )

    assert main(["install", "--yes", "--asr-spec", "quality", "--tts-spec", "fast"]) == 0

    out = capsys.readouterr().out
    assert "downloading tts-1.7b-base-q8" in out
    assert "up to 2.0 GiB" in out


def test_install_renders_progress_and_a_download_summary(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Chunk-level events must collapse into readable lines plus one honest total."""
    _write_wheel(tmp_path, __version__)
    expected_bytes = 1_600_000_000

    def fake_install_managed(wheel: Path, **kwargs: Any) -> InstallResult:
        progress = kwargs["progress"]
        progress({"phase": "cache_hit", "artifact": "asr-1.7b-q8"})
        for written in range(0, 1_500_000_000, 100_000_000):
            progress(
                {
                    "phase": "download",
                    "artifact": "tts-1.7b-base-q8",
                    "file": "model.safetensors",
                    "bytes": written,
                    "expected_bytes": expected_bytes,
                }
            )
        progress({"phase": "verifying", "artifact": "tts-1.7b-base-q8"})
        progress({"phase": "verified", "preset": "quality"})
        install_calls.append({"wheel": wheel, **kwargs})
        app_home = Path(kwargs["app_home"])
        return InstallResult(
            app_home=app_home,
            runtime_python=app_home / "runtime/current/.venv/bin/python",
            plist_path=Path.home() / "Library/LaunchAgents/com.speechrail.plist",
            enabled=False,
            prepared_id="prepared-quality",
            runtime_key="runtime-test",
        )

    monkeypatch.setattr(managed_install, "install_managed", fake_install_managed)

    assert main(["install", "--yes", "--asr-spec", "quality", "--tts-spec", "fast"]) == 0

    out = capsys.readouterr().out
    assert "Reusing verified model asr-1.7b-q8" in out
    assert "Verifying tts-1.7b-base-q8" in out
    assert "Verified local models" in out
    assert "Downloading tts-1.7b-base-q8 80% (1.2 GiB / 1.5 GiB)" in out
    # 15 chunk events collapse into one line per 10% bucket that is reached.
    assert out.count("Downloading tts-1.7b-base-q8") == 9
    assert "Model download: 1.3 GiB of new files." in out


def test_install_reports_a_rerun_that_downloaded_nothing(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write_wheel(tmp_path, __version__)

    def fake_install_managed(wheel: Path, **kwargs: Any) -> InstallResult:
        kwargs["progress"]({"phase": "cache_hit", "artifact": "asr-1.7b-q8"})
        kwargs["progress"]({"phase": "cache_hit", "artifact": "tts-1.7b-base-q8"})
        install_calls.append({"wheel": wheel, **kwargs})
        app_home = Path(kwargs["app_home"])
        return InstallResult(
            app_home=app_home,
            runtime_python=app_home / "runtime/current/.venv/bin/python",
            plist_path=Path.home() / "Library/LaunchAgents/com.speechrail.plist",
            enabled=False,
            prepared_id="prepared-quality",
            runtime_key="runtime-test",
        )

    monkeypatch.setattr(managed_install, "install_managed", fake_install_managed)

    assert main(["install", "--yes", "--asr-spec", "quality", "--tts-spec", "fast"]) == 0

    assert "Model download: none; reused 2 verified local snapshots." in capsys.readouterr().out


class _ReadyResponse:
    status = 200

    def __enter__(self) -> _ReadyResponse:
        return self

    def __exit__(self, *args: object) -> None:
        return None


class _FakeTime:
    """Advance instantly so a readiness timeout never really waits."""

    def __init__(self) -> None:
        self._now = 0.0

    def monotonic(self) -> float:
        self._now += 1_000.0
        return self._now

    def sleep(self, _seconds: float) -> None:
        raise AssertionError("readiness polling must not sleep in this test")


def test_install_names_the_missing_prerequisite(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write_wheel(tmp_path, __version__)
    monkeypatch.setattr(cli.shutil, "which", lambda _name: None)

    assert main(["install", "--yes"]) == 1

    stderr = capsys.readouterr().err
    assert "uv" in stderr
    assert "astral.sh" in stderr
    assert install_calls == []


def test_install_reports_readiness_after_enabling(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write_wheel(tmp_path, __version__)
    monkeypatch.setattr(cli.shutil, "which", lambda _name: "/opt/homebrew/bin/uv")
    monkeypatch.setattr(cli, "urlopen", lambda request, timeout: _ReadyResponse())

    assert main(["install", "--yes", "--asr-spec", "fast", "--tts-spec", "fast", "--enable"]) == 0

    assert install_calls[0]["uv_executable"] == "/opt/homebrew/bin/uv"
    out = capsys.readouterr().out
    assert "Service is ready" in out
    assert "Change profile later" in out


def test_install_reports_a_service_that_never_becomes_ready(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write_wheel(tmp_path, __version__)

    def unavailable(request: object, timeout: float) -> object:
        raise OSError("connection refused")

    monkeypatch.setattr(cli, "urlopen", unavailable)
    monkeypatch.setattr(cli, "time", _FakeTime())

    assert main(["install", "--yes", "--asr-spec", "fast", "--tts-spec", "fast", "--enable"]) == 0

    out = capsys.readouterr().out
    assert "is not ready yet" in out
    assert "service preflight" in out


def test_install_turns_a_running_service_into_a_stop_instruction(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write_wheel(tmp_path, __version__)

    def refuses(wheel: Path, **kwargs: Any) -> InstallResult:
        raise InstallerError("managed installation requires the SpeechRail service to be stopped")

    monkeypatch.setattr(managed_install, "install_managed", refuses)

    assert main(["install", "--yes", "--asr-spec", "fast", "--tts-spec", "fast"]) == 1

    stderr = capsys.readouterr().err
    assert "service stop" in stderr
    assert "/runtime/current/.venv/bin/speechrail" in stderr


def test_install_turns_a_preset_conflict_into_a_choice(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write_wheel(tmp_path, __version__)

    def refuses(wheel: Path, **kwargs: Any) -> InstallResult:
        raise InstallerError("a different managed selection is already configured")

    monkeypatch.setattr(managed_install, "install_managed", refuses)

    assert main(["install", "--yes", "--asr-spec", "quality", "--tts-spec", "fast"]) == 1

    stderr = capsys.readouterr().err
    assert "one selection per app home" in stderr
    assert "profile apply --asr-spec" in stderr


def test_repository_shim_reexports_the_packaged_installer() -> None:
    """The release SOP, zero-setup and older notes import tools.install_macos."""
    shim_path = Path(__file__).parents[1] / "tools" / "install_macos.py"
    spec = importlib.util.spec_from_file_location("speechrail_tools_installer_shim", shim_path)
    assert spec is not None and spec.loader is not None
    shim = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = shim
    spec.loader.exec_module(shim)

    assert shim.install_managed is managed_install.install_managed
    assert shim.run_preflight is managed_install.run_preflight
    assert issubclass(shim.InstallerError, RuntimeError)
    assert not hasattr(shim, "main")
