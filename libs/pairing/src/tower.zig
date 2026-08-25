// SPDX-License-Identifier: MIT OR Apache-2.0

//! Sextic-twist tower for pairing-friendly curves: Fp12 = Fp6[w] / (w² − v),
//! Fp6 = Fp2[v] / (v³ − ξ), built on top of the field library's
//! QuadraticExtension Fp2.
//!
//! The cubic non-residue `xi` doubles as the sextic ratio `b/b'` between the
//! curve and its twist, so the untwist map is simply
//!   Ψ(x', y') = (x'/w², y'/w³),
//! placing twisted G2 coordinates onto E(Fp12).
//!
//! Frobenius: because p ≡ 1 (mod 6), w^{p^k} = η_k·w with η_k = ξ^{(p^k−1)/6}
//! ∈ Fp2, and v^{p^k} = γ_k·v with γ_k = ξ^{(p^k−1)/3} = η_k². All constants
//! therefore live in Fp2 and are computed at compile time.

const std = @import("std");

/// Cubic extension of Fp2: elements a0 + a1·v + a2·v² with v³ = xi.
pub fn Fp6(comptime Fp2: type, comptime xi: Fp2) type {
    return struct {
        const Self = @This();

        /// Cubic non-residue (also the curve/twist ratio b/b').
        pub const XI = xi;

        c0: Fp2,
        c1: Fp2,
        c2: Fp2,

        pub fn zero() Self {
            return .{ .c0 = Fp2.zero(), .c1 = Fp2.zero(), .c2 = Fp2.zero() };
        }

        pub fn one() Self {
            return .{ .c0 = Fp2.one(), .c1 = Fp2.zero(), .c2 = Fp2.zero() };
        }

        pub fn new(c0: Fp2, c1: Fp2, c2: Fp2) Self {
            return .{ .c0 = c0, .c1 = c1, .c2 = c2 };
        }

        /// Embed an Fp2 element.
        pub fn fromFp2(a: Fp2) Self {
            return .{ .c0 = a, .c1 = Fp2.zero(), .c2 = Fp2.zero() };
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.c0.eql(b.c0) and a.c1.eql(b.c1) and a.c2.eql(b.c2);
        }

        pub fn isZero(self: Self) bool {
            return self.c0.isZero() and self.c1.isZero() and self.c2.isZero();
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .c0 = a.c0.add(b.c0), .c1 = a.c1.add(b.c1), .c2 = a.c2.add(b.c2) };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .c0 = a.c0.sub(b.c0), .c1 = a.c1.sub(b.c1), .c2 = a.c2.sub(b.c2) };
        }

        pub fn neg(a: Self) Self {
            return .{ .c0 = a.c0.neg(), .c1 = a.c1.neg(), .c2 = a.c2.neg() };
        }

        pub fn dbl(a: Self) Self {
            return a.add(a);
        }

        /// Schoolbook multiplication (15 Fp2 mults) with reduction by xi.
        pub fn mul(a: Self, b: Self) Self {
            const a0 = a.c0;
            const a1 = a.c1;
            const a2 = a.c2;
            const b0 = b.c0;
            const b1 = b.c1;
            const b2 = b.c2;

            const t00 = a0.mul(b0);
            const t01 = a0.mul(b1);
            const t02 = a0.mul(b2);
            const t10 = a1.mul(b0);
            const t11 = a1.mul(b1);
            const t12 = a1.mul(b2);
            const t20 = a2.mul(b0);
            const t21 = a2.mul(b1);
            const t22 = a2.mul(b2);

            // Reduction with v³ = ξ, v⁴ = ξv:
            //   v³ terms (t12, t21) fold into c0; the v⁴ term (t22) into c1.
            return .{
                .c0 = t00.add(t12.add(t21).mul(xi)),
                .c1 = t01.add(t10).add(t22.mul(xi)),
                .c2 = t02.add(t11).add(t20),
            };
        }

        pub fn sqr(a: Self) Self {
            return a.mul(a);
        }

        /// Closed-form inversion:
        /// inv(a) = (a0² − a1a2ξ, a2²ξ − a0a1, a1² − a0a2) / N,
        /// N = a0³ + a1³ξ + a2³ξ² − 3a0a1a2ξ.
        pub fn inv(a: Self) Self {
            std.debug.assert(!a.isZero());

            const t0 = a.c0.mul(a.c0).sub(a.c1.mul(a.c2).mul(xi));
            const t1 = a.c2.mul(a.c2).mul(xi).sub(a.c0.mul(a.c1));
            const t2 = a.c1.mul(a.c1).sub(a.c0.mul(a.c2));

            const n = a.c0.mul(t0)
                .add(a.c2.mul(t1).mul(xi))
                .add(a.c1.mul(t2).mul(xi));
            const n_inv = n.inv();

            return .{
                .c0 = t0.mul(n_inv),
                .c1 = t1.mul(n_inv),
                .c2 = t2.mul(n_inv),
            };
        }

        /// Multiply by an Fp2 scalar.
        pub fn mulFp2(a: Self, s: Fp2) Self {
            return .{ .c0 = a.c0.mul(s), .c1 = a.c1.mul(s), .c2 = a.c2.mul(s) };
        }

        test "fp6 inv: generic round-trips (regression: N cross terms)" {
            const Fp2t = @TypeOf(xi);
            // Cases hitting each denominator term, incl. the a=(0,a1,0)
            // shape that exposed the swapped ξ cross-terms.
            const cases = [_][3]Fp2t{
                .{ Fp2t.fromInt(3), Fp2t.fromInt(5), Fp2t.fromInt(7) },
                .{ Fp2t.zero(), Fp2t.fromInt(4), Fp2t.zero() },
                .{ Fp2t.zero(), Fp2t.zero(), Fp2t.fromInt(9) },
                .{ Fp2t.fromInt(11), Fp2t.zero(), Fp2t.fromInt(2) },
            };
            for (cases) |cc| {
                const a = Self.new(cc[0], cc[1], cc[2]);
                try std.testing.expect(a.mul(a.inv()).eql(Self.one()));
            }
        }

        /// Frobenius (single application). Uses γ = ξ^{(p−1)/3} ∈ Fp2 and
        /// the Fp2 Frobenius (conjugation).
        pub fn frobenius(a: Self) Self {
            const gamma = comptime gammaOnce(Fp2, xi);
            return .{
                .c0 = a.c0.frobenius(),
                .c1 = a.c1.frobenius().mul(gamma),
                .c2 = a.c2.frobenius().mul(gamma.sqr()),
            };
        }

        /// Frobenius² (two applications).
        pub fn frobenius2(a: Self) Self {
            return a.frobenius().frobenius();
        }

        /// Fast exponentiation (exponent is public).
        pub fn powFast(a: Self, exp: anytype) Self {
            var result = Self.one();
            var base = a;
            var e = expValue(exp);
            while (e > 0) : (e >>= 1) {
                if (e & 1 == 1) result = result.mul(base);
                base = base.sqr();
            }
            return result;
        }

        fn expValue(exp: anytype) u512 {
            const T = @TypeOf(exp);
            if (T == comptime_int) return @intCast(exp);
            return @intCast(exp);
        }
    };
}

/// γ = ξ^{(p−1)/3} ∈ Fp2 — single-application Frobenius coefficient on Fp6.
fn gammaOnce(
    comptime Fp2: type,
    comptime xi: Fp2,
) Fp2 {
    const p = @as(comptime_int, Fp2.MODULUS);
    comptime {
        @setEvalBranchQuota(200_000_000);
        const num = p - 1;
        std.debug.assert(num % 3 == 0);
        return xi.powFast(num / 3);
    }
}

fn ipow(base: comptime_int, exp: usize) comptime_int {
    var result: comptime_int = 1;
    var b = base;
    var e = exp;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) result *= b;
        b *= b;
    }
    return result;
}

/// Quadratic extension of Fp6: elements c0 + c1·w with w² = nu (nu = v in
/// practice, tying the two levels together).
pub fn Fp12(comptime Base6: type) type {
    // nu is Base6.one().c1 == v — i.e. w² = v, so w behaves like the sextic
    // generator: w⁶ = v³ = xi.
    const Fp2t = @TypeOf(Base6.zero().c0);
    const NU_VALUE = comptime blk: {
        var v = Base6.zero();
        v.c1 = Fp2t.one();
        break :blk v;
    };

    return struct {
        const Self = @This();

        pub const Base = Base6;
        /// Quadratic non-residue: the Base6 element v.
        pub const NU = NU_VALUE;

        c0: Base6,
        c1: Base6,

        pub fn zero() Self {
            return .{ .c0 = Base6.zero(), .c1 = Base6.zero() };
        }

        pub fn one() Self {
            return .{ .c0 = Base6.one(), .c1 = Base6.zero() };
        }

        pub fn new(c0: Base6, c1: Base6) Self {
            return .{ .c0 = c0, .c1 = c1 };
        }

        pub fn fromFp6(a: Base6) Self {
            return .{ .c0 = a, .c1 = Base6.zero() };
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.c0.eql(b.c0) and a.c1.eql(b.c1);
        }

        pub fn isZero(self: Self) bool {
            return self.c0.isZero() and self.c1.isZero();
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .c0 = a.c0.add(b.c0), .c1 = a.c1.add(b.c1) };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .c0 = a.c0.sub(b.c0), .c1 = a.c1.sub(b.c1) };
        }

        pub fn neg(a: Self) Self {
            return .{ .c0 = a.c0.neg(), .c1 = a.c1.neg() };
        }

        pub fn dbl(a: Self) Self {
            return a.add(a);
        }

        /// Multiplication: (a0 + a1w)(b0 + b1w) = (a0b0 + ν a1b1) + (a0b1 + a1b0)w.
        pub fn mul(a: Self, b: Self) Self {
            const t0 = a.c0.mul(b.c0);
            const t1 = a.c1.mul(b.c1);
            const t2 = a.c0.mul(b.c1);
            const t3 = a.c1.mul(b.c0);
            // ν·t1: ν = v, so multiplying by v maps (d0,d1,d2) -> (0·?, ...) =
            // (0, d0·1, 0)+... precisely v·(d0+d1v+d2v²) = d0v + d1v² + d2ξ.
            const nu_t1 = mulByNu(t1);
            return .{
                .c0 = t0.add(nu_t1),
                .c1 = t2.add(t3),
            };
        }

        pub fn sqr(a: Self) Self {
            return a.mul(a);
        }

        /// ν = v multiplication: v·(d0 + d1v + d2v²) = d2·ξ + d0·v + d1·v².
        fn mulByNu(h: Base6) Base6 {
            return .{
                .c0 = h.c2.mul(Base6.XI),
                .c1 = h.c0,
                .c2 = h.c1,
            };
        }

        /// Norm inversion: (c0 + c1w)^{-1} = (c0 − c1w) / (c0² − ν c1²).
        pub fn inv(a: Self) Self {
            std.debug.assert(!a.isZero());
            const t0 = a.c0.sqr();
            const t1 = a.c1.sqr();
            const nu_t1 = mulByNu(t1);
            const det = t0.sub(nu_t1);
            const det_inv = det.inv();
            return .{
                .c0 = a.c0.mul(det_inv),
                .c1 = a.c1.neg().mul(det_inv),
            };
        }

        /// Conjugation (the p⁶-power map on Fp12/Base6).
        pub fn conjugate(a: Self) Self {
            return .{ .c0 = a.c0, .c1 = a.c1.neg() };
        }

        /// Frobenius (single application).
        ///
        /// Because p ≡ 1 (mod 6) for pairing-friendly primes used here,
        /// w^p = w·ξ^{(p−1)/6} = w·η with η ∈ Base6.
        /// Frobenius² = frobenius ∘ frobenius (compose two calls).
        pub fn frobenius(a: Self) Self {
            const eta = comptime etaOnce(Base6);
            return .{
                .c0 = a.c0.frobenius(),
                .c1 = a.c1.frobenius().mulFp2(eta),
            };
        }

        /// Apply Frobenius twice (= Frobenius²).
        pub fn frobenius2(a: Self) Self {
            return a.frobenius().frobenius();
        }

        /// Apply Frobenius² with directly computed η₂ coefficient.
        /// Avoids compounding potential errors from double application.
        pub fn frobenius2Direct(a: Self) Self {
            const p: comptime_int = Fp2t.MODULUS;
            const eta2 = comptime blk: {
                @setEvalBranchQuota(500_000_000);
                const num_ = ipow(p, 2) - 1;
                std.debug.assert(num_ % 6 == 0);
                // Compute via repeated squaring in comptime_int-safe manner
                const half = num_ / 6 / (p + 1); // (p-1)/6 factor
                const eta1 = Base6.XI.powFast(half);
                // η₂ = η₁^{p+1} = Norm(η₁)
                break :blk eta1.mul(eta1);
            };
            return .{
                .c0 = a.c0.frobenius2(),
                .c1 = a.c1.frobenius2().mulFp2(eta2),
            };
        }

        /// Squaring specialised for elements of the cyclotomic subgroup
        /// (g·conj(g)=1, i.e. c0² = 1 + ν·c1²):
        ///   g² = (1 + 2·ν·c1²) + (2·c0·c1)·w
        /// Costs 1 Base squaring + 1 Base multiplication vs 2+1 general.
        pub fn cyclotomicSqr(g: Self) Self {
            const ve_sq = g.c1.sqr();
            const nu_ve = mulByNu(ve_sq);
            const c0 = Self.one().c0.add(nu_ve).add(nu_ve);
            const uv = g.c0.mul(g.c1);
            const c1 = uv.add(uv);
            return .{ .c0 = c0, .c1 = c1 };
        }

        /// Binary square-and-multiply over little-endian u64 limbs.
        pub fn powByLimbs(a: Self, limbs: []const u64) Self {
            var result = Self.one();
            var started = false;
            var i: usize = limbs.len;
            while (i > 0) {
                i -= 1;
                const limb = limbs[i];
                var bit: u6 = 63;
                while (true) : (bit -= 1) {
                    if (started) result = result.sqr();
                    if ((limb >> bit) & 1 == 1) {
                        result = if (started) result.mul(a) else a;
                        started = true;
                    }
                    if (bit == 0) break;
                }
            }
            return result;
        }

        /// 4-bit windowed SA&M using compressed squaring. Valid ONLY for
        /// elements of the cyclotomic subgroup (post easy-part).
        pub fn powByLimbsWindow4Cyclo(a: Self, limbs: []const u64) Self {
            var table: [16]Self = undefined;
            table[1] = a;
            table[2] = cyclotomicSqr(a);
            var k: usize = 3;
            while (k < 16) : (k += 1) {
                table[k] = table[k - 1].mul(a);
            }
            var result = Self.one();
            var started = false;
            var i: usize = limbs.len;
            while (i > 0) {
                i -= 1;
                const limb = limbs[i];
                var nib: u4 = 15;
                while (true) : (nib -= 1) {
                    const shift: u6 = @intCast(@as(u6, nib) * 4);
                    const w = @as(u64, (limb >> shift) & 0xF);
                    if (started) {
                        result = cyclotomicSqr(cyclotomicSqr(cyclotomicSqr(cyclotomicSqr(result))));
                    }
                    if (w != 0) {
                        result = if (started) result.mul(table[w]) else table[w];
                        started = true;
                    }
                    if (nib == 0) break;
                }
            }
            return result;
        }

        /// Fast exponentiation (public exponent).
        pub fn powFast(a: Self, exp: anytype) Self {
            var result = Self.one();
            var base = a;
            var e: u512 = if (@TypeOf(exp) == comptime_int) @intCast(exp) else @intCast(exp);
            while (e > 0) : (e >>= 1) {
                if (e & 1 == 1) result = result.mul(base);
                base = base.sqr();
            }
            return result;
        }
    };
}

/// η = ξ^{(p−1)/6} ∈ Fp2 — single-application Frobenius coefficient on Fp12.
fn etaOnce(comptime Base6: type) @TypeOf(Base6.zero().c0) {
    const Fp2t = @TypeOf(Base6.zero().c0);
    const p = @as(comptime_int, Fp2t.MODULUS);
    comptime {
        // Verify p ≡ 1 mod 6 (required for this formula).
        std.debug.assert(@mod(p, 6) == 1);
        @setEvalBranchQuota(200_000_000);
        const num = p - 1;
        std.debug.assert(num % 6 == 0);
        return Base6.XI.powFast(num / 6);
    }
}
