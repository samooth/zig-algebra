# zig-serialization

Canonical wire encoding for Zig values via comptime reflection. The format is
derived entirely from the compile-time type structure — there is no per-type
code and no schema.

Library version: **0.2.0** (`libs/serialization/build.zig.zon`); the workspace
version lives in the root `build.zig.zon`.

## Features

- **Two entry points** — `serialize(allocator, value) ![]u8` and
  `deserialize(allocator, bytes, comptime T) !T`
- **Field-element passthrough** — types exposing `toBytes`/`fromBytes` plus
  `NUM_BYTES` or `SIZE` are encoded through those, in either protocol
- **Structs in declaration order** — reflection over `std.meta.fields`
- **Golden test** — the exact byte layout is pinned, so an accidental format
  change fails the build
- **Self-delimiting** — `deserialize` rejects trailing bytes
  (`error.TrailingBytes`) and truncation (`error.UnexpectedEnd`); no silent
  truncation
- **Untrusted input is bounded** — a `u64` length prefix is validated against
  the bytes that remain (and the minimum wire size per element) *before*
  anything is allocated, so it returns `error.InvalidLength` instead of
  requesting an arbitrary allocation
- **Rollback on failure** — a decode that fails part-way through releases
  everything it had already allocated, so a rejected message leaks nothing
- **Allocator fields handled** — a `std.mem.Allocator` field is skipped on
  write and restored to the deserializing caller's allocator on read; a field
  named `owns_entries` is skipped on write and set to `true` on read
- **No dependencies**

## Supported types

| Category | Wire format |
|----------|-------------|
| `bool` | 1 byte, `0` or `1` (anything else → `error.InvalidValue`) |
| Unsigned integers | `bits / 8` little-endian bytes |
| `usize` | always 8 little-endian bytes, zero-extended — portable across 32/64-bit targets; a value above `maxInt(usize)` is `error.Overflow` |
| `[N]u8` | raw bytes, no length prefix |
| `[N]T` (other child) | elements in order, concatenated |
| `[]T` / `[]const T` | `u64` little-endian length prefix, then the elements |
| `?T` | 1 presence byte (`0`/`1`), then the payload when present |
| Field element, `NUM_BYTES` protocol | `NUM_BYTES` raw bytes from `toBytes() [NUM_BYTES]u8`; parsed with `fromBytes([]const u8) !T`, failure → `error.InvalidValue` |
| Field element, `SIZE` protocol | `SIZE` raw bytes from `toBytes(*[SIZE]u8) void`; parsed with `fromBytes([SIZE]u8) T` |
| Struct | fields in declaration order, skipping `std.mem.Allocator` fields and fields named `owns_entries` |

## Not supported

Anything else is a `comptime` `@compileError`, not a runtime error. Verified
rejections:

| Type | Error |
|------|-------|
| Error union, e.g. `anyerror!u8` | `cannot serialize type anyerror!u8` |
| Signed integer, e.g. `i32` | `signed integers are not serializable: i32` |
| Float, e.g. `f64` | `cannot serialize type f64` |
| Single-item pointer, e.g. `*u8` | `single-item pointers are not serializable: *u8` |
| `enum` | `cannot serialize type ...` |
| `union`, `opaque`, optional-of-pointer, `packed struct`, `anytype` fields | `cannot serialize type ...` |

In particular: **error unions are not handled.** Wrap the payload and encode the
tag yourself if you need it. Signed integers are rejected on purpose so the
encoding cannot silently depend on two's complement.

## Quick Start

```zig
const std = @import("std");
const ser = @import("zig-serialization");

const Record = struct {
    name: [3]u8,
    count: u32,
    rows: []const u16,
    flag: bool,
    maybe: ?[2]u8,

    fn deinit(self: @This(), a: std.mem.Allocator) void {
        a.free(self.rows);
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const value = Record{
        .name = .{ 'a', 'b', 'c' },
        .count = 0x01020304,
        .rows = &.{ 0x0102, 0x0304 },
        .flag = true,
        .maybe = .{ 0xde, 0xad },
    };

    const bytes = try ser.serialize(allocator, value);
    defer allocator.free(bytes);
    // 61 62 63 | 04 03 02 01 | 02 00*7 | 02 01 04 03 | 01 | 01 de ad
    //  name     | count u32   | rows len  | rows[0..1]  |flag | maybe

    const back = try ser.deserialize(allocator, bytes, Record);
    defer back.deinit(allocator);

    // Self-delimiting: trailing or missing bytes are errors, never truncation.
    const longer = try allocator.alloc(u8, bytes.len + 1);
    defer allocator.free(longer);
    @memcpy(longer[0..bytes.len], bytes);
    longer[bytes.len] = 0;
    if (ser.deserialize(allocator, longer, Record)) |_| {
        unreachable; // error.TrailingBytes
    } else |err| switch (err) {
        error.TrailingBytes => {},
        else => return err,
    }
}
```

### Field elements

Both byte conventions are recognised. A type counts as a field element when it
is a `struct` with `toBytes` **and** `fromBytes` **and** (`NUM_BYTES` or `SIZE`).

```zig
// NUM_BYTES protocol: toBytes() [NUM_BYTES]u8, fromBytes([]const u8) !Self
const F = @import("zig-field").M31;
const fb = try ser.serialize(allocator, F.fromInt(5));   // 4 little-endian bytes
const fback = try ser.deserialize(allocator, fb, F);

// SIZE protocol: toBytes(*[SIZE]u8) void, fromBytes([SIZE]u8) Self
const Pair = struct {
    const Self = @This();
    const SIZE = 2;
    lo: u8,
    hi: u8,
    pub fn toBytes(v: Self, out: *[SIZE]u8) void {
        out[0] = v.lo;
        out[1] = v.hi;
    }
    pub fn fromBytes(b: [SIZE]u8) Self {
        return .{ .lo = b[0], .hi = b[1] };
    }
};
const pb = try ser.serialize(allocator, Pair{ .lo = 0x11, .hi = 0x22 });  // 11 22
const pback = try ser.deserialize(allocator, pb, Pair);
```

## API

| Function | Signature | Notes |
|----------|-----------|-------|
| `serialize` | `(allocator: std.mem.Allocator, value: anytype) ![]u8` | returned slice is owned by the caller |
| `deserialize` | `(allocator: std.mem.Allocator, bytes: []const u8, comptime T: type) !T` | result owns its memory; release with `deinit(allocator)` |

Error set (inferred, not a named type): `error.UnexpectedEnd`,
`error.TrailingBytes`, `error.InvalidLength`, `error.InvalidValue`,
`error.Overflow`, plus `error.OutOfMemory`.

## Untrusted input

`deserialize` is written for bytes you did not produce:

- A `u64` length prefix is checked against the number of bytes actually left in
  the input, using `minWireSize(child)` as the per-element lower bound, before
  any allocation. A declared length larger than the input can support is
  `error.InvalidLength`, and the allocation size is therefore bounded by the
  input size times the type's own memory-per-wire-byte ratio. On 32-bit
  targets a prefix above `maxInt(usize)` is rejected here too, instead of
  tripping an `@intCast` overflow.
- A failing `readValue` rolls back every value it had already decoded (earlier
  struct fields, earlier slice elements, earlier optional payloads), so the
  partially built value owns nothing when the error surfaces. The rollback
  mirrors the read logic field for field and deliberately does **not** call a
  user `deinit` on a value whose later fields are still uninitialized.
- `error.TrailingBytes` frees the fully decoded value; that path now works
  whether or not the type exposes a `pub deinit`.

```zig
// 2^64-1 elements with no payload behind the prefix: rejected, not allocated.
const hostile = [_]u8{0xff} ** 8;
try std.testing.expectError(
    error.InvalidLength,
    ser.deserialize(allocator, &hostile, []const u32),
);
```

## Memory ownership

- `serialize` returns a fresh slice; free it with the same allocator.
- `deserialize` **allocates** every slice it decodes. A decoded type with a
  `deinit(allocator)` member is the caller's responsibility to release on the
  success path.
- `error.TrailingBytes` frees the decoded value before returning it, preferring
  the type's own `deinit`. **Declare `deinit` as `pub`** — verified with
  `std.heap.DebugAllocator`, two otherwise identical structs that differ only
  in `pub` on `deinit` behave differently here: the public one releases
  cleanly, the private one leaves a leak, because `hasDeinit` only checks
  `@hasDecl(T, "deinit")` and the cross-file method call does not reach a
  non-`pub` member.
- **Every other failure releases what it decoded** (`error.InvalidLength`,
  `error.UnexpectedEnd`, `error.InvalidValue`, `error.Overflow`). An earlier
  revision of this file stated the opposite: `readValue` had no unwind for the
  partially filled parent value, so a malformed message leaked the prefix it had
  managed to build. The rollback is now in place, and it does not need `deinit`
  to be `pub` — a type with no `deinit` at all is released through the mirrored
  walk.
- `deserialize` on a type without `deinit` still allocates; on the success path
  those allocations are only reachable through the returned value.

## Installation

`libs/serialization/build.zig` does **not** call `b.addModule`, so the
`zig-serialization` module is only registered by the workspace root
`build.zig`. Consume it from inside zig-algebra, or point a module at
`libs/serialization/src/root.zig` yourself:

```zig
const ser = b.createModule(.{
    .root_source_file = .{ .cwd_relative = "libs/serialization/src/root.zig" },
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zig-serialization", ser);
```

There are no dependencies.

## Running Tests

```bash
cd libs/serialization && zig build test
```

17 tests: the golden wire layout, a nested slice-of-slices round trip, the
`SIZE`-protocol field element, the `NUM_BYTES` field element plus strict
`bool`/optional flag validation, rejection of truncated and trailing bytes, and
the untrusted-input suite — over-long length prefixes rejected, a prefix that
never reaches the allocator (checked with `FailingAllocator`), rollback of
earlier struct fields, rollback of already-decoded slice elements, rollback of
optional payloads (allocated and not), a prefix that fails before an optional
payload runs, rollback that mirrors the read logic instead of calling a user
`deinit` on a half-built value, and a valid minimal encoding with empty
elements that must still round-trip.

## Design Notes

- All integers are little-endian.
- `u64` length prefixes bound every variable-length section.
- Structs are encoded positionally in declaration order, so **reordering or
  inserting a field changes the wire format** and is caught by the golden test
  only if that exact type is in it.
- Little-endian matches the `toBytes()` convention used by every `zig-field`
  type, so field elements drop in with no extra conversion.
- The module has a single source file and no imports beyond `std`.

## License

MIT OR Apache-2.0
