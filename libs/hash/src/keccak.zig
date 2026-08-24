//! Keccak-256 and SHA3-256 hash functions.
//!
//! Keccak-f[1600] permutation with 24 rounds.

const std = @import("std");

const RC = [24]u64{
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a,
    0x8000000080008000, 0x000000000000808b, 0x0000000080000001,
    0x8000000080008081, 0x8000000000008009, 0x000000000000008a,
    0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089,
    0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
    0x000000000000800a, 0x800000008000000a, 0x8000000080008081,
    0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
};

const RHO = [24]u6{
    1,  3,  6,  10, 15, 21, 28, 36, 45, 55, 2,  14,
    27, 41, 56, 8,  25, 43, 62, 18, 39, 61, 20, 44,
};

const PI = [24]u5{
    10, 7,  11, 17, 18, 3, 5,  16, 8,  21, 24, 4,
    15, 23, 19, 13, 12, 2, 20, 14, 22, 9,  6,  1,
};

pub fn keccakF1600(state: *[25]u64) void {
    var a = state.*;
    var b: [25]u64 = undefined;
    var c: [5]u64 = undefined;
    var d: [5]u64 = undefined;

    for (0..24) |round| {
        // Theta
        for (0..5) |x| {
            c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
        }
        for (0..5) |x| {
            d[x] = c[(x + 4) % 5] ^ std.math.rotr(u64, c[(x + 1) % 5], 63);
        }
        for (0..25) |i| {
            a[i] ^= d[i % 5];
        }

        // Rho and Pi
        b[0] = a[0];
        var x: u5 = 1;
        var y_coord: u5 = 0;
        for (0..24) |i| {
            b[PI[i]] = std.math.rotr(u64, a[x + 5 * y_coord], RHO[i]);
            const new_x = y_coord;
            const new_y = (2 * x + 3 * y_coord) % 5;
            x = new_x;
            y_coord = new_y;
        }

        // Chi
        for (0..5) |y| {
            for (0..5) |x2| {
                a[x2 + 5 * y] = b[x2 + 5 * y] ^ (~b[(x2 + 1) % 5 + 5 * y] & b[(x2 + 2) % 5 + 5 * y]);
            }
        }

        // Iota
        a[0] ^= RC[round];
    }

    state.* = a;
}

fn absorb(state: *[25]u64, buf: []u8, rate: usize, input: []const u8) void {
    var in = input;
    while (in.len > 0) {
        const take = @min(rate - buf.len, in.len);
        @memcpy(buf[buf.len .. buf.len + take], in[0..take]);
        buf.len += take;
        in = in[take..];
        if (buf.len == rate) {
            for (0..rate / 8) |i| {
                state[i] ^= std.mem.readInt(u64, buf[i * 8 ..][0..8], .little);
            }
            keccakF1600(state);
            buf.len = 0;
        }
    }
}

fn finalizeAndSqueeze(state: *[25]u64, buf: []u8, rate: usize, out: []u8, delim: u8) void {
    // Padding
    buf[buf.len] = delim;
    buf.len += 1;
    @memset(buf[buf.len..], 0);
    buf[rate - 1] |= 0x80;

    for (0..rate / 8) |i| {
        state[i] ^= std.mem.readInt(u64, buf[i * 8 ..][0..8], .little);
    }
    keccakF1600(state);

    var out_off: usize = 0;
    while (out_off < out.len) {
        const to_write = @min(rate, out.len - out_off);
        for (0..to_write / 8) |i| {
            std.mem.writeInt(u64, out[out_off..][0..8], state[i], .little);
            out_off += 8;
        }
        const rem = to_write % 8;
        for (0..rem) |i| {
            out[out_off] = @truncate(state[to_write / 8] >> (@as(u6, @intCast(i)) * 8));
            out_off += 1;
        }
        if (out_off < out.len) {
            keccakF1600(state);
        }
    }
}

// ============================================================================
// Keccak-256
// ============================================================================

pub const Keccak256 = struct {
    pub const BLOCK_LEN = 136; // 1600 - 256*2 = 1088 bits = 136 bytes
    pub const OUT_LEN = 32;

    state: [25]u64,
    buf: [BLOCK_LEN]u8,
    buf_len: usize,

    pub fn init() Keccak256 {
        return .{
            .state = std.mem.zeroes([25]u64),
            .buf = undefined,
            .buf_len = 0,
        };
    }

    pub fn update(self: *Keccak256, input: []const u8) void {
        var in = input;
        while (in.len > 0) {
            const take = @min(BLOCK_LEN - self.buf_len, in.len);
            @memcpy(self.buf[self.buf_len .. self.buf_len + take], in[0..take]);
            self.buf_len += take;
            in = in[take..];
            if (self.buf_len == BLOCK_LEN) {
                for (0..BLOCK_LEN / 8) |i| {
                    self.state[i] ^= std.mem.readInt(u64, self.buf[i * 8 ..][0..8], .little);
                }
                keccakF1600(&self.state);
                self.buf_len = 0;
            }
        }
    }

    pub fn finalize(self: *Keccak256, out: *[OUT_LEN]u8) void {
        self.buf[self.buf_len] = 0x01; // Keccak delimiter
        self.buf_len += 1;
        @memset(self.buf[self.buf_len..], 0);
        self.buf[BLOCK_LEN - 1] |= 0x80;

        for (0..BLOCK_LEN / 8) |i| {
            self.state[i] ^= std.mem.readInt(u64, self.buf[i * 8 ..][0..8], .little);
        }
        keccakF1600(&self.state);

        for (0..OUT_LEN / 8) |i| {
            std.mem.writeInt(u64, out[i * 8 ..][0..8], self.state[i], .little);
        }
    }
};

pub fn keccak256(input: []const u8) [32]u8 {
    var hasher = Keccak256.init();
    hasher.update(input);
    var out: [32]u8 = undefined;
    hasher.finalize(&out);
    return out;
}

// ============================================================================
// SHA3-256
// ============================================================================

pub const Sha3_256 = struct {
    pub const BLOCK_LEN = 136;
    pub const OUT_LEN = 32;

    state: [25]u64,
    buf: [BLOCK_LEN]u8,
    buf_len: usize,

    pub fn init() Sha3_256 {
        return .{
            .state = std.mem.zeroes([25]u64),
            .buf = undefined,
            .buf_len = 0,
        };
    }

    pub fn update(self: *Sha3_256, input: []const u8) void {
        var in = input;
        while (in.len > 0) {
            const take = @min(BLOCK_LEN - self.buf_len, in.len);
            @memcpy(self.buf[self.buf_len .. self.buf_len + take], in[0..take]);
            self.buf_len += take;
            in = in[take..];
            if (self.buf_len == BLOCK_LEN) {
                for (0..BLOCK_LEN / 8) |i| {
                    self.state[i] ^= std.mem.readInt(u64, self.buf[i * 8 ..][0..8], .little);
                }
                keccakF1600(&self.state);
                self.buf_len = 0;
            }
        }
    }

    pub fn finalize(self: *Sha3_256, out: *[OUT_LEN]u8) void {
        self.buf[self.buf_len] = 0x06; // SHA3 delimiter
        self.buf_len += 1;
        @memset(self.buf[self.buf_len..], 0);
        self.buf[BLOCK_LEN - 1] |= 0x80;

        for (0..BLOCK_LEN / 8) |i| {
            self.state[i] ^= std.mem.readInt(u64, self.buf[i * 8 ..][0..8], .little);
        }
        keccakF1600(&self.state);

        for (0..OUT_LEN / 8) |i| {
            std.mem.writeInt(u64, out[i * 8 ..][0..8], self.state[i], .little);
        }
    }
};

pub fn sha3_256(input: []const u8) [32]u8 {
    var hasher = Sha3_256.init();
    hasher.update(input);
    var out: [32]u8 = undefined;
    hasher.finalize(&out);
    return out;
}
