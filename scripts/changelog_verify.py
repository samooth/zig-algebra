#!/usr/bin/env python3
"""Fail if CHANGELOG.md's release headers are not unique, ordered, or non-empty.

This is the checker that AUDIT.md row 14 says does not exist. It was described in
prose in two repositories and implemented in neither, which is the ninth form of
this week's failures: a fact travelling without its subject. The rule itself is
the right one, and it earns its keep the moment it is written — on the day it was
added it found a release entry sitting 104 lines out of order in a published
changelog.

Three rules:

  1. No two release sections may carry the same version. The original roadmap
     had a duplicated `## [0.5.1]` section that survived a commit before anybody
     noticed by reading.
  2. Release sections must be in strictly descending version order, with
     `[Unreleased]` first if present. A changelog is read by someone deciding
     whether to bump, and an entry filed under the wrong version is an entry they
     will not find.
  3. Every section must have a non-empty body. A heading with nothing under it
     promises a release note that does not exist.

Exits 0 when the changelog holds, 1 with every violation listed when it does not.
It never exits 0 without having read the file and compared the order.
"""

import argparse
import re
import sys
from pathlib import Path
from typing import List, Optional, Tuple

RELEASE = re.compile(r"^## \[?v?(?P<ver>\d+\.\d+\.\d+)\]?(?P<rest>.*)$")
UNRELEASED = re.compile(r"^## \[Unreleased\]")


def ver_tuple(v: str) -> Tuple[int, int, int]:
    return tuple(int(x) for x in v.split("."))  # type: ignore[return-value]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--changelog", default="CHANGELOG.md")
    args = ap.parse_args()

    path = Path(args.changelog)
    if not path.exists():
        print(f"changelog_verify: {path} not found", file=sys.stderr)
        return 1
    lines = path.read_text(encoding="utf-8").splitlines()

    # A heading inside a fenced block is an example, not a section. The reference
    # implementation of this rule in the other repository has a dedicated counter
    # for exactly this, and it exists because a `## [` line inside a fenced example
    # reads as a section to anything that only looks at line starts. This tree has
    # no such line today, so the rule does not fire — but the difference between the
    # two implementations is real, and it is this one that is behind.
    sections: List[Tuple[int, str, Optional[str]]] = []  # (lineno, titulo, version)
    in_fence = False
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if UNRELEASED.match(line):
            sections.append((i, line, None))
            continue
        m = RELEASE.match(line)
        if m:
            sections.append((i, line, m.group("ver")))

    failures: list[str] = []

    if not sections:
        print(
            f"{path}: no release sections found. The changelog's shape changed and the "
            "gate is no longer looking at anything. A gate that cannot see its subject "
            "passes for the same reason a spreadsheet does.",
            file=sys.stderr,
        )
        return 1

    # Rule 1, uniqueness.
    seen: dict[str, int] = {}
    for lineno, title, ver in sections:
        if ver is None:
            continue
        if ver in seen:
            failures.append(
                f"{path}:{lineno} v{ver} appears twice, first at line {seen[ver]}. Two "
                "sections for one release means a reader looking for one of them finds "
                "the other."
            )
        else:
            seen[ver] = lineno

    # Rule 2, strictly descending, with Unreleased ahead of every release.
    prev_ver: Optional[Tuple[int, int, int]] = None
    prev_line = 0
    prev_label = ""
    for lineno, title, ver in sections:
        if ver is None:
            # [Unreleased] must come first; a release above it is out of order.
            if prev_ver is not None:
                failures.append(
                    f"{path}:{lineno} [Unreleased] appears after {prev_label} at line "
                    f"{prev_line}. Unreleased is the top of the file by definition."
                )
            continue
        cur = ver_tuple(ver)
        if prev_ver is not None and cur >= prev_ver:
            failures.append(
                f"{path}:{lineno} v{ver} follows {prev_label} at line {prev_line}, so the "
                f"releases are not in descending order — v{ver} belongs above it."
            )
        prev_ver, prev_line, prev_label = cur, lineno, f"v{ver}"

    # Rule 3, every section has a body.
    for k, (lineno, title, _ver) in enumerate(sections):
        end = sections[k + 1][0] if k + 1 < len(sections) else len(lines) + 1
        if not any(x.strip() for x in lines[lineno:end - 1]):
            failures.append(
                f"{path}:{lineno} {title.strip()!r} has no body. A heading with nothing "
                "under it promises a release note that does not exist."
            )

    releases = sum(1 for _, _, v in sections if v is not None)
    if failures:
        print("changelog does not hold up:\n", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        print(
            f"\n{len(failures)} violation(s) across {len(sections)} section(s).",
            file=sys.stderr,
        )
        return 1

    print(
        f"changelog in sync: {releases} release section(s), unique, descending, "
        f"all with a body ({len(sections) - releases} unreleased)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
