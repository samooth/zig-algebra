# zig-rng

Cryptographically secure and deterministic random number generators for Zig. Includes a ChaCha20 CSPRNG, a SHAKE256 XOF-based generator, a process-wide OS-seeded CSPRNG, and unbiased sampling helpers for field elements and bounded integers.

## Features

- **ChaCha20Rng** — stream-cipher CSPRNG (RFC 8439), deterministic from a 32-byte key
- **Shake256Rng** — XOF-based generator (Keccak-f[1600], rate 136 bytes), extendable output
- **Process-wide CSPRNG** (`csprng`) — seeded once from OS entropy, spinlock-guarded, with a host-injection hook for freestanding/WASM
- **Unbiased sampling** — rejection sampling for field elements and bounded integers, with a bounded attempt count
- **Utilities** — Fisher-Yates shuffle, random permutation, random bool, `u8`/`u32`/`u64` draws
- **`RngTrait`** — compile-time contract: any type with `randomBytes([]u8) void` satisfies it

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_rng = .{
        .path = "path/to/zig-algebra/libs/rng",
    },
},
```

Then in your `build.zig`:

```zig
const zr = b.dependency("zig_rng", .{});
exe.root_module.addImport("zig-rng", zr.module("zig-rng"));
```

The module is named `zig-rng`; it re-exports `chacha20`, `shake256`, `rng` and
`csprng` as sub-namespaces plus flat aliases for the common helpers.

## Quick Start

```zig
const std = @import("std");
const zr = @import("zig-rng");

pub fn main() !void {
    // --- ChaCha20-based CSPRNG ------------------------------------------
    // initFromSeed takes a *const [32]u8 (the RFC 8439 key).
    var chacha = zr.ChaCha20Rng.initFromSeed(&[_]u8{0x42} ** 32);

    var buf: [32]u8 = undefined;
    chacha.randomBytes(&buf);          // fill a caller-owned buffer
    const val = chacha.randomU64();    // random u64
    const val32 = chacha.randomU32();
    const val8 = chacha.randomU8();
    const flag = chacha.randomBool();
    const bounded = try chacha.randomU64Bounded(1000); // !u64, unbiased

    // Explicit key + nonce (32-byte key, 12-byte nonce):
    var chacha2 = zr.ChaCha20Rng.init(&[_]u8{1} ** 32, &[_]u8{2} ** 12);
    chacha2.randomBytes(&buf);

    // --- SHAKE256 XOF ---------------------------------------------------
    // init() takes no seed: absorb first, then squeeze (lazily finalized).
    var shake = zr.Shake256Rng.init();
    shake.absorbSeed("my seed material");

    var out: [48]u8 = undefined;
    shake.squeezeInto(&out);           // allocation-free

    var shake2 = zr.Shake256Rng.init();
    shake2.absorbSeed("my seed material");
    const heap = try shake2.squeeze(64, std.heap.page_allocator); // ![]u8
    defer std.heap.page_allocator.free(heap);

    // Convenience fixed-size squeezes also take an allocator:
    var s3 = zr.Shake256Rng.init();
    s3.absorbSeed("x");
    const w = try s3.squeeze32(std.heap.page_allocator); // ![32]u8

    // --- Unbiased field element ----------------------------------------
    // Signature: randomFieldElement(comptime F, comptime R, rng: *R) !F
    const F = @import("zig-field").Goldilocks;
    const elem = try zr.randomFieldElement(F, zr.ChaCha20Rng, &chacha);

    // --- Utilities (all take the RNG *type* and a mutable pointer) ------
    var items = [_]u32{ 1, 2, 3, 4, 5 };
    try zr.shuffle(u32, zr.ChaCha20Rng, &chacha, &items);
    const perm = try zr.randomPermutation(zr.ChaCha20Rng, &chacha, 8, std.heap.page_allocator);
    defer std.heap.page_allocator.free(perm);
    const b = zr.randomBool(zr.ChaCha20Rng, &chacha);
    const r64 = zr.randomU64(zr.ChaCha20Rng, &chacha);
    const u = try zr.randomU64Bounded(zr.ChaCha20Rng, &chacha, 50);

    // --- Process-wide CSPRNG -------------------------------------------
    var pbuf: [16]u8 = undefined;
    zr.csprng.bytes(&pbuf);
    const pr = zr.csprng.random(u64);
}
```

## API

### `ChaCha20Rng`

| Member | Signature | Notes |
|--------|-----------|-------|
| `init` | `(seed: *const [32]u8, nonce: *const [12]u8) Self` | RFC 8439 key + nonce |
| `initFromSeed` | `(seed: *const [32]u8) Self` | nonce is zeroed |
| `randomBytes` | `(self: *Self, out: []u8) void` | consumes the keystream buffer |
| `randomU64` / `randomU32` / `randomU8` | `(self: *Self) u64/u32/u8` | little-endian reads |
| `randomBool` | `(self: *Self) bool` | one byte, low bit |
| `randomU64Bounded` | `(self: *Self, max: u64) !u64` | rejection sampling |
| fields | `state`, `buffer`, `available`, `exhausted` | public |

### `Shake256Rng`

| Member | Signature | Notes |
|--------|-----------|-------|
| `init` | `() Self` | no seed argument; absorb first |
| `absorbSeed` | `(self: *Self, seed: []const u8) void` | must precede squeezing |
| `finalize` | `(self: *Self) void` | explicit; also called lazily |
| `squeeze` | `(self: *Self, len: usize, allocator) ![]u8` | heap; caller frees |
| `squeeze32` / `squeeze64` | `(self: *Self, allocator) ![32]u8` / `![64]u8` | stack result |
| `squeezeInto` | `(self: *Self, out: []u8) void` | allocation-free |

`Shake256Rng` does **not** implement `randomBytes`, so it does **not** satisfy
`RngTrait`; use it directly through `absorbSeed` + `squeezeInto`.

### Generic helpers (all take the RNG *type* as a comptime argument plus a mutable pointer)

| Function | Signature |
|----------|-----------|
| `randomFieldElement` | `(comptime F, comptime R, rng: *R) !F` |
| `randomU64Bounded` | `(comptime R, rng: *R, max: u64) !u64` |
| `shuffle` | `(comptime T, comptime R, rng: *R, items: []T) !void` |
| `randomPermutation` | `(comptime R, rng: *R, n: usize, allocator) ![]usize` |
| `randomBool` | `(comptime R, rng: *R) bool` |
| `randomU64` / `randomU32` / `randomU8` | `(comptime R, rng: *R) u64/u32/u8` |
| `RngTrait` | `(comptime R) type` — expose `.assert()` and `.has_randomBytes` |
| `MAX_REJECTION_ATTEMPTS` | `1024` |

### `csprng` (process-wide)

| Function | Signature | Notes |
|----------|-----------|-------|
| `bytes` | `(out: []u8) void` | lazily seeds on first use |
| `random` | `(comptime T) T` | uniformly random `T` |
| `setEntropy` | `(entropy: []const u8) void` | **required** on freestanding/WASI before any draw |
| `setRandomForTesting` | `(rng: ?*std.Random) void` | test-only deterministic injection |

## Errors and limits

- `error.InvalidBound` — `randomU64Bounded(max)` with `max == 0`.
- `error.RejectionSamplingFailed` — `MAX_REJECTION_ATTEMPTS` (1024) draws were
  all rejected. A healthy source effectively never hits this; a hostile or
  constant source always does (there is a regression test for that).
- `randomFieldElement` requires `F` to expose `MODULUS` (or `order`) and
  `fromInt`, and `R` to expose `randomBytes`. It reads `F.NUM_BYTES` bytes when
  available and falls back to `bit_length(order)` otherwise, capped at 64 bytes.

## Known limitations

- `ChaCha20Rng.initOsRandom()` **does not compile on Zig 0.16.0** — it calls the
  removed `std.crypto.random.bytes`. It is not covered by any test, so the
  breakage is latent. Use `zr.csprng.bytes()` (which has its own OS-entropy
  path) or supply your own seed for now.
- `ChaCha20Rng.refill` **panics** with "ChaCha20 counter exhausted" when the
  32-bit block counter wraps. At 64 bytes per block that is 256 GiB of keystream;
  re-seed before then.
- `csprng` serialises all callers on a spinlock, so it is not meant for bulk
  random-byte generation. Use a `ChaCha20Rng` for that.

## Design Notes

- `ChaCha20Rng` implements the ChaCha20 block function (20 rounds, 64-byte
  blocks) and hands out the keystream; key and counter are little-endian words.
- `Shake256Rng` is a Keccak sponge with rate 136 bytes and SHAKE domain bytes
  `0x1F … 0x80` on finalize.
- `csprng` seeds `std.Random.DefaultCsprng` once, then reuses it. Entropy source
  order: host injection (freestanding/WASI) → `arc4random_buf` (libc) →
  `getrandom` → `getrandom` syscall (Linux) → `BCryptGenRandom` (Windows) →
  `/dev/urandom`.
- Rejection sampling uses a bit mask derived from `bit_length(max - 1)`, so it is
  unbiased but not constant-time; it is only used for public-facing sampling.
- All generators are deterministic given the same seed, which is what makes the
  protocol-level fixtures in `zig-fri` and `zig-transcript` reproducible.

## Running Tests

```bash
cd libs/rng && zig build test
```

13 tests: ChaCha20 determinism across two instances, distinct outputs for
distinct seeds, `randomU64Bounded`, `randomBytes` non-repetition, SHAKE256
determinism and seed sensitivity, allocation-free `squeezeInto`, Fisher-Yates
permutation validity, `randomPermutation`, `randomFieldElement` on an in-file
F7, `randomBool` balance, `randomU64Bounded` edge cases (`0`, `1`, `max == 0`),
and a regression test that a constant-output source terminates with
`error.RejectionSamplingFailed` after `MAX_REJECTION_ATTEMPTS`.

## License

MIT OR Apache-2.0
