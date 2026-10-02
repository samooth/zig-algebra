const std = @import("std");

/// Foreign targets whose test binaries `cross-check` compiles without running.
///
/// The reason this step exists: a test that compiles on the host and fails to
/// *compile* on another OS is invisible to `zig build test`, because the error
/// is in a branch the host never takes. `libs/rng/src/csprng.zig` called
/// `BCryptGenRandom(null, ...)` against a `windows.HANDLE` (`*anyopaque`), which
/// a bare `null` does not coerce to in Zig 0.16 -- Linux, macOS and every local
/// run were green, and only the Windows CI job could see it. That is the same
/// blindness as the characteristic-2 fold, in a different direction: here the
/// Linux-only runs are the ones that cannot fail.
///
/// Compiling is enough; running would need the foreign runner. `macos` and
/// `windows` are both covered because a canceled macOS job is an open question,
/// not a pass.
const cross_targets = [_][]const u8{ "x86_64-windows-gnu", "aarch64-macos" };

/// Libraries that ship a `src/main.zig` example executable.
///
/// Declared rather than probed: a step that references a missing root source
/// fails the build, and filesystem probing during configure is a worse trade
/// than a list. `cross_register` turns each into a real executable for each
/// foreign target, which is what makes requirement 11 hold -- until now those
/// eight files were reachable by `cd libs/<name> && zig build install` and by
/// nothing else, which is how `libs/rng/src/main.zig` kept a
/// `std.debug.assert` that no gate had ever compiled.
const libs_with_example = [_][:0]const u8{
    "zig-algebra-traits",
    "zig-bigint",
    "zig-hash",
    "zig-linalg",
    "zig-merkle",
    "zig-pairing",
    "zig-poly",
    "zig-rng",
};

/// Set in `build` before the first `lib()` call. A file-scope `var` rather than
/// a parameter on `lib()`, which has seventeen call sites and none of them care
/// about cross-compilation.
var cross_step: ?*std.Build.Step = null;

/// Files under a library's `tests/` directory that are **not** test binaries.
///
/// Everything else in `libs/*/tests/` is wired into `test_step` by
/// `wire_tests_roots`, so a newly added test file runs by default. The
/// exemption list exists only for sources that live in `tests/` but are driven
/// by another step; the default is deliberately "it runs" rather than "it is
/// quietly skipped", because the alternative is the blindness this function
/// exists to close.
const non_test_sources = [_][2][]const u8{
    .{ "field", "benchmark.zig" },
    .{ "field", "fuzz.zig" },
};

/// Wire every `tests/*.zig` of a library into `test_step`.
///
/// **The root step used to run only the inline `src/` tests, so CI opened zero
/// files under `libs/*/tests/`.** Two P0 findings came out of that directory in
/// one round -- four public `hash` methods that did not compile, and
/// `Montgomery`'s wrong inverse for any modulus with zero headroom -- and the
/// gate that reported 421/421 green never opened either test.
///
/// `build.zig:45` already said the step "actually executes the tests", which
/// resolved *actually executes* without resolving *which tests*. This closes
/// the second half. The test roots are given exactly one import, their own
/// library module, which is what every one of them uses.
fn wire_tests_roots(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime module_name: []const u8,
    root_source: []const u8,
    mod: *std.Build.Module,
) void {
    // `libs/field/src/lib.zig` -> `libs/field`
    const src_dir = std.fs.path.dirname(root_source) orelse return;
    const lib_dir = std.fs.path.dirname(src_dir) orelse return;

    const io = b.graph.io;
    // Iterate the `tests/` directory itself, not the library directory: the
    // latter also holds `build.zig`, and a build script is not a test root.
    const tests_dir = std.fs.path.join(b.allocator, &.{ lib_dir, "tests" }) catch |err| {
        std.debug.panic("cannot build the tests path for {s}: {s}", .{ lib_dir, @errorName(err) });
    };
    // A library without a `tests/` directory is the normal case, so that one
    // error returns quietly. Anything else means the directory exists and
    // cannot be read, which is a build problem and must not be swallowed.
    var dir = std.Io.Dir.cwd().openDir(io, tests_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => std.debug.panic("cannot read {s}: {s}", .{ tests_dir, @errorName(err) }),
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |err| {
        std.debug.panic("cannot iterate {s}: {s}", .{ tests_dir, @errorName(err) });
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        var exempt = false;
        for (non_test_sources) |pair| {
            if (std.mem.eql(u8, pair[0], std.fs.path.basename(lib_dir)) and
                std.mem.eql(u8, pair[1], entry.name))
            {
                exempt = true;
                break;
            }
        }
        if (exempt) continue;

        const root = std.fs.path.join(b.allocator, &.{ lib_dir, "tests", entry.name }) catch |err| {
            std.debug.panic("cannot build a path for {s}: {s}", .{ entry.name, @errorName(err) });
        };
        const stem = entry.name[0 .. entry.name.len - ".zig".len];
        const tm = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        });
        tm.addImport(module_name, mod);
        const tb = b.addTest(.{
            .name = b.fmt("{s}-{s}-tests", .{ module_name, stem }),
            .root_module = tm,
        });
        test_step.dependOn(&b.addRunArtifact(tb).step);
    }
}

/// Create the module for a library, register its unit-test binary, and wire a
/// run step into `test_step` so `zig build test` actually executes the tests
/// (not merely compiles them).
fn lib(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime module_name: []const u8,
    root_source: []const u8,
    imports: []const struct { []const u8, *std.Build.Module },
) *std.Build.Module {
    const mod = b.addModule(module_name, .{
        .root_source_file = b.path(root_source),
        .target = target,
        .optimize = optimize,
    });
    const test_module = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = target,
        .optimize = optimize,
    });
    for (imports) |imp| {
        mod.addImport(imp[0], imp[1]);
        test_module.addImport(imp[0], imp[1]);
    }
    if (target.result.os.tag == .windows and std.mem.eql(u8, module_name, "zig-rng")) {
        mod.linkSystemLibrary("bcrypt", .{});
        test_module.linkSystemLibrary("bcrypt", .{});
    }
    const tests = b.addTest(.{
        .name = module_name ++ "-tests",
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
    wire_tests_roots(b, test_step, target, optimize, module_name, root_source, mod);
    var has_example = false;
    for (libs_with_example) |name| {
        if (std.mem.eql(u8, name, module_name)) has_example = true;
    }
    cross_register(b, module_name, root_source, imports, mod, has_example);
    return mod;
}

/// Compile `module_name`'s test binary for every foreign target in
/// `cross_targets`, and attach it to `cross-check`.
///
/// Separate modules rather than reusing the host one, because the target is
/// baked into the module. Installing is how you ask the build system to
/// *produce* an artifact without running it.
fn cross_register(
    b: *std.Build,
    module_name: []const u8,
    root_source: []const u8,
    imports: []const struct { []const u8, *std.Build.Module },
    self_mod: *std.Build.Module,
    has_example: bool,
) void {
    for (cross_targets) |triple| {
        const query = std.Target.Query.parse(.{
            .arch_os_abi = triple,
            // Diagnostics are omitted deliberately: a bad triple should fail the
            // step loudly, not be swallowed.
            // A plain literal: the triple is a source constant, so a dynamic
            // message would buy nothing.
        }) catch @panic("cross-check: unparseable target triple in cross_targets");
        const ct = b.resolveTargetQuery(query);
        const cm = b.createModule(.{
            .root_source_file = b.path(root_source),
            .target = ct,
            .optimize = .Debug,
        });
        for (imports) |imp| cm.addImport(imp[0], imp[1]);
        const ctests = b.addTest(.{
            .name = b.fmt("{s}-{s}-tests", .{ module_name, triple }),
            .root_module = cm,
        });
        if (has_example) {
            // `libs/<name>/src/root.zig` -> `libs/<name>/src/main.zig`
            const dir = root_source[0 .. root_source.len - "root.zig".len];
            const example_source = std.fmt.allocPrint(
                b.allocator,
                "{s}main.zig",
                .{dir},
            ) catch @panic("cross-check: out of memory building the example path");
            const em = b.createModule(.{
                .root_source_file = b.path(example_source),
                .target = ct,
                .optimize = .Debug,
            });
            for (imports) |imp| em.addImport(imp[0], imp[1]);
            em.addImport(module_name, self_mod);
            // `hash`'s example also needs `zig-field`, which the library itself
            // does not import: its demo used to declare a hand-rolled field
            // interface instead, 17 methods of it, one of them an
            // `invChecked` that had never been executed.
            if (std.mem.eql(u8, module_name, "zig-hash") or
                std.mem.eql(u8, module_name, "zig-rng"))
            {
                // Built from the local path rather than a dependency: the root
                // manifest declares no dependencies and creates every library
                // module from a path.
                const bm = b.createModule(.{
                    .root_source_file = b.path("libs/bigint/src/root.zig"),
                    .target = ct,
                    .optimize = .Debug,
                });
                const fm = b.createModule(.{
                    .root_source_file = b.path("libs/field/src/lib.zig"),
                    .target = ct,
                    .optimize = .Debug,
                });
                fm.addImport("zig-bigint", bm);
                em.addImport("zig-field", fm);
            }
            const eexe = b.addExecutable(.{
                .name = b.fmt("{s}-{s}-example", .{ module_name, triple }),
                .root_module = em,
            });
            const einst = b.addInstallArtifact(eexe, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("cross/{s}", .{triple}) } },
            });
            cross_step.?.dependOn(&einst.step);
        }
        // `install` forces compilation and links, but never spawns.
        const inst = b.addInstallArtifact(ctests, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("cross/{s}", .{triple}) } },
        });
        cross_step.?.dependOn(&inst.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Test step that runs all library tests
    const test_step = b.step("test", "Run all library tests");

    // Compiles every library's test binary for `cross_targets` without running
    // it. See the comment on `cross_targets` for the bug that motivates it.
    cross_step = b.step("cross-check", "Compile all test binaries for foreign targets (no run)");

    // Assert ledger gate. See docs/assert-ledger.md for the convention.
    // Fails if the tree contains an `std.debug.assert` the committed ledger
    // does not account for, so a new precondition on a public entry point
    // cannot land unnoticed.
    const assert_ledger = b.step("assert-check", "Verify the assert ledger is in sync with the tree");
    {
        const verify = b.addSystemCommand(&.{"python3"});
        verify.addFileArg(b.path("scripts/assert_verify.py"));
        verify.addArgs(&.{ "--root", "libs", "--ledger", "docs/assert_ledger.json" });
        verify.has_side_effects = true;
        assert_ledger.dependOn(&verify.step);
    }

    // AUDIT.md is a register of open items, and a register fails silently: a row
    // can sit open with a valid-looking table around it and nothing complains.
    // This step makes it a gate. Every row must name the observable that was
    // checked, a decision row must name an owner, the declared counts must
    // match the rows, and every `git show` in the document must resolve.
    const audit_ledger = b.step("audit-check", "Verify the AUDIT.md register holds up as a gate");
    {
        const verify = b.addSystemCommand(&.{"python3"});
        verify.addFileArg(b.path("scripts/audit_verify.py"));
        verify.addArgs(&.{ "--audit", "AUDIT.md" });
        verify.has_side_effects = true;
        audit_ledger.dependOn(&verify.step);
    }

    // The constant-time judgements, as a gate. A count says how many conditional
    // jumps a function emits; it does not say whether they depend on a secret, and
    // nothing here can decide that from the instruction stream -- it takes a person
    // reading the dataflow. So docs/ct_ledger.json records the count, the judgement,
    // the judgement's provenance, the reachability, and the object the count is a
    // property of, and this step fails on any of those missing or blank. It does
    // not classify anything, and the withdrawn section keeps a retracted figure
    // visible with its cause instead of deleting it.
    const ct_ledger = b.step("ct-check", "Verify the constant-time judgement ledger holds up");
    {
        const verify = b.addSystemCommand(&.{"python3"});
        verify.addFileArg(b.path("scripts/ct_verify.py"));
        verify.addArgs(&.{ "--ledger", "docs/ct_ledger.json" });
        verify.has_side_effects = true;
        ct_ledger.dependOn(&verify.step);
    }

    // Every test count written in prose, against the measured one. This happened
    // four times in one week: each time tests were added, the root total and the
    // per-library figures had to move together across the root README, seventeen
    // library READMEs and AGENTS.md, and three times they did not. The parts sum
    // to the total is the cheap half; the live half is CI handing this the number
    // the suite it just ran reported, so adding a test without moving
    // docs/test_counts.json fails the job that ran the tests.
    const counts = b.step("counts-check", "Verify every documented test count against the measurement");
    {
        const verify = b.addSystemCommand(&.{"python3"});
        verify.addFileArg(b.path("scripts/counts_verify.py"));
        verify.addArgs(&.{ "--root", "." });
        if (b.args) |args| verify.addArgs(args);
        verify.has_side_effects = true;
        counts.dependOn(&verify.step);
    }

    // CHANGELOG.md is the artefact a consumer reads before bumping, so its
    // release headers are checked rather than trusted: unique versions,
    // descending order, and a non-empty body under every section. This was
    // AUDIT.md row 14 for a week — described in prose in two repositories and
    // implemented in neither. The day it was written it found v0.5.1 filed
    // 104 lines below v0.5.0.
    const changelog = b.step("changelog-check", "Verify CHANGELOG.md release headers are unique and ordered");
    {
        const verify = b.addSystemCommand(&.{"python3"});
        verify.addFileArg(b.path("scripts/changelog_verify.py"));
        verify.addArgs(&.{ "--changelog", "CHANGELOG.md" });
        verify.has_side_effects = true;
        changelog.dependOn(&verify.step);
    }

    // algebra-traits (no deps)
    const traits_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-algebra-traits",
        "libs/algebra-traits/src/root.zig",
        &.{},
    );

    // bigint -> algebra-traits
    const bigint_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-bigint",
        "libs/bigint/src/root.zig",
        &.{.{ "zig-algebra-traits", traits_mod }},
    );

    // field -> bigint
    const field_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-field",
        "libs/field/src/lib.zig",
        &.{.{ "zig-bigint", bigint_mod }},
    );

    // hash -> algebra-traits
    const hash_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-hash",
        "libs/hash/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            // The algebraic-hash tests use `zf.Field(7)` instead of the
            // hand-rolled interface this file used to declare for them.
            .{ "zig-field", field_mod },
        },
    );

    // transcript -> (stdlib only, no internal deps)
    // Named for the same reason as `binary_field_mod`: the fuzz runner needs
    // it to reach `zig-fri`.
    const transcript_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-transcript",
        "libs/transcript/src/root.zig",
        &.{},
    );

    // merkle -> algebra-traits, hash
    const merkle_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-merkle",
        "libs/merkle/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-hash", hash_mod },
        },
    );

    // fri -> transcript, merkle, field
    // (declared after field_mod; see below)

    // rng -> algebra-traits, hash
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-rng",
        "libs/rng/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-hash", hash_mod },
        },
    );

    // parallel (no deps). Declared before binary-field, which depends on it
    // for the fork-join Pool: binary-field/src/pool.zig was a fork of
    // libs/parallel/src/root.zig that had already drifted, and both copies
    // carried their own tests.
    const parallel_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-parallel",
        "libs/parallel/src/root.zig",
        &.{},
    );

    // fri -> field, merkle, transcript. Built here rather than via `lib()` so
    // the fuzz runner can import it; `lib()` also wires a test run, and the
    // fuzz step must not pull the FRI test suite in behind it.
    const fri_fuzz_mod = b.addModule("zig-fri", .{
        .root_source_file = b.path("libs/fri/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fri_fuzz_mod.addImport("zig-field", field_mod);
    fri_fuzz_mod.addImport("zig-merkle", merkle_mod);
    fri_fuzz_mod.addImport("zig-transcript", transcript_mod);

    // binary-field -> algebra-traits, hash, merkle, parallel
    // Named (not `_ =`) because the mass-fuzz runner imports it: the fuzz gate
    // was blind to `Sumcheck`, `Prime31` and `Prime128`, which is to say it
    // could not have caught the characteristic-2 fold.
    const binary_field_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-binary-field",
        "libs/binary-field/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-hash", hash_mod },
            .{ "zig-merkle", merkle_mod },
            .{ "zig-parallel", parallel_mod },
        },
    );

    // curve -> field, hash
    const curve_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-curve",
        "libs/curve/src/root.zig",
        &.{
            .{ "zig-field", field_mod },
            .{ "zig-hash", hash_mod },
        },
    );

    // ntt -> algebra-traits, field
    const ntt_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-ntt",
        "libs/ntt/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-field", field_mod },
        },
    );

    // fri -> transcript, merkle, field
    //
    // The second `addModule("zig-transcript-inner", ...)` that used to live
    // here is gone: `lib("zig-transcript", ...)` above already produces the
    // module, and the duplicate was only reachable because nothing outside
    // this block could name it. Two modules for one library is two things to
    // keep in step, and the shadowing made the outer name unusable.
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-fri",
        "libs/fri/src/root.zig",
        &.{
            .{ "zig-transcript", transcript_mod },
            .{ "zig-merkle", merkle_mod },
            .{ "zig-field", field_mod },
        },
    );

    // poly -> algebra-traits
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-poly",
        "libs/poly/src/root.zig",
        &.{.{ "zig-algebra-traits", traits_mod }},
    );

    // linalg -> algebra-traits, field
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-linalg",
        "libs/linalg/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-field", field_mod },
        },
    );

    // serialization (no deps)
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-serialization",
        "libs/serialization/src/root.zig",
        &.{},
    );

    // pairing -> algebra-traits, field, curve
    const pairing_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-pairing",
        "libs/pairing/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-field", field_mod },
            .{ "zig-curve", curve_mod },
        },
    );

    // Benchmark step (always ReleaseFast regardless of -Doptimize)
    // pow against powFast, per field, as the minimum of seven repetitions. It is
    // a build step and not a test because a timing assertion in the suite is flaky
    // by construction. One measurement is not a number: Goldilocks came out at
    // 0.79, 0.89 and 1.28 across three single measurements, crossing the 1.0 that
    // decides the question, and 0.85, 0.84, 0.86 with the minimum of seven.
    const pow_bench_step = b.step("pow-bench", "Measure pow against powFast per field (min of 7)");
    {
        const exe = b.addExecutable(.{
            .name = "pow-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("libs/field/bench/pow.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        exe.root_module.addImport("zig-field", field_mod);
        exe.root_module.addImport("zig-bigint", bigint_mod);
        exe.root_module.addImport("zig-parallel", parallel_mod);
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        pow_bench_step.dependOn(&run.step);
    }

    const bench_step = b.step("bench", "Run benchmarks (ReleaseFast)");
    const bench_optimize = .ReleaseFast;
    const bench_module = b.createModule(.{
        .root_source_file = b.path("libs/pairing/src/bench.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_module.addImport("zig-field", field_mod);
    bench_module.addImport("zig-curve", curve_mod);
    bench_module.addImport("zig-algebra-traits", traits_mod);
    bench_module.addImport("zig-bigint", bigint_mod);
    bench_module.addImport("zig-ntt", ntt_mod);
    bench_module.addImport("zig-parallel", parallel_mod);
    const bench_exe = b.addExecutable(.{
        .name = "pairing-bench",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // kzg -> field, curve, pairing
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-kzg",
        "libs/kzg/src/root.zig",
        &.{
            .{ "zig-field", field_mod },
            .{ "zig-curve", curve_mod },
            .{ "zig-pairing", pairing_mod },
        },
    );

    // Example: Schnorr signature over BLS12-381
    const example_step = b.step("example", "Run BLS12-381 Schnorr signature example");
    const ex_mod = b.createModule(.{
        .root_source_file = b.path("examples/schnorr_signature.zig"),
        .target = target,
        .optimize = optimize,
    });
    ex_mod.addImport("zig-field", field_mod);
    ex_mod.addImport("zig-curve", curve_mod);
    ex_mod.addImport("zig-pairing", pairing_mod);
    ex_mod.addImport("zig-algebra-traits", traits_mod);
    ex_mod.addImport("zig-bigint", bigint_mod);
    ex_mod.addImport("zig-parallel", parallel_mod);
    const example_exe = b.addExecutable(.{
        .name = "schnorr-example",
        .root_module = ex_mod,
    });
    const run_example = b.addRunArtifact(example_exe);
    example_step.dependOn(&run_example.step);

    // Example: STARK prover (Fibonacci over Goldilocks with FRI)
    const stark_step = b.step("stark", "Run STARK prover example (Fibonacci over Goldilocks)");
    const transcript_root = b.path("libs/transcript/src/root.zig");
    const fri_root = b.path("libs/fri/src/root.zig");
    const stark_transcript_mod = b.createModule(.{
        .root_source_file = transcript_root,
        .target = target,
        .optimize = optimize,
    });
    const stark_hash_mod = b.createModule(.{
        .root_source_file = b.path("libs/hash/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stark_merkle_mod = b.createModule(.{
        .root_source_file = b.path("libs/merkle/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-hash", .module = stark_hash_mod },
        },
    });
    const stark_fri_mod = b.createModule(.{
        .root_source_file = fri_root,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-transcript", .module = stark_transcript_mod },
            .{ .name = "zig-merkle", .module = stark_merkle_mod },
            .{ .name = "zig-field", .module = field_mod },
        },
    });
    const stark_mod = b.createModule(.{
        .root_source_file = b.path("examples/stark_prover.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-transcript", .module = stark_transcript_mod },
            .{ .name = "zig-fri", .module = stark_fri_mod },
            .{ .name = "zig-parallel", .module = parallel_mod },
            .{ .name = "zig-field", .module = field_mod },
        },
    });
    const stark_exe = b.addExecutable(.{
        .name = "stark-example",
        .root_module = stark_mod,
    });
    const run_stark = b.addRunArtifact(stark_exe);
    stark_step.dependOn(&run_stark.step);

    // Mass fuzz runner (nightly CI; ReleaseFast only — too slow in Debug)
    const fuzz_step = b.step("fuzz", "Run massive randomized property tests (use -Doptimize=ReleaseFast)");
    const fuzz_pairing_mod = b.createModule(.{
        .root_source_file = b.path("libs/pairing/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = field_mod },
            .{ .name = "zig-curve", .module = curve_mod },
        },
    });
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("examples/fuzz_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = field_mod },
            .{ .name = "zig-curve", .module = curve_mod },
            .{ .name = "zig-pairing", .module = fuzz_pairing_mod },
            // Added so the nightly gate can see the code it is supposed to be
            // gating. Without these the job reported "all fuzz checks passed"
            // while never constructing a `Sumcheck`, a prime fixture or a torus
            // domain -- a green run of a check that could not have failed.
            .{ .name = "zig-binary-field", .module = binary_field_mod },
            .{ .name = "zig-fri", .module = fri_fuzz_mod },
            .{ .name = "zig-parallel", .module = parallel_mod },
            .{ .name = "zig-transcript", .module = transcript_mod },
            // So the nightly can hash-check. It could not before: the runner
            // never touched a hash, which is why a non-BLAKE3 "Blake3" stayed
            // green through the tag that shipped it.
            .{ .name = "zig-hash", .module = hash_mod },
        },
    });
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz-runner",
        .root_module = fuzz_mod,
    });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    // `zig build fuzz -- <seed>` replays a specific seed. A failure that cannot
    // be reproduced is a check that cannot be investigated.
    if (b.args) |args| run_fuzz.addArgs(args);
    fuzz_step.dependOn(&run_fuzz.step);

    // WASM build: freestanding, no entry point; `export fn`s become imports.
    const wasm_step = b.step("wasm", "Build examples/wasm_fp.zig to wasm32-freestanding");
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("examples/wasm_fp.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = field_mod },
        },
    });
    // createModule() doesn't take this field; assign directly (Module.zig:39).
    wasm_mod.export_symbol_names = &.{ "fp_add", "fp_mul", "fp_inv" };
    const wasm_exe = b.addExecutable(.{
        .name = "zig_algebra_fp",
        .root_module = wasm_mod,
    });
    wasm_exe.entry = .disabled; // -fno-entry: exports via `export fn`
    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    wasm_step.dependOn(&install_wasm.step);

    // Pairing WASM module (BN254 e(G1,G2) for JS/TS interop).
    const wp_step = b.step("wasm-pairing", "Build examples/wasm_pairing.zig to wasm32-freestanding");
    const pairing_src = b.createModule(.{
        .root_source_file = b.path("libs/pairing/src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = field_mod },
            .{ .name = "zig-curve", .module = curve_mod },
        },
    });
    const wpm = b.createModule(.{
        .root_source_file = b.path("examples/wasm_pairing.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = field_mod },
            .{ .name = "zig-curve", .module = curve_mod },
            .{ .name = "zig-pairing", .module = pairing_src },
        },
    });
    wpm.export_symbol_names = &.{ "pairing_api_version", "g1_validate", "g2_validate", "pairing_compute", "pairing_bilinear_check", "scratch_ptr" };
    const wp_exe = b.addExecutable(.{
        .name = "zig_algebra_pairing",
        .root_module = wpm,
    });
    wp_exe.entry = .disabled;
    const install_wp = b.addInstallArtifact(wp_exe, .{});
    wp_step.dependOn(&install_wp.step);

    if (optimize == .ReleaseFast) b.default_step = test_step;
}
