# Changelog

All notable changes to zig-algebra are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/) (0.x: MINOR may carry breaking changes).

> **The release history of 0.4.0 and 0.5.0, in order, because the order is the
> point.**
>
> - `v0.4.0` and `v0.5.0` were created as local tags, and **never left this
>   repository**. As of 2026-09-29 the published tags are `v0.1.0` …
>   `v0.3.2` plus `v0.5.1` and `v0.5.2`; there is no `v0.4.0` and no
>   `v0.5.0` on the remote,
>   and there never was. Both remain signed and un-moved locally, because
>   deleting them would lose the order; their content is contained in
>   `v0.5.1`. (`v0.5.3` is the section below: prepared on `main`, not a
>   published tag until it is pushed — a local tag is an intention.)
> - `v0.5.1` was re-pointed locally, more than once, while it was still
>   unpublished — once to carry the torus work, once to carry the Windows
>   compile fix — and was then **published on 2026-09-27** at `22df684`.
> - That publication is what this paragraph previously got wrong, in the
>   opposite direction. An earlier revision said `v0.5.1` "was never published";
>   the revision before that said `v0.5.0` was "published with a broken build
>   step" and "pushed anyway". Neither was true when written, and each stopped
>   being true when the state moved. See "write sequences, not states" in
>   `AGENTS.md`; this paragraph is the sequence.
>
> **Two process failures, not one.**
>
> 1. *The workflow did not run on tags.* `on.push.tags: ['v*']` was absent, so
>    a tag could be created with a red `benchmark` job and nobody would find
>    out from CI. Fixed before `v0.5.1` was published.
> 2. *Local tags were annotated as published.* This is the expensive one,
>    because it **justified a decision**: re-pointing `v0.5.1` was correct, but
>    it was done on a premise that was false, and the next session reading this
>    file would have inherited the wrong reason along with the right action. The
>    rule "never move a published tag" is unchanged and still correct; the
>    premise underneath it was not.
>
> The rule that follows from the second failure is in `AGENTS.md`: **an artifact
> exists when a consumer can fetch it, not when you created it.** A local tag is
> not a release, it is an intention.
>
> For the record, the compile error itself was real: the P0 sweep below turned
> `rootOfUnity` and `nttWithTwiddles` into error unions, and
> `libs/pairing/src/bench.zig` had two `void` helpers calling them with `try`.
> `zig build bench` does not build at `v0.5.0`. Nobody was harmed by that,
> because `v0.5.0` never reached anyone. Anyone who needs a tag whose
> `zig build bench` compiles should use `v0.5.1` or later, and that statement
> became true on 2026-09-27 when `v0.5.1` was actually pushed.
>
> **`v0.5.1` is published and therefore frozen.** It is at `22df684`; that tag
> is now what the "never move a published tag" rule protects, so it cannot be
> re-pointed. Two consequences, both expected. The Windows fix (`22df684`) is
> inside it, but this changelog correction is **not** — it is on `main` after
> the tagged commit, and ships with the next release. And the changelog *inside*
> the `v0.5.1` tarball still carries the earlier, fictional paragraph, because
> that text was frozen into the tag a commit before it was corrected. Both are
> the rule working: a wrong premise inside a published tag is paid for with
> `v0.5.2`, not with a rewrite.

## [Unreleased]

- **`zig-hash` (behaviour break): `Poseidon.hash()` now pads.** The sponge
  absorbed partial blocks over a zeroed state, so a message and its zero
  extension were the same message: `hash([a]) == hash([a, 0])`, and
  `hash([a, 0, b]) == hash([a, 0, b, 0])` across the block boundary. It now
  applies `pad10*1` at the field-element level (a `1` delimiter in the first
  position the message did not occupy, with an extra block when the message
  fills blocks exactly), so every digest of `hash()` changes. `hash2()` is
  untouched. Nothing inside this repository consumed `hash()` — it had no test
  at all, which is how the sponge stayed unpadded — but an external consumer
  of `hash()` sees different digests for the same input.
- Build logs: every green run of the full suite carried a `failed command:
  ... --listen=-` block above the `545/545` summary. The build runner prints a
  step's captured stderr "no matter the result", and the command it echoes is
  the one it spawned — including spawns that succeeded — so the Montgomery
  test's informational table (a `std.debug.print` in a green test) read as a
  failure in every CI log. Removed — the same test already pins all three
  counts with `expectEqual`.
- **`zig-transcript` (tested): the challenge bytes are pinned to a Python
  mirror of the protocol.** The library's tests checked the transcript against
  itself -- that challenges are sequential, that a length prefix prevents
  ambiguity, that a domain label separates -- which any re-keying scheme
  satisfies; the only mutation in the log for this library survived, and the
  log said why: "there is no vector to write". There is now. A Python mirror
  of the protocol as the docstrings state it, over the reference BLAKE3
  binding, supplies 32-, 64- and 128-byte challenges, the challenge that
  *follows* a wide one, `challengeU64`, and `challengeField` on both sides of
  its rejection loop -- the labels for those two were chosen in the same mirror
  for taking one draw and three, so the retry path is exercised rather than
  hoped for. That mutation, `digest[0] += 1` after the final, is now caught.
  Two more mutations needed the instrument to grow before they could bite: the
  extension rule is indistinguishable at 64 bytes (one extension, where "hash
  the emitted block" and "hash the output so far" are the same expression), and
  the re-key seed is invisible unless the challenge *after* a wide one is
  compared. Both are in the log now, with the instrument that sees them.
- **`zig-field` (P0, fixed): `QuadraticExtension.primitiveRootOfUnity` never
  returned for any order above the base field's two-adicity.** The
  quadratic-non-residue search walked the real axis -- `z = 2; z += 1`, so
  every candidate had `c1 = 0` -- and that is a search in a place where the
  answer cannot exist. For any non-zero `a` in the base field,
  `a^((p^2-1)/2) = (a^(p-1))^((p+1)/2) = 1` by Fermat, so **every base-field
  element is a square in `F_{p^2}`** and `legendre` can only answer `1` along
  that axis. Measured on `QuadraticExtension(M61, -1)`: two-adicity 1 for M61
  and 62 for the extension; `legendre == 1` for every real-axis value 2..8;
  `legendre == -1` for `5+3i`. So `primitiveRootOfUnity(62)` compiled and
  never returned -- 2^61 candidates, each a 121-bit exponentiation. The public
  API was reachable with a legal argument; nothing inside this repository
  reached it, because the only test of this function stopped on the cheap
  `log_size <= BaseField.two_adicity` path, and *that limitation was written
  down* in `libs/field/CHANGELOG.md` and `libs/field/TODO.md` with a reason
  that turned out to be false -- the extension binary runs in 59 ms with this
  case in it. Documented is not covered. The search now varies both components,
  which reaches a non-residue in a handful of tries (half of `F_{p^2}^*` is
  one), and it is bounded: a failed search returns `error.NoNonResidue` instead
  of running forever, which is also what makes the regression test possible --
  reverting the search to the real axis makes that test **fail** with
  `error.NoNonResidue` rather than hang. The root formula was already correct
  and is unchanged: `z^((p^2-1)/2^log_size)` has exact order `2^log_size` for a
  non-residue `z`, which the new test checks against the field rather than
  against the helper that built it.
- **`zig-algebra-traits` (fixed): `lagrangeInterpolate` returned the
  coefficients of a different polynomial.** Multiplying the Lagrange basis by
  the linear factor `(x - x_j)` added `li[k]` where it needed `li[k-1]`, so the
  product came out as `Π (1 - x_j * x)`: a polynomial of the right length
  that interpolates nothing. Interpolating `(1,1), (2,3), (3,5)` returned
  `[1, 0, 0]` — the constant `1` — instead of `[6, 2, 0]`. Nothing in this repository
  called the function, and its only test asserted that mismatched `xs`/`ys`
  are refused — the shape of the output was never checked against anything,
  which is the "not called" class from the audit, one layer down. The fix is
  in the basis multiplication, and the known-answer test now pins the
  coefficients and evaluates the result at the points.
- **`zig-algebra-traits` (fixed): a repeated node is a typed error, not a
  silent zero.** `lagrangeCoefficient` and `lagrangeInterpolate` divided by
  `Π (x_i - x_j)` through the total legacy `F.inv`, which returns zero for a
  zero denominator, so duplicated `xs` produced a plausible-looking zero
  coefficient. Both now return `error.DegenerateNodes`, which is what
  `poly.lagrangeInterpolate` has returned (`error.DivisionByZero`) for the
  same input since 0.3.0 — same condition, two names, and renaming poly's
  would break its API, so the disagreement is documented instead. **The
  mechanism is worth naming so this is not read as a refactor later: a silent
  `inv` became an explicit `isZero` test, and it is deliberately not
  `invChecked`** — `FieldTrait` requires `inv` and not `invChecked`, so
  calling the latter would break every conforming type that lacks it in order
  to catch a degree-two bug. The check is on the delta, which is the value the
  denominator actually inverts. This is an **API change**: the error sets of two
  public functions grow, and a caller that handled every error before now has
  one more to handle. The contract is
  deliberately narrower than "no duplicates anywhere": the denominator of
  `λ_i` only involves pairs that include `i`, so a unique `x_i` still yields a
  well-defined coefficient even when some other value is repeated; what such a
  set is not is a valid Lagrange basis, and that stays the caller's
  constraint.
- **`zig-poly` (tested): the polynomial arithmetic is differential-tested
  against Python over the same `F_7`.** Horner evaluation, long division, the
  formal derivative, composition, powers, `lagrangeInterpolate` and
  `vanishingPolynomial`, with the expected values computed from the
  mathematical definitions rather than transcribed from this code. The eight
  operand pairs are chosen for shape, not for value: constant operands,
  interior zero coefficients, a sum that crosses zero, an exact division, a
  dividend of lower degree than the divisor, and products that sit at the
  `max_degree` boundary. Each interpolation vector is additionally checked by
  the property it exists to have -- the polynomial evaluates to `ys[i]` at
  `xs[i]`, and the vanishing product is zero at every point -- so a vector is
  not just a transcription. The differential earned its keep before it saw this
  library: it caught an error in the *oracle* (a composition computed by
  sampling instead of by Horner in the polynomial ring), which is what a
  second implementation written from a specification is for.
- **`zig-ntt` (tested): the transform is checked against a DFT computed in
  Python.** The existing coverage was a round trip -- `ntt` then `intt` equals
  the input -- which every sign convention and every transposition passes,
  because a transform and its own inverse stay inverse however both are wrong.
  A direct DFT (`sum_j x[j] * w^(j*k)`, Python, same prime) is checked for
  log_n 1..4 over Goldilocks and BabyBear, using this library's own
  `primitiveRootOfUnity` values after verifying in Python that each is
  primitive of order 2^log_n, and the inverse of that external transform is
  checked to return the input. Observed: flipping the convention to `w^-1`
  leaves the round trip green and turns this red.
- **`zig-field` (tested): the field arithmetic is differential-tested against
  Python.** One test carries 45 vectors over five predefined fields -- M31,
  BabyBear, Goldilocks, StarkNet_Fp and BLS12_381_Fp -- for `add`, `mul`,
  `invChecked` and `neg`, computed in Python as `int` arithmetic modulo the same
  prime, so both backends are covered at once: the u64 small-field path (with
  its Mersenne fast path) and Montgomery CIOS over u64 limbs. Six of the nine
  vectors per field sit at the wraparound boundary (`p-1 + 1`, `p-1 + p-2`,
  ...), because random values do not reach it: removing the small-field `add`
  reduction is caught, and the first version of this fixture -- random pairs
  only -- caught nothing. One mutation survived and the reason is a fact about
  the code, not a gap in the test: M31's second Mersenne reduction cannot fire,
  since with `a, b < p` the two halves of the sum never add up to `p`. It is
  dead code in the hot path, and left in place rather than removed here.
- **`zig-rng` (fixed, important): the ChaCha20 CSPRNG was not ChaCha20.**
  The quarter round rolled three of its four values to the *right* where RFC
  8439 rolls them to the left (`<<< 12`, `<<< 8`, `<<< 7`; only the 16 is its
  own complement, which is why it looked plausible). The result is a
  self-consistent permutation of the state: deterministic, seed-sensitive,
  32 bytes per block — and not the algorithm the file, the README and the type
  name all claim. The existing tests could not see it, because determinism and
  "different seeds differ" are exactly what a wrong permutation also
  satisfies. Nothing else in this repository consumed the stream, so no other
  library's output changes; an external consumer gets different bytes from the
  same seed, and any use that needed real ChaCha20 (an interoperable KDF, an
  AEAD key, a published test vector) was getting something else. The rotations
  now follow the RFC, and the known-answer test in `libs/rng` pins both of its
  vectors.
- **`zig-rng` (tested): both generators are pinned to their specifications.**
  `ChaCha20Rng` against RFC 8439 §2.3.2 (block function) and §2.4.2 (keystream,
  and the plaintext XOR keystream that has to reproduce the published
  ciphertext); `Shake256Rng` against CPython's `hashlib.shake_256` at the
  empty seed, at `"abc"` and on both sides of the 1088-bit rate boundary
  (136 and 137 bytes), which is where a sponge goes wrong. SHAKE256 turned out
  to be correct FIPS 202 — the domain byte is `0x1F` and the rate is 136 — and
  the SHAKE vectors were observed failing when that byte is changed to `0x07`.
- **`zig-rng` (tested): a test that pinned the broken keystream.**
  `randomU64Bounded edge cases` asserted `randomU64Bounded(_, 2) == 0`. For
  `max = 2` both 0 and 1 are correct answers, so the literal was a property of
  the wrong generator, and it passed until the quarter round was fixed. It now
  asserts the range. A test written against the implementation pins the
  implementation; this one pinned a bug.
- **`zig-merkle` (tested): the tree is differential-tested against a
  from-scratch Python implementation over `hashlib.sha3_256`.** SHA3-256 is the
  same standard hash on both sides, so what the test pins is the tree: leaf
  hashing, the padding rule (an unused leaf is the hash of the empty byte
  string), internal-node hashing, proof order and the serialized proof
  layout. Five tree shapes -- four leaves, three, five, a single leaf, and
  eight -- with 23 proofs in total, checked in both directions: our proof
  serializes to the oracle's bytes, and the oracle's proof verifies against
  the oracle's root here, including the padded index whose leaf data is the
  empty string. Reverting the padding rule to zero fill turns it red.
- **`zig-bigint` (fixed): three signed-arithmetic contracts the code did not
  keep, all found by a differential against CPython.** The tests for this
  library asserted what the implementation produced, so three defects could
  sit behind their own docstrings: `mod` documented "always non-negative" and
  added `m` to a negative remainder, so `(-7).mod(-3)` returned `-4` instead
  of `2` whenever the dividend *and* the modulus were negative; `shr`
  documented an arithmetic (floor) shift and truncated toward zero, so
  `(-1).shr(7)` and `(-7).shr(7)` returned `0` where the bitwise operations
  — already two's complement, and already agreeing with CPython on the same
  values — imply `-1`; and `fromString` rejected every non-digit while
  `toString` writes a leading `-` for negatives, so `fromString(toString(x))`
  failed for every negative `x` and passed for every positive one, which is
  the exact shape of a round-trip test that only ever ran one side. `mod` and
  `shr` now follow their documentation and `fromString` accepts the sign its
  own serializer emits. `divRem`/`rem` keep C semantics (truncation, the
  remainder takes the dividend's sign); `fromString("")` is still zero and a
  bare `-` is still `error.InvalidDigit`. External consumers: `mod` and `shr`
  on negative arguments see different values — and the values they now
  produce are the ones the docstrings promised.
- **`zig-bigint` (behaviour addition): `fromString` reads a leading `-`.**
  See the fix above; the parse of positive decimal strings is unchanged, so
  this only widens what is accepted.
- **`zig-bigint` (tested): the arithmetic is differential-tested against
  CPython.** Three tests carry vectors generated with CPython 3 (`int` is
  arbitrary precision, and nothing in this repository produced them) for the
  contracts the docstrings state: 14 core cases across the 64-bit limb
  boundaries (add, sub, mul, divRem, mod, cmp), 10 bitwise/shift/gcd cases
  including the negative ones where the two defects above lived, and 8
  modular-exponentiation cases over the Mersenne 2^61-1, the STARK prime and
  the BLS12-381 scalar field. Reverting either fix turns the differential
  red — observed before the fixes were trusted. This is the library's first
  answer to "where did the vectors come from?"; see
  `docs/requirements.md`.
- **`zig-hash` (added): `Poseidon(...).initSpec()` generates the reference
  parameter set.** It is the IAIK `generate_parameters_grain.sage` Grain LFSR
  behind circomlibjs's `poseidon_constants.json` — header
  `FIELD=1, SBOX=0, n, t, RF, RP`, n-bit samples drawn MSB-first with
  candidates `>= p` rejected, then a Cauchy MDS built from 2t distinct reduced
  samples with every `x_i + y_j != 0`. So a caller who needs to interoperate
  no longer has to copy constants out of a JSON file or generate them from a
  seed. `SBOX=0` names the family `x^alpha`: the exponent does not enter the
  generator, so alpha = 3 and alpha = 5 over the same `(n, t, RF, RP)` produce
  identical constants. The sage script's `algorithm_1/2/3` sieve is not
  ported, and the known-answer test pins the published `M[1]` to the first
  candidate. `initFromSeed` is unchanged and still available for ad-hoc
  instances; `initSpec` compile-errors on anything the generator does not
  describe (a non-prime field, `BITS > 512`, a width outside the Grain
  header's 12/12/10/10 bits) and returns `NoValidRoundConstant` /
  `NoValidMdsEntry` from its 256-draw bounds.
- **`zig-hash` (tested): Poseidon is now pinned to two external parameter
  sets.** The permutation had no answer to check against — its tests asserted
  determinism and self-consistency, which any permutation passes. One
  known-answer test now fixes the CryptoExperts Hades parameters StarkNet
  uses (t=3, RF=8, RP=83, alpha=3, partial-round S-box on the last cell; the
  107 constants taken from poseidon-py's `CONST_RC_MONTGOMERY_P3`), exposed
  for that purpose as `PoseidonVariant(F, t, RF, RP, alpha, partial_sbox_index)`
  with `Poseidon(...)` keeping cell 0. The other pins `initSpec` itself:
  all 195 round constants and the 3x3 MDS of circomlibjs's `C[1]`/`M[1]`,
  plus three permutation states from its   `poseidon_reference.js`, over the
  BN254 scalar field. Both are external vectors; neither was produced by
  this code.
- **`zig-linalg` (tested): the linear algebra is now checked against exact
  Python arithmetic over `F_7`, written from the definitions rather than from
  the Zig.** The library's own tests agreed with the implementation, so they
  could not distinguish a correct factorisation from a self-consistent one.
  The differential asserts **properties** and not a factorisation: `A^T`,
  `A·v`, `det A` (adjugate, signed), `A·x == b`, and `L·U == P·A`. That last
  one is the one worth having and the one that is easiest to make vacuous —
  see the two findings below.
- **`zig-linalg` (finding, twice): the test was wrong four times before the
  library was ever wrong once.** The differential was written from the
  definitions, which is the only way it can be worth anything, and it still
  arrived with four defects of its own: a transposed comparison written
  against the original matrix instead of its transpose, `mulVec` fed the
  *expected* product as its input vector, two vector cases whose lengths and
  `norm2` values had been computed for 1 and 5 components and then asserted
  at 4, and a Goldilocks fixture that landed in the `F_7` table with a
  malformed slice literal. Each was caught by the arithmetic; none was caught
  by the tests that were already there, which is the point of writing the
  oracle from the specification. **The library survived: no defect was found
  in `Matrix`, `Vector` or `LU` in this pass.** That is a result, not an
  absence of one — it is what a differential is for.
- **`zig-linalg` (instrument): `L·U == P·A` was a tautology until a case
  forced a row swap.** The first version of the table had three invertible
  matrices, all with a non-zero pivot already in place, so `P` was the
  identity and the identity held without saying anything. A mutation that
  stopped `lu` from recording the swap in `P` **survived**, which is how the
  case set was found to be missing a branch: the fourth matrix has a zero in
  the top-left corner, so the first column pivots on row 1. With it, the same
  mutation is caught. A fourth mutation — choosing the first non-zero pivot
  instead of the largest — is **meant** to survive: both are valid
  row-pivoting rules and both satisfy `L·U == P·A`, so the test is not
  supposed to see it. Six more mutations are caught: the `transpose` index
  swap, the row-swap sign in `determinant`, a `mulVec` that skips the last
  term, `norm2` returning a product, `lu` swapping `P` but not `L`'s earlier
  columns, `solve` not permuting `b`, and `solve` reading the wrong diagonal
  of `U`.
- **`zig-linalg` (one 2x2 case over Goldilocks).** The `F_7` table exercises
  the algebra and the guard paths; this one runs a small system over a real
  prime so the Montgomery-backed `Field` operations are in the comparison too
  — `det` reduced to `7479327909597309152` and a solution whose product
  reproduces `b`, both computed by the same Python that produced the `F_7`
  vectors. It was added after the first version failed to compile for exactly
  the reason it exists: a 2x2 case in a table of 3x3 shapes.
- **`zig-kzg` (tested): the commitment, the witness and the verifier's decision
  are now compared with `py_ecc.bn128`,** py_ecc's reference BN254 module, over
  eight cases. The comparison is of the **decision**: each case carries py_ecc's
  own answer to the verification equation, so the test compares two
  implementations' verdicts and not only their bytes. The cases include two
  random 254-bit taus, `tau = 1`, the zero polynomial -- where the commitment
  and the witness are both the point at infinity, a branch no other case reaches
  -- `z = 0` with a non-zero constant term, a leading zero coefficient, and a
  degree equal to the setup bound. The setup itself is checked coordinate by
  coordinate: `[tau^i]G1` and `[tau]G2` are a claim about points, and the test
  now holds them to the external ones.
- **`zig-kzg` (the instrument was wrong twice, and both times it pointed at the
  library).** The first fixture reduced the scalars modulo `field_modulus`, which
  in py_ecc is **p**, instead of modulo the group order **r**. The two
  reductions coincide for any `tau` smaller than both, so five small cases
  passed and the 254-bit one disagreed -- a case set that cannot distinguish two
  reductions cannot report the wrong one. Rebuilt on `py_ecc.bn128`, the
  disagreement persisted and the second fault was in that module's `neg`, which
  returns a coordinate that is not on the curve for large scalars, and which
  `multiply` inherits; the inverses are now the group's own negation with the
  sign reduced by hand. With the ladder and the pairing still py_ecc's, all
  eight cases agree, and the library's setup, commitment, witness and verdict for
  a 254-bit `tau` are confirmed against **three** independent references:
  `py_ecc.bn128`, `py_ecc.optimized_bn128`, and an affine double-and-add
  written from the definition of the group law. **Nothing in the library was
  wrong.** Five of seven mutations are caught: `g1_pows[0]` set to the identity,
  the MSM receiving its scalars reversed, the quotient shifted one position,
  `evaluate` skipping the top coefficient, and the sign of `z` in `verify`.
- **`zig-kzg` (two guards that cannot be told apart).** `verify` checks that the
  commitment and the witness are on the curve *and* that they are in the r-order
  subgroup. Deleting either check leaves every test green, and that is expected
  rather than a hole: BN254's G1 has cofactor 1, so on-curve implies
  in-subgroup and neither removal can change an outcome. What the new test pins
  is the behaviour -- a commitment one field element off the curve, which a
  verifier must reject -- and not which of the two guards rejects it.
- **`zig-parallel` (fixed): the two tests in `libs/parallel/src/timing.zig` had
  never been run by anything.** `pub const timing = @import("timing.zig")`
  re-exports the declarations but does not pull a file's `test` blocks into the
  test binary, so the only check on `nowNs()` at all -- its monotonicity -- was
  collected by no gate: not by `cd libs/parallel && zig build test`, which
  reported 2/2, and not by the root step, which ran the same two. A reference to
  the file from a test block brings them in, and the count moves from 2 to 7.
  This is the "nothing counts as exercised until a test calls it" rule with a
  timer at the other end of it: the check existed, it was green, and it had
  never been executed.
- **`zig-parallel` (tested): the pool is now swept over its chunk boundaries and
  the clock is checked against a second OS clock.** 21 counts by 9 worker counts
  -- count 0 and 1, counts below the worker count, non-divisible counts, the
  64-worker cap -- with an execution counter, because `out[i] = i + 1` written
  twice looks exactly like written once. The clock's elapsed interval is compared
  with `CLOCK_REALTIME`'s, the offset between the two clocks is required to stay
  put, and the monotonic reading has to be three orders of magnitude below the
  wall-clock one. Six of seven mutations are caught.
- **`zig-parallel` (a check that was satisfied by construction).** Swapping
  `CLOCK_MONOTONIC` for `CLOCK_REALTIME` in `nowNs()` left every test green at
  first, because the offset check compares the two clocks against each other: if
  both readings came from the same clock the offset is zero at both ends and the
  assertion holds for the wrong reason. Only the size of the value separates
  them -- a monotonic clock counts from boot, a wall clock from 1970 -- so the
  check that bites is a factor of 1000 between the two readings, and it catches
  the swap in the branch this platform executes. A second swap inside the libc
  branch still survives here, and that is not a survivor either: `builtin.link_libc`
  is false in this build, so the branch is never entered, and the other operating
  systems in CI are where it runs. A mutation in a branch the platform does not
  execute is not evidence of anything.
- **`zig-serialization` (tested): the wire layout is now compared with an
  encoder written from the module's own documentation.** The format is a local
  convention, so there is no external standard to lean on; what there is
  instead is a second derivation of the same specification. A Python encoder
  implements the docstring's rules -- little-endian integers, `u64` length
  prefixes, declaration-order fields with `std.mem.Allocator` and
  `owns_entries` skipped, one presence byte per optional, raw bytes for `[N]u8`
  -- and reads nothing of this implementation. Over seven shapes it agrees
  byte for byte, and it independently reproduces the hand-written golden vector
  that was already in the file: two derivations of one specification, agreeing
  with each other and with the code. The shapes are chosen for what they
  distinguish rather than for their values -- an absent optional beside a
  present one, an empty slice, `usize` at both widths, zero and all-ones for
  every unsigned width, a slice of slices of structs, arrays of arrays, and 32
  bytes written both as a raw array and as a slice, which is the pair that
  tells the two forms apart on the wire.
- **`zig-serialization` (tested): seven buffers the format requires a decoder
  to reject.** Trailing bytes, a length prefix of 2^40 elements, a prefix one
  element longer than the bytes behind it, a presence byte outside {0, 1}, a
  struct truncated inside its last field, an empty input, and a 2^32 prefix over
  32 bytes. Each carries the type it is decoded as, because that is part of the
  contract: a prefix claiming four `u8` over four bytes is not an
  over-declaration, and the first version of this test asserted that it was.
  The expectation in every case is the specification's, not the code's. Nine
  mutations are caught, including the length bound whose removal lets a
  declared length reach the allocator.
- **`zig-fri` (fixed, P0 class): `torus.findGenerator` had no usable bound, and a
  wrong adicity turned it into the end of the run.** The search walked `t` to
  `p`, and its order test is `x^(2^(A-1)) == -1` with `A = torusAdicity(Base) =
  v2(p + 1)`. Replace `v2(p + 1)` with `v2(p - 1)` -- one operator -- and every
  candidate fails that test, so the loop walks `2^31` candidates for M31 and
  `2^61` for M61, each an inverse and an exponentiation in a 61-bit field. What
  that looks like from a gate is **a timeout, not a failure**: the suite was
  observed hitting 600 s with no output, which is the worst of the three
  outcomes, because a gate that expires says nothing about what it was
  checking. The search now stops at `torus.max_candidates` (2^20) and returns
  `error.TorusGeneratorNotFound`, and the same mutation is a red run in seconds.
  Nothing observable changes for a consumer: the first `t` is 2 over M31 and 4
  over M61, both far inside the bound, and the new constant is the only addition
  to the surface.
- **`zig-fri` (tested): the domain and the torus generator are now compared with
  a Python implementation of the module's documented sentences.** The
  generator is "the first `t >= 1` whose Cayley image has order exactly `2^A`",
  the adicity is `v2(p + 1)`, and the domain is `omega^2^(adicity - log_n)` with
  `at(i) = step_gen^i`; all 256 elements of three domains match element by
  element -- the Goldilocks base-field domain and the M31 and M61 torus domains.
  The Python side checks itself before it is believed: the generator's order is
  exactly `2^A` by repeated squaring, which does not go through the search, and
  every smaller `t` is rejected, which is the "first" half of the claim.
- **`zig-fri` (three assertions of mine were false about FRI, and the
  arithmetic said so each time).** The first version of the residual test
  asserted the residual *is* the input polynomial's coefficients; the second
  asserted it is a degree-3 polynomial. Neither is true: the fold is
  `p_even(x) + alpha * p_odd(x)/x`, so the child is a function of `x^2`, not of
  `x`, and a degree-3 input becomes a *constant* after two rounds. The third
  version used `x^n` as "not low degree" data on a domain of order `n`, which is
  the constant 1 -- the lowest-degree function on the domain -- so the verifier
  was right to accept it. What survived is the claim with content: a degree-31
  input (the maximum the config admits) must leave a residual with a nonzero
  coefficient above index 0, because a fold that dropped the odd part or forgot
  the challenge would send every input to a constant, and a degree-32 input must
  be rejected. **No defect was found in the fold, the domain or the
  interpolation.** Five of six mutations are caught; the sixth survives on
  purpose, because restoring the search bound to `p` changes nothing on the
  happy path, and a check that pins a constant's value is a drift detector
  rather than a proof.
- **`zig-fri` (tested): the candidate bound has its own test, and it is the
  discriminating one.** `max_candidates` was, until this test, a promise: the
  suite pinned that the constant existed and that the first working `t` was 2
  and 4, but nothing checked that lowering the limit produces
  `error.TorusGeneratorNotFound`. For M61 a limit of 3 now has to give the error
  and a limit of 4 the generator, so a loop that skipped the check, or applied
  it once instead of per candidate, cannot pass -- and a test that only
  asserted the error would have passed with a limit of 0. Three mutations
  confirm it: the limit going back to `p`, the loop ignoring the limit, and the
  limit being consulted once.
- **`zig-fri` (the loop and its own docstring disagreed by one).** The bound is
  documented as "at most `max_candidates` values of `t`" and the loop was
  `while (t < limit)` starting at `t = 1`, which examines one fewer than the
  limit it promises -- so a limit of exactly the first working `t` returned the
  error instead of the generator. The loop is now `t <= limit`. This is the
  sixth time in this pass that a stated contract and the code have differed, and
  the first time one was found by a test written to check the contract from the
  other side rather than by reading the two next to each other.

## [v0.5.3] — 2026-09-29

> **This release fixes ZA-2026-004, the `Montgomery` inverse for any
> zero-headroom modulus — and the direction of that matters: `v0.5.1` and
> `v0.5.2` still ship the defect, so a consumer of those releases either moves
> to `v0.5.3` or sizes the container with headroom.** The patch reached `main`
> in `086234a`, several commits before this one; the advisory's stale status
> line ("no patch exists yet", written while the patch already sat in `main`)
> and its correction are both in `SECURITY.md`.

### Added

- **`zig-transcript`: `challengeFieldChecked`,** and the contract statement that
  goes with it. **This is a change of contract for `challengeField`, not a fix
  to a broken function: the transcript was never incorrect.** It was exactly
  uniform *by courtesy of another library's `fromBytes`*, and that courtesy did
  not extend to this repository's own prime-field fixtures.

  ```
  libs/field/src/field.zig:200            fromBytes([]const u8) !Self        rejects
  libs/binary-field/src/prime128.zig:311  fromBytes([NUM_BYTES]u8) Self      reduces
  ```

  The guarantee moved, named, the way `inv`/`invChecked` and
  `millerLoop`/`millerLoopPairChecked` already do:

  - `challengeField(F)` — decodes through `F.fromBytes`, **promises no
    uniformity**; whether that rejects or reduces is a per-field convention
  - `challengeFieldChecked(F)` — requires `F.fromBytesChecked(bytes:
    [NUM_BYTES]u8) !F`, **promises exact uniformity on `[0, p)`**

  Six `fromBytesChecked` entry points were added so the name means one thing in
  all three libraries: two in `zig-field`'s prime field, two in `extension.zig`,
  and -- over GF(2^m), where every bit string is an element and there is nothing
  to reject -- `BinaryField` and `TowerField` with an **empty error set**,
  because a function that cannot fail should say so in its type.

  **The empty intersection is now closed.** `Sumcheck` gates at
  `MIN_SAFE_BITS = 128` and `Prime128` satisfies it, but `Prime128` could not
  use the transcript at all: `challengeField` required a signature `Prime128`
  does not have. A 128-bit sum-check with challenges from this transcript could
  not be assembled. `libs/fri`'s two call sites now use the `Checked` half.

  **And the part a consumer needs, because it is invisible in the renamed call
  site: the challenge sequence is unchanged, so a proof from `v0.5.2` still
  verifies.** Both halves are rejection sampling over the same acceptance
  predicate for both fields FRI instantiates (`Goldilocks`, `CM31`), and
  `Prime128` -- the one field where the halves differ, because its `fromBytes`
  reduces -- could not compile against `challengeField` at `v0.5.2`, so no
  proof of that shape exists to invalidate. That compatibility claim is not
  read off the decoders; it is pinned by `fri: the transcript switch preserved
  the challenge sequence`, which runs the frozen entry point and the new one
  side by side over both instantiations and compares bytes.

  A second defect surfaced while writing the test, in territory no review had
  reached: the extension copies of the digest had a `u512` XORed into a `u64`
  accumulator. Fixed in `7af963d`.

### Security

- **ZA-2026-004: `Montgomery` inverses are wrong for any modulus with zero
  headroom.** `montgomery.zig:275` implements `x += p` over `[n]u64` and
  discards the carry, so it computes `(x + p) mod 2^(64n)`. That is wrong
  exactly when `x + p >= 2^(64n)`, which for a modulus whose bit length equals
  `64 * n` means `x >= 2^(64n) - p` — and the loop invariant `x1 in [0, p)` does
  not exclude those values. Measured, first test in this repository that reaches
  `montgomery.zig` at all:

  ```
  secp256k1 (256-bit p, headroom 0): 0 correct, 16 WRONG
  BN254     (254-bit p, headroom 2): 16 correct, 0 wrong
  BLS12-381 (255-bit p, headroom 1): 16 correct, 0 wrong
  ```

  `addP` is **byte-for-byte identical since the first commit** `86605a1`, and
  `git diff 22df684 a22dbd9 -- libs/field/src/montgomery.zig` is empty, so
  **`v0.5.1` and `v0.5.2` shipped identical code and there is no release in
  which this was correct.** No patch yet; the advisory states the two candidate
  fixes without choosing.

  It stayed silent because `Montgomery(` appears nowhere outside `field.zig` and
  `montgomery.zig` — **no predefined field goes through the type**, and the ones
  that would be used here have headroom, so 421 green tests could not have found
  it. Silent by *coverage*, not by behaviour: `a * a^-1 == 1` exposes it
  immediately, and nobody was asking.

  Cross-referenced against the transcript finding, which is a **design fact, not
  a broken invariant**, and is easy to bury: see the two-open-findings note in
  the advisory.

### Fixed

- **`modExp` and `modExpU64` report `error.InvalidModulusWidth` when the
  modulus is too wide for the container.** The loop squares `b` every iteration
  and reduces afterwards, so the product is `b * b` with both factors of at most
  `len(m)` limbs, and `BigInt.mul` rejects when `alen + blen > max_limbs`
  (`bigint.zig:325`). **The threshold is a function of the modulus's width, and
  it is exactly `bitLength(m) <= 32 * max_limbs`** -- measured at `max_limbs` in
  2, 4 and 8, not derived.

  The base does not move it, and the mechanism is why: `b` is squared every
  iteration, so even a base of 3 reaches full width within a few steps. The
  threshold is set by `m`, not by the starting point.

  **This is not the same as the `egcd` overflow, and the two are not
  counted the same.** `egcd` had `catch unreachable` over an operation that
  really could fail, so a case that "worked" now fails: that is a **breaking
  API change**. `modExp` never worked past the threshold -- it returned
  `error.Overflow` -- so declaring it is **documentation of an existing silent
  failure, not a contract break**. `BigInt` uses an inferred error set, so
  adding an error here breaks nothing.

  The rename to `error.InvalidModulusWidth` happens at the call site and not in
  `mul`, because `mul` is the door for all of `bigint` and cannot know whether
  a modulus is involved: an error raised there would tell a plain `a * b` that
  its modulus is too wide. A test asserts that a plain multiplication still
  says `error.Overflow`.

  **Blast radius is external.** `modExp` is leaf API with no internal caller
  above half-width, so nothing in this workspace is affected; the exposure is to
  consumers. `PrimalityTest(8)` is the case to name: its modulus for a 512-bit
  candidate exceeds the 256-bit threshold, so it fails for every candidate.

- **`ExtendedGcd.egcd` reports `error.Overflow` instead of being undefined
  behaviour.** `egcd` computed `q * r`, `q * s` and `q * t` over
  `catch unreachable`. The intermediate needs up to twice the width of the
  container, `BigInt.mul` returns `error.Overflow` for it
  (`bigint.zig:325`), and that error became a trap in Debug and **UB in
  ReleaseFast**. It is reachable: with a modulus whose bit length equals the
  container's and the top bit set, `modInv(2, m)` hits it on the first
  iteration, for any `a`.

  **Before this was undefined behaviour; now it is an error, and the error is
  real.** An input that used to "work" now fails, which looks worse and is
  better: a failure rather than an undefined behaviour. `egcd` and `modInv`
  propagate it. `prime.zig`'s `catch unreachable` on `rem` is deliberately left
  alone and is genuinely unreachable, because the divisor there is a small
  prime, so no intermediate can exceed the dividend's width -- the difference
  from this one is that an input exists which reaches it.

  **No release was ever correct.** `libs/bigint/src/gcd.zig` has been touched
  exactly once in its history, by `86605a1`, the first commit of the monorepo,
  so **`v0.5.1` and `v0.5.2` ship identical code**. `egcd` returning an error is
  a **breaking API change** and is not in `v0.5.2`.

  **And there is no width rule to document in place of it.** The proposed
  boundaries ("container minus one", "container minus two") were both refuted
  by measurement: on a 256-bit container the widest surviving modulus is 193
  bits for `a` in 2..13 and **218 bits** for `a = 2^31 - 1`, because the
  threshold moves with the Euclidean trajectory rather than with `m`. The doc
  now says to size the `BigInt` with headroom and to treat `error.Overflow` as a
  real answer.

- **`Montgomery`'s binary-GCD inverse is correct for every modulus, including
  zero-headroom ones.** `addP` computed `x + p` in place over `[n]u64` and
  discarded the carry, so it computed `(x + p) mod 2^(64n)`. **There is no
  release in which this was correct:** `addP` is byte-for-byte identical since
  `86605a1`, the first commit of this repository, and
  `git diff 22df684 a22dbd9 -- libs/field/src/montgomery.zig` is empty, so
  `v0.5.1` and `v0.5.2` shipped identical code. See ZA-2026-004.

  The step is now `halveMod`, which halves **first**: `x >> 1` and
  `(p + 1) / 2` are each below `2^(64n - 1)`, so the sum cannot carry out of the
  container, and for odd `x` the identity `(x + p) / 2 == (x >> 1) + (p + 1) / 2`
  is exact over the integers. The overflow is gone **by construction** rather
  than detected, and the step stays constant-time.

  Measured, and the differential is what makes it credible -- the two moduli
  that were already correct are the control:

  ```
  before   secp256k1 (256-bit p, headroom 0):  0 correct, 16 WRONG
           BN254     (254-bit p, headroom 2): 16 correct,  0 wrong
           BLS12-381 (255-bit p, headroom 1): 16 correct,  0 wrong
  after    all three:                          16 correct,  0 wrong
  ```

  Reverting `halveMod` to the old order makes `zig build test` red again, **and
  the gate sees it** -- which it could not before the previous commit.

- **Four public `hash` methods did not compile.** `field.zig:663,1368` and
  `extension.zig:227,644` called `hash_val.wrapping_mul(...)` on a `u64`. Zig's
  wrapping arithmetic is the `*%` operator, not a method, so the bodies were
  hard errors the moment anything reached them. Nothing did: `rg '\.hash\('`
  across `libs/` and `examples/` returns zero, and Zig only analyses reachable
  code, so a suite of 421 green tests had never looked at these four.

  The two extension copies carried a **second** error the review did not report:
  `hash_val ^= v & 0xFF` with `v` a `u512`, which is `expected type 'u64', found
  'u512'`. Fixed with an explicit `@truncate` to a `u64` byte plus `*%`.

  **No expected digest is asserted, on purpose.** A literal produced by this
  implementation would be a self-generated known-answer vector wearing the
  appearance of one. The test asserts the reachability claim and the two
  properties a map key needs — stable, and not constant — and says plainly that
  it does not claim the FNV-1a result has any particular value.

- **A public re-export that names nothing: `lib.zig:31`** re-exports
  `predef.BLS12_381_Fp2`, which `predef/bls12_381.zig` does not define. Same
  family as the four bodies — declared surface nobody reaches — except this one
  fails loudly, on `zig-field.BLS12_381_Fp2`. **Not fixed here:** which
  non-residue BLS12-381's `Fp2` should use is a design decision, not a patch.

### Security

- **Named in the title, because the name was doing work the code cannot
  support: `zig-transcript` is a house design, not a Fiat–Shamir
  implementation.** `SECURITY.md` now says so under "Fiat-Shamir without a
  specification". Two of the three properties hold — the challenge is a
  deterministic function of the statement, and re-keying between draws stops
  the prover grinding it. **The third is unsatisfiable here and not through a
  defect:** a third party cannot derive the same challenges, because no
  specification exists to derive them from. The word "Fiat–Shamir" in a security
  document promised a property the code could not sustain.

  What is *not* claimed: this is not a vulnerability, no input triggers it, and
  nothing misbehaves. The rejection sampling in `challengeField` is correct —
  re-keyed between attempts, no wasted bytes, uniform on `[0, p)` — and that is
  written down too, so the section is not read as "it is broken". The bound is
  narrow and says where it sits: `std.crypto.hash.Blake3` underneath is
  externally verified; **the composition** — chaining, length encoding,
  re-keying discipline — has no external witness.

  **This does not close the verification and does not say it does.** The
  known-answer vector does not exist today and is not written: a hard-coded
  `expected` produced here would be instance 1 of our own rule wearing the
  appearance of a vector. `zig-transcript`'s README carries one line saying the
  same, without alarm, so nobody leaves the library page with the impression
  that a third party can reproduce the challenges.

  **The route to closing it is the owner's decision, and it now has a named
  target on the best rung of the provenance ladder:**
  `draft-irtf-cfrg-fiat-shamir` (Orrù, IRTF CFRG, Informational; revision
  `-03`, 17 August 2026) specifies the duplex sponge, the codecs and the NARG
  serialization with **39 published vectors** in Appendix B — 13 codec, 13
  SHAKE128, 13 TurboSHAKE128. Every part a STARK transcript needs is specified
  byte-level and vectored: absorb without separators, the squeeze stream,
  prefix-free encoding, field-element challenge decoding (B.2.11, plus a
  degree-2 extension at B.1.3), session-identifier derivation from an
  application tag (B.2.10), and negative cases. Appendix A is a sumcheck over
  **Mersenne31** and B.2.12 is its complete transcript — `Mersenne31` is this
  repository's `Prime31`, and `Sumcheck(Prime31)` is the protocol already here.

  This replaces an earlier recommendation of Plonky3 as the specification
  target. Plonky3 has a widely-used, well-documented *implementation*; that is
  the same step below as comparing a hash against its reference
  implementation — which is what the BLAKE3-against-`std` fix was, and it was
  worth doing, but it is a rung below a specification with vectors. Plonky3
  stays useful as a second implementation opinion, not as the spec.

  Three corrections to what the draft is usually described as, written down so
  nobody has to rediscover them: it is **not expired** (expiry 18 February
  2027); the word "overwrite" appears **zero** times in it and `Init` takes a
  **32-byte** session identifier padded to the rate, not a 64-byte IV; and there
  are **two** suites, SHAKE128 and TurboSHAKE128, both at `R = 168`. **STARK and
  FRI appear zero times** — the model is a k-round public-coin protocol that a
  FRI is expressible in, but no FRI-shaped transcript is vectored, so that gap
  is a mapping argument we owe, not a missing instrument.

  **And a correction to this repository's own wording.** The advisory calls our
  rejection sampling in `challengeField` correct, and it is — but the draft's
  §4.2.2 *SHOULD NOT* use rejection sampling, for the constant-time reasons in
  its §8.2, and specifies `LE2IP(Squeeze(Ns + 16)) mod M` with the 16 extra
  bytes bounding the bias to 2^-128 instead. Both are sound and they are not the
  same choice: migrating is a **change of criterion, not a bug fix**, recorded
  here so it is not later read as a regression and reverted. The draft's
  assumption is also stronger than plain indifferentiability — extraction- and
  simulation-friendly [CO25], loss quadratic in random-oracle queries, which is
  the term to watch for a transcript with many FRI queries.

  **Nothing is implemented.** No code written against this route, no dependency
  added, derivation untouched. The vectors have not been read into this tree,
  and the decision to migrate is the owner's.

  Consumers inherit this: `zig-zk`'s STARKs, and the 31-bit-field assumption
  already recorded at `libs/binary-field/src/prime128.zig:5`. This advisory does
  not fix it, it makes it visible, and it has to land before the consumer's,
  which cites it.

- Requirement 14 is no longer a coverage debt waiting to be paid. It now names
  the outstanding decision.

### Fixed

- **`libs/hash` used a hand-rolled field instead of the one in `zig-field`.**
  `libs/hash/src/root.zig` declared a minimal `F7` for its algebraic-hash tests
  and `libs/hash/src/main.zig` declared its own for the demo — two copies, 16
  and 17 methods respectively, including an `invChecked` that had never been
  executed. They had already diverged from the library they duplicated: the
  copy's `divChecked` returned `InverseOfZero` where `zig-field`'s returns
  `DivisionByZero`, and a test was asserting the copy's error set. Both are
  deleted; `libs/hash` now depends on `zig-field` and uses `zf.Field(7)`. The
  library did not depend on `zig-field` because nobody had decided that a
  consumer should — the failure mode the `AGENTS.md` rule about new
  capabilities describes, inside the repository that writes the rule.

### Added

- **Tests that bring four previously untestable guards down**, written
  mutation-first: the mutation, the gate that sees it, then the guard restored.
  `merkle`'s `validPathIndex` boundary, `bigint`'s negative-modulus check,
  `algebra-traits`'s `invChecked`, and a `kzg` record. The mutation log in
  `docs/requirements.md` grows from twenty entries to twenty-four, and
  `merkle` (18 -> 19), `bigint` (19 -> 20) and `algebra-traits` (4 -> 5) each
  gain the test that their guard needed.

### Security

- **`libs/transcript`'s challenge derivation implements no published
  specification, and is therefore not verifiable today.** It is a house design
  — `std.crypto.hash.Blake3`, a domain string, length-prefixed absorbs,
  finalise-and-rekey — and nothing in the file cites an RFC, an EIP or a
  reference implementation. Its ten tests are properties that any
  deterministic function satisfies, a counter included, and a mutation confirms
  the gap: perturbing the finalised digest by one changes every challenge and
  all ten tests pass.

  **No known-answer vector is provided**, and none is written here, because a
  hand-written `expected` in this repository would carry the appearance of
  provenance without the substance — worse than no vector, because a reader
  stops looking. Every Fiat-Shamir challenge in every project that uses this
  transcript rests on a construction nobody can check against anything. Closing
  this is a design decision: match the construction to a published transcript
  and adopt its vectors, or record the reproducibility of the challenges as an
  accepted assumption. `SECURITY.md` carries the detail.

- **Added: the four checked halves for the subgroup condition, additively.**
  `millerLoopChecked`, `pairingChecked`, `pairingSparseChecked` and
  `pairingDenseChecked`, each `error{G1NotInSubgroup, G2NotInSubgroup}!Fp12T`.
  **No total signature changed** — `kzg`, `bench` and the tower module call the
  totals and are untouched. The two errors are separate so a caller can tell
  which side failed, where the original combined `or` could not.

  The shape is the repository's own: `millerLoopPair` /
  `millerLoopPairChecked` twenty-five lines from `millerLoop`, and `inv` /
  `invChecked`. The four totals keep failing open and each doc comment now
  names its checked half and states the loss: for an invalid input it returns
  `Fp12T.one()`, and **that identity is indistinguishable** from a legitimate
  pairing that is the identity. That is the reason the checked half exists, and
  it is written down rather than implied.

  The G2 side is witnessed now, which it was not before. BN254's G2 cofactor is
  not 1, so a test builds an on-curve `q` outside the prime-order subgroup,
  confirms it with library code (`isOnCurve`, `!isG2InSubgroup`,
  `!q.scalarMul(r).infinity`), and requires all four checked halves to return
  `error.G2NotInSubgroup` while all four totals return the identity. The
  positive comes first in the same test — an in-subgroup pair must pair to
  something that is not the identity, or the negative would mean nothing.
  Removing the G2 guard from `pairingSparseChecked` makes that test fail.

  Requirement 17 moves from not satisfied to satisfied. The test that pinned
  the old behaviour was named "rejects off-curve pairing inputs" while its body
  asserted the identity; it is renamed to what it does, and now also asserts
  `error.G1NotInSubgroup`.

- **Named, because it is a fail-open and not a missing check: off-subgroup
  pairing inputs return the identity.** `bn254_tower.millerLoop`,
  `pairingSparse` and `pairingDense` each begin with
  `if (!isG1InSubgroup(p) or !isG2InSubgroup(q)) return Fp12T.one();`, and all
  three are declared `Fp12T`. The rejection is a value, so a caller pairing a
  point outside the prime-order subgroup gets the identity and no indication,
  and cannot tell it from a pair whose pairing genuinely is the identity.

  **It is specified, not accidental:** `bn254_tower.zig:500` is a test named
  "rejects off-curve pairing inputs" that asserts exactly `…eql(Fp12T.one())`.
  The name says "rejects" where the mechanism is "returns the identity", and
  that naming is the part worth correcting in a reader's head.

  It also matches this repository's own convention twenty-five lines away:
  `millerLoopPair` is a total wrapper returning a defined value and
  `millerLoopPairChecked` reports the condition, a split whose comment records
  why — a `std.debug.assert` compiled out in `ReleaseFast` produced a garbage
  `Fp12T`. These three have the total half and **no checked half**. The
  in-policy remedy is a `Checked` counterpart, which is additive and matches
  `inv`/`invChecked`; it is not applied here, because changing public API that
  `kzg`, `bench` and the tower module call is a contract change and belongs in
  its own commit with its own review. The G1 side reduces to `isOnCurve()` and is
  covered; whether a `q` outside the G2 prime-order subgroup is reachable is
  **not verified here** — what is verified is that the signature admits no way
  to signal it either way.

- **`kzg`'s two input guards are not coverage gaps but dead code.** `verify`'s
  on-curve check is implied by the subgroup check that follows it, since
  `isG1InSubgroup` already requires `isOnCurve()`; and the subgroup check has no
  reachable witness from this library's tools. Both guards are kept — removing
  one is a contract change and belongs in its own commit — and both are marked
  decorative rather than cited as coverage.

- **`zig build cross-check` compiles the eight library examples.** Each
  `libs/*/src/main.zig` is its library's `example` executable, and until now the
  root build and every CI job compiled only the library's root source. Those
  files were reachable by `cd libs/<name> && zig build install` and by nothing
  else, which is how `libs/rng/src/main.zig` kept a `std.debug.assert` no gate
  had ever compiled. The step now produces 34 test binaries and 16 example
  executables (eight libraries × `x86_64-windows-gnu` and `aarch64-macos`), and
  the first build of `hash`'s example is what surfaced the field fork above —
  so the gate paid for itself before it was finished.

### Versioning

- Root `build.zig.zon` is now **`0.5.3`** (was `0.5.2`); every library keeps
  its own independent semver. Manifests bumped for this release:

  | library | was -> now | why |
  |---|---|---|
  | `bigint` | 0.3.0 -> **0.4.0** | **breaking**: `egcd` returns an error union instead of being undefined behaviour; `modExp` names `error.InvalidModulusWidth` |
  | `binary-field` | 0.4.1 -> **0.5.0** | new public `fromBytesChecked` on `BinaryField`/`TowerField` |
  | `pairing` | 0.4.0 -> **0.5.0** | the four checked entry points |
  | `transcript` | 0.1.0 -> **0.2.0** | `challengeFieldChecked` |
  | `field` | 0.4.0 -> **0.4.1** | ZA-2026-004, and the four `hash` bodies that did not compile |
  | `fri` | 0.3.0 -> **0.3.1** | challenge entry point switched; **sequence unchanged**, pinned by the v0.5.2 KAT |
  | `hash` | 0.4.0 -> **0.4.1** | now depends on `zig-field`; digests unchanged |

  `algebra-traits` and `merkle` carry tests only; `curve`, `kzg`, `linalg`,
  `ntt`, `parallel`, `poly`, `rng` and `serialization` are untouched. The
  range stays `0.1.3` (`merkle`) to `0.5.0` (`binary-field`, `curve`,
  `pairing`).

- **Test counts, measured at both ends rather than carried forward.** At the
  `v0.5.2` tag the root step ran **417 tests in 17 binaries** and the
  packages summed to **533** — a 116-test region (the `field` and `curve`
  `tests/` roots) that no root gate had ever opened. `086234a` wired those
  roots into the step; at `v0.5.3` the root runs **545 tests in 27
  binaries**, which equals the per-library sum, in both Debug and
  ReleaseFast. The four tests since (`bigint` +3, `fri` +1) sit on top of
  that closure.

## [v0.5.2] — 2026-09-27

> **This note used to open "Not yet published; the tag follows the audit."
> Written before the tag, and a state assertion therefore expired the moment
> the state moved: `v0.5.2` was published on 2026-09-27, the remote tag
> `13ceafd` peeling to `a22dbd9`.** What the note was arguing for matters more
> than its expiry: `v0.5.1` is published and frozen at `22df684` and is **not**
> re-pointed, so this fix could not go into it — the mechanism is in the
> header. A soundness fix on a patch number is worth naming rather than
> hiding: the APIs are unchanged and no wire format moved, but the digests do
> not carry forward. `v0.6.0` would be equally defensible; 0.5.2 keeps the
> patch distance from the tag that carries the stale paragraph, which is
> itself evidence.

### Security: `zig-hash`'s Blake3 was not BLAKE3, in every release

**The sequence, because a state assertion here would expire.** `zig-hash`'s
`Blake3` did not implement BLAKE3 from the monorepo's first commit `86605a1`
through `v0.5.1` inclusive. It was fixed on `main` in `a5d197a`, and `v0.5.2`
is the first release containing the fix. So: if you need BLAKE3 commitments that
another implementation will verify, use `v0.5.2` or later, or call
`std.crypto.hash.Blake3` directly.

It was a self-consistent compression producing a wrong digest for every input.
Every commitment made under it is not a BLAKE3 commitment.

**Affected:** everything committing through `zig-hash`'s Blake3 — the
`MerkleTree` and `MMR` constructors in `merkle/root.zig`, and the query-point
binding in `binary-field/src/pcs.zig`.
**Not affected:** the Fiat-Shamir challenge derivation. `zig-fri` and
`zig-transcript` both use `std.crypto.hash.Blake3`, not this one, so no challenge
in this repository was ever derived from it. The exposure was commitments and
Merkle openings, not challenges.

The reported cause was not the cause. `compress` already matched the BLAKE3
reference byte for byte, including the `state[12..15]` layout, and it was not
changed. Two defects were in the finalisation:

1. The root output was a **second** compression, over the already-compressed
   state, an all-zero message block and `block_len = BLOCK_LEN`. In BLAKE3 the
   ROOT flag belongs in the single final compression, over the pre-compression
   chaining value and the real last block. The tree was BLAKE3; the
   finalisation was not.
2. The block buffer was never zeroed after a full block was compressed, and was
   declared `undefined` at construction, so a stale tail leaked into the last
   block. Observable only from 65 bytes of input.

**The existing known-answer test was the worst case, not a mitigation.**
`cryptographic hash known-answer vectors` asserted a Blake3 digest for
`"hello world"` that this implementation had produced itself — `bd214b44…`
where BLAKE3 gives `d74981ef…`. A vector whose provenance is "we ran the code"
is not a known-answer vector; it pins the bug and passes forever while looking
rigorous. Corrected. The `blake2b`, `blake2s`, `keccak` and `sha3` vectors in
that same test were already correct against `hashlib` and are untouched, so
Blake3 was the only broken primitive in the tree.

The new coverage is 45 canonical vectors from an independent implementation:
0–8 and 63–65 bytes, and every length in 1018–1030 and 2042–2054 plus
4095–4097, because BLAKE3's chunk is 1024 bytes and a single-block vector never
exercises the counter, the cross-chunk chaining, or the parent tree.
`fuzz_runner.zig` additionally differential-tests against
`std.crypto.hash.Blake3`; the nightly never hashed anything before, which is the
third reason the bug survived.

Versions: `hash` 0.3.0 → **0.4.0** (MINOR — its output is what was wrong, so
stored data does not carry forward), `merkle` 0.1.2 → 0.1.3, `binary-field`
0.4.0 → 0.4.1 (PATCH — no API or wire-format change, only the values).


### Corrections to this changelog

- The per-library test counts in the `v0.5.0` entry below were wrong when
  written and were carried forward across four releases. The root step's 391
  was right; the per-library total was **505**, not 507, because `field` runs
  **83** tests, not 85. Verified by running the suite at `72a4343`, the commit
  that introduced the figures -- the runner already disagreed there, so nothing
  was ever lost, only misreported. Corrected in place rather than left to
  propagate again. The current figures (root 421, per-library 535) are in
  AGENTS.md.

## [v0.5.0] — 2026-09-27

> **Created as a local tag and never pushed; as of 2026-09-27 there is no
> `v0.5.0` on the remote.** Nothing below reached a consumer, which is why the
> broken `zig build bench` documented in the header costs nobody anything. Kept
> un-moved and signed as a record of the order; its content is also in
> `v0.5.1`, published the same day.

### Security (P0 class, second sweep — advisory ZA-2026-003)

The 0.4.0 sweep (ZA-2026-002) covered six libraries. A second, exhaustive sweep
of every `std.debug.assert`, `catch unreachable` and `@panic` in the tree found
the same defect class in **ten more**. Each one was a real bounds or
arithmetic hazard in `ReleaseFast`, not a cosmetic assert:

- **algebra-traits** (0.2.0 -> **0.3.0**): `dotProduct` and
  `lagrangeCoefficient` return `error.LengthMismatch` / `error.IndexOutOfBounds`
  (the `for (a, b)` loop read past the shorter slice), and
  `lagrangeInterpolate` returns `error.LengthMismatch` instead of indexing `ys`
  out of bounds. The in-file `F7` gained `invChecked` / `divChecked`; `inv` and
  `div` are total. **BREAKING:** all three are error unions now.
- **poly** (0.1.1 -> **0.2.0**): the fixed `[max_degree + 1]F` coefficient array
  was written past its end on an over-long `fromCoeffs` or an over-degree `mul`.
  `fromCoeffs`, `mul`, `compose` and `pow` return `error.DegreeTooLarge`;
  `divRem` / `div` / `rem` return `error.DivisionByZero` (a zero divisor made
  the long-division loop non-terminating); `lagrangeInterpolate` returns
  `error.LengthMismatch` / `error.EmptyInput` / `error.DegreeTooLarge` /
  `error.DivisionByZero`; `vanishingPolynomial` returns `error.DegreeTooLarge`;
  `vector.inner` / `vecAdd` / `vecSub` / `hadamard` return
  `error.LengthMismatch`. `fromArray` keeps a comptime array literal and
  `@compileError`s on an oversized one. **BREAKING:** all of the above are error
  unions. Two previously declared-but-broken functions now work:
  `p.derivative()` (an `@intCast` with no result type) and `p.toString(buf)`
  (returned `!usize` from a `![]u8`).
- **linalg** (0.1.1 -> **0.2.0**): `identity`, `trace`, `determinant`, `lu` and
  `solve` return `error.NotSquare`. `identity` on a non-square `Matrix(F, r, c)`
  wrote `m.data[i][i]` past the end of the shorter rows. **BREAKING:** error
  unions; `solve` is now `error{NotSquare}!?Vector`.
- **fri** (0.1.1 -> **0.2.0**): `Domain.init` returns `error.DomainTooLarge`
  (the `two_adicity - log_n` shift underflowed, and `1 << shift` with a shift
  >= 64 is undefined behaviour), `Domain.fill` returns
  `error.LengthMismatch`, and `FriError` gained `DomainTooLarge` and
  `OrderTooLarge`. **`verify` was also missing a check:** it compared
  `log_domain` against `F.two_adicity` but not `log_final`, and `log_final`
  comes from the proof, so a config whose `log_final` exceeded the two-adicity
  underflowed the shift inside `Domain.init`. `verify` now returns `false` in
  that case. **BREAKING:** error unions.
- **curve** (0.4.0 -> **0.5.0**): `msm` returns `error.LengthMismatch` (the
  scalar snapshot loop read past `scalars`). `ByteScalar.add` / `sub` / `mul` /
  `inv` / `neg` / `fromBytes` return `error.NotCanonical` — they
  `catch unreachable`d the stdlib non-canonical rejection, so a wire scalar >=
  the group order aborted the process; `reduce` remains the total entry point.
  `group_ops.scalarMul` and `group_poly.evalGroupPoly` / `evalGroupPolyVerify`
  return `error.NonCanonicalScalar` for a stdlib pcurve point and a
  non-canonical byte scalar. **BREAKING:** error unions.
- **ntt** (0.1.1 -> **0.2.0**): `bitReverse` returns `error.InvalidLength`
  (`@ctz(0)` on an empty slice is undefined), `ntt` / `intt` return
  `error.LengthMismatch`, `nttWithTwiddles` / `inttWithTwiddles` add
  `error.InvalidTwiddles` for a wrong table or stage length, and all of them
  plus `precomputeTwiddles` return `error.LogTooLarge` because `2^log_n` was
  computed with `std.math.pow(usize, 2, log_n)`, which overflows for
  `log_n >= @bitSizeOf(usize)`. **BREAKING:** error unions.
- **field** (0.3.0 -> **0.4.0**): `batchAdd` / `batchSub` / `batchMul` and
  `multiExp` return `error.LengthMismatch` on both backends;
  `Ipa.innerProduct` and `Ipa.commit` return `error.LengthMismatch`;
  `primitiveRootOfUnity` returns `error.OrderTooLarge` and `rootOfUnity` adds
  `error.NotPowerOfTwo` (`std.math.log2(0)` is undefined), on both base-field
  backends and on `QuadraticExtension` / `CubicExtension`. Added
  `toU64Checked` (`error.Overflow`); `toU64` keeps truncating. Removed
  `src/ntt.zig` and `src/merkle.zig`, unreferenced duplicates of `zig-ntt` and
  of `MerkleTree` in `lib.zig` (the field README already said the generic
  transform lives in `zig-ntt`). **BREAKING:** error unions.
- **rng** (0.3.0 -> **0.4.0**): `Shake256Rng.absorbSeed` and `finalize` return
  `error.AlreadyFinalized`; absorbing or re-finalizing after the sponge was
  squeezed corrupted its state in `ReleaseFast`. `squeezeInto` is an error union
  for the same reason. The `byte_len` guard in `randomFieldElement` is now a
  `@compileError` (it is comptime-known either way). **BREAKING:** error unions.
- **hash** (0.2.0 -> **0.3.0**): `Poseidon(...).initFromSeed` returns
  `error.NoValidMdsEntry`; the `assert(attempt < 256)` on the MDS search was
  compiled out in `ReleaseFast`, where a failed search left `y[j]` undefined
  and produced a singular MDS matrix. The `t >= 3` sponge requirement moved to
  a `@compileError` in the `Poseidon` factory. **BREAKING:** new error in the
  set.
- **pairing** (0.3.0 -> **0.4.0**): `inv` is total (`inv(0) == zero()`) on the
  cubic extension, both Fp6 towers and `Fp12Direct`, each with an `invChecked`
  sibling; the closed-form inversions used to divide by a zero norm. Added
  `millerLoopChecked` (bn254), `millerLoopPairChecked` (bn254 direct and tower),
  all returning `error.PointAtInfinity`; the unchecked `millerLoop` /
  `millerLoopPair` fall back to the identity element instead of producing a
  garbage Fp12. `Fp12Direct` gained `invChecked`.

### Fixed (not a P0 defect)

- **`format` methods were dead code.** Eight `format` implementations
  (`zig-field` base and both extension towers, `zig-bigint`, `zig-poly`,
  `zig-linalg`, `zig-pairing`, `zig-algebra-traits`) still declared the
  pre-0.16 signature `(self, comptime fmt, options: std.fmt.FormatOptions,
  writer)`. Zig 0.16 only consults a method named `format` for the **`{f}`**
  specifier, and with that signature nothing consulted it at all, so every
  `std.debug.print("{}", .{value})` printed the default struct dump. All eight
  are now `pub fn format(self, writer: *std.Io.Writer) std.Io.Writer.Error!void`
  and work with `{f}`. This is why `zig-poly`'s `toString` now yields
  `1 + 2*x + 3*x^2` instead of a struct listing.

## [v0.5.1] — 2026-09-27

> **Published 2026-09-27 at `22df684`.** Its run (36328763514) was green on
> all three operating systems at 416/416 each, and it was the first tag push in
> this repository to trigger the gate at all. This section is therefore frozen:
> the tag cannot be re-pointed, and the changelog correction that follows
> `22df684` on `main` is **not** in it. See the header for the full sequence and
> for what that costs.

The follow-up to 0.5.0: the fix for the broken `zig build bench` described
above, the release gate whose absence let that happen, the assert ledger, the
two packaging fixes, and the characteristic-agnostic Lagrange and folding
arithmetic. Two releases in a row is not churn. 0.5.0 closed a P0 class
across ten libraries; 0.5.1 closed the release process, and found a
sign-inversion bug that only a prime field could expose.

> **The version jump from 0.3.2 to 0.5.1 skips two MINORs on purpose.** In
> `0.y.z` the MINOR carries the incompatible changes, and both `[v0.4.0]` and
> `[v0.5.0]` are present above with their full contents, so a consumer reading
> `0.5.1` reads the complete history rather than a gap. Writing it down so the
> next session reads it as a decision instead of an oversight: the intervening
> MINORs were created locally and never pushed, and the work in them was real.

### Corrections to this changelog

- The `pcs.zig` beta_r generalization was described in an earlier draft of the
  internal decision notes as landing with the first pass of this work. It did
  not; it landed afterwards, on its own. It is done now, with the soundness
  argument recorded: the summand is degree 1 in each variable under either
  expression, so the sum-check degree bound and the `k+1` summand count are
  unchanged.
- `PackedMle` is characteristic-2 specific and is **not** generalized here. See
  the entry below and `libs/binary-field/README.md`.

### Packaging

- **`zig-fri` was unconsumable as a package (0.2.0 -> 0.3.0).**
  `build.zig.zon` declared `.dependencies = .{}` while `src/root.zig` imports
  `zig-field`, `zig-merkle` and `zig-transcript`, and `build.zig` hand-wired
  all three from `../transcript/src/root.zig` and friends. A consumer resolving
  `zig_fri` got no dependencies, and the relative paths it would have needed do
  not exist in a package cache. It was the only library in the workspace not
  using `b.dependency`; it now declares its three dependencies and resolves
  them through the package manager.
- **`zig-parallel` could not be imported at all (0.1.1 -> 0.2.0).** Its
  `build.zig` never called `addModule`, so it exposed no module to consumers.
  That is the reason `zig-binary-field` carried a local fork of the fork-join
  `Pool`, and it is worth stating as a root cause: a library that cannot be
  consumed gets copied, and the copy drifts. The fork had lost the SPDX header
  and the module docs and diverged in its doc comments while the logic stayed
  identical, and its two tests were byte-identical duplicates of
  `parallel`'s — so it looked like the fork had its own coverage of the `Pool`
  when it was running the same two tests a second time. `pool.zig` is deleted
  (0.4.0) and `sumcheck.zig` imports `zig-parallel` directly. Test count
  therefore drops from 383 to 381 (and `binary-field` from 76 to 74) with no
  loss of coverage: the duplicated assertions no longer run twice.


### Added

- **`fuzz`: the nightly "mass fuzz" actually fuzzes, and can fail.**
  `timer_seed` was `0xF00D`, a constant named as if a timer had set it, so
  every night re-checked the same 1.12M field values and 110 pairing pairs and
  printed "all fuzz checks passed". Two things were wrong. It imported only
  `zig-field`, `zig-curve` and `zig-pairing`, so it never constructed a
  `Sumcheck`, a prime fixture or a torus domain -- green through three releases
  while the characteristic-2 fold sat in `sumcheck.zig`. And it now covers
  `zig-binary-field` and `zig-fri`: prime-field axioms, `Prime128` against a
  native `u256 % p` oracle, Sumcheck round trips on both entry points, and FRI
  round trips over the torus in M31 and M61. The seed comes from the clock, is
  printed on the first line, and replays with `zig build fuzz -- <seed>`.
  All three new sections were watched failing: `foldLinear` reverted to
  `a + t*(a + b)` reports `honest 0/80 verified`, an off-by-one torus
  generator reports `OrderTooLarge`, and a broken `add` reduction fails the
  pre-existing runner.
  Worth recording that the first version of the Sumcheck check was **wrong
  about the protocol**: it asserted random data must be rejected, and failed
  80/80, because `Sumcheck` proves the hypercube sum, which any table admits.
  Low degree is FRI's claim, not its.
- **`fri`: FRI over the norm-1 torus of `F[p^2]`, so `M31` and `M61` work.**
  `prove`/`verify` now have `proveOn`/`verifyOn` siblings that take the domain
  as a parameter (`prove`/`verify` are unchanged wrappers over `Domain(F)`).
  `torus.zig` builds a domain on the torus `T = {N(x) = 1}`, which is cyclic of
  order `p + 1` -- and for a Mersenne prime that is the whole point:
  `2^31 - 1 + 1 = 2^31`, so a field whose base two-adicity is **1** gets a FRI
  domain of size `2^31`. M61 gets 61. The `root.zig` header said "M31 has
  two-adicity 1 and cannot be used here"; that was true of the base field and
  false of the package, and is corrected in the same commit.
  The generator is derived by Cayley parametrization in raw `u128` arithmetic
  and then re-checked through the field's own `pow`, because construction and
  verification being the same computation would prove nothing. Two
  qualifications the obvious summary would have got wrong: the torus is **not**
  an improvement in general (for Goldilocks `p + 1` has 2-adicity 1 against the
  base field's 32, which is why FRI keeps the multiplicative subgroup there),
  and `F[p^2]`'s own `two_adicity` (32 for M31) is also large enough, so the
  torus is the domain you want for its structure rather than the only one that
  runs. 2's invertibility, which the fold's `1/2` depends on, is stated and
  checked rather than assumed.
- **`binary-field`: a 128-bit prime fixture, `Prime128`** (`p = 2^128 - 159`).
  The first field in this workspace that runs the **secure** `Sumcheck(F)`
  entry point rather than `SumcheckUnsafe`, which is what exposed the fold
  above. It carries a Pocklington primality certificate (`F = 42113237 ·
  62826870453001 > √p`, witness `a = 2`) because `2^128 - 1` passes a 128-bit
  size gate while being composite, and its independent oracle is native
  `u256 % p` against the field's algebraic `2^128 ≡ 159` fold — different
  techniques, so agreement is a real witness. `Prime31` is kept: its `u64`
  oracle is exact, and it still asserts that `Sumcheck(Prime31)` rejects the
  field.


### Fixed

- **`zig-rng` did not compile on Windows.** `libs/rng/src/csprng.zig` called
  `BCryptGenRandom(null, ...)` against `windows.HANDLE`, which is `*anyopaque`.
  A bare `null` does not coerce to a non-optional pointer in Zig 0.16, so the
  whole `zig-rng` test binary failed to compile on `windows-latest` and its 25
  tests never ran. The build summary reported `391/391 tests passed` — 416 minus
  the 25 that could not build — which reads like a pass. Microsoft documents the
  handle as optional (NULL means "system-preferred RNG"), so the declaration is
  now `?windows.HANDLE`; the ABI is unchanged. Pre-existing since the P0 sweep
  (`1e53043`), not introduced by this release's work, but it was the only red
  job and therefore a release blocker.

  **This is the fourth instance of one class: a file or module that is built but
  never type-checked as a test root, on some axis.** The first was
  `libs/rng/src/main.zig`, which the 0.4.0 P0 sweep missed because no test step
  ever compiled it as a test root. The second and third were packaging
  (`bbc08ff`: `fri` was not a consumable package). The fourth is this one, and
  the axis is the **operating system**: every Linux run was green, the Ubuntu CI
  job was green, `zig build fuzz` was green, because the error sits in a branch
  the host never takes. The multiplatform gate did not see it for exactly the
  reason the `src/`-only gate did not see `main.zig` — the thing that is not
  checked is the thing that breaks.

- **New gate: `zig build cross-check`,** which compiles every library's test
  binary for `x86_64-windows-gnu` and `aarch64-macos` and installs it without
  running it, plus a `cross-check` CI job. This is the check that would have
  caught the item above locally, in seconds, rather than through one 2m35s CI
  job. It was verified by reverting the one-line fix and watching it report the
  identical error the Windows job did. The blind spot is the mirror image of
  the characteristic-2 fold: there, char-2 runs could not fail on a linear bug;
  here, the Linux-only runs could not fail on a Windows-only compile error.

- **Lagrange and folding arithmetic in `zig-binary-field` is now
  characteristic-agnostic where it was not.** The Lagrange basis, its
  normalisation denominator, and the multilinear fold were all written with
  `add` because over GF(2^m) `a - b == a + b` is a law rather than a
  coincidence. That makes the expressions untestable in this library: no
  binary-field test matrix can distinguish `x - y` from `x + y`, and no
  transcription error in either is observable. Instantiated over a prime field
  the interpolation of `3 + 5x` returned `3 - 5x` -- every coefficient above
  the constant sign-inverted, undetectable in characteristic 2.
  - `Multilinear.eval` and `Multilinear.extend` now fold with
    `(1 - r_i)*a + r_i*b` (`polynomial.zig`).
  - `Sumcheck.interpolateCoeffs` now builds the basis with
    `prod_{j != i} (t - x_j)` and normalises with
    `prod_{i != j} (x_i - x_j)` (`sumcheck.zig`). The basis recurrence was a
    sixth occurrence of the same shape, not in the original inventory.
- **`PackedMle` is deliberately NOT generalized, and the reason is now
  recorded in the code.** The obvious one-line change to `lagrangeBasis` is a
  no-op over GF(2^m), so the suite could not confirm it, and instantiating
  `PackedMle` over a prime field shows `interpolate`/`eval` does not round-trip
  with `sub` either -- the specialisation is not confined to that one `add`.
  Changing it would make a characteristic-2 structure *look* general without
  being general, so it stays char-2 and says so.
- **`Pcs.kernelTables` now builds the Lagrange kernel in the general form**
  `l_j(t) = (1 - r_j) + (2·r_j - 1)·t` rather than the characteristic-2 form
  `t + (1 + r_j)`. The two are identical over GF(2^m); the general form is what
  holds over a prime field, and the discriminators `2·r_j` and `-1` are
  identically the char-2 values there. The summand stays degree 1 in each
  variable, so the sum-check's degree bound -- what the soundness argument rests
  on -- is unchanged, as is the count of `k+1` multilinear summands. Because the
  argument is always a hypercube bit, only the line's values at 0 and 1 are
  needed and the slope is never formed.
- **`prime_fixture.zig`** adds a small prime field whose modulus is proved prime
  by exact trial division at comptime, and which is checked against an
  independent `u64` oracle before being used as a substrate. The primality check
  is load-bearing rather than decorative: `2^128 - 1` has bit length 128, so it
  clears a `BITS >= 128` gate, and it is composite
  (`2^128 - 1 == (2^64 - 1)(2^64 + 1)`). A fixture built on it would pass every
  size gate and be nonsense. The tests are witnesses, not smoke tests: each
  asserts that the characteristic-2 form and the general form *disagree* on its
  input before asserting that the implementation returns the latter.


### Fixed

- **The sum-check fold was characteristic 2** (`binary-field`). `sumcheck.zig`
  folded each round with `a + t·(a + b)` in five places. That expression equals
  the linear kernel `L_t(x) = (1-t)·f(x) + t·f(1-x)` *only* where
  `1 - t == 1 + t`, i.e. in characteristic 2. Outside it, the fold is a
  different kernel from the one `verify` closes on, so **the verifier rejected
  honest proofs** over any odd-characteristic field.
  This was a **false negative, not a false positive**: the verifier closed on
  the correct linear kernel and the prover did not, so no forged proof was
  accepted and soundness was intact. The prover simply could not produce a
  proof that verified. The soundness break would have been the opposite
  arrangement -- the char-2 kernel also sitting in the verifier's closing
  equality, so that a kernel which is wrong over a prime field would have been
  accepting claims about primes. That is why it mattered; it is not what
  happened.
  Fixed by routing all five sites through one `foldLinear` helper, which is a
  bit-for-bit no-op under characteristic 2 — all pre-existing proofs are
  unchanged. This is the third bug in one family (after `interpolateCoeffs`'s
  `add`->`sub` and `kernelTables`' `beta_r`); all three are invisible to a
  characteristic-2 test matrix, and all three were found by a prime field.

### Versioning

- Root `build.zig.zon` is now **`0.5.0`** (was `0.4.0`); every library keeps
  its own independent semver. Manifests bumped for this release:
  `algebra-traits` 0.2.0 -> 0.3.0, `bigint` 0.2.0 -> 0.3.0 (the `format`
  signature), `curve` 0.4.0 -> 0.5.0, `field` 0.3.0 -> 0.4.0, `fri` 0.1.1 ->
  0.2.0, `hash` 0.2.0 -> 0.3.0, `kzg` 0.2.0 -> 0.2.1 (internal error
  propagation only), `linalg` 0.1.1 -> 0.2.0, `ntt` 0.1.1 -> 0.2.0, `pairing`
  0.3.0 -> 0.4.0, `poly` 0.1.1 -> 0.2.0, `rng` 0.3.0 -> 0.4.0.
  `binary-field`, `merkle`, `parallel`, `serialization` and `transcript` are
  unchanged, so the per-library range stays `0.1.0` (`transcript`) to `0.5.0`
  (`curve`).
- **Test counts.** The root `zig build test` step now runs **391 tests**
  (verified on Zig 0.16.0 in Debug and ReleaseFast), up from 354; per-library
  `zig build test` steps sum to **505**, up from 470, because `field` (83) and
  `curve` (98) also compile their separate `tests/` roots. Per-library totals:
  algebra-traits 4, bigint 19, binary-field 84, curve 98, field 83, fri 12,
  hash 18, kzg 6, linalg 11, merkle 18, ntt 15, pairing 58, parallel 2, poly 28,
  rng 25, serialization 15, transcript 10. (This entry originally claimed 507
  and `field` 85; the runner reported 505 and 83 at this commit. See
  "Corrections" under Unreleased.) The new tests are the negative cases
  for every error above (mismatched lengths, non-power-of-two lengths, over-
  capacity degrees, non-canonical scalars, points at infinity, out-of-range
  two-adicity, double finalization).
- **`algebra-traits` has tests now.** It previously shipped a `test` step with
  zero tests, so the generic algorithms were never exercised.

### Docs

- Every affected library README documents its new error union, and the
  "Known limitations" entries that described the old assert-based behaviour are
  replaced by the contract that now holds.
- `zig-ntt`'s README records that `root` itself is still unvalidated: only the
  buffer shape and `log_n` are checked, so a root of the wrong order still
  produces a wrong transform.
- `zig-field`'s README records the removal of `src/ntt.zig` / `src/merkle.zig`
  and the `{f}` formatting rule.
- `zig-poly`'s README now lists `compose` with a non-monomial `q` as the one
  remaining known gap; `derivative` and `toString` are fixed and removed from it.

## [v0.4.0] — 2026-09-27

> **Created as a local tag and never pushed; as of 2026-09-27 there is no
> `v0.4.0` on the remote** — like `v0.5.0`, this exists only in this
> repository. Kept un-moved and signed so the version history stays readable;
> its content is also in `v0.5.1`.

### Security (P0 class: asserted preconditions)

The preconditions of several public entry points were expressed as
`std.debug.assert`, which Zig compiles out in `ReleaseFast`/`ReleaseSmall`. A
violating input therefore panicked in Debug/ReleaseSafe and, in a release
build, hung, read/wrote out of bounds, or silently produced a wrong result.
All of these are now typed errors, with total legacy wrappers kept only where a
signature could not change. `SECURITY.md` records the full advisory as
**ZA-2026-002**; the highlights:

- **field** (0.2.0 → **0.3.0**): added `invChecked` (`error.InverseOfZero`),
  `divChecked` (`error.DivisionByZero`) and `batchInvChecked`
  (`error.LengthMismatch` / `error.InverseOfZero`) on `SmallField`, `BigField`,
  `QuadraticExtension` and `CubicExtension`, plus Montgomery's
  `invMontgomeryChecked`. **BREAKING in behaviour:** `inv`, `inverse` and `div`
  are total — `inv(0) == zero()` and `x / 0 == zero()` — where they previously
  asserted (Debug/ReleaseSafe) or spun forever in the binary-GCD loop
  (ReleaseFast). `randomBounded(rnd, 0)` returns zero instead of hanging,
  `Vec8.fromSlice8` zero-fills/truncates instead of reading past the slice,
  `MerkleTree(F).verifyBatch` fails closed on a length mismatch, and
  `nttVec8M31Checked` / `inttVec8M31Checked` report
  `error.InvalidLength` (the unchecked pair is now a no-op on a mismatch).
- **binary-field** (0.2.0 → **0.3.0**): `invChecked` on `BinaryField` and
  `TowerField` (`error.InverseOfZero`; the GF(2) base case also rejects a
  non-unit). `Multilinear.numVarsChecked` (`error.NotPowerOfTwo`) with `eval` /
  `extend` returning `error.InvalidPointLength`; `PackedMle` gained `MAX_K` and
  `checkK` and now returns `error.InvalidDimension` / `error.LengthMismatch`
  (`betaOnHChecked` likewise), and `novelEval` validates `k` and the coefficient
  length. **BREAKING:** `Sumcheck(F)` now requires `F.BITS >= 128` and returns
  `error.FieldTooSmall`; `MlePcs(F, E)` and `CommittedMlePcs(F, E)` apply the
  same check to their challenge field `E`. The
  new `SumcheckUnsafe`, `MlePcsUnsafe` and `CommittedMlePcsUnsafe` bypass it to
  keep the historical 4-bit on-chain challenge format — they are **toy/test
  only and not sound against a grinding prover**, and the library's own small
  field tests were switched to them.
- **merkle** (0.1.1 → **0.1.2**): `MMR.verify` shape-checks the proof before
  indexing it — the sibling and flag arrays must have equal length, and the
  depth must match the zero-padded tree (`2^ceil(log2(leaf_count))`) with the
  index below it. A proof whose two halves disagreed in length previously
  caused an out-of-bounds read of `is_left_sibling`.
- **rng** (0.2.0 → **0.3.0**): added `setEntropyChecked`
  (`error.EntropyTooLong` / `error.InsufficientEntropy`) and
  `entropyAvailable`. Legacy `setEntropy` now truncates to the 64-byte host
  buffer and zero-fills the tail instead of overflowing it; the host buffer is
  zero-initialised and a seed request longer than the injected entropy is
  refused rather than copying uninitialised memory. Added
  `setRandomForTestingSeed(?u64)`, whose state lives in the module;
  `setRandomForTesting` now stores a copy of the `std.Random` interface value
  and must be reset with `defer setRandomForTesting(null)` (the previous
  pointer form could outlive the caller's generator). `src/root.zig` added
  `refAllDecls`, without which the `csprng` tests were never collected.
- **serialization** (0.1.1 → **0.2.0**): `deserialize` treats its input as
  untrusted. A `u64` length prefix is validated against the bytes that remain
  and the per-element minimum wire size before anything is allocated
  (`error.InvalidLength`), and a failure part-way through rolls back every
  value already decoded, so a rejected input no longer leaks. **BREAKING:**
  `error.InvalidLength` is a new error in the inferred error set, and
  `error.TrailingBytes` now releases the decoded value through a path that does
  not depend on `deinit` being `pub`.
- **curve** (0.3.0 → **0.4.0**): `hashToPoint` returns
  `error{ DomainTooLong, NoValidPoint }!Point` and `generatorVector` returns
  `(DeriveError || std.mem.Allocator.Error)![]Point`, freeing its allocation
  when a derivation fails. The `catch unreachable` on the 64-byte label buffer
  and the `unreachable` on an exhausted try-and-increment search are gone; the
  domain limits are exported as `max_domain_len` and
  `max_generator_vector_domain_len`. **BREAKING:** both functions are error
  unions now, so existing `const p = hashToPoint(...)` call sites need `try`.

### Versioning

- Root `build.zig.zon` shipped **`0.4.0`** (was `0.3.2`); every library keeps
  its own independent semver in `libs/<name>/build.zig.zon`. The manifests
  bumped for this release are `field` `0.3.0`, `binary-field` `0.3.0`,
  `merkle` `0.1.2`, `rng` `0.3.0`, `serialization` `0.2.0` and `curve`
  `0.4.0`; every other manifest is unchanged, so the per-library range is
  `0.1.0` (`transcript`) to `0.4.0` (`curve`).

### Docs
- Documentation pass so every top-level document matches the current tree.
  Historical entries are retained, with factual corrections noted here.
- **Test counts.** The root `zig build test` step ran **354 tests** in this
  release (verified on Zig 0.16.0 in both Debug and ReleaseFast; the current
  tree is at 382 / 498 — see [Unreleased]); per-library `zig build test`
  steps sum to 470 because `field` (85) and `curve` (96) also compile their
  separate `tests/` roots. Older documents quoted 222, 297 and 316; the 297
  figure in `SECURITY.md` was accurate for the suite as it stood when advisory
  ZA-2026-001 was fixed and is kept there as history. Per-library totals:
  algebra-traits 0, bigint 18, binary-field 76, curve 96, field 85, fri 10,
  hash 17, kzg 6, linalg 9, merkle 18, ntt 11, pairing 54, parallel 2, poly 20,
  rng 23, serialization 15, transcript 10.
- **Library counts.** The workspace has 17 libraries. `kzg` is the 17th
  (added in v0.2.2); v0.1.0 shipped 14 libraries and v0.2.0 brought the total
  to 16 with `fri` and `transcript`.
- **IPA is a `zig-field` module, not a library.** The v0.3.2 "ipa" bullets
  refer to `libs/field/src/ipa.zig`. `Ipa.verify` is still a stub
  (`error.Unsupported`); the working path is `Ipa.verifyWithCommitment`, whose
  commitment is the inner-product commitment `C = <a,G> + <b,H> + c·U` (not a
  Merkle commitment), and its challenges are a local SHA-256 of `(L, R, round)`
  rather than a `zig-transcript` Fiat-Shamir session. The module is now listed
  under Known Limitations in `README.md` and Scope in `SECURITY.md`.
- **Validation contract documented.** `README.md` gained a table pairing each
  legacy total wrapper with its `…Checked` sibling, and every document now
  states that `inv(0) == 0` is a source-compatibility result, not a valid
  inverse, and that `SumcheckUnsafe` / `MlePcsUnsafe` / `CommittedMlePcsUnsafe`
  are unsound.
- **Feature lists corrected** to the code that exists: `zig-ntt` is radix-2
  power-of-two only (no mixed-radix, 2-D, batch or SIMD; the M31 `Vec8` NTT is
  in `zig-field`), `zig-poly` has schoolbook multiplication with no
  Karatsuba/FFT/GCD, and `zig-merkle` has binary/MMR/sparse trees with
  inclusion and non-membership proofs and proof serialization, but no Verkle
  tree or batch updates.
- **Dependency graphs** in `README.md`, `DESIGN.md` and `docs/architecture.md`
  now match the imports wired in the root `build.zig` and in each
  `libs/*/build.zig.zon` (notably `binary-field → merkle`, `fri → field`,
  `merkle → algebra-traits`, `kzg → field, curve, pairing`).
- **Memory claims softened.** There is no global "zero allocation" guarantee:
  fixed-size types stay on the stack, while the proof stack (`fri`, `kzg`,
  `Ipa`) and the Merkle/PCS/twiddle paths take a caller-supplied allocator and
  propagate `error.OutOfMemory`.
- **`zig build wasm` is implemented** (as is `zig build wasm-pairing`); the
  claim in `DESIGN.md` that the build target was pending is removed.
- **Benchmarks are labelled indicative** with the machine they were measured
  on; CI stores them as an artifact without regression thresholds.
- **No independent audit** is now stated in `README.md`, `SECURITY.md`,
  `DESIGN.md`, `docs/architecture.md` and `AGENTS.md`; the "production
  candidate" label means test-covered, not audited.
- **STARK demo field corrected** to Goldilocks (`examples/stark_prover.zig`) in
  `AGENTS.md` and in the `.github/workflows/test.yml` step name; the demo has
  used Goldilocks since it was introduced.
- **Stale `inv(0)` statements removed.** `libs/field/CHANGELOG.md` and
  `libs/field/TODO.md` claimed there was no `inv(0)` test because `inv`
  debug-asserted; both now describe the total legacy behaviour and the checked
  API.

## [v0.3.2] — 2026-09-25

### Added
- **field/hash**: RFC 9380 `expand_message_xmd`, `hashToField` and
  cofactor-aware `hashToCurve` APIs, with seed-length validation.
- **ipa**: algebraic verification of the inner-product commitment through
  `verifyWithCommitment` (not a Merkle commitment).
- **rng**: SHAKE256 sampling, Windows `BCryptGenRandom` entropy and serialized
  CSPRNG test hooks.
- **testing**: canonical BLS12-381 generators plus known-answer coverage for
  field, Blake3, Blake2, Keccak/SHA3, Poseidon, MiMC and M31 values.

### Fixed
- **fri**: added transcript path validation and Merkle-shape, degree, leaf,
  sibling and query checks; hardened KZG, BigInt, NTT, field, Poseidon and
  Merkle arithmetic and OOM cleanup.
- **proof stack**: Sumcheck and PCS entry points now validate arity, lengths and
  points; allocation-error paths release owned storage, including Merkle proofs.
- **wasm**: `fp_add` ignored its `b_lo`/`b_hi` arguments; now composes both
  128-bit operands correctly (matching `fp_mul`). CI gained value tests for
  `fp_add` (carry + hi-word cases) and a known-answer test for `fp_inv`.
- **portability**: replaced Linux-only timing with `zig-parallel`'s portable
  `timing.nowNs()` across examples and pairing benchmarks.
- **pairing**: corrected sparse Miller-loop squarings and chord-line signs;
  added sparse/dense, bilinearity and EIP-197 regression coverage.
- **input safety**: rejected low-order pairing points and invalid algebraic
  hash seeds; wide-field sampling now preserves rejection-sampling uniformity.
- **field**: removed data-dependent branches from Montgomery reduction and
  clarified the non-constant-time status of square roots and scalar
  multiplication.

### Changed
- **pairing**: BN254's tower implementation is canonical, and production
  `pairing()` uses the verified sparse twist-side loop with split final
  exponentiation (~17 ms versus ~30 ms dense).
- **rng**: rejection sampling returns typed range errors and is bounded by a
  fixed attempt limit.
- **examples/build**: updated Zig 0.16 output/import APIs, wired missing module
  dependencies and targets, and made the root ReleaseFast test step execute the
  full test suite.
- CI coverage now includes Windows and expanded wasm value tests.

### Changed (BREAKING)
- **kzg**: `commit` and the internal MSM now take a caller-supplied allocator;
  allocation errors are propagated instead of `catch unreachable`.
- **curve**: `scalarMul` on affine/projective Weierstrass points now uses a
  4-bit windowed left-to-right ladder in Jacobian coordinates (~8x faster;
  O(1) field inversions instead of one per addition). Still non-CT.
- **fri**: layer commitments now use the shared `zig-merkle` tree instead of a
  private duplicate (`zig-fri` gains a `zig-merkle` dependency edge).

## [v0.2.2] — 2026-08-26

### Added
- **kzg** (17th library): KZG polynomial commitments over BN254 — synthetic
  setup, commit/prove/verify against the verified optimal ate pairing and
  Pippenger MSM.
- **curve**: generic multi-scalar multiplication (naive + Pippenger with
  adaptive windows), plus latent curve fixes.

### Fixed / Tested
- **pairing**: known-answer vectors against py_ecc (EIP-197 reference).

## [v0.2.1] — 2026-08-25

### Added
- **wasm**: BN254 pairing module for JS/TS interop (`wasm-pairing` build step).

### Performance
- **pairing**: BLS12-381 split final exponentiation resurrected and verified
  (~32 ms steady-state optimal ate pairing).

### Docs
- DESIGN.md: BLS12-381 final-exponentiation notes; stage-anchoring pattern.

## [v0.2.0] — 2026-08-25

Performance and correctness pass across the pairing tower:
BN254 optimal ate via Fp6/Fp12 tower, dense py_ecc-faithful reference path,
cyclotomic compressed squaring, windowed final exponentiation, and the
STARK example stack (transcript → FRI) hardening.

## [v0.1.0] — initial release

14 libraries: algebra-traits, bigint, hash, rng, field, binary-field, curve,
pairing, merkle, ntt, poly, linalg, parallel, serialization — plus examples and
benchmarks.
