"""Deterministic tests for the vendored incremental TTS state machine.

The vendor overlay is the only part of the incremental path that is not covered
by the SpeechRail unit suite, because it ships beside ``mlx_audio`` instead of
``speechrail``.  These tests load ``incremental.py`` straight from
``vendor/mlx-audio-incremental`` with no MLX import, so the frame-by-frame
text/EOS bookkeeping is checked without loading a model.
"""

from __future__ import annotations

import importlib.util
import sys
from collections.abc import Sequence
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[1]
_VENDOR_MODULE_PATH = (
    _REPO_ROOT
    / "vendor"
    / "mlx-audio-incremental"
    / "src"
    / "mlx_audio"
    / "tts"
    / "models"
    / "qwen3_tts"
    / "incremental.py"
)


def _load_vendor_incremental() -> ModuleType:
    # The module is not importable as ``mlx_audio.*`` in the test environment,
    # so load it by path and register it before execution for dataclasses.
    name = "speechrail_test_vendor_incremental"
    spec = importlib.util.spec_from_file_location(name, _VENDOR_MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(name, None)
    return module


vendor = _load_vendor_incremental()


def _encode(text: str) -> tuple[int, ...]:
    """Return one stable token id per character."""

    return tuple(range(1, len(text) + 1))


class _FakeBackend:
    """Record every frame the driver asks for and script the terminal frame."""

    def __init__(
        self,
        *,
        prefill_tokens: int = 2,
        terminal_after: int | None = None,
        silent: bool = False,
    ) -> None:
        self.frames: list[tuple[int | None, bool]] = []
        self.started_with: list[str] = []
        self.prefill_tokens = prefill_tokens
        self.terminal_after = terminal_after
        self.silent = silent
        self.cancelled = 0
        self.closed = 0

    def begin_generation(self, text: str) -> int:
        self.started_with.append(text)
        return self.prefill_tokens

    def advance(self, *, token: int | None, seal: bool):
        self.frames.append((token, seal))
        terminal = self.terminal_after is not None and len(self.frames) >= self.terminal_after
        pcm16 = b"" if self.silent else b"\x00\x00"
        return vendor.FrameOutcome(pcm16=pcm16, terminal=terminal)

    @property
    def generation_identity(self) -> str:
        return "fake-identity"

    @property
    def sample_rate(self) -> int:
        return 24_000

    @property
    def prefill_target_tokens(self) -> int:
        return self.prefill_tokens

    @property
    def peak_memory_bytes(self) -> int | None:
        return 1024

    def cancel(self) -> None:
        self.cancelled += 1

    def close(self) -> None:
        self.closed += 1


def _driver(backend: _FakeBackend, *, max_chars: int = 4096):
    return vendor.IncrementalSessionDriver(backend, _encode, max_chars=max_chars)


def _text_tokens(frames: Sequence[tuple[int | None, bool]]) -> list[int]:
    return [int(token) for token, seal in frames if token is not None and not seal]


def test_prefill_frame_runs_without_consuming_trailing_text() -> None:
    backend = _FakeBackend(prefill_tokens=2)
    driver = _driver(backend)
    driver.append_text("abcd")

    event = driver.step(max_steps=1)

    assert event.kind == "pcm"
    # The prefill forward pass *is* the first frame: upstream samples the first
    # codec frame from it and only reads the trailing queue on the next frame.
    assert backend.frames == [(None, False)]
    assert driver.prefill_target_tokens == 2
    assert driver.initial_prefill_count == 1


def test_append_after_first_pcm_reports_only_unconsumed_tokens() -> None:
    backend = _FakeBackend(prefill_tokens=2)
    driver = _driver(backend)
    assert len(driver.append_text("abcd")) == 4

    driver.step(max_steps=1)
    suffix = driver.append_text("ef")

    # Six tokens in total, two consumed by the prefill, one frame ran: the
    # suffix must still contain the four tokens the model has not seen.
    assert tuple(suffix) == (3, 4, 5, 6)
    assert backend.started_with == ["abcd"]


def test_trailing_text_is_fed_one_token_per_frame_after_the_prefill() -> None:
    backend = _FakeBackend(prefill_tokens=2, terminal_after=6)
    driver = _driver(backend)
    driver.append_text("abcd")
    driver.step(max_steps=1)
    driver.append_text("ef")
    driver.finish_input()

    while driver.step(max_steps=1).kind == "pcm":
        pass

    assert backend.frames[0] == (None, False)
    assert _text_tokens(backend.frames) == [3, 4, 5, 6]


def test_seal_uses_eos_once_and_then_pads() -> None:
    backend = _FakeBackend(prefill_tokens=2, terminal_after=5)
    driver = _driver(backend)
    driver.append_text("ab")
    driver.step(max_steps=1)
    driver.finish_input()
    while driver.step(max_steps=1).kind == "pcm":
        pass

    assert backend.frames[0] == (None, False)
    assert backend.frames[1] == (None, True)
    assert backend.frames[2:] == [(None, False), (None, False), (None, False)]


def test_starved_input_waits_without_sealing() -> None:
    backend = _FakeBackend(prefill_tokens=2)
    driver = _driver(backend)
    driver.append_text("ab")
    driver.step(max_steps=1)

    event = driver.step(max_steps=4)

    assert event.kind == "waiting_for_text"
    assert backend.frames == [(None, False)]

    driver.append_text("cd")
    assert driver.step(max_steps=1).kind == "pcm"
    assert driver.step(max_steps=1).kind == "pcm"
    assert _text_tokens(backend.frames) == [3, 4]


def test_append_that_rewrites_a_consumed_token_fails_closed() -> None:
    calls: list[str] = []

    def encode(text: str) -> tuple[int, ...]:
        calls.append(text)
        if text == "ab":
            return (1, 2)
        return (9, 2, 3)

    driver = vendor.IncrementalSessionDriver(_FakeBackend(prefill_tokens=1), encode)
    driver.append_text("ab")
    driver.step(max_steps=1)
    driver.step(max_steps=1)

    with pytest.raises(vendor.IncrementalTextError, match="stable_text_prefix_changed"):
        driver.append_text("c")


def test_append_limits_and_terminated_states_are_rejected() -> None:
    backend = _FakeBackend(prefill_tokens=1, terminal_after=1)
    driver = _driver(backend, max_chars=4)
    driver.append_text("abcd")

    with pytest.raises(vendor.IncrementalTextError, match="append_text_exceeds_limit"):
        driver.append_text("e")

    driver.step(max_steps=1)
    assert driver.step(max_steps=1).kind == "finished"
    with pytest.raises(vendor.IncrementalStateError, match="session_finished"):
        driver.append_text("z")


def test_cancel_and_close_are_idempotent_and_block_progress() -> None:
    backend = _FakeBackend(prefill_tokens=1)
    driver = _driver(backend)
    driver.append_text("ab")
    driver.step(max_steps=1)

    driver.cancel()
    driver.cancel()
    assert backend.cancelled == 1
    with pytest.raises(vendor.IncrementalStateError, match="session_cancelled"):
        driver.step(max_steps=1)
    with pytest.raises(vendor.IncrementalStateError, match="session_cancelled"):
        driver.append_text("c")

    driver.close()
    driver.close()
    assert backend.closed == 1
    with pytest.raises(vendor.IncrementalStateError, match="session_closed"):
        driver.finish_input()


def test_step_requires_a_positive_budget() -> None:
    driver = _driver(_FakeBackend(prefill_tokens=1))
    for value in (0, -1, True):
        with pytest.raises(vendor.IncrementalStateError, match="max_steps_invalid"):
            driver.step(max_steps=value)  # type: ignore[arg-type]


def test_max_steps_bounds_frames_and_reports_starvation() -> None:
    backend = _FakeBackend(prefill_tokens=1)
    driver = _driver(backend)
    driver.append_text("abc")
    driver.step(max_steps=1)

    event = driver.step(max_steps=2)

    assert event.kind == "pcm"
    assert _text_tokens(backend.frames) == [2]


def test_stalled_backend_without_starvation_raises_backend_error() -> None:
    backend = _FakeBackend(prefill_tokens=2, silent=True)
    driver = _driver(backend)
    driver.append_text("ab")
    driver.step(max_steps=1)
    driver.finish_input()

    # The input is sealed and no text is pending, so a silent frame budget can
    # only mean a stalled model, never a legal wait.  The driver reports that as
    # a terminal error event instead of raising into the caller.
    stalled = driver.step(max_steps=1)

    assert stalled.kind == "error"
    assert stalled.error_code == "tts_backend_failed"
    assert backend.frames == [(None, False), (None, True)]
    assert driver.step(max_steps=1).kind == "finished"


def test_metadata_is_proxied_from_the_backend() -> None:
    driver = _driver(_FakeBackend(prefill_tokens=3))

    assert driver.generation_identity == "fake-identity"
    assert driver.sample_rate == 24_000
    assert driver.prefill_target_tokens == 3
    assert driver.peak_memory_bytes == 1024


def test_feeder_actions_are_exhaustive() -> None:
    buffer = vendor.StableTextTokenBuffer(_encode)
    feeder = vendor.IncrementalTextFeeder(buffer)
    assert feeder.next_action() == "wait"

    buffer.append("ab")
    assert feeder.next_action() == "text"
    buffer.take(2)
    assert feeder.next_action() == "wait"

    feeder.finish_input()
    assert feeder.next_action() == "seal"
    feeder.seal()
    assert feeder.next_action() == "pad"
    assert feeder.starved is False


def test_frame_outcome_defaults_are_empty() -> None:
    outcome = vendor.FrameOutcome()
    assert isinstance(outcome, vendor.FrameOutcome)
    assert outcome.pcm16 == b""
    assert outcome.terminal is False


def test_public_names_are_stable() -> None:
    expected: dict[str, Any] = {
        "IncrementalSessionDriver": vendor.IncrementalSessionDriver,
        "IncrementalTextFeeder": vendor.IncrementalTextFeeder,
        "StableTextTokenBuffer": vendor.StableTextTokenBuffer,
        "IncrementalEvent": vendor.IncrementalEvent,
        "IncrementalTextError": vendor.IncrementalTextError,
        "IncrementalStateError": vendor.IncrementalStateError,
        "IncrementalBackendError": vendor.IncrementalBackendError,
    }
    for name, value in expected.items():
        assert getattr(vendor, name) is value
        assert name in vendor.__all__
