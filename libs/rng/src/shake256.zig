//! SHAKE256 XOF (Extendable-Output Function) used as a CSPRNG.
//!
//! SHAKE256 is based on the Keccak-f[1600] permutation with a capacity of 512 bits
//! (rate = 1088 bits = 136 bytes).  It provides arbitrary-length output and is
//! suitable for generating large amounts of pseudorandom data from a seed.
//!
//! # Usage
//! ```zig
//! var rng = Shake256Rng.init();
//! rng.absorbSeed("my seed material");
//! const bytes = rng.squeeze(32);
//! ```

const std = @import("std");
const keccak = @import("zig-hash").keccak;

/// Rate in bytes for SHAKE256: 1600 - 2*256 = 1088 bits = 136 bytes.
const RATE: usize = 136;

/// SHAKE256-based XOF PRNG.
pub const Shake256Rng = struct {
    /// Keccak-f[1600] state (25 lanes of u64).
    state: [25]u64,
    /// Absorption buffer.
    buf: [RATE]u8,
    /// Valid bytes in `buf`.
    buf_len: usize,
    /// Squeeze buffer (filled after each permutation).
    squeeze_buf: [RATE]u8,
    /// Bytes remaining in squeeze buffer.
    squeeze_avail: usize,
    /// True after `finalize` has been called.
    finalized: bool,

    const Self = @This();

    pub fn init() Self {
        return .{
            .state = std.mem.zeroes([25]u64),
            .buf = undefined,
            .buf_len = 0,
            .squeeze_buf = undefined,
            .squeeze_avail = 0,
            .finalized = false,
        };
    }

    /// Absorb arbitrary seed material into the sponge.
    pub fn absorbSeed(self: *Self, seed: []const u8) void {
        std.debug.assert(!self.finalized);
        var in = seed;
        while (in.len > 0) {
            if (self.buf_len == RATE) {
                self.absorbBlock();
            }
            const take = @min(RATE - self.buf_len, in.len);
            @memcpy(self.buf[self.buf_len .. self.buf_len + take], in[0..take]);
            self.buf_len += take;
            in = in[take..];
        }
    }

    /// Finalize absorption and switch to squeezing mode.
    pub fn finalize(self: *Self) void {
        std.debug.assert(!self.finalized);
        // SHAKE256 padding: 0x1F (domain separator for SHAKE) then 0x80
        self.buf[self.buf_len] = 0x1F;
        self.buf_len += 1;
        @memset(self.buf[self.buf_len..], 0);
        self.buf[RATE - 1] |= 0x80;
        self.absorbBlock();
        self.finalized = true;
        self.squeeze_avail = 0;
    }

    /// Squeeze `len` pseudorandom bytes.
    pub fn squeeze(self: *Self, len: usize, allocator: std.mem.Allocator) ![]u8 {
        if (!self.finalized) self.finalize();
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        var off: usize = 0;
        while (off < len) {
            if (self.squeeze_avail == 0) {
                keccak.keccakF1600(&self.state);
                for (0..RATE / 8) |i| {
                    std.mem.writeInt(u64, self.squeeze_buf[i * 8 ..][0..8], self.state[i], .little);
                }
                self.squeeze_avail = RATE;
            }
            const take = @min(self.squeeze_avail, len - off);
            const start = RATE - self.squeeze_avail;
            @memcpy(out[off .. off + take], self.squeeze_buf[start .. start + take]);
            off += take;
            self.squeeze_avail -= take;
        }
        return out;
    }

    /// Squeeze exactly 32 bytes.
    pub fn squeeze32(self: *Self, allocator: std.mem.Allocator) ![32]u8 {
        const s = try self.squeeze(32, allocator);
        defer allocator.free(s);
        var out: [32]u8 = undefined;
        @memcpy(&out, s);
        return out;
    }

    /// Squeeze exactly 64 bytes.
    pub fn squeeze64(self: *Self, allocator: std.mem.Allocator) ![64]u8 {
        const s = try self.squeeze(64, allocator);
        defer allocator.free(s);
        var out: [64]u8 = undefined;
        @memcpy(&out, s);
        return out;
    }

    /// Fill `out` with squeezed bytes (allocation-free for fixed-size slices).
    pub fn squeezeInto(self: *Self, out: []u8) void {
        if (!self.finalized) self.finalize();
        var off: usize = 0;
        while (off < out.len) {
            if (self.squeeze_avail == 0) {
                keccak.keccakF1600(&self.state);
                for (0..RATE / 8) |i| {
                    std.mem.writeInt(u64, self.squeeze_buf[i * 8 ..][0..8], self.state[i], .little);
                }
                self.squeeze_avail = RATE;
            }
            const take = @min(self.squeeze_avail, out.len - off);
            const start = RATE - self.squeeze_avail;
            @memcpy(out[off .. off + take], self.squeeze_buf[start .. start + take]);
            off += take;
            self.squeeze_avail -= take;
        }
    }

    fn absorbBlock(self: *Self) void {
        for (0..RATE / 8) |i| {
            self.state[i] ^= std.mem.readInt(u64, self.buf[i * 8 ..][0..8], .little);
        }
        keccak.keccakF1600(&self.state);
        self.buf_len = 0;
    }
};
