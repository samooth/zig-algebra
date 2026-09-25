// SPDX-License-Identifier: MIT OR Apache-2.0

//! Hash-to-curve implementation following RFC 9380.
//!
//! For curves with a = 0 (BN254, BLS12-381, Pasta), uses the
//! Shallue-van de Woestijne mapping (Section 6.6.1) which works
//! for any Weierstrass curve without requiring an isogeny map.
//!
//! Reference: https://www.rfc-editor.org/rfc/rfc9380

const std = @import("std");

pub const HashToFieldError = error{
    OutputTooLong,
    DstTooLong,
};

/// Expand message according to RFC 9380 expand_message_xmd with SHA-256.
pub fn expandMessageXmd(
    msg: []const u8,
    dst: []const u8,
    out: []u8,
) HashToFieldError!void {
    if (out.len > std.math.maxInt(u16)) return HashToFieldError.OutputTooLong;
    if (dst.len > std.math.maxInt(u8)) return HashToFieldError.DstTooLong;
    if (out.len == 0) return;

    const hash_len = 32;
    const zero_pad = [_]u8{0} ** 64;
    var len_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_bytes, @intCast(out.len), .big);
    const dst_len = [_]u8{@intCast(dst.len)};

    var b0: [hash_len]u8 = undefined;
    var h0 = std.crypto.hash.sha2.Sha256.init(.{});
    h0.update(&zero_pad);
    h0.update(msg);
    h0.update(&len_bytes);
    h0.update(&[_]u8{0});
    h0.update(dst);
    h0.update(&dst_len);
    h0.final(&b0);

    var previous: [hash_len]u8 = undefined;
    var h1 = std.crypto.hash.sha2.Sha256.init(.{});
    h1.update(&b0);
    h1.update(&[_]u8{1});
    h1.update(dst);
    h1.update(&dst_len);
    h1.final(&previous);

    var offset: usize = 0;
    const first_len = @min(out.len, hash_len);
    @memcpy(out[0..first_len], previous[0..first_len]);
    offset = first_len;

    var block_index: usize = 2;
    while (offset < out.len) : (block_index += 1) {
        var mixed: [hash_len]u8 = undefined;
        for (0..hash_len) |i| mixed[i] = b0[i] ^ previous[i];

        var next: [hash_len]u8 = undefined;
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(&mixed);
        h.update(&[_]u8{@intCast(block_index)});
        h.update(dst);
        h.update(&dst_len);
        h.final(&next);

        const end = @min(offset + hash_len, out.len);
        @memcpy(out[offset..end], next[0 .. end - offset]);
        previous = next;
        offset = end;
    }
}

/// Hash a message to `count` field elements.
pub fn hashToField(
    comptime F: type,
    msg: []const u8,
    dst: []const u8,
    comptime count: usize,
) HashToFieldError![count]F {
    const p = F.MODULUS;
    const L = comptime blk: {
        var value = p;
        var bits: usize = 0;
        while (value != 0) : (bits += 1) value >>= 1;
        break :blk (bits + 128 + 7) / 8;
    };

    var expanded: [count * L]u8 = undefined;
    try expandMessageXmd(msg, dst, &expanded);

    var elements: [count]F = undefined;
    comptime var i: usize = 0;
    inline while (i < count) : (i += 1) {
        const start = i * L;
        var val: u512 = 0;
        for (start..start + L) |j| {
            val = (val << 8) | expanded[j];
        }
        elements[i] = F.fromInt(val % @as(u512, @intCast(p)));
    }
    return elements;
}

/// Shallue-van de Woestijne mapping (RFC 9380 Section 6.6.1).
///
/// Maps a field element u to a point on the curve y^2 = x^3 + b.
/// Works for ANY Weierstrass curve including a=0 curves.
///
/// Precomputed constants Z, tv4_const, tv6_const are computed at comptime.
pub fn CurvePoint(comptime F: type) type {
    return struct { x: F, y: F };
}

pub fn mapToCurveSvdW(
    comptime F: type,
    comptime a: F,
    comptime b: F,
    u: F,
) (error{SqrtFailed}!CurvePoint(F)) {
    // g(x) = x^3 + a*x + b. SVDW requires:
    //   (1) Z non-square, and (2) −g(Z)·(3Z² + 4A) square.
    // Search upward from 1; the first valid Z is found within a few tries.
    var Z: F = F.one();
    {
        var zi: usize = 1;
        while (zi < 64) : (zi += 1) {
            const cand = F.fromInt(zi);
            if (cand.legendre() != -1) continue;
            const gz = cand.mul(cand).mul(cand).add(a.mul(cand)).add(b);
            const tv4_arg = gz.neg().mul(cand.sqr().mulBy3().add(a.mulBy4()));
            if (tv4_arg.legendre() == 1) {
                Z = cand;
                break;
            }
        }
    }
    const Z2 = Z.mul(Z);
    const gZ = Z.mul(Z).mul(Z).add(a.mul(Z)).add(b); // g(Z) = Z^3 + a*Z + b

    // Precompute: tv4 = sqrt(-g(Z) * (3*Z^2 + 4*A))
    // For a=0: 3*Z^2 + 4*A = 3, so tv4 = sqrt(-3 * g(Z))
    const neg_gZ = gZ.neg();
    const three_z2_plus_4a = Z2.mulBy3().add(a.mulBy4());
    const tv4_arg = neg_gZ.mul(three_z2_plus_4a);
    var tv4 = tv4_arg.sqrt() orelse F.one();
    // Ensure sgn0(tv4) == 0 (make it "positive" = even integer representative)
    {
        const bytes = tv4.toBytes();
        if (bytes[0] & 1 == 1) tv4 = tv4.neg();
    }

    // Precompute: tv6 = -4 * g(Z) / (3*Z^2 + 4*A)
    const four = F.fromInt(4);
    const neg_four = four.neg();
    const tv6 = neg_four.mul(gZ).mul(three_z2_plus_4a.inv());

    // Step 1: tv1 = u^2 * g(Z)
    const tv1a = u.mul(u).mul(gZ);

    // Step 2: tv2 = 1 + tv1
    const tv2 = F.one().add(tv1a);

    // Step 3: tv1 = 1 - tv1
    const tv1 = F.one().sub(tv1a);

    // Step 4: tv3 = inv0(tv1 * tv2)
    const tv1_times_tv2 = tv1.mul(tv2);
    const tv3 = if (!tv1_times_tv2.isZero()) tv1_times_tv2.inv() else F.zero();

    // Step 7: tv5 = u * tv1 * tv3 * tv4
    const tv5 = u.mul(tv1).mul(tv3).mul(tv4);

    // Step 9: x1 = -Z/2 - tv5
    const half = F.fromInt(2).inv();
    const neg_z_half = Z.mul(half).neg();
    const x1 = neg_z_half.sub(tv5);

    // Step 10: x2 = -Z/2 + tv5
    const x2 = neg_z_half.add(tv5);

    // Step 11: x3 = Z + tv6 * (tv2^2 * tv3)^2
    const inner = tv2.mul(tv2).mul(tv3);
    const x3 = Z.add(tv6.mul(inner.mul(inner)));

    // Step 12-14: Try x1, x2, x3 in order
    const gx1 = x1.mul(x1).mul(x1).add(a.mul(x1)).add(b);
    if (gx1.legendre() == 1) {
        const y1 = gx1.sqrt() orelse return error.SqrtFailed;
        return .{ .x = x1, .y = y1 };
    }

    const gx2 = x2.mul(x2).mul(x2).add(a.mul(x2)).add(b);
    if (gx2.legendre() == 1) {
        const y2 = gx2.sqrt() orelse return error.SqrtFailed;
        return .{ .x = x2, .y = y2 };
    }

    const gx3 = x3.mul(x3).mul(x3).add(a.mul(x3)).add(b);
    const y3 = gx3.sqrt() orelse return error.SqrtFailed;
    return .{ .x = x3, .y = y3 };
}

/// Hash a message to a curve point (full pipeline).
///
/// Implements hash_to_curve from RFC 9380 Section 3:
/// 1. Hash message to 2 field elements
/// 2. Map each to a curve point via SvdW
/// 3. Add the two points
pub fn hashToCurve(
    comptime F: type,
    comptime a: F,
    comptime b: F,
    msg: []const u8,
    dst: []const u8,
) (error{ SqrtFailed, OutputTooLong, DstTooLong, SumIsInfinity }!CurvePoint(F)) {
    const us = try hashToField(F, msg, dst, 2);

    const p1 = try mapToCurveSvdW(F, a, b, us[0]);
    const p2 = try mapToCurveSvdW(F, a, b, us[1]);

    const AffinePoint = @import("weierstrass.zig").AffinePoint(F, a, b);
    const ep1 = AffinePoint{ .x = p1.x, .y = p1.y, .infinity = false };
    const ep2 = AffinePoint{ .x = p2.x, .y = p2.y, .infinity = false };
    const sum = ep1.add(ep2);
    if (sum.infinity) return error.SumIsInfinity;
    return .{ .x = sum.x, .y = sum.y };
}

// ============================================================================
// Tests
// ============================================================================

test "expandMessageXmd produces output" {
    var out: [64]u8 = undefined;
    try expandMessageXmd("test", "dst", &out);
    var out2: [64]u8 = undefined;
    try expandMessageXmd("test", "dst", &out2);
    std.debug.assert(std.mem.eql(u8, &out, &out2));
}

test "expandMessageXmd matches RFC 9380 vector" {
    var out: [32]u8 = undefined;
    try expandMessageXmd("", "QUUX-V01-CS02-with-expander-SHA256-128", &out);
    const expected = [_]u8{
        0x68, 0xa9, 0x85, 0xb8, 0x7e, 0xb6, 0xb4, 0x69,
        0x52, 0x12, 0x89, 0x11, 0xf2, 0xa4, 0x41, 0x2b,
        0xbc, 0x30, 0x2a, 0x9d, 0x75, 0x96, 0x67, 0xf8,
        0x7f, 0x7a, 0x21, 0xd8, 0x03, 0xf0, 0x72, 0x35,
    };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "hashToField is deterministic" {
    const F = @import("zig-field").Field(0xFFFFFFFF00000001);
    const us1 = try hashToField(F, "hello", "dst", 2);
    const us2 = try hashToField(F, "hello", "dst", 2);
    std.debug.assert(us1[0].eql(us2[0]));
    std.debug.assert(us1[1].eql(us2[1]));
}
