//! Multi-scalar multiplication (MSM) via Pippenger bucket decomposition.
//!
//! Computes sum(points[i] * scalars[i]) in O(n·bits/c) group additions
//! instead of O(n·bits), where c is an adaptive window size.
//!
//! Generic over the curve's affine/projective point pair; scalars may be
//! any field type exposing toBytes() little-endian (e.g. Fr of either
//! pairing family).

const std = @import("std");

fn CoordField(comptime Aff: type) type {
    return @TypeOf(@as(Aff, undefined).x);
}

fn toProj(comptime Proj: type, p: anytype) Proj {
    if (p.infinity) return Proj.zero();
    return .{ .x = p.x, .y = p.y, .z = CoordField(@TypeOf(p)).one() };
}

/// Optimal window size for n scalar-point pairs.
pub fn windowSize(n: usize) usize {
    var c: usize = 1;
    var t = n;
    while (t > 0) : (t >>= 1) c += 1;
    return std.math.clamp(c, 3, 8);
}

pub fn msm(
    comptime Aff: type,
    comptime Proj: type,
    comptime Scalar: type,
    allocator: std.mem.Allocator,
    points: []const Aff,
    scalars: []const Scalar,
) !Proj {
    std.debug.assert(points.len == scalars.len);
    const n = points.len;
    if (n == 0) return Proj.zero();

    // Snapshot scalars as little-endian bytes once.
    const SBYTES = @sizeOf(@TypeOf(scalars[0].toBytes()));
    const BITS = SBYTES * 8;
    const all_bytes = try allocator.alloc([SBYTES]u8, n);
    defer allocator.free(all_bytes);
    for (scalars, 0..n) |s, i| all_bytes[i] = s.toBytes();

    const proj_points = try allocator.alloc(Proj, n);
    defer allocator.free(proj_points);
    for (points, 0..n) |p, i| proj_points[i] = toProj(Proj, p);

    const c = windowSize(n);
    const num_windows = (BITS + c - 1) / c;
    const num_buckets = (@as(usize, 1) << @intCast(c)) - 1;

    const buckets = try allocator.alloc(Proj, num_buckets);
    defer allocator.free(buckets);

    var result = Proj.zero();
    var first_window = true;

    var w: usize = num_windows;
    while (w > 0) {
        w -= 1;

        if (!first_window) {
            var k: usize = 0;
            while (k < c) : (k += 1) result = result.dbl();
        }

        for (buckets) |*b| b.* = Proj.zero();

        // Scatter into buckets by window value.
        for (proj_points, 0..n) |pt, i| {
            var idx: usize = 0;
            const base_bit = w * c;
            var j: usize = 0;
            while (j < c) : (j += 1) {
                const bit_pos = base_bit + j;
                if (bit_pos < BITS) {
                    const bit_i: u3 = @intCast(bit_pos % 8);
                    if ((all_bytes[i][bit_pos / 8] >> bit_i) & 1 == 1)
                        idx |= @as(usize, 1) << @intCast(j);
                }
            }
            if (idx != 0) buckets[idx - 1] = buckets[idx - 1].add(pt);
        }

        // Gather with running-sum trick, highest bucket first.
        var running = Proj.zero();
        var acc = Proj.zero();
        var bi = num_buckets;
        while (bi > 0) {
            bi -= 1;
            running = running.add(buckets[bi]);
            acc = acc.add(running);
        }
        result = result.add(acc);
        first_window = false;
    }
    return result;
}

// ============================================================================
// Tests
// ============================================================================

const stdt = std.testing;

test "msm: matches naive scalarMul+add" {
    const bn254 = @import("bn254.zig");
    const Fr = bn254.Fr;
    const G1P = bn254.G1Projective;

    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rand = prng.random();

    const n = 50;
    var pts: [n]bn254.G1 = undefined;
    var scs: [n]Fr = undefined;
    var naive = G1P.zero();

    for (0..n) |i| {
        pts[i] = bn254.G1_generator.scalarMul(@as(u64, i * 7 + 3));
        scs[i] = Fr.fromInt(rand.int(u32) | 1);
        naive = naive.add(toProj(G1P, pts[i]).scalarMul(scs[i].toU64()));
    }

    const fast = try msm(bn254.G1, G1P, Fr, stdt.allocator, &pts, &scs);
    try stdt.expect(fast.eql(naive));
}

test "msm: empty input returns identity" {
    const bn254 = @import("bn254.zig");
    const Fr = bn254.Fr;
    const r = try msm(bn254.G1, bn254.G1Projective, Fr, stdt.allocator, &.{}, &.{});
    try stdt.expect(r.isZero());
}

test "msm: single element equals scalarMul" {
    const bn254 = @import("bn254.zig");
    const Fr = bn254.Fr;
    const G1P = bn254.G1Projective;
    const pt = bn254.G1_generator;
    const s = Fr.fromInt(123456789);

    const fast = try msm(bn254.G1, G1P, Fr, stdt.allocator, &.{pt}, &.{s});
    const ref = toProj(G1P, pt).scalarMul(s.toU64());
    try stdt.expect(fast.eql(ref));
}

test "msm: zero scalar contributes nothing" {
    const bn254 = @import("bn254.zig");
    const Fr = bn254.Fr;
    const G1P = bn254.G1Projective;

    var pts: [2]bn254.G1 = undefined;
    pts[0] = bn254.G1_generator.scalarMul(5);
    pts[1] = bn254.G1_generator.scalarMul(9);

    const r = try msm(bn254.G1, G1P, Fr, stdt.allocator, &pts, &.{ Fr.zero(), Fr.fromInt(9) });
    const ref = toProj(G1P, pts[1]).scalarMul(@as(u64, 9));
    try stdt.expect(r.eql(ref));
}

test "msm: window size heuristic" {
    try stdt.expectEqual(@as(usize, 3), windowSize(1));
    try stdt.expectEqual(@as(usize, 7), windowSize(50));
    try stdt.expectEqual(@as(usize, 8), windowSize(4096));
}

fn _x() void {}
