// Test entry point for the HypergraphZ test suite.
// This file lives outside src/ so that the documentation generator does not
// traverse test-only files when building docs from src/hypergraphz.zig.

test {
    _ = @import("core_tests.zig");
    _ = @import("mutations_tests.zig");
    _ = @import("queries_tests.zig");
    _ = @import("traversal_tests.zig");
    _ = @import("algorithms_tests.zig");
    _ = @import("projections_tests.zig");
    _ = @import("codec_tests.zig");
}
