"""The current-boundaries checker must actually fail on the drift it claims to catch."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest


def _checker() -> object:
    script_path = (
        Path(__file__).parents[1] / "scripts" / "check_current_boundaries_contract.py"
    )
    spec = importlib.util.spec_from_file_location(
        "check_current_boundaries_contract",
        script_path,
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_current_boundaries_states_nothing_the_code_contradicts() -> None:
    """The active document must not drift back into a known-false claim."""

    module = _checker()
    assert module.find_drift(  # type: ignore[attr-defined]
        (Path(__file__).parents[1] / "docs" / "architecture" / "current-boundaries.md")
        .read_text(encoding="utf-8")
    ) == []


@pytest.mark.parametrize(
    ("sentence", "expected"),
    [
        ("6. 仓库/源码当前 release 版本为 `3.5.6`。", "hardcodes a release version"),
        ("10. 词级时间戳由 ASR 原生输出提供，不依赖 aligner。", "ASR-native word timestamps"),
        (
            "各 TTS spec 的 custom_voice / base（`reference` 另含 `voice_design`）是 lane。",
            "binds voice_design to the reference spec",
        ),
    ],
)
def test_a_known_false_claim_is_reported(sentence: str, expected: str) -> None:
    """A single reverted sentence must fail the gate, not pass silently."""

    module = _checker()
    problems = module.find_drift(  # type: ignore[attr-defined]
        f"1. 一条无关内容。\n{sentence}\n"
    )
    assert any(expected in problem for problem in problems), problems


def test_dropping_the_voice_design_statement_is_itself_drift() -> None:
    """Silence is not agreement: the lane statement has to stay."""

    module = _checker()
    problems = module.find_drift("1. 一条无关内容。\n")  # type: ignore[attr-defined]
    assert any("independent" in problem for problem in problems), problems


def test_unrelated_prose_is_not_flagged() -> None:
    """The checker anchors on claims, so it must not scan for forbidden words."""

    module = _checker()
    text = (
        "1. 本机部署了 release 3.5.6，voice_design 与 reference 无关。\n"
        "2. 版本号由 pyproject.toml 定义。\n"
        "3. `voice_design` 不与档位绑定，只处理设计任务。\n"
    )
    assert module.find_drift(text) == []  # type: ignore[attr-defined]
