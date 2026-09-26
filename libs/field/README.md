# zig-field

A generic prime-field arithmetic library for Zig, supporting fields up to 512 bits with Montgomery arithmetic and tower extensions.

## Features

- **Generic `Field(comptime modulus)` factory** — create prime fields of any size up to 512 bits
- **Dual backend**:
  - **Small fields** (< 2^64): native `u64` with fast reduction; Mersenne primes (`2^k - 1`) use the classic split reduction
  - **Large fields** (≥ 2^64): Montgomery arithmetic over `[N]u64` limbs using CIOS multiplication
- **SIMD Vec8 backend for M31** — 8-lane `@Vector(8, u64)` arithmetic with per-lane Mersenne reduction (`addVec8`, `subVec8`, `mulVec8`, `reduceVec8`, `fromVec8U32`, `toVec8U32`)
- **Tower extensions**: `QuadraticExtension` and `CubicExtension` with Karatsuba multiplication and norm-based inversion
- **Extension metadata**: `NON_RESIDUE` (base-field non-residue) and `EXT_NON_RESIDUE` (`v` where `v^2 = n` or `v^3 = n`) exposed on both extension types
- **Power-of-two roots of unity** — computed via quadratic non-residue search (no factorization required)
- **Tonelli-Shanks square roots** and Legendre symbols
- **Predefined fields**: M31, BabyBear, KoalaBear, Goldilocks, M61, StarkNet, Pallas, Vesta, BN254, BLS12-381
- **Extension towers**: CM31, QM31, BN254_Fp2 (matching zig-stark semantics)
- **8-lane SIMD NTT/INTT for M31** — `nttVec8M31` / `inttVec8M31` (the generic Cooley-Tukey transform with precomputed twiddles lives in `zig-ntt`)
- **Multi-scalar exponentiation** — `multiExp` with windowed Pippenger algorithm
- **Inner Product Argument (IPA)** — Bulletproofs-style proof of `<a, b> = c` without revealing vectors
- **Merkle trees** — SHA-256 based trees over field elements with inclusion proofs
- **Constant-time serialization on large-field backends**: `fromBytesCT` / `fromIntCT` with a validity flag; small-field reduction may still use `%`
- **Allocation-free core** — field arithmetic, roots, and extensions never allocate. `Ipa` and `MerkleTree` take a caller-supplied `std.mem.Allocator`
- **One internal dependency** — `zig-bigint` (plus the Zig standard library)

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_field = .{
        .path = "../zig-algebra/libs/field",
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
const F = zf.Field(2147483647); // 2^31 - 1, same modulus as zf.M31

// Basic arithmetic
const a = F.fromInt(12345);
const b = F.fromInt(67890);
const sum = a.add(b);
const prod = a.mul(b);
const inv = a.inv();

// Power-of-two roots of unity (for NTT).
// M31 has two_adicity == 1, so it only exposes 2^1-roots — use a field with
// a large 2-adic part (BabyBear has two_adicity == 27) for NTT-sized domains.
const BB = zf.BabyBear;
const root = BB.primitiveRootOfUnity(4); // 16th root of unity
std.debug.assert(root.pow(16).isOne());

// Square roots and Legendre symbols
const legendre = a.legendre(); // -1, 0 or 1
const sqrt_a = F.fromInt(4).sqrt() orelse return error.NoSquareRoot;

// Serialization (little-endian, exactly NUM_BYTES)
const bytes = a.toBytes();
const a2 = try F.fromBytes(&bytes); // error.InvalidLength / error.ValueOutOfRange
std.debug.assert(a.eql(a2));

// Branch-free serialization for public or secret data.
// Returns .value plus .valid = (input < MODULUS).
const ct_result = F.fromBytesCT(bytes);
std.debug.assert(ct_result.valid);
std.debug.assert(ct_result.value.eql(a));

// Random elements
var prng = std.Random.DefaultPrng.init(42);
const rand = F.random(prng.random());
```

> **Constant-time caveat**: `fromBytesCT` / `fromIntCT` never branch on the input.
> For large fields (≥ 2^64) the comparison and selection are limb-wise bitwise, so
> they are timing-constant. For small fields the reduction uses `v % MODULUS`,
> whose latency varies on x86-64 — use them on public data there, and keep
> secret-scalar code on the `inv`/`mul` paths with your own audit.

## Tower Extensions

```zig
const zf = @import("zig-field");
const M31 = zf.M31;

// Quadratic extension: CM31 = M31[v]/(v^2 + 1)  (identical to zf.CM31)
const CM31 = zf.QuadraticExtension(M31, M31.fromInt(M31.MODULUS - 1)); // v^2 = -1

// Quadratic extension: QM31 = CM31[j]/(j^2 + i)  (identical to zf.QM31)
const QM31 = zf.QuadraticExtension(CM31, CM31.new(M31.zero(), M31.fromInt(M31.MODULUS - 1)));

const i = CM31.new(M31.zero(), M31.one());
std.debug.assert(i.mul(i).eq(CM31.fromBase(M31.one().neg())));

const j = QM31.new(CM31.zero(), CM31.one());
const minus_i = QM31.new(CM31.imaginaryUnit().neg(), CM31.zero());
std.debug.assert(j.mul(j).eq(minus_i));

// Cubic extension: same factory shape, three coefficients.
// The non-residue must be a *cubic* non-residue (comptime-asserted): 3 is a
// cube mod M31, 5 is not.
const C3 = zf.CubicExtension(M31, M31.fromInt(5)); // v^3 = 5
const w = C3.new(M31.zero(), M31.one(), M31.zero()); // the generator v
std.debug.assert(w.mul(w).mul(w).eq(C3.fromBase(M31.fromInt(5))));
```

## SIMD Vec8 (M31)

```zig
const zf = @import("zig-field");
const M31 = zf.M31;

// 8-lane vector arithmetic
const a: M31.Vec8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
const b: M31.Vec8 = .{ 8, 7, 6, 5, 4, 3, 2, 1 };

// Add with Mersenne reduction
const sum = M31.addVec8(a, b);

// Multiply with lo+hi fold (result may be >= 2*MODULUS)
const prod = M31.mulVec8(a, b);

// Normalize to [0, MODULUS)
const norm = M31.reduceVec8(prod);

// Convert from zig-stark's @Vector(8, u32) layout
const u32_vec: @Vector(8, u32) = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
const vec8 = M31.fromVec8U32(u32_vec);
const back = M31.toVec8U32(vec8);
```

## Predefined Fields

```zig
const zf = @import("zig-field");

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

// Extension metadata (for zig-stark adapters)
const CM31_n = CM31.NON_RESIDUE;       // -1 in M31 (an M31 element)
const CM31_v = CM31.EXT_NON_RESIDUE;   // 0 + 1*v, a CM31 element
const QM31_n = QM31.NON_RESIDUE;       // -i, a CM31 element
const QM31_v = QM31.EXT_NON_RESIDUE;   // 0 + 1*j, a QM31 element
```

`Fp6` / `Fp12` sextic towers are **not** part of this library, and
`zf.BLS12_381_Fp2` is a broken re-export (it points at a symbol that does not
exist in `predef/bls12_381.zig`, so referencing it fails to compile). Use
`zig-pairing` (`bn254_tower.Fp6` / `Fp12`, `bls12_381.Fp6` / `Fp12`) for the
sextic towers, or `zc.bls12_381.Fp2` from `zig-curve` for the BLS12-381
quadratic extension:

```zig
const zc = @import("zig-curve");
const B2 = zc.bls12_381.Fp2; // Fp2 = Fp[u]/(u^2 + 1)
```

## Multi-Scalar Exponentiation

```zig
const zf = @import("zig-field");
const F = zf.M31;

// Windowed Pippenger algorithm: product(bases[i]^exponents[i])
const bases = [_]F{ F.fromInt(2), F.fromInt(3), F.fromInt(5) };
const exponents = [_]u64{ 10, 20, 30 };
const result = F.multiExp(&bases, &exponents, 4); // 4-bit window
```

## Inner Product Argument (IPA)

```zig
const zf = @import("zig-field");
const F = zf.M31;
const Ipa = zf.Ipa(F);

const seed: [32]u8 = [_]u8{7} ** 32;
var ipa = try Ipa.init(allocator, 8, seed); // n must be a power of two
defer ipa.deinit();

var a: [8]F = undefined;
var b: [8]F = undefined;
for (0..8) |k| {
    a[k] = F.fromInt(k + 1);
    b[k] = F.fromInt(9 - k);
}

const c = Ipa.innerProduct(&a, &b);          // <a, b>
const commitment = ipa.commit(&a, &b, c);   // public commitment to the vectors

const proof = try ipa.prove(allocator, &a, &b);
defer proof.deinit(allocator);

// Verification requires the commitment that was published at commit time.
try ipa.verifyWithCommitment(commitment, &proof);

// `verify` is an unimplemented stub: it always fails with error.Unsupported.
try std.testing.expectError(error.Unsupported, ipa.verify(&proof, c));
```

## Merkle Trees

`MerkleTree(F)` is a SHA-256 tree over field elements, independent of
`zig-merkle` (which is generic over the hash function).

```zig
const zf = @import("zig-field");
const F = zf.M31;
const Tree = zf.MerkleTree(F);

const leaves = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4) };
var tree = try Tree.init(allocator, &leaves);
defer tree.deinit();

const root = tree.rootHash();                    // [32]u8
const proof = try tree.proof(allocator, 2);      // []const [32]u8
defer allocator.free(proof);

std.debug.assert(Tree.verify(root, 2, proof, leaves[2]));
```

## NTT / INTT

The generic transform (Cooley-Tukey, in-place, optional precomputed twiddles)
lives in `zig-ntt`. `zig-field` keeps only the M31 8-lane SIMD entry points.

```zig
const zf = @import("zig-field");
const zntt = @import("zig-ntt");

// --- zig-ntt: scalar Cooley-Tukey with optional twiddle table ---
const F = zf.BabyBear;
var data = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4) };
const log_n = 2;
const root = F.primitiveRootOfUnity(log_n);

zntt.ntt(F, &data, log_n, root);  // Forward NTT
zntt.intt(F, &data, log_n, root); // Inverse NTT (round-trips)

const twiddles = try zntt.precomputeTwiddles(F, log_n, root, allocator);
defer zntt.freeTwiddles(F, twiddles, allocator);
zntt.nttWithTwiddles(F, &data, log_n, twiddles);
zntt.inttWithTwiddles(F, &data, log_n, twiddles);

// --- zig-field: M31 8-lane SIMD, data.len must be 8 * 2^log_n ---
const M31 = zf.M31;
var lanes: [16]M31 = undefined;
for (&lanes, 0..) |*slot, k| slot.* = M31.fromInt(k + 1);
const m31_root = M31.primitiveRootOfUnity(1); // 2^1-roots only on M31
zf.nttVec8M31(&lanes, 1, m31_root);
zf.inttVec8M31(&lanes, 1, m31_root);
```

## Running Tests

```bash
# From the monorepo root (runs the inline src/ tests only)
zig build test

# Just this library: inline src/ tests plus the per-topic tests/ roots
cd libs/field && zig build test
```

`cd libs/field && zig build test` runs seven binaries — `zig-field-tests` (11
inline), `field-tests` (37), `extension-tests` (9), `merkle-tests` (4),
`ipa-tests` (2), `simd-tests` (5) and `ext_quick-tests` (2) — 70 tests total.

## Design Notes

- **Montgomery constants** (`R^2`, `-p^{-1} mod 2^64`) are derived at comptime from the modulus using arbitrary-precision comptime integers
- **Roots of unity** use the quadratic non-residue method: find `z` with `(z/p) = -1`, then `z^((p-1)/2^t)` has exact order `2^t` — no factorization of `p-1` needed. `primitiveRootOfUnity(t)` debug-asserts `t <= two_adicity`, which is why M31 (`two_adicity == 1`) cannot host an NTT domain
- **Square roots** use Tonelli-Shanks with `p ≡ 3 mod 4` shortcut when two-adicity is 1
- **Extension field inverses** use the norm-based formula: `(a + bv)^{-1} = (a - bv) / (a^2 - n b^2)` for `v^2 = n`
- **Cubic extension inverse** uses the closed form with `v^3 = n`
- **zig-stark integration**: Vec8 SIMD backend matches zig-stark's `@Vector(8, u32)` lane layout; `NON_RESIDUE` / `EXT_NON_RESIDUE` on extension types enable generic tower reconstruction without hardcoding non-residues
- **Mersenne Vec8 multiply** returns a `lo+hi` folded value that may exceed `2 * MODULUS`; call `reduceVec8` before comparing or serializing

## License

MIT OR Apache-2.0
