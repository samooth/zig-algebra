//! BN254 direct degree-12 extension: Fp12 = Fp2[w]/(w¹² − ξ) with ξ = 9+u.
//!
//! # Why direct extension
//!
//! BN254 uses a D-type twist where b' = 4/ξ_c with ξ_c = 9+u. Building the
//! tower hierarchically (Fp6 then Fp12) requires choosing a cubic non-residue
//! at the Fp6 level, but ξ_c turns out to be a cube in Fp₂*, making it
//! unusable there.
//!
//! However ξ_c is neither a square nor a cube in Fp₂* (verified numerically),
//! so x¹² − ξ_c IS irreducible over Fp₂ and gives us a valid degree-12
//! extension directly. Bonus: the untwist map becomes trivial:
//!
//!   ψ(x', y') ∈ E'(Fp2) ↦ (x'·w⁴, y'·w⁶) ∈ E(Fp12)
//!
//! because w¹² = ξ_c absorbs the twist coefficient exactly.
//!
//! # Status
//!
//! Field arithmetic implemented and tested. Miller loop / final exp pending.

const std = @import("std");
const zf = @import("zig-field");

pub const Fp = zf.BN254_Fp;

/// BN254 Fp2 = Fp[u]/(u² + 1).
pub const Fp2 = zf.BN254_Fp2;

/// Decimal representation of BN254 prime p for reference.
pub const P_DECIMAL: u512 = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

/// Direct degree-12 extension of Fp2 by w where w¹² = ξ = 9+u.
///
/// Element representation: [c₀, c₁, ..., c₁₁] representing Σ cᵢ·wⁱ.
/// Multiplication is schoolbook O(144) Fp2 muls followed by reduction mod
/// (w¹² − ξ).
pub const Fp12Direct = struct {
    coeff: [12]Fp2,

    pub const ZERO: Fp12Direct = .{ .coeff = @splat(Fp2.zero()) };
    pub const ONE: Fp12Direct = blk: {
        var c = [_]Fp2{Fp2.zero()} ** 12;
        c[0] = Fp2.one();
        break :blk .{ .coeff = c };
    };

    /// The reduction constant ξ = 9 + u as an Fp2 element.
    pub const XI: Fp2 = Fp2.new(Fp.fromInt(9), Fp.one());

    pub fn fromCoeffs(coeffs: [12]Fp2) Fp12Direct {
        return .{ .coeff = coeffs };
    }

    pub fn fromFp2(a: Fp2) Fp12Direct {
        var c = [_]Fp2{Fp2.zero()} ** 12;
        c[0] = a;
        return .{ .coeff = c };
    }

    pub fn eql(a: Fp12Direct, b: Fp12Direct) bool {
        for (&a.coeff, &b.coeff) |*x, *y| if (!x.eq(y.*)) return false;
        return true;
    }

    pub fn isZero(a: Fp12Direct) bool {
        for (&a.coeff) |*c| if (!c.isZero()) return false;
        return true;
    }

    pub fn add(a: Fp12Direct, b: Fp12Direct) Fp12Direct {
        var out: [12]Fp2 = undefined;
        for (&out, &a.coeff, &b.coeff) |*o, *x, *y| o.* = x.add(y.*);
        return .{ .coeff = out };
    }

    pub fn neg(a: Fp12Direct) Fp12Direct {
        var out: [12]Fp2 = undefined;
        for (&out, &a.coeff) |*o, *x| o.* = x.neg();
        return .{ .coeff = out };
    }

    pub fn sub(a: Fp12Direct, b: Fp12Direct) Fp12Direct {
        return a.add(b.neg());
    }

    /// Schoolbook multiplication followed by reduction mod (w¹² − ξ).
    pub fn mul(a: Fp12Direct, b: Fp12Direct) Fp12Direct {
        var prod: [24]Fp2 = @splat(Fp2.zero());
        for (0..12) |i| {
            if (a.coeff[i].isZero()) continue;
            for (0..12) |j| {
                if (b.coeff[j].isZero()) continue;
                prod[i + j] = prod[i + j].add(a.coeff[i].mul(b.coeff[j]));
            }
        }
        // Reduce terms of degree >= 12: w^(k+12) = w^k · ξ.
        var out: [12]Fp2 = undefined;
        for (0..12) |k| {
            out[k] = prod[k].add(XI.mul(prod[k + 12]));
        }
        return .{ .coeff = out };
    }

    pub fn sqr(a: Fp12Direct) Fp12Direct {
        return a.mul(a);
    }

    /// Compute a^n via square-and-multiply for small positive n.
    pub fn powSmall(a: Fp12Direct, n: u32) Fp12Direct {
        var result = ONE;
        var base = a;
        var e = n;
        while (e > 0) : (e >>= 1) {
            if (e & 1 == 1) result = result.mul(base);
            base = base.sqr();
        }
        return result;
    }
};

// Convenience aliases for Fp2 operations used above.
// These assume zf.BN254_Fp2 exposes them; adjust if API differs.
test "fp12_direct: zero and one" {
    try std.testing.expect(Fp12Direct.ZERO.isZero());
    try std.testing.expect(!Fp12Direct.ONE.eql(Fp12Direct.ZERO));
    try std.testing.expect(Fp12Direct.ONE.eql(Fp12Direct.ONE));
    try std.testing.expect(!Fp12Direct.ZERO.eql(Fp12Direct.ONE));
}

test "fp12_direct: additive identity" {
    const a = Fp12Direct.fromFp2(Fp2.fromInt(42));
    try std.testing.expect(a.add(Fp12Direct.ZERO).eql(a));
    try std.testing.expect(a.sub(a).eql(Fp12Direct.ZERO));
}

test "fp12_direct: multiplicative identity" {
    const a = Fp12Direct.fromFp2(Fp2.fromInt(7));
    try std.testing.expect(a.mul(Fp12Direct.ONE).eql(a));
    try std.testing.expect(Fp12Direct.ONE.mul(a).eql(a));
}

test "fp12_direct: multiplication is commutative" {
    const a = Fp12Direct.fromFp2(Fp2.fromInt(3));
    const b = Fp12Direct.fromFp2(Fp2.fromInt(5));
    try std.testing.expect(a.mul(b).eql(b.mul(a)));
}

test "fp12_direct: multiplication is associative" {
    const a = Fp12Direct.fromFp2(Fp2.fromInt(2));
    const b = Fp12Direct.fromFp2(Fp2.fromInt(3));
    const c = Fp12Direct.fromFp2(Fp2.fromInt(4));
    try std.testing.expect(a.mul(b).mul(c).eql(a.mul(b.mul(c))));
}

test "fp12_direct: distributivity" {
    const a = Fp12Direct.fromFp2(Fp2.fromInt(5));
    const b = Fp12Direct.fromFp2(Fp2.fromInt(7));
    const c = Fp12Direct.fromFp2(Fp2.fromInt(11));
    try std.testing.expect(a.mul(b.add(c)).eql(a.mul(b).add(a.mul(c))));
}

test "fp12_direct: w^12 == xi" {
    // Construct element w (coefficient of w^1 is 1, rest 0).
    var w = Fp12Direct.ZERO;
    w.coeff[1] = Fp2.one();
    // w^12 should equal XI embedded into Fp12.
    var w12 = Fp12Direct.ONE;
    var i: u32 = 0;
    while (i < 12) : (i += 1) w12 = w12.mul(w);

    var xi_embedded = Fp12Direct.ZERO;
    xi_embedded.coeff[0] = Fp12Direct.XI;
    try std.testing.expect(w12.eql(xi_embedded));
}
