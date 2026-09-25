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

    pub fn fromInt(x: u256) Self {
        return .{ .value = @intCast(x % @as(u256, modulus)) };
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

    pub fn identity() Self {
        return one();
    }

    pub fn inverse(a: Self) Self {
        return inv(a);
    }

    pub fn inv(a: Self) Self {
        std.debug.assert(!a.isZero());
        return pow(a, modulus - 2);
    }

    pub fn div(a: Self, b: Self) Self {
        return mul(a, inv(b));
    }

    pub fn pow(base: Self, exp: u256) Self {
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
        return fromInt(0x5eed);
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
    const Self = @This();
    const List = std.ArrayList(F7);
    pub const BaseField = F7;

    coeffs: List,

    pub fn init(allocator: std.mem.Allocator) Self {
        _ = allocator;
        return .{ .coeffs = .empty };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.coeffs.deinit(allocator);
    }

    pub fn fromCoeffs(items: []const F7, allocator: std.mem.Allocator) !Self {
        var result = init(allocator);
        errdefer result.deinit(allocator);
        try result.coeffs.appendSlice(allocator, items);
        return result;
    }

    pub fn degree(self: Self) usize {
        var d = self.coeffs.items.len;
        while (d > 0 and self.coeffs.items[d - 1].isZero()) d -= 1;
        return if (d == 0) 0 else d - 1;
    }

    pub fn coeff(self: Self, i: usize) F7 {
        return if (i < self.coeffs.items.len) self.coeffs.items[i] else F7.zero();
    }

    pub fn add(a: Self, b: Self, allocator: std.mem.Allocator) !Self {
        const max_len = @max(a.coeffs.items.len, b.coeffs.items.len);
        var result = init(allocator);
        errdefer result.deinit(allocator);
        try result.coeffs.resize(allocator, max_len);
        for (0..max_len) |i| {
            result.coeffs.items[i] = F7.add(a.coeff(i), b.coeff(i));
        }
        return result;
    }

    pub fn eval(self: Self, x: F7) F7 {
        return traits.evalPolyHorner(F7, self.coeffs.items, x);
    }

    pub fn eql(a: Self, b: Self) bool {
        const max_len = @max(a.coeffs.items.len, b.coeffs.items.len);
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
    std.debug.print("=== zig-algebra-traits example ===\n\n", .{});

    // Verify F7 satisfies Field trait
    traits.assertField(F7);
    std.debug.print("F7 satisfies Field trait\n", .{});

    // Verify F7 satisfies Ring trait
    traits.assertRing(F7);
    std.debug.print("F7 satisfies Ring trait\n", .{});

    // Basic operations
    const a = F7.fromInt(3);
    const b = F7.fromInt(5);

    std.debug.print("a = {}, b = {}\n", .{ a, b });
    std.debug.print("a + b = {}\n", .{F7.add(a, b)});
    std.debug.print("a * b = {}\n", .{F7.mul(a, b)});
    std.debug.print("a - b = {}\n", .{F7.sub(a, b)});
    std.debug.print("-a = {}\n", .{F7.neg(a)});
    std.debug.print("a^-1 = {}\n", .{F7.inv(a)});
    std.debug.print("a / b = {}\n", .{F7.div(a, b)});
    std.debug.print("a^3 = {}\n", .{F7.pow(a, 3)});

    // Test generic pow from traits
    const p = traits.pow(F7, a, 4);
    std.debug.print("generic pow(a, 4) = {}\n", .{p});

    // Test sum
    const items = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    const s = traits.sum(F7, &items);
    std.debug.print("sum([1,2,3]) = {}\n", .{s});

    // Test product
    const pr = traits.product(F7, &items);
    std.debug.print("product([1,2,3]) = {}\n", .{pr});

    // Polynomial example
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const coeffs = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(1) }; // 1 + 2x + x^2
    var poly = try PolyF7.fromCoeffs(&coeffs, allocator);
    defer poly.deinit(allocator);

    std.debug.print("\nPolynomial: 1 + 2x + x^2\n", .{});
    std.debug.print("degree = {}\n", .{poly.degree()});
    std.debug.print("eval(2) = {}\n", .{poly.eval(F7.fromInt(2))});

    std.debug.print("\nAll trait assertions passed!\n", .{});
}
