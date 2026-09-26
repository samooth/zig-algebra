# zig-algebra Architecture Documentation

## Overview

`zig-algebra` is a monorepo containing 17 independent algebraic libraries that form the mathematical foundation for cryptographic protocols. The libraries are organized in layers, where each layer depends only on lower layers.

Layering below is the strict ordering implied by the real module imports
(root `build.zig` and each `libs/*/build.zig.zon`); a few libraries only need a
level because their dependencies do.

## Layer Architecture

```
Layer 0: algebra-traits          (compile-time trait contracts)
    │
Layer 1: bigint, hash, transcript
    │                             (primitives + Fiat-Shamir; transcript has no deps)
Layer 2: field, merkle, rng      (field on bigint; merkle/rng on hash)
    │
Layer 3: curve, binary-field     (curve on field; binary-field on merkle)
    │
Layer 4: ntt, poly, linalg, pairing
    │                             (ntt/linalg on field, pairing on curve)
Proof stack: fri, kzg            (fri on transcript+merkle+field, kzg on pairing)
    │
Utils:  parallel, serialization  (no internal dependencies)
```

## Core Design Principles

### 1. Zero-Cost Abstractions via Comptime

All generic algorithms are parameterized by comptime types that implement trait contracts. The compiler monomorphizes each instantiation, producing code equivalent to hand-written specialized versions.

```zig
// Generic NTT works over any Field trait implementation
pub fn ntt(comptime F: type, data: []F, log_n: usize, root: F) void {
    traits.assertField(F); // compile-time contract check
    // ... implementation
}

// Instantiation: ntt(M31, data, log_n, M31.TWO_ADIC_ROOT)
// Compiler generates specialized M31-specific NTT code
```

### 2. Trait Contracts (algebra-traits)

All algebraic structures are defined as compile-time verified contracts:

```zig
pub fn FieldTrait(comptime T: type) type {
    return struct {
        pub const has_ring = RingTrait(T);
        pub const has_inv = @hasDecl(T, "inv");
        pub const has_div = @hasDecl(T, "div");
        pub const has_pow = @hasDecl(T, "pow");
        pub const has_isZero = @hasDecl(T, "isZero");

        pub fn assert() void {
            has_ring.assert();
            if (!has_inv) @compileError("Field trait: missing 'inv' on " ++ @typeName(T));
            // ...
        }
    };
}
```

### 3. Explicit Memory Ownership

- Fixed-size algebraic types live on the stack (fields, points, vectors,
  matrices, polynomials, towers)
- Variable-size structures (Merkle trees, FRI/KZG proofs, IPA, binary-field
  PCS, NTT twiddle caches) take a caller-supplied allocator and expose
  `deinit(allocator)`
- `error.OutOfMemory` is propagated; the proof stack has no `catch unreachable`
- No hidden allocations inside scalar operations

### 4. Typed Errors for Caller Input (0.4.0)

Preconditions over caller-supplied lengths, dimensions, domains and
invertibility are no longer expressed as `std.debug.assert`. That assert is
compiled out in `ReleaseFast`, and the code it used to guard either looped
forever (binary GCD on zero), indexed past a caller-supplied length, or
allocated from an untrusted length prefix. Those inputs are now
`error.LengthMismatch` / `error.InvalidDimension` / `error.InvalidLength` /
`error.NotPowerOfTwo` / `error.InvalidPointLength` / `error.DomainTooLong`, and
invertibility is `error.InverseOfZero` / `error.DivisionByZero`. Two shapes are
used:

- a new error-returning entry point (`Multilinear.numVarsChecked`,
  `csprng.setEntropyChecked`, `nttVec8M31Checked`, `hashToPoint` /
  `generatorVector`, which became error unions);
- a legacy **total** wrapper kept next to a `…Checked` sibling for source
  compatibility (`inv` / `div` / `batchInv`, `numVars`, `setEntropy`), which
  must be documented as not being a validation step.

`std.debug.assert` remains for invariants that no caller input can influence.

### 5. Zig 0.16 Compatibility

All libraries target Zig 0.16.0 with:
- `b.createModule()` + `root_module =` pattern
- No deprecated `root_source_file`
- Proper fingerprint generation
- `u7`/`u6` shift amount handling

## Library Details

### algebra-traits (Layer 0)

The foundation. Defines all algebraic trait contracts as compile-time checked
contracts (`traits.zig`):

- `SetTrait` - basic equality/zero/one
- `GroupTrait`, `AdditiveGroupTrait`, `MultiplicativeGroupTrait` - groups
- `RingTrait`, `FieldTrait`, `PrimeFieldTrait`, `FieldExtensionTrait`
- `VectorSpaceTrait` - vector spaces over fields
- `PolynomialRingTrait` - polynomial operations
- `EllipticCurveTrait`, `PairingFriendlyTrait` - curves and pairings
- `CommitmentSchemeTrait`, `MerkleTreeTrait`, `TranscriptTrait`
- `NttTrait` - NTT requirements
- `HashToFieldTrait`, `HashToCurveTrait` - RFC 9380 style hashing
- `FieldRngTrait` - field random elements

Plus `assert*` helpers (`assertField`, `assertRing`, `assertGroup`,
`assertEllipticCurve`, `assertPairingFriendly`) and generic algorithms (`pow`,
`sum`, `product`, `egcd`). It is compile-time only: it ships 0 runtime tests by
design.

### bigint (Layer 1)

Arbitrary-precision integers with limb-based representation:

- `BigInt(max_limbs)` - configurable precision over `[max_limbs]u64`
- Addition, subtraction, multiplication
- Division with remainder: `divRemU64` fast path for single-limb divisors,
  simplified shift-and-subtract for multi-limb (Knuth Algorithm D is *not*
  implemented)
- GCD / extended GCD / modular inverse (`ExtendedGcd`)
- Modular exponentiation: square-and-multiply for `BigInt` exponents plus a
  `u64`-exponent fast path
- Primality testing: trial division by small primes, then Miller-Rabin

### hash (Layer 1)

Cryptographic hash functions:

- **Blake3** - fast, parallelizable, XOF support
- **Blake2b/Blake2s** - RFC 7693
- **Keccak-256/SHA3-256** - Ethereum compatible
- **Poseidon** - ZK-friendly algebraic hash
- **MiMC** - minimal constraints for SNARKs
- **Hash interface** - unified `hashBytes`/`hash2` for Merkle

### transcript (Layer 1)

Fiat-Shamir transcript for non-interactive proofs:

- Blake3-based (stdlib only, no internal library dependencies)
- Field-aware challenges (`challengeField`) and byte appends
- Re-keying after each challenge
- Label-parameterised initialisation so a transcript is domain-separated by
  the caller

### rng (Layer 2)

Random number generators:

- **ChaCha20Rng** - stream cipher CSPRNG
- **Shake256Rng** - XOF-based PRNG
- **Process-wide CSPRNG** - thread-safe ChaCha20 seeded from OS entropy
  (`getrandom` on Linux, `BCryptGenRandom` on Windows, `/dev/urandom` elsewhere,
  host-injected entropy for freestanding/wasm) with a test-only
  deterministic injection hook (`setRandomForTesting`, `setRandomForTestingSeed`)
- **Host entropy injection** - `setEntropy` (total: truncates to capacity and
  zero-fills the tail), `setEntropyChecked`
  (`error.EntropyTooLong` / `error.InsufficientEntropy`), `entropyAvailable`
- **Fisher-Yates** - unbiased shuffling, plus `randomPermutation`
- **Rejection sampling** - uniform field elements, bounded by
  `MAX_REJECTION_ATTEMPTS` and returning typed range errors

### field (Layer 2)

Prime field implementations:

- **M31** - 2^31 - 1 (STARK-friendly, Mersenne fast path + Vec8 SIMD)
- **BabyBear** - 2^31 - 2^27 + 1
- **KoalaBear** - 2^31 - 2^24 + 1
- **M61** - 2^61 - 1
- **Goldilocks** - 2^64 - 2^32 + 1 (used by the STARK/FRI demo)
- **StarkNet_Fp** - STARK field
- **BN254_Fp** - BN254 base field
- **BLS12_381_Fp** - BLS12-381 base field
- **Extensions**: CM31, QM31, BN254_Fp2 (the `BLS12_381_Fp2` re-export in `zig-field` is currently broken; use `zig-curve`'s BLS12-381 `Fp2`)
- `Field(modulus)` picks `SmallField` (< 2^64, native u64, Mersenne
  split-reduce) or `BigField` (Montgomery CIOS over `[N]u64` limbs)
- Binary GCD inversion (non-constant-time: input-dependent iteration count),
  with `invChecked` / `divChecked` / `batchInvChecked` as the enforced API and
  the plain `inv` / `div` / `batchInv` kept as total legacy wrappers
  (`inv(0) == 0`, `x / 0 == 0` — zero is not an inverse)
- `Vec8NttM31` - `@Vector(8, u64)` Cooley-Tukey NTT, **M31 only**, with
  `nttVec8M31Checked` / `inttVec8M31Checked` enforcing `data.len == 8 * 2^log_n`
- RFC 9380 `expand_message_xmd`, `hashToField`, cofactor-aware `hashToCurve`
- Two extra modules that are not separate libraries: `MerkleTree(F)` (SHA-256
  over serialized field elements) and `Ipa(F)`, the Bulletproofs-style inner
  product argument — `Ipa.verify` is a stub (`error.Unsupported`); only
  `verifyWithCommitment` verifies, and its challenges are a local SHA-256 over
  `(L, R, round)` rather than a `zig-transcript` session

### merkle (Layer 2)

Merkle tree variants, all generic over a comptime hash type `H` that must
expose a one-shot `hash([]const u8) [32]u8` (e.g. `zh.Blake3`,
`zh.Keccak256`, `zh.Sha3_256`, `zh.Blake2b256`, `zh.Blake2s256`) — there is no
built-in default:

- `MerkleTree(H)` - binary Merkle tree (power-of-two leaves), build from leaves
  (`init`) or from pre-hashed leaves (`initFromHashes`), array-heap storage
- `MMR(H)` - append-only log (`append`/`appendHash`); `verify` shape-checks the
  proof (sibling/flag array lengths must agree, and the depth must match the
  zero-padded tree `2^ceil(log2(leaf_count))`) before indexing anything
- `SparseMerkleTree(H, DEPTH)` - 256-bit key/value set with inclusion **and**
  non-membership proofs (`verifyNonMembership`)
- `MerkleProof` - path + sibling hashes + side flags, with
  `serialize`/`deserialize`
- Verification helpers: `MerkleTree.verify`, `verifyHashed`, `verifyPath`

### binary-field (Layer 3)

Characteristic-2 fields:

- Generic `BinaryField(bits, reduction_constant)`
- Tower: GF(2) → GF(4) → GF(16) → GF(256) → … → GF(2^128) (`TowerField`)
- CLMUL hardware acceleration (x86 PCLMULQDQ, ARM PMULL)
- Multilinear polynomial evaluation: packed MLE (`PackedMle`, `novelEval`), with
  `MAX_K` / `error.InvalidDimension` / `error.LengthMismatch` instead of asserts
- Sum-check protocol over binary fields. `Sumcheck(F)` requires `F.BITS >= 128`
  and returns `error.FieldTooSmall` otherwise
- Multilinear evaluation / commitment protocols: `MlePcs` (verifier holds the
   table) and `CommittedMlePcs` (Merkle-committed), i.e. Binius-style
   polynomial commitments — not a full Binius implementation
- `inv(0) == 0` in both families is a **legacy total** result (`invChecked`
  reports `error.InverseOfZero`), and `SumcheckUnsafe` / `MlePcsUnsafe` /
  `CommittedMlePcsUnsafe` bypass the 128-bit requirement to keep the 4-bit
  on-chain challenge format: **toy/test-only and not sound against a grinding
  prover**

### curve (Layer 3)

Elliptic curve implementations:

- **Stdlib curves**: Curve25519, Ed25519, Ristretto255, Secp256k1, P256, P384
- **BN254**: G1, G2 (pairing-friendly)
- **BLS12-381**: G1, G2
- **Pasta**: Pallas, Vesta (2-cycle)
- Hash-to-curve (RFC 9380 Shallue-van de Woestijne)
- Nothing-up-my-sleeve generator derivation (`hashToPoint` /
  `generatorVector`) with `error.DomainTooLong` / `error.NoValidPoint` instead
  of `catch unreachable`
- Group operations (generic over any point type)
- Byte-scalar arithmetic
- Group-element polynomial evaluation (VSS/KZG)

### ntt (Layer 4)

Number-Theoretic Transforms (radix-2, power-of-two sizes):

- `ntt` - iterative in-place Cooley-Tukey with bit-reversal permutation
- `intt` - inverse NTT
- `bitReverse` - standalone permutation
- `precomputeTwiddles`/`freeTwiddles` + `nttWithTwiddles`/`inttWithTwiddles` -
  cached roots of unity (the only allocating entry point)
- Generic over any field satisfying the trait; no mixed-radix, 2-D, batch or
  SIMD paths here (the M31 Vec8 NTT lives in `zig-field`)

### poly (Layer 4)

Polynomial operations over fields:

- `Polynomial(F, max_degree)` - dense, stack-allocated coefficients
- Arithmetic: add, sub, neg, scale, mul, pow
- Division: `divRem`/`div`/`rem`
- Evaluation: `eval` (Horner)
- `derivative`, `compose`, `lagrangeInterpolate`, `vanishingPolynomial`
- Vector helpers (`inner`, `powers`, `vecAdd`, `vecSub`, `vecScale`, `hadamard`,
  `vecSum`, `vecEql`)
- Multiplication is schoolbook; there is no Karatsuba/FFT path and no GCD

### linalg (Layer 4)

Linear algebra over finite fields, allocation-free with comptime dimensions:

- `Vector(F, n)` - add, sub, neg, scale, dot, norm²
- `Matrix(F, rows, cols)` - add, sub, scale, matrix×matrix, matrix×vector,
  transpose, trace
- Determinant (closed form for 1×1/2×2, Gaussian elimination above)
- `LU(F, n)` - partial pivoting, returns L, U, P with P·A = L·U
- Solving A·x = b through LU, `null` for singular systems

### fri (proof stack)

FRI v2 over a 2-adic multiplicative subgroup:

- Natural-order subgroup `H_k` with antipodal pairs and positional folds
- Logarithmic configuration (`log_initial_degree`, `log_final`,
  `log_residual_degree`) validated for consistency
- Fiat-Shamir folding challenges via `zig-transcript`
- Layer commitments in the shared `zig-merkle` tree (path depth must match the
  layer shape)
- `prove`/`verify` take a caller allocator; the regression suite covers
  random-data rejection, over-degree rejection, tampering, truncated paths,
  transcript desync and non-power-of-two proofs
- See `SECURITY.md` advisory ZA-2026-001 for the history of the verifier

### kzg (proof stack)

KZG polynomial commitments over BN254:

- `Setup.generate` - **synthetic** trusted setup (tests/dev only)
- `commit` - Pippenger MSM over `[tau^i]G1`
- `prove` - witness quotient `q(x) = (p(x) - p(z))/(x - z)` via Horner
- `verify` - pairing check `e(C - [y]G1, [tau]G2 - [z]G2) == e(W, G2)`
- Scalar multiplication delegated to the windowed Jacobian ladder in
  `zig-curve`; non-constant-time
- `commit`/`prove` take a caller allocator (breaking change introduced in
  v0.3.0)

### pairing (Layer 4)

Bilinear pairings:

- Generic `Fp2`/`Fp6`/`Fp12` tower types
- BLS12-381 optimal ate with split final exponentiation
- BN254 tower pairing: production `pairing()` = sparse twist-side Miller loop +
  split final exp, cross-checked against `pairingDense`
- BN254 direct degree-12 extension (`Fp12 = Fp2[w]/(w^12 - xi)`) as a second
  opinion
- Both BN254 paths are covered by bilinearity, non-degeneracy and EIP-197
  known-answer tests; neither is constant-time

### parallel (Utility)

Fork-join thread pool:

- `Pool.parallelFor(ctx, count, func)` - parallel map
- Auto-fallback to sequential on single-threaded/WASM
- Comptime-sized worker handles (max 64)

### serialization (Utility)

Canonical wire encoding via comptime reflection:

- Field elements → SIZE little-endian bytes
- Arrays → concatenated elements
- Slices → u64 length + elements
- Unsigned integers → bits/8 little-endian
- Booleans → 1 byte
- Optionals → presence byte + payload
- Structs → fields in declaration order
- Allocator fields skipped/restored
- `deserialize` treats its input as untrusted: a `u64` length prefix that claims
  more elements than the remaining bytes can hold is rejected with
  `error.InvalidLength` **before** allocating, and any failure part-way through
  rolls back the values already decoded, so a rejected input leaks nothing

## Testing

```bash
# Individual library (field and curve also compile their tests/ roots)
cd libs/field && zig build test

# All libraries
zig build test

# With specific optimization (same 382 tests, seconds instead of ~1-2 min)
zig build test -Doptimize=ReleaseFast
```

Counts verified on Zig 0.16.0: the root `zig build test` step runs **382 tests**
in both Debug and ReleaseFast; per-library steps sum to 498 because `field`
(85) and `curve` (98) additionally compile their separate `tests/` roots.
`algebra-traits` had no tests before 0.5.0 and now has 4.

## Versioning

The root `build.zig.zon` carries the **workspace version `0.5.0`**. Each
library ships its own `build.zig.zon` with an independent semver — currently
`0.1.0` (`transcript`) through `0.5.0` (`curve`). Library count grew 14
(v0.1.0) → 16 (v0.2.0: `fri`, `transcript`) → 17 (v0.2.2: `kzg`). The 0.5.0
release bumped `algebra-traits`, `bigint`, `curve`, `field`, `fri`, `hash`,
`kzg`, `linalg`, `ntt`, `pairing`, `poly` and `rng`; the other five manifests
are unchanged. Bump the library version for API changes and the
workspace version for ecosystem-level releases; record both in `CHANGELOG.md`.

## Known Gaps

Documented because the architecture above is easy to over-read:

- No independent cryptographic audit exists for any library here.
- Pairing, curve `scalarMul` and field inversion are not constant-time.
- `inv(0) == 0` and `x / 0 == 0` in `zig-field`, and `inv(0) == 0` in
  `zig-binary-field`, are legacy total wrappers, not valid mathematics. Use
  `invChecked` / `divChecked` / `batchInvChecked`.
- `Sumcheck(F)` in `zig-binary-field` requires `F.BITS >= 128`; the PCS
  entry points require `E.BITS >= 128` for their challenge field. The
  `SumcheckUnsafe` / `MlePcsUnsafe` / `CommittedMlePcsUnsafe` variants are
  grindable and must stay in tests.
- `Ipa.verify` (inside `zig-field`) is a stub; `verifyWithCommitment` is the
  working path and is not bound to a `zig-transcript` session.
- `kzg.Setup.generate` is a synthetic trusted setup.

## Contributing

1. Maintain layer separation (no upward dependencies)
2. Add tests for new functionality
3. Keep comptime-only where possible
4. Document trait requirements in doc comments
5. Run full test suite before PR: `zig build test`