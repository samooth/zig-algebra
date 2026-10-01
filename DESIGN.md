# Design Decisions

Key architectural and implementation choices in zig-algebra, with rationale.

## Field Arithmetic

### Montgomery CIOS (not FIOS or FIPS)

BigField uses Coarsely Integrated Operating Structure for Montgomery multiplication.
CIOS processes one limb of the multiplier per outer-loop iteration, keeping the
intermediate result in registers. For our target limb counts (4–8 u64 limbs),
CIOS minimises memory traffic compared to FIOS (which spills intermediates) and
FIPS (which uses a separate product buffer).

### Binary GCD inversion (not Fermat)

SmallField and BigField use the binary extended GCD algorithm for inversion
instead of Fermat's little theorem (`x^(p-2)` via square-and-multiply).

Rationale:
- Binary GCD: ~2·BITS iterations, each a shift + subtract, versus ~BITS
  Montgomery multiplications plus their squares for a 381-bit exponentiation.
- No need for a WideExp type sized to hold p−2 (saves stack).
- Trade-off: iteration count is input-dependent (leaks timing). Acceptable for
  STARKs/zkSNARKs where field elements are public. NOT suitable for secret-key ops.
  (`BigField.inv` routes through `Montgomery.invMontgomery`, whose limbs use the
  constant-time `ct*` helpers, but the loop bound still depends on the input.)

### Total vs checked inversion (0.4.0)

The binary GCD loop has no defined behaviour for a zero input: with `a == 0`
the `u & 1 == 0` branch is taken forever while `v` never moves, so the loop
does not terminate. This used to be documented as a `std.debug.assert`, which
means a caller that could supply zero got a panic in Debug/ReleaseSafe and an
infinite loop in `ReleaseFast`. The pair is now explicit:

- `inv(self) Self` — legacy, total: `inv(0) == zero()`. It delegates to
  `invChecked` and swallows `error.InverseOfZero`, so a non-invertible input
  stays zero instead of fabricating a plausible-looking element.
- `invChecked(self) error{InverseOfZero}!Self` — the API new code must use.

The same split is applied to `div` / `divChecked` and to Montgomery's
`invMontgomery` / `invMontgomeryChecked`, and it is extended to the tower types
(`QuadraticExtension`, `CubicExtension`, `TowerField`) whose norm-based and
recursive inverses degenerate to zero in the same way. Zero is a field element,
but it is not invertible, so a zero result must never be treated as
"invertible"; the legacy
wrappers exist for source compatibility only. The same reasoning covers every
other `std.debug.assert` that guarded a caller-supplied length or dimension
(`batchInv`, `randomBounded`, `Vec8.fromSlice8`, the M31 SIMD NTT, the packed
MLE and the binary-field MLE table lengths): they are `error.LengthMismatch` /
`error.InvalidDimension` / `error.InvalidLength` now, and the `…Checked`
sibling rejects rather than totalising.

### Mersenne fast-path

`SmallField` keeps residues in canonical form (no Montgomery round-trip) and
detects Mersenne primes (p = 2^k − 1) at comptime, reducing with the classic
split-reduce `(lo & M) + (hi >> k)` in `add`, `sub` and `mul`. This is what
makes M31 (~2^31) competitive with hand-written implementations.

### Dual backend

`Field(modulus)` dispatches at comptime:
- modulus < 2^64 → `SmallField` (native u64 arithmetic)
- modulus ≥ 2^64 → `BigField` (Montgomery over `[N]u64` limbs)

Both expose identical APIs. The caller never sees which backend is active.

## Allocation Policy

Fixed-size algebraic types are stack-only:

- `BigField`/`BigInt(max_limbs)`: `[N]u64` limbs
- `Polynomial(F, max_degree)`: `[max_degree + 1]F`
- `Matrix(F, rows, cols)`: `[rows][cols]F`
- `Vector(F, n)`, `Fq` towers, points: nested fixed arrays

There is **no global "zero allocation" guarantee**: anything of variable size
takes a caller-supplied `std.mem.Allocator` and returns a `deinit`-able owner.
That includes the proof stack (`fri.prove`/`fri.verify`, `kzg.commit`/`prove`,
`Ipa.prove`), the Merkle trees, the binary-field PCS/sum-check, twiddle-factor
caching in `zig-ntt`, and string conversion. Allocation failures are propagated
as `error.OutOfMemory` — the proof stack never uses `catch unreachable`.

## NTT Design

`zig-ntt` is Cooley-Tukey iterative radix-2 with bit-reversal permutation,
power-of-two sizes only, plus an inverse NTT and an optional twiddle-factor
cache (`precomputeTwiddles`/`nttWithTwiddles`, which is the one allocating
entry point in the library). Chosen over recursive (Stockham) because:
- In-place, no scratch buffer needed
- Cache-friendly for power-of-two sizes ≤ L2 cache
- Twiddle factors can be precomputed once and reused across calls

`zig-field` additionally ships a M31-only `@Vector(8, u64)` NTT
(`nttVec8M31`/`inttVec8M31`); `zig-ntt` itself has no SIMD, mixed-radix, 2-D or
batch specialisations.

## Curve Arithmetic

### Affine vs Projective

The Weierstrass module provides both. Tests use affine for clarity;
production code should use projective (Jacobian) for scalar multiplication
to avoid inversions per step.

### Generator verification

All curve generators are canonical values from their respective specifications
(IETF, EIP-197, zkcrypto). Each generator is verified on-curve at test time.

## Pairing Tower

Fp12 = Fp6[w]/(w²−v), Fp6 = Fp2[v]/(v³−ξ), built over Fp2 = QuadraticExtension(Fp, non_residue).

The tower parameter ξ must satisfy TWO conditions simultaneously:
1. Not a cube in Fp2 (so Fp6 is degree 3)
2. w⁶ = ξ = b′/b (so the untwist map Ψ works)

For BLS12-381 (M-twist): ξ = 1 + u, b′ = 4ξ, so both conditions hold.

For BN254 (D-twist) both conditions are met by **γ = 9 + u** (verified in tests
as neither a cube nor a square in Fp2, with w⁶ = γ and the untwist landing on
E(Fp12)). An earlier session's claim that `1/(9+u)` being a cube blocks BN254
was a faulty numeric check; the implemented resolution was to pick γ = 9 + u
and prove the tower properties directly rather than deriving them from b/b′.
`zig-pairing` therefore ships three BN254 entry points: the production
`bn254_tower.pairing` (sparse Miller loop + split final exponentiation), the
`pairingDense` cross-check reference, and `bn254_direct`, an independent
degree-12 extension Fp12 = Fp2[w]/(w¹² − ξ) used as a second opinion.

## Testing Philosophy

Every mathematical operation is tested against a reference:
- Field arithmetic: property-based tests against u512/u1024 reference computation
- Curves: on-curve checks, scalar-mul consistency ([k]P == P+P+...+P)
- Pairings: bilinearity e(aP,bQ) = e(P,Q)^{ab}, r-torsion, non-degeneracy
- Serialization: golden wire-layout tests to catch accidental format changes

Negative coverage also includes the validation paths themselves: out-of-range
and mismatched-length inputs must return typed errors, and must not leave a
leak, an out-of-bounds access or an unbounded allocation behind. See the
"Total vs checked" section above.

Counts (Zig 0.16.0, re-derived 2026-10-01): the root `zig build test` step
executes **588** tests in both Debug and ReleaseFast, and the per-library steps
sum to the same 588 because the root step compiles the `tests/` roots of `field`
(89) and `curve` (98) as well as every library's inline `src/` tests. This line
said 391, and the per-library sum it quoted, 507, is a number from a tree that
no longer exists. `zig build counts-check` is what keeps it right; it is in the
gate precisely because a design document nobody re-reads is where a stale count
survives longest. See `README.md`.

## Security Notes

Constant-time guarantees apply ONLY where explicitly documented:
- BigField Montgomery mul/add/sub: constant-time ✓
- SmallField add/sub: constant-time ✓
- SmallField multiplication/reduction (`%`): NOT constant-time ✗
  (acceptable for public data)
- BigInt comparison: NOT constant-time ✗
- GCD inversion: NOT constant-time ✗ (input-dependent iteration count)
- Curve scalarMul and both pairing implementations: NOT constant-time ✗
  (documented on the API; pairing inputs are treated as public data)

For STARK/SNARK proving (public data): all of the above are safe.
For signature schemes or key exchange: audit before use.

Non-cryptographic caveats that documentation must keep visible:
- **No independent audit exists** for any library in this workspace.
- `inv(0) == 0` and `x / 0 == 0` are the **legacy total** results of the
  non-checked wrappers in `zig-field` and of `inv` in `zig-binary-field`. They
  are source-compatibility shims, not a mathematical statement; the
  `…Checked` variants are what new code must call.
- `zig-binary-field`'s `Sumcheck` refuses `F.BITS < 128`
  (`error.FieldTooSmall`); the `SumcheckUnsafe` / `MlePcsUnsafe` /
  `CommittedMlePcsUnsafe` variants keep the historical 4-bit challenge format
  and are grindable, i.e. **not sound against a malicious prover**. They exist
  for the on-chain toy format and tests.
- `kzg.Setup.generate` is a synthetic trusted setup (tests/dev only).
- `Ipa.verify` in `zig-field` is a stub (`error.Unsupported`); only
  `verifyWithCommitment` verifies, and its challenges are a local SHA-256 of
  `(L, R, round)` rather than a `zig-transcript` Fiat-Shamir session.
- `zig-rng`'s `csprng.setRandomForTesting` retains a pointer to the caller's
  generator state; it must be reset with `defer setRandomForTesting(null)`, or
  `setRandomForTestingSeed` should be used instead (module-owned state).
- `zig build bench` numbers are indicative and machine-specific; CI records
  them as an artifact without regression thresholds.

## WASM Compilation

Both WASM targets are implemented as build steps (no manual flags needed):

```bash
zig build wasm          # examples/wasm_fp.zig      -> wasm32-freestanding
zig build wasm-pairing  # examples/wasm_pairing.zig -> wasm32-freestanding
```

`zig build wasm` exports `fp_add`, `fp_mul` and `fp_inv` for
`examples/wasm_fp.zig` (128-bit BN254-Fp arguments in/out); the root
`build.zig` resolves the `wasm32-freestanding` target, disables the entry
point and lists the exported symbols explicitly. `zig build wasm-pairing`
additionally exports `pairing_api_version`, `g1_validate`, `g2_validate`,
`pairing_compute`, `pairing_bilinear_check` and `scratch_ptr` for JS/TS
interop. CI builds both and drives them from Node
(`scripts/wasm_field_smoke.js`, `scripts/wasm_pairing_smoke.js`).

## Dependency Graph Rationale

Edges as wired in the root `build.zig` (and mirrored in each library's
`build.zig.zon`).

| Edge | Why |
|------|-----|
| bigint → algebra-traits | Validates BigInt against Ring/Field contracts at comptime |
| hash → algebra-traits | Traits are compile-time only; Blake3/Keccak/Poseidon need no runtime deps beyond stdlib |
| rng → algebra-traits, hash | Field sampling is trait-checked; SHAKE256 XOF extends Keccak and CSPRNG seeding hashes |
| merkle → algebra-traits, hash | Tree nodes hashed with Blake3/SHA3/Poseidon |
| field → bigint | BigField uses `[N]u64` limb helpers from bigint for Montgomery arithmetic |
| binary-field → algebra-traits, hash, merkle | GF(2^n) challenges come from hash; the MLE PCS commits to Merkle roots |
| curve → field, hash | Points over Fp/Fp2 from the field library; hash-to-curve needs hash functions |
| ntt → algebra-traits, field | Trait-checks the coefficient type and is exercised against the concrete field types |
| poly → algebra-traits | Validates the coefficient type is a proper Ring/Field |
| linalg → algebra-traits, field | Matrix/vector elements are field elements |
| pairing → algebra-traits, field, curve | Tower Fp12 built on field extensions; Miller loop evaluates on curve points |
| transcript → (none) | stdlib Blake3 only; base of the proof-stack dependency chain |
| fri → transcript, merkle, field | Folding challenges from Fiat-Shamir; layer commitments via the shared zig-merkle tree; degrees over a concrete field |
| kzg → field, curve, pairing | Commitments are BN254 G1 points and verification runs the pairing |
| parallel → (none) | Thread pool is self-contained |
| serialization → (none) | Comptime reflection only |

## Semantic Versioning

- v0.1.0: Initial release — 14 libraries (algebra-traits, bigint, hash, rng,
  field, binary-field, curve, pairing, merkle, ntt, poly, linalg, parallel,
  serialization).
- v0.2.0: added `transcript` and `fri` (16 libraries).
- v0.2.2: added `kzg` as the 17th library.
- v0.4.0: workspace version; validation hardening (asserts → typed errors plus
  total legacy wrappers) in `field` (0.3.0), `binary-field` (0.3.0), `merkle`
  (0.1.2), `rng` (0.3.0), `serialization` (0.2.0) and `curve` (0.4.0). The
  remaining manifests are unchanged.
- Current: workspace `0.4.0`; each library carries its own independent semver
  (currently `0.1.0`–`0.4.0`).
- Future: bump MAJOR on breaking API changes, MINOR on new features.

## BN254 optimal ate pairing (tower) — algorithm notes

- Tower: Fp6 = Fp2[v]/(v^3 - gamma), gamma = 9+u (non-cube, non-square;
  an early session's contrary claim was a faulty numeric check).
  Fp12 = Fp6[w]/(w^2 - v); w^6 = gamma.
- Untwist: psi(x',y') = (x'*v, y'*v*w)  [zeta=1 eigenspace].
- Loop: optimal ate 6x+2, twist-side affine arithmetic with sparse lines
  (~15 Fp2 muls/step + 1 Fp12 sqr). Tangent AND chord lines share one
  slot convention: d*py + (-n*px)w + (n*tx - d*ty)vw. An early session's
  contrary "sign asymmetry" note was wrong — the real defects were
  MISSING MILLER SQUARINGS in the accumulator plus inverted chord signs;
  both fixed and covered by direct sparse==dense / bilinearity tests.
- Verticals are OMITTED: v(P)=px - x'*v is a general Fp12 element in
  this layout and does NOT vanish under final exponentiation... but the
  dense py_ecc reference omits them identically and matches EIP-197
  KATs, so the omission is part of the verified formulation.
- Extra terms: two dense lines with pi(Q) and -pi^2(Q), pi applied per
  coordinate of the EMBEDDED point (field Frobenius), per py_ecc.
- Final exp split: f^N = [frob^6(f) * f^-1]^M, M=(p^6+1)/r. The easy
  part is Frobenius-only + one closed-form tower inversion; the hard
  part runs 4-bit-windowed SA&M with cyclotomic compressed squaring
  (valid since frob^6 == w-conjugation on this subgroup).

Performance arc for e(G1,G2) on the development machine: 170 ms -> 44 ms
(split) -> 29 ms (cyclotomic+window) -> ~32 ms steady-state (sparse loop)
-> ~17 ms (sparse promoted to production path after fixing missing Miller
squarings; dense reference kept at ~30 ms for cross-checking). Treat these
as *relative* improvements only: absolute timings are machine-specific (a
Ryzen 7 5800H currently measures ~21 ms for the tower path and ~37 ms for the
dense reference — see the benchmark table in `README.md`).

An independent degree-12 formulation (`bn254_direct`, Fp12 = Fp2[w]/(w^12 − ξ))
is kept as a second opinion: it is bilinear and non-degenerate under test, but
it is ~5x slower than the tower path, so the tower stays the production entry
point.

## BLS12-381 pairing — final exponentiation notes

- Easy part: t = conj(f)*f^-1 (= f^(p^6-1); conj IS the p^6-map because
  nu is a non-residue in Fp6*), then u = frob^2(t)*t (= t^(1+p^2)).
- Hard part: u^d, d = (p^4-p^2+1)/r, via 4-bit-windowed SA&M with
  cyclotomic compressed squaring (shared tower.Fp12 primitives).
- Stage anchoring pattern (used for BN254 too): every optimised stage
  must be tested equal to an independent comptime-limb SA&M over the
  exact stage exponent BEFORE wiring into production; full-pipeline
  equality against the unoptimised path closes the loop.
- The early-session "broken split" was never diagnosed at the time;
  resurrecting it with stage anchoring revealed no defect in the
  documented formulas — the original failure predates the current test
  infrastructure and did not reproduce.

## KZG commitment scheme

- Setup is SYNTHETIC (fixed tau by caller): tests/dev only; production
  requires a powers-of-tau ceremony with toxic-waste destruction.
- commit = MSM over [tau^i]G1; prove = commit of witness quotient
  q(x)=(p(x)-p(z))/(x-z) via Horner synthetic division.
- verify pairing check: e(C-[y]G1, G2gen) == e(W, [tau]G2 - [z]G2gen).
  NOTE the RHS needs the affine SUBTRACTION in G2 — comparing against
  bare [tau]G2 silently fails even though group identity holds.
- `commit`/`prove` take a caller-supplied allocator and propagate
  `error.OutOfMemory` (breaking change introduced in v0.3.0).
- Scalar-mult by Fr over curve points: delegates to zig-curve's
  windowed ladder (4-bit windows, left-to-right, Jacobian coordinates;
  O(1) inversions). The earlier per-byte LSB-first affine double-and-add
  was ~8x slower; an MSB-first infinity-flagged accumulator variant had
  proved fragile before that (see git history).
