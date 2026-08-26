# zig-kzg

Kate-Zaverucha-Goldberg (KZG) polynomial commitments over BN254. Uses verified optimal ate pairing and Pippenger MSM from the zig-algebra ecosystem.

## Features

- **Polynomial commitments** — commit to polynomial via `[τ^i]G1` trusted setup
- **Open/verify** — prove evaluation `y = p(z)` with witness `W = [q(τ)]G1`
- **BN254 curve** — Ethereum-compatible pairing-friendly curve
- **Synthetic trusted setup** — test-only setup from known τ
- **Pippenger MSM** — fast multi-scalar multiplication for commits

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_kzg = .{
        .path = "path/to/zig-algebra/libs/kzg",
    },
},
```

Then in your `build.zig`:

```zig
const zk = b.dependency("zig_kzg", .{});
exe.root_module.addImport("zig-kzg", zk.module("zig-kzg"));
```

## Quick Start

```zig
const zk = @import("zig-kzg");
const allocator = std.heap.page_allocator;

// Generate synthetic trusted setup (TEST ONLY — use proper ceremony for production)
var setup = try zk.Setup.generate(allocator, zk.Fr.fromInt(42), 16);
defer setup.deinit();

// Polynomial: p(x) = 2 + x + 3x^2
const coeffs = [_]zk.Fr{ zk.Fr.fromInt(2), zk.Fr.fromInt(1), zk.Fr.fromInt(3) };

// Commit: C = sum(coeffs[i] * [τ^i]G1)
const commitment = try zk.commit(&setup, allocator, &coeffs);

// Open at z = 5
const z = zk.Fr.fromInt(5);
const proof = try zk.prove(&setup, allocator, &coeffs, z);
defer {} // witness is a value copy

// Verify: e(C - [y]G1, [τ]G2) == e(W, G2)
const ok = zk.verify(&setup, commitment, z, proof.y, proof.witness);
try std.testing.expect(ok);
```

## API

| Function/Type | Description |
|---------------|-------------|
| `Setup` | Trusted setup with `[τ^i]G1`, `[τ]G2`, `G2_gen` |
| `Setup.generate(allocator, τ, max_degree)` | Create synthetic setup (TEST ONLY) |
| `commit(setup, allocator, coeffs)` | Commit to polynomial |
| `evaluate(coeffs, z)` | Evaluate polynomial at z (Horner) |
| `prove(setup, allocator, coeffs, z)` | Open polynomial at z, returns `{witness, y}` |
| `verify(setup, commitment, z, y, witness)` | Verify opening proof |

## Warning: Synthetic Setup

The `Setup.generate()` function creates a **synthetic trusted setup** from a known τ value. This is **only suitable for testing and development**. Production deployments require a proper powers-of-tau ceremony (e.g., using `aztec-ceremony` or similar MPC).

## Running Tests

```bash
zig build test
```

## Design Notes

- Commitment: `C = Σ coeffs[i] * g1_pows[i]` via MSM
- Witness: `W = Σ q[i] * g1_pows[i]` where `q(x) = (p(x) - p(z)) / (x - z)`
- Verification uses pairing check: `e(C - [y]G1, G2_gen) == e(W, [τ]G2 - [z]G2_gen)`
- Non-constant-time (uses synthetic setup and public values only)

## License

MIT OR Apache-2.0