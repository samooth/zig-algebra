// SPDX-License-Identifier: MIT OR Apache-2.0

//! A small prime field fixture, for exercising code paths that the binary-field
//! test matrix cannot reach on its own.
//!
//! `Sumcheck(F)`, `MlePcs(F, E)` and `CommittedMlePcs(F, E)` require
//! `F.BITS >= 128`, and every field this workspace instantiates over is binary,
//! so the Lagrange and folding arithmetic in `sumcheck.zig`, `pack.zig` and
//! `polynomial.zig` has only ever run where `sub` is literally `add`. Those
//! expressions were written as `add` because in characteristic 2 `a - b == a + b`
//! is a law, not a coincidence -- which is exactly the situation where a
//! transcription error is invisible. A prime field is what makes the difference
//! observable.
//!
//! **This fixture is below `MIN_SAFE_BITS`, and that is forced.** 31 bits is what
//! leaves products inside `u64`, so the reference below is exact rather than a
//! second copy of the same technique. A 128-bit prime would need 256-bit
//! products, at which point the "independent" oracle is a `u256` reduction or a
//! second Montgomery implementation -- not independent. So any field small
//! enough to witness exactly is below the secure threshold, and this one enters
//! through `SumcheckUnsafe`. What it establishes is that the arithmetic is
//! characteristic-agnostic; what it does not establish is the secure entry
//! point's behaviour, which no fixture in this tree can reach. See
//! `docs/assert-ledger.md`, "The size gate and native-width testability are in
//! direct conflict".
//!
//! Two properties make the fixture trustworthy rather than merely present:
//!
//! 1. **The modulus is proved prime at comptime**, not asserted in a comment.
//!    This is not extra paranoia. `2^128 - 1` has bit length 128, so it clears
//!    a `BITS >= 128` check, and it is composite:
//!    `2^128 - 1 == (2^64 - 1)(2^64 + 1)`. A fixture built on it would sail
//!    through every size gate and be nonsense downstream. The primality check
//!    below is exact trial division, not a probabilistic test, so a wrong
//!    constant is a compile error.
//!
//! 2. **The field is checked against an independent oracle** before it is used
//!    as a substrate for anything. `u64` reference arithmetic modulo the prime
//!    is a different implementation with a different failure mode; agreeing
//!    with it is evidence, where agreeing with itself is not. This is the same
//!    differential harness used against `zig-bigint`, applied locally.

const std = @import("std");

const testing = std.testing;

/// A prime modulus. 2^31 - 1 (Mersenne) is the largest Mersenne prime that
/// leaves headroom in `u64` for products, which keeps the oracle below exact.
pub const PRIME: u64 = 2147483647;

comptime {
    // Exact trial division: 2 is ruled out by the constant, then every odd
    // divisor up to sqrt(PRIME). sqrt(2^31 - 1) is about 46341, so this is
    // ~23000 divisions at compile time, and a composite constant is a
    // compile error rather than a field that quietly does not exist.
    assertPrime(PRIME);
}

fn assertPrime(n: u64) void {
    // The quota has to be raised here rather than at the call site: each
    // comptime evaluation of this function starts with the default budget.
    @setEvalBranchQuota(100_000_000);
    if (n < 2) @compileError("PRIME must be >= 2");
    if (n % 2 == 0) {
        if (n != 2) @compileError("PRIME is even, so it is composite");
    }
    var d: u64 = 3;
    while (d * d <= n) : (d += 2) {
        if (n % d == 0) @compileError("PRIME has a nontrivial factor, so it is composite");
    }
}

/// Reference arithmetic in plain `u64`, independent of the field's reduction.
const Ref = struct {
    const Self = @This();

    value: u64,

    fn one() Self {
        return .{ .value = 1 };
    }
    fn init(x: u64) Self {
        return .{ .value = x % PRIME };
    }
    fn add(a: Self, b: Self) Self {
        const s = a.value +% b.value;
        return .{ .value = if (s >= PRIME) s - PRIME else s };
    }
    fn sub(a: Self, b: Self) Self {
        return .{ .value = if (a.value >= b.value) a.value - b.value else a.value + PRIME - b.value };
    }
    fn mul(a: Self, b: Self) Self {
        return .{ .value = (a.value * b.value) % PRIME };
    }
    fn inv(a: Self) Self {
        // Fermat: a^(p-2) mod p. a = 0 has no inverse, which is the case the
        // checked variant must report.
        if (a.value == 0) return .{ .value = 0 };
        return pow(a, PRIME - 2);
    }
    fn neg(a: Self) Self {
        return sub(.{ .value = 0 }, a);
    }
    fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
    }
    fn isZero(a: Self) bool {
        return a.value == 0;
    }

    fn pow(base_in: Self, e_in: u64) Self {
        var result: Self = .{ .value = 1 };
        var b = base_in;
        var e = e_in;
        while (e > 0) : (e >>= 1) {
            if (e & 1 == 1) result = mul(result, b);
            b = mul(b, b);
        }
        return result;
    }
};

/// The field under test: the same 2^31-1 modulus, reduced by an independent
/// route from `Ref` (Mersenne fold `lo + hi` rather than `%`), so agreement
/// between the two is evidence rather than tautology.
pub const Prime31 = struct {
    const Self = @This();

    value: u64,

    pub const MODULUS: u64 = PRIME;
    pub const NUM_BYTES: usize = 4;
    /// Transcript buffer width for one element; the sum-check decoder feeds
    /// `fromBytes` a `SIZE`-wide buffer, so it has to match `NUM_BYTES`.
    pub const SIZE: usize = 4;
    pub const BITS: u16 = 31;
    pub const PRIME_FIELD = true;

    pub fn zero() Self {
        return .{ .value = 0 };
    }
    pub fn one() Self {
        return .{ .value = 1 };
    }
    pub fn fromInt(x: anytype) Self {
        const v: u64 = @intCast(@as(u128, @abs(@as(i128, @intCast(x)))) % @as(u128, PRIME));
        return .{ .value = v };
    }
    pub fn toInt(self: Self) u64 {
        return self.value;
    }

    pub fn add(a: Self, b: Self) Self {
        return .{ .value = (a.value +% b.value) % PRIME };
    }
    pub fn sub(a: Self, b: Self) Self {
        // The operation under test. In characteristic 2 this would be
        // `a.add(b)`, which is why every expression here used to be written
        // with `add` and why a prime field is needed to notice a mistake.
        return .{ .value = (a.value +% PRIME -% b.value) % PRIME };
    }
    pub fn neg(a: Self) Self {
        return sub(zero(), a);
    }
    pub fn mul(a: Self, b: Self) Self {
        // Mersenne fold: for 2^31 - 1, x*y == lo + hi*(2^31 - 1) * 2.
        const prod: u64 = a.value *% b.value;
        const lo = prod & PRIME;
        const hi = prod >> 31;
        return .{ .value = (lo +% hi) % PRIME };
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

    pub fn pow(base_in: Self, e_in: u64) Self {
        var result = one();
        var b = base_in;
        var e = e_in;
        while (e > 0) : (e >>= 1) {
            if (e & 1 == 1) result = mul(result, b);
            b = mul(b, b);
        }
        return result;
    }

    pub fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
    }
    pub fn isZero(a: Self) bool {
        return a.value == 0;
    }
    pub fn sqr(a: Self) Self {
        return mul(a, a);
    }

    /// Big-endian encoding into a caller buffer, the shape `zig-field` uses and
    /// the one the sum-check transcript expects.
    pub fn toBytes(self: Self, out: []u8) void {
        std.mem.writeInt(u32, out[0..4], @intCast(self.value), .big);
        @memset(out[4..], 0);
    }

    /// 2^31 - 1 has BITS == 31, which is below the secure `Sumcheck` threshold.
    /// Recorded on the type so the reason the tests use the Unsafe variant is
    /// visible from the fixture rather than from a comment elsewhere.
    pub fn isBelowSecureThreshold() bool {
        return BITS < 128;
    }

    pub fn eq(a: Self, b: Self) bool {
        return a.value == b.value;
    }

    /// Total, as the field contract requires: the sum-check transcript decoder
    /// calls this without a `try`, because over GF(2^m) every bit string is a
    /// valid element. A prime field does not have that property, and the total
    /// form is therefore *lossy* here -- an encoding `>= PRIME` cannot be
    /// rejected on this path. `fromBytesChecked` is the variant that refuses
    /// it, and the round-trip test below is what establishes that the lossy
    /// path is never reached with a non-canonical value in this fixture.
    pub fn fromBytes(bytes: [NUM_BYTES]u8) Self {
        return .{ .value = @as(u64, std.mem.readInt(u32, bytes[0..4], .big)) % PRIME };
    }

    /// # Errors
    /// `error.NotCanonical` when the encoding is `>= PRIME`.
    pub fn fromBytesChecked(bytes: [NUM_BYTES]u8) error{NotCanonical}!Self {
        const v = std.mem.readInt(u32, bytes[0..4], .big);
        if (v >= PRIME) return error.NotCanonical;
        return .{ .value = v };
    }

    pub fn encode(self: Self) [NUM_BYTES]u8 {
        var out: [NUM_BYTES]u8 = undefined;
        self.toBytes(&out);
        return out;
    }

    pub fn random(rand: std.Random) Self {
        return .{ .value = rand.intRangeLessThan(u64, 0, PRIME) };
    }

    /// Present so this type can stand in wherever a `BinaryField` is expected.
    /// GF(2^m) arithmetic is *not* emulated: the flag makes any attempt to
    /// confuse the two fail loudly rather than silently.
    pub fn isBinaryField() bool {
        return false;
    }

    pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}", .{self.value});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "the fixture modulus is prime, and the size gate would not have caught a bad one" {
    // 2^31 - 1 is prime; the comptime check in this file is what established
    // that, and it is what would reject a wrong constant.
    comptime assertPrime(PRIME);
    try testing.expectEqual(@as(usize, 31), @bitSizeOf(u64) - @clz(PRIME));

    // The counterexample that makes the primality check load-bearing rather
    // than decorative: 2^128 - 1 clears a BITS >= 128 gate and is composite.
    const mersenne_128: u128 = std.math.maxInt(u128); // == 2^128 - 1
    try testing.expectEqual(@as(usize, 128), @bitSizeOf(u128) - @clz(mersenne_128));
    try testing.expect(mersenne_128 % ((@as(u128, 1) << 64) - 1) == 0);
    try testing.expect(mersenne_128 % ((@as(u128, 1) << 64) + 1) == 0);
}

test "Prime31 agrees with an independent u64 oracle" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    for (0..4000) |_| {
        const av = rand.intRangeLessThan(u64, 0, PRIME);
        const bv = rand.intRangeLessThan(u64, 0, PRIME);
        const a = Prime31.fromInt(av);
        const b = Prime31.fromInt(bv);
        const ra = Ref.init(av);
        const rb = Ref.init(bv);

        // `sub` is the operation the whole exercise is about.
        try testing.expectEqual(ra.sub(rb).value, a.sub(b).toInt());
        try testing.expect(Ref.add(ra, rb).eql(Ref.init(a.add(b).toInt())));
        try testing.expect(Ref.mul(ra, rb).eql(Ref.init(a.mul(b).toInt())));
        try testing.expect(Ref.neg(ra).eql(Ref.init(a.neg().toInt())));
        if (!a.isZero()) {
            try testing.expect(Ref.mul(ra, ra.inv()).eql(Ref.init(1)));
            try testing.expectEqual(@as(u64, 1), (try a.invChecked()).mul(a).toInt());
        }
        try testing.expect(Ref.add(ra, rb).sub(ra).eql(rb));
    }
}

test "sub and add differ in Prime31, which is the whole point" {
    // If this fails, the fixture has stopped being a witness for the
    // characteristic-2 accident it exists to detect.
    const a = Prime31.fromInt(5);
    const b = Prime31.fromInt(3);
    try testing.expect(a.sub(b).eql(Prime31.fromInt(2)));
    try testing.expect(!a.add(b).eql(a.sub(b)));
    // wrap-around, where char 2 and a prime field agree by accident
    const small = Prime31.fromInt(1);
    try testing.expect(small.sub(Prime31.fromInt(2)).eql(Prime31.fromInt(PRIME - 1)));
}

test "Prime31 encoding round-trips and rejects non-canonical" {
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    for (0..500) |_| {
        const a = Prime31.random(rand);
        try testing.expectEqual(a.toInt(), Prime31.fromBytes(a.encode()).toInt());
        try testing.expectEqual(a.toInt(), (try Prime31.fromBytesChecked(a.encode())).toInt());
    }
    const p_bytes = (Prime31{ .value = PRIME }).encode();
    try testing.expectError(error.NotCanonical, Prime31.fromBytesChecked(p_bytes));
    // The total form reduces instead of failing, which is the documented
    // divergence from the binary-field contract.
    try testing.expectEqual(@as(u64, 0), Prime31.fromBytes(p_bytes).toInt());
}

// ============================================================================
// The witness: the same code paths over a field where sub is not add
// ============================================================================

const pack = @import("pack.zig");
const polynomial = @import("polynomial.zig");
const sumcheck = @import("sumcheck.zig");

const ML = polynomial.Multilinear(Prime31);
const Packed = pack.PackedMle(Prime31);
const SC = sumcheck.SumcheckUnsafe(Prime31);

// Multilinear evaluation at a point. Over a binary field `(1 - r)*a + r*b` and
// `a + r*(a + b)` are the same expression, so a transcription error in either is
// invisible. Over a prime field they differ on the first value that is not 0
// or 1, which is what makes this a witness rather than a smoke test.
test "witness: Multilinear.eval folds with (1 - r_i)*a + r_i*b" {
    const a = testing.allocator;
    // f(x0, x1) = x0 + 2*x1, evaluated at (3, 1) -> 3 + 2*1 = 5.
    const evals = [_]Prime31{
        Prime31.fromInt(0), Prime31.fromInt(1), Prime31.fromInt(2), Prime31.fromInt(3),
    };
    try testing.expectEqual(@as(u64, 5), (try polynomial.fromEvals(Prime31, &evals).eval(a, &.{ Prime31.fromInt(3), Prime31.one() })).toInt());

    // And a point where the char-2 identity would give a different answer:
    // at (2, 0) a char-2 fold yields a + r*(a + b) with a=0, b=1, r=2.
    // A point where the two forms genuinely diverge. The discriminant between
    // `a + r*(a + b)` and `(1 - r)*a + r*b` is 2*r*a, which vanishes in
    // characteristic 2 and is non-zero here for r, a != 0. The table has
    // f(0,0) = 1, so the first fold has a = 1.
    const table = [_]Prime31{
        Prime31.fromInt(1), Prime31.fromInt(2), Prime31.fromInt(4), Prime31.fromInt(8),
    };
    const rv = [_]u64{ 3, 5 };
    const r = [_]Prime31{ Prime31.fromInt(3), Prime31.fromInt(5) };
    const got = try polynomial.fromEvals(Prime31, &table).eval(a, &r);

    // Two folds, laid out as the hypercube table: [f(0,0) f(1,0) f(0,1) f(1,1)],
    // low index is the fast-varying variable.
    const general_step = struct {
        fn f(av: u64, bv: u64, rv_: u64) u64 {
            const rr = Ref.init(rv_);
            return Ref.one().sub(rr).mul(Ref.init(av)).add(rr.mul(Ref.init(bv))).value;
        }
    }.f;
    const char2_step = struct {
        fn f(av: u64, bv: u64, rv_: u64) u64 {
            return Ref.init(av).add(Ref.init(rv_).mul(Ref.init(av).add(Ref.init(bv)))).value;
        }
    }.f;

    var g_cur = [_]u64{ 1, 2, 4, 8 };
    var c_cur = [_]u64{ 1, 2, 4, 8 };
    for (rv) |r_i| {
        var gn: [2]u64 = undefined;
        var cn: [2]u64 = undefined;
        for (0..2) |i| {
            gn[i] = general_step(g_cur[2 * i], g_cur[2 * i + 1], r_i);
            cn[i] = char2_step(c_cur[2 * i], c_cur[2 * i + 1], r_i);
        }
        g_cur = .{ gn[0], gn[1], 0, 0 };
        c_cur = .{ cn[0], cn[1], 0, 0 };
    }

    // The two forms disagree on this input, which is what makes the fixture a
    // witness rather than a smoke test: over GF(2^m) both would be 3 and the
    // distinction could not exist.
    try testing.expect(g_cur[0] != c_cur[0]);
    try testing.expectEqual(g_cur[0], got.toInt());
    try testing.expect(Prime31.fromInt(c_cur[0]).toInt() != got.toInt());
}

test "witness: Multilinear.extend folds with (1 - r_i)*a + r_i*b" {
    const a = testing.allocator;
    // f(x0,x1) = x0 + 2*x1; fixing x0 = 3 leaves the table of f(3, x1).
    const evals = [_]Prime31{
        Prime31.fromInt(0), Prime31.fromInt(1), Prime31.fromInt(2), Prime31.fromInt(3),
    };
    // The table convention is fixed by polynomial.zig's own test vector, which
    // documents f(x0,x1) = x0 + 2*x1 and that fixing x0 = 3 leaves
    // [3, 3+2]. Reproducing that here keeps the two from drifting apart.
    const out = try polynomial.fromEvals(Prime31, &evals).extend(a, &.{Prime31.fromInt(3)});
    defer a.free(out);
    try testing.expectEqualSlices(Prime31, &.{ Prime31.fromInt(3), Prime31.fromInt(5) }, out);
}

test "witness: interpolateCoeffs builds the Lagrange basis with x_i - x_j" {
    const a = testing.allocator;
    // Interpolate f(x) = 3 + 5x at the points 1, 2, 3 and evaluate back.
    const points = [_]Prime31{ Prime31.fromInt(1), Prime31.fromInt(2), Prime31.fromInt(3) };
    const values = [_]Prime31{ Prime31.fromInt(8), Prime31.fromInt(13), Prime31.fromInt(18) };
    const coeffs = try SC.interpolateCoeffs(a, &points, &values);
    defer a.free(coeffs);

    for (points, values) |p, v| {
        // Horner
        var acc = coeffs[coeffs.len - 1];
        var i = coeffs.len - 1;
        while (i > 0) {
            i -= 1;
            acc = acc.mul(p).add(coeffs[i]);
        }
        try testing.expectEqual(v.toInt(), acc.toInt());
    }
}

test "witness: PackedMle is characteristic-2 specific, and the fixture shows it" {
    const a = testing.allocator;
    const k: u8 = 3;
    var table: [8]Prime31 = undefined;
    for (&table, 0..) |*t, i| {
        t.* = Prime31.fromInt(@as(u64, i) * 7 + 2);
    }
    const coeffs = try Packed.interpolate(a, k, &table);
    defer a.free(coeffs);
    try testing.expectEqual(@as(usize, 8), coeffs.len);

    // `PackedMle.interpolate` documents that the reconstruction satisfies
    // g(x_i) = f(i). That does not hold over a prime field -- with the
    // characteristic-2 recurrence it does not hold with `sub` either, which
    // means the specialization is not confined to the one `add`. This test
    // pins the limitation instead of asserting a property that is not there,
    // so that whoever generalizes `pack.zig` has to delete this test rather
    // than have it go quietly green.
    var round_trips = true;
    for (&table, 0..) |want, i| {
        const r = &[_]Prime31{
            Prime31.fromInt(i & 1),
            Prime31.fromInt((i >> 1) & 1),
            Prime31.fromInt((i >> 2) & 1),
        };
        const got = try Packed.eval(a, k, coeffs, r);
        if (got.toInt() != want.toInt()) round_trips = false;
    }
    try testing.expect(!round_trips);
}

test "witness: the secure Sumcheck refuses Prime31, which is why the Unsafe variant exists" {
    // This is the documented trade, stated as a test: the 31-bit prime cannot
    // instantiate the secure entry point, and `SumcheckUnsafe` is the API for
    // small fields. The code under test above is identical in both.
    const Secure = sumcheck.Sumcheck(Prime31);
    try testing.expectError(
        error.FieldTooSmall,
        Secure.prove(testing.allocator, 1, &.{&[_]Prime31{ Prime31.zero(), Prime31.one() }}),
    );
}

test "witness: the MLE kernel l_j is (1 - r_j) + (2 r_j - 1) t, not t + (1 + r_j)" {
    const a = testing.allocator;
    const k: usize = 3;
    const n: usize = 1 << k;
    const Pcs = @import("pcs.zig").MlePcsUnsafe(Prime31, Prime31);
    const r = [_]Prime31{ Prime31.fromInt(1), Prime31.fromInt(4), Prime31.fromInt(9) };

    const kt = try Pcs.kernelTables(a, k, &r);
    defer {
        for (kt) |t| a.free(t);
        a.free(kt);
    }

    // For every j and every i, the table entry must be the general form, and the
    // characteristic-2 form must disagree on at least one of them. The
    // discriminator is 2*r_j, which is 0 in characteristic 2 and 2*r_j here.
    var any_disagree = false;
    for (r, 0..) |rj, j| {
        const l_at_0 = Prime31.one().sub(rj);
        const l_at_1 = rj;
        const char2_0 = Prime31.one().add(rj); // 1 + r_j
        const char2_1 = rj.add(rj).add(Prime31.one()); // t + (1 + r_j) at t=1
        for (0..n) |i| {
            const bit: u8 = @intFromBool((i >> @intCast(j)) & 1 == 1);
            const want = if (bit == 0) l_at_0 else l_at_1;
            try testing.expectEqual(want.toInt(), kt[j][i].toInt());
            const char2 = if (bit == 0) char2_0 else char2_1;
            if (!char2.eql(want)) any_disagree = true;
        }
    }
    try testing.expect(any_disagree);
}
