# Changelog

All notable changes to zig-algebra are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/) (0.x: MINOR may carry breaking changes).

## [Unreleased]

### Security (P0 class: asserted preconditions)

The preconditions of several public entry points were expressed as
`std.debug.assert`, which Zig compiles out in `ReleaseFast`/`ReleaseSmall`. A
violating input therefore panicked in Debug/ReleaseSafe and, in a release
build, hung, read/wrote out of bounds, or silently produced a wrong result.
All of these are now typed errors, with total legacy wrappers kept only where a
signature could not change. `SECURITY.md` records the full advisory as
**ZA-2026-002**; the highlights:

- **field** (0.2.0 → **0.3.0**): added `invChecked` (`error.InverseOfZero`),
  `divChecked` (`error.DivisionByZero`) and `batchInvChecked`
  (`error.LengthMismatch` / `error.InverseOfZero`) on `SmallField`, `BigField`,
  `QuadraticExtension` and `CubicExtension`, plus Montgomery's
  `invMontgomeryChecked`. **BREAKING in behaviour:** `inv`, `inverse` and `div`
  are total — `inv(0) == zero()` and `x / 0 == zero()` — where they previously
  asserted (Debug/ReleaseSafe) or spun forever in the binary-GCD loop
  (ReleaseFast). `randomBounded(rnd, 0)` returns zero instead of hanging,
  `Vec8.fromSlice8` zero-fills/truncates instead of reading past the slice,
  `MerkleTree(F).verifyBatch` fails closed on a length mismatch, and
  `nttVec8M31Checked` / `inttVec8M31Checked` report
  `error.InvalidLength` (the unchecked pair is now a no-op on a mismatch).
- **binary-field** (0.2.0 → **0.3.0**): `invChecked` on `BinaryField` and
  `TowerField` (`error.InverseOfZero`; the GF(2) base case also rejects a
  non-unit). `Multilinear.numVarsChecked` (`error.NotPowerOfTwo`) with `eval` /
  `extend` returning `error.InvalidPointLength`; `PackedMle` gained `MAX_K` and
  `checkK` and now returns `error.InvalidDimension` / `error.LengthMismatch`
  (`betaOnHChecked` likewise), and `novelEval` validates `k` and the coefficient
  length. **BREAKING:** `Sumcheck(F)` now requires `F.BITS >= 128` and returns
  `error.FieldTooSmall`; `MlePcs(F, E)` and `CommittedMlePcs(F, E)` apply the
  same check to their challenge field `E`. The
  new `SumcheckUnsafe`, `MlePcsUnsafe` and `CommittedMlePcsUnsafe` bypass it to
  keep the historical 4-bit on-chain challenge format — they are **toy/test
  only and not sound against a grinding prover**, and the library's own small
  field tests were switched to them.
- **merkle** (0.1.1 → **0.1.2**): `MMR.verify` shape-checks the proof before
  indexing it — the sibling and flag arrays must have equal length, and the
  depth must match the zero-padded tree (`2^ceil(log2(leaf_count))`) with the
  index below it. A proof whose two halves disagreed in length previously
  caused an out-of-bounds read of `is_left_sibling`.
- **rng** (0.2.0 → **0.3.0**): added `setEntropyChecked`
  (`error.EntropyTooLong` / `error.InsufficientEntropy`) and
  `entropyAvailable`. Legacy `setEntropy` now truncates to the 64-byte host
  buffer and zero-fills the tail instead of overflowing it; the host buffer is
  zero-initialised and a seed request longer than the injected entropy is
  refused rather than copying uninitialised memory. Added
  `setRandomForTestingSeed(?u64)`, whose state lives in the module;
  `setRandomForTesting` now stores a copy of the `std.Random` interface value
  and must be reset with `defer setRandomForTesting(null)` (the previous
  pointer form could outlive the caller's generator). `src/root.zig` added
  `refAllDecls`, without which the `csprng` tests were never collected.
- **serialization** (0.1.1 → **0.2.0**): `deserialize` treats its input as
  untrusted. A `u64` length prefix is validated against the bytes that remain
  and the per-element minimum wire size before anything is allocated
  (`error.InvalidLength`), and a failure part-way through rolls back every
  value already decoded, so a rejected input no longer leaks. **BREAKING:**
  `error.InvalidLength` is a new error in the inferred error set, and
  `error.TrailingBytes` now releases the decoded value through a path that does
  not depend on `deinit` being `pub`.
- **curve** (0.3.0 → **0.4.0**): `hashToPoint` returns
  `error{ DomainTooLong, NoValidPoint }!Point` and `generatorVector` returns
  `(DeriveError || std.mem.Allocator.Error)![]Point`, freeing its allocation
  when a derivation fails. The `catch unreachable` on the 64-byte label buffer
  and the `unreachable` on an exhausted try-and-increment search are gone; the
  domain limits are exported as `max_domain_len` and
  `max_generator_vector_domain_len`. **BREAKING:** both functions are error
  unions now, so existing `const p = hashToPoint(...)` call sites need `try`.

### Versioning

- Root `build.zig.zon` is now **`0.4.0`** (was `0.3.2`); every library keeps
  its own independent semver in `libs/<name>/build.zig.zon`. The manifests
  bumped for this release are `field` `0.3.0`, `binary-field` `0.3.0`,
  `merkle` `0.1.2`, `rng` `0.3.0`, `serialization` `0.2.0` and `curve`
  `0.4.0`; every other manifest is unchanged, so the per-library range is
  `0.1.0` (`transcript`) to `0.4.0` (`curve`).

### Docs
- Documentation pass so every top-level document matches the current tree.
  Historical entries are retained, with factual corrections noted here.
- **Test counts.** The root `zig build test` step runs **354 tests** (verified
  on Zig 0.16.0 in both Debug and ReleaseFast); per-library `zig build test`
  steps sum to 470 because `field` (85) and `curve` (96) also compile their
  separate `tests/` roots. Older documents quoted 222, 297 and 316; the 297
  figure in `SECURITY.md` was accurate for the suite as it stood when advisory
  ZA-2026-001 was fixed and is kept there as history. Per-library totals:
  algebra-traits 0, bigint 18, binary-field 76, curve 96, field 85, fri 10,
  hash 17, kzg 6, linalg 9, merkle 18, ntt 11, pairing 54, parallel 2, poly 20,
  rng 23, serialization 15, transcript 10.
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
- **Validation contract documented.** `README.md` gained a table pairing each
  legacy total wrapper with its `…Checked` sibling, and every document now
  states that `inv(0) == 0` is a source-compatibility result, not a valid
  inverse, and that `SumcheckUnsafe` / `MlePcsUnsafe` / `CommittedMlePcsUnsafe`
  are unsound.
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
- **Stale `inv(0)` statements removed.** `libs/field/CHANGELOG.md` and
  `libs/field/TODO.md` claimed there was no `inv(0)` test because `inv`
  debug-asserted; both now describe the total legacy behaviour and the checked
  API.

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
