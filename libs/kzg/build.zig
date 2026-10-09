const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const field_dep = b.dependency("zig_field", .{
        .target = target,
        .optimize = optimize,
    });
    const field_mod = field_dep.module("zig-field");

    const traits_dep = b.dependency("zig_algebra_traits", .{
        .target = target,
        .optimize = optimize,
    });
    const traits_mod = traits_dep.module("zig-algebra-traits");

    const curve_dep = b.dependency("zig_curve", .{
        .target = target,
        .optimize = optimize,
    });
    const curve_mod = curve_dep.module("zig-curve");

    const pairing_dep = b.dependency("zig_pairing", .{
        .target = target,
        .optimize = optimize,
    });
    const pairing_mod = pairing_dep.module("zig-pairing");

    const kzg_mod = b.addModule("zig-kzg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kzg_mod.addImport("zig-field", field_mod);
    kzg_mod.addImport("zig-curve", curve_mod);
    kzg_mod.addImport("zig-pairing", pairing_mod);
    kzg_mod.addImport("zig-algebra-traits", traits_mod);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zig-field", field_mod);
    test_module.addImport("zig-curve", curve_mod);
    test_module.addImport("zig-pairing", pairing_mod);
    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .name = "kzg-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-kzg", .module = kzg_mod },
                .{ .name = "zig-curve", .module = curve_mod },
            },
        }),
    });
    b.installArtifact(example);
}
