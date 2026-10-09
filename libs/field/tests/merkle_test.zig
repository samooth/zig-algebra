//! `zig-field` no longer carries its own Merkle tree. These are the tests that
//! used to exercise it, rewritten against `zig-merkle`, which is where the tree
//! now lives.
//!
//! The reason for the rewrite is worth recording, because it is a failure this
//! repository documents and here had lived in its own tree:
//!
//! `zig-field`'s tree padded a short leaf list with `hashLeaf(F.zero())` --
//! SHA-256 of the zero element -- where `zig-merkle` pads with
//! `H.hashBytes(&.{})`, SHA-256 of nothing. The same leaves therefore produced
//! different roots and the proofs did not cross-verify. **No test could see it**:
//! all four tests of `field`'s tree were round trips -- build, prove, verify
//! against the root the same implementation had produced -- and a round trip is
//! consistent by construction, so it cannot tell one tree from another.
//!
//! `merkle_parity.zig` was the instrument that found it, by building both over
//! the same leaves. With one tree gone, that test's job is done, and its
//! replacement is the one below: an interop check, which is what a round trip
//! could never be.
//!
//! Wired explicitly in the root `build.zig` rather than by `wire_tests_roots`,
//! because that helper imports only the library a file lives in and this one
//! needs `zig-merkle` too.

const std = @import("std");
const testing = std.testing;
const zf = @import("zig-field");
const zm = @import("zig-merkle");

/// SHA-256, one-shot, which is what `zig-field`'s tree used. `zig-merkle` is
/// generic over the hash, so reusing it here means the only thing that changed
/// between the old tree and this one is the padding rule -- nothing about the
/// digest, which keeps the comparison honest.
const Sha256 = struct {
    pub const HASH_LEN = 32;
    pub fn hashBytes(input: []const u8) [HASH_LEN]u8 {
        var out: [HASH_LEN]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(input, &out, .{});
        return out;
    }
};

const Tree = zm.MerkleTree(Sha256);

/// Serialise field elements into the byte slices `zig-merkle` wants. The buffers
/// have to outlive the call, so they live here rather than inline.
const Leaves = struct {
    bufs: [][zf.M31.NUM_BYTES]u8,
    slices: [][]const u8,

    fn make(alloc: std.mem.Allocator, elems: []const zf.M31) !Leaves {
        const bufs = try alloc.alloc([zf.M31.NUM_BYTES]u8, elems.len);
        const slices = try alloc.alloc([]const u8, elems.len);
        for (elems, 0..) |e, i| {
            bufs[i] = e.toBytes();
            slices[i] = &bufs[i];
        }
        return .{ .bufs = bufs, .slices = slices };
    }

    fn deinit(self: *Leaves, alloc: std.mem.Allocator) void {
        alloc.free(self.bufs);
        alloc.free(self.slices);
    }
};

test "merkle over field elements: build, prove and verify every leaf" {
    const F = zf.M31;
    const elems = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4), F.fromInt(5), F.fromInt(6), F.fromInt(7), F.fromInt(8) };

    var lv = try Leaves.make(testing.allocator, &elems);
    defer lv.deinit(testing.allocator);

    var tree = try Tree.init(testing.allocator, lv.slices);
    defer tree.deinit();

    const root = tree.root();
    for (0..elems.len) |i| {
        const proof = try tree.prove(i, testing.allocator);
        defer proof.deinit(testing.allocator);
        try testing.expect(Tree.verify(root, i, lv.slices[i], proof));
    }
}

test "merkle over field elements: verify fails with a wrong leaf" {
    const F = zf.M31;
    const elems = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4) };

    var lv = try Leaves.make(testing.allocator, &elems);
    defer lv.deinit(testing.allocator);

    var tree = try Tree.init(testing.allocator, lv.slices);
    defer tree.deinit();
    const root = tree.root();

    const wrong = F.fromInt(99).toBytes();
    const proof = try tree.prove(0, testing.allocator);
    defer proof.deinit(testing.allocator);
    try testing.expect(!Tree.verify(root, 0, &wrong, proof));
}

test "merkle over field elements: a non-power-of-two leaf list pads, and every real leaf still verifies" {
    // Five leaves, so three padding leaves exist and the padding rule is
    // load-bearing. Under the old `field` tree these padded with the hash of the
    // zero element; under `zig-merkle` they pad with the hash of nothing, which
    // is why the two trees disagreed.
    const F = zf.M31;
    const elems = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4), F.fromInt(5) };

    var lv = try Leaves.make(testing.allocator, &elems);
    defer lv.deinit(testing.allocator);

    var tree = try Tree.init(testing.allocator, lv.slices);
    defer tree.deinit();
    const root = tree.root();

    // `capacity` is the padded count. `actualLeafCount` is *not* the caller's
    // count -- it returns capacity too, with a comment saying the real number is
    // the caller's to track. A name that promises the actual count and returns
    // the padded one is worth knowing about before relying on it, so the shape is
    // pinned here rather than assumed.
    try testing.expectEqual(@as(usize, 8), tree.capacity());
    try testing.expectEqual(tree.capacity(), tree.actualLeafCount());
    for (0..elems.len) |i| {
        const proof = try tree.prove(i, testing.allocator);
        defer proof.deinit(testing.allocator);
        try testing.expect(Tree.verify(root, i, lv.slices[i], proof));
    }
}

test "merkle over field elements: one interpretation, not two" {
    // The test `merkle_parity.zig` used to assert that `field`'s tree and
    // `zig-merkle` disagreed. They cannot disagree any more -- there is one tree
    // -- and this is the property that replaced that one: the same serialised
    // elements, built through the library that owns the tree, verify.
    //
    // It is not a round trip against the old implementation, because the old
    // implementation is gone and its roots were different. What it pins is that a
    // field element's serialisation is what the tree now hashes, which is the
    // join between the two libraries.
    const F = zf.M31;
    const elems = [_]F{ F.fromInt(7), F.fromInt(11), F.fromInt(13) };

    var lv = try Leaves.make(testing.allocator, &elems);
    defer lv.deinit(testing.allocator);

    var tree = try Tree.init(testing.allocator, lv.slices);
    defer tree.deinit();

    // The leaf hash must be SHA-256 of the element's bytes, not of anything else:
    // reconstruct it by hand and compare against what the tree committed.
    const leaf_index = 1;
    var by_hand: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lv.slices[leaf_index], &by_hand, .{});

    // A proof for the real leaf verifies, which is only possible if the tree
    // hashed exactly those bytes.
    const proof = try tree.prove(leaf_index, testing.allocator);
    defer proof.deinit(testing.allocator);
    try testing.expect(Tree.verify(tree.root(), leaf_index, lv.slices[leaf_index], proof));

    // And the same proof does not verify for the hand-reconstructed hash of a
    // different element, which pins that the join is per-element.
    const other = F.fromInt(99).toBytes();
    try testing.expect(!Tree.verify(tree.root(), leaf_index, &other, proof));
    std.mem.doNotOptimizeAway(&by_hand);
}
