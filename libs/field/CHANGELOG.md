# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `batchInv()` — Batch inversion via Montgomery's trick (O(n) muls + 1 inv)
- **Cross-platform monotonic clock for benchmarks** — Uses `clock_gettime(CLOCK_MONOTONIC)` on Linux/macOS/BSD and `QueryPerformanceCounter` on Windows
- **Fixed `multiExp` Pippenger algorithm** — Corrected window processing order (squaring after window processing, accumulator reset per window)
- **Fixed IPA `verifyWithCommitment`** — Uses round challenges `x_j` for L/R terms, position challenges `s_i` only for final generator reconstruction
- **Fixed SIMD Vec8 arithmetic** — Rewrote `addVec8`, `subVec8`, `reduceVec8` to use scalar operations for comparisons, fixing integer overflow in debug mode
- **CI updated to Zig 0.16.0** — Using Codeberg-hosted Zig

### Fixed
- **SIMD Vec8 integer overflow** — Fixed `addVec8`, `subVec8`, `reduceVec8` by replacing vector comparisons with scalar per-lane operations, eliminating debug-mode overflow panics
- **`multiExp` algorithm** — Fixed window processing order: squaring now happens AFTER processing each window (not before), accumulator reset per window
- **IPA `verifyWithCommitment`** — Corrected verification equation to use round challenges `x_j` for L/R terms (`sum(x_j^2 * L_j) + sum(x_j^{-2} * R_j)`) and position challenges `s_i` only for final generators `G' = sum(s_i^{-1} * G_i)`, `H' = sum(s_i * H_i)`

### Changed
- Benchmark suite uses cross-platform monotonic clock (`clock_gettime` / `QueryPerformanceCounter`)
- Reduced small field benchmark iterations from 500M to 100M to avoid timing overflow
- CI updated from Zig 0.13.0/0.14.0 to 0.16.0 (Codeberg-hosted)
- All commits GPG signed with EDDSA key B59CBA1AED05C03737146912E791C5B7A60B5A80
- `powFast()` — Non-constant-time exponentiation (~2x faster for public exponents)
- `sqr()` — Dedicated squaring (placeholder for future CIOS optimization)
- `mulBy2/3/4/5()` — Multiply by small constants (common in constraint polynomials)
- `fromIntStrict()` — Rejects values >= MODULUS (catches bugs early)
- `toInt()` — Convert field element back to canonical integer
- `toBytesBE()` / `fromBytesBE()` — Big-endian serialization
- `eqCT()` / `isZeroCT()` — Constant-time equality for secret data
- `zeroize()` — Secure memory wipe for secret values
- M61 predefined field (2^61 - 1, largest Mersenne prime in u64)
- `powFast()` on QuadraticExtension and CubicExtension
- Edge-case tests (fromInt(0), pow(x,0), inv(1), sqrt(0), batchInv, etc.)
- GitHub Actions CI/CD (Linux, macOS, Windows)
- `zig build docs` step for API documentation
- **NTT/INTT native module** (`src/ntt.zig`) — Cooley-Tukey iterative in-place NTT/INTT for any prime field with sufficient 2-adicity
- `precomputeTwiddles()` / `freeTwiddles()` / `nttWithTwiddles()` — precomputed twiddle factors for repeated transforms
- `nttVec8M31()` / `inttVec8M31()` — 8-lane SIMD NTT using Vec8 butterflies (process 8 transforms in parallel)
- `frobenius()` — Frobenius automorphism for QuadraticExtension (a + b*v → a - b*v)
- `batchAdd()` / `batchSub()` / `batchMul()` — Vectorized batch operations for STARK trace columns
- `randomBounded()` — Unbiased random sampling within `[0, bound)` for SmallField and BigField
- `isNegative()` / `lexicographicCmp()` — Canonical form predicates for signature schemes
- `BN254_Fp6` / `BN254_Fp12` — Full tower extensions for BN254 pairings
- `Ipa(F)` — Inner Product Argument (Bulletproofs-style) over finite fields: prove `<a, b> = c` without revealing vectors
- `MerkleTree(F)` — Merkle tree over finite field elements with SHA-256, inclusion proofs, and batch verification
- `BLS12_381_Fp6` / `BLS12_381_Fp12` — Full tower extensions for BLS12-381 pairings
- `StarkNet_Fp` predefined field (Cairo VM base field: 2^251 + 17*2^192 + 1)
- `Pallas_Fp` / `Vesta_Fp` predefined fields (Pasta cycle for recursive SNARKs / Halo2)
- `multiExp()` — Multi-scalar exponentiation (Pippenger windowed algorithm) for SmallField and BigField
- **Vec8 SIMD backend for M31** — 8-lane `@Vector(8, u64)` arithmetic with per-lane Mersenne reduction (`addVec8`, `subVec8`, `mulVec8`, `reduceVec8`), conversions (`fromVec8U32`, `toVec8U32`, `fromSlice8`, `fromElements`, `negVec8`, `ctSelectVec8`), matching zig-stark's `@Vector(8, u32)` lane layout
- **EXT_NON_RESIDUE** on QuadraticExtension (`v` where `v^2 = NON_RESIDUE`) and CubicExtension (`v` where `v^3 = NON_RESIDUE`)
- **NON_RESIDUE** exposed on both QuadraticExtension and CubicExtension (base-field non-residue)
- **Constant-time serialization**: `fromBytesCT` / `fromIntCT` return `{ value, valid }` for secret data; `fromBytes` / `fromInt` validate non-canonical inputs
- `div()`, `eql()`, `format()`, `hash()` on all field and extension types
- `mulByNonResidue()` for quadratic extensions (fixed swapped components bug)
- `div()`, `format()`, `hash()` for cubic extensions
- Miller-Rabin primality test in `Field()` constructor (comptime)
- Non-residue validation in extensions (Legendre == -1 for quadratic, cubic non-residue check)
- Fuzz harness (`tests/fuzz.zig`) with property tests for all fields/extensions
- `zig build fuzz` step in build.zig

### Fixed
- **BigField neg() off-by-1 bug** (BLS12_381_Fp): fixed borrow propagation in
  Montgomery `sub()` by changing `borrow = borrow_from_diff + new_borrow` to
  `borrow = borrow_from_diff | new_borrow` (also applied to the four other
  limb-subtraction loops and `ctLimbsCmpLt`).
- **`ctShr` in-place aliasing**: the carry bit was read from an already
  overwritten limb, corrupting multi-limb right shifts (bit 0 of limb `i+1`
  failed to propagate into bit 63 of limb `i`). Broke BLS12_381/BN254 inverse.
- **BigField inverse**: reimplemented on the binary extended GCD algorithm
  (`Mont.invMontgomery` = `fromMontgomery` → `binaryGcdInverse` →
  `toMontgomery`). Replaces the temporary Fermat `a^(p-2)` fallback with
  ~2·BITS iterations of limb add/sub/shift.
- **QuadraticExtension `mulByNonResidue`**: swapped `c0`/`c1` components, fixed
  to correctly compute `a·n + b·n·v`.
- **QuadraticExtension `format`**: missing closing brace in debug output.
- **BigField `fromBytes`**: now rejects non-canonical values `>= MODULUS` with
  `error.ValueOutOfRange`.
- **SmallField `random`**: now uses exact `NUM_BYTES` instead of fixed 8 bytes,
  avoiding entropy waste for small fields (M31, BabyBear, KoalaBear).
- **`binaryGcdInverse`**: documented that iteration count is input-dependent
  (not constant-time), suitable for public values in STARKs.

### Changed
- BigField `inv()` uses binary extended GCD instead of Fermat's little theorem.
- Benchmark suite uses `std.os.linux.clock_gettime` for timing and `@divExact`
  for i128 division in ReleaseFast.
- BigField `neg`/`sqrt` tests re-enabled (no longer gated on `NUM_LIMBS == 1`).
- Removed debug test `BigField neg debug` from montgomery.zig.
- Extension `primitiveRootOfUnity` test limited to fast path (Debug mode too slow for high two-adicity).

## [0.1.0] - 2026-08-19

### Added
- Generic `Field(comptime modulus)` factory with dual backend:
  - Small fields (< 2^64): native `u64` with fast reduction; Mersenne primes
    (`2^k - 1`) use classic split reduction
  - Large fields (≥ 2^64): Montgomery arithmetic over `[N]u64` limbs using CIOS
    multiplication
- Extension towers: `QuadraticExtension` and `CubicExtension`
- Predefined fields: M31, BabyBear, KoalaBear, Goldilocks, BN254_Fp, BLS12_381_Fp
- Extension towers: CM31, QM31, BN254_Fp2 (matching zig-stark semantics)
- Power-of-two roots of unity via quadratic non-residue search
- Tonelli–Shanks square roots and Legendre symbols
- Binary extended GCD inverse for small fields (10-50x faster than Fermat)
- Constant-time Montgomery primitives (ctSelect, ctShr, ctLimbsCmpLt, etc.)
- Property-based tests against u512/u1024 reference arithmetic
- Benchmark suite with ReleaseFast

### Security
- Constant-time Montgomery arithmetic for big fields (CIOS algorithm)
- Montgomery form used internally for all big field operations