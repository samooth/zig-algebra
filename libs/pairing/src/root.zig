//! zig-pairing: Bilinear pairings for elliptic curves.
//!
//! Implements optimal ate pairing for BLS12-381 and BN254 curves.
//! Supports:
//! - BLS12-381: 381-bit prime, k=12 embedding degree
//! - BN254: 254-bit prime, k=12 embedding degree
//!
//! Uses optimal ate pairing with Miller loop and final exponentiation.

const std = @import("std");
const traits = @import("zig-algebra-traits");
const zf = @import("zig-field");
const zc = @import("zig-curve");

// ============================================================================
// Field Extensions (generic implementations)
// ============================================================================

/// Quadratic extension Fp2 = Fp[u]/(u^2 - non_residue)
pub fn Fp2(comptime F: type, comptime non_residue: F) type {
    traits.assertField(F);
    return struct {
        const Self = @This();
        c0: F,
        c1: F,

        pub fn zero() Self { return .{ .c0 = F.zero(), .c1 = F.zero() }; }
        pub fn one() Self { return .{ .c0 = F.one(), .c1 = F.zero() }; }

        pub fn add(a: Self, b: Self) Self {
            return .{ .c0 = a.c0.add(b.c0), .c1 = a.c1.add(b.c1) };
        }
        pub fn sub(a: Self, b: Self) Self {
            return .{ .c0 = a.c0.sub(b.c0), .c1 = a.c1.sub(b.c1) };
        }
        pub fn neg(a: Self) Self {
            return .{ .c0 = a.c0.neg(), .c1 = a.c1.neg() };
        }
        pub fn mul(a: Self, b: Self) Self {
            // (a0 + a1*u) * (b0 + b1*u) = (a0*b0 + a1*b1*non_residue) + (a0*b1 + a1*b0)*u
            const c0 = a.c0.mul(b.c0).add(a.c1.mul(b.c1).mul(non_residue));
            const c1 = a.c0.mul(b.c1).add(a.c1.mul(b.c0));
            return .{ .c0 = c0, .c1 = c1 };
        }
        pub fn inv(a: Self) Self {
            // (a0 + a1*u)^-1 = (a0 - a1*u) / (a0^2 - a1^2*non_residue)
            const norm = a.c0.mul(a.c0).sub(a.c1.mul(a.c1).mul(non_residue));
            const norm_inv = norm.inv();
            return .{ .c0 = a.c0.mul(norm_inv), .c1 = a.c1.neg().mul(norm_inv) };
        }
        pub fn div(a: Self, b: Self) Self { return a.mul(b.inv()); }

        pub fn eql(a: Self, b: Self) bool { return a.c0.eql(b.c0) and a.c1.eql(b.c1); }
        pub fn isZero(self: Self) bool { return self.c0.isZero() and self.c1.isZero(); }
        pub fn isOne(self: Self) bool { return self.c0.isOne() and self.c1.isZero(); }

        pub fn conjugate(a: Self) Self { return .{ .c0 = a.c0, .c1 = a.c1.neg() }; }
        pub fn frobenius(a: Self) Self { return a.conjugate(); } // For quadratic extension

        pub fn pow(a: Self, exp: u64) Self {
            var result = Self.one();
            var base = a;
            var e = exp;
            while (e > 0) {
                if ((e & 1) == 1) result = result.mul(base);
                base = base.mul(base);
                e >>= 1;
            }
            return result;
        }
    };
}

/// Cubic extension Fp6 = Fp2[v]/(v^3 - non_residue)
pub fn Fp6(comptime BaseFp2: type, comptime non_residue: BaseFp2) type {
    return struct {
        const Self = @This();
        c0: BaseFp2,
        c1: BaseFp2,
        c2: BaseFp2,

        pub fn zero() Self { return .{ .c0 = BaseFp2.zero(), .c1 = BaseFp2.zero(), .c2 = BaseFp2.zero() }; }
        pub fn one() Self { return .{ .c0 = BaseFp2.one(), .c1 = BaseFp2.zero(), .c2 = BaseFp2.zero() }; }

        pub fn add(a: Self, b: Self) Self {
            return .{ .c0 = a.c0.add(b.c0), .c1 = a.c1.add(b.c1), .c2 = a.c2.add(b.c2) };
        }
        pub fn sub(a: Self, b: Self) Self {
            return .{ .c0 = a.c0.sub(b.c0), .c1 = a.c1.sub(b.c1), .c2 = a.c2.sub(b.c2) };
        }
        pub fn neg(a: Self) Self {
            return .{ .c0 = a.c0.neg(), .c1 = a.c1.neg(), .c2 = a.c2.neg() };
        }
        pub fn mul(a: Self, b: Self) Self {
            // Karatsuba-like multiplication for cubic extension
            // (a0 + a1*v + a2*v^2) * (b0 + b1*v + b2*v^2)
            // v^3 = non_residue
            const c0 = a.c0.mul(b.c0).add(a.c1.mul(b.c2).mul(non_residue)).add(a.c2.mul(b.c1).mul(non_residue));
            const c1 = a.c0.mul(b.c1).add(a.c1.mul(b.c0)).add(a.c2.mul(b.c2).mul(non_residue));
            const c2 = a.c0.mul(b.c2).add(a.c1.mul(b.c1)).add(a.c2.mul(b.c0));
            return .{ .c0 = c0, .c1 = c1, .c2 = c2 };
        }
        pub fn inv(a: Self) Self {
            // Simplified inversion using norm
            // For proper implementation, use extended Euclidean algorithm
            // This is a placeholder - proper implementation needed
            return .{ .c0 = a.c0, .c1 = a.c1.neg(), .c2 = a.c2.neg() };
        }
        pub fn div(a: Self, b: Self) Self { return a.mul(b.inv()); }

        pub fn eql(a: Self, b: Self) bool {
            return a.c0.eql(b.c0) and a.c1.eql(b.c1) and a.c2.eql(b.c2);
        }
        pub fn isZero(self: Self) bool { return self.c0.isZero() and self.c1.isZero() and self.c2.isZero(); }
        pub fn isOne(self: Self) bool { return self.c0.isOne() and self.c1.isZero() and self.c2.isZero(); }

        pub fn conjugate(a: Self) Self { return .{ .c0 = a.c0, .c1 = a.c1.neg(), .c2 = a.c2 }; }
        pub fn frobenius(a: Self) Self { return .{ .c0 = a.c0.frobenius(), .c1 = a.c1.frobenius(), .c2 = a.c2.frobenius() }; }

        pub fn pow(a: Self, exp: u64) Self {
            var result = Self.one();
            var base = a;
            var e = exp;
            while (e > 0) {
                if ((e & 1) == 1) result = result.mul(base);
                base = base.mul(base);
                e >>= 1;
            }
            return result;
        }
    };
}

/// Degree 12 extension Fp12 = Fp6[w]/(w^2 - non_residue)
pub fn Fp12(comptime BaseFp6: type, comptime non_residue: BaseFp6) type {
    return struct {
        const Self = @This();
        c0: BaseFp6,
        c1: BaseFp6,

        pub fn zero() Self { return .{ .c0 = BaseFp6.zero(), .c1 = BaseFp6.zero() }; }
        pub fn one() Self { return .{ .c0 = BaseFp6.one(), .c1 = BaseFp6.zero() }; }

        pub fn add(a: Self, b: Self) Self { return .{ .c0 = a.c0.add(b.c0), .c1 = a.c1.add(b.c1) }; }
        pub fn sub(a: Self, b: Self) Self { return .{ .c0 = a.c0.sub(b.c0), .c1 = a.c1.sub(b.c1) }; }
        pub fn neg(a: Self) Self { return .{ .c0 = a.c0.neg(), .c1 = a.c1.neg() }; }
        pub fn mul(a: Self, b: Self) Self {
            // (a0 + a1*w) * (b0 + b1*w) = (a0*b0 + a1*b1*non_residue) + (a0*b1 + a1*b0)*w
            const c0 = a.c0.mul(b.c0).add(a.c1.mul(b.c1).mul(non_residue));
            const c1 = a.c0.mul(b.c1).add(a.c1.mul(b.c0));
            return .{ .c0 = c0, .c1 = c1 };
        }
        pub fn inv(a: Self) Self {
            const norm = a.c0.mul(a.c0).sub(a.c1.mul(a.c1).mul(non_residue));
            const norm_inv = norm.inv();
            return .{ .c0 = a.c0.mul(norm_inv), .c1 = a.c1.neg().mul(norm_inv) };
        }
        pub fn div(a: Self, b: Self) Self { return a.mul(b.inv()); }

        pub fn eql(a: Self, b: Self) bool { return a.c0.eql(b.c0) and a.c1.eql(b.c1); }
        pub fn isZero(self: Self) bool { return self.c0.isZero() and self.c1.isZero(); }
        pub fn isOne(self: Self) bool { return self.c0.isOne() and self.c1.isZero(); }

        pub fn conjugate(a: Self) Self { return .{ .c0 = a.c0, .c1 = a.c1.neg() }; }
        pub fn frobenius(a: Self) Self { return .{ .c0 = a.c0.frobenius(), .c1 = a.c1.frobenius() }; }

        pub fn pow(a: Self, exp: u64) Self {
            var result = Self.one();
            var base = a;
            var e = exp;
            while (e > 0) {
                if ((e & 1) == 1) result = result.mul(base);
                base = base.mul(base);
                e >>= 1;
            }
            return result;
        }
    };
}

// ============================================================================
// Curve parameter aliases
// ============================================================================

pub const BLS12_381_X = 0xD201000000010000; // x = −0xD201000000010000 (negative)
pub const BN254_X = 0x44E992B44A6909F1;

pub const BLS12_381_G1 = zc.bls12_381.G1;
pub const BLS12_381_G2 = zc.bls12_381.G2;
pub const BN254_G1 = zc.bn254.G1;
pub const BN254_G2 = zc.bn254.G2;

pub const bls12_381_pairing_impl = @import("bls12_381.zig");
pub const bn254_pairing_impl = @import("bn254.zig");


// ============================================================================
// Tests
// ============================================================================

// Minimal F7 field for algebraic pairing tests
const F7 = struct {
    const Self = @This();
    value: u64,
    pub const modulus: u64 = 7;
    pub const characteristic: u64 = 7;
    pub const order: u64 = 7;

    pub fn zero() Self { return .{ .value = 0 }; }
    pub fn one() Self { return .{ .value = 1 }; }
    pub fn fromInt(x: u256) Self { return .{ .value = @intCast(x % modulus) }; }
    pub fn toInt(self: Self) u64 { return self.value; }
    pub fn eql(a: Self, b: Self) bool { return a.value == b.value; }
    pub fn add(a: Self, b: Self) Self { return fromInt(a.value + b.value); }
    pub fn sub(a: Self, b: Self) Self { return fromInt(a.value + (modulus - b.value % modulus)); }
    pub fn neg(a: Self) Self { return if (a.value == 0) zero() else fromInt(modulus - a.value); }
    pub fn mul(a: Self, b: Self) Self { return fromInt(a.value * b.value); }
    pub fn inv(a: Self) Self {
        std.debug.assert(!a.isZero());
        return pow(a, modulus - 2);
    }
    pub const inverse = inv;
    pub fn div(a: Self, b: Self) Self { return mul(a, inv(b)); }
    pub fn pow(base: Self, exp: u64) Self {
        var result = one();
        var b = base;
        var e = exp;
        while (e > 0) {
            if ((e & 1) == 1) result = mul(result, b);
            b = mul(b, b);
            e >>= 1;
        }
        return result;
    }
    pub fn isZero(self: Self) bool { return self.value == 0; }
    pub fn random() Self { return fromInt(1); }
    pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) !void { try w.print("{}", .{self.value}); }
};

test "Fp2 basic operations" {
    _ = Fp2(F7, F7.fromInt(6)); // -1

    const a = Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(1), .c1 = F7.fromInt(2) };
    const b = Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(3), .c1 = F7.fromInt(4) };

    try std.testing.expect(a.add(b).eql(Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(4), .c1 = F7.fromInt(6) }));
    try std.testing.expect(a.sub(b).eql(Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(5), .c1 = F7.fromInt(5) }));
    
    // (1 + 2u) * (3 + 4u) = 3 + 4u + 6u + 8u^2 = 3 + 10u - 8 = -5 + 3u = 2 + 3u (mod 7)
    // Wait: u^2 = -1, so 8u^2 = -8 = 6 (mod 7)
    // 3 + 4u + 6u + 6 = 9 + 10u = 2 + 3u (mod 7)
    const prod = a.mul(b);
    try std.testing.expect(prod.eql(Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(2), .c1 = F7.fromInt(3) }));
}

test "BLS12-381 Fp2 construction" {
    // Test that BLS12-381 Fp2 can be constructed
    const Fp2_381 = zc.bls12_381.Fp2;
    const a = Fp2_381{ .c0 = zc.bls12_381.Fp.fromInt(1), .c1 = zc.bls12_381.Fp.fromInt(2) };
    const b = Fp2_381{ .c0 = zc.bls12_381.Fp.fromInt(3), .c1 = zc.bls12_381.Fp.fromInt(4) };
    try std.testing.expect(a.add(b).c0.eql(zc.bls12_381.Fp.fromInt(4)));
    try std.testing.expect(a.add(b).c1.eql(zc.bls12_381.Fp.fromInt(6)));
}

test "BN254 Fp2 construction" {
    const Fp2_254 = zc.bn254.Fp2;
    const a = Fp2_254{ .c0 = zc.bn254.Fp.fromInt(1), .c1 = zc.bn254.Fp.fromInt(2) };
    const b = Fp2_254{ .c0 = zc.bn254.Fp.fromInt(3), .c1 = zc.bn254.Fp.fromInt(4) };
    try std.testing.expect(a.add(b).c0.eql(zc.bn254.Fp.fromInt(4)));
    try std.testing.expect(a.add(b).c1.eql(zc.bn254.Fp.fromInt(6)));
}

test "Fp6 basic structure" {
    const Fp2_7 = Fp2(F7, F7.fromInt(6));
    _ = Fp6(Fp2(F7, F7.fromInt(6)), Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(1), .c1 = F7.fromInt(1) });
    
    const a = Fp6(Fp2_7, Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(1), .c1 = F7.fromInt(1) }){ 
        .c0 = Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(1), .c1 = F7.fromInt(0) }, 
        .c1 = Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(0), .c1 = F7.fromInt(1) }, 
        .c2 = Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(0), .c1 = F7.fromInt(0) } 
    };
    const b = Fp6(Fp2_7, Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(1), .c1 = F7.fromInt(1) }){ 
        .c0 = Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(0), .c1 = F7.fromInt(1) }, 
        .c1 = Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(1), .c1 = F7.fromInt(0) }, 
        .c2 = Fp2(F7, F7.fromInt(6)){ .c0 = F7.fromInt(0), .c1 = F7.fromInt(0) } 
    };
    
    // a = 1 + v, b = u + v
    // a*b = (1+v)(u+v) = u + v + uv + v^2 = u + (1+u)v + v^2 ... expanded in Fp6:
    //   c0' = c0*d0 + n*(c1*d2 + c2*d1) = (1)(u) + n*0 = u
    //   c1' = c0*d1 + c1*d0 + n*(c2*d2) = (v) + (u) + 0 = (1+u)... but with Fp2 mul:
    //         (1,0)*(1,0)=(1,0); (0,1)*(0,1)= -1 = (p-1,0); sum = (0,0) = 0
    //   c2' = c0*d2 + c1*d1 + c2*d0 = 0 + (0,1)*(1,0) + 0 = u
    const prod = a.mul(b);
    try std.testing.expect(prod.c0.c0.eql(F7.fromInt(0)));
    try std.testing.expect(prod.c0.c1.eql(F7.fromInt(1))); // u
    try std.testing.expect(prod.c1.isZero());
    try std.testing.expect(prod.c2.c1.eql(F7.fromInt(1))); // u
    try std.testing.expect(prod.c2.c0.eql(F7.fromInt(0)));
}

test "BLS12-381 generator points exist" {
    // Test that generator points are on the curve
    const g1 = zc.bls12_381.G1_generator;
    const g2 = zc.bls12_381.G2_generator;
    try std.testing.expect(g1.isOnCurve());
    try std.testing.expect(g2.isOnCurve());
}

test "BN254 generator points exist" {
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    try std.testing.expect(g1.isOnCurve());
    try std.testing.expect(g2.isOnCurve());
}

// Example program
pub fn main() !void {
    const g1 = zc.bls12_381.G1_generator;
    const g2 = zc.bls12_381.G2_generator;
    const e = bls12_381_pairing_impl.pairing(g1, g2);
    std.debug.print("BLS12-381 e(G1, G2) zero={}\n", .{e.isZero()});
    const bn_g1 = zc.bn254.G1_generator;
    const bn_g2 = zc.bn254.G2_generator;
    const bn_e = bn254_pairing_impl.pairing(bn_g1, bn_g2);
    std.debug.print("BN254 e(G1, G2) zero={}\n", .{bn_e.isZero()});
}

test {
    // Force analysis of imported modules so their inline tests are collected.
    std.testing.refAllDecls(@This());
}
