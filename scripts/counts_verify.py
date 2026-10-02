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
import subprocess
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
    # These two were missing from this list and were the worst in the tree:
    # DESIGN.md said the root step executes 391 tests, and docs/architecture.md
    # said 423 in one place and 583 in another, against a measurement of 588. A gate
    # is only as good as the file list it was given, and that list came from
    # whichever task happened to be in front of me rather than from the tree.
    ("DESIGN.md", r"executes \*\*(\d+)\*\* tests"),
    ("docs/architecture.md", r"same (\d+) tests, seconds"),
    ("docs/architecture.md", r"runs \*\*(\d+) tests\*\*"),
]

# A named library's own count, asserted outside its README.
LIBRARY_CLAIMS = [
    ("docs/architecture.md", r"before 0\.5\.0 and now has (\d+)", "algebra-traits"),
    ("README.md", r"before `0\.5\.0` and now has (\d+)", "algebra-traits"),
]

# Which tracked Markdown documents this gate checks, and which it deliberately does
# not. The second list is the one to read skeptically, which is why every entry
# carries a reason and why the script prints the skipped set on every run.
#
# It exists because the obvious rule does not work, and the measurement is worth more
# than the rule: scanning every tracked .md for "<N> tests" finds 63 citations, of
# which 31 are not any current total. Every one of the 31 is correct. CHANGELOG.md
# is 12 of them -- a changelog that restated today's counts would be a changelog that
# lied about the past. SECURITY.md quotes 417/417 because that is what two test
# modes reported on the day. docs/requirements.md is a mutation log whose rows say
# "2 tests fail" as the expected outcome of a deliberate mutation. So a gate of "every
# N tests in every .md must equal a current total" would have to be fed 31 lies to
# pass, and a gate nobody can pass is a gate nobody reads.
#
# The rule that does work is a registry checked against the tree: a document is either
# matched by a pattern above, or it is here with a reason. A new Markdown file that is
# in neither fails, so the scope cannot grow silently; an entry naming a file that is
# gone fails, so it cannot rot. That is the difference between an exception list and a
# hidden hand-written list: this one is derived, it is gated in both directions, and it
# is printed every run.
NOT_CHECKED = {
    "CHANGELOG.md": "a record of what was true at each release; restating today's "
    "totals would falsify it",
    "SECURITY.md": "quotes the counts the affected releases reported, and a vector "
    "count from an external implementation",
    "docs/requirements.md": "mutation log; rows state how many tests SHOULD fail",
    "docs/assert-ledger.md": "per-library analysis of a past gap, including counts "
    "of tests that were not being run",
    "libs/field/TODO.md": "a work list; its counts are the ones being argued about, "
    "and TODO.md is where they get resolved",
    "TODO.md": "a work list, for the same reason",
    "draft/INTEGRATOR-REPLY.md": "an unsent draft quoting release figures",
    "libs/field/CHANGELOG.md": "same reason as the root CHANGELOG.md; its two "
    "stale figures (85 tests) are entries about v0.3.0 and v0.4.0",
}

# Documents measured to cite no test count at all. Skipping them would be the weak
# move: the claim "this file states no count" is itself checkable, it is true today for
# all four, and if one of them ever grows a figure the gate fires instead of going
# quietly unchecked. A skip list is the right instrument for a record whose numbers are
# meant to be old; it is the wrong instrument for a document that simply has none.
CITES_NO_COUNT = [
    "AUDIT.md",
    "docs/pending-items.md",
    "docs/roadmap-2026-09-25.md",
    "libs/field/AGENTS.md",
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

    # 2c-0b. documents measured to cite no count must still cite none.
    for rel in CITES_NO_COUNT:
        path = root / rel
        if not path.exists():
            failures.append(f"{rel}: listed as citing no test count, but the file is absent.")
            continue
        found = COUNT_IN_LIBRARY.findall(path.read_text(encoding="utf-8"))
        if found:
            failures.append(
                f"{rel}: now states {len(found)} test count(s) ({', '.join(found[:6])}), and "
                "this gate reads none of them. Either the figure is current and belongs in a "
                "pattern above so it is compared, or it is historical and the file belongs "
                "in NOT_CHECKED with that reason. The third option -- a number nothing checks "
                "-- is the one that let DESIGN.md say 391 for a release."
            )

    # 2c-0. the gate's own scope, checked against the tree in both directions.
    checked_files = {rel for rel, _ in ROOT_TOTAL_PATTERNS} | {
        rel for rel, _, _ in LIBRARY_CLAIMS
    } | {"README.md"} | {f"libs/{lib}/README.md" for lib in per} | set(CITES_NO_COUNT)
    tracked = subprocess.run(
        ["git", "-C", str(root), "ls-files", "*.md"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    for rel in sorted(tracked):
        if rel not in checked_files and rel not in NOT_CHECKED:
            failures.append(
                f"{rel}: a tracked Markdown file that no pattern in this gate reads and "
                f"that {Path(__file__).name} has no reason for skipping. Adding a document "
                "that quotes a test count has to be a decision, and this is where the "
                "decision is recorded. If the file genuinely holds no count, add it to "
                "NOT_CHECKED with the reason -- that way the next reader sees what is not "
                "being checked instead of inferring it."
            )
    for rel in sorted(NOT_CHECKED):
        if rel not in tracked:
            failures.append(
                f"{Path(__file__).name}: NOT_CHECKED names {rel}, which is not a tracked "
                "file. A skip list that names a file that is gone is a list nobody reads."
            )
        if not NOT_CHECKED[rel].strip():
            failures.append(f"{Path(__file__).name}: NOT_CHECKED[{rel}] has no reason.")

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

    # 2d. a named library's own count, asserted outside its README.
    for rel, pat, lib in LIBRARY_CLAIMS:
        found = re.findall(pat, (root / rel).read_text(encoding="utf-8"))
        if len(found) != 1:
            failures.append(
                f"{rel}: the claim about {lib} matched {len(found)} times, not 1. "
                f"Pattern: {pat!r}. A reworded document is not a passing document."
            )
            continue
        if int(found[0]) != per[lib]:
            failures.append(
                f"{rel}: says {lib} has {found[0]} tests, the measurement is {per[lib]}."
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
    # The skipped set goes to stdout on every passing run, not only on failure. A gate
    # that tells you what it did not look at is auditable; one that stays quiet about it
    # reads as complete coverage, which is the belief that let DESIGN.md say 391.
    if NOT_CHECKED:
        print(
            f"scope: {len(tracked)} tracked Markdown files, "
            f"{len(tracked) - len(NOT_CHECKED)} checked; not checked, with reasons:"
        )
        for rel in sorted(NOT_CHECKED):
            print(f"  - {rel}: {NOT_CHECKED[rel]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
