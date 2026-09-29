//! Poseidon hash function (algebraic / ZK-friendly).
//!
//! Permutation-based hash over a prime field. Uses:
//! - Full S-box rounds (x^5 or x^3 or x^alpha)
//! - Partial S-box rounds (1 S-box per round)
//! - MDS matrix mixing
//!
//! Designed for minimal arithmetic constraints in SNARKs/STARKs.

const std = @import("std");
const traits = @import("zig-algebra-traits");

pub const MAX_SEED_LEN: usize = 1 << 20;

/// Poseidon permutation over a field F.
///
/// `t`: width (number of field elements per state, typically 3 or 5)
/// `full_rounds`: total full S-box rounds (RF = Rf)
/// `partial_rounds`: partial S-box rounds (RP = Rp)
/// `alpha`: S-box exponent (typically 5 for prime fields where gcd(5, p-1)=1)
///
/// The partial-round S-box touches cell 0; for the variants that use another
/// cell, see `PoseidonVariant`.
pub fn Poseidon(comptime F: type, comptime t: usize, comptime full_rounds: usize, comptime partial_rounds: usize, comptime alpha: u64) type {
    return PoseidonVariant(F, t, full_rounds, partial_rounds, alpha, 0);
}

/// Poseidon with an explicit cell for the partial-round S-box. The reference
/// Hades implementations vary: most of the literature and `Poseidon` above use
/// cell 0; CryptoExperts' f251 library (the StarkNet parameters) uses the last
/// cell and `alpha = 3`.
pub fn PoseidonVariant(comptime F: type, comptime t: usize, comptime full_rounds: usize, comptime partial_rounds: usize, comptime alpha: u64, comptime partial_sbox_index: usize) type {
    traits.assertField(F);
    // The sponge needs a rate of at least two (`rate = t - 1`) and a non-empty
    // capacity. This used to be a `std.debug.assert(t >= 3)` inside `hash`,
    // which is compiled out in ReleaseFast and then indexed a `[0]` state.
    if (t < 3) @compileError("Poseidon: width t must be >= 3");
    if (partial_sbox_index >= t) @compileError("Poseidon: partial_sbox_index must be < t");

    const total_rounds = full_rounds + partial_rounds;

    return struct {
        const Self = @This();

        /// Round constants: [total_rounds][t]F
        round_constants: [total_rounds][t]F,
        /// MDS matrix: [t][t]F
        mds_matrix: [t][t]F,

        pub fn init(round_constants: [total_rounds][t]F, mds_matrix: [t][t]F) Self {
            return .{
                .round_constants = round_constants,
                .mds_matrix = mds_matrix,
            };
        }

        /// Generate round constants and MDS matrix deterministically from a
        /// seed string.
        ///
        /// # Errors
        /// `error.SeedTooLong` when `seed.len > MAX_SEED_LEN`, and
        /// `error.NoValidMdsEntry` when the 256-attempt search for an MDS
        /// entry with `x_i + candidate != 0` for every `i` and distinct from
        /// the previous `y[j]` finds nothing. That `std.debug.assert(attempt <
        /// 256)` was compiled out in `ReleaseFast`, where a failed search left
        /// `y[j]` undefined and produced a singular MDS matrix.
        pub fn initFromSeed(seed: []const u8) error{ SeedTooLong, NoValidMdsEntry }!Self {
            if (seed.len > MAX_SEED_LEN) return error.SeedTooLong;
            var rc: [total_rounds][t]F = undefined;
            var mds: [t][t]F = undefined;

            // Generate round constants using a simple counter-based PRNG
            var counter: u64 = 0;
            for (0..total_rounds) |r| {
                for (0..t) |i| {
                    rc[r][i] = fieldFromCounter(F, seed, counter);
                    counter += 1;
                }
            }

            var x: [t]F = undefined;
            var y: [t]F = undefined;
            for (0..t) |i| x[i] = F.fromInt(i + 1);
            for (0..t) |j| {
                var candidate = F.fromInt(t + j + 1).neg();
                var attempt: usize = 0;
                while (attempt < 256) : (attempt += 1) {
                    var valid = true;
                    for (x) |xi| {
                        if (xi.add(candidate).isZero()) {
                            valid = false;
                            break;
                        }
                    }
                    if (valid) {
                        for (y[0..j]) |previous| {
                            if (previous.eql(candidate)) {
                                valid = false;
                                break;
                            }
                        }
                    }
                    if (valid) {
                        y[j] = candidate;
                        break;
                    }
                    candidate = candidate.add(F.one());
                }
                if (attempt == 256) return error.NoValidMdsEntry;
            }
            for (0..t) |i| {
                for (0..t) |j| mds[i][j] = F.inv(x[i].add(y[j]));
            }

            return init(rc, mds);
        }

        /// Generate round constants and the MDS matrix with the reference
        /// parameter generator: the IAIK `generate_parameters_grain.sage`
        /// Grain LFSR behind circomlibjs's `poseidon_constants.json`.
        ///
        /// The 80-bit header is (FIELD=1, SBOX=0, n, t, RF, RP) followed by
        /// 30 ones; n-bit samples are drawn MSB-first, rejected when `>= p`
        /// for round constants, and reduced modulo p for the Cauchy MDS
        /// candidate (2t distinct samples, every `x_i + y_j != 0` in F).
        ///
        /// `SBOX=0` records the family `x^alpha`: the exponent does not
        /// enter the header, so alpha = 3 and alpha = 5 with the same
        /// `(n, t, RF, RP)` generate the same parameters. The sage script's
        /// `algorithm_1/2/3` sieve that pre-validates MDS candidates is not
        /// ported; the known-answer test over circomlib's published `M[1]`
        /// pins that the first candidate is accepted for this parameter set.
        ///
        /// # Errors
        /// `error.NoValidRoundConstant` when 256 consecutive n-bit candidates
        /// for one constant land `>= p` (each draw has probability > 1/2 of
        /// being `< p`, so this is a bounded safety net, not an expected
        /// outcome), `error.NoValidMdsEntry` when 256 draws fail the
        /// distinctness or non-zero-sum conditions, or when an MDS entry
        /// inverts to zero despite the non-zero-sum check.
        pub fn initSpec() error{ NoValidRoundConstant, NoValidMdsEntry }!Self {
            if (@hasDecl(F, "EXT_NON_RESIDUE")) @compileError("initSpec: F must be a prime field, not an extension field");
            if (!@hasDecl(F, "MODULUS")) @compileError("initSpec: F must declare MODULUS");
            if (!@hasDecl(F, "BITS")) @compileError("initSpec: F must declare BITS");
            if (!@hasDecl(F, "invChecked")) @compileError("initSpec: F must provide invChecked");
            if (F.BITS > 512) @compileError("initSpec: F.BITS must be <= 512 (the Grain sampler yields u512)");
            if (t >= 1 << 12) @compileError("initSpec: t must be < 4096 (12-bit Grain header field)");
            if (full_rounds >= 1 << 10) @compileError("initSpec: full_rounds must be < 1024 (10-bit Grain header field)");
            if (partial_rounds >= 1 << 10) @compileError("initSpec: partial_rounds must be < 1024 (10-bit Grain header field)");

            const n: usize = F.BITS;
            const p: u512 = F.MODULUS;
            var grain = Grain.init(n, t, full_rounds, partial_rounds);

            var round_constants: [total_rounds][t]F = undefined;
            for (&round_constants) |*row| {
                for (row) |*cell| {
                    var attempts: usize = 0;
                    while (true) : (attempts += 1) {
                        if (attempts == 256) return error.NoValidRoundConstant;
                        const candidate = grain.sample(n);
                        if (candidate < p) {
                            cell.* = F.fromInt(candidate);
                            break;
                        }
                    }
                }
            }

            var attempts: usize = 0;
            while (attempts < 256) : (attempts += 1) {
                // 2t samples reduced modulo p, redrawn as a whole while any
                // two coincide -- the reference draws all 2t before checking.
                var samples: [2 * t]u512 = undefined;
                var draws: usize = 0;
                while (draws < 256) : (draws += 1) {
                    for (&samples) |*s| s.* = grain.sample(n) % p;
                    var duplicate = false;
                    for (0..2 * t) |i| {
                        for (0..i) |j| {
                            if (samples[i] == samples[j]) duplicate = true;
                        }
                    }
                    if (!duplicate) break;
                }
                if (draws == 256) return error.NoValidMdsEntry;

                // Every x_i + y_j must be nonzero in F. Both samples are
                // reduced, so the sum mod p is zero exactly when the other
                // sample is the additive complement -- computed without
                // ever forming a < 2p sum that could exceed u512.
                var zero_sum = false;
                for (0..t) |i| {
                    for (0..t) |j| {
                        if (samples[t + j] == (p - samples[i]) % p) zero_sum = true;
                    }
                }
                if (zero_sum) continue;

                var mds: [t][t]F = undefined;
                for (0..t) |i| {
                    for (0..t) |j| {
                        const a = samples[i];
                        const b = samples[t + j];
                        const sum: u512 = if (a >= p - b) a - (p - b) else a + b;
                        const s = if (sum >= p) sum - p else sum;
                        mds[i][j] = F.invChecked(F.fromInt(s)) catch return error.NoValidMdsEntry;
                    }
                }
                return init(round_constants, mds);
            }
            return error.NoValidMdsEntry;
        }

        /// S-box: x^alpha
        fn sbox(x: F) F {
            return F.pow(x, alpha);
        }

        /// Apply S-box to all elements (full round).
        fn fullSbox(state: *[t]F) void {
            for (0..t) |i| {
                state[i] = sbox(state[i]);
            }
        }

        /// Apply S-box to the configured cell only (partial round).
        fn partialSbox(state: *[t]F) void {
            state[partial_sbox_index] = sbox(state[partial_sbox_index]);
        }

        /// Add round constants.
        fn addConstants(self: Self, state: *[t]F, r: usize) void {
            for (0..t) |i| {
                state[i] = F.add(state[i], self.round_constants[r][i]);
            }
        }

        /// MDS matrix multiplication: state = MDS * state
        fn applyMds(self: Self, state: *[t]F) void {
            var new_state: [t]F = undefined;
            for (0..t) |i| {
                var sum = F.zero();
                for (0..t) |j| {
                    sum = F.add(sum, F.mul(self.mds_matrix[i][j], state[j]));
                }
                new_state[i] = sum;
            }
            state.* = new_state;
        }

        /// Single permutation round.
        fn round(self: Self, state: *[t]F, r: usize, is_full: bool) void {
            self.addConstants(state, r);
            if (is_full) {
                fullSbox(state);
            } else {
                partialSbox(state);
            }
            self.applyMds(state);
        }

        /// Full permutation.
        pub fn permute(self: Self, state: *[t]F) void {
            const rp_begin = full_rounds / 2;
            const rp_end = rp_begin + partial_rounds;

            // First full rounds
            for (0..rp_begin) |r| {
                self.round(state, r, true);
            }

            // Partial rounds
            for (rp_begin..rp_end) |r| {
                self.round(state, r, false);
            }

            // Last full rounds
            for (rp_end..total_rounds) |r| {
                self.round(state, r, true);
            }
        }

        /// Hash a message (sponge construction, pad10*1 at element level).
        /// The final element of the padded stream is a `1` delimiter placed in
        /// the first position the message did not occupy, so a message and its
        /// zero extension never share a stream; a message that fills blocks
        /// exactly gains one extra block carrying the delimiter. For t=3:
        /// rate=2, capacity=1 (2 elements absorbed per block).
        pub fn hash(self: Self, msg: []const F) [2]F {
            comptime std.debug.assert(t >= 3);
            const rate = t - 1;

            var state: [t]F = std.mem.zeroes([t]F);

            var i: usize = 0;
            while (i + rate <= msg.len) : (i += rate) {
                for (0..rate) |j| {
                    state[j] = F.add(state[j], msg[i + j]);
                }
                self.permute(&state);
            }

            const rem = msg.len - i;
            for (0..rem) |j| {
                state[j] = F.add(state[j], msg[i + j]);
            }
            state[rem] = F.add(state[rem], F.one());
            self.permute(&state);

            return .{ state[0], state[1] };
        }

        /// Hash two field elements (common use case).
        pub fn hash2(self: Self, a: F, b: F) F {
            var state: [t]F = std.mem.zeroes([t]F);
            state[0] = a;
            state[1] = b;
            self.permute(&state);
            return state[0];
        }
    };
}

/// Deterministically generate a field element from a counter.
fn fieldFromCounter(comptime F: type, seed: []const u8, counter: u64) F {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("zig-hash:algebraic-constant");
    var seed_len: [8]u8 = undefined;
    std.mem.writeInt(u64, &seed_len, @intCast(seed.len), .little);
    hasher.update(&seed_len);
    hasher.update(seed);
    var counter_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter_bytes, counter, .little);
    hasher.update(&counter_bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var value: u256 = 0;
    for (digest) |byte| value = (value << 8) | byte;
    return F.fromInt(value);
}

/// The 80-bit Grain LFSR of the IAIK `generate_parameters_grain.sage`
/// reference parameter generator: one bit per `u1` slot, taps at
/// 62/51/38/23/13/0, shift toward index 0 with the feedback bit last.
const Grain = struct {
    state: [80]u1,

    /// Header (MSB-first within each field): FIELD=1 (GF(p)) as 2 bits,
    /// SBOX=0 (the `x^alpha` family) as 4 bits, then n, t, full_rounds and
    /// partial_rounds as 12/12/10/10 bits, then 30 ones. The burn-in
    /// discards the first 160 steps before any output is used.
    fn init(n: usize, t: usize, full_rounds: usize, partial_rounds: usize) Grain {
        var s: [80]u1 = [_]u1{0} ** 80;
        s[1] = 1; // FIELD = 1 -> bits "01"; SBOX = 0 leaves bits 2..6 zero
        setBits(&s, 6, n, 12);
        setBits(&s, 18, t, 12);
        setBits(&s, 30, full_rounds, 10);
        setBits(&s, 40, partial_rounds, 10);
        for (50..80) |i| s[i] = 1;
        var g = Grain{ .state = s };
        for (0..160) |_| _ = g.step();
        return g;
    }

    fn setBits(s: *[80]u1, comptime offset: usize, value: usize, comptime width: usize) void {
        for (0..width) |i| {
            // The shift amount must itself be a valid shift count (u6 for a
            // 64-bit value), so it is cast rather than left as `usize`.
            const shift: u6 = @intCast(width - 1 - @as(usize, i));
            s[offset + i] = @intCast((value >> shift) & 1);
        }
    }

    fn step(self: *Grain) u1 {
        const b = self.state[62] ^ self.state[51] ^ self.state[38] ^
            self.state[23] ^ self.state[13] ^ self.state[0];
        std.mem.copyForwards(u1, self.state[0..79], self.state[1..80]);
        self.state[79] = b;
        return b;
    }

    /// Next generator bit: one step, then while it is zero step twice per
    /// iteration, then one final step whose bit is the output.
    fn nextBit(self: *Grain) u1 {
        var b = self.step();
        while (b == 0) {
            _ = self.step();
            b = self.step();
        }
        return self.step();
    }

    /// `width` output bits MSB-first as a u512.
    fn sample(self: *Grain, width: usize) u512 {
        var v: u512 = 0;
        for (0..width) |_| v = (v << 1) | self.nextBit();
        return v;
    }
};
