# zig-curve

Elliptic curve implementations for Zig. Re-exports stdlib curves and provides custom implementations for pairing-friendly/SNARK curves with generic Weierstrass arithmetic and hash-to-curve (RFC 9380).

## Features

- **Generic Weierstrass curves** — `AffinePoint(F, a, b)` and `ProjectivePoint(F, a, b)` with Jacobian coordinates
- **Stdlib re-exports** — Curve25519, Ed25519, Ristretto255, Secp256k1, P256, P384
- **BN254** — G1, G2 (pairing-friendly, used by Ethereum zkSNARKs)
- **BLS12-381** — G1, G2 (pairing-friendly, used by BLS signatures, Ethereum 2.0)
- **Pasta cycle** — Pallas, Vesta (used by Halo2, recursive SNARKs)
- **Hash-to-curve** — RFC 9380 Shallue-van de Woestijne mapping, `expand_message_xmd`, `hash_to_field`
- **Schnorr signature type** — `(R: Point, z: Scalar)` with serialization
- **Scalar field arithmetic** — secp256k1 scalar operations (add, mul, inv, random)
- **Point operations** — add, double, scalar multiply, SEC1 serialization

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_curve = .{
        .path = "path/to/zig-algebra-core/zig-curve",
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
const zc = @import("zig-curve");

// BN254 curve operations
const G1 = zc.bn254.G1_generator;
const G2 = G1.double().add(G1); // 3*G1
const P = G1.scalarMul(scalar);

// BLS12-381
const bls_G1 = zc.bls12_381.G1_generator;
const bls_G2 = zc.bls12_381.G2_generator;

// Pasta cycle
const pallas = zc.pasta.Pallas_generator;
const vesta = zc.pasta.Vesta_generator;

// Hash-to-curve (RFC 9380)
const point = zc.hash_to_curve.hashToCurve(F, a, b, "hello", "DST");

// Stdlib curves
const secp = zc.secp256k1; // std.crypto.ecc.Secp256k1
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
| `bn254` | `G1`, `G2`, `G1_generator`, `G2_generator`, `Fr` |
| `bls12_381` | `G1`, `G2`, `G1_generator`, `G2_generator`, `Fr` |
| `pasta` | `Pallas`, `Vesta`, `Pallas_generator`, `Vesta_generator` |
| `hash_to_curve` | `hashToCurve`, `mapToCurveSvdW`, `hashToField`, `expandMessageXmd` |

## Running Tests

```bash
zig build test
```

## Design Notes

- Weierstrass curves use Jacobian projective coordinates for efficient addition/doubling
- Hash-to-curve uses Shallue-van de Woestijne mapping (RFC 9380 §6.6.1), which works for any curve including a=0
- BLS12-381 Fp2 is defined locally (quadratic extension of BLS12_381_Fp)
- All generators are computed and verified at comptime

## License

MIT OR Apache-2.0
