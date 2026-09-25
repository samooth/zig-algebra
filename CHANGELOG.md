# Changelog

All notable changes to zig-algebra are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/) (0.x: MINOR may carry breaking changes).

## [Unreleased]

## [v0.3.2] — 2026-09-25

### Added
- **field/hash**: RFC 9380 `expand_message_xmd`, `hashToField` and
  cofactor-aware `hashToCurve` APIs, with seed-length validation.
- **ipa**: algebraic verification of Merkle commitments through
  `verifyWithCommitment`.
- **rng**: SHAKE256 sampling, Windows `BCryptGenRandom` entropy and serialized
  CSPRNG test hooks.
- **testing**: canonical BLS12-381 generators plus known-answer coverage for
  field, Blake3, Blake2, Keccak/SHA3, Poseidon, MiMC and M31 values.

### Fixed
- **fri**: added transcript path validation and Merkle-shape, degree, leaf,
  sibling and query checks; hardened KZG, BigInt, NTT, field, Poseidon and
  Merkle arithmetic and OOM cleanup.
- **proof stack**: Sumcheck and PCS entry points now validate arity, lengths and
  points; allocation-error paths release owned storage, including Merkle proofs.
- **wasm**: `fp_add` ignored its `b_lo`/`b_hi` arguments; now composes both
  128-bit operands correctly (matching `fp_mul`). CI gained value tests for
  `fp_add` (carry + hi-word cases) and a known-answer test for `fp_inv`.
- **portability**: replaced Linux-only timing with `zig-parallel`'s portable
  `timing.nowNs()` across examples and pairing benchmarks.
- **pairing**: corrected sparse Miller-loop squarings and chord-line signs;
  added sparse/dense, bilinearity and EIP-197 regression coverage.
- **input safety**: rejected low-order pairing points and invalid algebraic
  hash seeds; wide-field sampling now preserves rejection-sampling uniformity.
- **field**: removed data-dependent branches from Montgomery reduction and
  clarified the non-constant-time status of square roots and scalar
  multiplication.

### Changed
- **pairing**: BN254's tower implementation is canonical, and production
  `pairing()` uses the verified sparse twist-side loop with split final
  exponentiation (~17 ms versus ~30 ms dense).
- **rng**: rejection sampling returns typed range errors and is bounded by a
  fixed attempt limit.
- **examples/build**: updated Zig 0.16 output/import APIs, wired missing module
  dependencies and targets, and made the root ReleaseFast test step execute the
  full test suite.
- CI coverage now includes Windows and expanded wasm value tests.

### Changed (BREAKING)
- **kzg**: `commit` and the internal MSM now take a caller-supplied allocator;
  allocation errors are propagated instead of `catch unreachable`.
- **curve**: `scalarMul` on affine/projective Weierstrass points now uses a
  4-bit windowed left-to-right ladder in Jacobian coordinates (~8x faster;
  O(1) field inversions instead of one per addition). Still non-CT.
- **fri**: layer commitments now use the shared `zig-merkle` tree instead of a
  private duplicate (`zig-fri` gains a `zig-merkle` dependency edge).

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
