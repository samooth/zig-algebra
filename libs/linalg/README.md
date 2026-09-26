# zig-linalg

Linear algebra over finite fields: fixed-size vectors, rectangular matrices, LU
decomposition with partial pivoting, and linear system solving. All types are
comptime-parameterised, so every operation is stack-only and heap-free.

## Features

- **`Vector(F, n)`** — `add`, `sub`, `neg`, `scale`, `dot`, `norm2`, `eql`, `get`, `set`, `zero`, `fromArray`
- **`Matrix(F, rows, cols)`** — `add`, `sub`, `scale`, `mul`, `mulVec`,
  `transpose`, `trace`, `determinant`, `eql`, `zero`, `identity`, `fromArray`,
  `row`, `col`, `get`, `set`, `setRow`, `setCol`
- **Determinant** — closed form for 1×1 and 2×2, Gaussian elimination for n ≥ 3
- **LU decomposition** — partial pivoting by lexicographic order; returns
  `{ L, U, P }` with `P·A = L·U`
- **Linear solving** — `solve(b)` returns `?Vector(F, rows)`; `null` when the
  system is singular
- **Compile-time dimension checking** — `Matrix(F, 3, 3)` and `Matrix(F, 3, 4)`
  are distinct types; `mul` takes the output column count as a comptime argument
- **No allocations** — every value lives on the stack

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_linalg = .{
        .path = "path/to/zig-algebra/libs/linalg",
    },
},
```

Then in your `build.zig`:

```zig
const zl = b.dependency("zig_linalg", .{});
exe.root_module.addImport("zig-linalg", zl.module("zig-linalg"));
```

## Quick Start

```zig
const std = @import("std");
const linalg = @import("zig-linalg");
const F = @import("zig-field").Goldilocks;

pub fn main() !void {
    const M3 = linalg.Matrix(F, 3, 3);
    const V3 = linalg.Vector(F, 3);

    const A = M3.fromArray(.{
        .{ F.fromInt(2), F.fromInt(1), F.fromInt(1) },
        .{ F.fromInt(1), F.fromInt(3), F.fromInt(2) },
        .{ F.fromInt(1), F.fromInt(0), F.fromInt(4) },
    });
    const b = V3.fromArray(.{
        F.fromInt(4), F.fromInt(5), F.fromInt(6),
    });

    // Solve A·x = b. `null` means singular.
    const x = A.solve(b) orelse return error.Singular;

    // Verify: A·x == b
    std.debug.assert(A.mulVec(x).eql(b));

    // LU decomposition: P·A == L·U
    const lu = A.lu();
    std.debug.assert(lu.P.mul(3, A).eql(lu.L.mul(3, lu.U)));

    std.debug.print("x = {}, A*x = {}\n", .{ x, A.mulVec(x) });
}
```

`Vector` and `Matrix` both declare a `format` method that would print them as
`[a, b, c]`, but its signature is stale on Zig 0.16 (see Known limitations), so
`{}` in practice falls back to the default struct form. Use `data` when you want
a specific rendering.

## API

### `Vector(F, n)`

| Method | Signature | Notes |
|--------|-----------|-------|
| `zero` | `() Self` | all-zero vector |
| `fromArray` | `(arr: [n]F) Self` | |
| `get` / `set` | `(self: Self, i: usize) F` / `(self: *Self, i: usize, v: F) void` | |
| `add` / `sub` / `neg` | `(self: Self, other: Self) Self` | |
| `scale` | `(self: Self, scalar: F) Self` | scalar is the **second** argument |
| `dot` | `(self: Self, other: Self) F` | |
| `norm2` | `(self: Self) F` | `self.dot(self)` |
| `eql` | `(self: Self, other: Self) bool` | |
| field | `data: [n]F` | public, so `v.data[i]` also works |

### `Matrix(F, rows, cols)`

| Method | Signature | Notes |
|--------|-----------|-------|
| `zero` | `() Self` | |
| `identity` | `() error{NotSquare}!Self` | `error.NotSquare` when `rows != cols` |
| `fromArray` | `(arr: [rows][cols]F) Self` | |
| `get` / `set` | `(self, r, c)` / `(self: *Self, r, c, v)` | |
| `row` / `col` | `(self: Self, r: usize) Vector(F, cols)` / `(self: Self, c: usize) Vector(F, rows)` | |
| `setRow` / `setCol` | `(self: *Self, r: usize, vec)` / `(self: *Self, c: usize, vec)` | requires `*Self` |
| `add` / `sub` / `scale` | `(self: Self, other: Self) Self` / `(self: Self, scalar: F) Self` | |
| `transpose` | `(self: Self) Matrix(F, cols, rows)` | |
| `mul` | `(self: Self, comptime OtherCols: usize, other: Matrix(F, cols, OtherCols)) Matrix(F, rows, OtherCols)` | |
| `mulVec` | `(self: Self, vec: Vector(F, cols)) Vector(F, rows)` | |
| `trace` | `(self: Self) error{NotSquare}!F` | `error.NotSquare` when not square |
| `determinant` | `(self: Self) error{NotSquare}!F` | `error.NotSquare` when not square; `F.zero()` if singular |
| `lu` | `(self: Self) error{NotSquare}!LU(F, rows)` | `error.NotSquare` when not square |
| `solve` | `(self: Self, b: Vector(F, rows)) error{NotSquare}!?Vector(F, rows)` | `error.NotSquare` when not square; `null` if singular |
| `eql` | `(self: Self, other: Self) bool` | |
| field | `data: [rows][cols]F` | public |

### `LU(F, n)`

```zig
pub fn LU(comptime F: type, comptime n: usize) type {
    return struct { L: Matrix(F, n, n), U: Matrix(F, n, n), P: Matrix(F, n, n) };
};
```

`L` is lower triangular with a unit diagonal, `U` is upper triangular, and `P`
is a row permutation, with `P·A = L·U`.

## Field requirements

Every entry point begins with `zig-algebra-traits`' `assertField(F)`, so `F`
needs `zero`, `one`, `add`, `sub`, `neg`, `mul`, `div`, `inv`, `pow`, `isZero`
and `eql`.

`lu` and therefore `solve` additionally require:

- **`F.lexicographicCmp(a, b) i8`** — partial pivoting compares candidates in
  the field's canonical (lexicographic) order, because a finite field has no
  magnitude. Every predefined field in `zig-field` provides it. A hand-rolled
  field without it compiles for `add`/`mul`/`determinant` but fails inside `lu`.
- `F` must be a field in which the system is actually solvable; the algorithm
  is plain forward/back substitution with no pivoting rescue, so it assumes
  `U`'s diagonal is non-zero. A zero pivot returns `null` from `solve`, which
  also covers the singular case.

## Known limitations

- `determinant`, `trace`, `identity`, `lu` and `solve` return
  `error.NotSquare` when `rows != cols`. Before 0.2.0 they debug-asserted
  `rows == cols`, which vanishes in ReleaseFast and let a non-square matrix
  read or write out of bounds.
- `lu` does **not** report singularity: if a column has no non-zero pivot it
  `continue`s, leaving the corresponding `U` diagonal at zero. `solve` then
  detects it and returns `null`, but a direct `lu()` call gives you a
  `P, L, U` triple that does not satisfy `P·A = L·U`. Check the diagonal
  yourself if you call `lu` directly.
- `solve` and `lu` are `O(n³)` with no blocking or Strassen; there is no
  sparse, rectangular, or banded variant.
- `mul` requires the output column count as a **comptime** argument. That is
  what makes the shapes checkable, but it means dynamic `n` is impossible; you
  must monomorphise per shape.
- The `Vector`/`Matrix` `format` methods use the Zig 0.16 signature, so they
  are only selected by the `{f}` specifier: `std.debug.print("{f}", .{v})`
  yields `[a, b, c]`, while `{}` still falls back to the default struct form.
  (The same 0.16 rule applies to `zig-bigint`'s `BigInt.format` and
  `zig-field`'s field `format`.)
- `std.debug.assert(a.len == b.len)`-style shape checks are Debug-only, and
  there is no bounds-checked indexing; out-of-range `row`/`col`/`get` is
  undefined in ReleaseFast.
- Nothing is constant-time; the pivoting and elimination loops branch on value
  comparisons.

## Design Notes

- Butterfly-free, branch-light kernels: every operation is a plain nested loop
  over `F`, which lets LLVM auto-vectorise.
- `scale` takes the scalar **second** (`v.scale(s)`), matching the convention
  used by `zig-field`'s `mulBy*` helpers. Note that
  `zig-algebra-traits`' `dotProduct` calls `V.scale(vector, vector)`, which does
  not match — use `Vector.dot` instead of `dotProduct`.
- `norm2` is `dot(self)`, not a square root; it returns an `F`, not a length.
- `determinant` negates the accumulator on every row swap, so the sign of the
  permutation is tracked correctly.
- Storage is row-major `[rows][cols]F`, public as `data`, so manual loops and
  `std.mem` operations work directly.

## Running Tests

```bash
cd libs/linalg && zig build test
```

11 tests: vector basics, matrix basics, `identity`, matrix-vector multiply, LU +
solve, 3×3 operations including a computed inverse, singular detection,
partial pivoting on a matrix needing a row swap, a Goldilocks multiply, the
`error.NotSquare` rejections for non-square shapes, and the total-vs-checked
`inv`/`div` contract of the in-file `F7`.
The suite uses an in-file `F7` (which includes `lexicographicCmp`) plus
`Goldilocks` from `zig-field`.

## License

MIT OR Apache-2.0
