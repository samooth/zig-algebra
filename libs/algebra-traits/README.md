# zig-algebra-traits

Compile-time type contracts (traits) for computational algebra in Zig. The root
of the zig-algebra dependency tree: **zero dependencies, zero runtime cost**.
Traits exist only to turn a cryptic "missing declaration" error deep inside
generic code into a clear `@compileError` at the point of use.

## Features

- **19 trait constructors** re-exported at the root (20 defined in
  `traits.zig`; `GroupTraitWithId` is only reachable through `traits.GroupTraitWithId`):

  `SetTrait`, `GroupTrait`, `AdditiveGroupTrait`, `MultiplicativeGroupTrait`,
  `RingTrait`, `FieldTrait`, `PrimeFieldTrait`, `FieldExtensionTrait`,
  `VectorSpaceTrait`, `PolynomialRingTrait`, `EllipticCurveTrait`,
  `PairingFriendlyTrait`, `CommitmentSchemeTrait`, `NttTrait`,
  `HashToFieldTrait`, `HashToCurveTrait`, `MerkleTreeTrait`, `TranscriptTrait`,
  `FieldRngTrait`

- **5 assertion helpers** — `assertField`, `assertRing`, `assertGroup`,
  `assertEllipticCurve`, `assertPairingFriendly`
- **7 generic algorithms** — `pow`, `sum`, `product`, `egcd`, `dotProduct`,
  `evalPolyHorner`, `lagrangeInterpolate` (plus
  `traits.lagrangeCoefficient`, not re-exported at the root)
- **Every trait type argument is `comptime`** — including the base field/ring
  type for the higher-order traits

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_algebra_traits = .{
        .path = "path/to/zig-algebra/libs/algebra-traits",
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
const std = @import("std");
const zat = @import("zig-algebra-traits");

// A minimal prime field that satisfies the Field trait.
const F7 = struct {
    const Self = @This();
    value: u64,
    pub const modulus: u64 = 7;
    pub const characteristic: u64 = 7;
    pub const order: u64 = 7;

    pub fn zero() Self { return .{ .value = 0 }; }
    pub fn one() Self { return .{ .value = 1 }; }
    pub fn fromInt(x: u256) Self { return .{ .value = @intCast(x % modulus) }; }
    pub fn toInt(self: Self) u64 { return self.value; }
    pub fn eql(a: Self, b: Self) bool { return a.value == b.value; }
    pub fn add(a: Self, b: Self) Self { return fromInt(a.value + b.value); }
    pub fn sub(a: Self, b: Self) Self { return fromInt(a.value + (modulus - b.value % modulus)); }
    pub fn neg(a: Self) Self { return if (a.value == 0) zero() else fromInt(modulus - a.value); }
    pub fn mul(a: Self, b: Self) Self { return fromInt(a.value * b.value); }
    pub fn inv(a: Self) Self { return pow(a, modulus - 2); }
    pub fn div(a: Self, b: Self) Self { return mul(a, inv(b)); }
    pub fn pow(base: Self, exp: u256) Self {
        var r = one();
        var b = base;
        var e = exp;
        while (e > 0) : (e >>= 1) {
            if (e & 1 == 1) r = mul(r, b);
            b = mul(b, b);
        }
        return r;
    }
    pub fn isZero(self: Self) bool { return self.value == 0; }
    // GroupTraitWithId also wants these two
    pub fn identity() Self { return one(); }
    pub fn inverse(a: Self) Self { return inv(a); }
    pub fn random() Self { return fromInt(1); }
};

pub fn main() !void {
    // Compile-time contract check: no output, no runtime cost.
    zat.assertField(F7);
    zat.assertRing(F7);
    zat.assertGroup(F7);

    // Traits are also usable as values, which is how you read the flags.
    _ = comptime zat.SetTrait(F7).assert();
    _ = comptime zat.PrimeFieldTrait(F7).assert();
    // GroupTrait takes the operation name as a second comptime argument.
    _ = comptime zat.GroupTrait(F7, "add").assert();
    // GroupTraitWithId is not re-exported at the root.
    _ = comptime zat.traits.GroupTraitWithId(F7, "add", "zero").assert();
    std.debug.print("F7 has eql={} neg={} inv={} div={} pow={} isZero={} order={}\n", .{
        zat.SetTrait(F7).has_eq,
        zat.AdditiveGroupTrait(F7).has_neg,
        zat.FieldTrait(F7).has_inv,
        zat.FieldTrait(F7).has_div,
        zat.FieldTrait(F7).has_pow,
        zat.FieldTrait(F7).has_isZero,
        zat.PrimeFieldTrait(F7).has_modulus,
    });
}
```

## API

### Traits

All trait arguments are `comptime type`. `(F)` in the "Args" column is a
required second type argument; traits marked *(optional flag)* only
`@hasDecl`-check it.

| Trait | Args | Purpose | `assert()` requires |
|-------|------|---------|----------------------|
| `SetTrait` | `(T)` | equality | `eql` |
| `GroupTrait` | `(T, op_name: []const u8)` | named binary op + identity + inverse | `op_name`, `identity`, `inverse`, `eql` |
| `GroupTraitWithId`¹ | `(T, op_name, id_name)` | as above, custom identity name | `op_name`, `id_name`, `inverse`, `eql` |
| `AdditiveGroupTrait` | `(T)` | `add`/`zero`/`neg` | `add`, `zero`, `neg`, `eql` |
| `MultiplicativeGroupTrait` | `(T)` | `mul`/`one`/`inv` | `mul`, `one`, `inv`, `eql` |
| `RingTrait` | `(T)` | ring | additive group + `mul`, `one`, `sub` |
| `FieldTrait` | `(T)` | field | ring + `inv`, `div`, `pow`, `isZero` |
| `PrimeFieldTrait` | `(T)` | F_p | field + `modulus`, `fromInt` |
| `FieldExtensionTrait` | `(T)` | F_{p^k} | field + `BaseField`, `extension_degree` |
| `VectorSpaceTrait` | `(V, F)` | V over F | field + `add`, `neg`, `zero`, `scale`, `eql` |
| `PolynomialRingTrait` | `(P, R)` | R[x] | ring + `add`, `mul`, `eval`, `degree`, `coeff`, `eql` |
| `EllipticCurveTrait` | `(E, F)` | Weierstrass curve | field + `add`, `double`, `neg`, `scalarMul`, `generator`, `identity`, `isOnCurve`, `eql` |
| `PairingFriendlyTrait` | `(E, F)` | e: G1×G2→GT | curve + `G1`, `G2`, `GT`, `pairing` |
| `CommitmentSchemeTrait` | `(C, F)` | commit/open/verify | field + `commit`, `open`, `verify` |
| `NttTrait` | `(N, F)` | transform/inverse | field + `transform`, `inverse` |
| `HashToFieldTrait` | `(H, F)` | hash into F | field + `hashToField` |
| `HashToCurveTrait` | `(H, E, F)` | hash into E | curve + `hashToCurve` |
| `MerkleTreeTrait` | `(M)` | build/root/prove/verify | `build`, `root`, `prove`, `verify` |
| `TranscriptTrait` | `(T, F)` | absorb/squeeze | field + `absorb`, `squeeze` |
| `FieldRngTrait` | `(R, F)` | random field elements | field + `randomField` |

¹ `GroupTraitWithId` is defined in `traits.zig` but is **not** re-exported from
the crate root; reach it as `traits.traits.GroupTraitWithId`.

Optional flags exposed on every trait struct: `EllipticCurveTrait` →
`has_toAffine`, `has_fromAffine`, `has_order`, `has_cofactor`,
`has_subgroupCheck`, `has_isIdentity`; `CommitmentSchemeTrait` →
`has_batchVerify`; `NttTrait` → `has_primitiveRoot`, `has_bitReverse`;
`PrimeFieldTrait` → `has_toInt`; `HashToFieldTrait` → `has_hashToScalar`;
`MerkleTreeTrait` → `has_update`; `TranscriptTrait` → `has_absorbPoint`,
`has_clone`; `FieldRngTrait` → `has_randomScalar`, `has_rejectionSample`;
`FieldExtensionTrait` → `has_frobenius`; `VectorSpaceTrait` → `has_dim`;
`PolynomialRingTrait` → `has_fromCoeffs`.

### Assertion helpers

```zig
zat.assertField(T);                          // FieldTrait(T).assert()
zat.assertRing(T);                           // RingTrait(T).assert()
zat.assertGroup(T);                          // AdditiveGroupTrait(T).assert()
zat.assertEllipticCurve(E, F);               // EllipticCurveTrait(E, F).assert()
zat.assertPairingFriendly(E, F);             // PairingFriendlyTrait(E, F).assert()
```

### Generic algorithms

```zig
// Exponentiation by squaring. Delegates to T.pow when it exists.
const r = zat.pow(F7, F7.fromInt(3), 100);          // T, base, exp: u256

// Sum / product over a slice. Both assert the group traits.
const items = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
const s = zat.sum(F7, &items);                      // 6
const p = zat.product(F7, &items);                  // 6

// Horner's method. coeffs[i] is the coefficient of x^i.
const coeffs = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
const y = zat.evalPolyHorner(F7, &coeffs, F7.fromInt(2)); // 1 + 4 + 12 = 17 = 3

// Lagrange interpolation. Allocates; caller frees.
var gpa = std.heap.DebugAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();
const xs = [_]F7{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(2) };
const ys = [_]F7{ F7.fromInt(1), F7.fromInt(3), F7.fromInt(5) };
const poly = try zat.lagrangeInterpolate(F7, &xs, &ys, allocator);
defer allocator.free(poly);                         // 1 + 2x

// Single Lagrange basis coefficient (FROST / Shamir style shares).
const lam = zat.traits.lagrangeCoefficient(F7, &xs, 0, F7.fromInt(5));

// Extended GCD. Returns .{ .gcd, .x, .y }.
const ring = /* a RingTrait type that also has div/mod/isNegative/neg */;
const eg = zat.egcd(ring, ring.one(), ring.one());
```

## Known limitations

- **`dotProduct` is unusable.** Its body is `V.scale(ai, bi)` where both
  arguments are `V`, so it only type-checks if `V.scale` itself takes two vector
  arguments (a Hadamard product). It does not compile for a real vector space
  with a `scale(scalar, vector)` or `scale(vector, scalar)` signature. Do not
  use it; `zig-linalg`'s `Vector.dot` is the working replacement.
- **`egcd` needs more than `RingTrait`.** It calls `T.isZero`, `T.div`,
  `T.isNegative` and `T.neg` on top of the ring operations, and none of those
  are checked by `RingTrait(T).assert()`. A type can pass the assertion and then
  fail to compile inside `egcd`.
- `VectorSpaceTrait.assert()` only checks that `scale` *exists*, not its
  argument order, so it cannot catch the mismatch described above.
- `lagrangeInterpolate` assumes the `xs` are pairwise distinct; a duplicate
  makes `F.inv(denom)` divide by zero. It is not checked.
- `VectorSpaceTrait` declares `dimension` as part of the contract in its
  documentation but does not check it; only `has_dim` is exposed.
- Several traits (e.g. `NttTrait`) are contracts over types that no library in
  this workspace actually implements under those exact names — they exist for
  downstream generic code, not for the bundled libraries.

## Design Notes

- Every trait is a comptime struct with `has_*` boolean constants and an
  `assert()` that emits `@compileError` with the offending `@typeName`.
- Trait hierarchy: `Set` → `Group` → `Ring` → `Field` → {`PrimeField`,
  `FieldExtension`}; `VectorSpace` is parameterized by a `Field`; `EllipticCurve`
  is parameterized by a `Field`; `PairingFriendly` extends `EllipticCurve`.
- The higher-order traits assert their base type's trait too, so
  `VectorSpaceTrait(V, F).assert()` transitively validates `F`.
- No allocations, no external dependencies, no runtime checks.

## Running Tests

```bash
cd libs/algebra-traits && zig build test
```

`src/traits.zig` currently contains no `test` blocks, so this step only
type-checks the module (the root `zig build test` reports 0 tests for
`zig-algebra-traits`). `zig build` installs `src/main.zig` as the
`traits-example` executable, which is the runnable version of the Quick Start.

## License

MIT OR Apache-2.0
