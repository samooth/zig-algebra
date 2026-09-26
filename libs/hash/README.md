# zig-hash

Cryptographic hash functions for Zig. Includes traditional hashes (Blake3, Blake2, Keccak, SHA3) and ZK-friendly algebraic hashes (Poseidon, MiMC).

## Features

- **Blake3** — parallelizable, with keyed and key-derivation modes
- **Blake2b256 / Blake2s256** — fast, used in many protocols
- **Keccak-256** — Ethereum-compatible
- **SHA3-256** — NIST standard
- **Poseidon** — ZK-friendly algebraic hash (minimal constraints), sponge-based
- **MiMC** — ZK-friendly hash for SNARKs (Feistel-based, fewer constraints)
- **Streaming API** — incremental hashing for large inputs (`init` / `update` / `finalize`)
- **`Hash` interface** — a small Blake3-based pair-hash shim matching zig-stark's `core/hash/hash.zig`

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_hash = .{
        .path = "../zig-algebra/libs/hash",
    },
},
```

Then in your `build.zig`:

```zig
const zh = b.dependency("zig_hash", .{});
exe.root_module.addImport("zig-hash", zh.module("zig-hash"));
```

## Quick Start

### One-shot and streaming byte hashes

```zig
const std = @import("std");
const zh = @import("zig-hash");

// One-shot
const digest = zh.hashBlake3("hello world");
const keccak = zh.hashKeccak256("ethereum");
_ = zh.hashSha3_256("x");
_ = zh.hashBlake2b256("x");
_ = zh.hashBlake2s256("x");

// Streaming (incremental). `init` takes no options and `finalize` writes
// into a caller-provided buffer; there is no `finalResult`.
var hasher = zh.Blake3.init();
hasher.update("chunk 1");
hasher.update("chunk 2");
var final: [zh.blake3.OUT_LEN]u8 = undefined;
hasher.finalize(&final);

// Keccak-256 and the Blake2 variants follow the same shape
var k = zh.Keccak256.init();
k.update("chunk 1");
var kd: [zh.Keccak256.OUT_LEN]u8 = undefined;
k.finalize(&kd);
std.debug.assert(std.mem.eql(u8, &kd, &zh.hashKeccak256("chunk 1")));

var b2 = zh.Blake2b256.init(null); // optional key
b2.update("chunk 1");
var b2d: [zh.Blake2b256.OUT_LEN]u8 = undefined;
b2.finalize(&b2d);

// Keyed and key-derivation modes of Blake3
var keyed = zh.Blake3.initKeyed(&[_]u8{1} ** 32);
keyed.update("x");
var kout: [zh.blake3.OUT_LEN]u8 = undefined;
keyed.finalize(&kout);

var derived = zh.Blake3.initDeriveKey("my-context");
derived.update("key material");
var dout: [zh.blake3.OUT_LEN]u8 = undefined;
derived.finalize(&dout);
```

### ZK-friendly hashing (over prime fields)

`Poseidon` and `MiMC` are **type factories**, not functions you call
directly. Instantiate the type with its parameters, then build an instance
from a seed (or from explicit round constants and an MDS matrix).

```zig
const std = @import("std");
const zh = @import("zig-hash");
const zf = @import("zig-field");

const allocator = ...; // caller-supplied std.mem.Allocator

const F = zf.BabyBear;
const input = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3) };

// Poseidon(F, t, full_rounds, partial_rounds, alpha)
const PoseidonF = zh.Poseidon(F, 3, 8, 60, 5);
const poseidon = try PoseidonF.initFromSeed("demo");

const out2 = poseidon.hash(&input); // [2]F  (sponge, rate = t - 1)
const ab = poseidon.hash2(input[0], input[1]); // single F
_ = out2;
_ = ab;

var state = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3) };
poseidon.permute(&state); // one permutation, in place

// MiMC(F, rounds, exponent)
const MiMCF = zh.MiMC(F, 91, 5);
const mimc = try MiMCF.initFromSeed("demo");
const mimc_out = mimc.hash(&input); // single F
_ = mimc_out;
_ = mimc.hash2(input[0], input[1]);
_ = mimc.permute(input[0]);

// Constants and the MDS matrix can also be supplied explicitly
const explicit = PoseidonF.init(
    [_][3]F{.{ F.fromInt(1), F.fromInt(2), F.fromInt(3) }} ** 68, // 8 + 60 rounds
    [_][3]F{
        .{ F.fromInt(1), F.fromInt(0), F.fromInt(0) },
        .{ F.fromInt(0), F.fromInt(1), F.fromInt(0) },
        .{ F.fromInt(0), F.fromInt(0), F.fromInt(1) },
    },
);
_ = explicit.hash(&input);

// Seeds longer than zh.poseidon.MAX_SEED_LEN (1 MiB) are rejected
const too_long = try allocator.alloc(u8, zh.poseidon.MAX_SEED_LEN + 1);
defer allocator.free(too_long);
@memset(too_long, 0);
try std.testing.expectError(error.SeedTooLong, PoseidonF.initFromSeed(too_long));
try std.testing.expectError(error.SeedTooLong, MiMCF.initFromSeed(too_long));
```

> **Caveat — not audited parameters.** `initFromSeed` derives round
> constants and the MDS matrix from a Blake3 counter stream. That makes the
> instances deterministic and reproducible, but it is *not* a standard
> Poseidon/MiMC parameter set and no differential/random-oracle analysis has
> been done. Do not use these instances in production signatures or proofs.

## Hash Functions

| Algorithm | Entry points | Output | Use case |
|-----------|--------------|--------|----------|
| Blake3 | `zh.Blake3`, `zh.hashBlake3`, `zh.Blake3.hashBytes` | 32 bytes | General-purpose, STARKs, Merkle trees |
| Blake2b256 | `zh.Blake2b256`, `zh.hashBlake2b256` | 32 bytes | General-purpose |
| Blake2s256 | `zh.Blake2s256`, `zh.hashBlake2s256` | 32 bytes | General-purpose |
| Keccak-256 | `zh.Keccak256`, `zh.hashKeccak256` | 32 bytes | Ethereum |
| SHA3-256 | `zh.Sha3_256`, `zh.hashSha3_256` | 32 bytes | NIST standard |
| Poseidon | `zh.Poseidon(F, t, Rf, Rp, alpha)` → `hash` returns `[2]F`, `permute` operates on `t` lanes | 2 field elements | ZK-friendly (algebraic) |
| MiMC | `zh.MiMC(F, rounds, exponent)` → `hash`/`hash2`/`permute` return one `F` | 1 field element | ZK-friendly (minimal constraints) |

## Running Tests

```bash
# From the monorepo root
zig build test

# Just this library (18 tests, all inline in src/root.zig)
cd libs/hash && zig build test
```

## Design Notes

- Traditional hashes operate on byte arrays; the `Blake3` / `Blake2b256` /
  `Blake2s256` / `Keccak256` / `Sha3_256` structs all expose
  `init` → `update`* → `finalize` and every algorithm also has a one-shot
  free function
- ZK-friendly hashes operate on field elements. `F` must satisfy
  `zig-algebra-traits`' `FieldTrait` (`zero`, `one`, `add`, `sub`, `neg`,
  `mul`, `inv`, `div`, `pow`, `eql`, `isZero`)
- Poseidon is a **sponge** over the `x^alpha` S-box: each round adds round
  constants, applies the S-box to all `t` lanes (full round) or only lane 0
  (partial round), then multiplies by the MDS matrix. `hash` absorbs
  `rate = t - 1` elements per permutation and squeezes 2 outputs
- MiMC is a **Feistel network** over a single lane: the round function is
  `x -> x^exponent + c_i`, and `hash2(l, r)` chains four of them
- The `Hash` shim (`zh.Hash`) exposes `hashBytes` and `hash2`; note that
  `Hash.hash2` currently does **not** compile (it calls the pre-0.16 Blake3
  API), so use `zh.Blake3` directly for two-child hashing
- Poseidon's sponge needs a rate of at least two, so the `Poseidon` factory
  `@compileError`s when `t < 3` (it used to be a `std.debug.assert` inside
  `hash`, compiled out in `ReleaseFast`, which then indexed a `[0]` state)
- `Poseidon(...).initFromSeed` returns `error.NoValidMdsEntry` if the 256-round
  search for a valid MDS entry finds nothing. That guard used to be a
  `std.debug.assert`, compiled out in `ReleaseFast`, where the failed search
  left `y[j]` undefined and produced a singular MDS matrix
- Custom `format` methods need the `{f}` specifier in Zig 0.16; `{}` prints the
  default struct form

## License

MIT OR Apache-2.0
