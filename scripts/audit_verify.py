#!/usr/bin/env python3
"""Fail if AUDIT.md does not hold up as a gate rather than a spreadsheet.

The failure mode this exists for: AUDIT.md is a register of open items, and a
register fails silently. Row 11 sat open for a week with a valid-looking table
around it, and nothing failed. A gate needs a number behind the rows, and it
needs the document's own claims about itself to be checked rather than trusted.

Five rules. Each one is here because it caught something, not because it is
tidy:

  1. Every row carries a non-empty closing criterion. The observable that was
     checked. An empty cell is an error, not a style question.
  2. An `open` row's criterion may not restate its own item text.
  3. A `decision` row must name an owner (`owner:`). A decision with no owner is
     an open row wearing a different label.
  4. The declared counts in the machine-readable comment must match the rows.
  5. The document's record of the original must be what it says it is: the copy
     it names must exist in the tree and match the sha256 recorded beside it.
     Any `git show <ref>:<path>` in the file must also resolve — two did not, the
     file pointed at an `AUDIT-original.md` that never existed on the branch.
     The checksum carries the rule rather than the ref, because the branch that
     holds the pre-rewrite history is local and unpublished, and a gate that
     depends on a ref nobody else has is a gate that is red for the wrong
     reason.

Exits 0 when the register holds, 1 with every violation listed when it does not.
The output is the report: an empty result means the question was asked and came
back clean, and this script never exits 0 without having asked.
"""

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

ROW = re.compile(
    r"^\|\s*(?P<num>\d+)\s*\|(?P<item>[^|]*)\|(?P<status>[^|]*)\|"
    r"(?P<criterion>[^|]*)\|(?P<how>[^|]*)\|\s*$"
)
DECLARED = re.compile(r"<!--\s*audit:(?P<body>total=\d+[^>]*)\s*-->")
RECORD = re.compile(
    r"<!--\s*audit:record=(?P<path>[^\s>]+)\s+sha256=(?P<sha>[0-9a-f]{64})\s*-->"
)
GIT_SHOW = re.compile(r"git show\s+([A-Za-z0-9._/-]+:[A-Za-z0-9._/-]+)")

CLOSED, OPEN, DECISION = "closed", "open", "decision"

# Words that satisfy "owner:" without naming anybody.
ROLES = frozenset({
    "the", "someone", "somebody", "anyone", "nobody", "a", "an",
    "we", "i", "you", "they", "it",
})


def classify(status: str) -> str:
    s = status.strip().lower().strip("*")
    if s.startswith(CLOSED):
        return CLOSED
    if s.startswith(DECISION):
        return DECISION
    if s.startswith(OPEN):
        return OPEN
    return "unknown"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--audit", default="AUDIT.md")
    ap.add_argument(
        "--no-check-refs",
        action="store_true",
        help="skip rule 5, which resolves every git show in the document",
    )
    args = ap.parse_args()

    path = Path(args.audit)
    if not path.exists():
        print(f"audit_verify: {path} not found", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8")

    rows = []
    for lineno, line in enumerate(text.splitlines(), 1):
        m = ROW.match(line.strip())
        if m:
            rows.append((lineno, m.groupdict()))

    failures: list[str] = []

    if not rows:
        failures.append(
            f"{path}: no rows parsed. The table's shape changed and the gate no "
            "longer sees the register it exists to watch. A gate that cannot see "
            "its subject passes for the same reason a spreadsheet does."
        )

    # Rule 1 and 2 and 3, per row.
    for lineno, r in rows:
        num, item = r["num"], r["item"].strip()
        kind = classify(r["status"])
        criterion = r["criterion"].strip()

        if kind == "unknown":
            failures.append(
                f"{path}:{lineno} row {num}: status {r['status'].strip()!r} is not one of "
                f"closed, open, decision"
            )
        if not criterion:
            failures.append(
                f"{path}:{lineno} row {num}: empty closing criterion. Every row names "
                "the observable that was checked; an empty cell is how a row becomes "
                "unfalsifiable."
            )
        elif kind == OPEN and criterion.lower() == item.lower():
            failures.append(
                f"{path}:{lineno} row {num}: an open row's criterion restates the item. "
                "If the only way to satisfy it is to re-read the sentence, it is not a "
                "criterion."
            )
        elif kind == DECISION:
            if "owner:" not in criterion.lower():
                failures.append(
                    f"{path}:{lineno} row {num}: a decision row names no owner. A decision "
                    "with no owner is an open row wearing a different label."
                )
            else:
                # Strip markdown emphasis and surrounding punctuation before looking
                # at the word: the document writes `owner: **thomas**`, and comparing
                # the raw token meant the rule never fired on the format actually in use.
                # A check that passes on the wrong reason is a check that does not exist.
                raw = criterion.lower().split("owner:", 1)[1].strip()
                # The owner is the name before the first comma; the rest of the cell is
                # the decision being waited on, and quoting it as the owner made the
                # message unreadable.
                owner = raw.split(",", 1)[0].strip().strip("*_` ").rstrip(".,:;")
                words = owner.split()
                # A gate that only checks for a string accepts a role, and a role does
                # not answer. This rule exists because a row said "the repository owner"
                # and satisfied the previous rule while naming nobody — the same shape
                # as a true statement that cannot be refuted.
                first = words[0].strip("*_`.,:;") if words else ""
                if not first or first in ROLES:
                    failures.append(
                        f"{path}:{lineno} row {num}: the owner is {owner!r}, which is a role "
                        "rather than a person. Naming a role satisfies the requirement to "
                        "name an owner and answers nothing."
                    )

    # Rule 4, declared counts against counted rows.
    counts = {CLOSED: 0, OPEN: 0, DECISION: 0}
    for _, r in rows:
        counts[classify(r["status"])] = counts.get(classify(r["status"]), 0) + 1

    dm = DECLARED.search(text)
    if not dm:
        failures.append(
            f"{path}: no machine-readable count comment (<!-- audit:... -->). Without a "
            "declared number there is nothing for the rows to disagree with, which is "
            "the state this file was in for a week."
        )
    else:
        declared = dict(
            (k, int(v))
            for k, v in re.findall(r"(\w+)=(\d+)", dm.group("body"))
        )
        actual = dict(counts)
        actual["total"] = len(rows)
        for key, want in sorted(declared.items()):
            got = actual.get(key)
            if got != want:
                failures.append(
                    f"{path}: declares {key}={want} but the table has {got}. Move the "
                    "number and the rows together, or decide which one is true."
                )

    # Rule 5, the document's record of the original must still be what it claims.
    # Two forms, and the reason for the second one is worth stating: resolving a
    # `git show` is only useful if the ref is published, and the branch that
    # holds the pre-rewrite history is local on purpose. So the record that the
    # gate depends on is the copy in the tree, identified by checksum, which
    # works on a fresh clone.
    refs_checked = 0
    for ref in sorted(set(GIT_SHOW.findall(text))):
        refs_checked += 1
        proc = subprocess.run(
            ["git", "cat-file", "-e", ref],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            failures.append(
                f"{path}: `git show {ref}` does not resolve in this repository. A "
                "document that points at a file which is not there cannot be used to "
                "recover anything."
            )

    record = RECORD.search(text)
    if not record:
        failures.append(
            f"{path}: no record comment (<!-- audit:record=... sha256=... -->). Without "
            "one, the document's own account of what the original said is unfalsifiable."
        )
    else:
        rec_path = Path(record.group("path"))
        want = record.group("sha")
        if not rec_path.exists():
            failures.append(
                f"{path}: record path {rec_path} does not exist. The copy this document "
                "relies on is not in the tree."
            )
        else:
            got = hashlib.sha256(rec_path.read_bytes()).hexdigest()
            if got != want:
                failures.append(
                    f"{path}: {rec_path} has sha256 {got[:16]}..., the document records "
                    f"{want[:16]}.... A dated record that has been edited is no longer "
                    "the record, and a register that points at a modified copy is worse "
                    "than one that points at nothing."
                )

    if failures:
        print("audit register does not hold up:\n", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        print(
            f"\n{len(failures)} violation(s): {len(rows)} rows, {refs_checked} ref(s) resolved.",
            file=sys.stderr,
        )
        return 1

    print(
        f"audit register in sync: {len(rows)} rows "
        f"({counts[CLOSED]} closed / {counts[OPEN]} open / {counts[DECISION]} decision), "
        f"declared counts match, {refs_checked} ref(s) resolve"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
