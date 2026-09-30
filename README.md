# zig-algebra

![Tests](https://github.com/samooth/zig-algebra/actions/workflows/test.yml/badge.svg)
![Format](https://github.com/samooth/zig-algebra/actions/workflows/test.yml/badge.svg?job=fmt)

A modular ecosystem of 17 algebraic libraries for cryptography, zero-knowledge proofs, and high-performance computation in Zig 0.16.0.

> **Status:** workspace version `0.5.1` (see [Versioning](#versioning)). No
> independent cryptographic audit has been performed; "production candidate"
> below means test-covered, not audited. Review `SECURITY.md` before use.
>
> `0.4.0`, `0.5.0` and `0.5.1` are hardening releases: input validation that used to be
> `std.debug.assert` (invisible in `ReleaseFast`) is now typed errors, and the
> legacy total wrappers are explicitly marked as such. `0.5.0` closes the same
> defect class in the ten libraries `0.4.0` did not cover, including two on the
> verification path for untrusted proof data (`zig-fri` `Domain.init`,
> `zig-ntt` transforms). See [Known Limitations](#known-limitations) and
> `SECURITY.md` advisory ZA-2026-003.

## Vision

`zig-algebra` is not a monolithic library. It is a collection of **independent, specialized libraries** that together cover the full computational algebra stack needed for modern cryptography, ZK proofs, and blockchain applications.

Each library:
- Is **independently usable**
- Has **zero or minimal dependencies** (only lower-level modules)
- Uses **comptime** for monomorphization (zero-cost abstractions)
- Is **stack-only for fixed-size types**; variable-size structures (Merkle
  trees, FRI/KZG proofs, IPA, binary-field PCS) take a caller-supplied allocator

## Architecture

| Layer | Libraries |
|-------|-----------|
| **Traits** | `algebra-traits` (Field, Group, Ring, VectorSpace...) |
| **Foundation** | `bigint` (arbitrary-precision integers) · `hash` (Blake3, Blake2, Keccak/SHA3, Poseidon, MiMC) · `rng` (ChaCha20, SHAKE256) · `transcript` (Fiat-Shamir) |
| **Fields** | `field` (prime fields, Montgomery + Mersenne fast paths, tower extensions, IPA) · `binary-field` (GF(2^n), towers, packed MLE, sum-check, MLE PCS) |
| **Curves** | `curve` (Weierstrass, BN254, BLS12-381, Pasta, stdlib curves) · `pairing` (optimal ate pairings, Fp2/Fp6/Fp12 towers) |
| **Data Structures** | `merkle` (binary, MMR, sparse) |
| **Transforms** | `ntt` (iterative Cooley-Tukey, inverse NTT, twiddle cache) |
| **Polynomials** | `poly` (dense univariate, Lagrange interpolation, vanishing polynomial, vector helpers) |
| **Linear Algebra** | `linalg` (vectors, matrices, LU decomposition, linear solving over fields) |
| **Proof Stack** | `fri` (low-degree testing) · `kzg` (polynomial commitments) |
| **Utilities** | `parallel` (fork-join thread pool, portable monotonic clock) · `serialization` (generic wire encoding) |

## Dependency Graph

Edges below are the module imports actually wired in the root `build.zig`
(mirrored by each library's `build.zig.zon`).

```
algebra-traits (no deps)
├── bigint            (→ algebra-traits)
├── hash              (→ algebra-traits)
├── rng               (→ algebra-traits, hash)
├── merkle            (→ algebra-traits, hash)
├── field             (→ bigint)
├── binary-field      (→ algebra-traits, hash, merkle, parallel)
├── curve             (→ field, hash)
├── ntt               (→ algebra-traits, field)
├── poly              (→ algebra-traits)
├── linalg            (→ algebra-traits, field)
└── pairing           (→ algebra-traits, field, curve)

transcript (stdlib Blake3 only, no internal deps)
├── fri               (→ transcript, merkle, field)
└── kzg               (→ field, curve, pairing)

parallel (no deps) · serialization (no deps)
```

## Libraries

| Library | Description | Tests |
|---------|-------------|-------|
| [algebra-traits](libs/algebra-traits/) | Type contracts (traits) for computational algebra | 8 |
| [bigint](libs/bigint/) | Arbitrary-precision integer arithmetic | 28 |
| [hash](libs/hash/) | Cryptographic hash functions (Blake3, Blake2b/2s, Keccak/SHA3, Poseidon, MiMC) | 22 |
| [transcript](libs/transcript/) | Fiat-Shamir transcripts over stdlib Blake3 (no internal deps) | 13 |
| [fri](libs/fri/) | Fast Reed-Solomon IOP of Proximity (STARK low-degree testing, Merkle-committed) | 26 |
| [rng](libs/rng/) | Cryptographically secure PRNGs (ChaCha20, SHAKE256; OS entropy incl. Windows `BCryptGenRandom`) | 27 |
| [field](libs/field/) | Prime field arithmetic (Montgomery for ≥ 2^64, Mersenne fast path for small fields), tower extensions, Vec8 SIMD, IPA, field-element Merkle | 89 |
| [binary-field](libs/binary-field/) | Binary Galois fields GF(2^n), towers, CLMUL, packed MLE, sum-check, MLE polynomial commitments | 97 |
| [curve](libs/curve/) | Elliptic curves (Weierstrass affine/projective, BN254, BLS12-381, Pasta, stdlib curves, hash-to-curve, MSM) | 98 |
| [pairing](libs/pairing/) | Bilinear pairings: BLS12-381 optimal ate, BN254 tower (production `pairing()` = sparse Miller + split final exp) and BN254 direct degree-12; all covered by bilinearity/EIP-197 KAT tests | 58 |
| [ntt](libs/ntt/) | Number-Theoretic Transform (iterative Cooley-Tukey, inverse NTT, twiddle cache) | 16 |
| [merkle](libs/merkle/) | Merkle trees (binary, MMR, sparse) | 20 |
| [poly](libs/poly/) | Dense univariate polynomials over finite fields | 30 |
| [linalg](libs/linalg/) | Vectors, matrices, LU decomposition, linear system solving over fields | 11 |
| [parallel](libs/parallel/) | Fork-join parallel executor (thread pool) | 2 |
| [serialization](libs/serialization/) | Canonical wire encoding via comptime reflection | 15 |
| [kzg](libs/kzg/) | KZG polynomial commitments over BN254 (commit/prove/verify via pairings + MSM; synthetic setup, tests only) | 6 |

> **Test counts.** The `Tests` column is what each library's own
> `cd libs/<name> && zig build test` executes. The root `zig build test` runs
> **583 tests** (verified on Zig 0.16.0 in both Debug and ReleaseFast): the root
> step compiles **all 27 test binaries** — every library's inline `src/` tests
> plus the separate `tests/` roots of `field` (6 files, 89 tests) and `curve`
> (4 files, 98 tests). The per-library steps sum to **583, the same number**.
> `algebra-traits` shipped with zero tests before `0.5.0` and now has 5. `kzg`
> was added in v0.2.2 as the 17th library.

## API Status

| Status | Libraries and APIs |
|--------|--------------------|
| **Production candidate** | `algebra-traits`, `bigint`, `field`, `curve`, `hash`, `rng`, `transcript`, `merkle`, `ntt`, `poly`, `linalg`, `parallel`, `serialization` |
| **Security-sensitive / experimental** | `binary-field`, `pairing`, `fri`, `kzg`; review `SECURITY.md`, threat models, and deployment parameters before use |
| **Demo only** | Files under `examples/` and library `main.zig` programs; they are not protocol implementations or audited deployments |

“Production candidate” means covered by the repository tests and compatibility
checks; it does not claim an independent cryptographic audit or constant-time
guarantee. Module-level gaps (e.g. the IPA verifier inside `zig-field`) are
listed under [Known Limitations](#known-limitations).

## Validation Contract (0.4.0, extended in 0.5.0)

Input validation used to be expressed as `std.debug.assert`, which is compiled
out in `ReleaseFast`. `0.4.0` covered `field`, `binary-field`, `merkle`,
`rng`, `serialization` and `curve`; `0.5.0` closed the same class in
`algebra-traits`, `poly`, `linalg`, `fri`, `ntt`, `field`, `rng`, `hash` and
`pairing`. Most of those became error unions outright; where a signature had to
stay total, the entry point is split in two:

| Legacy (total) | Checked | Rejects |
|----------------|---------|---------|
| `F.inv()` → `zero()` on `0` | `F.invChecked()` | `error.InverseOfZero` |
| `F.div(y)` → `zero()` on `y == 0` | `F.divChecked(y)` | `error.DivisionByZero` |
| `F.batchInv(in, out)` (silently ignores a length mismatch, inverts around zeros) | `F.batchInvChecked(in, out)` | `error.LengthMismatch`, `error.InverseOfZero` |
| `BinaryField.inv()`, `TowerField.inv()` → `zero()` on `0` | `invChecked()` | `error.InverseOfZero` |
| `Multilinear.numVars()` → `0` on a malformed table | `numVarsChecked()` | `error.NotPowerOfTwo` |
| `PackedMle` checked methods / `novelEval` | `checkK`, `betaOnHChecked`, typed methods | `error.InvalidDimension`, `error.LengthMismatch` |
| `nttVec8M31` / `inttVec8M31` → no-op on a length mismatch | `nttVec8M31Checked` / `inttVec8M31Checked` | `error.InvalidLength` |
| `randomBounded(rnd, 0)` → `zero()` | — | (the empty range is defined) |
| `csprng.setEntropy` → truncates to capacity | `setEntropyChecked` | `error.EntropyTooLong`, `error.InsufficientEntropy` |
| `hashToPoint`, `generatorVector` (previously `catch unreachable`) | same names | `error.DomainTooLong`, `error.NoValidPoint` |
| `ByteScalar.add/sub/mul/inv/neg/fromBytes` (previously `catch unreachable`) | `ByteScalar.reduce` (total) | `error.NotCanonical` |
| `group_ops.scalarMul`, `evalGroupPoly` (previously `catch unreachable`) | same names | `error.NonCanonicalScalar` |
| `millerLoop`, `millerLoopPair` → identity on an infinity input | `millerLoopChecked`, `millerLoopPairChecked` | `error.PointAtInfinity` |
| `pairing` extension `inv()` → `zero()` on `0` | `invChecked()` | `error.InverseOfZero` |
| `Shake256Rng.absorbSeed` / `finalize` → corrupt the sponge | same names | `error.AlreadyFinalized` |
| `BigField.toU64()` → truncates above `u64` | `toU64Checked()` | `error.Overflow` |

Everything in the following list became a **breaking** error union in `0.5.0`,
so existing call sites need `try`: `algebra-traits`' `dotProduct`,
`lagrangeInterpolate` and `lagrangeCoefficient`; all of `zig-poly`'s
degree-increasing and vector helpers; `zig-linalg`'s `identity`, `trace`,
`determinant`, `lu` and `solve`; `zig-fri`'s `Domain.init` and `Domain.fill`;
`zig-ntt`'s `bitReverse`, `ntt`, `intt`, `nttWithTwiddles`, `inttWithTwiddles`
and `precomputeTwiddles`; `zig-field`'s `batchAdd`/`batchSub`/`batchMul`,
`multiExp`, `Ipa.innerProduct`, `Ipa.commit`, `primitiveRootOfUnity` and
`rootOfUnity`; `zig-curve`'s `msm`; `zig-hash`'s `Poseidon.initFromSeed`.

The legacy column is **kept for source compatibility only**. Where a legacy
function used to assert, it previously panicked in Debug/ReleaseSafe and either
hung or read/wrote out of bounds in `ReleaseFast`; it is now total. Prefer the
`…Checked` entry points in new code, and never read the legacy `inv` result as
proof that the argument was invertible.

## Quick Start

Each library can be used independently via path dependencies:

```zig
// build.zig.zon
.{
    .dependencies = .{
        .zig_field = .{ .path = "path/to/zig-algebra/libs/field" },
        .zig_curve = .{ .path = "path/to/zig-algebra/libs/curve" },
    },
}
```

```zig
// build.zig
const zf = b.dependency("zig_field", .{});
exe.root_module.addImport("zig-field", zf.module("zig-field"));

const zc = b.dependency("zig_curve", .{});
exe.root_module.addImport("zig-curve", zc.module("zig-curve"));
```

```zig
// Usage
const std = @import("std");
const zf = @import("zig-field");
const zc = @import("zig-curve");

// Prime field arithmetic
const F = zf.Field(21888242871839275222246405745257275088696311157297823662689037894645226208583); // BN254_Fp
const a = F.fromInt(42);
const b = (try a.invChecked()).mul(a);  // invChecked, not inv: inv(0) == 0
try std.testing.expect(b.isOne());

// Elliptic curve operations
const g = zc.bn254.G1_generator;   // affine point value
const two_g = g.add(g);           // 2G
const three_g = two_g.add(g);     // 3G
```

## Build Steps

| Step | What it does |
|------|--------------|
| `zig build test` | Runs the 583 library tests (also the default step under `-Doptimize=ReleaseFast`) |
| `zig build bench` | Field/curve/pairing/MSM/NTT benchmarks; the benchmark harness is ReleaseFast |
| `zig build example` | BLS12-381 Schnorr signature demo |
| `zig build stark` | STARK prover/verifier demo: Fibonacci over **Goldilocks** with FRI |
| `zig build wasm` | `examples/wasm_fp.zig` → wasm32-freestanding (`fp_add`, `fp_mul`, `fp_inv`) |
| `zig build wasm-pairing` | `examples/wasm_pairing.zig` → wasm32-freestanding BN254 pairing |
| `zig build fuzz` | Randomized property/fuzz runner (use `-Doptimize=ReleaseFast`) |

## Running Tests

```bash
# Test a specific library (includes its tests/ roots, where present)
cd libs/field && zig build test

# Test all libraries (from root)
zig build test

# Faster full run
zig build test -Doptimize=ReleaseFast
```

## Known Limitations

- **No independent audit.** Nothing here has been reviewed by an external
  auditor; the pairing, FRI, KZG and binary-field stacks are the most exposed.
- **Legacy `inv(0) == 0` (and `x / 0 == 0`).** `zig-field` (`SmallField`,
  `BigField`, `QuadraticExtension`, `CubicExtension`), `zig-binary-field`
  (`BinaryField`, `TowerField`) and the Montgomery backend all keep a total
  `inv()` that returns zero for a non-invertible argument, and a total `div()`
  that returns zero for a zero divisor. Zero is **not** a field element that
  satisfies `x * inv(x) == 1`; using the legacy API where invertibility is a
  requirement silently yields zero. Use `invChecked` / `divChecked` /
  `batchInvChecked`.
- **`SumcheckUnsafe`, `MlePcsUnsafe`, `CommittedMlePcsUnsafe` are not secure.**
  They exist to keep the historical 4-bit Bitcoin-Script challenge format
  testable. `Sumcheck(F)` itself now refuses `F.BITS < 128` with
  `error.FieldTooSmall`; the `…Unsafe` variants skip that check and are
  grindable by a malicious prover. Toy fields and tests only.
- **IPA is incomplete.** `zig-field`'s `Ipa.verify` is a stub that returns
  `error.Unsupported`; only `Ipa.verifyWithCommitment` is implemented. IPA
  challenges come from a local SHA-256 over `(L, R, round)` — they are *not*
  bound to a `zig-transcript` Fiat-Shamir session, so the module is not
  transcript-composable.
- **KZG setup is synthetic.** `Setup.generate` uses a caller-supplied `tau`;
  production needs a real powers-of-tau ceremony.
- **Constant-time is partial.** Inversion (binary GCD), integer comparison,
  square roots and scalar multiplication are not constant-time; see
  `DESIGN.md` and `SECURITY.md`.
- **`zig-rng` test hooks must be reset.** `csprng.setRandomForTesting` stores a
  copy of the `std.Random` interface, but that interface still points at the
  caller's generator state: pair it with `defer setRandomForTesting(null)`, or
  use `setRandomForTestingSeed`, whose state lives inside the module.
- **Documented API gaps remain:** see each library README for known broken or
  unimplemented entry points (including the `zig-field` `BLS12_381_Fp2` re-export,
  `zig-hash` `Hash.hash2`, and `zig-rng` `ChaCha20Rng.initOsRandom` on Zig
  0.16.0). Test coverage does not imply every public helper is usable.

## Design Principles

1. **Correctness first** — arithmetic is tested against independent references where available
2. **No external runtime dependencies** — the Zig standard library, plus the Windows `bcrypt` system library for OS entropy in `zig-rng`
3. **Comptime-first** — all constants computed at compile time
4. **Explicit memory** — fixed-size types are stack-allocated; anything
   variable-size (trees, proofs, vectors) takes a caller-supplied allocator and
   documents its `deinit`
5. **Generic** — algorithms work over any field/curve via comptime parameters

## SIMD: Vec8 for Mersenne-31

`zig-field` exposes 8-lane SIMD arithmetic for M31 as `@Vector(8, u64)`
(auto-vectorized on targets with 64-bit vectors, scalarized otherwise). `Vec8`
and the `*Vec8` helpers are **M31-only** — they are `void`/comptime errors for
any other field:

```zig
const zf = @import("zig-field");
const M31 = zf.M31;

const a: M31.Vec8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
const b: M31.Vec8 = @splat(1000);
const sum = M31.addVec8(a, b); // lane-wise add mod 2^31-1
const prod = M31.mulVec8(a, b); // lane-wise mul mod 2^31-1

// Vec8 Cooley-Tukey NTT lives in zig-field as well:
var data: [16]M31 = undefined;
for (&data, 0..) |*slot, k| slot.* = M31.fromInt(k + 1);
const log_n = 1;
const root = M31.primitiveRootOfUnity(log_n);
zf.nttVec8M31(&data, log_n, root);

// `data.len` must be exactly `8 * 2^log_n`. The legacy entry point leaves the
// data untouched on a mismatch; the checked one reports it:
try zf.nttVec8M31Checked(&data, log_n, root);
```

## Benchmarks (indicative)

Measured with `zig build bench` (ReleaseFast) on an AMD Ryzen 7 5800H /
Linux x86-64 / Zig 0.16.0. **These are orientation numbers, not guarantees**:
they scale with CPU, frequency scaling and build flags, and CI only uploads the
output as an artifact (no regression thresholds).

```
BLS12-381 Fp mul                    0.5 µs
BLS12-381 Fp inv                    5.8 µs
Fp2 mul                             1.7 µs
Fp12 mul                           53.6 µs
BLS12-381 G1 scalarMul             91.9 µs   <- windowed Jacobian ladder
BLS12-381 optimal ate              33.6 ms
BN254 optimal ate (tower)          20.9 ms   <- production: sparse Miller + split final exp
BN254 tower dense reference        36.6 ms   <- cross-check reference
BN254 ate (direct deg-12)         107.1 ms
MSM n=256 naive                   21.1 ms
MSM n=256 pippenger               11.9 ms
MSM n=65536 pippenger             506.9 ms
NTT 2^20 Fr (twiddles)          1113.9 ms
```

Re-run with `zig build bench` from the repo root to get numbers for your own
machine. Small-field timings (e.g. M31 `mul`) are below the clock resolution
and print as `0 ns`.

## Versioning

The workspace root manifest (`build.zig.zon`) is versioned as **`0.5.0`**, while
each library carries its own `build.zig.zon` with an independent semver
(libraries currently between `0.1.0` (`transcript`) and `0.5.0` (`curve`)).
Library count grew over time: 14 libraries at v0.1.0, 16 at v0.2.0
(`fri` + `transcript`), 17 at v0.2.2 (`kzg`).

- **`0.5.1`** (current) fixes the `zig build bench` compile error that shipped
  in `v0.5.0`, and carries the release gate whose absence let it: CI now
  triggers on `tags: ['v*']`, and AGENTS.md requires the tag to be pushed only
  after CI is green on that exact commit. `v0.5.0` is **not** moved — it is
  signed and possibly cloned, and rewriting a published tag to hide a compile
  error is worse than publishing a patch. It also carries the assert ledger
  (`zig build assert-check`), the `fri`/`parallel` packaging fixes, and the
  characteristic-agnostic Lagrange and folding arithmetic. Manifests in this
  release: `binary-field` 0.4.0, `parallel` 0.2.0, `fri` 0.3.0, `bigint` 0.3.0.
- **`0.5.0`** extends the validation hardening to `algebra-traits`,
  `poly`, `linalg`, `fri`, `ntt`, `field`, `rng`, `hash` and `pairing`, and
  fixes eight dead `format` methods, and adds the assert ledger
  (`zig build assert-check`). Bumped: `algebra-traits` 0.3.0, `bigint` 0.3.0,
  `curve` 0.5.0, `field` 0.4.0, `fri` 0.3.0, `hash` 0.3.0, `kzg` 0.2.1,
  `linalg` 0.2.0, `ntt` 0.2.0, `pairing` 0.4.0, `poly` 0.2.0, `rng` 0.4.0,
  `binary-field` 0.4.0, `parallel` 0.2.0. `merkle`, `serialization` and
  `transcript` are unchanged. See the `0.5.1` entry below for what that release
  changed and why two releases landed back to back.

  `fri` 0.3.0 and `parallel` 0.2.0 are the two packaging fixes: `fri` declared
  `.dependencies = .{}` while hand-wiring three sibling libraries from `../`,
  which made it unusable as a package; `parallel` never called `addModule` at
  all, so it could not be imported as a dependency — which is why
  `binary-field` carried a fork of its fork-join `Pool`. That fork is gone
  (0.4.0); its two tests were byte-identical duplicates of `parallel`'s, so the
  count drops by two without losing coverage.
- **`0.4.0`** carried the same hardening for `field`, `binary-field`, `merkle`,
  `rng`, `serialization` and `curve` (`field` and `binary-field` to `0.3.0`,
  `curve` to `0.4.0`, `rng` to `0.3.0`, `serialization` to `0.2.0`, `merkle` to
  `0.1.2`).

See `CHANGELOG.md` for the full history.

## License

MIT OR Apache-2.0
