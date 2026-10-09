#!/usr/bin/env python3
"""Check the cryptographic entry-point ledger against the tree.

Every `pub fn` in `libs/*/src/*.zig` whose name starts with a cryptographic
verb -- `pairing, millerLoop, finalExp, commit, prove, verify, open, sign,
multiScalarMul, msm, hashTo, mapToCurve, derive, challenge` -- is either pinned
to a vector from an implementation independent of this tree, or carries a
recorded reason it does not need one. The list of entry points is *derived*
from `git ls-files`, never written by hand, so a new entry point fails the gate
the day it appears and a renamed one fails the day it moves.

Scope note, and it is a finding rather than a footnote: the row this implements
recorded its derivation rule as a name-prefix match and measured 37 entry
points. 37 is the count of TOP-LEVEL `pub fn` only; the same rule applied to
methods inside structs yields 30 more, 67 in total. The excluded set is not
noise -- it contains `Ipa.verify`, the stub this tree lists as a known gap.
The gate therefore covers both shapes and says so.

Three ways it fails, each of which must be seen failing before a green run
means anything:
  empty entry      a `pub fn` in the tree with no row in the ledger
  absent name      a row naming an entry point that no longer exists
  blank provenance a row with neither a vector nor a reason
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

VERBS = [
    "pairing", "millerLoop", "finalExp", "commit", "prove", "verify", "open",
    "sign", "multiScalarMul", "msm", "hashTo", "mapToCurve", "derive", "challenge",
]

PUB_FN = re.compile(r"^(pub fn (\w+)|(\s+)pub fn (\w+))")


def derive(root: Path) -> dict[str, list[str]]:
    """file -> [name, ...] for every entry point the rule selects."""
    tracked = subprocess.run(
        ["git", "ls-files", "libs/*/src/*.zig"], capture_output=True, text=True, check=True
    ).stdout.split()
    out: dict[str, list[str]] = {}
    for rel in tracked:
        if rel.endswith("/main.zig"):
            continue
        names = []
        counts: dict[str, int] = {}
        for line in (root / rel).read_text(encoding="utf-8", errors="replace").split("\n"):
            m = PUB_FN.match(line)
            if not m:
                continue
            name = m.group(2) or m.group(4)
            if not any(name.startswith(v) for v in VERBS):
                continue
            # A file may declare the same name twice in different constructs
            # (pcs.zig has MlePcsWith's proveEval and CommittedMlePcsWith's;
            # merkle_tree.zig has a method and a free function both named
            # verifyPath). They are distinct entry points, so the second and
            # later ones carry an occurrence suffix rather than sharing a row.
            counts[name] = counts.get(name, 0) + 1
            names.append(name if counts[name] == 1 else f"{name}#{counts[name]}")
        if names:
            out[rel] = names
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--ledger", default="docs/kat_ledger.json")
    args = ap.parse_args()
    root = Path(args.root)

    tree = derive(root)
    ledger_path = root / args.ledger
    failures: list[str] = []

    if not ledger_path.exists():
        print(f"{ledger_path.name}: no ledger at {ledger_path}. A gate with no "
              "ledger is a gate that has not looked at anything.")
        return 1
    ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
    rows = ledger.get("entries", {})

    derived = {f"{f}:{n}" for f, names in tree.items() for n in names}
    row_keys = set(rows)

    # 1. empty entry: the tree has one the ledger does not account for.
    for key in sorted(derived - row_keys):
        failures.append(f"empty entry: {key} is in the tree and has no row in the ledger")

    # 2. absent name: the ledger names one the tree no longer has.
    for key in sorted(row_keys - derived):
        failures.append(f"absent name: the ledger has {key}, which the tree does not declare")

    # 3. blank provenance, and the printed reasons.
    pinned, reasoned = [], []
    for key in sorted(derived & row_keys):
        row = rows[key]
        vec, reason = str(row.get("vector", "")).strip(), str(row.get("reason", "")).strip()
        if not vec and not reason:
            failures.append(f"blank provenance: {key} has neither a vector nor a reason")
            continue
        if vec:
            pinned.append((key, vec))
        else:
            reasoned.append((key, reason))

    if failures:
        print("cryptographic entry-point ledger does not hold up:\n")
        for f in failures:
            print(f"  {f}")
        print(f"\n{len(failures)} violation(s).")
        return 1

    total = len(derived)
    print(f"entry-point ledger in sync: {total} entry points over {len(tree)} files "
          f"({len(pinned)} pinned to an external vector, {len(reasoned)} with a recorded reason)")
    print("\npinned to an external vector:")
    for key, vec in pinned:
        print(f"  {key}\n      {vec}")
    print("\nwith a recorded reason:")
    for key, reason in reasoned:
        print(f"  {key}\n      {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
