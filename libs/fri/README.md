# zig-fri

FRI v2 (Fast Reed–Solomon Interactive Oracle Proof of Proximity) over a 2-adic
multiplicative subgroup, with Merkle commitments and a Fiat–Shamir transcript.
This is the STARK proximity backend used by the workspace's `zig build stark`
example.

> **Status:** maintained implementation with regression tests for the v2
> configuration, folding, path depth, and soundness boundaries. It is **not** a
> substitute for an independent cryptographic audit. Select query counts and
> blowup for your threat model and read `SECURITY.md` before relying on it.

## Features

- **Antipodal-pair commitment** — one Merkle leaf per pair `(f(x), f(-x))`, so a
  layer of size `n` commits `n/2` leaves
- **Two-to-one fold** — squaring maps `H_k → H_{k-1}`; the fold child of the
  pair `(j, j + n/2)` lands at position `j` of the half-size domain, preserving
  the natural layout at every layer
- **Algebraic (rather than parity) fold)** — see the exact formula below
- **Fiat–Shamir** — challenges come from `zig-transcript`
- **Merkle commitments** — the shared `zig-merkle` binary tree, hashed with
  Blake3
- **Residual as the degree anchor** — the last layer is interpolated to
  coefficients and truncated to the declared degree bound
- **Config validation** — every relationship between the log parameters is
  checked at `prove`/`verify` time

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
const zfri = b.dependency("zig_fri", .{});
exe.root_module.addImport("zig-fri", zfri.module("zig-fri"));
```

`libs/fri/build.zig.zon` declares no package dependencies: the build script
reconstructs the `zig-transcript`, `zig-bigint`, `zig-field`, `zig-hash` and
`zig-merkle` modules from sibling source paths. If you also depend on
`zig-field` directly, the resulting `zig-field` module instances are distinct
types and cannot be mixed; construct the `zig-fri` module against your own
`zig-field` module instead (that is what the workspace root `build.zig` does).

## Quick Start

```zig
const std = @import("std");
const zfri = @import("zig-fri");
const Transcript = @import("zig-transcript").Transcript;
const F = @import("zig-field").Goldilocks;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = zfri.Config{
        .log_domain = 7,            // initial domain: 2^7 = 128 points
        .log_initial_degree = 6,    // committed polynomial has degree < 64
        .log_final = 5,             // last layer: 2^5 = 32 points
        .log_residual_degree = 4,   // residual degree bound: 2^4 = 16
        .num_queries = 20,
    };

    // 2 folding rounds: log_domain - log_final = 7 - 5.
    const rounds = try config.rounds();
    try config.validate();

    // The natural-order subgroup domain: domain[i] = g_k^i.
    const domain = try zfri.Domain(F).init(F, config.log_domain);
    std.debug.assert(domain.size() == (@as(usize, 1) << config.log_domain));

    // p(x) = x^2 + x + 1, low degree, so the honest proof verifies.
    var evaluations: [128]F = undefined;
    for (0..evaluations.len) |i| {
        const x = domain.at(i);
        evaluations[i] = x.sqr().add(x).add(F.one());
    }

    // Prove (mutates the prover transcript).
    var pt = Transcript.init("fri-demo");
    var proof = try zfri.prove(F, allocator, &pt, &evaluations, config);
    defer proof.deinit(allocator);

    // Verify (mutates a freshly initialised verifier transcript).
    var vt = Transcript.init("fri-demo");
    const ok = try zfri.verify(F, &vt, &proof, config);

    std.debug.print("rounds={} layers={} queries={} residual={} verify={}\n", .{
        rounds, proof.layers.len, proof.queries.len, proof.residual.len, ok });
}
```

## API

### `Domain(F)`

`init` is generic over the field so the returned type does not have to be
spelled; both `F` arguments are the same type and must be a `zig-field` field
with `two_adicity` and `primitiveRootOfUnity`.

| Member | Signature | Notes |
|--------|-----------|-------|
| `init` | `(comptime Field: type, log_n: u6) error{DomainTooLarge, OrderTooLarge}!Self` | `error.DomainTooLarge` when `log_n > Field.two_adicity` (the shift would underflow); `error.OrderTooLarge` from the field |
| `log_n` | `u6` field | |
| `step_gen` | `F` field | the generator `g_k` |
| `size` | `(self: Self) usize` | `2^log_n` |
| `at` | `(self: Self, i: usize) F` | `g_k^i`, natural order |
| `fill` | `(self: Self, buf: []F) error{LengthMismatch}!void` | `error.LengthMismatch` when `buf.len != size()` |

### `Config`

```zig
pub const Config = struct {
    log_domain: u6,            // log2 of the initial domain size
    log_initial_degree: u6,    // log2 of the committed polynomial's degree bound
    log_final: u6,             // log2 of the LAST layer's domain size
    log_residual_degree: u6,   // log2 of the residual degree bound d
    num_queries: usize,        // number of random positions checked

    pub fn rounds(self: Config) FriError!usize;   // == log_domain - log_final
    pub fn validate(self: Config) FriError!void;  // rounds() + the degree relations
};
```

`rounds()` rejects:

- `log_domain == 0` or `log_domain > 63`
- `log_final >= log_domain` (no folds to do)
- `log_residual_degree >= log_final` (rate ≥ 1: no soundness distance)
- `log_final > 12` or `log_residual_degree > 12` (the fixed 4096-element
  verifier buffers)
- `num_queries == 0`

`validate()` additionally rejects `log_initial_degree > log_domain`,
`log_initial_degree < rounds`, and any config where
`log_initial_degree - rounds != log_residual_degree`. Both are called by `prove`
and `verify`, so a bad config is an `error.InvalidParameters`, not undefined
behaviour.

`Config` fields are all required — there are no defaults.

### Proof / query structures

| Type | Fields |
|------|--------|
| `FriError` | `error{InvalidParameters, InvalidProof, OutOfMemory}` |
| `LayerInfo` | `merkle_root: [32]u8`, `log_size: u6` |
| `QueryProof` | `pair_index: usize`, `values: [][]u8` (serialised `2*NUM_BYTES` per round), `paths: [][]const [32]u8` |
| `Proof` | `layers: []LayerInfo`, `residual: []const []const u8` (one `NUM_BYTES` blob per coefficient), `queries: []QueryProof`, `log_domain: u6`, `log_final: u6`, `log_residual_degree: u6` |
| `Proof.deinit` | `(self: *Proof, allocator: std.mem.Allocator) void` |

| Function | Signature | Notes |
|----------|-----------|-------|
| `prove` | `(comptime F, allocator, transcript: anytype, evals: []const F, config: Config) FriError!Proof` | `evals.len` must be `2^log_domain` |
| `verify` | `(comptime F, transcript: anytype, proof: *const Proof, config: Config) FriError!bool` | |

`transcript` is `anytype`, but `prove`/`verify` call methods on it, so pass a
**pointer** (`&transcript`). It must expose `absorbBytes`, `absorbField`,
`challengeField` and `challengeU64` — i.e. `zig-transcript`'s `Transcript`.

`Proof.deinit(allocator)` frees every allocation the proof owns, including the
per-query `values` and `paths` slices and the residual blobs. The `allocator`
passed to `prove` is not stored in the proof, so pass the same one to `deinit`.

## The fold, exactly

Layer `i` has size `n_i = 2^{log_domain - i}` and half size `h_i = n_i / 2`.
The leaf at index `j` commits to `(f_i[j], f_i[j + h_i])` — the antipodal pair
`x_j, -x_j` — hashed with Blake3. After absorbing the layer root, the prover
squeezes a challenge `α_i` and forms the next layer:

```text
even  = (f(x) + f(-x)) / 2
odd   = (f(x) - f(-x)) / (2x)
f_{i+1}[j] = even + α_i · odd
```

with `x = domain_i.at(j)`. This is the standard FRI fold: the even part carries
the degree-halving component, the odd part is scaled by the random `α_i` to
hide the degree-`d` component. Because `x_j^2 = g_{k-1}^j`, the child of the
pair at `(j, j + h_i)` is exactly position `j` of the half-size domain.

`verify` re-derives the same expression and requires **exact positional
equality** with the next round's revealed pair (no even/odd slack), then in the
last round compares against the truncated residual evaluated on the final
domain.

## Soundness model

The residual is the degree anchor. The final layer (size `2^log_final`) is
interpolated to coefficients with a naive `O(m²)` Vandermonde solve and truncated
to `2^log_residual_degree` coefficients. For an honest prover the discarded
coefficients are exactly zero (each fold halves the degree of a true
polynomial), so the truncation is lossless. For a cheater the truncation drops
real energy and the re-evaluated residual disagrees with the last committed
layer almost everywhere; the queries catch it. With blowup
`B = 2^log_final / 2^log_residual_degree` and `q` queries the per-query
acceptance probability for maximally-far data is about `1/B`, so rejection is
overwhelming. This is textbook FRI, and the exact constants depend on the field
and on `num_queries`; there is no independent audit.

`verify` rejects (returns `false`) when `log_domain > two_adicity` or
`log_final > two_adicity`; before 0.1.2 only `log_domain` was checked, and a
`log_final` beyond the two-adicity underflowed the shift inside
`Domain.init`.

## Requirements on `F`

A `zig-field` field with `two_adicity >= max(log_domain, log_final)` that
exposes `add/sub/mul/div/inv/pow/one/zero/fromInt/toBytes/fromBytes`. Goldilocks
(`two_adicity = 32`) is the reference field. **M31 has `two_adicity = 1` and
cannot be used** for any `log_domain > 1`.

## Known limitations

- `buildQueries` re-derives every layer's Merkle tree from the layer's
  evaluations, so the prover holds all layers in memory. There is no streaming
  / out-of-core mode.
- The final-layer interpolation is an `O(m²)` dense Gaussian elimination with
  partial pivoting, which is why `log_final` is capped at 12.
- `verify` allocates two fixed `[4096]F` stack buffers (≈ 32 KB each on
  Goldilocks); they are the reason for the `log_final <= 12` cap.
- `buildQueries` stores a fixed `[64]?MerkleTree` on the stack, so `rounds` is
  effectively capped at 64 (implied by `log_domain <= 63`).
- There is no degree-bound check on the *input* evaluations beyond the
  config relations; soundness rests on the residual plus the queries, which is
  the FRI design, not a shortcut.
- `Proof.deinit` calls `allocator.free` on every query sub-slice, including
  empty-but-allocated ones; a hand-rolled `Proof` that was not produced by
  `prove` will confuse it.
- Not constant-time; FRI operates on public data by construction.
- `Domain.init` returns `error.DomainTooLarge` when `log_n > F.two_adicity`;
  the old `std.debug.assert` was compiled out in `ReleaseFast`, where
  `two_adicity - log_n` underflowed and `1 << shift` with a shift >= 64 is
  undefined behaviour. `Domain.init` also forwards
  `error.OrderTooLarge` from `F.primitiveRootOfUnity`.
- `Domain.fill` returns `error.LengthMismatch`; the old assert vanished in
  `ReleaseFast` and the loop wrote past the end of `buf`.

## Running Tests

```bash
cd libs/fri && zig build test
```

12 tests: a degree-2 polynomial verifies; **random data must be rejected**
(regression for ZA-2026-001, which v1 accepted 16/16 of); an over-degree
polynomial must be rejected; a tampered query value is rejected; a truncated
Merkle path is rejected; a wrong transcript label is rejected; the
interpolator recovers a degree-1 polynomial; the domain's antipodal/squaring
structure; config validation rejects three bad shapes; and a larger
1024-point domain with a degree-31 polynomial verifies.

## Design Notes

- Layers commit to antipodal pairs, and folding is checked with exact
  positional equality, so there is no even/odd ambiguity to exploit.
- Challenges are derived with `transcript.challengeField(F)`, and query starting
  positions with `transcript.challengeU64()`.
- Merkle paths must have exactly the depth implied by the layer size
  (`layer_log - 1`); a shorter or longer path is rejected.
- The final layer is sent as truncated residual coefficients, not as
  evaluations.
- Field elements inside a proof are serialised as their `toBytes()` blobs
  (little-endian, `NUM_BYTES` each), and deserialised with `fromBytes`; a
  non-canonical encoding is `error.InvalidProof`.

## License

MIT OR Apache-2.0
