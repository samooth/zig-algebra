# Where the open items went, and the list that was lost and then found

**Correction, 2026-09-30.** An earlier version of this file reported the
pre-rewrite roadmap as unrecoverable: "gone rather than mislaid", "no blob, no
stash and no reflog entry". **That was false.** The directory
`backup/pre-todo-rewrite-20260925` is gone from the working tree, but its
content was never in danger, because it was also a **git ref**:

```
git show backup/pre-todo-rewrite-20260925:TODO.md      # 155 lines, intact
```

The branch points at `6f5d50b` ("chore: ignore local package cache",
2026-09-25), is **not** an ancestor of `main`, and carries **34 commits that
`main` does not**. It is the only ref to the pre-rewrite history.

## How a recoverable thing was reported as lost

The search that produced the false zero was a filesystem search:

```
find / -maxdepth 4 -name "pre-todo-rewrite*"    # returned nothing
```

The name it was looking for was not a path. It was a branch. A search pointed at
the filesystem cannot see a ref, so it returned an empty answer that was
consistent with absence, and that empty answer was written into a signed commit
about bounding losses. This is the failure this repository has a name for — an
instrument answering a different question — and it was worth recording that the
sharpest instance of it in this repository's history is in **the document whose
subject is bounding losses**. The recovery was one command away the entire time.

## The list that existed, and what became of it

The recovered file is not a duplicate of the per-library sections. It was a
**single central roadmap**, "Roadmap de corrección de zig-algebra", 155 lines,
dated 2026-09-25, organised as P0 blockers, P1 items, and closing criteria, with
most items already checked and **13 still open**.

So the rewrite did not merely avoid losing the items. It replaced one list that
enumerated them with roughly fifteen places that each hold a fragment, and no
document enumerates the whole. That is a **regression in checkability**, and it
was previously an inference; the original in hand makes it a comparison.

The destinations are listed below. They remain useful as a map — that part of
the earlier report stands — but the map is now a *scatter diagram*, not proof of
loss.

| Destination | Bullets | What it holds |
|---|---|---|
| `libs/field/TODO.md` | 15 open, 5 phantom, 7 not-in-scope | The surviving sibling of the lost roadmap, in the same dialect: `## Done`, `## Phantom`, `## Open`, `## Not in scope`. 44 closed. |
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
| `libs/poly/README.md` | 0 bullets, 1 table row | The counter returns zero and the file has the worst gap in the tree: `compose` with a non-monomial `q` returns a silently wrong polynomial. |
| `docs/requirements.md` | 2 | Rows explicitly marked **intention**: a claim that no instrument yet sustains. |
| `SECURITY.md` | 2 | "Two open findings, neither citing the other", which the document itself calls a defect in the document. |

Counts are **bullet counts**, taken mechanically, and are coarse. The count for
`libs/poly` is zero because its gap is a table row, and it is the one library
whose gap is a wrong answer rather than a missing feature. Every number in the
table has that blind spot.

One destination is a *correction* rather than a gap: `libs/pairing/README.md:14`
says BN254 "is **no longer unimplemented** — the older status table in git
history predated `bn254_tower.zig`". At least one stale claim about what exists
was corrected during the rewrite.

## The 13 open items, with what was measured

Line numbers are those of the recovered file. **Six are measured closed and seven
are not verified.** The unverified column is not a formality: the instruments
that would answer several of them do not exist, and that is itself the finding.

| Line | Item | Status |
|---|---|---|
| 17 | CI matrix Linux/macOS/Windows and WASM | **Closed.** Run 36749932662 on `aa333d1`: 11/11 jobs, three operating systems, `wasm-build` including the Node smoke. |
| 18 | No unversioned temporary artefacts in the worktree | **Closed.** `git status --porcelain --untracked-files=all` is empty. |
| 101 | Replace the remaining public validation asserts with typed errors | **Closed.** `zig build assert-check`: `public=0 internal=1 comptime=23 fixture=30`. |
| 136 | Remove the local `/tmp/bsvz.tar.gz` dependency | **Closed.** No match in `build.zig.zon`. |
| 137 | Remove the `zig_algebra` self-dependency | **Closed.** `.dependencies = .{}` and no `path = "."`. The `.name = .zig_algebra` on line 2 is the package's own name, which is required, not a self-reference. |
| 139 | Reconcile versions `0.3.0`/`0.3.1` and the FRI advisory | **Closed by supersession.** Root is `0.6.0` and `zig-fri` is `0.4.0`; the versions the item names no longer exist. |
| 138 | Make the submodule path packages reproducible | **Not verified.** Needs a sweep of the 17 `build.zig.zon` files that nobody has run. |
| 148 | No critical security TODO without a regression test | **Not verified.** No instrument enumerates security TODOs. |
| 151 | No test hangs indefinitely on rejection sampling; field and transcript need review | **Not verified.** The FRI generator is bounded and typed as of `f80827b`; `field` and `transcript` are unchecked, and an unbounded search is a check without an answer. |
| 152 | No asserts removed in ReleaseFast leaving out-of-range pathways | **Not answerable by the ledger.** The ledger counts asserts that are *present*; this item is about ones that were *removed*, which is a different question with no instrument. |
| 153 | External points validate on-curve, subgroup and encoding | **Partly visible.** `wasm-build` checks subgroup and encoding; nothing checks the curve library's external entry points. |
| 154 | Serializers have resource limits and free memory on every error | **Partly contradicted.** The serialization differential added rejection tests, and `libs/poly`'s `compose` is a live wrong answer against the spirit of this item. |
| 155 | Constant-time claims backed by tests or an assembly audit | **Not verified, and open by admission.** `SECURITY.md` states that no independent audit exists for any library. |

## What is actually lost

Narrower than first reported, and it is worth stating exactly:

- The **directory** `backup/pre-todo-rewrite-20260925`, as a directory. It was
  never tracked, so the duplicate of the tree it held is gone. The tracked state
  at the same point is on the branch.
- Any **uncommitted** edit that existed inside that directory at the moment it
  disappeared. A branch records commits, not working trees.
- Nothing else that was measured. The roadmap itself is intact.

And the risk that remains is not loss but **single-copy custody**: the
pre-rewrite history, with its 34 commits and the only copy of that roadmap,
exists in exactly one ref in exactly one clone. The remote carries `main` only.

## The structural consequence

Open items live in at least **fifteen** places, and no document enumerates them
all, where before the rewrite one document enumerated thirteen. "Is the list
complete?" is answerable only by re-running the sweep in the table above, and
that sweep is not a gate: nothing fails when a new gap appears in a library
README and not in a central list, and nothing fails when one is closed in a
destination and left open in another.

This is the shape the assert ledger had before it was a gate, and a pointer table
does not fix it. What this file fixes is that the question is now written down
with the original available to answer it, and the roadmap can be restored to
`main` by anyone who decides the scatter is the wrong shape.
