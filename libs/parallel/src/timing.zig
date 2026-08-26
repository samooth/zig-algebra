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
