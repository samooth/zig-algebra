//! MiMC hash function (Minimal Multiplicative Complexity).
//!
//! Designed for minimal arithmetic constraints in SNARKs.
//! Uses a Feistel network with round function x^exponent.

const std = @import("std");
const traits = @import("zig-algebra-traits");

/// MiMC hash over a field F.
///
/// `rounds`: number of Feistel rounds (typically ~220 for 128-bit security)
/// `exponent`: typically 3, 5, or 7 (must be coprime to p-1)
pub fn MiMC(comptime F: type, comptime rounds: usize, comptime exponent: u64) type {
    traits.assertField(F);

    return struct {
        const Self = @This();

        /// Round constants: [rounds]F
        round_constants: [rounds]F,

        pub fn init(round_constants: [rounds]F) Self {
            return .{ .round_constants = round_constants };
        }

        /// Generate round constants deterministically from seed.
        pub fn initFromSeed(seed: []const u8) Self {
            var rc: [rounds]F = undefined;
            var counter: u64 = 0;
            for (0..rounds) |i| {
                rc[i] = fieldFromCounter(F, seed, counter);
                counter += 1;
            }
            return init(rc);
        }

        /// MiMC permutation: x -> x^exponent + c (repeated `rounds` times).
        pub fn permute(self: Self, state: F) F {
            var x = state;
            for (0..rounds) |i| {
                const x_exp = F.pow(x, exponent);
                x = F.add(x_exp, self.round_constants[i]);
            }
            return x;
        }

        /// Hash two field elements using Feistel network.
        pub fn hash2(self: Self, left: F, right: F) F {
            const xl = self.permute(left);
            const xr = F.add(xl, right);
            const yl = self.permute(xr);
            const yr = F.add(yl, left);
            return F.add(yl, yr);
        }

        /// Hash a message (sponge-like).
        pub fn hash(self: Self, msg: []const F) F {
            var state = F.zero();
            for (msg) |m| {
                state = self.hash2(state, m);
            }
            return state;
        }
    };
}

fn fieldFromCounter(comptime F: type, seed: []const u8, counter: u64) F {
    var buf: [40]u8 = undefined;
    @memcpy(buf[0..seed.len], seed);
    std.mem.writeInt(u64, buf[seed.len..][0..8], counter, .little);
    var val: u256 = 0;
    for (0..32) |i| {
        val = (val << 8) | buf[i % buf.len];
    }
    return F.fromInt(val);
}
