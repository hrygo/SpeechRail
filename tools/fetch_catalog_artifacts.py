#!/usr/bin/env python3
"""Fetch immutable metadata for NEW SpeechRail catalog artifacts (ModelScope)."""
from __future__ import annotations

import json
import sys
import urllib.request

# 与既有 5 制品一致: 剔除 .gitattributes 与根级 configuration.json; 保留 README.md 与 *.index.json
EXCLUDE_EXACT = {".gitattributes", "configuration.json"}
NEW = [
    ("asr-0.6b-q4", "mlx-community/Qwen3-ASR-0.6B-4bit", "qwen3_asr", "asr", (4, 64, "mlx")),
    (
        "aligner-q8",
        "mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
        "qwen3_forced_aligner",
        "aligner",
        (8, 64, "mlx"),
    ),
    (
        "aligner-bf16",
        "mlx-community/Qwen3-ForcedAligner-0.6B-bf16",
        "qwen3_forced_aligner",
        "aligner",
        (None, None, "none"),
    ),
]


def files(repo: str) -> list[dict]:
    url = (
        f"https://modelscope.cn/api/v1/models/{repo}/repo/files"
        "?Revision=master&Recursive=true"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
    with urllib.request.urlopen(req, timeout=40) as r:
        return (json.load(r).get("Data") or {}).get("Files") or []


def main() -> None:
    out = []
    for key, repo, family, variant, (bits, gs, fmt) in NEW:
        fs = files(repo)
        revs = sorted({f["Revision"] for f in fs})
        if len(revs) != 1:
            raise SystemExit(f"{repo}: expected one canonical revision, got {revs}")
        rev = revs[0]
        entries = [
            {"path": f["Path"], "size": f["Size"], "sha256": f["Sha256"]}
            for f in fs
            if f.get("Type") != "tree"
            and f["Path"] not in EXCLUDE_EXACT
            and f.get("Sha256")
        ]
        out.append(
            {
                "key": key,
                "model_id": repo,
                "revision": rev,
                "family": family,
                "variant": variant,
                "quantization": {"bits": bits, "group_size": gs, "format": fmt},
                "files": entries,
                "sources": [{"provider": "modelscope", "repository": repo, "revision": rev}],
            }
        )
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
