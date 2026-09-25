//! Core RNG utilities: Fisher-Yates shuffles, rejection sampling for finite fields,
//! and a generic `Rng` trait interface.
//!
//! All functions are allocation-free where possible.

const std = @import("std");
const traits = @import("zig-algebra-traits");

/// Generic RNG interface trait.  Any type providing `randomBytes` satisfies this.
pub fn RngTrait(comptime T: type) type {
    return struct {
        pub const has_randomBytes = @hasDecl(T, "randomBytes");

        pub fn assert() void {
            if (!has_randomBytes) @compileError("Rng trait: missing 'randomBytes' on " ++ @typeName(T));
        }
    };
}

/// Generate a uniformly random field element using rejection sampling.
///
/// The algorithm draws random integers until one falls in `[0, p)` where `p`
/// is the field modulus.  This is statistically unbiased and allocation-free.
///
/// # Type Parameters
/// - `F`:  A type satisfying the `Field` trait (must expose `fromInt`, `order`, `eql`).
/// - `R`:  A type satisfying the `Rng` trait (must expose `randomBytes`).
pub fn randomFieldElement(comptime F: type, comptime R: type, rng: *R) F {
    traits.assertField(F);
    RngTrait(R).assert();

    const order = comptime blk: {
        if (@hasDecl(F, "MODULUS")) break :blk F.MODULUS;
        break :blk F.order;
    };
    const byte_len = comptime blk: {
        if (@hasDecl(F, "NUM_BYTES")) break :blk F.NUM_BYTES;
        const bits = std.math.log2_int(@TypeOf(order), order) + 1;
        break :blk (bits + 7) / 8;
    };
    std.debug.assert(byte_len > 0 and byte_len <= 64);

    const order_wide: u512 = @intCast(order);
    var buf: [byte_len]u8 = undefined;

    while (true) {
        rng.randomBytes(&buf);
        var val: u512 = 0;
        for (0..byte_len) |i| {
            val = (val << 8) | buf[i];
        }
        if (val < order_wide) {
            if (comptime @hasDecl(F, "NUM_BYTES") and F.NUM_BYTES > 32) {
                return F.fromInt(val);
            }
            return F.fromInt(@as(u256, @truncate(val)));
        }
    }
}

/// Generate a uniformly random unsigned integer in `[0, max)` using rejection sampling.
///
/// Works for any `R` with `randomBytes`.  `max` must be > 0.
pub fn randomU64Bounded(comptime R: type, rng: *R, max: u64) !u64 {
    RngTrait(R).assert();
    if (max == 0) return error.InvalidBound;
    if (max == 1) return 0;

    const bits: u6 = @intCast(64 - @clz(max - 1));
    const mask = if (bits == 64) ~@as(u64, 0) else (@as(u64, 1) << bits) - 1;
    var buf: [8]u8 = undefined;

    while (true) {
        rng.randomBytes(&buf);
        const val = std.mem.readInt(u64, &buf, .little) & mask;
        if (val < max) return val;
    }
}

/// Fisher-Yates shuffle: permute `items` in-place uniformly at random.
///
/// # Type Parameters
/// - `T`:  Element type.
/// - `R`:  RNG type satisfying `RngTrait`.
pub fn shuffle(comptime T: type, comptime R: type, rng: *R, items: []T) !void {
    RngTrait(R).assert();
    var i: usize = items.len;
    while (i > 1) {
        i -= 1;
        const j = try randomU64Bounded(R, rng, @intCast(i + 1));
        const tmp = items[i];
        items[i] = items[j];
        items[j] = tmp;
    }
}

/// Generate a random permutation of `[0, n)` as a newly allocated slice.
/// Caller owns the returned memory.
pub fn randomPermutation(comptime R: type, rng: *R, n: usize, allocator: std.mem.Allocator) ![]usize {
    RngTrait(R).assert();
    const perm = try allocator.alloc(usize, n);
    errdefer allocator.free(perm);
    for (0..n) |i| perm[i] = i;
    try shuffle(usize, R, rng, perm);
    return perm;
}

/// Generate a random boolean with probability 1/2.
pub fn randomBool(comptime R: type, rng: *R) bool {
    RngTrait(R).assert();
    var buf: [1]u8 = undefined;
    rng.randomBytes(&buf);
    return buf[0] & 1 == 1;
}

/// Generate a random `u64` from the RNG.
pub fn randomU64(comptime R: type, rng: *R) u64 {
    RngTrait(R).assert();
    var buf: [8]u8 = undefined;
    rng.randomBytes(&buf);
    return std.mem.readInt(u64, &buf, .little);
}

/// Generate a random `u32` from the RNG.
pub fn randomU32(comptime R: type, rng: *R) u32 {
    RngTrait(R).assert();
    var buf: [4]u8 = undefined;
    rng.randomBytes(&buf);
    return std.mem.readInt(u32, &buf, .little);
}

/// Generate a random `u8` from the RNG.
pub fn randomU8(comptime R: type, rng: *R) u8 {
    RngTrait(R).assert();
    var buf: [1]u8 = undefined;
    rng.randomBytes(&buf);
    return buf[0];
}
