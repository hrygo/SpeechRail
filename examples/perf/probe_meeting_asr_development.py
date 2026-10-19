"""Locked ASR development execution and offline result comparison.

evaluate-development requires model-run authorization; compare-development is offline.

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
    comparison = commands.add_parser("compare-development")
    comparison.add_argument("--comparison-lock", required=True, type=Path)
    comparison.add_argument("--output-directory", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "evaluate-development":
            from meeting_asr_execution import execute_asr_development

            operation = execute_asr_development(
                evaluation_lock=args.asr_lock,
                output_directory=args.output_directory,
            )
        else:
            from meeting_asr_comparison import execute_asr_comparison

            operation = execute_asr_comparison(
                comparison_lock=args.comparison_lock,
                output_directory=args.output_directory,
            )
        result = asyncio.run(operation)
        serialized = json.dumps(result, sort_keys=True, allow_nan=False)
    except Exception:
        parser.error(
            "locked ASR development execution failed"
            if args.command == "evaluate-development"
            else "locked ASR comparison failed"
        )
    print(serialized)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
