#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path


SEMVER_RE = re.compile(r"^(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)$")


class ReleaseError(RuntimeError):
    pass


@dataclass(frozen=True)
class SemVer:
    major: int
    minor: int
    patch: int

    @staticmethod
    def parse(value: str) -> "SemVer":
        value = value.strip().lstrip("v")
        match = SEMVER_RE.match(value)
        if not match:
            raise ReleaseError(f"Invalid version (expected x.y.z): {value!r}")
        return SemVer(
            major=int(match.group("major")),
            minor=int(match.group("minor")),
            patch=int(match.group("patch")),
        )

    def bump(self, level: str) -> "SemVer":
        if level == "major":
            return SemVer(self.major + 1, 0, 0)
        if level == "minor":
            return SemVer(self.major, self.minor + 1, 0)
        if level == "patch":
            return SemVer(self.major, self.minor, self.patch + 1)
        raise ReleaseError(f"Unknown bump level: {level}")

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


BUMP_PRIORITY = {"patch": 0, "minor": 1, "major": 2}


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").replace("\r\n", "\n")


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")


def _discover_pending(pending_dir: Path) -> list[tuple[str, Path]]:
    if not pending_dir.exists():
        return []

    pending_files: list[tuple[str, Path]] = []
    for file_path in sorted(pending_dir.glob("*.md")):
        lower_name = file_path.name.lower()
        bump_level: str | None = None
        for level in ("patch", "minor", "major"):
            if lower_name.endswith(f".{level}.md"):
                bump_level = level
                break
        if bump_level is None:
            continue
        pending_files.append((bump_level, file_path))
    return pending_files


def _select_bump_level(pending: list[tuple[str, Path]]) -> str:
    if not pending:
        raise ReleaseError("No pending release notes found.")
    return max((level for level, _ in pending), key=lambda lvl: BUMP_PRIORITY[lvl])


def _compile_release_notes(pending: list[tuple[str, Path]]) -> str:
    # Stable ordering: by filename.
    sections: list[str] = []
    for _, file_path in sorted(pending, key=lambda it: it[1].name):
        body = _read_text(file_path).strip()
        if not body:
            continue
        sections.append(body)
    return "\n\n---\n\n".join(sections).rstrip() + "\n"


def _stamp_reapack_file(
    *,
    template_path: Path,
    out_path: Path,
    version: SemVer,
    release_notes_md: str,
) -> None:
    template = _read_text(template_path)

    # Replace the @version line.
    out = re.sub(r"(?m)^--@version\s*$", f"--@version {version}", template)

    # Insert changelog lines immediately after --@changelog.
    if "--@changelog" not in out:
        raise ReleaseError(f"Template missing --@changelog: {template_path}")

    changelog_lines: list[str] = []
    for line in release_notes_md.rstrip("\n").split("\n"):
        if line.strip() == "":
            changelog_lines.append("--  ")
        else:
            changelog_lines.append(f"--  {line}")

    insertion = "\n".join(changelog_lines) + "\n"
    out = out.replace("--@changelog\n", f"--@changelog\n{insertion}", 1)

    _write_text(out_path, out)


def cmd_prepare(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()

    current_version_path = repo_root / args.current_version_file
    pending_dir = repo_root / args.pending_dir
    changes_out_dir = repo_root / args.changes_out_dir
    reapack_template = repo_root / args.reapack_template
    reapack_out = repo_root / args.reapack_out

    current_version_raw = _read_text(current_version_path).strip()
    current = SemVer.parse(current_version_raw)

    pending = _discover_pending(pending_dir)
    bump_level = _select_bump_level(pending)
    new_version = current.bump(bump_level)

    notes = _compile_release_notes(pending)
    if not notes.strip():
        raise ReleaseError("Pending notes were found but compiled release notes are empty.")

    changes_file = changes_out_dir / f"changes-{new_version}.md"

    if not args.dry_run:
        _write_text(current_version_path, f"{new_version}\n")
        _write_text(changes_file, notes)
        _stamp_reapack_file(
            template_path=reapack_template,
            out_path=reapack_out,
            version=new_version,
            release_notes_md=notes,
        )

        # Remove pending files (they are now part of changes-<version>.md)
        for _, file_path in pending:
            try:
                file_path.unlink()
            except FileNotFoundError:
                pass

    print(f"bump_level={bump_level}")
    print(f"version={new_version}")
    print(f"changes_file={changes_file.relative_to(repo_root)}")

    if args.github_output:
        out_path = Path(args.github_output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("a", encoding="utf-8") as f:
            f.write(f"bump_level={bump_level}\n")
            f.write(f"version={new_version}\n")
            f.write(f"changes_file={changes_file.relative_to(repo_root)}\n")

    return 0


def cmd_cut(_: argparse.Namespace) -> int:
    # Placeholder for future shared-toolkit extraction.
    # Current implementation keeps cut logic in GitHub workflow.
    print("cut is implemented in GitHub Actions workflow")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="XY Pad release automation helper")
    parser.add_argument(
        "--repo-root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Repository root directory (default: auto)",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    prepare = sub.add_parser("prepare", help="Prepare a release (bump version, compile notes, stamp ReaPack file)")
    prepare.add_argument("--dry-run", action="store_true", help="Do not write any files")
    prepare.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT", ""),
        help="Path to GitHub Actions output file (defaults to $GITHUB_OUTPUT)",
    )
    prepare.add_argument("--current-version-file", default="XY_Pad/releases/current.txt")
    prepare.add_argument("--pending-dir", default="XY_Pad/releases/pending")
    prepare.add_argument("--changes-out-dir", default="XY_Pad/releases")
    prepare.add_argument("--reapack-template", default="XY_Pad/releases/reapack-base")
    prepare.add_argument("--reapack-out", default="XY_Pad-ReaPack.lua")
    prepare.set_defaults(func=cmd_prepare)

    cut = sub.add_parser("cut", help="Cut/tag release (currently workflow-owned)")
    cut.set_defaults(func=cmd_cut)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except ReleaseError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
