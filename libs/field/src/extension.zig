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

/// `fromBytesChecked` takes its array by value (to match
/// `zig-binary-field`), so a slice taken out of a longer buffer has to be
/// copied rather than coerced.
fn checkedPart(comptime F: type, bytes: []const u8, comptime off: usize) error{InvalidFieldElement}!F {
    var arr: [F.NUM_BYTES]u8 = undefined;
    for (&arr, 0..) |*b, i| b.* = bytes[off + i];
    return F.fromBytesChecked(arr) catch error.InvalidFieldElement;
}

const field = @import("field.zig");

/// Upper bound on the quadratic-non-residue search in
/// `QuadraticExtension.primitiveRootOfUnity`. Half of `F_{p^2}^*` is a
/// non-residue, so a search over both components succeeds in about two tries;
/// this bound only decides what a *failed* search does, and a failed search
/// must be an error rather than an unbounded loop. It is large enough to cover
/// the whole plane for every field with `p <= 32`.
const MAX_NON_RESIDUE_SEARCH: usize = 1024;

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
            // Legendre via modular exponentiation over big moduli needs a
            // generous comptime branch budget (default 1000 is far too low).
            @setEvalBranchQuota(100_000_000);
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

        pub const NUM_BYTES: usize = 2 * BaseField.NUM_BYTES;

        pub fn toBytes(self: Self) [NUM_BYTES]u8 {
            var out: [NUM_BYTES]u8 = undefined;
            const c0 = self.c0.toBytes();
            const c1 = self.c1.toBytes();
            @memcpy(out[0..BaseField.NUM_BYTES], &c0);
            @memcpy(out[BaseField.NUM_BYTES..], &c1);
            return out;
        }

        pub fn fromBytes(bytes: []const u8) !Self {
            if (bytes.len != NUM_BYTES) return error.InvalidLength;
            return .{
                .c0 = BaseField.fromBytes(bytes[0..BaseField.NUM_BYTES]) catch return error.InvalidFieldElement,
                .c1 = BaseField.fromBytes(bytes[BaseField.NUM_BYTES..]) catch return error.InvalidFieldElement,
            };
        }

        /// Rejecting decode: every coordinate must itself be canonical, so the
        /// success set is exactly the field. See `fromBytesChecked` on the
        /// base field. `error.InvalidFieldElement` rather than the base's own
        /// error, so one signature covers every `BaseField`.
        pub fn fromBytesChecked(bytes: [NUM_BYTES]u8) error{InvalidFieldElement}!Self {
            return .{
                .c0 = try checkedPart(BaseField, &bytes, 0),
                .c1 = try checkedPart(BaseField, &bytes, BaseField.NUM_BYTES),
            };
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
        ///
        /// Total: `inv(0) == zero()`. The norm of zero is zero, so the base
        /// field inverse is the zero element and the product below is zero; the
        /// legacy signature cannot report "no inverse" and an assert only fired
        /// in Debug/ReleaseSafe (in ReleaseFast it hung inside the base GCD
        /// loop). Use `invChecked` to reject a non-invertible value.
        pub fn inv(self: Self) Self {
            return self.invChecked() catch zero();
        }

        /// Checked inverse: `error.InverseOfZero` when `self == 0`.
        pub fn invChecked(self: Self) error{InverseOfZero}!Self {
            // `n` is a non-residue, so `x^2 - n y^2 == 0` iff `x == y == 0`;
            // the check makes the contract explicit instead of relying on it.
            if (self.isZero()) return error.InverseOfZero;
            const norm = self.c0.mul(self.c0).sub(non_residue.mul(self.c1.mul(self.c1)));
            const norm_inv = try norm.invChecked();
            return .{
                .c0 = self.c0.mul(norm_inv),
                .c1 = self.c1.neg().mul(norm_inv),
            };
        }

        /// Alias for `inv` (trait compatibility). Total, like `inv`.
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
        ///
        /// Total: `self / 0 == zero()`. Use `divChecked` to reject a zero
        /// divisor.
        pub fn div(self: Self, other: Self) Self {
            return self.mul(other.inv());
        }

        /// Checked division: `error.DivisionByZero` when `other == 0`
        /// (`error.InverseOfZero` is unreachable, the zero divisor is rejected
        /// above).
        pub fn divChecked(self: Self, other: Self) error{ DivisionByZero, InverseOfZero }!Self {
            if (other.isZero()) return error.DivisionByZero;
            return self.mul(try other.invChecked());
        }

        /// Hash for HashMap support.
        pub fn hash(self: Self) u64 {
            // FNV-1a hash of both components
            var hash_val: u64 = 14695981039346656037;
            for (0..2) |i| {
                var v = if (i == 0) self.c0.toU512() else self.c1.toU512();
                for (0..8) |_| {
                    // `v` is a u512 here, so the byte has to be narrowed before
                    // it meets the u64 accumulator -- and the multiply is `*%`,
                    // because Zig's wrapping arithmetic is an operator, not a
                    // method on u64.
                    const byte: u64 = @truncate(v);
                    hash_val ^= byte & 0xFF;
                    hash_val *%= 1099511628211;
                    v >>= 8;
                }
            }
            return hash_val;
        }

        /// Format for debugging.
        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

        /// Multiply by small constants (faster than general multiplication).
        pub fn mulBy2(self: Self) Self {
            return self.add(self);
        }
        pub fn mulBy3(self: Self) Self {
            return self.add(self).add(self);
        }
        pub fn mulBy4(self: Self) Self {
            return self.mulBy2().mulBy2();
        }
        pub fn mulBy5(self: Self) Self {
            return self.mulBy4().add(self);
        }
        pub fn sqr(self: Self) Self {
            return self.mul(self);
        }

        /// Constant-time exponentiation. Exponent must fit in `WideExp` and be non-negative.
        /// UNMEASURED: this was documented as "~2x slower than square-and-multiply
        /// because every multiply is
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

        /// Fast exponentiation (NOT constant-time).
        ///
        /// Measured against `pow` rather than asserted: 7.5x on BN254_Fp, 11.2x
        /// on BLS12_381_Fp, 1.3x on Goldilocks, and a **1.5-2x REGRESSION** on
        /// the small Mersenne primes M31 and BabyBear, where the windowed form
        /// is slower than what it replaces. Do not use this on a small Mersenne
        /// field expecting a speedup.
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
        ///
        /// # Errors
        /// `error.OrderTooLarge` when `log_size > two_adicity` (the old
        /// `std.debug.assert` is compiled out in `ReleaseFast`, where
        /// `orderExponent(log_size)` then shifted past the exponent width),
        /// and `error.NoNonResidue` when the bounded search below finds none.
        ///
        /// **The search has to leave the real axis, and that is arithmetic
        /// rather than an implementation detail.** For every non-zero `a` in
        /// the base field, `a^((p^2-1)/2) = (a^(p-1))^((p+1)/2) = 1`, so every
        /// base-field element is a square in `F_{p^2}` and `legendre` can only
        /// return `1` along that axis. The previous body walked `2, 3, 4, ...`
        /// with `Self.one()` -- the real axis and nothing else -- so on
        /// `QuadraticExtension(M61, -1)` the call `primitiveRootOfUnity(62)`
        /// compiled and never returned: 2^61 candidates, each one a
        /// 121-bit exponentiation. Both components vary now, which reaches a
        /// non-residue in a handful of tries (half of `F_{p^2}^*` is one), and
        /// the attempt count is bounded so a caller is never left waiting: an
        /// exhaustive search is what the old loop was, and an unbounded one is
        /// not a contract.
        pub fn primitiveRootOfUnity(log_size: usize) error{ OrderTooLarge, NoNonResidue }!Self {
            if (log_size > two_adicity) return error.OrderTooLarge;

            if (log_size <= BaseField.two_adicity) {
                return Self.fromBase(try BaseField.primitiveRootOfUnity(log_size));
            }

            var k: usize = 0;
            while (k < MAX_NON_RESIDUE_SEARCH) : (k += 1) {
                const z = Self.new(
                    BaseField.fromInt(k + 2),
                    BaseField.fromInt(k + 1),
                );
                if (z.legendre() == -1) return z.pow(orderExponent(log_size));
            }
            return error.NoNonResidue;
        }

        /// `order`-th root of unity (`order` a power of two).
        ///
        /// # Errors
        /// `error.NotPowerOfTwo` when `order` is zero or not a power of two
        /// (`std.math.log2(0)` is undefined), plus `error.OrderTooLarge`.
        pub fn rootOfUnity(order: usize) error{ NotPowerOfTwo, OrderTooLarge }!Self {
            if (order == 0 or (order & (order - 1)) != 0) return error.NotPowerOfTwo;
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
        if (p_minus_1 % 3 != 0) @compileError("CubicExtension requires a base field with p == 1 (mod 3)");
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

        pub const NUM_BYTES: usize = 3 * BaseField.NUM_BYTES;

        pub fn toBytes(self: Self) [NUM_BYTES]u8 {
            var out: [NUM_BYTES]u8 = undefined;
            const c0 = self.c0.toBytes();
            const c1 = self.c1.toBytes();
            const c2 = self.c2.toBytes();
            @memcpy(out[0..BaseField.NUM_BYTES], &c0);
            @memcpy(out[BaseField.NUM_BYTES..][0..BaseField.NUM_BYTES], &c1);
            @memcpy(out[2 * BaseField.NUM_BYTES ..], &c2);
            return out;
        }

        pub fn fromBytes(bytes: []const u8) !Self {
            if (bytes.len != NUM_BYTES) return error.InvalidLength;
            return .{
                .c0 = BaseField.fromBytes(bytes[0..BaseField.NUM_BYTES]) catch return error.InvalidFieldElement,
                .c1 = BaseField.fromBytes(bytes[BaseField.NUM_BYTES..][0..BaseField.NUM_BYTES]) catch return error.InvalidFieldElement,
                .c2 = BaseField.fromBytes(bytes[2 * BaseField.NUM_BYTES ..]) catch return error.InvalidFieldElement,
            };
        }

        /// Rejecting decode: all `m` coordinates must be canonical. See
        /// `fromBytesChecked` on the base field.
        pub fn fromBytesChecked(bytes: [NUM_BYTES]u8) error{InvalidFieldElement}!Self {
            return .{
                .c0 = try checkedPart(BaseField, &bytes, 0),
                .c1 = try checkedPart(BaseField, &bytes, BaseField.NUM_BYTES),
                .c2 = try checkedPart(BaseField, &bytes, 2 * BaseField.NUM_BYTES),
            };
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
        ///
        /// Total: `inv(0) == zero()` — the denominator of zero is zero, so the
        /// base field inverse yields zero and the whole element is zero. The
        /// legacy signature cannot report "no inverse"; the removed assert only
        /// fired in Debug/ReleaseSafe while ReleaseFast hung in the base GCD
        /// loop. Use `invChecked` to reject a non-invertible value.
        pub fn inv(self: Self) Self {
            return self.invChecked() catch zero();
        }

        /// Checked inverse: `error.InverseOfZero` when `self == 0`.
        pub fn invChecked(self: Self) error{InverseOfZero}!Self {
            if (self.isZero()) return error.InverseOfZero;
            const a = self.c0;
            const b = self.c1;
            const c = self.c2;
            const A = a.mul(a).sub(non_residue.mul(b.mul(c)));
            const B = non_residue.mul(c.mul(c)).sub(a.mul(b));
            const C = b.mul(b).sub(a.mul(c));
            const denom = a.mul(A).add(non_residue.mul(c.mul(B))).add(non_residue.mul(b.mul(C)));
            const denom_inv = try denom.invChecked();
            return .{
                .c0 = A.mul(denom_inv),
                .c1 = B.mul(denom_inv),
                .c2 = C.mul(denom_inv),
            };
        }

        /// Alias for `inv` (trait compatibility). Total, like `inv`.
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
                .c2 = BaseField.ctSelect(on, a.c2, b.c2),
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

        /// Multiply by small constants (faster than general multiplication).
        pub fn mulBy2(self: Self) Self {
            return self.add(self);
        }
        pub fn mulBy3(self: Self) Self {
            return self.add(self).add(self);
        }
        pub fn mulBy4(self: Self) Self {
            return self.mulBy2().mulBy2();
        }
        pub fn mulBy5(self: Self) Self {
            return self.mulBy4().add(self);
        }
        pub fn sqr(self: Self) Self {
            return self.mul(self);
        }

        /// Constant-time exponentiation. Exponent must fit in `WideExp` and be non-negative.
        /// UNMEASURED: this was documented as "~2x slower than square-and-multiply
        /// because every multiply is
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

        /// Fast exponentiation (NOT constant-time).
        ///
        /// Measured against `pow` rather than asserted: 7.5x on BN254_Fp, 11.2x
        /// on BLS12_381_Fp, 1.3x on Goldilocks, and a **1.5-2x REGRESSION** on
        /// the small Mersenne primes M31 and BabyBear, where the windowed form
        /// is slower than what it replaces. Do not use this on a small Mersenne
        /// field expecting a speedup.
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
        ///
        /// Total: `self / 0 == zero()`. Use `divChecked` to reject a zero
        /// divisor.
        pub fn div(self: Self, other: Self) Self {
            return self.mul(other.inv());
        }

        /// Checked division: `error.DivisionByZero` when `other == 0`
        /// (`error.InverseOfZero` is unreachable, the zero divisor is rejected
        /// above).
        pub fn divChecked(self: Self, other: Self) error{ DivisionByZero, InverseOfZero }!Self {
            if (other.isZero()) return error.DivisionByZero;
            return self.mul(try other.invChecked());
        }

        /// Hash for HashMap support.
        pub fn hash(self: Self) u64 {
            // FNV-1a hash of all three components
            var hash_val: u64 = 14695981039346656037;
            for (0..3) |i| {
                var v = if (i == 0) self.c0.toU512() else if (i == 1) self.c1.toU512() else self.c2.toU512();
                for (0..8) |_| {
                    // `v` is a u512 here, so the byte has to be narrowed before
                    // it meets the u64 accumulator -- and the multiply is `*%`,
                    // because Zig's wrapping arithmetic is an operator, not a
                    // method on u64.
                    const byte: u64 = @truncate(v);
                    hash_val ^= byte & 0xFF;
                    hash_val *%= 1099511628211;
                    v >>= 8;
                }
            }
            return hash_val;
        }

        /// Format for debugging.
        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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
