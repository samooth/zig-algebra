// SPDX-License-Identifier: MIT OR Apache-2.0

const std = @import("std");
const zf = @import("zig-field");

fn testQuadratic(comptime Ext: type, comptime Base: type) !void {
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const a = Ext.new(Base.random(rnd), Base.random(rnd));
        const b = Ext.new(Base.random(rnd), Base.random(rnd));

        // Associativity
        try std.testing.expect(a.add(b).add(a).eq(a.add(b.add(a))));
        try std.testing.expect(a.mul(b).mul(a).eq(a.mul(b.mul(a))));

        // Commutativity
        try std.testing.expect(a.add(b).eq(b.add(a)));
        try std.testing.expect(a.mul(b).eq(b.mul(a)));

        // Distributivity
        try std.testing.expect(a.mul(b.add(a)).eq(a.mul(b).add(a.mul(a))));

        // Inverse: only meaningful for non-zero elements, and `inv` is total
        // (`inv(0) == 0`), so the zero case is skipped explicitly.
        if (!a.isZero()) {
            try std.testing.expect(a.mul(a.inv()).eq(Ext.one()));
            try std.testing.expect((try a.invChecked()).eq(a.inv()));
            // x * x^-1 == 1 in both directions.
            try std.testing.expect(a.inv().mul(a).eq(Ext.one()));
        }
    }
}

test "CM31 extension identities" {
    try testQuadratic(zf.CM31, zf.M31);

    // i^2 == -1
    const i = zf.CM31.new(zf.M31.zero(), zf.M31.one());
    try std.testing.expect(i.mul(i).eq(zf.CM31.fromBase(zf.M31.one().neg())));
}

test "QM31 extension identities" {
    try testQuadratic(zf.QM31, zf.CM31);

    // j^2 == -i
    const j = zf.QM31.new(zf.CM31.zero(), zf.CM31.one());
    const minus_i = zf.QM31.new(zf.CM31.new(zf.M31.zero(), zf.M31.one()).neg(), zf.CM31.zero());
    try std.testing.expect(j.mul(j).eq(minus_i));
}

test "BN254_Fp2 extension identities" {
    try testQuadratic(zf.BN254_Fp2, zf.BN254_Fp);

    // u^2 == -1
    const u = zf.BN254_Fp2.new(zf.BN254_Fp.zero(), zf.BN254_Fp.one());
    try std.testing.expect(u.mul(u).eq(zf.BN254_Fp2.fromBase(zf.BN254_Fp.one().neg())));
}

test "CubicExtension inverse and serialization" {
    const Ext = zf.CubicExtension(zf.M31, zf.M31.fromInt(5));
    const value = Ext.new(zf.M31.fromInt(3), zf.M31.fromInt(4), zf.M31.fromInt(5));
    try std.testing.expect(value.mul(value.inv()).eq(Ext.one()));
    try std.testing.expect((try value.invChecked()).eq(value.inv()));
    const bytes = value.toBytes();
    const decoded = try Ext.fromBytes(&bytes);
    try std.testing.expect(decoded.eq(value));
}

test "inverse and division of zero are defined, checked variants report them" {
    // Legacy APIs return zero instead of hanging (ReleaseFast) or asserting
    // (Debug); the checked APIs report the missing inverse/divisor.
    inline for (.{ zf.CM31, zf.QM31, zf.BN254_Fp2 }) |Ext| {
        try std.testing.expect(Ext.zero().inv().isZero());
        try std.testing.expect(Ext.zero().inverse().isZero());
        try std.testing.expectError(error.InverseOfZero, Ext.zero().invChecked());

        const a = Ext.fromInt(3);
        const b = Ext.fromInt(7);
        try std.testing.expect(a.div(b).eq(a.mul(b.inv())));
        try std.testing.expect(a.div(Ext.zero()).isZero());
        try std.testing.expectError(error.DivisionByZero, a.divChecked(Ext.zero()));
        try std.testing.expect((try a.divChecked(b)).eq(a.div(b)));
    }

    const Cubic = zf.CubicExtension(zf.M31, zf.M31.fromInt(5));
    try std.testing.expect(Cubic.zero().inv().isZero());
    try std.testing.expectError(error.InverseOfZero, Cubic.zero().invChecked());
    try std.testing.expect(Cubic.fromInt(9).div(Cubic.zero()).isZero());
    try std.testing.expectError(error.DivisionByZero, Cubic.fromInt(9).divChecked(Cubic.zero()));
}

test "Roots of unity" {
    // Only test fast path (t <= M31.two_adicity = 1)
    // Slow path (t > 1) is too slow in Debug mode
    var t: usize = 0;
    while (t <= 1) : (t += 1) {
        const w = try zf.CM31.primitiveRootOfUnity(t);
        try std.testing.expect(w.pow(@as(u128, 1) << @intCast(t)).isOne());
        if (t > 0) {
            try std.testing.expect(!w.pow(@as(u128, 1) << @intCast(t - 1)).isOne());
        }
    }
}

test "QuadraticExtension imaginary unit squares to NON_RESIDUE" {
    const M31 = zf.M31;
    const CM31 = zf.CM31;

    const v = CM31.new(M31.zero(), M31.one()); // v = 0 + 1*v
    const v2 = v.mul(v); // v^2 = NON_RESIDUE
    const nr = CM31.fromBase(CM31.NON_RESIDUE);
    try std.testing.expect(v2.eq(nr));
}

test "QuadraticExtension frobenius" {
    const F = zf.M31;
    const CM31 = zf.CM31;

    // For M31 (p ≡ 3 mod 4), frobenius(a + b*i) = a - b*i
    const a = CM31.new(F.fromInt(3), F.fromInt(4));
    const f = a.frobenius();
    const expected = CM31.new(F.fromInt(3), F.fromInt(4).neg());
    try std.testing.expect(f.eq(expected));

    // frobenius(frobenius(x)) = x for quadratic extensions
    const ff = f.frobenius();
    try std.testing.expect(ff.eq(a));
}

test "SmallField batchAdd/batchSub/batchMul" {
    const F = zf.M31;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    var a: [10]F = undefined;
    var b: [10]F = undefined;
    var out: [10]F = undefined;
    for (0..10) |i| {
        a[i] = F.random(rnd);
        b[i] = F.random(rnd);
    }

    try F.batchAdd(&a, &b, &out);
    for (0..10) |i| {
        try std.testing.expect(out[i].eq(a[i].add(b[i])));
    }

    try F.batchSub(&a, &b, &out);
    for (0..10) |i| {
        try std.testing.expect(out[i].eq(a[i].sub(b[i])));
    }

    try F.batchMul(&a, &b, &out);
    for (0..10) |i| {
        try std.testing.expect(out[i].eq(a[i].mul(b[i])));
    }
}

test "BigField batchAdd/batchSub/batchMul" {
    const F = zf.BN254_Fp;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    var a: [5]F = undefined;
    var b: [5]F = undefined;
    var out: [5]F = undefined;
    for (0..5) |i| {
        a[i] = F.random(rnd);
        b[i] = F.random(rnd);
    }

    try F.batchAdd(&a, &b, &out);
    for (0..5) |i| {
        try std.testing.expect(out[i].eq(a[i].add(b[i])));
    }

    try F.batchSub(&a, &b, &out);
    for (0..5) |i| {
        try std.testing.expect(out[i].eq(a[i].sub(b[i])));
    }

    try F.batchMul(&a, &b, &out);
    for (0..5) |i| {
        try std.testing.expect(out[i].eq(a[i].mul(b[i])));
    }
}

// The P0 this pins: `primitiveRootOfUnity` on a quadratic extension hung for
// every `log_size` above the base field's two-adicity, because the
// non-residue search walked the real axis -- where nothing can be a
// non-residue. Every number below is measured against the extension, not
// against the base field it embeds.
test "quadratic extension: a root of order above the base two-adicity, off the real axis" {
    const M61 = zf.M61;
    const E = zf.extension.QuadraticExtension(M61, M61.one().neg());

    // The premise, written down where the bug was: for a in F_p^*,
    // a^((p^2-1)/2) = (a^(p-1))^((p+1)/2) = 1, so the real axis is all
    // residues. Measured: legendre == 1 for every one of these.
    for (2..9) |a| {
        try std.testing.expectEqual(@as(i8, 1), E.fromInt(a).legendre());
    }
    // And a non-residue does exist off it, which is what the search has to
    // reach. Measured on this field: 5+3i.
    try std.testing.expectEqual(@as(i8, -1), E.new(M61.fromInt(5), M61.fromInt(3)).legendre());

    // The P0 input itself: 62 > 1, so this used to compile and never return.
    try std.testing.expect(E.two_adicity > M61.two_adicity);
    const log_size = E.two_adicity;
    const w = try E.primitiveRootOfUnity(log_size);

    // The contract, checked against the field and not against the helper that
    // built it: exact order 2^log_size.
    const two_pow = @as(u128, 1) << @intCast(log_size);
    try std.testing.expect(w.pow(two_pow).isOne());
    try std.testing.expect(!w.pow(two_pow / 2).isOne());

    // Same path, cheap field, so the search is exercised on every run rather
    // than only here: CM31 has base two-adicity 1 and extension two-adicity 32.
    const CM = zf.CM31;
    try std.testing.expect(CM.two_adicity > 1);
    const wc = try CM.primitiveRootOfUnity(CM.two_adicity);
    const two_pow_c = @as(u128, 1) << @intCast(CM.two_adicity);
    try std.testing.expect(wc.pow(two_pow_c).isOne());
    try std.testing.expect(!wc.pow(two_pow_c / 2).isOne());
}
