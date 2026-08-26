# Changelog

All notable changes to zig-algebra are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/) (0.x: MINOR may carry breaking changes).

## [Unreleased]

### Fixed
- **wasm**: `fp_add` ignored its `b_lo`/`b_hi` arguments; now composes both
  128-bit operands correctly (matching `fp_mul`). CI gained value tests for
  `fp_add` (carry + hi-word cases) and a known-answer test for `fp_inv`.
- **portability**: replaced Linux-only `std.os.linux.clock_gettime` timing in
  `examples/stark_prover.zig`, `examples/schnorr_signature.zig` and
  `libs/pairing/src/bench.zig` with the new portable `zig-parallel`
  `timing.nowNs()` (QPC on Windows, `clock_gettime(CLOCK_MONOTONIC)` via libc,
  raw syscall on bare-metal Linux).
- **curve**: fixed latent `mulBy8` compile error for Fp2-based projective
  points (exposed when G2 scalar multiplication moved to the projective ladder).
- **pairing**: `pairingSparse` was not bilinear-equivalent to the dense
  reference — the accumulator skipped ALL Miller squarings and chord lines
  had inverted w-slot signs. Both fixed with direct sparse==dense,
  bilinearity and random-pair equality tests. The earlier "sign asymmetry"
  hypothesis in DESIGN.md was incorrect and has been removed.
- **testing**: `pairing()` had silently routed to `pairingDense`, so no test
  exercised `pairingSparse` at all (same blind-spot pattern as the wasm bug).

### Changed
- **pairing**: production `pairing()` now uses the verified sparse twist-side
  loop with split final exponentiation: ~17 ms vs ~30 ms dense (1.8x);
  still validated against EIP-197 known-answer vectors.

### Changed (BREAKING)
- **kzg**: `commit` and the internal MSM now take a caller-supplied allocator;
  allocation errors are propagated instead of `catch unreachable`.
- **curve**: `scalarMul` on affine/projective Weierstrass points now uses a
  4-bit windowed left-to-right ladder in Jacobian coordinates (~8x faster;
  O(1) field inversions instead of one per addition). Still non-CT.
- **fri**: layer commitments now use the shared `zig-merkle` tree instead of a
  private duplicate (`zig-fri` gains a `zig-merkle` dependency edge).
- CI: test matrix now includes `windows-latest`.

## [v0.2.2] — 2026-08-26

### Added
- **kzg** (18th library): KZG polynomial commitments over BN254 — synthetic
  setup, commit/prove/verify against the verified optimal ate pairing and
  Pippenger MSM.
- **curve**: generic multi-scalar multiplication (naive + Pippenger with
  adaptive windows), plus latent curve fixes.

### Fixed / Tested
- **pairing**: known-answer vectors against py_ecc (EIP-197 reference).

## [v0.2.1] — 2026-08-25

### Added
- **wasm**: BN254 pairing module for JS/TS interop (`wasm-pairing` build step).

### Performance
- **pairing**: BLS12-381 split final exponentiation resurrected and verified
  (~32 ms steady-state optimal ate pairing).

### Docs
- DESIGN.md: BLS12-381 final-exponentiation notes; stage-anchoring pattern.

## [v0.2.0] — 2026-08-25

Performance and correctness pass across the pairing tower:
BN254 optimal ate via Fp6/Fp12 tower, dense py_ecc-faithful reference path,
cyclotomic compressed squaring, windowed final exponentiation, and the
STARK example stack (transcript → FRI) hardening.

## [v0.1.0] — initial release

14 libraries: algebra-traits, bigint, hash, rng, field, binary-field, curve,
pairing, merkle, ntt, poly, linalg, parallel, serialization — plus transcript
and fri building blocks, examples and benchmarks.
