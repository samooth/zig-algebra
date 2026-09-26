#!/usr/bin/env python3
"""Fail if the committed assert ledger does not account for the tree.

Runs scripts/assert_scan.py over --root and compares the classified counts
against the committed ledger. Comparison is on `(file, kind, count)` -- never
on line numbers, which rot on the first edit above them.

The failure mode is deliberate: any occurrence the ledger does not know about,
and any `(file, kind, count)` that moved, is a hard error naming the assert.
That is what makes "there is no public debt" a checkable claim instead of a
convention someone has to remember.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default="libs")
    ap.add_argument("--ledger", default="docs/assert_ledger.json")
    ap.add_argument(
        "--allow-unclassified",
        action="store_true",
        help="do not fail on occurrences with no assigned kind",
    )
    args = ap.parse_args()

    ledger_path = Path(args.ledger)
    if not ledger_path.is_file():
        print(f"assert_verify: {ledger_path} not found", file=sys.stderr)
        return 2

    committed = json.loads(ledger_path.read_text())
    if committed.get("scanner_version") != 1:
        print(
            f"assert_verify: ledger was produced by scanner v"
            f"{committed.get('scanner_version')}, this is v1. Regenerate.",
            file=sys.stderr,
        )
        return 1

    scan_args = committed.get("scan_args", [])
    proc = subprocess.run(
        [sys.executable, str(HERE / "assert_scan.py"), "--root", args.root, "--json", *scan_args],
        capture_output=True,
        text=True,
        check=True,
    )
    fresh = json.loads(proc.stdout)

    problems: list[str] = []

    # 1. Per (file, kind) counts must match exactly.
    old_map = {(e["file"], e["kind"]): e["count"] for e in committed["counts_by_file_kind"]}
    new_map = {(e["file"], e["kind"]): e["count"] for e in fresh["counts_by_file_kind"]}

    for key in sorted(set(old_map) | set(new_map)):
        old = old_map.get(key)
        new = new_map.get(key)
        if old == new:
            continue
        file, kind = key
        if old is None:
            problems.append(f"NEW      {file}: {new} occurrence(s) of kind '{kind}' not in the ledger")
        elif new is None:
            problems.append(f"REMOVED  {file}: {kind} went from {old} to 0")
        else:
            problems.append(f"MOVED    {file}: {kind} went from {old} to {new}")

    # 2. Totals must match, so a compensating pair of changes cannot hide.
    for field in ("gross_occurrences", "prose_only_occurrences", "code_occurrences"):
        o, n = committed.get(field), fresh.get(field)
        if o != n:
            problems.append(f"TOTAL    {field}: ledger {o}, tree {n}")

    # 3. Nothing may sit unclassified unless explicitly tolerated.
    unclassified = fresh["counts_by_kind"].get("unclassified", 0)
    if unclassified and not args.allow_unclassified:
        problems.append(
            f"UNCLASSIFIED {unclassified} occurrence(s) have no kind. "
            f"Run the scanner and decide, or pass --allow-unclassified."
        )

    # 4. A new public precondition is the failure this whole thing exists for.
    public = fresh["counts_by_kind"].get("public", 0)
    committed_public = committed["counts_by_kind"].get("public", 0)
    if public > committed_public:
        problems.append(
            f"PUBLIC   {public - committed_public} new precondition(s) on a public entry "
            f"point. A public assert must become a typed error, not a ledger entry."
        )

    if problems:
        print("assert ledger out of sync:\n", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        print(
            "\nSee docs/assert-ledger.md. If the change is intended, regenerate the\n"
            "ledger (scripts/assert_scan.py --root libs --json > docs/assert_ledger.json)\n"
            "and commit the diff so the change is reviewable.",
            file=sys.stderr,
        )
        return 1

    counts = fresh["counts_by_kind"]
    print(
        f"assert ledger in sync: {fresh['gross_occurrences']} gross "
        f"({fresh['prose_only_occurrences']} prose) / {fresh['code_occurrences']} code "
        f"| public={counts.get('public', 0)} internal={counts.get('internal', 0)} "
        f"comptime={counts.get('comptime', 0)} fixture={counts.get('fixture', 0)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
