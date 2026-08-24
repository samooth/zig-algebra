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
pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8, comptime T: type) !T {
    var cursor = Cursor{ .bytes = bytes };
    var value: T = undefined;
    try readValue(&cursor, allocator, &value, T);
    if (cursor.pos != cursor.bytes.len) return error.TrailingBytes;
    return value;
}

/// True when `T` is a field element: exposes `SIZE`, `toBytes`, `fromBytes`.
fn isField(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "SIZE") and @hasDecl(T, "toBytes") and @hasDecl(T, "fromBytes");
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
                var buf: [T.SIZE]u8 = undefined;
                value.toBytes(&buf);
                try list.appendSlice(allocator, &buf);
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

fn readValue(cursor: *Cursor, allocator: std.mem.Allocator, result: anytype, comptime T: type) !void {
    switch (@typeInfo(T)) {
        .bool => result.* = (try cursor.byte()) == 1,
        .int => |i| {
            if (i.signedness == .signed) @compileError("signed integers are not serializable: " ++ @typeName(T));
            if (T == usize) {
                const bytes = try cursor.take(8);
                var v: u64 = 0;
                inline for (0..8) |b| v |= @as(u64, bytes[b]) << @intCast(8 * b);
                result.* = @intCast(v);
                return;
            }
            const n_bytes = @divExact(i.bits, 8);
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
                inline for (0..a.len) |i| try readValue(cursor, allocator, &result[i], a.child);
            }
        },
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    const len = try cursor.readU64();
                    const child = p.child;
                    const slice = try allocator.alloc(child, @intCast(len));
                    errdefer allocator.free(slice);
                    for (0..@as(usize, @intCast(len))) |i| try readValue(cursor, allocator, &slice[i], child);
                    result.* = slice;
                },
                .one, .many, .c => @compileError("single-item pointers are not serializable: " ++ @typeName(T)),
            }
        },
        .@"struct" => {
            const is_field = comptime isField(T);
            if (is_field) {
                const bytes = try cursor.take(T.SIZE);
                result.* = T.fromBytes(bytes[0..T.SIZE].*);
                return;
            }
            inline for (std.meta.fields(T)) |f| {
                if (f.type == std.mem.Allocator) {
                    @field(result, f.name) = allocator;
                    continue;
                }
                if (comptime std.mem.eql(u8, f.name, "owns_entries")) continue;
                try readValue(cursor, allocator, &@field(result, f.name), f.type);
            }
            if (@hasField(T, "owns_entries")) @field(result, "owns_entries") = true;
        },
        .optional => |o| {
            const flag = try cursor.byte();
            if (flag == 1) {
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

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return error.UnexpectedEnd;
        const out = self.bytes[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    fn byte(self: *Cursor) !u8 {
        const b = try self.take(1);
        return b[0];
    }

    fn readU64(self: *Cursor) !u64 {
        var v: u64 = 0;
        const bytes = try self.take(8);
        inline for (0..8) |b| v |= @as(u64, bytes[b]) << @intCast(8 * b);
        return v;
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
