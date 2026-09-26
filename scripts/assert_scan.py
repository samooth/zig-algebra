#!/usr/bin/env python3
"""Scan a tree for std.debug.assert occurrences and classify them.

Implements the convention defined in docs/assert-ledger.md. Standard library
only: the gate that consumes this must not need a build step or a toolchain
that a downstream repository does not already have.

    scripts/assert_scan.py --root libs                # human summary
    scripts/assert_scan.py --root libs --json         # ledger on stdout

Classification:

    fixture    lexically inside a `test` block
    comptime   inside a `comptime {}` block, or on a `comptime`-prefixed line
    unclassified  anything else

`public` vs `internal` cannot be decided lexically -- a `pub fn` may still be
reachable only through another `pub fn`, and a non-`pub` helper may be a real
precondition. Those two are supplied by the caller through --override, and any
occurrence left unclassified is what the gate reports.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

SCANNER_VERSION = 1
SCHEMA = 1

ASSERT_RE = re.compile(r"std\.debug\.assert")
TEST_RE = re.compile(r"^\s*test\b")
# `test {`, `test "name" {`, `test "name" { ... }` all open a test block.
TEST_OPEN_RE = re.compile(r'^\s*test\b[^{]*\{\s*$')
FUNC_OPEN_RE = re.compile(r"^\s*(?:pub\s+)?(?:export\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)")
COMPTIME_BLOCK_RE = re.compile(r"^\s*comptime\s*\{")
COMPTIME_LINE_RE = re.compile(r"^\s*comptime\s+.*std\.debug\.assert")
# A `blk:` whose result is comptime-evaluated: `const x = blk: {`, or
# `const x: T = blk: {`, or the explicit `const x = comptime blk: {`.
COMPTIME_BLK_RE = re.compile(
    r"^\s*const\s+[A-Za-z_][A-Za-z0-9_]*\s*(?::\s*[\w.]+\s*)?=\s*(?:comptime\s+)?blk:\s*\{\s*$"
)


def strip_line_comment(line: str) -> str:
    """Drop everything from the first `//`.

    Zig has no nested block comments, so a line comment starts at the first
    `//` that is not inside a string literal. Occurrences after it are prose,
    not code -- this is the distinction that makes the count meaningful.
    """
    out = []
    in_string = False
    escaped = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            out.append(ch)
        else:
            if ch == '"':
                in_string = True
                out.append(ch)
            elif ch == "/" and i + 1 < len(line) and line[i + 1] == "/":
                break
            else:
                out.append(ch)
        i += 1
    return "".join(out)


class Scanner:
    def __init__(self) -> None:
        self.in_test = False
        self.test_depth = 0
        self.in_comptime = False
        self.comptime_depth = 0
        self.depth = 0
        self.fn = "<module>"
        self.fn_depth = 0

    def classify(self, path: Path, lineno: int, raw: str) -> dict | None:
        gross = len(ASSERT_RE.findall(raw))
        if gross == 0:
            return None
        code = strip_line_comment(raw)
        occurrences = len(ASSERT_RE.findall(code))
        if occurrences == 0:
            # Every occurrence on this line is prose. These are the
            # explanations 0.5.0 wrote about each replaced precondition.
            return {
                "file": str(path),
                "line": lineno,
                "fn": self.fn,
                "gross": gross,
                "occurrences": 0,
                "kind": None,
                "prose_only": True,
                "text": raw.strip()[:120],
            }

        kind = None
        if self.in_test:
            kind = "fixture"
        elif self.in_comptime or COMPTIME_LINE_RE.match(raw):
            kind = "comptime"

        return {
            "file": str(path),
            "line": lineno,
            "fn": self.fn,
            "gross": gross,
            "occurrences": occurrences,
            "kind": kind,
            "prose_only": False,
            "text": raw.strip()[:120],
        }

    def feed(self, path: Path) -> list[dict]:
        hits = []
        self.in_test = self.in_comptime = False
        self.test_depth = self.comptime_depth = 0
        self.depth = 0
        self.fn = "<module>"
        self.fn_depth = 0

        for lineno, raw in enumerate(path.read_text(errors="replace").split("\n"), 1):
            hit = self.classify(path, lineno, raw)
            if hit:
                hits.append(hit)

            stripped = raw.strip()
            opened_test = bool(TEST_OPEN_RE.match(raw))
            if TEST_RE.match(raw) and not opened_test and stripped.endswith(";"):
                # `test foo() void;` style reference, not a block.
                pass
            if opened_test:
                self.in_test = True
                self.test_depth = self.depth

            if COMPTIME_BLOCK_RE.match(raw):
                self.in_comptime = True
                self.comptime_depth = self.depth
            elif COMPTIME_BLK_RE.match(raw):
                self.in_comptime = True
                self.comptime_depth = self.depth

            m = FUNC_OPEN_RE.match(raw)
            if m and "{" in raw:
                self.fn = m.group(1)
                self.fn_depth = self.depth

            # Track brace depth on code only, so a `}` inside a string or a
            # comment does not shift the nesting we classify against.
            code = strip_line_comment(raw)
            for ch in code:
                if ch == "{":
                    self.depth += 1
                elif ch == "}":
                    self.depth -= 1
                    if self.in_test and self.depth <= self.test_depth:
                        self.in_test = False
                    if self.in_comptime and self.depth <= self.comptime_depth:
                        self.in_comptime = False
                    if self.fn != "<module>" and self.depth <= self.fn_depth:
                        self.fn = "<module>"
        return hits


def walk(root: Path, src_only: bool) -> list[Path]:
    out = []
    for p in sorted(root.rglob("*.zig")):
        if not p.is_file():
            continue
        if src_only and f"{os.sep}src{os.sep}" not in str(p):
            continue
        out.append(p)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default="libs", help="tree to scan (default: libs)")
    ap.add_argument(
        "--src-only",
        action="store_true",
        help="scan only libs/*/src, excluding the separate tests/ roots",
    )
    ap.add_argument("--json", action="store_true", help="emit the ledger on stdout")
    ap.add_argument(
        "--overrides",
        default="docs/assert_overrides.txt",
        help="file listing <path> <kind> <reason> lines (default: docs/assert_overrides.txt)",
    )
    ap.add_argument(
        "--override",
        default="",
        help="extra file:kind[,file:kind...] applied on top of the overrides file",
    )
    args = ap.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"assert_scan: {root} is not a directory", file=sys.stderr)
        return 2

    overrides: dict[str, str] = {}
    ov_path = Path(args.overrides)
    if ov_path.is_file():
        for lineno, line in enumerate(ov_path.read_text().split("\n"), 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            parts = s.split(None, 2)
            if len(parts) < 2:
                print(f"assert_scan: {ov_path}:{lineno}: want '<path> <kind> <reason>'", file=sys.stderr)
                return 2
            overrides[parts[0]] = parts[1]
    for item in filter(None, (s.strip() for s in args.override.split(","))):
        if ":" not in item:
            print(f"assert_scan: bad --override {item!r}, want file:kind", file=sys.stderr)
            return 2
        f, k = item.rsplit(":", 1)
        overrides[f] = k

    scanner = Scanner()
    all_hits: list[dict] = []
    for path in walk(root, args.src_only):
        for hit in scanner.feed(path):
            rel = str(path)
            if hit["kind"] is None:
                hit["kind"] = overrides.get(rel)
            all_hits.append(hit)

    by_kind: dict[str, int] = {}
    gross_total = 0
    prose_total = 0
    for hit in all_hits:
        gross_total += hit["gross"]
        if hit["prose_only"]:
            prose_total += hit["gross"]
            continue
        k = hit["kind"] or "unclassified"
        by_kind[k] = by_kind.get(k, 0) + hit["occurrences"]

    file_kind: dict[tuple[str, str], int] = {}
    for hit in all_hits:
        if hit["prose_only"]:
            continue
        key = (hit["file"], hit["kind"] or "unclassified")
        file_kind[key] = file_kind.get(key, 0) + hit["occurrences"]

    if args.json:
        ledger = {
            "schema": SCHEMA,
            "scanner": "scripts/assert_scan.py",
            "scanner_version": SCANNER_VERSION,
            "root": str(root),
            "scan_args": ["--src-only"] if args.src_only else [],
            "source_commit": "REPLACE_WITH_ORIGIN_COMMIT",
            "gross_occurrences": gross_total,
            "prose_only_occurrences": prose_total,
            "code_occurrences": sum(by_kind.values()),
            "counts_by_kind": dict(sorted(by_kind.items())),
            "counts_by_file_kind": [
                {"file": f, "kind": k, "count": c}
                for (f, k), c in sorted(file_kind.items())
            ],
            "entries": [
                {
                    "file": h["file"],
                    "fn": h["fn"],
                    "kind": h["kind"] or "unclassified",
                    "reason": "REPLACE",
                }
                for h in all_hits
                if not h["prose_only"]
            ],
        }
        json.dump(ledger, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    print(f"assert ledger for {root}/  (scanner v{SCANNER_VERSION})")
    print()
    print(f"{'file':44}  {'fixture':>7} {'comptime':>8} {'internal':>8} {'public':>6} {'unclass':>7}")
    for path in walk(root, args.src_only):
        rel = str(path)
        buckets: dict[str, int] = {}
        for hit in all_hits:
            if hit["file"] == rel and not hit["prose_only"]:
                k = hit["kind"] or "unclassified"
                buckets[k] = buckets.get(k, 0) + hit["occurrences"]
        if not buckets:
            continue
        print(
            f"{rel:44}  {buckets.get('fixture',0):7} {buckets.get('comptime',0):8} "
            f"{buckets.get('internal',0):8} {buckets.get('public',0):6} {buckets.get('unclassified',0):7}"
        )
    print()
    code_total = sum(by_kind.values())
    print(f"gross occurrences (incl. prose)  {gross_total}")
    print(f"  of which prose-only             {prose_total}")
    print(f"code occurrences                  {code_total}")
    print()
    print("code occurrences by kind:")
    for k, v in sorted(by_kind.items()):
        print(f"  {k:14} {v}")
    if "unclassified" in by_kind:
        print()
        print("unclassified occurrences still need a kind:")
        for hit in all_hits:
            if hit["prose_only"] or hit["kind"] is not None:
                continue
            print(f"  {hit['file']}:{hit['line']}  fn={hit['fn']}  | {hit['text']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
