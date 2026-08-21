const std = @import("std");
const zf = @import("zig-field");

test "M31 Vec8 SIMD parity" {
    const M31 = zf.M31;
    const Vec8 = M31.Vec8;

    // Verify Vec8 type exists
    comptime {
        std.debug.assert(Vec8 != void);
    }

    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    // Test addVec8 vs scalar
    for (0..100) |_| {
        var a_vals: [8]u64 = undefined;
        var b_vals: [8]u64 = undefined;
        for (0..8) |i| {
            a_vals[i] = M31.random(rnd).value;
            b_vals[i] = M31.random(rnd).value;
        }
        const a: Vec8 = @as(Vec8, .{ a_vals[0], a_vals[1], a_vals[2], a_vals[3], a_vals[4], a_vals[5], a_vals[6], a_vals[7] });
        const b: Vec8 = @as(Vec8, .{ b_vals[0], b_vals[1], b_vals[2], b_vals[3], b_vals[4], b_vals[5], b_vals[6], b_vals[7] });
        const sum_vec = M31.reduceVec8(M31.addVec8(a, b));
        const sum_arr: [8]u64 = @bitCast(sum_vec);
        for (0..8) |i| {
            const sum_scalar = M31.fromInt(a_vals[i]).add(M31.fromInt(b_vals[i]));
            try std.testing.expect(sum_arr[i] == sum_scalar.value);
        }
    }

    // Test subVec8 vs scalar
    for (0..100) |_| {
        var a_vals: [8]u64 = undefined;
        var b_vals: [8]u64 = undefined;
        for (0..8) |i| {
            a_vals[i] = M31.random(rnd).value;
            b_vals[i] = M31.random(rnd).value;
        }
        const a: Vec8 = @as(Vec8, .{ a_vals[0], a_vals[1], a_vals[2], a_vals[3], a_vals[4], a_vals[5], a_vals[6], a_vals[7] });
        const b: Vec8 = @as(Vec8, .{ b_vals[0], b_vals[1], b_vals[2], b_vals[3], b_vals[4], b_vals[5], b_vals[6], b_vals[7] });
        const diff_vec = M31.reduceVec8(M31.subVec8(a, b));
        const diff_arr: [8]u64 = @bitCast(diff_vec);
        for (0..8) |i| {
            const diff_scalar = M31.fromInt(a_vals[i]).sub(M31.fromInt(b_vals[i]));
            try std.testing.expect(diff_arr[i] == diff_scalar.value);
        }
    }

    // Test mulVec8 vs scalar
    for (0..100) |_| {
        var a_vals: [8]u64 = undefined;
        var b_vals: [8]u64 = undefined;
        for (0..8) |i| {
            a_vals[i] = M31.random(rnd).value;
            b_vals[i] = M31.random(rnd).value;
        }
        const a: Vec8 = @as(Vec8, .{ a_vals[0], a_vals[1], a_vals[2], a_vals[3], a_vals[4], a_vals[5], a_vals[6], a_vals[7] });
        const b: Vec8 = @as(Vec8, .{ b_vals[0], b_vals[1], b_vals[2], b_vals[3], b_vals[4], b_vals[5], b_vals[6], b_vals[7] });
        const prod_vec = M31.reduceVec8(M31.mulVec8(a, b));
        const prod_arr: [8]u64 = @bitCast(prod_vec);
        for (0..8) |i| {
            const prod_scalar = M31.fromInt(a_vals[i]).mul(M31.fromInt(b_vals[i]));
            try std.testing.expect(prod_arr[i] == prod_scalar.value);
        }
    }

    // Test negVec8 vs scalar
    for (0..100) |_| {
        var a_vals: [8]u64 = undefined;
        for (0..8) |i| {
            a_vals[i] = M31.random(rnd).value;
        }
        const a: Vec8 = .{ a_vals[0], a_vals[1], a_vals[2], a_vals[3], a_vals[4], a_vals[5], a_vals[6], a_vals[7] };
        const neg_vec = M31.negVec8(a);
        const neg_arr: [8]u64 = @bitCast(neg_vec);
        for (0..8) |i| {
            const neg_scalar = M31.fromInt(a_vals[i]).neg();
            try std.testing.expect(neg_arr[i] == neg_scalar.value);
        }
    }

    // Test fromVec8U32 / toVec8U32 round-trip
    for (0..100) |_| {
        var u32_vals: [8]u32 = undefined;
        for (0..8) |i| {
            u32_vals[i] = @intCast(M31.random(rnd).value);
        }
        const u32_vec: @Vector(8, u32) = @as(@Vector(8, u32), u32_vals);
        const vec8 = M31.fromVec8U32(u32_vec);
        const back = M31.toVec8U32(vec8);
        const back_arr: [8]u32 = @bitCast(back);
        for (0..8) |i| {
            try std.testing.expect(u32_vals[i] == back_arr[i]);
        }
    }

    // Test fromSlice8
    for (0..100) |_| {
        var slice: [8]u32 = undefined;
        for (0..8) |i| {
            slice[i] = @intCast(M31.random(rnd).value);
        }
        const vec8 = M31.fromSlice8(&slice);
        const vec8_arr: [8]u64 = @bitCast(vec8);
        for (0..8) |i| {
            try std.testing.expect(vec8_arr[i] == slice[i]);
        }
    }

    // Test fromElements
    for (0..100) |_| {
        var elems: [8]M31 = undefined;
        for (0..8) |i| {
            elems[i] = M31.random(rnd);
        }
        const vec8 = M31.fromElements(elems[0], elems[1], elems[2], elems[3], elems[4], elems[5], elems[6], elems[7]);
        const vec8_arr: [8]u64 = @bitCast(vec8);
        for (0..8) |i| {
            try std.testing.expect(vec8_arr[i] == elems[i].value);
        }
    }

    // Test ctSelectVec8
    for (0..100) |_| {
        var a_vals: [8]u64 = undefined;
        var b_vals: [8]u64 = undefined;
        for (0..8) |i| {
            a_vals[i] = M31.random(rnd).value;
            b_vals[i] = M31.random(rnd).value;
        }
        const a: Vec8 = @as(Vec8, .{ a_vals[0], a_vals[1], a_vals[2], a_vals[3], a_vals[4], a_vals[5], a_vals[6], a_vals[7] });
        const b: Vec8 = @as(Vec8, .{ b_vals[0], b_vals[1], b_vals[2], b_vals[3], b_vals[4], b_vals[5], b_vals[6], b_vals[7] });
        const on = (rnd.int(u8) & 1) == 1;
        const sel = M31.ctSelectVec8(on, a, b);
        const sel_arr: [8]u64 = @bitCast(sel);
        if (on) {
            for (0..8) |i| try std.testing.expect(sel_arr[i] == a_vals[i]);
        } else {
            for (0..8) |i| try std.testing.expect(sel_arr[i] == b_vals[i]);
        }
    }
}

test "M31 SIMD constants match zig-stark expectations" {
    const M31 = zf.M31;
    try std.testing.expect(M31.MODULUS_U64 == M31.MODULUS);
    try std.testing.expect(M31.SIZE == 4);
    try std.testing.expect(M31.GENERATOR == 31);
    try std.testing.expect(M31.TWO_ADIC_ROOT == M31.MODULUS - 1);
}

test "CM31 NON_RESIDUE and EXT_NON_RESIDUE" {
    const CM31 = zf.CM31;
    // NON_RESIDUE = -1 in M31
    try std.testing.expect(CM31.NON_RESIDUE.eq(zf.M31.one().neg()));
    // EXT_NON_RESIDUE = i = 0 + 1·i
    const i = CM31.imaginaryUnit();
    try std.testing.expect(CM31.EXT_NON_RESIDUE.eq(i));
}

test "QM31 NON_RESIDUE and EXT_NON_RESIDUE" {
    const QM31 = zf.QM31;
    const CM31 = zf.CM31;
    // NON_RESIDUE = -i in CM31 (as a CM31 element)
    const minus_i_cm31 = CM31.new(zf.M31.zero(), zf.M31.one().neg());
    try std.testing.expect(QM31.NON_RESIDUE.eq(minus_i_cm31));
    // EXT_NON_RESIDUE = j = 0 + 1·j
    const j = QM31.imaginaryUnit();
    try std.testing.expect(QM31.EXT_NON_RESIDUE.eq(j));
}

test "BN254_Fp2 NON_RESIDUE and EXT_NON_RESIDUE" {
    const Fp2 = zf.BN254_Fp2;
    // NON_RESIDUE = -1 in BN254_Fp
    try std.testing.expect(Fp2.NON_RESIDUE.eq(zf.BN254_Fp.one().neg()));
    // EXT_NON_RESIDUE = u = 0 + 1·u
    const u = Fp2.imaginaryUnit();
    try std.testing.expect(Fp2.EXT_NON_RESIDUE.eq(u));
}
