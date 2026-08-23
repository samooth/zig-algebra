# zig-linalg

Linear algebra over finite fields for Zig. Vectors, matrices, LU decomposition, and linear system solving — all allocation-free with compile-time dimension checking.

## Features

- **Vector** — fixed-size vectors over any field: add, sub, neg, scale, dot, norm²
- **Matrix** — rectangular matrices: add, sub, scale, multiply (matrix×matrix and matrix×vector), transpose, trace
- **Determinant** — Gaussian elimination for n×n (n≥3), closed-form for 1×1 and 2×2
- **LU decomposition** — partial pivoting; returns L, U, P satisfying P·A = L·U
- **Linear solving** — solve A·x = b via LU decomposition; returns `null` for singular systems

## Quick Start

```zig
const linalg = @import("zig-linalg");
const zf = @import("zig-field");
const F = zf.Goldilocks;

const M3 = linalg.Matrix(F, 3, 3);
const V3 = linalg.Vector(F, 3);

var A = M3.fromArray(.{
    .{ F.fromInt(2), F.fromInt(1), F.fromInt(1) },
    .{ F.fromInt(1), F.fromInt(3), F.fromInt(2) },
    .{ F.fromInt(1), F.fromInt(0), F.fromInt(4) },
});
const b = V3.fromArray(.{
    F.fromInt(4), F.fromInt(5), F.fromInt(6),
});

// Solve A·x = b
const x = A.solve(b) orelse return error.Singular;

// Verify: A·x == b
try std.testing.expect(A.mulVec(x).eql(b));
```

## API

| Type | Operations |
|------|-----------|
| `Vector(F, n)` | `add`, `sub`, `neg`, `scale`, `dot`, `norm2`, `eql`, `get`, `set` |
| `Matrix(F, rows, cols)` | `add`, `sub`, `scale`, `mul(n, other)`, `mulVec`, `transpose`, `trace`, `determinant`, `eql`, `identity`, `row`, `col`, `get`, `set` |
| `Matrix.solve(b)` | Returns `?Vector` — `null` if singular |

## Running Tests

```bash
cd libs/linalg && zig build test
```

## Design Notes

- All operations are stack-only; no heap allocations.
- Matrix dimensions are comptime parameters: `Matrix(F, 3, 3)` is a distinct type from `Matrix(F, 3, 4)`.
- `mul` takes the output column count as a comptime argument: `A.mul(3, B)` for a 3-column B.
- Determinant uses Gaussian elimination for n ≥ 3 (O(n³)); 2×2 uses the closed form.

## License

MIT OR Apache-2.0
