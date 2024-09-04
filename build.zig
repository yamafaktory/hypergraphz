const std = @import("std");
const HyperZigPath = "src/hyperzig.zig";

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const root_source_file = b.path(HyperZigPath);

    // Export as module to be available via @import("hyperzig").
    _ = b.addModule("hyperzig", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
        .filter = b.option([]const u8, "filter", "Filter strings for tests"),
    });

    const run_lib_unit_tests = b.addRunArtifact(unit_tests);

    // Disable cache for unit tests to get logs.
    // https://ziggit.dev/t/how-to-enable-more-logging-and-disable-caching-with-zig-build-test/2654/11
    run_lib_unit_tests.has_side_effects = true;

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    // Notes:
    // - `zig build test -Doptimize=ReleaseFast` to run the unit tests in release-fast mode.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Generate docs step.
    const docs_step = b.step("docs", "Emit docs");
    const docs_install = b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs",
        .source_dir = unit_tests.getEmittedDocs(),
    });
    docs_step.dependOn(&docs_install.step);
    b.default_step.dependOn(docs_step);

    // Check step used by the zls configuration.
    const check_step = b.step("check", "Check if HyperZig compiles");
    const check = b.addTest(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = .Debug,
    });
    check_step.dependOn(&check.step);

    // Bench step.
    // const bench_step = b.step("bench", "Run benchmarks");
    // const bench_exe = b.addExecutable(.{
    //     .name = "bench",
    //     .root_source_file = b.path("src/bench.zig"),
    //     .target = target,
    //     .optimize = .ReleaseFast,
    // });
    // const bench_run = b.addRunArtifact(bench_exe);
    // if (b.args) |args| {
    //     bench_run.addArgs(args);
    // }
    // bench_step.dependOn(&bench_run.step);
    // b.default_step.dependOn(bench_step);

    if (b.lazyDependency("uuid", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        unit_tests.root_module.addImport("uuid", dep.module("uuid"));
        check.root_module.addImport("uuid", dep.module("uuid"));
        // bench_exe.root_module.addImport("uuid", dep.module("uuid"));
    }
}
