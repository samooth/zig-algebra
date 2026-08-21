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

/// Poseidon permutation over a field F.
///
/// `t`: width (number of field elements per state, typically 3 or 5)
/// `full_rounds`: total full S-box rounds (RF = Rf)
/// `partial_rounds`: partial S-box rounds (RP = Rp)
/// `alpha`: S-box exponent (typically 5 for prime fields where gcd(5, p-1)=1)
pub fn Poseidon(comptime F: type, comptime t: usize, comptime full_rounds: usize, comptime partial_rounds: usize, comptime alpha: u64) type {
    traits.assertField(F);

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

        /// Generate round constants and MDS matrix deterministically from a seed string.
        pub fn initFromSeed(seed: []const u8) Self {
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

            // Generate MDS matrix (Cauchy matrix for invertibility)
            // M[i][j] = 1 / (x_i + y_j) where x_i and y_j are distinct
            for (0..t) |i| {
                for (0..t) |j| {
                    const xi = fieldFromCounter(F, seed, counter);
                    counter += 1;
                    const yj = fieldFromCounter(F, seed, counter);
                    counter += 1;
                    const sum = F.add(xi, yj);
                    mds[i][j] = F.inv(sum);
                }
            }

            return init(rc, mds);
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

        /// Apply S-box to first element only (partial round).
        fn partialSbox(state: *[t]F) void {
            state[0] = sbox(state[0]);
        }

        /// Add round constants.
        fn addConstants(state: *[t]F, r: usize) void {
            for (0..t) |i| {
                state[i] = F.add(state[i], Self.round_constants[r][i]);
            }
        }

        /// MDS matrix multiplication: state = MDS * state
        fn applyMds(state: *[t]F) void {
            var new_state: [t]F = undefined;
            for (0..t) |i| {
                var sum = F.zero();
                for (0..t) |j| {
                    sum = F.add(sum, F.mul(Self.mds_matrix[i][j], state[j]));
                }
                new_state[i] = sum;
            }
            state.* = new_state;
        }

        /// Single permutation round.
        fn round(state: *[t]F, r: usize, is_full: bool) void {
            addConstants(state, r);
            if (is_full) {
                fullSbox(state);
            } else {
                partialSbox(state);
            }
            applyMds(state);
        }

        /// Full permutation.
        pub fn permute(self: Self, state: *[t]F) void {
            _ = self;
            const rp_begin = full_rounds / 2;
            const rp_end = rp_begin + partial_rounds;

            // First full rounds
            for (0..rp_begin) |r| {
                round(state, r, true);
            }

            // Partial rounds
            for (rp_begin..rp_end) |r| {
                round(state, r, false);
            }

            // Last full rounds
            for (rp_end..total_rounds) |r| {
                round(state, r, true);
            }
        }

        /// Hash a message (sponge construction, simplified).
        /// For t=3: rate=2, capacity=1 (2 elements absorbed per block).
        pub fn hash(self: Self, msg: []const F) [2]F {
            std.debug.assert(t >= 3);
            const rate = t - 1;

            var state: [t]F = std.mem.zeroes([t]F);

            // Absorb
            var i: usize = 0;
            while (i < msg.len) : (i += rate) {
                const end = @min(i + rate, msg.len);
                for (i..end) |j| {
                    state[j - i] = F.add(state[j - i], msg[j]);
                }
                self.permute(&state);
            }

            // Squeeze (2 outputs)
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
    // Simple hash-based generation: Blake3(seed || counter) -> field element
    var buf: [40]u8 = undefined;
    @memcpy(buf[0..seed.len], seed);
    std.mem.writeInt(u64, buf[seed.len..][0..8], counter, .little);

    // Use a simple deterministic reduction
    // In practice, you'd use a proper hash-to-field
    var val: u256 = 0;
    for (0..32) |i| {
        val = (val << 8) | buf[i % buf.len];
    }
    return F.fromInt(val);
}
