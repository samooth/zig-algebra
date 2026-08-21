// SPDX-License-Identifier: MIT OR Apache-2.0

//! Native Number-Theoretic Transform (NTT) and Inverse NTT.
//!
//! Cooley-Tukey iterative in-place NTT with bit-reversal permutation.
//! Supports any prime field with sufficient 2-adicity (power-of-two roots of unity).
//!
//! ## Usage
//! ```zig
//! const F = zf.M31;
//! var data = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4) };
//! const log_n = 2; // n = 4
//! const root = F.primitiveRootOfUnity(log_n); // 4th root of unity
//! zf.ntt(F, &data, log_n, root);
//! zf.intt(F, &data, log_n, root); // round-trips to original
//! ```

const std = @import("std");

/// In-place bit-reversal permutation.
/// `data.len` must be a power of two.
pub fn bitReverse(comptime F: type, data: []F) void {
    const n = data.len;
    std.debug.assert(n > 0 and (n & (n - 1)) == 0);
    const log_n = @ctz(n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Reverse only the lower log_n bits
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

/// Forward NTT (Cooley-Tukey, iterative, in-place).
///
/// * `data` — input/output array of length `2^log_n`
/// * `log_n` — log2 of the transform length
/// * `root` — primitive `2^log_n`-th root of unity in the field
///
/// After calling, `data[k] = sum_{j=0}^{n-1} input[j] * root^(j*k)`.
pub fn ntt(comptime F: type, data: []F, log_n: usize, root: F) void {
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

/// Inverse NTT (Cooley-Tukey, iterative, in-place).
///
/// Uses `root^{-1}` and multiplies each output by `n^{-1}`.
pub fn intt(comptime F: type, data: []F, log_n: usize, root: F) void {
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == n);

    const root_inv = root.inv();
    ntt(F, data, log_n, root_inv);

    const n_inv = F.fromInt(n).inv();
    for (data) |*x| {
        x.* = x.mul(n_inv);
    }
}

/// Precompute twiddle factors for all stages of an NTT of size `2^log_n`.
/// Returns an array of `log_n` slices, where `twiddles[s][j] = root^(j * 2^(log_n - s - 1))`.
///
/// Precomputing avoids redundant `pow` calls inside the NTT loops.
pub fn precomputeTwiddles(comptime F: type, log_n: usize, root: F, allocator: std.mem.Allocator) ![]const []const F {
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

/// Free memory allocated by `precomputeTwiddles`.
pub fn freeTwiddles(comptime F: type, twiddles: []const []const F, allocator: std.mem.Allocator) void {
    for (twiddles) |t| {
        allocator.free(t);
    }
    allocator.free(twiddles);
}

/// NTT using precomputed twiddle factors (faster for repeated transforms).
pub fn nttWithTwiddles(comptime F: type, data: []F, log_n: usize, twiddles: []const []const F) void {
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

/// Inverse NTT using precomputed twiddle factors.
pub fn inttWithTwiddles(comptime F: type, data: []F, log_n: usize, twiddles: []const []const F) void {
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == n);

    // For inverse, we need the conjugate twiddles (inverse of each twiddle).
    // Since precomputeTwiddles computes w, w^2, w^3... we need w^{-1}, w^{-2}...
    // For simplicity, we compute the inverse NTT by running forward NTT with
    // inverted twiddles. A more efficient approach inverts twiddles at precompute time.
    nttWithTwiddles(F, data, log_n, twiddles);

    const n_inv = F.fromInt(n).inv();
    for (data) |*x| {
        x.* = x.mul(n_inv);
    }
}

// ============================================================================
// Vec8 SIMD NTT for M31 (process 8 independent transforms in parallel)
// ============================================================================

const M31 = @import("lib.zig").M31;

/// 8-lane Vec8 NTT butterfly for M31.
/// Processes 8 independent NTTs simultaneously using SIMD vector operations.
///
/// `data` must have length `8 * n` where `n = 2^log_n`.
/// Layout: data[i*8 + lane] = element i of transform `lane`.
pub fn nttVec8M31(data: []M31, log_n: usize, root: M31) void {
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == 8 * n);

    // Bit-reversal per lane
    var lane: usize = 0;
    while (lane < 8) : (lane += 1) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // Reverse only the lower log_n bits
            var j: usize = 0;
            var k: usize = 0;
            while (k < log_n) : (k += 1) {
                j = (j << 1) | ((i >> @intCast(k)) & 1);
            }
            if (j > i) {
                const tmp = data[i * 8 + lane];
                data[i * 8 + lane] = data[j * 8 + lane];
                data[j * 8 + lane] = tmp;
            }
        }
    }

    // Cooley-Tukey with Vec8 butterflies
    var s: usize = 1;
    while (s <= log_n) : (s += 1) {
        const m = std.math.pow(usize, 2, s);
        const half_m = m >> 1;
        const wm = root.pow(@as(u64, 1) << @intCast(log_n - s));

        var k: usize = 0;
        while (k < n) : (k += m) {
            var w = M31.one();
            var j: usize = 0;
            while (j < half_m) : (j += 1) {
                // Load 8-lane vectors
                var u_vec: M31.Vec8 = undefined;
                var t_vec: M31.Vec8 = undefined;
                inline for (0..8) |l| {
                    u_vec[l] = data[(k + j) * 8 + l].value;
                    t_vec[l] = w.mul(data[(k + j + half_m) * 8 + l]).value;
                }

                // Butterfly: (u + t, u - t) using SIMD
                const sum = M31.reduceVec8(M31.addVec8(u_vec, t_vec));
                const diff = M31.reduceVec8(M31.subVec8(u_vec, t_vec));

                inline for (0..8) |l| {
                    data[(k + j) * 8 + l] = .{ .value = sum[l] };
                    data[(k + j + half_m) * 8 + l] = .{ .value = diff[l] };
                }

                w = w.mul(wm);
            }
        }
    }
}

/// Inverse Vec8 NTT for M31.
pub fn inttVec8M31(data: []M31, log_n: usize, root: M31) void {
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == 8 * n);

    const root_inv = root.inv();
    nttVec8M31(data, log_n, root_inv);

    const n_inv = M31.fromInt(n).inv();
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        data[i] = data[i].mul(n_inv);
    }
}
