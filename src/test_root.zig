// Test entry point for the HypergraphZ test suite.
// This file is intentionally separate from the library root (hypergraphz.zig)
// so that the documentation generator does not traverse test-only files.

test {
    _ = @import("tests/core_tests.zig");
    _ = @import("tests/mutations_tests.zig");
    _ = @import("tests/queries_tests.zig");
    _ = @import("tests/traversal_tests.zig");
    _ = @import("tests/algorithms_tests.zig");
    _ = @import("tests/projections_tests.zig");
    _ = @import("tests/codec_tests.zig");
}
