# zig-hash

Cryptographic hash functions for Zig. Includes traditional hashes (Blake3, Keccak, SHA3) and ZK-friendly algebraic hashes (Poseidon, MiMC).

## Features

- **Blake3** — parallelizable, used in STARKs
- **Blake2b256 / Blake2s256** — fast, used in many protocols
- **Keccak-256** — Ethereum-compatible
- **SHA3-256** — NIST standard
- **Poseidon** — ZK-friendly algebraic hash (minimal constraints)
- **MiMC** — ZK-friendly hash for SNARKs (even fewer constraints)
- **Common `Hash` interface** — unified API across all hash functions
- **Streaming API** — incremental hashing for large inputs

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_hash = .{
        .path = "path/to/zig-algebra-core/zig-hash",
    },
},
```

Then in your `build.zig`:

```zig
const zh = b.dependency("zig_hash", .{});
exe.root_module.addImport("zig-hash", zh.module("zig-hash"));
```

## Quick Start

```zig
const zh = @import("zig-hash");

// One-shot hashing
const digest = zh.Blake3.hash("hello world");
const keccak = zh.Keccak256.hash("ethereum");

// Streaming (incremental)
var hasher = zh.Blake3.init(.{});
hasher.update("chunk 1");
hasher.update("chunk 2");
const final = hasher.finalResult();

// ZK-friendly hashing (over prime fields)
const F = @import("zig-field").BN254_Fp;
const input = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3) };
const hash = zh.Poseidon.hash(F, &input);
const mimc = zh.MiMC.hash(F, &input);
```

## Hash Functions

| Algorithm | Output | Use case |
|-----------|--------|----------|
| Blake3 | 256-bit | General-purpose, STARKs |
| Blake2b256 | 256-bit | General-purpose |
| Blake2s256 | 256-bit | General-purpose |
| Keccak-256 | 256-bit | Ethereum |
| SHA3-256 | 256-bit | NIST standard |
| Poseidon | Field element | ZK-friendly (algebraic) |
| MiMC | Field element | ZK-friendly (minimal constraints) |

## Running Tests

```bash
zig build test
```

## Design Notes

- Traditional hashes operate on byte arrays
- ZK-friendly hashes (Poseidon, MiMC) operate on field elements with minimal arithmetic constraints
- Poseidon uses a sponge construction with ARX (add-rotate-xor) round functions
- MiMC uses a simple x^3 round function for minimal R1CS constraints
- The `Hash` interface provides a common API across all hash functions

## License

MIT OR Apache-2.0
