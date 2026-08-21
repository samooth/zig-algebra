# zig-ntt

Number-Theoretic Transform over finite fields. The engine behind all STARK/SNARK polynomial operations.

## Features

- **Cooley-Tukey iterative NTT** — in-place, O(n log n), no allocations
- **INTT (inverse NTT)** — round-trips with forward NTT
- **Bit-reversal permutation** — built-in reordering
- **Twiddle precomputation** — cache roots of unity for repeated use
- **Generic over any field** — works with M31, BabyBear, BN254, BLS12-381, etc.
- **Power-of-two sizes** — standard radix-2 NTT

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_ntt = .{
        .path = "path/to/zig-algebra-core/zig-ntt",
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
const zntt = @import("zig-ntt");
const F = @import("zig-field").BabyBear;

// Forward NTT (evaluations → coefficients)
var data = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4) };
const log_n = 2;
const root = F.primitiveRootOfUnity(log_n);

zntt.ntt(F, &data, log_n, root);

// Inverse NTT (coefficients → evaluations)
zntt.intt(F, &data, log_n, root);
// data is now back to [1, 2, 3, 4] (with scaling)

// With precomputed twiddles (faster for repeated NTTs)
const twiddles = try zntt.precomputeTwiddles(F, log_n, root, allocator);
defer zntt.freeTwiddles(F, twiddles, allocator);

zntt.nttWithTwiddles(F, &data, log_n, twiddles);
```

## API

| Function | Description |
|----------|-------------|
| `ntt(F, data, log_n, root)` | In-place forward NTT |
| `intt(F, data, log_n, root)` | In-place inverse NTT |
| `bitReverse(data, log_n)` | Bit-reverse permutation |
| `precomputeTwiddles(F, log_n, root, alloc)` | Precompute twiddle factors |
| `freeTwiddles(F, twiddles, alloc)` | Free twiddle cache |
| `nttWithTwiddles(F, data, log_n, twiddles)` | NTT with cached twiddles |
| `inttWithTwiddles(F, data, log_n, twiddles)` | INTT with cached twiddles |

## Running Tests

```bash
zig build test
```

## Design Notes

- Uses the Cooley-Tukey butterfly: `a' = a + w*b`, `b' = a - w*b`
- Twiddle factors are `root^(bit_reverse(i))` for i = 0..n-1
- The INTT divides by n (multiply by n^{-1}) to invert the NTT
- Power-of-two roots of unity are required — use `F.primitiveRootOfUnity(log_n)` from zig-field
- The Vec8 SIMD NTT for M31 is in zig-field (SIMD-optimized for 8-lane vectors)

## License

MIT OR Apache-2.0
