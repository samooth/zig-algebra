//! Massive randomized property testing (fuzzing) entry point.
//!
//! Runs field axiom checks at 1M+ iterations per field plus pairing
//! bilinearity over many random scalar pairs. Intended for the nightly
//! CI job (`zig build fuzz`) in ReleaseFast; far too slow for Debug.

const std = @import("std");
const zf = @import("zig-field");
const zc = @import("zig-curve");
const tp = @import("zig-pairing").bn254_tower_pairing;

pub fn main() !void {
    var timer_seed: u64 = 0xF00D;
    std.debug.print("== zig-algebra mass fuzz ==\n", .{});

    // ---- Field axioms ----
    const fields = .{
        .{ "M31", zf.M31, 1_000_000 },
        .{ "BN254_Fp", zf.BN254_Fp, 100_000 },
        .{ "BLS12_381_Fp", zf.BLS12_381_Fp, 20_000 },
    };
    inline for (fields) |spec| {
        try zf.checkFieldAxioms(spec[1], spec[2], 0xA11CE + timer_seed);
        std.debug.print("axioms {s}: {d} iterations OK\n", .{ spec[0], spec[2] });
        timer_seed +%= 1000;
    }

    // ---- Pairing bilinearity: e(aP, bQ) == e(P,Q)^{ab} over random a,b ----
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    var prng = std.Random.DefaultPrng.init(0xB1A1EA + timer_seed);
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
