#!/usr/bin/env python3
"""Validate an external UTF-8 TXT corpus against the production importer.

No models, network, installed App, user database, or UI are used. The Swift
checker exercises eight lossless encoding/newline variants when representable.
Results contain statistics, source ranges and chapter titles, never book bodies.
By default, in CI, or without the complete external corpus, this checker skips.
Exit 1 means a corpus assertion failed; exit 2 means a verification error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

SOURCES = (
    "macos/SpeechRailApp/SpeechRailApp/AudiobookDomain.swift",
    "macos/SpeechRailApp/SpeechRailApp/AudiobookSourceIndex.swift",
    "macos/SpeechRailApp/SpeechRailApp/AudiobookChapterPlanner.swift",
    "macos/SpeechRailApp/SpeechRailApp/AudiobookTXTImporter.swift",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--run", action="store_true", help="explicitly enable local corpus regression"
    )
    parser.add_argument("--corpus", type=Path, default=os.getenv("SPEECHRAIL_AUDIOBOOK_CORPUS_DIR"))
    parser.add_argument("--output-directory", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    truthy = {"1", "true", "yes", "on"}
    if any(os.getenv(key, "").lower() in truthy for key in ("CI", "GITHUB_ACTIONS")):
        print(json.dumps({"status": "skipped", "reason": "ci"}))
        return 0
    if not args.run and os.getenv("SPEECHRAIL_RUN_AUDIOBOOK_CORPUS") != "1":
        print(json.dumps({"status": "skipped", "reason": "not_enabled"}))
        return 0
    if args.corpus is None or not args.corpus.is_dir():
        print(json.dumps({"status": "skipped", "reason": "corpus_unavailable"}))
        return 0
    corpus = args.corpus.resolve()
    if corpus.is_relative_to(repo):
        parser.error("novel corpus must remain outside the repository")
    manifest = repo / "scripts/audiobook_text_corpus_manifest.json"
    expected = json.loads(manifest.read_text())["files"]
    if any(not (corpus / item["name"]).is_file() for item in expected):
        print(json.dumps({"status": "skipped", "reason": "corpus_incomplete"}))
        return 0
    mismatched = [
        item["name"] for item in expected if sha256(corpus / item["name"]) != item["sha256"]
    ]
    if mismatched:
        parser.error(f"corpus fingerprint differs from regression manifest: {mismatched}")
    if args.output_directory:
        output = args.output_directory.resolve()
        if output.is_relative_to(repo):
            parser.error("verification artifacts must remain outside the repository")
        if output.exists() and (not output.is_dir() or any(output.iterdir())):
            parser.error("--output-directory must be new or empty")
        output.mkdir(parents=True, exist_ok=True)
    else:
        output = Path(tempfile.mkdtemp(prefix="speechrail-audiobook-corpus-"))

    harness = repo / "macos/SpeechRailApp/AudiobookTextCorpusTool/main.swift"
    input_paths = (
        *SOURCES,
        "macos/SpeechRailApp/Package.swift",
        str(harness.relative_to(repo)),
        str(manifest.relative_to(repo)),
        str(Path(__file__).resolve().relative_to(repo)),
    )
    inputs = {rel: sha256(repo / rel) for rel in input_paths}
    corpus_files = sorted(
        p
        for p in corpus.iterdir()
        if p.is_file() and (p.suffix.lower() in {".txt", ".epub"} or p.name == "sources.json")
    )
    corpus_hashes = {p.name: sha256(p) for p in corpus_files}
    metadata = {
        "started_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "corpus": str(corpus),
        "corpus_sha256": corpus_hashes,
        "source_sha256": inputs,
    }
    (output / "inputs.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    package = repo / "macos/SpeechRailApp"
    build_command = [
        "swift",
        "build",
        "--package-path",
        str(package),
        "--disable-automatic-resolution",
        "--skip-update",
        "--configuration",
        "release",
    ]
    with (output / "compile.log").open("w") as log:
        compiled = subprocess.run(
            [*build_command, "--product", "audiobook-text-corpus"],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    if compiled.returncode:
        print(f"Verification compilation failed; see {output / 'compile.log'}")
        return 2
    binary_path = subprocess.run(
        [*build_command, "--show-bin-path"], capture_output=True, text=True, check=True
    ).stdout.strip()
    executable = Path(binary_path) / "audiobook-text-corpus"
    with (
        (output / "results.jsonl").open("w") as results,
        (output / "stderr.log").open("w") as errors,
    ):
        completed = subprocess.run(
            [str(executable), str(corpus), str(manifest)],
            stdout=results,
            stderr=errors,
            check=False,
        )

    records = [
        json.loads(line)
        for line in (output / "results.jsonl").read_text().splitlines()
        if line.strip()
    ]
    summary = next((r for r in records if r.get("summary")), None)
    changed = [
        rel
        for rel, expected in inputs.items()
        if not (repo / rel).is_file() or sha256(repo / rel) != expected
    ]
    changed_corpus = [
        name
        for name, expected in corpus_hashes.items()
        if not (corpus / name).is_file() or sha256(corpus / name) != expected
    ]
    metadata.update(
        {
            "completed_at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "changed_sources": changed,
            "changed_corpus": changed_corpus,
            "checker_exit_code": completed.returncode,
            "summary": summary,
        }
    )
    (output / "inputs.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    for record in records:
        if record.get("variant") == "original":
            print(
                f"{record['file']}: {record['status']}; "
                f"paragraphs={record.get('paragraphs', '?')}, "
                f"chapters={record.get('chapters', '?')}, atoms={record.get('atoms', '?')}"
            )
        if record.get("status") == "failed":
            print(
                f"FAIL {record['file']} [{record['variant']}]: "
                f"{record.get('reason', 'assertion_failed')}"
            )
    print(json.dumps(summary, ensure_ascii=False))
    print(f"Artifacts: {output}")
    if not summary or changed or changed_corpus:
        print(
            f"Verification incomplete: changed_sources={changed}; changed_corpus={changed_corpus}"
        )
        return 2
    return 1 if completed.returncode or summary["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
