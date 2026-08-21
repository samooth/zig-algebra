// SPDX-License-Identifier: MIT OR Apache-2.0

//! Process-wide CSPRNG with OS entropy bootstrapping.
//!
//! Thread-safe ChaCha20 CSPRNG seeded from the OS, with WASM host injection
//! support and test-only deterministic injection.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Thread-safe, process-wide ChaCha20 CSPRNG seeded from the OS.
var csprng: std.Random.DefaultCsprng = undefined;
var seeded: bool = false;
var lock: std.atomic.Mutex = .unlocked;

/// Host-supplied entropy for freestanding targets (web wasm): the host calls
/// `setEntropy` with bytes from the host CSPRNG before any randomness is requested.
const host_seed_capacity = 64;
var host_seed: [host_seed_capacity]u8 = undefined;
var host_seed_len: usize = 0;

/// Inject entropy from the host. Web builds must call this before the first
/// `bytes` call, or it panics.
pub fn setEntropy(entropy: []const u8) void {
    std.debug.assert(entropy.len <= host_seed.len);
    @memcpy(host_seed[0..entropy.len], entropy);
    host_seed_len = entropy.len;
}

/// `false` for single-threaded targets so the atomic lock is never analyzed.
const locking = !builtin.single_threaded;

/// Test-only hook: inject a deterministic `std.Random` for reproducible results.
var test_rng: ?*std.Random = null;

pub fn setRandomForTesting(rng: ?*std.Random) void {
    test_rng = rng;
}

/// Fill `out` with cryptographically secure random bytes.
pub fn bytes(out: []u8) void {
    if (test_rng) |rng| {
        std.Random.bytes(rng.*, out);
        return;
    }
    lockBytes();
    defer unlockBytes();
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
    if (test_rng) |rng| {
        return std.Random.int(rng.*, T);
    }
    lockBytes();
    defer unlockBytes();
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
    if (host_seed_len == 0) {
        @panic("secure entropy unavailable: call setEntropy before generating");
    }
    std.debug.assert(out.len <= host_seed_len);
    @memcpy(out, host_seed[0..out.len]);
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
        @panic("secure entropy unavailable: no Windows getrandom binding");
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

test "setRandomForTesting deterministic" {
    var prng = std.Random.DefaultPrng.init(42);
    var rng_instance = prng.random();
    setRandomForTesting(&rng_instance);

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    bytes(&buf1);
    bytes(&buf2);
    try testing.expectEqual(buf1, buf2);

    setRandomForTesting(null);
}
