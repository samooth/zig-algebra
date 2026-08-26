//! Systematic benchmarks for zig-algebra.
//!
//! Run: zig build bench (from repo root)
//! All benchmarks compile in ReleaseFast regardless of -Doptimize.

const std = @import("std");

// Re-export modules for benchmark functions
pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("Use: zig build bench\n", .{});
    std.debug.print("(Central harness: libs/pairing/src/bench.zig — fields, curves,\n", .{});
    std.debug.print(" pairings, MSM, NTT. Field-only micro-benches: cd libs/field && zig build bench)\n", .{});
}
