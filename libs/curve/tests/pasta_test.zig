// SPDX-License-Identifier: MIT OR Apache-2.0

const std = @import("std");
const pasta = @import("zig-curve").pasta;

test "Pallas generator on curve" {
    std.debug.assert(pasta.Pallas_generator.isOnCurve());
}

test "Pallas identity" {
    const id = pasta.Pallas.zero();
    std.debug.assert(id.add(pasta.Pallas_generator).eql(pasta.Pallas_generator));
}

test "Pallas scalar mul by 2" {
    const p = pasta.Pallas_generator.scalarMul(@as(u64, 2));
    const p2 = pasta.Pallas_generator.add(pasta.Pallas_generator);
    std.debug.assert(p.eql(p2));
}

test "Pallas scalar mul by 0" {
    const p = pasta.Pallas_generator.scalarMul(@as(u64, 0));
    std.debug.assert(p.eql(pasta.Pallas.zero()));
}

test "Pallas neg" {
    const neg = pasta.Pallas_generator.neg();
    const sum = pasta.Pallas_generator.add(neg);
    std.debug.assert(sum.eql(pasta.Pallas.zero()));
}

test "Pallas associative law: (a+b)+c = a+(b+c)" {
    const a = pasta.Pallas_generator.scalarMul(@as(u64, 1));
    const b = pasta.Pallas_generator.scalarMul(@as(u64, 2));
    const c = pasta.Pallas_generator.scalarMul(@as(u64, 3));

    const ab = a.add(b);
    const ab_c = ab.add(c);

    const bc = b.add(c);
    const a_bc = a.add(bc);

    std.debug.assert(ab_c.eql(a_bc));
}

test "Vesta generator on curve" {
    std.debug.assert(pasta.Vesta_generator.isOnCurve());
}

test "Vesta identity" {
    const id = pasta.Vesta.zero();
    std.debug.assert(id.add(pasta.Vesta_generator).eql(pasta.Vesta_generator));
}

test "Vesta scalar mul by 2" {
    const p = pasta.Vesta_generator.scalarMul(@as(u64, 2));
    const p2 = pasta.Vesta_generator.add(pasta.Vesta_generator);
    std.debug.assert(p.eql(p2));
}

test "Vesta scalar mul by 0" {
    const p = pasta.Vesta_generator.scalarMul(@as(u64, 0));
    std.debug.assert(p.eql(pasta.Vesta.zero()));
}

test "Vesta neg" {
    const neg = pasta.Vesta_generator.neg();
    const sum = pasta.Vesta_generator.add(neg);
    std.debug.assert(sum.eql(pasta.Vesta.zero()));
}

test "Vesta associative law: (a+b)+c = a+(b+c)" {
    const a = pasta.Vesta_generator.scalarMul(@as(u64, 1));
    const b = pasta.Vesta_generator.scalarMul(@as(u64, 2));
    const c = pasta.Vesta_generator.scalarMul(@as(u64, 3));

    const ab = a.add(b);
    const ab_c = ab.add(c);

    const bc = b.add(c);
    const a_bc = a.add(bc);

    std.debug.assert(ab_c.eql(a_bc));
}

test "2-cycle property: PallasScalar = Vesta base" {
    // Verify types are the same by comparing field moduli
    std.debug.assert(pasta.PallasScalar.MODULUS == pasta.VestaFp.MODULUS);
}

test "2-cycle property: VestaScalar = Pallas base" {
    std.debug.assert(pasta.VestaScalar.MODULUS == pasta.PallasFp.MODULUS);
}
