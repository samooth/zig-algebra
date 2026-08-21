# zig-field

A generic prime-field arithmetic library for Zig, supporting fields up to 512 bits with Montgomery arithmetic and tower extensions.

## Features

- **Generic `Field(comptime modulus)` factory** — create prime fields of any size up to 512 bits
- **Dual backend**:
  - **Small fields** (< 2^64): native `u64` with fast reduction; Mersenne primes (`2^k - 1`) use the classic split reduction
  - **Large fields** (≥ 2^64): Montgomery arithmetic over `[N]u64` limbs using CIOS multiplication
- **SIMD Vec8 backend for M31** — 8-lane `@Vector(8, u64)` arithmetic with per-lane Mersenne reduction (`addVec8`, `subVec8`, `mulVec8`, `reduceVec8`, `fromVec8U32`, etc.)
- **Tower extensions**: `QuadraticExtension` and `CubicExtension` with Karatsuba multiplication and norm-based inversion
- **Extension metadata**: `NON_RESIDUE` (base-field non-residue) and `EXT_NON_RESIDUE` (`v` where `v^2 = n` or `v^3 = n`) exposed on both extension types
- **Power-of-two roots of unity** — computed via quadratic non-residue search (no factorization required)
- **Tonelli-Shanks square roots** and Legendre symbols
- **Predefined fields**: M31, BabyBear, KoalaBear, Goldilocks, M61, BN254, BLS12-381, StarkNet, Pallas, Vesta
- **Extension towers**: CM31, QM31, BN254_Fp2, BN254_Fp6/Fp12, BLS12_381_Fp2/Fp6/Fp12 (matching zig-stark semantics)
- **Native NTT/INTT** — Cooley-Tukey iterative in-place transforms with precomputed twiddles, 8-lane SIMD for M31
- **Multi-scalar exponentiation** — `multiExp` with windowed Pippenger algorithm
- **Inner Product Argument (IPA)** — Bulletproofs-style proof of `<a, b> = c` without revealing vectors
- **Merkle trees** — SHA-256 based trees over field elements with inclusion proofs
- **Constant-time serialization**: `fromBytesCT` / `fromIntCT` with validity flag for secret data
- **No allocations**, no external dependencies — only Zig standard library

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_field = .{
        .url = "https://github.com/samooth/zig-field/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const zf = b.dependency("zig_field", .{});
exe.root_module.addImport("zig-field", zf.module("zig-field"));
```

## Quick Start

```zig
const std = @import("std");
const zf = @import("zig-field");

// Create a prime field
const F = zf.Field(2147483647); // M31

// Basic arithmetic
const a = F.fromInt(12345);
const b = F.fromInt(67890);
const sum = a.add(b);
const prod = a.mul(b);
const inv = a.inv();

// Power-of-two roots of unity (for NTT)
const root = F.primitiveRootOfUnity(4); // 16th root of unity
try std.testing.expect(root.pow(16).isOne());

// Square roots and Legendre symbols
const legendre = a.legendre();
const sqrt_a = a.sqrt() orelse return error.NoSquareRoot;

// Serialization
const bytes = a.toBytes();
const a2 = F.fromBytes(&bytes);
try std.testing.expect(a.eq(a2));

// Constant-time serialization (for secret data)
const ct_result = F.fromBytesCT(bytes);
const a3 = ct_result.value;
try std.testing.expect(ct_result.valid);

// Random elements
var prng = std.Random.DefaultPrng.init(42);
const rand = F.random(prng.random());
```

## Tower Extensions

```zig
const M31 = zf.M31;

// Quadratic extension: CM31 = M31[i]/(i^2 + 1)
const CM31 = zf.QuadraticExtension(M31, M31.fromInt(M31.MODULUS - 1)); // i^2 = -1

// Quadratic extension: QM31 = CM31[j]/(j^2 + i)
const QM31 = zf.QuadraticExtension(CM31, CM31.new(M31.zero(), M31.fromInt(M31.MODULUS - 1))); // j^2 = -i

const i = CM31.new(M31.zero(), M31.one());
try std.testing.expect(i.mul(i).eq(CM31.fromBase(M31.one().neg())));

const j = QM31.new(CM31.zero(), CM31.one());
const minus_i = QM31.new(CM31.imaginaryUnit().neg(), CM31.zero());
try std.testing.expect(j.mul(j).eq(minus_i));
```

## SIMD Vec8 (M31)

```zig
const M31 = zf.M31;

// 8-lane vector arithmetic
const a: M31.Vec8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
const b: M31.Vec8 = .{ 8, 7, 6, 5, 4, 3, 2, 1 };

// Add with Mersenne reduction
const sum = M31.addVec8(a, b);

// Multiply with lo+hi fold (may be >= 2*MOD)
const prod = M31.mulVec8(a, b);

// Normalize to [0, MOD)
const norm = M31.reduceVec8(prod);

// Convert from zig-stark's @Vector(8, u32) layout
const u32_vec: @Vector(8, u32) = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
const vec8 = M31.fromVec8U32(u32_vec);
const back = M31.toVec8U32(vec8);
```

## Predefined Fields

```zig
// Base fields
const M31 = zf.M31;                    // 2^31 - 1
const BabyBear = zf.BabyBear;          // 2^31 - 2^27 + 1
const KoalaBear = zf.KoalaBear;        // 2^31 - 2^24 + 1
const Goldilocks = zf.Goldilocks;      // 2^64 - 2^32 + 1
const M61 = zf.M61;                    // 2^61 - 1 (largest Mersenne in u64)
const StarkNet_Fp = zf.StarkNet_Fp;    // 2^251 + 17*2^192 + 1 (Cairo VM)
const Pallas_Fp = zf.Pallas_Fp;        // Pasta cycle for recursive SNARKs
const Vesta_Fp = zf.Vesta_Fp;          // Pasta cycle for recursive SNARKs
const BN254_Fp = zf.BN254_Fp;          // BN254 base field
const BLS12_381_Fp = zf.BLS12_381_Fp;  // BLS12-381 base field

// Extension towers (matching zig-stark)
const CM31 = zf.CM31;                  // M31 quadratic extension, v^2 = -1
const QM31 = zf.QM31;                  // CM31 quadratic extension, v^2 = -i
const BN254_Fp2 = zf.BN254_Fp2;        // BN254 quadratic extension, v^2 = -1
const BN254_Fp6 = zf.BN254_Fp6;        // BN254 tower extension
const BN254_Fp12 = zf.BN254_Fp12;      // BN254 full extension for pairings
const BLS12_381_Fp2 = zf.BLS12_381_Fp2;  // BLS12-381 quadratic extension
const BLS12_381_Fp6 = zf.BLS12_381_Fp6;  // BLS12-381 tower extension
const BLS12_381_Fp12 = zf.BLS12_381_Fp12; // BLS12-381 full extension for pairings

// Extension metadata (for zig-stark adapter)
const CM31_n = CM31.NON_RESIDUE;       // -1 in M31
const CM31_v = CM31.EXT_NON_RESIDUE;   // i = 0 + 1·i
const QM31_n = QM31.NON_RESIDUE;       // -i in CM31
const QM31_v = QM31.EXT_NON_RESIDUE;   // j = 0 + 1·j
```

## Multi-Scalar Exponentiation

```zig
const F = zf.M31;

// Windowed Pippenger algorithm: product(bases[i]^exponents[i])
const bases = [_]F{ F.fromInt(2), F.fromInt(3), F.fromInt(5) };
const exponents = [_]u64{ 10, 20, 30 };
const result = F.multiExp(&bases, &exponents, 4); // 4-bit window
```

## Inner Product Argument (IPA)

```zig
var ipa = try zf.Ipa(F).init(allocator, 64, seed);
defer ipa.deinit();

const c = zf.Ipa(F).innerProduct(&a, &b);
const proof = try ipa.prove(allocator, &a, &b, c);
defer proof.deinit(allocator);

try ipa.verifyWithCommitment(commitment, &proof);
```

## Merkle Trees

```zig
var tree = try zf.MerkleTree(F).init(allocator, &leaves);
defer tree.deinit();

const root = tree.rootHash();
const proof = try tree.proof(allocator, index);
try zf.MerkleTree(F).verify(root, index, proof, leaf);
```

## Native NTT/INTT

```zig
const F = zf.BabyBear;
var data = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4) };
const log_n = 2;
const root = F.primitiveRootOfUnity(log_n);

zf.ntt(F, &data, log_n, root);  // Forward NTT
zf.intt(F, &data, log_n, root); // Inverse NTT (round-trips)

// With precomputed twiddles
const twiddles = try zf.precomputeTwiddles(F, log_n, root, allocator);
defer zf.freeTwiddles(F, twiddles, allocator);
zf.nttWithTwiddles(F, &data, log_n, twiddles);
```

## Running Tests

```bash
# Debug mode (slow for large fields)
zig build test

# ReleaseFast for performance tests
zig build bench -Doptimize=ReleaseFast
```

## Design Notes

- **Montgomery constants** (`R^2`, `-p^{-1} mod 2^64`) are derived at comptime from the modulus using arbitrary-precision comptime integers
- **Roots of unity** use the quadratic non-residue method: find `z` with `(z/p) = -1`, then `z^((p-1)/2^t)` has exact order `2^t` — no factorization of `p-1` needed
- **Square roots** use Tonelli-Shanks with `p ≡ 3 mod 4` shortcut when two-adicity is 1
- **Extension field inverses** use the norm-based formula: `(a + bv)^{-1} = (a - bv) / (a^2 - n b^2)` for `v^2 = n`
- **Cubic extension inverse** uses the closed form with `v^3 = n`
- **zig-stark integration**: Vec8 SIMD backend matches zig-stark's `@Vector(8, u32)` lane layout; `NON_RESIDUE` / `EXT_NON_RESIDUE` on extension types enable generic tower reconstruction without hardcoding non-residues

## License

MIT OR Apache-2.0