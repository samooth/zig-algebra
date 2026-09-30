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

Line numbers are those of the recovered file, which is now restored in the tree
as [`roadmap-2026-09-25.md`](roadmap-2026-09-25.md) — verbatim, so its unchecked
boxes are a record rather than a claim. **Ten are measured closed or
partly closed, and three remain open**, two of them by the repository's own
admission. Updated 2026-09-30, after the second verification pass; an earlier
version of this table said seven were unverified, which is itself the staleness
this repository keeps paying for in prose.

| Line | Item | Status |
|---|---|---|
| 17 | CI matrix Linux/macOS/Windows and WASM | **Closed.** Run 36749932662 on `aa333d1`: 11/11 jobs, three operating systems, `wasm-build` including the Node smoke. |
| 18 | No unversioned temporary artefacts in the worktree | **Closed.** `git status --porcelain --untracked-files=all` is empty. |
| 101 | Replace the remaining public validation asserts with typed errors | **Closed.** `zig build assert-check`: `public=0 internal=1 comptime=23 fixture=30`. |
| 136 | Remove the local `/tmp/bsvz.tar.gz` dependency | **Closed.** No match in `build.zig.zon`. |
| 137 | Remove the `zig_algebra` self-dependency | **Closed.** `.dependencies = .{}` and no `path = "."`. The `.name = .zig_algebra` on line 2 is the package's own name, which is required, not a self-reference. |
| 139 | Reconcile versions `0.3.0`/`0.3.1` and the FRI advisory | **Closed by supersession.** Root is `0.6.0` and `zig-fri` is `0.4.0`; the versions the item names no longer exist. |
| 138 | Make the submodule path packages reproducible | **Closed.** All 17 `libs/*/build.zig.zon` path dependencies are relative and resolve inside the repository; none absolute, none dangling. |
| 148 | No critical security TODO without a regression test | **Two findings, both the shape the item forbids.** `libs/pairing/src/bn254.zig:207` carries `TODO: Pairing tests` over a `pub fn pairing()` that nothing calls and nothing tests, in a second BN254 implementation absent from `libs/pairing/README.md`'s status table; its *types* are used by `libs/curve/src/msm.zig`, so the file is half live. Not a vulnerability — an uncalled function cannot give a wrong answer to anyone — but a live trap, and `assert-check` cannot see it because "declared but never called" is not inventoried. Separately `libs/binary-field/src/pack.zig:29` cites `TODO.md §1` and no such file exists in that library. |
| 151 | No test hangs indefinitely on rejection sampling; field and transcript need review | **Closed by reading the construction, not by sweeping.** All five satisfaction-loops in `field` and `transcript` accept with probability at least one half by construction: the big-field `randomBounded` masks to `bitlength(limit-1)`, so `2^bits >= limit` and acceptance is `limit / 2^bits >= 1/2`; the small-field path delegates to `std.Random.uintLessThan`; the two transcript loops re-key the hasher per attempt, so retries are uncorrelated. A 32-site sweep classified as 19 counter-bounded, 8 value-bounded and 5 satisfaction; the first sweep's pattern (`while (x % m)`) could not see the `while (true)` it was looking for. **Residual:** 4 of the 19 counter-bounded were read individually and are test sample sizes, not searches; the other 15 were classified by head, not read. |
| 152 | No asserts removed in ReleaseFast leaving out-of-range pathways | **Closed as far as any instrument reaches, with the gap named.** `assert-check` reports `public=0`, so no public validation assert exists; the full suite is green in ReleaseFast on three operating systems, which is what exercises the paths an assert used to guard. **Named gap:** a pathway no test exercises is invisible to both instruments, and no instrument here can see a removal. |
| 153 | External points validate on-curve, subgroup and encoding | **Partial, and the residual is the finding.** On-curve is enforced with a typed error in one public path (`libs/curve/src/weierstrass.zig:95`). **No subgroup check exists in the curve library at all** — subgroup validation lives in `zig-pairing` and in the WASM layer — so a point taken from outside `zig-curve` and multiplied by a secret receives no subgroup check from it. Encoding is not checked by this pass. |
| 154 | Serializers have resource limits and free memory on every error | **Partial.** Boundedness is argued in a comment (`libs/serialization/src/root.zig:33`, sizes bounded by the input size via `minWireSize`) and the rejection tests use a `FailingAllocator` to prove nothing reaches the allocator, but **no test is named for a resource limit**. The `compose` counter-example named in the earlier version of this table is resolved: it accumulates by multiplication, the entry was stale, and two tests now hold it — one evaluating the definition numerically over `F7`, one asserting the operands survive a degree failure. |
| 155 | Constant-time claims backed by tests or an assembly audit | **Open, and its would-be instrument is decorative.** The test named "Constant-time primitives" (`libs/field/src/montgomery.zig:471`) asserts that a selector returns the value asked for, not that it takes constant time, so it would pass against an implementation that is not constant-time. There is deliberately no timing test in `field`, since timing tests are flaky. The instrument that would close this is an assembly audit, and `SECURITY.md` states that no independent audit exists for any library. |

## What is actually lost

Narrower than first reported, and it is worth stating exactly. The roadmap
itself is **not** lost: it is in this tree, verbatim, as
[`roadmap-2026-09-25.md`](roadmap-2026-09-25.md), and the working directory that
held a duplicate of it is the only thing that is gone:

- The **directory** `backup/pre-todo-rewrite-20260925`, as a directory. It was
  never tracked, so the duplicate of the tree it held is gone. The tracked state
  at the same point is on the branch.
- Any **uncommitted** edit that existed inside that directory at the moment it
  disappeared. A branch records commits, not working trees.
- Nothing else that was measured. The roadmap itself is intact.

And the risk that remains is not loss but **single-copy custody**: the
pre-rewrite history, with its 34 commits, exists in exactly one ref in exactly
one clone, and the remote carries `main` only. The roadmap is no longer part of
that risk — it is in this tree — but the history it was written against is, and
a `git push origin backup/pre-todo-rewrite-20260925` would end the custody
question without touching the working tree.

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
