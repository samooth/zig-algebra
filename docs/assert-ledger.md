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
   **(Superseded in part: `Prime128` now crosses the size gate itself and runs
   the secure `Sumcheck` entry point. See "The size gate and native-width
   testability looked like a hard conflict" below for why the "impossible"
   conclusion recorded here was wrong. `Prime31` is kept because its `u64`
   oracle is exact, which the 128-bit one is not.)**
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

## The size gate and native-width testability looked like a hard conflict

This section is kept because the conclusion it originally reached was **wrong**,
and the way it was wrong is the useful part.

`Sumcheck(F)`, `MlePcs(F, E)` and `CommittedMlePcs(F, E)` require
`F.BITS >= 128` (`MIN_SAFE_BITS`). That is a *security* threshold: below it the
4-bit challenges are grindable, so the entry points refuse. A prime-field
fixture wants the opposite -- a modulus small enough that an independent
reference fits in a native integer, so agreement is exact rather than modular.
A 31-bit prime leaves products at 62 bits and fits `u64`; a 128-bit prime needs
256.

The original reading was that this is a property of the design: the gap is 97
bits, no fixture can cross it, and the honest outcome is that the generalized
path is covered through the sound path's *arithmetic* (`SumcheckUnsafe`, same
inner loop, wider challenges) but never through its *entry point*. The argument
against closing it was that a `u256` reduction is "the same technique twice",
and therefore not an independent oracle.

**That argument does not hold, and the mistake was assuming the two techniques
would be alike.** `Prime128` (`p = 2^128 - 159`) closes the gate with:

| | field arithmetic | oracle |
|---|---|---|
| method | algebraic: `2^128 ≡ 159 (mod p)`, two folds through `u256` | native: `(@as(u256, a) * b) % p` |
| where the work happens | hand-written shifts and one conditional subtract | the language's own 256-bit multiply and remainder |

They agree or the differential test fails. A wrong fold constant, a missed
carry, a bad final subtraction and a wrong `K` all break the comparison, and
none of them can be masked by a matching error in the other column, because
neither column is written in terms of the other. The 5000 random products and
the exhaustive small-value sweep are what make this a witness instead of an
assertion -- and `p` is not merely *a* large prime: it carries a Pocklington
certificate (`F = 42113237 · 62826870453001 > √p`, witness `a = 2`, factors
verified by a 13-base Miller-Rabin that is deterministic below 2^64), so the
size gate means what it says. `2^128 - 1` would have passed the gate and been
composite, which is the trap this fixture exists to avoid.

## What the 128-bit field found that 31 bits could not

Wiring `Prime128` into `Sumcheck` is the first time a field of odd
characteristic has gone through the secure entry point in this workspace, and
it exposed a defect that the entire `binary-field` matrix is structurally
blind to.

**The sum-check fold was characteristic 2.** `sumcheck.zig` folded with
`a + t·(a + b)` in five places, which is `L_t(x) = (1-t)·f(x) + t·f(1-x)`
*only* under `1 - t == 1 + t`. Outside characteristic 2 it is a different
kernel from the one the verifier closes on, so **the verifier rejected honest
proofs**.

The direction matters, because the two failure modes are different claims and
only one of them is a security problem. This was a **false negative**: the
verifier closed on the correct linear kernel and the prover folded with the
char-2 one, so the verifier was *right* to refuse -- no forged proof was
accepted, and soundness was never in question. What was broken is
availability of the protocol: the prover could not produce a proof that
verified at all. The soundness break would have been the **opposite**
arrangement, the char-2 fold also sitting in the verifier's closing equality,
so that a kernel which is wrong over a prime field would have been *accepting*
claims about primes and the degree bound would have been meaningless. That is
why the bug was worth chasing past "it only affects a field nothing ships
with"; it is the reason it mattered, and not a description of what happened.

The fix is a single `foldLinear` helper used by all five sites. It is a
bit-for-bit no-op under characteristic 2, so all pre-existing proofs are
unchanged, and the generalized `Multilinear` is now the only definition of the
kernel in the package.

That is the **third** bug in one family: `interpolateCoeffs`'s `add`->`sub`,
`kernelTables`' `beta_r`, and now the fold. All three are invisible to a
characteristic-2 matrix, and all three were found by the same instrument. The
lesson is not "test prime fields" -- it is that **a fixture whose
discriminator is identically zero over the fields under test is a fixture that
cannot fail**, and each of these looked fully covered.

**And the fixture's own Miller-Rabin was wrong first.** The initial version
reused the field's `mulmod128`, which reduces modulo `PRIME`, to compute
Miller-Rabin powers for a factor `n` -- so it computed the powers modulo
`2^128 - 159` instead of modulo `n`, and reported every small prime as
composite (`isPrime(97) == false`). A separate `mulmodSmall`/`powmodSmall` for
arbitrary moduli fixed it, and `isPrimeSmall` now has a test pinning it against
known primes *and* known composites, Carmichael numbers included. A primality
oracle that has only ever been asked about the one constant it exists to
certify has never been shown to reject anything.

**Consequence:** anyone reading "the fixture tests the generalized sum-check"
can now mean the entry point, not just the arithmetic. `Prime31` still
instantiates `SumcheckUnsafe` and still asserts that `Sumcheck(Prime31)`
*rejects* the field; both remain, because the 31-bit fixture is the one whose
oracle is exact in `u64` and whose `u64` products are checked against native
arithmetic. The two fixtures are complementary: `Prime31` witnesses that the
`add`/`sub` distinction is real, `Prime128` witnesses that the secure path runs
at all.
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
