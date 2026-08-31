from pathlib import Path

import pytest

from speechrail.backends.qwen3_native import Qwen3BackendConfig, validate_snapshot


def test_snapshot_preflight_rejects_missing_or_repository_local_models(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="absolute"):
        validate_snapshot(Path("relative"), repository_root=tmp_path)

    inside_repository = tmp_path / "models" / "qwen"
    inside_repository.mkdir(parents=True)
    with pytest.raises(ValueError, match="outside"):
        validate_snapshot(inside_repository, repository_root=tmp_path)


def test_backend_config_rejects_cpu_fallback_for_mps_profile(tmp_path: Path) -> None:
    model_dir = tmp_path.parent / "external-model"
    model_dir.mkdir(exist_ok=True)
    python = Path("/usr/bin/python3")

    with pytest.raises(ValueError, match="float16"):
        Qwen3BackendConfig(
            repository_root=tmp_path,
            python_executable=python,
            model_dir=model_dir,
            device="mps",
            dtype="float32",
        )
