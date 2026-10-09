//! Bitcoin's Merkle root, against vectors from an independent implementation.
//!
//! The vectors were produced by a from-scratch Python computation of the
//! documented rule -- leaves already hashes, an odd level duplicates its last
//! node, each concatenation hashed twice -- and then checked against a value
//! nobody had to trust: **the genesis block's Merkle root equals its single
//! coinbase txid.** That is the case which proves the "one leaf is the root, not
//! a hash of it" rule, and it is a published constant.
//!
//! The vectors are therefore not this implementation's own output. A
//! self-generated vector would pass forever while measuring the wrong thing,
//! which is the failure `AGENTS.md` §0 records for `zig-hash`'s Blake3.

const std = @import("std");
const testing = std.testing;
const zm = @import("zig-merkle");

/// Bitcoin's hash: SHA-256, twice.
const Hash256 = struct {
    pub const HASH_LEN = 32;
    pub fn hashBytes(input: []const u8) [HASH_LEN]u8 {
        var once: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(input, &once, .{});
        var twice: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&once, &twice, .{});
        return twice;
    }
};

const Btc = zm.BitcoinMerkle(Hash256);

fn leaf(comptime n: u8) [32]u8 {
    return [_]u8{n} ** 32;
}

test "bitcoin merkle: the genesis block's root is its own txid" {
    // The published coinbase txid of block 0. With one transaction the Merkle
    // root *is* that txid -- not a hash of it -- which is what distinguishes
    // Bitcoin's rule from every "build the tree, then read the root" shape.
    const genesis_txid = [32]u8{
        0x4a, 0x5e, 0x1e, 0x4b, 0xaa, 0xb8, 0x9f, 0x3a, 0x32, 0x51, 0x8a, 0x88, 0xc3, 0x1b, 0xc8, 0x7f,
        0x61, 0x8f, 0x76, 0x67, 0x3e, 0x2c, 0xc7, 0x7a, 0xb2, 0x12, 0x7b, 0x7a, 0xfd, 0xed, 0xa3, 0x3b,
    };
    const root = try Btc.root(&[_][32]u8{genesis_txid});
    try testing.expectEqual(genesis_txid, root);
}

test "bitcoin merkle: known vectors from an independent implementation" {
    const Case = struct { leaves: []const [32]u8, root: [32]u8 };

    const two = [_][32]u8{ leaf(1), leaf(2) };
    const three = [_][32]u8{ leaf(1), leaf(2), leaf(3) };
    const five = [_][32]u8{ leaf(1), leaf(2), leaf(3), leaf(4), leaf(5) };
    const asym = [_][32]u8{
        [_]u8{'a'} ** 32,
        [_]u8{'b'} ** 32,
        [_]u8{'c'} ** 32,
        [_]u8{'d'} ** 32,
    };

    const cases = [_]Case{
        .{
            .leaves = &two,
            .root = hex("39ce20bede82c96b8908bec4a157b09c549b3db90b9b474bda9ae9b9030310b4"),
        },
        .{
            // Odd count: the third leaf is duplicated before the first pairing.
            .leaves = &three,
            .root = hex("223e023fadf1f053df26988871f893c821c28edf77d64a955e6c2a02d547bdac"),
        },
        .{
            // Odd at both levels: 5 -> 6 -> 3 -> 4 -> 2 -> 1.
            .leaves = &five,
            .root = hex("26e2870f72368b3f8baef83fa26282d95d9c194e1f33d90a12932e0f6022e5d3"),
        },
        .{
            .leaves = &asym,
            .root = hex("4f31d4749007919f66c5536c0ddfbdf265fa6b9891820fe78889739193ad7cdf"),
        },
    };

    for (cases) |c| {
        try testing.expectEqual(c.root, try Btc.root(c.leaves));
    }
}

test "bitcoin merkle: an odd level duplicates its last node rather than padding" {
    // The property the padding-based tree cannot have, asserted on its own
    // rather than left to the vectors. With three leaves, the root must equal
    // hash(hash(l0 ++ l1) ++ hash(l2 ++ l2)): the duplicated node is the LAST
    // one, hashed with itself, rather than a padding node in a fourth slot.
    const l0 = leaf(1);
    const l1 = leaf(2);
    const l2 = leaf(3);
    const root = try Btc.root(&[_][32]u8{ l0, l1, l2 });

    var pair: [64]u8 = undefined;
    @memcpy(pair[0..32], &l0);
    @memcpy(pair[32..], &l1);
    const left = Hash256.hashBytes(&pair);
    @memcpy(pair[0..32], &l2);
    @memcpy(pair[32..], &l2); // the last node hashed with ITSELF
    const right = Hash256.hashBytes(&pair);

    var top: [64]u8 = undefined;
    @memcpy(top[0..32], &left);
    @memcpy(top[32..], &right);
    try testing.expectEqual(Hash256.hashBytes(&top), root);
}

test "bitcoin merkle: an empty block is an error, not a zero root" {
    try testing.expectError(error.EmptyLeaves, Btc.root(&[_][32]u8{}));
}

test "bitcoin merkle: order matters" {
    const a = leaf(1);
    const b = leaf(2);
    try testing.expect(!std.mem.eql(u8, &(try Btc.root(&[_][32]u8{ a, b })), &(try Btc.root(&[_][32]u8{ b, a }))));
}

test "bitcoin merkle: the hex parser used for these vectors" {
    // The vectors are only worth what the parser is worth, so the parser is
    // pinned against values that can be checked by eye.
    try testing.expectEqual([_]u8{0x0a} ** 32, hex("0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a"));
    try testing.expectEqual([_]u8{ 0xde, 0xad, 0xbe, 0xef } ++ [_]u8{0} ** 28, hex("deadbeef00000000000000000000000000000000000000000000000000000000"));
}

// Parse a 64-digit hex literal into 32 bytes at comptime. Written by hand
// rather than through `std.fmt.hexToBytes`, which was rejecting these literals
// for a reason unrelated to their contents.
fn hex(comptime s: []const u8) [32]u8 {
    if (s.len != 64) @compileError("hex literal must be 64 hex digits");
    var out: [32]u8 = undefined;
    comptime var i: usize = 0;
    inline while (i < 32) : (i += 1) {
        const hi = nibble(s[i * 2]);
        const lo = nibble(s[i * 2 + 1]);
        out[i] = hi * 16 + lo;
    }
    return out;
}

fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("not a hex digit"),
    };
}
