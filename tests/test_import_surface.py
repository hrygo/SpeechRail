"""Shipped modules must import on their own, without an import cycle.

The service is a modular monolith, so each published module has to be usable as
the *first* import in a fresh interpreter.  A cycle that only resolves when a
particular module happens to be imported first is a real defect: a caller,
tool or test that starts from the other end gets an ``ImportError``.
"""

from __future__ import annotations

import subprocess
import sys

import pytest

_STANDALONE_IMPORTS = (
    "speechrail.config",
    "speechrail.domain.tts",
    "speechrail.domain.model_spec",
    "speechrail.application.services",
    "speechrail.app",
)


@pytest.mark.parametrize("module", _STANDALONE_IMPORTS)
def test_module_imports_as_the_first_import_in_a_fresh_interpreter(module: str) -> None:
    completed = subprocess.run(
        [sys.executable, "-c", f"import {module}"],
        capture_output=True,
        text=True,
        check=False,
    )

    assert completed.returncode == 0, (
        f"`import {module}` failed in a fresh interpreter:\n{completed.stderr}"
    )
