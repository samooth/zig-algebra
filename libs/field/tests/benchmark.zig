// SPDX-License-Identifier: MIT OR Apache-2.0

//! Micro-benchmarks for the predefined fields.
//!
//! Run with `zig build bench -Doptimize=ReleaseFast`.

const std = @import("std");
const builtin = @import("builtin");
const zf = @import("zig-field");

// Use higher iterations for small fields where operations are very fast
const iters_small = 100_000_000;
const iters_large = 10_000_000;

// Cross-platform monotonic clock using std.c.clock_gettime
// Linux: CLOCK_MONOTONIC (1), macOS: MONOTONIC (6), Windows: not supported via clock_gettime
fn getMonotonicNanos() i64 {
    const c = @import("std").c;
    var ts: c.timespec = undefined;
    const clock_id: c.clockid_t = switch (builtin.os.tag) {
        .linux, .emscripten => c.CLOCK.MONOTONIC,
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => c.CLOCK.MONOTONIC,
        .freebsd, .openbsd, .netbsd, .dragonfly => c.CLOCK.MONOTONIC,
        .haiku => c.CLOCK.MONOTONIC,
        .windows => return @as(i64, 0), // Windows: fallback to QueryPerformanceCounter below
        else => return @as(i64, 0),
    };
    const result = c.clock_gettime(clock_id, &ts);
    if (result != 0) return @as(i64, 0);
    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
}

// Windows-specific monotonic clock using QueryPerformanceCounter
fn getWindowsMonotonicNanos() i64 {
    const windows = @import("std").os.windows;
    const kernel32 = windows.kernel32;
    var frequency: i64 = 0;
    var counter: i64 = 0;
    // QueryPerformanceFrequency
    const freq_result = kernel32.QueryPerformanceFrequency(&frequency);
    if (freq_result == 0) return 0;
    // QueryPerformanceCounter
    const counter_result = kernel32.QueryPerformanceCounter(&counter);
    if (counter_result == 0) return 0;
    return (counter * 1_000_000_000) / frequency;
}

fn getNanos() i64 {
    return switch (builtin.os.tag) {
        .windows => getWindowsMonotonicNanos(),
        else => getMonotonicNanos(),
    };
}

var global_sink: i64 = 0;

// Debug function to test timing
fn testTiming() !void {
    const start = getNanos();
    var i: usize = 0;
    while (i < 10_000_000) : (i += 1) {
        global_sink += @as(i64, @intCast(i));
    }
    const end = getNanos();
    std.debug.print("Timing test: start={}, end={}, diff={} ns\n", .{start, end, end - start});
}

fn bench(comptime F: type, name: []const u8, iters: usize) !void {
    const a = F.fromInt(123456789);
    const b = F.fromInt(987654321);
    var acc = F.zero();

    // Warm up
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        acc = acc.add(b);
        acc = a.mul(b);
    }

    const start_add = getNanos();
    i = 0;
    while (i < iters) : (i += 1) {
        acc = acc.add(b);
        // Prevent loop optimization by using result
        global_sink += @intCast(acc.toInt());
    }
    const end_add = getNanos();
    const add_elapsed = end_add - start_add;

    const start_mul = getNanos();
    var j: usize = 0;
    while (j < iters) : (j += 1) {
        // Make multiplication depend on loop counter to prevent optimization
        acc = a.mul(F.fromInt(j));
        global_sink += @intCast(acc.toInt());
    }
    const end_mul = getNanos();
    const mul_elapsed = end_mul - start_mul;

    const add_ns = @divTrunc(add_elapsed, @as(i64, @intCast(iters)));
    const mul_ns = @divTrunc(mul_elapsed, @as(i64, @intCast(iters)));

    // Print raw elapsed for debugging
    std.debug.print("  raw: add_elapsed={} mul_elapsed={}\n", .{add_elapsed, mul_elapsed});

    std.debug.print(
        "{s:>12}: add {d:>6} ns/op  mul {d:>6} ns/op\n",
        .{ name, add_ns, mul_ns },
    );
}

pub fn main() !void {
    try testTiming();
    // Small fields: use more iterations for measurable times
    try bench(zf.M31, "M31", iters_small);
    try bench(zf.BabyBear, "BabyBear", iters_small);
    try bench(zf.KoalaBear, "KoalaBear", iters_small);
    try bench(zf.Goldilocks, "Goldilocks", iters_small);
    try bench(zf.M61, "M61", iters_small);

    // Large fields: fewer iterations
    try bench(zf.BN254_Fp, "BN254_Fp", iters_large);
    try bench(zf.BLS12_381_Fp, "BLS12_381_Fp", iters_large);
    try bench(zf.StarkNet_Fp, "StarkNet_Fp", iters_large);
    try bench(zf.Pallas_Fp, "Pallas_Fp", iters_large);
    try bench(zf.Vesta_Fp, "Vesta_Fp", iters_large);

    // Extensions - need separate function since they don't have toInt()
    // Skipping extensions for now as they don't have toInt()
    _ = zf.CM31;
    _ = zf.QM31;
    _ = zf.BN254_Fp2;
}