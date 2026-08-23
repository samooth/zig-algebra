# zig-parallel

Fork-join parallel executor for Zig. A lightweight thread pool that distributes work across available cores with a simple callback API.

## Features

- **Thread pool** — pre-allocated worker threads, no per-task allocation
- **parallelFor** — split a range across N workers with a user callback
- **Sequential fallback** — automatically degrades to single-threaded when only 1 worker is available

## Quick Start

```zig
const parallel = @import("zig-parallel");

var pool = try parallel.Pool.init(allocator, num_workers);
defer pool.deinit();

// Run a function over [0, n) in parallel
try pool.parallelFor(n, struct {
    fn run(start: usize, end: usize) void {
        // process elements [start, end)
    }
}.run);
```

## Running Tests

```bash
cd libs/parallel && zig build test
```

## License

MIT OR Apache-2.0
