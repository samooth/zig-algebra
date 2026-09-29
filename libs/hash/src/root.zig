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
const zf = @import("zig-field");

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

/// The real field, imported. The algebraic-hash tests and the example each used
/// to declare their own minimal F7 -- 16 and 17 methods respectively, including
/// `invChecked` implementations that had never been executed -- because the
/// library did not depend on `zig-field` and no one decided that a consumer
/// should. Two copies of a fork of the field interface, one of them in a file
/// no build target compiled.
const F7 = zf.Field(7);

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

test "Poseidon hash padding separates messages from their zero extensions" {
    // The sponge absorbed partial blocks over a zeroed state, so any message
    // and its zero extension landed in the same padded stream: [a] and
    // [a, 0] hashed identically, and so did [a, 0, b] and [a, 0, b, 0] across
    // the block boundary. A hash that cannot tell a message from the same
    // message with a zero appended is not a hash.
    const PoseidonF7 = poseidon.Poseidon(F7, 3, 8, 57, 5);
    const p = try PoseidonF7.initFromSeed("test");
    const a = F7.fromInt(5);
    const b = F7.fromInt(3);

    const eqlPair = struct {
        fn call(x: [2]F7, y: [2]F7) bool {
            return x[0].eql(y[0]) and x[1].eql(y[1]);
        }
    }.call;

    try std.testing.expect(!eqlPair(p.hash(&.{a}), p.hash(&.{ a, F7.zero() })));

    try std.testing.expect(!eqlPair(p.hash(&.{ a, F7.zero(), b }), p.hash(&.{ a, F7.zero(), b, F7.zero() })));

    const empty = p.hash(&.{});
    try std.testing.expect(!(empty[0].isZero() and empty[1].isZero()));
    try std.testing.expect(!eqlPair(empty, p.hash(&.{F7.zero()})));
}

test "Poseidon permutation matches CryptoExperts' Hades (StarkNet parameters)" {
    // Known-answer vectors from poseidon-py 0.1.5 (Python bindings for the
    // CryptoExperts Poseidon C implementation, https://github.com/CryptoExperts/
    // poseidon), whose parameters StarkNet uses: t=3, RF=8, RP=83, alpha=3
    // (x^3), the partial-round S-box on the last cell, MDS =
    // [[3,1,1],[1,-1,1],[1,1,-2]]. The 107 round constants below are that
    // library's CONST_RC_MONTGOMERY_P3 de-Montgomery'd and laid out as three
    // per full round and (0,0,rc) for partial rounds; the three expected
    // states come from calling hades_permutation, never from this code.
    const S = zf.StarkNet_Fp;
    const round_keys: [91][3]S = .{
        .{ S.fromInt(0x6861759ea556a2339dd92f9562a30b9e58e2ad98109ae4780b7fd8eac77fe6f), S.fromInt(0x3827681995d5af9ffc8397a3d00425a3da43f76abf28a64e4ab1a22f27508c4), S.fromInt(0x3a3956d2fad44d0e7f760a2277dc7cb2cac75dc279b2d687a0dbe17704a8309) },
        .{ S.fromInt(0x626c47a7d421fe1f13c4282214aa759291c78f926a2d1c6882031afe67ef4cd), S.fromInt(0x78985f8e16505035bd6df5518cfd41f2d327fcc948d772cadfe17baca05d6a6), S.fromInt(0x5427f10867514a3204c659875341243c6e26a68b456dc1d142dcf34341696ff) },
        .{ S.fromInt(0x5af083f36e4c729454361733f0883c5847cd2c5d9d4cb8b0465e60edce699d7), S.fromInt(0x7d71701bde3d06d54fa3f74f7b352a52d3975f92ff84b1ac77e709bfd388882), S.fromInt(0x603da06882019009c26f8a6320a1c5eac1b64f699ffea44e39584467a6b1d3e) },
        .{ S.fromInt(0x4332a6f6bde2f288e79ce13f47ad1cdeebd8870fd13a36b613b9721f6453a5d), S.fromInt(0x53d0ebf61664c685310a04c4dec2e7e4b9a813aaeff60d6c9e8caeb5cba78e7), S.fromInt(0x5346a68894845835ae5ebcb88028d2a6c82f99f928494ee1bfc2d15eaabfebc) },
        .{ S.zero(), S.zero(), S.fromInt(0x4b085eb1df4258c3453cc97445954bf3433b6ab9dd5a99592864c00f54a3f9a) },
        .{ S.zero(), S.zero(), S.fromInt(0x731cfd19d508285965f12a079b2a169fdfe0a8e610e6f2d5ca5d7b0961f6d96) },
        .{ S.zero(), S.zero(), S.fromInt(0x217d08b5339852bcc6f7a774936b3e72ecd9e1f9a73d743f8079c1e3587eeaa) },
        .{ S.zero(), S.zero(), S.fromInt(0xc935dd633b0fd63599b13c850dab3cb966ba510c81b20959e267008518c6e) },
        .{ S.zero(), S.zero(), S.fromInt(0x52af8d378dd6772ee187ed23f79a7d98cf5a0a387103971467fe940e7b8b2be) },
        .{ S.zero(), S.zero(), S.fromInt(0x294851c98b2682f1ec9918b9f12fcceaa6e28a7b79b2e506362cda595f8ab75) },
        .{ S.zero(), S.zero(), S.fromInt(0x11b59990bacc280824d1021418d4f589da8c30063471494c204b169ab086064) },
        .{ S.zero(), S.zero(), S.fromInt(0x4b4df56e3d7753f91960d59ae099b9beb2ce690e6bbdcd0b599d49ceb2acd6a) },
        .{ S.zero(), S.zero(), S.fromInt(0x5eecfa15a757dc3ecae9fbd8ff06e466243534f30629fc5f1cf09eb5161ac4) },
        .{ S.zero(), S.zero(), S.fromInt(0x680bfdd8b9680e04659227634a1ec5282e5a7cef81b15677f8448bda4279059) },
        .{ S.zero(), S.zero(), S.fromInt(0x1d0bf8fab0a1a7a14e2930794f7a3065c17e10b1cedd791b8877d97acd85053) },
        .{ S.zero(), S.zero(), S.fromInt(0x2c2c8c79f808ace54ba207053c0d412c0fc11a610f14c48876701a37e32f464) },
        .{ S.zero(), S.zero(), S.fromInt(0x354ec9ed01d20ec52aae19a9b858d3474d8234c11ad7bce630ad56c54afa562) },
        .{ S.zero(), S.zero(), S.fromInt(0x30df20fcf6427bac38bb5d1a42287f4e4136ac5892340e994e6ea28deec1e55) },
        .{ S.zero(), S.zero(), S.fromInt(0x528cf329c64e7ee3040bafbdeff61e241d99b424091e31472eda296fc9c6778) },
        .{ S.zero(), S.zero(), S.fromInt(0x40416f24f623534634789660df5435ebf0c3e0c69e6c5b5ff6e757930bd1960) },
        .{ S.zero(), S.zero(), S.fromInt(0x380c8f936e2ed9fd488ae3bac7dce315ba21b11e88339cd5444435ccc9ea38) },
        .{ S.zero(), S.zero(), S.fromInt(0x1cc4f5d5603d176f1a8e344392efd2d03ad0541832829d245e0e2291f255b75) },
        .{ S.zero(), S.zero(), S.fromInt(0x5728917af5da91f9539310d99f5d142e011d6c8e015ea5423c502aa99c09752) },
        .{ S.zero(), S.zero(), S.fromInt(0xefb450a9e86e1a46e295a348f0f23590925107d17c56d7c788fecc17219aa1) },
        .{ S.zero(), S.zero(), S.fromInt(0x2020d74d36c421ae1a025616b342d0784b8fcd977de6c53a6c26693774dca99) },
        .{ S.zero(), S.zero(), S.fromInt(0x7cfb309b75fd3bf2705558ae511dc82335050969f4bf84fa2b7b4f583989287) },
        .{ S.zero(), S.zero(), S.fromInt(0x4651e48b2e9349a5365e009ece626809d7b7d02a617eb98c785a784812d75e9) },
        .{ S.zero(), S.zero(), S.fromInt(0xd77627b270f65122d0269719da923ccae822d9aad0f0947a3b5c8f71c0dcc7) },
        .{ S.zero(), S.zero(), S.fromInt(0x199ad3d641b54c4d571b3fe37773a8b82b003377f0dd8b7d3b7758c32908ea8) },
        .{ S.zero(), S.zero(), S.fromInt(0x44f33640a8ecfd3973e2e9172a7333482b2d297be2da289319e72d137cdfe6e) },
        .{ S.zero(), S.zero(), S.fromInt(0x7e4adf9894d964189d00a02dcf1e6be7f801234f5216eab6b6f366b6701abf7) },
        .{ S.zero(), S.zero(), S.fromInt(0x3641fa5b3c90452f5ff808f8a9817eda7c6aecfb5471dfdca559fb4e711ee90) },
        .{ S.zero(), S.zero(), S.fromInt(0x3de5729efd2fcbd897a49a78fa923fc306df32e6e2f0e02d0eee2c2cc3f3533) },
        .{ S.zero(), S.zero(), S.fromInt(0x62691891a3fc1e27f622966ca0be20c06563500c8f06c9bdb77bd2882d6c994) },
        .{ S.zero(), S.zero(), S.fromInt(0x6608d3bf11c18e4688739f72205763d1590cc4f9885ae1d86e96e0604baa0be) },
        .{ S.zero(), S.zero(), S.fromInt(0x11c9c9b39cac71e3419726ce779116d07249f51cbdda4fd98c25cbbf593a316) },
        .{ S.zero(), S.zero(), S.fromInt(0x61e23b58203269caef0850f74da27b9748e3312ea40c6844dd68c557c462ad7) },
        .{ S.zero(), S.zero(), S.fromInt(0x4182cd9ab1d9488f870a572010bc2a3d9878440b25951e4ce010855cf83bdc8) },
        .{ S.zero(), S.zero(), S.fromInt(0x520fe6c4a096793f9055e6823116d15f1df2fe89d306f9965f6a59f4f3ecb71) },
        .{ S.zero(), S.zero(), S.fromInt(0x346b2b2d6e5810129e093093dcd3dfa99ed6d71f47723ea3fbe4d4e2fd4afa1) },
        .{ S.zero(), S.zero(), S.fromInt(0x1359ca923e7f1448ec1dd2a3684bee4e8b682c8e8e973acea72877ce9f7e6cf) },
        .{ S.zero(), S.zero(), S.fromInt(0x47c655f55cf307800dfefdad24de86fde9deadab145a1b392420f37b95d9675) },
        .{ S.zero(), S.zero(), S.fromInt(0x4ab291f16555fa8a968cd7c9c285a9598efd925f2d58b7aa38ad87dca8441a8) },
        .{ S.zero(), S.zero(), S.fromInt(0x39f409c7c782101223d1f6f7d86c21a22c44ef959510e392c9c7c5d17c629c5) },
        .{ S.zero(), S.zero(), S.fromInt(0x44be36b782f882ad86eecb0cd6beb02e1a2f9fb5587a3babfacead0cafb6052) },
        .{ S.zero(), S.zero(), S.fromInt(0x50a1dfde9b504ad2906db6eb5b507203cd1ceb394c52ce7107679a53a0d538b) },
        .{ S.zero(), S.zero(), S.fromInt(0x5c753c14da89e287b181c0dd11ac6c3680bdd7f1017dae083e7aebbeab183ab) },
        .{ S.zero(), S.zero(), S.fromInt(0x2cf6306ed32232106c8015a3b180f386eee93e15f7b4f4fa57746525fc0520c) },
        .{ S.zero(), S.zero(), S.fromInt(0x2c2014634d52e27420873cf347429091dfc6380689bd4f54d7d8e502c1c3a09) },
        .{ S.zero(), S.zero(), S.fromInt(0x3cfb9c5bd93e02b2fdacde2058e33e5975c446345f010d850fc09cdf86ed8a1) },
        .{ S.zero(), S.zero(), S.fromInt(0x363fa71a383cf3897933f1411fc5f806e311e84f72cb50a9ea4e1281f6b0299) },
        .{ S.zero(), S.zero(), S.fromInt(0x728199657067ee16947b3fc76271676b4901b2a3686cffebcb960da91b05df8) },
        .{ S.zero(), S.zero(), S.fromInt(0x3fdfbd47d27f3d34f0723b728e8921dc9bde34a9872df5a652a078d7e4ee021) },
        .{ S.zero(), S.zero(), S.fromInt(0x7f241379440cacd7dc0efbe7858eb7de53cc02ca7d24197945c453398eff449) },
        .{ S.zero(), S.zero(), S.fromInt(0x5b2e8771ea9a0004e3bf056f3727797cbb457a27574d5f104354e52a5c25f0b) },
        .{ S.zero(), S.zero(), S.fromInt(0xa8ddbce708de44a7e0b3b0333146e1e910245be6bf822ea057a081bda2e23e) },
        .{ S.zero(), S.zero(), S.fromInt(0x2d521e0daca24e431aa47cd90a0f551c12270e533835613edce2e19aa9b0f61) },
        .{ S.zero(), S.zero(), S.fromInt(0x6cdbc0f2aa54d2cf7d5ac3b93f855af03eef7b07aaee00341a6266c30e08ae6) },
        .{ S.zero(), S.zero(), S.fromInt(0x3dd96a17111ec8f4c5da3ad6794c0961ceee452cbe92c7a0941112b36ed9bf3) },
        .{ S.zero(), S.zero(), S.fromInt(0x5eafb1edeedc5c07ac07fdd06159344a2cfb92196a65d9ec0c5e732c36687dc) },
        .{ S.zero(), S.zero(), S.fromInt(0x4ab038d7b09eda9324577b260feaebdbcec5a7b7c7f449b312cfcd065c207e6) },
        .{ S.zero(), S.zero(), S.fromInt(0x4ca71981e4df6b505d2b0d94e235608463c58052570f68e495fc80c7fdef220) },
        .{ S.zero(), S.zero(), S.fromInt(0x6dee9c6da4617e32aa419899c8ea8137e9b59d7e2759ffe573c15b77e413d2f) },
        .{ S.zero(), S.zero(), S.fromInt(0x58f9e60b34ddab84dcbe2396065a4305b4a795a4770e4541e625d0460c6f186) },
        .{ S.zero(), S.zero(), S.fromInt(0x47b7b4a802a10c1e6c9c735db6c34042d290906f274bea8fcecef17fc9af632) },
        .{ S.zero(), S.zero(), S.fromInt(0x1849bcdb9ad7171096ecc936a186774084a074be0bfc0fbb9463a06a2bd430c) },
        .{ S.zero(), S.zero(), S.fromInt(0x41870fbe04438348af5767bddaecd8aea3b49b4217547dec4d699b1466736cc) },
        .{ S.zero(), S.zero(), S.fromInt(0x226c04e598076a9fa02aa64557daf28c0ec42e3d4da68d1965029d284738b07) },
        .{ S.zero(), S.zero(), S.fromInt(0x1f0e971f0485a5b42eb92d6655c3ddb475cec4371f269a95335b2a7d6dac0fb) },
        .{ S.zero(), S.zero(), S.fromInt(0x9f31cc2907dccbf994d35aa47ee3f4ebdf3703f795047a7b40dd3926431563) },
        .{ S.zero(), S.zero(), S.fromInt(0x4b40cce78f3b641e31ce4df58ce5a42c22cfbc198c84451ffe8cca4c64bd7d2) },
        .{ S.zero(), S.zero(), S.fromInt(0x191660489e4bd8a3e4563173de4a226f3ac736962fdfb70f72cb93ce50f8b9f) },
        .{ S.zero(), S.zero(), S.fromInt(0x18c0919618db971f74eb01f293f2daea814b475103373dc7ed8dd4c7b467410) },
        .{ S.zero(), S.zero(), S.fromInt(0x35b60253848530e845c8753121577d0ef37002e941c3dc1fb240bd57eadc803) },
        .{ S.zero(), S.zero(), S.fromInt(0x1ae99db1575ae91c8b43a9f71a5f362581ad9b413d97fa6fd029134957451d5) },
        .{ S.zero(), S.zero(), S.fromInt(0x3e6e1d0f3f8a0f728148ebcbd5d7d337d7cb8feb58a37d2d1dfb357e172647b) },
        .{ S.zero(), S.zero(), S.fromInt(0x18bc36dffa8f96a659e1a171b55d2706ee3e9ad619e16f5c38dd1f4a209b8f3) },
        .{ S.zero(), S.zero(), S.fromInt(0x2c7a3ef1afb6a302b54afc3a107ff9199a16efe9a1cc3ab83fa5b64893de4ed) },
        .{ S.zero(), S.zero(), S.fromInt(0x53a7bd889bed07bf5e27dd8e92f6ae85e4fe4e84b0c6dde9856e94469de4bd7) },
        .{ S.zero(), S.zero(), S.fromInt(0x4d383ff7ffc6318fda704aca35995f86bec5a02ce9a0bf9d3cc0cc2f03ccea9) },
        .{ S.zero(), S.zero(), S.fromInt(0x4667b6762fb8ad53d07ef7e8a65b21ca96e0b3503037710d1292519c326f5cd) },
        .{ S.zero(), S.zero(), S.fromInt(0x2cc8b43e75cf0b42a93c39ea98bcd46055dccc9589f02eb7fb536422e5921f) },
        .{ S.zero(), S.zero(), S.fromInt(0x6b32ee98680871d38751447bfd76086ba4df0e7be59c55f4b2ce25582bf9c60) },
        .{ S.zero(), S.zero(), S.fromInt(0x3e907927c7182faaa3b3c81358b82e734efac1f0609f0862d635cb1387102a3) },
        .{ S.zero(), S.zero(), S.fromInt(0x3f3a5057b3a08975f0253728e512af78d2f437973f6a93793ea5e8424fbc6ea) },
        .{ S.zero(), S.zero(), S.fromInt(0x14b491d73724779f8aa74b3fd8aa5821c21e1017224726a7a946bb6ca68d8f5) },
        .{ S.zero(), S.zero(), S.fromInt(0x5c8278c7bbfc30ae7f60e514fe3b9367aca84c54ad1373861695ea4abb814ef) },
        .{ S.fromInt(0x64851937f9836ee5a08a7dde65e44b467018a82ba3bf99bba0b4502755c8074), S.fromInt(0x6a9ac84251294769eca450ffb52b441882be77cb85f422ff9ea5e73f1d971dc), S.fromInt(0x37ec35b710b0d04c9a2b71f2f7bd098c6a81d991d27f0fc1884f5ca545064de) },
        .{ S.fromInt(0x5334f75b052c0235119816883040da72c6d0a61538bdfff46d6a242bfeb7a1), S.fromInt(0x5d0af4fcbd9e056c1020cca9d871ae68f80ee4af2ec6547cd49d6dca50aa431), S.fromInt(0x30131bce2fba5694114a19c46d24e00b4699dc00f1d53ba5ab99537901b1e65) },
        .{ S.fromInt(0x5646a95a7c1ae86b34c0750ed2e641c538f93f13161be3c4957660f2e788965), S.fromInt(0x4b9f291d7b430c79fac36230a11f43e78581f5259692b52c90df47b7d4ec01a), S.fromInt(0x5006d393d3480f41a98f19127072dc83e00becf6ceb4d73d890e74abae01a13) },
        .{ S.fromInt(0x62c9d42199f3b260e7cb8a115143106acf4f702e6b346fd202dc3b26a679d80), S.fromInt(0x51274d092db5099f180b1a8a13b7f2c7606836eabd8af54bf1d9ac2dc5717a5), S.fromInt(0x61fc552b8eb75e17ad0fb7aaa4ca528f415e14f0d9cdbed861a8db0bfff0c5b) },
    };
    const mds: [3][3]S = .{
        .{ S.fromInt(3), S.fromInt(1), S.fromInt(1) },
        .{ S.fromInt(1), S.fromInt(1).neg(), S.fromInt(1) },
        .{ S.fromInt(1), S.fromInt(1), S.fromInt(2).neg() },
    };

    const p = poseidon.PoseidonVariant(S, 3, 8, 83, 3, 2).init(round_keys, mds);

    var a = [3]S{ S.fromInt(1), S.fromInt(2), S.fromInt(3) };
    p.permute(&a);
    try std.testing.expect(a[0].eql(S.fromInt(0xfa8c9b6742b6176139365833d001e30e932a9bf7456d009b1b174f36d558c5)));
    try std.testing.expect(a[1].eql(S.fromInt(0x4f04deca4cb7f9f2bd16b1d25b817ca2d16fba2151e4252a2e2111cde08bfe6)));
    try std.testing.expect(a[2].eql(S.fromInt(0x58dde0a2a785b395ee2dc7b60b79e9472ab826e9bb5383a8018b59772964892)));

    var b = [3]S{ S.zero(), S.zero(), S.zero() };
    p.permute(&b);
    try std.testing.expect(b[0].eql(S.fromInt(0x79e8d1e78258000a28fc9d49e233bc6852357968577b1e386550ed6a9086133)));
    try std.testing.expect(b[1].eql(S.fromInt(0x3840d003d0f3f96dbb796ff6aa6a63be5b5404b91ccaabca256154cbb6fb984)));
    try std.testing.expect(b[2].eql(S.fromInt(0x1eb39da3f7d3b04142d0ac83d9da00c9325a61fb2ef326e50b70eaa8a3c7cc7)));

    var c = [3]S{ S.fromInt(7), S.fromInt(11), S.fromInt(13) };
    p.permute(&c);
    try std.testing.expect(c[0].eql(S.fromInt(0x3c74696ff739d8a65224b7c1a9e227ba76644762569788ffa172fb4b1c3cf8)));
    try std.testing.expect(c[1].eql(S.fromInt(0x1e920363300a64a10ac8feb8699127ac3ca38c228746a6893e58ecb3855cfaa)));
    try std.testing.expect(c[2].eql(S.fromInt(0x763d1b6a4b1a4a3692cf012e3a1ed7a0aae4c41b0143bcd84f7779fe55e1d66)));
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
    // `DivisionByZero`, not `InverseOfZero`. The hand-rolled F7 this test was
    // written against returned `InverseOfZero` from `divChecked`, so the test
    // was asserting the fork's error set rather than the library's -- the two
    // had already diverged, and the divergence was only visible when the real
    // field was imported.
    try std.testing.expectError(error.DivisionByZero, F7.divChecked(F7.one(), F7.zero()));
    const a = F7.fromInt(3);
    try std.testing.expect((try a.invChecked()).mul(a).eql(F7.one()));
}
