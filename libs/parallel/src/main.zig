//! zig-parallel consumer: use the fork-join pool, and see what it guarantees.
//!
//! The contract is "every index exactly once", which is not something a print
//! statement can show. So this counts: each worker records how many indices it
//! saw, and the total is checked against the count that was requested. A
//! duplicated index would push the total up and a dropped one would keep it
//! down, so the equality is the property rather than a demonstration of it.

const std = @import("std");
const parallel = @import("zig-parallel");

const Ctx = struct {
    seen: []usize,
    workers: usize,

    fn work(self: *Ctx, index: usize) void {
        self.seen[index] += 1;
    }
};

pub fn main() !void {
    const counts = [_]usize{ 0, 1, 3, 7, 100, 997 };
    const workers = [_]usize{ 1, 2, 4, 64 };

    std.debug.print("zig-parallel: every index exactly once, over {d} shapes\n\n", .{counts.len * workers.len});
    std.debug.print("  count | workers | total | per-index min/max | ok\n", .{});

    var failures: usize = 0;
    for (counts) |count| {
        for (workers) |nw| {
            const seen = try std.heap.page_allocator.alloc(usize, count);
            defer std.heap.page_allocator.free(seen);
            @memset(seen, 0);

            var pool = parallel.Pool.init(nw);
            defer pool.deinit();

            var ctx = Ctx{ .seen = seen, .workers = nw };
            pool.parallelFor(Ctx, &ctx, count, Ctx.work);

            var total: usize = 0;
            var lo: usize = std.math.maxInt(usize);
            var hi: usize = 0;
            for (seen) |s| {
                total += s;
                lo = @min(lo, s);
                hi = @max(hi, s);
            }
            if (count == 0) {
                lo = 0;
                hi = 0;
            }

            // Exactly once per index: the sum equals the count, and no index was
            // hit more than once. Both halves are needed -- a duplicated index
            // with a matching total is still a bug.
            const ok = total == count and (count == 0 or (lo == 1 and hi == 1));
            if (!ok) failures += 1;

            std.debug.print("  {d:>5} | {d:>7} | {d:>5} | {d}/{d:<14} | {s}\n", .{
                count, nw, total, lo, hi, if (ok) "yes" else "NO",
            });
        }
    }

    std.debug.print("\n{d} failure(s) across {d} shapes\n", .{ failures, counts.len * workers.len });
}
