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

        pub fn scalarMul(self: Self, scalar: anytype) Self {
            var result = Self.zero();
            var base = self;
            var exp: u512 = scalar;

            while (exp > 0) {
                if (exp % 2 == 1) {
                    result = result.add(base);
                }
                base = base.dbl();
                exp /= 2;
            }
            return result;
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
            const y = m.mul(s.sub(t)).sub(yyyy.mulBy8());
            const z = self.y.mulBy2().mul(self.z);

            return .{ .x = x, .y = y, .z = z };
        }

        pub fn scalarMul(self: Self, scalar: anytype) Self {
            var result = Self.zero();
            var base = self;
            var exp: u512 = scalar;

            while (exp > 0) {
                if (exp % 2 == 1) {
                    result = result.add(base);
                }
                base = base.dbl();
                exp /= 2;
            }
            return result;
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
