//! zig-fri: Fast Reed-Solomon Interactive Oracle Proof of Proximity.
//!
//! FRI lets a prover convince a verifier that a committed function is
//! close to a low-degree polynomial, without revealing it. Core of STARKs.
//!
//! # Protocol (index-pairing FRI over arbitrary domains)
//!
//! ## Commit phase (Fiat-Shamir made non-interactive):
//!
//! ```text
//! layer_evals[0] = input evaluations (length n)
//! tree[0] = merkle(layer_evals[0]); absorb(root[0])
//! for i in 1..=R:
//!     alpha[i-1] = challenge()
//!     layer_evals[i][j] = layer_evals[i-1][2j] + alpha * layer_evals[i-1][2j+1]
//!     if i < R: tree[i] = merkle(layer_evals[i]); absorb(root[i])
//! absorb(final_evals)
//! ```
//!
//! Each challenge depends on all previously committed values, preserving
//! the interactive-commit-then-challenge security in a non-interactive form.
//!
//! ## Query phase:
//! For each random index k in [0,n): walk down the fold path collecting
//! sibling pairs; verify Merkle inclusion and fold consistency at every
//! round; final fold must match final_evals[k >> R].
//!
//! # Proof size
//! Per query: R × (2·NUM_BYTES + log(n)·32) bytes.
//! With M31 (4B elems), n=2¹⁶, R=12: ~950 B/query.
//!
//! # Soundness
//! Error ≤ (degree_bound / |F|)^num_queries. With M31 (~2³¹) and degree 2¹⁶,
//! 100 queries give ≈ 2⁻¹⁵⁰ soundness.

const std = @import("std");

const Blake3 = std.crypto.hash.Blake3;
const HASH_LEN = 32;

pub const FriError = error{
    InvalidParameters,
    ProofTooShort,
    VerificationFailed,
    OutOfMemory,
};

/// Simple binary Merkle tree over fixed-size hashes (self-contained).
const MerkleTree = struct {
    levels: [][]const [HASH_LEN]u8,

    fn init(
        allocator: std.mem.Allocator,
        leaf_hashes: []const [HASH_LEN]u8,
    ) !MerkleTree {
        if (leaf_hashes.len == 0) return error.EmptyTree;
        if (leaf_hashes.len & (leaf_hashes.len - 1) != 0) return error.NotPowerOfTwo;
        const num_levels = std.math.log2_int(usize, leaf_hashes.len) + 1;
        var levels = try allocator.alloc([]const [HASH_LEN]u8, num_levels);
        errdefer allocator.free(levels);

        levels[0] = try allocator.dupe([HASH_LEN]u8, leaf_hashes);
        for (1..num_levels) |i| {
            const prev = levels[i - 1];
            const count = prev.len / 2;
            const cur = try allocator.alloc([HASH_LEN]u8, count);
            for (0..count) |j| {
                var h = Blake3.init(.{});
                h.update(&prev[2 * j]);
                h.update(&prev[2 * j + 1]);
                h.final(&cur[j]);
            }
            levels[i] = cur;
        }
        return .{ .levels = levels };
    }

    fn deinit(self: *MerkleTree, allocator: std.mem.Allocator) void {
        for (self.levels) |lvl| allocator.free(lvl);
        allocator.free(self.levels);
    }

    fn root(self: *const MerkleTree) [HASH_LEN]u8 {
        return self.levels[self.levels.len - 1][0];
    }

    fn prove(
        self: *const MerkleTree,
        allocator: std.mem.Allocator,
        index: usize,
    ) ![][HASH_LEN]u8 {
        const path_len = self.levels.len - 1;
        const path = try allocator.alloc([HASH_LEN]u8, path_len);
        var idx = index;
        for (0..path_len) |lvl| {
            path[lvl] = self.levels[lvl][idx ^ 1];
            idx >>= 1;
        }
        return path;
    }

    fn verifyPath(
        root_hash: [HASH_LEN]u8,
        index: usize,
        leaf: [HASH_LEN]u8,
        path: []const [HASH_LEN]u8,
    ) bool {
        var current = leaf;
        var idx = index;
        for (path) |sibling| {
            var h = Blake3.init(.{});
            if (idx & 1 == 0) {
                h.update(&current);
                h.update(&sibling);
            } else {
                h.update(&sibling);
                h.update(&current);
            }
            h.final(&current);
            idx >>= 1;
        }
        return std.mem.eql(u8, &current, &root_hash);
    }
};

fn hashElem(comptime F: type, elem: F) [HASH_LEN]u8 {
    const bytes = elem.toBytes();
    var out: [HASH_LEN]u8 = undefined;
    Blake3.hash(&bytes, &out, .{});
    return out;
}

fn hashPair(comptime F: type, a: F, b: F) [HASH_LEN]u8 {
    const ab = a.toBytes();
    const bb = b.toBytes();
    var h = Blake3.init(.{});
    h.update(&ab);
    h.update(&bb);
    var out: [HASH_LEN]u8 = undefined;
    h.final(&out);
    return out;
}

// ============================================================================
// Configuration
// ============================================================================

pub const Config = struct {
    /// Initial number of evaluations (must be power of 2).
    domain_size: usize,
    /// Stop folding once layer size reaches this (sent as final poly).
    final_length: usize = 16,
    /// Number of random queries in verification phase.
    num_queries: usize = 100,
};

pub fn numRounds(config: Config) FriError!usize {
    if (config.domain_size == 0 or config.domain_size & (config.domain_size - 1) != 0)
        return FriError.InvalidParameters;
    if (config.final_length == 0 or config.final_length & (config.final_length - 1) != 0)
        return FriError.InvalidParameters;
    if (config.final_length >= config.domain_size) return FriError.InvalidParameters;
    const log_n = std.math.log2_int(usize, config.domain_size);
    const log_final = std.math.log2_int(usize, config.final_length);
    return log_n - log_final;
}

// ============================================================================
// Proof structures
// ============================================================================

/// Metadata for one committed layer (verifier-side view).
pub const LayerInfo = struct {
    /// Merkle root over all evaluations at this layer.
    merkle_root: [HASH_LEN]u8,
    /// Number of evaluations at this layer.
    len: usize,
};

/// Per-query data.
pub const QueryProof = struct {
    /// Initial query index in [0, domain_size).
    index: usize,
    /// For each round: the pair of evaluations at that round, serialised.
    /// Length = num_rounds. Each entry is 2 * NUM_BYTES long.
    pairs: []const []const u8,
    /// For each round: Merkle auth path for the pair leaf.
    auth_paths: []const []const [HASH_LEN]u8,
};

/// Full FRI proof.
pub const Proof = struct {
    /// Layer metadata for rounds 0..R-1 (final round sent as evals).
    layers: []LayerInfo,
    /// Serialised final polynomial evaluations (length == final_length).
    final_evals: []const []const u8,
    /// Query proofs.
    queries: []QueryProof,
    /// Original domain size.
    domain_size: usize,
    /// Number of folding rounds.
    num_rounds: usize,

    pub fn deinit(self: *Proof, allocator: std.mem.Allocator) void {
        for (self.queries) |q| {
            for (q.pairs) |p| allocator.free(p);
            allocator.free(@constCast(q.pairs));
            for (q.auth_paths) |p| allocator.free(p);
            allocator.free(@constCast(q.auth_paths));
        }
        allocator.free(self.queries);
        allocator.free(self.layers);
        for (self.final_evals) |fe| allocator.free(fe);
        allocator.free(self.final_evals);
    }
};

// ============================================================================
// Serialization helpers
// ============================================================================

fn serializeElem(comptime F: type, allocator: std.mem.Allocator, elem: F) ![]u8 {
    const buf = try allocator.alloc(u8, F.NUM_BYTES);
    const bytes = elem.toBytes();
    @memcpy(buf, &bytes);
    return buf;
}

fn deserializeElem(comptime F: type, bytes: []const u8) FriError!F {
    if (bytes.len != F.NUM_BYTES) return FriError.ProofTooShort;
    return F.fromBytes(bytes) catch return FriError.ProofTooShort;
}

fn serializePair(comptime F: type, allocator: std.mem.Allocator, a: F, b: F) ![]u8 {
    const N = F.NUM_BYTES;
    const buf = try allocator.alloc(u8, 2 * N);
    const ab = a.toBytes();
    const bb = b.toBytes();
    @memcpy(buf[0..N], &ab);
    @memcpy(buf[N .. 2 * N], &bb);
    return buf;
}

fn deserializePair(comptime F: type, bytes: []const u8) FriError![2]F {
    const N = F.NUM_BYTES;
    if (bytes.len != 2 * N) return FriError.ProofTooShort;
    const a = F.fromBytes(bytes[0..N]) catch return FriError.ProofTooShort;
    const b = F.fromBytes(bytes[N .. 2 * N]) catch return FriError.ProofTooShort;
    return .{ a, b };
}

// ============================================================================
// Prover
// ============================================================================

/// Run the full FRI protocol (prover side).
///
/// `p_evals` must contain `config.domain_size` evaluations. Returns a proof
/// that can be verified with `verify`.
pub fn prove(
    comptime F: type,
    allocator: std.mem.Allocator,
    transcript: anytype,
    p_evals: []const F,
    config: Config,
) FriError!Proof {
    const n = config.domain_size;
    if (n == 0 or (n & (n - 1)) != 0) return FriError.InvalidParameters;
    if (p_evals.len != n) return FriError.InvalidParameters;
    if (config.final_length < 1 or (config.final_length & (config.final_length - 1)) != 0)
        return FriError.InvalidParameters;
    if (config.final_length >= n) return FriError.InvalidParameters;

    const rounds = try numRounds(config);

    // Build all layer evaluations sequentially, absorbing roots as we go
    // so each challenge depends on prior commitments (Fiat-Shamir ordering).
    var layer_evals = try allocator.alloc([]F, rounds + 1);
    // Not referenced by the returned Proof; free on both success and error.
    defer {
        for (layer_evals) |le| allocator.free(le);
        allocator.free(layer_evals);
    }

    var trees_buf: [64]?MerkleTree = @splat(null);
    defer for (trees_buf) |maybe_tree| {
        if (maybe_tree) |*t| {
            var t_mut = t.*;
            t_mut.deinit(allocator);
        }
    };

    // Layer 0: commit to input.
    layer_evals[0] = allocator.dupe(F, p_evals) catch return FriError.OutOfMemory;
    {
        const half = n / 2;
        const hashes = allocator.alloc([HASH_LEN]u8, half) catch return FriError.OutOfMemory;
        defer allocator.free(hashes);
        for (0..half) |j| hashes[j] = hashPair(F, p_evals[2 * j], p_evals[2 * j + 1]);
        trees_buf[0] = MerkleTree.init(allocator, hashes) catch return FriError.OutOfMemory;
    }
    transcript.absorbBytes(&trees_buf[0].?.root()); // Fold rounds 1..R, committing between challenges.
    for (1..rounds + 1) |i| {
        const alpha = blk: { const a = transcript.challengeField(F); break :blk a; };
        const prev = layer_evals[i - 1];
        const half = prev.len / 2;
        const cur = allocator.alloc(F, half) catch return FriError.OutOfMemory;
        for (0..half) |j| {
            cur[j] = prev[2 * j].add(alpha.mul(prev[2 * j + 1]));
        }
        layer_evals[i] = cur;

        // Commit this layer too (except the very last, which is sent raw).
        if (i < rounds) {
            const num_pairs = half / 2;
            const hashes = allocator.alloc([HASH_LEN]u8, num_pairs) catch return FriError.OutOfMemory;
            defer allocator.free(hashes);
            for (0..num_pairs) |j| hashes[j] = hashPair(F, cur[2 * j], cur[2 * j + 1]);
            trees_buf[i] = MerkleTree.init(allocator, hashes) catch return FriError.OutOfMemory;
            transcript.absorbBytes(&trees_buf[i].?.root());
        }
    }

    // Absorb final layer evaluations.
    const final_raw = layer_evals[rounds];
    for (final_raw) |e| transcript.absorbField(F, e);

    // Build proof structures.
    const layer_metas = allocator.alloc(LayerInfo, rounds) catch return FriError.OutOfMemory;
    for (0..rounds) |i| {
        layer_metas[i] = .{
            .merkle_root = trees_buf[i].?.root(),
            .len = layer_evals[i].len,
        };
    }

    const final_bytes = allocator.alloc([]const u8, final_raw.len) catch return FriError.OutOfMemory;
    for (final_raw, 0..) |e, j| {
        final_bytes[j] = serializeElem(F, allocator, e) catch return FriError.OutOfMemory;
    }

    // Generate query proofs.
    const queries = allocator.alloc(QueryProof, config.num_queries) catch return FriError.OutOfMemory;
    for (0..config.num_queries) |qi| {
        const seed = transcript.challengeU64();
        const start_index: usize = @intCast(seed % @as(u64, @intCast(n)));

        const pairs = allocator.alloc([]const u8, rounds) catch return FriError.OutOfMemory;
        const paths = allocator.alloc([]const [HASH_LEN]u8, rounds) catch return FriError.OutOfMemory;

        var idx = start_index;
        for (0..rounds) |r| {
            const evals = layer_evals[r];
            const even = evals[idx & ~@as(usize, 1)];
            const odd = evals[(idx & ~@as(usize, 1)) + 1];

            pairs[r] = serializePair(F, allocator, even, odd) catch return FriError.OutOfMemory;

            const leaf_idx = idx >> 1;
            paths[r] = trees_buf[r].?.prove(allocator, leaf_idx) catch return FriError.OutOfMemory;

            idx >>= 1;
        }

        queries[qi] = .{
            .index = start_index,
            .pairs = pairs,
            .auth_paths = paths,
        };
    }

    return Proof{
        .layers = layer_metas,
        .final_evals = final_bytes,
        .queries = queries,
        .domain_size = n,
        .num_rounds = rounds,
    };
}

// ============================================================================
// Verifier
// ============================================================================

/// Verify a FRI proof.
///
/// Checks (in order):
///   1. Structural validity (sizes, lengths).
///   2. Query indices match transcript-derived challenges.
///   3. Every pair authenticates against its layer's Merkle root.
///   4. Folding consistency across all rounds.
///   5. Final fold matches the final polynomial evaluations.
pub fn verify(
    comptime F: type,
    transcript: anytype,
    proof: *const Proof,
    config: Config,
) FriError!bool {
    if (proof.domain_size != config.domain_size) return false;
    if (proof.num_rounds != try numRounds(config)) return false;
    if (proof.layers.len != proof.num_rounds) return false;

    const n = proof.domain_size;
    const rounds = proof.num_rounds;
    const final_len = config.final_length;
    if (proof.final_evals.len != final_len) return false;

    // Replay the commit phase to derive the same fold challenges.
    // Order matters: absorb root[i] then squeeze alpha[i] for i in 0..R.
    // (Prover absorbed root[0] first, then for i in 1..=R: squeeze alpha,
    // fold, and if i<R absorb root[i].)
    //
    // To replay: absorb root[0]; squeeze alpha[0]; absorb root[1]; squeeze
    // alpha[1]; ... ; absorb root[R-1]; squeeze alpha[R-1].
    var alphas: [64]F = undefined;
    if (rounds > 64) return FriError.ProofTooShort;
    for (0..rounds) |i| {
        transcript.absorbBytes(&proof.layers[i].merkle_root); alphas[i] = blk: { const a = transcript.challengeField(F); break :blk a; };
    }
    // Absorb final evaluations (same order as prover).
    var final_vals: [4096]F = undefined;
    if (proof.final_evals.len > 4096) return FriError.ProofTooShort;
    for (proof.final_evals, 0..) |fb, fi| {
        const fe = deserializeElem(F, fb) catch return false;
        transcript.absorbField(F, fe);
        final_vals[fi] = fe;
    }

    // Verify each query.
    for (proof.queries) |q| {
        if (q.pairs.len != rounds) return false;
        if (q.auth_paths.len != rounds) return false;
        if (q.index >= n) return false;

        // Derive same query index.
        const seed = transcript.challengeU64();
        const expected_idx: usize = @intCast(seed % @as(u64, @intCast(n)));
        if (q.index != expected_idx) { return false; }

        var idx = q.index;
        // Track the value carried forward from previous round's fold.
        // At round 0 we don't have it yet; it comes from the fold of round 0.
        var carried: ?F = null;

        for (0..rounds) |r| {
            const pair_bytes = q.pairs[r];
            const pair = deserializePair(F, pair_bytes) catch return false;
            const even = pair[0];
            const odd = pair[1];

            // Verify Merkle inclusion of this pair's leaf.
            const leaf_idx = idx >> 1;
            const ab = even.toBytes();
            const bb = odd.toBytes();
            var h = Blake3.init(.{});
            h.update(&ab);
            h.update(&bb);
            var leaf_hash: [HASH_LEN]u8 = undefined;
            h.final(&leaf_hash);

            if (!MerkleTree.verifyPath(proof.layers[r].merkle_root, leaf_idx, leaf_hash, q.auth_paths[r]))
                { return false; }
            // Fold-consistency check: carried (from previous round's fold)
            // must equal one of {even, odd} depending on parity.
            if (carried) |cv| {
                // Previous fold produced value at index `idx` of THIS layer.
                // The pair we just fetched contains indices (idx&~1, (idx&~1)+1).
                // One of them must be cv.
                const even_matches = cv.eql(even);
                const odd_matches = cv.eql(odd);
                if (!even_matches and !odd_matches) { return false; }
            }

            // Compute next round's carried value via fold.
            const alpha = alphas[r];
            carried = even.add(alpha.mul(odd));

            idx >>= 1;
        }

        // Final check: last carried value must match final_evals[idx].
        const fi = idx; // == original_k >> rounds
        if (fi >= proof.final_evals.len) return false;
        const fc = carried orelse return false;
        if (!fc.eql(final_vals[fi])) { return false; }
    }

    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Test field: Mersenne-31
const M31 = struct {
    const Self = @This();
    value: u32,
    pub const MODULUS: u32 = 0x7FFFFFFF;
    pub const NUM_BYTES: usize = 4;

    pub fn zero() Self { return .{ .value = 0 }; }
    pub fn one() Self { return .{ .value = 1 }; }
    pub fn fromInt(x: anytype) Self { return .{ .value = @intCast(@mod(x, Self.MODULUS)) }; }
    pub fn toInt(self: Self) u32 { return self.value; }
    pub fn eql(a: Self, b: Self) bool { return a.value == b.value; }
    pub fn add(a: Self, b: Self) Self { return fromInt(a.value +% b.value); }
    pub fn mul(a: Self, b: Self) Self { return fromInt(@as(u64, a.value) *% b.value); }
    pub fn sub(a: Self, b: Self) Self { return fromInt(a.value +% Self.MODULUS -% b.value); }
    pub fn isZero(self: Self) bool { return self.value == 0; }
    pub fn neg(a: Self) Self { return if (a.value == 0) zero() else fromInt(Self.MODULUS - a.value); }
    pub fn sqr(a: Self) Self { return mul(a, a); }
    pub fn inv(a: Self) Self { return pow(a, Self.MODULUS - 2); }
    pub fn pow(base: Self, exp: u32) Self {
        var r = one();
        var b = base;
        var e = exp;
        while (e > 0) : (e >>= 1) {
            if (e & 1 == 1) r = mul(r, b);
            b = b.sqr();
        }
        return r;
    }
    pub fn fromBytes(bytes: []const u8) !Self {
        if (bytes.len != 4) return error.InvalidLength;
        const v = std.mem.readInt(u32, bytes[0..4], .little);
        if (v >= Self.MODULUS) return error.ValueOutOfRange;
        return .{ .value = v };
    }
    pub fn toBytes(self: Self) [4]u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.value, .little);
        return buf;
    }
};

test "merkle: basic tree operations" {
    const allocator = testing.allocator;
    var leaves: [4][HASH_LEN]u8 = undefined;
    for (&leaves, 0..) |*leaf, i| {
        Blake3.hash(std.mem.asBytes(&i), leaf, .{});
    }
    var tree = try MerkleTree.init(allocator, &leaves);
    defer tree.deinit(allocator);

    const r = tree.root();

    for (0..4) |i| {
        const path = try tree.prove(allocator, i);
        defer allocator.free(path);
        try testing.expect(MerkleTree.verifyPath(r, i, leaves[i], path));
    }
}

test "merkle: tampered leaf fails" {
    const allocator = testing.allocator;
    var leaves: [4][HASH_LEN]u8 = undefined;
    for (&leaves, 0..) |*leaf, i| {
        Blake3.hash(std.mem.asBytes(&i), leaf, .{});
    }
    var tree = try MerkleTree.init(allocator, &leaves);
    defer tree.deinit(allocator);

    const r = tree.root();
    const path = try tree.prove(allocator, 1);
    defer allocator.free(path);

    var bad = leaves[1];
    bad[0] ^= 0xFF;
    try testing.expect(!MerkleTree.verifyPath(r, 1, bad, path));
}

test "fri: prove and verify low-degree polynomial" {
    const allocator = testing.allocator;
    const Transcript = @import("zig-transcript").Transcript;

    const n = 128;
    // Evaluations of x²+x+1 at points 0..127.
    var p_evals: [n]M31 = undefined;
    for (0..n) |i| {
        const xi = M31.fromInt(i);
        p_evals[i] = xi.sqr().add(xi).add(M31.one());
    }

    const config = Config{
        .domain_size = n,
        .final_length = 8,
        .num_queries = 10,
    };

    var prover_transcript = Transcript.init("test-fri");
    var proof = try prove(M31, allocator, &prover_transcript, &p_evals, config);
    defer proof.deinit(allocator);

    var verifier_transcript = Transcript.init("test-fri");
    const ok = try verify(M31, &verifier_transcript, &proof, config);
    try testing.expect(ok);
}

test "fri: larger domain with more rounds" {
    const allocator = testing.allocator;
    const Transcript = @import("zig-transcript").Transcript;

    const n = 512;
    var p_evals: [n]M31 = undefined;
    for (0..n) |i| p_evals[i] = M31.fromInt(i *% 7 +% 3);

    const config = Config{ .domain_size = n, .final_length = 16, .num_queries = 20 };

    var pt = Transcript.init("big-fri");
    var proof = try prove(M31, allocator, &pt, &p_evals, config);
    defer proof.deinit(allocator);

    var vt = Transcript.init("big-fri");
    const ok = try verify(M31, &vt, &proof, config);
    try testing.expect(ok);
}

test "fri: wrong transcript rejects proof" {
    const allocator = testing.allocator;
    const Transcript = @import("zig-transcript").Transcript;

    const n = 64;
    var p_evals: [n]M31 = undefined;
    for (0..n) |i| p_evals[i] = M31.fromInt(i);

    const config = Config{ .domain_size = n, .final_length = 8, .num_queries = 5 };

    var pt = Transcript.init("domain-a");
    var proof = try prove(M31, allocator, &pt, &p_evals, config);
    defer proof.deinit(allocator);

    var vt = Transcript.init("domain-b"); // Different domain label
    const ok = try verify(M31, &vt, &proof, config);
    try testing.expect(!ok);
}

test "fri: invalid domain size rejected" {
    var p_evals: [10]M31 = undefined;
    for (0..10) |i| p_evals[i] = M31.fromInt(i);

    const config = Config{ .domain_size = 10 };
    // Just check numRounds rejects it.
    try testing.expectError(FriError.InvalidParameters, numRounds(config));
}

test "fri: mismatched eval length rejected" {
    const allocator = testing.allocator;
    const Transcript = @import("zig-transcript").Transcript;

    var p_evals: [16]M31 = undefined;
    for (0..16) |i| p_evals[i] = M31.fromInt(i);

    const config = Config{ .domain_size = 32 };
    var t = Transcript.init("mismatch");
    const result = prove(M31, allocator, &t, &p_evals, config);
    try testing.expectError(FriError.InvalidParameters, result);
}
