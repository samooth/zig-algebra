// SPDX-License-Identifier: MIT OR Apache-2.0

//! Portable monotonic timing for benchmarking and profiling.
//!
//! Single canonical `nowNs()` implementation:
//!   - Windows: QueryPerformanceCounter via ntdll (same pattern as std.Io.Threaded)
//!   - POSIX with libc (Linux, macOS): clock_gettime(CLOCK_MONOTONIC) via std.c
//!   - Linux without libc: raw syscall wrapper std.os.linux.clock_gettime
//!
//! Non-CT; intended for public-data benchmark loops and example timers only.

const std = @import("std");
const builtin = @import("builtin");

/// Monotonic nanoseconds for elapsed-time measurement.
///
/// Never returns a decreasing value within a process lifetime.
/// Clock read failure is not recoverable on supported targets; the
/// underlying calls are infallible in practice (asserted by the OS).
pub fn nowNs() u64 {
    switch (builtin.os.tag) {
        .windows => {
            var qpc: std.os.windows.LARGE_INTEGER = undefined;
            var qpf: std.os.windows.LARGE_INTEGER = undefined;
            _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&qpc);
            _ = std.os.windows.ntdll.RtlQueryPerformanceFrequency(&qpf);
            const c: u64 = @bitCast(qpc);
            const f: u64 = @bitCast(qpf);
            // 10 MHz is the common QPF; skip the division in that case.
            if (f == 10_000_000) return c * (std.time.ns_per_s / 10_000_000);
            // Fixed-point ns conversion (see std.Io.Threaded).
            const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(f));
            return @intCast((@as(u96, c) * scale) >> 32);
        },
        else => {
            var ts: std.posix.timespec = undefined;
            if (builtin.link_libc) {
                _ = std.c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
            } else if (builtin.os.tag == .linux) {
                _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
            } else {
                @compileError("timing.nowNs: unsupported target " ++ @tagName(builtin.os.tag));
            }
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        },
    }
}

test "nowNs is monotonic across a busy wait" {
    var prev = nowNs();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const t = nowNs();
        try std.testing.expect(t >= prev);
        prev = t;
    }
}

// A second clock from the same operating system, used to check the *scale* of
// `nowNs()` rather than its self-consistency: it has to be a *different* clock,
// because a check that compares the two against each other is satisfied when
// both readings come from the same one. Scale, offset stability and epoch
// distance are all properties of the pair, so the pair has to be real.
//
// std 0.16 exposes no wall clock for Windows, so the one call is declared here,
// in a test, rather than added to the library's surface. FILETIME is 100ns
// intervals since 1601.
const GetSystemTimeAsFileTime = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetSystemTimeAsFileTime(lp: *u64) callconv(.winapi) void;
}.GetSystemTimeAsFileTime else void;

fn otherClockNs() u64 {
    switch (builtin.os.tag) {
        .windows => {
            var ft: u64 = undefined;
            GetSystemTimeAsFileTime(&ft);
            return ft * 100;
        },
        else => {
            var ts: std.posix.timespec = undefined;
            if (builtin.link_libc) {
                _ = std.c.clock_gettime(std.posix.CLOCK.REALTIME, &ts);
            } else if (builtin.os.tag == .linux) {
                _ = std.os.linux.clock_gettime(.REALTIME, &ts);
            } else {
                @compileError("otherClockNs: unsupported target " ++ @tagName(builtin.os.tag));
            }
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        },
    }
}

test "nowNs measures an interval in nanoseconds, as a second OS clock does" {
    // The delay is spent waiting on `nowNs()` itself, which is what makes the
    // comparison bite: if our unit were microseconds, waiting for 50 of "our"
    // milliseconds would only be 50 microseconds of the other clock's time.
    const mono0 = nowNs();
    const real0 = otherClockNs();
    const objetivo = mono0 + 50 * std.time.ns_per_ms;
    while (nowNs() < objetivo) {}
    const mono1 = nowNs();
    const real1 = otherClockNs();

    const d_mono = mono1 - mono0;
    const d_real = real1 - real0;

    // A factor of ten is the whole space of unit mistakes this is looking for.
    // Both clocks measure the same elapsed time in the same unit, so their
    // intervals agree up to the granularity of the polling loop.
    const ratio = @as(f64, @floatFromInt(d_mono)) / @as(f64, @floatFromInt(d_real));
    try std.testing.expect(ratio > 0.5 and ratio < 2.0);

    // In the other direction: an absolute floor. 50 of our milliseconds cannot
    // have taken less than 20 of the other clock's, and a real-time clock does
    // not run backwards, so a negative or tiny interval means the scale is off.
    try std.testing.expect(d_real >= 20 * std.time.ns_per_ms);
    try std.testing.expect(d_real < 5 * std.time.ns_per_s);

    // A monotonic clock is not a wall clock: the offset between the two is the
    // epoch difference, and it stays put across the interval -- within the cost
    // of the two clock reads, which are not simultaneous. This is what a
    // REALTIME-based `nowNs()` could not satisfy, since its offset would move
    // by the whole interval.
    const offset_before = @as(i128, mono0) - @as(i128, real0);
    const offset_after = @as(i128, mono1) - @as(i128, real1);
    const deriva = @abs(offset_after - offset_before);
    try std.testing.expect(deriva < @as(i128, 5 * std.time.ns_per_ms));

    // The offset check above is satisfied by construction if `nowNs()` *is* a
    // realtime reading -- the offset would be zero at both ends, which is why
    // this one exists. What separates the two clocks is the size of their
    // values: a monotonic clock counts from boot, a wall clock from 1970.
    //
    // A factor of 10 is a decade of slack on top of the decades that separate
    // the two epochs, and it is what a same-clock substitution fails: both
    // readings of one clock give a ratio of 1, up to the order of the two
    // reads. A larger factor would be tighter on Windows, whose FILETIME epoch
    // is 1601: 1000x there would only tolerate fifteen days of uptime.
    const factor = @as(u128, @intCast(real1)) / @as(u128, @intCast(mono1));
    try std.testing.expect(factor > 10);
}
