//! Massive randomized property testing (fuzzing) entry point.
//!
//! Runs field axiom checks at 1M+ iterations per field, pairing bilinearity
//! over many random scalar pairs, and randomized FRI/Sumcheck round trips.
//! Intended for the nightly CI job (`zig build fuzz`) in ReleaseFast; far too
//! slow for Debug.
//!
//! # The seed
//!
//! This used to be `var timer_seed: u64 = 0xF00D` -- a constant with a name
//! that implied otherwise. A nightly job that re-runs the same 1.1M values
//! every night explores nothing, while reporting "all fuzz checks passed" and
//! carrying the step description "massive randomized property tests". The
//! count was massive; the randomization was one seed, forever.
//!
//! So the seed now comes from the clock by default, is **printed on the first
//! line of output**, and can be pinned: `zig build fuzz -- <seed>`. A failure
//! that cannot be reproduced is a check that cannot be investigated, and a
//! seed nobody printed is a seed nobody can replay.

const std = @import("std");
const zf = @import("zig-field");
const zc = @import("zig-curve");
const bf = @import("zig-binary-field");
const fri = @import("zig-fri");
const zp = @import("zig-parallel");
const zh = @import("zig-hash");
const tp = @import("zig-pairing").bn254_tower_pairing;

const Transcript = @import("zig-transcript").Transcript;

/// The seed for this run: `argv[1]` if given, else the wall clock.
///
/// Uses `zig-parallel`'s portable clock rather than `std.time`, which does not
/// exist in Zig 0.16 (see AGENTS.md, "Common Gotchas").
fn resolveSeed(args: std.process.Args) u64 {
    var it = std.process.Args.Iterator.init(args);
    _ = it.next();
    if (it.next()) |arg| {
        const parsed = std.fmt.parseInt(u64, arg, 0) catch {
            std.debug.print("seed: {s} is not a u64; using the clock instead\n", .{arg});
            return zp.timing.nowNs();
        };
        return parsed;
    }
    return zp.timing.nowNs();
}

/// Field axioms for the prime fixtures.
///
/// Not `zf.checkFieldAxioms`: that helper ends with `toBytes()` returning an
/// array, which is the `SmallField` contract in AGENTS.md, while the fixtures
/// take an output buffer. Rather than bend the fixtures' API to fit the
/// helper -- they are test-only, and the buffer form is what every caller in
/// the tree uses -- the axioms are written here against the API they actually
/// have, plus the byte round trip the helper would have covered.
fn checkPrimeFieldAxioms(comptime F: type, iterations: usize, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (0..iterations) |_| {
        const a = F.random(rand);
        const b = F.random(rand);
        const c = F.random(rand);
        try std.testing.expect(a.add(b).add(c).eql(a.add(b.add(c))));
        try std.testing.expect(a.add(b).eql(b.add(a)));
        try std.testing.expect(a.add(F.zero()).eql(a));
        try std.testing.expect(a.add(a.neg()).isZero());
        try std.testing.expect(a.mul(b).mul(c).eql(a.mul(b.mul(c))));
        try std.testing.expect(a.mul(b).eql(b.mul(a)));
        try std.testing.expect(a.mul(F.one()).eql(a));
        try std.testing.expect(a.mul(b.add(c)).eql(a.mul(b).add(a.mul(c))));
        if (!a.isZero()) {
            try std.testing.expect(a.mul(a.inv()).eql(F.one()));
        }
        // Serialization round trip, the part the shared helper could not run.
        var buf: [F.NUM_BYTES]u8 = undefined;
        a.toBytes(&buf);
        const recovered = F.fromBytes(buf);
        try std.testing.expect(recovered.eql(a));
    }
}

pub fn main(init: std.process.Init) !void {
    const seed = resolveSeed(init.minimal.args);
    // First line on purpose: it is what a reader pastes into `-- <seed>`.
    std.debug.print("== zig-algebra mass fuzz ==\nseed: {d}\n", .{seed});

    // ---- BLAKE3, against canonical vectors AND the stdlib ----
    //
    // The fuzz runner could not see a hash at all before, so `zig-hash`'s
    // Blake3 shipped as a non-BLAKE3 for the whole life of the repository:
    // a self-consistent compression, verified only by tests written against
    // itself. Two independent checks here. The literals pin the known answers
    // so the test cannot drift with any implementation in the tree, and
    // `std.crypto.hash.Blake3` -- which is correct, and is what `zig-fri` and
    // `zig-transcript` use -- is the differential for random lengths, so the
    // KAT does not have to enumerate 4096 bytes to be convincing.
    {
        const literals = [_]struct { input: []const u8, digest: []const u8 }{
            .{ .input = "", .digest = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262" },
            .{ .input = "abc", .digest = "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85" },
            .{ .input = "hello world", .digest = "d74981efa70a0c880b8d8c1985d075dbcbf679b99a5f9914e5aaf96b831a9e24" },
        };
        for (literals) |v| {
            const got = zh.hashBlake3(v.input);
            const hex = std.fmt.bytesToHex(got, .lower);
            if (!std.mem.eql(u8, v.digest, &hex)) {
                std.debug.print("FAIL BLAKE3 KAT on {d}-byte input:\n  want {s}\n  got  {s}\n", .{ v.input.len, v.digest, &hex });
                return error.Blake3KatFailed;
            }
        }

        // Differential across the lengths that matter: BLAKE3's chunk is 1024
        // bytes, so block edges, the chunk counter and the parent tree all
        // live at and around 1024, 2048 and 4096.
        var buf: [4200]u8 = undefined;
        var prng_h = std.Random.DefaultPrng.init(0xB1AE3 +% seed);
        const rand_h = prng_h.random();
        for (&buf) |*b| b.* = rand_h.int(u8);
        const lengths = [_]usize{ 0, 1, 2, 3, 63, 64, 65, 1023, 1024, 1025, 2047, 2048, 2049, 4095, 4096, 4097, 4200 };
        for (lengths) |n| {
            const got = zh.hashBlake3(buf[0..n]);
            var want: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(buf[0..n], &want, .{});
            if (!std.mem.eql(u8, &got, &want)) {
                std.debug.print("FAIL BLAKE3 vs stdlib at len={d}\n", .{n});
                return error.Blake3Mismatch;
            }
        }
        std.debug.print("BLAKE3: 3 literal vectors + {d} differential lengths OK\n", .{lengths.len});
    }

    // ---- Field axioms ----
    var timer_seed: u64 = seed;
    const fields = .{
        .{ "M31", zf.M31, 1_000_000 },
        .{ "BN254_Fp", zf.BN254_Fp, 100_000 },
        .{ "BLS12_381_Fp", zf.BLS12_381_Fp, 20_000 },
    };
    inline for (fields) |spec| {
        try zf.checkFieldAxioms(spec[1], spec[2], 0xA11CE +% timer_seed);
        std.debug.print("axioms {s}: {d} iterations OK\n", .{ spec[0], spec[2] });
        timer_seed +%= 1000;
    }

    // ---- Prime fixtures: axioms, at fuzz scale ----
    //
    // `Prime31` and `Prime128` are fields the nightly job could not see before:
    // the fuzz gate was green while never constructing one, so it could not
    // have caught a regression in them -- which is exactly where the
    // characteristic-2 sum-check fold lived for three releases.
    try checkPrimeFieldAxioms(bf.prime_fixture.Prime31, 200_000, 0xBEEF +% timer_seed);
    std.debug.print("axioms Prime31: 200000 iterations OK\n", .{});
    try checkPrimeFieldAxioms(bf.prime128.Prime128, 20_000, 0xCAFE +% timer_seed);
    std.debug.print("axioms Prime128: 20000 iterations OK\n", .{});

    // ---- Prime128 against an independent native-u256 oracle ----
    //
    // The field reduces by hand through `2^128 == 159`; the oracle is the
    // language's own 256-bit multiply and remainder. Different techniques, so
    // disagreement is a real signal. Axioms alone would not catch a fold that
    // is self-consistently wrong.
    {
        const P = bf.prime128.PRIME;
        var prng = std.Random.DefaultPrng.init(0xDEAD +% timer_seed);
        const rand = prng.random();
        var mismatches: usize = 0;
        for (0..50_000) |_| {
            const a = bf.prime128.Prime128.random(rand);
            const b = bf.prime128.Prime128.random(rand);
            const p: u256 = @as(u256, P);
            const want_mul = @as(u128, @intCast((@as(u256, a.toInt()) * b.toInt()) % p));
            const want_add = @as(u128, @intCast((@as(u256, a.toInt()) + b.toInt()) % p));
            if (a.mul(b).toInt() != want_mul) mismatches += 1;
            if (a.add(b).toInt() != want_add) mismatches += 1;
        }
        if (mismatches != 0) {
            std.debug.print("FAIL Prime128 vs native u256 oracle: {d} mismatches\n", .{mismatches});
            return error.OracleMismatch;
        }
        std.debug.print("Prime128 vs native u256 oracle: 100000 ops agree\n", .{});
    }

    // ---- Sumcheck round trips, both entry points ----
    //
    // `Sumcheck(Prime128)` is the **secure** path (`MIN_SAFE_BITS = 128`); the
    // 31-bit field can only reach `SumcheckUnsafe`. Both are exercised here.
    //
    // What this protocol does and does not prove is worth writing down, because
    // getting it wrong produces a check that is confidently, continuously
    // wrong. `Sumcheck` proves the **hypercube sum** `sum_x prod_j f_j(x)`,
    // and the prover can do that honestly for *any* table, random or not. The
    // low-degree property is not its claim; FRI's folding and the final
    // residual are what test that. The first version of this check asserted
    // that random data must be rejected, and it failed 80/80 -- the check was
    // wrong, not the sum-check.
    //
    // So the two directions that actually discriminate are: an honest proof
    // verifies, and a tampered one does not. Both, on both entry points.
    {
        var prng = std.Random.DefaultPrng.init(0x5C4E +% timer_seed);
        const rand = prng.random();
        var honest_ok: usize = 0;
        var tampered_rejected: usize = 0;
        var total: usize = 0;

        const P31 = bf.prime_fixture.Prime31;
        const Unsafe = bf.sumcheck.SumcheckUnsafe(P31);
        const P128 = bf.prime128.Prime128;
        const Secure = bf.sumcheck.Sumcheck(P128);
        const alloc = std.heap.page_allocator;

        for (0..40) |_| {
            const k: usize = 1 + rand.uintLessThan(u8, 4); // 1..4 variables
            const n: usize = @as(usize, 1) << @intCast(k);
            total += 2;

            var table: [16]P128 = undefined;
            for (0..n) |i| table[i] = P128.random(rand);
            var table31: [16]P31 = undefined;
            for (0..n) |i| table31[i] = P31.random(rand);

            // The table is exactly `2^k` long: the verifier rejects anything
            // else with `InvalidTableLength`, a different question from this one.
            const tabs128 = [_][]const P128{table[0..n]};
            var p128 = try Secure.prove(alloc, k, &tabs128);
            defer p128.deinit(alloc);
            if (try Secure.verify(alloc, k, &tabs128, p128)) {
                honest_ok += 1;
            }
            // Tamper the claimed sum. `false` here is meaningful only because
            // the honest proof above verified on the same code path.
            p128.claimed_sum = p128.claimed_sum.add(P128.one());
            if (!try Secure.verify(alloc, k, &tabs128, p128)) {
                tampered_rejected += 1;
            }

            const tabs31 = [_][]const P31{table31[0..n]};
            var p31 = try Unsafe.prove(alloc, k, &tabs31);
            defer p31.deinit(alloc);
            if (try Unsafe.verify(alloc, k, &tabs31, p31)) {
                honest_ok += 1;
            }
            p31.claimed_sum = p31.claimed_sum.add(P31.one());
            if (!try Unsafe.verify(alloc, k, &tabs31, p31)) {
                tampered_rejected += 1;
            }
        }
        if (honest_ok != total or tampered_rejected != total) {
            std.debug.print(
                "FAIL Sumcheck: honest {d}/{d} verified, tampered {d}/{d} rejected\n",
                .{ honest_ok, total, tampered_rejected, total },
            );
            return error.SumcheckDiscriminationFailed;
        }
        std.debug.print("Sumcheck: {d} honest verified, {d} tampered rejected (both entry points)\n", .{ honest_ok, tampered_rejected });
    }

    // ---- FRI round trips over the torus, in M31 and M61 ----
    //
    // Also the only place the torus is exercised at scale. The nightly job
    // could not have caught a regression in `torus.zig` before, because it
    // never imported `zig-fri`.
    {
        var prng = std.Random.DefaultPrng.init(0x7070 +% timer_seed);
        const rand = prng.random();
        const T31 = fri.torus.Torus31;
        const D31 = fri.torus.TorusDomain(T31, zf.M31);
        const T61 = fri.torus.Torus61;
        const D61 = fri.torus.TorusDomain(T61, zf.M61);

        inline for (.{ .{ T31, D31 }, .{ T61, D61 } }) |pair| {
            const F = pair[0];
            const Dom = pair[1];
            for (0..20) |_| {
                // Config validity is `Config.validate`, and it is stricter than
                // it looks: it requires
                //   log_initial_degree - (log_domain - log_final)
                //       == log_residual_degree,
                // so `log_initial_degree` is *derived* here rather than
                // guessed. Guessing it returns InvalidParameters.
                const log_n: u6 = @intCast(5 + rand.uintLessThan(u8, 3)); // 5..7
                const n: usize = @as(usize, 1) << @intCast(log_n);
                const log_final: u6 = 4;
                const log_residual_degree: u6 = 3;
                const cfg = fri.Config{
                    .log_domain = log_n,
                    .log_initial_degree = (log_n - log_final) + log_residual_degree,
                    .log_final = log_final,
                    .log_residual_degree = log_residual_degree,
                    .num_queries = 8,
                };
                const dom = try Dom.init(F, log_n);
                var evals = try std.heap.page_allocator.alloc(F, n);
                defer std.heap.page_allocator.free(evals);
                // Low degree: a quadratic in the domain point, which the FRI
                // degree bound accepts.
                const c1 = F.fromInt(3);
                const c2 = F.fromInt(7);
                for (0..n) |i| {
                    const x = dom.at(i);
                    evals[i] = x.sqr().add(x.mul(c1)).add(c2);
                }
                var pt = Transcript.init("mass-fuzz-torus");
                var proof = try fri.proveOn(F, Dom, std.heap.page_allocator, &pt, evals, cfg);
                defer proof.deinit(std.heap.page_allocator);
                var vt = Transcript.init("mass-fuzz-torus");
                if (!try fri.verifyOn(F, Dom, &vt, &proof, cfg)) {
                    std.debug.print("FAIL torus FRI round trip at log_n={d}\n", .{log_n});
                    return error.TorusFriFailed;
                }
            }
            std.debug.print("torus FRI: 20 honest round trips OK\n", .{});
        }
    }

    // ---- Pairing bilinearity: e(aP, bQ) == e(P,Q)^{ab} over random a,b ----
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    var prng = std.Random.DefaultPrng.init(0xB1A1EA +% timer_seed);
    const rand = prng.random();
    const pairs = 100;
    var i: usize = 0;
    while (i < pairs) : (i += 1) {
        var abuf: [32]u8 = undefined;
        var bbuf: [32]u8 = undefined;
        rand.bytes(&abuf);
        rand.bytes(&bbuf);
        const a = std.mem.readInt(u256, &abuf, .little) % 0x30644E72E131A029B85045B68181585D2833E84879B9709143E1F593F0000001;
        const b = std.mem.readInt(u256, &bbuf, .little) % 0x30644E72E131A029B85045B68181585D2833E84879B9709143E1F593F0000001;

        const lhs = tp.pairing(g1.scalarMul(a), g2.scalarMul(b));
        const rhs = tp.pairing(g1, g2).powFast(@as(u512, a) * @as(u512, b) % 0x30644E72E131A029B85045B68181585D2833E84879B9709143E1F593F0000001);
        if (!lhs.eql(rhs)) {
            std.debug.print("FAIL bilinearity at pair {d}\n", .{i});
            return error.BilinearityFailed;
        }
    }
    std.debug.print("pairing bilinearity: {d} random pairs OK (sparse path)\n", .{pairs});

    // ---- Sparse/dense agreement on random pairs ----
    i = 0;
    while (i < 10) : (i += 1) {
        const a = 2 + rand.uintLessThan(u64, 1 << 40);
        const b = 2 + rand.uintLessThan(u64, 1 << 40);
        if (!tp.pairingSparse(g1.scalarMul(a), g2.scalarMul(b)).eql(
            tp.pairingDense(g1.scalarMul(a), g2.scalarMul(b)),
        )) {
            std.debug.print("FAIL sparse==dense at pair {d}\n", .{i});
            return error.SparseDenseMismatch;
        }
    }
    std.debug.print("sparse==dense: 10 random pairs OK\n", .{});

    std.debug.print("== all fuzz checks passed ==\n", .{});
}
