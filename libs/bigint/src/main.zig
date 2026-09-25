//! zig-bigint example

const std = @import("std");
const bigint = @import("root.zig");

pub fn main() !void {
    std.debug.print("=== zig-bigint example ===\n\n", .{});

    const Big = bigint.BigInt(16);
    const Gcd = bigint.ExtendedGcd(16);
    const ModExp = bigint.ModExp(16);
    const Prime = bigint.PrimalityTest(16);

    // Basic arithmetic
    const a = Big.fromU64(12345678901234567890);
    const b = Big.fromU64(9876543210987654321);

    std.debug.print("a = {}\n", .{a});
    std.debug.print("b = {}\n", .{b});
    std.debug.print("a + b = {}\n", .{try a.add(b)});
    std.debug.print("a - b = {}\n", .{try a.sub(b)});
    std.debug.print("a * b = {}\n", .{try a.mul(b)});

    // Division
    const qr = try a.divRem(b);
    std.debug.print("a / b = {} (remainder {})\n", .{ qr.q, qr.r });

    // Large number from string
    const large = try Big.fromString("123456789012345678901234567890");
    std.debug.print("\nlarge = {}\n", .{large});
    std.debug.print("large * 2 = {}\n", .{try large.mul(Big.fromU64(2))});

    // GCD
    const g = Gcd.egcd(a, b);
    std.debug.print("\ngcd(a, b) = {}\n", .{g.g});

    // Modular inverse
    const inv = try Gcd.modInv(Big.fromU64(3), Big.fromU64(11));
    std.debug.print("3^-1 mod 11 = {}\n", .{inv});

    // Modular exponentiation
    const me = try ModExp.modExpU64(Big.fromU64(2), 100, Big.fromU64(1000000007));
    std.debug.print("2^100 mod 1000000007 = {}\n", .{me});

    // Primality test
    const p = Big.fromU64(104729);
    const is_prime = try Prime.millerRabin(p, 7);
    std.debug.print("\n104729 is prime: {}\n", .{is_prime});

    const composite = Big.fromU64(91);
    const is_comp = try Prime.millerRabin(composite, 7);
    std.debug.print("91 is prime: {}\n", .{is_comp});

    // Negative numbers
    const neg = Big.fromI64(-42);
    std.debug.print("\n-42 = {}\n", .{neg});
    std.debug.print("abs(-42) = {}\n", .{neg.abs()});

    std.debug.print("\nAll operations completed successfully!\n", .{});
}
