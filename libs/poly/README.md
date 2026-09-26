# zig-poly

Dense univariate polynomials over finite fields. Allocation-free polynomial arithmetic with a comptime-known maximum degree using stack storage.

## Features

- **Generic `Polynomial(F, max_degree)` type** — stack-allocated coefficient array
- **Arithmetic** — addition, subtraction, negation, scaling, multiplication, division with remainder
- **Evaluation** — Horner's method
- **Interpolation** — Lagrange interpolation from points
- **Vanishing polynomial** — `Z_H(x) = ∏ (x - x_i)` over an explicit point set
- **Composition and integer powers** — `compose`, `pow`
- **Vector helpers** — `inner`, `powers`, `vecAdd`, `vecSub`, `vecScale`, `hadamard`, `vecSum`, `vecEql`

> `max_degree` is a **compile-time bound on the result of every operation**,
> not just storage. `mul`, `divRem` and `pow` debug-assert that the result
> fits, so pick a value that covers the largest intermediate you need (two
> degree-`d` polynomials multiply to degree `2d`).

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_poly = .{
        .path = "../zig-algebra/libs/poly",
    },
},
```

Then in your `build.zig`:

```zig
const zp = b.dependency("zig_poly", .{});
exe.root_module.addImport("zig-poly", zp.module("zig-poly"));
```

## Quick Start

```zig
const std = @import("std");
const zp = @import("zig-poly");
const F = @import("zig-field").BN254_Fp;

// 9 coefficient slots (degrees 0..8)
const P = zp.Polynomial(F, 8);

// There is no `init`. Use `fromArray` with a comptime literal, or
// `fromCoeffs` with a runtime slice.
const p1 = P.fromArray(&.{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4) });
const runtime_coeffs = [_]F{ F.fromInt(5), F.fromInt(6) };
const p2 = P.fromCoeffs(&runtime_coeffs);

// Arithmetic
const sum = p1.add(p1);
const prod = p1.mul(p1); // degree 3 * degree 3 = degree 6, fits in P
std.debug.assert(prod.degree == 6);
_ = p1.sub(p1);
_ = p1.neg();
_ = p1.scale(F.fromInt(3));

// Evaluation (Horner's method)
const y = p1.eval(F.fromInt(10));
_ = y;

// Lagrange interpolation. `max_degree` must be >= points.len - 1.
const points = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3) };
const values = [_]F{ F.fromInt(10), F.fromInt(20), F.fromInt(30) };
const interpolated = zp.lagrangeInterpolate(F, 4, &points, &values);
std.debug.assert(interpolated.eval(points[0]).eql(values[0]));
std.debug.assert(interpolated.eval(points[2]).eql(values[2]));

// Vanishing polynomial over a point set: Z(x) = ∏ (x - xs[i]),
// so it vanishes on every point and nowhere else.
const z_h = zp.vanishingPolynomial(F, 8, &points);
for (points) |pt| {
    std.debug.assert(z_h.eval(pt).isZero());
}

// Division with remainder: p1 == q * d + r
const qr = p1.divRem(p1);
std.debug.assert(p1.eql(qr.q.mul(p1).add(qr.r)));

// Composition and integer powers.
// `compose` computes self(other(x)); see the caveat in the API table.
const x2 = P.x().mul(P.x());
const substituted = p1.compose(x2); // p1(x^2) = c0 + c1x^2 + c2x^4 + c3x^6
std.debug.assert(substituted.degree == 6);
_ = p1.mul(P.x()); // p1(x) * x
_ = P.x().pow(3); // x^3
_ = P.constant(F.fromInt(7));
_ = P.zero();
std.debug.assert(P.MAX_DEGREE == 8);
```

### Vector helpers

Every allocating vector helper takes a comptime element type and an
allocator, and returns a slice the caller owns.

```zig
const zp = @import("zig-poly");
const F = @import("zig-field").BN254_Fp;

const a = [_]F{ F.fromInt(1), F.fromInt(2) };
const b = [_]F{ F.fromInt(3), F.fromInt(4) };

_ = zp.inner(F, &a, &b); // dot product, no allocation

const pw = try zp.powers(F, allocator, F.fromInt(2), 3);
defer allocator.free(pw);
const vadd = try zp.vecAdd(F, allocator, &a, &b);
defer allocator.free(vadd);
const vsub = try zp.vecSub(F, allocator, &a, &b);
defer allocator.free(vsub);
const scaled = try zp.vecScale(F, allocator, F.fromInt(2), &a);
defer allocator.free(scaled);
const hd = try zp.hadamard(F, allocator, &a, &b);
defer allocator.free(hd);
_ = zp.vecSum(F, &a); // no allocation
_ = zp.vecEql(F, &a, &b); // no allocation
```

## API

| Function | Description |
|----------|-------------|
| `Polynomial(F, max_degree).zero()` | Zero polynomial (`degree == -1`) |
| `Polynomial(F, max_degree).constant(c)` | Constant polynomial |
| `Polynomial(F, max_degree).x()` | The identity polynomial |
| `Polynomial(F, max_degree).fromArray(comptime src)` | Build from a comptime array literal |
| `Polynomial(F, max_degree).fromCoeffs(src)` | Build from a runtime slice |
| `p.normalize()` | Strip leading zero coefficients, update `degree` |
| `p.isZero()` / `p.isConstant()` | Predicates |
| `p.leadingCoeff()` | Highest non-zero coefficient |
| `p.eql(q)` | Polynomial equality |
| `p.add(q)` / `p.sub(q)` / `p.neg()` | Additive operations |
| `p.scale(s)` | Multiply every coefficient by `s` |
| `p.mul(q)` | Naive O(n²) multiplication |
| `p.eval(x)` | Horner evaluation |
| `p.divRem(d)` | Division returning `{ q, r }` |
| `p.div(d)` / `p.rem(d)` | Quotient / remainder only |
| `p.compose(q)` | Composition `self(q(x))` — **only correct when `q` is a monomial `x^k`** (see below) |
| `p.pow(n)` | Integer power by square-and-multiply |
| `lagrangeInterpolate(F, max_degree, xs, ys)` | Lagrange interpolation |
| `vanishingPolynomial(F, max_degree, xs)` | `∏ (x - xs[i])` |

`compose` accumulates `Σ c_i · q(x)^i` with a plain `add`, so it only lands in
the right degree slot when `q` is a monomial `x^k`. Verified: `p.compose(x)`
returns `p`, and `p.compose(x^2)` returns `c0 + c1x² + c2x⁴ + c3x⁶`. With a
general `q` (for example a constant) it silently returns a wrong polynomial —
`p.compose(2)` collapses to a constant instead of `p(2x)`. Do not use it with
a non-monomial `q` until the implementation is fixed.

**Known gaps** — declared but currently broken in `src/poly.zig`:

| Function | Problem |
|----------|---------|
| `p.derivative()` | `poly.zig:269` — `@intCast` with an unknown result type; does not compile |
| `p.toString(buf)` | `poly.zig:346` — returns `!usize` but `std.fmt.bufPrint` yields `![]u8`; does not compile |

## Running Tests

```bash
# From the monorepo root
zig build test

# Just this library (20 tests, all inline in src/root.zig)
cd libs/poly && zig build test
```

## Design Notes

- Coefficients are stored in increasing degree order: `coeffs[i]` is the
  coefficient of `x^i`, and `degree` is `-1` for the zero polynomial
- Maximum degree is comptime-known, so the coefficient array is a fixed
  `[max_degree + 1]F` on the stack and all polynomial operations are
  allocation-free
- `F` must satisfy `zig-algebra-traits`' `FieldTrait`
- Multiplication is naive O(n²) — can be extended with Karatsuba or FFT for
  large polynomials
- `zig-poly` is self-contained: nothing else in the workspace depends on it
  yet. It is a candidate for constraint polynomials, IPA/KZG helpers and
  secret sharing, but those consumers currently carry their own arithmetic

## License

MIT OR Apache-2.0
