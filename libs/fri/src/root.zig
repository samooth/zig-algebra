//! zig-fri v2: Fast Reed-Solomon Interactive Oracle Proof of Proximity.
//!
//! FRI lets a prover convince a verifier that a committed function is
//! close to a low-degree polynomial, without revealing it. Core of STARKs.
//!
//! # Protocol (canonical FRI over a 2-adic multiplicative subgroup)
//!
//! The committed evaluations live on the order-`n = 2^k` subgroup
//! `H_k = <g^(2^(adicity-k))>` of the base field (natural exponent order:
//! `domain[i] = g_k^i`). Antipodal pairs `x / -x` sit at positions
//! `(j, j + n/2)`, and squaring maps `H_k -> H_{k-1}` two-to-one — exactly
//! the FRI fold structure. Requires a field with `two_adicity >= k`
//! (Goldilocks: 32; M31 has two-adicity 1 and cannot be used here).
//!
//! ## Commit phase (Fiat-Shamir made non-interactive)
//!
//! ```text
//! layer[0] = input evaluations (length n, natural domain order)
//! for i in 0..R:
//!     root[i] = merkle( leaves[j] = H(f_i[j], f_i[j + n_i/2]) )
//!     absorb(root[i]); alpha[i] = challenge()
//!     f_{i+1}[j] = (f_i[j] + f_i[j+n_i/2])/2
//!               + alpha[i] * (f_i[j] - f_i[j+n_i/2]) / (2 * x_j)
//! residual = f_R interpolated to COEFFICIENTS, truncated to the
//!            degree bound d (the degree anchor)
//! absorb(residual coefficients...)
//! ```
//!
//! The residual is the degree anchor: the final domain has size
//! `2^log_final > d` (rate < 1), so a degree-`>= d` imposter disagrees
//! with the truncated residual's evaluations almost everywhere.
//!
//! ## Query phase
//!
//! For each of `num_queries` random starting positions: walk down the
//! antipodal-pair chain, verifying Merkle inclusion and — with exact
//! positional equality, no even/odd slack — that each fold lands on the
//! next layer's value, ending at the residual's evaluation on the final
//! domain.
//!
//! # Soundness
//!
//! Textbook FRI: each query tests the codeword distance of the committed
//! layers; the residual pins the degree. With blowup `B = 2^log_final / d`
//! and `q` queries the rejection of far-from-low-degree data is
//! overwhelming (per-query pass ≈ 1/B for maximally-far data). See
//! SECURITY.md for the v1 failure this v2 replaces.
//!
//! # Requirements on `F`
//!
//! Any `zig-field` `Field(modulus)` with `two_adicity >= log_domain`:
//! exposes `add/sub/mul/div/inv/pow`, `primitiveRootOfUnity`,
//! `fromInt`, `random`, `toBytes`. Goldilocks is the reference field.

const std = @import("std");

const zfield = @import("zig-field");
const Blake3 = std.crypto.hash.Blake3;
const HASH_LEN = 32;

pub const FriError = error{
    InvalidParameters,
    InvalidProof,
    OutOfMemory,
};

/// Blake3 adapter for zig-merkle's `hashBytes` interface.
const Blake3Hash = struct {
    pub fn hashBytes(input: []const u8) [HASH_LEN]u8 {
        var out: [HASH_LEN]u8 = undefined;
        Blake3.hash(input, &out, .{});
        return out;
    }
};

/// Binary Merkle tree over fixed-size hashes (shared zig-merkle impl).
const MerkleTree = @import("zig-merkle").MerkleTree(Blake3Hash);

// ============================================================================
// Domain
// ============================================================================

/// The order-2^log_n subgroup of F*, in natural exponent order.
///
/// `at(i) = g_k^i` where `g_k = omega^(2^(two_adicity - log_n))` and
/// `omega` is F's primitive `2^two_adicity`-th root of unity. Squaring
/// maps this domain onto `Domain(F)` of size n/2 two-to-one:
/// `x_j^2 = g_{k-1}^j`, so the fold child of the antipodal pair
/// `(j, j + n/2)` lands at position `j` of the half-size domain — the
/// natural layout is preserved at every layer.
pub fn Domain(comptime F: type) type {
    return struct {
        log_n: u6,
        step_gen: F,

        const Self = @This();

        pub fn init(comptime Field: type, log_n: u6) Self {
            std.debug.assert(log_n <= Field.two_adicity);
            const omega = Field.primitiveRootOfUnity(Field.two_adicity);
            const shift: u6 = @intCast(Field.two_adicity - log_n);
            return .{ .log_n = log_n, .step_gen = omega.pow(@as(u64, 1) << shift) };
        }

        pub fn size(self: Self) usize {
            return @as(usize, 1) << self.log_n;
        }

        /// The i-th domain element (natural order): g_k^i.
        pub fn at(self: Self, i: usize) F {
            return self.step_gen.pow(@as(u64, @intCast(i)));
        }

        /// Fill `buf` (len == size) with the domain elements.
        pub fn fill(self: Self, buf: []F) void {
            std.debug.assert(buf.len == self.size());
            var x = F.one();
            const g = self.step_gen;
            for (buf) |*slot| {
                slot.* = x;
                x = x.mul(g);
            }
        }
    };
}

// ============================================================================
// Configuration
// ============================================================================

pub const Config = struct {
    /// log2 of the initial domain size (order of H_k). The committed
    /// evaluations are the polynomial on the full domain.
    log_domain: u6,
    /// log2 of the degree bound of the committed polynomial.
    log_initial_degree: u6,
    /// log2 of the LAST FRI layer's domain size. The residual polynomial
    /// is evaluated on this domain.
    log_final: u6,
    /// log2 of the residual degree bound (d). The residual is sent as
    /// exactly `2^log_residual_degree` coefficients; the final domain
    /// must be strictly larger (rate < 1) so queries catch cheaters.
    log_residual_degree: u6,
    /// Number of random positions checked.
    num_queries: usize,

    /// Derived: number of folding rounds.
    pub fn rounds(self: Config) FriError!usize {
        if (self.log_domain == 0 or self.log_domain > 63) return FriError.InvalidParameters;
        if (self.log_final >= self.log_domain) return FriError.InvalidParameters;
        if (self.log_residual_degree >= self.log_final) return FriError.InvalidParameters;
        if (self.log_final > 12 or self.log_residual_degree > 12) return FriError.InvalidParameters;
        if (self.num_queries == 0) return FriError.InvalidParameters;
        return self.log_domain - self.log_final;
    }

    pub fn validate(self: Config) FriError!void {
        const round_count = try self.rounds();
        if (self.log_initial_degree > self.log_domain) return FriError.InvalidParameters;
        if (self.log_initial_degree < round_count) return FriError.InvalidParameters;
        if (self.log_initial_degree - round_count != self.log_residual_degree) return FriError.InvalidParameters;
    }
};

// ============================================================================
// Proof structures
// ============================================================================

/// One committed layer (verifier view).
pub const LayerInfo = struct {
    merkle_root: [HASH_LEN]u8,
    log_size: u6,
};

/// Per-query opening: values at one antipodal pair per layer + Merkle
/// paths for those pair-leaves.
pub const QueryProof = struct {
    /// Initial pair index (leaf index in layer 0): the pair covers
    /// positions (j, j + n/2).
    pair_index: usize,
    /// Per layer r: the antipodal pair (f(x), f(-x)) at the queried spot.
    values: [][]u8, // serialized 2*NUM_BYTES per round; parse per F
    paths: [][]const [HASH_LEN]u8,
};

/// Full FRI proof.
pub const Proof = struct {
    layers: []LayerInfo,
    /// The residual polynomial, coefficients, degree < 2^log_residual_degree.
    residual: []const []const u8,
    queries: []QueryProof,
    log_domain: u6,
    log_final: u6,
    log_residual_degree: u6,

    pub fn deinit(self: *Proof, allocator: std.mem.Allocator) void {
        for (self.queries) |q| {
            for (q.values) |v| allocator.free(@constCast(v));
            allocator.free(@constCast(q.values));
            for (q.paths) |p| allocator.free(@constCast(p));
            allocator.free(@constCast(q.paths));
        }
        allocator.free(self.queries);
        allocator.free(self.layers);
        for (self.residual) |c| allocator.free(@constCast(c));
        allocator.free(@constCast(self.residual));
    }
};

// ============================================================================
// Serialization helpers
// ============================================================================

fn serializeElem(comptime F: type, allocator: std.mem.Allocator, elem: F) FriError![]u8 {
    const buf = allocator.alloc(u8, F.NUM_BYTES) catch return FriError.OutOfMemory;
    const bytes = elem.toBytes();
    @memcpy(buf, &bytes);
    return buf;
}

fn serializePair(comptime F: type, allocator: std.mem.Allocator, a: F, b: F) FriError![]u8 {
    const N = F.NUM_BYTES;
    const buf = allocator.alloc(u8, 2 * N) catch return FriError.OutOfMemory;
    const ab = a.toBytes();
    const bb = b.toBytes();
    @memcpy(buf[0..N], &ab);
    @memcpy(buf[N .. 2 * N], &bb);
    return buf;
}

fn deserializeElem(comptime F: type, bytes: []const u8) FriError!F {
    if (bytes.len != F.NUM_BYTES) return FriError.InvalidProof;
    return F.fromBytes(bytes) catch return FriError.InvalidProof;
}

fn deserializePair(comptime F: type, bytes: []const u8) FriError![2]F {
    const N = F.NUM_BYTES;
    if (bytes.len != 2 * N) return FriError.InvalidProof;
    const a = F.fromBytes(bytes[0..N]) catch return FriError.InvalidProof;
    const b = F.fromBytes(bytes[N .. 2 * N]) catch return FriError.InvalidProof;
    return .{ a, b };
}

/// Two-to-one leaf hashing for the commitment layer: leaf_j commits to
/// the antipodal pair (f(x), f(-x)) at positions (j, j + n/2).
fn hashPair(comptime F: type, x: F, neg_x: F) [HASH_LEN]u8 {
    const ab = x.toBytes();
    const bb = neg_x.toBytes();
    var h = Blake3.init(.{});
    h.update(&ab);
    h.update(&bb);
    var out: [HASH_LEN]u8 = undefined;
    h.final(&out);
    return out;
}

// ============================================================================
// Prover
// ============================================================================

/// Prove that `evals` (length 2^log_domain; the polynomial evaluated on
/// the natural-order subgroup domain) has degree < 2^log_residual_degree.
///
/// For an honest prover the residual's high coefficients are exactly
/// zero (each fold halves the degree of a true polynomial), so
/// truncating the coefficient vector is lossless; for a cheater the
/// truncation drops real energy and the re-evaluated residual disagrees
/// with the last committed layer almost everywhere — queries catch it.
pub fn prove(
    comptime F: type,
    allocator: std.mem.Allocator,
    transcript: anytype,
    evals: []const F,
    config: Config,
) FriError!Proof {
    try config.validate();
    const rounds = try config.rounds();
    const n: usize = @as(usize, 1) << config.log_domain;
    if (evals.len != n) return FriError.InvalidParameters;
    if (config.log_domain > F.two_adicity) return FriError.InvalidParameters;
    const residual_len: usize = @as(usize, 1) << config.log_residual_degree;

    const half_inv = F.fromInt(1).div(F.fromInt(2));

    // Layer buffers 0..R (the last becomes the residual basis).
    var layer_evals = allocator.alloc([]F, rounds + 1) catch return FriError.OutOfMemory;
    const empty_evals: []F = &[_]F{};
    for (layer_evals) |*le| le.* = empty_evals;
    defer {
        for (layer_evals) |le| {
            if (le.len != 0) allocator.free(le);
        }
        allocator.free(layer_evals);
    }
    layer_evals[0] = allocator.dupe(F, evals) catch return FriError.OutOfMemory;

    var roots = allocator.alloc([HASH_LEN]u8, rounds) catch return FriError.OutOfMemory;
    defer allocator.free(roots);
    // Layer 0 must survive into the proof's query extraction; take it out
    // of the defer-managed set by aliasing (freed via layer_evals too, but
    // we only free once — see ownership note below).
    const layers_meta = allocator.alloc(LayerInfo, rounds) catch return FriError.OutOfMemory;
    errdefer allocator.free(layers_meta);
    // NOTE: layers_meta freed by caller via Proof.deinit; roots is a copy.

    var alphas: [64]F = undefined;
    var log_cur: u6 = config.log_domain;

    for (0..rounds) |r| {
        const cur = layer_evals[r];
        const half = cur.len / 2;

        // Commit: one leaf per antipodal pair (positions j, j + half).
        const leaves = allocator.alloc([HASH_LEN]u8, half) catch return FriError.OutOfMemory;
        defer allocator.free(leaves);
        for (0..half) |j| leaves[j] = hashPair(F, cur[j], cur[j + half]);

        var tree = MerkleTree.initFromHashes(allocator, leaves) catch return FriError.OutOfMemory;
        defer tree.deinit();
        roots[r] = tree.root();
        layers_meta[r] = .{ .merkle_root = tree.root(), .log_size = log_cur };

        // Absorb the root, then squeeze the fold challenge.
        transcript.absorbBytes(&roots[r]);
        alphas[r] = transcript.challengeField(F);

        // Fold with the antipodal pair (j, j + half): the child lands at
        // position j of the half-size natural domain (x_j^2 = g_{k-1}^j).
        const dom = Domain(F).init(F, log_cur);
        const next = allocator.alloc(F, half) catch return FriError.OutOfMemory;
        for (0..half) |j| {
            const x = dom.at(j);
            const fx = cur[j];
            const fnegx = cur[j + half];
            const even = fx.add(fnegx).mul(half_inv);
            const odd = fx.sub(fnegx).div(x).mul(half_inv);
            next[j] = even.add(alphas[r].mul(odd));
        }
        layer_evals[r + 1] = next;
        log_cur -= 1;
    }

    // ---------- residual ----------
    // Interpolate the final layer (length 2^log_final, natural order) to
    // coefficients and truncate to the degree bound.
    const full_coeffs = interpolateToCoeffs(F, allocator, layer_evals[rounds], config.log_final) catch return FriError.OutOfMemory;
    defer allocator.free(full_coeffs);

    const residual_bytes = allocator.alloc([]const u8, residual_len) catch return FriError.OutOfMemory;
    for (residual_bytes) |*cb| cb.* = &[_]u8{};
    errdefer {
        for (residual_bytes) |cb| {
            if (cb.len != 0) allocator.free(@constCast(cb));
        }
        allocator.free(@constCast(residual_bytes));
    }
    for (0..residual_len) |i| {
        residual_bytes[i] = try serializeElem(F, allocator, full_coeffs[i]);
    }
    for (residual_bytes) |cb| {
        const c = try deserializeElem(F, cb);
        transcript.absorbField(F, c);
    }

    // ---------- queries ----------
    const queries = try buildQueries(F, allocator, transcript, layer_evals[0 .. rounds + 1], roots, config);

    return .{
        .layers = layers_meta,
        .residual = residual_bytes,
        .queries = queries,
        .log_domain = config.log_domain,
        .log_final = config.log_final,
        .log_residual_degree = config.log_residual_degree,
    };
}

/// Naive O(m^2) interpolation on the final (tiny) domain: returns
/// coefficients c_0..c_{m-1} of the unique poly of degree < m matching
/// the values at the natural points H_{log_final}[i]. Small final sizes
/// keep this cheap.
fn interpolateToCoeffs(
    comptime F: type,
    allocator: std.mem.Allocator,
    values: []const F,
    log_final: u6,
) FriError![]F {
    const m = values.len; // == 2^log_final
    const dom = Domain(F).init(F, log_final);
    // Solve the Vandermonde system V·c = v with V[i][j] = x_i^j.
    const mat = allocator.alloc(F, m * (m + 1)) catch return FriError.OutOfMemory;
    defer allocator.free(mat);
    for (0..m) |i| {
        const xi = dom.at(i);
        var xp = F.one();
        for (0..m) |j| {
            mat[i * (m + 1) + j] = xp;
            xp = xp.mul(xi);
        }
        mat[i * (m + 1) + m] = values[i];
    }
    const coeffs = allocator.alloc(F, m) catch return FriError.OutOfMemory;
    errdefer allocator.free(coeffs);
    for (0..m) |col| {
        // pivot
        var pivot: ?usize = null;
        for (col..m) |r| {
            if (!mat[r * (m + 1) + col].isZero()) {
                pivot = r;
                break;
            }
        }
        const p = pivot orelse return FriError.InvalidParameters;
        if (p != col) {
            for (0..(m + 1)) |c| {
                const tmp = mat[col * (m + 1) + c];
                mat[col * (m + 1) + c] = mat[p * (m + 1) + c];
                mat[p * (m + 1) + c] = tmp;
            }
        }
        // normalize row col
        const inv = mat[col * (m + 1) + col].inv();
        for (0..(m + 1)) |c| mat[col * (m + 1) + c] = mat[col * (m + 1) + c].mul(inv);
        // eliminate other rows
        for (0..m) |r| {
            if (r == col) continue;
            const f = mat[r * (m + 1) + col];
            if (f.isZero()) continue;
            for (0..(m + 1)) |c| {
                const sub_v = mat[col * (m + 1) + c].mul(f);
                mat[r * (m + 1) + c] = mat[r * (m + 1) + c].sub(sub_v);
            }
        }
    }
    for (0..m) |i| coeffs[i] = mat[i * (m + 1) + m];
    return coeffs;
}

fn buildQueries(
    comptime F: type,
    allocator: std.mem.Allocator,
    transcript: anytype,
    layers: []const []F,
    roots: []const [HASH_LEN]u8,
    config: Config,
) FriError![]QueryProof {
    _ = roots;
    const round_count = config.rounds() catch return FriError.InvalidParameters;

    var trees_buf: [64]?MerkleTree = @splat(null);
    defer for (&trees_buf) |*maybe_tree| {
        if (maybe_tree.*) |*t| t.deinit();
    };
    for (0..round_count) |r| {
        const cur = layers[r];
        const half = cur.len / 2;
        const leaves = allocator.alloc([HASH_LEN]u8, half) catch return FriError.OutOfMemory;
        defer allocator.free(leaves);
        for (0..half) |j| leaves[j] = hashPair(F, cur[j], cur[j + half]);
        trees_buf[r] = MerkleTree.initFromHashes(allocator, leaves) catch return FriError.OutOfMemory;
    }

    const queries = allocator.alloc(QueryProof, config.num_queries) catch return FriError.OutOfMemory;
    for (queries) |*q| {
        q.* = .{
            .pair_index = 0,
            .values = &[_][]u8{},
            .paths = &[_][]const [HASH_LEN]u8{},
        };
    }
    errdefer {
        for (queries) |q| {
            for (q.values) |v| {
                if (v.len != 0) allocator.free(v);
            }
            if (q.values.len != 0) allocator.free(q.values);
            for (q.paths) |p| {
                if (p.len != 0) allocator.free(@constCast(p));
            }
            if (q.paths.len != 0) allocator.free(@constCast(q.paths));
        }
        allocator.free(queries);
    }

    for (queries) |*q| {
        const seed = transcript.challengeU64();
        const e0: usize = @intCast(seed % @as(u64, @intCast(layers[0].len)));
        q.pair_index = e0;
        q.values = allocator.alloc([]u8, round_count) catch return FriError.OutOfMemory;
        for (q.values) |*v| v.* = &[_]u8{};
        q.paths = allocator.alloc([]const [HASH_LEN]u8, round_count) catch return FriError.OutOfMemory;
        for (q.paths) |*p| p.* = &[_][HASH_LEN]u8{};

        var e: usize = e0;
        for (0..round_count) |r| {
            const half = layers[r].len / 2;
            const j = e % half;
            q.values[r] = try serializePair(F, allocator, layers[r][j], layers[r][j + half]);

            const mp = trees_buf[r].?.prove(j, allocator) catch return FriError.OutOfMemory;
            allocator.free(mp.is_left_sibling);
            q.paths[r] = mp.siblings;

            e = j;
        }
    }
    return queries;
}

// ============================================================================
// Verifier
// ============================================================================

/// Verify a FRI proof.
///
/// Checks (in order):
///   1. Structural validity (sizes, lengths, config match).
///   2. Query indices match transcript-derived challenges.
///   3. Every antipodal pair authenticates against its layer's Merkle root.
///   4. Folding consistency across all rounds (exact positional equality).
///   5. The last fold matches the residual's evaluation on the final
///      domain — the degree anchor.
pub fn verify(
    comptime F: type,
    transcript: anytype,
    proof: *const Proof,
    config: Config,
) FriError!bool {
    try config.validate();
    const rounds = try config.rounds();
    if (proof.log_domain != config.log_domain) return FriError.InvalidProof;
    if (proof.log_final != config.log_final) return FriError.InvalidProof;
    if (proof.log_residual_degree != config.log_residual_degree) return FriError.InvalidProof;
    if (config.log_domain > F.two_adicity) return false;
    if (proof.layers.len != rounds) return FriError.InvalidProof;
    const residual_len: usize = @as(usize, 1) << config.log_residual_degree;
    if (proof.residual.len != residual_len) return FriError.InvalidProof;
    if (proof.queries.len != config.num_queries) return FriError.InvalidProof;

    const n: usize = @as(usize, 1) << config.log_domain;
    const final_len: usize = @as(usize, 1) << config.log_final;
    const half_inv = F.fromInt(1).div(F.fromInt(2));

    // ---------- replay challenges ----------
    var alphas: [64]F = undefined;
    if (rounds > 64) return FriError.InvalidProof;
    for (0..rounds) |r| {
        if (proof.layers[r].log_size != config.log_domain - @as(u6, @intCast(r))) {
            return FriError.InvalidProof;
        }
        transcript.absorbBytes(&proof.layers[r].merkle_root);
        alphas[r] = transcript.challengeField(F);
    }

    // ---------- residual: coefficients + evaluations on final domain ----------
    var residual: [4096]F = undefined;
    if (residual_len > 4096) return FriError.InvalidProof;
    for (proof.residual, 0..) |cb, i| {
        residual[i] = try deserializeElem(F, cb);
        transcript.absorbField(F, residual[i]);
    }

    // The residual is evaluated on the FULL final domain (size
    // 2^log_final > degree bound): rate < 1 gives the soundness distance.
    var final_evals_buf: [4096]F = undefined;
    if (final_len > 4096) return FriError.InvalidProof;
    const dom_final = Domain(F).init(F, proof.log_final);
    for (0..final_len) |i| {
        const xi = dom_final.at(i);
        var acc = F.zero();
        var xp = F.one();
        for (proof.residual) |cb| {
            const c = try deserializeElem(F, cb);
            acc = acc.add(c.mul(xp));
            xp = xp.mul(xi);
        }
        final_evals_buf[i] = acc;
    }

    // ---------- queries ----------
    for (proof.queries) |q| {
        const seed = transcript.challengeU64();
        const expected_idx: usize = @intCast(seed % @as(u64, @intCast(n)));
        if (q.pair_index != expected_idx) return false;
        if (q.values.len != rounds or q.paths.len != rounds) return false;

        var e: usize = q.pair_index;
        for (0..rounds) |r| {
            const layer_log: u6 = config.log_domain - @as(u6, @intCast(r));
            const half_r: usize = (@as(usize, 1) << layer_log) / 2;
            const j = e % half_r; // pair slot in layer r

            const pair = try deserializePair(F, q.values[r]);
            const x = pair[0]; // f(x)  at position j
            const negx = pair[1]; // f(-x) at position j + half_r

            // Merkle inclusion of this pair-leaf.
            const leaf = hashPair(F, x, negx);
            const expected_depth: usize = @as(usize, layer_log) - 1;
            if (q.paths[r].len != expected_depth) return false;
            if (!MerkleTree.verifyPath(proof.layers[r].merkle_root, j, leaf, q.paths[r])) {
                return false;
            }

            // Fold: child at layer r+1, position j.
            const dom_r = Domain(F).init(F, layer_log);
            const xv = dom_r.at(j);
            const even = x.add(negx).mul(half_inv);
            const odd = x.sub(negx).div(xv).mul(half_inv);
            const expected = even.add(alphas[r].mul(odd));

            if (r + 1 < rounds) {
                // Exact positional equality: the child value is slot 0 of
                // the next round's pair if j is in the lower half of the
                // next layer, slot 1 otherwise (antipodal pair of j in
                // layer r+1 is (j mod half', j mod half' + half')).
                const half_next = half_r / 2;
                const child_slot: usize = if (j < half_next) 0 else 1;
                const child_pair = try deserializePair(F, q.values[r + 1]);
                const child = child_pair[child_slot];
                if (!expected.eql(child)) return false;
            } else {
                // Last round: compare against the residual's evaluation at
                // final-domain position j — the degree anchor.
                if (!expected.eql(final_evals_buf[j])) return false;
            }
            e = j; // next layer's element position
        }
    }

    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Transcript = @import("zig-transcript").Transcript;
const Goldilocks = zfield.Goldilocks;

/// log2 of the residual degree bound used across the suite: rate 1/8 at
/// the final domain (log_final=6 => 64-point domain, degree bound 8).
fn testConfig(log_n: u6, queries: usize) Config {
    return .{
        .log_domain = log_n,
        .log_initial_degree = @intCast(log_n - 3),
        .log_final = 6,
        .log_residual_degree = 3,
        .num_queries = queries,
    };
}

/// Evaluate `coeffs` (degree < len) at `x`.
fn evalPoly(comptime F: type, coeffs: []const F, x: F) F {
    var acc = F.zero();
    var xp = F.one();
    for (coeffs) |c| {
        acc = acc.add(c.mul(xp));
        xp = xp.mul(x);
    }
    return acc;
}

test "fri v2: degree-2 poly verifies" {
    const a = testing.allocator;
    const log_n: u6 = 8; // 256
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    const c1 = Goldilocks.fromInt(3);
    const c2 = Goldilocks.fromInt(7);
    for (0..n) |i| {
        const x = dom.at(i);
        evals[i] = x.sqr().add(x.mul(c1)).add(c2);
    }

    var pt = Transcript.init("fri-v2-test");
    var proof = try prove(Goldilocks, a, &pt, evals, cfg);
    defer proof.deinit(a);

    var vt = Transcript.init("fri-v2-test");
    try testing.expect(try verify(Goldilocks, &vt, &proof, cfg));
}

test "fri v2: RANDOM data must be rejected (regression: ZA-2026-001)" {
    const a = testing.allocator;
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rng = prng.random();

    var accepted: usize = 0;
    const trials = 16;
    for (0..trials) |t| {
        for (0..n) |i| evals[i] = Goldilocks.random(rng);
        // vary data across trials
        evals[0] = evals[0].add(Goldilocks.fromInt(t));

        var pt = Transcript.init("fri-v2-test");
        var proof = try prove(Goldilocks, a, &pt, evals, cfg);
        defer proof.deinit(a);
        var vt = Transcript.init("fri-v2-test");
        if (try verify(Goldilocks, &vt, &proof, cfg)) accepted += 1;
    }
    // Random data is maximally far from degree < 8: every trial must
    // reject. (v1 accepted 16/16 of these — ZA-2026-001.)
    try testing.expectEqual(@as(usize, 0), accepted);
}

test "fri v2: over-degree poly must be rejected" {
    const a = testing.allocator;
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);

    var accepted: usize = 0;
    const trials = 8;
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rng = prng.random();
    for (0..trials) |t| {
        // degree-128 polynomial (degree bound is 8).
        var coeffs: [129]Goldilocks = undefined;
        for (&coeffs, 0..) |*c, k| c.* = Goldilocks.fromInt(k *% 2654435761 +% t);
        coeffs[128] = Goldilocks.random(rng);
        for (0..n) |i| evals[i] = evalPoly(Goldilocks, &coeffs, dom.at(i));

        var pt = Transcript.init("fri-v2-test");
        var proof = try prove(Goldilocks, a, &pt, evals, cfg);
        defer proof.deinit(a);
        var vt = Transcript.init("fri-v2-test");
        if (try verify(Goldilocks, &vt, &proof, cfg)) accepted += 1;
    }
    try testing.expectEqual(@as(usize, 0), accepted);
}

test "fri v2: tampered query value rejected" {
    const a = testing.allocator;
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    for (0..n) |i| {
        const x = dom.at(i);
        evals[i] = x.sqr().add(Goldilocks.fromInt(5));
    }

    var pt = Transcript.init("fri-v2-test");
    var proof = try prove(Goldilocks, a, &pt, evals, cfg);
    defer proof.deinit(a);

    // Corrupt one value of the first query's first pair.
    @constCast(&proof.queries[0].values[0][0]).* ^= 1;

    var vt = Transcript.init("fri-v2-test");
    try testing.expect(!(try verify(Goldilocks, &vt, &proof, cfg)));
}

test "fri v2: truncated Merkle path rejected" {
    const a = testing.allocator;
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    for (0..n) |i| evals[i] = dom.at(i).sqr();

    var pt = Transcript.init("fri-v2-test");
    var proof = try prove(Goldilocks, a, &pt, evals, cfg);
    defer proof.deinit(a);

    const original_path = proof.queries[0].paths[0];
    try testing.expect(original_path.len > 0);
    @constCast(&proof.queries[0].paths[0]).* = original_path[0 .. original_path.len - 1];
    defer @constCast(&proof.queries[0].paths[0]).* = original_path;

    var vt = Transcript.init("fri-v2-test");
    try testing.expect(!(try verify(Goldilocks, &vt, &proof, cfg)));
}

test "fri v2: wrong transcript (statement binding) rejected" {
    const a = testing.allocator;
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    for (0..n) |i| evals[i] = dom.at(i).sqr();

    var pt = Transcript.init("fri-v2-test");
    var proof = try prove(Goldilocks, a, &pt, evals, cfg);
    defer proof.deinit(a);

    var vt = Transcript.init("different-statement"); // different label
    const ok = verify(Goldilocks, &vt, &proof, cfg) catch false;
    try testing.expect(!ok);
}

test "fri v2: interpolateToCoeffs recovers a degree-1 polynomial" {
    const a = testing.allocator;
    const log_f: u6 = 6;
    const m: usize = @as(usize, 1) << log_f;
    const dom = Domain(Goldilocks).init(Goldilocks, log_f);

    var values = try a.alloc(Goldilocks, m);
    defer a.free(values);
    const c0 = Goldilocks.fromInt(5);
    const c1 = Goldilocks.fromInt(3);
    for (0..m) |i| {
        const x = dom.at(i);
        values[i] = c0.add(c1.mul(x));
    }
    const coeffs = try interpolateToCoeffs(Goldilocks, a, values, log_f);
    defer a.free(coeffs);
    try testing.expectEqual(@as(usize, 64), coeffs.len);
    try testing.expect(coeffs[0].eql(c0));
    try testing.expect(coeffs[1].eql(c1));
    for (coeffs[2..]) |c| try testing.expect(c.isZero());
}

test "fri v2: domain structure — antipodal pairs and squaring" {
    const t = std.testing;
    const log_n: u6 = 6;
    const dom = Domain(Goldilocks).init(Goldilocks, log_n);
    const n = dom.size();

    var buf: [64]Goldilocks = undefined;
    dom.fill(buf[0..n]);

    // x and x + n/2 are negatives (exponent differs by 2^(k-1)).
    for (0..n / 2) |i| {
        try t.expect(buf[i].add(buf[i + n / 2]).isZero());
    }

    // Squaring collapses {x, -x} pairs: element j of H_k squares to
    // element j of H_{k-1} (natural layout fold).
    const dom2 = Domain(Goldilocks).init(Goldilocks, log_n - 1);
    for (0..n / 2) |i| {
        try t.expect(buf[i].sqr().eql(dom2.at(i)));
    }

    // All distinct, none zero.
    for (buf[0..n], 0..) |x, i| {
        try t.expect(!x.isZero());
        for (buf[0..i]) |y| try t.expect(!x.eql(y));
    }
}

test "fri v2: config validation" {
    // log_final >= log_domain
    try testing.expectError(FriError.InvalidParameters, (Config{
        .log_domain = 6,
        .log_initial_degree = 3,
        .log_final = 6,
        .log_residual_degree = 2,
        .num_queries = 4,
    }).rounds());
    // rate 1 (degree bound == final domain size): no distance
    try testing.expectError(FriError.InvalidParameters, (Config{
        .log_domain = 8,
        .log_initial_degree = 5,
        .log_final = 6,
        .log_residual_degree = 6,
        .num_queries = 4,
    }).rounds());
    // zero queries
    try testing.expectError(FriError.InvalidParameters, (Config{
        .log_domain = 8,
        .log_initial_degree = 5,
        .log_final = 6,
        .log_residual_degree = 3,
        .num_queries = 0,
    }).rounds());
}

test "fri v2: larger domain, honest degree-bounded poly verifies" {
    const a = testing.allocator;
    const log_n: u6 = 10; // 1024
    const n: usize = @as(usize, 1) << log_n;
    // degree bound 32 (log_final=8 => 256-point final domain, rate 1/8)
    const cfg = Config{ .log_domain = log_n, .log_initial_degree = 7, .log_final = 8, .log_residual_degree = 5, .num_queries = 20 };
    const dom = Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    // degree-31 polynomial: max degree under the bound.
    var coeffs: [32]Goldilocks = undefined;
    var prng = std.Random.DefaultPrng.init(1234);
    const rng = prng.random();
    for (&coeffs) |*c| c.* = Goldilocks.random(rng);
    for (0..n) |i| evals[i] = evalPoly(Goldilocks, &coeffs, dom.at(i));

    var pt = Transcript.init("fri-v2-test");
    var proof = try prove(Goldilocks, a, &pt, evals, cfg);
    defer proof.deinit(a);
    var vt = Transcript.init("fri-v2-test");
    try testing.expect(try verify(Goldilocks, &vt, &proof, cfg));
}
