# zig-parallel

Fork-join parallel executor for Zig. A small, allocation-free thread pool that
splits an index range across a fixed number of OS threads, plus the workspace's
canonical portable monotonic clock (`timing.nowNs()`).

## Features

- **`Pool`** — a worker budget, capped at `Pool.max_workers` (64) so the
  comptime-sized handle/task arrays stay small
- **`parallelFor`** — split `[0, count)` into contiguous chunks, one per
  worker, spawn, run, join
- **Zero per-task allocation** — the pool itself is just a `usize`
- **Graceful degradation** — falls back to running inline when
  `builtin.single_threaded`, when `num_workers <= 1`, or when `count <= 1`; and
  if a single `std.Thread.spawn` fails it runs that chunk on the calling thread
- **`timing.nowNs()`** — `u64` monotonic nanoseconds: QPC on Windows,
  `clock_gettime(CLOCK_MONOTONIC)` with libc, `std.os.linux.clock_gettime`
  bare-metal

## Installation

`libs/parallel/build.zig` does **not** call `b.addModule`, so the
`zig-parallel` module is only registered by the workspace root `build.zig`.
Consume it from inside zig-algebra, or point a module at
`libs/parallel/src/root.zig` yourself:

```zig
const parallel = b.createModule(.{
    .root_source_file = .{ .cwd_relative = "libs/parallel/src/root.zig" },
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zig-parallel", parallel);
```

`zig-parallel` has no dependencies, so no extra imports are needed.

## Quick Start

```zig
const std = @import("std");
const parallel = @import("zig-parallel");

pub fn main() !void {
    // `deinit` takes `*Pool`, so the pool binding must be `var`.
    var pool = parallel.Pool.init(4);
    defer pool.deinit();

    // `parallelFor` takes the context *type* as a comptime argument and a
    // MUTABLE pointer to the instance.
    const Context = struct {
        values: []usize,
        fn square(self: *@This(), index: usize) void {
            self.values[index] = self.values[index] * self.values[index];
        }
    };

    var values = [_]usize{ 1, 2, 3, 4 };
    var context = Context{ .values = &values };
    pool.parallelFor(Context, &context, values.len, Context.square);
    // values == { 1, 4, 9, 16 }

    // Worker budget is clamped.
    const huge = parallel.Pool.init(1000);
    std.debug.print("workers={} (max {})\n", .{ huge.num_workers, parallel.Pool.max_workers });

    // Portable monotonic clock.
    const t0 = parallel.timing.nowNs();
    std.debug.print("nowNs is u64: {} > 0 = {}\n", .{ @TypeOf(t0) == u64, t0 > 0 });
}
```

## API

### `Pool`

| Member | Signature | Notes |
|--------|-----------|-------|
| `num_workers` | `usize` field | the (already clamped) budget |
| `max_workers` | `comptime usize` = `64` | |
| `init` | `(num_workers: usize) Pool` | returns `@min(num_workers, 64)` |
| `deinit` | `(self: *Pool) void` | no-op; requires a mutable binding |
| `parallelFor` | `(self: *const Pool, comptime Ctx: type, ctx: *Ctx, count: usize, comptime func: fn (*Ctx, usize) void) void` | |

`parallelFor` semantics:

- If `builtin.single_threaded`, `num_workers <= 1`, or `count <= 1`, the loop
  runs inline on the calling thread. This is what makes the same code path
  compile and run under `wasm32-freestanding` single-thread builds.
- Otherwise `min(num_workers, count)` threads are spawned over contiguous
  chunks of size `ceil(count / nw)`, then all handles are joined.
- `func` **must not return an error**. Record failures in `ctx` (e.g. an
  `std.atomic.Value` flag) and inspect them after the call.
- `parallelFor` itself takes `*const Pool`; only `deinit` needs `*Pool`.
- The work runs on real OS threads, so `ctx` is shared mutable state: any field
  written by `func` from more than one chunk needs synchronization, and any
  allocator used inside `func` must be thread-safe.

### `timing`

| Function | Signature | Notes |
|----------|-----------|-------|
| `timing.nowNs` | `() u64` | monotonic nanoseconds |

`std.time.Timer` and `std.time.nanoTimestamp()` do not exist in Zig 0.16; use
this instead of writing platform-specific timing inline.

## Running Tests

```bash
cd libs/parallel && zig build test
```

2 tests: a parallel-vs-sequential equality check and a 1-worker sum.

## Design Notes

- The pool owns no handles between calls — it spawns and joins per
  `parallelFor` invocation. That keeps `Pool` trivially copyable (it is one
  `usize`) at the cost of thread-creation latency per call. For a long-lived
  pool of persistent workers you want a different design.
- `handles: [max_workers]std.Thread` is a stack array, which is why the worker
  count is capped.
- `timing.nowNs` returns `u64`; cast to a signed type if you need deltas that
  can be negative.

## License

MIT OR Apache-2.0
