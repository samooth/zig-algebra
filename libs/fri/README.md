# zig-fri

FRI v2 over a 2-adic multiplicative subgroup with Merkle commitments. The API uses logarithms for domain and degree bounds and is compatible with Zig 0.16.0.

## Features

- **Antipodal-pair FRI** — commitments hash `(f(x), f(-x))` and fold by squaring
- **Explicit degree bound** — initial and residual bounds are validated
- **Fiat-Shamir transcript** — non-interactive via transcript challenges
- **Merkle tree commitments** — using zig-merkle with Blake3
- **Configurable soundness** — tune `num_queries` for the desired security level

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
const F = @import("zig-field").Goldilocks;

const config = zfri.Config{
    .log_domain = 7,
    .log_initial_degree = 6,
    .log_final = 5,
    .log_residual_degree = 4,
    .num_queries = 20,
};

const domain = zfri.Domain(F).init(F, config.log_domain);
var evaluations: [128]F = undefined;
for (0..evaluations.len) |i| {
    const x = domain.at(i);
    evaluations[i] = x.sqr().add(x).add(F.one());
}

var pt = Transcript.init("fri-demo");
var proof = try zfri.prove(F, allocator, &pt, &evaluations, config);
defer proof.deinit(allocator);

var vt = Transcript.init("fri-demo");
const ok = try zfri.verify(F, &vt, &proof, config);
try std.testing.expect(ok);
```

## API

| Function | Description |
|----------|-------------|
| `Domain(F).init(F, log_n)` | Build the natural-order multiplicative subgroup |
| `prove(F, allocator, transcript, evaluations, config)` | Generate a FRI proof |
| `verify(F, transcript, proof, config)` | Verify a FRI proof |
| `Config.rounds()` | Compute and validate the number of folds |

## Config

```zig
const Config = struct {
    log_domain: u6,
    log_initial_degree: u6,
    log_final: u6,
    log_residual_degree: u6,
    num_queries: usize,
};
```

`log_domain` is the logarithm of the initial domain size. The relation
`log_initial_degree - rounds == log_residual_degree` is mandatory, and the
residual degree bound must be strictly smaller than `2^log_final`.

## Running Tests

```bash
zig build test
```

## Design Notes

- Each layer commits to antipodal pairs and uses exact positional fold checks.
- Challenges are derived with `transcript.challengeField()`.
- The final layer is interpolated and sent as truncated residual coefficients.
- Merkle paths must have exactly the depth implied by each layer.
- The field must provide `two_adicity >= log_domain` and a primitive root of unity.

## License

MIT OR Apache-2.0