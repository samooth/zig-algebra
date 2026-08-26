# zig-transcript

Fiat-Shamir transcript for non-interactive zero-knowledge proofs. Provides a deterministic challenge derivation API over Blake3.

## Features

- **Fiat-Shamir heuristic** — convert interactive protocols to non-interactive
- **Blake3-based** — fast, parallelizable hash function
- **Field-aware challenges** — `challengeField(F)` returns uniform field elements
- **Re-keying** — squeeze re-keying after each challenge prevents state extension attacks
- **Deterministic** — same transcript label → same challenge stream

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_transcript = .{
        .path = "path/to/zig-algebra/libs/transcript",
    },
},
```

Then in your `build.zig`:

```zig
const zt = b.dependency("zig_transcript", .{});
exe.root_module.addImport("zig-transcript", zt.module("zig-transcript"));
```

## Quick Start

```zig
const zt = @import("zig-transcript");
const F = @import("zig-field").BN254_Fp;

// Initialize transcript with domain separator
var transcript = zt.Transcript.init("my-zk-protocol");

// Absorb public data
transcript.absorbBytes("public input");
transcript.absorbField(F, some_value);

// Squeeze challenges
const challenge = transcript.challengeField(F);
const u64_challenge = transcript.challengeU64();

// Re-keying happens automatically after each squeeze
// This prevents length-extension style attacks
```

## API

| Method | Description |
|--------|-------------|
| `Transcript.init(label)` | Create transcript with domain separator |
| `absorbBytes(bytes)` | Absorb arbitrary bytes |
| `absorbField(F, value)` | Absorb field element (via toBytes) |
| `absorbFieldBytes(F, bytes)` | Absorb field element bytes directly |
| `challengeField(F)` | Squeeze uniform field element |
| `challengeU64()` | Squeeze uniform u64 |
| `challengeBytes(len)` | Squeeze arbitrary bytes |

## Transcript Structure

```
Transcript {
    hasher: Blake3,        // Internal Blake3 state
    label: []const u8,     // Domain separator
    counter: u64,          // Challenge counter (for re-keying)
}
```

## Security Notes

- **Domain separation**: Always use unique labels for different protocols
- **Re-keying**: After each `challenge*()` call, the hasher is re-keyed with the challenge output
- **Determinism**: Same label + same absorbed data = same challenge stream
- **Not for signatures**: This is for ZK proof transcripts, not digital signatures

## Running Tests

```bash
zig build test
```

## Design Notes

- Uses stdlib Blake3 (not zig-hash's Blake3) — no internal dependencies
- Minimal implementation (~20 LOC core logic)
- Extracted from zig-stark's transcript module
- Compatible with zig-fri, zig-kzg, and other ZK protocols

## License

MIT OR Apache-2.0