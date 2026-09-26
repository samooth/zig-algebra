# zig-field Improvements Roadmap

Status as of this revision. `zig-field` is version **0.3.0**.

Each item was checked against `libs/field/src/`, `libs/field/tests/` and
`libs/field/build.zig`. Items marked **Phantom** were previously listed as
complete but have no declaration, no test and no caller anywhere in `src/`.

## Done

### Arithmetic

- [x] `batchInv` — batch inversion via Montgomery's trick (O(n) muls + 1 inv),
      both backends
- [x] `invChecked` / `divChecked` / `batchInvChecked` — typed errors
      (`error.InverseOfZero`, `error.DivisionByZero`, `error.LengthMismatch`) on
      both backends and both extension towers; the plain `inv` / `div` /
      `batchInv` stay as total legacy wrappers (`inv(0) == 0`, `x / 0 == 0`)
- [x] `powFast` — non-constant-time exponentiation, both backends and both
      extension towers
- [x] `toInt()` — field element back to a canonical integer
- [x] `sqr()` — present on both backends, but see *Open* below; it is
      `self.mul(self)`, not a dedicated squaring routine
- [x] `eqCT()` / `isZeroCT()` — constant-time equality for secret data
- [x] `zeroize()` — secure memory wipe for secret values
- [x] `mulBy2` / `mulBy3` / `mulBy4` / `mulBy5` / `mulBy8` — multiplication by
      small constants
- [x] `div`, `eq`, `eql`, `hash` on field and extension types
- [x] Constant-time serialization: `fromBytesCT` / `fromIntCT` returning
      `{ value, valid }`
- [x] `isNegative()` / `lexicographicCmp()` — canonical-form predicates
- [x] `batchAdd` / `batchSub` / `batchMul` — vectorised batch operations
- [x] `multiExp()` — Pippenger multi-scalar exponentiation, both backends
- [x] `randomBounded()` — unbiased bounded sampling, both backends
- [x] BigField `inv()` on the binary extended GCD (replaced the Fermat
      fallback)
- [x] BigField `neg()` borrow-propagation fix
- [x] `ctShr` in-place aliasing fix (it broke BLS12_381/BN254 inversion)
- [x] `QuadraticExtension.mulByNonResidue` component-swap fix
- [x] `QuadraticExtension.format` missing-brace fix
- [x] `multiExp` Pippenger window-order fix
- [x] SIMD Vec8 debug-mode overflow fix (`addVec8`, `subVec8`, `reduceVec8`)

### Fields and towers

- [x] M61 predefined field (2^61 − 1)
- [x] StarkNet_Fp (Cairo VM base field)
- [x] Pallas_Fp / Vesta_Fp (Pasta cycle)
- [x] `frobenius()` on `QuadraticExtension` (a + b·v → a − b·v)
- [x] `EXT_NON_RESIDUE` and `NON_RESIDUE` on `QuadraticExtension` and
      `CubicExtension`; `mulByNonResidue()` on `QuadraticExtension`
- [x] Non-canonical input rejection in `fromBytes` / `fromInt`

### Transforms and proofs building blocks

- [x] `src/ntt.zig` — in-place NTT/INTT, `precomputeTwiddles` / `freeTwiddles` /
      `nttWithTwiddles` / `inttWithTwiddles`
- [x] `nttVec8M31()` / `inttVec8M31()` — 8-lane SIMD NTT for M31, plus the
      `nttVec8M31Checked` / `inttVec8M31Checked` pair that enforces
      `data.len == 8 * 2^log_n` with `error.InvalidLength`
- [x] `M31.Vec8` SIMD backend with `addVec8` / `subVec8` / `mulVec8` /
      `reduceVec8` / `ctSelectVec8` / conversions
- [x] `MerkleTree(F)` — SHA-256 Merkle tree over field elements, inclusion proofs,
      batch verification
- [x] `Ipa(F)` — Inner Product Argument (Bulletproofs-style), with
      `verifyWithCommitment`

### Tooling

- [x] Edge-case tests: `pow(x, 0)`, `pow(x, 1)`, `inv(1)`, `sqrt(0)`,
      `sqrt(1)`, `sqrt(non-residue) == null`
- [x] Negative tests for the validation paths: `inv(0)`, division by zero,
      `batchInv` with zeros / mismatched lengths, `randomBounded(rnd, 0)`,
      `Vec8.fromSlice8` short/long slices, the M31 SIMD NTT length contract,
      `MerkleTree.verifyBatch` length mismatch
- [x] Fuzz harness (`tests/fuzz.zig`) and `zig build fuzz`
- [x] GitHub Actions CI on Linux / macOS / Windows, pinned to Zig 0.16.0
      downloaded from ziglang.org, with a scoped `zig fmt --check build.zig libs examples bench scripts` job
- [x] `zig build fmt` step

## Phantom — previously listed as done, never implemented

These identifiers appear **only** in `CHANGELOG.md` and this file. There is no
declaration in `src/`, no test in `tests/`, and no caller in the workspace.

- [x] ~~`fromIntStrict()` — Rejects values >= MODULUS~~ — **never existed.**
      `fromInt` already reduces, and `fromBytes` already returns
      `error.ValueOutOfRange` for `>= MODULUS`.
- [x] ~~`fromBytesBE()` / `toBytesBE()` — Big-endian serialization~~ — **never
      existed.** All serialisation in this library is little-endian
      `toBytes`/`fromBytes`; big-endian framing is left to the caller.
- [x] ~~`BigField.toBytes()` — Serialize Montgomery form back to bytes~~ —
      `BigField.toBytes()` does exist (`src/field.zig:872`); it was already
      covered by the 0.1.0 serialization entry, so it is listed as done rather
      than as a new item.
- [x] ~~CI/CD GitHub Actions (Linux/macOS/Windows, zig 0.13 + master)~~ — the CI
      exists but pins **Zig 0.16.0** only; `master` is not exercised. Corrected
      above.
- [x] ~~`build.zig` docs step (`zig build docs`)~~ — the **step** exists, but it
      is a declared no-op: `build.zig:152` describes it as
      "Build API documentation (not implemented)" and it depends on nothing. It
      does not produce documentation.
- [x] ~~BN254_Fp6 / BN254_Fp12 — full tower extensions~~ and
      ~~BLS12_381_Fp6 / BLS12_381_Fp12~~ — **not in this library.** The Fp6/Fp12
      towers live in `zig-pairing` (`libs/pairing/src/tower.zig`, used by
      `bn254_tower.zig` and `bls12_381.zig`). `zig-field` exports
      `BLS12_381_Fp2`, `BN254_Fp2`, `CM31` and `QM31` only.

## Open

Ordered roughly by value per unit of effort.

- [ ] **Fix the `zig build bench` harness.** For the two non-Mersenne 64-bit
      `SmallField`s (Goldilocks, M61) the `mul` loop reports 20–40 ns total for
      100M iterations, i.e. `0 ns/op`, and Goldilocks' `add_elapsed` swings
      between 40 ns and ~125 ms across runs. The printed numbers for those two
      fields are unusable; the per-field values in `CHANGELOG.md` come from a
      serial-dependency harness instead. See the Benchmarks section there.
- [ ] **Real `sqr()`.** `sqr()` is `self.mul(self)` on both backends. A CIOS
      squaring (saving the `a*b` cross term) should land around 30% on
      `BigField`; nothing has been measured yet, so the old "~30% faster" claim
      was removed rather than kept.
- [ ] **Correct the `powFast` docstrings.** All four copies say
      "~2x faster than `pow`" (`src/field.zig:477`, `src/field.zig:1084`,
      `src/extension.zig:276`, `src/extension.zig:555`). Measured: 7.5x on
      BN254_Fp, 11.2x on BLS12_381_Fp, 1.3x on Goldilocks, and a **1.5–2x
      regression** on M31 and BabyBear. The claim should also warn about the
      small-Mersenne regression.
- [ ] **Fix the `format` method signature.** `field.zig:591`, `field.zig:1210`
      and the two in `extension.zig` all declare
      `options: std.fmt.FormatOptions`, which was removed in Zig 0.16. The
      methods are dead: `{}` on a field element falls back to default struct
      printing, e.g. `M31.fromInt(7)` prints `.{ .value = 7 }` rather than `7`.
      `zig-bigint`'s `BigInt.format` and `zig-linalg`'s `Vector`/`Matrix.format`
      have the same problem.
- [ ] **Implement `Ipa.verify`.** `src/ipa.zig:221` is a stub that returns
      `error.Unsupported`; only `verifyWithCommitment` works. Related: IPA round
      challenges are a local SHA-256 of `(L, R, round)`, not a
      `zig-transcript` Fiat–Shamir session, so the IPA proof is not bound to any
      protocol statement.
- [ ] **`frobenius()` on `CubicExtension`.** Only the quadratic tower has it.
- [ ] **`mulByNonResidue()` on `CubicExtension`.** Only the quadratic tower has
      it.
- [ ] **`Vec8` outside M31.** `Vec8` is `void` for every field that is not
      Mersenne with `BITS == 31`, so the Vec8 helpers cannot be reused for
      Goldilocks or the big fields. Either generalise the lane type or make the
      `void` case a compile error instead of a silently uncallable stub.
- [ ] **More extension tests.** `extension_test.zig` has 10 tests;
      `ext_quick.zig` has 2. The `primitiveRootOfUnity` test is limited to the
      fast path because Debug mode is too slow at high two-adicity, so extension
      roots of unity are under-covered.
- [ ] **BigField coverage in the property tests.** `tests/fuzz.zig` exists but
      the big-field paths are exercised on fewer predefined fields than the
      small-field ones.
- [ ] **Fuzzing integration beyond the in-repo harness.** There is no
      `zig-afl` integration; the current `zig build fuzz` is a fixed-seed
      property runner, not a coverage-guided fuzzer.
- [ ] **Formal verification of the Montgomery CIOS multiplication.** Still
      unproven; correctness currently rests on property tests against
      `u512`/`u1024` reference arithmetic.
- [ ] **Constant-time inversion.** `binaryGcdInverse` and `SmallField.inv` are
      both input-dependent. Safe for public STARK values, not for secrets.
- [ ] **GPU backend (CUDA / OpenCL) for batch operations.** Not started.
- [ ] **WASM target tuning.** `zig build wasm` builds and passes the Node smoke
      test, but there is no performance work on the freestanding target.
- [ ] **Constant-time batch inversion.** `batchInv` is now total instead of
      asserting, but its accumulator is a running product and the whole batch
      still costs one binary-GCD inverse, so the function remains
      input-dependent and is not usable on secret data as written.
      `batchInvChecked` is the API to call when a zero input must be an error.

## Not in scope for this library

- Pairings (Miller loop, final exponentiation) — `zig-pairing`
- KZG polynomial commitments — `zig-kzg`
- FRI prover/verifier — `zig-fri`
- Merkle trees over raw bytes — `zig-merkle`
- The binary-field PCS / sum-check stack — `zig-binary-field`
- Transcripts — `zig-transcript`
