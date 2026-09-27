// SPDX-License-Identifier: MIT OR Apache-2.0

//! Process-wide CSPRNG with OS entropy bootstrapping.
//!
//! Thread-safe ChaCha20 CSPRNG seeded from the OS, with WASM host injection
//! support and test-only deterministic injection.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const windows = std.os.windows;

/// `algorithm` is documented by Microsoft as optional: a NULL handle means
/// "use the system-preferred RNG". Declaring it `?windows.HANDLE` says that,
/// and it is what makes the `null` below legal -- `windows.HANDLE` is
/// `*anyopaque`, and a bare `null` does not coerce to a non-optional pointer in
/// Zig 0.16, so this file failed to *compile* on Windows. Every other line of
/// this module is platform-independent, which is why only the Windows CI job
/// ever saw it. The ABI is unchanged: a nullable pointer is the same shape.
extern "bcrypt" fn BCryptGenRandom(
    algorithm: ?windows.HANDLE,
    buffer: [*]u8,
    buffer_len: u32,
    flags: u32,
) windows.NTSTATUS;

/// Thread-safe, process-wide ChaCha20 CSPRNG seeded from the OS.
var csprng: std.Random.DefaultCsprng = undefined;
var seeded: bool = false;
var lock: std.atomic.Mutex = .unlocked;

/// Host-supplied entropy for freestanding targets (web wasm): the host calls
/// `setEntropy` with bytes from the host CSPRNG before any randomness is requested.
///
/// The buffer is zero-initialized, not `undefined`: every byte a reader can
/// reach is initialized, so a short seed can never leak uninitialized memory
/// into output (reading `undefined` bytes is undefined behaviour, and in
/// ReleaseFast the safety checks that would catch it are gone).
const host_seed_capacity = 64;
var host_seed: [host_seed_capacity]u8 = [_]u8{0} ** host_seed_capacity;
var host_seed_len: usize = 0;

/// Minimum host entropy `setEntropy` must leave available for the CSPRNG seed.
pub const required_entropy_len = std.Random.DefaultCsprng.secret_seed_length;
pub const EntropyError = error{ EntropyTooLong, InsufficientEntropy };

/// Inject entropy from the host. Web builds must call this before the first
/// `bytes` call, or it panics.
///
/// Longer inputs are *truncated* to `host_seed_capacity` bytes, never copied
/// past the end of the buffer: the previous `std.debug.assert` guard was
/// compiled out in ReleaseFast, so an over-long slice overflowed
/// `host_seed` there with no diagnostic. Callers that need strict validation
/// should use `setEntropyChecked`; the remaining bytes of the slice are always
/// zeros after truncation.
pub fn setEntropy(entropy: []const u8) void {
    lockBytes();
    defer unlockBytes();
    const n = @min(entropy.len, host_seed.len);
    @memcpy(host_seed[0..n], entropy[0..n]);
    @memset(host_seed[n..], 0);
    host_seed_len = n;
}

/// Strict entropy injection: rejects an over-capacity buffer instead of
/// truncating it, and rejects a buffer too short to seed the CSPRNG.
pub fn setEntropyChecked(entropy: []const u8) EntropyError!void {
    if (entropy.len > host_seed_capacity) return error.EntropyTooLong;
    if (entropy.len < required_entropy_len) return error.InsufficientEntropy;
    setEntropy(entropy);
}

/// Number of host entropy bytes currently available (0 = none).
pub fn entropyAvailable() usize {
    lockBytes();
    defer unlockBytes();
    return host_seed_len;
}

/// `false` for single-threaded targets so the atomic lock is never analyzed.
const locking = !builtin.single_threaded;

/// Test-only hook: inject a deterministic `std.Random` for reproducible results.
///
/// The hook stores a copy of the `std.Random` *interface* value, but
/// `std.Random` is `{ ptr: *anyopaque, fillFn }` — `ptr` still points at the
/// caller's generator state. Installing the hook therefore extends the
/// lifetime requirement of that state:
///
/// * always pair install/reset with `defer setRandomForTesting(null);` so a
///   failed expectation cannot leave a hook pointing at a dead stack frame
///   (the next `bytes`/`random` call would then be a use-after-scope);
/// * prefer `setRandomForTestingSeed`, whose state lives inside this module
///   and can never dangle, even if the hook is left installed.
var test_rng: ?std.Random = null;

/// Module-owned deterministic state backing `setRandomForTestingSeed`.
var test_prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0);
var test_prng_active: bool = false;

pub fn setRandomForTesting(rng: ?*std.Random) void {
    lockBytes();
    defer unlockBytes();
    if (rng) |r| {
        test_rng = r.*;
    } else {
        test_rng = null;
        test_prng_active = false;
    }
}

/// Test-only hook with module-owned state: no pointer into caller memory is
/// retained, so this cannot dangle. `null` disables the hook.
pub fn setRandomForTestingSeed(seed: ?u64) void {
    lockBytes();
    defer unlockBytes();
    if (seed) |s| {
        test_prng = std.Random.DefaultPrng.init(s);
        test_prng_active = true;
        test_rng = null;
    } else {
        test_prng_active = false;
    }
}

fn testRandom() ?std.Random {
    if (test_rng) |r| return r;
    if (test_prng_active) return test_prng.random();
    return null;
}

/// Fill `out` with cryptographically secure random bytes.
pub fn bytes(out: []u8) void {
    lockBytes();
    defer unlockBytes();
    if (testRandom()) |rng| {
        std.Random.bytes(rng, out);
        return;
    }
    if (!seeded) {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        osEntropy(&seed);
        csprng = std.Random.DefaultCsprng.init(seed);
        seeded = true;
    }
    csprng.fill(out);
}

/// Generate a random value of type T. Uses the CSPRNG.
pub fn random(comptime T: type) T {
    lockBytes();
    defer unlockBytes();
    if (testRandom()) |rng| {
        return std.Random.int(rng, T);
    }
    if (!seeded) {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        osEntropy(&seed);
        csprng = std.Random.DefaultCsprng.init(seed);
        seeded = true;
    }
    return std.Random.int(csprng.random(), T);
}

fn lockBytes() void {
    if (!locking) return;
    while (!lock.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

fn unlockBytes() void {
    if (!locking) return;
    lock.unlock();
}

fn seedFromHost(out: []u8) void {
    const src = hostSeedSlice(out.len) orelse @panic("secure entropy unavailable: " ++ "call setEntropy with at least required_entropy_len bytes before generating");
    @memcpy(out, src);
}

/// The initialized prefix of `host_seed` usable for a `n`-byte seed request,
/// or `null` when the host has not injected that much entropy.
///
/// This is a real bounds check, not `std.debug.assert`: the assert was
/// compiled out in ReleaseFast, where an over-long request used to
/// `@memcpy` past `host_seed_len` and read uninitialized memory.
fn hostSeedSlice(n: usize) ?[]const u8 {
    if (n == 0) return host_seed[0..0];
    if (n > host_seed_len) return null;
    return host_seed[0..n];
}

fn osEntropy(out: []u8) void {
    if (builtin.os.tag == .freestanding or builtin.os.tag == .wasi) {
        seedFromHost(out);
        return;
    }
    if (builtin.link_libc and @TypeOf(posix.system.arc4random_buf) != void) {
        posix.system.arc4random_buf(out.ptr, out.len);
        return;
    }
    if (@TypeOf(posix.system.getrandom) != void) {
        getrandomLoop(out);
        return;
    }
    if (builtin.os.tag == .linux) {
        var i: usize = 0;
        while (i < out.len) {
            const rc = std.os.linux.getrandom(out[i..].ptr, out[i..].len, 0);
            switch (posix.errno(rc)) {
                .SUCCESS => i += @intCast(rc),
                .INTR => {},
                else => @panic("secure entropy unavailable"),
            }
        }
        return;
    }
    if (builtin.os.tag == .windows) {
        var offset: usize = 0;
        while (offset < out.len) {
            const chunk: usize = @min(out.len - offset, std.math.maxInt(u32));
            const status = BCryptGenRandom(null, out.ptr + offset, @intCast(chunk), 0x00000002);
            if (status != .SUCCESS) @panic("secure entropy unavailable");
            offset += chunk;
        }
        return;
    }
    const file = std.fs.openFileAbsolute("/dev/urandom", .{}) catch @panic("secure entropy unavailable");
    defer file.close();
    file.reader().readNoEof(out) catch @panic("secure entropy unavailable");
}

fn getrandomLoop(out: []u8) void {
    var i: usize = 0;
    while (i < out.len) {
        const rc = posix.system.getrandom(out[i..].ptr, out[i..].len, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => i += @intCast(rc),
            .INTR => {},
            else => @panic("secure entropy unavailable"),
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "bytes fills output" {
    var buf: [32]u8 = undefined;
    bytes(&buf);
    // Should not be all zeros (extremely unlikely)
    try testing.expect(!std.mem.allEqual(u8, &buf, 0));
}

test "random produces values" {
    const val = random(u64);
    _ = val;
}

test "setRandomForTesting is a reproducible stream" {
    // Always reset via defer: without it a failed expectation below leaves the
    // process-wide hook pointing at `prng`/`rng_instance` after this frame is
    // gone, and the next `bytes`/`random` call reads freed stack memory.
    defer setRandomForTesting(null);

    var first_a: [32]u8 = undefined;
    var first_b: [32]u8 = undefined;
    {
        var prng = std.Random.DefaultPrng.init(42);
        var rng_instance = prng.random();
        setRandomForTesting(&rng_instance);
        bytes(&first_a);
        bytes(&first_b);
        setRandomForTesting(null);
    }

    var second_a: [32]u8 = undefined;
    var second_b: [32]u8 = undefined;
    {
        var prng = std.Random.DefaultPrng.init(42);
        var rng_instance = prng.random();
        setRandomForTesting(&rng_instance);
        bytes(&second_a);
        bytes(&second_b);
    }

    try testing.expectEqual(first_a, second_a);
    try testing.expectEqual(first_b, second_b);
    // The installed generator is a stream, not a constant block.
    try testing.expect(!std.mem.eql(u8, &first_a, &first_b));
}

test "setRandomForTestingSeed is deterministic and leaves no caller pointer behind" {
    defer setRandomForTesting(null);

    var first_a: [48]u8 = undefined;
    var first_b: [48]u8 = undefined;
    setRandomForTestingSeed(1234);
    bytes(&first_a);
    bytes(&first_b);

    // The installed generator state lives in this module, not on the test's
    // stack: it stays valid even if the hook outlives the installing frame.
    try testing.expect(test_rng == null);
    try testing.expect(test_prng_active);

    setRandomForTestingSeed(1234);
    var second_a: [48]u8 = undefined;
    var second_b: [48]u8 = undefined;
    bytes(&second_a);
    bytes(&second_b);

    try testing.expectEqual(first_a, second_a);
    try testing.expectEqual(first_b, second_b);
    try testing.expect(!std.mem.eql(u8, &first_a, &first_b));

    // A different seed must not reproduce the same stream.
    setRandomForTestingSeed(1235);
    var other: [48]u8 = undefined;
    bytes(&other);
    try testing.expect(!std.mem.eql(u8, &first_a, &other));
}

test "setRandomForTestingSeed(null) restores the real CSPRNG" {
    setRandomForTestingSeed(7);
    var from_hook: [32]u8 = undefined;
    bytes(&from_hook);
    setRandomForTestingSeed(null);
    try testing.expect(!test_prng_active);

    var from_csprng: [32]u8 = undefined;
    bytes(&from_csprng);
    try testing.expect(!std.mem.eql(u8, &from_hook, &from_csprng));
}

test "setEntropyChecked rejects short and over-long entropy" {
    defer setEntropy("");
    try std.testing.expectError(error.InsufficientEntropy, setEntropyChecked(&[_]u8{0x01}));
    try std.testing.expectError(error.EntropyTooLong, setEntropyChecked(&([_]u8{0x02} ** (host_seed_capacity + 1))));
    try setEntropyChecked(&([_]u8{0x03} ** required_entropy_len));
    try std.testing.expectEqual(required_entropy_len, entropyAvailable());
}

test "setEntropy truncates over-long input instead of overflowing host_seed" {
    defer setEntropy("");
    const big = [_]u8{0xab} ** 512;
    setEntropy(&big);

    // Clamped to the buffer capacity, not written past its end.
    try testing.expectEqual(host_seed.len, entropyAvailable());
    // The retained prefix is the caller's bytes.
    try testing.expectEqualSlices(u8, big[0..host_seed.len], &host_seed);

    // A full-capacity seed request is satisfiable and returns the injected
    // bytes (no uninitialized memory is ever copied).
    var out: [host_seed_capacity]u8 = undefined;
    seedFromHost(&out);
    try testing.expectEqualSlices(u8, &host_seed, &out);
}

test "setEntropy zeroes the tail and never reports more than it holds" {
    defer setEntropy("");
    setEntropy(&[_]u8{0xff} ** 64);
    try testing.expectEqual(@as(usize, 64), entropyAvailable());

    // Shrinking the injected entropy must not leave the old bytes reachable.
    setEntropy(&[_]u8{ 0x01, 0x02, 0x03 });
    try testing.expectEqual(@as(usize, 3), entropyAvailable());
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, host_seed[0..3]);
    for (host_seed[3..]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "host entropy requests are bounded by the injected length" {
    defer setEntropy("");

    setEntropy("");
    try testing.expectEqual(@as(usize, 0), entropyAvailable());
    try testing.expect(hostSeedSlice(1) == null);
    try testing.expect(hostSeedSlice(0) != null);

    setEntropy(&[_]u8{0x42} ** required_entropy_len);
    try testing.expectEqual(required_entropy_len, entropyAvailable());
    const usable = hostSeedSlice(required_entropy_len) orelse return error.MissingEntropy;
    try testing.expectEqualSlices(u8, &[_]u8{0x42} ** required_entropy_len, usable);
    // A seed request longer than the injection is refused instead of reading
    // uninitialized `host_seed` bytes.
    try testing.expect(hostSeedSlice(required_entropy_len + 1) == null);
    try testing.expect(hostSeedSlice(host_seed_capacity) == null);

    var out: [required_entropy_len]u8 = undefined;
    seedFromHost(&out);
    try testing.expect(!std.mem.allEqual(u8, &out, 0));
}
