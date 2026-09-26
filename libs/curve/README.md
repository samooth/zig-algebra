# zig-curve

Elliptic curve implementations for Zig. Re-exports stdlib curves and provides custom implementations for pairing-friendly/SNARK curves with generic Weierstrass arithmetic and hash-to-curve (RFC 9380).

Library version: **0.4.0** (`libs/curve/build.zig.zon`); the workspace version
lives in the root `build.zig.zon`.

## Features

- **Generic Weierstrass curves** — `AffinePoint(F, a, b)` and `ProjectivePoint(F, a, b)` with Jacobian coordinates
- **Stdlib re-exports** — Curve25519, Ed25519, Ristretto255, Secp256k1, P256, P384
- **BN254** — G1, G2 (pairing-friendly, used by Ethereum zkSNARKs)
- **BLS12-381** — G1, G2 (pairing-friendly, used by BLS signatures, Ethereum 2.0)
- **Pasta cycle** — Pallas, Vesta (used by Halo2, recursive SNARKs)
- **Hash-to-curve** — RFC 9380 Shallue-van de Woestijne mapping, `expandMessageXmd`, `hashToField`, `hashToCurve`, `hashToCurveWithCofactor`
- **Nothing-up-my-sleeve generator derivation** — `hashToPoint` / `generatorVector`, returning `error.DomainTooLong` / `error.NoValidPoint` instead of aborting
- **Multi-scalar multiplication** — `msm.msm(Aff, Proj, Scalar, allocator, points, scalars)` via Pippenger bucket decomposition with an adaptive window (`msm.windowSize`), returning a projective point. Returns `error.LengthMismatch` when `points.len != scalars.len`
- **Byte-array scalar arithmetic** — `byte_scalar.ByteScalar(ScalarType, N)` (add, sub, mul, inv, neg, reduce) over big-endian `[N]u8` scalars. Every parsing operation (`add`, `sub`, `mul`, `inv`, `neg`, `fromBytes`) returns `error.NotCanonical` when an input is `>= n`; they used to `catch unreachable` the stdlib rejection. `reduce` is the total entry point for untrusted bytes. `ScalarType` must expose the **stdlib** ECC scalar shape (`fromBytes(bytes, .big)`, `toBytes(.big)`, `invert()`), e.g. `std.crypto.ecc.Secp256k1.scalar.Scalar` — it does **not** accept `zig-field` types, whose `toBytes`/`fromBytes` take no endianness argument
- **Group trait helpers** — `group_ops.GroupOps(Point)` and free functions `identity`, `eql`, `scalarMul`
- **Point operations** — `add`, `dbl`, `scalarMul`, `neg`, `eql`, SEC1 `toBytes` / `fromBytes`

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_curve = .{
        .path = "../zig-algebra/libs/curve",
    },
},
```

Then in your `build.zig`:

```zig
const zc = b.dependency("zig_curve", .{});
exe.root_module.addImport("zig-curve", zc.module("zig-curve"));
```

## Quick Start

```zig
const std = @import("std");
const zc = @import("zig-curve");

// BN254 curve operations.
// The method is `dbl`, not `double`.
const G1 = zc.bn254.G1_generator;
const three_G1 = G1.dbl().add(G1);
std.debug.assert(three_G1.eql(G1.scalarMul(3)));

// Jacobian/projective coordinates: `ProjectivePoint` has no `eql` that
// accepts an affine point, so convert with `toAffine`.
const P1 = zc.bn254.G1Projective.generator(G1.x, G1.y);
std.debug.assert(P1.dbl().toAffine().eql(G1.dbl()));

// SEC1-style serialization (2 * F.NUM_BYTES, x || y).
// `toBytes` is a method; `fromBytes` is a static constructor.
const sec1 = G1.toBytes();
const round_tripped = try zc.bn254.G1.fromBytes(sec1);
std.debug.assert(round_tripped.eql(G1));

// BLS12-381
const bls_G1 = zc.bls12_381.G1_generator;
const bls_G2 = zc.bls12_381.G2_generator;

// Pasta cycle
const pallas = zc.pasta.Pallas_generator;
const vesta = zc.pasta.Vesta_generator;

// Hash-to-curve (RFC 9380). `hashToCurve` returns a plain
// `hash_to_curve.CurvePoint(F)` struct of field elements, not an
// `AffinePoint`, so lift it explicitly if you need curve operations.
const h2c = zc.hash_to_curve;
const pt = try h2c.hashToCurve(
    zc.bn254.Fp,
    zc.bn254.G1_a,
    zc.bn254.G1_b,
    "hello",
    "BN254_G1_XMD:SHA-256_SSWU_RO_",
);
const mapped = zc.bn254.G1{ .x = pt.x, .y = pt.y, .infinity = false };
std.debug.assert(mapped.isOnCurve());

// Stdlib curves
const secp = zc.secp256k1; // std.crypto.ecc.Secp256k1

// Nothing-up-my-sleeve generators by try-and-increment. Both entry points
// return error unions; a domain that does not fit the label buffer is
// `error.DomainTooLong` and an exhausted search is `error.NoValidPoint`.
const gens = try zc.hash_to_curve_derive.generatorVector(
    std.crypto.ecc.Secp256k1, "my-protocol/v1", 4, allocator,
);
defer allocator.free(gens);
```

## Curves

| Curve | Field | Use case |
|-------|-------|----------|
| secp256k1 | ~2^256 | Bitcoin, Ethereum |
| Curve25519 | ~2^255 | Key exchange |
| Ed25519 | ~2^255 | Fast signatures |
| BN254 G1/G2 | ~2^254 | zkSNARKs (Ethereum) |
| BLS12-381 G1/G2 | ~381 bits | BLS signatures, Ethereum 2.0 |
| Pallas | ~2^255 | Halo2 recursive SNARKs |
| Vesta | ~2^255 | Halo2 (Pallas cycle) |

## API

| Module | Key types/functions |
|--------|-------------------|
| `weierstrass` | `AffinePoint(F, a, b)`, `ProjectivePoint(F, a, b)` |
| `bn254` | `Fp`, `Fp2`, `Fr`, `G1`, `G2`, `G1Projective`, `G2Projective`, `G1_generator`, `G2_generator`, `G1_a`, `G1_b`, `G2_a`, `G2_b` |
| `bls12_381` | `Fp`, `Fp2`, `Fr`, `G1`, `G2`, `G1Projective`, `G2Projective`, `G1_generator`, `G2_generator`, `G1_a`, `G1_b`, `G2_a`, `G2_b` |
| `pasta` | `PallasFp`, `VestaFp`, `Pallas`, `Vesta`, `PallasProjective`, `VestaProjective`, `PallasScalar`, `VestaScalar`, `Pallas_generator`, `Vesta_generator`, `Pallas_a`, `Pallas_b`, `Vesta_a`, `Vesta_b` |
| `hash_to_curve` | `hashToCurve`, `hashToCurveWithCofactor`, `mapToCurveSvdW`, `hashToField`, `expandMessageXmd`, `CurvePoint` |
| `hash_to_curve_derive` | `DeriveError` (`DomainTooLong`, `NoValidPoint`), `max_attempts`, `max_domain_len`, `max_generator_vector_domain_len`, `hashToPoint`, `generatorVector` |
| `msm` | `msm(Aff, Proj, Scalar, allocator, points, scalars) error{LengthMismatch, OutOfMemory}!Proj`, `windowSize` |
| `group_ops` | `GroupOps(Point)`, `identity`, `eql`, `scalarMul` |
| `group_poly` | `evalGroupPoly`, `evalGroupPolyVerify` |
| `byte_scalar` | `ByteScalar(ScalarType, N)` — stdlib-style ECC scalar fields only |

## Running Tests

```bash
# From the monorepo root (runs the inline src/ tests only)
zig build test

# Just this library: inline src/ tests plus the per-curve tests/ roots
cd libs/curve && zig build test
```

`cd libs/curve && zig build test` runs five binaries: `zig-curve-tests`
(52 inline tests), `bn254-tests` (7), `bls12-381-tests` (7), `pasta-tests`
(14) and `hash-to-curve-tests` (16) — 98 tests in total. The root
`zig build test` compiles only the inline `src/` tests, so it counts 52 for
this library.

## Design Notes

- `AffinePoint` uses affine coordinates with `add` / `dbl` / `scalarMul`; `ProjectivePoint` uses Jacobian coordinates for the same operations and converts back with `toAffine`
- Point equality is `eql` (a method). There is no `double`; the doubling entry point is `dbl`
- `hashToPoint` hashes `"{domain}:{counter}"` into a 64-byte stack buffer, so the domain is length-limited: at most `max_domain_len` (43) bytes for `hashToPoint`, and `max_generator_vector_domain_len` (22) for `generatorVector`, which appends `"/{index}"` per element. The search runs at most `max_attempts` (100,000) rounds and then reports `error.NoValidPoint`. Both used to be `catch unreachable` / `unreachable`; they are error unions now, so `const p = hashToPoint(...)` call sites need `try`.
- Hash-to-curve uses Shallue-van de Woestijne mapping (RFC 9380 §6.6.1), which works for any curve including `a = 0`
- BLS12-381: curve equation `y² = x³ + 4` (G1) and `y² = x³ + 4(1+u)` (G2 over Fp2)
- BLS12-381 G1/G2 generators are the canonical spec values
- BN254: curve equation `y² = x³ + 3` (G1) and `y² = x³ + 3/(9+u)` (G2 over Fp2), canonical EIP-197 generators. `G2_b` is derived at comptime as `(27/82) - (3/82)·u`
- `mapToCurveSvdW` searches upward from 1 for a `Z` satisfying both RFC 9380 criteria (`Z` non-square and `−g(Z)·(3Z² + 4a)` square). `a` and `b` are comptime parameters, so the compiler often folds the search
- Pasta scalar fields are cross-wired with the base fields: `PallasScalar = VestaFp`, `VestaScalar = PallasFp`
- This library contains **no signature scheme**. The BLS12-381 Schnorr demo lives in `examples/schnorr_signature.zig` and runs via `zig build example`
- Point arithmetic, scalar multiplication and pairing-adjacent operations are **not constant-time**; do not use them on secret scalars without your own audit
- `msm` rejects a `points`/`scalars` length mismatch with `error.LengthMismatch`; it used to debug-assert it, which vanishes in ReleaseFast and let the scalar snapshot loop read out of bounds
- `group_ops.scalarMul` and `group_poly.evalGroupPoly` / `evalGroupPolyVerify` return `error.NonCanonicalScalar` for a stdlib pcurve point and a non-canonical byte scalar; they used to `catch unreachable` it

## License

MIT OR Apache-2.0
