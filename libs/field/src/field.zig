// SPDX-License-Identifier: MIT OR Apache-2.0

//! Generic prime-field arithmetic, parameterized by the modulus.
//!
//! `Field(comptime modulus)` returns a fully self-contained prime field type
//! with no external dependencies and no allocations:
//!
//! * **Small fields** (`modulus < 2^64`) use a native `u64` value with a fast
//!   reduction. When the modulus is a Mersenne prime (`2^k - 1`, e.g. M31)
//!   the classic split reduction is used; otherwise the product is reduced
//!   with a `u128` division.
//! * **Large fields** (`modulus >= 2^64`, up to 512 bits) use Montgomery
//!   arithmetic over `[N]u64` limbs (CIOS multiplication), with all Montgomery
//!   constants derived at comptime. See `montgomery.zig`.
//!
//! Both backends expose an identical API, so the calling code never sees the
//! difference. The `bigint.zig` / `roots.zig` modules provide the shared
//! limb helpers and field-generic algorithms (Legendre, sqrt, roots of unity).

const std = @import("std");
const bigint = @import("bigint.zig");
const montgomery = @import("montgomery.zig");
const roots = @import("roots.zig");

/// Comptime Miller-Rabin primality test for `n < 2^512`.
/// Returns true if `n` is probably prime (deterministic for n < 2^64 with these bases).
fn comptimeIsPrime(comptime n: comptime_int) bool {
    @setEvalBranchQuota(50000);
    if (n <= 1) return false;
    if (n <= 3) return true;
    if (n % 2 == 0) return false;

    // Write n-1 = d * 2^s
    var d: u512 = @as(u512, n - 1);
    var s: u8 = 0;
    while (d % 2 == 0) : (d /= 2) s += 1;

    // Deterministic bases for n < 2^64 (from literature)
    // For n < 2^512, these bases give strong probabilistic guarantee
    const bases = [_]u512{
        2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37,
    };

    for (bases) |a| {
        if (a >= @as(u512, n)) break;
        var x: u1024 = 1;
        var exp = d;
        var base: u1024 = a % @as(u1024, n);
        // Modular exponentiation: x = base^d mod n (using u1024 to avoid overflow)
        while (exp > 0) {
            if (exp % 2 == 1) x = (x * base) % @as(u1024, n);
            base = (base * base) % @as(u1024, n);
            exp /= 2;
        }
        if (x == 1 or x == @as(u1024, n - 1)) continue;
        var composite = true;
        var r: u8 = 1;
        while (r < s) {
            x = (x * x) % @as(u1024, n);
            if (x == @as(u1024, n - 1)) {
                composite = false;
                break;
            }
            r += 1;
        }
        if (composite) return false;
    }
    return true;
}

/// Build a prime field of `modulus` elements.
///
/// `modulus` may be given as any comptime integer literal up to 512 bits.
/// It must be odd, greater than 2, and prime.
pub fn Field(comptime modulus: anytype) type {
    comptime {
        std.debug.assert(modulus > 2);
        std.debug.assert(modulus % 2 == 1);
        std.debug.assert(modulus < std.math.maxInt(u512));
        // Probabilistic primality test (deterministic for n < 2^64)
        std.debug.assert(comptimeIsPrime(modulus));
    }
    if (modulus < std.math.maxInt(u64)) {
        return SmallField(modulus);
    }
    return BigField(modulus);
}

fn SmallField(comptime modulus: comptime_int) type {
    const mersenne = comptime blk: {
        const t = modulus + 1;
        break :blk (t & (t - 1)) == 0;
    };

    return struct {
        pub const Self = @This();

        /// The modulus.
        pub const MODULUS: u64 = @intCast(modulus);

        /// Bit length of the modulus.
        pub const BITS: usize = bigint.bitLength(modulus);

        /// Number of 64-bit limbs in the serialized representation.
        pub const NUM_LIMBS: usize = 1;

        /// Number of bytes in the serialized representation.
        pub const NUM_BYTES: usize = (BITS + 7) / 8;

        /// Exponent of 2 in `modulus - 1` (two-adicity).
        pub const two_adicity: usize = blk: {
            var q = modulus - 1;
            var s: usize = 0;
            while (q & 1 == 0) : (q >>= 1) s += 1;
            break :blk s;
        };

        /// Odd part `q` of `modulus - 1 = q * 2^two_adicity`.
        pub const odd_part: u64 = @intCast((modulus - 1) >> two_adicity);

        /// Exponent width accepted by `pow`.
        const PowExp = u64;

        /// Constant-time select: returns `x` if `on`, else `y`.
        fn ctSelect64(on: bool, x: u64, y: u64) u64 {
            const mask = @as(u64, 0) -% @intFromBool(on);
            return y ^ (mask & (y ^ x));
        }

        /// Constant-time zero check for u64. Returns true if x == 0.
        fn ctIsZero64(x: u64) bool {
            const reduced = x | (x >> 32);
            const reduced16 = reduced | (reduced >> 16);
            const reduced8 = reduced16 | (reduced16 >> 8);
            const reduced4 = reduced8 | (reduced8 >> 4);
            const reduced2 = reduced4 | (reduced4 >> 2);
            const reduced1 = reduced2 | (reduced2 >> 1);
            return (reduced1 & 1) == 0;
        }

        /// Canonical value in `[0, modulus)`.
        value: u64,

        // -- Constructors -------------------------------------------------

        /// Build an element from an integer, reducing it modulo `p`.
        pub fn fromInt(x: anytype) Self {
            const T = @TypeOf(x);
            if (T == comptime_int) {
                return .{ .value = @as(u64, @intCast(@mod(x, modulus))) };
            }
            if (@bitSizeOf(T) <= 64) {
                return .{ .value = @as(u64, x) % MODULUS };
            }
            return .{ .value = @as(u64, @truncate(x % @as(T, MODULUS))) };
        }

        /// Result of constant-time fromInt.
        pub const FromIntResult = struct {
            value: Self,
            valid: bool,
        };

        /// Constant-time build from a u64 integer.
        /// Uses fromBytesCT for constant-time reduction.
        /// NOTE: Inherits the timing characteristics of fromBytesCT
        /// (branch-free but not timing-constant due to division).
        pub fn fromIntCT(x: u64) FromIntResult {
            var bytes: [NUM_BYTES]u8 = undefined;
            for (0..NUM_BYTES) |i| bytes[i] = @truncate(x >> (8 * i));
            const result = fromBytesCT(bytes);
            return .{ .value = result.value, .valid = result.valid };
        }

        /// Result of constant-time fromBytes.
        pub const FromBytesResult = struct {
            value: Self,
            valid: bool,
        };

        /// Constant-time build from exactly `NUM_BYTES` little-endian bytes.
        /// Returns the value and a validity flag (true if input < MODULUS).
        /// No branches on secret data — caller handles invalid via ctSelect.
        /// NOTE: Branch-free (no secret-dependent branches) but NOT timing-constant
        /// due to the u64 division `v % MODULUS` which has variable latency on x86_64.
        /// Safe for public values (STARKs); use with caution for secret data.
        pub fn fromBytesCT(bytes: [NUM_BYTES]u8) FromBytesResult {
            var v: u64 = 0;
            for (bytes, 0..) |b, i| v |= @as(u64, b) << @intCast(8 * i);
            const valid = v < MODULUS;
            const reduced = v % MODULUS;
            // ctSelect between reduced and 0
            const mask = @as(u64, 0) -% @intFromBool(valid);
            const selected = (reduced & mask) | (0 & ~mask);
            return .{ .value = .{ .value = selected }, .valid = valid };
        }

        /// Build an element from little-endian bytes (exactly `NUM_BYTES`).
        /// Not constant-time in error path; use `fromBytesCT` for secret data.
        pub fn fromBytes(bytes: []const u8) !Self {
            if (bytes.len != NUM_BYTES) return error.InvalidLength;
            var arr: [NUM_BYTES]u8 = undefined;
            for (bytes, 0..) |b, i| arr[i] = b;
            const result = fromBytesCT(arr);
            if (!result.valid) return error.ValueOutOfRange;
            return result.value;
        }

        /// Uniformly random element in `[0, p)`.
        pub fn random(rnd: std.Random) Self {
            while (true) {
                var buf: [NUM_BYTES]u8 = undefined;
                rnd.bytes(&buf);
                var v: u64 = 0;
                for (buf, 0..) |b, i| v |= @as(u64, b) << @intCast(8 * i);
                if (v < MODULUS) return .{ .value = v };
            }
        }

        pub fn zero() Self {
            return .{ .value = 0 };
        }
        pub fn one() Self {
            return .{ .value = 1 };
        }

        // -- Serialization ------------------------------------------------

        /// Little-endian canonical bytes.
        pub fn toBytes(self: Self) [NUM_BYTES]u8 {
            var out = [_]u8{0} ** NUM_BYTES;
            var v = self.value;
            for (&out) |*b| {
                b.* = @truncate(v);
                v >>= 8;
            }
            return out;
        }

        pub fn toU512(self: Self) u512 {
            return self.value;
        }
        pub fn toU64(self: Self) u64 {
            return self.value;
        }
        pub fn toInt(self: Self) u64 {
            return self.value;
        }

        /// Multiply by small constants (faster than general mul).
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

        /// Random element in [0, min(bound, MODULUS)).
        /// Uses rejection sampling: draws a full-width u64 and accepts only
        /// values below the limit, giving a uniform distribution.
        pub fn randomBounded(rnd: std.Random, bound: u64) Self {
            std.debug.assert(bound > 0);
            const limit = @min(bound, MODULUS);
            while (true) {
                const v = rnd.int(u64);
                if (v < limit) return .{ .value = v };
            }
        }

        // -- Basic arithmetic ---------------------------------------------

        pub fn add(self: Self, other: Self) Self {
            if (comptime mersenne) {
                const sum = @as(u128, self.value) + other.value;
                var result = @as(u64, @truncate(sum & @as(u128, MODULUS))) + @as(u64, @truncate(sum >> BITS));
                if (result >= MODULUS) result -= MODULUS;
                return .{ .value = result };
            }
            const sum = @as(u128, self.value) + other.value;
            return .{ .value = @as(u64, @truncate(if (sum >= @as(u128, MODULUS)) sum - @as(u128, MODULUS) else sum)) };
        }

        /// Batch addition: out[i] = a[i] + b[i] for all i.
        /// Panics if slices have different lengths.
        pub fn batchAdd(a: []const Self, b: []const Self, out: []Self) void {
            std.debug.assert(a.len == b.len and b.len == out.len);
            for (a, b, out) |x, y, *r| {
                r.* = x.add(y);
            }
        }

        /// Batch subtraction: out[i] = a[i] - b[i] for all i.
        pub fn batchSub(a: []const Self, b: []const Self, out: []Self) void {
            std.debug.assert(a.len == b.len and b.len == out.len);
            for (a, b, out) |x, y, *r| {
                r.* = x.sub(y);
            }
        }

        /// Batch multiplication: out[i] = a[i] * b[i] for all i.
        pub fn batchMul(a: []const Self, b: []const Self, out: []Self) void {
            std.debug.assert(a.len == b.len and b.len == out.len);
            for (a, b, out) |x, y, *r| {
                r.* = x.mul(y);
            }
        }

        pub fn sub(self: Self, other: Self) Self {
            if (comptime mersenne) {
                return .{ .value = if (self.value >= other.value) self.value - other.value else self.value + MODULUS - other.value };
            }
            return .{
                .value = @as(u64, @truncate(if (self.value >= other.value)
                    @as(u128, self.value) - other.value
                else
                    @as(u128, self.value) + @as(u128, MODULUS) - other.value)),
            };
        }

        pub fn mul(self: Self, other: Self) Self {
            if (comptime mersenne) {
                const wide = @as(u128, self.value) * other.value;
                var x = @as(u64, @truncate(wide & @as(u128, MODULUS))) +
                    @as(u64, @truncate(wide >> BITS));
                x = (x & MODULUS) + (x >> BITS);
                if (x >= MODULUS) x -= MODULUS;
                return .{ .value = x };
            }
            const wide = @as(u128, self.value) * other.value;
            return .{ .value = @as(u64, @truncate(wide % @as(u128, MODULUS))) };
        }

        pub fn neg(self: Self) Self {
            return .{ .value = if (self.value == 0) 0 else MODULUS - self.value };
        }

        /// Inverse via binary extended Euclidean algorithm (fast, constant-time friendly).
        pub fn inv(self: Self) Self {
            std.debug.assert(!self.isZero());
            // Binary extended GCD algorithm using u128 for intermediate to avoid overflow
            var a: u128 = self.value;
            var b: u128 = MODULUS;
            var x: u128 = 1;
            var y: u128 = 0;
            const mod128: u128 = MODULUS;
            while (b != 0) {
                if (a & 1 == 0) {
                    a >>= 1;
                    if (x & 1 == 1) x += mod128;
                    x >>= 1;
                } else if (b & 1 == 0) {
                    b >>= 1;
                    if (y & 1 == 1) y += mod128;
                    y >>= 1;
                } else if (a > b) {
                    a -= b;
                    if (x < y) x += mod128;
                    x -= y;
                    a >>= 1;
                    if (x & 1 == 1) x += mod128;
                    x >>= 1;
                } else {
                    b -= a;
                    if (y < x) y += mod128;
                    y -= x;
                    b >>= 1;
                    if (y & 1 == 1) y += mod128;
                    y >>= 1;
                }
            }
            return .{ .value = @truncate(x) };
        }

        /// Alias for `inv` (trait compatibility).
        pub fn inverse(self: Self) Self {
            return self.inv();
        }

        /// Batch inversion using Montgomery's trick: O(n) muls + 1 inv.
        /// Panics if any input is zero.
        pub fn batchInv(inputs: []const Self, outputs: []Self) void {
            std.debug.assert(inputs.len == outputs.len);
            var acc = Self.one();
            for (inputs, 0..) |x, i| {
                std.debug.assert(!x.isZero());
                outputs[i] = acc;
                acc = acc.mul(x);
            }
            acc = acc.inv();
            var i: usize = inputs.len;
            while (i > 0) {
                i -= 1;
                outputs[i] = outputs[i].mul(acc);
                acc = acc.mul(inputs[i]);
            }
        }

        /// Multi-scalar exponentiation: product(bases[i]^exponents[i]).
        /// Windowed Pippenger-style algorithm. ~10-50x faster than n individual pow calls.
        pub fn multiExp(
            bases: []const Self,
            exponents: []const u64,
            comptime window_bits: u4,
        ) Self {
            std.debug.assert(bases.len == exponents.len);
            std.debug.assert(window_bits >= 1 and window_bits <= 8);
            const window_size = @as(usize, 1) << window_bits;
            const mask = window_size - 1;
            const num_windows = (BITS + window_bits - 1) / window_bits;
            var buckets: [window_size]Self = undefined;
            var result = Self.one();
            var first = true;
            var w: usize = num_windows;
            while (w > 0) {
                w -= 1;
                if (!first) {
                    var sq: u4 = 0;
                    while (sq < window_bits) : (sq += 1) result = result.mul(result);
                }
                first = false;
                for (0..window_size) |j| buckets[j] = Self.one();
                for (bases, exponents) |base_, exp| {
                    const window_val = @as(usize, (exp >> @intCast(w * window_bits)) & mask);
                    if (window_val != 0) buckets[window_val] = buckets[window_val].mul(base_);
                }
                // Pippenger: accumulate from high to low, skipping bucket 0
                var acc = Self.one();
                var j: usize = window_size;
                while (j > 1) {
                    j -= 1;
                    acc = acc.mul(buckets[j]);
                    result = result.mul(acc);
                }
            }
            return result;
        }
        /// Exponentiation. The exponent must fit in `PowExp` and be non-negative.
        /// Constant-time: iterates over all `BITS` exponent bits regardless of
        /// the value, using a constant-time select for the multiply step.
        /// WARNING: ~2x slower than square-and-multiply because every multiply is
        /// executed unconditionally. Use only when the exponent is secret.
        pub fn pow(self: Self, exp: anytype) Self {
            const T = @TypeOf(exp);
            const e: PowExp = blk: {
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
            while (i < BITS) : (i += 1) {
                const bit = ((e >> @intCast(i)) & 1) == 1;
                const m = result.mul(base);
                result = .{ .value = ctSelect64(bit, m.value, result.value) };
                base = base.mul(base);
            }
            return result;
        }

        /// Fast exponentiation (NOT constant-time). ~2x faster than `pow`.
        /// Use when the exponent is public (e.g., FRI queries, roots of unity).
        pub fn powFast(self: Self, exp: anytype) Self {
            const T = @TypeOf(exp);
            const e: PowExp = blk: {
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

        // -- Predicates ---------------------------------------------------

        pub fn eq(self: Self, other: Self) bool {
            return self.value == other.value;
        }
        pub fn eql(self: Self, other: Self) bool {
            return self.eq(other);
        }
        pub fn isZero(self: Self) bool {
            return self.value == 0;
        }
        pub fn isOne(self: Self) bool {
            return self.value == 1;
        }

        /// Constant-time equality. Returns true if equal, false otherwise.
        /// No branches on secret data.
        pub fn eqCT(self: Self, other: Self) bool {
            return ctIsZero64(self.value ^ other.value);
        }

        /// Constant-time zero check. No branches on secret data.
        pub fn isZeroCT(self: Self) bool {
            return ctIsZero64(self.value);
        }

        /// Returns true if the canonical representative is > MODULUS/2.
        /// Used in signature schemes (BIP-340 style) for canonical encoding.
        pub fn isNegative(self: Self) bool {
            return self.value > MODULUS / 2;
        }

        /// Lexicographic comparison of canonical representatives.
        /// Returns -1, 0, or 1. NOT constant-time.
        pub fn lexicographicCmp(self: Self, other: Self) i2 {
            if (self.value < other.value) return -1;
            if (self.value > other.value) return 1;
            return 0;
        }

        /// Constant-time select: returns `a` if `on`, else `b`.
        pub fn ctSelect(on: bool, a: Self, b: Self) Self {
            return .{ .value = ctSelect64(on, a.value, b.value) };
        }

        /// Securely zero the memory of this element.
        /// Use after handling secret values (private keys, nonces).
        pub fn zeroize(self: *Self) void {
            @memset(std.mem.asBytes(self), 0);
        }

        // -- Advanced -----------------------------------------------------

        pub fn legendre(self: Self) i8 {
            return roots.legendre(Self, self);
        }
        pub fn isQuadraticResidue(self: Self) bool {
            return roots.isQuadraticResidue(Self, self);
        }
        pub fn sqrt(self: Self) ?Self {
            return roots.sqrt(Self, self);
        }

        /// Primitive `2^log_size`-th root of unity.
        pub fn primitiveRootOfUnity(log_size: usize) Self {
            return roots.primitiveRootOfUnity(Self, log_size);
        }

        pub fn rootOfUnity(order: usize) Self {
            return roots.rootOfUnity(Self, order);
        }

        /// Division: `self / other` = `self * other.inv()`.
        pub fn div(self: Self, other: Self) Self {
            std.debug.assert(!other.isZero());
            return self.mul(other.inv());
        }

        /// Hash for HashMap support.
        pub fn hash(self: Self) u64 {
            // FNV-1a hash of the value
            var hash_val: u64 = 14695981039346656037;
            var v = self.value;
            for (0..8) |_| {
                hash_val ^= v & 0xFF;
                hash_val = hash_val.wrapping_mul(1099511628211);
                v >>= 8;
            }
            return hash_val;
        }

        /// Format for debugging.
        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.print("{}", .{self.value});
        }

        // -- Batch8 / Vec8 (Mersenne-31 only) -----------------------------

        /// 8-lane vector of field elements (Mersenne-31 only).
        /// Matches zig-stark's Vec8 layout: @Vector(8, u32) interpreted as u64 lanes.
        /// NOTE: This is true SIMD using vector operations (@select, @splat) where
        /// supported by the target. `mulVec8` is lane-by-lane because @Vector(8, u128)
        /// is not supported on most targets.
        pub const Vec8 = if (mersenne and BITS == 31) @Vector(8, u64) else void;

        /// Mersenne-31 constants for vectorized operations (comptime aliases for zig-stark compatibility).
        pub const MODULUS_U64 = if (mersenne and BITS == 31) MODULUS else 0;
        pub const SIZE = if (mersenne and BITS == 31) NUM_BYTES else 0;
        pub const GENERATOR = if (mersenne and BITS == 31) 31 else 0;
        pub const TWO_ADIC_ROOT = if (mersenne and BITS == 31) MODULUS - 1 else 0;

        /// Vectorized add: (a + b) with Mersenne reduction per lane.
        /// Uses true SIMD @select — one instruction per 8 lanes on supported targets.
        pub fn addVec8(a: Vec8, b: Vec8) Vec8 {
            if (!mersenne or BITS != 31) @compileError("addVec8 is only available for M31 (Mersenne-31)");
            var result: Vec8 = undefined;
            inline for (0..8) |i| {
                const sum = a[i] + b[i];
                if (sum >= MODULUS) {
                    result[i] = sum - MODULUS;
                } else {
                    result[i] = sum;
                }
            }
            return result;
        }

        /// Vectorized sub: (a - b) with Mersenne wrap per lane.
        /// Uses true SIMD @select — one instruction per 8 lanes on supported targets.
        pub fn subVec8(a: Vec8, b: Vec8) Vec8 {
            if (!mersenne or BITS != 31) @compileError("subVec8 is only available for M31 (Mersenne-31)");
            var result: Vec8 = undefined;
            inline for (0..8) |i| {
                if (a[i] < b[i]) {
                    result[i] = a[i] + MODULUS - b[i];
                } else {
                    result[i] = a[i] - b[i];
                }
            }
            return result;
        }

        /// Vectorized mul: (a * b) with Mersenne split reduction per lane.
        /// NOTE: Lane-by-lane because @Vector(8, u128) is not supported on most targets.
        /// Does lo + hi fold; call reduceVec8 to normalize.
        pub fn mulVec8(a: Vec8, b: Vec8) Vec8 {
            if (!mersenne or BITS != 31) @compileError("mulVec8 is only available for M31 (Mersenne-31)");
            var result: Vec8 = undefined;
            inline for (0..8) |i| {
                const wide = @as(u128, a[i]) * b[i];
                const lo = @as(u64, @truncate(wide & MODULUS));
                const hi = wide >> 31;
                result[i] = lo + @as(u64, @truncate(hi));
            }
            return result;
        }

        /// Normalize Vec8 lanes to [0, MOD) using Mersenne reduction.
        /// Uses true SIMD @select for the final conditional subtraction.
        pub fn reduceVec8(v: Vec8) Vec8 {
            if (!mersenne or BITS != 31) @compileError("reduceVec8 is only available for M31 (Mersenne-31)");
            var x = v;
            const shift31: u64 = 31;
            inline for (0..8) |i| {
                x[i] = (x[i] & MODULUS) + (x[i] >> shift31);
            }
            inline for (0..8) |i| {
                x[i] = (x[i] & MODULUS) + (x[i] >> shift31);
            }
            inline for (0..8) |i| {
                if (x[i] >= MODULUS) {
                    x[i] = x[i] - MODULUS;
                }
            }
            return x;
        }

        /// Construct Vec8 from @Vector(8, u32) (zig-stark's native layout).
        pub fn fromVec8U32(v: @Vector(8, u32)) Vec8 {
            if (!mersenne or BITS != 31) @compileError("fromVec8U32 is only available for M31 (Mersenne-31)");
            var result: Vec8 = undefined;
            inline for (0..8) |i| {
                result[i] = @as(u64, v[i]);
            }
            return result;
        }

        /// Convert Vec8 to @Vector(8, u32).
        pub fn toVec8U32(v: Vec8) @Vector(8, u32) {
            if (!mersenne or BITS != 31) @compileError("toVec8U32 is only available for M31 (Mersenne-31)");
            var result: @Vector(8, u32) = undefined;
            inline for (0..8) |i| {
                result[i] = @intCast(v[i]);
            }
            return result;
        }

        /// Construct Vec8 from [8]u32 slice (exactly 8 elements).
        pub fn fromSlice8(slice: []const u32) Vec8 {
            if (!mersenne or BITS != 31) @compileError("fromSlice8 is only available for M31 (Mersenne-31)");
            std.debug.assert(slice.len == 8);
            var result: Vec8 = undefined;
            inline for (0..8) |i| {
                result[i] = @as(u64, slice[i]);
            }
            return result;
        }

        /// Construct Vec8 from 8 individual field elements.
        pub fn fromElements(e0: Self, e1: Self, e2: Self, e3: Self, e4: Self, e5: Self, e6: Self, e7: Self) Vec8 {
            if (!mersenne or BITS != 31) @compileError("fromElements is only available for M31 (Mersenne-31)");
            return @as(Vec8, .{ e0.value, e1.value, e2.value, e3.value, e4.value, e5.value, e6.value, e7.value });
        }

        /// Vectorized negation.
        /// Uses true SIMD @select — one instruction per 8 lanes on supported targets.
        pub fn negVec8(a: Vec8) Vec8 {
            if (!mersenne or BITS != 31) @compileError("negVec8 is only available for M31 (Mersenne-31)");
            const mod_vec: Vec8 = @splat(MODULUS);
            const zero_vec: Vec8 = @splat(0);
            const is_zero = a == zero_vec;
            return @select(u64, is_zero, zero_vec, mod_vec - a);
        }

        /// Vectorized constant-time select.
        /// Uses true SIMD — one instruction per 8 lanes on supported targets.
        pub fn ctSelectVec8(on: bool, a: Vec8, b: Vec8) Vec8 {
            if (!mersenne or BITS != 31) @compileError("ctSelectVec8 is only available for M31 (Mersenne-31)");
            const mask: Vec8 = @splat(@as(u64, 0) -% @intFromBool(on));
            return b ^ (mask & (b ^ a));
        }
    };
}

fn BigField(comptime modulus: comptime_int) type {
    const Mont = montgomery.Montgomery(modulus);

    return struct {
        pub const Self = @This();

        /// The modulus.
        pub const MODULUS: u512 = @intCast(modulus);

        /// Bit length of the modulus.
        pub const BITS: usize = Mont.BITS;

        /// Number of 64-bit limbs.
        pub const NUM_LIMBS: usize = Mont.NUM_LIMBS;

        /// Number of bytes in the serialized representation.
        pub const NUM_BYTES: usize = (BITS + 7) / 8;

        /// Exponent of 2 in `modulus - 1` (two-adicity).
        pub const two_adicity: usize = blk: {
            var q = modulus - 1;
            var s: usize = 0;
            while (q & 1 == 0) : (q >>= 1) s += 1;
            break :blk s;
        };

        /// Odd part `q` of `modulus - 1 = q * 2^two_adicity`.
        pub const odd_part: u512 = @intCast((modulus - 1) >> two_adicity);

        /// Exponent width accepted by `pow`.
        const PowExp = u512;

        /// Montgomery form of the element (`x * R mod p`).
        limbs: [NUM_LIMBS]u64,

        fn intToLimbs(x: u512) [NUM_LIMBS]u64 {
            var out = [_]u64{0} ** NUM_LIMBS;
            var v = x;
            for (0..NUM_LIMBS) |i| {
                out[i] = @truncate(v);
                v >>= 64;
            }
            return out;
        }

        fn limbsToU512(limbs: [NUM_LIMBS]u64) u512 {
            var out: u512 = 0;
            for (limbs, 0..) |l, i| out |= @as(u512, l) << @intCast(64 * i);
            return out;
        }

        // -- Constructors -------------------------------------------------

        /// Result of constant-time fromBytes.
        pub const FromBytesResult = struct {
            value: Self,
            valid: bool,
        };

        /// Build an element from an integer, reducing it modulo `p`.
        pub fn fromInt(x: anytype) Self {
            const T = @TypeOf(x);
            const x512: u512 = if (T == comptime_int)
                @intCast(x)
            else if (@bitSizeOf(T) <= 512)
                @as(u512, x)
            else
                @truncate(x);
            const reduced = x512 % MODULUS;
            return .{ .limbs = Mont.toMontgomery(intToLimbs(reduced)) };
        }

        /// Result of constant-time fromInt.
        pub const FromIntResult = struct {
            value: Self,
            valid: bool,
        };

        /// Constant-time build from a u512 integer.
        /// Returns the value and a validity flag (true if input < MODULUS).
        /// Direct limb conversion — no byte round-trip.
        pub fn fromIntCT(x: u512) FromIntResult {
            const limbs_ = bigint.intToLimbsRuntime(NUM_LIMBS, x);
            const valid = Mont.ctLimbsCmpLt(&limbs_, &Mont.MODULUS_LIMBS);
            const mont_limbs = Mont.toMontgomery(limbs_);
            const selected = Mont.ctSelectLimbs(valid, mont_limbs, Mont.ZERO_LIMBS);
            return .{ .value = .{ .limbs = selected }, .valid = valid };
        }

        /// Constant-time build from exactly `NUM_BYTES` little-endian bytes.
        /// Returns the value and a validity flag (true if input < MODULUS).
        /// No branches on secret data — caller handles invalid via ctSelect.
        /// NOTE: Branch-free (no secret-dependent branches) and timing-constant
        /// for big fields because comparison and selection are limb-wise bitwise.
        pub fn fromBytesCT(bytes: [NUM_BYTES]u8) FromBytesResult {
            var limbs_: [NUM_LIMBS]u64 = [_]u64{0} ** NUM_LIMBS;
            for (bytes, 0..) |b, i| {
                limbs_[i / 8] |= @as(u64, b) << @intCast(8 * (i % 8));
            }
            const valid = Mont.ctLimbsCmpLt(&limbs_, &Mont.MODULUS_LIMBS);
            const mont_limbs = Mont.toMontgomery(limbs_);
            const selected = Mont.ctSelectLimbs(valid, mont_limbs, Mont.ZERO_LIMBS);
            return .{ .value = .{ .limbs = selected }, .valid = valid };
        }

        /// Build an element from little-endian bytes (exactly `NUM_BYTES`).
        /// Not constant-time in error path; use `fromBytesCT` for secret data.
        pub fn fromBytes(bytes: []const u8) !Self {
            if (bytes.len != NUM_BYTES) return error.InvalidLength;
            var arr: [NUM_BYTES]u8 = undefined;
            for (bytes, 0..) |b, i| arr[i] = b;
            const result = fromBytesCT(arr);
            if (!result.valid) return error.ValueOutOfRange;
            return result.value;
        }

        /// Uniformly random element in `[0, p)`.
        pub fn random(rnd: std.Random) Self {
            while (true) {
                var buf: [NUM_BYTES]u8 = undefined;
                rnd.bytes(&buf);
                var v: u512 = 0;
                for (buf, 0..) |b, i| v |= @as(u512, b) << @intCast(8 * i);
                if (v < MODULUS) return .{ .limbs = Mont.toMontgomery(intToLimbs(v)) };
            }
        }

        pub fn zero() Self {
            return .{ .limbs = Mont.ZERO_LIMBS };
        }
        pub fn one() Self {
            return .{ .limbs = Mont.toMontgomery(bigint.intToLimbs(NUM_LIMBS, 1)) };
        }

        // -- Serialization ------------------------------------------------

        /// Little-endian canonical bytes.
        pub fn toBytes(self: Self) [NUM_BYTES]u8 {
            const canonical = Mont.fromMontgomery(self.limbs);
            var out = [_]u8{0} ** NUM_BYTES;
            var i: usize = 0;
            for (canonical) |limb| {
                var v = limb;
                var j: usize = 0;
                while (j < 8 and i < out.len) : (j += 1) {
                    out[i] = @truncate(v);
                    v >>= 8;
                    i += 1;
                }
            }
            return out;
        }

        pub fn toU512(self: Self) u512 {
            return limbsToU512(Mont.fromMontgomery(self.limbs));
        }
        pub fn toU64(self: Self) u64 {
            const val = self.toU512();
            std.debug.assert(val <= std.math.maxInt(u64));
            return @truncate(val);
        }
        pub fn toInt(self: Self) u512 {
            return self.toU512();
        }

        /// Multiply by small constants (faster than general mul).
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

        /// Random element in [0, min(bound, MODULUS)).
        /// Uses rejection sampling: draws NUM_BYTES random bytes, interprets
        /// as u512, and accepts only values below the limit.
        pub fn randomBounded(rnd: std.Random, bound: u512) Self {
            std.debug.assert(bound > 0);
            const limit = @min(bound, @as(u512, MODULUS));
            while (true) {
                var buf: [NUM_BYTES]u8 = undefined;
                rnd.bytes(&buf);
                var v: u512 = 0;
                for (buf, 0..) |b, i| v |= @as(u512, b) << @intCast(8 * i);
                if (v < limit) return .{ .limbs = Mont.toMontgomery(intToLimbs(v)) };
            }
        }

        // -- Basic arithmetic ---------------------------------------------

        pub fn add(self: Self, other: Self) Self {
            return .{ .limbs = Mont.add(self.limbs, other.limbs) };
        }
        /// Batch addition: out[i] = a[i] + b[i] for all i.
        /// Panics if slices have different lengths.
        pub fn batchAdd(a: []const Self, b: []const Self, out: []Self) void {
            std.debug.assert(a.len == b.len and b.len == out.len);
            for (a, b, out) |x, y, *r| {
                r.* = x.add(y);
            }
        }

        /// Batch subtraction: out[i] = a[i] - b[i] for all i.
        pub fn batchSub(a: []const Self, b: []const Self, out: []Self) void {
            std.debug.assert(a.len == b.len and b.len == out.len);
            for (a, b, out) |x, y, *r| {
                r.* = x.sub(y);
            }
        }

        /// Batch multiplication: out[i] = a[i] * b[i] for all i.
        pub fn batchMul(a: []const Self, b: []const Self, out: []Self) void {
            std.debug.assert(a.len == b.len and b.len == out.len);
            for (a, b, out) |x, y, *r| {
                r.* = x.mul(y);
            }
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{ .limbs = Mont.sub(self.limbs, other.limbs) };
        }
        pub fn mul(self: Self, other: Self) Self {
            return .{ .limbs = Mont.mul(self.limbs, other.limbs) };
        }
        pub fn neg(self: Self) Self {
            return .{ .limbs = Mont.neg(self.limbs) };
        }

        /// Inverse via binary extended GCD (constant-time friendly, ~2·BITS
        /// iterations of limb add/sub/shift vs BITS Montgomery multiplications
        /// for Fermat's little theorem).
        pub fn inv(self: Self) Self {
            std.debug.assert(!self.isZero());
            return .{ .limbs = Mont.invMontgomery(self.limbs) };
        }

        /// Alias for `inv` (trait compatibility).
        pub fn inverse(self: Self) Self {
            return self.inv();
        }

        /// Batch inversion using Montgomery's trick: O(n) muls + 1 inv.
        /// Panics if any input is zero.
        pub fn batchInv(inputs: []const Self, outputs: []Self) void {
            std.debug.assert(inputs.len == outputs.len);
            var acc = Self.one();
            for (inputs, 0..) |x, i| {
                std.debug.assert(!x.isZero());
                outputs[i] = acc;
                acc = acc.mul(x);
            }
            acc = acc.inv();
            var i: usize = inputs.len;
            while (i > 0) {
                i -= 1;
                outputs[i] = outputs[i].mul(acc);
                acc = acc.mul(inputs[i]);
            }
        }

        /// Multi-scalar exponentiation: product(bases[i]^exponents[i]).
        /// Windowed Pippenger-style algorithm. ~10-50x faster than n individual pow calls.
        pub fn multiExp(
            bases: []const Self,
            exponents: []const u512,
            comptime window_bits: u4,
        ) Self {
            std.debug.assert(bases.len == exponents.len);
            std.debug.assert(window_bits >= 1 and window_bits <= 8);
            const window_size = @as(usize, 1) << window_bits;
            const mask: u512 = @as(u512, window_size - 1);
            const num_windows = (BITS + window_bits - 1) / window_bits;
            var buckets: [window_size]Self = undefined;
            var result = Self.one();
            var first = true;
            var w: usize = num_windows;
            while (w > 0) {
                w -= 1;
                if (!first) {
                    var sq: u4 = 0;
                    while (sq < window_bits) : (sq += 1) result = result.mul(result);
                }
                first = false;
                for (0..window_size) |j| buckets[j] = Self.one();
                for (bases, exponents) |base_, exp| {
                    const shift = w * window_bits;
                    // Extract window bits directly (O(1) vs previous O(shift) loop)
                    const window_val = @as(usize, @intCast((exp >> @intCast(shift)) & mask));
                    if (window_val != 0) buckets[window_val] = buckets[window_val].mul(base_);
                }
                // Pippenger: accumulate from high to low, skipping bucket 0
                var acc = Self.one();
                var j: usize = window_size;
                while (j > 1) {
                    j -= 1;
                    acc = acc.mul(buckets[j]);
                    result = result.mul(acc);
                }
            }
            return result;
        }

        /// Exponentiation. The exponent must fit in `PowExp` (512 bits) and be non-negative.
        /// Constant-time: iterates over all `BITS` exponent bits regardless of
        /// the value, using a constant-time limb select for the multiply step.
        /// WARNING: ~2x slower than square-and-multiply because every multiply is
        /// executed unconditionally. Use only when the exponent is secret.
        pub fn pow(self: Self, exp: anytype) Self {
            const T = @TypeOf(exp);
            const e: PowExp = blk: {
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
            while (i < BITS) : (i += 1) {
                const bit = ((e >> @intCast(i)) & 1) == 1;
                const m = result.mul(base);
                result = .{ .limbs = Mont.ctSelectLimbs(bit, m.limbs, result.limbs) };
                base = base.mul(base);
            }
            return result;
        }

        /// Fast exponentiation (NOT constant-time). ~2x faster than `pow`.
        /// Use when the exponent is public (e.g., FRI queries, roots of unity).
        pub fn powFast(self: Self, exp: anytype) Self {
            const T = @TypeOf(exp);
            const e: PowExp = blk: {
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

        // -- Predicates ---------------------------------------------------

        pub fn eq(self: Self, other: Self) bool {
            var diff: u64 = 0;
            for (self.limbs, other.limbs) |a, b| diff |= a ^ b;
            return diff == 0;
        }
        pub fn eql(self: Self, other: Self) bool {
            return self.eq(other);
        }
        pub fn isZero(self: Self) bool {
            var acc: u64 = 0;
            for (self.limbs) |l| acc |= l;
            return acc == 0;
        }
        pub fn isOne(self: Self) bool {
            return self.eq(Self.one());
        }

        /// Constant-time equality. No branches on secret data.
        pub fn eqCT(self: Self, other: Self) bool {
            var diff: u64 = 0;
            for (self.limbs, other.limbs) |a, b| diff |= a ^ b;
            return diff == 0;
        }

        /// Constant-time zero check. No branches on secret data.
        pub fn isZeroCT(self: Self) bool {
            var acc: u64 = 0;
            for (self.limbs) |l| acc |= l;
            return acc == 0;
        }

        /// Returns true if the canonical representative is > MODULUS/2.
        /// Uses limb-wise comparison. NOT constant-time (early-exit on MSB difference).
        pub fn isNegative(self: Self) bool {
            const half = Mont.MODULUS_LIMBS;
            // Add 1 to half (in-place, ignoring carry for simplicity)
            var half_plus_1 = half;
            half_plus_1[0] +%= 1;
            // Compare self.limbs >= half_plus_1
            return !Mont.ctLimbsCmpLt(&self.limbs, &half_plus_1);
        }

        /// Lexicographic comparison of canonical representatives (Montgomery form).
        /// Returns -1, 0, or 1. NOT constant-time.
        pub fn lexicographicCmp(self: Self, other: Self) i2 {
            var i: usize = NUM_LIMBS;
            while (i > 0) {
                i -= 1;
                if (self.limbs[i] < other.limbs[i]) return -1;
                if (self.limbs[i] > other.limbs[i]) return 1;
            }
            return 0;
        }

        /// Constant-time select: returns `a` if `on`, else `b`.
        pub fn ctSelect(on: bool, a: Self, b: Self) Self {
            return .{ .limbs = Mont.ctSelectLimbs(on, a.limbs, b.limbs) };
        }

        /// Securely zero the memory of this element.
        pub fn zeroize(self: *Self) void {
            @memset(std.mem.asBytes(self), 0);
        }

        // -- Advanced -----------------------------------------------------

        pub fn legendre(self: Self) i8 {
            return roots.legendre(Self, self);
        }
        pub fn isQuadraticResidue(self: Self) bool {
            return roots.isQuadraticResidue(Self, self);
        }
        pub fn sqrt(self: Self) ?Self {
            return roots.sqrt(Self, self);
        }

        /// Primitive `2^log_size`-th root of unity.
        pub fn primitiveRootOfUnity(log_size: usize) Self {
            return roots.primitiveRootOfUnity(Self, log_size);
        }

        /// `order`-th root of unity (`order` a power of two).
        pub fn rootOfUnity(order: usize) Self {
            return roots.rootOfUnity(Self, order);
        }

        /// Division: `self / other` = `self * other.inv()`.
        pub fn div(self: Self, other: Self) Self {
            std.debug.assert(!other.isZero());
            return self.mul(other.inv());
        }

        /// Hash for HashMap support.
        pub fn hash(self: Self) u64 {
            // FNV-1a hash of the canonical value
            var hash_val: u64 = 14695981039346656037;
            const canonical = Mont.fromMontgomery(self.limbs);
            for (canonical) |limb| {
                var v = limb;
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
            try writer.print("{}", .{self.toU512()});
        }
    };
}
