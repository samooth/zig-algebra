//! zig-transcript: Fiat-Shamir transcript for non-interactive proofs.
//!
//! A transcript absorbs prover messages (field elements, commitments, public
//! inputs) and squeezes verifier challenges deterministically. Every challenge
//! depends on ALL previously absorbed data AND on previous challenges (via
//! re-keying after each squeeze), preventing state-extension attacks.
//!
//! Uses Blake3 (stdlib) internally — audited, fast, zero external deps.
//!
//! # Usage (STARK round)
//! ```zig
//! var t = Transcript.init("STARK-Prover-v1");
//! t.absorbField(M31, public_input);
//! t.absorbBytes(&merkle_root);       // [32]u8 commitment
//!
//! const alpha = t.challengeField(M31); // first challenge
//! // ... compute next layer ...
//! t.absorbField(M31, folded_root);
//! const beta = t.challengeField(M31); // second challenge
//! ```
//!
//! # Security
//! - Domain separation on init prevents cross-protocol replay.
//! - Length-prefixing on absorb prevents concatenation ambiguity.
//! - Re-keying after squeeze prevents state extension.
//! - Challenge values are uniformly derived from the hash sponge; callers
//!   must reduce mod p if needed (handled by `challengeField`).

const std = @import("std");

const Blake3 = @import("std").crypto.hash.Blake3;
const DIGEST_LEN = 32;

/// Fiat-Shamir transcript for non-interactive proof systems.
///
/// Absorb prover messages → squeeze verifier challenges → re-key → repeat.
/// All operations are allocation-free (stack only).
pub const Transcript = struct {
    hasher: Blake3,

    /// Create a new transcript bound to a domain label.
    /// The label prevents cross-protocol attacks: two different protocols
    /// using the same messages will produce different challenges.
    pub fn init(domain_label: []const u8) Transcript {
        var t = Transcript{ .hasher = Blake3.init(.{}) };
        // Length-prefix domain label to prevent ambiguity.
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, domain_label.len, .little);
        t.hasher.update(&len_buf);
        t.hasher.update(domain_label);
        return t;
    }

    /// Absorb raw bytes (length-prefixed to prevent concatenation ambiguity).
    pub fn absorbBytes(self: *Transcript, data: []const u8) void {
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, data.len, .little);
        self.hasher.update(&len_buf);
        self.hasher.update(data);
    }

    /// Absorb a single u64 (length-prefixed, fixed 8-byte encoding).
    pub fn absorbU64(self: *Transcript, val: u64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, val, .little);
        self.absorbBytes(&buf);
    }

    /// Absorb a field element via its `toBytes()` serialisation.
    ///
    /// Works with any type exposing `toBytes() -> [N]u8`, including
    /// SmallField, BigField, quadratic/cubic extensions, and tower elements.
    pub fn absorbField(self: *Transcript, comptime F: type, elem: F) void {
        const bytes = elem.toBytes();
        self.absorbBytes(&bytes);
    }

    /// Absorb an optional field element (encodes presence/absence).
    pub fn absorbOptionalField(self: *Transcript, comptime F: type, elem: ?F) void {
        if (elem) |e| {
            self.absorbU64(1);
            self.absorbField(F, e);
        } else {
            self.absorbU64(0);
        }
    }

    /// Squeeze `out.len` bytes of challenge output.
    ///
    /// Finalises the current hasher state, copies the digest to `out`
    /// (extending via re-hashing if out.len > 32), then RE-KEYS the hasher
    /// with the challenge bytes so subsequent squeezes depend on this one.
    pub fn challengeBytes(self: *Transcript, out: []u8) void {
        var digest: [DIGEST_LEN]u8 = undefined;
        self.hasher.final(&digest);

        var offset: usize = 0;
        while (offset < out.len) {
            const copy_len = @min(DIGEST_LEN, out.len - offset);
            @memcpy(out[offset .. offset + copy_len], digest[0..copy_len]);
            offset += copy_len;
            if (offset < out.len) {
                // Extend: hash current output to get more bytes
                var ext = Blake3.init(.{});
                ext.update(&digest);
                ext.final(&digest);
            }
        }

        // Re-key: reset hasher with challenge as seed.
        // This ensures the next squeeze depends on this one.
        self.hasher = Blake3.init(.{});
        self.hasher.update(&digest);
    }

    /// Squeeze a u64 challenge.
    pub fn challengeU64(self: *Transcript) u64 {
        var buf: [8]u8 = undefined;
        self.challengeBytes(&buf);
        return std.mem.readInt(u64, &buf, .little);
    }

    /// Squeeze a field element of type F.
    ///
    /// Requires F to have:
    ///   - `NUM_BYTES`: byte length constant
    ///   - `fromBytes([]const u8) !Self`
    ///
    /// **No uniformity is promised**, and this function cannot tell whether the
    /// field's decoder supports it. It is exact only when `F.fromBytes` *rejects*
    /// out-of-range encodings, which `zig-field`'s does (`error.ValueOutOfRange`)
    /// and which `zig-binary-field`'s prime fixtures deliberately do not: theirs
    /// reduces, so the result is `bytes mod p` and the distribution carries the
    /// reduction's bias. The two are different field conventions living in one
    /// repository, and the name of the decoder is the only thing that
    /// distinguishes them.
    ///
    /// New code that needs a uniform challenge should call
    /// `challengeFieldChecked`, whose success set is `[0, p)` for every field
    /// that exposes `fromBytesChecked`.
    pub fn challengeField(self: *Transcript, comptime F: type) F {
        const N = F.NUM_BYTES;
        while (true) {
            var buf: [N]u8 = undefined;
            self.challengeBytes(&buf);
            if (F.fromBytes(&buf)) |val| {
                return val;
            } else |_| {
                // Bytes exceeded modulus; challengeBytes already re-keyed
                // the hasher so the next attempt produces different bytes.
            }
        }
    }

    /// Decodes a challenge with `F.fromBytesChecked`, re-keying and retrying on
    /// rejection.
    ///
    /// **Uniform on `[0, p)` exactly**, for any field exposing
    /// `fromBytesChecked(bytes: [NUM_BYTES]u8) !F` whose success set is the
    /// field: rejection sampling over such a decoder has no bias to bound.
    /// Compare the alternative in `draft-irtf-cfrg-fiat-shamir` section 4.2.2,
    /// `LE2IP(Squeeze(Ns + 16)) mod M`, which reduces and therefore carries up
    /// to 2^-128 and is chosen there for constant time rather than correctness.
    ///
    /// Over GF(2^m) (`BinaryField`, `TowerField`) `fromBytesChecked` cannot
    /// fail, because every bit string is an element, and the loop runs once.
    pub fn challengeFieldChecked(self: *Transcript, comptime F: type) F {
        const N = F.NUM_BYTES;
        while (true) {
            var buf: [N]u8 = undefined;
            self.challengeBytes(&buf);
            if (F.fromBytesChecked(buf)) |val| {
                return val;
            } else |_| {
                // Encoding was out of range. challengeBytes already re-keyed
                // the hasher, so this retry draws different bytes.
            }
        }
    }

    /// Squeeze n field elements of type F.
    pub fn challengeFields(self: *Transcript, comptime F: type, comptime n: usize) [n]F {
        var result: [n]F = undefined;
        for (&result) |*r| r.* = self.challengeField(F);
        return result;
    }

    /// Compute a combined challenge from multiple field elements.
    /// Convenience method: absorbs all elements then squeezes one challenge.
    pub fn challengeFrom(
        self: *Transcript,
        comptime F: type,
        elems: []const F,
    ) F {
        for (elems) |e| self.absorbField(F, e);
        return self.challengeField(F);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Small test field: Mersenne-31
const M31 = struct {
    const Self = @This();
    value: u32,
    pub const MODULUS: u32 = 0x7FFFFFFF;
    pub const NUM_BYTES: usize = 4;

    pub fn zero() Self {
        return .{ .value = 0 };
    }
    pub fn one() Self {
        return .{ .value = 1 };
    }
    pub fn fromInt(x: anytype) Self {
        return .{ .value = @intCast(@mod(x, Self.MODULUS)) };
    }
    pub fn toInt(self: Self) u32 {
        return self.value;
    }
    pub fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
    }
    pub fn add(a: Self, b: Self) Self {
        return fromInt(a.value + b.value);
    }
    pub fn mul(a: Self, b: Self) Self {
        return fromInt(@as(u64, a.value) * b.value);
    }
    pub fn sub(a: Self, b: Self) Self {
        return fromInt(a.value +% Self.MODULUS -% b.value);
    }
    pub fn isZero(self: Self) bool {
        return self.value == 0;
    }
    pub fn neg(a: Self) Self {
        return if (a.value == 0) zero() else fromInt(Self.MODULUS - a.value);
    }
    pub fn sqr(a: Self) Self {
        return mul(a, a);
    }
    pub fn inv(a: Self) Self {
        // Fermat: x^(p-2) mod p
        return pow(a, Self.MODULUS - 2);
    }
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

test "deterministic: same input → same challenge" {
    var t1 = Transcript.init("test-domain");
    var t2 = Transcript.init("test-domain");
    t1.absorbU64(42);
    t2.absorbU64(42);
    try testing.expect(t1.challengeU64() == t2.challengeU64());
}

test "different domains → different challenges" {
    var t1 = Transcript.init("domain-a");
    var t2 = Transcript.init("domain-b");
    t1.absorbU64(42);
    t2.absorbU64(42);
    try testing.expect(t1.challengeU64() != t2.challengeU64());
}

test "different absorbed data → different challenges" {
    var t1 = Transcript.init("test");
    var t2 = Transcript.init("test");
    t1.absorbU64(1);
    t2.absorbU64(2);
    try testing.expect(t1.challengeU64() != t2.challengeU64());
}

test "challenges are sequential (re-keyed)" {
    var t = Transcript.init("seq");
    const c1 = t.challengeU64();
    const c2 = t.challengeU64();
    const c3 = t.challengeU64();
    // Extremely unlikely all three are equal
    try testing.expect(c1 != c2 or c2 != c3 or c1 != c3);
}

test "length prefix prevents ambiguity" {
    // absorb([ab]) + absorb([c]) ≠ absorb([abc])
    var t1 = Transcript.init("ambiguity-test");
    var t2 = Transcript.init("ambiguity-test");
    t1.absorbBytes("ab");
    t1.absorbBytes("c");
    t2.absorbBytes("abc");
    try testing.expect(t1.challengeU64() != t2.challengeU64());
}

test "absorbField works with test field" {
    var t = Transcript.init("field-test");
    t.absorbField(M31, M31.fromInt(42));
    const c = t.challengeField(M31);
    try testing.expect(c.value < M31.MODULUS);
}

test "challengeField rejects out-of-range values" {
    var t = Transcript.init("rejection");
    // Squeeze many challenges; all must be < MODULUS
    for (0..100) |_| {
        const c = t.challengeField(M31);
        try testing.expect(c.value < M31.MODULUS);
    }
}

test "challengeFields squeezes multiple" {
    var t = Transcript.init("multi");
    const challenges = t.challengeFields(M31, 4);
    // At least some must differ (probability of all equal ≈ 0)
    try testing.expect(!challenges[0].eql(challenges[1]) or !challenges[1].eql(challenges[2]));
}

test "absorbOptionalField encodes presence" {
    var t_some = Transcript.init("opt");
    var t_none = Transcript.init("opt");
    t_some.absorbOptionalField(M31, M31.fromInt(7));
    t_none.absorbOptionalField(M31, null);
    try testing.expect(t_some.challengeU64() != t_none.challengeU64());
}

test "challengeFrom combines multiple elements" {
    var t1 = Transcript.init("combine");
    var t2 = Transcript.init("combine");
    const elems = [_]M31{ M31.fromInt(1), M31.fromInt(2), M31.fromInt(3) };
    const c1 = t1.challengeFrom(M31, &elems);
    // Same elements → same challenge
    const c2 = t2.challengeFrom(M31, &elems);
    try testing.expect(c1.eql(c2));
    // Different order → different challenge
    const rev = [_]M31{ M31.fromInt(3), M31.fromInt(2), M31.fromInt(1) };
    const c3 = t2.challengeFrom(M31, &rev);
    try testing.expect(!c1.eql(c3));
}

// A field whose `fromBytes` is total and lossy while its `fromBytesChecked`
// rejects, which is the shape of `zig-binary-field`'s prime fixtures
// (`prime128.zig:311` reduces, `:318` refuses) against `zig-field`'s
// (`field.zig:200`, which rejects and has no checked variant under that name
// until this change).
//
// The constant return is a **deliberate caricature**. The real difference
// between a reducing and a rejecting decoder is unobservable by sampling: for
// `Prime128` the chance a draw lands in `[p, 2^128)` is 159/2^128, and for
// `Prime31` the skew falls on two values out of 2^31, so no counting test can
// ever see it. A test that cannot fail is the thing this repository keeps
// refusing to accept, so the witness has to be constructed instead of sampled.
const ReducingDecoder = struct {
    pub const NUM_BYTES: u8 = 8;
    pub const MODULUS: u64 = 0xFFFFFFFFFFFFFFC5; // 2^64 - 59, prime
    value: u64 = 0,

    /// Total and lossy, like a reducing decoder: no error is possible, so the
    /// caller cannot tell the value was not a faithful decode. Returns a fixed
    /// value so the lossiness is observable at all.
    pub fn fromBytes(bytes: []const u8) !@This() {
        if (bytes.len != NUM_BYTES) return error.InvalidLength;
        return .{ .value = 7 };
    }

    /// Rejecting decoder: success set is exactly `[0, MODULUS)`.
    pub fn fromBytesChecked(bytes: [NUM_BYTES]u8) error{ValueOutOfRange}!@This() {
        var v: u64 = 0;
        for (bytes, 0..) |b, i| v |= @as(u64, b) << @intCast(8 * i);
        if (v >= MODULUS) return error.ValueOutOfRange;
        return .{ .value = v };
    }
};

test "transcript: challengeFieldChecked uses the rejecting decoder, challengeField does not" {
    // The reducing path: total, lossy, no uniformity claimed.
    var t1 = Transcript.init("reducing");
    for (0..16) |_| {
        try std.testing.expectEqual(@as(u64, 7), t1.challengeField(ReducingDecoder).value);
    }

    // The rejecting path: every challenge is a faithful decode in `[0, p)`.
    var t2 = Transcript.init("checked");
    var saw_non_lossy: usize = 0;
    for (0..256) |_| {
        const c = t2.challengeFieldChecked(ReducingDecoder);
        try std.testing.expect(c.value < ReducingDecoder.MODULUS);
        if (c.value != 7) saw_non_lossy += 1;
    }
    // 255/256 of the draws land in [0, 2^64) while the modulus is 2^64 - 59, so
    // the probability of 256 losses by chance is (59/2^64)^256.
    try std.testing.expect(saw_non_lossy > 0);
}
