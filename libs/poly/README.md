# zig-poly

Dense univariate polynomials over finite fields. Allocation-free polynomial arithmetic with comptime-known maximum degree using stack storage.

## Features

- **Generic `Polynomial(F, max_degree)` type** — stack-allocated coefficients
- **Arithmetic** — addition, subtraction, multiplication, division with remainder
- **Evaluation** — Horner's method, multi-point evaluation
- **Interpolation** — Lagrange interpolation from points
- **Derivative and composition** — formal derivative, polynomial composition
- **Vanishing polynomial** — `Z_H(x) = x^n - 1` for cosets
- **Polynomial evaluation at scalar points** — for secret sharing, VSS
- **Lagrange coefficient computation** — for interpolation and threshold schemes

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_poly = .{
        .path = "path/to/zig-algebra-core/zig-poly",
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
const zp = @import("zig-poly");
const F = @import("zig-field").BN254_Fp;

// Create polynomials
const p1 = zp.Polynomial(F, 4).init(&[_]F{
    F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4),
});
const p2 = zp.Polynomial(F, 4).init(&[_]F{
    F.fromInt(5), F.fromInt(6), F.fromInt(7), F.fromInt(8),
});

// Arithmetic
const sum = p1.add(p2);
const prod = p1.mul(p2);

// Evaluation (Horner's method)
const y = p1.eval(F.fromInt(10));

// Lagrange interpolation
const points = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3) };
const values = [_]F{ F.fromInt(10), F.fromInt(20), F.fromInt(30) };
const interpolated = zp.lagrangeInterpolate(F, &points, &values);

// Vanishing polynomial
const z_h = zp.vanishingPolynomial(F, 8); // x^8 - 1
```

## API

| Function | Description |
|----------|-------------|
| `Polynomial(F, N).init(coeffs)` | Create polynomial from coefficients |
| `p1.add(p2)` | Polynomial addition |
| `p1.sub(p2)` | Polynomial subtraction |
| `p1.mul(p2)` | Polynomial multiplication |
| `p1.div(p2)` | Polynomial division with remainder |
| `p1.eval(x)` | Evaluate at point x |
| `p1.derivative()` | Formal derivative |
| `p1.compose(q)` | Polynomial composition p(q(x)) |
| `lagrangeInterpolate(F, xs, ys)` | Lagrange interpolation |
| `vanishingPolynomial(F, n)` | x^n - 1 |

## Running Tests

```bash
zig build test
```

## Design Notes

- Coefficients are stored in increasing degree order: `coeffs[i]` is the coefficient of `x^i`
- Maximum degree is comptime-known for stack allocation
- Multiplication uses naive O(n^2) — can be extended with Karatsuba or FFT for large polynomials
- Used by zig-commitment (IPA), zig-stark (constraint polynomials), and secret sharing (polynomial evaluation)

## License

MIT OR Apache-2.0
