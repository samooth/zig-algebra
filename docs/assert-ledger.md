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

**Prime field for the `binary-field` test matrix.** `binary-field` does not
depend on `zig-field`, and `algebra-traits` carries contracts only, so there was
no prime field available to that library's tests -- and every field it
instantiates over is binary, which is precisely the condition under which
`a - b` and `a + b` cannot be told apart. Decision: **a local prime field in
the library's own tree, `prime_fixture.zig`, plus `SumcheckUnsafe` over it.**

Two things this decided that were not obvious beforehand:

1. **Not a large prime.** The instinct was "the secure `Sumcheck` needs
   `BITS >= 128`, so use a 128-bit prime". Two traps in that. A 127-bit
   Mersenne prime fails the size gate; and `2^128 - 1` *passes* it while being
   composite, `2^128 - 1 == (2^64 - 1)(2^64 + 1)`. So the fixture carries an
   exact comptime primality assertion by trial division -- not extra paranoia,
   the thing that makes the size gate mean anything -- and uses a 31-bit prime
   with `SumcheckUnsafe`, which is the documented API for small fields and
   exercises the identical `interpolateCoeffs` / `Multilinear.eval` arithmetic
   that needed generalizing. The 31-bit value is chosen because products leave
   headroom in `u64`, so the oracle is exact rather than modular.
2. **A witness, not a smoke test.** Each test first asserts that the
   characteristic-2 form and the general form *disagree* on its input, and only
   then asserts that the implementation returns the general one. Without the
   first half the test would still pass over a binary field and prove nothing.

Self-contained beats a dependency: the commit does not wait on another repo's
release, and the manifest surgery would collide with the `fri` and `parallel`
dependency work.

**What the fixture found that the binary-field matrix could not.** Instantiated
over a prime field, the Lagrange interpolation of `3 + 5x` returned `3 - 5x`:
every coefficient above the constant sign-inverted, because the basis
recurrence divided by `x + x_j`. Over GF(2^m) that is the same divisor, so
nothing in the matrix could tell. It also showed that `PackedMle` does not
round-trip over a prime field with `sub` either -- its specialization is not
confined to the one `add` -- so `PackedMle` is left characteristic-2 and says
so, rather than being half-generalized into something that looks general.

**Consequence accepted:** the mechanical `add`->`sub` fix in
`interpolateCoeqs` is a bit-for-bit no-op under characteristic 2, because
`BinaryField.sub` is defined as `add`. It lands with the prime-field
witnesses in the same PR, so the generalized path is covered on arrival rather
than one refactor later.

**`pack.zig:lagrangeDenom` is not a third site.** It returns `z[1]`, the
coefficient of x in `Z_H`, which is characteristic-independent. Unchanged.

**`pcs.zig` beta_r is a different class, and is done.** `ℓ_j(t) = t +
(1 + r_j)` becomes `ℓ_j(t) = (1 - r_j) + (2·r_j - 1)·t`, which reduces to the
current expression exactly under characteristic 2 (`-1 = 1`, `2 = 0`). It is not
an `add`->`sub`: it changes a two-term expression into a three-term one and
touches the sum-check inner loop, which is why it got its own commit and its
own soundness note.

The implementation does not build the slope, because the argument is always a
hypercube bit: it needs only the two values on the line, `l_j(0) = 1 - r_j` and
`l_j(1) = r_j`. **Soundness is unchanged.** The summand is degree 1 in each
variable under either expression, so the sum-check's degree bound -- the thing
the argument for security actually rests on -- is identical, and the `k+1`
multilinear summands the composition counts are unchanged. The change makes an
implicit characteristic-2 dependency explicit; it does not alter what is proved.

`prime_fixture.zig` checks the two forms *disagree* over a prime field before
asserting the general one is returned, so the test cannot pass vacuously. The
discriminator is `2·r_j`, which is identically 0 in characteristic 2 -- which is
also why the binary-field suite could never have noticed either way.

`polynomial.zig`'s test vector in the `extend` test is a statement about the
field, not a characteristic-2 claim, and is left alone.

## The size gate and native-width testability are in direct conflict

This is a structural property of the problem, not an oversight in
`prime_fixture.zig`, and rediscovering it costs a day, so it is written here.

`Sumcheck(F)`, `MlePcs(F, E)` and `CommittedMlePcs(F, E)` require
`F.BITS >= 128` (`MIN_SAFE_BITS`). That is a *security* threshold: below it the
4-bit challenges are grindable, so the entry points refuse.

For a prime-field fixture to be a trustworthy witness it must be
*checkable*: the field's own arithmetic and an independent reference must agree
exactly, not modulo something. The only way to get an exact reference is to
compute in a native integer wide enough that products do not overflow. A
31-bit prime leaves products at 62 bits, which fits `u64` comfortably, so the
oracle is exact. **A 128-bit prime does not: its products need 256 bits, so the
"independent oracle" has to be a `u256` reduction or a second Montgomery
implementation — which is no longer independent, it is the same technique twice.**

So the two requirements are in direct tension:

| Requirement | Wants |
|---|---|
| `Sumcheck(F)` accepts it | `BITS >= 128`, i.e. arithmetic in 256 bits and up |
| An exact independent oracle | arithmetic in ≤ 64 bits, i.e. `BITS <= 31` |

**Any field small enough for the arithmetic to be exact in native width is below
`MIN_SAFE_BITS`.** `M31` at 31 bits is the ceiling of what this workspace can
witness exactly, and it is 97 bits short of the gate.

### Two consequences, both true

1. **The generalized path has no coverage through the secure entry point.** The
   `prime_fixture.zig` tests instantiate `SumcheckUnsafe`, and one of them
   asserts that `Sumcheck(Prime31)` *rejects* the field. That test is honest
   about the trade, but nobody has run a ≥128-bit prime through the secure
   `Sumcheck` and checked the generalized Lagrange arithmetic there. With the
   current fixture that is not possible.
2. **The gap is a property of the design, not of the fixture.** Closing it means
   building a `u256` prime field and a reference that is independent of it —
   realistically a `BigInt`-based oracle from `zig-bigint`, which
   `binary-field` does not currently depend on.

What the fixture *does* establish, and it is not nothing: the arithmetic is
character-agnostic. The generalized `interpolateCoeffs`, `Multilinear.fold` and
`kernelTables` are exercised on a field where `sub` is not `add`, which is the
property that a binary-field matrix structurally cannot observe. The
`SumcheckUnsafe` variant runs the identical arithmetic in the identical inner
loop; only the challenge width differs.

Anyone reading "the fixture tests the generalized sum-check" should read it as
"through the sound path's *arithmetic*", never as "through the sound path's
*entry point*". The code itself already marks that distinction: the secure
variant returns `error.FieldTooSmall`, and the fixture's test says so.

## A correctness fix is not a release gate

Worth stating separately, because the instinct after a validation sweep is to
treat a green run as a licence to cut a release. A correctness fix is
orthogonal to the release gate in both directions.

- A green run does not authorise a tag. The gate is
  `on.push.tags: ['v*']` plus the AGENTS.md rule that the tag is pushed only
  after CI is green on that exact commit. What a green run establishes is that
  *this* work does not regress the build; whether the tree is a release is a
  separate decision, and per the rule above the remote's owner makes it.
- A tag pushed without a gate having ever run is unproven. The first real tag
  is the gate's own test run, and it should be read rather than assumed.

The reason this is written down: during the 0.5.0 work the natural reading of
"all green" was "ready to cut 0.5.0", and that is how a tag came to point at a
commit whose `zig build bench` did not compile.
