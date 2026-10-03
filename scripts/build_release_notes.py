#!/usr/bin/env python3
"""Compose the GitHub Release body from the repository CHANGELOG.

The CHANGELOG is the curated, hand-reviewed record of what changed in a
release, so it is the body of the release notes rather than a generated
commit list. This script extracts the section for the released version,
appends the installation instructions, and fails closed when the section is
missing or empty, so a tag can never ship with release notes that silently
omit the changelog.

The version and repository placeholders in the installation instructions are
substituted here. They used to live in a single-quoted shell string in the
release workflow, which shipped a literal ``speechrail-<version>-*.whl`` to
every published release.

Only the standard library is used: the publish job runs this without
provisioning uv, and repository scripts must stay portable.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

_SECTION_RE = re.compile(r"^## \[(?P<version>[^\]]+)\](?P<suffix>.*)$")

# Implicit concatenation keeps every source line under the 100-column limit
# without inserting a newline into the rendered CJK prose, which would add a
# space at the soft break. The emitted text is byte-identical to the workflow
# string this replaced.
_INSTALLATION_NOTES = (
    "## 发布文件说明\n"
    "\n"
    "- `speechrail-{version}-*.whl` — Python 服务包"
    "（CLI、FastAPI 应用、内置 CoreML 分人 worker），"
    "自带 `speechrail install` 安装入口："
    "不需要 clone 仓库即可安装服务并准备模型。\n"
    "- `SpeechRail-{version}-macOS-arm64.dmg` — macOS 控制面 App，最低 macOS 26.0。"
    "DMG 文件本身未签名、未公证，包内 App 带 ad hoc 本地签名"
    "（内嵌 `com.speechrail.desktop.local-control.xpc` 的 peer 校验依赖这个签名，"
    "缺了它 App 会显示「控制通道不可用」）。"
    "不加载模型、不启动服务、不监听 8201。\n"
    "- `SHA256SUMS` — 上述两个制品的 SHA-256 校验值。\n"
    "\n"
    "安装服务（在下载目录执行；`speechrail-*.whl` 需要是该目录里唯一的 wheel）：\n"
    "\n"
    "```bash\n"
    "cd ~/Downloads\n"
    "shasum -a 256 -c SHA256SUMS\n"
    "uvx --python 3.14.7 --from ./speechrail-*.whl speechrail install "
    "--asr-spec quality --tts-spec quality --yes --enable\n"
    "```\n"
    "\n"
    "升级用同一条命令，但必须先停掉旧实例：先用已安装 runtime 的\n"
    '`speechrail service stop --app-home "$HOME/Library/Application Support/SpeechRail"`，'
    "再执行上面的安装；\n"
    "省略 `--asr-spec`/`--tts-spec` 会沿用当前规格。\n"
    "\n"
    "服务与 App 是两个独立发布单元：先安装服务，再安装 App；"
    "只装 App 会显示「无法连接本机服务」。"
    "DMG 未签名也未公证（包内 App 只有 ad hoc 本地签名），"
    "首次打开时 macOS 可能要求在「隐私与安全性」中点击「仍要打开」。\n"
    "\n"
    "安装顺序、wheel 的用途与限制、首次验证和常见问题见安装手册：\n"
    "https://github.com/{repository}/blob/main/docs/users/installing-speechrail.md"
)


@dataclass(frozen=True, slots=True)
class _Section:
    version: str
    lines: tuple[str, ...]


def _parse_sections(changelog: str) -> list[_Section]:
    """Split the changelog into its ``## [version]`` sections, newest first."""

    sections: list[_Section] = []
    current_version: str | None = None
    current_lines: list[str] = []
    for line in changelog.splitlines():
        match = _SECTION_RE.match(line)
        if match is not None:
            if current_version is not None:
                sections.append(_Section(current_version, tuple(current_lines)))
            current_version = match.group("version")
            current_lines = [line]
        elif current_version is not None:
            current_lines.append(line)
    if current_version is not None:
        sections.append(_Section(current_version, tuple(current_lines)))
    return sections


def _release_body(sections: list[_Section], version: str) -> str:
    """Return the changelog body for ``version`` without its heading."""

    for section in sections:
        if section.version != version:
            continue
        body = "\n".join(section.lines[1:]).strip("\n")
        if not body.strip():
            raise ValueError(f"changelog section for {version} has no entries")
        return body
    raise ValueError(f"changelog has no '## [{version}]' section")


def _previous_release(
    sections: list[_Section], version: str, published_tags: set[str] | None = None
) -> str | None:
    """Return the newest released version older than ``version``, if any."""

    seen_current = False
    for section in sections:
        if section.version == version:
            seen_current = True
            continue
        if not seen_current or section.version == "Unreleased":
            continue
        if published_tags is not None and f"v{section.version}" not in published_tags:
            continue
        return section.version
    return None


def render_release_notes(
    *,
    version: str,
    changelog: str,
    repository: str | None = None,
    published_tags: set[str] | None = None,
) -> str:
    """Render the full release body for ``version``."""

    sections = _parse_sections(changelog)
    parts = [f"## {version} 变更说明", "", _release_body(sections, version)]
    previous = _previous_release(sections, version, published_tags)
    if published_tags is not None:
        seen_current = False
        for section in sections:
            if section.version == version:
                seen_current = True
                continue
            if not seen_current or section.version == "Unreleased":
                continue
            if section.version == previous:
                break
            parts.extend(["", *section.lines])

    notes = _INSTALLATION_NOTES.replace("{version}", version)
    if repository:
        notes = notes.replace("{repository}", repository)
    else:
        notes = notes.replace(
            "https://github.com/{repository}/blob/main/docs/users/"
            "installing-speechrail.md",
            "docs/users/installing-speechrail.md",
        )
    parts.extend(["", notes])

    if repository and previous:
        parts.extend(
            [
                "",
                f"**Full Changelog**: https://github.com/{repository}/compare/"
                f"v{previous}...v{version}",
            ]
        )
    return "\n".join(parts).rstrip() + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--published-tags",
        type=Path,
        default=None,
        help="file of published release tags, one per line; includes intervening changelog entries",
    )
    parser.add_argument(
        "--version",
        required=True,
        help="released version without the leading v, for example 3.3.2",
    )
    parser.add_argument(
        "--changelog",
        type=Path,
        default=ROOT / "CHANGELOG.md",
        help="changelog to read the release section from",
    )
    parser.add_argument(
        "--repository",
        default=None,
        help="OWNER/REPO used for the compare link and manual URL",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="file to write; defaults to standard output",
    )
    args = parser.parse_args(argv)

    try:
        changelog = args.changelog.read_text(encoding="utf-8")
    except OSError as error:
        print(f"release notes generation FAILED: {error}", file=sys.stderr)
        return 1

    try:
        body = render_release_notes(
            version=args.version,
            changelog=changelog,
            repository=args.repository,
            published_tags=(
                set(args.published_tags.read_text(encoding="utf-8").splitlines())
                if args.published_tags is not None
                else None
            ),
        )
    except (ValueError, OSError) as error:
        print(f"release notes generation FAILED: {error}", file=sys.stderr)
        return 1

    if args.output is None:
        sys.stdout.write(body)
        return 0
    try:
        args.output.write_text(body, encoding="utf-8")
    except OSError as error:
        print(f"release notes generation FAILED: {error}", file=sys.stderr)
        return 1
    print(f"release notes written: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
