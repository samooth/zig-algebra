# zig-algebra — Agent Guide

## §0 Nothing Counts as Exercised Until a Test Calls It

**A declaration that no test calls is not exercised, no matter how many greps
find its name.** The thing that exercises code is a test calling it. Not
`refAllDecls`, not taking the address of a decl, not `installArtifact`, not a
`pub` on a public export surface, not compiling. A test that calls it.

Three tiers, and only the third is coverage:

| Tier | What it proves | Example that looked like coverage |
|------|----------------|-----------------------------------|
| compiles | the types line up | `addExecutable` on `src/main.zig`; a `pub` re-export in a root file |
| is collected | inline `test` blocks get analyzed and can run | `std.testing.refAllDecls(@This())` — necessary, still not a call |
| **is called** | **the behaviour ran and was asserted** | `test "..." { try f(x); }` |

**The specific trap in this workspace, and it is now closed: logic that lives
only in an example is never executed.** Each of the eight `libs/*/src/main.zig`
is its library's `example` executable, and the `test` step roots are
`src/root.zig` (or `src/lib.zig`) plus the separate `tests/` roots. Until
`b4fdfd2`'s successor wired them into `cross-check`, those files were reachable
by `cd libs/<name> && zig build install` and by nothing else — no root build
step, no CI job — so nothing in a `main.zig` was ever type-checked, let alone
run. That is where `std.debug.assert(!a.isZero())` survived the 0.5.0 P0 sweep
in `libs/rng/src/main.zig:44`: a reviewer's grep finds it, the suite never
touches it.

The gap was not hypothetical, it was structural, and closing it found more than
the assert. `libs/hash/src/main.zig` had been carrying a **hand-rolled field
interface** — 16 or 17 methods depending on the file, including an
`invChecked` that had never been executed — duplicating `zig-field` inside a
hash example, in a library that did not depend on `zig-field`. Two copies, one
in `root.zig` for the tests and one in `main.zig` for the demo, and they had
already diverged: the copy's `divChecked` returned `InverseOfZero` where the
library's returns `DivisionByZero`, and a test was asserting the copy's error
set. The fix was not a gate, it was deleting both copies and importing
`zig-field`; then `cross-check` compiles all eight examples for both foreign
targets, so the next fork of an interface in a demo fails the build instead of
waiting for a reviewer.

**The rule applies to the checking mechanism too.** A check that reports
success has to have been *observed failing* on an input that must fail. A gate
nobody has ever seen go red is decoration, and the most dangerous kind of
decoration is one that looks rigorous. Before trusting any gate -- a test, a
scanner, a smoke script, a CI job -- break it on purpose and confirm it says
so. `zig build assert-check` was proven by adding a `std.debug.assert` to a
`pub fn` and checking that the failure named the file and the line and exited
non-zero. The same applies to a regex over a log: feed it a string that should
match, and one that should not, and confirm both directions. A check written
by interpolating the expected value into the pattern proves nothing, because it
cannot fail.

**A test written against the implementation passes by construction. Write the
test against the specification — and a hash is never checked against itself.**

`zig-hash`'s `blake3.zig` was not BLAKE3, for the entire life of this
repository: a self-consistent compression, wrong in every digest it produced,
present in the first monorepo commit and in every published tag. It was
invisible for three reasons that are worth naming individually, because each is
its own trap.

The tests of `hash` checked determinism, round-trips and self-consistency —
exactly the class of test that cannot detect that the function is a different
function. A hash that disagrees with itself is not a hash; agreeing with itself
proves nothing about which hash it is.

The file *had* a test named `cryptographic hash known-answer vectors`, and that
is the worse case. Its Blake3 entry asserted `bd214b44…` for `"hello world"`
where BLAKE3 gives `d74981ef…` — **the "known" answer had been produced by the
implementation under test.** A self-generated KAT pins the bug and passes
forever while looking more rigorous than a determinism check. If a vector's
provenance is "we ran the code", it is not a known-answer vector.

And the nightly `fuzz` job could not have caught it either: it exercised fields
and FRI and never hashed anything.

The discipline already existed here — `SECURITY.md` documents KATs against
`py_ecc` for the pairings. It was simply not applied to the one primitive where
it mattered most. **A pattern that is written down but absent from the list is
not a control.** When a new primitive is added, the list is what has to change.

The two instruments, and they are different: hard-code the canonical digests from
an *independent* implementation so the test cannot drift with anything in the
tree, and differential-test against a different implementation over the inputs
where the structure lives (for BLAKE3 that is every length around 1024 and 2048,
because its chunk is 1024 bytes — a single-block vector never exercises the
counter, the cross-chunk chaining, or the parent tree).

**A checker that has only ever been asked about the one thing it exists to
certify has never been shown to reject anything.** The sharpest instance here
is an oracle. The first Miller-Rabin in `prime128.zig` reused the field's
`mulmod128`, which reduces modulo the field's own prime, to compute powers for
a factor `n` -- so it computed the powers modulo `2^128 - 159` instead of
modulo `n`, and reported *every small prime as composite*, including 97. It
looked entirely plausible, it was exercised on every run, and it was wrong.
`isPrimeSmall` is now pinned by a test that feeds it known primes **and** known
composites, Carmichael numbers included. Ask of any checker in this tree: what
input does it reject, and has anyone run that?

**The value of a check is not what it asserts, it is what can fail. A check
written against an implementation pins that implementation -- a digest, an
error name, a round trip, a signature -- and cannot tell "correct" from "what we
wrote".** This generalises the rule above; the five instances are listed with
their paths in `docs/requirements.md`, and each is a real one here:

1. a self-generated KAT — `hash` asserted a Blake3 digest it had produced itself
   for the whole life of the repository;
2. a round trip — `binary-field` round-tripped on every field in the package
   while `Sumcheck` rejected honest proofs over odd characteristic;
3. an error set — a test asserted the hand-rolled field's `divChecked` error,
   not `zig-field`'s, so porting the demo would have "proved" the library wrong;
4. a shape check — `assert-check`'s only possible failure is "the code changed
   shape", which makes it a drift detector, not a proof;
5. a declared surface nothing can reach — `divChecked` declares
   `DivisionByZero | InverseOfZero` and can only produce the first, and a
   declaration nothing can falsify is a claim nothing can test.

**A check that cannot fail is not a check. Give it an input that would break
it, or mark it as decorative and stop citing it.** The instrument is a mutation:
a mutation is a check asked a question it could answer wrongly, and the mutation
log in `docs/requirements.md` is what makes this operable rather than
rhetorical. A rule with no instances behind it is an intention — the two rows in
that table marked as intentions exist because they were written before the
instrument did.

**A check that produces no output is not a check that passed -- it is a check
that did not run.** This is a *different* failure mode from the one above, and
both rules are needed. A check that always passes is caught by breaking it and
watching it go red. A check that never runs is not caught that way at all: it
produces no output, and no output is indistinguishable from a check nobody
invoked. The discriminator is concrete: **report the check's output, not its
exit code.** An empty result is an unresolved question, not a pass, and it has
to be resolved before it is reported -- not after.

The instance that forced the rule: verifying the signature on the re-pointed
`v0.5.1` tag with `git tag -v v0.5.1 | rg 'Good signature'`. GPG in this
environment is localised, so it answers `Firma correcta`, the grep matched
nothing, and it exited non-zero -- a "failure" that was really a language
mismatch. It was one step from being reported as a tag that was not signed
correctly, or, read the other way, as a grep that had been silently
discarded. `git tag -v` had actually succeeded. Both directions of that check
are the same question asked about two different things: *what does this
checker reject, and has anyone run it?*

So: **an example calls the library, it does not re-implement it.** If example
code needs a field or a helper, import the tested one. If a `main.zig` grows
logic that a caller depends on, move it into the library where a test can
reach it. The same rule applies to a `pub` helper with no caller — that is
dead code wearing a public signature, and `zig build assert-check` is the
mechanical half of catching it (see `docs/assert-ledger.md`).

**An artifact exists when a consumer can fetch it, not when you created it. A
local tag is not a release, it is an intention.** This is the same shape as the
two rules above: a name promising something the thing does not deliver.

`v0.4.0`, `v0.5.0` and `v0.5.1` were all created locally and all three were
written about as though they were published — the changelog said `v0.5.0` was
"pushed anyway" and "possibly cloned" when `git ls-remote --tags origin` ends at
`v0.3.2`. The cost was not the mislabel. It was that the fiction **justified a
decision**: re-pointing `v0.5.1` was correct, but on a premise that was false,
and a future session reading the changelog would inherit the wrong reason along
with the right action.

The rule "never move a published tag" is unchanged and still right. What was
wrong was the premise underneath it. So before treating anything as shipped,
check what the remote actually has — `git ls-remote --tags origin` — and if the
changelog and the remote disagree, the changelog is the thing that is broken,
not the record. A correction committed on top is better than a rewrite: it
leaves the error visible, with its date and its cause, and a history in which
the error never happened leaves no trace that the criterion was ever applied to
a false premise.

**Write sequences, not states. A document that asserts a state goes stale the
moment the state moves; one that asserts a sequence does not.**

This changelog got the same paragraph wrong twice, in opposite directions.
First it said `v0.5.0` was "published with a broken build step", "pushed anyway",
"possibly cloned" — it had not been, and nothing of that release ever reached
anyone. Then the correction said `v0.5.1` "was never published" — true when
written, and false as soon as the tag was pushed, which is what happened next.
Both times the same cause: the sentence said *is* or *were* about something that
has a moment.

The version that survives is the ordered one: "`v0.4.0` and `v0.5.0` were created
locally and never left this repository; `v0.5.1` was re-pointed locally while
unpublished and was published on 2026-09-27 at `22df684`." That is still true in
a year. "v0.5.1 is not published" stopped being true in the next commit. **Give
the moment a date**, because "was published" without one is a state with the
same defect, only slower.

The same applies to any claim about the remote: `origin/main` is at `<sha>` *as
of <date>* beats `origin/main is up to date`, and the first goes stale visibly
instead of quietly.

**The corollary, and it is about ordering rather than wording: the audit goes
before the tag.** See "Releasing: the tag is the gate" for the rule and for the
two releases it explains — `v0.5.0` shipped a `zig build bench` that did not
compile, and `v0.5.1` shipped a CHANGELOG paragraph that was false. Both
because someone tagged before finishing to look. The natural order is tag, then
review, and it is the wrong order: the tag freezes the state, and a correction
that arrives afterwards lives in `main` while the published tarball keeps
telling the old story. The review has to be a step **of the release**, before
the photo.

That is also why `v0.5.1` can carry a stale paragraph and still be the right
release. It is sound in every other respect — 416/416 on three operating
systems, the gate green on the tag's own run — because everything *else* did
get reviewed before the tag. The defect was never "the tag was wrong"; it was
"the tag was taken before anyone looked".

**The audit goes before the *design*, not only before the tag.** The rule above is
about a photograph; this one is about the thing being photographed. For new
functionality, the sharp version is: **before writing it, decide who will
consume it and how they will know it is still in sync.** The natural order —
write the code, then ask who wants it — is how the last batch of divergences
happened, and it is not a coincidence that they were all *consumed* problems
rather than bugs.

The four questions, in order, and the code comes last:

1. **Who consumes this?** If the answer is a repository that already has a
   private copy of the same code, then the change is a convergence, not a new
   feature, and the consumer is a fork. Say so now, while the design is still
   cheap to change.
2. **How does that consumer know it did not diverge?** The mechanism has to
   exist before the code, not after. Here it is the CHANGELOG: a consumer reads
   it before bumping. Note what was missing last time — the fork *predated* the
   releases, so there was nothing to read, and the divergence had no channel.
3. **Who writes the first test of the contract?** The owner of the contract.
   If the consumer writes it, the contract is theirs and the two implementations
   only agree by accident.
4. **Then, and only then, the code.**

And the cheap corollary, which is the difference between *consumption* and
*forking*: **say what changed, in the artefact the consumer reads.** A library
README that lists only its current API cannot tell someone evaluating whether
to adopt it what it took to get here, or what will bite them if they start from
an older tag instead. That is not documentation polish — a forker from an old
tag inherits the whole delta with nothing to warn them, including any
interoperability change, because a changed wire format is invisible in an API
sketch.

This is not hypothetical here. The same shape has shipped three times in this
workspace: a `main.zig` assert that 0.5.0 missed, a public precondition in
`zig-bigint` that no library under test referenced, and an unconnected
diagnostic in a sibling repo's test file that was already written but never
wired to `buildTrace` — so the message existed and nothing could ever see it.
"Un gadget que nadie invoca nunca falla."

## Overview
Modular algebra library ecosystem for Zig 0.16.0. 17 libraries (workspace
version 0.5.1) covering fields, curves, pairings, and STARK building blocks.
No independent cryptographic audit exists; see SECURITY.md before making
security claims.

## Build Commands

```bash
zig build test        # Run all library tests (544 tests, ~1-2 min Debug)
zig build test -Doptimize=ReleaseFast   # Same 544 tests, seconds
zig build bench       # Run ReleaseFast benchmarks (field/curve/pairing/MSM/NTT)
zig build example     # BLS12-381 Schnorr signature demo
zig build stark       # STARK prover demo (Fibonacci over Goldilocks via FRI)
zig build wasm        # examples/wasm_fp.zig -> wasm32-freestanding
zig build wasm-pairing  # examples/wasm_pairing.zig -> wasm32-freestanding
zig build fuzz -Doptimize=ReleaseFast  # randomized property/fuzz runner
zig build assert-check             # assert ledger vs the tree (see §0)
```

`zig build` with no step runs the full test suite when
`-Doptimize=ReleaseFast` is set; in Debug it builds nothing.

Per-library: `cd libs/<name> && zig build test`. Only `field` and `curve` have
separate `tests/` roots; the root `zig build test` step compiles inline `src/`
tests only (544 total, and the per-library sum is 544: **the root step now runs the `tests/` roots too**).

> **How the count is derived**, because getting it wrong is how the previous
> figures drifted: since the gate fix, `zig build test` compiles **all 27 test
> binaries** -- the 17 library `src/` roots plus the 10 files under
> `libs/field/tests/` and `libs/curve/tests/` -- so the root total and the
> per-library sum are the **same number** and there is no aggregate to
> reconcile. Before that they were not: the gap was 118 tests in `field` and
> `curve` that the gate never opened, which is how a P0 in `Montgomery` sat in
> `main` behind an 11/11 green run.
>
> Measure it; do not carry it forward, and do not add deltas to a figure you have
> not re-derived. An earlier pass did exactly that and compounded a stale number
> twice.


## Code Conventions

### Naming
- Types: PascalCase (`Fp12Direct`, `MerkleTree`)
- Functions/methods: camelCase (`fromBytes`, `scalarMul`, `challengeField`)
- Constants: SCREAMING_SNAKE (`MODULUS`, `NUM_BYTES`, `XI`, `HASH_LEN`)
- Private helpers: `_` prefix optional; prefer module-private via non-pub

### Field API Contract
Every field type MUST expose:
```zig
pub const NUM_BYTES: usize;
pub fn zero() Self;
pub fn one() Self;
pub fn fromInt(x: anytype) Self;
pub fn add(a: Self, b: Self) Self;
pub fn sub(a: Self, b: Self) Self;
pub fn mul(a: Self, b: Self) Self;
pub fn neg(a: Self) Self;
pub fn eql(a: Self, b: Self) bool;   // or eq()
pub fn isZero(self: Self) bool;
pub fn toBytes(self: Self) [NUM_BYTES]u8;
pub fn fromBytes(bytes: []const u8) !Self;  // error on >= MODULUS
```
Optional but common: `inv()`, `sqr()`, `pow()`, `conjugate()`, `frobenius()`.

### Checked Inverses and Division (0.4.0 rule, extended 0.5.0)
Invertible operations come in pairs: a total legacy wrapper and a checked one.
New code MUST use the checked one.

```zig
pub fn inv(self: Self) Self;                 // legacy, total: inv(0) == zero()
pub fn invChecked(self: Self) error{InverseOfZero}!Self;
pub fn div(self: Self, other: Self) Self;    // legacy, total: x / 0 == zero()
pub fn divChecked(self: Self, other: Self) error{ DivisionByZero, InverseOfZero }!Self;
pub fn batchInv(inputs: []const Self, outputs: []Self) void;                 // legacy, total
pub fn batchInvChecked(inputs: []const Self, outputs: []Self) error{ LengthMismatch, InverseOfZero }!void;
```

Rationale: the old `std.debug.assert(!self.isZero())` was compiled out in
`ReleaseFast`, where the binary-GCD loop then never terminated. The total
wrapper is kept for source compatibility, and it propagates zero, which is
*not* a valid inverse. Do not "fix" a caller by asserting in a new place —
return a typed error instead. Apply the same split to length/dimension inputs:
`length` and `dimension` mismatches are `error.LengthMismatch` /
`error.InvalidDimension`, never asserts. A legacy total wrapper is not a
validation step, and `std.debug.assert` is now reserved for invariants that no
caller input can influence.

### Constant-Time vs Non-CT
- **CT required**: field inversion/mul on secret keys, EC scalarMul,
  signature operations.
- **Non-CT OK**: public parameters, transcript hashing, Merkle tree
  construction on public data, benchmark loops.
- Document CT status in function docstring when relevant.

### Error Handling
- Return errors instead of panicking in library code:
  ```zig
  pub fn fromBytes(bytes: []const u8) !Self { ... }
  ```
- Use `std.debug.assert` only for internal invariants that no caller input can
  influence; see the checked-inverse rule above for anything a caller can
  reach.
- Public APIs validate inputs and return typed errors.

### Memory
- Prefer stack allocation for fixed-size algebraic types (fields, points).
- Use caller-provided allocator for variable-size structures (trees, proofs).
  The proof stack does this: `fri.prove`/`fri.verify`, `kzg.commit`/`prove`,
  `Ipa.prove` and the binary-field PCS/sum-check all take an allocator and
  propagate `OutOfMemory` (no `catch unreachable`).
- All heap allocations must have matching `deinit(allocator)` methods.

### Comptime
- Use `comptime` blocks for modulus-dependent constants.
- Set generous eval quotas for heavy comptime work:
  `@setEvalBranchQuota(100_000_000);` (needed for legendre on 381-bit).
- Avoid runtime branching on secret data.

## Testing

- Every library has inline tests in source files AND a `test` step in its
  `build.zig`.
- Root `build.zig` aggregates all libraries via the `lib()` helper.
- Test naming: descriptive strings like `"mul distributes over add"`.
- Include negative tests: tampered data must fail verification.
- Counts (Zig 0.16.0, verified): root `zig build test` = 544; per-library
  `zig build test` totals sum to 544, which now **equals** the root total because the
  root step runs the `tests/` roots as well. Per-library totals: algebra-traits 5, bigint 23, binary-field 97, curve 98, field 87, fri 25, hash 19, kzg 6, linalg 11, merkle 19, ntt 15, pairing 58, parallel 2, poly 28, rng 25, serialization 15, transcript 11.
- Re-derive a count by running the suite and reading the runner's own summary
  (`zig build test --summary all`); do not carry a figure forward from a doc.
  The `field 85` / `507` pair above was wrong when written -- the runner
  reported 83 at the very commit that introduced it -- and stayed wrong for
  four releases because nothing re-measured it.

### What the Gates Do and Do Not Cover

`zig build assert-check` enforces the §0 rule *partially*: it fails on a new
`std.debug.assert` the ledger does not account for, and specifically on a new
one in a `pub` entry point. It does **not** detect a `pub fn` with no caller
and no assert — "declared but never called" is currently unenforced, and the
`main.zig` case is the one that bit three times. Treat the ledger as the
mechanical half of the rule, not the whole of it.

### Property-Based Testing Pattern
For ring/field axioms, generate random elements and verify:
```zig
test "property: associativity" {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (0..1000) |_| {
        const a = F.random(rand);
        const b = F.random(rand);
        const c = F.random(rand);
        try testing.expect(a.add(b).add(c).eql(a.add(b.add(c))));
    }
}
```

## Requirements, and the audit behind a rewrite

`docs/requirements.md` holds the table: what each library has to satisfy, what
holds each claim up, and what it is meant to catch. A row that cannot name the
test that sustains it is marked as an intention, because an intention reads
exactly like a requirement inside a table and the difference is only visible if
the table says which is which.

It also carries the per-library audit — external vectors, a mutation seen
failing, and fork history. **Check it before proposing a rewrite.** The question
is not whether a library is large; it is whether anything could tell you the
rewrite had not broken it. A rewrite without the requirements and the
instruments written down first reproduces the fork with extra steps, which is
what happened to `binary-field` and its fork for three releases.

## Adding a New Library

1. Create `libs/<name>/build.zig` + `build.zig.zon` + `src/root.zig`.
2. Wire into root `build.zig` using the `lib()` helper with imports list.
3. Update README.md architecture table.
4. Update DESIGN.md dependency graph if new edges exist.

## Versioning

Root `build.zig.zon` carries the workspace version (`0.5.1`); each library has
its own independent semver in `libs/<name>/build.zig.zon` (currently
`0.1.0`–`0.5.0`). Bump the library version for API changes, the workspace
version for ecosystem-level releases, and record both in `CHANGELOG.md`.

## Known Gaps (do not paper over these in docs)

- `inv(0) == 0` and `x / 0 == 0` are the **legacy total** behaviours of
  `inv`/`div` in `zig-field` (both backends plus both extension towers) and of
  `inv` in `zig-binary-field` (`BinaryField`, `TowerField`). Zero is not an
  inverse, so the legacy result must never be read as "invertible". Document
  `invChecked` / `divChecked` / `batchInvChecked` as the APIs new code uses.
- `Sumcheck(F)` in `zig-binary-field` requires `F.BITS >= 128`;
  `MlePcs(F, E)` and `CommittedMlePcs(F, E)` require `E.BITS >= 128` for
  their challenge field and return `error.FieldTooSmall` otherwise.
  `SumcheckUnsafe` / `MlePcsUnsafe` / `CommittedMlePcsUnsafe` skip that check,
  keep the historical 4-bit on-chain challenge format, and are **not sound**
  against a grinding prover. Label them toy/test-only everywhere.
- `Ipa.verify` in `libs/field/src/ipa.zig` is a stub (`error.Unsupported`);
  only `Ipa.verifyWithCommitment` works, and IPA challenges are a local
  SHA-256 of `(L, R, round)` — not a `zig-transcript` Fiat-Shamir session.
- `kzg.Setup.generate` is a synthetic setup (tests/dev only).
- Pairing, curve scalarMul and field inversion are not constant-time.
- `zig build bench` numbers are machine-specific; label them as indicative.
- No independent cryptographic audit exists for any library.

## Common Gotchas (Zig 0.16)

- No `std.time.Timer` and no `std.time.nanoTimestamp()` in Zig 0.16. Use
  `zig-parallel`'s portable clock: `@import("zig-parallel").timing.nowNs()`
  (QPC on Windows, `std.c.clock_gettime(CLOCK_MONOTONIC)` with libc,
  `std.os.linux.clock_gettime` bare-metal). Do NOT write Linux-only
  timing inline in shared code.
- No `std.io.getStdOut()`; use `std.debug.print` for output.
- Blake3 is at `std.crypto.hash.Blake3`, not `std.crypto.hash.blake3`.
- ArrayList needs explicit allocator at method calls, not construction.
- Struct fields need trailing commas.
- Error unions: `error{X}!T` syntax (not `T!X`).

## Releasing: the tag is the gate

**Never move or delete a published tag.** It is signed and may already be
cloned. If a released commit is wrong, cut the next patch release and say so in
the CHANGELOG — a broken build in a tagged release is a one-line fix, and
rewriting history that someone already fetched is worse than publishing 0.5.1
with a line. This is not hypothetical: `v0.5.0` (c47b4b0) shipped a
`zig build bench` that did not compile, and the fix is `v0.5.1`.

**The audit goes before the tag, not after. Tagging first is the wrong order,
and it is the whole order.** A tag freezes state; a lie corrected afterwards
lives in `main` while the published tarball goes on telling it. Both of this
repository's bad releases are that mistake, not different ones:

| release | shipped | why |
|---|---|---|
| `v0.5.0` | a `zig build bench` that does not compile | tagged before the build was looked at |
| `v0.5.1` | a CHANGELOG paragraph that was false | tagged before the paragraph was audited |

`v0.5.1` is otherwise sound — 416/416 on three operating systems, the gate green
on the tag's own run — because for everything *else* there had been a review
before the tag. The defect is not "the tag was wrong", it is "the tag was taken
before anyone looked". So the review is a step **of the release**, before the
photo, and a release is not ready until it has happened. It has no name in the
build system because nothing automatable can stand in for it: `on.push.tags`
fires after the tag exists, which is detection, not prevention.

What that review has to include, learned the hard way: the changelog against
`git ls-remote --tags origin`, the build steps, and the claims in the docs. Not
the tests — CI does the tests, and it does them after the tag too. The things CI
cannot do are the ones where the artifact lies about itself.

**A tag is a photograph.** A correction committed after it does not reach the
photograph; that is what a tag *is*. The cost is paid with the next release
**that has to exist for some other reason** — not with a release manufactured
for a changelog, which is the churn the note above calls churn. `v0.5.1` is
frozen at `22df684` with the stale paragraph inside it, and that stays true
until something else needs a version. Writing the correction on top is all that
can be done without rewriting published history, and it is enough: a reader of
`CHANGELOG.md` on `main` is told the snapshot differs.

**Push `main` first, and the tag only once the run for that SHA is green.** The
order is not stylistic and it is not a deadlock: CI only runs on what is on the
remote, so a commit that is not pushed has no run to wait for. Concretely —
push `main`, read the run for that exact SHA, and if it is green, push the tag.
The tag push re-runs CI by way of the trigger, and that re-run is *detection
after the fact*; the push of `main` first is the prevention. `main` alone is
not a sufficient precondition, because the failure mode is shipping a commit
whose CI was red at the time and green-looking later on a different SHA.

`on.push.tags: ['v*']` is in the tree, so once this lands a tag push runs
`fmt`, `assert-ledger`, `test` on three OSes, `release-smoke`, `benchmark`,
`fuzz`, `stark-example` and both wasm smokes. That trigger is **detection, not
prevention**: the tag already exists publicly by the time the run starts. The
rule above is the prevention; the trigger makes a violation visible instead of
silent. That trigger is now proven — `v0.5.1` was the first tag push in this
repository, and its run went green on all three operating systems at 416/416
each. It is still detection, not prevention: that run is why we know the gate
works, and it is not why the tag was correct.

**The remote is the owner's.** `main` and the tag namespace are pushed by a
person, not by an agent in a working tree. Do not push. Hand over the commit
SHA and the list of what was verified, and let them decide when it ships. A
tree that is green locally is a reason to offer, not a reason to push -- and
a GPG failure is a reason to stop and say so, never a reason to commit
unsigned into a repository whose history is signed.

The gate covers every buildable target. Before 0.5.1 it did not: there was no
`tags` trigger, `zig build fuzz` was in no job at all, and the `benchmark` job
carried an "informational only" comment that read as if a red job there did not
matter. It did matter — a compile error is not an informational number.

## Signing Commits

All commits GPG-signed with key `B59CBA1AED05C03737146912E791C5B7A60B5A80`.
If signing fails with tty error, warm agent cache first:
```bash
echo test | gpg --clearsign > /dev/null && git commit -S ...
```
