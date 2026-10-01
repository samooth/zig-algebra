//! Measure `pow` against `powFast` per field, with the sign that matters.
//!
//! One measurement is not a number. Measured once, Goldilocks came out at 0.79,
//! 0.89 and 1.28 across three runs -- it crossed 1.0, which is the line that
//! decides whether the fast path is faster at all. With a minimum of seven
//! repetitions it comes out 0.85, 0.84, 0.86. A figure that moves 60% between
//! runs cannot support any claim, including the claim that made this benchmark
//! necessary.
//!
//! So: one function, two branches selected at comptime so the two paths cannot
//! drift apart, a separate iteration count per operation because exponentiating
//! is roughly 500x a multiplication and one count cannot serve both, and the
//! **minimum** of the repetitions, which is the statistic least contaminated by
//! scheduler noise and page faults.
//!
//! The ratio printed is powFast / pow. **Greater than one means powFast is
//! SLOWER.** That is the reading which inverts the claim the docstrings used to
//! make, so it is the reading that matters, and it is why the ratio is the sign
//! it is. The figure is printed as an unsigned hundredths so that a signed `{d}`
//! does not put a `+` in the middle of the column.
//!
//! Why the ratio is field-dependent is NOT settled here. The plausible cause --
//! that a 31-bit field gives the window nothing to gain on while a 381-bit one
//! has many windows to place -- is a hypothesis about the code, not a
//! measurement, and it belongs in a report rather than in a comment that reads
//! like a finding. Settling it means reading each field's `pow`.
//!
//! Run it with `zig build pow-bench`. It is not a test: a timing assertion in
//! the suite is flaky by construction, which is the same reason the suite has no
//! timing test at all.

const std = @import("std");
const zf = @import("zig-field");
const nowNs = @import("zig-parallel").timing.nowNs;

/// Repetitions, and the minimum of them is the reported figure. Seven is the
/// smallest number tried that stopped the ratio crossing 1.0 between runs.
const REPS = 7;

/// Exponentiating is about 500x a multiplication, so the same count cannot time
/// both. `mul` is here only to show the scale the pow counts are chosen against.
const MUL_ITERS = 2_000_000;
const POW_ITERS = 4_000;

/// Wide enough for the big backend's `toInt()`, which returns u512.
var sink: u512 = 0;

/// A tuple of name/type pairs, walked with `inline for` in `main`. It cannot be an
/// array of a struct holding a `type`: a type is comptime-only, so the loop has to
/// be comptime for each field to be instantiated at all.
const CASES = .{
    .{ "M31", zf.M31 },
    .{ "BabyBear", zf.BabyBear },
    .{ "Goldilocks", zf.Goldilocks },
    .{ "M61", zf.M61 },
    .{ "StarkNet_Fp", zf.StarkNet_Fp },
    .{ "BN254_Fp", zf.BN254_Fp },
    .{ "BLS12_381_Fp", zf.BLS12_381_Fp },
};

fn runCase(comptime name: []const u8, comptime F: type, seed: u64) void {
    const slow = nsPerOp(F, false, POW_ITERS, seed);
    const fast = nsPerOp(F, true, POW_ITERS, seed);
    // Hundredths, unsigned: a signed `{d}` puts the sign mid-column, and the
    // column is the thing being compared.
    const ratio_x100: u64 = @intCast(@divTrunc(fast * 100, slow));
    const direction = if (fast > slow) "powFast SLOWER" else "powFast faster";
    std.debug.print(
        "{s:>14} {d:>10} {d:>11} {d:>13}  {s}\n",
        .{ name, slow, fast, ratio_x100, direction },
    );
    std.mem.doNotOptimizeAway(sink);
}

/// ns/op, as the minimum over REPS repetitions. `fast` selects the branch at
/// comptime so both paths run the same loop with the same base and the same
/// exponent.
fn nsPerOp(comptime F: type, comptime fast: bool, comptime iters: usize, seed: u64) u64 {
    // The exponent is the field's own width, not a fixed 64-bit constant: windowing
    // wins on wide exponents, so a narrow one would understate powFast on exactly
    // the fields where it is worth having. `MODULUS - 2` is full width for every
    // field -- 2^31-3 on M31, the whole 381-bit modulus on BLS12-381 -- and it is
    // the same relative input for both branches, so the comparison is about the
    // method and not about the operand.
    // The base MUST be a runtime value. With a compile-time base AND a
    // compile-time exponent, `a.pow(e)` is a compile-time constant: the first
    // version of this benchmark timed four fields at 0 ns/op for `pow` and real
    // numbers for `powFast`, because one branch folded and the other did not. That
    // reports powFast as infinitely slow on exactly the fields where it is not --
    // the right answer for the wrong reason, which is worse than no answer. `seed`
    // is read from the clock at startup, so the compiler cannot know it, and the
    // exponent stays fixed so both branches get the same input.
    const a = F.fromInt(seed | 1);
    // The exponent is an INTEGER at the field's own width -- `pow` and `powFast`
    // take `exp: anytype` and cast it internally, so passing a field element does
    // not compile, and passing a u512 to a 31-bit field would make `powFast` size
    // its window for 512 bits and distort the very ratio this measures. The width
    // is chosen at comptime, mirroring the library's own two backends.
    const Exp = if (F.BITS <= 64) u64 else u512;
    const e: Exp = @intCast(F.MODULUS - 2);

    var best: u64 = std.math.maxInt(u64);
    var rep: usize = 0;
    while (rep < REPS) : (rep += 1) {
        const start = nowNs();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const r = if (fast) a.powFast(e) else a.pow(e);
            sink +%= r.toInt();
        }
        const ns = (nowNs() - start) / iters;
        if (ns < best) best = ns;
    }
    return best;
}

fn mulNsPerOp(comptime F: type, seed: u64) u64 {
    const a = F.fromInt(seed | 1);
    var best: u64 = std.math.maxInt(u64);
    var rep: usize = 0;
    while (rep < REPS) : (rep += 1) {
        const start = nowNs();
        var i: usize = 0;
        while (i < MUL_ITERS) : (i += 1) {
            // Both operands vary with the loop, so the multiply cannot be hoisted
            // or folded the way a fixed-base one was. A first version of this line
            // reported 1 ns/op on M31, which is faster than a real 31-bit
            // multiply, and that number was the give-away.
            sink +%= a.mul(F.fromInt(@as(u64, @truncate(i)) ^ seed)).toInt();
        }
        const ns = (nowNs() - start) / MUL_ITERS;
        if (ns < best) best = ns;
    }
    return best;
}

pub fn main() !void {
    std.debug.print(
        "pow vs powFast — {d} fields, minimum of {d} repetitions, {d} pow iterations\n",
        .{ CASES.len, REPS, POW_ITERS },
    );
    std.debug.print(
        "ratio is powFast/pow: GREATER THAN 1 MEANS powFast IS SLOWER\n\n",
        .{},
    );
    std.debug.print(
        "{s:>14} {s:>10} {s:>11} {s:>13}  {s}\n",
        .{ "field", "pow ns/op", "powFast", "ratio x100", "direction" },
    );

    // The seed is a runtime value read once, so nothing inside the timed loops
    // can be folded to a constant.
    const seed = nowNs();
    inline for (CASES) |c| runCase(c[0], c[1], seed);

    const M = zf.M31;
    const mul = mulNsPerOp(M, seed);
    // The same measurement the table uses, not a fresh single call: an earlier
    // version timed one pow with iters=1, which includes call and loop overhead
    // and disagreed with its own table by 40%.
    const pow_same = nsPerOp(M, false, POW_ITERS, seed);
    std.debug.print(
        "\nscale check, M31: mul {d} ns/op against pow {d} ns/op, so one pow is about {d} muls\n" ++
            "— which is why the two operations get different iteration counts. The coordinator's\n" ++
            "estimate for the same ratio is about 500x, so treat this line as a sanity check on\n" ++
            "the shape of the table, not as a figure to quote.\n",
        .{ mul, pow_same, @divTrunc(pow_same, mul) },
    );
    std.mem.doNotOptimizeAway(sink);
}
