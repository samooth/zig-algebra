# zig-ntt

Number-Theoretic Transform over finite fields: iterative Cooley–Tukey radix-2
NTT/INTT with bit-reversal permutation, plus an optional precomputed-twiddle
fast path. The transform engine behind polynomial-heavy STARK/SNARK code.

## Features

- **In-place iterative NTT/INTT** — O(n log n), no allocation
- **Bit-reversal permutation** — built in, derived from `data.len` (not passed)
- **Precomputed twiddles** — one slice per stage, reused across transforms
- **Generic over any `zig-field` field** with `log_n <= F.two_adicity`
- **Twiddled path is bit-identical** to the recomputing path (there is a
  regression test asserting it)
- **Power-of-two sizes only** — standard radix-2

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_ntt = .{
        .path = "path/to/zig-algebra/libs/ntt",
    },
},
```

Then in your `build.zig`:

```zig
const zntt = b.dependency("zig_ntt", .{});
exe.root_module.addImport("zig-ntt", zntt.module("zig-ntt"));
```

## Quick Start

```zig
const std = @import("std");
const zntt = @import("zig-ntt");
const F = @import("zig-field").BabyBear;

pub fn main() !void {
    var data = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4) };
    const log_n: usize = 2;                  // length 4, must be <= F.two_adicity
    const root = F.primitiveRootOfUnity(log_n);

    // Forward NTT, then inverse: the round trip restores `data`.
    try zntt.ntt(F, &data, log_n, root);
    const transformed = data;
    try zntt.intt(F, &data, log_n, root);

    // Bit-reversal takes the FIELD TYPE and the slice; it derives log_n itself.
    var rev = [_]F{ F.fromInt(0), F.fromInt(1), F.fromInt(2), F.fromInt(3) };
    try zntt.bitReverse(F, &rev);                 // -> { 0, 2, 1, 3 }

    // With precomputed twiddles (faster for repeated transforms).
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const twiddles = try zntt.precomputeTwiddles(F, log_n, root, allocator);
    defer zntt.freeTwiddles(F, twiddles, allocator);

    var d2 = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4) };
    try zntt.nttWithTwiddles(F, &d2, log_n, twiddles);   // same output as ntt()
    try zntt.inttWithTwiddles(F, &d2, log_n, twiddles);  // inverse, includes 1/n

    std.debug.print("ntt={any} roundtrip_ok={} twiddle_lens={any}\n", .{
        transformed, data[0].eql(F.fromInt(1)), [_]usize{ twiddles[0].len, twiddles[1].len } });
}
```

## API

Every function takes the field type as the first `comptime` argument.

| Function | Signature | Notes |
|----------|-----------|-------|
| `ntt` | `(comptime F, data: []F, log_n: usize, root: F) error{LogTooLarge, LengthMismatch, InvalidLength}!void` | in place; `error.LengthMismatch` when `data.len != 2^log_n` |
| `intt` | `(comptime F, data: []F, log_n: usize, root: F) error{LogTooLarge, LengthMismatch, InvalidLength}!void` | in place; multiplies by `n⁻¹` |
| `bitReverse` | `(comptime F, data: []F) error{InvalidLength}!void` | **no `log_n` argument** — derived from `data.len`; `error.InvalidLength` when it is zero or not a power of two |
| `precomputeTwiddles` | `(comptime F, log_n: usize, root: F, allocator) error{LogTooLarge, OutOfMemory}![]const []const F` | `log_n` slices, caller frees |
| `freeTwiddles` | `(comptime F, twiddles: []const []const F, allocator) void` | frees the slices and the outer array |
| `nttWithTwiddles` | `(comptime F, data: []F, log_n: usize, twiddles: []const []const F) error{LogTooLarge, LengthMismatch, InvalidTwiddles, InvalidLength}!void` | `error.InvalidTwiddles` when the table or a stage has the wrong length |
| `inttWithTwiddles` | `(comptime F, data: []F, log_n: usize, twiddles: []const []const F) error{LogTooLarge, LengthMismatch, InvalidTwiddles, InvalidLength}!void` | `error.InvalidTwiddles` when the table or a stage has the wrong length |

The field must satisfy the `Field` trait (checked with `zig-algebra-traits`), and
`root` must be a primitive `2^log_n`-th root of unity, which is what
`F.primitiveRootOfUnity(log_n)` returns.

`log_n == 0` is legal (a length-1 transform) for `ntt`/`intt`;
`precomputeTwiddles(F, 0, …)` returns a zero-length outer slice, and the
`nttWithTwiddles`/`inttWithTwiddles` stage loop then does nothing.

## Twiddle layout

`precomputeTwiddles` returns `log_n` stages. Stage `s` has `2^s` entries:

```text
twiddles[s].len == 2^s
twiddles[s][j]  == (root ^ (2 ^ (log_n - 1 - s)))^j     for j in 0 .. 2^s
```

For `log_n = 2` that gives `twiddles[0] = [1]` (stage `wm = root²`, one entry)
and `twiddles[1] = [1, root]` (`wm = root`, two entries). Stage `s` is consumed
by the butterfly stage with `m = 2^(s+1)`, which needs exactly `m/2 = 2^s`
twiddles — the lengths line up by construction.

## Field support (`two_adicity` is the hard limit)

`F.primitiveRootOfUnity(log_size)` debug-asserts `log_size <= F.two_adicity`, so
the usable `log_n` is bounded by it:

| Field | `two_adicity` | max `log_n` |
|-------|---------------|-------------|
| M31 | 1 | 1 |
| M61 | 1 | 1 |
| BN254_Fp | 1 | 1 |
| BLS12_381_Fp | 1 | 1 |
| KoalaBear | 24 | 24 |
| BabyBear | 27 | 27 |
| Goldilocks | 32 | 32 |
| Pallas_Fp / Vesta_Fp | 32 | 32 |
| StarkNet_Fp | 192 | 192 |

So "works with M31, BabyBear, BN254, BLS12-381" is true only in the sense that
they *compile*: BN254_Fp, BLS12_381_Fp, M31 and M61 only admit `log_n <= 1`
(2-point transforms), and asking for `log_n = 2` on them aborts the assertion in
`roots.primitiveRootOfUnity`. For a 256+-point transform you need Goldilocks,
BabyBear, KoalaBear, Pallas/Vesta or StarkNet.

## SIMD variant

`zig-field` ships an 8-lane SIMD NTT for M31 as
`zf.nttVec8M31(data, log_n, root)` and `zf.inttVec8M31(data, log_n, root)`, using
`M31.Vec8` (`@Vector(8, u64)`) butterflies to run eight transforms in parallel.
It lives in `zig-field/src/lib.zig` (`Vec8NttM31`), not here, and it inherits
M31's `two_adicity = 1` limit. The checked variants
`zf.nttVec8M31Checked` / `zf.inttVec8M31Checked` return `error.InvalidLength`
for a mismatched buffer; the plain ones leave it untouched.

## Known limitations

- The length and shape contracts of `ntt`, `intt`, `bitReverse` and the twiddle
  variants are typed errors, not asserts. Before 0.2.0 they were
  `std.debug.assert`s, which abort in Debug/ReleaseSafe and vanish in
  ReleaseFast, where a wrong `log_n` was out-of-bounds access.
- `2^log_n` is computed with an explicit `error.LogTooLarge` for
  `log_n >= @bitSizeOf(usize)`; the old `std.math.pow(usize, 2, log_n)`
  overflowed there.
- `root` is *not* validated: passing a root of the wrong order produces a wrong
  transform rather than an error. Only the buffer shape is checked.
- `F.primitiveRootOfUnity(log_size)` in `zig-field` still debug-asserts
  `log_size <= F.two_adicity`, so asking a two-adicity-1 field (M31, M61,
  BN254_Fp, BLS12_381_Fp) for `log_n = 2` aborts inside `zig-field`, not here.
- No radix-4/8 path and no Bluestein fallback: lengths must be powers of two.
- `precomputeTwiddles` allocates `log_n` slices (one per stage), so it is not
  optimal for a single one-shot transform; use `ntt` for that.
- The inverse path recomputes the root inverse as `root.inv()` and, for the
  twiddled variant, derives each twiddle as `-twiddles[half_m - j]` (with
  `j == 0` special-cased to `F.one()`). This is correct but means the two
  inverses are not symmetric in cost.
- Not constant-time: the loops are fixed-trip, but `inv()` is not.

## Design Notes

- Butterfly is the classic Cooley–Tukey radix-2 step:
  `u = a[k+j]`, `t = w·a[k+j+half]`, then `a[k+j] = u + t`,
  `a[k+j+half] = u − t`, with `w` advancing by `wm` within each block.
- Bit-reversal is applied first, in place, swapping only `j > i` so the
  permutation is its own inverse and stable.
- Stage `s` (1-based, `s = 1 .. log_n`) uses `m = 2^s`, `half_m = m/2`, and
  `wm = root^(2^(log_n - s))`.
- `intt` runs `ntt` with `root.inv()` and then scales by `n⁻¹ = F.fromInt(n).inv()`.
- The twiddled variants skip the per-block `w = w·wm` update, so they are the
  path to use when transforming many polynomials of the same length.

## Running Tests

```bash
cd libs/ntt && zig build test
```

15 tests: bit-reversal involution, bit-reversal for `n = 4`, `ntt`/`intt`
round-trips for M31, BabyBear, Goldilocks, BN254_Fp and BLS12_381_Fp, the
twiddled round trip, cyclic convolution via the transform, twiddle
precomputation/free with per-entry verification, and `nttWithTwiddles` matching
`ntt` bit-for-bit. The field round-trips are capped at
`min(two_adicity + 1, 5)`, so BN254_Fp and BLS12_381_Fp only exercise
`log_n <= 1`.

## License

MIT OR Apache-2.0
