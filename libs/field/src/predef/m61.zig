// SPDX-License-Identifier: MIT OR Apache-2.0

//! Mersenne-61: the largest Mersenne prime that fits in u64.
//!
//! `p = 2^61 - 1 = 2305843009213693951`
//!
//! Useful for very large FFTs (2^61 elements possible) and as a
//! fast alternative to 64-bit primes when 61 bits of precision suffice.

const zf = @import("../lib.zig");

pub const M61 = zf.Field(2305843009213693951);
