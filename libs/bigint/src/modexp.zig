//! Modular exponentiation for BigInt.
//!
//! Provides binary (square-and-multiply) exponentiation for both
//! `BigInt`-sized exponents and `u64` exponents (the common case).
//!
//! # Quick Start
//! ```zig
//! const Big = BigInt(8);
//! const ME = ModExp(8);
//!
//! const base = Big.fromU64(2);
//! const exp  = Big.fromU64(100);
//! const mod  = Big.fromU64(1000000007);
//! const result = try ME.modExp(base, exp, mod);
//! // result == 2^100 mod 1000000007
//!
//! // Faster path for u64 exponents:
//! const result2 = try ME.modExpU64(base, 100, mod);
//! ```

const std = @import("std");
const bigint = @import("bigint.zig");
const gcd = @import("gcd.zig");

/// Modular exponentiation operations for a given BigInt precision.
///
/// `max_limbs` must match the precision of the `BigInt` instances you pass in.
pub fn ModExp(comptime max_limbs: usize) type {
    const Big = bigint.BigInt(max_limbs);
    const Gcd = gcd.ExtendedGcd(max_limbs);

    return struct {
        /// Modular exponentiation: `base^exp mod mod_val`.
        ///
        /// Uses binary exponentiation (square-and-multiply).
        ///
        /// # Errors
        /// - `error.DivisionByZero` if `mod_val == 0`.
        /// - `error.InvalidModulus` if `mod_val < 0`.
        ///
        /// # Negative Exponents
        /// If `exp < 0`, computes `(base^-1)^|exp| mod mod_val` using the modular inverse.
        pub fn modExp(base: Big, exp: Big, mod_val: Big) !Big {
            if (mod_val.isZero()) return error.DivisionByZero;
            if (mod_val.isNegative()) return error.InvalidModulus;
            if (exp.isNegative()) {
                const inv = try Gcd.modInv(base, mod_val);
                return modExp(inv, exp.neg(), mod_val);
            }

            var result = Big.one();
            var b = try base.mod(mod_val);
            var e = exp;

            while (!e.isZero()) {
                if ((e.limbs[0] & 1) == 1) {
                    result = try (try result.mul(b)).mod(mod_val);
                }
                b = try (try b.mul(b)).mod(mod_val);
                e = e.shr(1);
            }
            return result;
        }

        /// Modular exponentiation with a `u64` exponent (fast path).
        ///
        /// This avoids the overhead of `BigInt` exponent arithmetic.
        pub fn modExpU64(base: Big, exp: u64, mod_val: Big) !Big {
            if (mod_val.isZero()) return error.DivisionByZero;
            var result = Big.one();
            var b = try base.mod(mod_val);
            var e = exp;
            while (e > 0) {
                if (e & 1 == 1) {
                    result = try (try result.mul(b)).mod(mod_val);
                }
                b = try (try b.mul(b)).mod(mod_val);
                e >>= 1;
            }
            return result;
        }
    };
}
