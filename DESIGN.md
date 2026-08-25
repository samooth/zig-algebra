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
- GCD binario: O(2·bits) iterations, each a shift + subtract → ~2× faster than
  381-bit modular exponentiation.
- No need for a WideExp type sized to hold p−2 (saves stack).
- Trade-off: iteration count is input-dependent (leaks timing). Acceptable for
  STARKs/zkSNARKs where field elements are public. NOT suitable for secret-key ops.

### Mersenne fast-path

SmallField detects Mersenne primes (p = 2^k − 1) at comptime and replaces
Montgomery reduction with the classic split-reduce: `(lo & M) + (hi >> k)`.
This is what makes M31 (~2^31) competitive with hand-written implementations.

### Dual backend

`Field(modulus)` dispatches at comptime:
- modulus < 2^64 → `SmallField` (native u64 arithmetic)
- modulus ≥ 2^64 → `BigField` (Montgomery over `[N]u64` limbs)

Both expose identical APIs. The caller never sees which backend is active.

## Allocation Policy

Zero heap allocations in all hot paths. Every type uses fixed-size arrays:

- `BigInt(max_limbs)`: `[max_limbs]u64`
- `Polynomial(F, max_degree)`: `[max_degree + 1]F`
- `Matrix(F, rows, cols)`: `[rows][cols]F`

The only allocations occur in string conversion (`toString`, `fromString`)
and in the Merkle tree (node storage). These are cold paths.

## NTT Design

Cooley-Tukey iterative radix-2 with bit-reversal permutation.
Chosen over recursive (Stockham) because:
- In-place, no scratch buffer needed
- Cache-friendly for power-of-two sizes ≤ L2 cache
- Twiddle factors can be precomputed once and reused across calls

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

For BLS12-381 (M-twist): b′ = 4ξ with ξ = 1+u ✓ both conditions met.
For BN254 (D-twist): b′ = 3/(9+u), so b/b′ = 9+u. But 1/(9+u) IS a cube in Fp2,
making it unsuitable. Resolution requires twist-scaling constants or a direct
degree-12 extension.

## Testing Philosophy

Every mathematical operation is tested against a reference:
- Field arithmetic: property-based tests against u512/u1024 reference computation
- Curves: on-curve checks, scalar-mul consistency ([k]P == P+P+...+P)
- Pairings: bilinearity e(aP,bQ) = e(P,Q)^{ab}, r-torsion, non-degeneracy
- Serialization: golden wire-layout tests to catch accidental format changes

## Security Notes

Constant-time guarantees apply ONLY where explicitly documented:
- BigField Montgomery mul/add/sub: constant-time ✓
- SmallField add/sub: constant-time ✓
- SmallField division (`%`): NOT constant-time ✗ (acceptable for public data)
- BigInt comparison: NOT constant-time ✗
- GCD inversion: NOT constant-time ✗ (input-dependent iteration count)

For STARK/SNARK proving (public data): all of the above are safe.
For signature schemes or key exchange: audit before use.

## WASM Compilation

Zig compiles to wasm32-freestanding natively:

```bash
zig build-exe examples/wasm_fp.zig \
  -target wasm32-freestanding -O ReleaseFast \
  --dep zig-field -Mroot=examples/wasm_fp.zig \
  -Mzig-field=libs/field/src/lib.zig ...
```

See `examples/wasm_fp.zig` for exported functions (`fp_mul`, `fp_add`, `fp_inv`).
The build.zig target is pending Zig 0.16 WASM linker flags.

## Dependency Graph Rationale

| Edge | Why |
|------|-----|
| bigint → algebra-traits | Validates BigInt against Ring/Field contracts at comptime |
| hash → (none) | Self-contained; Blake3/Keccak/Poseidon have no deps beyond stdlib |
| rng → hash | SHAKE256 XOF extends Keccak; CSPRNG seeds from Blake3 |
| field → bigint | BigField uses `[N]u64` limbs from bigint for Montgomery arithmetic |
| binary-field → hash | GF(2^n) uses hash for challenge generation in Binius PCS |
| curve → field, hash | Points over Fp/Fp2 from field lib; hash-to-curve needs hash functions |
| pairing → field, curve | Tower Fp12 built on field extensions; Miller loop evaluates on curve points |
| ntt → algebra-traits | Validates Field trait for NTT-compatible types |
| poly → algebra-traits | Validates coefficient type is a proper Ring/Field |
| merkle → hash | Tree nodes hashed with Blake3/SHA3/Poseidon |
| linalg → field | Matrix/vector elements are field elements |
| parallel → (none) | Thread pool is self-contained |
| serialization → (none) | Comptime reflection only |
| transcript → (none) | stdlib Blake3 only; base of the proof-stack dependency chain |
| fri → transcript | Folding challenges derived from Fiat-Shamir transcript |

## Semantic Versioning

- v0.1.0: Initial release — all 14 libs with verified tests
- Future: bump MAJOR on breaking API changes, MINOR on new features

## BN254 optimal ate pairing (tower) — algorithm notes

- Tower: Fp6 = Fp2[v]/(v^3 - gamma), gamma = 9+u (non-cube, non-square;
  an early session's contrary claim was a faulty numeric check).
  Fp12 = Fp6[w]/(w^2 - v); w^6 = gamma.
- Untwist: psi(x',y') = (x'*v, y'*v*w)  [zeta=1 eigenspace].
- Loop: optimal ate 6x+2, twist-side affine arithmetic with sparse lines
  (~15 Fp2 muls/step). SIGN ASYMMETRY: tangent lines use
  (-n*px, n*tx - d*ty) while chord lines use (+n*px, d*ty - n*tx);
  reusing tangent signs on chords corrupts every addition step.
- Verticals are OMITTED: v(P)=px - x'*v is a general Fp12 element in
  this layout and does NOT vanish under final exponentiation.
- Extra terms: two dense lines with pi(Q) and -pi^2(Q), pi applied per
  coordinate of the EMBEDDED point (field Frobenius), per py_ecc.
- Final exp split: f^N = [frob^6(f) * f^-1]^M, M=(p^6+1)/r. The easy
  part is Frobenius-only + one closed-form tower inversion; the hard
  part runs 4-bit-windowed SA&M with cyclotomic compressed squaring
  (valid since frob^6 == w-conjugation on this subgroup).

Performance arc for e(G1,G2): 170 ms -> 44 ms (split) -> 29 ms
(cyclotomic+window) -> ~32 ms steady-state (sparse loop).

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
