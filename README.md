# zig-algebra

![Tests](https://github.com/samooth/zig-algebra/actions/workflows/test.yml/badge.svg)
![Format](https://github.com/samooth/zig-algebra/actions/workflows/test.yml/badge.svg?job=fmt)

A modular ecosystem of 17 algebraic libraries for cryptography, zero-knowledge proofs, and high-performance computation in Zig 0.16.0.

> **Status:** workspace version `0.3.2` (see [Versioning](#versioning)). No
> independent cryptographic audit has been performed; "production candidate"
> below means test-covered, not audited. Review `SECURITY.md` before use.

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
├── binary-field      (→ algebra-traits, hash, merkle)
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
| [algebra-traits](libs/algebra-traits/) | Type contracts (traits) for computational algebra | 0 (compile-time only) |
| [bigint](libs/bigint/) | Arbitrary-precision integer arithmetic | 18 |
| [hash](libs/hash/) | Cryptographic hash functions (Blake3, Blake2b/2s, Keccak/SHA3, Poseidon, MiMC) | 17 |
| [transcript](libs/transcript/) | Fiat-Shamir transcripts over stdlib Blake3 (no internal deps) | 10 |
| [fri](libs/fri/) | Fast Reed-Solomon IOP of Proximity (STARK low-degree testing, Merkle-committed) | 10 |
| [rng](libs/rng/) | Cryptographically secure PRNGs (ChaCha20, SHAKE256; OS entropy incl. Windows `BCryptGenRandom`) | 13 |
| [field](libs/field/) | Prime field arithmetic (Montgomery for ≥ 2^64, Mersenne fast path for small fields), tower extensions, Vec8 SIMD, IPA, field-element Merkle | 70 |
| [binary-field](libs/binary-field/) | Binary Galois fields GF(2^n), towers, CLMUL, packed MLE, sum-check, MLE polynomial commitments | 68 |
| [curve](libs/curve/) | Elliptic curves (Weierstrass affine/projective, BN254, BLS12-381, Pasta, stdlib curves, hash-to-curve, MSM) | 92 |
| [pairing](libs/pairing/) | Bilinear pairings: BLS12-381 optimal ate, BN254 tower (production `pairing()` = sparse Miller + split final exp) and BN254 direct degree-12; all covered by bilinearity/EIP-197 KAT tests | 54 |
| [ntt](libs/ntt/) | Number-Theoretic Transform (iterative Cooley-Tukey, inverse NTT, twiddle cache) | 11 |
| [merkle](libs/merkle/) | Merkle trees (binary, MMR, sparse) | 14 |
| [poly](libs/poly/) | Dense univariate polynomials over finite fields | 20 |
| [linalg](libs/linalg/) | Vectors, matrices, LU decomposition, linear system solving over fields | 9 |
| [parallel](libs/parallel/) | Fork-join parallel executor (thread pool) | 2 |
| [serialization](libs/serialization/) | Canonical wire encoding via comptime reflection | 5 |
| [kzg](libs/kzg/) | KZG polynomial commitments over BN254 (commit/prove/verify via pairings + MSM; synthetic setup, tests only) | 6 |

> **Test counts.** The `Tests` column is what each library's own
> `cd libs/<name> && zig build test` executes. The root `zig build test` runs
> **316 tests** (verified on Zig 0.16.0 in both Debug and ReleaseFast): it
> compiles each library's inline `src/` tests only, so `field` and `curve` —
> the two libraries with separate `tests/` roots — contribute 11 and 48 tests
> there instead of 70 and 92. `algebra-traits` is compile-time only and
> contributes 0 tests. `kzg` was added in v0.2.2 as the 17th library.

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
const b = a.inv().mul(a);
try std.testing.expect(b.isOne());

// Elliptic curve operations
const g = zc.bn254.G1_generator;   // affine point value
const two_g = g.add(g);           // 2G
const three_g = two_g.add(g);     // 3G
```

## Build Steps

| Step | What it does |
|------|--------------|
| `zig build test` | Runs the 316 library tests (also the default step under `-Doptimize=ReleaseFast`) |
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

The workspace root manifest (`build.zig.zon`) is versioned as **`0.3.2`**, while
each library carries its own `build.zig.zon` with an independent semver
(workspace `0.3.2`; libraries currently between `0.1.0` and `0.3.0`). Library
count grew over time: 14 libraries at v0.1.0, 16 at v0.2.0 (`fri` +
`transcript`), 17 at v0.2.2 (`kzg`). See `CHANGELOG.md` for the full history.

## License

MIT OR Apache-2.0
