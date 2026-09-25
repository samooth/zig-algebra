# zig-parallel

Fork-join parallel executor for Zig. A lightweight thread pool that distributes work across available cores with a simple callback API.

## Features

- **Thread pool** — pre-allocated worker threads, no per-task allocation
- **parallelFor** — split a range across N workers with a user callback
- **Sequential fallback** — automatically degrades to single-threaded when only 1 worker is available

## Quick Start

```zig
const parallel = @import("zig-parallel");

const pool = parallel.Pool.init(num_workers);
defer pool.deinit();

const Context = struct {
    values: []usize,
    fn square(self: *@This(), index: usize) void {
        self.values[index] = self.values[index] * self.values[index];
    }
};

var values = [_]usize{ 1, 2, 3, 4 };
var context = Context{ .values = &values };
pool.parallelFor(Context, &context, values.len, Context.square);
```

`parallelFor` takes a comptime context type, a mutable context pointer, the
range length, and a callback with signature `fn (*Ctx, usize) void`. The
callback cannot return an error; record failures in the context and inspect
them after the call. `Pool.init` caps the worker count at 64 and falls back
to sequential execution on single-threaded targets or with one worker.

## Running Tests

```bash
cd libs/parallel && zig build test
```

## License

MIT OR Apache-2.0
