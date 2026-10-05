"""Verify codec EOS handling without importing MLX or loading a model."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import numpy as np
import pytest

_ROOT = Path(__file__).resolve().parents[1]
_OVERLAY = (
    _ROOT / "vendor/mlx-audio-incremental/src/mlx_audio/tts/models/qwen3_tts"
)


def _load_backend(monkeypatch: pytest.MonkeyPatch) -> ModuleType:
    package_name = "speechrail_test_vendor_eos"
    package = ModuleType(package_name)
    package.__path__ = [str(_OVERLAY)]  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, package_name, package)
    mlx = ModuleType("mlx")
    core = ModuleType("mlx.core")
    core.eval = lambda *values: None  # type: ignore[attr-defined]
    mlx.core = core  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx", mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", core)
    for name in ("incremental", "incremental_backend"):
        qualified = f"{package_name}.{name}"
        spec = importlib.util.spec_from_file_location(qualified, _OVERLAY / f"{name}.py")
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        monkeypatch.setitem(sys.modules, qualified, module)
        spec.loader.exec_module(module)
    return module


def test_backend_codec_eos_never_runs_code_predictor_or_decoder(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = _load_backend(monkeypatch)
    sampled = []
    forwards = []

    class Talker:
        def __call__(self, embeds: Any, *, cache: Any) -> tuple[Any, Any]:
            forwards.append(embeds)
            return np.zeros((1, 1, 4)), np.zeros((1, 1, 4))

        @property
        def code_predictor(self) -> Any:
            raise AssertionError("EOS is a stop marker, not an audio code")

        def get_input_embeddings(self) -> Any:
            raise AssertionError("EOS must not become the next codec embedding")

    def sample_token(*args: Any, **kwargs: Any) -> Any:
        sampled.append(kwargs)
        return np.array([[2150]])

    model = SimpleNamespace(
        talker=Talker(), _sample_token=sample_token, sample_rate=24_000,
    )
    backend = module.Qwen3TtsIncrementalBackend(
        model, variant="custom_voice", speaker="serena",
    )
    # Use the same state produced by begin_generation; only the model is fake.
    backend._started = True
    backend._input_embeds = np.zeros((1, 1, 4))
    backend._eos_token_id = 2150
    backend._suppress_tokens = []
    backend._num_code_groups = 16
    backend._code_cache = [SimpleNamespace(keys=None, values=None, offset=0)]

    outcome = backend.advance(token=None, seal=True)

    assert outcome.terminal and outcome.pcm16 == b""
    assert backend._generated_tokens == [] and backend._generated_codes == []
    assert backend._pending_codec_embed is None
    assert backend._frames == 0
    # Terminal is absorbing even when the private backend is called directly.
    assert backend.advance(token=None, seal=False).terminal
    assert len(forwards) == len(sampled) == 1
