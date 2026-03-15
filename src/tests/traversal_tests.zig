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

fn defaultPairToHyperedge(_: HypergraphZId, _: HypergraphZId) Hyperedge {
    return .{};
}

test "find shortest path" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.findShortestPath(max_id, data.v_a));
    try expectError(HypergraphZError.VertexNotFound, graph.findShortestPath(data.v_a, max_id));

    {
        var result = try graph.findShortestPath(data.v_a, data.v_e);
        defer result.deinit(std.testing.allocator);

        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_d, data.v_e }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_b, data.v_e);
        defer result.deinit(std.testing.allocator);

        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_b, data.v_c, data.v_e }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_d, data.v_a);
        defer result.deinit(std.testing.allocator);

        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_d, data.v_e, data.v_a }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_c, data.v_b);
        defer result.deinit(std.testing.allocator);

        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_c, data.v_d, data.v_b }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_d, data.v_b);
        defer result.deinit(std.testing.allocator);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_d, data.v_b }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_c, data.v_c);
        defer result.deinit(std.testing.allocator);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{data.v_c}, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_e, data.v_e);
        defer result.deinit(std.testing.allocator);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{data.v_e}, result.data.?.items);
    }

    {
        const disconnected = try graph.createVertex(Vertex{});
        var result = try graph.findShortestPath(data.v_a, disconnected);
        defer result.deinit(std.testing.allocator);
        try expect(result.data == null);
    }
}

test "breadth first search" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.breadthFirstSearch(max_id));

    {
        const result = try graph.breadthFirstSearch(data.v_a);
        defer graph.allocator.free(result);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_b, data.v_d, data.v_c, data.v_e }, result);
    }

    {
        const result = try graph.breadthFirstSearch(data.v_e);
        defer graph.allocator.free(result);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_e, data.v_a, data.v_b, data.v_d, data.v_c }, result);
    }

    {
        const disconnected = try graph.createVertex(Vertex{});
        const result = try graph.breadthFirstSearch(disconnected);
        defer graph.allocator.free(result);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{disconnected}, result);
    }
}

test "depth first search" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.depthFirstSearch(max_id));

    {
        const result = try graph.depthFirstSearch(data.v_a);
        defer graph.allocator.free(result);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_b, data.v_c, data.v_d, data.v_e }, result);
    }

    {
        const result = try graph.depthFirstSearch(data.v_c);
        defer graph.allocator.free(result);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_c, data.v_d, data.v_e, data.v_a, data.v_b }, result);
    }

    {
        const disconnected = try graph.createVertex(Vertex{});
        const result = try graph.depthFirstSearch(disconnected);
        defer graph.allocator.free(result);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{disconnected}, result);
    }
}

test "find all paths" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.findAllPaths(max_id, data.v_a));
    try expectError(HypergraphZError.VertexNotFound, graph.findAllPaths(data.v_a, max_id));

    // Same vertex returns the trivial single-vertex path.
    {
        var result = try graph.findAllPaths(data.v_a, data.v_a);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.items.len == 1);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{data.v_a}, result.data.items[0]);
    }

    // Disconnected vertex: no path to any connected vertex.
    {
        const disconnected = try graph.createVertex(Vertex{});
        var result = try graph.findAllPaths(disconnected, data.v_a);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.items.len == 0);
    }

    // v_a → v_e: 4 simple paths.
    {
        var result = try graph.findAllPaths(data.v_a, data.v_e);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.items.len == 4);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_d, data.v_b, data.v_c, data.v_e }, result.data.items[0]);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_d, data.v_e }, result.data.items[1]);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_b, data.v_c, data.v_e }, result.data.items[2]);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_b, data.v_c, data.v_d, data.v_e }, result.data.items[3]);
    }

    // v_e → v_b: 2 simple paths.
    {
        var result = try graph.findAllPaths(data.v_e, data.v_b);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.items.len == 2);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_e, data.v_a, data.v_d, data.v_b }, result.data.items[0]);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_e, data.v_a, data.v_b }, result.data.items[1]);
    }
}

test "is reachable" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.isReachable(max_id, data.v_a));
    try expectError(HypergraphZError.VertexNotFound, graph.isReachable(data.v_a, max_id));

    // Every vertex can reach itself.
    try expect(try graph.isReachable(data.v_a, data.v_a));
    try expect(try graph.isReachable(data.v_e, data.v_e));

    // Reachable pairs (via directed edges).
    try expect(try graph.isReachable(data.v_a, data.v_e));
    try expect(try graph.isReachable(data.v_e, data.v_a)); // e -> a via h_b
    try expect(try graph.isReachable(data.v_b, data.v_d));

    // Disconnected vertex is unreachable from and cannot reach connected vertices.
    {
        const disconnected = try graph.createVertex(Vertex{});
        try expect(!try graph.isReachable(data.v_a, disconnected));
        try expect(!try graph.isReachable(disconnected, data.v_a));
    }
}

test "get transitive closure" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.getTransitiveClosure(defaultPairToHyperedge));
    }

    // Empty graph: closure has no vertices and no hyperedges.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        var closure = try graph.getTransitiveClosure(defaultPairToHyperedge);
        defer closure.deinit();
        try expect(closure.countVertices() == 0);
        try expect(closure.countHyperedges() == 0);
    }

    // Linear acyclic chain [a,b,c]: pairs a→b, b→c.
    // Strict closure: a→b, a→c, b→c. No self-loops (no cycles).
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const v_c = try graph.createVertexAssumeCapacity(.{});
        const he = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(he, &.{ v_a, v_b, v_c });
        try graph.build();
        var closure = try graph.getTransitiveClosure(defaultPairToHyperedge);
        defer closure.deinit();
        // a→b, a→c, b→c: 3 edges, no self-loops.
        try expect(closure.countVertices() == 3);
        try expect(closure.countHyperedges() == 3);
        try closure.build();
        try expect(try closure.isKUniform(2));
    }

    // Main test graph: all 5 vertices are mutually reachable and on cycles.
    // Strict closure has 5*5 = 25 edges (every pair including self-loops).
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);
        var closure = try graph.getTransitiveClosure(defaultPairToHyperedge);
        defer closure.deinit();
        try expect(closure.countVertices() == 5);
        try expect(closure.countHyperedges() == 25);
        try closure.build();
        try expect(try closure.isKUniform(2));
    }

    // Mapper receives the correct (from, to) IDs.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const he = try graph.createHyperedgeAssumeCapacity(.{ .weight = 5 });
        try graph.appendVerticesToHyperedge(he, &.{ v_a, v_b });
        try graph.build();

        const S = struct {
            fn mapper(_: HypergraphZId, _: HypergraphZId) Hyperedge {
                return .{ .weight = 42 };
            }
        };
        var closure = try graph.getTransitiveClosure(S.mapper);
        defer closure.deinit();
        try expect(closure.countHyperedges() == 1);
        // New hyperedge carries the mapped data, not the original.
        const new_id: HypergraphZId = v_b + 1;
        try expect((try closure.getHyperedge(new_id)).weight == 42);
    }
}
