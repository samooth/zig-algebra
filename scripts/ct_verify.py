#!/usr/bin/env python3
"""Fail if a constant-time judgement in docs/ct_ledger.json is missing a field.

A count says how many conditional jumps a function emits. It does not say whether
they depend on a secret, and nothing in this workspace can decide that from the
instruction stream: it takes a person reading the dataflow. So the ledger records
the count, the judgement, where the judgement came from, and whether the function
was reachable in an emission at all -- and this gate holds it to those five.

What this gate deliberately does not do is classify. Four attempts at deciding
whether a jump is data-dependent, from the instruction text alone, were each wrong
in a direction the previous one was not. The decisive case is 'test r8, 8', where
the 8 is a mask on the value rather than a constant being compared against, and no
rule over operand shape separates it from a literal: in assembly that is a question
of what the instruction means in the dataflow, not of how it is written.

A ledger with zero entries passes the shape check and means nothing, so requiring
at least one is here to keep a rewrite from turning the file into an empty schema.
That is the whole positive control; the mutation is in AGENTS.md: add an entry with
an empty provenance and this must say so.
"""

import argparse
import json
import sys
from pathlib import Path

REQUIRED_ENTRY_FIELDS = (
    "function",
    "conditional_jumps",
    "branchless",
    "judgment",
    "provenance",
    "reachability",
)

REQUIRED_OBJECT_FIELDS = (
    "modulus",
    "target",
    "zig",
    "modes_measured",
    "not_measured",
    "tool",
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--ledger", default="docs/ct_ledger.json")
    args = ap.parse_args()

    root = Path(args.root)
    path = root / args.ledger
    if not path.exists():
        print(f"ct_verify: {path} not found", file=sys.stderr)
        return 1
    led = json.loads(path.read_text(encoding="utf-8"))
    failures = []

    entries = led.get("entries")
    if not isinstance(entries, list) or not entries:
        failures.append(
            f"{args.ledger}: no entries. A ledger with none passes every shape check "
            "and certifies nothing, which is the state a rewrite leaves behind."
        )
        entries = []

    for i, e in enumerate(entries):
        label = e.get("function", f"entry {i}")
        for f in REQUIRED_ENTRY_FIELDS:
            if f not in e:
                failures.append(f"{args.ledger}: {label} has no {f!r}.")
            elif isinstance(e[f], str) and not e[f].strip():
                failures.append(
                    f"{args.ledger}: {label} has an empty {f!r}. A field that is present "
                    "and blank is the shape this gate was built to catch: the sentence "
                    "exists and the thing it was supposed to say does not."
                )
        for k in ("conditional_jumps", "branchless"):
            v = e.get(k)
            if k in e and not isinstance(v, int):
                failures.append(f"{args.ledger}: {label}: {k} is {v!r}, not a count.")
        obj = e.get("object")
        if not isinstance(obj, dict):
            failures.append(
                f"{args.ledger}: {label} has no object. A count without the modulus, the "
                "target, the mode and what was not measured is a number with no label, "
                "which is wrong on its own terms and readable out of context as if it "
                "were universal."
            )
        else:
            for f in REQUIRED_OBJECT_FIELDS:
                if not str(obj.get(f, "")).strip():
                    failures.append(f"{args.ledger}: {label}: object.{f} is missing or empty.")

    for i, w in enumerate(led.get("withdrawn", [])):
        for f in ("claim", "why_withdrawn"):
            if not str(w.get(f, "")).strip():
                failures.append(
                    f"{args.ledger}: withdrawn[{i}] has no {f!r}. A withdrawal without a "
                    "cause is a deletion with a date on it, and the next reader cannot "
                    "tell whether the figure was wrong or the note was."
                )

    if failures:
        print("the constant-time ledger is not usable:\n", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        print(f"\n{len(failures)} violation(s).", file=sys.stderr)
        return 1

    jumps = sum(e["conditional_jumps"] for e in entries)
    print(
        f"ct ledger in shape: {len(entries)} measured function(s), {jumps} conditional "
        f"jump(s) recorded, {len(led.get('withdrawn', []))} withdrawn claim(s) kept with "
        "their reason"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())