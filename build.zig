const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Test step that runs all library tests
    const test_step = b.step("test", "Run all library tests");

    // algebra-traits
    const traits_mod = b.addModule("zig-algebra-traits", .{
        .root_source_file = b.path("libs/algebra-traits/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const traits_test_module = b.createModule(.{
        .root_source_file = b.path("libs/algebra-traits/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const traits_tests = b.addTest(.{
        .name = "zig-algebra-traits-tests",
        .root_module = traits_test_module,
    });
    test_step.dependOn(&traits_tests.step);

    // bigint
    const bigint_mod = b.addModule("zig-bigint", .{
        .root_source_file = b.path("libs/bigint/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    bigint_mod.addImport("zig-algebra-traits", traits_mod);
    const bigint_test_module = b.createModule(.{
        .root_source_file = b.path("libs/bigint/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    bigint_test_module.addImport("zig-algebra-traits", traits_mod);
    const bigint_tests = b.addTest(.{
        .name = "zig-bigint-tests",
        .root_module = bigint_test_module,
    });
    test_step.dependOn(&bigint_tests.step);

    // hash
    const hash_mod = b.addModule("zig-hash", .{
        .root_source_file = b.path("libs/hash/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    hash_mod.addImport("zig-algebra-traits", traits_mod);
    const hash_test_module = b.createModule(.{
        .root_source_file = b.path("libs/hash/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    hash_test_module.addImport("zig-algebra-traits", traits_mod);
    const hash_tests = b.addTest(.{
        .name = "zig-hash-tests",
        .root_module = hash_test_module,
    });
    test_step.dependOn(&hash_tests.step);

    // rng
    const rng_mod = b.addModule("zig-rng", .{
        .root_source_file = b.path("libs/rng/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    rng_mod.addImport("zig-algebra-traits", traits_mod);
    rng_mod.addImport("zig-hash", hash_mod);
    const rng_test_module = b.createModule(.{
        .root_source_file = b.path("libs/rng/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    rng_test_module.addImport("zig-algebra-traits", traits_mod);
    rng_test_module.addImport("zig-hash", hash_mod);
    const rng_tests = b.addTest(.{
        .name = "zig-rng-tests",
        .root_module = rng_test_module,
    });
    test_step.dependOn(&rng_tests.step);

    // field
    const field_mod = b.addModule("zig-field", .{
        .root_source_file = b.path("libs/field/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    field_mod.addImport("zig-bigint", bigint_mod);
    const field_test_module = b.createModule(.{
        .root_source_file = b.path("libs/field/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    field_test_module.addImport("zig-bigint", bigint_mod);
    const field_tests = b.addTest(.{
        .name = "zig-field-tests",
        .root_module = field_test_module,
    });
    test_step.dependOn(&field_tests.step);

    // binary-field
    const binary_field_mod = b.addModule("zig-binary-field", .{
        .root_source_file = b.path("libs/binary-field/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    binary_field_mod.addImport("zig-algebra-traits", traits_mod);
    binary_field_mod.addImport("zig-hash", hash_mod);
    const binary_field_test_module = b.createModule(.{
        .root_source_file = b.path("libs/binary-field/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    binary_field_test_module.addImport("zig-algebra-traits", traits_mod);
    binary_field_test_module.addImport("zig-hash", hash_mod);
    const binary_field_tests = b.addTest(.{
        .name = "zig-binary-field-tests",
        .root_module = binary_field_test_module,
    });
    test_step.dependOn(&binary_field_tests.step);

    // curve
    const curve_mod = b.addModule("zig-curve", .{
        .root_source_file = b.path("libs/curve/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    curve_mod.addImport("zig-field", field_mod);
    curve_mod.addImport("zig-hash", hash_mod);
    const curve_test_module = b.createModule(.{
        .root_source_file = b.path("libs/curve/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    curve_test_module.addImport("zig-field", field_mod);
    curve_test_module.addImport("zig-hash", hash_mod);
    const curve_tests = b.addTest(.{
        .name = "zig-curve-tests",
        .root_module = curve_test_module,
    });
    test_step.dependOn(&curve_tests.step);

    // merkle
    const merkle_mod = b.addModule("zig-merkle", .{
        .root_source_file = b.path("libs/merkle/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    merkle_mod.addImport("zig-algebra-traits", traits_mod);
    merkle_mod.addImport("zig-hash", hash_mod);
    const merkle_test_module = b.createModule(.{
        .root_source_file = b.path("libs/merkle/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    merkle_test_module.addImport("zig-algebra-traits", traits_mod);
    merkle_test_module.addImport("zig-hash", hash_mod);
    const merkle_tests = b.addTest(.{
        .name = "zig-merkle-tests",
        .root_module = merkle_test_module,
    });
    test_step.dependOn(&merkle_tests.step);

    // ntt
    const ntt_mod = b.addModule("zig-ntt", .{
        .root_source_file = b.path("libs/ntt/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntt_mod.addImport("zig-algebra-traits", traits_mod);
    ntt_mod.addImport("zig-field", field_mod);
    const ntt_test_module = b.createModule(.{
        .root_source_file = b.path("libs/ntt/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntt_test_module.addImport("zig-algebra-traits", traits_mod);
    ntt_test_module.addImport("zig-field", field_mod);
    const ntt_tests = b.addTest(.{
        .name = "zig-ntt-tests",
        .root_module = ntt_test_module,
    });
    test_step.dependOn(&ntt_tests.step);

    // poly
    const poly_mod = b.addModule("zig-poly", .{
        .root_source_file = b.path("libs/poly/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    poly_mod.addImport("zig-algebra-traits", traits_mod);
    const poly_test_module = b.createModule(.{
        .root_source_file = b.path("libs/poly/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    poly_test_module.addImport("zig-algebra-traits", traits_mod);
    const poly_tests = b.addTest(.{
        .name = "zig-poly-tests",
        .root_module = poly_test_module,
    });
    test_step.dependOn(&poly_tests.step);

    // parallel
    _ = b.addModule("zig-parallel", .{
        .root_source_file = b.path("libs/parallel/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parallel_test_module = b.createModule(.{
        .root_source_file = b.path("libs/parallel/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parallel_tests = b.addTest(.{
        .name = "zig-parallel-tests",
        .root_module = parallel_test_module,
    });
    test_step.dependOn(&parallel_tests.step);

    // serialization
    _ = b.addModule("zig-serialization", .{
        .root_source_file = b.path("libs/serialization/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const serialization_test_module = b.createModule(.{
        .root_source_file = b.path("libs/serialization/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const serialization_tests = b.addTest(.{
        .name = "zig-serialization-tests",
        .root_module = serialization_test_module,
    });
    test_step.dependOn(&serialization_tests.step);
}
