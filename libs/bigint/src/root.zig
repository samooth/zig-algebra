//! zig-bigint: Arbitrary-precision integer arithmetic for Zig.
//!
//! Allocation-free, comptime-configurable precision.
//! Backed by fixed-size `[N]u64` limb arrays.

const std = @import("std");

pub const limb = @import("limb.zig");
pub const bigint = @import("bigint.zig");
pub const gcd = @import("gcd.zig");
pub const modexp = @import("modexp.zig");
pub const prime = @import("prime.zig");

pub const Limb = limb.Limb;
pub const DoubleLimb = limb.DoubleLimb;
pub const BigInt = bigint.BigInt;
pub const ExtendedGcd = gcd.ExtendedGcd;
pub const Gcd = gcd.ExtendedGcd;
pub const ModExp = modexp.ModExp;
pub const PrimalityTest = prime.PrimalityTest;

// Re-export limb array helpers for use by zig-field (Montgomery arithmetic)
pub const bitLength = limb.bitLength;
pub const numLimbs = limb.numLimbs;
pub const intToLimbs = limb.intToLimbs;
pub const intToLimbsRuntime = limb.intToLimbsRuntime;
pub const limbsToInt = limb.limbsToInt;
pub const cmp = limb.cmp;
pub const add = limb.add;
pub const sub = limb.sub;
pub const shl = limb.shl;
pub const shr = limb.shr;
pub const mul = limb.mul;

// ============================================================================
// Tests
// ============================================================================

test "BigInt construction and comparison" {
    const Big = BigInt(8);

    const a = Big.fromU64(42);
    const b = Big.fromU64(42);
    const c = Big.fromU64(43);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(a.lt(c));
    try std.testing.expect(c.gt(a));
    try std.testing.expect(a.isZero() == false);
    try std.testing.expect(Big.zero().isZero() == true);
}

test "BigInt addition" {
    const Big = BigInt(8);

    const a = Big.fromU64(123);
    const b = Big.fromU64(456);
    const sum = try a.add(b);
    try std.testing.expect(sum.eql(Big.fromU64(579)));

    // Large number addition
    const x = try Big.fromU128(0xFFFFFFFFFFFFFFFF_FFFFFFFFFFFFFFFF);
    const y = Big.fromU64(1);
    const z = try x.add(y);
    try std.testing.expect(z.limbs[0] == 0);
    try std.testing.expect(z.limbs[1] == 0);
    try std.testing.expect(z.limbs[2] == 1);
}

test "BigInt subtraction" {
    const Big = BigInt(8);

    const a = Big.fromU64(100);
    const b = Big.fromU64(30);
    const diff = try a.sub(b);
    try std.testing.expect(diff.eql(Big.fromU64(70)));

    // Subtraction resulting in negative
    const neg = try b.sub(a);
    try std.testing.expect(neg.isNegative());
    try std.testing.expect(neg.abs().eql(Big.fromU64(70)));
}

test "BigInt multiplication" {
    const Big = BigInt(8);

    const a = Big.fromU64(12345);
    const b = Big.fromU64(6789);
    const prod = try a.mul(b);
    try std.testing.expect(prod.eql(Big.fromU64(12345 * 6789)));

    // Large multiplication
    const x = try Big.fromU128(0xFFFFFFFFFFFFFFFF);
    const y = try Big.fromU128(0xFFFFFFFFFFFFFFFF);
    const z = try x.mul(y);
    try std.testing.expect(z.limbs[0] == 1); // (2^64-1)^2 = 2^128 - 2^65 + 1
    try std.testing.expect(z.limbs[1] == 0xFFFFFFFFFFFFFFFE);
}

test "BigInt division by single limb" {
    const Big = BigInt(8);

    const a = Big.fromU64(100);
    const dr = try a.divRemU64(7);
    try std.testing.expect(dr.q.eql(Big.fromU64(14)));
    try std.testing.expect(dr.r == 2);
}

test "BigInt division" {
    const Big = BigInt(8);

    const a = Big.fromU64(1000);
    const b = Big.fromU64(7);
    const qr = try a.divRem(b);
    try std.testing.expect(qr.q.eql(Big.fromU64(142)));
    try std.testing.expect(qr.r.eql(Big.fromU64(6)));
}

test "BigInt modular arithmetic" {
    const Big = BigInt(8);

    const a = Big.fromU64(17);
    const m = Big.fromU64(5);
    const r = try a.mod(m);
    try std.testing.expect(r.eql(Big.fromU64(2)));
}

test "mod is in [0, |m|) whatever the signs, as its docstring promises" {
    // The body added `m` to a negative remainder, so a negative `m` moved the
    // result further down instead of up: (-7).mod(-3) was -4, and the
    // docstring said "always non-negative". Cases taken from the CPython
    // `a % abs(m)` convention.
    const Big = BigInt(8);
    try std.testing.expect((try Big.fromI64(-7).mod(Big.fromI64(-3))).eql(Big.fromU64(2)));
    try std.testing.expect((try Big.fromI64(-7).mod(Big.fromI64(3))).eql(Big.fromU64(2)));
    try std.testing.expect((try Big.fromI64(7).mod(Big.fromI64(-3))).eql(Big.fromU64(1)));
    try std.testing.expect((try Big.fromI64(7).mod(Big.fromI64(3))).eql(Big.fromU64(1)));
    try std.testing.expect((try Big.fromI64(-6).mod(Big.fromI64(3))).eql(Big.zero()));
    try std.testing.expect((try Big.zero().mod(Big.fromI64(-9))).eql(Big.zero()));
    try std.testing.expectError(error.DivisionByZero, Big.fromI64(7).mod(Big.zero()));
}

test "fromString reads back what toString writes, sign included" {
    // toString emitted '-' for every negative value while fromString
    // rejected any non-digit, so the round trip failed on exactly the half of
    // the type that the old round-trip test never produced. Pinned over the
    // limb boundaries, where a magnitude that parses but does not compare
    // equal would hide behind a lenient eql.
    const Big = BigInt(8);
    const values = [_][]const u8{
        "0",                     "1",                                       "-1",                                       "7",
        "-7",                    "123456789",                               "-987654321",                               "18446744073709551615",
        "-18446744073709551615", "340282366920938463463374607431768211455", "-340282366920938463463374607431768211455",
    };
    for (values) |text| {
        const parsed = try Big.fromString(text);
        const written = try parsed.toString(std.testing.allocator);
        defer std.testing.allocator.free(written);
        try std.testing.expectEqualStrings(text, written);
        try std.testing.expect((try Big.fromString(written)).eql(parsed));
    }
    try std.testing.expectError(error.InvalidDigit, Big.fromString("-"));
    try std.testing.expectError(error.InvalidDigit, Big.fromString("12-3"));
    try std.testing.expect((try Big.fromString("-0")).eql(Big.zero()));
}

test "BigInt core arithmetic matches CPython's arbitrary-precision integers" {
    // Vectors generated with CPython 3 (`int` is arbitrary precision, and
    // nothing in this repository produced them) for the contracts `divRem`
    // and `mod` document: division truncates toward zero with the remainder
    // taking the dividend's sign, and `mod` lands in [0, |m|). The
    // magnitudes sit on 64-bit limb boundaries on purpose -- 2^63, 2^64,
    // 2^128, 2^192, 2^256 -- because a carry bug lives exactly there, and a
    // vector that never crosses a limb cannot see one.
    const Big = BigInt(8);
    const Core = struct {
        a: []const u8,
        b: []const u8,
        sum: []const u8,
        diff: []const u8,
        prod: []const u8,
        quo: []const u8,
        rem: []const u8,
        modv: []const u8,
        cmp: i2,
    };
    const vectors = [_]Core{
        .{ .a = "0", .b = "1", .sum = "1", .diff = "-1", .prod = "0", .quo = "0", .rem = "0", .modv = "0", .cmp = @as(i2, -1) },
        .{ .a = "1", .b = "1", .sum = "2", .diff = "0", .prod = "1", .quo = "1", .rem = "0", .modv = "0", .cmp = @as(i2, 0) },
        .{ .a = "9223372036854775808", .b = "9223372036854775807", .sum = "18446744073709551615", .diff = "1", .prod = "85070591730234615856620279821087277056", .quo = "1", .rem = "1", .modv = "1", .cmp = @as(i2, 1) },
        .{ .a = "18446744073709551615", .b = "18446744073709551616", .sum = "36893488147419103231", .diff = "-1", .prod = "340282366920938463444927863358058659840", .quo = "0", .rem = "18446744073709551615", .modv = "18446744073709551615", .cmp = @as(i2, -1) },
        .{ .a = "18446744073709551616", .b = "3", .sum = "18446744073709551619", .diff = "18446744073709551613", .prod = "55340232221128654848", .quo = "6148914691236517205", .rem = "1", .modv = "1", .cmp = @as(i2, 1) },
        .{ .a = "340282366920938463463374607431768211455", .b = "18446744073709551623", .sum = "340282366920938463481821351505477763078", .diff = "340282366920938463444927863358058659832", .prod = "6277101735386680766217765991654235660327530952412702441465", .quo = "18446744073709551609", .rem = "48", .modv = "48", .cmp = @as(i2, 1) },
        .{ .a = "3618502788666131213697322783095070105623107215331596699973092056135872020481", .b = "6277101735386680763835789423207666416102355444464034512895", .sum = "3618502788666131219974424518481750869458896638539263116075447500599906533376", .diff = "3618502788666131207420221047708389341787317792123930283870736611671837507586", .prod = "22713710134237715999500474335206288307294974223920124070148517819518904977457252755073032060915904500024231202955513217523960298602495", .quo = "576460752303423505", .rem = "576460752303423506", .modv = "576460752303423506", .cmp = @as(i2, 1) },
        .{ .a = "6277101735386680763835789423207666416102355444464034512896", .b = "6277101735386680763835789423207666416102355444464034512897", .sum = "12554203470773361527671578846415332832204710888928069025793", .diff = "-1", .prod = "39402006196394479212279040100143613805079739270465446667954570505981108452261046400837473921301017996251092024819712", .quo = "0", .rem = "6277101735386680763835789423207666416102355444464034512896", .modv = "6277101735386680763835789423207666416102355444464034512896", .cmp = @as(i2, -1) },
        .{ .a = "-7", .b = "3", .sum = "-4", .diff = "-10", .prod = "-21", .quo = "-2", .rem = "-1", .modv = "2", .cmp = @as(i2, -1) },
        .{ .a = "7", .b = "-3", .sum = "4", .diff = "10", .prod = "-21", .quo = "-2", .rem = "1", .modv = "1", .cmp = @as(i2, 1) },
        .{ .a = "-7", .b = "-3", .sum = "-10", .diff = "-4", .prod = "21", .quo = "2", .rem = "-1", .modv = "2", .cmp = @as(i2, -1) },
        .{ .a = "-1180591620717411303424", .b = "295147905179352825856", .sum = "-885443715538058477568", .diff = "-1475739525896764129280", .prod = "-348449143727040986586495598010130648530944", .quo = "-4", .rem = "0", .modv = "0", .cmp = @as(i2, -1) },
        .{ .a = "12345678901234567890123456789", .b = "987654321098765432109876543210", .sum = "999999999999999999999999999999", .diff = "-975308642197530864219753086421", .prod = "12193263113702179522618503273362292333223746380111126352690", .quo = "0", .rem = "12345678901234567890123456789", .modv = "12345678901234567890123456789", .cmp = @as(i2, -1) },
        .{ .a = "115792089237316195423570985008687907853269984665640564039457584007913129639935", .b = "340282366920938463463374607431768211455", .sum = "115792089237316195423570985008687907853610267032561502502920958615344897851390", .diff = "115792089237316195423570985008687907852929702298719625575994209400481361428480", .prod = "39402006196394479212279040100143613804963947181228130472524722419237033863643600344381704752381994682191283092455425", .quo = "340282366920938463463374607431768211457", .rem = "0", .modv = "0", .cmp = @as(i2, 1) },
    };
    for (vectors) |v| {
        const a = try Big.fromString(v.a);
        const b = try Big.fromString(v.b);
        try std.testing.expect((try a.add(b)).eql(try Big.fromString(v.sum)));
        try std.testing.expect((try a.sub(b)).eql(try Big.fromString(v.diff)));
        try std.testing.expect((try a.mul(b)).eql(try Big.fromString(v.prod)));
        const qr = try a.divRem(b);
        try std.testing.expect(qr.q.eql(try Big.fromString(v.quo)));
        try std.testing.expect(qr.r.eql(try Big.fromString(v.rem)));
        try std.testing.expect((try a.mod(b)).eql(try Big.fromString(v.modv)));
        try std.testing.expectEqual(v.cmp, a.cmp(b));
    }
}

test "BigInt bit operations, shifts and gcd match CPython" {
    // Same generator. `shr` is arithmetic (floor) for negative values, as
    // its docstring says; the 65-bit shifts cross a whole limb.
    const Big = BigInt(8);
    const G = Gcd(8);
    const Bits = struct {
        a: []const u8,
        b: []const u8,
        g: []const u8,
        band: []const u8,
        bor: []const u8,
        bxor: []const u8,
        shl7: []const u8,
        shr7: []const u8,
        shl65: []const u8,
        shr65: []const u8,
    };
    const vectors = [_]Bits{
        .{ .a = "0", .b = "0", .g = "0", .band = "0", .bor = "0", .bxor = "0", .shl7 = "0", .shr7 = "0", .shl65 = "0", .shr65 = "0" },
        .{ .a = "18446744073709551615", .b = "18446744073709551616", .g = "1", .band = "0", .bor = "36893488147419103231", .bxor = "36893488147419103231", .shl7 = "2361183241434822606720", .shr7 = "144115188075855871", .shl65 = "680564733841876926889855726716117319680", .shr65 = "0" },
        .{ .a = "340282366920938463463374607431768211455", .b = "170141183460469231731687303715884105728", .g = "1", .band = "170141183460469231731687303715884105728", .bor = "340282366920938463463374607431768211455", .bxor = "170141183460469231731687303715884105727", .shl7 = "43556142965880123323311949751266331066240", .shr7 = "2658455991569831745807614120560689151", .shl65 = "12554203470773361527671578846415332832167817400780649922560", .shr65 = "9223372036854775807" },
        .{ .a = "-1", .b = "255", .g = "1", .band = "255", .bor = "-1", .bxor = "-256", .shl7 = "-128", .shr7 = "-1", .shl65 = "-36893488147419103232", .shr65 = "-1" },
        .{ .a = "-1180591620717411303424", .b = "295147905179352825856", .g = "295147905179352825856", .band = "0", .bor = "-885443715538058477568", .bxor = "-885443715538058477568", .shl7 = "-151115727451828646838272", .shr7 = "-9223372036854775808", .shl65 = "-43556142965880123323311949751266331066368", .shr65 = "-32" },
        .{ .a = "9223372036854775808", .b = "4611686018427387904", .g = "4611686018427387904", .band = "0", .bor = "13835058055282163712", .bxor = "13835058055282163712", .shl7 = "1180591620717411303424", .shr7 = "72057594037927936", .shl65 = "340282366920938463463374607431768211456", .shr65 = "0" },
        .{ .a = "6277101735386680763835789423207666416102355444464034512897", .b = "18446744073709551615", .g = "1", .band = "1", .bor = "6277101735386680763835789423207666416120802188537744064511", .bxor = "6277101735386680763835789423207666416120802188537744064510", .shl7 = "803469022129495137770981046170581301261101496891396417650816", .shr7 = "49039857307708443467467104868809893875799651909875269632", .shl65 = "231584178474632390847141970017375815706539969331281128078952061503973678383104", .shr65 = "170141183460469231731687303715884105728" },
        .{ .a = "-7", .b = "3", .g = "1", .band = "1", .bor = "-5", .bxor = "-6", .shl7 = "-896", .shr7 = "-1", .shl65 = "-258254417031933722624", .shr65 = "-1" },
        .{ .a = "57896044618658097711785492504343953926634992332820282019728792003956564819968", .b = "57896044618658097711785492504343953926634992332820282019728792003956564819968", .g = "57896044618658097711785492504343953926634992332820282019728792003956564819968", .band = "57896044618658097711785492504343953926634992332820282019728792003956564819968", .bor = "57896044618658097711785492504343953926634992332820282019728792003956564819968", .bxor = "0", .shl7 = "7410693711188236507108543040556026102609279018600996098525285376506440296955904", .shr7 = "452312848583266388373324160190187140051835877600158453279131187530910662656", .shl65 = "2135987035920910082395021706169552114602704522356652769947041607822219725780640550022962086936576", .shr65 = "1569275433846670190958947355801916604025588861116008628224" },
        .{ .a = "115792089237316195423570985008687907853269984665640564039457584007913129639935", .b = "18446744073709551615", .g = "18446744073709551615", .band = "18446744073709551615", .bor = "115792089237316195423570985008687907853269984665640564039457584007913129639935", .bxor = "115792089237316195423570985008687907853269984665640564039439137263839420088320", .shl7 = "14821387422376473014217086081112052205218558037201992197050570753012880593911680", .shr7 = "904625697166532776746648320380374280103671755200316906558262375061821325311", .shl65 = "4271974071841820164790043412339104229205409044713305539894083215644439451561244206557776754769920", .shr65 = "3138550867693340381917894711603833208051177722232017256447" },
    };
    for (vectors) |v| {
        const a = try Big.fromString(v.a);
        const b = try Big.fromString(v.b);
        try std.testing.expect((try G.egcd(a, b)).g.eql(try Big.fromString(v.g)));
        try std.testing.expect(a.bitAnd(b).eql(try Big.fromString(v.band)));
        try std.testing.expect(a.bitOr(b).eql(try Big.fromString(v.bor)));
        try std.testing.expect(a.bitXor(b).eql(try Big.fromString(v.bxor)));
        try std.testing.expect((try a.shl(7)).eql(try Big.fromString(v.shl7)));
        try std.testing.expect(a.shr(7).eql(try Big.fromString(v.shr7)));
        try std.testing.expect((try a.shl(65)).eql(try Big.fromString(v.shl65)));
        try std.testing.expect(a.shr(65).eql(try Big.fromString(v.shr65)));
    }
}

test "BigInt modular exponentiation matches CPython's pow" {
    // pow(a, e, m) in CPython, over the fields this ecosystem uses: the
    // Mersenne 2^61-1, the STARK prime and the BLS12-381 scalar field. Every
    // modulus stays under the 32*max_limbs width threshold, which is a
    // separate contract with its own test.
    const Big = BigInt(8);
    const ME = ModExp(8);
    const Exp = struct { a: []const u8, e: []const u8, m: []const u8, r: []const u8 };
    const vectors = [_]Exp{
        .{ .a = "2", .e = "10", .m = "1000", .r = "24" },
        .{ .a = "2", .e = "0", .m = "7", .r = "1" },
        .{ .a = "5", .e = "1", .m = "3", .r = "2" },
        .{ .a = "3", .e = "5", .m = "11", .r = "1" },
        .{ .a = "7", .e = "18446744073709551629", .m = "18446744073709551557", .r = "16790916694802184733" },
        .{ .a = "1267650600228229401496703205377", .e = "65537", .m = "3618502788666131213697322783095070105623107215331596699973092056135872020481", .r = "32693487889769341272950467266621626850756033291401840963505979986675793854" },
        .{ .a = "123456789", .e = "1000", .m = "2305843009213693951", .r = "607234073701413367" },
        .{ .a = "18446744073709551615", .e = "65537", .m = "52435875175126190479447740508185965837690552500527637822603658699938581184513", .r = "3450719233425594202655059376546050658683241833234411947747777383136624358838" },
    };
    for (vectors) |v| {
        const a = try Big.fromString(v.a);
        const e = try Big.fromString(v.e);
        const m = try Big.fromString(v.m);
        try std.testing.expect((try ME.modExp(a, e, m)).eql(try Big.fromString(v.r)));
    }
}

test "BigInt shift" {
    const Big = BigInt(8);

    const a = Big.fromU64(1);
    const b = try a.shl(64);
    try std.testing.expect(b.limbs[1] == 1);
    try std.testing.expect(b.limbs[0] == 0);

    const c = b.shr(64);
    try std.testing.expect(c.eql(Big.fromU64(1)));
}

test "BigInt string conversion" {
    const Big = BigInt(8);

    const a = Big.fromU64(123456789);
    const s = try a.toString(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("123456789", s);

    const b = try Big.fromString("9876543210");
    try std.testing.expect(b.eql(Big.fromU64(9876543210)));
}

test "Extended GCD" {
    const Big = BigInt(8);
    const G = ExtendedGcd(8);

    const a = Big.fromU64(240);
    const b = Big.fromU64(46);
    const res = try G.egcd(a, b);
    try std.testing.expect(res.g.eql(Big.fromU64(2)));

    // Verify: a*x + b*y = g
    const ax = try a.mul(res.x);
    const by = try b.mul(res.y);
    const sum = try ax.add(by);
    try std.testing.expect(sum.eql(res.g));
}

test "Modular inverse" {
    const Big = BigInt(8);
    const G = ExtendedGcd(8);

    const a = Big.fromU64(3);
    const m = Big.fromU64(11);
    const inv = try G.modInv(a, m);
    // 3 * 4 = 12 = 1 mod 11
    try std.testing.expect(inv.eql(Big.fromU64(4)));
}

test "Modular exponentiation" {
    const Big = BigInt(8);
    const ME = ModExp(8);

    const base = Big.fromU64(2);
    const exp = Big.fromU64(10);
    const mod_val = Big.fromU64(1000);
    const result = try ME.modExp(base, exp, mod_val);
    try std.testing.expect(result.eql(Big.fromU64(24))); // 2^10 = 1024, 1024 mod 1000 = 24

    // Test with u64 exponent
    const result2 = try ME.modExpU64(base, 10, mod_val);
    try std.testing.expect(result2.eql(Big.fromU64(24)));
}

test "Miller-Rabin primality" {
    const Big = BigInt(8);
    const P = PrimalityTest(8);

    // Small primes
    try std.testing.expect(try P.millerRabin(Big.fromU64(2), 7));
    try std.testing.expect(try P.millerRabin(Big.fromU64(3), 7));
    try std.testing.expect(try P.millerRabin(Big.fromU64(97), 7));
    try std.testing.expect(try P.millerRabin(Big.fromU64(104729), 7)); // 10000th prime

    // Composites
    try std.testing.expect(!try P.millerRabin(Big.fromU64(100), 7));
    try std.testing.expect(!try P.millerRabin(Big.fromU64(91), 7)); // 7*13
    try std.testing.expect(!try P.millerRabin(Big.fromU64(1), 7));
}

test "BigInt negative numbers" {
    const Big = BigInt(8);

    const a = Big.fromI64(-42);
    try std.testing.expect(a.isNegative());
    try std.testing.expect(a.abs().eql(Big.fromU64(42)));

    const b = Big.fromI64(30);
    const sum = try a.add(b);
    try std.testing.expect(sum.eql(Big.fromI64(-12)));

    const prod = try a.mul(b);
    try std.testing.expect(prod.isNegative());
    try std.testing.expect(prod.abs().eql(Big.fromU64(1260)));
}

test "BigInt bit operations" {
    const Big = BigInt(8);

    const a = Big.fromU64(0b1010);
    const b = Big.fromU64(0b1100);

    const band = a.bitAnd(b);
    try std.testing.expect(band.eql(Big.fromU64(0b1000)));

    const bor = a.bitOr(b);
    try std.testing.expect(bor.eql(Big.fromU64(0b1110)));

    const bxor = a.bitXor(b);
    try std.testing.expect(bxor.eql(Big.fromU64(0b0110)));
}

test "BigInt multi-limb division" {
    const Big = BigInt(2);
    const a = try Big.fromU128((@as(u128, 1) << 127) + 123);
    const b = try Big.fromU128((@as(u128, 1) << 64) + 5);
    const qr = try a.divRem(b);
    try std.testing.expect(qr.q.eql(try Big.fromU128(0x7FFFFFFFFFFFFFFD)));
    try std.testing.expect(qr.r.eql(try Big.fromU128(0x800000000000008A)));
}

test "BigInt constructors handle signed minimum and one-limb limits" {
    const Big = BigInt(8);
    const min = Big.fromI64(std.math.minInt(i64));
    try std.testing.expect(min.isNegative());
    try std.testing.expect(min.abs().eql(Big.fromU64(1 << 63)));

    const One = BigInt(1);
    _ = try One.fromU128(std.math.maxInt(u64));
    try std.testing.expectError(error.Overflow, One.fromU128(@as(u128, 1) << 64));
}

test "modInverse accessible via Gcd re-export" {
    const G = Gcd(8);
    const Big = BigInt(8);
    const inv = try G.modInv(Big.fromU64(3), Big.fromU64(11));
    try std.testing.expect(inv.eql(Big.fromU64(4))); // 3*4 = 12 ≡ 1 mod 11
}

test "modInv rejects a negative modulus and a zero modulus" {
    // Guards `modInv`'s modulus check. A negative modulus is the interesting
    // one: `mod` and the final `mod(m)` on a negative modulus are not the
    // modular inverse anybody means, and the guard is the only thing stopping
    // them. Written mutation-first: with the `isNegative` arm removed, the
    // negative case below returns instead of erroring.
    const Big = BigInt(8);
    const G = ExtendedGcd(8);

    try std.testing.expectError(error.InvalidModulus, G.modInv(Big.fromU64(3), Big.zero()));
    try std.testing.expectError(
        error.InvalidModulus,
        G.modInv(Big.fromU64(3), Big.fromU64(11).neg()),
    );

    // And the positive path still works, so the guard is not simply rejecting
    // everything.
    try std.testing.expect((try G.modInv(Big.fromU64(3), Big.fromU64(11))).eql(Big.fromU64(4)));
}

test "modInv with a full-width modulus returns an error instead of trapping" {
    // The witness. This used to be undefined behaviour: `egcd`'s `q * r` needs
    // twice the width of the container, `BigInt.mul` returns `error.Overflow`
    // for it, and `catch unreachable` turned that into a trap in Debug and UB
    // in ReleaseFast. Any `a` reaches it on the first iteration.
    const L: usize = 2;
    const G = ExtendedGcd(L);
    const Big = bigint.BigInt(L);

    // bitLength(m) == 64 * max_limbs: the container exactly full, top bit set.
    const m = Big{ .limbs = .{ 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF }, .len = L, .negative = false };
    try std.testing.expectEqual(error.Overflow, G.modInv(Big.fromU64(2), m));
    try std.testing.expectEqual(error.Overflow, G.modInv(Big.fromU64(3), m));

    // `egcd` itself is the thing that could not report, and now does.
    try std.testing.expectEqual(error.Overflow, G.egcd(Big.fromU64(2), m));

    // **There is no `bitLength(m) <= X` rule that makes this unreachable, and
    // the doc must not pretend otherwise.** Measured on a 256-bit container:
    // the widest modulus that survives is 193 bits for `a` in 2..13, and **218
    // bits** for `a = 2^31 - 1`, so the boundary moves with the *trajectory*,
    // not with the modulus. A width bound of "container minus one" or "minus
    // two" is therefore unsafe: both admit inputs that overflow. The honest
    // rule is the one in the doc -- size the `BigInt` with headroom for the
    // modulus you intend, and treat `error.Overflow` as a real answer.
    const L4: usize = 4;
    const G4 = ExtendedGcd(L4);
    const B4 = bigint.BigInt(L4);
    const ofWidth = struct {
        fn f(w: usize) B4 {
            var limbs = [_]u64{0xFFFF_FFFF_FFFF_FFFF} ** L4;
            var i = w;
            while (i < 256) : (i += 1) limbs[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
            return B4{ .limbs = limbs, .len = (w + 63) / 64, .negative = false };
        }
    }.f;
    // 218 works for this `a`, and 255 -- "container minus one" -- does not, which
    // is the measurement that rules the bound out rather than asserting it.
    try std.testing.expect(G4.modInv(B4.fromU64(2_147_483_647), ofWidth(218)) != error.Overflow);
    try std.testing.expectEqual(error.Overflow, G4.modInv(B4.fromU64(2_147_483_647), ofWidth(255)));
}

test "modExp: the width threshold is 32*max_limbs, and the base does not move it" {
    // Measured across three precisions, and with **two** bases on purpose. A
    // test with only a wide base would pass for the wrong reason: the
    // mechanism says `b` is squared every iteration and so reaches full width
    // regardless of where it started, so the narrow base has to give the same
    // number. If it ever does not, the threshold is not the thing we measured.
    inline for (.{ 2, 4, 8 }) |L| {
        const M = modexp.ModExp(L);
        const B = bigint.BigInt(L);
        const ofWidth = struct {
            fn f(comptime B2: type, w: usize) B2 {
                var limbs = [_]u64{0xFFFF_FFFF_FFFF_FFFF} ** L;
                var i = w;
                while (i < 64 * L) : (i += 1) limbs[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
                return B2{ .limbs = limbs, .len = (w + 63) / 64, .negative = false };
            }
        }.f;

        var wide_threshold: usize = 0;
        var narrow_threshold: usize = 0;
        var w: usize = 1;
        while (w <= 64 * L) : (w += 1) {
            const m = ofWidth(B, w);
            const wide = m.sub(B.one()) catch m;
            if (M.modExp(wide, B.fromU64(65537), m) != error.InvalidModulusWidth) wide_threshold = w;
            if (M.modExp(B.fromU64(3), B.fromU64(65537), m) != error.InvalidModulusWidth) narrow_threshold = w;
        }

        // The threshold is exactly half the container, in bits.
        try std.testing.expectEqual(@as(usize, 32 * L), wide_threshold);
        // And the base is irrelevant, which is the mechanism, not a coincidence.
        try std.testing.expectEqual(wide_threshold, narrow_threshold);
        // One bit past it is the declared error, and it is the *renamed* one.
        const at = ofWidth(B, wide_threshold);
        try std.testing.expectEqual(
            error.InvalidModulusWidth,
            M.modExp(B.fromU64(3), B.fromU64(65537), ofWidth(B, wide_threshold + 1)),
        );
        // The boundary itself still works.
        try std.testing.expect(M.modExp(B.fromU64(3), B.fromU64(65537), at) != error.InvalidModulusWidth);
    }
}

test "modExp: a plain multiplication still says Overflow, not InvalidModulusWidth" {
    // The rename is local to the modular exponentiation. `mul` is the door for
    // all of `bigint` and cannot know a modulus is involved, so raising the
    // error there would make this lie about a modulus that does not exist.
    const L: usize = 2;
    const B = bigint.BigInt(L);
    const big = B{ .limbs = [_]u64{0xFFFF_FFFF_FFFF_FFFF} ** L, .len = L, .negative = false };
    try std.testing.expectEqual(error.Overflow, big.mul(big));
}
