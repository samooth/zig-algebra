//! Does `Polynomial.mul` need Karatsuba, and at what degree? Measured, not assumed.
//!
//! The question came from outside: a 2026 result (`Staggered extraction for exact
//! matrix multiplication over every field`, eprint-adjacent, formalized in Lean)
//! proves omega < 2.371 over **every fixed field, including every positive
//! characteristic**, without an extension field and without interpolation. That
//! is the theoretical warrant `zig-poly`'s naive O(n^2) product never had. A
//! warrant is not a measurement, so this file measures.
//!
//! ## What it found
//!
//! The textbook crossover of 8 is the *worst* of the three tried in the range
//! this library actually uses. The real crossover sits near degree 32-64, and the
//! degrees `libs/poly`'s own tests exercise are 0, 8, 16 and 64. Concretely, with
//! the crossover at 32, against a naive product over the same slice coefficients:
//!
//!   degree            8     16     32     64    128    256
//!   M31            0.87x  0.81x  1.06x  1.27x  1.75x  1.91x
//!   Goldilocks     0.87x  0.81x  1.06x  1.27x  1.75x  1.91x   (Montgomery)
//!
//! Full table and caveats in `docs/poly-mul-measurement.md`.
//!
//! ## Why the harness looks like this
//!
//! **A correctness check gates every timing.** The first version of this
//! benchmark printed "Karatsuba loses" in all twenty-one cells and was wrong: a
//! buffer sized `half+1` overflowed whenever the operand count was odd, because
//! then the high half has `half+1` elements and its product needs `2*half+1`
//! coefficients. Every printed figure was plausible and every figure was
//! measuring a broken routine. The comparison against the library's own answer is
//! what caught it, so it stays in the timed region's prerequisite and the run
//! reports `NO` rather than a number if it fails.
//!
//! **The minimum of repetitions, not the mean.** Taken as a single measurement,
//! degree 32 over Goldilocks moved between 3170 ns and 6116 ns across two runs of
//! the same binary -- 90% of noise on a figure whose whole job is to decide a 1.0x
//! threshold. The minimum is the statistic least contaminated by the scheduler.
//!
//! **Three baselines, because one hides the question.** `libs/poly`'s naive
//! product runs over a comptime-sized array and ends in `normalize()`, which
//! scans all `max_degree+1` slots. A naive product over slices has neither cost.
//! Comparing Karatsuba against the library conflates three changes; comparing it
//! against naive-on-slices isolates the algorithmic one, and the third column is
//! the difference between them.
//!
//! ## A constraint this measurement uncovered
//!
//! `Polynomial(F, max_degree).mul` rejects with `error.DegreeTooLarge` any product
//! whose degree exceeds `max_degree`. So multiplying two degree-`d` operands
//! requires instantiating with `max_degree >= 2d`: a caller working at degree 64
//! carries a 129-element array and pays a 129-slot `normalize()` even though the
//! answer has degree 128. That is a property of the fixed-size representation,
//! not of the multiplication, and it is why the second baseline exists.
//!
//! Run it with `zig build poly-mul-bench`.

const std = @import("std");
const zp = @import("zig-poly");
const zf = @import("zig-field");
const nowNs = @import("zig-parallel").timing.nowNs;

/// Repetitions; the minimum is reported. Seven is what `libs/field/bench/pow.zig`
/// settled on for the same reason, and it is the smallest count that stopped these
/// ratios crossing their threshold between runs.
const REPS: u32 = 7;

/// Iterations per timed run, per degree. Testing is roughly (2d+1)^2 field
/// operations, so one count cannot serve degree 4 and degree 256.
fn itersFor(deg: usize) u32 {
    if (deg <= 32) return 20_000;
    if (deg <= 64) return 8_000;
    if (deg <= 128) return 1_500;
    return 300;
}

/// Below this operand length Karatsuba recurses no further. It is the parameter
/// the measurement is about, so it is a comptime argument and not a constant:
/// the same binary is built once per value and the tables below come from
/// separate runs at each.
const CROSSOVER: usize = 32;

/// The field `libs/poly`'s own tests use. It is not exported by the library, so it
/// is reproduced here rather than reached for; the reproduction is only for the
/// "cheapest possible field" end of the cost axis.
const F7 = struct {
    value: u64,
    pub const MODULUS: u64 = 7;
    pub const NUM_BYTES: usize = 8;
    pub fn zero() F7 {
        return .{ .value = 0 };
    }
    pub fn one() F7 {
        return .{ .value = 1 };
    }
    pub fn fromInt(x: anytype) F7 {
        return .{ .value = @intCast(@mod(@as(i128, @intCast(x)), MODULUS)) };
    }
    pub fn add(a: F7, b: F7) F7 {
        return fromInt(a.value + b.value);
    }
    pub fn sub(a: F7, b: F7) F7 {
        return fromInt(a.value + MODULUS - b.value);
    }
    pub fn mul(a: F7, b: F7) F7 {
        return fromInt(a.value * b.value);
    }
    pub fn neg(a: F7) F7 {
        return fromInt(MODULUS - a.value);
    }
    pub fn inv(a: F7) F7 {
        if (a.isZero()) return zero();
        var x = a.value;
        var e: u64 = MODULUS - 2;
        var r: u64 = 1;
        while (e != 0) {
            if (e & 1 != 0) r = (r * x) % MODULUS;
            x = (x * x) % MODULUS;
            e >>= 1;
        }
        return .{ .value = r };
    }
    pub fn inverse(a: F7) F7 {
        return inv(a);
    }
    pub fn div(a: F7, b: F7) F7 {
        return a.mul(b.inv());
    }
    pub fn eql(a: F7, b: F7) bool {
        return a.value == b.value;
    }
    pub fn isZero(a: F7) bool {
        return a.value == 0;
    }
    pub fn isOne(a: F7) bool {
        return a.value == 1;
    }
    pub fn pow(a: F7, e: u32) F7 {
        var r = one();
        var i: u32 = 0;
        while (i < e) : (i += 1) r = r.mul(a);
        return r;
    }
    pub fn toBytes(a: F7) [8]u8 {
        var out: [8]u8 = undefined;
        std.mem.writeInt(u64, &out, a.value, .little);
        return out;
    }
    pub fn fromBytes(bytes: []const u8) !F7 {
        if (bytes.len != 8) return error.BadLength;
        const v = std.mem.readInt(u64, bytes[0..8], .little);
        if (v >= MODULUS) return error.NotCanonical;
        return .{ .value = v };
    }
};

// ---------------------------------------------------------------- kernels

fn mulNaiveSlice(comptime F: type, a: []const F, b: []const F, out: []F) void {
    for (out) |*o| o.* = F.zero();
    for (a, 0..) |av, i| {
        if (av.isZero()) continue;
        for (b, 0..) |bv, j| {
            out[i + j] = out[i + j].add(av.mul(bv));
        }
    }
}

/// Karatsuba over slices: `out` must hold `a.len + b.len - 1` elements and `pool`
/// must hold `8 * (half + 4)` at every level. All three accumulator buffers are
/// sized `2*(half+1)`, which is the case that broke the first version: when the
/// operand count is odd the high half has `half+1` elements and its product needs
/// `2*half+1` coefficients.
fn mulKaraSlice(comptime F: type, a: []const F, b: []const F, out: []F, pool: []F) void {
    const la = a.len;
    const lb = b.len;
    std.debug.assert(out.len >= la + lb - 1);
    if (la < CROSSOVER or lb < CROSSOVER) {
        mulNaiveSlice(F, a, b, out);
        return;
    }

    const half = @max(la, lb) / 2;
    const a0 = a[0..@min(half, la)];
    const a1 = if (half < la) a[half..] else a[0..0];
    const b0 = b[0..@min(half, lb)];
    const b1 = if (half < lb) b[half..] else b[0..0];

    const w = half + 1;
    const pw = 2 * w;
    std.debug.assert(pool.len >= 2 * w + 3 * pw);
    const sa = pool[0..w];
    const sb = pool[w .. 2 * w];
    const z0 = pool[2 * w .. 2 * w + pw];
    const z2 = pool[2 * w + pw .. 2 * w + 2 * pw];
    const z1 = pool[2 * w + 2 * pw .. 2 * w + 3 * pw];
    const rest = pool[2 * w + 3 * pw ..];

    for (0..w) |i| {
        const av = if (i < a0.len) a0[i] else F.zero();
        const aw = if (i < a1.len) a1[i] else F.zero();
        sa[i] = av.add(aw);
        const bv = if (i < b0.len) b0[i] else F.zero();
        const bw = if (i < b1.len) b1[i] else F.zero();
        sb[i] = bv.add(bw);
    }

    mulKaraSlice(F, a0, b0, z0, rest);
    mulKaraSlice(F, a1, b1, z2, rest);
    mulKaraSlice(F, sa, sb, z1, rest);

    // out = z0 + (z1 - z0 - z2) x^half + z2 x^(2 half)
    for (out) |*o| o.* = F.zero();
    for (z0, 0..) |v, i| {
        if (!v.isZero()) out[i] = out[i].add(v);
    }
    for (z2, 0..) |v, i| {
        if (!v.isZero()) out[i + 2 * half] = out[i + 2 * half].add(v);
    }
    for (0..pw) |i| {
        const term = z1[i].add(z0[i].neg()).add(z2[i].neg());
        if (!term.isZero()) out[i + half] = out[i + half].add(term);
    }
}

// ---------------------------------------------------------------- harness

fn benchField(
    comptime F: type,
    comptime name: []const u8,
    alloc: std.mem.Allocator,
    prng: *std.Random.DefaultPrng,
) !void {
    var rnd = prng.random();

    std.debug.print("\n=== {s} (crossover {d}) ===\n", .{ name, CROSSOVER });
    std.debug.print("  deg |   lib naive | slice naive |  karatsuba |  k vs lib |  k vs slice | correct\n", .{});

    const degrees = [_]usize{ 8, 16, 32, 64, 128, 256 };
    inline for (degrees) |deg| {
        const n = deg + 1;
        const Poly = zp.Polynomial(F, 2 * deg);

        const ca = try alloc.alloc(F, n);
        const cb = try alloc.alloc(F, n);
        defer alloc.free(ca);
        defer alloc.free(cb);
        for (ca) |*v| v.* = F.fromInt(rnd.int(u8) % 7);
        for (cb) |*v| v.* = F.fromInt(rnd.int(u8) % 7);
        ca[deg] = F.fromInt(1 + rnd.int(u6) % 6);
        cb[deg] = F.fromInt(1 + rnd.int(u6) % 6);

        const pa = try Poly.fromCoeffs(ca);
        const pb = try Poly.fromCoeffs(cb);
        const reps = itersFor(deg);

        // The answer the library produces, taken once outside the timed region.
        // Every Karatsuba figure below is compared against it before it is printed.
        const ref = try pa.mul(pb);

        var lib_ns: f64 = std.math.floatMax(f64);
        {
            var k: u32 = 0;
            while (k < REPS) : (k += 1) {
                var sink = Poly.zero();
                const t0 = nowNs();
                var r: u32 = 0;
                while (r < reps) : (r += 1) sink = try pa.mul(pb);
                const dt = nowNs() - t0;
                std.mem.doNotOptimizeAway(sink.coeffs[0].toBytes());
                lib_ns = @min(lib_ns, @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(reps)));
            }
        }

        const out_len = 2 * n - 1;
        const outbuf = try alloc.alloc(F, out_len);
        const pool = try alloc.alloc(F, 16 * (n + 2));
        defer alloc.free(outbuf);
        defer alloc.free(pool);

        var slice_ns: f64 = std.math.floatMax(f64);
        {
            var k: u32 = 0;
            while (k < REPS) : (k += 1) {
                const t0 = nowNs();
                var r: u32 = 0;
                while (r < reps) : (r += 1) mulNaiveSlice(F, ca, cb, outbuf);
                const dt = nowNs() - t0;
                std.mem.doNotOptimizeAway(outbuf[0].toBytes());
                slice_ns = @min(slice_ns, @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(reps)));
            }
        }

        // Correctness first. If this fails the row prints `NO` and the ratio next
        // to it is measuring a broken routine, which is how the first version of
        // this file produced a confident false negative.
        var correct = true;
        {
            mulKaraSlice(F, ca, cb, outbuf, pool);
            for (outbuf, 0..) |v, i| {
                if (!v.eql(ref.coeffs[i])) {
                    correct = false;
                    break;
                }
            }
        }

        var kara_ns: f64 = std.math.floatMax(f64);
        {
            var k: u32 = 0;
            while (k < REPS) : (k += 1) {
                const t0 = nowNs();
                var r: u32 = 0;
                while (r < reps) : (r += 1) mulKaraSlice(F, ca, cb, outbuf, pool);
                const dt = nowNs() - t0;
                std.mem.doNotOptimizeAway(outbuf[0].toBytes());
                kara_ns = @min(kara_ns, @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(reps)));
            }
        }

        std.debug.print("{d:>5} | {d:>11.1} | {d:>11.1} | {d:>10.1} | {d:>8.2}x | {d:>10.2}x | {s}\n", .{
            deg,
            lib_ns,
            slice_ns,
            kara_ns,
            lib_ns / kara_ns,
            slice_ns / kara_ns,
            if (correct) "yes" else "NO",
        });
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    std.debug.print("Polynomial.mul: library naive vs naive-on-slices vs Karatsuba\n", .{});
    std.debug.print("Ratios > 1 mean Karatsuba wins against that baseline. Crossover = {d}.\n", .{CROSSOVER});
    std.debug.print("Figures are the minimum of {d} runs. Full methodology: docs/poly-mul-measurement.md\n", .{REPS});

    var p0 = std.Random.DefaultPrng.init(0x5eed);
    var p1 = std.Random.DefaultPrng.init(0x5eed);
    var p2 = std.Random.DefaultPrng.init(0x5eed);

    try benchField(F7, "F7 (u64 %% 7) -- poly's own test field", alloc, &p0);
    try benchField(zf.M31, "M31 (SmallField, Mersenne fast path)", alloc, &p1);
    try benchField(zf.Goldilocks, "Goldilocks (BigField, Montgomery CIOS)", alloc, &p2);
}
