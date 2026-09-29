// SPDX-License-Identifier: MIT OR Apache-2.0

//! Property tests for the generic prime-field arithmetic.
//!
//! Every predefined field is checked against a big-integer reference
//! (`u512`/`u1024` modulo arithmetic) and for the algebraic identities that a
//! field must satisfy.

const std = @import("std");
const zf = @import("zig-field");

// Set to true to enable debug output in multiExp tests
const DEBUG_MULTIEXP = false;

/// Reference square-and-multiply over `u1024` modulo arithmetic.
fn powRef(comptime F: type, a: F, e: u64) u512 {
    const p: u512 = F.MODULUS;
    var result: u512 = 1;
    var base: u512 = a.toU512();
    var ee = e;
    while (ee > 0) : (ee >>= 1) {
        if ((ee & 1) == 1) {
            result = @as(u512, @truncate((@as(u1024, result) * @as(u1024, base)) % @as(u1024, p)));
        }
        base = @as(u512, @truncate((@as(u1024, base) * @as(u1024, base)) % @as(u1024, p)));
    }
    return result;
}

fn testFieldArithmetic(comptime F: type) !void {
    const p: u512 = F.MODULUS;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const a = F.fromInt(rnd.int(u512) % p);
        const b = F.fromInt(rnd.int(u512) % p);
        const av = a.toU512();
        const bv = b.toU512();

        try std.testing.expectEqual((av + bv) % p, a.add(b).toU512());
        try std.testing.expectEqual((av + p - bv) % p, a.sub(b).toU512());
        try std.testing.expectEqual(
            @as(u512, @truncate((@as(u1024, av) * @as(u1024, bv)) % @as(u1024, p))),
            a.mul(b).toU512(),
        );
        // neg (off-by-1 bug fixed in Montgomery sub).
        try std.testing.expectEqual((p - av) % p, a.neg().toU512());

        // Inverse and exponentiation.
        if (!a.isZero()) {
            try std.testing.expect(a.mul(a.inv()).isOne());
            try std.testing.expectEqual(a.pow(p - 2).toU512(), a.inv().toU512());
        }
        try std.testing.expectEqual(powRef(F, a, 12345), a.pow(12345).toU512());
        if (!a.isZero()) try std.testing.expect(a.pow(p - 1).isOne());

        // Square roots: a square always has a sqrt whose square matches.
        const sq = a.mul(a);
        try std.testing.expectEqual(@as(i8, 1), sq.legendre());
        const r = sq.sqrt() orelse return error.TestUnexpectedResult;
        try std.testing.expect(r.mul(r).eq(sq));

        // Serialization round-trip.
        const bytes = a.toBytes();
        try std.testing.expect(a.eq(try F.fromBytes(&bytes)));

        // The checked entry point rejects the modulus itself, so its success
        // set is exactly `[0, p)`. `zig-transcript`'s `challengeFieldChecked`
        // claims exact uniformity on the strength of this, and the claim is
        // only as good as this assertion -- so it runs for every field rather
        // than for one representative of them.
        const modulus_bytes = modulusBytesOf(F);
        try std.testing.expectError(error.ValueOutOfRange, F.fromBytesChecked(modulus_bytes));
        try std.testing.expectError(error.ValueOutOfRange, F.fromBytesChecked(@splat(0xFF)));
        // Exactly one below the modulus still decodes, and to the right value:
        // the boundary is inclusive-below, not a blanket rejection.
        //
        // `below[0]`, not `below[NUM_BYTES - 1]`: the encodings are
        // little-endian, and every prime modulus here is odd, so subtracting one
        // is a borrow-free decrement of the **least** significant byte.
        // Decrementing the most significant one gives a different number that is
        // still below the modulus, and the test catches that -- which is the only
        // reason to write the exact value rather than "still decodes".
        var below = modulus_bytes;
        below[0] -= 1;
        try std.testing.expect((try F.fromBytesChecked(below)).eql(F.fromInt(F.MODULUS - 1)));
    }
}

/// The little-endian encoding of `F.MODULUS`, which no element can hold.
fn modulusBytesOf(comptime F: type) [F.NUM_BYTES]u8 {
    var out: [F.NUM_BYTES]u8 = undefined;
    var n = F.MODULUS;
    for (&out) |*b| {
        b.* = @truncate(n);
        n >>= 8;
    }
    return out;
}

fn testRoots(comptime F: type) !void {
    const t_max = @min(F.two_adicity, 12);
    var t: usize = 0;
    while (t <= t_max) : (t += 1) {
        const w = try F.primitiveRootOfUnity(t);
        try std.testing.expect(w.pow(@as(u128, 1) << @intCast(t)).isOne());
        if (t > 0) {
            try std.testing.expect(!w.pow(@as(u128, 1) << @intCast(t - 1)).isOne());
        }
    }
}

test "public hash() is reachable and is a stable, input-dependent digest" {
    // Four public `hash` bodies had never been analysed by the compiler:
    // `wrapping_mul` is not a method on u64 -- Zig's wrapping arithmetic is the
    // `*%` operator -- and nothing called `hash`, so 421 green tests never looked
    // at it. A test that does nothing but call them is what turns them from code
    // nobody has read into code that runs.
    //
    // **No expected digest is asserted, on purpose.** A literal produced by this
    // implementation would be a self-generated known-answer vector, which is the
    // one thing that must never look like provenance. What is asserted here is
    // the reachability claim and the two properties a map key needs: stable, and
    // not constant. That the FNV-1a result has any particular value is *not*
    // claimed, and pinning it would make the test pass for a wrong constant.
    try std.testing.expect(zf.M31.fromInt(1).hash() != zf.M31.fromInt(2).hash());
    try std.testing.expectEqual(zf.M31.fromInt(7).hash(), zf.M31.fromInt(7).hash());
    try std.testing.expect(zf.BLS12_381_Fp.fromInt(1).hash() != zf.BLS12_381_Fp.fromInt(2).hash());
    try std.testing.expect(zf.Goldilocks.fromInt(1).hash() != zf.Goldilocks.fromInt(2).hash());

    // The extension towers carry their own copies of the same function, and the
    // cubic one is not instantiated anywhere as a predefined -- which is part of
    // why it was never analysed. Instantiate it here to reach the body.
    // `zf.BLS12_381_Fp2` is *not* used here: lib.zig:31 re-exports
    // `predef.BLS12_381_Fp2`, which that file does not define. Same family as
    // the four bodies -- declared surface, never reached -- except this one
    // fails loudly. Reported, not fixed: which non-residue BLS12-381's Fp2
    // should use is a design decision, not a patch.
    const Sq = zf.BN254_Fp2;
    try std.testing.expect(Sq.fromInt(1).hash() != Sq.fromInt(2).hash());
    try std.testing.expectEqual(Sq.fromInt(5).hash(), Sq.fromInt(5).hash());
    // A cubic tower over a 381-bit prime needs heavy comptime work, which is
    // why no predefined instantiates one. The quota is the one AGENTS.md
    // prescribes for exactly this case.
    @setEvalBranchQuota(100_000_000);
    const Cb = zf.CubicExtension(zf.BLS12_381_Fp, zf.BLS12_381_Fp.fromInt(2));
    try std.testing.expect(Cb.fromInt(1).hash() != Cb.fromInt(2).hash());
    try std.testing.expectEqual(Cb.fromInt(5).hash(), Cb.fromInt(5).hash());
}

test "montgomery: a * a^-1 must be 1, and headroom is what makes it true" {
    // The regression test for the reported finding, and **the first test in this
    // repository that touches `montgomery.zig` at all**. `Montgomery(` appears
    // nowhere outside `field.zig` and `montgomery.zig` itself, so CIOS
    // multiplication and the binary-GCD inverse had no test that reached them.
    //
    // The diagnosis, stated so the test can be read as a claim rather than a
    // ritual: `addP` adds `p` in place over `[n]u64` and discards the carry, so
    // it computes `(x + p) mod 2^256` rather than `x + p`. That is wrong exactly
    // when `x + p >= 2^256`, i.e. `x >= 2^256 - p`. Whether any `x` in the loop
    // can be that large is decided by the **bit length of the modulus against
    // its container**: 256-bit p in four limbs has headroom 0, so `2^256 - p` is
    // merely `2^32 + 977` and essentially every `x1` clears it; 254-bit p leaves
    // two bits of slack and the threshold sits at about `2^253`, which the loop
    // does not reach.
    //
    // So the three moduli below are the differential. BN254 and BLS12-381 pass
    // for a structural reason, not because they are luckier.
    const Secp = zf.montgomery.Montgomery(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F);
    const Bn = zf.montgomery.Montgomery(0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD47);
    const Bls = zf.montgomery.Montgomery(0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB);

    const Result = struct { ok: usize, bad: usize };
    const check = struct {
        fn run(comptime M: type, comptime n: usize) !Result {
            var ok: usize = 0;
            var bad: usize = 0;
            var seed: u64 = 0x243F6A8885A308D3;
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                var a: [n]u64 = [_]u64{0} ** n;
                for (&a) |*limb| {
                    seed = seed *% 6364136223846793005 +% 1442695040888963407;
                    limb.* = seed;
                }
                a[n - 1] &= 0x3FFFFFFFFFFFFFFF; // keep it inside the modulus
                const a_m = M.toMontgomery(a);
                const inv_m = try M.invMontgomeryChecked(a_m);
                const product = M.fromMontgomery(M.mul(a_m, inv_m));
                if (std.mem.eql(u64, &product, &M.CANONICAL_ONE)) ok += 1 else bad += 1;
            }
            return .{ .ok = ok, .bad = bad };
        }
    }.run;

    const secp = try check(Secp, 4);
    const bn = try check(Bn, 4);
    const bls = try check(Bls, 6);

    // The two moduli with headroom are correct, and that is now pinned rather
    // than assumed.
    try std.testing.expectEqual(@as(usize, 0), bn.bad);
    try std.testing.expectEqual(@as(usize, 0), bls.bad);
    // secp256k1 has none. This is the failing assertion, and it is the finding.
    try std.testing.expectEqual(@as(usize, 0), secp.bad);
}

test "M31 arithmetic" {
    try testFieldArithmetic(zf.M31);
}
test "M31 roots of unity" {
    try testRoots(zf.M31);
}
test "BabyBear arithmetic" {
    try testFieldArithmetic(zf.BabyBear);
}
test "BabyBear roots of unity" {
    try testRoots(zf.BabyBear);
}
test "KoalaBear arithmetic" {
    try testFieldArithmetic(zf.KoalaBear);
}
test "KoalaBear roots of unity" {
    try testRoots(zf.KoalaBear);
}
test "Goldilocks arithmetic" {
    try testFieldArithmetic(zf.Goldilocks);
}
test "Goldilocks roots of unity" {
    try testRoots(zf.Goldilocks);
}
test "BN254_Fp roots of unity" {
    try testRoots(zf.BN254_Fp);
}
test "BLS12_381_Fp arithmetic" {
    try testFieldArithmetic(zf.BLS12_381_Fp);
}
test "BLS12_381_Fp roots of unity" {
    try testRoots(zf.BLS12_381_Fp);
}

test "fromInt reduces modulo p" {
    try std.testing.expect(zf.M31.fromInt(zf.M31.MODULUS).isZero());
    try std.testing.expect(zf.M31.fromInt(zf.M31.MODULUS + 5).eq(zf.M31.fromInt(5)));
    try std.testing.expect(zf.M31.fromInt(@as(u512, 1) << 40).eq(zf.M31.fromInt((@as(u512, 1) << 40) % zf.M31.MODULUS)));
    try std.testing.expect(zf.BN254_Fp.fromInt(@as(u512, 1) << 500).eq(zf.BN254_Fp.fromInt((@as(u512, 1) << 500) % zf.BN254_Fp.MODULUS)));
}

test "known M31 byte encoding" {
    var buf: [zf.M31.NUM_BYTES]u8 = undefined;
    _ = &buf;
    const one = zf.M31.one().toBytes();
    try std.testing.expectEqual(@as(u8, 1), one[0]);
    try std.testing.expectEqual(@as(u8, 0), one[1]);
}

test "random sampling stays in range" {
    var prng = std.Random.DefaultPrng.init(123);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const a = zf.BN254_Fp.random(prng.random());
        try std.testing.expect(a.toU512() < zf.BN254_Fp.MODULUS);
    }
}

// ============================================================================
// Edge-case tests for field arithmetic
// ============================================================================

test "SmallField edge cases: fromInt, toInt, serialization" {
    const F = zf.M31;
    // fromInt(0)
    const zero = F.fromInt(0);
    try std.testing.expect(zero.isZero());
    try std.testing.expect(zero.toInt() == 0);

    // fromInt(1)
    const one = F.fromInt(1);
    try std.testing.expect(one.isOne());
    try std.testing.expect(one.toInt() == 1);

    // fromInt(MODULUS - 1)
    const max = F.fromInt(F.MODULUS - 1);
    try std.testing.expect(max.toInt() == F.MODULUS - 1);

    // fromInt(MODULUS) == 0
    const wrap = F.fromInt(F.MODULUS);
    try std.testing.expect(wrap.isZero());

    // Serialization round-trip LE
    var prng = std.Random.DefaultPrng.init(42);
    const a = F.random(prng.random());
    const bytes = a.toBytes();
    const a2 = try F.fromBytes(&bytes);
    try std.testing.expect(a.eq(a2));
}

test "SmallField edge cases: pow, inv, sqrt" {
    const F = zf.M31;

    // pow(x, 0) == 1
    const a = F.fromInt(123);
    try std.testing.expect(a.pow(0).isOne());
    try std.testing.expect(a.powFast(0).isOne());

    // pow(x, 1) == x
    try std.testing.expect(a.pow(1).eq(a));
    try std.testing.expect(a.powFast(1).eq(a));

    // inv(1) == 1
    try std.testing.expect(F.one().inv().isOne());

    // sqrt(0) == 0
    const sqrt0 = F.zero().sqrt();
    try std.testing.expect(sqrt0 != null);
    try std.testing.expect(sqrt0.?.isZero());

    // sqrt(1) == +/-1
    const sqrt1 = F.one().sqrt();
    try std.testing.expect(sqrt1 != null);
    try std.testing.expect(sqrt1.?.isOne() or sqrt1.?.eq(F.one().neg()));

    // sqrt of non-residue returns null
    const non_res = F.fromInt(2); // 2 is a non-residue in M31 (Legendre = -1)
    if (non_res.legendre() == -1) {
        try std.testing.expect(non_res.sqrt() == null);
    }
}

test "SmallField: mulBy2/3/4/5 vs mul" {
    const F = zf.M31;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    for (0..100) |_| {
        const a = F.random(rnd);
        try std.testing.expect(a.mulBy2().eq(a.mul(F.fromInt(2))));
        try std.testing.expect(a.mulBy3().eq(a.mul(F.fromInt(3))));
        try std.testing.expect(a.mulBy4().eq(a.mul(F.fromInt(4))));
        try std.testing.expect(a.mulBy5().eq(a.mul(F.fromInt(5))));
        try std.testing.expect(a.sqr().eq(a.mul(a)));
    }
}

test "SmallField: batchInv correctness" {
    const F = zf.M31;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    var inputs: [10]F = undefined;
    var outputs: [10]F = undefined;
    for (0..10) |i| {
        inputs[i] = F.random(rnd);
        // Ensure no zero
        while (inputs[i].isZero()) inputs[i] = F.random(rnd);
    }

    F.batchInv(&inputs, &outputs);

    for (0..10) |i| {
        try std.testing.expect(inputs[i].mul(outputs[i]).isOne());
    }
}

test "SmallField: eqCT and isZeroCT" {
    const F = zf.M31;
    const a = F.fromInt(42);
    const b = F.fromInt(42);
    const c = F.fromInt(43);

    try std.testing.expect(a.eqCT(b));
    try std.testing.expect(!a.eqCT(c));
    try std.testing.expect(F.zero().isZeroCT());
    try std.testing.expect(!F.one().isZeroCT());
}

test "BigField edge cases: fromInt, toInt, serialization" {
    const F = zf.BN254_Fp;

    const zero = F.fromInt(0);
    try std.testing.expect(zero.isZero());
    try std.testing.expect(zero.toInt() == 0);

    const one = F.fromInt(1);
    try std.testing.expect(one.isOne());
    try std.testing.expect(one.toInt() == 1);

    // Serialization round-trip
    var prng = std.Random.DefaultPrng.init(42);
    const a = F.random(prng.random());
    const bytes = a.toBytes();
    const a2 = try F.fromBytes(&bytes);
    try std.testing.expect(a.eq(a2));
}

test "BigField: batchInv correctness" {
    const F = zf.BN254_Fp;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    var inputs: [5]F = undefined;
    var outputs: [5]F = undefined;
    for (0..5) |i| {
        inputs[i] = F.random(rnd);
        while (inputs[i].isZero()) inputs[i] = F.random(rnd);
    }

    F.batchInv(&inputs, &outputs);

    for (0..5) |i| {
        try std.testing.expect(inputs[i].mul(outputs[i]).isOne());
    }
}

test "BigField: mulBy2/3/4/5 vs mul" {
    const F = zf.BN254_Fp;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    for (0..50) |_| {
        const a = F.random(rnd);
        try std.testing.expect(a.mulBy2().eq(a.mul(F.fromInt(2))));
        try std.testing.expect(a.mulBy3().eq(a.mul(F.fromInt(3))));
        try std.testing.expect(a.mulBy4().eq(a.mul(F.fromInt(4))));
        try std.testing.expect(a.mulBy5().eq(a.mul(F.fromInt(5))));
        try std.testing.expect(a.sqr().eq(a.mul(a)));
    }
}

// ============================================================================
// Zero-inverse / zero-divisor contracts (regressions for hangs and OOB writes)
// ============================================================================

/// Every backend must behave identically: `inv(0) == 0`, `x / 0 == 0`, and the
/// checked variants must report the missing inverse/divisor. The legacy
/// behaviour before these tests was a debug-only assert, i.e. an infinite loop
/// in the binary GCD (`a == 0` never reduces) under ReleaseFast.
fn testZeroInverseContract(comptime F: type) !void {
    try std.testing.expect(F.zero().inv().isZero());
    try std.testing.expect(F.zero().inverse().isZero());
    try std.testing.expectError(error.InverseOfZero, F.zero().invChecked());
    try std.testing.expect(F.fromInt(9).div(F.zero()).isZero());
    try std.testing.expectError(error.DivisionByZero, F.fromInt(9).divChecked(F.zero()));

    // Non-zero values are unaffected.
    const a = F.fromInt(3);
    const b = F.fromInt(7);
    try std.testing.expect(a.mul(a.inv()).isOne());
    try std.testing.expect((try a.invChecked()).eq(a.inv()));
    try std.testing.expect(a.div(b).eq(a.mul(b.inv())));
    try std.testing.expect((try a.divChecked(b)).eq(a.div(b)));
}

test "M31: inv(0)/div by zero are defined and checked" {
    try testZeroInverseContract(zf.M31);
}

test "BabyBear: inv(0)/div by zero are defined and checked" {
    try testZeroInverseContract(zf.BabyBear);
}

test "Goldilocks: inv(0)/div by zero are defined and checked" {
    try testZeroInverseContract(zf.Goldilocks);
}

test "BN254_Fp: inv(0)/div by zero are defined and checked" {
    try testZeroInverseContract(zf.BN254_Fp);
}

test "BLS12_381_Fp: inv(0)/div by zero are defined and checked" {
    try testZeroInverseContract(zf.BLS12_381_Fp);
}

/// batchInv must survive a zero input (used to hang on `inv(0)`) and a length
/// mismatch (used to write past the end of `outputs`), and `batchInvChecked`
/// must report both.
fn testBatchInvContract(comptime F: type) !void {
    const inputs = [_]F{ F.fromInt(2), F.zero(), F.fromInt(5), F.one(), F.zero() };
    var outputs: [inputs.len]F = undefined;
    F.batchInv(&inputs, &outputs);

    for (inputs, outputs) |x, inv_x| {
        if (x.isZero()) {
            try std.testing.expect(inv_x.isZero());
        } else {
            try std.testing.expect(x.mul(inv_x).isOne());
        }
    }

    // Checked variant: zero-free input gives the same inverses ...
    const nonzero = [_]F{ F.fromInt(2), F.fromInt(5), F.one() };
    var checked: [nonzero.len]F = undefined;
    try F.batchInvChecked(&nonzero, &checked);
    for (nonzero, checked) |x, inv_x| try std.testing.expect(x.mul(inv_x).isOne());
    // ... and a zero input is reported instead of hanging.
    var untouched: [inputs.len]F = @splat(F.fromInt(42));
    try std.testing.expectError(error.InverseOfZero, F.batchInvChecked(&inputs, &untouched));
    for (untouched) |v| try std.testing.expect(v.eq(F.fromInt(42)));

    var short: [inputs.len - 2]F = undefined;
    try std.testing.expectError(error.LengthMismatch, F.batchInvChecked(&inputs, &short));
    // Legacy: a mismatch writes nothing at all (no out-of-bounds store).
    var sentinel: [inputs.len]F = @splat(F.fromInt(42));
    F.batchInv(&inputs, sentinel[0 .. inputs.len - 1]);
    for (sentinel) |v| try std.testing.expect(v.eq(F.fromInt(42)));

    // Empty input is a no-op, not a call to inv on an empty product.
    var empty: [1]F = undefined;
    F.batchInv(&[_]F{}, empty[0..0]);
    try F.batchInvChecked(&[_]F{}, empty[0..0]);
}

test "SmallField: batchInv tolerates zeros and length mismatch" {
    try testBatchInvContract(zf.M31);
}

test "BigField: batchInv tolerates zeros and length mismatch" {
    try testBatchInvContract(zf.BN254_Fp);
}

/// Randomised cross-check of the zero-tolerant `batchInv` against per-element
/// inversion, with zeros deliberately injected.
fn testBatchInvRandom(comptime F: type, seed: u64, iterations: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    for (0..iterations) |_| {
        const n = 1 + rnd.uintLessThan(usize, 8);
        var inputs: [8]F = undefined;
        var outputs: [8]F = undefined;
        for (0..n) |i| {
            inputs[i] = if (rnd.uintLessThan(u8, 4) == 0) F.zero() else F.random(rnd);
        }
        F.batchInv(inputs[0..n], outputs[0..n]);
        for (0..n) |i| {
            if (inputs[i].isZero()) {
                try std.testing.expect(outputs[i].isZero());
            } else {
                try std.testing.expect(inputs[i].mul(outputs[i]).isOne());
                try std.testing.expect(outputs[i].eq((try inputs[i].invChecked())));
            }
        }
    }
}

test "M31: batchInv matches per-element inversion at random" {
    try testBatchInvRandom(zf.M31, 1234, 50);
}

test "BN254_Fp: batchInv matches per-element inversion at random" {
    try testBatchInvRandom(zf.BN254_Fp, 4321, 10);
}

test "randomBounded(0) yields zero instead of dividing by zero" {
    var prng = std.Random.DefaultPrng.init(5);
    const rnd = prng.random();
    try std.testing.expect(zf.M31.randomBounded(rnd, 0).isZero());
    try std.testing.expect(zf.BN254_Fp.randomBounded(rnd, 0).isZero());
    // A bound larger than the modulus is still clamped to the field.
    try std.testing.expect(zf.M31.randomBounded(rnd, std.math.maxInt(u64)).toInt() < zf.M31.MODULUS);
    try std.testing.expect(zf.BN254_Fp.randomBounded(rnd, std.math.maxInt(u512)).toInt() < zf.BN254_Fp.MODULUS);
}

test "M61 field basic arithmetic" {
    const F = zf.M61;
    const a = F.fromInt(123456789);
    const b = F.fromInt(987654321);

    try std.testing.expect(a.add(b).eq(b.add(a)));
    try std.testing.expect(a.mul(b).eq(b.mul(a)));
    try std.testing.expect(a.mul(a.inv()).isOne());
    try std.testing.expect(a.add(a.neg()).isZero());

    // Vec8 should not be available for M61 (not 31 bits)
    // This is a compile-time check, so we verify the type is void
    comptime {
        std.debug.assert(F.Vec8 == void);
    }
}

test "SmallField: multiExp correctness" {
    const F = zf.M31;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    // Test with random bases and exponents (reduced modulo p-1)
    const bases = [_]F{
        F.random(rnd), F.random(rnd), F.random(rnd), F.random(rnd),
        F.random(rnd), F.random(rnd), F.random(rnd), F.random(rnd),
    };
    const exponents = [_]u64{
        rnd.int(u64) % (F.MODULUS - 1), rnd.int(u64) % (F.MODULUS - 1),
        rnd.int(u64) % (F.MODULUS - 1), rnd.int(u64) % (F.MODULUS - 1),
        rnd.int(u64) % (F.MODULUS - 1), rnd.int(u64) % (F.MODULUS - 1),
        rnd.int(u64) % (F.MODULUS - 1), rnd.int(u64) % (F.MODULUS - 1),
    };

    const multi_result = try F.multiExp(&bases, &exponents, 4);

    // Compare with individual pow and mul
    var expected = F.one();
    for (bases, exponents) |base_, exp| {
        expected = expected.mul(base_.pow(exp));
    }

    if (DEBUG_MULTIEXP) {
        std.debug.print("SmallField multi_result: {}\n", .{multi_result});
        std.debug.print("SmallField expected: {}\n", .{expected});
    }

    try std.testing.expect(multi_result.eq(expected));
}

test "SmallField: multiExp simple case" {
    const F = zf.M31;
    // Simple test: bases = [2, 3], exponents = [2, 3]
    // Expected: 2^2 * 3^3 = 4 * 27 = 108
    const bases = [_]F{ F.fromInt(2), F.fromInt(3) };
    const exponents = [_]u64{ 2, 3 };

    const multi_result = try F.multiExp(&bases, &exponents, 2);

    var expected = F.one();
    for (bases, exponents) |base_, exp| {
        expected = expected.mul(base_.pow(exp));
    }

    if (DEBUG_MULTIEXP) {
        std.debug.print("Simple multi_result: {}\n", .{multi_result});
        std.debug.print("Simple expected: {}\n", .{expected});
    }

    try std.testing.expect(multi_result.eq(expected));
}

test "SmallField: multiExp with zero exponents" {
    const F = zf.M31;
    const bases = [_]F{ F.fromInt(2), F.fromInt(3), F.fromInt(5) };
    const exponents = [_]u64{ 0, 0, 0 };

    const result = try F.multiExp(&bases, &exponents, 3);
    try std.testing.expect(result.isOne());
}

test "BigField: multiExp correctness" {
    const F = zf.BN254_Fp;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    const bases = [_]F{
        F.random(rnd), F.random(rnd), F.random(rnd), F.random(rnd),
    };
    const exponents = [_]u512{
        rnd.int(u512) % (F.MODULUS - 1), rnd.int(u512) % (F.MODULUS - 1),
        rnd.int(u512) % (F.MODULUS - 1), rnd.int(u512) % (F.MODULUS - 1),
    };

    const multi_result = try F.multiExp(&bases, &exponents, 4);

    // Compare with individual pow and mul
    var expected = F.one();
    for (bases, exponents) |base_, exp| {
        expected = expected.mul(base_.pow(exp));
    }

    if (DEBUG_MULTIEXP) {
        std.debug.print("BigField multi_result: {}\n", .{multi_result});
        std.debug.print("BigField expected: {}\n", .{expected});
    }

    try std.testing.expect(multi_result.eq(expected));
}

test "StarkNet_Fp basic arithmetic" {
    const F = zf.StarkNet_Fp;
    const a = F.fromInt(123456789);
    const b = F.fromInt(987654321);

    try std.testing.expect(a.add(b).eq(b.add(a)));
    try std.testing.expect(a.mul(b).eq(b.mul(a)));
    try std.testing.expect(a.mul(a.inv()).isOne());
    try std.testing.expect(a.add(a.neg()).isZero());
    try std.testing.expect(a.sub(b).eq(a.add(b.neg())));

    // Serialization round-trip
    const bytes = a.toBytes();
    const a2 = try F.fromBytes(&bytes);
    try std.testing.expect(a.eq(a2));
}

test "Pallas_Fp basic arithmetic" {
    const F = zf.Pallas_Fp;
    const a = F.fromInt(123456789);
    const b = F.fromInt(987654321);

    try std.testing.expect(a.add(b).eq(b.add(a)));
    try std.testing.expect(a.mul(b).eq(b.mul(a)));
    try std.testing.expect(a.mul(a.inv()).isOne());
    try std.testing.expect(a.add(a.neg()).isZero());
}

test "Vesta_Fp basic arithmetic" {
    const F = zf.Vesta_Fp;
    const a = F.fromInt(123456789);
    const b = F.fromInt(987654321);

    try std.testing.expect(a.add(b).eq(b.add(a)));
    try std.testing.expect(a.mul(b).eq(b.mul(a)));
    try std.testing.expect(a.mul(a.inv()).isOne());
    try std.testing.expect(a.add(a.neg()).isZero());
}

test "Pasta fields are a 2-cycle" {
    // Pallas scalar = Vesta base, Vesta scalar = Pallas base
    // Verify by checking the modulus relationship
    const pallas_p = zf.Pallas_Fp.MODULUS;
    const vesta_p = zf.Vesta_Fp.MODULUS;

    // Both are 255-bit primes
    try std.testing.expect(pallas_p > (1 << 254));
    try std.testing.expect(vesta_p > (1 << 254));

    // They are different
    try std.testing.expect(pallas_p != vesta_p);
}

test "SmallField randomBounded" {
    const F = zf.M31;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    for (0..100) |_| {
        const bound = 1000;
        const v = F.randomBounded(rnd, bound);
        try std.testing.expect(v.toInt() < bound);
    }
}

test "BigField randomBounded" {
    const F = zf.BN254_Fp;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    for (0..20) |_| {
        const bound: u512 = 1000000;
        const v = F.randomBounded(rnd, bound);
        try std.testing.expect(v.toInt() < bound);
    }
}

test "randomBounded boundary values" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();

    try std.testing.expect(zf.M31.randomBounded(rnd, 1).isZero());
    for (0..8) |_| {
        try std.testing.expect(zf.M31.randomBounded(rnd, zf.M31.MODULUS).toInt() < zf.M31.MODULUS);
        try std.testing.expect(zf.BN254_Fp.randomBounded(rnd, zf.BN254_Fp.MODULUS).toInt() < zf.BN254_Fp.MODULUS);
    }
}

test "SmallField isNegative" {
    const F = zf.M31;
    const half = F.MODULUS / 2;

    try std.testing.expect(!F.fromInt(1).isNegative());
    try std.testing.expect(!F.fromInt(half).isNegative());
    try std.testing.expect(F.fromInt(half + 1).isNegative());
    try std.testing.expect(F.fromInt(F.MODULUS - 1).isNegative());
}

test "SmallField lexicographicCmp" {
    const F = zf.M31;
    const a = F.fromInt(10);
    const b = F.fromInt(20);
    const c = F.fromInt(10);

    try std.testing.expect(a.lexicographicCmp(b) == -1);
    try std.testing.expect(b.lexicographicCmp(a) == 1);
    try std.testing.expect(a.lexicographicCmp(c) == 0);
}

test "BigField isNegative" {
    const F = zf.BN254_Fp;
    try std.testing.expect(!F.fromInt(1).isNegative());
}
