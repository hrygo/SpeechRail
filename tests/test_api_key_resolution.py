from __future__ import annotations

from pathlib import Path

import pytest

from speechrail.config.auth import resolve_api_key


def _write_key(app_home: Path, value: str) -> None:
    env_file = app_home / "config" / ".env"
    env_file.parent.mkdir(parents=True)
    env_file.write_text(value, encoding="utf-8")
    env_file.chmod(0o600)


def test_environment_key_has_priority_over_managed_config(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write_key(tmp_path, 'SPEECHRAIL_API_KEY="file-key"\n')
    monkeypatch.setenv("SPEECHRAIL_API_KEY", " env-key ")

    assert resolve_api_key(app_home=tmp_path) == "env-key"


def test_blank_environment_key_falls_back_to_managed_config(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write_key(tmp_path, "export SPEECHRAIL_API_KEY='file-key'\n")
    monkeypatch.setenv("SPEECHRAIL_API_KEY", "  ")

    assert resolve_api_key(app_home=tmp_path) == "file-key"


def test_quoted_managed_key_allows_a_trailing_comment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write_key(tmp_path, 'SPEECHRAIL_API_KEY="file-key" # local only\n')
    monkeypatch.delenv("SPEECHRAIL_API_KEY", raising=False)

    assert resolve_api_key(app_home=tmp_path) == "file-key"


def test_default_app_home_can_be_selected_without_explicit_argument(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write_key(tmp_path, "SPEECHRAIL_API_KEY=file-key # local only\n")
    monkeypatch.delenv("SPEECHRAIL_API_KEY", raising=False)
    monkeypatch.setenv("SPEECHRAIL_APP_HOME", str(tmp_path))

    assert resolve_api_key() == "file-key"


def test_missing_key_keeps_keyless_mode(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("SPEECHRAIL_API_KEY", raising=False)
    monkeypatch.setenv("SPEECHRAIL_APP_HOME", str(tmp_path))

    assert resolve_api_key() is None


@pytest.mark.parametrize("value", ["bad\nkey", "bad\rkey"])
def test_key_with_header_injection_characters_is_rejected(
    value: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SPEECHRAIL_API_KEY", value)

    with pytest.raises(ValueError, match="invalid characters"):
        resolve_api_key()
