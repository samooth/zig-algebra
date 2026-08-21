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

        // Inverse
        try std.testing.expect(!a.isZero() or !a.mul(a.inv()).eq(Ext.one()));
        // Norm * inv = 1
        try std.testing.expect(!a.isZero() or a.mul(a.inv()).eq(Ext.one()));
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

test "Roots of unity" {
    // Only test fast path (t <= M31.two_adicity = 1)
    // Slow path (t > 1) is too slow in Debug mode
    var t: usize = 0;
    while (t <= 1) : (t += 1) {
        const w = zf.CM31.primitiveRootOfUnity(t);
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

    F.batchAdd(&a, &b, &out);
    for (0..10) |i| {
        try std.testing.expect(out[i].eq(a[i].add(b[i])));
    }

    F.batchSub(&a, &b, &out);
    for (0..10) |i| {
        try std.testing.expect(out[i].eq(a[i].sub(b[i])));
    }

    F.batchMul(&a, &b, &out);
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

    F.batchAdd(&a, &b, &out);
    for (0..5) |i| {
        try std.testing.expect(out[i].eq(a[i].add(b[i])));
    }

    F.batchSub(&a, &b, &out);
    for (0..5) |i| {
        try std.testing.expect(out[i].eq(a[i].sub(b[i])));
    }

    F.batchMul(&a, &b, &out);
    for (0..5) |i| {
        try std.testing.expect(out[i].eq(a[i].mul(b[i])));
    }
}
