const std = @import("std");
const HypergraphZPath = "src/hypergraphz.zig";
const BenchPath = "src/bench.zig";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_source_file = b.path(HypergraphZPath);

    const root_module = b.addModule("hypergraphz", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_module = root_module,
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
    const docs_step = b.step("docs", "Build the HypergraphZ docs");
    const docs_obj = b.addObject(.{
        .name = "zeit",
        .root_module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = target,
            .optimize = optimize,
        }),
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    // Check step used by the zls configuration.
    const check_step = b.step("check", "Check if HypergraphZ compiles");
    const check = b.addTest(.{
        .root_module = root_module,
    });
    check_step.dependOn(&check.step);

    // Bench step.
    const bench_source_file = b.path(BenchPath);
    const bench_module = b.addModule("bench", .{
        .root_source_file = bench_source_file,
        .target = target,
        .optimize = .ReleaseFast,
    });

    const bench_step = b.step("bench", "Run benchmarks");
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_module,
    });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        bench_run.addArgs(args);
    }
    bench_step.dependOn(&bench_run.step);
    b.default_step.dependOn(bench_step);
}
