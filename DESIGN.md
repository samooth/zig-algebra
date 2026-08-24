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
