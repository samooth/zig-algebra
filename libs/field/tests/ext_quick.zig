const std = @import("std");
const zf = @import("zig-field");

test "CM31 extension sanity" {
    const CM31 = zf.CM31;
    const i = CM31.imaginaryUnit();
    try std.testing.expect(i.mul(i).eq(CM31.fromBase(zf.M31.one().neg())));
    var prng = std.Random.DefaultPrng.init(42);
    for (0..100) |_| {
        const a = zf.M31.random(prng.random());
        const b = zf.M31.random(prng.random());
        const e1 = CM31.new(a, b);
        const inv = e1.inv();
        try std.testing.expect(e1.mul(inv).eq(CM31.one()));
    }
}

test "BN254_Fp2 extension sanity" {
    const Fp2 = zf.BN254_Fp2;
    const i = Fp2.imaginaryUnit();
    try std.testing.expect(i.mul(i).eq(Fp2.fromBase(zf.BN254_Fp.one().neg())));
    var prng = std.Random.DefaultPrng.init(43);
    for (0..100) |_| {
        const a = zf.BN254_Fp.random(prng.random());
        const b = zf.BN254_Fp.random(prng.random());
        const e1 = Fp2.new(a, b);
        const inv = e1.inv();
        try std.testing.expect(e1.mul(inv).eq(Fp2.one()));
    }
}
