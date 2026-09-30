# zig-bigint

Arbitrary-precision **signed** integer arithmetic for Zig. Allocation-free,
comptime-configurable precision backed by fixed-size `[N]u64` limb arrays, plus
the limb-array primitives that `zig-field` uses for its Montgomery constants.

## Features

- **Generic `BigInt(N)`** — precision chosen at comptime via the number of 64-bit limbs; sign + magnitude representation
- **Arithmetic** — `add`, `sub`, `mul`, `div`, `rem`, `mod`, `divRem`, `divRemU64`, `neg`, `abs`, `shl`, `shr`, `addU64`/`subU64`/`mulU64`
- **Bitwise** — `bitAnd`, `bitOr`, `bitXor` (two's complement internally)
- **Comparison / predicates** — `eql`, `cmp` (`i2`), `lt`/`gt`/`leq`/`geq`, `isZero`, `isOne`, `isNegative`, `bitLen`
- **Conversion** — `fromU64`, `fromI64`, `fromU128`, `fromString`, `toString`
- **Modular arithmetic** — `ExtendedGcd(N)` (`.egcd`, `.modInv`) and `ModExp(N)` (`.modExp`, `.modExpU64`)
- **Primality testing** — `PrimalityTest(N)` (`.trialDivision`, `.millerRabin`, `.isProbablyPrime`)
- **Limb-array helpers** — `intToLimbs`, `intToLimbsRuntime`, `limbsToInt`, `cmp`, `add`, `sub`, `shl`, `shr`, `mul`, `bitLength`, `numLimbs`
- **No heap allocation** in the hot path; only `toString`/`fromString` touch an allocator

### Semantics the tests pin

The signed contracts are not the ones every language picks, and the tests say
which is which — they are checked against CPython's `int`, not against this
implementation:

| operation | contract | example |
|---|---|---|
| `divRem` / `div` / `rem` | truncates toward zero (C), remainder takes the **dividend's** sign | `-7 / -3 == 2`, `-7 % -3 == -1` |
| `mod` | result in `[0, |m|)`; the sign of `m` is irrelevant | `(-7).mod(-3) == 2`, `7.mod(-3) == 1` |
| `shr` | **arithmetic** (floor) for negatives, as `bitXor` already is | `(-7).shr(7) == -1`, `(-1).shr(7) == -1` |
| `bitAnd`/`bitOr`/`bitXor` | two's complement over the whole integer | `(-1) ^ 255 == -256` |
| `fromString` | optional leading `-`; `toString` writes one, so the two round-trip | `fromString("-42")`, `fromString("-")` is `error.InvalidDigit` |
| `eql` / `cmp` | sign-aware: `-0` is `0` | `fromString("-0").eql(zero())` |

`mod` and `shr` both failed these contracts and were fixed: `mod` added a
negative `m` to a negative remainder (`(-7).mod(-3)` returned `-4`), and `shr`
truncated toward zero while documenting an arithmetic shift (`(-1).shr(7)`
returned `0`). The CPython differential is what found them — a test written
against this implementation would have passed both.

## Testing

The vectors in `src/root.zig` labelled *CPython* were generated with CPython 3
(`int` is arbitrary precision) for the contracts above, with magnitudes on the
64-bit limb boundaries (`2^63`, `2^64`, `2^128`, `2^192`, `2^256`) because a
carry bug lives exactly there. Reverting either fix turns the differential
red, which was observed before either fix was trusted.

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_bigint = .{
        .path = "path/to/zig-algebra/libs/bigint",
    },
},
```

Then in your `build.zig`:

```zig
const zbi = b.dependency("zig_bigint", .{});
exe.root_module.addImport("zig-bigint", zbi.module("zig-bigint"));
```

## Quick Start

```zig
const std = @import("std");
const zbi = @import("zig-bigint");

pub fn main() !void {
    // 256-bit precision = 4 limbs
    const Big = zbi.BigInt(4);

    // --- Construction ---
    const a = Big.fromU64(0xdeadbeef);          // infallible
    const b = try Big.fromU128(0xcafebabe);     // error union: can overflow!
    const neg = Big.fromI64(-42);

    // --- Arithmetic: every one of these can return error.Overflow ---
    const sum = try a.add(b);          // 3742... (a + b)
    const diff = try a.sub(b);         // signed
    const prod = try a.mul(b);         // 3736...
    const qr = try a.divRem(b);        // .{ .q, .r }
    const q = try a.div(b);
    const r = try a.rem(b);
    const shifted = try a.shl(64);     // 1 in limb 1
    const unshifted = shifted.shr(64); // back to a
    _ = .{ sum, diff, prod, qr, q, r, unshifted, neg };

    // --- Modular arithmetic (precisions must match) ---
    const m = Big.fromU64(1_000_000_007);
    const gcd = zbi.ExtendedGcd(4);
    const eg = gcd.egcd(Big.fromU64(240), Big.fromU64(46));
    // eg.g == 2, eg.x == -9, eg.y == 47  (240*-9 + 46*47 = 2)

    const inv = try gcd.modInv(a, m);              // a^-1 mod m
    // error.NotInvertible when gcd(a, m) != 1
    // error.InvalidModulus when m <= 0

    const me = zbi.ModExp(4);
    const p1 = try me.modExp(a, Big.fromU64(65537), m);  // BigInt exponent
    const p2 = try me.modExpU64(a, 65537, m);            // u64 exponent
    // error.DivisionByZero when m == 0, error.InvalidModulus when m < 0
    _ = .{ eg, inv, p1, p2 };

    // --- Primality ---
    const pt = zbi.PrimalityTest(4);
    const is_prime = try pt.millerRabin(Big.fromU64(104729), 7); // true
    const also = try pt.isProbablyPrime(Big.fromU64(104729));     // same, 7 rounds
    _ = .{ is_prime, also };

    // --- Text ---
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const s = try a.toString(allocator);   // "3735928559"
    defer allocator.free(s);
    const parsed = try Big.fromString("123456789012345678901234567890");
    _ = parsed;
}
```

## API

### `BigInt(N)`

`N` is the maximum number of `u64` limbs, so the precision is `N * 64` bits.
Each `BigInt(N)` is a distinct monomorphized type: `N` **must** match the
`max_limbs` passed to `ExtendedGcd(N)` / `ModExp(N)` / `PrimalityTest(N)`.

| Category | Members |
|----------|---------|
| Fields | `limbs: [N]u64`, `len: usize`, `negative: bool`, `MAX_LIMBS`, `MAX_BITS` |
| Constructors | `zero()`, `one()`, `fromU64(u64)`, `fromI64(i64)`, `fromU128(u128) !Self`, `fromString([]const u8) !Self` |
| Arithmetic | `add`, `sub`, `mul`, `neg`, `abs` — all `!Self` except `neg`/`abs` |
| Narrow arithmetic | `addU64`, `subU64`, `mulU64` — `!Self` |
| Division | `divRem`, `div`, `rem`, `mod`, `divRemU64` — `!Self` / `!struct { q, r }` |
| Shifts | `shl(usize) !Self`, `shr(usize) Self` |
| Bitwise | `bitAnd`, `bitOr`, `bitXor` — `Self` |
| Comparison | `eql`, `cmp() i2`, `lt`, `gt`, `leq`, `geq` |
| Predicates | `isZero`, `isOne`, `isNegative`, `bitLen() usize` |
| Formatting | `toString(allocator) ![]u8` |

Error set: `error.Overflow` (result exceeds `N` limbs), `error.DivisionByZero`,
`error.InvalidDigit` (from `fromString`).

### Limb-array helpers

These take a **comptime** limb count `n` and work on `*const [n]u64` /
`*[n]u64`. They exist for `zig-field`'s Montgomery constant generation and are
intended to be called from `comptime` context; the `out` parameter must itself
be a comptime-known value.

```zig
const zbi = @import("zig-bigint");

// --- constants ---
const bits   = comptime zbi.bitLength(255);   // 8   (comptime_int argument!)
const limbs4 = comptime zbi.numLimbs(256);    // 4

// --- serialize / deserialize (comptime) ---
const limbs  = comptime zbi.intToLimbs(4, @as(u256, 0xdeadbeef));
const value  = comptime zbi.limbsToInt(4, u256, &limbs); // T must hold n*64 bits
const runtime = zbi.intToLimbsRuntime(4, @as(u512, 12345)); // usable at runtime

// --- compare (returns std.math.Order) ---
const order  = comptime zbi.cmp(4, &limbs, &limbs);   // .eq

// --- out-parameter arithmetic (comptime) ---
const carry  = comptime blk: {
    var out: [4]u64 = undefined;
    break :blk zbi.add(4, &limbs, &limbs, &out);   // returns final carry
};
const shl_out = comptime blk: {
    var out: [4]u64 = undefined;
    zbi.shl(4, &limbs, 3, &out);                    // bit shift, not limb shift
    break :blk out;
};
const shr_out = comptime blk: {
    var out: [4]u64 = undefined;
    zbi.shr(4, &limbs, 3, &out);
    break :blk out;
};
// schoolbook n x n -> 2n limbs
const wide = comptime zbi.mul(4, &limbs, &limbs);
_ = .{ bits, limbs4, value, runtime, order, carry, shl_out, shr_out, wide };
```

## Known limitations

- `limb.sub(n, a, b, out)` **panics with "integer overflow"** whenever a borrow
  is actually needed (`out[i] = diff - borrow` is not a wrapping subtraction).
  In Debug/ReleaseSafe this aborts; in ReleaseFast it silently wraps. Verify with
  `7 - 9`, or use `Big.sub`, which is correct. The sibling helpers (`add`, `shl`,
  `shr`, `mul`) are unaffected.
- `limb.bitLength` takes a `comptime_int`. Calling it from a runtime scope fails
  to compile (`var v = value;` in the loop); wrap the call in `comptime`.
- `BigInt.format` needs the `{f}` specifier. It uses the Zig 0.16 signature, so
  `"{f}"` formats and `{}` falls back to the default struct printing. Use
  `toString`.
- `limb.cmpLimbs` is total: slices of different lengths are compared with
  zero-extension, which is the correct comparison of little-endian limb vectors
  and what `BigInt` already does internally. `cmpLimbsChecked` returns
  `error.LengthMismatch` when equal lengths are a requirement. Before this it
  asserted, which is compiled out in `ReleaseFast` and read past the end of the
  shorter slice — it is a `pub fn` over caller slices.
- `divRem` for multi-limb divisors uses shift-and-subtract, not Knuth Algorithm
  D. It is correct but roughly `O(bits²)`; it is not used on any hot path.
- `ExtendedGcd.egcd` and friends use `catch unreachable` internally, so they are
  **not** safe to call on inputs whose intermediate products exceed `N` limbs.
  Give the type enough headroom.
- Nothing here is constant-time. `binaryGcdInverse`-style tricks are not used;
  `egcd` and `inv` branch on value magnitude.

## Design Notes

- Representation is sign + magnitude, not two's complement: `negative` is a flag
  and `limbs` holds the magnitude. Little-endian, so `limbs[0]` is the least
  significant word.
- `len` is always normalized: trailing zero limbs are stripped, and `negative`
  is cleared for zero.
- `mul` rejects up front with `error.Overflow` when `len(a) + len(b) > N`, so a
  product that cannot fit never partially computes.
- `BigInt(N)` with `N = (bits + 63) / 64` gives exactly the precision you need;
  `zbi.numLimbs(bits)` computes it.
- `zig-field` uses only the limb-array helpers and `BigInt` for **comptime**
  Montgomery constants (`R²`, `m₀⁻¹`); no `zig-bigint` code runs in a field
  multiplication.

## Running Tests

```bash
cd libs/bigint && zig build test
```

28 tests, measured with `zig build test --summary all` on 2026-09-30. The root
`zig build test` runs this library's inline `src/` tests too, so it counts the
same 28.

## License

MIT OR Apache-2.0
