//! BigInt: arbitrary-precision signed integer backed by a fixed-size limb array.
//!
//! Provides allocation-free arithmetic on integers of up to `max_limbs * 64` bits.
//! All operations use stack storage only; the only allocations happen in
//! `toString` and `fromString`.
//!
//! # Quick Start
//! ```zig
//! const Big = BigInt(8); // 512-bit precision
//! const a = Big.fromU64(12345678901234567890);
//! const b = Big.fromU64(9876543210987654321);
//! const sum = try a.add(b);
//! const prod = try a.mul(b);
//! const qr = try a.divRem(b);
//! ```
//!
//! # Design
//! - **Sign + magnitude**: `negative` flag plus unsigned `limbs` array.
//! - **Little-endian**: `limbs[0]` is the least significant word.
//! - **Normalization**: `len` always reflects the number of non-zero limbs.
//! - **Overflow**: Returns `error.Overflow` when a result exceeds `max_limbs`.

const std = @import("std");
const limb = @import("limb.zig");

pub const Limb = limb.Limb;
pub const DoubleLimb = limb.DoubleLimb;

/// Big integer with at most `max_limbs` unsigned magnitude limbs.
///
/// `max_limbs` is a `comptime` parameter, so every `BigInt(N)` is a distinct
/// monomorphized type with no dynamic allocation.
///
/// # Type Parameters
/// - `max_limbs`: Maximum number of `u64` limbs.  Precision = `max_limbs * 64` bits.
pub fn BigInt(comptime max_limbs: usize) type {
    return struct {
        const Self = @This();

        /// Magnitude limbs, little-endian (`limbs[0]` = LSB).
        limbs: [max_limbs]Limb = std.mem.zeroes([max_limbs]Limb),
        /// Number of significant limbs (after normalization).
        len: usize = 0,
        /// Sign: `false` = positive or zero, `true` = negative.
        negative: bool = false,

        pub const MAX_LIMBS = max_limbs;
        pub const MAX_BITS = max_limbs * limb.LimbBits;

        // ------------------------------------------------------------------
        // Constructors
        // ------------------------------------------------------------------

        /// Return zero.
        pub fn zero() Self {
            return .{};
        }

        /// Return one.
        pub fn one() Self {
            var r = Self{};
            r.limbs[0] = 1;
            r.len = 1;
            return r;
        }

        /// Construct from an unsigned 64-bit integer.
        pub fn fromU64(x: u64) Self {
            var r = Self{};
            if (x != 0) {
                r.limbs[0] = x;
                r.len = 1;
            }
            return r;
        }

        /// Construct from a signed 64-bit integer.
        pub fn fromI64(x: i64) Self {
            var r = Self{};
            if (x == 0) return r;
            const ux = @abs(x);
            r.limbs[0] = @intCast(ux);
            r.len = 1;
            r.negative = x < 0;
            return r;
        }

        /// Construct from an unsigned 128-bit integer.
        pub fn fromU128(x: u128) Self {
            var r = Self{};
            if (x == 0) return r;
            r.limbs[0] = @truncate(x);
            r.limbs[1] = @truncate(x >> 64);
            r.len = if (r.limbs[1] == 0) 1 else 2;
            return r;
        }

        /// Parse from a decimal ASCII string.
        ///
        /// Returns `error.InvalidDigit` if the string contains non-digit characters.
        ///
        /// # Example
        /// ```zig
        /// const a = try Big.fromString("123456789012345678901234567890");
        /// ```
        pub fn fromString(s: []const u8) !Self {
            var r = Self.zero();
            for (s) |c| {
                if (c < '0' or c > '9') return error.InvalidDigit;
                const digit = c - '0';
                r = try r.mulU64(10);
                r = try r.addU64(digit);
            }
            return r;
        }

        // ------------------------------------------------------------------
        // Normalization & Predicates
        // ------------------------------------------------------------------

        /// Strip leading zero limbs and clear the sign of zero.
        pub fn normalize(self: *Self) void {
            var i = self.len;
            while (i > 0 and self.limbs[i - 1] == 0) i -= 1;
            self.len = i;
            if (self.len == 0) self.negative = false;
        }

        /// Return `true` if the value is zero.
        pub fn isZero(self: Self) bool {
            return self.len == 0;
        }

        /// Return `true` if the value is exactly one.
        pub fn isOne(self: Self) bool {
            return self.len == 1 and self.limbs[0] == 1 and !self.negative;
        }

        /// Return `true` if the value is negative.
        pub fn isNegative(self: Self) bool {
            return self.negative and self.len > 0;
        }

        /// Return the absolute value.
        pub fn abs(self: Self) Self {
            var r = self;
            r.negative = false;
            return r;
        }

        /// Return the number of bits required to represent the magnitude.
        pub fn bitLen(self: Self) usize {
            if (self.len == 0) return 0;
            const msb = self.limbs[self.len - 1];
            return (self.len - 1) * limb.LimbBits + limb.bitLen(msb);
        }

        // ------------------------------------------------------------------
        // Comparison
        // ------------------------------------------------------------------

        /// Return `true` if `self == other`.
        pub fn eql(self: Self, other: Self) bool {
            if (self.isZero() and other.isZero()) return true;
            if (self.negative != other.negative) return false;
            if (self.len != other.len) return false;
            return std.mem.eql(Limb, self.limbs[0..self.len], other.limbs[0..other.len]);
        }

        /// Three-way comparison: returns `-1`, `0`, or `1`.
        pub fn cmp(self: Self, other: Self) i2 {
            if (self.isZero() and other.isZero()) return 0;
            if (!self.negative and other.negative) return 1;
            if (self.negative and !other.negative) return -1;

            const mag_cmp = limb.cmpLimbs(self.limbs[0..@max(self.len, other.len)], other.limbs[0..@max(self.len, other.len)]);
            if (self.negative) return -mag_cmp;
            return mag_cmp;
        }

        pub fn lt(self: Self, other: Self) bool { return self.cmp(other) < 0; }
        pub fn gt(self: Self, other: Self) bool { return self.cmp(other) > 0; }
        pub fn leq(self: Self, other: Self) bool { return self.cmp(other) <= 0; }
        pub fn geq(self: Self, other: Self) bool { return self.cmp(other) >= 0; }

        // ------------------------------------------------------------------
        // Addition / Subtraction (unsigned magnitude)
        // ------------------------------------------------------------------

        /// Unsigned magnitude addition: `|a| + |b|`.
        fn addMag(a: Self, b: Self) !Self {
            var r = Self{};
            const n = @max(a.len, b.len);
            var carry: u1 = 0;
            for (0..n) |i| {
                const ai = if (i < a.len) a.limbs[i] else 0;
                const bi = if (i < b.len) b.limbs[i] else 0;
                const res = limb.addWithCarry(ai, bi, carry);
                r.limbs[i] = res.sum;
                carry = res.cout;
            }
            if (carry == 1) {
                if (n >= max_limbs) return error.Overflow;
                r.limbs[n] = 1;
                r.len = n + 1;
            } else {
                r.len = n;
            }
            r.normalize();
            return r;
        }

        /// Unsigned magnitude subtraction: `|a| - |b|`, requires `|a| >= |b|`.
        fn subMag(a: Self, b: Self) Self {
            std.debug.assert(a.geqMag(b));
            var r = Self{};
            var borrow: u1 = 0;
            for (0..a.len) |i| {
                const bi = if (i < b.len) b.limbs[i] else 0;
                const res = limb.subWithBorrow(a.limbs[i], bi, borrow);
                r.limbs[i] = res.diff;
                borrow = res.bout;
            }
            r.len = a.len;
            r.normalize();
            return r;
        }

        fn geqMag(self: Self, other: Self) bool {
            if (self.len != other.len) return self.len > other.len;
            return limb.cmpLimbs(self.limbs[0..self.len], other.limbs[0..self.len]) >= 0;
        }

        // ------------------------------------------------------------------
        // Signed addition / subtraction
        // ------------------------------------------------------------------

        /// Signed addition.
        ///
        /// # Errors
        /// `error.Overflow` if the result exceeds `max_limbs`.
        pub fn add(self: Self, other: Self) !Self {
            if (self.negative == other.negative) {
                var r = try addMag(self.abs(), other.abs());
                r.negative = self.negative;
                return r;
            }
            // Different signs: subtraction
            const a = self.abs();
            const b = other.abs();
            if (a.geqMag(b)) {
                var r = subMag(a, b);
                r.negative = self.negative;
                r.normalize();
                return r;
            } else {
                var r = subMag(b, a);
                r.negative = other.negative;
                r.normalize();
                return r;
            }
        }

        /// Signed subtraction: `self - other`.
        pub fn sub(self: Self, other: Self) !Self {
            var neg_other = other;
            neg_other.negative = !other.negative;
            return self.add(neg_other);
        }

        /// Arithmetic negation.
        pub fn neg(self: Self) Self {
            var r = self;
            if (!r.isZero()) r.negative = !r.negative;
            return r;
        }

        // ------------------------------------------------------------------
        // Add / Sub with u64
        // ------------------------------------------------------------------

        /// Add an unsigned 64-bit integer.
        pub fn addU64(self: Self, x: u64) !Self {
            const other = fromU64(x);
            return self.add(other);
        }

        /// Subtract an unsigned 64-bit integer.
        pub fn subU64(self: Self, x: u64) !Self {
            const other = fromU64(x);
            return self.sub(other);
        }

        // ------------------------------------------------------------------
        // Multiplication
        // ------------------------------------------------------------------

        /// Signed multiplication.
        ///
        /// Uses grade-school O(n*m) limb-by-limb multiplication.
        ///
        /// # Errors
        /// `error.Overflow` if the result exceeds `max_limbs`.
        pub fn mul(self: Self, other: Self) !Self {
            if (self.isZero() or other.isZero()) return Self.zero();

            const alen = self.len;
            const blen = other.len;
            if (alen + blen > max_limbs) return error.Overflow;

            var r = Self{};
            for (0..alen) |i| {
                var carry: Limb = 0;
                for (0..blen) |j| {
                    const res = limb.mulAddCarry(self.limbs[i], other.limbs[j], r.limbs[i + j], carry);
                    r.limbs[i + j] = res.lo;
                    carry = res.hi;
                }
                r.limbs[i + blen] = carry;
            }
            r.len = alen + blen;
            r.negative = self.negative != other.negative;
            r.normalize();
            return r;
        }

        /// Multiply by a single `u64` limb.
        pub fn mulU64(self: Self, x: u64) !Self {
            if (self.isZero() or x == 0) return Self.zero();
            if (x == 1) return self;

            var r = Self{};
            var carry: Limb = 0;
            for (0..self.len) |i| {
                const res = limb.mulAddCarry(self.limbs[i], x, 0, carry);
                r.limbs[i] = res.lo;
                carry = res.hi;
            }
            if (carry != 0) {
                if (self.len >= max_limbs) return error.Overflow;
                r.limbs[self.len] = carry;
                r.len = self.len + 1;
            } else {
                r.len = self.len;
            }
            r.negative = self.negative;
            return r;
        }

        // ------------------------------------------------------------------
        // Division and Remainder
        // ------------------------------------------------------------------

        /// Divide by a single limb. Returns `(quotient, remainder)`.
        ///
        /// Uses the standard long-division algorithm in base 2^64.
        pub fn divRemU64(self: Self, divisor: u64) !struct { q: Self, r: u64 } {
            if (divisor == 0) return error.DivisionByZero;
            if (self.isZero()) return .{ .q = Self.zero(), .r = 0 };

            var q = Self{};
            var remainder: DoubleLimb = 0;
            var i = self.len;
            while (i > 0) {
                i -= 1;
                remainder = (remainder << 64) | self.limbs[i];
                const d = remainder / divisor;
                q.limbs[i] = @truncate(d);
                remainder = remainder % divisor;
            }
            q.len = self.len;
            q.negative = self.negative;
            q.normalize();
            return .{ .q = q, .r = @truncate(remainder) };
        }

        /// Long division: `self / other`. Returns `(quotient, remainder)`.
        ///
        /// For single-limb divisors, delegates to `divRemU64`.
        /// For multi-limb divisors, uses a simplified shift-and-subtract approach.
        /// (Production code should use Knuth Algorithm D.)
        ///
        /// # Errors
        /// `error.DivisionByZero` if `other` is zero.
        pub fn divRem(self: Self, other: Self) !struct { q: Self, r: Self } {
            if (other.isZero()) return error.DivisionByZero;
            if (self.isZero()) return .{ .q = Self.zero(), .r = Self.zero() };

            const mag_a = self.abs();
            const mag_b = other.abs();

            if (mag_b.len == 1) {
                const dr = try mag_a.divRemU64(mag_b.limbs[0]);
                var q = dr.q;
                var r = Self.fromU64(dr.r);
                q.negative = self.negative != other.negative;
                r.negative = self.negative;
                q.normalize();
                r.normalize();
                return .{ .q = q, .r = r };
            }

            if (mag_a.len < mag_b.len) {
                var r = self;
                r.negative = self.negative;
                return .{ .q = Self.zero(), .r = r };
            }

            // Simplified long division for multi-limb divisor
            var q = Self.zero();
            var remainder = mag_a;

            const b_msb = mag_b.limbs[mag_b.len - 1];

            const n = mag_b.len;
            const m = mag_a.len - n;

            var i: usize = m + 1;
            while (i > 0) {
                i -= 1;
                var rem_slice = remainder.limbs[i..i + n + 1];
                const rem_hi = @as(DoubleLimb, rem_slice[n]) << 64 | rem_slice[n - 1];
                var qhat: Limb = @truncate(@min(rem_hi / b_msb, std.math.maxInt(Limb)));

                // Adjust qhat
                while (true) {
                    var prod = Self.zero();
                    var carry: Limb = 0;
                    for (0..n) |j| {
                        const p = limb.mulWide(mag_b.limbs[j], qhat);
                        const s = limb.addWithCarry(p.lo, carry, 0);
                        prod.limbs[j] = s.sum;
                        carry = p.hi + s.cout;
                    }
                    prod.limbs[n] = carry;
                    prod.len = n + 1;
                    prod.normalize();

                    var subtrahend = Self.zero();
                    for (0..n + 1) |j| {
                        subtrahend.limbs[i + j] = prod.limbs[j];
                    }
                    subtrahend.len = i + n + 1;
                    subtrahend.normalize();

                    if (remainder.geqMag(subtrahend)) {
                        remainder = remainder.subMag(subtrahend);
                        q.limbs[i] = qhat;
                        break;
                    }
                    qhat -= 1;
                }
            }

            q.len = m + 1;
            q.negative = self.negative != other.negative;
            q.normalize();
            remainder.negative = self.negative;
            remainder.normalize();
            return .{ .q = q, .r = remainder };
        }

        /// Integer division (quotient only).
        pub fn div(self: Self, other: Self) !Self {
            const qr = try self.divRem(other);
            return qr.q;
        }

        /// Remainder only.
        pub fn rem(self: Self, other: Self) !Self {
            const qr = try self.divRem(other);
            return qr.r;
        }

        /// Modular reduction: `self mod m`, always non-negative.
        pub fn mod(self: Self, m: Self) !Self {
            var r = try self.rem(m);
            if (r.isNegative()) {
                r = try r.add(m);
            }
            return r;
        }

        // ------------------------------------------------------------------
        // Bit shifts
        // ------------------------------------------------------------------

        /// Left shift by `shift` bits.
        ///
        /// # Errors
        /// `error.Overflow` if the result exceeds `max_limbs`.
        pub fn shl(self: Self, shift: usize) !Self {
            if (self.isZero() or shift == 0) return self;
            const limb_shift = shift / limb.LimbBits;
            const bit_shift = @as(usize, shift % limb.LimbBits);

            if (self.len + limb_shift > max_limbs) return error.Overflow;

            var r = Self{};
            var carry: Limb = 0;
            for (0..self.len) |i| {
                const val = self.limbs[i];
                r.limbs[i + limb_shift] = (val << @intCast(bit_shift)) | carry;
                carry = if (bit_shift == 0) 0 else val >> @intCast(limb.LimbBits - bit_shift);
            }
            if (carry != 0) {
                if (self.len + limb_shift >= max_limbs) return error.Overflow;
                r.limbs[self.len + limb_shift] = carry;
                r.len = self.len + limb_shift + 1;
            } else {
                r.len = self.len + limb_shift;
            }
            r.negative = self.negative;
            r.normalize();
            return r;
        }

        /// Right shift by `shift` bits (arithmetic for negative numbers).
        pub fn shr(self: Self, shift: usize) Self {
            if (self.isZero() or shift == 0) return self;
            const limb_shift = shift / limb.LimbBits;
            const bit_shift = @as(usize, shift % limb.LimbBits);

            if (limb_shift >= self.len) return Self.zero();

            var r = Self{};
            var borrow: Limb = 0;
            var i: usize = self.len;
            while (i > limb_shift) {
                i -= 1;
                const val = self.limbs[i];
                r.limbs[i - limb_shift] = (val >> @intCast(bit_shift)) | borrow;
                borrow = if (bit_shift == 0) 0 else val << @intCast(limb.LimbBits - bit_shift);
            }
            r.len = self.len - limb_shift;
            r.negative = self.negative;
            r.normalize();
            return r;
        }

        // ------------------------------------------------------------------
        // Bitwise (two's complement for negative)
        // ------------------------------------------------------------------

        /// Convert to two's complement representation in a fixed buffer.
        fn toTwosComplement(self: Self, buf: *[max_limbs]Limb) void {
            if (!self.negative) {
                @memcpy(buf[0..self.len], self.limbs[0..self.len]);
                @memset(buf[self.len..], 0);
                return;
            }
            // Invert and add 1
            for (0..max_limbs) |i| {
                buf[i] = ~self.limbs[i];
            }
            var carry: u1 = 1;
            for (0..max_limbs) |i| {
                const res = limb.addWithCarry(buf[i], 0, carry);
                buf[i] = res.sum;
                carry = res.cout;
            }
        }

        /// Bitwise AND.
        pub fn bitAnd(self: Self, other: Self) Self {
            var a: [max_limbs]Limb = undefined;
            var b: [max_limbs]Limb = undefined;
            self.toTwosComplement(&a);
            other.toTwosComplement(&b);
            var r = Self{};
            for (0..max_limbs) |i| {
                r.limbs[i] = a[i] & b[i];
            }
            if ((r.limbs[max_limbs - 1] >> 63) != 0) {
                for (0..max_limbs) |i| {
                    r.limbs[i] = ~r.limbs[i];
                }
                var carry: u1 = 1;
                for (0..max_limbs) |i| {
                    const res = limb.addWithCarry(r.limbs[i], 0, carry);
                    r.limbs[i] = res.sum;
                    carry = res.cout;
                }
                r.negative = true;
            }
            r.normalize();
            return r;
        }

        /// Bitwise OR.
        pub fn bitOr(self: Self, other: Self) Self {
            var a: [max_limbs]Limb = undefined;
            var b: [max_limbs]Limb = undefined;
            self.toTwosComplement(&a);
            other.toTwosComplement(&b);
            var r = Self{};
            for (0..max_limbs) |i| {
                r.limbs[i] = a[i] | b[i];
            }
            if ((r.limbs[max_limbs - 1] >> 63) != 0) {
                for (0..max_limbs) |i| r.limbs[i] = ~r.limbs[i];
                var carry: u1 = 1;
                for (0..max_limbs) |i| {
                    const res = limb.addWithCarry(r.limbs[i], 0, carry);
                    r.limbs[i] = res.sum;
                    carry = res.cout;
                }
                r.negative = true;
            }
            r.normalize();
            return r;
        }

        /// Bitwise XOR.
        pub fn bitXor(self: Self, other: Self) Self {
            var a: [max_limbs]Limb = undefined;
            var b: [max_limbs]Limb = undefined;
            self.toTwosComplement(&a);
            other.toTwosComplement(&b);
            var r = Self{};
            for (0..max_limbs) |i| {
                r.limbs[i] = a[i] ^ b[i];
            }
            if ((r.limbs[max_limbs - 1] >> 63) != 0) {
                for (0..max_limbs) |i| r.limbs[i] = ~r.limbs[i];
                var carry: u1 = 1;
                for (0..max_limbs) |i| {
                    const res = limb.addWithCarry(r.limbs[i], 0, carry);
                    r.limbs[i] = res.sum;
                    carry = res.cout;
                }
                r.negative = true;
            }
            r.normalize();
            return r;
        }

        // ------------------------------------------------------------------
        // Formatting
        // ------------------------------------------------------------------

        /// Convert to a decimal string.  Caller must free the result.
        pub fn toString(self: Self, allocator: std.mem.Allocator) ![]u8 {
            if (self.isZero()) {
                const s = try allocator.alloc(u8, 1);
                s[0] = '0';
                return s;
            }
            var mag = self.abs();
            var digits = std.ArrayList(u8){};
            defer digits.deinit(allocator);

            while (!mag.isZero()) {
                const dr = try mag.divRemU64(10);
                try digits.append(allocator, @intCast(dr.r + '0'));
                mag = dr.q;
            }

            const len = digits.items.len + if (self.negative) @as(usize, 1) else 0;
            const result = try allocator.alloc(u8, len);
            var pos: usize = 0;
            if (self.negative) {
                result[0] = '-';
                pos = 1;
            }
            var i = digits.items.len;
            while (i > 0) {
                i -= 1;
                result[pos] = digits.items[i];
                pos += 1;
            }
            return result;
        }

        /// Standard `std.fmt` formatting.
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            const s = try self.toString(gpa.allocator());
            defer gpa.allocator().free(s);
            try writer.writeAll(s);
        }
    };
}
