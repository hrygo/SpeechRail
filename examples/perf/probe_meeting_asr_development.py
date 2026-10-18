"""Explicit locked ASR development execution; requires model-run authorization.

No model or environment discovery, downloads, service operations or holdout.
All evaluation choices belong in the independent control lock, not CLI flags.
"""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    evaluation = commands.add_parser("evaluate-development")
    evaluation.add_argument("--asr-lock", required=True, type=Path)
    evaluation.add_argument("--output-directory", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        from meeting_asr_execution import execute_asr_development

        result = asyncio.run(
            execute_asr_development(
                evaluation_lock=args.asr_lock,
                output_directory=args.output_directory,
            )
        )
        serialized = json.dumps(result, sort_keys=True, allow_nan=False)
    except Exception:
        parser.error("locked ASR development execution failed")
    print(serialized)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
