//! Example usage of zig-algebra-traits

const std = @import("std");
const traits = @import("root.zig");

// ============================================================================
// Example: A minimal prime field F_7
// ============================================================================

const F7 = struct {
    const Self = @This();

    value: u64,

    pub const modulus: u64 = 7;
    pub const characteristic: u64 = 7;
    pub const order: u64 = 7;

    pub fn zero() Self {
        return .{ .value = 0 };
    }

    pub fn one() Self {
        return .{ .value = 1 };
    }

    pub fn fromInt(x: u64) Self {
        return .{ .value = x % modulus };
    }

    pub fn toInt(self: Self) u64 {
        return self.value;
    }

    pub fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
    }

    pub fn neq(a: Self, b: Self) bool {
        return !eql(a, b);
    }

    pub fn add(a: Self, b: Self) Self {
        return fromInt(a.value + b.value);
    }

    pub fn sub(a: Self, b: Self) Self {
        return fromInt(a.value + (modulus - b.value % modulus));
    }

    pub fn neg(a: Self) Self {
        return if (a.value == 0) zero() else fromInt(modulus - a.value);
    }

    pub fn mul(a: Self, b: Self) Self {
        return fromInt(a.value * b.value);
    }

    pub fn inv(a: Self) Self {
        std.debug.assert(!a.isZero());
        // Fermat's little theorem: a^(p-2) mod p
        return pow(a, modulus - 2);
    }

    pub fn div(a: Self, b: Self) Self {
        return mul(a, inv(b));
    }

    pub fn pow(base: Self, exp: u64) Self {
        var result = one();
        var b = base;
        var e = exp;
        while (e > 0) {
            if (e & 1 == 1) result = mul(result, b);
            b = mul(b, b);
            e >>= 1;
        }
        return result;
    }

    pub fn isZero(self: Self) bool {
        return self.value == 0;
    }

    pub fn random() Self {
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        return fromInt(prng.random().int(u64));
    }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}", .{self.value});
    }
};

// ============================================================================
// Example: A minimal polynomial over F7
// ============================================================================

const PolyF7 = struct {
    const Self = @import("std").ArrayList(F7);
    pub const BaseField = F7;

    coeffs: Self,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self.init(allocator);
    }

    pub fn fromCoeffs(coeffs: []const F7, allocator: std.mem.Allocator) !Self {
        var result = Self.init(allocator);
        try result.appendSlice(coeffs);
        return result;
    }

    pub fn degree(self: Self) usize {
        var d = self.items.len;
        while (d > 0 and self.items[d - 1].isZero()) d -= 1;
        return if (d == 0) 0 else d - 1;
    }

    pub fn coeff(self: Self, i: usize) F7 {
        return if (i < self.items.len) self.items[i] else F7.zero();
    }

    pub fn add(a: Self, b: Self, allocator: std.mem.Allocator) !Self {
        const max_len = @max(a.items.len, b.items.len);
        var result = Self.init(allocator);
        try result.resize(max_len);
        for (0..max_len) |i| {
            result.items[i] = F7.add(a.coeff(i), b.coeff(i));
        }
        return result;
    }

    pub fn eval(self: Self, x: F7) F7 {
        return traits.evalPolyHorner(F7, self.items, x);
    }

    pub fn eql(a: Self, b: Self) bool {
        const max_len = @max(a.items.len, b.items.len);
        for (0..max_len) |i| {
            if (!F7.eql(a.coeff(i), b.coeff(i))) return false;
        }
        return true;
    }
};

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("=== zig-algebra-traits example ===\n\n", .{});

    // Verify F7 satisfies Field trait
    traits.assertField(F7);
    try stdout.print("F7 satisfies Field trait\n", .{});

    // Verify F7 satisfies Ring trait
    traits.assertRing(F7);
    try stdout.print("F7 satisfies Ring trait\n", .{});

    // Basic operations
    const a = F7.fromInt(3);
    const b = F7.fromInt(5);

    try stdout.print("a = {}, b = {}\n", .{ a, b });
    try stdout.print("a + b = {}\n", .{F7.add(a, b)});
    try stdout.print("a * b = {}\n", .{F7.mul(a, b)});
    try stdout.print("a - b = {}\n", .{F7.sub(a, b)});
    try stdout.print("-a = {}\n", .{F7.neg(a)});
    try stdout.print("a^-1 = {}\n", .{F7.inv(a)});
    try stdout.print("a / b = {}\n", .{F7.div(a, b)});
    try stdout.print("a^3 = {}\n", .{F7.pow(a, 3)});

    // Test generic pow from traits
    const p = traits.pow(F7, a, 4);
    try stdout.print("generic pow(a, 4) = {}\n", .{p});

    // Test sum
    const items = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    const s = traits.sum(F7, &items);
    try stdout.print("sum([1,2,3]) = {}\n", .{s});

    // Test product
    const pr = traits.product(F7, &items);
    try stdout.print("product([1,2,3]) = {}\n", .{pr});

    // Polynomial example
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const coeffs = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(1) }; // 1 + 2x + x^2
    const poly = try PolyF7.fromCoeffs(&coeffs, allocator);
    defer poly.deinit();

    try stdout.print("\nPolynomial: 1 + 2x + x^2\n", .{});
    try stdout.print("degree = {}\n", .{poly.degree()});
    try stdout.print("eval(2) = {}\n", .{poly.eval(F7.fromInt(2))});

    try stdout.print("\nAll trait assertions passed!\n", .{});
}
