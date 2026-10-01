#!/usr/bin/env python3
"""Fail if a test count written in prose disagrees with the measured count.

This exists because it happened four times in one week. Each time tests were
added, the root total and the per-library figures moved, and every document that
quoted them had to be moved by hand: the root README table, the per-library
READMEs, and AGENTS.md. On three of those occasions the root total and one
per-library figure were updated and the other was not, so a document in this
repository stated two different numbers for the same thing.

The check is deliberately not a re-measurement: running seventeen test suites to
prove a sentence is expensive, and the CI job that already runs them knows the
number. So this compares three things and reports which of them disagree:

  1. the parts of `docs/test_counts.json` against its own total
  2. every count cited in a README or in AGENTS.md against that file
  3. optionally, a count passed in with --measured, which CI takes from the suite
     it just ran

Rule 3 is what makes this a gate rather than another spreadsheet: a test added
without moving the baseline fails the job that ran the tests. Without it, this
would be a register, and registers fail silently.

A pattern that matches zero times is also a failure. If a document is reworded
until the sentence this looks for no longer exists, that is not a pass, it is a
check that stopped looking at anything.
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Per-library: "N tests" / "N tests:" in that library's own README. The lookbehind
# keeps "RFC 8439 test vectors" from being read as a count, which is the same
# substring mistake that let a global find-and-replace corrupt a documented prime.
COUNT_IN_LIBRARY = re.compile(r"(?<!RFC )\b(\d+)\s+tests?\b")
TABLE_ROW = re.compile(r"^\| \[[a-z-]+\]\(libs/([a-z-]+)/\)[^\n]*\| (\d+) \|$")

# The root total is looked for in named sentences rather than as a bare number,
# because "588" also appears in benchmark timings and in prose about a past
# mistake. Each pattern must match exactly once.
SUMMARY_TOTAL = re.compile(r".*;\s+(\d+)/\d+ tests passed.*")

ROOT_TOTAL_PATTERNS = [
    ("README.md", r"runs \*\*(\d+) tests\*\*"),
    ("README.md", r"\*\*(\d+), the same number\*\*"),
    ("README.md", r"Runs the (\d+) library tests"),
    ("AGENTS.md", r"all library tests \((\d+) tests,"),
    ("AGENTS.md", r"Same (\d+) tests, seconds"),
    ("AGENTS.md", r"\((\d+) total across all 27 test binaries"),
    ("AGENTS.md", r"root `zig build test` = (\d+);"),
    ("AGENTS.md", r"totals sum to (\d+), which now"),
    ("AGENTS.md", r"pairing 58, parallel 7, poly 32, rng 27, serialization (\d+),"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--baseline", default="docs/test_counts.json")
    ap.add_argument(
        "--measured",
        default=None,
        help="the total the suite just reported, as text. An empty value fails with "
        "a sentence naming the cause rather than an argparse type error.",
    )
    ap.add_argument(
        "--summary-file",
        default=None,
        help="a file holding the suite's own --summary output; the count is parsed out "
        "of it here, where the pattern can be tested, rather than in a workflow "
        "where nothing tests it. The line is on STDERR, which is why the caller "
        "redirects 2>&1.",
    )
    args = ap.parse_args()

    root = Path(args.root)
    base_path = root / args.baseline
    if not base_path.exists():
        print(f"counts_verify: {base_path} not found", file=sys.stderr)
        return 1
    base = json.loads(base_path.read_text(encoding="utf-8"))
    per = base["per_library"]
    total = base["total"]
    failures = []

    # 1. the baseline against itself.
    summed = sum(per.values())
    if summed != total:
        failures.append(
            f"{args.baseline}: per_library sums to {summed} but total says {total}."
        )
    if len(per) != 17:
        failures.append(
            f"{args.baseline}: {len(per)} libraries listed, this workspace has 17."
        )

    # 2a. each library README's cited count.
    for lib, want in sorted(per.items()):
        readme = root / "libs" / lib / "README.md"
        if not readme.exists():
            failures.append(f"{readme} not found")
            continue
        cited = [int(m.group(1)) for m in COUNT_IN_LIBRARY.finditer(readme.read_text(encoding="utf-8"))]
        if not cited:
            failures.append(
                f"{readme}: states no test count at all. A README that does not say "
                "how many tests a library has cannot be checked, and an unchecked "
                "figure is how the four divergences happened."
            )
            continue
        for got in cited:
            if got != want:
                failures.append(
                    f"{readme}: cites {got} tests, the measurement is {want}."
                )

    # 2b. the root table's Tests column.
    root_readme = (root / "README.md").read_text(encoding="utf-8")
    for i, line in enumerate(root_readme.splitlines(), 1):
        m = TABLE_ROW.match(line)
        if not m:
            continue
        lib, got = m.group(1), int(m.group(2))
        if lib not in per:
            failures.append(f"README.md:{i}: row for {lib}, which is not in the baseline")
        elif got != per[lib]:
            failures.append(f"README.md:{i}: table says {got} for {lib}, measurement is {per[lib]}")

    # 2c. the named sentences carrying the root total.
    for rel, pat in ROOT_TOTAL_PATTERNS:
        text = (root / rel).read_text(encoding="utf-8")
        want = per["serialization"] if "serialization" in pat else total
        found = re.findall(pat, text)
        if len(found) != 1:
            failures.append(
                f"{rel}: the sentence this looks for matched {len(found)} times, not 1. "
                f"Pattern: {pat!r}. A reworded document is not a passing document."
            )
            continue
        got = int(found[0])
        if got != want:
            failures.append(
                f"{rel}: says {got} where the measurement is {want} "
                f"(pattern {pat!r})."
            )

    # 3. the live measurement, when CI has one.
    measured = None
    if args.summary_file is not None:
        spath = Path(args.summary_file)
        if not spath.exists():
            failures.append(
                f"--summary-file {args.summary_file} does not exist. The caller is "
                "supposed to hand over the suite's own output."
            )
        else:
            text = spath.read_text(encoding="utf-8", errors="replace")
            hits = re.findall(SUMMARY_TOTAL, text)
            if len(hits) != 1:
                failures.append(
                    f"{args.summary_file}: the suite's summary line matched {len(hits)} "
                    f"times, not 1, looking for {SUMMARY_TOTAL.pattern!r}. The build "
                    "prints that line on STDERR, so `zig build test --summary all` "
                    "piped without 2>&1 writes an empty file and this check cannot see "
                    "its own input."
                )
            else:
                measured = int(hits[0])
    if measured is None and args.measured is not None:
        raw = str(args.measured).strip()
        if not raw or not raw.isdigit():
            failures.append(
                f"--measured was {raw!r}, which is not a count. The caller extracts "
                "the number from the suite's own summary line, and that summary goes to "
                "STDERR: piping `zig build test --summary all` without `2>&1` captures "
                "stdout only, so the extraction silently yields nothing. This is the "
                "check failing to see its own input, which is the one failure mode it "
                "cannot be allowed to have."
            )
        else:
            measured = int(raw)
    # The comparison lives OUTSIDE both extraction paths on purpose. It sat inside
    # the --measured branch, so a number that arrived via --summary-file was parsed
    # and then never compared: the live gate, the one that matters, did not fire.
    # Restructuring a check and not re-testing every direction is how that happens,
    # and the symptom was a direction that printed nothing.
    if measured is not None and measured != total:
        failures.append(
            f"{args.baseline}: total says {total} and the suite just reported "
            f"{measured}. The tests moved and the documented counts did not; re-derive "
            f"the per-library figures and update this file in the same commit that added "
            f"the tests."
        )

    if failures:
        print("documented test counts do not hold up:\n", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        print(f"\n{len(failures)} violation(s).", file=sys.stderr)
        return 1

    tail = f", measured {measured}" if measured is not None else ""
    print(
        f"documented counts in sync: {len(per)} libraries, {summed} tests"
        f"{tail}; baseline dated {base['measured']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
