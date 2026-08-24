//! Blake2b and Blake2s hash functions (RFC 7693).

const std = @import("std");

// Sigma permutation for Blake2
const SIGMA = [12][16]u8{
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    .{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
    .{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
    .{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
    .{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
    .{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
    .{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
    .{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
    .{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
};

// ============================================================================
// Blake2b (64-bit words, 128-byte blocks, 12 rounds)
// ============================================================================

const Blake2bIV = [8]u64{
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
    0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
    0x510e527fade682d1, 0x9b05688c2b3e6c1f,
    0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
};

fn blake2bG(v: *[16]u64, a: usize, b: usize, c: usize, d: usize, x: u64, y: u64) void {
    v[a] = v[a] +% v[b] +% x;
    v[d] = std.math.rotr(u64, v[d] ^ v[a], 32);
    v[c] = v[c] +% v[d];
    v[b] = std.math.rotr(u64, v[b] ^ v[c], 24);
    v[a] = v[a] +% v[b] +% y;
    v[d] = std.math.rotr(u64, v[d] ^ v[a], 16);
    v[c] = v[c] +% v[d];
    v[b] = std.math.rotr(u64, v[b] ^ v[c], 63);
}

fn blake2bRound(v: *[16]u64, m: *const [16]u64, s: *const [16]u8) void {
    blake2bG(v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
    blake2bG(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
    blake2bG(v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
    blake2bG(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
    blake2bG(v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
    blake2bG(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
    blake2bG(v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
    blake2bG(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
}

fn blake2bCompress(h: *[8]u64, block: *const [128]u8, t: u128, f: bool, rounds: usize) void {
    var v: [16]u64 = undefined;
    @memcpy(v[0..8], h);
    @memcpy(v[8..16], &Blake2bIV);
    v[12] ^= @truncate(t);
    v[13] ^= @truncate(t >> 64);
    if (f) v[14] = ~v[14];

    var m: [16]u64 = undefined;
    for (0..16) |i| {
        m[i] = std.mem.readInt(u64, block[i * 8 ..][0..8], .little);
    }

    for (0..rounds) |i| {
        blake2bRound(&v, &m, &SIGMA[i]);
    }

    for (0..8) |i| {
        h[i] ^= v[i] ^ v[i + 8];
    }
}

pub const Blake2b256 = struct {
    pub const BLOCK_LEN = 128;
    pub const OUT_LEN = 32;
    pub const KEY_LEN = 64;

    h: [8]u64,
    buf: [BLOCK_LEN]u8,
    buf_len: u8,
    t: u128,

    pub fn init(key: ?[]const u8) Blake2b256 {
        var h = Blake2bIV;
        h[0] ^= 0x01010000 ^ @as(u64, if (key) |k| @intCast(k.len) else 0) << 8 ^ OUT_LEN;
        var s = Blake2b256{ .h = h, .buf = undefined, .buf_len = 0, .t = 0 };
        if (key) |k| {
            @memset(&s.buf, 0);
            @memcpy(s.buf[0..k.len], k);
            s.buf_len = KEY_LEN;
        }
        return s;
    }

    pub fn update(self: *Blake2b256, input: []const u8) void {
        var in = input;
        while (in.len > 0) {
            if (self.buf_len == BLOCK_LEN) {
                self.t += BLOCK_LEN;
                blake2bCompress(&self.h, &self.buf, self.t, false, 12);
                self.buf_len = 0;
            }
            const want = BLOCK_LEN - self.buf_len;
            const take = @min(want, in.len);
            @memcpy(self.buf[self.buf_len .. self.buf_len + take], in[0..take]);
            self.buf_len += @intCast(take);
            in = in[take..];
        }
    }

    pub fn finalize(self: *Blake2b256, out: *[OUT_LEN]u8) void {
        self.t += self.buf_len;
        @memset(self.buf[self.buf_len..], 0);
        blake2bCompress(&self.h, &self.buf, self.t, true, 12);
        for (0..OUT_LEN / 8) |i| {
            std.mem.writeInt(u64, out[i * 8 ..][0..8], self.h[i], .little);
        }
    }
};

pub fn blake2b256(input: []const u8) [32]u8 {
    var hasher = Blake2b256.init(null);
    hasher.update(input);
    var out: [32]u8 = undefined;
    hasher.finalize(&out);
    return out;
}

// ============================================================================
// Blake2s (32-bit words, 64-byte blocks, 10 rounds)
// ============================================================================

const Blake2sIV = [8]u32{
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
};

fn blake2sG(v: *[16]u32, a: usize, b: usize, c: usize, d: usize, x: u32, y: u32) void {
    v[a] = v[a] +% v[b] +% x;
    v[d] = std.math.rotr(u32, v[d] ^ v[a], 16);
    v[c] = v[c] +% v[d];
    v[b] = std.math.rotr(u32, v[b] ^ v[c], 12);
    v[a] = v[a] +% v[b] +% y;
    v[d] = std.math.rotr(u32, v[d] ^ v[a], 8);
    v[c] = v[c] +% v[d];
    v[b] = std.math.rotr(u32, v[b] ^ v[c], 7);
}

fn blake2sRound(v: *[16]u32, m: *const [16]u32, s: *const [16]u8) void {
    blake2sG(v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
    blake2sG(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
    blake2sG(v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
    blake2sG(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
    blake2sG(v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
    blake2sG(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
    blake2sG(v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
    blake2sG(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
}

fn blake2sCompress(h: *[8]u32, block: *const [64]u8, t: u64, f: bool, rounds: usize) void {
    var v: [16]u32 = undefined;
    @memcpy(v[0..8], h);
    @memcpy(v[8..16], &Blake2sIV);
    v[12] ^= @truncate(t);
    v[13] ^= @truncate(t >> 32);
    if (f) v[14] = ~v[14];

    var m: [16]u32 = undefined;
    for (0..16) |i| {
        m[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .little);
    }

    for (0..rounds) |i| {
        blake2sRound(&v, &m, &SIGMA[i]);
    }

    for (0..8) |i| {
        h[i] ^= v[i] ^ v[i + 8];
    }
}

pub const Blake2s256 = struct {
    pub const BLOCK_LEN = 64;
    pub const OUT_LEN = 32;
    pub const KEY_LEN = 32;

    h: [8]u32,
    buf: [BLOCK_LEN]u8,
    buf_len: u8,
    t: u64,

    pub fn init(key: ?[]const u8) Blake2s256 {
        var h = Blake2sIV;
        h[0] ^= 0x01010000 ^ @as(u32, if (key) |k| @intCast(k.len) else 0) << 8 ^ OUT_LEN;
        var s = Blake2s256{ .h = h, .buf = undefined, .buf_len = 0, .t = 0 };
        if (key) |k| {
            @memset(&s.buf, 0);
            @memcpy(s.buf[0..k.len], k);
            s.buf_len = KEY_LEN;
        }
        return s;
    }

    pub fn update(self: *Blake2s256, input: []const u8) void {
        var in = input;
        while (in.len > 0) {
            if (self.buf_len == BLOCK_LEN) {
                self.t += BLOCK_LEN;
                blake2sCompress(&self.h, &self.buf, self.t, false, 10);
                self.buf_len = 0;
            }
            const want = BLOCK_LEN - self.buf_len;
            const take = @min(want, in.len);
            @memcpy(self.buf[self.buf_len .. self.buf_len + take], in[0..take]);
            self.buf_len += @intCast(take);
            in = in[take..];
        }
    }

    pub fn finalize(self: *Blake2s256, out: *[OUT_LEN]u8) void {
        self.t += self.buf_len;
        @memset(self.buf[self.buf_len..], 0);
        blake2sCompress(&self.h, &self.buf, self.t, true, 10);
        for (0..OUT_LEN / 4) |i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], self.h[i], .little);
        }
    }
};

pub fn blake2s256(input: []const u8) [32]u8 {
    var hasher = Blake2s256.init(null);
    hasher.update(input);
    var out: [32]u8 = undefined;
    hasher.finalize(&out);
    return out;
}
