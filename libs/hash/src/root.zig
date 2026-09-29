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

test "initSpec reproduces the IAIK Grain generator (circomlibjs, BN254 Fr)" {
    // Parameters of the IAIK generate_parameters_grain.sage command that
    // circomlibjs documents for poseidon_constants.json:
    // `1 0 254 3 8 57 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001`
    // -- FIELD=1 (GF(p)), SBOX=0, n=254, t=3, RF=8, RP=57 over the BN254
    // scalar field. The 195 round constants (their C[1]) and the 3x3 Cauchy
    // MDS (their M[1]) below are that published JSON, and the three expected
    // states are their poseidon_reference.js with initState 0 -- none of
    // them was produced by this code.
    const B = zf.Field(0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001);
    const p = try poseidon.PoseidonVariant(B, 3, 8, 57, 5, 0).initSpec();

    const expected_round_constants: [195]u256 = .{
        0x0ee9a592ba9a9518d05986d656f40c2114c4993c11bb29938d21d47304cd8e6e, 0x00f1445235f2148c5986587169fc1bcd887b08d4d00868df5696fff40956e864, 0x08dff3487e8ac99e1f29a058d0fa80b930c728730b7ab36ce879f3890ecf73f5,
        0x2f27be690fdaee46c3ce28f7532b13c856c35342c84bda6e20966310fadc01d0, 0x2b2ae1acf68b7b8d2416bebf3d4f6234b763fe04b8043ee48b8327bebca16cf2, 0x0319d062072bef7ecca5eac06f97d4d55952c175ab6b03eae64b44c7dbf11cfa,
        0x28813dcaebaeaa828a376df87af4a63bc8b7bf27ad49c6298ef7b387bf28526d, 0x2727673b2ccbc903f181bf38e1c1d40d2033865200c352bc150928adddf9cb78, 0x234ec45ca27727c2e74abd2b2a1494cd6efbd43e340587d6b8fb9e31e65cc632,
        0x15b52534031ae18f7f862cb2cf7cf760ab10a8150a337b1ccd99ff6e8797d428, 0x0dc8fad6d9e4b35f5ed9a3d186b79ce38e0e8a8d1b58b132d701d4eecf68d1f6, 0x1bcd95ffc211fbca600f705fad3fb567ea4eb378f62e1fec97805518a47e4d9c,
        0x10520b0ab721cadfe9eff81b016fc34dc76da36c2578937817cb978d069de559, 0x1f6d48149b8e7f7d9b257d8ed5fbbaf42932498075fed0ace88a9eb81f5627f6, 0x1d9655f652309014d29e00ef35a2089bfff8dc1c816f0dc9ca34bdb5460c8705,
        0x04df5a56ff95bcafb051f7b1cd43a99ba731ff67e47032058fe3d4185697cc7d, 0x0672d995f8fff640151b3d290cedaf148690a10a8c8424a7f6ec282b6e4be828, 0x099952b414884454b21200d7ffafdd5f0c9a9dcc06f2708e9fc1d8209b5c75b9,
        0x052cba2255dfd00c7c483143ba8d469448e43586a9b4cd9183fd0e843a6b9fa6, 0x0b8badee690adb8eb0bd74712b7999af82de55707251ad7716077cb93c464ddc, 0x119b1590f13307af5a1ee651020c07c749c15d60683a8050b963d0a8e4b2bdd1,
        0x03150b7cd6d5d17b2529d36be0f67b832c4acfc884ef4ee5ce15be0bfb4a8d09, 0x2cc6182c5e14546e3cf1951f173912355374efb83d80898abe69cb317c9ea565, 0x005032551e6378c450cfe129a404b3764218cadedac14e2b92d2cd73111bf0f9,
        0x233237e3289baa34bb147e972ebcb9516469c399fcc069fb88f9da2cc28276b5, 0x05c8f4f4ebd4a6e3c980d31674bfbe6323037f21b34ae5a4e80c2d4c24d60280, 0x0a7b1db13042d396ba05d818a319f25252bcf35ef3aeed91ee1f09b2590fc65b,
        0x2a73b71f9b210cf5b14296572c9d32dbf156e2b086ff47dc5df542365a404ec0, 0x1ac9b0417abcc9a1935107e9ffc91dc3ec18f2c4dbe7f22976a760bb5c50c460, 0x12c0339ae08374823fabb076707ef479269f3e4d6cb104349015ee046dc93fc0,
        0x0b7475b102a165ad7f5b18db4e1e704f52900aa3253baac68246682e56e9a28e, 0x037c2849e191ca3edb1c5e49f6e8b8917c843e379366f2ea32ab3aa88d7f8448, 0x05a6811f8556f014e92674661e217e9bd5206c5c93a07dc145fdb176a716346f,
        0x29a795e7d98028946e947b75d54e9f044076e87a7b2883b47b675ef5f38bd66e, 0x20439a0c84b322eb45a3857afc18f5826e8c7382c8a1585c507be199981fd22f, 0x2e0ba8d94d9ecf4a94ec2050c7371ff1bb50f27799a84b6d4a2a6f2a0982c887,
        0x143fd115ce08fb27ca38eb7cce822b4517822cd2109048d2e6d0ddcca17d71c8, 0x0c64cbecb1c734b857968dbbdcf813cdf8611659323dbcbfc84323623be9caf1, 0x028a305847c683f646fca925c163ff5ae74f348d62c2b670f1426cef9403da53,
        0x2e4ef510ff0b6fda5fa940ab4c4380f26a6bcb64d89427b824d6755b5db9e30c, 0x0081c95bc43384e663d79270c956ce3b8925b4f6d033b078b96384f50579400e, 0x2ed5f0c91cbd9749187e2fade687e05ee2491b349c039a0bba8a9f4023a0bb38,
        0x30509991f88da3504bbf374ed5aae2f03448a22c76234c8c990f01f33a735206, 0x1c3f20fd55409a53221b7c4d49a356b9f0a1119fb2067b41a7529094424ec6ad, 0x10b4e7f3ab5df003049514459b6e18eec46bb2213e8e131e170887b47ddcb96c,
        0x2a1982979c3ff7f43ddd543d891c2abddd80f804c077d775039aa3502e43adef, 0x1c74ee64f15e1db6feddbead56d6d55dba431ebc396c9af95cad0f1315bd5c91, 0x07533ec850ba7f98eab9303cace01b4b9e4f2e8b82708cfa9c2fe45a0ae146a0,
        0x21576b438e500449a151e4eeaf17b154285c68f42d42c1808a11abf3764c0750, 0x2f17c0559b8fe79608ad5ca193d62f10bce8384c815f0906743d6930836d4a9e, 0x2d477e3862d07708a79e8aae946170bc9775a4201318474ae665b0b1b7e2730e,
        0x162f5243967064c390e095577984f291afba2266c38f5abcd89be0f5b2747eab, 0x2b4cb233ede9ba48264ecd2c8ae50d1ad7a8596a87f29f8a7777a70092393311, 0x2c8fbcb2dd8573dc1dbaf8f4622854776db2eece6d85c4cf4254e7c35e03b07a,
        0x1d6f347725e4816af2ff453f0cd56b199e1b61e9f601e9ade5e88db870949da9, 0x204b0c397f4ebe71ebc2d8b3df5b913df9e6ac02b68d31324cd49af5c4565529, 0x0c4cb9dc3c4fd8174f1149b3c63c3c2f9ecb827cd7dc25534ff8fb75bc79c502,
        0x174ad61a1448c899a25416474f4930301e5c49475279e0639a616ddc45bc7b54, 0x1a96177bcf4d8d89f759df4ec2f3cde2eaaa28c177cc0fa13a9816d49a38d2ef, 0x066d04b24331d71cd0ef8054bc60c4ff05202c126a233c1a8242ace360b8a30a,
        0x2a4c4fc6ec0b0cf52195782871c6dd3b381cc65f72e02ad527037a62aa1bd804, 0x13ab2d136ccf37d447e9f2e14a7cedc95e727f8446f6d9d7e55afc01219fd649, 0x1121552fca26061619d24d843dc82769c1b04fcec26f55194c2e3e869acc6a9a,
        0x00ef653322b13d6c889bc81715c37d77a6cd267d595c4a8909a5546c7c97cff1, 0x0e25483e45a665208b261d8ba74051e6400c776d652595d9845aca35d8a397d3, 0x29f536dcb9dd7682245264659e15d88e395ac3d4dde92d8c46448db979eeba89,
        0x2a56ef9f2c53febadfda33575dbdbd885a124e2780bbea170e456baace0fa5be, 0x1c8361c78eb5cf5decfb7a2d17b5c409f2ae2999a46762e8ee416240a8cb9af1, 0x151aff5f38b20a0fc0473089aaf0206b83e8e68a764507bfd3d0ab4be74319c5,
        0x04c6187e41ed881dc1b239c88f7f9d43a9f52fc8c8b6cdd1e76e47615b51f100, 0x13b37bd80f4d27fb10d84331f6fb6d534b81c61ed15776449e801b7ddc9c2967, 0x01a5c536273c2d9df578bfbd32c17b7a2ce3664c2a52032c9321ceb1c4e8a8e4,
        0x2ab3561834ca73835ad05f5d7acb950b4a9a2c666b9726da832239065b7c3b02, 0x1d4d8ec291e720db200fe6d686c0d613acaf6af4e95d3bf69f7ed516a597b646, 0x041294d2cc484d228f5784fe7919fd2bb925351240a04b711514c9c80b65af1d,
        0x154ac98e01708c611c4fa715991f004898f57939d126e392042971dd90e81fc6, 0x0b339d8acca7d4f83eedd84093aef51050b3684c88f8b0b04524563bc6ea4da4, 0x0955e49e6610c94254a4f84cfbab344598f0e71eaff4a7dd81ed95b50839c82e,
        0x06746a6156eba54426b9e22206f15abca9a6f41e6f535c6f3525401ea0654626, 0x0f18f5a0ecd1423c496f3820c549c27838e5790e2bd0a196ac917c7ff32077fb, 0x04f6eeca1751f7308ac59eff5beb261e4bb563583ede7bc92a738223d6f76e13,
        0x2b56973364c4c4f5c1a3ec4da3cdce038811eb116fb3e45bc1768d26fc0b3758, 0x123769dd49d5b054dcd76b89804b1bcb8e1392b385716a5d83feb65d437f29ef, 0x2147b424fc48c80a88ee52b91169aacea989f6446471150994257b2fb01c63e9,
        0x0fdc1f58548b85701a6c5505ea332a29647e6f34ad4243c2ea54ad897cebe54d, 0x12373a8251fea004df68abcf0f7786d4bceff28c5dbbe0c3944f685cc0a0b1f2, 0x21e4f4ea5f35f85bad7ea52ff742c9e8a642756b6af44203dd8a1f35c1a90035,
        0x16243916d69d2ca3dfb4722224d4c462b57366492f45e90d8a81934f1bc3b147, 0x1efbe46dd7a578b4f66f9adbc88b4378abc21566e1a0453ca13a4159cac04ac2, 0x07ea5e8537cf5dd08886020e23a7f387d468d5525be66f853b672cc96a88969a,
        0x05a8c4f9968b8aa3b7b478a30f9a5b63650f19a75e7ce11ca9fe16c0b76c00bc, 0x20f057712cc21654fbfe59bd345e8dac3f7818c701b9c7882d9d57b72a32e83f, 0x04a12ededa9dfd689672f8c67fee31636dcd8e88d01d49019bd90b33eb33db69,
        0x27e88d8c15f37dcee44f1e5425a51decbd136ce5091a6767e49ec9544ccd101a, 0x2feed17b84285ed9b8a5c8c5e95a41f66e096619a7703223176c41ee433de4d1, 0x1ed7cc76edf45c7c404241420f729cf394e5942911312a0d6972b8bd53aff2b8,
        0x15742e99b9bfa323157ff8c586f5660eac6783476144cdcadf2874be45466b1a, 0x1aac285387f65e82c895fc6887ddf40577107454c6ec0317284f033f27d0c785, 0x25851c3c845d4790f9ddadbdb6057357832e2e7a49775f71ec75a96554d67c77,
        0x15a5821565cc2ec2ce78457db197edf353b7ebba2c5523370ddccc3d9f146a67, 0x2411d57a4813b9980efa7e31a1db5966dcf64f36044277502f15485f28c71727, 0x002e6f8d6520cd4713e335b8c0b6d2e647e9a98e12f4cd2558828b5ef6cb4c9b,
        0x2ff7bc8f4380cde997da00b616b0fcd1af8f0e91e2fe1ed7398834609e0315d2, 0x00b9831b948525595ee02724471bcd182e9521f6b7bb68f1e93be4febb0d3cbe, 0x0a2f53768b8ebf6a86913b0e57c04e011ca408648a4743a87d77adbf0c9c3512,
        0x00248156142fd0373a479f91ff239e960f599ff7e94be69b7f2a290305e1198d, 0x171d5620b87bfb1328cf8c02ab3f0c9a397196aa6a542c2350eb512a2b2bcda9, 0x170a4f55536f7dc970087c7c10d6fad760c952172dd54dd99d1045e4ec34a808,
        0x29aba33f799fe66c2ef3134aea04336ecc37e38c1cd211ba482eca17e2dbfae1, 0x1e9bc179a4fdd758fdd1bb1945088d47e70d114a03f6a0e8b5ba650369e64973, 0x1dd269799b660fad58f7f4892dfb0b5afeaad869a9c4b44f9c9e1c43bdaf8f09,
        0x22cdbc8b70117ad1401181d02e15459e7ccd426fe869c7c95d1dd2cb0f24af38, 0x0ef042e454771c533a9f57a55c503fcefd3150f52ed94a7cd5ba93b9c7dacefd, 0x11609e06ad6c8fe2f287f3036037e8851318e8b08a0359a03b304ffca62e8284,
        0x1166d9e554616dba9e753eea427c17b7fecd58c076dfe42708b08f5b783aa9af, 0x2de52989431a859593413026354413db177fbf4cd2ac0b56f855a888357ee466, 0x3006eb4ffc7a85819a6da492f3a8ac1df51aee5b17b8e89d74bf01cf5f71e9ad,
        0x2af41fbb61ba8a80fdcf6fff9e3f6f422993fe8f0a4639f962344c8225145086, 0x119e684de476155fe5a6b41a8ebc85db8718ab27889e85e781b214bace4827c3, 0x1835b786e2e8925e188bea59ae363537b51248c23828f047cff784b97b3fd800,
        0x28201a34c594dfa34d794996c6433a20d152bac2a7905c926c40e285ab32eeb6, 0x083efd7a27d1751094e80fefaf78b000864c82eb571187724a761f88c22cc4e7, 0x0b6f88a3577199526158e61ceea27be811c16df7774dd8519e079564f61fd13b,
        0x0ec868e6d15e51d9644f66e1d6471a94589511ca00d29e1014390e6ee4254f5b, 0x2af33e3f866771271ac0c9b3ed2e1142ecd3e74b939cd40d00d937ab84c98591, 0x0b520211f904b5e7d09b5d961c6ace7734568c547dd6858b364ce5e47951f178,
        0x0b2d722d0919a1aad8db58f10062a92ea0c56ac4270e822cca228620188a1d40, 0x1f790d4d7f8cf094d980ceb37c2453e957b54a9991ca38bbe0061d1ed6e562d4, 0x0171eb95dfbf7d1eaea97cd385f780150885c16235a2a6a8da92ceb01e504233,
        0x0c2d0e3b5fd57549329bf6885da66b9b790b40defd2c8650762305381b168873, 0x1162fb28689c27154e5a8228b4e72b377cbcafa589e283c35d3803054407a18d, 0x2f1459b65dee441b64ad386a91e8310f282c5a92a89e19921623ef8249711bc0,
        0x1e6ff3216b688c3d996d74367d5cd4c1bc489d46754eb712c243f70d1b53cfbb, 0x01ca8be73832b8d0681487d27d157802d741a6f36cdc2a0576881f9326478875, 0x1f7735706ffe9fc586f976d5bdf223dc680286080b10cea00b9b5de315f9650e,
        0x2522b60f4ea3307640a0c2dce041fba921ac10a3d5f096ef4745ca838285f019, 0x23f0bee001b1029d5255075ddc957f833418cad4f52b6c3f8ce16c235572575b, 0x2bc1ae8b8ddbb81fcaac2d44555ed5685d142633e9df905f66d9401093082d59,
        0x0f9406b8296564a37304507b8dba3ed162371273a07b1fc98011fcd6ad72205f, 0x2360a8eb0cc7defa67b72998de90714e17e75b174a52ee4acb126c8cd995f0a8, 0x15871a5cddead976804c803cbaef255eb4815a5e96df8b006dcbbc2767f88948,
        0x193a56766998ee9e0a8652dd2f3b1da0362f4f54f72379544f957ccdeefb420f, 0x2a394a43934f86982f9be56ff4fab1703b2e63c8ad334834e4309805e777ae0f, 0x1859954cfeb8695f3e8b635dcb345192892cd11223443ba7b4166e8876c0d142,
        0x04e1181763050e58013444dbcb99f1902b11bc25d90bbdca408d3819f4fed32b, 0x0fdb253dee83869d40c335ea64de8c5bb10eb82db08b5e8b1f5e5552bfd05f23, 0x058cbe8a9a5027bdaa4efb623adead6275f08686f1c08984a9d7c5bae9b4f1c0,
        0x1382edce9971e186497eadb1aeb1f52b23b4b83bef023ab0d15228b4cceca59a, 0x03464990f045c6ee0819ca51fd11b0be7f61b8eb99f14b77e1e6634601d9e8b5, 0x23f7bfc8720dc296fff33b41f98ff83c6fcab4605db2eb5aaa5bc137aeb70a58,
        0x0a59a158e3eec2117e6e94e7f0e9decf18c3ffd5e1531a9219636158bbaf62f2, 0x06ec54c80381c052b58bf23b312ffd3ce2c4eba065420af8f4c23ed0075fd07b, 0x118872dc832e0eb5476b56648e867ec8b09340f7a7bcb1b4962f0ff9ed1f9d01,
        0x13d69fa127d834165ad5c7cba7ad59ed52e0b0f0e42d7fea95e1906b520921b1, 0x169a177f63ea681270b1c6877a73d21bde143942fb71dc55fd8a49f19f10c77b, 0x04ef51591c6ead97ef42f287adce40d93abeb032b922f66ffb7e9a5a7450544d,
        0x256e175a1dc079390ecd7ca703fb2e3b19ec61805d4f03ced5f45ee6dd0f69ec, 0x30102d28636abd5fe5f2af412ff6004f75cc360d3205dd2da002813d3e2ceeb2, 0x10998e42dfcd3bbf1c0714bc73eb1bf40443a3fa99bef4a31fd31be182fcc792,
        0x193edd8e9fcf3d7625fa7d24b598a1d89f3362eaf4d582efecad76f879e36860, 0x18168afd34f2d915d0368ce80b7b3347d1c7a561ce611425f2664d7aa51f0b5d, 0x29383c01ebd3b6ab0c017656ebe658b6a328ec77bc33626e29e2e95b33ea6111,
        0x10646d2f2603de39a1f4ae5e7771a64a702db6e86fb76ab600bf573f9010c711, 0x0beb5e07d1b27145f575f1395a55bf132f90c25b40da7b3864d0242dcb1117fb, 0x16d685252078c133dc0d3ecad62b5c8830f95bb2e54b59abdffbf018d96fa336,
        0x0a6abd1d833938f33c74154e0404b4b40a555bbbec21ddfafd672dd62047f01a, 0x1a679f5d36eb7b5c8ea12a4c2dedc8feb12dffeec450317270a6f19b34cf1860, 0x0980fb233bd456c23974d50e0ebfde4726a423eada4e8f6ffbc7592e3f1b93d6,
        0x161b42232e61b84cbf1810af93a38fc0cece3d5628c9282003ebacb5c312c72b, 0x0ada10a90c7f0520950f7d47a60d5e6a493f09787f1564e5d09203db47de1a0b, 0x1a730d372310ba82320345a29ac4238ed3f07a8a2b4e121bb50ddb9af407f451,
        0x2c8120f268ef054f817064c369dda7ea908377feaba5c4dffbda10ef58e8c556, 0x1c7c8824f758753fa57c00789c684217b930e95313bcb73e6e7b8649a4968f70, 0x2cd9ed31f5f8691c8e39e4077a74faa0f400ad8b491eb3f7b47b27fa3fd1cf77,
        0x23ff4f9d46813457cf60d92f57618399a5e022ac321ca550854ae23918a22eea, 0x09945a5d147a4f66ceece6405dddd9d0af5a2c5103529407dff1ea58f180426d, 0x188d9c528025d4c2b67660c6b771b90f7c7da6eaa29d3f268a6dd223ec6fc630,
        0x3050e37996596b7f81f68311431d8734dba7d926d3633595e0c0d8ddf4f0f47f, 0x15af1169396830a91600ca8102c35c426ceae5461e3f95d89d829518d30afd78, 0x1da6d09885432ea9a06d9f37f873d985dae933e351466b2904284da3320d8acc,
        0x2796ea90d269af29f5f8acf33921124e4e4fad3dbe658945e546ee411ddaa9cb, 0x202d7dd1da0f6b4b0325c8b3307742f01e15612ec8e9304a7cb0319e01d32d60, 0x096d6790d05bb759156a952ba263d672a2d7f9c788f4c831a29dace4c0f8be5f,
        0x054efa1f65b0fce283808965275d877b438da23ce5b13e1963798cb1447d25a4, 0x1b162f83d917e93edb3308c29802deb9d8aa690113b2e14864ccf6e18e4165f1, 0x21e5241e12564dd6fd9f1cdd2a0de39eedfefc1466cc568ec5ceb745a0506edc,
        0x1cfb5662e8cf5ac9226a80ee17b36abecb73ab5f87e161927b4349e10e4bdf08, 0x0f21177e302a771bbae6d8d1ecb373b62c99af346220ac0129c53f666eb24100, 0x1671522374606992affb0dd7f71b12bec4236aede6290546bcef7e1f515c2320,
        0x0fa3ec5b9488259c2eb4cf24501bfad9be2ec9e42c5cc8ccd419d2a692cad870, 0x193c0e04e0bd298357cb266c1506080ed36edce85c648cc085e8c57b1ab54bba, 0x102adf8ef74735a27e9128306dcbc3c99f6f7291cd406578ce14ea2adaba68f8,
        0x0fe0af7858e49859e2a54d6f1ad945b1316aa24bfbdd23ae40a6d0cb70c3eab1, 0x216f6717bbc7dedb08536a2220843f4e2da5f1daa9ebdefde8a5ea7344798d22, 0x1da55cc900f0d21f4a3e694391918a1b3c23b2ac773c6b3ef88e2e4228325161,
    };
    for (expected_round_constants, 0..) |c, k| {
        try std.testing.expect(p.round_constants[k / 3][k % 3].eql(B.fromInt(c)));
    }

    const expected_mds: [3][3]B = .{
        .{ B.fromInt(0x109b7f411ba0e4c9b2b70caf5c36a7b194be7c11ad24378bfedb68592ba8118b), B.fromInt(0x16ed41e13bb9c0c66ae119424fddbcbc9314dc9fdbdeea55d6c64543dc4903e0), B.fromInt(0x2b90bba00fca0589f617e7dcbfe82e0df706ab640ceb247b791a93b74e36736d) },
        .{ B.fromInt(0x2969f27eed31a480b9c36c764379dbca2cc8fdd1415c3dded62940bcde0bd771), B.fromInt(0x2e2419f9ec02ec394c9871c832963dc1b89d743c8c7b964029b2311687b1fe23), B.fromInt(0x101071f0032379b697315876690f053d148d4e109f5fb065c8aacc55a0f89bfa) },
        .{ B.fromInt(0x143021ec686a3f330d5f9e654638065ce6cd79e28c5b3753326244ee65a1b1a7), B.fromInt(0x176cc029695ad02582a70eff08a6fd99d057e12e58e7d7b6b16cdfabc8ee2911), B.fromInt(0x19a3fc0a56702bf417ba7fee3802593fa644470307043f7773279cd71d25d5e0) },
    };
    for (expected_mds, 0..) |row, i| {
        for (row, 0..) |c, j| {
            try std.testing.expect(p.mds_matrix[i][j].eql(c));
        }
    }

    var a = [3]B{ B.zero(), B.fromInt(1), B.fromInt(2) };
    p.permute(&a);
    try std.testing.expect(a[0].eql(B.fromInt(0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a)));
    try std.testing.expect(a[1].eql(B.fromInt(0xfca49b798923ab0239de1c9e7a4a9a2210312b6a2f616d18b5a87f9b628ae29)));
    try std.testing.expect(a[2].eql(B.fromInt(0xe7ae82e40091e63cbd4f16a6d16310b3729d4b6e138fcf54110e2867045a30c)));

    var b = [3]B{ B.zero(), B.zero(), B.zero() };
    p.permute(&b);
    try std.testing.expect(b[0].eql(B.fromInt(0x2098f5fb9e239eab3ceac3f27b81e481dc3124d55ffed523a839ee8446b64864)));
    try std.testing.expect(b[1].eql(B.fromInt(0x13a545a13f1d91dddb87f46679dfaec0900ce24791a924bee7fa4d69a9569d85)));
    try std.testing.expect(b[2].eql(B.fromInt(0x6be479e5fcd717c6c21b32f108033bf1da6cf4d8e3e8c48042c475e0b121480)));

    var c = [3]B{ B.zero(), B.fromInt(7), B.fromInt(11) };
    p.permute(&c);
    try std.testing.expect(c[0].eql(B.fromInt(0x2e7148e460381c2100d9e589706223b5907de3231ccd752e7807a83e8a6603d8)));
    try std.testing.expect(c[1].eql(B.fromInt(0x110495217b4bca523cae7ad5fadf068fe22d593af250298292da6b4ce1bb7878)));
    try std.testing.expect(c[2].eql(B.fromInt(0x10922a455c61016669e1a5a84874428a1d3ce40c237d58fb67ef955dbb7e7ac3)));
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
