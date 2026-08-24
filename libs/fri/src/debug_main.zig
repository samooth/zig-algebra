const std = @import("std");
const Transcript = @import("zig-transcript").Transcript;
const fri = @import("fri_lib");

const M31 = struct {
    const Self = @This();
    value: u32,
    pub const MODULUS: u32 = 0x7FFFFFFF;
    pub const NUM_BYTES: usize = 4;
    pub fn zero() Self { return .{ .value = 0 }; }
    pub fn one() Self { return .{ .value = 1 }; }
    pub fn fromInt(x: anytype) Self { return .{ .value = @intCast(@mod(x, Self.MODULUS)) }; }
    pub fn eql(a: Self, b: Self) bool { return a.value == b.value; }
    pub fn add(a: Self, b: Self) Self { return fromInt(a.value +% b.value); }
    pub fn mul(a: Self, b: Self) Self { return fromInt(@as(u64, a.value) *% b.value); }
    pub fn fromBytes(bytes: []const u8) !Self {
        const v = std.mem.readInt(u32, bytes[0..4], .little);
        if (v >= Self.MODULUS) return error.ValueOutOfRange;
        return .{ .value = v };
    }
    pub fn toBytes(self: Self) [4]u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.value, .little);
        return buf;
    }
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const n = 16;
    var p_evals: [n]M31 = undefined;
    for (0..n) |i| p_evals[i] = M31.fromInt(i);

    const config = fri.Config{ .domain_size = n, .final_length = 2, .num_queries = 3 };

    var pt = Transcript.init("dbg");
    var proof = try fri.prove(M31, gpa, &pt, &p_evals, config);
    defer proof.deinit(gpa);

    std.debug.print("num_rounds={d}\n", .{proof.num_rounds});
    std.debug.print("layers:\n", .{});
    for (proof.layers, 0..) |l, i| {
        std.debug.print("  [{d}] len={d} root={x}\n", .{ i, l.len, l.merkle_root[0] });
    }

    // Replay
    var vt = Transcript.init("dbg");
    _ = try fri.verify(M31, &vt, &proof, config);
}
