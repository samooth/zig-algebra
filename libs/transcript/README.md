# zig-transcript

Transcript for non-interactive zero-knowledge proofs, in the Fiat–Shamir style:
a single-field Blake3 sponge that absorbs prover messages, squeezes verifier
challenges, and re-keys after every squeeze.

> **House design, not a specification.** No published specification is
> implemented, so a third party cannot derive the same challenges from the same
> statement — the composition is ours and has no external witness. This is a
> design fact, not a defect, and it is written up in `SECURITY.md`. The
> construction's parts are sound and individually tested; what is unverified is
> that they compose the way a third party would expect.

## Features

- **Fiat–Shamir** — turn an interactive protocol into a non-interactive one
- **Blake3 from the standard library** — no internal dependencies at all
- **Field-aware challenges** — `challengeField(F)` returns a uniform element via
  rejection sampling, not a reduction
- **The bytes are pinned to an outside implementation** — a Python mirror of
  the protocol (length-prefixed absorbs, a challenge that finalises, extends by
  re-hashing, and re-keys with the block it emitted) over the reference BLAKE3
  binding, for 32-, 64- and 128-byte challenges, for the challenge *after* a
  wide one, and for both sides of `challengeField`'s rejection loop. The
  in-repo tests check the same properties against the transcript itself, which
  any re-keying scheme satisfies.
- **Re-keying** — after each squeeze the hasher is reset and re-seeded with the
  challenge bytes, so a challenge depends on every previous challenge
- **Length-prefixed absorb** — prevents concatenation ambiguity
- **Allocation-free** — all state is one Blake3 hasher on the stack

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

`zig-transcript` declares **no** dependencies, so nothing else needs wiring. The
other libraries in the workspace do not depend on it through a package
dependency: `zig-fri` and the STARK example build the module from
`libs/transcript/src/root.zig` directly.

## Quick Start

```zig
const std = @import("std");
const zt = @import("zig-transcript");
const F = @import("zig-field").BN254_Fp;

pub fn main() !void {
    // Initialize the transcript with a domain separator.
    var transcript = zt.Transcript.init("my-zk-protocol");

    // Absorb public data. `absorbField` uses the element's own toBytes().
    transcript.absorbBytes("public input");
    transcript.absorbField(F, F.fromInt(7));
    transcript.absorbU64(99);
    // Optionals encode presence/absence explicitly.
    transcript.absorbOptionalField(F, F.fromInt(7));
    transcript.absorbOptionalField(F, null);

    // Squeeze challenges. Re-keying happens automatically after each squeeze,
    // so the next challenge depends on this one.
    const challenge = transcript.challengeField(F);   // uniform in [0, p)
    const u64_challenge = transcript.challengeU64();

    var out: [64]u8 = undefined;
    transcript.challengeBytes(&out);                  // fills a caller buffer

    const three = transcript.challengeFields(F, 3);   // [3]F
    const combined = transcript.challengeFrom(F, &[_]F{ F.fromInt(1), F.fromInt(2) });
    // challengeFrom absorbs every element, then squeezes one challenge.

    std.debug.print("challenge={} u64={} bytes={} n={} combined={}\n", .{
        challenge.toInt(), u64_challenge, out[0], three.len, combined.toInt() });
}
```

## API

### Absorb

| Method | Signature | Notes |
|--------|-----------|-------|
| `absorbBytes` | `(self: *Transcript, data: []const u8) void` | 8-byte little-endian length prefix, then the bytes |
| `absorbU64` | `(self: *Transcript, val: u64) void` | fixed 8-byte encoding via `absorbBytes` |
| `absorbField` | `(self: *Transcript, comptime F: type, elem: F) void` | requires `F.toBytes() [N]u8` |
| `absorbOptionalField` | `(self: *Transcript, comptime F: type, elem: ?F) void` | `absorbU64(1/0)` then the payload |

### Squeeze

| Method | Signature | Notes |
|--------|-----------|-------|
| `challengeBytes` | `(self: *Transcript, out: []u8) void` | **fills a caller-owned slice**; does not return bytes |
| `challengeU64` | `(self: *Transcript) u64` | little-endian read of 8 squeezed bytes |
| `challengeField` | `(self: *Transcript, comptime F: type) F` | requires `F.NUM_BYTES` and `F.fromBytes([]const u8) !F`; loops until `fromBytes` succeeds |
| `challengeFields` | `(self: *Transcript, comptime F: type, comptime n: usize) [n]F` | `n` challenges in order |
| `challengeFieldChecked` | `(self: *Transcript, comptime F: type) F` | **requires `F.fromBytesChecked(bytes: [NUM_BYTES]u8) !F`**; exactly uniform on `[0, p)`. Use this one for a uniform challenge |
| `challengeFrom` | `(self: *Transcript, comptime F: type, elems: []const F) F` | absorb all, squeeze one |

`challengeBytes` finalises the sponge, copies the 32-byte digest into `out`,
extends by re-hashing if `out.len > 32`, then **re-keys**: the hasher is reset to
a fresh `Blake3` and updated with the digest, so the next challenge cannot be
computed without this one. The re-key happens on every call, including the
retries inside `challengeField`.

## Transcript structure

`Transcript` has exactly **one** field:

```zig
pub const Transcript = struct {
    hasher: std.crypto.hash.Blake3,   // the entire state
};
```

There is no stored `label` and no `counter`. The domain separator is absorbed
into the hasher at `init` time (length-prefixed, like any other absorb), and
sequencing comes from the re-keying step rather than an explicit counter. Use
`@typeInfo(Transcript).@"struct".fields.len == 1` if you need to assert this.

## Security notes

- **Domain separation** — `init` absorbs the label length and the label, so two
  protocols using identical messages still derive different challenges.
- **Length prefixing** — every `absorbBytes` prefixes the length, so
  `absorb("ab") + absorb("c")` differs from `absorb("abc")`.
- **Re-keying** — after each `challenge*` call the hasher is reset and re-seeded
  with the challenge output, which blocks state extension. `challengeField`'s
  rejection-sampling retries therefore also advance the transcript.
- **Uniformity** — `challengeFieldChecked` draws through `F.fromBytesChecked`
  and re-keys on rejection, so the result is **exactly** uniform on `[0, p)`.
  Exact *about what*: the decoder's success set is the field, and rejection
  sampling over such a decoder has no bias to bound. `challengeField` makes **no
  uniformity claim** — it decodes through `F.fromBytes`, and whether that
  rejects or reduces is a per-field convention (`zig-field`'s rejects;
  `zig-binary-field`'s prime fixtures reduce, on purpose). The property was never
  the transcript's to promise. New code that needs a uniform challenge should
  use the `Checked` half. Same split as `inv`/`invChecked` and
  `millerLoop`/`millerLoopPairChecked`.
- **Determinism** — same label + same absorb sequence = same challenge stream.
  This is what makes `zig-fri` reproducible.
- **Not for signatures** — this is a ZK proof transcript, not a message
  authentication or signature scheme.
- Not constant-time: the hasher is a fixed-cost function, but
  `challengeField`'s retry count leaks the number of rejected draws.

## Running Tests

```bash
cd libs/transcript && zig build test
```

10 tests: determinism, domain separation, absorb sensitivity, challenge
sequencing, length-prefix disambiguation, `absorbField`, 100 consecutive
`challengeField` draws, `challengeFields`, `absorbOptionalField` presence
encoding, and `challengeFrom` order sensitivity.

## Design Notes

- Uses `std.crypto.hash.Blake3` (capital `B`), not `zig-hash`'s wrapper, so the
  module has zero internal dependencies.
- All absorb/squeeze methods take `*Transcript`; the struct is a value, so copy
  it to fork a transcript (there is no `clone` method).
- `challengeField` requires `F.NUM_BYTES`; a field without it will not compile.
  Extension types in `zig-field` expose `NUM_BYTES` and `fromBytes`, so tower
  elements work as challenges.

## License

MIT OR Apache-2.0
