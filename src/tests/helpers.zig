const std = @import("std");
const hg = @import("../hypergraphz.zig");

pub const HypergraphZ = hg.HypergraphZ;
pub const HypergraphZId = hg.HypergraphZId;
pub const HypergraphZError = hg.HypergraphZError;

pub const expect = std.testing.expect;
pub const expectEqualSlices = std.testing.expectEqualSlices;
pub const expectError = std.testing.expectError;
pub const maxInt = std.math.maxInt;
pub const max_id = maxInt(HypergraphZId);

pub const Hyperedge = struct { meow: bool = false, weight: usize = 1 };
pub const Vertex = struct { purr: bool = false };
pub const Graph = HypergraphZ(Hyperedge, Vertex);

pub fn scaffold() HypergraphZError!Graph {
    std.testing.log_level = .debug;
    return try HypergraphZ(Hyperedge, Vertex).init(std.testing.allocator, .{ .vertices_capacity = 5, .hyperedges_capacity = 3 });
}

pub const Data = struct {
    v_a: HypergraphZId,
    v_b: HypergraphZId,
    v_c: HypergraphZId,
    v_d: HypergraphZId,
    v_e: HypergraphZId,
    h_a: HypergraphZId,
    h_b: HypergraphZId,
    h_c: HypergraphZId,
};

pub fn generateTestData(graph: *Graph) !Data {
    const v_a = try graph.createVertexAssumeCapacity(.{});
    const v_b = try graph.createVertexAssumeCapacity(.{});
    const v_c = try graph.createVertexAssumeCapacity(.{});
    const v_d = try graph.createVertexAssumeCapacity(.{});
    const v_e = try graph.createVertexAssumeCapacity(.{});

    const h_a = try graph.createHyperedgeAssumeCapacity(.{});
    try graph.appendVerticesToHyperedge(h_a, &.{ v_a, v_b, v_c, v_d, v_e });
    const h_b = try graph.createHyperedgeAssumeCapacity(.{});
    try graph.appendVerticesToHyperedge(h_b, &.{ v_e, v_e, v_a });
    const h_c = try graph.createHyperedgeAssumeCapacity(.{});
    try graph.appendVerticesToHyperedge(h_c, &.{ v_b, v_c, v_c, v_e, v_a, v_d, v_b });

    try graph.build();

    return .{
        .v_a = v_a,
        .v_b = v_b,
        .v_c = v_c,
        .v_d = v_d,
        .v_e = v_e,
        .h_a = h_a,
        .h_b = h_b,
        .h_c = h_c,
    };
}
