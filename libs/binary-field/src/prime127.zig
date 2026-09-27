// SPDX-License-Identifier: MIT OR Apache-2.0

//! A 128-bit prime field fixture, for exercising the **secure** `Sumcheck(F)`.
//!
//! `Prime31` in this directory is deliberately below `MIN_SAFE_BITS = 128`,
//! because a field small enough for an exact native-width oracle tops out at 31
//! bits. That is the whole reason this file exists: with the 31-bit fixture the
//! generalized Lagrange and folding arithmetic is exercised, but only through
//! `SumcheckUnsafe`, so **no test in this tree has ever run the secure entry
//! point with the generalized arithmetic.** See `docs/assert-ledger.md`, "The
//! size gate and native-width testability are in direct conflict", for why the
//! two requirements cannot both be met below 128 bits.
//!
//! ## Why BigInt is not needed
//!
//! A 128-bit prime's products need 256 bits, and `u256` is a native Zig type.
//! The only reason I reached for `zig-bigint` in the notes was the fear that the
//! reduction would be uncheckable. It is not: `p = 2^128 - 159`, so
//! `2^128 == 159 (mod p)`, and a product reduces in two rounds using that
//! identity alone.
//!
//! ## Primality is proved, not asserted
//!
//! A size gate does not imply primality, and this is not hypothetical:
//! `2^128 - 1` has bit length 128 and is composite, being
//! `(2^64 - 1)(2^64 + 1)`. Trial division cannot decide a 128-bit number, so
//! this file carries a **Pocklington certificate** instead:
//!
//! ```text
//! p       = 2^128 - 159
//! p - 1   = 2^5 * 3 * 10253 * 29333 * 4454477 * 42113237 * 62826870453001
//! F       = 42113237 * 62826870453001          (fully factored, F > sqrt(p))
//! a       = 2
//! ```
//!
//! with `a^(p-1) == 1 (mod p)` and `gcd(a^((p-1)/q) - 1, p) == 1` for each
//! prime `q | F`. Pocklington's theorem then forces `p` prime. The two factors
//! of `F` are checked by Miller-Rabin over the first thirteen primes, which is
//! deterministic well past 2^46. `certifyPrimality()` re-derives all of it
//! from the constant, so a wrong modulus is a test failure naming the failed
//! step rather than a silently non-field.
//!
//! The certificate is a **test**, not a `comptime` block: it costs a few
//! hundred 256-bit modular operations, which is a fine price for a test run and
//! a poor one for every compile of the library, ReleaseFast and wasm included.

const std = @import("std");

const testing = std.testing;

/// The modulus. 2^128 - 159: exactly 128 bits, and prime (see the certificate).
pub const PRIME: u128 = std.math.maxInt(u128) - 158; // == 2^128 - 159

/// `2^128 mod p`, the identity the reduction is built on.
const K: u128 = 159;

const MASK128: u128 = std.math.maxInt(u128);

// Pocklington certificate data. Changing any of these without changing PRIME
// is a compile error at the `certifyPrimality` call site, not a silent drift.
const POCKLINGTON_FACTORS = [_]u128{ 42113237, 62826870453001 };
const POCKLINGTON_BASE: u128 = 2;

fn reduce256(x: u256) u128 {
    // x == lo + hi * 2^128 == lo + hi * K (mod p)
    const hi: u256 = x >> 128;
    const lo: u256 = x & MASK128;
    const t: u256 = lo + hi * K;
    const hi2: u256 = t >> 128;
    const lo2: u256 = t & MASK128;
    var t2: u256 = lo2 + hi2 * K;
    // t2 < 2^128 + 2^8 * 159 < 2p, so at most one subtraction.
    if (t2 >= PRIME) t2 -= PRIME;
    return @intCast(t2);
}

fn mulmod128(a: u128, b: u128) u128 {
    return reduce256(@as(u256, a) * @as(u256, b));
}

fn powmod128(base_in: u128, e_in: u128) u128 {
    var result: u128 = 1;
    var b = base_in;
    var e = e_in;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) result = mulmod128(result, b);
        b = mulmod128(b, b);
    }
    return result;
}

/// Modular arithmetic for an *arbitrary* modulus below 2^64, used only by
/// `isPrimeSmall`.
///
/// This deliberately does NOT reuse `mulmod128`. That function reduces modulo
/// `PRIME`, so using it here would compute the Miller-Rabin powers modulo
/// `2^128 - 159` instead of modulo `n` -- the check would be exercising the
/// wrong modulus while looking entirely correct. It did, and the symptom was
/// `isPrime(97) == false`: every small prime "failed". Plain `u256` multiply
/// with a native remainder is exact below 2^64 and needs no cleverness.
fn mulmodSmall(a: u64, b: u64, m: u64) u64 {
    return @intCast((@as(u128, a) * @as(u128, b)) % m);
}

fn powmodSmall(base_in: u64, e_in: u64, m: u64) u64 {
    var result: u64 = 1 % m;
    var b = base_in % m;
    var e = e_in;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) result = mulmodSmall(result, b, m);
        b = mulmodSmall(b, b, m);
    }
    return result;
}

fn gcd128(a_in: u128, b_in: u128) u128 {
    var a = a_in;
    var b = b_in;
    while (b != 0) {
        const t = a % b;
        a = b;
        b = t;
    }
    return a;
}

/// Deterministic Miller-Rabin. The first thirteen primes are a proven
/// deterministic base set for every `n < 3_317_044_064_679_887_385_961_981`,
/// which is far above the 2^46 needed to certify `F`'s factors.
const MR_BASES = [_]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41 };

/// Miller-Rabin for `n < 2^64`. The first thirteen primes are a proven
/// deterministic base set for every `n < 3_317_044_064_679_887_385_961_981`,
/// comfortably above 2^64, so this decides primality exactly -- it is not a
/// probabilistic filter.
pub fn isPrimeSmall(n: u64) bool {
    if (n < 2) return false;
    for (MR_BASES) |b| {
        if (n == b) return true;
    }
    if (n % 2 == 0) return false;
    var d = n - 1;
    var s: u6 = 0;
    while (d % 2 == 0) {
        d /= 2;
        s += 1;
    }
    for (MR_BASES) |b| {
        var x = powmodSmall(b, d, n);
        if (x == 1 or x == n - 1) continue;
        var is_composite = true;
        var r: u6 = 1;
        while (r < s) : (r += 1) {
            x = mulmodSmall(x, x, n);
            if (x == n - 1) {
                is_composite = false;
                break;
            }
        }
        if (is_composite) return false;
    }
    return true;
}

/// Re-derive the primality of `PRIME` from the constant itself, naming the step
/// that fails. Returns the reason as an enum so a test can report it.
pub const Certificate = enum { ok, modulus_not_128_bits, factor_missing, factor_composite, factored_part_too_small, base_not_in_subgroup, gcd_not_one };

pub fn certifyPrimality() Certificate {
    if (@bitSizeOf(u128) != 128) return .modulus_not_128_bits;
    if (@bitSizeOf(u128) - @clz(PRIME) != 128) return .modulus_not_128_bits;

    // F must be a fully factored divisor of p-1 exceeding sqrt(p).
    var f: u128 = 1;
    for (POCKLINGTON_FACTORS) |q| {
        if (q < 2) return .factor_composite;
        if (!isPrimeSmall(@intCast(q))) return .factor_composite;
        if ((PRIME - 1) % q != 0) return .factor_missing;
        f *= q;
    }
    // F > sqrt(p), compared in u256 because F is 72 bits and F^2 is 144.
    if (@as(u256, f) * @as(u256, f) <= PRIME) return .factored_part_too_small;

    const a = POCKLINGTON_BASE;
    if (a % PRIME == 0) return .base_not_in_subgroup;
    if (powmod128(a, PRIME - 1) != 1) return .base_not_in_subgroup;
    for (POCKLINGTON_FACTORS) |q| {
        const e = (PRIME - 1) / q;
        const x = powmod128(a, e);
        if (gcd128(if (x == 0) PRIME else x - 1, PRIME) != 1) return .gcd_not_one;
    }
    return .ok;
}

/// The field under test.
pub const Prime127 = struct {
    const Self = @This();

    value: u128,

    pub const MODULUS: u128 = PRIME;
    pub const BITS: u16 = 128;
    /// Must equal `NUM_BYTES`: the sum-check transcript feeds `fromBytes` a
    /// `SIZE`-wide buffer.
    pub const NUM_BYTES: usize = 16;
    pub const SIZE: usize = 16;
    pub const PRIME_FIELD = true;

    pub fn zero() Self {
        return .{ .value = 0 };
    }
    pub fn one() Self {
        return .{ .value = 1 };
    }
    /// Accepts a signed or unsigned comptime integer. Negative values are
    /// interpreted modulo `p`, as a field requires.
    pub fn fromInt(x: anytype) Self {
        const T = @TypeOf(x);
        const info = @typeInfo(T);
        if (info == .comptime_int) {
            if (x < 0) return .{ .value = reduce256(@as(u256, PRIME) - @as(u256, @as(u128, @intCast(-x)))) };
            return .{ .value = reduce256(@as(u256, @intCast(x))) };
        }
        if (info == .int and info.int.signedness == .signed) {
            const v: i128 = @intCast(x);
            if (v < 0) return .{ .value = reduce256(@as(u256, PRIME) - @as(u256, @as(u128, @intCast(-v)))) };
            return .{ .value = reduce256(@as(u256, @as(u128, @intCast(v)))) };
        }
        return .{ .value = reduce256(@as(u256, @as(u128, @intCast(x)))) };
    }
    pub fn toInt(self: Self) u128 {
        return self.value;
    }

    pub fn add(a: Self, b: Self) Self {
        return .{ .value = reduce256(@as(u256, a.value) + @as(u256, b.value)) };
    }
    pub fn sub(a: Self, b: Self) Self {
        return .{ .value = reduce256(@as(u256, a.value) + @as(u256, PRIME) - @as(u256, b.value)) };
    }
    pub fn neg(a: Self) Self {
        return sub(zero(), a);
    }
    pub fn mul(a: Self, b: Self) Self {
        return .{ .value = mulmod128(a.value, b.value) };
    }
    pub fn sqr(a: Self) Self {
        return mul(a, a);
    }

    /// Legacy total inverse: `inv(0) == zero()`. Zero is not an inverse.
    pub fn inv(a: Self) Self {
        if (a.isZero()) return zero();
        return pow(a, PRIME - 2);
    }

    /// # Errors
    /// `error.InverseOfZero` when `a` is zero.
    pub fn invChecked(a: Self) error{InverseOfZero}!Self {
        if (a.isZero()) return error.InverseOfZero;
        return pow(a, PRIME - 2);
    }

    /// Legacy total division: `x / 0 == zero()`.
    pub fn div(a: Self, b: Self) Self {
        return mul(a, b.inv());
    }

    /// # Errors
    /// `error.InverseOfZero` when `b` is zero.
    pub fn divChecked(a: Self, b: Self) error{InverseOfZero}!Self {
        return mul(a, try b.invChecked());
    }

    pub fn pow(base_in: Self, e_in: u128) Self {
        return .{ .value = powmod128(base_in.value, e_in) };
    }

    pub fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
    }
    pub fn eq(a: Self, b: Self) bool {
        return a.value == b.value;
    }
    pub fn isZero(a: Self) bool {
        return a.value == 0;
    }

    pub fn toBytes(self: Self, out: []u8) void {
        std.mem.writeInt(u128, out[0..16], self.value, .big);
        @memset(out[16..], 0);
    }

    /// Total, as the field contract requires: the sum-check transcript decoder
    /// calls this without a `try`, because over GF(2^m) every bit string is a
    /// valid element. A prime field does not have that property, so this is
    /// lossy; `fromBytesChecked` is the variant that refuses.
    pub fn fromBytes(bytes: [NUM_BYTES]u8) Self {
        const v = std.mem.readInt(u128, bytes[0..16], .big);
        return .{ .value = if (v >= PRIME) v % PRIME else v };
    }

    /// # Errors
    /// `error.NotCanonical` when the encoding is `>= PRIME`.
    pub fn fromBytesChecked(bytes: [NUM_BYTES]u8) error{NotCanonical}!Self {
        const v = std.mem.readInt(u128, bytes[0..16], .big);
        if (v >= PRIME) return error.NotCanonical;
        return .{ .value = v };
    }

    pub fn encode(self: Self) [NUM_BYTES]u8 {
        var out: [NUM_BYTES]u8 = undefined;
        self.toBytes(&out);
        return out;
    }

    pub fn random(rand: std.Random) Self {
        return .{ .value = @intCast(rand.intRangeLessThan(u128, 0, PRIME)) };
    }

    pub fn isBelowSecureThreshold() bool {
        return BITS < 128;
    }

    pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}", .{self.value});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "isPrimeSmall is pinned by known primes and known composites" {
    // The gate for the gate. A primality test that has only ever been run on
    // the one constant it exists to certify has never been shown to reject
    // anything, and the first version of this one computed modulo the wrong
    // prime: it reported every small prime as composite and looked perfectly
    // plausible. Known-good and known-bad inputs, both directions.
    const primes = [_]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 97, 42113237, 62826870453001, 18446744073709551557 };
    for (primes) |n| {
        testing.expect(isPrimeSmall(n)) catch |e| {
            std.debug.print("isPrimeSmall({d}) should be true\n", .{n});
            return e;
        };
    }
    // Carmichael numbers are the composites Miller-Rabin most often survives.
    const composites = [_]u64{ 0, 1, 4, 9, 25, 49, 561, 1105, 1729, 2465, 2821, 6601, 8911, 42113238 };
    for (composites) |n| {
        testing.expect(!isPrimeSmall(n)) catch |e| {
            std.debug.print("isPrimeSmall({d}) should be false\n", .{n});
            return e;
        };
    }
}

test "the modulus is prime, proved by a Pocklington certificate" {
    switch (certifyPrimality()) {
        .ok => {},
        else => |e| {
            std.debug.print("Pocklington certificate failed at: {s}\n", .{@tagName(e)});
            return error.PrimalityCertificateFailed;
        },
    }
    // The counterexample that makes this load-bearing rather than decorative:
    // 2^128 - 1 clears a BITS >= 128 gate and is composite.
    const mersenne_128: u128 = std.math.maxInt(u128);
    try testing.expectEqual(@as(usize, 128), @bitSizeOf(u128) - @clz(mersenne_128));
    const a: u128 = (@as(u128, 1) << 64) - 1;
    const b: u128 = (@as(u128, 1) << 64) + 1;
    try testing.expect(mersenne_128 / a == b);
}

test "the reduction agrees with a native u256 modulus, which is a different algorithm" {
    var prng = std.Random.DefaultPrng.init(0x9E3779B9);
    const rand = prng.random();
    for (0..5000) |_| {
        const av = rand.intRangeLessThan(u128, 0, PRIME);
        const bv = rand.intRangeLessThan(u128, 0, PRIME);
        const a = Prime127{ .value = av };
        const b = Prime127{ .value = bv };

        // The field reduces with `2^128 == 159 (mod p)`. The oracle reduces with
        // a native u256 remainder. Two different algorithms, so agreement is
        // evidence rather than tautology.
        try testing.expectEqual(@as(u128, @intCast((@as(u256, av) * @as(u256, bv)) % PRIME)), a.mul(b).value);
        try testing.expectEqual(@as(u128, @intCast((@as(u256, av) + @as(u256, bv)) % PRIME)), a.add(b).value);
        try testing.expectEqual(@as(u128, @intCast((@as(u256, av) + PRIME - @as(u256, bv)) % PRIME)), a.sub(b).value);

        if (!a.isZero()) {
            try testing.expectEqual(@as(u128, 1), a.mul(a.inv()).value);
            try testing.expectEqual(@as(u128, 1), (try a.invChecked()).mul(a).value);
        }
    }
}

test "sub and add differ in Prime127, which is the whole point" {
    const a = Prime127.fromInt(5);
    const b = Prime127.fromInt(3);
    try testing.expect(a.sub(b).eql(Prime127.fromInt(2)));
    try testing.expect(!a.add(b).eql(a.sub(b)));
    // wrap-around, where char 2 and a prime agree by accident
    try testing.expect(Prime127.one().sub(Prime127.fromInt(2)).eql(Prime127.fromInt(PRIME - 1)));
}

test "Prime127 encoding round-trips and rejects non-canonical" {
    var prng = std.Random.DefaultPrng.init(11);
    const rand = prng.random();
    for (0..500) |_| {
        const a = Prime127.random(rand);
        try testing.expectEqual(a.toInt(), Prime127.fromBytes(a.encode()).toInt());
        try testing.expectEqual(a.toInt(), (try Prime127.fromBytesChecked(a.encode())).toInt());
    }
    const p_bytes = (Prime127{ .value = PRIME }).encode();
    try testing.expectError(error.NotCanonical, Prime127.fromBytesChecked(p_bytes));
}

// ============================================================================
// The witness: the secure entry point, exercised with generalized arithmetic
// ============================================================================

const sumcheck = @import("sumcheck.zig");
const polynomial = @import("polynomial.zig");
const pcs = @import("pcs.zig");

const ML = polynomial.Multilinear(Prime127);
const SC = sumcheck.Sumcheck(Prime127);

test "the secure Sumcheck accepts this field, unlike the 31-bit one" {
    // The whole reason this file exists. `Sumcheck(Prime31)` returns
    // error.FieldTooSmall; `Sumcheck(Prime127)` must not, so the generalized
    // arithmetic runs through the sound entry point for the first time.
    try testing.expect(SC.MIN_SAFE_BITS <= Prime127.BITS);
    try testing.expect(!Prime127.isBelowSecureThreshold());

    const alloc = testing.allocator;
    const tables = [_][]const Prime127{
        &.{ Prime127.fromInt(3), Prime127.fromInt(7) },
    };
    var proof = try SC.prove(alloc, 1, &tables);
    defer proof.deinit(alloc);
    try testing.expect(try SC.verify(alloc, 1, &tables, proof));
}

test "the generalized Lagrange arithmetic round-trips over this field" {
    const alloc = testing.allocator;
    // f(x) = 3 + 5x at the points 1, 2, 3. Over a binary field this would be
    // indistinguishable from 3 - 5x; here the sign is observable.
    const points = [_]Prime127{ Prime127.fromInt(1), Prime127.fromInt(2), Prime127.fromInt(3) };
    const values = [_]Prime127{ Prime127.fromInt(8), Prime127.fromInt(13), Prime127.fromInt(18) };
    const coeffs = try SC.interpolateCoeffs(alloc, &points, &values);
    defer alloc.free(coeffs);
    try testing.expectEqual(@as(u128, 3), coeffs[0].toInt());
    try testing.expectEqual(@as(u128, 5), coeffs[1].toInt());
    for (points, values) |p, v| {
        var acc = coeffs[coeffs.len - 1];
        var i = coeffs.len - 1;
        while (i > 0) {
            i -= 1;
            acc = acc.mul(p).add(coeffs[i]);
        }
        try testing.expectEqual(v.toInt(), acc.toInt());
    }
}

test "the generalized multilinear fold is exercised over this field" {
    const alloc = testing.allocator;
    const table = [_]Prime127{
        Prime127.fromInt(1), Prime127.fromInt(2), Prime127.fromInt(4), Prime127.fromInt(8),
    };
    const r = [_]Prime127{ Prime127.fromInt(3), Prime127.fromInt(5) };
    const got = try polynomial.fromEvals(Prime127, &table).eval(alloc, &r);

    // Two folds, (1 - r_i)*a + r_i*b, in plain u256 arithmetic.
    const step = struct {
        fn f(av: u128, bv: u128, rv: u128) u128 {
            const p: u256 = PRIME;
            const one_minus: u256 = (p + 1 -% @as(u256, rv)) % p;
            return @intCast((one_minus * @as(u256, av) + @as(u256, rv) * @as(u256, bv)) % p);
        }
    }.f;
    const lo = step(1, 2, 3);
    const hi = step(4, 8, 3);
    try testing.expectEqual(step(lo, hi, 5), got.toInt());

    // The characteristic-2 form gives a different answer, which is what makes
    // this a witness. Discriminator: 2*r_i, non-zero here, identically 0 in
    // characteristic 2.
    const char2 = struct {
        fn f(av: u128, bv: u128, rv: u128) u128 {
            const p: u256 = PRIME;
            return @intCast((@as(u256, av) + @as(u256, rv) * (@as(u256, av) + @as(u256, bv))) % p);
        }
    }.f;
    const c_lo = char2(1, 2, 3);
    const c_hi = char2(4, 8, 3);
    try testing.expect(char2(c_lo, c_hi, 5) != got.toInt());
}

test "the fold this file exists to exercise is not the characteristic-2 fold" {
    // The gate for the gate. `Sumcheck` used to fold with
    // `a + t*(a + b)`, which is the characteristic-2 identity and, over this
    // field, a *different kernel* from the one the verifier closes on. Nothing
    // in `binary-field` could see that: every field in the package is char 2,
    // where the two forms are the same expression. This is the assertion that
    // makes the difference observable, so putting the char-2 form back fails
    // here instead of passing silently.
    const a = Prime127.fromInt(3);
    const b = Prime127.fromInt(7);
    const t = Prime127.fromInt(5);

    const linear: u128 = a.mul(Prime127.one().sub(t)).add(b.mul(t)).toInt();
    const char2: u128 = a.add(t.mul(a.add(b))).toInt();
    try testing.expect(linear != char2);

    // And the linear form is the one that matches plain arithmetic.
    const p: u256 = PRIME;
    const one_minus_t: u256 = (p + 1 -% @as(u256, t.toInt())) % p;
    const expected = @as(u128, @intCast((one_minus_t * @as(u256, a.toInt()) +
        @as(u256, t.toInt()) * @as(u256, b.toInt())) % p));
    try testing.expectEqual(expected, linear);
}

test "a tampered claimed sum is rejected as false, not as an error" {
    const alloc = testing.allocator;
    const tables = [_][]const Prime127{&.{ Prime127.fromInt(3), Prime127.fromInt(7) }};
    var proof = try SC.prove(alloc, 1, &tables);
    defer proof.deinit(alloc);

    // The honest proof must verify first, otherwise `false` below would be
    // indistinguishable from a verifier that rejects everything.
    try testing.expect(try SC.verify(alloc, 1, &tables, proof));

    proof.claimed_sum = proof.claimed_sum.add(Prime127.one());
    const ok = try SC.verify(alloc, 1, &tables, proof);
    try testing.expect(!ok);
}

test "a tampered round polynomial is rejected as false" {
    const alloc = testing.allocator;
    const tables = [_][]const Prime127{&.{ Prime127.fromInt(3), Prime127.fromInt(7) }};
    var proof = try SC.prove(alloc, 1, &tables);
    defer proof.deinit(alloc);
    try testing.expect(try SC.verify(alloc, 1, &tables, proof));

    // rounds[0] is the univariate s_0(t); perturbing one coefficient breaks the
    // round consistency equation the verifier recomputes.
    var coeffs = try alloc.dupe(Prime127, proof.rounds[0]);
    defer alloc.free(coeffs);
    coeffs[0] = coeffs[0].add(Prime127.one());
    const tampered = SC.Proof{ .claimed_sum = proof.claimed_sum, .rounds = &.{coeffs} };
    try testing.expect(!try SC.verify(alloc, 1, &tables, tampered));
}

test "a wrong table length is a typed domain error, distinct from a false" {
    const alloc = testing.allocator;
    // 3 elements cannot be a 2-variable table, so this is a caller error and
    // must not be reported as a forged proof.
    const bad = [_][]const Prime127{&.{ Prime127.fromInt(1), Prime127.fromInt(2), Prime127.fromInt(3) }};
    const good = [_][]const Prime127{&.{ Prime127.fromInt(1), Prime127.fromInt(2) }};
    var proof = try SC.prove(alloc, 1, &good);
    defer proof.deinit(alloc);
    try testing.expectError(error.InvalidTableLength, SC.verify(alloc, 1, &bad, proof));
}
