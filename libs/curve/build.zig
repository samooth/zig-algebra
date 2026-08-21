const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const field_dep = b.dependency("zig_field", .{
        .target = target,
        .optimize = optimize,
    });
    const field_mod = field_dep.module("zig-field");

    const hash_dep = b.dependency("zig_hash", .{
        .target = target,
        .optimize = optimize,
    });
    const hash_mod = hash_dep.module("zig-hash");

    const lib = b.addModule("zig-curve", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.addImport("zig-field", field_mod);
    lib.addImport("zig-hash", hash_mod);

    const test_step = b.step("test", "Run library tests");
    const lib_tests = b.addTest(.{
        .name = "zig-curve-tests",
        .root_module = lib,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    const bn254_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/bn254_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-curve", .module = lib },
        },
    });
    const bn254_tests = b.addTest(.{
        .name = "bn254-tests",
        .root_module = bn254_test_mod,
    });
    const run_bn254_tests = b.addRunArtifact(bn254_tests);
    test_step.dependOn(&run_bn254_tests.step);

    const bls12_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/bls12_381_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-curve", .module = lib },
        },
    });
    const bls12_tests = b.addTest(.{
        .name = "bls12-381-tests",
        .root_module = bls12_test_mod,
    });
    const run_bls12_tests = b.addRunArtifact(bls12_tests);
    test_step.dependOn(&run_bls12_tests.step);

    const pasta_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/pasta_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-curve", .module = lib },
        },
    });
    const pasta_tests = b.addTest(.{
        .name = "pasta-tests",
        .root_module = pasta_test_mod,
    });
    const run_pasta_tests = b.addRunArtifact(pasta_tests);
    test_step.dependOn(&run_pasta_tests.step);

    const h2c_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/hash_to_curve_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-curve", .module = lib },
        },
    });
    const h2c_tests = b.addTest(.{
        .name = "hash-to-curve-tests",
        .root_module = h2c_test_mod,
    });
    const run_h2c_tests = b.addRunArtifact(h2c_tests);
    test_step.dependOn(&run_h2c_tests.step);

    const fmt_check = b.addFmt(.{ .paths = &.{"."}, .check = true });
    const fmt_step = b.step("fmt", "Check code formatting");
    fmt_step.dependOn(&fmt_check.step);
}
