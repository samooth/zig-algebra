//! BN254 pairing on Fp2[w]/(w¹² − (9+u)) — NOTE: this ring has degree 24
//! over Fp, not 12! A degree-12 extension of Fp2 IS degree-24 over Fp; the
//! true Fp12 used by pairings lives in bn254_tower.zig via the standard
//! 2→6→12 tower.
//!
//! The pairing computed here is bilinear and its value is in μ_r, and it is
//! **not the pairing value**: measured 2026-10-09 against py_ecc, the output
//! is an element of μ_r that no isomorphism to py_ecc's tower maps onto
//! e(P,Q), and it is not a Frobenius power of it either. The likely cause is
//! the loop parameter below, which is 6x² rather than the 6x+2 that py_ecc
//! and the verified tower use; setting it to 6x+2 breaks bilinearity, so the
//! loop and its extra terms were built for each other and both are wrong
//! together. A test named DEFECT MARKER pins this, and the history is in
//! SECURITY.md advisory ZA-2026-008.
//!
//! Cost: ~4× larger multiplies than the tower would need.
//!
//! Untwist here: ψ(x', y') = (x'·w⁴, y'·w⁶), absorbing b' = 3/(9+u)
//! exactly (alt_bn128 curve is y² = x³ + 3).

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

    /// Symmetric squaring: cross products c_i·c_j (i<j) computed once and
    /// doubled — 78 Fp2 muls worst case vs 144 schoolbook. Followed by
    /// reduction mod (w¹² − ξ).
    pub fn sqr(a: Fp12Direct) Fp12Direct {
        var prod: [24]Fp2 = @splat(Fp2.zero());
        for (0..12) |i| {
            const ai = a.coeff[i];
            if (ai.isZero()) continue;
            prod[2 * i] = prod[2 * i].add(ai.sqr());
            var j = i + 1;
            while (j < 12) : (j += 1) {
                const aj = a.coeff[j];
                if (aj.isZero()) continue;
                const p1 = ai.mul(aj);
                prod[i + j] = prod[i + j].add(p1.add(p1));
            }
        }
        var out: [12]Fp2 = undefined;
        for (0..12) |k| {
            out[k] = prod[k].add(XI.mul(prod[k + 12]));
        }
        return .{ .coeff = out };
    }

    /// Multiply by sparse element c0 + c2·w² + c6·w⁶ (Miller line values).
    /// Source term c_s·f[k] lands at degree k+s; degrees ≥12 fold via ξ.
    /// 36 Fp2 muls vs 144 schoolbook.
    fn mulBySparse026(f: Fp12Direct, c0: Fp2, c2: Fp2, c6: Fp2) Fp12Direct {
        var out: [12]Fp2 = @splat(Fp2.zero());
        var hi: [12]Fp2 = @splat(Fp2.zero()); // degrees 12..23
        for (0..12) |k| {
            const fk = f.coeff[k];
            out[k] = out[k].add(c0.mul(fk));
            if (k + 2 < 12) out[k + 2] = out[k + 2].add(c2.mul(fk)) else hi[k + 2 - 12] = hi[k + 2 - 12].add(c2.mul(fk));
            if (k + 6 < 12) out[k + 6] = out[k + 6].add(c6.mul(fk)) else hi[k + 6 - 12] = hi[k + 6 - 12].add(c6.mul(fk));
        }
        for (0..12) |k| {
            out[k] = out[k].add(XI.mul(hi[k]));
        }
        return .{ .coeff = out };
    }

    /// Multiply by sparse vertical v0 + v4·w⁴. 24 Fp2 muls vs 144.
    fn mulBySparse04(f: Fp12Direct, v0: Fp2, v4: Fp2) Fp12Direct {
        var out: [12]Fp2 = @splat(Fp2.zero());
        var hi: [12]Fp2 = @splat(Fp2.zero());
        for (0..12) |k| {
            const fk = f.coeff[k];
            out[k] = out[k].add(v0.mul(fk));
            if (k + 4 < 12) out[k + 4] = out[k + 4].add(v4.mul(fk)) else hi[k + 4 - 12] = hi[k + 4 - 12].add(v4.mul(fk));
        }
        for (0..12) |k| {
            out[k] = out[k].add(XI.mul(hi[k]));
        }
        return .{ .coeff = out };
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

    /// Square-and-multiply over a multi-limb exponent (little-endian u64s),
    /// scanning MSB→LSB. Non-CT: exponents here are public constants.
    pub fn powByLimbs(a: Fp12Direct, limbs: []const u64) Fp12Direct {
        var result = ONE;
        var started = false;
        var i: usize = limbs.len;
        while (i > 0) {
            i -= 1;
            const limb = limbs[i];
            var bit: u6 = 63;
            while (true) : (bit -= 1) {
                if (started) result = result.sqr();
                if ((limb >> bit) & 1 == 1) {
                    if (started) {
                        result = result.mul(a);
                    } else {
                        result = a; // first set bit: result := a
                        started = true;
                    }
                }
                if (bit == 0) break;
            }
        }
        return result;
    }

    /// Multiplicative inverse: a^(p^12 − 2) via SA&M over precomputed limbs.
    /// Non-CT (public data only).
    /// Legacy total inverse: `inv(0) == zero()`. Zero is not an inverse;
    /// new code that requires invertibility must call `invChecked`.
    pub fn inv(a: Fp12Direct) Fp12Direct {
        if (a.isZero()) return ZERO;
        return a.powByLimbs(&P12_MINUS_2_LIMBS);
    }

    /// # Errors
    /// `error.InverseOfZero` when `a` is the zero element. The old
    /// `std.debug.assert` was compiled out in `ReleaseFast`, where
    /// `a^(p^12 - 2)` on zero returned zero without the caller noticing.
    pub fn invChecked(a: Fp12Direct) error{InverseOfZero}!Fp12Direct {
        if (a.isZero()) return error.InverseOfZero;
        return a.powByLimbs(&P12_MINUS_2_LIMBS);
    }
};

/// Final exponentiation constant N = (p^12 − 1)/r, little-endian u64 limbs
/// (~2790 bits, top limbs zero).
pub const FINAL_EXP_LIMBS = [48]u64{
    0x86964B64CA86F120, 0x40A4EFB7E54523A4, 0x837FA97896E84ABB, 0x361102B6B9B2B918,
    0xC0DE81DEF35692DA, 0xBE04C7E8A6C3C760, 0xD766F9C9D570BB7F, 0xC230974D83561841,
    0x5BBA1668C3BE69A3, 0x7F3811C410526294, 0x29BAEE7DDADDA71C, 0xBF813B8D145DA900,
    0x641BBADF423F9A2C, 0xA80BB4EA44EACC5E, 0xCD65664814FDE37C, 0x4A0364B9580291D2,
    0xEE93DFB10826F0DD, 0x6B42DB8DC5514724, 0xBB10CF430B0F3785, 0x40494E406F804216,
    0x55CFE107ACF3AAFB, 0x2088EC80E0EBAE87, 0x846A3ED011A337A0, 0x48A45A4A1E3A5195,
    0xE5664568DFC50E16, 0xAB6A41294C0CC4EB, 0x82D0D602D268C7DA, 0x6668449AED3CC48A,
    0x5062CD0FB2015DFC, 0x7F2940A8B1DDB3D1, 0x77F5B63A2A226448, 0xFEF0781361E443AE,
    0xF977870E88D5C6C8, 0x790364A61F676BAA, 0x5887E72ECEADDEA3, 0x1377E563A09A1B70,
    0xC54EFEE1BD8C3B2,  0x3EC3D15AD524D8F7, 0xDAF15466B2383A5D, 0xE1E30A73BB94FEC0,
    0x6A1C71015F3F7BE2, 0x842D43BF6369B1FF, 0x20FDDADF107D20BC, 0x2F4B6DC970,
    0,                  0,                  0,                  0,
};

/// p^12 − 2 as little-endian u64 limbs (for inversion).
pub const P12_MINUS_2_LIMBS = [48]u64{
    0xC1D4E2D2CA86F11F, 0x41BF0E6B068AAFDB, 0x23C5B159F8E334F7, 0xDB3F4157D4F4C1A6,
    0x5D1390D0AD44CDE3, 0xBDE30EC3AC19E53A, 0xE967B77365ACBFB6, 0xDDDC3CD5778AB175,
    0x149DDA742C67F3EB, 0x0FFB72D2B1BD509,  0x2092F07CAAE3590D, 0x5954B6865C929F15,
    0xBF03A7EAC45865CA, 0x6ACC85FF3050D845, 0x04F734402C7E9C87, 0xFAFFDCD3E420AF5F,
    0x39B9E7C33466EBC5, 0x9A6BDF0BE72B9BB6, 0xA4E3B43978298046, 0x27A80E4DBD46D78C,
    0xFBB3D91BE7B7FF49, 0xABADE6714D68AA10, 0xB5914D60D8B15012, 0xDD600BA556C2761C,
    0xC93A85CCB6522FBA, 0xB409DD086EAC626,  0x382EE9C8E530232F, 0x1CE1C9500AA55B90,
    0xCC2713BF84C279D9, 0xEAA7A4A16D1A05DC, 0x1A7AA25767C1CEC5, 0x219B8A10DDBE1123,
    0xA523759E261408AC, 0xE5FF67475F1F3ADD, 0xC90EFB9439CBA604, 0x11CBB900DAD55C8D,
    0xB8EC71A82A5FA888, 0xD2CCF14141D6F9A0, 0x4DACF90E8E139C69, 0x380FDB292B696A8D,
    0x1046AB2684B00EB6, 0x4DB41B22A5B9BA9F, 0xC1E6C4BCFEAA38D3, 0x4BF43F7F5933D90D,
    0x7F447128E8041DA4, 0x2CC29793FA9C753A, 0x5AB6DF1836F1770C, 0x08F0AC8ADC,
};

// ============================================================================
// BN254 optimal ate pairing over the direct extension
// ============================================================================

const zc = @import("zig-curve");
const G1Point = zc.bn254.G1;
const G2Point = zc.bn254.G2;

/// Loop parameter, 127 bits, x = 0x44E992B44A6909F1. Comment used to say
/// "t−1 = 6x², the ate parameter", and 6x² is indeed t−1 — it is also not the
/// parameter the pairing this tree is pinned to uses: py_ecc and
/// bn254_tower.zig both run 6x+2 (65 bits). Changing this constant alone does
/// not fix the value (bilinearity breaks, because the extra terms below were
/// written for it); see the DEFECT MARKER at the end of this file.
const LOOP: u128 = 0x6F4D8248EEB859FBF83E9682E87CFD46;

/// Embed an Fp2 value at slot k of Fp12Direct (i.e. multiply by w^k).
fn embedSlot(v: Fp2, k: usize) Fp12Direct {
    var out = Fp12Direct.ZERO;
    out.coeff[k] = v;
    return out;
}

/// Affine point on the twist E'(Fp2): y² = x³ + b', b' = 4/(9+u) = 3·b₂/…
/// We reuse zc.bn254.G2 whose curve is exactly this twist.
const TwistAffine = struct { x: Fp2, y: Fp2 };

fn twistDbl(t: TwistAffine) TwistAffine {
    // λ = 3x²/2y; x3 = λ² − 2x; y3 = λ(x − x3) − y
    const lam = t.x.sqr().add(t.x.sqr().add(t.x.sqr()))
        .mul(t.y.add(t.y).inv());
    const x3 = lam.sqr().sub(t.x.add(t.x));
    const y3 = lam.mul(t.x.sub(x3)).sub(t.y);
    return .{ .x = x3, .y = y3 };
}

fn twistAdd(t: TwistAffine, q: TwistAffine) TwistAffine {
    // λ = (qy−ty)/(qx−tx); x3 = λ²−tx−qx; y3 = λ(tx−x3)−ty
    const lam = q.y.sub(t.y).mul(q.x.sub(t.x).inv());
    const x3 = lam.sqr().sub(t.x.add(q.x));
    const y3 = lam.mul(t.x.sub(x3)).sub(t.y);
    return .{ .x = x3, .y = y3 };
}

/// Coefficients (slots 0,2,6) of the scaled line l̃(P)
/// = py·d + (−n·px)·w² + (n·tx − d·ty)·w⁶, where λ = n/d. This equals
/// d · (true tangent/chord line evaluated at P).
const LineCoeffs = struct { s0: Fp2, s2: Fp2, s6: Fp2 };

fn lineNum(n: Fp2, d: Fp2, tx: Fp2, ty: Fp2, px: Fp, py: Fp) LineCoeffs {
    return .{
        .s0 = Fp2.fromBase(py).mul(d),
        .s2 = n.neg().mul(Fp2.fromBase(px)),
        .s6 = n.mul(tx).sub(d.mul(ty)),
    };
}

/// Coefficients (slots 0,4) of the vertical v(P) = px − tx·w⁴.
const VertCoeffs = struct { v0: Fp2, v4: Fp2 };

fn lineDen(px: Fp, tx: Fp2) VertCoeffs {
    return .{ .v0 = Fp2.fromBase(px), .v4 = tx.neg() };
}

/// Optimal ate Miller loop: f_{t−1,Q}(P) as ratio gnum/gden (exact, no
/// intermediate inversions). Vertical lines do NOT lie in a subfield killed
/// by final exponentiation in the direct-degree-12 representation, so they
/// are accumulated into gden and divided once at the end.
///
/// Convention (strict divisor formalism): doubling contributes
/// ℓ_{T,T}(P)/v_{2T}(P); addition contributes ℓ_{T,Q}(P)/v_{T+Q}(P).
pub const NumDenDirect = struct {
    num: Fp12Direct,
    den: Fp12Direct,

    pub fn init() NumDenDirect {
        return .{ .num = Fp12Direct.ONE, .den = Fp12Direct.ONE };
    }
};
///
/// `p` and `q` must not be the point at infinity. The guard used to be a
/// `std.debug.assert`, compiled out in `ReleaseFast`, where an infinity input
/// then produced a garbage `Fp12Direct`; use `millerLoopPairChecked` when the
/// inputs are untrusted.
pub fn millerLoopPair(p: G1Point, q: G2Point) NumDenDirect {
    return millerLoopPairChecked(p, q) catch NumDenDirect.init();
}

/// # Errors
/// `error.PointAtInfinity` when either input is the point at infinity.
pub fn millerLoopPairChecked(p: G1Point, q: G2Point) error{PointAtInfinity}!NumDenDirect {
    if (p.infinity or q.infinity) return error.PointAtInfinity;
    var gnum = Fp12Direct.ONE;
    var gden = Fp12Direct.ONE;
    var t = TwistAffine{ .x = q.x, .y = q.y };

    // Find true MSB of LOOP (< 2^128).
    var msb: u7 = 127;
    while ((LOOP >> @intCast(msb)) & 1 == 0) : (msb -= 1) {}

    // Process bits msb−1 … 0 (MSB itself is implicit in f=1, T=Q start).
    var bit: u7 = msb - 1;
    while (true) : (bit -= 1) {
        // Doubling: f ← f² · ℓ_{t,t}(P)/v_{2t}(P)
        {
            const n = t.x.sqr().add(t.x.sqr().add(t.x.sqr()));
            const d = t.y.add(t.y);
            const t2 = twistDbl(t);
            const ln = lineNum(n, d, t.x, t.y, p.x, p.y);
            const vd = lineDen(p.x, t2.x);
            gnum = gnum.sqr().mulBySparse026(ln.s0, ln.s2, ln.s6);
            gden = gden.sqr().mulBySparse04(vd.v0, vd.v4);
            t = t2;
        }
        // Addition: f ← f · ℓ_{t,q}(P)/v_{t+q}(P)
        if ((LOOP >> @intCast(bit)) & 1 == 1) {
            const n = q.y.sub(t.y);
            const d = q.x.sub(t.x);
            const tq = twistAdd(t, .{ .x = q.x, .y = q.y });
            const ln = lineNum(n, d, t.x, t.y, p.x, p.y);
            const vd = lineDen(p.x, tq.x);
            gnum = gnum.mulBySparse026(ln.s0, ln.s2, ln.s6);
            gden = gden.mulBySparse04(vd.v0, vd.v4);
            t = tq;
        }
        if (bit == 0) break;
    }
    return .{ .num = gnum, .den = gden };
}

/// Final exponentiation f ↦ f^((p¹²−1)/r).
pub fn finalExponentiate(f: Fp12Direct) Fp12Direct {
    if (f.isZero()) return Fp12Direct.ZERO;
    return f.powByLimbs(&FINAL_EXP_LIMBS);
}

/// Full optimal ate pairing e(P, Q) for P ∈ G1 ⊂ E(Fp), Q ∈ G2 ⊂ E'(Fp2).
/// Non-CT: pairing inputs in this library are treated as public data.
pub fn pairing(p: G1Point, q: G2Point) Fp12Direct {
    const parts = millerLoopPair(p, q);
    const f = parts.num.mul(parts.den.inv());
    return finalExponentiate(f);
}

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

test "fp12_direct: sqr matches mul on dense elements" {
    // Dense element exercising all 12 slots and the ξ-fold wraparound.
    var a = Fp12Direct.ZERO;
    for (0..12) |k| {
        a.coeff[k] = Fp2.new(Fp.fromInt(k + 3), Fp.fromInt(2 * k + 1));
    }
    try std.testing.expect(a.sqr().eql(a.mul(a)));
    // Sparse-ish and boundary values.
    var b = Fp12Direct.ZERO;
    b.coeff[11] = Fp2.new(Fp.fromInt(7), Fp.one());
    b.coeff[0] = Fp2.new(Fp.fromInt(13), Fp.zero());
    try std.testing.expect(b.sqr().eql(b.mul(b)));
    // Sparse multiply paths agree with generic mul.
    const c = Fp2.new(Fp.fromInt(5), Fp.fromInt(9));
    const d = Fp2.new(Fp.fromInt(2), Fp.fromInt(17));
    const e = Fp2.new(Fp.fromInt(11), Fp.zero());
    const sparse = a.mulBySparse026(c, d, e);
    var line = Fp12Direct.ZERO;
    line.coeff[0] = c;
    line.coeff[2] = d;
    line.coeff[6] = e;
    try std.testing.expect(sparse.eql(a.mul(line)));
    const sparse_v = a.mulBySparse04(c, d);
    var vert = Fp12Direct.ZERO;
    vert.coeff[0] = c;
    vert.coeff[4] = d;
    try std.testing.expect(sparse_v.eql(a.mul(vert)));
}

test "fp12_direct: inv round-trips" {
    // Small sanity: (2)^-1 · 2 == 1 in Fp12. Uses full SA&M inversion.
    const a = Fp12Direct.fromFp2(Fp2.fromInt(7));
    const a_inv = a.inv();
    try std.testing.expect(a.mul(a_inv).eql(Fp12Direct.ONE));
    try std.testing.expect(a_inv.mul(a).eql(Fp12Direct.ONE));
}

test "bn254_direct: twist point arithmetic stays on curve" {
    const b = zc.bn254.G2_b;
    const onCurve = struct {
        fn f(pt: TwistAffine) bool {
            return pt.y.sqr().sub(pt.x.sqr().mul(pt.x)).sub(b).isZero();
        }
    }.f;
    var t = TwistAffine{ .x = zc.bn254.G2_generator.x, .y = zc.bn254.G2_generator.y };
    try std.testing.expect(onCurve(t));
    // First step must be a doubling (chord degenerates when adding Q to Q).
    t = twistDbl(t);
    const g = TwistAffine{ .x = zc.bn254.G2_generator.x, .y = zc.bn254.G2_generator.y };
    for (0..5) |_| {
        t = twistAdd(t, g); // t := (i+3)·G, never ±g
        if (!onCurve(t)) return error.AddOffCurve;
    }
    // And repeated doublings.
    for (0..10) |_| {
        t = twistDbl(t);
        if (!onCurve(t)) return error.DblOffCurve;
    }
}

test "bn254_pairing: non-degenerate" {
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    const e = pairing(g1, g2);
    try std.testing.expect(!e.eql(Fp12Direct.ONE));
}

test "bn254_pairing: bilinear small scalars" {
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    const two_g1 = g1.scalarMul(@as(u64, 2));
    const three_g2 = g2.scalarMul(@as(u64, 3));

    const lhs = pairing(two_g1, three_g2); // e(2P, 3Q) = e(P,Q)^6
    const base = pairing(g1, g2);
    const rhs = base.powSmall(6);
    try std.testing.expect(lhs.eql(rhs));
}

test "bn254_pairing: r-torsion annihilates" {
    const Fr = zc.bn254.Fr;
    const g2 = zc.bn254.G2_generator;
    // e(−P,Q)·e(P,Q) = 1, the statement this test was always meant to make.
    // It used to assert `prod.mul(prod.inv()).eql(ONE)`, which is `x·x⁻¹ == 1`
    // and holds for every x in the ring: a check that could not fail. The
    // product itself has to be one, and it is, because the line functions are
    // odd in P — which is a property of the loop, not of the value.
    const r_minus_1 = Fr.MODULUS - 1;
    const e_neg = pairing(zc.bn254.G1_generator.scalarMul(r_minus_1), g2); // e(-P,Q)
    const e_pos = pairing(zc.bn254.G1_generator, g2);
    try std.testing.expect(e_neg.mul(e_pos).eql(Fp12Direct.ONE));

    // And the value really is r-torsion: e^r == 1, with r's limbs built at
    // comptime from the curve order. This is the check that would catch a
    // value outside μ_r; it passes for this file's wrong value too, which is
    // exactly why it is a supporting check and not the one that matters.
    var r_limbs: [4]u64 = undefined;
    var rv: u512 = Fr.MODULUS;
    for (&r_limbs) |*l| {
        l.* = @intCast(rv & 0xFFFFFFFFFFFFFFFF);
        rv >>= 64;
    }
    try std.testing.expect(e_pos.powByLimbs(&r_limbs).eql(Fp12Direct.ONE));
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

// ---------------------------------------------------------------------------
// Known-answer vector from an independent implementation
// ---------------------------------------------------------------------------

/// Convert the py_ecc vector into this ring's coordinates. The isomorphism is
/// `t -> w^2`, because `(w^2)^6 = w^12 = 9+u` and `9+u` is the root of
/// py_ecc's modulus polynomial `(9+u)^2 - 18(9+u) + 82 = 0` that this ring's
/// own non-residue selects. Since this ring's basis is `1, w, ..., w^11`, the
/// isomorphism lands on the even powers, so the image is sparse: slot `2k`
/// takes `a_k`, and `a_6..a_11` wrap through `w^12 = 9+u` back into the same
/// six slots scaled by it.
fn katToDirect(a: *const [12]Fp) Fp12Direct {
    var out = Fp12Direct.ZERO;
    for (0..6) |k| {
        out.coeff[2 * k] = Fp2.fromBase(a[k]).add(Fp2.fromBase(a[k + 6]).mul(Fp12Direct.XI));
    }
    return out;
}

/// Product in py_ecc's basis, Fq[t]/(t^12 - 18 t^6 + 82): schoolbook over 24
/// coefficients, then reduce from the top down with
/// t^k ↦ 18 t^(k-6) - 82 t^(k-12).
fn pyMulDirect(a: *const [12]Fp, b: *const [12]Fp) [12]Fp {
    var c: [24]Fp = undefined;
    for (&c) |*x| x.* = Fp.zero();
    for (0..12) |i| {
        for (0..12) |j| {
            c[i + j] = c[i + j].add(a[i].mul(b[j]));
        }
    }
    var k: usize = 23;
    while (k >= 12) : (k -= 1) {
        if (!c[k].isZero()) {
            c[k - 6] = c[k - 6].add(c[k].mul(Fp.fromInt(18)));
            c[k - 12] = c[k - 12].sub(c[k].mul(Fp.fromInt(82)));
            c[k] = Fp.zero();
        }
    }
    var r: [12]Fp = undefined;
    for (0..12) |i| r[i] = c[i];
    return r;
}

/// Deterministic pseudo-random Fp (splitmix64), so the test needs no
/// random() helper and never depends on the platform.
fn pseudoFpDirect(seed: u64) Fp {
    var z = seed +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z = z ^ (z >> 31);
    return Fp.fromInt(z);
}

test "bn254_direct: the py_ecc basis conversion is a ring homomorphism" {
    // The conversion the KAT rests on must preserve products between py_ecc's
    // basis and this ring, checked against py_ecc's own reduction computed
    // here. A wrong isomorphism -- a Frobenius twist, a different root of the
    // modulus polynomial -- fails on random inputs rather than yielding a
    // plausible element, which is the failure mode this repository cares
    // about.
    var s: u64 = 0xD1EC_7B0A;
    var t: usize = 0;
    while (t < 4) : (t += 1) {
        var a: [12]Fp = undefined;
        var b: [12]Fp = undefined;
        for (0..12) |i| {
            a[i] = pseudoFpDirect(s +% @as(u64, @intCast(i)));
            b[i] = pseudoFpDirect(s +% @as(u64, @intCast(i)) +% 0x500);
        }
        s +%= 0x1000;
        try std.testing.expect(katToDirect(&a).mul(katToDirect(&b)).eql(katToDirect(&pyMulDirect(&a, &b))));
    }
}

/// The py_ecc 8.0.0 known-answer vector for `pairing(G1, G2)`, in the
/// basis 1, t, ..., t^11 of Fq[t]/(t^12 - 18 t^6 + 82). Both py_ecc
/// modules (`py_ecc.bn128` and `py_ecc.optimized_bn128`) agree on it
/// coefficient for coefficient. Wrapped in a branch-quota block because
/// each fromInt over a Montgomery field is a comptime multiplication.
const PY_ECC_KAT = blk: {
    @setEvalBranchQuota(100_000);
    break :blk [12]Fp{
        Fp.fromInt(0x28c6e04df059260df7d2d2a1f9b5f77676d1939847852c4ed50d2318744c1d5f), // [0]
        Fp.fromInt(0x17bb74adab1705c26133af1dac87044a3833ac011018e8158da48382bbd2dcd6), // [1]
        Fp.fromInt(0xd3bd72f54d742f78ea9e6015c8ea2f2e7fbb728c9c905ec531dcf7de5b246f0), // [2]
        Fp.fromInt(0x90cb8ee97e091a667af03882b06c3ecb4e437993cbd1b05b98c7f9dfcfe9c40), // [3]
        Fp.fromInt(0x16b6d855b5cbf76f9829a309db52f5c442f65ae29f996af59d65f85f4afe78a), // [4]
        Fp.fromInt(0xa0272204db51dadc0342bd318b9302a44faec12ff500bdd4d4b012ffe45f36f), // [5]
        Fp.fromInt(0x84f330485b09e866bc2f2ea2b897394deaf3f12aa31f28cb0552990967d4704), // [6]
        Fp.fromInt(0x27ed208e7a0b55ae6e710bbfbd2fd922669c026360e37cc5b2ab862411536104), // [7]
        Fp.fromInt(0x2067586885c3318eeffa1938c754fe3c60224ee5ae15e66af6b5104c47c8c5d8), // [8]
        Fp.fromInt(0x279db296f9d479292532c7c493d8e0722b6efae42158387564889c79fc038ee3), // [9]
        Fp.fromInt(0x2b03614464f04dd772d86df88674c270ffc8747ea13e72da95e3594468f222c4), // [10]
        Fp.fromInt(0x108c19d15f9446f744d0f110405d3856d6cc3bda6c4d537663729f5257628417), // [11]
    };
};


test "bn254_direct: DEFECT MARKER -- the value is not py_ecc's, and this inverts when the loop is fixed" {
    // This module's three pairing tests (non-degenerate, bilinear small
    // scalars, r-torsion) all pass against this value, because they compare
    // the implementation with itself: bilinearity holds for any bilinear map,
    // and the value is in μ_r. This marker asserts the defect on purpose --
    // the same shape as the one bn254.zig carried -- because a test asserting
    // the correct value cannot be written while the value is wrong, and a
    // suite that goes quietly green is worse than one that names what is
    // broken. When the loop and its extra terms are fixed this test FAILS and
    // has to be inverted to `expected.eql(actual)`; that inversion is the
    // signal, and a marker that cannot fail is not a marker.
    //
    // Measured 2026-10-09, with the library's own arithmetic: the value is not
    // the py_ecc value under any of the twelve isomorphisms t -> w^{2·p^j}
    // (each one checked in this ring), it is not a Frobenius power of it, and
    // the quotient e/real is not a constant. So it is a different element of
    // μ_r, not a presentation difference -- the loop parameter below is 6x²
    // where py_ecc and the verified tower run 6x+2, and setting it to 6x+2
    // alone breaks bilinearity, so the loop and its extra terms were built
    // for each other and both are wrong together.
    const expected = katToDirect(&PY_ECC_KAT);
    const actual = pairing(zc.bn254.G1_generator, zc.bn254.G2_generator);
    try std.testing.expect(!expected.eql(actual));

    // Controls, so the assertion above discriminates rather than holds
    // vacuously: a tampered vector still maps somewhere else, and the
    // conversion it goes through is a ring homomorphism (the test above).
    var tampered = PY_ECC_KAT;
    tampered[3] = tampered[3].add(Fp.one());
    try std.testing.expect(!katToDirect(&tampered).eql(actual));
    try std.testing.expect(!katToDirect(&tampered).eql(expected));
}
