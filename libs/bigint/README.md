# zig-bigint

Arbitrary-precision integer arithmetic for Zig. Allocation-free, comptime-configurable precision backed by fixed-size `[N]u64` limb arrays.

## Features

- **Generic `BigInt(N)` type** — configure precision at comptime via number of 64-bit limbs
- **Limb-array helpers** — `bitLength`, `numLimbs`, `intToLimbs`, `limbsToInt`, `cmp`, `add`, `sub`, `shl`, `shr`, `mul`
- **Extended GCD** — for modular inverse, parameter generation
- **Modular exponentiation** — square-and-multiply
- **Primality testing** — Miller-Rabin deterministic for < 64 bits, probabilistic for larger
- **Constant-time operations** — where applicable
- **No allocations**, no external dependencies

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_bigint = .{
        .path = "path/to/zig-algebra-core/zig-bigint",
    },
},
```

Then in your `build.zig`:

```zig
const bigint = b.dependency("zig_bigint", .{});
exe.root_module.addImport("zig-bigint", bigint.module("zig-bigint"));
```

## Quick Start

```zig
const zbi = @import("zig-bigint");

// Create a 256-bit big integer (4 limbs)
const BigInt256 = zbi.BigInt(4);

// Basic arithmetic
const a = BigInt256.fromU512(0xdeadbeef);
const b = BigInt256.fromU512(0xcafebabe);
const sum = a.add(b);
const prod = a.mul(b);

// Modular arithmetic
const m = BigInt256.fromU512(p);
const inv = a.modInv(m);
const pow = a.modPow(exp, m);

// Primality test
const is_prime = BigInt256.isProbablePrime(candidate);
```

## Limb-Array Operations

For raw limb arrays (used by zig-field Montgomery arithmetic):

```zig
const limbs = zbi.intToLimbs(4, some_u512);
const value = zbi.limbsToInt(4, u512, &limbs);
const cmp_result = zbi.cmp(4, &a_limbs, &b_limbs);
const sum = zbi.add(4, &a_limbs, &b_limbs);
```

## Running Tests

```bash
zig build test
```

## Design Notes

- Limbs are stored little-endian: `limbs[0]` is the least significant word
- All operations are allocation-free (stack-only)
- `BigInt(N)` with `N = (bits + 63) / 64` gives the required precision
- Used by zig-field for Montgomery arithmetic constants computed at comptime

## License

MIT OR Apache-2.0
