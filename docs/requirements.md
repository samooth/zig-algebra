# Requirements

What a library in this repository has to satisfy, and what holds each claim up.

## How to read this

A row is a **requirement** only if it points at something that can fail. Three
columns carry that:

- **vive en** — where the property is enforced, with a path and a line where
  there is one.
- **lo sostiene** — the test, gate or job that would report it broken. A row
  that cannot name one is not a requirement. It is an **intention**, and it is
  marked as such, because an intention reads exactly like a requirement in a
  table and the difference is only visible if the table says which is which.
- **se rompe si** — the concrete failure this is meant to catch, not a
  restatement of the requirement.

The third question in [the audit](#auditoría-por-librería) is the one this
table exists to answer, and it was added after a fact: a test that has never
been seen to fail has not demonstrated that it carries anything.

Everything here was verified by running it, at the commits cited. Where a
figure could not be established it says so rather than rounding up.

## The value of a check is not what it asserts, it is what can fail

A check written against an implementation pins that implementation, whatever it
is. A digest, an error name, a round trip, a signature — the check cannot tell
"correct" from "what we wrote". Five instances of it, all in this repository and
all with the path where each can be read:

1. **A self-generated known-answer vector.** `libs/hash/src/root.zig` asserted
   `bd214b44…` for `"hello world"`, a digest this implementation had produced
   itself; BLAKE3 gives `d74981ef…`. It was named
   `cryptographic hash known-answer vectors`, and it pinned a non-BLAKE3 for the
   whole life of the repository.
2. **A round trip.** `binary-field`'s tests round-tripped on every field in the
   package while `Sumcheck` rejected **honest** proofs over any
   odd-characteristic field. A round trip is consistent by construction.
3. **An error set.** `libs/hash/src/root.zig` asserted `InverseOfZero` from
   `divChecked` — the hand-rolled field's answer, not `zig-field`'s, which is
   `DivisionByZero`. A test that fixes the wrong error is worse than no test: it
   turns the mistake into the contract, and the first person to port the demo
   would have seen the test fail and concluded the library was wrong.
4. **A signature-shaped check.** `zig build assert-check` fails when a
   `std.debug.assert` appears that the ledger does not account for. Its only
   possible failure mode is "the code changed shape". That makes it a drift
   detector, not a proof of correctness.
5. **A declared surface no input can reach.** `libs/field/src/field.zig:651`
   and `:1354` declare `divChecked` as returning
   `error{ DivisionByZero, InverseOfZero }`, but `invChecked` fails only on a
   zero value and `divChecked` has already returned before calling it, so the
   `InverseOfZero` arm is unreachable in both backends. It is indistinguishable
   from a reachable, correct arm to any test, because telling them apart needs
   the input that does not exist. `AGENTS.md:286` documents the two-error set,
   so doc and implementation agree: a dead arm *by contract*. It is not narrowed
   here — narrowing a public error set is an API break.

The fifth is not a check, which is why the rule has to be stated wider than
checks. **A declaration is a claim about behaviour, and a claim nothing can
falsify is a claim nothing can test.**

### What to do when a check cannot fail

Two options, and picking neither is not one of them: give the check an input
that would break it, or mark it as decorative and stop citing it. The mechanism
is a **mutation** — a mutation is a check that is asked a question it could
answer wrongly — and the [mutation log](#mutations-watched-failing) is what makes
this rule operable rather than rhetorical. A rule with no mutation log behind it
is an intention, and this table has two rows marked as intentions precisely
because they were written before the instrument existed.

## Requirements

| # | requisito | vive en | lo sostiene | se rompe si |
|---|---|---|---|---|
| 1 | A hash is validated against **external** canonical vectors, never against its own output | `libs/hash/src/root.zig` — "cryptographic hash known-answer vectors" and "Blake3 known-answer vectors, canonical" | 45 BLAKE3 vectors from an independent implementation, plus blake2b/blake2s/sha3 vectors checked against `hashlib` | A vector whose digest was produced by the implementation under test. It pins the bug and passes forever while looking rigorous — which is what the Blake3 entry in that test was, for the whole life of the repository |
| 2 | A hash is differential-tested against a different implementation over the inputs where the structure lives | `examples/fuzz_runner.zig`, nightly `fuzz` job | 3 literal vectors + 17 lengths differential against `std.crypto.hash.Blake3`, including 1023/1024/1025 and 4095/4096/4097 | A single-block vector. BLAKE3's chunk is 1024 bytes, so one short vector never reaches the counter, the cross-chunk chaining, or the parent tree |
| 3 | A check has to be able to be **seen failing** | `examples/fuzz_runner.zig`, and the mutation log below | Watched mutations, not assertions of intent | A gate that was only ever run green. "It passes" is not evidence that it would have caught anything |
| 4 | A check that produces no output is not a check that passed | `.github/workflows/test.yml` — `cross-check` uses `--summary all` | Log names the 34 binaries (17 libraries × 2 targets) | A job that is green, ran for a minute, and says nothing about what it verified. A duration is not a claim about coverage |
| 5 | A round trip proves consistency, not correctness | Nowhere — this is a **known gap** and it is an intention, not a requirement | Nothing yet, and the absence is the point: **until an instrument exists that detects a self-consistent round trip, no round trip in this repository proves correctness** — including every STARK one | The characteristic-2 fold bug: `binary-field` round-trips passed on every field in the package while `Sumcheck` rejected **honest** proofs over any odd-characteristic field. It took a 128-bit prime fixture to see it. That is a bug in an instrument, not a bug in one library, and it generalises |
| 6 | A test written against the implementation passes by construction | `AGENTS.md` §0 | The 45-vector KAT, which is pinned to literals | Any test whose expected value came from running the code. See requirement 1 |
| 7 | A field large enough to be sound is required by the protocol, not by taste | `libs/binary-field/src/sumcheck.zig` — `MIN_SAFE_BITS = 128` | `error.FieldTooSmall` at 128 bits, and `Prime128` crossing it | A field that is 128 bits without being prime: `2^128 - 1` passes the size gate and is composite, `2^128 - 1 == (2^64 - 1)(2^64 + 1)` |
| 8 | Primality of a fixture's modulus is **proved**, not asserted | `libs/binary-field/src/prime128.zig` — Pocklington certificate | `certifyPrimality()` re-derives `F > √p`, witness `a = 2`, and each prime factor of `F` by a 13-base Miller-Rabin; `isPrimeSmall` is pinned against known primes **and** known composites | A size gate standing in for primality. Also: the first Miller-Rabin here reused the field's `mulmod`, so it computed powers modulo the field's prime instead of modulo `n` and called every small prime composite, `isPrime(97) == false` |
| 9 | An `add`/`sub` distinction is exercised over a field where they differ | `libs/binary-field/src/prime_fixture.zig`, `prime128.zig` | Tests assert the characteristic-2 form and the general form **disagree** on the input, then that the general one is returned | A characteristic-2 test matrix. There the discriminator `2·r` is identically zero, so no test there can distinguish `x - y` from `x + y` |
| 10 | A generalized expression must reduce to the characteristic-2 one where that is correct | `libs/binary-field/src/sumcheck.zig` — `foldLinear` | Single shared definition at all five call sites; the 96 `binary-field` tests pass unchanged, which is the proof it is a no-op in char 2 | Copying the kernel instead of sharing it. The drift happened because five sites had five copies and nothing to keep them in step |
| 11 | Every module that is built **in any target** is also type-checked there | `build.zig` — `cross_register`, `libs_with_example` | `zig build cross-check` compiles the eight example executables for both foreign targets, 16 artefacts, and CI runs the same step | `libs/rng/src/main.zig:44` carried a `std.debug.assert` for the whole life of the repository because no CI job compiled that file. **This row was unsatisfied when the table was written and was closed by deleting code rather than adding a gate** — see the audit |
| 12 | A document asserts a **sequence**, not a state | `AGENTS.md` §0 | — | "the hash was broken" expires when the state moves. It was wrong twice in opposite directions: `v0.5.0` was "published" and had not been, then `v0.5.1` was "not published" and had |
| 13 | The audit happens before the tag, not after | `AGENTS.md`, "Releasing: the tag is the gate" | `v0.5.2` shipped with the fix in it; `v0.5.1` shipped a false CHANGELOG paragraph because the tag was taken before anyone read it | Tagging first, which is the natural order and the wrong one. A tag is a photograph; a later correction does not reach it |
| 17 | A rejection is **distinguishable** from a value | **Satisfied** — the four totals still fail open, and each one now says so | `bn254_tower: an off-subgroup G2 point is reported by all four checked halves and hidden by all four totals` | Found **not satisfied**, and the failure was *open*, which is worse than a missing check: three sites rejected by returning `Fp12T.one()` from a signature declared `Fp12T`, so the failure mode was in the type. Closed additively — `millerLoopChecked`, `pairingChecked`, `pairingSparseChecked`, `pairingDenseChecked`, each `error{G1NotInSubgroup, G2NotInSubgroup}!Fp12T`, no total signature changed. The totals keep failing open by design, with the loss (an identity indistinguishable from a legitimate one) in each doc comment, and each names its checked half |
| 18 | A public method nobody calls has a body nobody has looked at | **Not satisfied** — and finding them is a *reachability* problem, not a coverage one | The instrument is a declared list of methods that must be instantiated, not a metric. Measured 8 of 104 in `field.zig` and `extension.zig` at the date of this entry, after the `hash` fix | `rg '\.hash\('` across `libs/` and `examples/` returns zero. Zig only analyses reachable code, so four public `hash` bodies had never been looked at by the compiler and all four failed to compile. A suite of 421 green tests cannot see this, and no additional coverage test would have found it: the bodies were not in the graph. **The class was already half-catalogued** — `hash2` and `initOsRandom` appear in `Known Limitations` — and one of the catalogued methods did not compile, which means the classification was never re-read, not that the class is new |
| 19 | A module taking a `comptime modulus` is tested at the parameter values that break it | **Not satisfied** — and the case is not hypothetical | The instrument is a modulus with `bitLength == 64 * n`, i.e. headroom 0. It is the most obvious one because every predefined in the workspace evades it: BN254 is 254 bits, BLS12-381 is 255, and **`Montgomery` is not exercised by any predefined at all** | `Montgomery` had **no test in this repository that reached it** — `Montgomery(` appears nowhere outside `field.zig` and `montgomery.zig`. A 421-test suite cannot see this however long it runs: the nine predefs are the same suite under other names, and none of them goes through the type. Found by external review, not by mutation — the three commits that touched `montgomery.zig` changed other things, and `addP` is byte-identical since the first commit |
| 20 | The automated gate executes the tests that would catch a wrong answer in the public surface | **Not satisfied** — and this is the fourth instance of the same blindness | The instrument is the list of roots CI actually runs. `.github/workflows/test.yml:52` runs **only** `zig build test`, and the root step compiles each library's inline `src/` tests alone, so `libs/field/tests/` **never runs in CI at all** | ZA-2026-004 is in the tree with a regression test that fails, and the root build still reports **421/421 green**, because the test lives in a root the gate does not execute. A P0 in the public API of `libs/field` cannot turn this repository's only automated gate red. The same gap was already patched around once for an unrelated reason: the Windows compile error in `libs/rng/src/csprng.zig` was invisible to the Linux root build (`test.yml:86-87`) and was given its own step |
| 14 | A transcript challenge is derivable by a third party from the statement alone | **Not satisfiable as written** — and this is a decision that is missing, not coverage that is missing | No instrument exists and none can: `zig-transcript` implements no published specification, so there is nothing external to compare against. The missing decision is the owner's, and the route now has a named target with the best available provenance: `draft-irtf-cfrg-fiat-shamir` (revision `-03`, 17 August 2026), which specifies the duplex sponge, the codecs and the NARG serialization with 39 published vectors in Appendix B — including field-element challenge decoding (B.2.11), session-identifier derivation (B.2.10) and a complete **sumcheck over Mersenne31** transcript (B.2.12), where Mersenne31 is this repository's `Prime31`. What is missing is not an instrument but the owner's decision, plus a mapping argument for FRI-shaped transcripts, for which the draft has no vector (STARK and FRI appear zero times in it) | The third Fiat-Shamir property is unsatisfiable by construction, and a `expected` written here would be instance 1 of this table's own rule wearing the appearance of a vector. A mutation confirms the gap: adding 1 to the first byte of the finalised digest changes every challenge and all 10 tests pass; the ten tests are properties any deterministic function satisfies, a counter included. **This row is not a coverage debt to be paid later — it says which decision is outstanding** |
| 15 | Who consumes a new capability, and how they learn it has not diverged, is decided **before** it is written | `AGENTS.md` §0 | The circular-domain work has not started; this row is why | Writing the code and then asking who wants it. That is how `binary-field` diverged from its fork for three releases, and the interoperability bug in the Merkle leaf hashing was invisible from both sides because a round trip is self-consistent |
| 16 | Every input guard is exercised by a test that would fail without it | **Partially satisfied** — see the mutation log | Exercised now: `merkle/src/merkle_tree.zig:26`, `bigint/src/gcd.zig:83`, `algebra-traits/src/root.zig:92`, `bn254_tower.zig` checked halves. Still not: `kzg/src/root.zig:166-167` (on-curve, subgroup) | Disabling the two `kzg` guards leaves every test green. **None of them is wrong** — they are untested, and a guard nobody exercises is a claim nothing can falsify. Correctness and coverage are separate findings and conflating them is its own error. `kzg` is the sharpest: **two** consecutive `return false` guards, six tests, and both are dead code. Note the contrast with requirement 17: the `bn254_tower` guards looked the same but were *live* and failed open — which is why "untested" is not a single finding. The reachability form is recorded separately below, because "untested" and "never analysed by the compiler" are different failures |

## Mutations watched failing

Requirement 3 is only worth something with the list, so here it is. Every row
was produced by breaking working code on purpose and reading the failure.

| what was broken | gate | what it said |
|---|---|---|
| BLAKE3 ROOT flag in the wrong place | fuzz | `FAIL BLAKE3 vs stdlib at len=1025` |
| BLAKE3 block buffer not zeroed after a full block | fuzz **and** the 45-vector KAT | `FAIL … at len=65`, `Blake3 KAT failed at len=65` |
| `?windows.HANDLE` reverted to `windows.HANDLE` | `cross-check` | `expected type '*anyopaque', found '@TypeOf(null)'` |
| `cyclotomicSqr` coefficient 2 → 1 | `pairing` tests, incl. the `py_ecc` KAT | 6 tests fail, incl. `cyclotomicSqr matches generic sqr` |
| `poly` degree guard `>` → `>=` | `poly` tests | 2 tests fail |
| `serialization` flag guard `1` → `2` | `serialization` tests | 1 test fails |
| `ntt` non-power-of-two guard removed | `ntt` tests | 1 test fails |
| `linalg` `NotSquare` `!=` → `>` | `linalg` tests | 1 test fails |
| **G2 subgroup guard removed from `pairingSparseChecked`** | **caught — `bn254_tower: an off-subgroup G2 point is reported by all four checked halves and hidden by all four totals` fails at `bn254_tower.zig:625`** |
| **`Montgomery` instantiated with a zero-headroom modulus** | **the inverse is wrong and nothing asked: `montgomery: a * a^-1 must be 1, and headroom is what makes it true` reports secp256k1 `0 correct, 16 WRONG` against BN254 `16/16` and BLS12-381 `16/16`** |
| **`challengeFieldChecked` implemented through the reducing decoder** | **`transcript: challengeFieldChecked uses the rejecting decoder, challengeField does not` fails.** The gate is a *synthetic field* whose `fromBytes` is total and returns a fixed value, which makes the two paths distinguishable **by construction** — a constructed witness, not a sample. That is the whole point: the real difference between a reducing and a rejecting decoder is **unobservable by sampling** (`Prime128`: a draw lands in `[p, 2^128)` with probability 159/2^128; `Prime31`: the skew falls on two values out of 2^31), so a counting test could never have seen it and would have been decoration. The first version of this test argued from "255 of 256 draws land in range" and was itself decorative; it was replaced |
| **Four public `hash` bodies in `field`/`extension`, and one broken re-export** | **not a mutation finding — a *reachability* one: there was nothing to mutate in code outside the analysis graph.** The gate is the compiler, now reached: `field.zig:663,1368` and `extension.zig:227,644` failed with `no field or member function named 'wrapping_mul' in 'u64'`, and reverting one `*%` brings the error back at the same line. `lib.zig:31` re-exports `predef.BLS12_381_Fp2`, which `predef/bls12_381.zig` does not define |
| **`kzg` on-curve guard disabled** | **nothing — 6/6 pass, and it is *dead code*** |
| **`kzg` subgroup guard disabled** | **nothing — 6/6 pass, and it has *no reachable witness*** |
| **`merkle` `validPathIndex` `<` → `<=`** | `merkle: a path index at or past the leaf count is rejected` |
| **`transcript` `digest[0] += 1` after the final** | **nothing — 10/10 pass, and there is no vector to write** |
| **`bigint` negative-modulus guard removed** | `modInv rejects a negative modulus and a zero modulus` |
| **`algebra-traits` `inv` guard made vacuous** | `invChecked rejects zero while inv stays total` |
| **`parallel` chunk `(count+nw-1)/nw` → `(count+nw)/nw`** | **nothing — 2/2 pass** — benign: it changes work *balance*, not results, so a result-equality check cannot see it and should not |
| `SmallField.add` reduction off by one | fuzz | runner exits non-zero |
| `foldLinear` reverted to `a + t·(a + b)` | fuzz | `Sumcheck: honest 0/80 verified` |
| the same fold | unit tests | 4 tests fail, including both negatives |
| torus generator given order `2^(A-1)` instead of `2^A` | fuzz | `error: OrderTooLarge` |
| the same generator | unit tests | 8 tests fail, including every FRI positive |
| `?windows.HANDLE` reverted to `windows.HANDLE` | `cross-check` | `expected type '*anyopaque', found '@TypeOf(null)'` |

The negative tests that guard these are only load-bearing because each one first
asserts the honest case. The tampered-Sumcheck test in `prime128.zig` falls
under the reverted fold because its first assertion is that the honest proof
verifies; a guard that never fails on the honest path is decoration.

## Auditoría por librería

Three questions, all of them answerable without reading the implementation.
`#1` is external vectors, `#2` a mutation seen failing, `#3` a fork that
diverged. Most rows are "no", and the "no" is the finding: it is what says
where a rewrite would buy something and where it would not.

| library | tests | #1 vector provenance | #2 mutation seen failing | #3 forked and diverged |
|---|---|---|---|---|
| `hash` | 19 | **demonstrated** — BLAKE3 45 vectors from an independent implementation; blake2b/blake2s/sha3 re-checked against `hashlib`; keccak shown distinct from sha3 | **yes** — 3 mutations | no |
| `field` | 87 | **unknown** | **yes** — `add` reduction, and `fromBytesChecked` contract per field | no — **and see ZA-2026-004**: `Montgomery` had no test reaching it, and it is wrong for any zero-headroom modulus |
| `binary-field` | 97 | **demonstrated** — Pocklington certificate, plus a `u256` oracle for `Prime128` | **yes** — sum-check fold, torus generator | **yes** — extracted from `zig-zk/libs/stark/binius/`, diverged three releases, Merkle leaf double-hash invisible from both sides |
| `fri` | 25 | **unknown** | **yes** — torus generator | no |
| `pairing` | 58 | **demonstrated** — `py_ecc` (EIP-197) | **yes** — `cyclotomicSqr`, caught | no |
| `rng` | 25 | **unknown** | **yes** — `?windows.HANDLE` | no |
| `merkle` | 19 | **unknown** | **yes** — `validPathIndex` off-by-one, caught | no |
| `poly` | 28 | **unknown** | **yes** — a guard mutation, caught | no |
| `bigint` | 20 | **unknown** | **yes** — negative-modulus guard removed, caught | no |
| `transcript` | 11 | **unknown** | **survived** — guard mutated, nothing noticed | no |
| `serialization` | 15 | **unknown** | **yes** — a guard mutation, caught | no |
| `ntt` | 15 | **unknown** | **yes** — a guard mutation, caught | no |
| `linalg` | 11 | **unknown** | **yes** — a guard mutation, caught | no |
| `kzg` | 6 | **unknown** | **survived** — guard mutated, nothing noticed | no |
| `algebra-traits` | 5 | **unknown** | **yes** — `invChecked` zero guard removed, caught | no |
| `parallel` | 2 | **unknown** | **survived** — guard mutated, nothing noticed | no |

### What the table says

**Question 1 is not "does it have external vectors?" It is "can you demonstrate
where they came from?"** The evidence is in this repository's own history:
`hash` had vectors, they were self-generated, and they hid a non-BLAKE3 for the
entire life of the repository. A self-generated vector is indistinguishable
from a real one from the inside.

And that has an uncomfortable consequence for the audit itself: **provenance
cannot be audited from inside the repository.** Demonstrating it means
comparing against something outside. So for the fourteen libraries below the
three, the honest answer is not "no" — it is **unknown**, and an unknown is a
finding rather than an absence. "We never checked" and "we checked and there is
nothing" are different claims, and only one of them is true.

**Three libraries can demonstrate provenance.** `hash` (BLAKE3 45 vectors,
blake2b/blake2s/sha3 re-checked against `hashlib`), `pairing` (`py_ecc`,
EIP-197) and `binary-field` (a Pocklington certificate plus a `u256` oracle).
One of the three is `hash`, which hid a non-BLAKE3 the whole time — which is the
argument for the requirement being about provenance and not about having
vectors.

**Seven of the ten unmeasured libraries were measured, and six guards are
dead code.** A mutation was written for each: change a guard, a comparison, an
off-by-one. Six of twelve mutations were caught, and the six that survived are
the finding. They are not subtle:

- **`kzg` has two consecutive `return false` guards that no test exercises** —
  on-curve and subgroup membership, in a library with six tests. Both are
  currently dead code.
- **`merkle`'s `validPathIndex` accepts an index one past the leaf count** under
  mutation, and nothing notices. **The code is correct** -- `index < leaf_count`
  is right, and the off-by-one is what the mutation introduces. What is missing
  is the test that would catch it, in a module 209 files across the other two
  repositories depend on. Not a live bug; absent coverage, and it closes the
  same way: with a test that brings the guard down.
- **`kzg`'s two guards are not merely untested: one is dead code and the other
  has no reachable witness.** `verify` opens with an on-curve check and then a
  subgroup check, and `isG1InSubgroup(p)` is
  `p.infinity or (p.isOnCurve() and ...)` — so anything the first guard rejects,
  the second rejects too. The first is a decision point nothing can reach, and
  disabling it changes no outcome. The second needs a point in the cofactor
  torsion: `G1·r` is the point at infinity, because the generator already has
  order `r`, and a scan of 64 values of `x` over `y² = x³ + 3` found 42 on-curve
  points with exact square roots and **zero** outside the subgroup. BN254's G1 is
  documented as having a trivial cofactor, which would make the second guard
  redundant rather than merely untested; that part is not verified here and the
  scan cannot distinguish a trivial cofactor from a large one. Both guards stay
  in the code — removing one is a contract change — and both are marked
  decorative rather than cited as coverage. An attempt to pin the redundancy
  with a test was itself reverted: the test could not be made to fail, which is
  the rule refusing a check that cannot fail.
- **`transcript`'s challenge derivation has no known-answer vector, and there is
  none to write.** Adding 1 to the first byte of the finalised digest changes
  every challenge and all ten tests pass. The ten tests are properties —
  determinism, domain separation, sequentiality, length prefix — and every one
  of them is satisfied by any deterministic function, a counter included. So
  the provenance question comes first, and the answer is: **the derivation
  implements no published specification.** No RFC, no EIP, no reference
  implementation is cited anywhere in `libs/transcript`, and the construction is
  a house design — `std.crypto.hash.Blake3`, a domain string, length-prefixed
  absorbs, finalise-and-rekey. There is therefore no external vector to compare
  against, and a hand-written `expected` here would be the first instance of our
  own rule with the *appearance* of a vector, which is worse than the original
  because it would look like provenance. **Verdict: this derivation is not
  verifiable today.** That is a design fact rather than a coverage gap, and it
  is recorded in `SECURITY.md` as such.
- **`bigint` accepts a negative modulus** under mutation; **`algebra-traits`
  silently returns something for inverting zero**; both unnoticed.
- `parallel`'s chunk computation is mutable without consequence — correctly so,
  since it changes work *balance* and not results, and a result-equality check
  should not see it.

These are requirements 14 and 16 in the table, marked not satisfied, with the
path of the gate that is missing. A guard nobody exercises is a claim nothing
can falsify, which is the fifth instance from the rule above arriving in a
different costume.

**`parallel` reports 2 tests and `timing.zig` has a third** that the root step
never collects, for the reason in requirement 11: a file not imported from the
root is lazily unanalysed and its tests do not run.

**Requirement 11 was violated by the repository that wrote it, and closing it
was not the fix anyone would guess.** The eight `main.zig` files were not
compiled by any build step, so the obvious repair was one `addExecutable` each
in the existing `cross_register` helper. Adding the gate is what made the real
state visible: **the first build of `libs/hash/src/main.zig` failed**, because
the field interface it had been carrying for the repository's whole life was not
the library's field. Its `divChecked` returned `InverseOfZero` where
`zig-field`'s returns `DivisionByZero` — and a test in `root.zig` was asserting
the fork's error set. The repair was to delete both copies of that interface and
import `zig-field`, and only then to add the gate. Requirement 14 written in this
repository, demonstrated inside it: a consumer nobody decided, inventing its own
provider, one with an `invChecked` that has never been executed.

`cross-check` now compiles 34 test binaries and 16 example executables (eight
libraries × two targets), and the count is checked rather than assumed.

## What this table does not decide

It does not say a library should be rewritten. It says which ones have an
instrument that could tell a rewrite had not broken something. On the evidence
here that is `hash` and `binary-field`, and `binary-field` now has two
independent reasons rather than one. Its fork diverged for three releases with
nothing on either side able to see it; **and** it is in the set of libraries
whose tests have never been seen to fail, so the vectors it does have have never
demonstrated that they carry. The second is the stronger argument and it points
at the same place. A rewrite without the requirements and the instruments
written down first would reproduce the fork with extra steps.
