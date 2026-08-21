//! ChaCha20 stream cipher used as a CSPRNG (Cryptographically Secure PRNG).
//!
//! Implements the ChaCha20 core function (RFC 8439) as a deterministic
//! byte stream generator.  The keystream is generated in 64-byte blocks
//! and consumed on demand.
//!
//! # Usage
//! ```zig
//! var rng = ChaCha20Rng.initFromSeed(&[_]u8{0} ** 32);
//! const bytes = rng.randomBytes(16);
//! const u = rng.randomU64();
//! ```

const std = @import("std");

/// Number of ChaCha rounds (20 for standard ChaCha20).
const ROUNDS: u32 = 20;

/// ChaCha20 state: 16 x u32 words.
/// Layout: [constant; constant; key(8); counter(1); nonce(3)]
const State = [16]u32;

inline fn quarterRound(a: *u32, b: *u32, c: *u32, d: *u32) void {
    a.* +%= b.*;
    d.* = std.math.rotr(u32, d.* ^ a.*, 16);
    c.* +%= d.*;
    b.* = std.math.rotr(u32, b.* ^ c.*, 12);
    a.* +%= b.*;
    d.* = std.math.rotr(u32, d.* ^ a.*, 8);
    c.* +%= d.*;
    b.* = std.math.rotr(u32, b.* ^ c.*, 7);
}

fn blockFunction(state: *const State, output: *[64]u8) void {
    var x = state.*;
    var i: u32 = 0;
    while (i < ROUNDS / 2) : (i += 1) {
        // Column rounds
        quarterRound(&x[0], &x[4], &x[8], &x[12]);
        quarterRound(&x[1], &x[5], &x[9], &x[13]);
        quarterRound(&x[2], &x[6], &x[10], &x[14]);
        quarterRound(&x[3], &x[7], &x[11], &x[15]);
        // Diagonal rounds
        quarterRound(&x[0], &x[5], &x[10], &x[15]);
        quarterRound(&x[1], &x[6], &x[11], &x[12]);
        quarterRound(&x[2], &x[7], &x[8], &x[13]);
        quarterRound(&x[3], &x[4], &x[9], &x[14]);
    }
    for (0..16) |j| {
        x[j] +%= state[j];
        std.mem.writeInt(u32, output[j * 4 ..][0..4], x[j], .little);
    }
}

/// ChaCha20-based CSPRNG.
pub const ChaCha20Rng = struct {
    /// Internal ChaCha state (words 0..15).
    state: State,
    /// Keystream buffer (one block).
    buffer: [64]u8,
    /// Number of valid bytes remaining in `buffer`.
    available: u8,

    const Self = @This();

    /// Initialize from a 32-byte seed and a 12-byte nonce.
    pub fn init(seed: *const [32]u8, nonce: *const [12]u8) Self {
        var s: State = undefined;
        // Constants "expand 32-byte k"
        s[0] = 0x61707865;
        s[1] = 0x3320646e;
        s[2] = 0x79622d32;
        s[3] = 0x6b206574;
        // Key
        for (0..8) |i| {
            s[4 + i] = std.mem.readInt(u32, seed[i * 4 ..][0..4], .little);
        }
        // Counter
        s[12] = 0;
        // Nonce
        for (0..3) |i| {
            s[13 + i] = std.mem.readInt(u32, nonce[i * 4 ..][0..4], .little);
        }
        return .{
            .state = s,
            .buffer = undefined,
            .available = 0,
        };
    }

    /// Initialize from a 32-byte seed (nonce is zeroed).
    pub fn initFromSeed(seed: *const [32]u8) Self {
        const nonce = [_]u8{0} ** 12;
        return init(seed, &nonce);
    }

    /// Initialize from an unpredictable OS entropy source.
    pub fn initOsRandom() !Self {
        var seed: [32]u8 = undefined;
        try std.crypto.random.bytes(&seed);
        return initFromSeed(&seed);
    }

    /// Refill the internal buffer with a fresh keystream block.
    fn refill(self: *Self) void {
        blockFunction(&self.state, &self.buffer);
        self.available = 64;
        // Increment counter (word 12)
        self.state[12] +%= 1;
        if (self.state[12] == 0) {
            // Handle 64-bit counter overflow (word 12 + 13)
            self.state[13] +%= 1;
        }
    }

    /// Fill `out` with random bytes from the keystream.
    pub fn randomBytes(self: *Self, out: []u8) void {
        var remaining = out;
        while (remaining.len > 0) {
            if (self.available == 0) self.refill();
            const take = @min(self.available, remaining.len);
            const start = 64 - self.available;
            @memcpy(remaining[0..take], self.buffer[start .. start + take]);
            remaining = remaining[take..];
            self.available -= @intCast(take);
        }
    }

    /// Generate a uniformly random `u64`.
    pub fn randomU64(self: *Self) u64 {
        var buf: [8]u8 = undefined;
        self.randomBytes(&buf);
        return std.mem.readInt(u64, &buf, .little);
    }

    /// Generate a uniformly random `u32`.
    pub fn randomU32(self: *Self) u32 {
        var buf: [4]u8 = undefined;
        self.randomBytes(&buf);
        return std.mem.readInt(u32, &buf, .little);
    }

    /// Generate a uniformly random `u8`.
    pub fn randomU8(self: *Self) u8 {
        var buf: [1]u8 = undefined;
        self.randomBytes(&buf);
        return buf[0];
    }

    /// Generate a random boolean.
    pub fn randomBool(self: *Self) bool {
        return self.randomU8() & 1 == 1;
    }

    /// Generate a uniformly random value in `[0, max)` using rejection sampling.
    pub fn randomU64Bounded(self: *Self, max: u64) u64 {
        std.debug.assert(max > 0);
        if (max == 1) return 0;
        // Rejection sampling: find smallest n such that 2^n >= max
        const bits: u6 = @intCast(64 - @clz(max - 1));
        const mask = if (bits == 64) ~@as(u64, 0) else (@as(u64, 1) << bits) - 1;
        while (true) {
            const v = self.randomU64() & mask;
            if (v < max) return v;
        }
    }
};
