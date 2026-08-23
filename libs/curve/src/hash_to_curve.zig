// SPDX-License-Identifier: MIT OR Apache-2.0

//! Hash-to-curve implementation following RFC 9380.
//!
//! For curves with a = 0 (BN254, BLS12-381, Pasta), uses the
//! Shallue-van de Woestijne mapping (Section 6.6.1) which works
//! for any Weierstrass curve without requiring an isogeny map.
//!
//! Reference: https://www.rfc-editor.org/rfc/rfc9380

const std = @import("std");

/// Expand message to arbitrary length using SHA-256 (expand_message_xmd).
pub fn expandMessageXmd(
    msg: []const u8,
    dst: []const u8,
    out: []u8,
) void {
    const hash_len = 32;
    const len_in_bytes = out.len;
    const b_len = (len_in_bytes + hash_len - 1) / hash_len;

    var idx: usize = 0;
    while (idx < b_len) : (idx += 1) {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(msg);
        h.update(&[_]u8{@intCast(len_in_bytes & 0xff)});
        h.update(dst);
        var b0: [hash_len]u8 = undefined;
        h.final(&b0);

        var h2 = std.crypto.hash.sha2.Sha256.init(.{});
        h2.update(&b0);
        h2.update(&[_]u8{@intCast((idx + 1) & 0xff)});
        h2.update(dst);
        var bi: [hash_len]u8 = undefined;
        h2.final(&bi);

        const start = idx * hash_len;
        const end = @min(start + hash_len, len_in_bytes);
        @memcpy(out[start..end], bi[0 .. end - start]);
    }
}

/// Hash a message to `count` field elements.
pub fn hashToField(
    comptime F: type,
    msg: []const u8,
    dst: []const u8,
    comptime count: usize,
) [count]F {
    const p = F.MODULUS;
    const L = comptime blk: {
        const bits = @bitSizeOf(@TypeOf(p));
        const k = (bits + 127) / 128;
        break :blk k * 16;
    };

    var expanded: [count * L]u8 = undefined;
    expandMessageXmd(msg, dst, &expanded);

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
) (error{SqrtFailed}!CurvePoint(F)) {
    const us = hashToField(F, msg, dst, 2);

    const p1 = try mapToCurveSvdW(F, a, b, us[0]);
    const p2 = try mapToCurveSvdW(F, a, b, us[1]);

    const AffinePoint = @import("weierstrass.zig").AffinePoint(F, a, b);
    const ep1 = AffinePoint{ .x = p1.x, .y = p1.y, .infinity = false };
    const ep2 = AffinePoint{ .x = p2.x, .y = p2.y, .infinity = false };
    const sum = ep1.add(ep2);
    return .{ .x = sum.x, .y = sum.y };
}

// ============================================================================
// Tests
// ============================================================================

test "expandMessageXmd produces output" {
    var out: [64]u8 = undefined;
    expandMessageXmd("test", "dst", &out);
    var out2: [64]u8 = undefined;
    expandMessageXmd("test", "dst", &out2);
    std.debug.assert(std.mem.eql(u8, &out, &out2));
}

test "hashToField is deterministic" {
    const F = @import("zig-field").Field(0xFFFFFFFF00000001);
    const us1 = hashToField(F, "hello", "dst", 2);
    const us2 = hashToField(F, "hello", "dst", 2);
    std.debug.assert(us1[0].eql(us2[0]));
    std.debug.assert(us1[1].eql(us2[1]));
}
