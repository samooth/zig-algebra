//! Simplified STARK prover/verifier: Fibonacci over M31.
//!
//! Demonstrates the full zig-algebra STARK stack:
//!   trace → constraint check → FRI commitment → verify
//!
//! The AIR (Algebraic Intermediate Representation) has one transition
//! constraint over two trace columns:
//!     a_{i+1} = a_i + b_i      (Fibonacci step)
//!     b_{i+1} = a_{i+1}        (shift register)
//! with public input a_0, b_0 and public output a_{n-1}.
//!
//! For pedagogical clarity this example skips the composition polynomial and
//! low-degree-extension steps of a full STARK; it proves proximity of the
//! *trace polynomial itself* via FRI, which is sufficient to show every
//! library in the stack working together.

const std = @import("std");

const nowNs = @import("zig-parallel").timing.nowNs;
const Transcript = @import("zig-transcript").Transcript;
const fri = @import("zig-fri");

// ---------------------------------------------------------------------------
// Minimal field: Mersenne-31 (matches BSV's preferred STARK field)
// ---------------------------------------------------------------------------

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
        return fromInt(a.value +% b.value);
    }
    pub fn mul(a: Self, b: Self) Self {
        return fromInt(@as(u64, a.value) *% b.value);
    }
    pub fn sub(a: Self, b: Self) Self {
        return fromInt(a.value +% Self.MODULUS -% b.value);
    }
    pub fn neg(a: Self) Self {
        return if (a.value == 0) zero() else fromInt(Self.MODULUS - a.value);
    }
    pub fn sqr(a: Self) Self {
        return mul(a, a);
    }
    pub fn inv(a: Self) Self {
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

// ---------------------------------------------------------------------------
// Trace generation
// ---------------------------------------------------------------------------

const Trace = struct {
    /// Column a: Fibonacci sequence values.
    a: []M31,
    /// Column b: shifted copy of a (b[i] = a[i+1]).
    b: []M31,

    fn deinit(self: *Trace, allocator: std.mem.Allocator) void {
        allocator.free(self.a);
        allocator.free(self.b);
    }
};

/// Generate a Fibonacci trace of length `n` starting from (a0, b0).
fn generateTrace(allocator: std.mem.Allocator, a0: M31, b0: M31, n: usize) !Trace {
    var a = try allocator.alloc(M31, n);
    var b = try allocator.alloc(M31, n);
    a[0] = a0;
    b[0] = b0;
    for (1..n) |i| {
        // Fibonacci transition: next_a = a + b, next_b = next_a (shift)
        a[i] = a[i - 1].add(b[i - 1]);
        b[i] = a[i];
    }
    return .{ .a = a, .b = b };
}

/// Check all transition constraints on a trace. Returns number of violations.
fn checkConstraints(trace: Trace) usize {
    var violations: usize = 0;
    for (1..trace.a.len) |i| {
        // Constraint: a[i] == a[i-1] + b[i-1]
        const expected = trace.a[i - 1].add(trace.b[i - 1]);
        if (!expected.eql(trace.a[i])) violations += 1;
        // Constraint: b[i] == a[i]
        if (!trace.a[i].eql(trace.b[i])) violations += 1;
    }
    return violations;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Use std.debug.print for output (Zig 0.16 removed std.io)

    const trace_len = 64; // power of 2 for FRI
    const num_queries = 30;

    std.debug.print("\n=== STARK Prover Demo: Fibonacci over M31 ===\n\n", .{});
    std.debug.print("Field: M31 (mod 2^31 - 1)\n", .{});
    std.debug.print("Trace length: {d} steps\n", .{trace_len});
    std.debug.print("FRI queries: {d}\n\n", .{num_queries});

    // Public inputs / outputs
    const a0 = M31.fromInt(3);
    const b0 = M31.fromInt(5);
    std.debug.print("Public input : a_0={d}, b_0={d}\n", .{ a0.toInt(), b0.toInt() });

    // 1. Generate honest trace.
    var trace = try generateTrace(gpa, a0, b0, trace_len);
    defer trace.deinit(gpa);

    const final_value = trace.a[trace_len - 1];
    std.debug.print("Public output: a_{d}={d}\n\n", .{ trace_len - 1, final_value.toInt() });

    // 2. Prover checks constraints locally before proving.
    const violations = checkConstraints(trace);
    if (violations != 0) {
        std.debug.print("ERROR: trace has {d} constraint violations!\n", .{violations});
        return error.InvalidTrace;
    }
    std.debug.print("[Prover] All {d} transition constraints satisfied.\n", .{2 * (trace_len - 1)});

    // 3. Combine columns into single polynomial evaluations for FRI.
    //    Simple approach: interleave a and b into one array of length 2n.
    const combined_len = 2 * trace_len;
    const combined = try gpa.alloc(M31, combined_len);
    defer gpa.free(combined);
    for (0..trace_len) |i| {
        combined[2 * i] = trace.a[i];
        combined[2 * i + 1] = trace.b[i];
    }

    // 4. Run FRI prove.
    const config = fri.Config{
        .domain_size = combined_len,
        .final_length = 4,
        .num_queries = num_queries,
    };

    std.debug.print("\n[Prover] Running FRI commit phase...\n", .{});
    const prove_start = nowNs();
    var prover_transcript = Transcript.init("stark-fib-demo-v1");
    var proof = try fri.prove(M31, gpa, &prover_transcript, combined, config);
    const prove_ns = nowNs() - prove_start;
    std.debug.print("[Prover] Proof generated in {d:.2} ms\n", .{
        @as(f64, @floatFromInt(prove_ns)) / 1e6,
    });
    defer proof.deinit(gpa);

    // Estimate proof size.
    var proof_bytes: usize = proof.layers.len * @sizeOf(@TypeOf(proof.layers[0].merkle_root));
    for (proof.final_evals) |fe| proof_bytes += fe.len;
    for (proof.queries) |q| {
        for (q.pairs) |p| proof_bytes += p.len;
        for (q.auth_paths) |path| proof_bytes += path.len * 32;
    }
    std.debug.print("[Prover] Estimated proof size: {d} bytes\n", .{proof_bytes});

    // 5. Verifier checks.
    std.debug.print("\n[Verifier] Verifying FRI proof...\n", .{});
    const verify_start = nowNs();
    var verifier_transcript = Transcript.init("stark-fib-demo-v1");
    const ok_honest = try fri.verify(M31, &verifier_transcript, &proof, config);
    const verify_ns = nowNs() - verify_start;
    std.debug.print("[Verifier] Verification time: {d:.3} ms\n", .{
        @as(f64, @floatFromInt(verify_ns)) / 1e6,
    });
    std.debug.print("[Verifier] Honest proof accepted: {}\n", .{ok_honest});

    if (!ok_honest) {
        std.debug.print("ERROR: honest proof rejected!\n", .{});
        return error.VerificationFailed;
    }

    // 6. Tamper detection: corrupt one query's pair and re-verify.
    std.debug.print("\n[Tamper] Corrupting first query pair...\n", .{});
    @constCast(&proof.queries[0].pairs[0][0]).* ^= 1;

    var tampered_verifier = Transcript.init("stark-fib-demo-v1");
    const ok_tampered = fri.verify(M31, &tampered_verifier, &proof, config) catch false;
    std.debug.print("[Tamper] Tampered proof accepted: {}\n", .{ok_tampered});

    if (ok_tampered) {
        std.debug.print("WARNING: tampering not detected (structural check only)\n", .{});
    } else {
        std.debug.print("[Tamper] Tampering correctly detected.\n", .{});
    }

    std.debug.print("\n=== Done ===\n", .{});
}
