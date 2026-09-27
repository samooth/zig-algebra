# zig-binary-field

Binary (characteristic-2) Galois fields for Zig. GF(2^n) arithmetic with two field families (polynomial-reduced and Wiedemann tower), CLMUL hardware acceleration, and a Binius-style multilinear polynomial commitment stack.

Library version: **0.3.0** (`libs/binary-field/build.zig.zon`); the workspace
version lives in the root `build.zig.zon`.

## Features

- **Generic `BinaryField(bits, reduction_constant)`** — GF(2^n) reduced modulo an arbitrary irreducible polynomial. The leading `x^bits` term is implicit: you supply only the lower coefficients (e.g. `BinaryField(4, 0x3)` for `x^4 + x + 1`, `BinaryField(128, 0x87)` for the GCM polynomial)
- **Wiedemann tower fields** — `TowerField(level)` builds `T_i = T_{i-1}[X_{i-1}] / (X_{i-1}^2 + X_{i-2}·X_{i-1} + 1)`, so `TowerField(level).BITS == 1 << level`. `TowerField(7)` is GF(2^128)
- **CLMUL hardware acceleration** — x86_64 `PCLMULQDQ` when the CPU has the `pclmul` feature, with a portable bit-sliced software fallback
- **Multilinear polynomial evaluation** — `Multilinear(Field)` with folding-based `eval` / `extend` / `hypercubeSum`, validated with `error.NotPowerOfTwo` / `error.InvalidPointLength`
- **Packed MLE (Binius packing)** — `PackedMle` (with `MAX_K`), `novelNorms`, `novelEval`
- **Sum-check protocol** — `Sumcheck(F)` prover/verifier with a seeded transcript.
  The secure entry point requires `F.BITS >= 128` and returns
  `error.FieldTooSmall` otherwise; `SumcheckUnsafe(F)` is only
  for toy/on-chain experiments such as the historical 4-bit Bitcoin Script
  format and is not sound against a grinding prover.
- **Merkle-committed MLE PCS** — `MlePcs(F, E)` and `CommittedMlePcs(F, E)`
  (the challenge field `E` must have `E.BITS >= 128`), plus the `…Unsafe` toy variants

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_binary_field = .{
        .path = "../zig-algebra/libs/binary-field",
    },
},
```

Then in your `build.zig`:

```zig
const bf = b.dependency("zig_binary_field", .{});
exe.root_module.addImport("zig-binary-field", bf.module("zig-binary-field"));
```

## Quick Start

```zig
const std = @import("std");
const zbf = @import("zig-binary-field");

// `BinaryField` needs BOTH the bit width and the reduction constant.
// AES polynomial: x^8 + x^4 + x^3 + x + 1  ->  reduction_constant = 0x1B
const GF8 = zbf.BinaryField(8, 0x1B);
const a = GF8.fromInt(0x53);
const b = GF8.fromInt(0xCA);
const sum = a.add(b);   // XOR — add and sub are identical in char 2
const prod = a.mul(b);  // carry-less multiply + reduction
std.debug.assert(a.sub(b).eq(sum));
std.debug.assert(prod.eq(a.mul(b)));
std.debug.assert(a.mul(GF8.one()).eq(a));

// Serialization: toBytes writes into a caller-provided buffer, fromBytes
// takes it back by value and cannot fail.
var bytes: [1]u8 = undefined;
a.toBytes(&bytes);
std.debug.assert(GF8.fromBytes(bytes).eq(a));

// `BinaryField.inv` is only implemented for bits == 4 and bits == 128; any
// other width hits a comptime error, so reach for `pow` with an exponent
// derived from 2^bits - 1 instead.
const Gf4 = zbf.BinaryField(4, 0x3);
std.debug.assert(Gf4.fromInt(2).mul(Gf4.fromInt(2).inv()).eq(Gf4.one()));

const Gf128 = zbf.BinaryField(128, 0x87);
const g = Gf128.fromInt(3);
std.debug.assert(g.mul(g.inv()).eq(Gf128.one()));
std.debug.assert(g.pow(3).eq(g.mul(g).mul(g)));

// `inv(0) == 0` is the legacy total result. Zero is not an inverse; call
// `invChecked` when invertibility is a requirement.
std.debug.assert(Gf128.zero().inv().isZero());
try std.testing.expectError(error.InverseOfZero, Gf128.zero().invChecked());
```

### Predefined instances

```zig
// Polynomial-reduced family (BinaryField)
const Gf4_poly = zbf.Gf16;  // == BinaryField(4, 0x3)  — watch the name
const Gf128_poly = zbf.Gf128; // == BinaryField(128, 0x87) — GCM / GHASH
std.debug.assert(Gf4_poly.BITS == 4 and Gf128_poly.BITS == 128);

// Tower family: TowerField(level), BITS = 1 << level
const T0 = zbf.TowerField(0); // Gf2     — 1 bit
const T3 = zbf.TowerField(3); // Gf256   — 8 bits
const T7 = zbf.TowerField(7); // Gf2_128 — 128 bits
std.debug.assert(T0.BITS == 1 and T3.BITS == 8 and T7.BITS == 128);

// Re-exported names
std.debug.assert(zbf.Gf2.BITS == 1);
std.debug.assert(zbf.Gf4.BITS == 2);
std.debug.assert(zbf.Gf256.BITS == 8);
std.debug.assert(zbf.Gf65536.BITS == 16);
std.debug.assert(zbf.Gf2_32.BITS == 32);
std.debug.assert(zbf.Gf2_64.BITS == 64);
std.debug.assert(zbf.Gf2_128.BITS == 128);
```

> **Name collision**: `zbf.Gf16` is `BinaryField(4, 0x3)`, while
> `zbf.tower.Gf16` is `TowerField(2)`. They are different types with the same
> name. Prefer the explicit `zbf.BinaryField(4, 0x3)` / `zbf.TowerField(2)`
> spellings.

### Tower field arithmetic

```zig
const T7 = zbf.Gf2_128;
const t1 = T7.fromInt(3);
const t2 = T7.fromInt(5);

std.debug.assert(t1.mul(t2).eq(t2.mul(t1)));
std.debug.assert(t1.mul(t1.inv()).eq(T7.one()));
std.debug.assert(t1.add(t2).eq(t2.add(t1)));
std.debug.assert(T7.fromInt(0).isZero());

// alpha() adjoins X_{level-1}: alpha^2 + beta*alpha + 1 = 0,
// i.e. alpha^2 = beta*alpha + 1 in characteristic 2.
const alpha = T7.alpha();
const beta = T7.embed(6, zbf.TowerField(6).alpha());
std.debug.assert(alpha.mul(alpha).eq(beta.mul(alpha).add(T7.one())));

// Subfield access, norm, absolute trace, zero-cost embedding
const x = T7.fromInt(12345);
std.debug.assert(T7.fromSubfield(x.toSubfield()).eq(x));
_ = x.norm(); // multiplicative norm into T_{level-1}
_ = x.trace(); // absolute trace to GF(2), returned as u1
```

### Multilinear polynomials and packed MLE

```zig
const G = zbf.Gf256;
const table = [_]G{ G.fromInt(1), G.fromInt(2), G.fromInt(3), G.fromInt(4) };
const mle = zbf.fromEvals(G, &table);
std.debug.assert(mle.numVars() == 2);
std.debug.assert((try mle.numVarsChecked()) == 2); // error.NotPowerOfTwo otherwise

const r = [_]G{ G.fromInt(5), G.fromInt(6) };
const value = try mle.eval(allocator, &r); // fold every variable, then read
_ = value;

const ext = try mle.extend(allocator, &r); // partial fold, keeps a table
defer allocator.free(ext);
std.debug.assert(ext.len == 1);

_ = mle.hypercubeSum(); // the claimed sum H

// Packed MLE helpers. `k` must satisfy `1 <= k <= P.MAX_K`; everything else
// is error.InvalidDimension, and any length mismatch error.LengthMismatch.
const P = zbf.PackedMle(G);
std.debug.assert(P.MAX_K == @min(G.BITS, @bitSizeOf(usize) - 2));
const coeffs = [_]G{ G.fromInt(1), G.fromInt(2), G.fromInt(3), G.fromInt(4), G.fromInt(5), G.fromInt(6), G.fromInt(7), G.fromInt(8) };
const x3 = [_]G{ G.fromInt(0), G.fromInt(1), G.fromInt(2) };
_ = try P.eval(allocator, 3, &coeffs, &x3);
_ = try P.vanishingPoly(allocator, 3);
_ = try P.interpolate(allocator, 3, &coeffs);
_ = P.betaOnH(3, &x3, 1);          // legacy: a short r yields zero
_ = try P.betaOnHChecked(3, &x3, 1); // error.LengthMismatch when r.len < k
_ = zbf.novelNorms(G, 3);
_ = try zbf.novelEval(allocator, G, 3, &coeffs, x3[1]);
```

### CLMUL

```zig
const cl = zbf.clmul;
// true when the CPU has PCLMULQDQ and the hardware path is in use
if (cl.has_hardware_clmul) {
    const p = cl.clmul64(3, 5); // 128-bit polynomial product
    _ = p;
}
const q = cl.clmul128(3, 5); // 256-bit polynomial product
_ = q;
```

### Sum-check and PCS

```zig
// Secure entry points: these require F.BITS >= 128 and return
// error.FieldTooSmall for a smaller field (e.g. GF(256)).
const S = zbf.Sumcheck(zbf.Gf2_128);
_ = S; // prove / verify, plus a seeded transcript variant

const Pcs = zbf.MlePcs(zbf.Gf256, zbf.Gf2_128);
const Committed = zbf.CommittedMlePcs(zbf.Gf256, zbf.Gf2_128);
_ = Pcs;
_ = Committed;
```

> **The `…Unsafe` family is not secure.** `SumcheckUnsafe`, `MlePcsUnsafe` and
> `CommittedMlePcsUnsafe` skip the `E.BITS >= 128` check so the historical
> 4-bit on-chain challenge format stays testable over GF(2^4) and GF(2^8). A
> prover can grind challenges in a field that small, so a proof accepted by
> these entry points proves nothing to a remote verifier. Use them for the
> on-chain toy format and for tests only.

## Running Tests

```bash
# From the monorepo root
zig build test

# Just this library (74 tests, all inline)
cd libs/binary-field && zig build test
```

## Known limitations

- `inv(0) == 0` in `BinaryField` and at every `TowerField` level is the legacy
  total result, not a valid inverse. `invChecked` reports
  `error.InverseOfZero`; at the GF(2) base case it also rejects any value other
  than `one()`.
- `Sumcheck(F)` needs `F.BITS >= 128`; `MlePcs(F, E)` and
  `CommittedMlePcs(F, E)` need `E.BITS >= 128` for their challenge field. The
  `…Unsafe` variants are grindable and toy-only.
- Not a full Binius implementation: there is no Binius commit of a packed MLE
  beyond `CommittedMlePcs`.

## Design Notes

- Addition is XOR (no carry), so `sub` is an alias for `add`
- `BinaryField` stores elements in a `u128` and multiplies with a portable
  bit-loop plus polynomial reduction mod `x^bits + reduction_constant`. It
  does **not** use the CLMUL path, and `inv` is only implemented for `bits`
  equal to 4 or 128
- `TowerField` uses the canonical Binius / [DP23 §2.3] tower, storing elements
  in the multilinear (Cantor) monomial basis. Multiplication is the
  Karatsuba-style recursion and inversion is the recursive norm-conjugate
  method of [FP97], costing O(level) field operations
- Subfield embedding in the tower is **zero-cost**: an element of `T_{i-1}`
  is the same bit string as its image in `T_i`
- `clmul.clmul64` / `clmul128` use inline `PCLMULQDQ` on x86_64 with the
  `pclmul` CPU feature and fall back to a bit-sliced software implementation
  everywhere else. There is no ARM `PMULL` path
- `src/accel.zig` defines an optional GPU `values[t]` hook for the Gf256
  sum-check. It is internal: the library never depends on CUDA, and the hook
  is not re-exported from `root.zig`
- **Dimensions and lengths are typed errors, not asserts.** `std.debug.assert`
  is compiled out in `ReleaseFast`, so a range such as `k` in `PackedMle`, a
  MLE table length or a query-point length is validated with
  `error.InvalidDimension` / `error.LengthMismatch` / `error.NotPowerOfTwo` /
  `error.InvalidPointLength` and propagated from `eval`, `extend`,
  `interpolate`, `kernelPoly`, `mulModVanishing` and `novelEval`.
  `PackedMle.MAX_K` is the documented upper bound (`min(F.BITS,
  bitSizeOf(usize) - 2)`), because the vanishing polynomial of a dimension-`k`
  subspace allocates `2^(k+1) - 1` elements.

## License

MIT OR Apache-2.0
