# Changelog

All notable changes to `zig-field` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Library version: **0.4.0** (`libs/field/build.zig.zon`). The workspace version
lives in the root `build.zig.zon` (`0.5.0`).

---

## [0.4.0] — 2026-09-27

### Security

- `batchAdd` / `batchSub` / `batchMul` and `multiExp` return
  `error{LengthMismatch}`. The `std.debug.assert` that guarded the slice
  lengths is compiled out in `ReleaseFast`, where the three-way batch loop
  wrote past `out` and the `multiExp` window loop read past `exponents`.
  `multiExp`'s `window_bits` range is a comptime parameter, so it is now a
  `@compileError` rather than a runtime assert.
- `Ipa.innerProduct` and `Ipa.commit` return `error.LengthMismatch`; the
  asserts vanished in `ReleaseFast` and the two-slice loops read out of bounds.
- `primitiveRootOfUnity` returns `error.OrderTooLarge` and `rootOfUnity` adds
  `error.NotPowerOfTwo`, on `SmallField`, `BigField`, `QuadraticExtension` and
  `CubicExtension`. The old asserts vanished in `ReleaseFast`, where
  `two_adicity - log_size` underflowed the exponent shift and
  `std.math.log2(0)` is undefined.

### Added

- `BigField.toU64Checked` (`error.Overflow`). `toU64` keeps truncating, which
  is a source-compatible legacy result and never a validation step.

### Removed

- `src/ntt.zig` and `src/merkle.zig`, both unreferenced duplicates (of
  `zig-ntt`'s transform and of `MerkleTree` in `lib.zig` respectively). Their
  asserts were compiled out in `ReleaseFast` and the checked implementations
  are the exported ones. `zig-ntt` and `lib.zig` are now the only
  implementations.

### Fixed

- The `format` methods on the field and extension types used the pre-0.16
  signature `(self, comptime fmt, options: std.fmt.FormatOptions, writer)`.
  Zig 0.16 only selects a `format` method for `{f}`, so all of them were dead
  and `{}` printed the default struct dump. They now use
  `fn (self, writer: *std.Io.Writer) std.Io.Writer.Error!void`.

---

## [Unreleased]

### Added

Checked variants of every entry point whose precondition used to be a
`std.debug.assert` (compiled out in `ReleaseFast`/`ReleaseSmall`):

- `invChecked()` → `error.InverseOfZero` on `SmallField`, `BigField`,
  `QuadraticExtension` and `CubicExtension`
- `divChecked(other)` → `error.DivisionByZero` on the same four types
- `batchInvChecked(inputs, outputs)` → `error.LengthMismatch` /
  `error.InverseOfZero` on both backends; on error `outputs` is untouched
- `Montgomery(M).invMontgomeryChecked` → `error.InverseOfZero`, and
  `binaryGcdInverse` now returns `?[]u64` (`null` for zero) instead of looping
- `nttVec8M31Checked` / `inttVec8M31Checked` → `error.InvalidLength` when
  `data.len != 8 * 2^log_n` (also rejects a `log_n` whose `8 * 2^log_n` would
  not fit in a `usize`); exported flat as `zf.nttVec8M31Checked` /
  `zf.inttVec8M31Checked`

### Changed (BREAKING in behaviour)

- **`inv`, `inverse`, `div` and `batchInv` are total.** `inv(0) == zero()` and
  `x / 0 == zero()` where the code previously `std.debug.assert`ed the input was
  non-zero — a panic in Debug/ReleaseSafe and, for `inv`, an infinite loop in
  `ReleaseFast` once the assert was compiled out and the binary-GCD loop
  stopped making progress on `a == 0`. `batchInv` now returns without touching
  `outputs` on a length mismatch (it used to write past the end) and writes
  `zero()` at each zero input while inverting every other position. Zero is not
  an inverse; call the `…Checked` variants when invertibility is required.
- `randomBounded(rnd, 0)` returns zero (the empty range) instead of looping
  forever on an unsatisfiable range test.
- `Vec8.fromSlice8` zero-fills the remaining lanes for a short slice and
  truncates a long one to its first 8 entries, instead of reading past the end.
- `MerkleTree(F).verifyBatch` fails closed (`false`) on a length mismatch
  instead of verifying only the first `min(len)` entries and returning `true`.
- `nttVec8M31` / `inttVec8M31` leave `data` untouched on a length mismatch
  (they used to read and write out of bounds); the `…Checked` pair reports it.

### Testing

- `cd libs/field && zig build test` runs 85 tests in this library (7 test
  binaries: inline `src/` tests 13, `field_test.zig` 47, `extension_test.zig` 10,
  `merkle_test.zig` 4, `ipa_test.zig` 2, `simd_test.zig` 7, `ext_quick.zig` 2).
  The root `zig build test` only compiles the inline `src/` tests, so it reports
  13 for `zig-field` and 354 for the whole workspace.
- New negative tests cover `inv(0)`, `div` by zero, `batchInv` with zeros and
  with mismatched lengths, `randomBounded(rnd, 0)`, `fromSlice8` with a short and
  a long slice, the M31 SIMD NTT length contract, `verifyBatch` length
  mismatch, and the zero-input paths of `invMontgomery` / `invMontgomeryChecked`
  at M31 and BLS12-381 sizes.

### Added (verified present in `src/` as of this revision)

- `batchInv(inputs, outputs)` — batch inversion via Montgomery's trick
  (O(n) muls + 1 inv) on both `SmallField` and `BigField`
- `powFast(exp)` — non-constant-time exponentiation, on `SmallField`,
  `BigField`, `QuadraticExtension` and `CubicExtension`. **See the measured
  numbers below: the old "~2x faster" claim was wrong in both directions.**
- `sqr()` on both backends — currently a thin `self.mul(self)` wrapper
- `mulBy2` / `mulBy3` / `mulBy4` / `mulBy5` / `mulBy8` — multiplication by small
  constants (the previous changelog listed only 2/3/4/5)
- `toInt()` — canonical integer back out of a field element
- `eqCT()` / `isZeroCT()` — constant-time equality for secret data
- `zeroize()` — `*Self` secure memory wipe via `@memset(std.mem.asBytes(self), 0)`
- `fromBytesCT` / `fromIntCT` — return `{ value, valid }` for secret data
- `isNegative()` / `lexicographicCmp()` — canonical-form predicates, required by
  signature schemes and by `zig-linalg`'s pivoting
- `randomBounded(rnd, bound)` — unbiased bounded sampling for `SmallField`
  (`u64` bound) and `BigField` (`u512` bound)
- `batchAdd` / `batchSub` / `batchMul` — vectorised batch operations
- `multiExp()` — Pippenger-windowed multi-scalar exponentiation on both backends
- `batchInv`-adjacent `div`, `eql`, `eq`, `hash` on both field and extension types
- M61 predefined field (2^61 − 1, the largest Mersenne prime that fits in `u64`)
- StarkNet_Fp (2^251 + 17·2^192 + 1), Pallas_Fp and Vesta_Fp (Pasta cycle)
- `src/ntt.zig` — in-place Cooley–Tukey NTT/INTT, `precomputeTwiddles` /
  `freeTwiddles` / `nttWithTwiddles` / `inttWithTwiddles`
- `nttVec8M31()` / `inttVec8M31()` — 8-lane SIMD NTT for M31 via
  `@Vector(8, u64)` butterflies (exported as `Vec8NttM31` plus the two flat
  aliases)
- `M31.Vec8` SIMD backend — `addVec8`, `subVec8`, `mulVec8`, `reduceVec8`,
  `negVec8`, `ctSelectVec8`, `fromVec8U32`, `toVec8U32`, `fromSlice8`,
  `fromElements`. Only defined for Mersenne `BITS == 31`; every other field
  gets `Vec8 = void`, so the Vec8 helpers are not callable there.
- `frobenius()` — Frobenius automorphism (`a + b·v → a − b·v`) on
  `QuadraticExtension` only
- `EXT_NON_RESIDUE` and `NON_RESIDUE` on both `QuadraticExtension` and
  `CubicExtension`; `mulByNonResidue()` on `QuadraticExtension`
- Constant-time Montgomery primitives: `ctSelect`, `ctShr`, `ctLimbsCmpLt`
- `Ipa(F)` — Inner Product Argument over finite fields, exported as
  `Ipa` from `src/lib.zig`
- `MerkleTree(F)` — Merkle tree over field elements with SHA-256, inclusion
  proofs, and batch verification
- `tests/fuzz.zig` plus a `zig build fuzz` step

### Fixed

- **BigField `neg()` off-by-one** (BLS12_381_Fp): borrow propagation in
  Montgomery `sub()` changed from `borrow_from_diff + new_borrow` to
  `borrow_from_diff | new_borrow`, in the main limb-subtraction loop and in the
  four other limb loops plus `ctLimbsCmpLt`.
- **`ctShr` in-place aliasing**: the carry bit was read from an already
  overwritten limb, so bit 0 of limb `i+1` failed to propagate into bit 63 of
  limb `i`. This broke BLS12_381/BN254 inversion.
- **BigField `inv()`**: reimplemented on the binary extended GCD
  (`fromMontgomery` → `binaryGcdInverse` → `toMontgomery`), ~2·BITS iterations of
  limb add/sub/shift, replacing the temporary Fermat `a^(p−2)` fallback.
- **QuadraticExtension `mulByNonResidue`**: `c0`/`c1` were swapped, so it
  computed the wrong product; now correctly `a·n + b·n·v`.
- **QuadraticExtension `format`**: missing closing brace in debug output.
- **`multiExp` Pippenger window order**: squaring now happens *after* each
  window is processed, and the accumulator is reset per window.
- **SIMD Vec8 overflow**: `addVec8`, `subVec8` and `reduceVec8` were rewritten to
  use scalar per-lane comparisons instead of vector comparisons, removing the
  debug-mode integer-overflow panics.
- **SmallField `random`**: draws exactly `NUM_BYTES` bytes instead of a fixed 8,
  so M31/BabyBear/KoalaBear no longer waste entropy.
- **BigField `fromBytes`**: rejects non-canonical values `>= MODULUS` with
  `error.ValueOutOfRange`.
- **IPA `verifyWithCommitment`**: the verification equation now uses the round
  challenges `x_j` for the L/R terms
  (`Σ x_j²·L_j + Σ x_j⁻²·R_j`) and the position challenges `s_i` only for the
  final generators `G' = Σ s_i⁻¹·G_i`, `H' = Σ s_i·H_i`.

### Changed

- BigField `inv()` uses binary extended GCD instead of Fermat's little theorem.
- `binaryGcdInverse` is documented as input-dependent (not constant-time); it is
  appropriate for public STARK values, not secrets.
- BigField `neg`/`sqrt` tests are no longer gated on `NUM_LIMBS == 1`; the
  `BigField neg debug` scratch test was removed from `montgomery.zig`.
- The extension `primitiveRootOfUnity` test is limited to the fast path because
  Debug mode is too slow at high two-adicity.
- Edge-case tests cover `pow(x, 0)`, `pow(x, 1)`, `inv(1)`, `sqrt(0)`, `sqrt(1)`
  and "sqrt of a non-residue returns `null`" — for `SmallField`. `inv(0)` is
  now covered too: an earlier revision of this file said there was **no**
  `inv(0)` test because `inv` debug-asserted a non-zero input. That assertion is
  gone, so the test asserts the total behaviour (`inv(0) == zero()`) and the
  checked behaviour (`invChecked(0) == error.InverseOfZero`).
- **Removed from the changelog because they never existed in `src/`:**
  `fromIntStrict()`, `fromBytesBE()` and `toBytesBE()`. A repository-wide search
  finds these identifiers only in this file and in `TODO.md`; there is no
  declaration, no test, and no caller. Non-canonical input is rejected by
  `fromBytes`/`fromInt` themselves, and big-endian framing is left to the
  caller.
- **Moved out of this library:** the BN254 and BLS12-381 Fp6/Fp12 towers are
  implemented and exported by `zig-pairing` (`libs/pairing/src/tower.zig` via
  `bn254_tower.zig` / `bls12_381.zig`), not by `zig-field`. `zig-field` exports
  `BLS12_381_Fp2`, `BN254_Fp2`, `CM31` and `QM31` only.

### Build and CI

- `zig build test` runs 85 tests in this library (7 test binaries: inline `src/`
  tests 13, `field_test.zig` 47, `extension_test.zig` 10, `merkle_test.zig` 4,
  `ipa_test.zig` 2, `simd_test.zig` 7, `ext_quick.zig` 2). The root
  `zig build test` only compiles the inline `src/` tests, so it reports 13 for
  `zig-field` and 354 for the whole workspace.
- Additional steps: `zig build bench`, `zig build fuzz`, `zig build fmt`
  (`zig fmt --check build.zig libs examples bench scripts`, enforced in CI).
- **`zig build docs` is a no-op placeholder.** `build.zig` declares the step with
  the description "Build API documentation (not implemented)" and it depends on
  nothing. An earlier version of this file claimed it built API documentation.
- CI is GitHub Actions (`.github/workflows/test.yml`, `fuzz.yml`) with a
  composite setup action that downloads Zig **from ziglang.org**, pinned to
  `0.16.0`. It runs on `ubuntu-latest`, `macos-latest` and `windows-latest`,
  plus a scoped `zig fmt --check build.zig libs examples bench scripts`, a ReleaseFast smoke build, the benchmark (informational
  only, no regression thresholds), the STARK example, and the two wasm32
  smoke tests under Node. An earlier version of this file said the CI used
  "Codeberg-hosted Zig" and moved from Zig 0.13/0.14; neither is true of the
  current workflow.

---

## Benchmarks

### Method

- `cd libs/field && zig build bench -Doptimize=ReleaseFast`
- Clock: `std.c.clock_gettime(CLOCK_MONOTONIC)` on Linux/Apple/BSD/Haiku,
  `QueryPerformanceCounter` on Windows (see `tests/benchmark.zig`). The
  iteration divider is `@divTrunc`, not `@divExact`; an earlier version of this
  file said `@divExact`.
- Iterations: 100,000,000 for the small fields, 10,000,000 for the large ones
  (reduced from 500M).
- Machine for the numbers below: AMD Ryzen 7 5800H, Linux 6.8 x86_64, Zig
  0.16.0, `-Doptimize=ReleaseFast`. Treat them as indicative, not as thresholds.
  The CI benchmark job is explicitly informational.

### `zig build bench` output (5 runs, ns/op)

| Field | add | mul |
|-------|-----|-----|
| M31 | 1–2 | 1 |
| BabyBear | 0 | 1 |
| KoalaBear | 0 | 1 |
| Goldilocks | 0 | **0 — see below** |
| M61 | 1 | **0 — see below** |
| BN254_Fp | 88–100 | 238–272 |
| BLS12_381_Fp | 144–178 | 376–491 |
| StarkNet_Fp | 63–104 | 185–238 |
| Pallas_Fp | 71–97 | 205–279 |
| Vesta_Fp | 72–106 | 216–263 |

The small-field figures are at the resolution limit (100M iterations of an
O(1) operation lands around 100–300 ms total, i.e. 1–3 ns/op).

### Known benchmark defect: Goldilocks and M61 `mul`

Reproducible on every run: the `mul` loop of `bench()` reports a **total
elapsed time of 20–40 ns for 100,000,000 iterations**, which is impossible, so
the printed `+0 ns/op` for Goldilocks and M61 `mul` is meaningless. The
corresponding raw line looks like:

```text
  raw: add_elapsed=40 mul_elapsed=40
  Goldilocks: add     +0 ns/op  mul     +0 ns/op
```

Goldilocks `add_elapsed` is also unstable across runs (40 ns in some runs,
~125 ms in others). Both are the two non-Mersenne 64-bit `SmallField`s, whose
`mul` reduces with `wide % MODULUS` on a `u128`. A serial-dependency
measurement of the same operation, which cannot be eliminated, gives
Goldilocks `mul` ≈ 6 ns/op and M61 `mul` ≈ 3 ns/op (see below). Treat the
`zig build bench` Goldilocks/M61 cells as broken until the harness is fixed;
the values here are supplied from the serial measurement instead.

### Independent measurement, serial dependency chains

To defeat dead-code elimination, each operation's result feeds the next one.
These are **latency** figures, not throughput, so they are not comparable to
the table above; they are included because they are trustworthy for every
field. ReleaseFast, same machine, 20M iterations (2M for the big fields):

| Field | add (ns/op) | mul (ns/op) |
|-------|-------------|-------------|
| Goldilocks | 0 | 6 |
| M61 | 2 | 3 |
| M31 | 2 | 3–5 |
| BabyBear | 0 | 6 |
| KoalaBear | 0 | 6 |
| BN254_Fp | 100–104 | 183–199 |
| BLS12_381_Fp | 171–177 | 305–308 |
| StarkNet_Fp | 80–86 | 146–160 |
| Pallas_Fp | 91–104 | 165–178 |
| Vesta_Fp | 90–95 | 176–212 |

### `pow` vs `powFast`

The `powFast` docstring and `TODO.md` both claimed "~2x faster". Measured with
a varying ~32-bit exponent (so neither call can be hoisted), ReleaseFast:

| Field | `pow` (ns/op) | `powFast` (ns/op) | speed-up |
|-------|---------------|-------------------|----------|
| M31 | 149 | 311 | **0.48x (slower)** |
| BabyBear | 330 | 582 | **0.57x (slower)** |
| Goldilocks | 780 | 604 | 1.29x |
| BN254_Fp | 48,891 | 6,557 | **7.46x** |
| BLS12_381_Fp | 124,384 | 11,143 | **11.16x** |

So `powFast` is a large win for multi-limb fields and a regression for small
Mersenne fields, where the `ctSelect`-based `pow` is already cheap enough that
the extra branches cost more than they save. The "~2x" figure is wrong in both
directions. The stale comment
`/// Fast exponentiation (NOT constant-time). ~2x faster than `pow`.` is still
present in `src/field.zig` (lines 477 and 1084) and `src/extension.zig`
(lines 276 and 555) and is tracked in `TODO.md`; only the documentation here
has been corrected.

---

## [0.1.0] — 2026-08-19

### Added

- Generic `Field(comptime modulus)` factory with a dual backend:
  - Small fields (< 2^64): native `u64` with fast reduction; Mersenne primes
    (`2^k − 1`) use classic split reduction
  - Large fields (≥ 2^64): Montgomery arithmetic over `[N]u64` limbs using CIOS
    multiplication
- Extension towers `QuadraticExtension` and `CubicExtension`, plus the
  `CM31`, `QM31` and `BN254_Fp2` instances
- Predefined fields M31, BabyBear, KoalaBear, Goldilocks, BN254_Fp,
  BLS12_381_Fp
- Power-of-two roots of unity via quadratic non-residue search — no
  factorisation of `p − 1` required
- Tonelli–Shanks square roots and Legendre symbols
- Binary extended GCD inverse for small fields (documented as 10–50x faster
  than Fermat at the time; the big-field path was Fermat until the fix above)
- Constant-time Montgomery primitives (`ctSelect`, `ctShr`, `ctLimbsCmpLt`, …)
- Property-based tests against `u512`/`u1024` reference arithmetic
- Miller-Rabin primality validation in the `Field()` constructor (comptime), and
  non-residue validation for the extensions (Legendre = −1 for quadratic,
  cubic non-residue check)
- Benchmark suite with ReleaseFast

### Security

- Constant-time Montgomery arithmetic for big fields (CIOS algorithm)
- Montgomery form used internally for all big-field operations
- No independent cryptographic audit has been performed on this library

---

## License

MIT OR Apache-2.0
