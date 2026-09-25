//! Simplified STARK prover/verifier: Fibonacci over Goldilocks.
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

const Goldilocks = @import("zig-field").Goldilocks;

// ---------------------------------------------------------------------------
// Trace generation
// ---------------------------------------------------------------------------

const Trace = struct {
    /// Column a: Fibonacci sequence values.
    a: []Goldilocks,
    /// Column b: shifted copy of a (b[i] = a[i+1]).
    b: []Goldilocks,

    fn deinit(self: *Trace, allocator: std.mem.Allocator) void {
        allocator.free(self.a);
        allocator.free(self.b);
    }
};

/// Generate a Fibonacci trace of length `n` starting from (a0, b0).
fn generateTrace(allocator: std.mem.Allocator, a0: Goldilocks, b0: Goldilocks, n: usize) !Trace {
    var a = try allocator.alloc(Goldilocks, n);
    var b = try allocator.alloc(Goldilocks, n);
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

    std.debug.print("\n=== STARK Prover Demo: Fibonacci over Goldilocks ===\n\n", .{});
    std.debug.print("Field: Goldilocks (mod 2^64 - 2^32 + 1)\n", .{});
    std.debug.print("Trace length: {d} steps\n", .{trace_len});
    std.debug.print("FRI queries: {d}\n\n", .{num_queries});

    // Public inputs / outputs
    const a0 = Goldilocks.fromInt(3);
    const b0 = Goldilocks.fromInt(5);
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

    // 3. Use the trace column as a low-degree polynomial and evaluate it on
    //    the FRI domain. This keeps the demo honest without pretending to
    //    implement a full composition polynomial and low-degree extension.
    const combined_len = trace_len;
    const combined_coeffs = try gpa.alloc(Goldilocks, combined_len);
    defer gpa.free(combined_coeffs);
    for (0..trace_len) |i| {
        combined_coeffs[i] = trace.a[i];
    }

    const domain = fri.Domain(Goldilocks).init(Goldilocks, 7);
    const evaluations = try gpa.alloc(Goldilocks, 1 << 7);
    defer gpa.free(evaluations);
    for (0..evaluations.len) |i| {
        const x = domain.at(i);
        var value = Goldilocks.zero();
        var j: usize = combined_len;
        while (j > 0) {
            j -= 1;
            value = value.mul(x).add(combined_coeffs[j]);
        }
        evaluations[i] = value;
    }

    // 4. Run FRI prove.
    const config = fri.Config{
        .log_domain = 7,
        .log_initial_degree = 6,
        .log_final = 5,
        .log_residual_degree = 4,
        .num_queries = num_queries,
    };

    std.debug.print("\n[Prover] Running FRI commit phase...\n", .{});
    const prove_start = nowNs();
    var prover_transcript = Transcript.init("stark-fib-demo-v1");
    var proof = try fri.prove(Goldilocks, gpa, &prover_transcript, evaluations, config);
    const prove_ns = nowNs() - prove_start;
    std.debug.print("[Prover] Proof generated in {d:.2} ms\n", .{
        @as(f64, @floatFromInt(prove_ns)) / 1e6,
    });
    defer proof.deinit(gpa);

    // Estimate proof size.
    var proof_bytes: usize = proof.layers.len * @sizeOf(@TypeOf(proof.layers[0].merkle_root));
    for (proof.residual) |residual| proof_bytes += residual.len;
    for (proof.queries) |q| {
        for (q.values) |values| proof_bytes += values.len;
        for (q.paths) |path| proof_bytes += path.len * 32;
    }
    std.debug.print("[Prover] Estimated proof size: {d} bytes\n", .{proof_bytes});

    // 5. Verifier checks.
    std.debug.print("\n[Verifier] Verifying FRI proof...\n", .{});
    const verify_start = nowNs();
    var verifier_transcript = Transcript.init("stark-fib-demo-v1");
    const ok_honest = try fri.verify(Goldilocks, &verifier_transcript, &proof, config);
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
    @constCast(&proof.queries[0].values[0][0]).* ^= 1;

    var tampered_verifier = Transcript.init("stark-fib-demo-v1");
    const ok_tampered = fri.verify(Goldilocks, &tampered_verifier, &proof, config) catch false;
    std.debug.print("[Tamper] Tampered proof accepted: {}\n", .{ok_tampered});

    if (ok_tampered) {
        std.debug.print("WARNING: tampering not detected (structural check only)\n", .{});
    } else {
        std.debug.print("[Tamper] Tampering correctly detected.\n", .{});
    }

    std.debug.print("\n=== Done ===\n", .{});
}
