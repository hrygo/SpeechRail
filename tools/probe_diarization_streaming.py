"""Static capability probe for native streaming Sortformer diarization (R1).

Reads the current interpreter's package metadata and the installed NeMo
class definition only.  It never downloads anything and never restores model
weights: a missing runtime or an unverifiable streaming API is reported as
such, and the continuous diarization capability must stay offline until this
probe reports a verified method surface (plus an authorized real-CPU smoke).

Usage (from the repository root):

    uv run python tools/probe_diarization_streaming.py

Output is a single JSON object with the NeMo version, the streaming-related
methods/signatures found on the local ``SortformerEncLabelModel`` class, and
a verdict.  No snapshot paths, audio, or transcripts are printed.
"""

from __future__ import annotations

import inspect
import json
import sys
from importlib.metadata import PackageNotFoundError, version
from typing import Any

STREAMING_METHOD_HINTS = ("stream", "chunk", "fifo", "aosc", "spkcache")
STREAMING_CONFIG_HINTS = (
    "chunk_len",
    "chunk_right_context",
    "fifo_len",
    "spkcache_len",
    "spkcache_update_period",
)
STREAMING_CLASSES = ("SortformerEncLabelModel", "DiarizeSortformerDLModel")


def _package_version(name: str) -> str | None:
    try:
        return version(name)
    except PackageNotFoundError:
        return None


def _inspect_class(cls: type[Any]) -> dict[str, Any]:
    streaming_methods: list[dict[str, str]] = []
    for name, member in inspect.getmembers(cls, predicate=inspect.isfunction):
        lowered = name.lower()
        if not any(hint in lowered for hint in STREAMING_METHOD_HINTS):
            continue
        try:
            signature = str(inspect.signature(member))
        except (TypeError, ValueError):
            signature = "<unavailable>"
        source = inspect.getsourcefile(member)
        _, line = inspect.getsourcelines(member)
        streaming_methods.append(
            {
                "name": name,
                "signature": signature,
                "source_file": source.split("/")[-1] if source else "<unknown>",
                "source_line": line,
            }
        )
    config_fields: list[str] = []
    try:
        module = sys.modules[cls.__module__]
        for attribute in dir(module):
            lowered = attribute.lower()
            if any(hint in lowered for hint in STREAMING_CONFIG_HINTS):
                config_fields.append(attribute)
    except Exception:  # pragma: no cover - defensive: metadata probing only
        pass
    return {
        "class": cls.__name__,
        "module": cls.__module__,
        "streaming_methods": streaming_methods,
        "streaming_config_symbols": sorted(config_fields),
    }


def probe() -> dict[str, Any]:
    """Return the static streaming-diarization capability report."""
    nemo_version = _package_version("nemo-toolkit")
    report: dict[str, Any] = {
        "probe": "diarization_streaming",
        "nemo_version": nemo_version,
        "weights_loaded": False,
        "classes": [],
        "verdict": "unsupported",
        "reason": None,
    }
    if nemo_version is None:
        report["reason"] = "nemo-toolkit is not installed in this interpreter"
        return report
    try:
        import nemo.collections.asr.models as asr_models  # type: ignore[import-untyped]
    except Exception as exc:  # pragma: no cover - depends on local runtime
        report["reason"] = f"nemo.collections.asr.models failed to import: {type(exc).__name__}"
        return report

    for class_name in STREAMING_CLASSES:
        cls = getattr(asr_models, class_name, None)
        if cls is not None:
            report["classes"].append(_inspect_class(cls))

    verified = any(
        any(
            "forward_streaming_step" in method["name"]
            or "streaming" in method["name"]
            for method in entry["streaming_methods"]
        )
        for entry in report["classes"]
    )
    if verified:
        report["verdict"] = "candidate"
        report["reason"] = (
            "streaming methods found; verify signatures, CPU RTF and a real smoke "
            "before enabling the continuous capability"
        )
    else:
        report["reason"] = (
            "no streaming-shaped method found on the installed Sortformer classes"
        )
    return report


def main() -> int:
    print(json.dumps(probe(), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
