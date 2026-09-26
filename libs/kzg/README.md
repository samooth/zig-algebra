# zig-kzg

Kate–Zaverucha–Goldberg (KZG) polynomial commitments over BN254, built on the
workspace's optimal-ate pairing (`zig-pairing`) and Pippenger MSM
(`zig-curve`).

> **Status:** development / test API. `verify` performs on-curve and
> in-subgroup checks and the pairing equation is the real one, but the built-in
> setup is **synthetic** — `Setup.generate` takes a caller-chosen τ and
> publishes `[τⁱ]G1` to anyone who reads the source. Do not use it in
> production. A deployment needs a verified powers-of-tau transcript and must
> validate every externally supplied point and encoding at the protocol
> boundary.

## Features

- **Polynomial commitment** — `C = Σ coeffs[i]·[τⁱ]G1` via Pippenger MSM
- **Open / verify** — witness `W = [q(τ)]G1` for `q(x) = (p(x) − p(z)) / (x − z)`,
  verified with a two-pairing equation
- **BN254** — Ethereum-compatible pairing-friendly curve
- **Single verification pairing pair** — `e(C − [y]G1, G2_gen)` vs
  `e(W, [τ]G2 − [z]G2_gen)`
- **Input validation** — `isOnCurve` + `isG1InSubgroup` on both the commitment
  and the witness; degree bound and empty-polynomial checks
- **Synthetic trusted setup** — test/dev only

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

`zig-kzg` re-exports the types it needs: `Fr`, `Fp`, `Fp2`, `G1`, `G2`, `G1Proj`,
`Fp12T`, and the `KzgError` set.

## Quick Start

```zig
const std = @import("std");
const zk = @import("zig-kzg");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Synthetic trusted setup (TEST ONLY — use a real ceremony for production).
    // `deinit` takes no arguments, and takes *Setup, so bind it with `var`.
    var setup = try zk.Setup.generate(allocator, zk.Fr.fromInt(42), 16);
    defer setup.deinit();

    // Polynomial p(x) = 2 + x + 3x^2, coefficients low degree first.
    const coeffs = [_]zk.Fr{ zk.Fr.fromInt(2), zk.Fr.fromInt(1), zk.Fr.fromInt(3) };

    // Commit: C = sum(coeffs[i] * [tau^i]G1)
    const commitment = try zk.commit(&setup, allocator, &coeffs);

    // Open at z = 5.
    const z = zk.Fr.fromInt(5);
    const opening = try zk.prove(&setup, allocator, &coeffs, z);
    // opening = .{ .witness = W (G1), .y = p(z) (Fr) }

    // Verify: e(C - [y]G1, G2_gen) == e(W, [tau]G2 - [z]G2_gen)
    const ok = zk.verify(&setup, commitment, z, opening.y, opening.witness);

    // Tampering breaks it.
    const bad = zk.verify(&setup, commitment, z, opening.y.add(zk.Fr.one()), opening.witness);

    std.debug.print("y={} ok={} tampered={} g1_pows={}\n", .{
        opening.y.toInt(), ok, bad, setup.g1_pows.len });
}
```

## API

### `Setup`

| Member | Signature | Notes |
|--------|-----------|-------|
| `g1_pows` | `[]G1` | `g1_pows[i] = [τⁱ]G1`, length `max_degree + 1` |
| `g2_tau` | `G2` | `[τ]G2` |
| `g2_gen` | `G2` | the G2 generator |
| `allocator` | `std.mem.Allocator` | the allocator `generate` was given |
| `generate` | `(allocator, tau: Fr, max_degree: usize) KzgError!Setup` | **TEST ONLY** |
| `deinit` | `(self: *Setup) void` | frees `g1_pows`; takes **no** allocator argument |

### Operations

| Function | Signature | Notes |
|----------|-----------|-------|
| `commit` | `(setup: *const Setup, allocator, coeffs: []const Fr) KzgError!G1` | MSM over `g1_pows[0..len]` |
| `evaluate` | `(coeffs: []const Fr, z: Fr) Fr` | Horner, infallible |
| `witnessCoeffs` | `(allocator, coeffs: []const Fr, z: Fr) KzgError![]Fr` | quotient coefficients, length `len − 1`; **caller frees** |
| `prove` | `(setup: *const Setup, allocator, coeffs, z) KzgError!struct { witness: G1, y: Fr }` | `witnessCoeffs` + MSM; result is a value copy |
| `verify` | `(setup: *const Setup, commitment: G1, z: Fr, y: Fr, witness: G1) bool` | pure, no error union |

`KzgError` = `error{DegreeExceedsSetup, InvalidPoint, InvalidPolynomial, OutOfMemory}`.

Rejected inputs:

| Call | Result |
|------|--------|
| `commit` / `prove` with `coeffs.len == 0` | `error.InvalidPolynomial` |
| `witnessCoeffs` with `coeffs.len == 0` | `error.InvalidPolynomial` |
| `commit` / `prove` with `coeffs.len > setup.g1_pows.len` | `error.DegreeExceedsSetup` |
| `verify` with a commitment or witness off the curve | `false` |
| `verify` with a commitment or witness outside the r-torsion subgroup | `false` |
| `verify` at the wrong `z`, a wrong `y`, or a scaled witness | `false` |
| any allocation failure | `error.OutOfMemory` |

## Warning: synthetic setup

`Setup.generate()` builds a **synthetic trusted setup** from a τ value the
caller chooses. Everyone reading the source knows τ, so the discrete log of the
commitments is known too and the scheme is not binding. It is only suitable for
tests and development. Production deployments require a real powers-of-tau
ceremony (an MPC transcript download and verification), and must additionally
reject untrusted `G1`/`G2` points at the API boundary.

## Design Notes

- Commitment: `C = Σ coeffs[i]·g1_pows[i]` via `zc.msm.msm` (Pippenger), then a
  single projective→affine conversion.
- Witness: `q(x) = (p(x) − p(z)) / (x − z)`, computed by Horner-based synthetic
  division, so `q` has `len − 1` coefficients and `W = Σ q[i]·g1_pows[i]`.
- Verification equation implemented in `verify`:

  ```text
  e(C - [y]G1, G2_gen)  ==  e(W, [tau]G2 - [z]G2_gen)
  ```

  which is the standard rearrangement of `e(C, G2) = e(W, [tau]G2) · e([y]G1, G2)`
  via the identity `e(a, b)·e(a, -c) = e(a, b - c)`. The code builds
  `[tau]G2 - [z]G2_gen` with affine subtraction and substitutes `Fp12T.one()`
  for a degenerate (infinity) input on either side.
- Everything is **non-constant-time**: the setup is public, the polynomial
  coefficients are the prover's secret, and `zc.msm`/pairing branch on value
  magnitude. Do not reuse this code path for secret-scalar workloads.
- `prove` returns a value copy of the witness — there is nothing to free. Only
  `Setup.deinit` and `witnessCoeffs` transfers ownership.

## Running Tests

```bash
cd libs/kzg && zig build test
```

6 tests: constant/empty-polynomial edges, degree-1 commit vs manual sum, the
happy path, tampered `y`, tampered witness, and wrong opening point.

## License

MIT OR Apache-2.0
