//! zig-serialization consumer: encode a structure, decode it back, and check the
//! wire bytes are the ones the format prescribes.
//!
//! The point of this example is the round trip *plus* a length check, because a
//! serializer that silently changes layout passes a round trip and breaks every
//! other implementation. The golden length is derived from the format's rules --
//! little-endian integers, a u64 prefix per slice, one presence byte per
//! optional -- and pinned here so a reordering or a widened prefix shows up.

const std = @import("std");
const serde = @import("zig-serialization");

const Point = struct {
    x: u32,
    y: u32,
    label: []const u8,
    tag: ?u8,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const value = Point{
        .x = 0x01020304,
        .y = 0x05060708,
        .label = "zig-algebra",
        .tag = 7,
    };

    const bytes = try serde.serialize(alloc, value);
    std.debug.print("zig-serialization: {d} bytes on the wire\n\n", .{bytes.len});
    std.debug.print("  ", .{});
    for (bytes, 0..) |b, i| {
        std.debug.print("{x:0>2} ", .{b});
        if ((i + 1) % 16 == 0) std.debug.print("\n  ", .{});
    }
    std.debug.print("\n", .{});

    // Format-derived length: 4 (x) + 4 (y) + 8 (label len) + 12 (label) +
    // 1 (presence) + 1 (tag) = 30.
    const expected_len = 4 + 4 + 8 + value.label.len + 1 + 1;
    std.debug.print("\n  expected length: {d}, actual: {d} -- {s}\n", .{
        expected_len,
        bytes.len,
        if (bytes.len == expected_len) "match" else "MISMATCH",
    });

    // Field order on the wire: x is little-endian, so the first four bytes are
    // the low word first. This is what a big-endian writer would get wrong, and
    // a round trip would not notice.
    try std.testing.expectEqual(@as(u8, 0x04), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x03), bytes[1]);

    const back = try serde.deserialize(alloc, bytes, Point);
    std.debug.print("  round trip: x={x} y={x} label=\"{s}\" tag={?d}\n", .{
        back.x, back.y, back.label, back.tag,
    });
    try std.testing.expect(back.x == value.x and back.y == value.y);
    try std.testing.expect(std.mem.eql(u8, back.label, value.label));
    try std.testing.expectEqual(value.tag, back.tag);

    // An absent optional takes a presence byte and no payload, so the same
    // struct without a tag is two bytes shorter.
    const bare = Point{ .x = 1, .y = 2, .label = "", .tag = null };
    const bare_bytes = try serde.serialize(alloc, bare);
    const bare_len = 4 + 4 + 8 + 0 + 1;
    std.debug.print("  absent optional: {d} bytes (expected {d}) -- {s}\n", .{
        bare_bytes.len, bare_len, if (bare_bytes.len == bare_len) "match" else "MISMATCH",
    });
    try std.testing.expectEqual(bare_len, bare_bytes.len);
}
