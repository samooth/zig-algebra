//! Extended GCD and modular inverse for BigInt.
//!
//! Provides the Extended Euclidean Algorithm and modular multiplicative inverse
//! for arbitrary-precision integers.
//!
//! # Quick Start
//! ```zig
//! const Big = BigInt(8);
//! const G = ExtendedGcd(8);
//!
//! const a = Big.fromU64(240);
//! const b = Big.fromU64(46);
//! const res = G.egcd(a, b);
//! // res.g == gcd(240, 46) == 2
//! // res.x == -9, res.y == 47
//! // Verify: 240*(-9) + 46*47 = 2
//!
//! const inv = try G.modInv(Big.fromU64(3), Big.fromU64(11));
//! // inv == 4 because 3*4 = 12 = 1 (mod 11)
//! ```

const std = @import("std");
const bigint = @import("bigint.zig");

/// Extended GCD operations for a given BigInt precision.
///
/// `max_limbs` must match the precision of the `BigInt` instances you pass in.
pub fn ExtendedGcd(comptime max_limbs: usize) type {
    const Big = bigint.BigInt(max_limbs);

    return struct {
        /// Extended Euclidean Algorithm.
        ///
        /// Returns `(g, x, y)` such that `a*x + b*y = g = gcd(a, b)`.
        ///
        /// The result is normalized so that `g` is always non-negative.
        /// If `a` and `b` are both zero, `g` is zero.
        pub fn egcd(a: Big, b: Big) struct { g: Big, x: Big, y: Big } {
            var old_r = a;
            var r = b;
            var old_s = Big.one();
            var s = Big.zero();
            var old_t = Big.zero();
            var t = Big.one();

            while (!r.isZero()) {
                const q = old_r.div(r) catch unreachable;

                const tmp_r = old_r;
                old_r = r;
                r = tmp_r.sub(q.mul(r) catch unreachable) catch unreachable;

                const tmp_s = old_s;
                old_s = s;
                s = tmp_s.sub(q.mul(s) catch unreachable) catch unreachable;

                const tmp_t = old_t;
                old_t = t;
                t = tmp_t.sub(q.mul(t) catch unreachable) catch unreachable;
            }

            // Ensure gcd is positive
            if (old_r.isNegative()) {
                old_r = old_r.neg();
                old_s = old_s.neg();
                old_t = old_t.neg();
            }

            return .{ .g = old_r, .x = old_s, .y = old_t };
        }

        /// Modular multiplicative inverse: `a^-1 mod m`.
        ///
        /// Returns `error.InvalidModulus` if `m <= 0`.
        /// Returns `error.NotInvertible` if `gcd(a, m) != 1`.
        ///
        /// # Example
        /// ```zig
        /// const inv = try G.modInv(Big.fromU64(3), Big.fromU64(11));
        /// // inv == 4
        /// ```
        pub fn modInv(a: Big, m: Big) !Big {
            if (m.isZero() or m.isNegative()) return error.InvalidModulus;
            const a_pos = a.mod(m) catch unreachable;
            const res = egcd(a_pos, m);
            if (!res.g.eql(Big.one())) return error.NotInvertible;
            return res.x.mod(m);
        }
    };
}
