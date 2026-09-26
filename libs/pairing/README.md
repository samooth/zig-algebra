# zig-pairing

Bilinear pairings for pairing-friendly elliptic curves: optimal ate pairings for BLS12-381 and BN254 over a shared Fp2/Fp6/Fp12 tower.

## Status

| Curve | Pairing | Tests | Notes |
|-------|---------|-------|-------|
| BLS12-381 | optimal ate, M-twist, ξ = 1+u | 10 | `src/bls12_381.zig`; sparse Miller loop, split final exponentiation, known-answer vs py_ecc |
| BN254 | optimal ate, D-type twist, ξ = 9+u | 22 | `src/bn254_tower.zig`; sparse + dense reference paths, cross-checked against each other and vs py_ecc |
| BN254 (direct embedding) | reference | 13 | `src/bn254_direct.zig`; untwisted embedding, used as a cross-check |
| Generic tower | — | 7 | `src/root.zig` Fp2/Fp6/Fp12 factories and generator on-curve checks |

`zig build test` for this library runs 54 tests in total. BN254 is **no longer
unimplemented** — the older status table in git history predated
`bn254_tower.zig`.

## Architecture

- `src/tower.zig` — generic sextic tower `Fp6 = Fp2[v]/(v^3 - ξ)` and `Fp12 = Fp6[w]/(w^2 - v)`. `Fp12` is tied to the sextic generator (`w^6 = ξ`) so the two levels share one non-residue
- `src/bls12_381.zig` — BLS12-381 optimal ate pairing over `src/tower.zig`
- `src/bn254_tower.zig` — BN254 optimal ate pairing over `src/tower.zig` (the current implementation)
- `src/bn254_direct.zig` — BN254 with the untwisted/direct embedding, kept as an independent reference
- `src/bn254.zig` — legacy BN254 pairing module (no inline tests; re-exported as `bn254_legacy`)
- `src/root.zig` — standalone `Fp2` / `Fp6` / `Fp12` generic types plus re-exports

## BLS12-381 Pairing

```
e(P ∈ G1, Q ∈ G2) → GT ⊂ Fp12
```

Miller loop over the seed bits of x = −0xd201000000010000; affine lines are
evaluated at P through a sparse Fp12 multiplication hitting only the Fp6
`c0`/`c1` slots of the `w` basis. Final exponentiation is split into the easy
part `(p^6 − 1)(p^2 + 1)` and the hard part over `N = (p^12 − 1)/r`.

```zig
const std = @import("std");
const zp = @import("zig-pairing");
const zc = @import("zig-curve");

const bls = zp.bls12_381_pairing_impl;
const g1 = zc.bls12_381.G1_generator;
const g2 = zc.bls12_381.G2_generator;

std.debug.assert(bls.isG1InSubgroup(g1) and bls.isG2InSubgroup(g2));

// e(G1, G2)
const e = bls.pairing(g1, g2);
std.debug.assert(!e.isZero()); // non-degenerate

// Bilinearity: e(2P, 3Q) == e(P, Q)^6.
// `powFast` takes a plain integer exponent (not a field element) and
// Fp12 equality is `eql`, not `eq`.
const lhs = bls.pairing(g1.dbl(), g2.dbl().add(g2));
std.debug.assert(lhs.eql(e.powFast(6)));

// Split the computation: Miller loop then final exponentiation
const f = bls.millerLoop(g1, g2);
std.debug.assert(bls.finalExpSplit(f).eql(e));

// Tower types and constants
const Fp2 = bls.Fp2; // XI = 1 + u
const Fp6 = bls.Fp6;
const Fp12 = bls.Fp12;
std.debug.assert(Fp2.new(zc.bls12_381.Fp.one(), zc.bls12_381.Fp.one()).eql(bls.XI));
std.debug.assert(Fp12.one().eql(bls.gt_one));
```

## BN254 Pairing

```zig
const zp = @import("zig-pairing");
const zc = @import("zig-curve");

// `bn254_pairing` is an alias for `bn254_tower_pairing`
const bn = zp.bn254_pairing;
const g1 = zc.bn254.G1_generator;
const g2 = zc.bn254.G2_generator;

std.debug.assert(bn.isG1InSubgroup(g1) and bn.isG2InSubgroup(g2));

const e = bn.pairing(g1, g2);
std.debug.assert(!e.isZero());

// Bilinearity
const lhs = bn.pairing(g1.scalarMul(2), g2.scalarMul(3));
std.debug.assert(lhs.eql(e.powFast(6)));

// The sparse and dense implementations agree
std.debug.assert(bn.pairingSparse(g1, g2).eql(bn.pairingDense(g1, g2)));
std.debug.assert(bn.pairingSparse(g1, g2).eql(e));

// Tower types and constants
const Fp2 = bn.Fp2; // GAMMA = 9 + u
const Fp6 = bn.Fp6;
const Fp12 = bn.Fp12;
std.debug.assert(Fp6.XI.eql(bn.GAMMA));
_ = bn.OMEGA;
_ = bn.ZETA;
_ = bn.gt_one;

// Numerator/denominator Miller form
const nd = bn.millerLoopPair(g1, g2);
_ = nd.num;
_ = nd.den;
_ = bn.finalExponentiate;
_ = bn.finalExponentiateSplit;
```

Input validation is done inside the Miller loop: off-curve or wrong-subgroup
points collapse to the identity element instead of raising an error
(`bn254_tower.pairing*` guard explicitly and return `Fp12.one()`;
`bls12_381.pairing` inherits the same behaviour through `millerLoop`, and
`finalExponentiateSplit(1) == 1`).

## Generic tower types

`src/root.zig` exposes standalone towers unrelated to the curve-specific
modules. Each takes its non-residue as an explicit value.

```zig
const zp = @import("zig-pairing");
const zf = @import("zig-field");

const Fp2 = zp.Fp2(zf.BN254_Fp, zf.BN254_Fp.fromInt(9));
const Fp6 = zp.Fp6(Fp2, Fp2.zero());
const Fp12 = zp.Fp12(Fp6, Fp6.zero());

std.debug.assert(Fp12.one().mul(Fp12.one().inv()).isOne());
```

## Verified properties

- Non-degenerate: e(G1, G2) ≠ 1 (both curves)
- r-torsion: e(G1, G2)^r = 1
- Bilinear: e(aP, bQ) = e(P, Q)^(ab)
- BN254: the sparse and dense Miller loops agree, and both match a
  known-answer value from py_ecc
- BLS12-381: split final exponentiation matches full square-and-multiply,
  and the result matches a py_ecc reference

## Running Tests

```bash
# From the monorepo root
zig build test

# Just this library (54 tests, all inline)
cd libs/pairing && zig build test
```

Prefer ReleaseFast: in Debug the final exponentiations dominate and the
suite takes about a minute, versus ~1 s in ReleaseFast.

## Notes

- `src/bench.zig` is wired to the monorepo `zig build bench` step
- Not constant-time: the Miller loop and final exponentiation branch on
  control bits derived from the seed and exponent. Both exponents are public
  curve parameters, but do not feed secret scalars through these paths
- There is no independent cryptographic audit for this library

## License

MIT OR Apache-2.0
