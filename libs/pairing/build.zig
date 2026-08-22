const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const traits_dep = b.dependency("zig_algebra_traits", .{
        .target = target,
        .optimize = optimize,
    });
    const traits_mod = traits_dep.module("zig-algebra-traits");

    const field_dep = b.dependency("zig_field", .{
        .target = target,
        .optimize = optimize,
    });
    const field_mod = field_dep.module("zig-field");

    const curve_dep = b.dependency("zig_curve", .{
        .target = target,
        .optimize = optimize,
    });
    const curve_mod = curve_dep.module("zig-curve");

    const pairing_mod = b.addModule("zig-pairing", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    pairing_mod.addImport("zig-algebra-traits", traits_mod);
    pairing_mod.addImport("zig-field", field_mod);
    pairing_mod.addImport("zig-curve", curve_mod);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zig-algebra-traits", traits_mod);
    test_module.addImport("zig-field", field_mod);
    test_module.addImport("zig-curve", curve_mod);
    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const example_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_module.addImport("zig-pairing", pairing_mod);
    const example = b.addExecutable(.{
        .name = "pairing-example",
        .root_module = example_module,
    });
    b.installArtifact(example);
}
