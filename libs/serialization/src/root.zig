// SPDX-License-Identifier: MIT OR Apache-2.0

//! zig-serialization: Generic canonical wire encoding.
//!
//! Provides compile-time reflection-based serialization/deserialization
//! of arbitrary Zig types. Derives the wire format entirely from the
//! compile-time type structure — no per-type code required.
//!
//! # Supported Types
//! - **Field elements**: Any type with `SIZE`, `toBytes(*[SIZE]u8)`, `fromBytes([SIZE]u8)` → `SIZE` little-endian bytes
//! - **`[N]u8`**: Raw bytes (e.g., `Hash.Digest`)
//! - **`[N]T`** (other arrays): Elements in order
//! - **Slices `[]T` / `[]const T`**: `u64` LE length prefix, then elements
//! - **Unsigned integers**: `bits/8` little-endian bytes (`usize` = 8 bytes)
//! - **`bool`**: Single byte (0/1)
//! - **Optionals `?T`**: One byte presence flag (0/1), then `T`
//! - **Structs**: Fields in declaration order
//!   - `std.mem.Allocator` fields: skipped on write, restored to caller's allocator on read
//!   - `owns_entries` fields: skipped
//!
//! # Conventions
//! - Little-endian for all integers
//! - `u64` length prefixes bound every variable-length section
//! - Self-delimiting: `deserialize` rejects trailing data
//!
//! # Untrusted input
//!
//! `deserialize` is written for untrusted bytes:
//!
//! - A `u64` length prefix is validated against the number of bytes actually
//!   left in the input before anything is allocated, so a declared length can
//!   never be larger than the input that backs it. Every allocation is
//!   therefore bounded by the input size (see `minWireSize`).
//! - A failing `readValue` rolls back every value it had already decoded:
//!   the partially built value owns nothing when the error surfaces, so
//!   `DebugAllocator` reports no leaks.
//!
//! Extracted from zig-stark's `core/serialization.zig`.

const std = @import("std");

/// Serialize a value to a byte slice using the canonical wire format.
///
/// The returned slice is allocated with `allocator`; caller must free.
pub fn serialize(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try writeValue(allocator, &list, value);
    return list.toOwnedSlice(allocator);
}

/// Deserialize a value from a byte slice using the canonical wire format.
///
/// The returned value owns its memory (release with `deinit(allocator)` if needed).
/// Returns `error.TrailingBytes` if input has unconsumed bytes.
///
/// `bytes` is treated as untrusted: a length prefix that claims more elements
/// than the remaining input can hold is rejected with `error.InvalidLength`
/// before any allocation happens, and a failure part-way through leaves nothing
/// allocated behind.
pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8, comptime T: type) !T {
    var cursor = Cursor{ .bytes = bytes };
    var value: T = undefined;
    try readValue(&cursor, allocator, &value, T);
    if (cursor.pos != cursor.bytes.len) {
        releaseValue(allocator, &value);
        return error.TrailingBytes;
    }
    return value;
}

/// True when `T` is a field element: exposes `NUM_BYTES` or `SIZE`, `toBytes`, and `fromBytes`.
fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "deinit"),
        else => false,
    };
}

/// Release a fully decoded value, preferring the type's own `deinit`.
///
/// Only called on complete values; partial values go through `deinitValue`,
/// which mirrors `readValue` and never calls user code on uninitialized state.
fn releaseValue(allocator: std.mem.Allocator, value: anytype) void {
    if (comptime hasDeinit(@TypeOf(value.*))) {
        value.deinit(allocator);
        return;
    }
    deinitValue(allocator, value);
}

fn isField(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "toBytes") and @hasDecl(T, "fromBytes") and
        (@hasDecl(T, "NUM_BYTES") or @hasDecl(T, "SIZE"));
}

/// Smallest number of bytes a serialized `T` can occupy.
///
/// Used to reject `u64` length prefixes before allocating. A result of 0 means
/// "no useful lower bound" (only reachable for empty structs and `[0]T`
/// arrays), in which case the length is validated against the remaining byte
/// count alone.
fn minWireSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |i| wireIntSize(T, i.bits, i.signedness),
        .array => |a| if (a.child == u8)
            a.len
        else
            a.len *| minWireSize(a.child),
        .pointer => |p| switch (p.size) {
            // Just the `u64` length prefix: the elements may all be empty.
            .slice => 8,
            .one, .many, .c => @compileError("single-item pointers are not serializable: " ++ @typeName(T)),
        },
        .@"struct" => if (isField(T))
            fieldWireSize(T)
        else
            structWireSize(T),
        .optional => 1,
        else => @compileError("cannot size type " ++ @typeName(T)),
    };
}

fn wireIntSize(comptime T: type, comptime bits: u16, comptime signedness: std.builtin.Signedness) usize {
    if (signedness == .signed) @compileError("signed integers are not serializable: " ++ @typeName(T));
    // `usize` is always 8 bytes on the wire regardless of pointer width.
    if (T == usize) return 8;
    return bits / 8;
}

fn fieldWireSize(comptime T: type) usize {
    if (comptime @hasDecl(T, "NUM_BYTES")) return T.NUM_BYTES;
    return T.SIZE;
}

fn structWireSize(comptime T: type) usize {
    var total: usize = 0;
    inline for (std.meta.fields(T)) |f| {
        if (f.type == std.mem.Allocator) continue;
        if (comptime std.mem.eql(u8, f.name, "owns_entries")) continue;
        total += minWireSize(f.type);
    }
    return total;
}

fn writeValue(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try list.append(allocator, if (value) 1 else 0),
        .int => |i| {
            if (i.signedness == .signed) @compileError("signed integers are not serializable: " ++ @typeName(T));
            if (T == usize) {
                // `usize` is always 8 bytes on the wire regardless of the
                // target pointer width (zero-extended), so the format is
                // portable across 32/64-bit.
                const v: u64 = value;
                var tmp: [8]u8 = undefined;
                inline for (0..8) |b| tmp[b] = @truncate(v >> @intCast(8 * b));
                try list.appendSlice(allocator, &tmp);
                return;
            }
            const n_bytes = @divExact(i.bits, 8);
            var tmp: [n_bytes]u8 = undefined;
            inline for (0..n_bytes) |b| tmp[b] = @truncate(value >> @intCast(8 * b));
            try list.appendSlice(allocator, &tmp);
        },
        .array => |a| {
            if (a.child == u8) {
                try list.appendSlice(allocator, &value);
            } else {
                inline for (value) |v| try writeValue(allocator, list, v);
            }
        },
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    const len: u64 = @intCast(value.len);
                    try writeValue(allocator, list, len);
                    for (value) |v| try writeValue(allocator, list, v);
                },
                .one, .many, .c => @compileError("single-item pointers are not serializable: " ++ @typeName(T)),
            }
        },
        .@"struct" => {
            const is_field = comptime isField(T);
            if (is_field) {
                if (comptime @hasDecl(T, "NUM_BYTES")) {
                    const bytes = value.toBytes();
                    try list.appendSlice(allocator, &bytes);
                } else {
                    var buf: [T.SIZE]u8 = undefined;
                    value.toBytes(&buf);
                    try list.appendSlice(allocator, &buf);
                }
                return;
            }
            inline for (std.meta.fields(T)) |f| {
                if (f.type == std.mem.Allocator) continue;
                if (comptime std.mem.eql(u8, f.name, "owns_entries")) continue;
                try writeValue(allocator, list, @field(value, f.name));
            }
        },
        .optional => {
            if (value) |payload| {
                try list.append(allocator, 1);
                try writeValue(allocator, list, payload);
            } else {
                try list.append(allocator, 0);
            }
        },
        else => @compileError("cannot serialize type " ++ @typeName(T)),
    }
}

/// Read a value of type `T` into `result`.
///
/// Contract: on error every allocation made while decoding `result` is
/// released again and `result` is left in an unusable state — callers must not
/// `deinit` it. On success `result` is a complete, owned value.
fn readValue(cursor: *Cursor, allocator: std.mem.Allocator, result: anytype, comptime T: type) !void {
    switch (@typeInfo(T)) {
        .bool => {
            const value = try cursor.byte();
            if (value > 1) return error.InvalidValue;
            result.* = value == 1;
        },
        .int => |i| {
            const n_bytes = comptime wireIntSize(T, i.bits, i.signedness);
            if (T == usize) {
                const bytes = try cursor.take(8);
                var v: u64 = 0;
                inline for (0..8) |b| v |= @as(u64, bytes[b]) << @intCast(8 * b);
                if (@as(u128, v) > @as(u128, std.math.maxInt(usize))) return error.Overflow;
                result.* = @intCast(v);
                return;
            }
            const bytes = try cursor.take(n_bytes);
            var v: T = 0;
            inline for (0..n_bytes) |b| v |= @as(T, bytes[b]) << @intCast(8 * b);
            result.* = v;
        },
        .array => |a| {
            if (a.child == u8) {
                const bytes = try cursor.take(@sizeOf(T));
                result.* = bytes[0..@sizeOf(T)].*;
            } else {
                inline for (0..a.len) |i| {
                    readValue(cursor, allocator, &result[i], a.child) catch |err| {
                        inline for (0..a.len) |j| {
                            if (j < i) deinitValue(allocator, &result[j]);
                        }
                        return err;
                    };
                }
            }
        },
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    const child = p.child;
                    const len = try cursor.sliceLen(child);
                    const slice = try allocator.alloc(child, len);
                    // On failure release the elements decoded so far, then the
                    // slice itself: a half-decoded slice is not the caller's
                    // to clean up.
                    var i: usize = 0;
                    while (i < len) : (i += 1) {
                        readValue(cursor, allocator, &slice[i], child) catch |err| {
                            for (slice[0..i]) |*element| deinitValue(allocator, element);
                            allocator.free(slice);
                            return err;
                        };
                    }
                    result.* = slice;
                },
                .one, .many, .c => @compileError("single-item pointers are not serializable: " ++ @typeName(T)),
            }
        },
        .@"struct" => {
            const is_field = comptime isField(T);
            if (is_field) {
                if (comptime @hasDecl(T, "NUM_BYTES")) {
                    const bytes = try cursor.take(T.NUM_BYTES);
                    result.* = T.fromBytes(bytes) catch return error.InvalidValue;
                } else {
                    const bytes = try cursor.take(T.SIZE);
                    result.* = T.fromBytes(bytes[0..T.SIZE].*);
                }
                return;
            }
            inline for (std.meta.fields(T), 0..) |f, idx| {
                if (f.type == std.mem.Allocator) {
                    @field(result, f.name) = allocator;
                    continue;
                }
                if (comptime std.mem.eql(u8, f.name, "owns_entries")) continue;
                readValue(cursor, allocator, &@field(result, f.name), f.type) catch |err| {
                    // Roll back every field decoded before this one, otherwise
                    // a malformed input leaks the prefix it managed to build.
                    inline for (std.meta.fields(T), 0..) |g, j| {
                        if (j < idx) deinitValue(allocator, &@field(result, g.name));
                    }
                    return err;
                };
            }
            if (@hasField(T, "owns_entries")) @field(result, "owns_entries") = true;
        },
        .optional => |o| {
            const flag = try cursor.byte();
            if (flag > 1) return error.InvalidValue;
            if (flag == 1) {
                // A failing `readValue` rolls back its own partial state.
                var payload: o.child = undefined;
                try readValue(cursor, allocator, &payload, o.child);
                result.* = payload;
            } else {
                result.* = null;
            }
        },
        else => @compileError("cannot deserialize type " ++ @typeName(T)),
    }
}

/// Free everything `readValue` may have allocated inside `value`.
///
/// Mirrors `readValue` field for field and never calls user `deinit` methods:
/// it also runs on partially decoded values whose later fields are still
/// uninitialized. Types that own memory outside their own fields cannot be
/// rolled back this way; nothing in this repository does.
fn deinitValue(allocator: std.mem.Allocator, value: anytype) void {
    const T = @TypeOf(value.*);
    // `std.mem.Allocator` is stored, not owned: nothing to release.
    if (T == std.mem.Allocator) return;
    switch (@typeInfo(T)) {
        .bool, .int, .@"enum", .@"union", .@"opaque" => {},
        .array => |a| {
            if (a.child != u8) {
                for (&value.*) |*element| deinitValue(allocator, element);
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                // Elements were allocated one by one by `readValue`, so they
                // have to be released one by one too before the slice itself.
                for (value.*) |*element| deinitValue(allocator, element);
                allocator.free(value.*);
            },
            .one, .many, .c => {},
        },
        .@"struct" => {
            if (comptime isField(T)) return;
            inline for (std.meta.fields(T)) |f| {
                if (f.type == std.mem.Allocator) continue;
                if (comptime std.mem.eql(u8, f.name, "owns_entries")) continue;
                deinitValue(allocator, &@field(value.*, f.name));
            }
        },
        .optional => {
            if (value.*) |*payload| deinitValue(allocator, payload);
        },
        else => @compileError("cannot release type " ++ @typeName(T)),
    }
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos > self.bytes.len or n > self.bytes.len - self.pos) return error.UnexpectedEnd;
        const out = self.bytes[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    fn byte(self: *Cursor) !u8 {
        const b = try self.take(1);
        return b[0];
    }

    fn remaining(self: *const Cursor) usize {
        return self.bytes.len - self.pos;
    }

    fn readU64(self: *Cursor) !u64 {
        var v: u64 = 0;
        const bytes = try self.take(8);
        inline for (0..8) |b| v |= @as(u64, bytes[b]) << @intCast(8 * b);
        return v;
    }

    /// Validate a `u64` length prefix against the bytes that are left and
    /// return it as a `usize`.
    ///
    /// Rejecting an over-long prefix *before* `allocator.alloc` is what keeps
    /// untrusted input from requesting a huge allocation (or tripping an
    /// `@intCast` overflow on 32-bit targets). The lower bound per element is
    /// `minWireSize(child)`, so the allocation can never exceed the input by
    /// more than the fixed memory-per-wire-byte ratio of the type itself.
    fn sliceLen(self: *Cursor, comptime child: type) !usize {
        const declared = try self.readU64();
        if (declared > std.math.maxInt(usize)) return error.InvalidLength;
        const available = self.remaining();
        const min_size = comptime minWireSize(child);
        if (min_size == 0) {
            if (declared > available) return error.InvalidLength;
        } else if (declared > available / min_size) {
            return error.InvalidLength;
        }
        return @intCast(declared);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "golden wire layout is stable" {
    // Pins the exact byte layout: field order, little-endian ints, u64 length
    // prefixes, the optional presence flag, and raw [N]u8 arrays. Any change
    // to the wire format breaks this test.
    const alloc = std.testing.allocator;
    const G = struct {
        name: [3]u8,
        count: u32,
        rows: []const u16,
        flag: bool,
        maybe: ?[2]u8,
    };
    const value = G{
        .name = .{ 'a', 'b', 'c' },
        .count = 0x01020304,
        .rows = &.{ 0x0102, 0x0304 },
        .flag = true,
        .maybe = .{ 0xde, 0xad },
    };
    const expected = [_]u8{
        'a', 'b', 'c', // name
        0x04, 0x03, 0x02, 0x01, // count u32 LE
        0x02, 0, 0, 0, 0, 0, 0, 0, // rows len u64 LE
        0x02, 0x01, 0x04, 0x03, // rows[0], rows[1] u16 LE
        0x01, // flag
        0x01, 0xde, 0xad, // maybe present + payload
    };
    const bytes = try serialize(alloc, value);
    defer alloc.free(bytes);
    try testing.expectEqualSlices(u8, &expected, bytes);
}

test "round-trip a nested slice-of-slices struct" {
    const alloc = std.testing.allocator;
    const S = struct {
        name: [3]u8,
        count: usize,
        rows: []const []const u32,
        maybe: ?[]const u8,

        fn deinit(self: @This(), a: std.mem.Allocator) void {
            for (self.rows) |r| a.free(r);
            a.free(self.rows);
            if (self.maybe) |m| a.free(m);
        }
    };
    const rows = [_][]const u32{ &.{ 1, 2, 3 }, &.{}, &.{4} };
    const maybe = [_]u8{ 0xde, 0xad };
    const value = S{ .name = .{ 'a', 'b', 'c' }, .count = 7, .rows = &rows, .maybe = &maybe };

    const bytes = try serialize(alloc, value);
    defer alloc.free(bytes);
    const back = try deserialize(alloc, bytes, S);
    defer back.deinit(alloc);

    try testing.expectEqualStrings("abc", &back.name);
    try testing.expectEqual(@as(usize, 7), back.count);
    try testing.expectEqual(@as(usize, 3), back.rows.len);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, back.rows[0]);
    try testing.expectEqual(@as(usize, 0), back.rows[1].len);
    try testing.expectEqualSlices(u32, &.{4}, back.rows[2]);
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad }, back.maybe.?);
}

const S2 = struct {
    const Self = @This();
    pub const SIZE = 2;
    pub fn toBytes(v: Self, out: *[SIZE]u8) void {
        out[0] = v.lo;
        out[1] = v.hi;
    }
    pub fn fromBytes(bytes: [SIZE]u8) Self {
        return .{ .lo = bytes[0], .hi = bytes[1] };
    }
    lo: u8,
    hi: u8,
};

test "field-element types use their toBytes/fromBytes" {
    const alloc = std.testing.allocator;
    const value = S2{ .lo = 0x11, .hi = 0x22 };
    const bytes = try serialize(alloc, value);
    defer alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22 }, bytes);
    const back = try deserialize(alloc, bytes, S2);
    try testing.expectEqual(@as(u8, 0x11), back.lo);
    try testing.expectEqual(@as(u8, 0x22), back.hi);
}

const S3 = struct {
    const NUM_BYTES: usize = 2;
    value: u16,

    fn toBytes(self: S3) [NUM_BYTES]u8 {
        return .{ @truncate(self.value), @truncate(self.value >> 8) };
    }

    fn fromBytes(bytes: []const u8) !S3 {
        if (bytes.len != NUM_BYTES) return error.InvalidLength;
        return .{ .value = @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8) };
    }
};

test "NUM_BYTES fields and strict flags are supported" {
    const alloc = std.testing.allocator;
    const bytes = try serialize(alloc, S3{ .value = 0x1234 });
    defer alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, bytes);
    const back = try deserialize(alloc, bytes, S3);
    try testing.expectEqual(@as(u16, 0x1234), back.value);
    try testing.expectError(error.InvalidValue, deserialize(alloc, &[_]u8{2}, bool));
    try testing.expectError(error.InvalidValue, deserialize(alloc, &[_]u8{2}, ?u8));
}

test "rejects truncated and trailing bytes" {
    const alloc = std.testing.allocator;
    const bytes = try serialize(alloc, [_]u32{ 1, 2 });
    defer alloc.free(bytes);
    const trailing = try alloc.alloc(u8, bytes.len + 1);
    defer alloc.free(trailing);
    @memcpy(trailing[0..bytes.len], bytes);
    trailing[bytes.len] = 0;
    try testing.expectError(error.TrailingBytes, deserialize(alloc, trailing, [2]u32));
    try testing.expectError(error.UnexpectedEnd, deserialize(alloc, bytes[0..3], [2]u32));
}

test "a length prefix larger than the remaining input is rejected" {
    const alloc = std.testing.allocator;
    var buf: [24]u8 = [_]u8{0} ** 24;

    // len = 2^64-1 with nothing following it.
    std.mem.writeInt(u64, buf[0..8], std.math.maxInt(u64), .little);
    try testing.expectError(error.InvalidLength, deserialize(alloc, &buf, []const u32));

    // len = 2^40 with nothing following it.
    std.mem.writeInt(u64, buf[0..8], 1 << 40, .little);
    try testing.expectError(error.InvalidLength, deserialize(alloc, &buf, []const u8));

    // Three inner slices need at least 3 * 8 bytes; only 16 are left.
    std.mem.writeInt(u64, buf[0..8], 3, .little);
    try testing.expectError(error.InvalidLength, deserialize(alloc, &buf, []const []const u32));

    // Two 16-byte structs need 32 bytes; only 16 are left.
    std.mem.writeInt(u64, buf[0..8], 2, .little);
    try testing.expectError(error.InvalidLength, deserialize(alloc, &buf, []const Inner));

    // One element declared, zero bytes left for it.
    const lone = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.InvalidLength, deserialize(alloc, &lone, []const u32));
    try testing.expectError(error.InvalidLength, deserialize(alloc, &lone, []const Inner));
}

test "an over-long length prefix never reaches the allocator" {
    // The first allocation fails: if the length prefix were trusted until
    // `allocator.alloc`, this would report OutOfMemory instead.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const huge = [_]u8{0xff} ** 8; // len = 2^64-1
    try testing.expectError(error.InvalidLength, deserialize(failing.allocator(), &huge, []const u32));
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);

    var failing2 = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const one_element = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 }; // len = 1, no element bytes
    try testing.expectError(error.InvalidLength, deserialize(failing2.allocator(), &one_element, []const u32));
    try testing.expectEqual(@as(usize, 0), failing2.alloc_index);
}

const Inner = struct { a: [8]u8, b: [8]u8 };

/// Allocator and `owns_entries` fields are stored, never owned: the rollback
/// must leave them alone.
const Holder = struct {
    allocator: std.mem.Allocator,
    entries: []u32,
    tail: []const u8,
    owns_entries: bool = false,
};

test "a failure in a later field rolls back the earlier ones" {
    const alloc = std.testing.allocator;
    // entries: len 2 + two u32 (fully decoded), tail: len 8 with no bytes.
    var buf: [24]u8 = [_]u8{0} ** 24;
    std.mem.writeInt(u64, buf[0..8], 2, .little);
    std.mem.writeInt(u32, buf[8..12], 0xdeadbeef, .little);
    std.mem.writeInt(u32, buf[12..16], 0xfeedface, .little);
    std.mem.writeInt(u64, buf[16..24], 8, .little);

    // `std.testing.allocator` reports a leak if `entries` is not released.
    try testing.expectError(error.InvalidLength, deserialize(alloc, &buf, Holder));
}

const NestedHolder = struct {
    rows: []const []const u32,
    tail: []const u8,
};

test "a failure inside a slice rolls back the elements already decoded" {
    const alloc = std.testing.allocator;
    // rows: two inner slices — the first with 2 u32 values, the second empty —
    // which consumes the whole input, so `tail` cannot even read its prefix.
    var buf: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, buf[0..8], 2, .little);
    std.mem.writeInt(u64, buf[8..16], 2, .little);
    std.mem.writeInt(u32, buf[16..20], 11, .little);
    std.mem.writeInt(u32, buf[20..24], 22, .little);
    std.mem.writeInt(u64, buf[24..32], 0, .little);

    // `rows` (and its first element) were fully decoded; both must be freed.
    try testing.expectError(error.UnexpectedEnd, deserialize(alloc, &buf, NestedHolder));
}

test "trailing bytes free the decoded value" {
    const alloc = std.testing.allocator;
    var buf: [21]u8 = [_]u8{0} ** 21;
    std.mem.writeInt(u64, buf[0..8], 1, .little);
    std.mem.writeInt(u32, buf[8..12], 7, .little);
    std.mem.writeInt(u64, buf[12..20], 0, .little);
    buf[20] = 0xff; // one stray trailing byte
    try testing.expectError(error.TrailingBytes, deserialize(alloc, &buf, Holder));
}

test "optional payloads are rolled back too" {
    const alloc = std.testing.allocator;
    const WithOptional = struct { flag: bool, maybe: ?[]const u32 };
    // optional present, 4 u32 declared, no bytes for them.
    var buf: [12]u8 = [_]u8{0} ** 12;
    buf[0] = 1;
    buf[1] = 1;
    std.mem.writeInt(u64, buf[2..10], 4, .little);
    try testing.expectError(error.InvalidLength, deserialize(alloc, &buf, WithOptional));

    // A short payload is caught by the length check: for a fixed-size element
    // the check is exact, so the cursor cannot run dry first.
    const truncated = [_]u8{ 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0xaa, 0xbb };
    try testing.expectError(error.InvalidLength, deserialize(alloc, &truncated, WithOptional));
}

test "an allocated optional payload is rolled back when a later field fails" {
    const alloc = std.testing.allocator;
    const Deep = struct { maybe: ?[]const u32, tail: [8]u8 };
    // optional present with one u32 (allocated), then a fixed 8-byte field
    // that the input no longer covers.
    var buf: [13]u8 = [_]u8{0} ** 13;
    buf[0] = 1;
    std.mem.writeInt(u64, buf[1..9], 1, .little);
    std.mem.writeInt(u32, buf[9..13], 0x1234, .little);
    try testing.expectError(error.UnexpectedEnd, deserialize(alloc, &buf, Deep));
}

test "a length prefix that does not fit fails before the optional payload runs" {
    const alloc = std.testing.allocator;
    const Deep = struct { maybe: ?[]const []const u8 };
    // present optional, outer len 1 (needs 8 bytes, only 5 are left).
    const bytes = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xaa, 0xbb, 0xcc };
    try testing.expectError(error.InvalidLength, deserialize(alloc, &bytes, Deep));
}

/// Has its own `deinit`, so the rollback must not call it on a partially
/// decoded value: `tail` is still uninitialized when `rows` has to be freed.
const WithDeinit = struct {
    rows: []const []const u32,
    tail: []const u8,

    fn deinit(self: WithDeinit, a: std.mem.Allocator) void {
        for (self.rows) |r| a.free(r);
        a.free(self.rows);
        a.free(self.tail);
    }
};

test "rollback mirrors the read logic instead of calling a user deinit" {
    const alloc = std.testing.allocator;
    // rows: two inner slices, the first holding two u32s, the second empty;
    // then nothing at all, so `tail` cannot be read.
    var buf: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, buf[0..8], 2, .little);
    std.mem.writeInt(u64, buf[8..16], 2, .little);
    std.mem.writeInt(u32, buf[16..20], 5, .little);
    std.mem.writeInt(u32, buf[20..24], 6, .little);
    std.mem.writeInt(u64, buf[24..32], 0, .little);

    // Three allocations (rows, rows[0], plus the read of rows[1]) must all be
    // released, and `deinit` must not be called on the half-built value.
    try testing.expectError(error.UnexpectedEnd, deserialize(alloc, &buf, WithDeinit));
}

test "a valid payload with empty elements still round-trips" {
    // The `minWireSize` bound must not reject legitimate minimal encodings:
    // an empty inner slice still costs its 8-byte length prefix.
    const alloc = std.testing.allocator;
    const S = struct { rows: []const []const u32 };
    const value = S{ .rows = &.{ &.{}, &.{}, &.{} } };
    const bytes = try serialize(alloc, value);
    defer alloc.free(bytes);
    const back = try deserialize(alloc, bytes, S);
    defer alloc.free(back.rows);
    try testing.expectEqual(@as(usize, 3), back.rows.len);
    for (back.rows) |row| try testing.expectEqual(@as(usize, 0), row.len);
}

// ---------------------------------------------------------------------------
// Differential against an encoder written from the documented rules
// ---------------------------------------------------------------------------
//
// Every expected byte string below was produced by a Python encoder written
// from this module's own docstring -- little-endian integers, `u64` length
// prefixes, declaration-order fields with `std.mem.Allocator` and
// `owns_entries` skipped, one presence byte per optional, raw bytes for `[N]u8`
// -- and from nothing in this file. It independently reproduces the
// hand-written golden vector above, which is the point: two derivations of the
// same specification agreeing with each other and with the code.
//
// The rejection cases come from the specification too. A conforming decoder
// has to refuse trailing bytes, a length prefix that outruns the input, and a
// presence byte outside {0, 1}; the truncated buffers have to fail wherever
// they are cut.

/// The struct the hand-written golden vector above uses, hoisted so the
/// rejection cases can name it as a decode target.
const SerGolden = struct {
    name: [3]u8,
    count: u32,
    rows: []const u16,
    flag: bool,
    maybe: ?[2]u8,
};

const SerCase = struct {
    name: []const u8,
    hex: []const u8,
};

/// Which type the decoder is asked for, and the error the format requires.
/// Both come from the specification, not from the implementation: a length
/// prefix is only an over-declaration when the bytes behind it cannot hold the
/// elements, so the target type is part of the contract being pinned.
const SerTarget = enum { u8, slice, bool, golden };

const SerReject = struct {
    name: []const u8,
    hex: []const u8,
    target: SerTarget,
    expected: anyerror,
};

/// Decode a hex literal from the oracle into a caller-owned buffer.
///
/// Run time, not comptime: the rejection cases are iterated at run time, and a
/// comptime reader would make the whole table a compile-time computation for no
/// gain -- a fixture is data, and data does not have to be evaluated early to
/// be checked.
fn serHex(h: []const u8, buf: []u8) ![]u8 {
    if (h.len != buf.len * 2) return error.MalformedOracleLiteral;
    _ = std.fmt.hexToBytes(buf, h) catch return error.MalformedOracleLiteral;
    return buf;
}

const ser_cases = [_]SerCase{
    .{ .name = "the golden struct: raw bytes, u32, a slice, a bool and a present optional", .hex = "616263040302010200000000000000020104030101dead" },
    .{ .name = "an absent optional and an empty slice", .hex = "01ffffffffffffffff000000000000000000" },
    .{ .name = "usize at both widths, zero-extended to eight bytes", .hex = "00000000000000000700000000000100" },
    .{ .name = "zero and all-ones for every unsigned width", .hex = "00ff0000ffff00000000ffffffff0000000000000000ffffffffffffffff" },
    .{ .name = "a slice of slices of structs, each with an optional", .hex = "020000000000000002000000000000000b0a0101ffff000100000000000000010000" },
    .{ .name = "arrays of elements and of arrays", .hex = "0100000002000000030000000400000001000001" },
    .{ .name = "32 bytes as a raw array, and 32 bytes as a slice of u8", .hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2000000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" },
};

const ser_rejects = [_]SerReject{
    .{ .name = "a trailing byte after a complete u8", .hex = "616263040302010200000000000000020104030101dead00", .target = .u8, .expected = error.TrailingBytes },
    .{ .name = "a length prefix of 2^40 elements", .hex = "00000000000100000000000000000000", .target = .slice, .expected = error.InvalidLength },
    .{ .name = "a length prefix of 5 elements over 4 bytes", .hex = "050000000000000001020304", .target = .slice, .expected = error.InvalidLength },
    .{ .name = "a presence byte outside {0, 1}", .hex = "02", .target = .bool, .expected = error.InvalidValue },
    .{ .name = "a struct truncated inside its last field", .hex = "616263040302010200000000000000020104030101de", .target = .golden, .expected = error.UnexpectedEnd },
    .{ .name = "an empty input for a struct", .hex = "", .target = .golden, .expected = error.UnexpectedEnd },
    .{ .name = "a length prefix of 2^32 elements over 32 bytes", .hex = "0000000001000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", .target = .slice, .expected = error.InvalidLength },
};

/// Serialize `value`, compare the bytes with the oracle's, then read the
/// oracle's bytes back and check the value survives a second serialization.
fn serExpectWire(comptime T: type, value: T, comptime hex: []const u8) !void {
    const alloc = testing.allocator;
    var buffer: [256]u8 = undefined;
    const want = try serHex(hex, buffer[0 .. hex.len / 2]);

    const got = try serialize(alloc, value);
    defer alloc.free(got);
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("serialization: fixture de {d} bytes\n  esperado {x}\n  obtenido {x}\n", .{
            want.len, want, got,
        });
        return error.TestExpectedEqual;
    }

    var back = try deserialize(alloc, want, T);
    defer deinitValue(alloc, &back);
    const again = try serialize(alloc, back);
    defer alloc.free(again);
    try testing.expectEqualSlices(u8, want, again);
}

test "serialization: the wire bytes match an encoder written from the documented rules" {
    try serExpectWire(SerGolden, .{
        .name = .{ 'a', 'b', 'c' },
        .count = 0x01020304,
        .rows = &.{ 0x0102, 0x0304 },
        .flag = true,
        .maybe = .{ 0xde, 0xad },
    }, ser_cases[0].hex);

    const Opts = struct {
        here: ?u64,
        there: ?u64,
        none: []const u8,
    };
    try serExpectWire(Opts, .{
        .here = 0xFFFFFFFFFFFFFFFF,
        .there = null,
        .none = &.{},
    }, ser_cases[1].hex);

    const Sizes = struct { small: usize, large: usize };
    try serExpectWire(Sizes, .{ .small = 0, .large = (1 << 48) + 7 }, ser_cases[2].hex);

    const Bounds = struct {
        a: u8,
        b: u8,
        c: u16,
        d: u16,
        e: u32,
        f: u32,
        g: u64,
        h: u64,
    };
    try serExpectWire(Bounds, .{
        .a = 0,
        .b = 255,
        .c = 0,
        .d = 65535,
        .e = 0,
        .f = 0xFFFFFFFF,
        .g = 0,
        .h = 0xFFFFFFFFFFFFFFFF,
    }, ser_cases[3].hex);

    const Cell = struct { v: u16, m: ?bool };
    const Nested = struct { matrix: []const []const Cell };
    try serExpectWire(Nested, .{ .matrix = &.{
        &.{ .{ .v = 0x0A0B, .m = true }, .{ .v = 0xFFFF, .m = null } },
        &.{.{ .v = 1, .m = null }},
    } }, ser_cases[4].hex);

    const Arrays = struct {
        quad: [4]u32,
        grid: [2][2]bool,
    };
    try serExpectWire(Arrays, .{
        .quad = .{ 1, 2, 3, 4 },
        .grid = .{ .{ true, false }, .{ false, true } },
    }, ser_cases[5].hex);

    const Both = struct { raw: [32]u8, listed: []const u8 };
    var raw: [32]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @intCast(i);
    var listed: [32]u8 = undefined;
    for (&listed, 0..) |*b, i| b.* = @intCast(i);
    try serExpectWire(Both, .{ .raw = raw, .listed = &listed }, ser_cases[6].hex);
}

test "serialization: buffers the format requires a decoder to reject" {
    const alloc = testing.allocator;

    for (ser_rejects) |r| {
        var buffer: [256]u8 = undefined;
        const bytes = try serHex(r.hex, buffer[0 .. r.hex.len / 2]);
        switch (r.target) {
            .u8 => try testing.expectError(r.expected, deserialize(alloc, bytes, u8)),
            .slice => try testing.expectError(r.expected, deserialize(alloc, bytes, []const u8)),
            .bool => try testing.expectError(r.expected, deserialize(alloc, bytes, bool)),
            .golden => try testing.expectError(r.expected, deserialize(alloc, bytes, SerGolden)),
        }
    }
}
