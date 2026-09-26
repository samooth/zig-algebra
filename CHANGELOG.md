# Changelog

All notable changes to zig-algebra are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/) (0.x: MINOR may carry breaking changes).

## [Unreleased]

### Docs
- Documentation pass so every top-level document matches the current tree.
  Historical entries are retained, with factual corrections noted here.
- **Test counts.** The root `zig build test` step runs **316 tests** (verified
  on Zig 0.16.0 in both Debug and ReleaseFast); per-library `zig build test`
  steps sum to 419 because `field` (70) and `curve` (92) also compile their
  separate `tests/` roots. Older documents quoted 222 and 297; the 297 figure
  in `SECURITY.md` was accurate for the suite as it stood when advisory
  ZA-2026-001 was fixed and is kept there as history.
- **Library counts.** The workspace has 17 libraries. `kzg` is the 17th
  (added in v0.2.2); v0.1.0 shipped 14 libraries and v0.2.0 brought the total
  to 16 with `fri` and `transcript`.
- **IPA is a `zig-field` module, not a library.** The v0.3.2 "ipa" bullets
  refer to `libs/field/src/ipa.zig`. `Ipa.verify` is still a stub
  (`error.Unsupported`); the working path is `Ipa.verifyWithCommitment`, whose
  commitment is the inner-product commitment `C = <a,G> + <b,H> + c·U` (not a
  Merkle commitment), and its challenges are a local SHA-256 of `(L, R, round)`
  rather than a `zig-transcript` Fiat-Shamir session. The module is now listed
  under Known Limitations in `README.md` and Scope in `SECURITY.md`.
- **Feature lists corrected** to the code that exists: `zig-ntt` is radix-2
  power-of-two only (no mixed-radix, 2-D, batch or SIMD; the M31 `Vec8` NTT is
  in `zig-field`), `zig-poly` has schoolbook multiplication with no
  Karatsuba/FFT/GCD, and `zig-merkle` has binary/MMR/sparse trees with
  inclusion and non-membership proofs and proof serialization, but no Verkle
  tree or batch updates.
- **Dependency graphs** in `README.md`, `DESIGN.md` and `docs/architecture.md`
  now match the imports wired in the root `build.zig` and in each
  `libs/*/build.zig.zon` (notably `binary-field → merkle`, `fri → field`,
  `merkle → algebra-traits`, `kzg → field, curve, pairing`).
- **Memory claims softened.** There is no global "zero allocation" guarantee:
  fixed-size types stay on the stack, while the proof stack (`fri`, `kzg`,
  `Ipa`) and the Merkle/PCS/twiddle paths take a caller-supplied allocator and
  propagate `error.OutOfMemory`.
- **`zig build wasm` is implemented** (as is `zig build wasm-pairing`); the
  claim in `DESIGN.md` that the build target was pending is removed.
- **Benchmarks are labelled indicative** with the machine they were measured
  on; CI stores them as an artifact without regression thresholds.
- **No independent audit** is now stated in `README.md`, `SECURITY.md`,
  `DESIGN.md`, `docs/architecture.md` and `AGENTS.md`; the "production
  candidate" label means test-covered, not audited.
- **STARK demo field corrected** to Goldilocks (`examples/stark_prover.zig`) in
  `AGENTS.md` and in the `.github/workflows/test.yml` step name; the demo has
  used Goldilocks since it was introduced.

### Versioning

- Root `build.zig.zon` carries the workspace version (`0.3.2`); every library
  keeps its own independent semver in `libs/<name>/build.zig.zon`, currently
  between `0.1.0` (`transcript`) and `0.3.0` (`curve`, `pairing`). Library
  versions bump for API changes, the workspace version for ecosystem-level
  releases.

## [v0.3.2] — 2026-09-25

### Added
- **field/hash**: RFC 9380 `expand_message_xmd`, `hashToField` and
  cofactor-aware `hashToCurve` APIs, with seed-length validation.
- **ipa**: algebraic verification of the inner-product commitment through
  `verifyWithCommitment` (not a Merkle commitment).
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
- **kzg** (17th library): KZG polynomial commitments over BN254 — synthetic
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
pairing, merkle, ntt, poly, linalg, parallel, serialization — plus examples and
benchmarks.
