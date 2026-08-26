// SPDX-License-Identifier: MIT OR Apache-2.0

//! Generic Weierstrass elliptic curve arithmetic.
//!
//! Supports both affine and projective (Jacobian) coordinates.
//! For pairing-friendly curves (BN254, BLS12-381), G2 points live over Fp2.

const std = @import("std");

/// Affine point on a Weierstrass curve y^2 = x^3 + a*x + b over field F.
pub fn AffinePoint(comptime F: type, comptime a: F, comptime b: F) type {
    return struct {
        const Self = @This();

        x: F,
        y: F,
        infinity: bool,

        pub fn zero() Self {
            return .{ .x = F.zero(), .y = F.zero(), .infinity = true };
        }

        pub fn generator(gx: F, gy: F) Self {
            return .{ .x = gx, .y = gy, .infinity = false };
        }

        pub fn isOnCurve(self: Self) bool {
            if (self.infinity) return true;
            const y2 = self.y.mul(self.y);
            const x3 = self.x.mul(self.x).mul(self.x);
            const ax = a.mul(self.x);
            return y2.eql(x3.add(ax).add(b));
        }

        pub fn eql(self: Self, other: Self) bool {
            if (self.infinity and other.infinity) return true;
            if (self.infinity or other.infinity) return false;
            return self.x.eql(other.x) and self.y.eql(other.y);
        }

        pub fn neg(self: Self) Self {
            if (self.infinity) return self;
            return .{ .x = self.x, .y = self.y.neg(), .infinity = false };
        }

        pub fn add(self: Self, other: Self) Self {
            if (self.infinity) return other;
            if (other.infinity) return self;
            if (self.eql(other.neg())) return Self.zero();
            if (self.eql(other)) return self.dbl();

            const dx = other.x.sub(self.x);
            const dy = other.y.sub(self.y);
            const lambda = dy.mul(dx.inv());
            const x3 = lambda.mul(lambda).sub(self.x).sub(other.x);
            const y3 = lambda.mul(self.x.sub(x3)).sub(self.y);
            return .{ .x = x3, .y = y3, .infinity = false };
        }

        pub fn dbl(self: Self) Self {
            if (self.infinity) return self;

            const x2 = self.x.mul(self.x);
            const dy = x2.mulBy3().add(a);
            const dx = self.y.mulBy2();
            const lambda = dy.mul(dx.inv());
            const x3 = lambda.mul(lambda).sub(self.x.mulBy2());
            const y3 = lambda.mul(self.x.sub(x3)).sub(self.y);
            return .{ .x = x3, .y = y3, .infinity = false };
        }

        /// Scalar multiplication: windowed ladder run in projective
        /// coordinates so the whole computation costs O(1) field inversions
        /// instead of one per addition.
        ///
        /// Non-CT (branches on scalar bits); NOT for secret scalars.
        pub fn scalarMul(self: Self, scalar: anytype) Self {
            const exp: u512 = scalar;
            return self.toProjective().scalarMul(exp).toAffine();
        }

        pub fn toBytes(self: Self) [2 * F.NUM_BYTES]u8 {
            var out: [2 * F.NUM_BYTES]u8 = undefined;
            const xb = self.x.toBytes();
            const yb = self.y.toBytes();
            @memcpy(out[0..F.NUM_BYTES], &xb);
            @memcpy(out[F.NUM_BYTES..], &yb);
            return out;
        }

        pub fn fromBytes(bytes: [2 * F.NUM_BYTES]u8) !Self {
            const x = try F.fromBytes(bytes[0..F.NUM_BYTES]);
            const y = try F.fromBytes(bytes[F.NUM_BYTES..]);
            const p = Self{ .x = x, .y = y, .infinity = false };
            if (!p.isOnCurve()) return error.NotOnCurve;
            return p;
        }

        /// Convert to projective coordinates.
        pub fn toProjective(self: Self) ProjectivePoint(F, a, b) {
            if (self.infinity) {
                return ProjectivePoint(F, a, b).zero();
            }
            return .{
                .x = self.x,
                .y = self.y,
                .z = F.one(),
            };
        }
    };
}

/// 4-bit windowed left-to-right scalar multiplication over any point type
/// with `zero()`, `dbl()` and `add()`.
///
/// ~n/4 additions instead of ~n/2 for n-bit scalars; on affine points the
/// caller should run this through projective coordinates to avoid per-step
/// field inversions (see `AffinePoint.scalarMul`).
///
/// Non-CT (branches on scalar bits); NOT for secret scalars.
fn scalarMulWindowed(comptime Point: type, base: Point, exp: u512) Point {
    if (exp == 0) return Point.zero();

    // table[i] = (i+1)*base for nibble values 1..15 (0 needs no add).
    var table: [15]Point = undefined;
    table[0] = base;
    var t: usize = 1;
    while (t < 15) : (t += 1) table[t] = table[t - 1].add(base);

    const nbits: usize = 512 - @clz(exp);
    var result = Point.zero();
    var nib: usize = (nbits + 3) / 4;
    while (nib > 0) {
        nib -= 1;
        const shift: std.math.Log2Int(u512) = @intCast(nib * 4);
        const digit: u4 = @truncate(exp >> shift);
        var j: usize = 0;
        while (j < 4) : (j += 1) result = result.dbl();
        if (digit != 0) result = result.add(table[digit - 1]);
    }
    return result;
}

/// Naive LSB-first double-and-add; kept as the independent test reference
/// for `scalarMulWindowed` (stage anchoring, see DESIGN.md).
fn scalarMulNaive(comptime Point: type, base: Point, exp: u512) Point {
    var result = Point.zero();
    var acc = base;
    var k = exp;
    while (k > 0) {
        if (k % 2 == 1) result = result.add(acc);
        acc = acc.dbl();
        k /= 2;
    }
    return result;
}

/// Projective (Jacobian) point: (X : Y : Z) represents (X/Z^2, Y/Z^3).
pub fn ProjectivePoint(comptime F: type, comptime a: F, comptime b: F) type {
    return struct {
        const Self = @This();
        const Affine = AffinePoint(F, a, b);

        x: F,
        y: F,
        z: F,

        pub fn zero() Self {
            return .{
                .x = F.zero(),
                .y = F.one(),
                .z = F.zero(),
            };
        }

        pub fn generator(gx: F, gy: F) Self {
            return .{
                .x = gx,
                .y = gy,
                .z = F.one(),
            };
        }

        pub fn isZero(self: Self) bool {
            return self.z.isZero();
        }

        pub fn eql(self: Self, other: Self) bool {
            if (self.isZero() and other.isZero()) return true;
            if (self.isZero() or other.isZero()) return false;

            // Normalise each side by ITS OWN z (fixed cross-z bug).
            const z1_inv = self.z.inv();
            const z2_inv = other.z.inv();
            const z1_inv2 = z1_inv.mul(z1_inv);
            const z2_inv2 = z2_inv.mul(z2_inv);
            const x1_proj = self.x.mul(z1_inv2);
            const x2_proj = other.x.mul(z2_inv2);
            if (!x1_proj.eql(x2_proj)) return false;

            const y1 = self.y.mul(z1_inv2.mul(z1_inv));
            const y2 = other.y.mul(z2_inv2.mul(z2_inv));
            return y1.eql(y2);
        }

        pub fn neg(self: Self) Self {
            if (self.isZero()) return self;
            return .{ .x = self.x, .y = self.y.neg(), .z = self.z };
        }

        pub fn add(self: Self, other: Self) Self {
            if (self.isZero()) return other;
            if (other.isZero()) return self;

            const z1z1 = self.z.mul(self.z);
            const z2z2 = other.z.mul(other.z);
            const ux1 = self.x.mul(z2z2);
            const ux2 = other.x.mul(z1z1);
            const s1 = self.y.mul(z2z2).mul(other.z);
            const s2 = other.y.mul(z1z1).mul(self.z);

            if (ux1.eql(ux2)) {
                if (!s1.eql(s2)) return Self.zero();
                return self.dbl();
            }

            const h = ux2.sub(ux1);
            const r = s2.sub(s1);
            const hh = h.mul(h);
            const hhh = hh.mul(h);
            const v = ux1.mul(hh);

            const x = r.mul(r).sub(hhh).sub(v.mulBy2());
            const y = r.mul(v.sub(x)).sub(s1.mul(hhh));
            const z = self.z.mul(other.z).mul(h);

            return .{ .x = x, .y = y, .z = z };
        }

        pub fn dbl(self: Self) Self {
            if (self.isZero()) return self;

            const xx = self.x.mul(self.x);
            const yy = self.y.mul(self.y);
            const yyyy = yy.mul(yy);
            const zz = self.z.mul(self.z);

            const s = self.x.mulBy4().mul(yy);
            const m = xx.mulBy3().add(a.mul(zz.mul(zz)));
            const t = m.mul(m).sub(s.mulBy2());

            const x = t;
            const y = m.mul(s.sub(t)).sub(yyyy.mulBy4().mulBy2());
            const z = self.y.mulBy2().mul(self.z);

            return .{ .x = x, .y = y, .z = z };
        }

        /// Scalar multiplication via 4-bit windowed left-to-right ladder in
        /// Jacobian coordinates (no inversions in the loop).
        ///
        /// Non-CT (branches on scalar bits); NOT for secret scalars.
        pub fn scalarMul(self: Self, scalar: anytype) Self {
            const exp: u512 = scalar;
            return scalarMulWindowed(Self, self, exp);
        }

        pub fn toAffine(self: Self) Affine {
            if (self.isZero()) return Affine.zero();
            const z_inv = self.z.inv();
            const z_inv2 = z_inv.mul(z_inv);
            const z_inv3 = z_inv2.mul(z_inv);
            return .{
                .x = self.x.mul(z_inv2),
                .y = self.y.mul(z_inv3),
                .infinity = false,
            };
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const bn254 = @import("bn254.zig");

test "windowed scalar mul matches naive reference (affine + projective)" {
    var prng = std.Random.DefaultPrng.init(0x57A7);
    const rand = prng.random();

    const G1 = bn254.G1;
    const G1Proj = bn254.G1Projective;
    const g = bn254.G1_generator;

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        // Full-width u512 scalars exercise every window position; the group
        // law is total over integers so reduction mod r is not required.
        var k_buf: [64]u8 = undefined;
        rand.bytes(&k_buf);
        const k = std.mem.readInt(u512, &k_buf, .little);
        try testing.expect(
            scalarMulWindowed(G1, g, k).eql(scalarMulNaive(G1, g, k)),
        );
        const gp = g.toProjective();
        try testing.expect(
            scalarMulWindowed(G1Proj, gp, k).toAffine().eql(scalarMulNaive(G1, g, k)),
        );
    }
}

test "windowed scalar mul edge cases" {
    const G1 = bn254.G1;
    const G1Proj = bn254.G1Projective;
    const g = bn254.G1_generator;

    const edges = [_]u512{ 0, 1, 2, 3, 15, 16, 17, 255, 256, 1 << 380, (1 << 381) - 1 };
    for (edges) |k| {
        const w = scalarMulWindowed(G1, g, k);
        const n = scalarMulNaive(G1, g, k);
        try testing.expect(w.eql(n));
        try testing.expect(g.toProjective().scalarMul(k).toAffine().eql(n));
    }
    try testing.expect(scalarMulWindowed(G1, g, 0).infinity);
    try testing.expect(scalarMulWindowed(G1Proj, G1Proj.zero(), 12345).isZero());
}
