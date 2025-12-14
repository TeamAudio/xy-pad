#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


class ReaPackPublishError(RuntimeError):
    pass


# ReaPack is whitespace-tolerant; accept indentation and any whitespace around the Lua comment
# prefix. We parse the content after `--`.
PROVIDES_LINE_RE = re.compile(r"^\s*--\s*(?P<body>.*)$")

# Detect meta directives like `--@version` (optionally spaced/indented: ` -- @version`).
DIRECTIVE_LINE_RE = re.compile(r"^\s*--\s*@")
PROVIDES_START_RE = re.compile(r"^\s*--\s*@provides\b")


@dataclass(frozen=True)
class ProvidesEntry:
    source: str
    target: str
    has_url: bool


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").replace("\r\n", "\n")


def _run(command: list[str], *, cwd: Path) -> None:
    proc = subprocess.run(command, cwd=str(cwd), text=True, capture_output=True)
    if proc.returncode != 0:
        raise ReaPackPublishError(
            f"Command failed ({proc.returncode}): {' '.join(command)}\n"
            f"stdout:\n{proc.stdout}\n"
            f"stderr:\n{proc.stderr}"
        )


def _parse_provides(reapack_file: Path) -> list[ProvidesEntry]:
    """Parse the `--@provides` block from a ReaPack metapackage file.

    Supported line forms within the provides block:
    - `[opts] path` or `path`: provides a single file path (options are ignored here)
    - `source > target`: provides a mapping
    - URLs are detected (http/https) and are not currently handled by sync automation

    Parsing stops when the next `--@...` directive is encountered.
    """
    text = _read_text(reapack_file)
    lines = text.split("\n")

    in_provides = False
    entries: list[ProvidesEntry] = []

    for raw in lines:
        if PROVIDES_START_RE.match(raw):
            in_provides = True
            continue

        if not in_provides:
            continue

        # Stop when we hit the next directive tag.
        if DIRECTIVE_LINE_RE.match(raw):
            break

        match = PROVIDES_LINE_RE.match(raw)
        if not match:
            continue

        body = match.group("body").strip()
        if not body:
            continue

        # Expected: "[opts] path" or "path" or "source > target" possibly with URL patterns.
        if body.startswith("["):
            end = body.find("]")
            if end != -1:
                body = body[end + 1 :].strip()

        # Drop any leading whitespace after the comment prefix.
        body = body.strip()

        # Split mapping.
        if ">" in body:
            left, right = body.split(">", 1)
            source = left.strip().split()[0]
            target = right.strip().split()[0]
        else:
            parts = body.split()
            if not parts:
                continue
            source = parts[0]
            target = parts[0]

        has_url = "http://" in body or "https://" in body
        entries.append(ProvidesEntry(source=source, target=target, has_url=has_url))

    return entries


def _copy_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def cmd_sync(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    reascripts_root = Path(args.reascripts_root).resolve()

    reapack_file = repo_root / args.reapack_file
    if not reapack_file.exists():
        raise ReaPackPublishError(f"ReaPack file not found: {reapack_file}")

    fx_dir = reascripts_root / "FX"
    if not fx_dir.exists():
        raise ReaPackPublishError(f"Expected reascripts FX directory not found: {fx_dir}")

    # Always copy the ReaPack metapackage file itself.
    _copy_file(reapack_file, fx_dir / "XY_Pad-ReaPack.lua")

    entries = _parse_provides(reapack_file)
    copied: list[str] = []

    for entry in entries:
        if entry.source == "." or entry.target == ".":
            continue
        if entry.has_url:
            # Not currently supported in automation (would require downloading/building artifacts).
            continue

        if not entry.source.startswith("XY_Pad/"):
            # We only support shipping files under XY_Pad/ in this repo.
            continue

        src_path = repo_root / entry.source
        if not src_path.exists():
            raise ReaPackPublishError(f"Provides file missing: {entry.source} (expected at {src_path})")

        dst_rel = entry.target
        if dst_rel.endswith("/"):
            dst_rel = dst_rel + Path(entry.source).name

        dst_path = fx_dir / dst_rel
        _copy_file(src_path, dst_path)
        copied.append(dst_rel)

    if args.run_index:
        # Update index.xml deterministically, but do not let reapack-index create its own commit.
        _run(["reapack-index", "--no-commit"], cwd=reascripts_root)

    print(f"copied_metapackage=FX/XY_Pad-ReaPack.lua")
    print(f"copied_files={len(copied)}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Sync XY Pad ReaPack package into TeamAudio/reascripts")
    parser.add_argument(
        "--repo-root",
        default=str(Path(__file__).resolve().parents[1]),
        help="xy-pad repo root (default: auto)",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    sync = sub.add_parser("sync", help="Copy files into reascripts and optionally run reapack-index")
    sync.add_argument("--reascripts-root", required=True, help="Path to checked out TeamAudio/reascripts")
    sync.add_argument("--reapack-file", default="XY_Pad-ReaPack.lua")
    sync.add_argument("--run-index", action="store_true", help="Run `reapack-index --no-commit`")
    sync.set_defaults(func=cmd_sync)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except ReaPackPublishError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
