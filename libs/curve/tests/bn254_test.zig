// SPDX-License-Identifier: MIT OR Apache-2.0

const std = @import("std");
const bn254 = @import("zig-curve").bn254;

test "G1 generator on curve" {
    std.debug.assert(bn254.G1_generator.isOnCurve());
}

test "G1 identity" {
    const id = bn254.G1.zero();
    std.debug.assert(id.add(bn254.G1_generator).eql(bn254.G1_generator));
}

test "G1 scalar mul by 2" {
    const p = bn254.G1_generator.scalarMul(@as(u64, 2));
    const p2 = bn254.G1_generator.add(bn254.G1_generator);
    std.debug.assert(p.eql(p2));
}

test "G1 scalar mul by 0" {
    const p = bn254.G1_generator.scalarMul(@as(u64, 0));
    std.debug.assert(p.eql(bn254.G1.zero()));
}

test "G1 neg" {
    const neg = bn254.G1_generator.neg();
    const sum = bn254.G1_generator.add(neg);
    std.debug.assert(sum.eql(bn254.G1.zero()));
}

test "G1 associative law: (a+b)+c = a+(b+c)" {
    const a = bn254.G1_generator.scalarMul(@as(u64, 1));
    const b = bn254.G1_generator.scalarMul(@as(u64, 2));
    const c = bn254.G1_generator.scalarMul(@as(u64, 3));

    const ab = a.add(b);
    const ab_c = ab.add(c);

    const bc = b.add(c);
    const a_bc = a.add(bc);

    std.debug.assert(ab_c.eql(a_bc));
}

test "Fr scalar field basic ops" {
    const one = bn254.Fr.fromInt(1);
    const two = bn254.Fr.fromInt(2);
    const sum = one.add(two);
    const expected = bn254.Fr.fromInt(3);
    std.debug.assert(sum.eql(expected));
}
