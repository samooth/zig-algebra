//! zig-hash: Cryptographic hash functions for Zig.
//!
//! Includes:
//! - Blake3 (fast, parallelizable, XOF)
//! - Blake2b / Blake2s (RFC 7693)
//! - Keccak-256 / SHA3-256
//! - Poseidon (ZK-friendly, algebraic)
//! - MiMC (minimal constraints for SNARKs)
//! - Pedersen hash (elliptic-curve based, trait-based)

const std = @import("std");

pub const blake3 = @import("blake3.zig");
pub const blake2 = @import("blake2.zig");
pub const keccak = @import("keccak.zig");
pub const poseidon = @import("poseidon.zig");
pub const mimc = @import("mimc.zig");

// Re-exports for convenience
pub const Blake3 = blake3.Blake3;
pub const Blake2b256 = blake2.Blake2b256;
pub const Blake2s256 = blake2.Blake2s256;
pub const Keccak256 = keccak.Keccak256;
pub const Sha3_256 = keccak.Sha3_256;
pub const Poseidon = poseidon.Poseidon;
pub const MiMC = mimc.MiMC;

// One-shot functions
pub const hashBlake3 = blake3.hash;
pub const hashBlake2b256 = blake2.blake2b256;
pub const hashBlake2s256 = blake2.blake2s256;
pub const hashKeccak256 = keccak.keccak256;
pub const hashSha3_256 = keccak.sha3_256;

// Common hash interface (matches zig-stark's core/hash/hash.zig)
pub const Hash = struct {
    pub const Digest = [32]u8;

    pub fn hashBytes(msg: []const u8) Digest {
        return blake3.hash(msg);
    }

    pub fn hash2(a: Digest, b: Digest) Digest {
        var h = blake3.Blake3.init(.{});
        h.update("zig-stark:pair");
        h.update(&a);
        h.update(&b);
        var out: Digest = undefined;
        h.final(&out);
        return out;
    }
};

// ============================================================================
// Tests
// ============================================================================

// Minimal F7 field for algebraic hash tests
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
    } // stub
};

test "Blake3 basic hash" {
    const msg = "hello world";
    const out = blake3.hash(msg);
    // Known test vector for "hello world" (first 32 bytes)
    // Just verify it doesn't crash and produces consistent output
    const out2 = blake3.hash(msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);

    // Different message -> different hash
    const out3 = blake3.hash("hello world!");
    try std.testing.expect(!std.mem.eql(u8, &out, &out3));
}

test "cryptographic hash known-answer vectors" {
    // Was `bd214b44...`, which is not BLAKE3 at all: that digest was produced by
    // this repository's own broken Blake3, so the vector pinned the bug. The
    // real BLAKE3("hello world") is d74981ef..., from an independent
    // implementation. The blake2b/blake2s/keccak/sha3 vectors below were
    // already correct and are unchanged.
    const blake3_expected = [_]u8{
        0xd7, 0x49, 0x81, 0xef, 0xa7, 0x0a, 0x0c, 0x88,
        0x0b, 0x8d, 0x8c, 0x19, 0x85, 0xd0, 0x75, 0xdb,
        0xcb, 0xf6, 0x79, 0xb9, 0x9a, 0x5f, 0x99, 0x14,
        0xe5, 0xaa, 0xf9, 0x6b, 0x83, 0x1a, 0x9e, 0x24,
    };
    try std.testing.expectEqualSlices(u8, &blake3_expected, &blake3.hash("hello world"));

    const blake2b_expected = [_]u8{
        0xbd, 0xdd, 0x81, 0x3c, 0x63, 0x42, 0x39, 0x72,
        0x31, 0x71, 0xef, 0x3f, 0xee, 0x98, 0x57, 0x9b,
        0x94, 0x96, 0x4e, 0x3b, 0xb1, 0xcb, 0x3e, 0x42,
        0x72, 0x62, 0xc8, 0xc0, 0x68, 0xd5, 0x23, 0x19,
    };
    try std.testing.expectEqualSlices(u8, &blake2b_expected, &blake2.blake2b256("abc"));

    const blake2s_expected = [_]u8{
        0x50, 0x8c, 0x5e, 0x8c, 0x32, 0x7c, 0x14, 0xe2,
        0xe1, 0xa7, 0x2b, 0xa3, 0x4e, 0xeb, 0x45, 0x2f,
        0x37, 0x45, 0x8b, 0x20, 0x9e, 0xd6, 0x3a, 0x29,
        0x4d, 0x99, 0x9b, 0x4c, 0x86, 0x67, 0x59, 0x82,
    };
    try std.testing.expectEqualSlices(u8, &blake2s_expected, &blake2.blake2s256("abc"));

    const keccak_expected = [_]u8{
        0x4e, 0x03, 0x65, 0x7a, 0xea, 0x45, 0xa9, 0x4f,
        0xc7, 0xd4, 0x7b, 0xa8, 0x26, 0xc8, 0xd6, 0x67,
        0xc0, 0xd1, 0xe6, 0xe3, 0x3a, 0x64, 0xa0, 0x36,
        0xec, 0x44, 0xf5, 0x8f, 0xa1, 0x2d, 0x6c, 0x45,
    };
    try std.testing.expectEqualSlices(u8, &keccak_expected, &keccak.keccak256("abc"));

    const sha3_expected = [_]u8{
        0x3a, 0x98, 0x5d, 0xa7, 0x4f, 0xe2, 0x25, 0xb2,
        0x04, 0x5c, 0x17, 0x2d, 0x6b, 0xd3, 0x90, 0xbd,
        0x85, 0x5f, 0x08, 0x6e, 0x3e, 0x9d, 0x52, 0x5b,
        0x46, 0xbf, 0xe2, 0x45, 0x11, 0x43, 0x15, 0x32,
    };
    try std.testing.expectEqualSlices(u8, &sha3_expected, &keccak.sha3_256("abc"));

    const PoseidonF7 = poseidon.Poseidon(F7, 3, 8, 57, 5);
    const poseidon_hash = try PoseidonF7.initFromSeed("demo");
    try std.testing.expectEqual(@as(u64, 3), poseidon_hash.hash2(F7.fromInt(1), F7.fromInt(2)).value);

    const MiMCF7 = mimc.MiMC(F7, 91, 5);
    const mimc_hash = try MiMCF7.initFromSeed("demo");
    try std.testing.expectEqual(@as(u64, 5), mimc_hash.hash2(F7.fromInt(1), F7.fromInt(2)).value);
}

test "Blake3 known-answer vectors, canonical (BLAKE3 KAT, not self-generated)" {
    // **The digests below come from an independent BLAKE3, not from this
    // implementation.** That is the entire point: a test written against the
    // implementation passes by construction. The existing "cryptographic hash
    // known-answer vectors" test had a Blake3 entry that this very
    // implementation produced, so it pinned the bug and passed forever -- a
    // known-answer test that is worse than none, because it looks rigorous.
    //
    // The input is a fixed repeating pattern; the digests are literals. Lengths
    // 0..8 and 63..65 cover the block edges, and the dense sweeps around 1024
    // and 2048 are the ones that matter: BLAKE3's chunk is 1024 bytes, so a
    // single-block vector never exercises the chunk counter, the chaining
    // across chunks, or the parent-node logic. Two short vectors would have
    // caught this bug; these are what stops it coming back.
    const pattern = [_]u8{ 251, 29, 51, 60, 62, 23, 249, 43, 190, 55, 60, 126, 138, 179, 98, 101 };

    const Vector = struct { len: usize, digest: []const u8 };
    const vectors = [_]Vector{
        .{ .len = 0, .digest = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262" },
        .{ .len = 1, .digest = "6f0dca6172751acf9d1c8232950d788c27119090ec34fdaa8fb3c1ec4cc67277" },
        .{ .len = 2, .digest = "0d03479de49204f3cf2d2818047d23253693a3e13d6716959496733db4e46258" },
        .{ .len = 3, .digest = "4dd91062928cc76fedb11acf56e25487f8a60e4eecd156d21283c640fdf359c3" },
        .{ .len = 4, .digest = "bfd38e7450466d7ca65b363f508cd0db6dd278f1afcee78789ca28b1f3998028" },
        .{ .len = 5, .digest = "c33ffbfd3912399cf457bb6ec4c1b6eaf43c690e8cc13abe8324a5b62bd8945d" },
        .{ .len = 6, .digest = "b374fff89a846df54cfd2419a73fe3d25c0d5721db971bd4e84d8c0b7b5a8394" },
        .{ .len = 7, .digest = "742873187603581df805140acbeff8f0042398bf2880de7cb7c49c0fd70ab164" },
        .{ .len = 8, .digest = "fb73b378fcee2b7c3299fa805a6d0340d9aa15d405b46becd77a92ce383830af" },
        .{ .len = 63, .digest = "f0090b8c2ebd20830c894ee32c4f95dbdc461483321a14a3dd3b9eafb1824a9a" },
        .{ .len = 64, .digest = "fd3a52e8bca0bed0a40f09cddb32232202cb56b64e70864c05bd0df8bb761439" },
        .{ .len = 65, .digest = "2d54b39c2a3ca275e23825cf7a795a2f8a04826a581c845a314fccfbb611ad2c" },
        .{ .len = 127, .digest = "b55f1ce4da5326835c60ce7367171106e5f0775c3720b4aa68470725a4a10381" },
        .{ .len = 128, .digest = "465bc797c43366924006fdd6b7651c9f4bac10d5b09736c20e94546c0977cfdd" },
        .{ .len = 129, .digest = "90797a4d37869c7306f55edf59b44d8a16841d91ffe803525e9d9adf3771a1de" },
        .{ .len = 1018, .digest = "0030551cfdf2ee8fe900f1ebe2fb788fbabb45c2a7160165d0c408f415b6cda8" },
        .{ .len = 1019, .digest = "0d94e503d13456fde9a1e06fa36d78c6c125d148c03259f2f6e9c672e242b1f8" },
        .{ .len = 1020, .digest = "5447f44dbfb825ed7bb90fccf88b2f2940dd8881f1dd38d9be17ea5b40dd5abb" },
        .{ .len = 1021, .digest = "481f4fa29135444c806f6b18e8a023df44de1ed365e10f55a4222507408f8c6c" },
        .{ .len = 1022, .digest = "f6ec46c461a7e5ece38f38d121b55bb7fbc7e4bc8cc20cefacf12120455bbc86" },
        .{ .len = 1023, .digest = "7e4b6cfaa58b6b3aebc061c11090e3a36345b7c91c34742d279f90782c0ec9fb" },
        .{ .len = 1024, .digest = "7bae33ce1ad8edc8d7bbd0715d84abcecccd1a64914b9412a163feda369cc00e" },
        .{ .len = 1025, .digest = "8be605cf3649f43b0b55cbc249cb8895ddea73136741aa38d2715a6c1d13f5af" },
        .{ .len = 1026, .digest = "1117c99158477cc8d7363e334202af3daa4a18628c593ebf98f07ef0a60d371a" },
        .{ .len = 1027, .digest = "1c3b3de026e02194acf68bec76a5b83efcea8ce0cf50b64d6e8ac9aae1d0bc6a" },
        .{ .len = 1028, .digest = "408422d7a347e4e28f46082c80f46d26d91137eed473a61bec3160e32e30ea9d" },
        .{ .len = 1029, .digest = "bd040b13ac50abd9c2905191c5afb8e991f8a395b9306baac940b5ee0a379cd9" },
        .{ .len = 1030, .digest = "46581b87e71fc8fdd4f3570b6edd2e789dda49298f89c93cd64eca17d72b582a" },
        .{ .len = 2042, .digest = "3701c8a56d398282f6495520cebdbb517bdcd47c641e9d40cfc27cf5e1f4090a" },
        .{ .len = 2043, .digest = "15f0be1a00a88fb05ae480da9c7444e76700813f25cbb32ad61b8277cd6e4a79" },
        .{ .len = 2044, .digest = "95d2cb6b1f66089880d6087bd88fd87ec0c1eb9de30da21525f5fb0592ad94d5" },
        .{ .len = 2045, .digest = "72faa65115e475b52f6a3b76ff5d8cbb7406cae3f9bcefeacb3d1eaca5e23289" },
        .{ .len = 2046, .digest = "6c044c3b9f400cf23bae88184086f79b1739b56f11eac1fb53a9fc28f20d5510" },
        .{ .len = 2047, .digest = "7fce8ad44ed01d91de6fd0516bc547e1887d6f5d82fd5600d707b4009ec6a38e" },
        .{ .len = 2048, .digest = "4615884a4ad7130594f47bd77fe23d52bde86e81a11aa9a2ca23825ff687601f" },
        .{ .len = 2049, .digest = "47f27e9ab7ef85cbd3093f16da345f3415a3dad17426717a778246652d00b57a" },
        .{ .len = 2050, .digest = "2b614de08f314ac4226cefcd7db538e5af03b1e2a5d745aca1c21438f298390e" },
        .{ .len = 2051, .digest = "e9750bb89159e554257e3458d00b48f52e94b8d556115d45da2572860c4a9069" },
        .{ .len = 2052, .digest = "50f86349ee88aa389e7ae4da818b9b232a8f6b4d80183be0cc94c52877be7fa9" },
        .{ .len = 2053, .digest = "ea85c859da4b24bedb171b9fc5c80b5862ac8355541a4d841929e9835e53df0c" },
        .{ .len = 2054, .digest = "05a423dbd4c4b11e968efbe6f42ff195bfac896e3c4de23dedafaaa0cb18663a" },
        .{ .len = 3072, .digest = "8b4b8bff0477463a3e70cb7fb18bc293f1c70235edb083a292eb6c9a5ec9f28b" },
        .{ .len = 4095, .digest = "35c7388092810b9934921a14a6f0e3f2df9c590cc7c1a1902d3b12803f24951f" },
        .{ .len = 4096, .digest = "31d5fead75b0dda701bd473515a93d6c44a4cee2fda098cf77450ee26e04597e" },
        .{ .len = 4097, .digest = "c27b713545cbc8390003af773cb28e45bb703b976e42d190682f281cd59ef38c" },
    };

    var input: [4097]u8 = undefined;
    for (vectors) |v| {
        for (0..v.len) |i| input[i] = pattern[i % pattern.len];
        const got = blake3.hash(input[0..v.len]);
        const hex = std.fmt.bytesToHex(got, .lower);
        std.testing.expectEqualStrings(v.digest, &hex) catch |e| {
            std.debug.print("Blake3 KAT failed at len={d}:\n  want {s}\n  got  {s}\n", .{ v.len, v.digest, &hex });
            return e;
        };
    }
}

test "Blake3 keyed hash" {
    const key = [_]u8{0x01} ** 32;
    const out = blake3.keyedHash(&key, "test");
    const out2 = blake3.keyedHash(&key, "test");
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Blake3 derive key" {
    const out = blake3.deriveKey("context", "material");
    const out2 = blake3.deriveKey("context", "material");
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Blake2b256 basic" {
    const msg = "abc";
    const out = blake2.blake2b256(msg);
    const out2 = blake2.blake2b256(msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Blake2s256 basic" {
    const msg = "abc";
    const out = blake2.blake2s256(msg);
    const out2 = blake2.blake2s256(msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Keccak256 basic" {
    const msg = "abc";
    const out = keccak.keccak256(msg);
    const out2 = keccak.keccak256(msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "SHA3-256 basic" {
    const msg = "abc";
    const out = keccak.sha3_256(msg);
    const out2 = keccak.sha3_256(msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Keccak vs SHA3 different" {
    const msg = "abc";
    const k = keccak.keccak256(msg);
    const s = keccak.sha3_256(msg);
    try std.testing.expect(!std.mem.eql(u8, &k, &s));
}

test "Poseidon over F7" {
    const PoseidonF7 = poseidon.Poseidon(F7, 3, 8, 57, 5);
    const p = try PoseidonF7.initFromSeed("test");

    const a = F7.fromInt(1);
    const b = F7.fromInt(2);
    const h = p.hash2(a, b);

    // Deterministic
    const h2 = p.hash2(a, b);
    try std.testing.expect(h.eql(h2));
}

test "MiMC over F7" {
    const MiMCF7 = mimc.MiMC(F7, 91, 5);
    const m = try MiMCF7.initFromSeed("test");

    const a = F7.fromInt(1);
    const b = F7.fromInt(2);
    const h = m.hash2(a, b);

    // Deterministic
    const h2 = m.hash2(a, b);
    try std.testing.expect(h.eql(h2));
}

test "Poseidon and MiMC reject oversized seeds" {
    const PoseidonF7 = poseidon.Poseidon(F7, 3, 8, 57, 5);
    const MiMCF7 = mimc.MiMC(F7, 91, 5);
    const seed = try std.testing.allocator.alloc(u8, poseidon.MAX_SEED_LEN + 1);
    defer std.testing.allocator.free(seed);
    try std.testing.expectError(error.SeedTooLong, PoseidonF7.initFromSeed(seed));
    try std.testing.expectError(error.SeedTooLong, MiMCF7.initFromSeed(seed));
}

test "streaming Blake3" {
    var hasher = Blake3.init();
    hasher.update("hello");
    hasher.update(" ");
    hasher.update("world");
    var out: [32]u8 = undefined;
    hasher.finalize(&out);

    const expected = blake3.hash("hello world");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "streaming Keccak256" {
    var hasher = Keccak256.init();
    hasher.update("hello");
    hasher.update(" ");
    hasher.update("world");
    var out: [32]u8 = undefined;
    hasher.finalize(&out);

    const expected = keccak.keccak256("hello world");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "streaming SHA3-256" {
    var hasher = Sha3_256.init();
    hasher.update("hello");
    hasher.update(" ");
    hasher.update("world");
    var out: [32]u8 = undefined;
    hasher.finalize(&out);

    const expected = keccak.sha3_256("hello world");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "Blake3 long message" {
    const msg = "a" ** 10000;
    const out = blake3.hash(msg[0..]);
    const out2 = blake3.hash(msg[0..]);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Blake3 empty message" {
    const out = blake3.hash("");
    const out2 = blake3.hash("");
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "F7 legacy inv/div are total and the checked variants reject zero" {
    try std.testing.expect(F7.inv(F7.zero()).isZero());
    try std.testing.expect(F7.div(F7.one(), F7.zero()).isZero());
    try std.testing.expectError(error.InverseOfZero, F7.invChecked(F7.zero()));
    try std.testing.expectError(error.InverseOfZero, F7.divChecked(F7.one(), F7.zero()));
    const a = F7.fromInt(3);
    try std.testing.expect((try a.invChecked()).mul(a).eql(F7.one()));
}
