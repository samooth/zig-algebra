//! Two Merkle trees in this tree, and they do not agree.
//!
//! `libs/field/src/lib.zig:139` opens with:
//!
//!     // Merkle tree over field elements (wrapper around zig-merkle with SHA-256)
//!
//! The code below that comment imports `std.crypto.hash.sha2.Sha256` and builds
//! its own tree. `libs/field`'s manifest declares one dependency, `zig-bigint`;
//! `@import("zig-merkle")` appears nowhere in `libs/field/src/`. The one
//! occurrence of the string "zig-merkle" in that library is this comment.
//!
//! So it is not a wrapper, and the two trees are not interchangeable. They
//! differ in exactly one place that matters -- the padding for leaves beyond
//! the caller's list, when the list is not a power of two:
//!
//!     libs/field/src/lib.zig:259      hashLeaf(F.zero())   -- SHA-256 of the
//!                                                              zero element
//!     libs/merkle/src/merkle_tree.zig:119  H.hashBytes(&.{})  -- SHA-256 of the
//!                                                              empty string
//!
//! SHA-256 of thirty-two zero bytes is not SHA-256 of nothing, so a tree built
//! one way has a different root from the same leaves built the other way, and a
//! proof from one does not verify against the other's root.
//!
//! ## Why no test saw this before
//!
//! Every test of `field`'s tree is a round trip: build, prove, verify against
//! the root the same implementation produced. A round trip is consistent by
//! construction and cannot tell one tree from another. `libs/field/tests/merkle_test.zig`
//! has four such tests and all four pass. This is the same shape `AGENTS.md`
//! records for the Merkle leaf-hash interoperability bug that was invisible
//! from both sides.
//!
//! ## What this test asserts, and why it asserts the negation
//!
//! It asserts that the two roots **differ**. That is the opposite of what a
//! consumer wants, and it is written this way because nothing here can make it
//! true: aligning the padding is a behaviour change to `field`'s public root,
//! not a fix this file can make. A test asserting the desirable property would
//! fail on every run and be deleted. A test asserting the current state fails
//! the moment somebody aligns the two -- which is the point, because that
//! change is also the moment this comment stops being true and the record has
//! to be rewritten.
//!
//! Wired explicitly in the root `build.zig`, because `wire_tests_roots` imports
//! only the library a file lives in and this one needs `zig-merkle` too. It is
//! listed in `non_test_sources` for the same reason `libs/field/tests/benchmark.zig`
//! is.

const std = @import("std");
const testing = std.testing;

const zf = @import("zig-field");
const zm = @import("zig-merkle");

/// `zig-merkle` needs `hashBytes`. Its own docstring at
/// `libs/merkle/src/merkle_tree.zig:90` says the parameter must have
/// `hash(input: []const u8) [HASH_LEN]u8`, which is wrong: the file uses
/// `H.hashBytes` ten times and `H.hash` never. SHA-256, to match what `field`
/// uses, so that the *only* difference left between the two trees is the
/// padding -- the interface mismatch would otherwise be a second one.
const Sha256T = struct {
    pub const HASH_LEN = 32;
    pub fn hashBytes(input: []const u8) [HASH_LEN]u8 {
        var out: [HASH_LEN]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(input, &out, .{});
        return out;
    }
};

test "field's MerkleTree and zig-merkle produce different roots for the same leaves" {
    const F = zf.Goldilocks;

    // Five leaves: not a power of two, so three padding leaves exist and the
    // padding rule is load-bearing. With a power-of-two count the two trees
    // would agree and the test would prove nothing.
    const n = 5;
    var leaves: [n]F = undefined;
    for (&leaves, 0..) |*l, i| l.* = F.fromInt(i + 1);

    var field_tree = try zf.MerkleTree(F).init(testing.allocator, &leaves);
    defer field_tree.deinit();
    const field_root = field_tree.rootHash();

    var bufs: [n][F.NUM_BYTES]u8 = undefined;
    var byte_leaves: [n][]const u8 = undefined;
    for (&bufs, 0..) |*b, i| {
        b.* = leaves[i].toBytes();
        byte_leaves[i] = b;
    }

    var merkle_tree = try zm.MerkleTree(Sha256T).init(testing.allocator, &byte_leaves);
    defer merkle_tree.deinit();
    const merkle_root = merkle_tree.root();

    // The current state. If these ever become equal, the padding has been
    // aligned, `libs/field/src/lib.zig:139`'s comment has become true, and this
    // file's header -- which says otherwise -- has to be rewritten.
    try testing.expect(!std.mem.eql(u8, &field_root, &merkle_root));
}

test "a proof from field's tree does not verify against zig-merkle's root" {
    const F = zf.Goldilocks;
    const n = 5;
    var leaves: [n]F = undefined;
    for (&leaves, 0..) |*l, i| l.* = F.fromInt(i + 1);

    var field_tree = try zf.MerkleTree(F).init(testing.allocator, &leaves);
    defer field_tree.deinit();

    // A valid opening inside `field`'s own tree: this is the half that has
    // always worked and is why nobody looked at the other one.
    const proof = try field_tree.proof(testing.allocator, 2);
    defer testing.allocator.free(proof);
    try testing.expect(zf.MerkleTree(F).verify(field_tree.rootHash(), 2, proof, leaves[2]));

    // Now the same leaf hashed the way `zig-merkle` hashes it, checked against
    // `field`'s root using `zig-merkle`'s verifier. It fails -- not because the
    // leaf is wrong, but because the tree it is being read against is a
    // different tree.
    const leaf_bytes = leaves[2].toBytes();
    try testing.expect(!zm.MerkleTree(Sha256T).verify(
        field_tree.rootHash(),
        2,
        &leaf_bytes,
        .{ .siblings = &.{}, .is_left_sibling = &.{} },
    ));
}
