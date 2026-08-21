// SPDX-License-Identifier: MIT OR Apache-2.0

const std = @import("std");
const bls12_381 = @import("zig-curve").bls12_381;

test "G1 generator on curve" {
    std.debug.assert(bls12_381.G1_generator.isOnCurve());
}

test "G1 identity" {
    const id = bls12_381.G1.zero();
    std.debug.assert(id.add(bls12_381.G1_generator).eql(bls12_381.G1_generator));
}

test "G1 scalar mul by 2" {
    const p = bls12_381.G1_generator.scalarMul(@as(u64, 2));
    const p2 = bls12_381.G1_generator.add(bls12_381.G1_generator);
    std.debug.assert(p.eql(p2));
}

test "G1 scalar mul by 0" {
    const p = bls12_381.G1_generator.scalarMul(@as(u64, 0));
    std.debug.assert(p.eql(bls12_381.G1.zero()));
}

test "G1 neg" {
    const neg = bls12_381.G1_generator.neg();
    const sum = bls12_381.G1_generator.add(neg);
    std.debug.assert(sum.eql(bls12_381.G1.zero()));
}

test "G1 associative law: (a+b)+c = a+(b+c)" {
    const a = bls12_381.G1_generator.scalarMul(@as(u64, 1));
    const b = bls12_381.G1_generator.scalarMul(@as(u64, 2));
    const c = bls12_381.G1_generator.scalarMul(@as(u64, 3));

    const ab = a.add(b);
    const ab_c = ab.add(c);

    const bc = b.add(c);
    const a_bc = a.add(bc);

    std.debug.assert(ab_c.eql(a_bc));
}

test "Fr scalar field basic ops" {
    const one = bls12_381.Fr.fromInt(1);
    const two = bls12_381.Fr.fromInt(2);
    const sum = one.add(two);
    const expected = bls12_381.Fr.fromInt(3);
    std.debug.assert(sum.eql(expected));
}
