# zig-rng

Cryptographically secure and deterministic random number generators for Zig. Includes process-wide CSPRNG, XOF-based RNG, and utilities for field element generation.

## Features

- **ChaCha20Rng** — stream-cipher CSPRNG (RFC 8439), fast and secure
- **SHAKE256Rng** — XOF-based CSPRNG, deterministic and extendable
- **Process-wide CSPRNG** — singleton seeded from OS entropy
- **Random field elements** — generate random elements in any prime field
- **Utilities** — Fisher-Yates shuffle, random permutation, random bool, bounded random

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_rng = .{
        .path = "path/to/zig-algebra-core/zig-rng",
    },
},
```

Then in your `build.zig`:

```zig
const zr = b.dependency("zig_rng", .{});
exe.root_module.addImport("zig-rng", zr.module("zig-rng"));
```

## Quick Start

```zig
const zr = @import("zig-rng");

// ChaCha20-based CSPRNG
var chacha = zr.ChaCha20Rng.init(42); // deterministic seed
var buf: [32]u8 = undefined;
chacha.randomBytes(&buf);
const val = chacha.randomU64();

// SHAKE256-based CSPRNG
var shake = zr.Shake256Rng.init(&seed_bytes);
shake.squeezeInto(&output);

// Random field element
const F = @import("zig-field").BN254_Fp;
const rand_elem = zr.randomFieldElement(F);

// Utilities
var items = [_]u32{ 1, 2, 3, 4, 5 };
zr.shuffle(u32, &items, prng.random());
const perm = zr.randomPermutation(8, prng.random());
const b = zr.randomBool(prng.random());
```

## API

| Function | Description |
|----------|-------------|
| `ChaCha20Rng.init(seed)` | Create ChaCha20 RNG from seed |
| `ChaCha20Rng.randomBytes(buf)` | Fill buffer with random bytes |
| `ChaCha20Rng.randomU64()` | Random u64 |
| `Shake256Rng.init(seed)` | Create SHAKE256 RNG from seed |
| `Shake256Rng.squeezeInto(buf)` | Squeeze random bytes |
| `randomFieldElement(F)` | Random element in prime field F |
| `randomU64Bounded(max)` | Random u64 in [0, max) |
| `shuffle(T, items, rng)` | Fisher-Yates shuffle |
| `randomPermutation(n, rng)` | Random permutation of [0, n) |
| `randomBool(rng)` | Random boolean |

## Running Tests

```bash
zig build test
```

## Design Notes

- ChaCha20Rng is seeded from a 32-byte key + 12-byte nonce (RFC 8439)
- SHAKE256Rng is XOF-based — can squeeze arbitrary amounts of output
- Process-wide CSPRNG uses OS entropy (`/dev/urandom`, `arc4random`, `getrandom`) for initial seeding
- `randomFieldElement` uses rejection sampling to avoid bias
- All RNGs are deterministic given the same seed

## License

MIT OR Apache-2.0
