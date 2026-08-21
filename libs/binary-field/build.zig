const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const traits_dep = b.dependency("zig_algebra_traits", .{
        .target = target,
        .optimize = optimize,
    });
    const traits_mod = traits_dep.module("zig-algebra-traits");

    const hash_dep = b.dependency("zig_hash", .{
        .target = target,
        .optimize = optimize,
    });
    const hash_mod = hash_dep.module("zig-hash");

    const binary_field_mod = b.addModule("zig-binary-field", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    binary_field_mod.addImport("zig-algebra-traits", traits_mod);
    binary_field_mod.addImport("zig-hash", hash_mod);

    const test_step = b.step("test", "Run unit tests");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zig-algebra-traits", traits_mod);
    test_module.addImport("zig-hash", hash_mod);
    const root_test = b.addTest(.{
        .root_module = test_module,
    });
    const run_root_tests = b.addRunArtifact(root_test);
    test_step.dependOn(&run_root_tests.step);
}
