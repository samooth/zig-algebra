# zig-algebra — Agent Guide

## Overview
Modular algebra library ecosystem for Zig 0.16.0. 17 libraries (workspace
version 0.4.0) covering fields, curves, pairings, and STARK building blocks.
No independent cryptographic audit exists; see SECURITY.md before making
security claims.

## Build Commands

```bash
zig build test        # Run all library tests (354 tests, ~1-2 min Debug)
zig build test -Doptimize=ReleaseFast   # Same 354 tests, seconds
zig build bench       # Run ReleaseFast benchmarks (field/curve/pairing/MSM/NTT)
zig build example     # BLS12-381 Schnorr signature demo
zig build stark       # STARK prover demo (Fibonacci over Goldilocks via FRI)
zig build wasm        # examples/wasm_fp.zig -> wasm32-freestanding
zig build wasm-pairing  # examples/wasm_pairing.zig -> wasm32-freestanding
zig build fuzz -Doptimize=ReleaseFast  # randomized property/fuzz runner
```

`zig build` with no step runs the full test suite when
`-Doptimize=ReleaseFast` is set; in Debug it builds nothing.

Per-library: `cd libs/<name> && zig build test`. Only `field` and `curve` have
separate `tests/` roots; the root `zig build test` step compiles inline `src/`
tests only (354 total vs. 470 summed over all per-library steps).

## Code Conventions

### Naming
- Types: PascalCase (`Fp12Direct`, `MerkleTree`)
- Functions/methods: camelCase (`fromBytes`, `scalarMul`, `challengeField`)
- Constants: SCREAMING_SNAKE (`MODULUS`, `NUM_BYTES`, `XI`, `HASH_LEN`)
- Private helpers: `_` prefix optional; prefer module-private via non-pub

### Field API Contract
Every field type MUST expose:
```zig
pub const NUM_BYTES: usize;
pub fn zero() Self;
pub fn one() Self;
pub fn fromInt(x: anytype) Self;
pub fn add(a: Self, b: Self) Self;
pub fn sub(a: Self, b: Self) Self;
pub fn mul(a: Self, b: Self) Self;
pub fn neg(a: Self) Self;
pub fn eql(a: Self, b: Self) bool;   // or eq()
pub fn isZero(self: Self) bool;
pub fn toBytes(self: Self) [NUM_BYTES]u8;
pub fn fromBytes(bytes: []const u8) !Self;  // error on >= MODULUS
```
Optional but common: `inv()`, `sqr()`, `pow()`, `conjugate()`, `frobenius()`.

### Checked Inverses and Division (0.4.0 rule)
Invertible operations come in pairs: a total legacy wrapper and a checked one.
New code MUST use the checked one.

```zig
pub fn inv(self: Self) Self;                 // legacy, total: inv(0) == zero()
pub fn invChecked(self: Self) error{InverseOfZero}!Self;
pub fn div(self: Self, other: Self) Self;    // legacy, total: x / 0 == zero()
pub fn divChecked(self: Self, other: Self) error{ DivisionByZero, InverseOfZero }!Self;
pub fn batchInv(inputs: []const Self, outputs: []Self) void;                 // legacy, total
pub fn batchInvChecked(inputs: []const Self, outputs: []Self) error{ LengthMismatch, InverseOfZero }!void;
```

Rationale: the old `std.debug.assert(!self.isZero())` was compiled out in
`ReleaseFast`, where the binary-GCD loop then never terminated. The total
wrapper is kept for source compatibility, and it propagates zero, which is
*not* a valid inverse. Do not "fix" a caller by asserting in a new place —
return a typed error instead. Apply the same split to length/dimension inputs:
`length` and `dimension` mismatches are `error.LengthMismatch` /
`error.InvalidDimension`, never asserts. A legacy total wrapper is not a
validation step, and `std.debug.assert` is now reserved for invariants that no
caller input can influence.

### Constant-Time vs Non-CT
- **CT required**: field inversion/mul on secret keys, EC scalarMul,
  signature operations.
- **Non-CT OK**: public parameters, transcript hashing, Merkle tree
  construction on public data, benchmark loops.
- Document CT status in function docstring when relevant.

### Error Handling
- Return errors instead of panicking in library code:
  ```zig
  pub fn fromBytes(bytes: []const u8) !Self { ... }
  ```
- Use `std.debug.assert` only for internal invariants that no caller input can
  influence; see the checked-inverse rule above for anything a caller can
  reach.
- Public APIs validate inputs and return typed errors.

### Memory
- Prefer stack allocation for fixed-size algebraic types (fields, points).
- Use caller-provided allocator for variable-size structures (trees, proofs).
  The proof stack does this: `fri.prove`/`fri.verify`, `kzg.commit`/`prove`,
  `Ipa.prove` and the binary-field PCS/sum-check all take an allocator and
  propagate `OutOfMemory` (no `catch unreachable`).
- All heap allocations must have matching `deinit(allocator)` methods.

### Comptime
- Use `comptime` blocks for modulus-dependent constants.
- Set generous eval quotas for heavy comptime work:
  `@setEvalBranchQuota(100_000_000);` (needed for legendre on 381-bit).
- Avoid runtime branching on secret data.

## Testing

- Every library has inline tests in source files AND a `test` step in its
  `build.zig`.
- Root `build.zig` aggregates all libraries via the `lib()` helper.
- Test naming: descriptive strings like `"mul distributes over add"`.
- Include negative tests: tampered data must fail verification.
- Counts (Zig 0.16.0, verified): root `zig build test` = 354; per-library
  `zig build test` totals sum to 470 (field 85, curve 96 include the `tests/`
  roots the root step skips). Per-library totals: algebra-traits 0,
  bigint 18, binary-field 76, curve 96, field 85, fri 10, hash 17, kzg 6,
  linalg 9, merkle 18, ntt 11, pairing 54, parallel 2, poly 20, rng 23,
  serialization 15, transcript 10.

### Property-Based Testing Pattern
For ring/field axioms, generate random elements and verify:
```zig
test "property: associativity" {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (0..1000) |_| {
        const a = F.random(rand);
        const b = F.random(rand);
        const c = F.random(rand);
        try testing.expect(a.add(b).add(c).eql(a.add(b.add(c))));
    }
}
```

## Adding a New Library

1. Create `libs/<name>/build.zig` + `build.zig.zon` + `src/root.zig`.
2. Wire into root `build.zig` using the `lib()` helper with imports list.
3. Update README.md architecture table.
4. Update DESIGN.md dependency graph if new edges exist.

## Versioning

Root `build.zig.zon` carries the workspace version (`0.4.0`); each library has
its own independent semver in `libs/<name>/build.zig.zon` (currently
`0.1.0`–`0.4.0`). Bump the library version for API changes, the workspace
version for ecosystem-level releases, and record both in `CHANGELOG.md`.

## Known Gaps (do not paper over these in docs)

- `inv(0) == 0` and `x / 0 == 0` are the **legacy total** behaviours of
  `inv`/`div` in `zig-field` (both backends plus both extension towers) and of
  `inv` in `zig-binary-field` (`BinaryField`, `TowerField`). Zero is not an
  inverse, so the legacy result must never be read as "invertible". Document
  `invChecked` / `divChecked` / `batchInvChecked` as the APIs new code uses.
- `Sumcheck(F)` in `zig-binary-field` requires `F.BITS >= 128`;
  `MlePcs(F, E)` and `CommittedMlePcs(F, E)` require `E.BITS >= 128` for
  their challenge field and return `error.FieldTooSmall` otherwise.
  `SumcheckUnsafe` / `MlePcsUnsafe` / `CommittedMlePcsUnsafe` skip that check,
  keep the historical 4-bit on-chain challenge format, and are **not sound**
  against a grinding prover. Label them toy/test-only everywhere.
- `Ipa.verify` in `libs/field/src/ipa.zig` is a stub (`error.Unsupported`);
  only `Ipa.verifyWithCommitment` works, and IPA challenges are a local
  SHA-256 of `(L, R, round)` — not a `zig-transcript` Fiat-Shamir session.
- `kzg.Setup.generate` is a synthetic setup (tests/dev only).
- Pairing, curve scalarMul and field inversion are not constant-time.
- `zig build bench` numbers are machine-specific; label them as indicative.
- No independent cryptographic audit exists for any library.

## Common Gotchas (Zig 0.16)

- No `std.time.Timer` and no `std.time.nanoTimestamp()` in Zig 0.16. Use
  `zig-parallel`'s portable clock: `@import("zig-parallel").timing.nowNs()`
  (QPC on Windows, `std.c.clock_gettime(CLOCK_MONOTONIC)` with libc,
  `std.os.linux.clock_gettime` bare-metal). Do NOT write Linux-only
  timing inline in shared code.
- No `std.io.getStdOut()`; use `std.debug.print` for output.
- Blake3 is at `std.crypto.hash.Blake3`, not `std.crypto.hash.blake3`.
- ArrayList needs explicit allocator at method calls, not construction.
- Struct fields need trailing commas.
- Error unions: `error{X}!T` syntax (not `T!X`).

## Signing Commits

All commits GPG-signed with key `B59CBA1AED05C03737146912E791C5B7A60B5A80`.
If signing fails with tty error, warm agent cache first:
```bash
echo test | gpg --clearsign > /dev/null && git commit -S ...
```
