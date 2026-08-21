// SPDX-License-Identifier: MIT OR Apache-2.0

//! zig-parallel: Lightweight fork-join parallel executor.
//!
//! Provides a minimal thread pool using pthreads (via `std.Thread.spawn`).
//! Automatically falls back to sequential execution on single-threaded targets
//! (e.g., WebAssembly) or when `num_workers <= 1`.
//!
//! Extracted from zig-stark's `core/pool.zig`.

const std = @import("std");
const builtin = @import("builtin");

/// A small fork-join parallel executor.
///
/// Each `parallelFor` spawns up to `num_workers` threads over contiguous
/// chunks of the item range and joins them. It is a no-op (sequential) when
/// `builtin.single_threaded`, when `num_workers <= 1`, or when the range
/// is trivial — so the same code path compiles and runs on wasm single-thread
/// builds.
///
/// `parallelFor`'s `func` must not return an error; capture failures in `ctx`
/// (e.g. an atomic flag) and check them after the call. The caller's allocator
/// must be thread-safe when the work allocates.
pub const Pool = struct {
    /// Worker budget, capped so the stack task/handle arrays are comptime-sized.
    num_workers: usize,

    pub const max_workers = 64;

    pub fn init(num_workers: usize) Pool {
        return .{ .num_workers = @min(num_workers, max_workers) };
    }

    pub fn deinit(self: *Pool) void {
        _ = self;
    }

    /// Run `func(ctx, index)` for every index in `[0, count)`.
    pub fn parallelFor(
        self: *const Pool,
        comptime Ctx: type,
        ctx: *Ctx,
        count: usize,
        comptime func: fn (*Ctx, usize) void,
    ) void {
        if (builtin.single_threaded or self.num_workers <= 1 or count <= 1) {
            for (0..count) |i| func(ctx, i);
            return;
        }

        const Impl = struct {
            fn worker(c: *Ctx, start: usize, end: usize) void {
                for (start..end) |i| func(c, i);
            }
        };

        const nw = @min(self.num_workers, count);
        var handles: [max_workers]std.Thread = undefined;
        const chunk = (count + nw - 1) / nw;

        var spawned: usize = 0;
        var start: usize = 0;
        while (start < count) : (start += chunk) {
            const end = @min(start + chunk, count);
            const h = std.Thread.spawn(.{}, Impl.worker, .{ ctx, start, end }) catch {
                for (start..end) |i| func(ctx, i);
                continue;
            };
            handles[spawned] = h;
            spawned += 1;
        }
        for (handles[0..spawned]) |h| h.join();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "pool parallelFor matches sequential" {
    const Pool0 = Pool.init(4);
    const count = 1000;

    var seq: [count]usize = undefined;
    for (0..count) |i| seq[i] = i + 1;

    const Ctx = struct {
        out: []usize,
        fn add(self: *@This(), i: usize) void {
            self.out[i] = i + 1;
        }
    };
    var out: [count]usize = undefined;
    var ctx = Ctx{ .out = &out };
    Pool0.parallelFor(Ctx, &ctx, count, Ctx.add);
    try testing.expectEqualSlices(usize, &seq, &out);
}

test "pool sequential fallback on single-threaded / 1 worker" {
    const Pool1 = Pool.init(1);
    const count = 8;
    const Ctx = struct {
        sum: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        fn add(self: *@This(), i: usize) void {
            self.sum.store(self.sum.load(.monotonic) + i, .monotonic);
        }
    };
    var ctx = Ctx{};
    Pool1.parallelFor(Ctx, &ctx, count, Ctx.add);
    try testing.expectEqual(@as(usize, 28), ctx.sum.load(.monotonic));
}