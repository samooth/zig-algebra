# Security Policy

## No independent audit

**No independent cryptographic audit exists for any library in this
workspace.** Passing the test suite, matching EIP-197/py_ecc known-answer
vectors and being covered by negative tests are *not* an audit. Every use of
this code — especially `pairing`, `fri`, `kzg` and `binary-field` — requires
your own review, threat model and parameter selection.

## Scope and non-claims

- **Constant time:** not guaranteed. Field inversion (binary GCD), BigInt
  comparison, square roots, curve `scalarMul` and both BN254/BLS12-381 pairing
  implementations are data-dependent. The Montgomery `mul`/`add`/`sub` core is
  constant-time; see `DESIGN.md` for the per-operation list.
- **Legacy total inverse/divide:** `inv(0) == 0` and `x / 0 == 0` in
  `zig-field` (both backends plus `QuadraticExtension` / `CubicExtension`) and
  `inv(0) == 0` in `zig-binary-field` (`BinaryField`, `TowerField`). These are
  **source-compatibility wrappers**, not a mathematical result: zero has no
  inverse, and `x * inv(x) == 1` does not hold for `x == 0`. Use
  `invChecked` / `divChecked` / `batchInvChecked`, which return
  `error.InverseOfZero`, `error.DivisionByZero` and `error.LengthMismatch`. The
  reason the wrappers exist at all is that the underlying binary-GCD loop does
  not terminate on a zero input, which used to be guarded by an
  `std.debug.assert` — a guard that vanished in `ReleaseFast`.
- **Binary-field sum-check over small fields:** `Sumcheck(F)` requires
  `F.BITS >= 128`; `MlePcs(F, E)` and `CommittedMlePcs(F, E)` require
  `E.BITS >= 128` for their challenge field. They return
  `error.FieldTooSmall` below that. `SumcheckUnsafe`, `MlePcsUnsafe` and
  `CommittedMlePcsUnsafe` skip the check, keep the historical 4-bit on-chain
  (Bitcoin Script) challenge format, and are **not sound**: a prover can grind
  small-field challenges. Treat them as toy/test-only code; they must never
  secure a remote proof.
- **KZG setup:** `Setup.generate` is synthetic (caller-chosen `tau`) and is for
  tests and development only. Production needs a verified powers-of-tau
  ceremony with toxic-waste destruction.
- **IPA:** `Ipa.verify` in `zig-field` is a stub that returns
  `error.Unsupported`; only `Ipa.verifyWithCommitment` verifies. Its challenges
  are a local SHA-256 over `(L, R, round)`, **not** a `zig-transcript`
  Fiat-Shamir session, so the module is not transcript-composable and is not
  safe to use as-is in a larger protocol.
- **Benchmarks:** `zig build bench` numbers are machine-specific measurements,
  not guarantees. CI stores them as an artifact with no regression thresholds.
- **Examples and demos:** `examples/*` and per-library `main.zig` programs are
  demonstrations, not protocol implementations.
- **Entropy:** `zig-rng` seeds its process-wide ChaCha20 CSPRNG from the OS
  (`getrandom` on Linux, Windows `BCryptGenRandom`, `/dev/urandom` elsewhere,
  host-injected entropy on wasm/freestanding) and panics if secure entropy is
  unavailable. Test hooks (`setRandomForTesting`, `setRandomForTestingSeed`) are
  for deterministic tests only and must not be reachable in production builds.
  `setRandomForTesting` keeps a pointer to the caller's generator state, so it
  must always be paired with `defer setRandomForTesting(null)`; prefer
  `setRandomForTestingSeed`, whose state lives inside the module.

## Advisory ZA-2026-001 — zig-fri `verify()` is not a low-degree test

**Affected:** the `zig-fri` implementation released in zig-algebra 0.3.0 and
earlier, including the immutable `v0.3.0` tag.

**Status:** the defect is fixed in the current working tree. The fix has not
been independently audited and is not, by itself, a production security
claim.

**Impact:** the affected `fri.verify()` accepted proofs of arbitrary committed
data with probability 1. A malicious prover could commit random evaluations and
produce an accepting proof. Any statement relying only on the affected FRI
verifier was therefore unproven.

## Root cause

The affected implementation had four compounding defects:

1. It treated a flat array as FRI evaluations without a Reed-Solomon subgroup
   or positional domain semantics.
2. It folded adjacent array entries without the antipodal weights required by
   FRI.
3. Its configuration had no initial degree bound or residual rate.
4. It checked the prover's own final evaluations instead of anchoring the claim
   to an independently defined low-degree residual.

The historical regression test accepted honestly folded random data 16/16
times.

## Current implementation

The current FRI implementation uses:

- the natural-order multiplicative subgroup `H_k` and antipodal pairs
  `(j, j + n/2)`;
- the positional fold
  `(f(x) + f(-x))/2 + alpha*(f(x) - f(-x))/(2*x)`;
- `log_initial_degree`, `log_final`, and `log_residual_degree` with an enforced
  relationship between the initial bound, folding rounds, and residual bound;
- Merkle commitments whose path depth must match the committed layer shape;
- residual coefficients evaluated on the final domain as the degree anchor;
- exact positional fold equality and Fiat-Shamir replay.

The regression suite covers random-data rejection, over-degree rejection,
tampered values, truncated Merkle paths, transcript desynchronization, and
non-power-of-two Merkle proofs.

## Verification performed

The current tree was re-verified with Zig 0.16.0:

```text
zig build test --summary all
zig build test --summary all -Doptimize=ReleaseFast
zig build stark
```

Both test modes passed **382/382 tests** (354/354 at the time of the
ZA-2026-001 fix), and the STARK demo (Fibonacci over Goldilocks) accepted the
honest proof while rejecting a tampered proof. The FRI tests also pass through
the standalone `libs/fri` build. The per-library steps sum to **498**.

> History: when the fix above landed, the same commands reported 297/297
> tests — that was the suite size at the time, not a different result. The
> count has since grown with the rest of the workspace (an intermediate
> documentation pass quoted 316; see `README.md` for the current per-library
> breakdown).

## Migration

FRI callers must provide evaluations on the canonical subgroup domain and use
the logarithmic configuration described in `libs/fri/README.md`. The old
`domain_size`/`final_length` API is not compatible with the corrected
verifier.

Do not use the historical `zig-pkg/` snapshot as evidence that the current
implementation is fixed. New deployments still require an external security
review, carefully chosen domain/degree parameters, and a real trusted setup
for the surrounding proof system.

## Advisory ZA-2026-002 — preconditions were asserted, not enforced

**Affected:** the `zig-algebra` working tree through workspace release 0.3.2,
in the `field`, `binary-field`, `merkle`, `rng`, `serialization` and `curve`
entry points listed below.

**Status:** addressed in the current tree (workspace `0.4.0`; `field` `0.3.0`,
`binary-field` `0.3.0`, `merkle` `0.1.2`, `rng` `0.3.0`, `serialization`
`0.2.0`, `curve` `0.4.0`). The fix has not been independently audited and is
not, by itself, a production security claim.

**Class of defect:** every precondition in this class was expressed as
`std.debug.assert`, which Zig compiles out in `ReleaseFast` and
`ReleaseSmall`. A violating input therefore behaved differently per
optimization level: a panic under Debug/ReleaseSafe, and a hang, an
out-of-bounds read/write, or silently wrong output in a release build. Where
the length, dimension or domain string comes from a peer, the memory-safety
and availability cases are remotely triggerable.

| Affected entry point | ReleaseFast behaviour before the fix |
|---------------------|------------------------------------|
| `zig-field` `inv` / `div` / `batchInv` (both backends and both towers) | binary-GCD loop on `a == 0` never terminates; `batchInv` also wrote past `outputs` on a length mismatch |
| `zig-field` `randomBounded(rnd, 0)`, `Vec8.fromSlice8`, `nttVec8M31` / `inttVec8M31`, `MerkleTree(F).verifyBatch` | rejection loop or unsatisfiable test hangs; out-of-bounds access; batch verification returned `true` after checking only `min(len)` entries |
| `zig-binary-field` `BinaryField.inv`, `TowerField.inv` | zero exponentiated or walked down the tower and came back as a fabricated zero inverse; the GF(2) base case asserted `a == 1` |
| `zig-binary-field` `Multilinear.numVars` / `eval` / `extend`, `PackedMle.*`, `novelEval` | folding past the end of the table; oversized `k` wrapped the length arithmetic and then allocated or indexed out of bounds |
| `zig-binary-field` `Sumcheck` over `F.BITS < 128` | 4-bit challenges were accepted as a secure sum-check, i.e. a grindable proof system |
| `zig-merkle` `MMR.verify` | sibling array walked by its length while indexing a shorter flag array (out-of-bounds read) |
| `zig-rng` `csprng.setEntropy`, host-seed reads, `setRandomForTesting` | over-long entropy overflowed the host buffer; a seed request longer than the injection copied uninitialized memory; the test hook could outlive the caller's generator state |
| `zig-serialization` `deserialize` | an untrusted `u64` length prefix reached the allocator unvalidated (allocation amplification / 32-bit `@intCast` overflow), and a mid-stream failure left the partially decoded value allocated |
| `zig-curve` `hashToPoint` / `generatorVector` | `catch unreachable` on the label buffer (abort) and `unreachable` on an exhausted search |

**Impact:** denial of service, undefined behaviour, allocation amplification,
and — for the sum-check entry points — a proof system that is not sound
against a grinding prover.

**Fix and residual risk:** the preconditions are now typed errors
(`error.InverseOfZero`, `error.DivisionByZero`, `error.LengthMismatch`,
`error.InvalidDimension`, `error.InvalidLength`, `error.NotPowerOfTwo`,
`error.InvalidPointLength`, `error.EntropyTooLong`,
`error.InsufficientEntropy`, `error.DomainTooLong`,
`error.NoValidPoint`), and the checked functions are the ones that enforce
them. Two caveats survive by design and must not be read away:

1. The legacy total wrappers still exist for source compatibility
   (`inv(0) == 0`, `x / 0 == 0`, truncating `setEntropy`, a no-op
   `nttVec8M31`). Calling them is not a validation step.
2. `SumcheckUnsafe` / `MlePcsUnsafe` / `CommittedMlePcsUnsafe` deliberately
   bypass the `F.BITS >= 128` requirement to keep the historical 4-bit on-chain
   format testable. They are toy-only and unsound for remote proofs.

## Advisory ZA-2026-003 — the asserted-precondition class was not fully closed

**Affected:** the `zig-algebra` tree through workspace release 0.4.0, in
`algebra-traits`, `poly`, `linalg`, `fri`, `curve`, `ntt`, `field`, `rng`,
`hash` and `pairing`.

**Status:** addressed in the current tree (workspace `0.5.0`). Same caveat as
ZA-2026-002: not independently audited, and not by itself a production
security claim.

**Class of defect:** identical to ZA-2026-002 — a precondition expressed as
`std.debug.assert`, `catch unreachable` or an unbounded search guard, which
Zig compiles out in `ReleaseFast`/`ReleaseSmall`. ZA-2026-002 covered six
libraries; an exhaustive sweep of the remaining tree found the same class in
ten more. Two of these are reachable from **attacker-supplied proof data**:

| Affected entry point | ReleaseFast behaviour before the fix |
|---------------------|------------------------------------|
| `zig-fri` `Domain.init`, and `verify`'s `log_final` | `two_adicity - log_n` underflowed, then `1 << shift` with `shift >= 64` (undefined behaviour). `log_final` comes from the proof and was never compared against `two_adicity` |
| `zig-ntt` all transforms | `2^log_n` came from `std.math.pow(usize, 2, log_n)`, which overflows for `log_n >= 64`; length and twiddle mismatches indexed out of bounds |
| `zig-poly` `fromCoeffs` / `mul` / `compose` / `pow` / `divRem` / `lagrangeInterpolate` / `vanishingPolynomial` | wrote past the fixed `[max_degree + 1]F` array; a zero divisor made the long-division loop non-terminating |
| `zig-linalg` `identity` / `trace` / `determinant` / `lu` / `solve` | `identity` on a non-square `Matrix(F, r, c)` wrote `data[i][i]` past the end of the shorter rows |
| `zig-hash` `Poseidon.initFromSeed` | a failed MDS search left `y[j]` undefined, producing a singular MDS matrix from a seed string |
| `zig-rng` `Shake256Rng.absorbSeed` / `finalize` | absorbing or re-finalizing after squeezing corrupted the sponge state |
| `zig-curve` `msm`, `ByteScalar.*`, `group_ops.scalarMul`, `group_poly.evalGroupPoly` | out-of-bounds scalar snapshot; `catch unreachable` on a non-canonical wire scalar aborted the process |
| `zig-field` `batchAdd/Sub/Mul`, `multiExp`, `Ipa.innerProduct/commit`, `primitiveRootOfUnity`, `rootOfUnity`, `toU64` | out-of-bounds batch writes and multi-exp reads; `two_adicity - log_size` underflowed the shift; `std.math.log2(0)` is undefined; `toU64` truncated silently |
| `zig-pairing` extension `inv`, `millerLoop` / `millerLoopPair` | divided by a zero norm and returned a fabricated element; an infinity input produced a garbage Fp12 |
| `zig-algebra-traits` `dotProduct`, `lagrangeInterpolate`, `lagrangeCoefficient` | out-of-bounds reads over the shorter slice / out-of-range index |

**Impact:** the same as ZA-2026-002 — denial of service, undefined behaviour,
and silently wrong cryptographic output. The `fri` and `ntt` rows are the
serious ones: both sit on the verification path for untrusted proof data.

**Fix:** typed errors throughout, with the same legacy-total-plus-checked
pattern (`inv` / `invChecked`, `millerLoop` / `millerLoopChecked`,
`ByteScalar.add` / `reduce`, `toU64` / `toU64Checked`). `verify` now rejects a
`log_final` above the two-adicity. Two unreferenced duplicate modules
(`zig-field/src/ntt.zig`, `zig-field/src/merkle.zig`) were removed so the
checked implementations are the only ones.

**Residual risk, unchanged by this advisory:**

1. Legacy total wrappers still exist for source compatibility. Calling them is
   not a validation step.
2. `SumcheckUnsafe` / `MlePcsUnsafe` / `CommittedMlePcsUnsafe` remain toy-only.
3. `pow` / `powFast` still `@panic` on a negative runtime exponent, and
   `BigField.toU64` still truncates above `u64`. Both are caller-side
   preconditions on a typed integer argument, and both have a checked sibling
   for the case that matters (`toU64Checked`); neither is reachable from
   attacker-controlled proof data in this workspace.
4. A `millerLoop` root or an NTT `root` of the wrong order is still not
   validated — only buffer shapes and `log_n` are checked.

## Reporting

Report suspected vulnerabilities privately to the maintainers. Do not disclose
security-sensitive details in a public issue or pull request.
