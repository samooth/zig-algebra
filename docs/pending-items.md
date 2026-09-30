# Where the open items went, and what cannot be recovered

Written 2026-09-30, after `backup/pre-todo-rewrite-20260925` was found absent
from the working tree.

**What this file is.** A pointer table to the places the open items now live, and
a record of what is gone. It is a *recovery report*, not a reconstruction of the
lost file and not a second source of truth. Where it disagrees with a destination
it links to, **the destination wins**. That rule is the point of the file: a
second list of open items is how this repository ended up with two copies of a
field interface inside a hash example, in `libs/hash/src/main.zig`, already
diverged. A recovery report that became a competing list would reproduce the
defect it is documenting.

**Why the loss is smaller than it looks.** `CHANGELOG.md:112` records that the
rewrite moved items down into `libs/field/CHANGELOG.md` and
`libs/field/TODO.md` "with a reason". The destinations are all present, and the
sweep below found them without needing the original.

## The sweep

Counts are **bullet counts**, taken mechanically, and are coarse: see the limits
at the end, where the instrument is shown failing on the item that mattered most.

| Destination | Bullets | What it holds |
|---|---|---|
| `libs/field/TODO.md` | 15 open, 5 phantom, 7 not-in-scope | The surviving sibling of the lost file, in the same dialect: `## Done`, `## Phantom`, `## Open`, `## Not in scope`. 44 items closed. |
| `AGENTS.md` Known Gaps | 7 | The workspace-level gaps, plus the instruction not to paper over them. |
| `README.md` Known Limitations | 8 | Includes two items no central list carries: the `zig-rng` test-hook reset, and the pointer to per-library API gaps. |
| `docs/architecture.md` Known Gaps | 6 | The same family as `AGENTS.md`, from the reader's view. |
| `libs/fri/README.md` | 10 | The most open items of any single library. |
| `libs/field/README.md` | 8 | |
| `libs/ntt/README.md` | 8 | |
| `libs/linalg/README.md` | 7 | |
| `libs/bigint/README.md` | 7 | |
| `libs/algebra-traits/README.md` | 6 | |
| `libs/rng/README.md` | 5 | |
| `libs/binary-field/README.md` | 3 | |
| `libs/poly/README.md` | 0 bullets, 1 table row | See below: the counter returns zero and the file has the worst gap in the tree. |
| `docs/requirements.md` | 2 | Rows explicitly marked **intention**: a claim that no instrument yet sustains, kept as an intention rather than dressed as a requirement. |
| `SECURITY.md` | 2 | "Two open findings, neither citing the other", which the document itself calls a defect in the document. |

75 bullets across the files that use bullets, plus the items recorded as tables,
as phantom entries, and as intentions.

One destination is a *correction* rather than a gap, and it is evidence of what
the rewrite was for: `libs/pairing/README.md:14` says BN254 "is **no longer
unimplemented** — the older status table in git history predated
`bn254_tower.zig`". At least one stale claim about what exists was corrected
during the rewrite. Nothing in this repository says whether the lost root
`TODO.md` carried claims of that kind, and this file does not guess.

## What cannot be recovered

- The lost file's text, wording, ordering and headings.
- Any item that was closed or dropped between 2026-09-25 and the rewrite without
  leaving a trace in one of the destinations above.
- Whether the file held claims that were wrong when written.
- **The number of items it held, in either direction.** Nothing here bounds it,
  so no claim about how complete the recovery is can be made from this
  repository. The destinations account for what they account for; they are not
  evidence about what was in the file.

The directory was never tracked, so there is no blob, no stash and no reflog
entry to recover it from. It is gone rather than mislaid.

## What the sweep found that was not recovered

Three things, none of which came from the lost file:

- **`zig-poly`'s `compose` is a silently wrong answer for a non-monomial `q`.**
  It accumulates with a plain `add`, so the result is only correct when `q` is
  `x^k`. It is recorded in `libs/poly/README.md:169` and in `CHANGELOG.md:1394`,
  and in no central list: neither `AGENTS.md`'s Known Gaps nor
  `docs/requirements.md` mentions it. It is tracked, and no single place claims
  it.
- **The mechanical counter returned 0 for `libs/poly`**, the file with the worst
  gap, because the gap is a table row and the instrument counts bullets. Every
  number in the table above has the same blind spot. The counts are bullet
  counts, not item counts, and should be read that way.
- **`libs/pairing/README.md` claimed 57 tests; 58/58 pass** when measured. The
  count was corrected in the commit beside this one. A figure carried in prose
  drifts, and the fix is to re-derive it rather than to add a delta to a number
  nobody measured.

## The structural consequence

Open items live in at least **fifteen** places, and no document enumerates them
all. "Is the list complete?" is therefore answerable only by re-running the
sweep above, and that sweep is not a gate: nothing fails when a new gap is added
to a library README and not to a central list, and nothing fails when one is
closed in a destination and left open in another.

This is the same shape the assert ledger had before it was a gate, and the
honest statement is that a pointer table does not fix it. What it fixes is that
the loss is now bounded and documented rather than silent, and that a future
reader can see that the completeness question exists and what would answer it.
