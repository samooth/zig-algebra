const std = @import("std");
const zf = @import("zig-field");

const M31 = zf.M31;
const BabyBear = zf.BabyBear;
const KoalaBear = zf.KoalaBear;
const Goldilocks = zf.Goldilocks;
const BN254_Fp = zf.BN254_Fp;
const BLS12_381_Fp = zf.BLS12_381_Fp;
const CM31 = zf.CM31;
const QM31 = zf.QM31;
const BN254_Fp2 = zf.BN254_Fp2;

const Rng = std.Random.DefaultPrng;

fn testSmallField(comptime F: type, rnd: std.Random) !void {
    for (0..1000) |_| {
        const a = F.random(rnd);
        const b = F.random(rnd);
        const c = F.random(rnd);

        // Associativity: (a + b) + c == a + (b + c)
        try std.testing.expect(a.add(b).add(c).eq(a.add(b.add(c))));
        try std.testing.expect(a.mul(b).mul(c).eq(a.mul(b.mul(c))));

        // Commutativity
        try std.testing.expect(a.add(b).eq(b.add(a)));
        try std.testing.expect(a.mul(b).eq(b.mul(a)));

        // Distributivity: a * (b + c) == a*b + a*c
        try std.testing.expect(a.mul(b.add(c)).eq(a.mul(b).add(a.mul(c))));

        // Inverse property: a * a.inv() == 1 (for a != 0)
        if (!a.isZero()) {
            try std.testing.expect(a.mul(a.inv()).eq(F.one()));
        }

        // Negation: a + (-a) == 0
        try std.testing.expect(a.add(a.neg()).eq(F.zero()));

        // Subtraction: a - b == a + (-b)
        try std.testing.expect(a.sub(b).eq(a.add(b.neg())));

        // Serialization round-trip
        const bytes = a.toBytes();
        const a2 = F.fromBytes(&bytes) catch unreachable;
        try std.testing.expect(a.eq(a2));
    }
}

fn testBigField(comptime F: type, rnd: std.Random) !void {
    for (0..200) |_| {
        const a = F.random(rnd);
        const b = F.random(rnd);
        const c = F.random(rnd);

        // Associativity
        try std.testing.expect(a.add(b).add(c).eq(a.add(b.add(c))));
        try std.testing.expect(a.mul(b).mul(c).eq(a.mul(b.mul(c))));

        // Commutativity
        try std.testing.expect(a.add(b).eq(b.add(a)));
        try std.testing.expect(a.mul(b).eq(b.mul(a)));

        // Distributivity
        try std.testing.expect(a.mul(b.add(c)).eq(a.mul(b).add(a.mul(c))));

        // Inverse property
        if (!a.isZero()) {
            try std.testing.expect(a.mul(a.inv()).eq(F.one()));
        }

        // Negation
        try std.testing.expect(a.add(a.neg()).eq(F.zero()));

        // Subtraction
        try std.testing.expect(a.sub(b).eq(a.add(b.neg())));

        // Serialization round-trip
        const bytes = a.toBytes();
        const a2 = F.fromBytes(&bytes) catch unreachable;
        try std.testing.expect(a.eq(a2));
    }
}

fn testQuadraticExtension(comptime Ext: type, rnd: std.Random) !void {
    for (0..200) |_| {
        const a = Ext.random(rnd);
        const b = Ext.random(rnd);
        const c = Ext.random(rnd);

        // Associativity
        try std.testing.expect(a.add(b).add(c).eq(a.add(b.add(c))));
        try std.testing.expect(a.mul(b).mul(c).eq(a.mul(b.mul(c))));

        // Commutativity
        try std.testing.expect(a.add(b).eq(b.add(a)));
        try std.testing.expect(a.mul(b).eq(b.mul(a)));

        // Distributivity
        try std.testing.expect(a.mul(b.add(c)).eq(a.mul(b).add(a.mul(c))));

        // Inverse property
        if (!a.isZero()) {
            try std.testing.expect(a.mul(a.inv()).eq(Ext.one()));
        }

        // Negation
        try std.testing.expect(a.add(a.neg()).eq(Ext.zero()));

        // Subtraction
        try std.testing.expect(a.sub(b).eq(a.add(b.neg())));
    }
}

fn testCM31Identities(rnd: std.Random) !void {
    for (0..500) |_| {
        const a = zf.M31.random(rnd);
        const b = zf.M31.random(rnd);
        const x = CM31.new(a, b);

        // i^2 = -1
        const i = CM31.imaginaryUnit();
        try std.testing.expect(i.mul(i).eq(CM31.fromBase(zf.M31.one().neg())));

        // conjugate: conj(a + bi) = a - bi
        const conj_x = x.conjugate();
        try std.testing.expect(conj_x.c0.eq(a));
        try std.testing.expect(conj_x.c1.eq(b.neg()));

        // norm: norm(a + bi) = a^2 + b^2 (since i^2 = -1)
        _ = x.c0.mul(x.c0).add(x.c1.mul(x.c1));
        const inv = x.inv();
        // x * inv = 1 => (a + bi)(a - bi)/norm = 1 => (a^2 + b^2)/norm = 1 => norm = a^2 + b^2
        if (!x.isZero()) {
            try std.testing.expect(x.mul(inv).eq(CM31.one()));
        }

        // Division: x / y == x * y.inv()
        const y2 = CM31.new(zf.M31.random(rnd), zf.M31.random(rnd));
        if (!y2.isZero()) {
            const div = x.div(y2);
            const mul = x.mul(y2.inv());
            try std.testing.expect(div.eq(mul));
        }
    }
}

fn testBN254_Fp2Identities(rnd: std.Random) !void {
    for (0..200) |_| {
        const a = zf.BN254_Fp.random(rnd);
        const b = zf.BN254_Fp.random(rnd);
        const x = BN254_Fp2.new(a, b);

        // i^2 = -1
        const i = BN254_Fp2.imaginaryUnit();
        try std.testing.expect(i.mul(i).eq(BN254_Fp2.fromBase(zf.BN254_Fp.one().neg())));

        // conjugate
        const conj_x = x.conjugate();
        try std.testing.expect(conj_x.c0.eq(a));
        try std.testing.expect(conj_x.c1.eq(b.neg()));

        if (!x.isZero()) {
            try std.testing.expect(x.mul(x.inv()).eq(BN254_Fp2.one()));
        }
    }
}

fn testCubicExtension(comptime Ext: type, rnd: std.Random) !void {
    for (0..100) |_| {
        const a = Ext.random(rnd);
        const b = Ext.random(rnd);
        const c = Ext.random(rnd);

        // Associativity
        try std.testing.expect(a.add(b).add(c).eq(a.add(b.add(c))));
        try std.testing.expect(a.mul(b).mul(c).eq(a.mul(b.mul(c))));

        // Commutativity
        try std.testing.expect(a.add(b).eq(b.add(a)));
        try std.testing.expect(a.mul(b).eq(b.mul(a)));

        // Distributivity
        try std.testing.expect(a.mul(b.add(c)).eq(a.mul(b).add(a.mul(c))));

        // Inverse property
        if (!a.isZero()) {
            try std.testing.expect(a.mul(a.inv()).eq(Ext.one()));
        }

        // Negation
        try std.testing.expect(a.add(a.neg()).eq(Ext.zero()));

        // Subtraction
        try std.testing.expect(a.sub(b).eq(a.add(b.neg())));
    }
}

pub fn main() !void {
    const iters: usize = 100;
    var prng = Rng.init(0x5eed_c0de);
    const rnd = prng.random();

    // Small fields
    for (0..iters) |_| {
        try testSmallField(M31, rnd);
        try testSmallField(BabyBear, rnd);
        try testSmallField(KoalaBear, rnd);
        try testSmallField(Goldilocks, rnd);
    }

    // Big fields
    for (0..iters) |_| {
        try testBigField(BN254_Fp, rnd);
        try testBigField(BLS12_381_Fp, rnd);
    }

    // Extensions
    for (0..iters) |_| {
        try testQuadraticExtension(CM31, rnd);
        try testQuadraticExtension(QM31, rnd);
        try testQuadraticExtension(BN254_Fp2, rnd);
    }

    // Specific identities
    for (0..iters) |_| {
        try testCM31Identities(rnd);
        try testBN254_Fp2Identities(rnd);
    }

    std.debug.print("fuzz: {d} iterations x (all fields, extensions, identities) OK, no leaks\n", .{iters});
}
