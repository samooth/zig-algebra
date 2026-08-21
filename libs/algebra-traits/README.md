# zig-algebra-traits

Type contracts (traits) for computational algebra in Zig. The foundation of the zig-algebra-core ecosystem.

## Features

- **18 traits** defining algebraic structures: `SetTrait`, `GroupTrait`, `AdditiveGroupTrait`, `MultiplicativeGroupTrait`, `RingTrait`, `FieldTrait`, `PrimeFieldTrait`, `FieldExtensionTrait`, `VectorSpaceTrait`, `PolynomialRingTrait`, `EllipticCurveTrait`, `PairingFriendlyTrait`, `CommitmentSchemeTrait`, `NttTrait`, `HashToFieldTrait`, `HashToCurveTrait`, `MerkleTreeTrait`, `TranscriptTrait`, `FieldRngTrait`
- **Generic algorithms**: `pow`, `sum`, `product`, `egcd`, `dotProduct`, `evalPolyHorner`, `lagrangeInterpolate`
- **Zero dependencies** — the root of the dependency tree
- **Zero-cost** — comptime trait checks, no runtime overhead

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_algebra_traits = .{
        .path = "path/to/zig-algebra-core/zig-algebra-traits",
    },
},
```

Then in your `build.zig`:

```zig
const traits = b.dependency("zig_algebra_traits", .{});
exe.root_module.addImport("zig-algebra-traits", traits.module("zig-algebra-traits"));
```

## Quick Start

```zig
const zat = @import("zig-algebra-traits");

// Use traits to write generic algorithms
fn doubleGroup(comptime G: type) fn (G) G {
    return struct {
        fn f(x: G) G {
            return x.add(x);
        }
    }.f;
}

// Use generic algorithms
const result = zat.pow(someField, base, exponent);
```

## API

### Traits

| Trait | Purpose |
|-------|---------|
| `SetTrait(T)` | Basic set operations (equality, hashing) |
| `GroupTrait(T)` | Group with identity and inverse |
| `AdditiveGroupTrait(T)` | Additive group (add, zero, neg) |
| `MultiplicativeGroupTrait(T)` | Multiplicative group (mul, one, inv) |
| `RingTrait(T)` | Ring (add + mul) |
| `FieldTrait(T)` | Field (ring + division) |
| `PrimeFieldTrait(T)` | Prime field with order, Legendre, sqrt |
| `EllipticCurveTrait(T)` | Weierstrass curve operations |
| `VectorSpaceTrait(T)` | Vector space over a field |

### Algorithms

```zig
// Exponentiation by squaring
const result = zat.pow(field, base, exponent);

// Sum and product of arrays
const s = zat.sum(field, &elements);
const p = zat.product(field, &elements);

// Extended GCD
const egcd = zat.egcd(a, b);

// Polynomial evaluation (Horner's method)
const y = zat.evalPolyHorner(coeffs, x);

// Lagrange interpolation
const poly = zat.lagrangeInterpolate(field, points, values);
```

## Running Tests

```bash
zig build test
```

## Design Notes

- Traits are defined as comptime structs with `has_*` compile-time booleans
- Generic algorithms use comptime parameters for field/curve types
- No allocations, no external dependencies

## License

MIT OR Apache-2.0
