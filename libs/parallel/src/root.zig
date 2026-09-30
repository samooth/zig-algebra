// SPDX-License-Identifier: MIT OR Apache-2.0

//! zig-parallel: Lightweight fork-join parallel executor.
//!
//! Provides a minimal thread pool using pthreads (via `std.Thread.spawn`).
//! Automatically falls back to sequential execution on single-threaded targets
//! (e.g., WebAssembly) or when `num_workers <= 1`.
//!
//! Also hosts `timing.nowNs()`, the canonical portable monotonic clock used
//! by examples and benchmarks across the workspace.
//!
//! Extracted from zig-stark's `core/pool.zig`.

const std = @import("std");
const builtin = @import("builtin");

pub const timing = @import("timing.zig");

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

// `pub const timing = @import("timing.zig")` re-exports the declarations but
// does **not** pull its `test` blocks into the test binary: the two tests in
// `timing.zig`, one of which is the only check on the clock at all, had never
// been run by `zig build test` or by the root step. This is the reference that
// reaches them.
test "reference: timing.zig's test blocks reach this binary" {
    _ = @import("timing.zig");
}

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

// The two existing tests use one shape each, and 1000 over 4 workers divides
// exactly, so the branch that clamps the last chunk to `count` is never taken
// with a remainder. The sweep below is the instrument for that, and the
// execution counter is what makes a duplicated index visible: writing
// `out[i] = i + 1` twice looks exactly like writing it once.
test "pool parallelFor runs every index exactly once, over the chunk boundaries" {
    const counts = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 33, 63, 64, 65, 127, 129, 1000, 1001 };
    const workers = [_]usize{ 1, 2, 3, 4, 5, 8, 16, 64, 65 };

    const Ctx = struct {
        out: []usize,
        runs: std.atomic.Value(u64),

        fn work(self: *@This(), i: usize) void {
            self.out[i] = i + 1;
            _ = self.runs.fetchAdd(1, .monotonic);
        }
    };

    var buffer: [1001]usize = undefined;
    inline for (counts) |count| {
        inline for (workers) |nw| {
            @memset(&buffer, 0);
            var ctx = Ctx{ .out = buffer[0..count], .runs = std.atomic.Value(u64).init(0) };
            var pool = Pool.init(nw);
            pool.parallelFor(Ctx, &ctx, count, Ctx.work);

            for (buffer[0..count], 0..) |got, i| {
                if (got != i + 1) {
                    std.debug.print("count={d} workers={d}: indice {d} recibio {d}\n", .{ count, nw, i, got });
                    return error.TestExpectedEqual;
                }
            }
            const runs = ctx.runs.load(.monotonic);
            if (runs != count) {
                std.debug.print("count={d} workers={d}: {d} ejecuciones, no {d}\n", .{ count, nw, runs, count });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "pool init caps the worker count at max_workers" {
    // A declared surface with no caller and no consequence until now: the cap
    // is what keeps the comptime-sized handle array in range.
    try testing.expectEqual(@as(usize, 0), Pool.init(0).num_workers);
    try testing.expectEqual(@as(usize, 1), Pool.init(1).num_workers);
    try testing.expectEqual(Pool.max_workers, Pool.init(64).num_workers);
    try testing.expectEqual(Pool.max_workers, Pool.init(65).num_workers);
    try testing.expectEqual(Pool.max_workers, Pool.init(1000).num_workers);
}
