"""Serve the hand-written OpenAPI contract instead of a generated approximation.

``contracts/openapi.yaml`` is the reviewed public contract: it carries the
error responses, the optional Bearer scheme and the SpeechRail extensions that
FastAPI cannot infer from route signatures. Letting ``/openapi.json`` fall back
to the generated document would publish a materially weaker contract, so the
service serves the reviewed file verbatim and the parity gate keeps comparing
the routing table against that same file.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml
from fastapi import FastAPI

_PACKAGED = Path(__file__).resolve().parents[1] / "assets" / "openapi.yaml"
_SOURCE_CHECKOUT = Path(__file__).resolve().parents[3] / "contracts" / "openapi.yaml"


def contract_path() -> Path:
    """Return the reviewed contract shipped in the wheel, or the checkout copy."""

    if _PACKAGED.is_file():
        return _PACKAGED
    return _SOURCE_CHECKOUT


@lru_cache(maxsize=1)
def load_openapi_document() -> dict[str, Any]:
    """Load and cache the reviewed OpenAPI document."""

    path = contract_path()
    if not path.is_file():
        raise FileNotFoundError(f"OpenAPI contract is missing: {path}")
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise ValueError(f"OpenAPI contract is not a mapping: {path}")
    return document


def install_openapi_document(app: FastAPI) -> None:
    """Publish the reviewed contract at ``/openapi.json`` and in the API docs."""

    def openapi() -> dict[str, Any]:
        return load_openapi_document()

    app.openapi = openapi  # type: ignore[method-assign]
