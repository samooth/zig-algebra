# zig-algebra

A modular ecosystem of algebraic libraries for cryptography, zero-knowledge proofs, and high-performance computation in Zig.

## Vision

`zig-algebra` is not a monolithic library. It is a collection of **independent, specialized libraries** that together cover the full computational algebra stack needed for modern cryptography, ZK proofs, and blockchain applications.

Each library:
- Is **independently usable**
- Has **zero or minimal dependencies** (only lower-level modules)
- Uses **comptime** for monomorphization (zero-cost abstractions)
- Is **allocation-free** where possible

## Architecture

| Layer | Libraries |
|-------|-----------|
| **Traits** | `algebra-traits` (Field, Group, Ring, VectorSpace...) |
| **Foundation** | `bigint` (arbitrary-precision integers) · `hash` (Blake3, Keccak, Poseidon, MiMC) · `rng` (ChaCha20, SHAKE256) |
| **Fields** | `field` (prime fields, Montgomery, tower extensions) · `binary-field` (GF(2^n), Binius) |
| **Curves** | `curve` (Weierstrass, BN254, BLS12-381, Pasta) · `pairing` (optimal ate pairings, Fp2/Fp6/Fp12 towers) |
| **Data Structures** | `merkle` (binary, MMR, sparse) |
| **Transforms** | `ntt` (Cooley-Tukey, Circle FFT, mixed-radix, SIMD) |
| **Polynomials** | `poly` (dense univariate, Lagrange, Karatsuba, GCD) |
| **Linear Algebra** | `linalg` (vectors, matrices, LU decomposition, linear solving over fields) |
| **Utilities** | `parallel` (fork-join thread pool) · `serialization` (generic wire encoding) |

## Dependency Graph

```
algebra-traits (no deps)
├── bigint            (→ algebra-traits)
├── hash              (no deps)
├── rng               (→ hash)
├── field             (→ bigint)
├── binary-field      (→ hash)
├── curve             (→ field, hash)
├── pairing           (→ field, curve)
├── merkle            (→ hash)
├── ntt               (→ algebra-traits)
├── poly              (→ algebra-traits)
├── linalg            (→ field)
├── parallel          (no deps)
└── serialization     (no deps)
```

## Libraries

| Library | Description | Tests |
|---------|-------------|-------|
| [algebra-traits](libs/algebra-traits/) | Type contracts (traits) for computational algebra | — |
| [bigint](libs/bigint/) | Arbitrary-precision integer arithmetic | 15 |
| [hash](libs/hash/) | Cryptographic hash functions (Blake3, Keccak, Poseidon, MiMC) | 15 |
| [rng](libs/rng/) | Cryptographically secure PRNGs (ChaCha20, SHAKE256) | 12 |
| [field](libs/field/) | Prime field arithmetic with Montgomery arithmetic | 58+ |
| [binary-field](libs/binary-field/) | Binary Galois fields GF(2^n), tower fields, Binius | 53 |
| [curve](libs/curve/) | Elliptic curves (Weierstrass, BN254, BLS12-381, Pasta) | 83 |
| [pairing](libs/pairing/) | Bilinear pairings: Fp2/Fp6/Fp12 towers, Miller loop, final exponentiation (BLS12-381 verified bilinear) | 14 |
| [ntt](libs/ntt/) | Number-Theoretic Transform (Cooley-Tukey iterative) | 10 |
| [merkle](libs/merkle/) | Merkle trees (binary, MMR, sparse) | 11 |
| [poly](libs/poly/) | Dense univariate polynomials over finite fields | 12 |
| [linalg](libs/linalg/) | Vectors, matrices, LU decomposition, linear system solving over fields | 9 |
| [parallel](libs/parallel/) | Fork-join parallel executor (thread pool) | 2 |
| [serialization](libs/serialization/) | Canonical wire encoding via comptime reflection | 4 |

> Run everything from the repo root: `zig build test` executes every suite
> above (189+ tests) and fails on any failure.

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
const G1 = zc.bn254.G1_generator;
const G2 = G1.double().add(G1); // 3*G
```

## Running Tests

```bash
# Test a specific library
cd libs/field && zig build test

# Test all libraries (from root)
zig build test
```

## Design Principles

1. **Correctness first** — all arithmetic is mathematically verified
2. **No external dependencies** — only Zig standard library
3. **Comptime-first** — all constants computed at compile time
4. **Allocation-free** — stack-only where possible
5. **Generic** — algorithms work over any field/curve via comptime parameters

## License

MIT OR Apache-2.0