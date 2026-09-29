//! zig-rng: Cryptographically secure and deterministic random number generators.
//!
//! Provides:
//! - **ChaCha20Rng**: Stream-cipher-based CSPRNG (RFC 8439).
//! - **Shake256Rng**: XOF-based CSPRNG (SHAKE256 extendable-output function).
//! - **Rejection sampling**: Unbiased random field elements and bounded integers.
//! - **Fisher-Yates**: Uniform random shuffles and permutations.
//!
//! All generators are deterministic given a seed, making them ideal for
//! reproducible tests, zero-knowledge proofs, and cryptographic protocols.

const std = @import("std");

pub const chacha20 = @import("chacha20.zig");
pub const shake256 = @import("shake256.zig");
pub const rng = @import("rng.zig");
pub const csprng = @import("csprng.zig");

// Re-exports
pub const ChaCha20Rng = chacha20.ChaCha20Rng;
pub const Shake256Rng = shake256.Shake256Rng;
pub const RngTrait = rng.RngTrait;
pub const MAX_REJECTION_ATTEMPTS = rng.MAX_REJECTION_ATTEMPTS;
pub const randomFieldElement = rng.randomFieldElement;
pub const randomU64Bounded = rng.randomU64Bounded;
pub const shuffle = rng.shuffle;
pub const randomPermutation = rng.randomPermutation;
pub const randomBool = rng.randomBool;
pub const randomU64 = rng.randomU64;
pub const randomU32 = rng.randomU32;
pub const randomU8 = rng.randomU8;

// ============================================================================
// Tests
// ============================================================================

test {
    // Reference every public declaration so the `@import`s above are forced
    // and `test` blocks declared inside imported modules (csprng.zig, ...)
    // are collected by the test runner. Without this the CSPRNG tests are
    // never compiled, let alone run.
    std.testing.refAllDecls(@This());
}

// Minimal F7 field for rejection-sampling tests
const F7 = struct {
    const Self = @This();
    value: u64,
    pub const modulus: u64 = 7;
    pub const characteristic: u64 = 7;
    pub const order: u64 = 7;

    pub fn zero() Self {
        return .{ .value = 0 };
    }
    pub fn one() Self {
        return .{ .value = 1 };
    }
    pub fn fromInt(x: u256) Self {
        return .{ .value = @intCast(x % modulus) };
    }
    pub fn toInt(self: Self) u64 {
        return self.value;
    }
    pub fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
    }
    pub fn add(a: Self, b: Self) Self {
        return fromInt(a.value + b.value);
    }
    pub fn sub(a: Self, b: Self) Self {
        return fromInt(a.value + (modulus - b.value % modulus));
    }
    pub fn neg(a: Self) Self {
        return if (a.value == 0) zero() else fromInt(modulus - a.value);
    }
    pub fn mul(a: Self, b: Self) Self {
        return fromInt(a.value * b.value);
    }
    /// Legacy total inverse: `inv(0) == zero()`. Zero is not an inverse;
    /// new code that requires invertibility must call `invChecked`.
    pub fn inv(a: Self) Self {
        if (a.isZero()) return zero();
        return pow(a, modulus - 2);
    }
    pub fn invChecked(a: Self) error{InverseOfZero}!Self {
        if (a.isZero()) return error.InverseOfZero;
        return pow(a, modulus - 2);
    }
    pub const inverse = inv;
    /// Legacy total division: `x / 0 == zero()`.
    pub fn div(a: Self, b: Self) Self {
        return mul(a, inv(b));
    }
    pub fn divChecked(a: Self, b: Self) error{InverseOfZero}!Self {
        return mul(a, try b.invChecked());
    }
    pub fn pow(base: Self, exp: u64) Self {
        var result = one();
        var b = base;
        var e = exp;
        while (e > 0) {
            if (e & 1 == 1) result = mul(result, b);
            b = mul(b, b);
            e >>= 1;
        }
        return result;
    }
    pub fn isZero(self: Self) bool {
        return self.value == 0;
    }
    pub fn random() Self {
        return fromInt(1);
    }
};

const RejectingRng = struct {
    pub fn randomBytes(self: *@This(), bytes: []u8) void {
        _ = self;
        @memset(bytes, 0xff);
    }
};

test "ChaCha20Rng deterministic" {
    const seed = [_]u8{0x42} ** 32;
    var rng1 = ChaCha20Rng.initFromSeed(&seed);
    var rng2 = ChaCha20Rng.initFromSeed(&seed);

    for (0..100) |_| {
        try std.testing.expectEqual(rng1.randomU64(), rng2.randomU64());
    }
}

test "ChaCha20Rng different seeds produce different output" {
    var rng1 = ChaCha20Rng.initFromSeed(&[_]u8{0x01} ** 32);
    var rng2 = ChaCha20Rng.initFromSeed(&[_]u8{0x02} ** 32);
    try std.testing.expect(rng1.randomU64() != rng2.randomU64());
}

test "ChaCha20Rng randomU64Bounded" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0xAB} ** 32);
    for (0..100) |_| {
        const v = try chacha.randomU64Bounded(100);
        try std.testing.expect(v < 100);
    }
}

test "ChaCha20Rng randomBytes" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0xCD} ** 32);
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    chacha.randomBytes(&buf1);
    chacha.randomBytes(&buf2);
    try std.testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}

test "ChaCha20 keystream matches RFC 8439" {
    // Vectors from RFC 8439 (https://www.rfc-editor.org/rfc/rfc8439.txt):
    // published, and not produced by this code. Two of them, because the
    // RFC's examples differ in nonce and initial counter.
    //
    //  * Section 2.3.2, the block function: key 00:01:...:1f, nonce
    //    00:00:00:09:00:00:00:4a:00:00:00:00, block count 1. Our stream
    //    starts at counter 0, so the RFC's block is our second one.
    //  * Section 2.4.2, the cipher: key 00:01:...:1f, nonce
    //    00:00:00:00:00:00:00:4a:00:00:00:00, initial counter 1, the RFC's
    //    "Sunscreen" plaintext and its published ciphertext. Xoring the
    //    plaintext with the keystream at counter 1 has to reproduce that
    //    ciphertext.
    const key: [32]u8 = .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    };

    // Section 2.3.2.
    const nonce_block: [12]u8 = .{ 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00 };
    var block_rng = ChaCha20Rng.init(&key, &nonce_block);
    var stream: [128]u8 = undefined;
    block_rng.randomBytes(&stream);
    var want_block: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want_block, "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e");
    try std.testing.expectEqualSlices(u8, &want_block, stream[64..128]);

    // Section 2.4.2.
    const nonce_cipher: [12]u8 = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00 };
    var cipher_rng = ChaCha20Rng.init(&key, &nonce_cipher);
    var cipher_stream: [64 + 114]u8 = undefined;
    cipher_rng.randomBytes(&cipher_stream);
    const keystream = cipher_stream[64..];
    var want_keystream: [114]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want_keystream, "224f51f3401bd9e12fde276fb8631ded8c131f823d2c06e27e4fcaec9ef3cf788a3b0aa372600a92b57974cded2b9334794cba40c63e34cdea212c4cf07d41b769a6749f3f630f4122cafe28ec4dc47e26d4346d70b98c73f3e9c53ac40c5945398b6eda1a832c89c167eacd901d7e2bf363");
    try std.testing.expectEqualSlices(u8, &want_keystream, keystream);

    const plaintext = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    try std.testing.expectEqual(@as(usize, 114), plaintext.len);
    var ciphertext: [114]u8 = undefined;
    for (0..114) |i| ciphertext[i] = plaintext[i] ^ keystream[i];
    var want_ciphertext: [114]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want_ciphertext, "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d");
    try std.testing.expectEqualSlices(u8, &want_ciphertext, &ciphertext);
}

test "Shake256Rng deterministic" {
    var rng1 = Shake256Rng.init();
    try rng1.absorbSeed("test seed");
    var rng2 = Shake256Rng.init();
    try rng2.absorbSeed("test seed");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const b1 = try rng1.squeeze(64, allocator);
    defer allocator.free(b1);
    const b2 = try rng2.squeeze(64, allocator);
    defer allocator.free(b2);

    try std.testing.expectEqualSlices(u8, b1, b2);
}

test "Shake256 matches hashlib.shake_256 (the standard, not our output)" {
    // Vectors from CPython's hashlib.shake_256 (OpenSSL), which implements
    // FIPS 202. Nothing in this repository produced them. The 136- and
    // 137-byte seeds sit exactly on and one past the 1088-bit rate, so the
    // block boundary is where a sponge goes wrong; `46b9dd2b...` is also the
    // widely published SHAKE256 of the empty string.
    const vectors = [_]struct { seed: []const u8, want: []const u8 }{
        .{ .seed = "", .want = "46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762f" },
        .{ .seed = "abc", .want = "483366601360a8771c6863080cc4114d8db44530f8f1e1ee4f94ea37e78b5739" },
        .{ .seed = "x" ** 136, .want = "7614c58639bf53a94aab54261d1f9b2607e66b6f34101e1dee67aae77feb36d3" },
        .{ .seed = "x" ** 137, .want = "dec52ac3834de8ec91882dfd9df517752dc80b9fd07cdda8bd511a98abfdc04f" },
        .{ .seed = "seed-material-for-shake-differential", .want = "967a44c50acbc675a70738446bba282f6ebb16b89aac2c0fa61b69fb18daf05b" },
    };
    for (vectors) |v| {
        var s = Shake256Rng.init();
        try s.absorbSeed(v.seed);
        const got = try s.squeeze32(std.testing.allocator);
        var want: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&want, v.want);
        try std.testing.expectEqualSlices(u8, &want, &got);
    }
}

test "Shake256Rng different seeds" {
    var rng1 = Shake256Rng.init();
    try rng1.absorbSeed("seed A");
    var rng2 = Shake256Rng.init();
    try rng2.absorbSeed("seed B");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const b1 = try rng1.squeeze(32, allocator);
    defer allocator.free(b1);
    const b2 = try rng2.squeeze(32, allocator);
    defer allocator.free(b2);

    try std.testing.expect(!std.mem.eql(u8, b1, b2));
}

test "Shake256Rng squeezeInto allocation-free" {
    var shake1 = Shake256Rng.init();
    try shake1.absorbSeed("fixed");
    var out: [48]u8 = undefined;
    try shake1.squeezeInto(&out);

    var shake2 = Shake256Rng.init();
    try shake2.absorbSeed("fixed");
    var out2: [48]u8 = undefined;
    try shake2.squeezeInto(&out2);

    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Fisher-Yates shuffle" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0x99} ** 32);
    var items = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    try shuffle(u32, ChaCha20Rng, &chacha, &items);

    // Verify all elements are still present (no duplicates or losses)
    var seen = std.StaticBitSet(10).initEmpty();
    for (items) |x| {
        try std.testing.expect(x < 10);
        try std.testing.expect(!seen.isSet(x));
        seen.set(x);
    }
}

test "randomPermutation" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0x77} ** 32);
    const perm = try randomPermutation(ChaCha20Rng, &chacha, 8, std.testing.allocator);
    defer std.testing.allocator.free(perm);

    var seen = std.StaticBitSet(8).initEmpty();
    for (perm) |x| {
        try std.testing.expect(x < 8);
        try std.testing.expect(!seen.isSet(x));
        seen.set(x);
    }
}

test "randomFieldElement F7" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0x11} ** 32);
    for (0..50) |_| {
        const f = try randomFieldElement(F7, ChaCha20Rng, &chacha);
        try std.testing.expect(f.value < 7);
    }
}

test "randomBool" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0x22} ** 32);
    var true_count: usize = 0;
    for (0..1000) |_| {
        if (randomBool(ChaCha20Rng, &chacha)) true_count += 1;
    }
    // Should be roughly 500, definitely not 0 or 1000
    try std.testing.expect(true_count > 300);
    try std.testing.expect(true_count < 700);
}

test "randomU64Bounded edge cases" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0x33} ** 32);
    // max = 1 is the only bound whose answer is forced.
    try std.testing.expectEqual(@as(u64, 0), try randomU64Bounded(ChaCha20Rng, &chacha, 1));
    // max = 2 has two possible answers, so the contract is the range. This
    // used to assert `== 0`, which was a property of the broken keystream and
    // not of the function: a wrong quarter round still draws *something*, and
    // the literal passed until the RFC 8439 vectors fixed the rotation
    // direction.
    for (0..32) |_| {
        const v = try randomU64Bounded(ChaCha20Rng, &chacha, 2);
        try std.testing.expect(v < 2);
    }
    try std.testing.expectError(error.InvalidBound, randomU64Bounded(ChaCha20Rng, &chacha, 0));
    try std.testing.expectError(error.InvalidBound, chacha.randomU64Bounded(0));
}

test "rejection sampling fails after a bounded number of attempts" {
    var rejecting = RejectingRng{};
    try std.testing.expectError(error.RejectionSamplingFailed, randomU64Bounded(RejectingRng, &rejecting, 100));
    try std.testing.expectError(error.RejectionSamplingFailed, randomFieldElement(F7, RejectingRng, &rejecting));
}

test "Shake256 rejects absorb/finalize after finalization" {
    var shake = Shake256Rng.init();
    try shake.absorbSeed("seed");
    try shake.finalize();

    // The old asserts on `!self.finalized` were compiled out in ReleaseFast,
    // where absorbing or re-finalizing corrupted the sponge state.
    try std.testing.expectError(error.AlreadyFinalized, shake.absorbSeed("late"));
    try std.testing.expectError(error.AlreadyFinalized, shake.finalize());
}

test "F7 legacy inv/div are total and the checked variants reject zero" {
    try std.testing.expect(F7.inv(F7.zero()).isZero());
    try std.testing.expect(F7.div(F7.one(), F7.zero()).isZero());
    try std.testing.expectError(error.InverseOfZero, F7.invChecked(F7.zero()));
    try std.testing.expectError(error.InverseOfZero, F7.divChecked(F7.one(), F7.zero()));
    const a = F7.fromInt(3);
    try std.testing.expect((try a.invChecked()).mul(a).eql(F7.one()));
}
