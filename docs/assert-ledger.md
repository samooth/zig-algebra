# Assert ledger — convention and ownership

Decisions taken 2026-09-27, after the 0.5.0 P0 closure was reviewed. This file
is the **normative** definition; `scripts/assert_scan.py` implements it and
`zig build assert-check` enforces it. Other repos (currently `zig-zk`) consume
the convention by running the scanner over their own tree.

## Why this exists

The P0 sweep was driven by `rg 'std.debug.assert|catch unreachable'`, which
counts **occurrences**, not **defects**. Of the 105 gross occurrences in
`libs/*/src/` at `v0.5.0`, 49 were doc-comments written by 0.5.0 itself,
explaining which precondition each typed error replaced. Any future session,
reviewer or script that measures with a raw grep therefore gets a number ~47%
fictional, and a library with zero real asserts (`poly`: 7 gross, 0 real)
looks like it carries debt.

A second correction matters more. The working assumption when this work
started was "the asserts are in the public API". That was false here. After
classification:

Scope `libs/*/src/`, which is where the P0 question lives. The separate
`tests/` roots add 50 more occurrences, all of them `fixture`.

| kind | count | what it means |
|------|-------|--------------|
| `public` | **0** | a precondition on a `pub fn` reachable with caller input |
| `internal` | 1 | an invariant between two internal calls, or a precondition on a non-`pub` helper |
| `comptime` | 23 | a `comptime` invariant of a modulus, non-residue, width or curve order |
| `fixture` | 30 | lexically inside a `test` block |

104 gross occurrences, of which **50 are prose** — doc-comments explaining the
precondition each typed error replaced — leaving 54 in code.

`public: 0` is why 0.5.0 could close the P0 instead of partially, and it is the
answer to "is there debt left". It is not derivable from any count: it exists
only once each assert is classified.

**The classification found one more public precondition, after 0.5.0 shipped.**
`zig-bigint`'s `cmpLimbs(a, b)` is a `pub fn` over two caller slices and
asserted `a.len == b.len`; in `ReleaseFast` the loop read past the end of the
shorter slice. It is now total under zero-extension — which is the comparison
`BigInt` already performed internally via `@max(len, other.len)`, so it is the
correct semantics rather than a guess — with `cmpLimbsChecked` keeping the
strictness. That is the whole argument for doing this: the convention found a
real defect on its first run, in a library 0.5.0 never touched, and
`libs/rng/src/main.zig` fell out of the same pass (an example built as an
executable, so no test step ever type-checked it).

## The four kinds

Classification is **per assert**, never per library. An assert between two
internal calls inside a prover is not a precondition on the public API, and a
library with 29 test asserts has less outstanding work than one with two
production asserts.

- **`public`** — a precondition of a `pub fn` (or of a method on a type
  reachable from a `pub` declaration) that caller input can violate. In
  `ReleaseFast` this is a memory-safety or silent-wrong-answer hazard. **These
  must be typed errors.** `std.debug.assert` is never acceptable here.
- **`internal`** — an invariant no caller input can influence, on a non-`pub`
  path. `std.debug.assert` is acceptable only if it is a genuine invariant and
  not a "can't happen" claim about data that did reach it. Where a precondition
  turned out to be caller-reachable it was reclassified to `public` and fixed
  (e.g. `zig-bigint`'s `a.geqMag(b)` is a documented precondition of a
  magnitude-subtraction helper, not an input check).
- **`comptime`** — evaluated at compile time from a `comptime` parameter: a
  modulus, a non-residue, a width, a curve order. Cannot be violated at
  runtime by any input, because the input would have to be a compile-time
  value chosen by the programmer. `std.debug.assert` is appropriate; prefer
  `@compileError` when the message can be a compile error.
- **`fixture`** — lexically inside a `test` block. These assert facts about a
  specific curve constant, generator or golden value. They are test
  assertions, not validation, and must never be counted as API surface.

## Keying: never by line number

`path:line` rots on the first edit above it. The ledger uses two levels:

- **Enforcement** — `(file, kind, count)`. Coarse and maximally stable. It
  catches additions, removals **and** reclassifications, because a kind change
  moves a count from one bucket to another. This is what the gate compares.
- **Provenance** — `(file, enclosing_fn, kind, reason)`. Human-readable, no line
  numbers, so it survives a refactor. It is documentation for the next reader;
  it is not machine-matched.

Inserting an assert in the middle of a function shifts the occurrence indices
after it. That is *detected* rather than silently tolerated, which is the
intended failure direction: fail-closed, requiring a deliberate ledger update.

## Generation and propagation

`scripts/assert_scan.py` takes `--root` and emits the ledger JSON on stdout.

- **zig-algebra** runs it over `libs/` and commits
  `docs/assert_ledger.json`. `zig build assert-check` fails if the committed
  file differs from a fresh scan.
- **Other repos** vendor nothing and depend on nothing at build time. They run
  the scanner over their own tree, commit the generated `assert_ledger.json`
  alongside their gate, and record the **origin commit** of the zig-algebra
  scan that produced it. Their gate fails on a content mismatch. Drift becomes
  a visible diff in their CI rather than a silent rot.

The ledger records `schema`, `scanner_version` and `source_commit`. Bumping the
scanner or the convention changes the version, so a convention change shows up
as a deliberate, reviewable event instead of a silent reclassification of every
assert in a downstream tree.

The scanner is `python3` standard library only, so the gate needs no build step
and no new toolchain.

## Decisions on the review items this file settles

**Prime field for the `binary-field` sum-check test.** `binary-field` does not
depend on `zig-field`, and `algebra-traits` carries contracts only, so there is
no prime field available to that library's tests. Decision: **a local prime
field in the test tree, not a new inter-package dependency.** Two conditions,
because a hand-rolled fixture that shares bugs with the code under test is worse
than no fixture:

1. The constant must satisfy the `Sumcheck` contract, so it needs
   `BITS >= 128`. A 127-bit Mersenne prime is *not* eligible. The fixture
   therefore carries a comptime primality assertion, so a wrong constant is a
   compile error rather than a silently non-field.
2. The fixture must be proven against an **independent oracle** before it is
   used as a substrate: `add`/`sub`/`mul`/`inv` checked against native
   `u256` arithmetic modulo the prime over many random values, the same pattern
   `zig-field` uses against `u512`/`u1024` references.

Self-contained beats a dependency here: the commit does not wait on another
repo's release, and the manifest surgery would collide with the `fri` and
`pool.zig` dependency work.

**Consequence accepted:** the `add`→`sub` mechanical fix in
`interpolateCoeqs` and `lagrangeBasis` is a bit-for-bit no-op under
characteristic 2, because `BinaryField.sub` is defined as `add`. It lands with
the prime-field test in the same PR, so the generalized path is covered on
arrival rather than one refactor later.

**`pack.zig:lagrangeDenom` is not a third site.** It returns `z[1]`, the
coefficient of x in `Z_H`, which is characteristic-independent. Unchanged.

**`pcs.zig` beta_r is a different class.** `ℓ_j(t) = t + (1 + r_j)` becomes
`ℓ_j(t) = (1 - r_j) + (2·r_j - 1)·t`, which reduces to the current expression
exactly under characteristic 2 (`-1 = 1`, `2 = 0`). It is not an `add`→`sub`; it
changes a two-term expression into a three-term one and touches the sum-check
inner loop. It lands as its own commit with its own soundness note, because it
is the change with a real behavioural surface.
