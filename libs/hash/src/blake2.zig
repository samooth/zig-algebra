const std = @import("std");

const StdBlake2b256 = std.crypto.hash.blake2.Blake2b256;
const StdBlake2s256 = std.crypto.hash.blake2.Blake2s256;

pub const Blake2b256 = struct {
    const Self = @This();

    pub const BLOCK_LEN = StdBlake2b256.block_length;
    pub const OUT_LEN = StdBlake2b256.digest_length;
    pub const KEY_LEN = StdBlake2b256.key_length_max;

    inner: StdBlake2b256,

    pub fn init(key: ?[]const u8) Self {
        return .{ .inner = StdBlake2b256.init(.{ .key = key }) };
    }

    pub fn update(self: *Self, input: []const u8) void {
        self.inner.update(input);
    }

    pub fn finalize(self: *Self, out: *[OUT_LEN]u8) void {
        self.inner.final(out);
    }
};

pub fn blake2b256(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    StdBlake2b256.hash(input, &out, .{});
    return out;
}

pub const Blake2s256 = struct {
    const Self = @This();

    pub const BLOCK_LEN = StdBlake2s256.block_length;
    pub const OUT_LEN = StdBlake2s256.digest_length;
    pub const KEY_LEN = StdBlake2s256.key_length_max;

    inner: StdBlake2s256,

    pub fn init(key: ?[]const u8) Self {
        return .{ .inner = StdBlake2s256.init(.{ .key = key }) };
    }

    pub fn update(self: *Self, input: []const u8) void {
        self.inner.update(input);
    }

    pub fn finalize(self: *Self, out: *[OUT_LEN]u8) void {
        self.inner.final(out);
    }
};

pub fn blake2s256(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    StdBlake2s256.hash(input, &out, .{});
    return out;
}
