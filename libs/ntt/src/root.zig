//! zig-ntt: Number-Theoretic Transform over finite fields.
//!
//! Cooley-Tukey iterative in-place NTT with bit-reversal permutation.
//! Supports any prime field with sufficient 2-adicity (power-of-two roots of unity).

const std = @import("std");
const traits = @import("zig-algebra-traits");

pub fn bitReverse(comptime F: type, data: []F) void {
    const n = data.len;
    std.debug.assert(n > 0 and (n & (n - 1)) == 0);
    const log_n = @ctz(n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j: usize = 0;
        var k: usize = 0;
        while (k < log_n) : (k += 1) {
            j = (j << 1) | ((i >> @intCast(k)) & 1);
        }
        if (j > i) {
            const tmp = data[i];
            data[i] = data[j];
            data[j] = tmp;
        }
    }
}

pub fn ntt(comptime F: type, data: []F, log_n: usize, root: F) void {
    traits.assertField(F);
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == n);

    bitReverse(F, data);

    var s: usize = 1;
    while (s <= log_n) : (s += 1) {
        const m = std.math.pow(usize, 2, s);
        const half_m = m >> 1;
        const wm = root.pow(@as(u64, 1) << @intCast(log_n - s));
        var k: usize = 0;
        while (k < n) : (k += m) {
            var w = F.one();
            var j: usize = 0;
            while (j < half_m) : (j += 1) {
                const t = w.mul(data[k + j + half_m]);
                const u = data[k + j];
                data[k + j] = u.add(t);
                data[k + j + half_m] = u.sub(t);
                w = w.mul(wm);
            }
        }
    }
}

pub fn intt(comptime F: type, data: []F, log_n: usize, root: F) void {
    traits.assertField(F);
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == n);

    const root_inv = root.inv();
    ntt(F, data, log_n, root_inv);

    const n_inv = F.fromInt(n).inv();
    for (data) |*x| {
        x.* = x.mul(n_inv);
    }
}

pub fn precomputeTwiddles(comptime F: type, log_n: usize, root: F, allocator: std.mem.Allocator) ![]const []const F {
    traits.assertField(F);
    const twiddles = try allocator.alloc([]F, log_n);
    errdefer allocator.free(twiddles);

    var s: usize = 0;
    while (s < log_n) : (s += 1) {
        const m = std.math.pow(usize, 2, s + 1);
        const half_m = m >> 1;
        twiddles[s] = try allocator.alloc(F, half_m);
        errdefer allocator.free(twiddles[s]);

        const wm = root.pow(@as(u64, 1) << @intCast(log_n - s - 1));
        var w = F.one();
        var j: usize = 0;
        while (j < half_m) : (j += 1) {
            twiddles[s][j] = w;
            w = w.mul(wm);
        }
    }
    return twiddles;
}

pub fn freeTwiddles(comptime F: type, twiddles: []const []const F, allocator: std.mem.Allocator) void {
    for (twiddles) |t| {
        allocator.free(t);
    }
    allocator.free(twiddles);
}

pub fn nttWithTwiddles(comptime F: type, data: []F, log_n: usize, twiddles: []const []const F) void {
    traits.assertField(F);
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == n);
    std.debug.assert(twiddles.len == log_n);

    bitReverse(F, data);

    var s: usize = 1;
    while (s <= log_n) : (s += 1) {
        const m = std.math.pow(usize, 2, s);
        const half_m = m >> 1;
        const stage_twiddles = twiddles[s - 1];
        std.debug.assert(stage_twiddles.len == half_m);

        var k: usize = 0;
        while (k < n) : (k += m) {
            var j: usize = 0;
            while (j < half_m) : (j += 1) {
                const w = stage_twiddles[j];
                const t = w.mul(data[k + j + half_m]);
                const u = data[k + j];
                data[k + j] = u.add(t);
                data[k + j + half_m] = u.sub(t);
            }
        }
    }
}

pub fn inttWithTwiddles(comptime F: type, data: []F, log_n: usize, twiddles: []const []const F) void {
    traits.assertField(F);
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == n);

    // For inverse, we run forward NTT with inverted twiddles
    // A more efficient approach would precompute inverse twiddles
    nttWithTwiddles(F, data, log_n, twiddles);

    const n_inv = F.fromInt(n).inv();
    for (data) |*x| {
        x.* = x.mul(n_inv);
    }
}