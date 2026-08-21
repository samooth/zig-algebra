const std = @import("std");

/// Binary (characteristic-2) Galois field GF(2^bits).
///
/// Elements are stored in a `u128` and arithmetic is done in the polynomial
/// ring GF(2)[x] modulo an irreducible polynomial of degree `bits`.
/// Characteristic 2 means:
///   - addition/subtraction is XOR (`add == sub`),
///   - multiplication is carry-less polynomial multiplication reduced mod the
///     field polynomial.
///
/// The reduction polynomial's *leading term* (degree `bits`) is implicit; the
/// caller supplies only the lower coefficients. Examples:
///
///   | Field        | Polynomial                     | bits | reduction_constant |
///   |--------------|--------------------------------|------|--------------------|
///   | GF(2^4)      | x^4 + x + 1                    | 4    | 0x3                |
///   | GF(2^128)    | x^128 + x^7 + x^2 + x + 1 (GCM)| 128  | 0x87               |
pub fn BinaryField(comptime bits: u8, comptime reduction_constant: u128) type {
    return struct {
        pub const BITS = bits;
        pub const SIZE = (bits + 7) / 8;
        pub const REDUCTION_CONSTANT = reduction_constant;

        value: u128,

        pub fn fromInt(x: anytype) @This() {
            const v: u128 = @intCast(x);
            const mask: u128 = if (bits == 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(bits)) - 1;
            return .{ .value = v & mask };
        }

        pub fn add(a: @This(), b: @This()) @This() {
            return .{ .value = a.value ^ b.value };
        }

        pub fn sub(a: @This(), b: @This()) @This() {
            return a.add(b);
        }

        /// Carry-less multiply followed by reduction mod the field polynomial.
        pub fn mul(a: @This(), b: @This()) @This() {
            // Carry-less product into a (hi, lo) u128 pair.
            var lo: u128 = 0;
            var hi: u128 = 0;
            var i: u8 = 0;
            while (i < bits) : (i += 1) {
                if ((b.value >> @intCast(i)) & 1 == 1) {
                    const sp = i;
                    const shifted_hi: u128 = if (sp == 0) 0 else (a.value >> @intCast(128 - sp));
                    const shifted_lo = a.value << @intCast(sp);
                    lo ^= shifted_lo;
                    hi ^= shifted_hi;
                }
            }
            return .{ .value = reduce(lo, hi) };
        }

        /// Reduce a 256-bit product (hi:lo) mod x^bits + reduction_constant.
        fn reduce(lo_in: u128, hi_in: u128) u128 {
            var lo = lo_in;
            var hi = hi_in;

            // Clear bits from the top of the 2*bits-bit product down to `bits`.
            var p: u16 = 2 * @as(u16, bits) - 2;
            while (p >= bits) : (p -= 1) {
                const is_set = if (p >= 128)
                    ((hi >> @intCast(p - 128)) & 1) == 1
                else
                    ((lo >> @intCast(p)) & 1) == 1;
                if (!is_set) continue;

                // XOR the field polynomial shifted by sp = p - bits:
                //   leading term at position p (clears this bit),
                //   reduction_constant occupying [p-bits .. p-1].
                const sp: u16 = p - bits;
                const c_lo = reduction_constant << @intCast(sp);
                var c_hi: u128 = 0;
                if (sp > 0) c_hi = reduction_constant >> @intCast(128 - sp);

                if (p >= 128) {
                    hi ^= @as(u128, 1) << @intCast(p - 128);
                } else {
                    lo ^= @as(u128, 1) << @intCast(p);
                }
                lo ^= c_lo;
                hi ^= c_hi;
            }
            return lo ^ hi;
        }

        pub fn pow(a: @This(), exp: anytype) @This() {
            var result = @This().one();
            var base = a;
            var e: u128 = exp;
            while (e > 0) : (e >>= 1) {
                if (e & 1 == 1) result = result.mul(base);
                base = base.mul(base);
            }
            return result;
        }

        /// a^(2^bits - 2) = a^-1 for a != 0 (multiplicative group has order 2^bits - 1).
        pub fn inv(a: @This()) @This() {
            std.debug.assert(a.value != 0);
            if (bits == 4) return a.pow(14);
            if (bits == 128) return a.pow(std.math.maxInt(u128) - 1); // 2^128 - 2
            @compileError("inv: unsupported field size");
        }

        pub fn eq(a: @This(), b: @This()) bool {
            return a.value == b.value;
        }

        pub fn zero() @This() {
            return .{ .value = 0 };
        }

        pub fn one() @This() {
            return .{ .value = 1 };
        }

        pub fn isZero(a: @This()) bool {
            return a.value == 0;
        }

        pub fn toBytes(a: @This(), out: *[SIZE]u8) void {
            switch (SIZE) {
                1 => out[0] = @truncate(a.value),
                2 => std.mem.writeInt(u16, out[0..2], @truncate(a.value), .little),
                4 => std.mem.writeInt(u32, out[0..4], @truncate(a.value), .little),
                8 => std.mem.writeInt(u64, out[0..8], @truncate(a.value), .little),
                16 => std.mem.writeInt(u128, out[0..16], a.value, .little),
                else => @compileError("BinaryField: unsupported byte size"),
            }
        }

        pub fn fromBytes(bytes: [SIZE]u8) @This() {
            const v: u128 = switch (SIZE) {
                1 => bytes[0],
                2 => std.mem.readInt(u16, bytes[0..2], .little),
                4 => std.mem.readInt(u32, bytes[0..4], .little),
                8 => std.mem.readInt(u64, bytes[0..8], .little),
                16 => std.mem.readInt(u128, bytes[0..16], .little),
                else => @compileError("BinaryField: unsupported byte size"),
            };
            return fromInt(v);
        }
    };
}

/// GF(2^4) with reduction polynomial x^4 + x + 1 (constant 0x3). Matches the
/// Bitcoin Script on-chain verifier representation (1 byte per element).
pub const Gf16 = BinaryField(4, 0x3);

/// GF(2^128) with the GCM reduction polynomial x^128 + x^7 + x^2 + x + 1
/// (constant 0x87). Used by the GPU-accelerated prover.
pub const Gf128 = BinaryField(128, 0x87);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "gf16 add is xor" {
    try std.testing.expectEqual(@as(u128, 0xa), Gf16.fromInt(0x3).add(Gf16.fromInt(0x9)).value);
    try std.testing.expectEqual(@as(u128, 0x0), Gf16.fromInt(0xf).add(Gf16.fromInt(0xf)).value);
}

test "gf16 mul known values" {
    // (x^2 + 1)(x^2 + x + 1) = x^4 + x^3 + x + 1; mod x^4 + x + 1 -> x^3
    try std.testing.expectEqual(@as(u128, 0x8), Gf16.fromInt(0x5).mul(Gf16.fromInt(0x7)).value);
    // x * x = x^2
    try std.testing.expectEqual(@as(u128, 0x4), Gf16.fromInt(0x2).mul(Gf16.fromInt(0x2)).value);
    // x^3 * x^3 = x^6 = x^3 + x^2  (x^4 = x + 1, x^6 = x^2(x^4) = x^3 + x^2)
    try std.testing.expectEqual(@as(u128, 0xc), Gf16.fromInt(0x8).mul(Gf16.fromInt(0x8)).value);
    try std.testing.expectEqual(@as(u128, 0x9), Gf16.one().mul(Gf16.fromInt(0x9)).value);
    try std.testing.expectEqual(@as(u128, 0x0), Gf16.zero().mul(Gf16.fromInt(0x9)).value);
}

test "gf16 multiplicative group closed under mul" {
    // Product of two non-zero elements is never zero (integral domain).
    for (1..16) |a_raw| {
        for (1..16) |b_raw| {
            const a = Gf16.fromInt(a_raw);
            const b = Gf16.fromInt(b_raw);
            try std.testing.expect(!a.mul(b).isZero());
        }
    }
}

test "gf16 inverse" {
    for (1..16) |a_raw| {
        const a = Gf16.fromInt(a_raw);
        const inv = a.inv();
        try std.testing.expectEqual(@as(u128, 1), a.mul(inv).value);
    }
}

test "gf16 powers of generator" {
    // 2 is a generator of GF(2^4)* (order 15).
    var acc = Gf16.one();
    var seen = [_]bool{false} ** 16;
    for (0..15) |_| {
        seen[@intCast(acc.value)] = true;
        acc = acc.mul(Gf16.fromInt(0x2));
    }
    var count: usize = 0;
    for (seen) |s| {
        if (s) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 15), count);
}

test "gf16 multiplication table vs reference log/antilog" {
    // Build log/antilog tables from generator 2.
    var alpha = Gf16.one();
    var log = [_]u8{0} ** 16;
    var exp = [_]u8{0} ** 16;
    for (0..15) |i| {
        exp[i] = @intCast(alpha.value);
        log[@intCast(alpha.value)] = @intCast(i);
        alpha = alpha.mul(Gf16.fromInt(0x2));
    }
    for (1..16) |a_raw| {
        for (1..16) |b_raw| {
            const prod = Gf16.fromInt(a_raw).mul(Gf16.fromInt(b_raw));
            const la = log[a_raw];
            const lb = log[b_raw];
            const ref = exp[(la + lb) % 15];
            try std.testing.expectEqual(ref, @as(u8, @intCast(prod.value)));
        }
    }
}

test "gf16 serialization round-trip" {
    for (0..16) |raw| {
        const a = Gf16.fromInt(raw);
        var buf: [Gf16.SIZE]u8 = undefined;
        a.toBytes(&buf);
        const back = Gf16.fromBytes(buf);
        try std.testing.expect(a.eq(back));
    }
}

test "gf128 mul by one and zero" {
    const a = Gf128.fromInt(0x1234_5678_9abc_def0_1122_3344_5566_7788);
    try std.testing.expect(a.mul(Gf128.one()).eq(a));
    try std.testing.expect(a.mul(Gf128.zero()).isZero());
}

test "gf128 carryless mul known vector" {
    // (x + 1) * (x + 1) = x^2 + 1  (since 2x = 0 in characteristic 2)
    const x = Gf128.fromInt(0x3);
    try std.testing.expectEqual(@as(u128, 0x5), x.mul(x).value);
    // 0x2 * 0x2 = 0x4, 0x2^3 = 0x8 (pure shifts, below any reduction)
    const two = Gf128.fromInt(0x2);
    try std.testing.expectEqual(@as(u128, 0x4), two.mul(two).value);
    try std.testing.expectEqual(@as(u128, 0x8), two.mul(two).mul(two).value);
}

test "gf128 reduction at the boundary" {
    // x^64 * x^64 = x^128 ≡ x^7 + x^2 + x + 1 = 0x87 mod the GCM polynomial.
    const x64 = Gf128.fromInt(@as(u128, 1) << 64);
    try std.testing.expectEqual(@as(u128, 0x87), x64.mul(x64).value);
}

test "gf128 inverse" {
    const a = Gf128.fromInt(0xdead_beef_cafe_babe_1234_5678_9abc_def0);
    const inv = a.inv();
    try std.testing.expect(a.mul(inv).eq(Gf128.one()));
}

test "gf128 serialization round-trip" {
    const a = Gf128.fromInt(0xdead_beef_cafe_babe_1234_5678_9abc_def0);
    var buf: [Gf128.SIZE]u8 = undefined;
    a.toBytes(&buf);
    const back = Gf128.fromBytes(buf);
    try std.testing.expect(a.eq(back));
}
