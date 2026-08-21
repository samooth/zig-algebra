// SPDX-License-Identifier: MIT OR Apache-2.0

//! Extension fields: `F_p[v]/(v^2 - n)` and `F_p[v]/(v^3 - n)`.
//!
//! The quadratic extension uses Karatsuba multiplication and the norm-based
//! inverse (`x^-1 = conj(x) / (c0^2 - n*c1^2)`), mirroring the semantics of
//! `zig-stark`'s `CM31`/`QM31` towers. The cubic extension uses the closed
//! form inverse `x^-1 = (A + Bv + Cv^2) / denom` with
//! `A = a^2 - nbc`, `B = nc^2 - ab`, `C = b^2 - ac` and
//! `denom = a^3 + n b^3 + n^2 c^3 - 3n abc`.

const std = @import("std");
const field = @import("field.zig");

/// Quadratic extension of `BaseField` by a non-residue `n`, with `v^2 = n`.
pub fn QuadraticExtension(comptime BaseField: type, comptime non_residue: BaseField) type {
    const base_bits = comptime @bitSizeOf(@TypeOf(BaseField.MODULUS));
    // Exponent width for `pow`; generous so extension group orders fit.
    const WideExp = if (base_bits <= 64) u128 else if (base_bits <= 128) u256 else if (base_bits <= 256) u512 else u1024;

    // Validate non_residue at comptime.
    comptime {
        // non_residue must not be zero
        std.debug.assert(!non_residue.isZero());

        // Only validate Legendre symbol for simple base fields (SmallField, BigField),
        // not for extension fields (QuadraticExtension, CubicExtension).
        // Simple fields have a `value` (SmallField) or `limbs` (BigField) field.
        // Extensions have `c0`, `c1` fields.
        const is_simple = @hasField(BaseField, "value") or @hasField(BaseField, "limbs");
        if (is_simple) {
            const legendre = non_residue.legendre();
            std.debug.assert(legendre == -1);
        }
    }

    return struct {
        pub const Self = @This();

        /// Base field modulus (kept for reference computations).
        pub const MODULUS = BaseField.MODULUS;

        /// The non-residue `n` such that `v^2 = n` in this extension.
        /// For CM31: n = -1. For QM31: n = -i. For BN254_Fp2: n = -1.
        pub const NON_RESIDUE = non_residue;

        /// The extension element `v` such that `v^2 = NON_RESIDUE`.
        /// CM31: v = i = 0 + 1·i. QM31: v = j = 0 + 1·j. BN254_Fp2: v = u = 0 + 1·u.
        pub const EXT_NON_RESIDUE = Self.new(BaseField.zero(), BaseField.one());

        /// Exponent of 2 in `|F_p^2*| = p^2 - 1`.
        pub const two_adicity: usize = blk: {
            const p = @as(comptime_int, BaseField.MODULUS);
            break :blk v2(p - 1) + v2(p + 1);
        };

        c0: BaseField,
        c1: BaseField,

        pub fn new(c0: BaseField, c1: BaseField) Self {
            return .{ .c0 = c0, .c1 = c1 };
        }

        /// Embed a base element.
        pub fn fromBase(x: BaseField) Self {
            return .{ .c0 = x, .c1 = BaseField.zero() };
        }

        /// Build from an integer, embedding it in the base field.
        pub fn fromInt(x: anytype) Self {
            return fromBase(BaseField.fromInt(x));
        }

        pub fn zero() Self {
            return .{ .c0 = BaseField.zero(), .c1 = BaseField.zero() };
        }
        pub fn one() Self {
            return .{ .c0 = BaseField.one(), .c1 = BaseField.zero() };
        }

        pub fn add(self: Self, other: Self) Self {
            return .{
                .c0 = self.c0.add(other.c0),
                .c1 = self.c1.add(other.c1),
            };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{
                .c0 = self.c0.sub(other.c0),
                .c1 = self.c1.sub(other.c1),
            };
        }

        /// Karatsuba multiplication.
        pub fn mul(self: Self, other: Self) Self {
            const a0b0 = self.c0.mul(other.c0);
            const a1b1 = self.c1.mul(other.c1);
            const cross = self.c0.add(self.c1).mul(other.c0.add(other.c1));
            return .{
                .c0 = a0b0.add(non_residue.mul(a1b1)),
                .c1 = cross.sub(a0b0).sub(a1b1),
            };
        }

        pub fn neg(self: Self) Self {
            return .{ .c0 = self.c0.neg(), .c1 = self.c1.neg() };
        }

        /// `(a + bv)^-1 = (a - bv) / (a^2 - n b^2)`.
        pub fn inv(self: Self) Self {
            const norm = self.c0.mul(self.c0).sub(non_residue.mul(self.c1.mul(self.c1)));
            const norm_inv = norm.inv();
            return .{
                .c0 = self.c0.mul(norm_inv),
                .c1 = self.c1.neg().mul(norm_inv),
            };
        }

        /// Alias for `inv` (trait compatibility).
        pub fn inverse(self: Self) Self {
            return self.inv();
        }

        /// `a - bv`.
        pub fn conjugate(self: Self) Self {
            return .{ .c0 = self.c0, .c1 = self.c1.neg() };
        }

        /// Multiply by the non-residue: `self * non_residue`.
        pub fn mulByNonResidue(self: Self) Self {
            return .{
                .c0 = non_residue.mul(self.c0),
                .c1 = non_residue.mul(self.c1),
            };
        }

        pub fn eq(self: Self, other: Self) bool {
            return self.c0.eq(other.c0) and self.c1.eq(other.c1);
        }
        pub fn eql(self: Self, other: Self) bool {
            return self.eq(other);
        }
        pub fn isZero(self: Self) bool {
            return self.c0.isZero() and self.c1.isZero();
        }
        pub fn isOne(self: Self) bool {
            return self.eq(Self.one());
        }

        /// Constant-time select: returns `a` if `on`, else `b`.
        pub fn ctSelect(on: bool, a: Self, b: Self) Self {
            return .{
                .c0 = BaseField.ctSelect(on, a.c0, b.c0),
                .c1 = BaseField.ctSelect(on, a.c1, b.c1),
            };
        }

        /// Uniformly random element in `[0, p)`.
        pub fn random(rnd: std.Random) Self {
            return .{
                .c0 = BaseField.random(rnd),
                .c1 = BaseField.random(rnd),
            };
        }

        /// Division: `self / other` = `self * other.inv()`.
        pub fn div(self: Self, other: Self) Self {
            std.debug.assert(!other.isZero());
            return self.mul(other.inv());
        }

        /// Hash for HashMap support.
        pub fn hash(self: Self) u64 {
            // FNV-1a hash of both components
            var hash_val: u64 = 14695981039346656037;
            for (0..2) |i| {
                var v = if (i == 0) self.c0.toU512() else self.c1.toU512();
                for (0..8) |_| {
                    hash_val ^= v & 0xFF;
                    hash_val = hash_val.wrapping_mul(1099511628211);
                    v >>= 8;
                }
            }
            return hash_val;
        }

        /// Format for debugging.
        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.print("{{c0: {}, c1: {}}}", .{ self.c0.toU512(), self.c1.toU512() });
        }

        /// The element `v` where `v^2 = non_residue` (i.e., `c0 = 0, c1 = 1`).
        pub fn imaginaryUnit() Self {
            return .{ .c0 = BaseField.zero(), .c1 = BaseField.one() };
        }

        /// Frobenius automorphism: (a + b*v)^p = a - b*v.
        /// Valid when the base prime p ≡ 3 (mod 4) and NON_RESIDUE = -1,
        /// which holds for CM31, BN254_Fp2, and BLS12_381_Fp2.
        pub fn frobenius(self: Self) Self {
            return .{
                .c0 = self.c0,
                .c1 = self.c1.neg(),
            };
        }

        /// Constant-time exponentiation. Exponent must fit in `WideExp` and be non-negative.
        /// WARNING: ~2x slower than square-and-multiply because every multiply is
        /// executed unconditionally. Use only when the exponent is secret.
        pub fn pow(self: Self, exp: anytype) Self {
            const T = @TypeOf(exp);
            const e: WideExp = blk: {
                if (T == comptime_int) {
                    break :blk @intCast(exp);
                }
                const info = @typeInfo(T);
                if (info == .int and info.int.signedness == .signed) {
                    if (exp < 0) @panic("pow: negative exponent not supported");
                }
                break :blk @intCast(exp);
            };
            var result = Self.one();
            var base = self;
            var i: usize = 0;
            while (i < @bitSizeOf(WideExp)) : (i += 1) {
                const bit = ((e >> @intCast(i)) & 1) == 1;
                const m = result.mul(base);
                result = Self.ctSelect(bit, m, result);
                base = base.mul(base);
            }
            return result;
        }

        /// Fast exponentiation (NOT constant-time). ~2x faster than `pow`.
        /// Use when the exponent is public.
        pub fn powFast(self: Self, exp: anytype) Self {
            const T = @TypeOf(exp);
            const e: WideExp = blk: {
                if (T == comptime_int) break :blk @intCast(exp);
                const info = @typeInfo(T);
                if (info == .int and info.int.signedness == .signed) {
                    if (exp < 0) @panic("powFast: negative exponent not supported");
                }
                break :blk @intCast(exp);
            };
            var result = Self.one();
            var base = self;
            var ee = e;
            while (ee > 0) : (ee >>= 1) {
                if ((ee & 1) == 1) result = result.mul(base);
                base = base.mul(base);
            }
            return result;
        }

        /// Legendre symbol in the extension field, used internally to find a
        /// quadratic non-residue for root-of-unity construction.
        pub fn legendre(self: Self) i8 {
            const exp = orderExponent(1);
            const r = self.pow(exp);
            if (r.isZero()) return 0;
            if (r.isOne()) return 1;
            return -1;
        }

        /// Primitive `2^log_size`-th root of unity (`0 <= log_size <= two_adicity`).
        ///
        /// If the base field already contains a root of the requested order it
        /// is embedded (cheap path). Otherwise a quadratic non-residue `z` in
        /// the extension is found and raised to `(p^2 - 1) / 2^log_size`,
        /// which has exact order `2^log_size`.
        pub fn primitiveRootOfUnity(log_size: usize) Self {
            std.debug.assert(log_size <= two_adicity);

            if (log_size <= BaseField.two_adicity) {
                return Self.fromBase(BaseField.primitiveRootOfUnity(log_size));
            }

            var z = Self.fromInt(2);
            while (z.legendre() != -1) z = z.add(Self.one());
            return z.pow(orderExponent(log_size));
        }

        /// `order`-th root of unity (`order` a power of two).
        pub fn rootOfUnity(order: usize) Self {
            std.debug.assert(order & (order - 1) == 0);
            return primitiveRootOfUnity(std.math.log2(order));
        }

        /// `(p^2 - 1) / 2^log_size` as a wide unsigned integer.
        fn orderExponent(log_size: usize) u1024 {
            const p = @as(u1024, BaseField.MODULUS);
            return (p * p - 1) >> @intCast(log_size);
        }
    };
}

/// Cubic extension of `BaseField` by a non-residue `n`, with `v^3 = n`.
pub fn CubicExtension(comptime BaseField: type, comptime non_residue: BaseField) type {
    const base_bits = comptime @bitSizeOf(@TypeOf(BaseField.MODULUS));
    const WideExp = if (base_bits <= 32) u128 else if (base_bits <= 64) u256 else if (base_bits <= 128) u512 else u1024;

    // Validate non_residue at comptime.
    comptime {
        // non_residue must not be zero
        std.debug.assert(!non_residue.isZero());
        // For cubic extension, we need p ≡ 1 (mod 3) and non_residue to be a cubic non-residue.
        // If 3 divides p-1, check n^((p-1)/3) != 1.
        // If 3 does not divide p-1, every element is a cubic residue (map x->x^3 is bijective).
        const p_minus_1 = BaseField.MODULUS - 1;
        if (p_minus_1 % 3 == 0) {
            const exp = p_minus_1 / 3;
            const result = non_residue.pow(exp);
            std.debug.assert(!result.eq(BaseField.one()));
        }
    }

    return struct {
        pub const Self = @This();

        pub const MODULUS = BaseField.MODULUS;

        /// The non-residue `n` such that `v^3 = n` in this extension.
        pub const NON_RESIDUE = non_residue;

        /// The extension element `v` such that `v^3 = NON_RESIDUE`.
        pub const EXT_NON_RESIDUE = Self.new(BaseField.zero(), BaseField.one(), BaseField.zero());

        c0: BaseField,
        c1: BaseField,
        c2: BaseField,

        pub fn new(c0: BaseField, c1: BaseField, c2: BaseField) Self {
            return .{ .c0 = c0, .c1 = c1, .c2 = c2 };
        }
        pub fn fromBase(x: BaseField) Self {
            return .{ .c0 = x, .c1 = BaseField.zero(), .c2 = BaseField.zero() };
        }
        pub fn fromInt(x: anytype) Self {
            return fromBase(BaseField.fromInt(x));
        }

        pub fn zero() Self {
            return .{ .c0 = BaseField.zero(), .c1 = BaseField.zero(), .c2 = BaseField.zero() };
        }
        pub fn one() Self {
            return .{ .c0 = BaseField.one(), .c1 = BaseField.zero(), .c2 = BaseField.zero() };
        }

        pub fn add(self: Self, other: Self) Self {
            return .{
                .c0 = self.c0.add(other.c0),
                .c1 = self.c1.add(other.c1),
                .c2 = self.c2.add(other.c2),
            };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{
                .c0 = self.c0.sub(other.c0),
                .c1 = self.c1.sub(other.c1),
                .c2 = self.c2.sub(other.c2),
            };
        }

        pub fn mul(self: Self, other: Self) Self {
            const a0b0 = self.c0.mul(other.c0);
            const a0b1 = self.c0.mul(other.c1);
            const a0b2 = self.c0.mul(other.c2);
            const a1b0 = self.c1.mul(other.c0);
            const a1b1 = self.c1.mul(other.c1);
            const a1b2 = self.c1.mul(other.c2);
            const a2b0 = self.c2.mul(other.c0);
            const a2b1 = self.c2.mul(other.c1);
            const a2b2 = self.c2.mul(other.c2);
            return .{
                .c0 = a0b0.add(non_residue.mul(a1b2.add(a2b1))),
                .c1 = a0b1.add(a1b0).add(non_residue.mul(a2b2)),
                .c2 = a0b2.add(a1b1).add(a2b0),
            };
        }

        pub fn neg(self: Self) Self {
            return .{
                .c0 = self.c0.neg(),
                .c1 = self.c1.neg(),
                .c2 = self.c2.neg(),
            };
        }

        /// Closed-form inverse: with `x = a + bv + cv^2`, the inverse is
        /// `(A + Bv + Cv^2)/denom` where `A = a^2 - nbc`, `B = nc^2 - ab`,
        /// `C = b^2 - ac` and `denom = a^3 + nb^3 + n^2c^3 - 3nabc`.
        pub fn inv(self: Self) Self {
            const a = self.c0;
            const b = self.c1;
            const c = self.c2;
            const A = a.mul(a).sub(non_residue.mul(b.mul(c)));
            const B = non_residue.mul(c.mul(c)).sub(a.mul(b));
            const C = b.mul(b).sub(a.mul(c));
            const denom = a.mul(A).add(non_residue.mul(c.mul(B))).add(non_residue.mul(b.mul(C)));
            const denom_inv = denom.inv();
            return .{
                .c0 = A.mul(denom_inv),
                .c1 = B.mul(denom_inv),
                .c2 = C.mul(denom_inv),
            };
        }

        /// Alias for `inv` (trait compatibility).
        pub fn inverse(self: Self) Self {
            return self.inv();
        }

        pub fn eq(self: Self, other: Self) bool {
            return self.c0.eq(other.c0) and self.c1.eq(other.c1) and self.c2.eq(other.c2);
        }
        pub fn eql(self: Self, other: Self) bool {
            return self.eq(other);
        }
        pub fn isZero(self: Self) bool {
            return self.c0.isZero() and self.c1.isZero() and self.c2.isZero();
        }
        pub fn isOne(self: Self) bool {
            return self.eq(Self.one());
        }

        /// Constant-time select: returns `a` if `on`, else `b`.
        pub fn ctSelect(on: bool, a: Self, b: Self) Self {
            return .{
                .c0 = BaseField.ctSelect(on, a.c0, b.c0),
                .c1 = BaseField.ctSelect(on, a.c1, b.c1),
            };
        }

        /// Uniformly random element in `[0, p)`.
        pub fn random(rnd: std.Random) Self {
            return .{
                .c0 = BaseField.random(rnd),
                .c1 = BaseField.random(rnd),
                .c2 = BaseField.random(rnd),
            };
        }

        /// Constant-time exponentiation. Exponent must fit in `WideExp` and be non-negative.
        /// WARNING: ~2x slower than square-and-multiply because every multiply is
        /// executed unconditionally. Use only when the exponent is secret.
        pub fn pow(self: Self, exp: anytype) Self {
            const T = @TypeOf(exp);
            const e: WideExp = blk: {
                if (T == comptime_int) {
                    break :blk @intCast(exp);
                }
                const info = @typeInfo(T);
                if (info == .int and info.int.signedness == .signed) {
                    if (exp < 0) @panic("pow: negative exponent not supported");
                }
                break :blk @intCast(exp);
            };
            var result = Self.one();
            var base = self;
            var i: usize = 0;
            while (i < @bitSizeOf(WideExp)) : (i += 1) {
                const bit = ((e >> @intCast(i)) & 1) == 1;
                const m = result.mul(base);
                result = Self.ctSelect(bit, m, result);
                base = base.mul(base);
            }
            return result;
        }

        /// Fast exponentiation (NOT constant-time). ~2x faster than `pow`.
        /// Use when the exponent is public.
        pub fn powFast(self: Self, exp: anytype) Self {
            const T = @TypeOf(exp);
            const e: WideExp = blk: {
                if (T == comptime_int) break :blk @intCast(exp);
                const info = @typeInfo(T);
                if (info == .int and info.int.signedness == .signed) {
                    if (exp < 0) @panic("powFast: negative exponent not supported");
                }
                break :blk @intCast(exp);
            };
            var result = Self.one();
            var base = self;
            var ee = e;
            while (ee > 0) : (ee >>= 1) {
                if ((ee & 1) == 1) result = result.mul(base);
                base = base.mul(base);
            }
            return result;
        }

        /// Division: `self / other` = `self * other.inv()`.
        pub fn div(self: Self, other: Self) Self {
            std.debug.assert(!other.isZero());
            return self.mul(other.inv());
        }

        /// Hash for HashMap support.
        pub fn hash(self: Self) u64 {
            // FNV-1a hash of all three components
            var hash_val: u64 = 14695981039346656037;
            for (0..3) |i| {
                var v = if (i == 0) self.c0.toU512() else if (i == 1) self.c1.toU512() else self.c2.toU512();
                for (0..8) |_| {
                    hash_val ^= v & 0xFF;
                    hash_val = hash_val.wrapping_mul(1099511628211);
                    v >>= 8;
                }
            }
            return hash_val;
        }

        /// Format for debugging.
        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.print("{{c0: {}, c1: {}, c2: {}}}", .{ self.c0.toU512(), self.c1.toU512(), self.c2.toU512() });
        }
    };
}

fn v2(comptime n: comptime_int) usize {
    var v = n;
    var s: usize = 0;
    while (v % 2 == 0) : (v /= 2) s += 1;
    return s;
}

// ---------------------------------------------------------------------------
// Predefined instances (matching zig-stark semantics)
// ---------------------------------------------------------------------------

/// `F_M31[v]/(v^2 + 1)`, the CM31 extension tower used by STARKs.
pub const CM31 = QuadraticExtension(
    field.Field(0x7FFFFFFF), // M31
    field.Field(0x7FFFFFFF).fromInt(0x7FFFFFFE), // -1
);

/// `F_CM31[j]/(j^2 + i)`, the QM31 tower used by STARKs (`j^2 = -i`).
pub const QM31 = QuadraticExtension(
    CM31,
    CM31.new(field.Field(0x7FFFFFFF).zero(), field.Field(0x7FFFFFFF).fromInt(0x7FFFFFFE)), // -i
);

/// `F_BN254[u]/(u^2 + 1)`, the Fp2 used by pairing-friendly SNARKs.
pub const BN254_Fp2 = QuadraticExtension(
    field.Field(0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD47),
    field.Field(0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD47).fromInt(0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD46), // -1
);
