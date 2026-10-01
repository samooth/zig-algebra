# zig-field Improvements Roadmap

Status as of this revision. `zig-field` is version **0.5.0**.

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

- [x] in-place NTT/INTT, `precomputeTwiddles` / `freeTwiddles` /
      `nttWithTwiddles` / `inttWithTwiddles` — the generic transform lives in
      `zig-ntt`; the unreferenced local `src/ntt.zig` duplicate was removed in
      `0.4.0` and only the M31 `Vec8` entry points remain here
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
- [x] **Correct the `powFast` docstrings.** Done 2026-10-01. All four copies said
      "~2x faster than `pow`", which was wrong in three ways at once: the ratio is
      field-dependent, the sign is inverted on the small Mersenne primes, and on
      two fields there is no difference to report. `zig build pow-bench` now
      measures it per field as the minimum of seven repetitions and prints
      powFast/pow, where **greater than one means slower** — the reading that
      inverts the old claim. Measured: `powFast` is ~1.1-1.2x slower on M31,
      BabyBear and M61, indistinguishable from parity on Goldilocks, and
      ~1.25-1.35x faster on BN254_Fp, BLS12_381_Fp and StarkNet_Fp. So the dual
      API's bargain is real on large fields and what falls is its universality,
      not the API. Why the ratio is field-dependent is a hypothesis about the
      code, recorded in the benchmark's header and not here as a finding.
      Two measurements of this disagreed on M61 and on the size of the large-field
      win, so the docstrings carry the direction and the range, not a number.
- [x] **Fix the `format` method signature.** Done in 0.4.0: `field.zig` (both
      backends) and `extension.zig` (both towers), plus `zig-bigint`,
      `zig-linalg`, `zig-poly`, `zig-pairing` and `zig-algebra-traits`, all use
      `fn (self, writer: *std.Io.Writer) std.Io.Writer.Error!void`. Note the
      remaining half of the problem is the *call site*, not the method: Zig
      0.16 only selects a `format` method for the `{f}` specifier, so
      `std.debug.print("{}", .{M31.fromInt(7)})` still prints
      `.{ .value = 7 }` while `"{f}"` prints `7`. The `[x]` above covers the
      method only; the *call-site* sweep is still open. Re-checked 2026-10-01
      over the whole tree, and it is not clean: six remain in this library's
      own tests, inside `if (DEBUG_MULTIEXP)` blocks that never run
      (`tests/field_test.zig:13` sets it `false`) —
      `tests/field_test.zig:608`, `:609`, `:630`, `:631`, `:668` and `:669`
      print `multi_result` and `expected`, and both are field elements, not
      integers (`multiExp` returns `error{LengthMismatch}!Self`; `expected`
      starts at `F.one()`). Outside `libs/field` the sweep is open too:
      `zig-pairing` prints `Fp12`/`Fp12T` elements (`src/main.zig:10`, `:17`,
      `:18`, `:24` — and those types have no `format` method at all, so `{f}`
      is not the fix there), `zig-algebra-traits` prints `F7` elements
      (`src/main.zig:194`-`:201`, `:205`, `:210`, `:214`, `:227`), and
      `zig-poly` prints the coefficient `F` with `{}` inside
      `Polynomial.format` (`src/poly.zig:351`, `:353`, `:355`;
      `src/root.zig:578`, `:581`, `:584`). `zig-poly/src/main.zig` also prints
      `Poly` values with `{}` although `Polynomial.format` exists — same
      symptom, not a field element. Nothing has been fixed here; this is the
      list a sweep has to visit.
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
- [ ] **More extension tests.** `extension_test.zig` has 11 tests;
      `ext_quick.zig` has 2. The `primitiveRootOfUnity` gap this item used to
      name is closed: the slow path -- `log_size` above the base field's
      two-adicity, which needs a non-residue *inside* the extension -- is now
      covered at two-adicity 62 over `QuadraticExtension(M61, -1)`, and the
      stated reason for skipping it ("Debug is too slow at high two-adicity")
      was wrong. What is still missing is coverage of the *bounded search's*
      failure path: `error.NoNonResidue` is unreachable in practice, so nothing
      asserts it, and raising the bound is the one edit that would turn a
      regression into a stalled suite rather than a red one.
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
