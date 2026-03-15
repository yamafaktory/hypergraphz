const std = @import("std");
const h = @import("helpers.zig");

const HypergraphZId = h.HypergraphZId;
const HypergraphZError = h.HypergraphZError;
const Hyperedge = h.Hyperedge;
const Vertex = h.Vertex;
const expect = h.expect;
const expectEqualSlices = h.expectEqualSlices;
const expectError = h.expectError;
const max_id = h.max_id;

test "clone" {
    // Error: not built.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.clone());
    }

    var graph = try h.scaffold();
    defer graph.deinit();
    const d = try h.generateTestData(&graph);

    var copy = try graph.clone();
    defer copy.deinit();
    try copy.build();

    // Same counts.
    try expect(copy.vertices.count() == graph.vertices.count());
    try expect(copy.hyperedges.count() == graph.hyperedges.count());
    try expect(copy.id_counter == graph.id_counter);

    // Same hyperedge relations.
    try expectEqualSlices(HypergraphZId, try graph.getHyperedgeVertices(d.h_a), try copy.getHyperedgeVertices(d.h_a));
    try expectEqualSlices(HypergraphZId, try graph.getHyperedgeVertices(d.h_b), try copy.getHyperedgeVertices(d.h_b));
    try expectEqualSlices(HypergraphZId, try graph.getHyperedgeVertices(d.h_c), try copy.getHyperedgeVertices(d.h_c));

    // Same reverse index.
    try expectEqualSlices(HypergraphZId, try graph.getVertexHyperedges(d.v_a), try copy.getVertexHyperedges(d.v_a));
    try expectEqualSlices(HypergraphZId, try graph.getVertexHyperedges(d.v_e), try copy.getVertexHyperedges(d.v_e));

    // Independence: mutating the copy does not affect the original.
    try copy.deleteVertex(d.v_a);
    try graph.checkIfVertexExists(d.v_a); // original still has v_a
    try expectError(HypergraphZError.VertexNotFound, copy.checkIfVertexExists(d.v_a));

    // Data is deep-copied: modifying clone's vertex data doesn't touch the original.
    try copy.updateVertex(d.v_b, .{ .purr = true });
    try expect((try graph.getVertex(d.v_b)).purr == false);
    try expect((try copy.getVertex(d.v_b)).purr == true);
}

test "allocation failure" {
    var failingAllocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var graph = try h.Graph.init(failingAllocator.allocator(), .{});
    defer graph.deinit();

    // The following fails since two allocations are made.
    try expectError(HypergraphZError.OutOfMemory, graph.createHyperedge(.{}));
}

test "create and get hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedge(max_id));

    const hyperedge = try graph.getHyperedge(hyperedge_id);
    try expect(@TypeOf(hyperedge) == Hyperedge);
}

test "create and get vertex" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const vertex_id = try graph.createVertex(.{});

    try expectError(HypergraphZError.VertexNotFound, graph.getVertex(max_id));

    const vertex = try graph.getVertex(vertex_id);
    try expect(@TypeOf(vertex) == Vertex);
}

test "get all hyperedges" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    const hyperedges = graph.getAllHyperedges();
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.h_a, data.h_b, data.h_c }, hyperedges);
}

test "get all vertices" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    const vertices = graph.getAllVertices();
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_b, data.v_c, data.v_d, data.v_e }, vertices);
}

test "count hyperedges" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(graph.countHyperedges() == 1);
    try graph.build();
    try graph.deleteHyperedge(hyperedge_id, false);
    try expect(graph.countHyperedges() == 0);
}

test "count vertices" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const vertex_id = try graph.createVertex(.{});
    try expect(graph.countVertices() == 1);
    try graph.build();
    try graph.deleteVertex(vertex_id);
    try expect(graph.countVertices() == 0);
}

test "update hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    try expectError(HypergraphZError.HyperedgeNotFound, graph.updateHyperedge(max_id, .{}));

    try graph.updateHyperedge(hyperedge_id, .{ .meow = true });
    const hyperedge = try graph.getHyperedge(hyperedge_id);
    try expect(@TypeOf(hyperedge) == Hyperedge);
    try expect(hyperedge.meow);
}

test "update vertex" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const vertex_id = try graph.createVertex(.{});

    try expectError(HypergraphZError.VertexNotFound, graph.updateVertex(max_id, .{}));

    try graph.updateVertex(vertex_id, .{ .purr = true });
    const vertex = try graph.getVertex(vertex_id);
    try expect(@TypeOf(vertex) == Vertex);
    try expect(vertex.purr);
}

test "reserve hyperedges" {
    var graph = try h.Graph.init(std.testing.allocator, .{});
    defer graph.deinit();

    try expect(graph.countHyperedges() == 0);
    try expect(graph.hyperedges.capacity() == 0);
    // Put more than `linear_scan_max`.
    try graph.reserveHyperedges(20);
    for (0..20) |_| {
        _ = try graph.createHyperedgeAssumeCapacity(.{});
    }
    try expect(graph.hyperedges.capacity() > 20);
    // Calling `createHyperedgeAssumeCapacity` will panic but we can't test
    // it, see: https://github.com/ziglang/zig/issues/1356.
}

test "reserve vertices" {
    var graph = try h.Graph.init(std.testing.allocator, .{});
    defer graph.deinit();

    try expect(graph.countVertices() == 0);
    try expect(graph.vertices.capacity() == 0);
    // Put more than `linear_scan_max`.
    try graph.reserveVertices(20);
    for (0..20) |_| {
        _ = try graph.createVertexAssumeCapacity(.{});
    }
    try expect(graph.vertices.capacity() > 20);
    // Calling `createVertexAssumeCapacity` will panic but we can't test
    // it, see: https://github.com/ziglang/zig/issues/1356.
}

test "reserve hyperedge vertices" {
    var graph = try h.Graph.init(std.testing.allocator, .{});
    defer graph.deinit();

    try expectError(HypergraphZError.HyperedgeNotFound, graph.reserveHyperedgeVertices(max_id, 10));

    const he = try graph.createHyperedge(.{});
    const hyperedge = graph.hyperedges.getPtr(he).?;
    try expect(hyperedge.relations.capacity == 0);
    try graph.reserveHyperedgeVertices(he, 20);
    try expect(hyperedge.relations.capacity >= 20);
    // Vertices can now be appended without reallocation.
    for (0..20) |_| {
        const v = try graph.createVertex(.{});
        try graph.appendVertexToHyperedge(he, v);
    }
    try expect(hyperedge.relations.items.len == 20);
}
