"""Offline subprocess configuration for a local Qwen3-TTS runtime.

This module deliberately contains no vendor import.  The worker process owns
the optional runtime dependency and receives only an already-validated local
snapshot path.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Literal


@dataclass(frozen=True, slots=True)
class Qwen3TtsBackendConfig:
    repository_root: Path
    python_executable: Path
    model_dir: Path
    device: Literal["mps", "cpu"]
    dtype: Literal["float16", "float32"]
    sample_rate: int
    timeout_seconds: float = 120.0

    def __post_init__(self) -> None:
        repository_root = self.repository_root.resolve(strict=True)
        python_executable = self.python_executable.absolute()
        if not python_executable.is_file() or not os.access(python_executable, os.X_OK):
            raise ValueError("python_executable must be an executable local file")
        if not self.model_dir.is_absolute():
            raise ValueError("model snapshot must be an absolute path")
        model_dir = self.model_dir.resolve(strict=True)
        if model_dir.is_relative_to(repository_root):
            raise ValueError("model snapshot must be outside repository")
        if not model_dir.is_dir() or not (model_dir / "config.json").is_file():
            raise ValueError("model snapshot is incomplete")
        if self.device == "mps" and self.dtype != "float16":
            raise ValueError("MPS requires float16")
        if self.device == "cpu" and self.dtype != "float32":
            raise ValueError("CPU requires float32")
        if self.sample_rate != 24_000:
            raise ValueError("Qwen3-TTS public PCM profile requires 24000 Hz")
        if self.timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        object.__setattr__(self, "repository_root", repository_root)
        object.__setattr__(self, "python_executable", python_executable)
        object.__setattr__(self, "model_dir", model_dir)

    def command(self) -> list[str]:
        return [
            str(self.python_executable),
            "-m",
            "speechrail.backends.qwen3_tts_worker",
            "--model-dir",
            str(self.model_dir),
            "--device",
            self.device,
            "--sample-rate",
            str(self.sample_rate),
        ]
