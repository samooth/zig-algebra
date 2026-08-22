# zig-algebra Architecture Documentation

## Overview

`zig-algebra` is a monorepo containing 14 independent algebraic libraries that form the mathematical foundation for cryptographic protocols. The libraries are organized in layers, where each layer depends only on lower layers.

## Layer Architecture

```
Layer 0: algebra-traits          (compile-time trait contracts)
    │
Layer 1: bigint, hash, rng       (primitives)
    │
Layer 2: field, binary-field     (concrete field implementations)
    │
Layer 3: curve, merkle           (curves & data structures)
    │
Layer 4: ntt, poly               (algorithms over fields)
    │
Utils:  parallel, serialization  (infrastructure)
```

## Core Design Principles

### 1. Zero-Cost Abstractions via Comptime

All generic algorithms are parameterized by comptime types that implement trait contracts. The compiler monomorphizes each instantiation, producing code equivalent to hand-written specialized versions.

```zig
// Generic NTT works over any Field trait implementation
pub fn ntt(comptime F: type, data: []F, root: F, log_n: usize) void {
    FieldTrait(F).assert();
    // ... implementation
}

// Instantiation: ntt(M31, data, primitive_root, log_n)
// Compiler generates specialized M31-specific NTT code
```

### 2. Trait Contracts (algebra-traits)

All algebraic structures are defined as compile-time verified contracts:

```zig
pub fn FieldTrait(comptime T: type) type {
    return struct {
        pub const has_add = @hasDecl(T, "add");
        pub const has_mul = @hasDecl(T, "mul");
        pub const has_inv = @hasDecl(T, "inv");
        // ...
        
        pub fn assert() void {
            if (!has_add) @compileError("FieldTrait: missing 'add' on " ++ @typeName(T));
            // ...
        }
    };
}
```

### 3. Allocation-Free Design

- Stack allocation preferred over heap
- Arena allocators for temporary buffers
- Pre-allocated buffers passed by caller
- No hidden allocations in hot paths

### 4. Zig 0.16 Compatibility

All libraries target Zig 0.16.0 with:
- `b.createModule()` + `root_module =` pattern
- No deprecated `root_source_file`
- Proper fingerprint generation
- `u7`/`u6` shift amount handling

## Library Details

### algebra-traits (Layer 0)

The foundation. Defines all algebraic trait contracts:

- `SetTrait` - basic equality/zero/one
- `GroupTrait` - additive/multiplicative groups
- `RingTrait` - rings with addition/multiplication
- `FieldTrait` - fields with inversion
- `VectorSpaceTrait` - vector spaces over fields
- `PolynomialRingTrait` - polynomial operations
- `EllipticCurveTrait` - curve point operations
- `PairingFriendlyTrait` - bilinear pairings
- `NttTrait` - NTT requirements
- `HashToField/Curve` - hash-to-curve
- `MerkleTreeTrait` - Merkle trees
- `TranscriptTrait` - Fiat-Shamir
- `FieldRngTrait` - field random elements

### bigint (Layer 1)

Arbitrary-precision integers with limb-based representation:

- `BigInt(max_limbs)` - configurable precision
- Addition, subtraction, multiplication
- Division with remainder (Knuth Algorithm D)
- GCD, extended GCD, modular inverse
- Modular exponentiation (binary & u64 fast path)
- Primality testing (trial division + Miller-Rabin)

### hash (Layer 1)

Cryptographic hash functions:

- **Blake3** - fast, parallelizable, XOF support
- **Blake2b/Blake2s** - RFC 7693
- **Keccak-256/SHA3-256** - Ethereum compatible
- **Poseidon** - ZK-friendly algebraic hash
- **MiMC** - minimal constraints for SNARKs
- **Hash interface** - unified `hashBytes`/`hash2` for Merkle

### rng (Layer 1)

Random number generators:

- **ChaCha20Rng** - stream cipher CSPRNG
- **Shake256Rng** - XOF-based PRNG
- **Fisher-Yates** - unbiased shuffling
- **Rejection sampling** - uniform field elements
- **Process-wide CSPRNG** - thread-safe with OS entropy

### field (Layer 2)

Prime field implementations:

- **M31** - 2^31 - 1 (STARK-friendly)
- **BabyBear** - 2^31 - 2^27 + 1
- **KoalaBear** - 2^31 - 2^24 + 1
- **Goldilocks** - 2^64 - 2^32 + 1
- **BN254_Fp** - BN254 base field
- **BLS12_381_Fp** - BLS12-381 base field
- **Extensions**: CM31, QM31, BN254_Fp2
- Montgomery arithmetic for fast multiplication
- SIMD NTT (Vec8) for M31/BabyBear

### binary-field (Layer 2)

Characteristic-2 fields:

- Generic `BinaryField(bits, reduction_constant)`
- Tower: GF(2) → GF(4) → GF(16) → GF(256) → ...
- CLMUL hardware acceleration (PCLMULQDQ)
- Packed MLE evaluation (Binius packing)
- Sum-check protocol
- FRI-PCS for binary fields

### curve (Layer 3)

Elliptic curve implementations:

- **Stdlib curves**: Curve25519, Ed25519, Ristretto255, Secp256k1, P256, P384
- **BN254**: G1, G2 (pairing-friendly)
- **BLS12-381**: G1, G2
- **Pasta**: Pallas, Vesta (2-cycle)
- Hash-to-curve (RFC 9380 Shallue-van de Woestijne)
- Group operations (generic over any point type)
- Byte-scalar arithmetic
- Group-element polynomial evaluation (VSS/KZG)

### merkle (Layer 3)

Merkle tree variants:

- Binary Merkle tree (power-of-two leaves)
- MMR (Merkle Mountain Range) - append-only
- Sparse Merkle Tree (256-bit keys)
- Verkle tree (vector commitments)
- Inclusion/exclusion proofs
- Batch updates
- Serialization

### ntt (Layer 4)

Number-Theoretic Transforms:

- Cooley-Tukey iterative (in-place)
- Circle FFT for Mersenne fields (M31, BabyBear)
- Mixed-radix NTT (non-power-of-2 sizes)
- NTT 2D (for matrices)
- Batch NTT (multiple vectors)
- Twiddle factor caching
- SIMD (AVX-512, NEON) acceleration

### poly (Layer 4)

Polynomial operations over rings:

- Dense coefficient representation
- Evaluation (Horner, multipoint)
- Interpolation (Lagrange, Newton, FFT-based)
- Multiplication (schoolbook, Karatsuba, FFT)
- Division with remainder
- GCD, derivative, composition
- Lagrange basis conversion

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

## Testing

```bash
# Individual library
cd libs/field && zig build test

# All libraries
zig build test

# With specific optimization
zig build test -Doptimize=ReleaseFast
```

## Versioning

All libraries versioned together at workspace level (v0.1.0). Individual libraries use semantic versioning internally.

## Contributing

1. Maintain layer separation (no upward dependencies)
2. Add tests for new functionality
3. Keep comptime-only where possible
4. Document trait requirements in doc comments
5. Run full test suite before PR: `zig build test`