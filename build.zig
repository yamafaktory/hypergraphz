const std = @import("std");
const hyperzigPath = "src/hyperzig.zig";

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

    // Export as module to be available via @import("hyperzig").
    _ = b.addModule("hyperzig", .{
        .root_source_file = b.path(hyperzigPath),
        .target = target,
        .optimize = optimize,
    });

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path(hyperzigPath),
        .target = target,
        .optimize = optimize,
        .filter = b.option([]const u8, "filter", "Filter strings for tests"),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Disable cache for unit tests to get logs.
    // https://ziggit.dev/t/how-to-enable-more-logging-and-disable-caching-with-zig-build-test/2654/11
    run_lib_unit_tests.has_side_effects = true;

    if (b.lazyDependency("uuid", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        lib_unit_tests.root_module.addImport("uuid", dep.module("uuid"));
    }

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    // Notes:
    // - `zig build test -Doptimize=ReleaseFast` to run the unit tests in release-fast mode.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
