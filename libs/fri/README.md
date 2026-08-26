# zig-fri

Fast Reed-Solomon Interactive Oracle Proof of Proximity (FRI) for STARKs. Implements index-pairing FRI over arbitrary domains with Merkle tree commitments.

## Features

- **Index-pairing FRI** — query phase reuses folded pairs for efficiency
- **Arbitrary domain sizes** — power-of-two domains supported
- **Fiat-Shamir transcript** — non-interactive via transcript challenges
- **Merkle tree commitments** — using zig-merkle with Blake3
- **Configurable soundness** — tune num_queries for desired security level

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_fri = .{
        .path = "path/to/zig-algebra/libs/fri",
    },
},
```

Then in your `build.zig`:

```zig
const zf = b.dependency("zig_fri", .{});
exe.root_module.addImport("zig-fri", zf.module("zig-fri"));
```

## Quick Start

```zig
const zfri = @import("zig-fri");
const Transcript = @import("zig-transcript").Transcript;
const M31 = @import("zig-field").M31;

const config = zfri.Config{
    .domain_size = 128,
    .final_length = 8,
    .num_queries = 20,
};

// Prover: compute evaluations of polynomial
var p_evals: [128]M31 = undefined;
for (0..128) |i| {
    const xi = M31.fromInt(i);
    p_evals[i] = xi.sqr().add(xi).add(M31.one());
}

var pt = Transcript.init("fri-demo");
var proof = try zfri.prove(M31, allocator, &pt, &p_evals, config);
defer proof.deinit(allocator);

// Verifier
var vt = Transcript.init("fri-demo");
const ok = try zfri.verify(M31, &vt, &proof, config);
try std.testing.expect(ok);
```

## API

| Function | Description |
|----------|-------------|
| `prove(F, allocator, transcript, p_evals, config)` | Generate FRI proof for evaluations |
| `verify(F, transcript, proof, config)` | Verify FRI proof |
| `numRounds(config)` | Compute number of folding rounds |

## Config

```zig
const Config = struct {
    domain_size: usize,    // Must be power of 2
    final_length: usize = 16,  // Final layer size (power of 2)
    num_queries: usize = 100,  // Security parameter
};
```

## Running Tests

```bash
zig build test
```

## Design Notes

- Uses index-pairing FRI: each query collects pairs (even, odd) at each fold level
- Challenges derived via transcript.challengeField() — deterministic given same transcript label
- Merkle tree built over hashPairs(even, odd) at each layer
- Final polynomial evaluations sent directly (no Merkle commitment)
- Soundness: error ≤ (degree_bound / |F|)^num_queries

## License

MIT OR Apache-2.0