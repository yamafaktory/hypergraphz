const std = @import("std");
const h = @import("helpers.zig");

const HypergraphZId = h.HypergraphZId;
const HypergraphZError = h.HypergraphZError;
const Vertex = h.Vertex;
const expect = h.expect;
const expectEqualSlices = h.expectEqualSlices;
const expectError = h.expectError;

test "compute centrality" {
    const approxEq = std.math.approxEqAbs;
    const eps = 1e-9;

    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.computeCentrality());
    }

    // Empty graph: empty result.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        var result = try graph.computeCentrality();
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 0);
    }

    // Single isolated vertex: all scores zero.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try graph.createVertex(Vertex{});
        try graph.build();
        var result = try graph.computeCentrality();
        defer result.deinit(std.testing.allocator);
        var single_it = result.data.iterator();
        const scores = single_it.next().?.value_ptr.*;
        try expect(approxEq(f64, scores.degree, 0.0, eps));
        try expect(approxEq(f64, scores.closeness, 0.0, eps));
        try expect(approxEq(f64, scores.betweenness, 0.0, eps));
    }

    // Linear chain [a,b,c]: h = [v_a, v_b, v_c] → pairs (a,b),(b,c).
    // n=3, pairs: a(out=1,in=0), b(out=1,in=1), c(out=0,in=1).
    // degree: a=1/4=0.25, b=2/4=0.5, c=1/4=0.25.
    // closeness (Wasserman-Faust):
    //   a: reachable=2, total_dist=3 → 4/(2*3) ≈ 0.6667
    //   b: reachable=1, total_dist=1 → 1/(2*1) = 0.5
    //   c: no outgoing → 0.0
    // betweenness (normalised by (n-1)*(n-2)=2):
    //   b lies on the only path a→c → raw=1 → 1/2=0.5; a=0, c=0.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const v_c = try graph.createVertexAssumeCapacity(.{});
        const he = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(he, &.{ v_a, v_b, v_c });
        try graph.build();

        var result = try graph.computeCentrality();
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 3);

        const sa = result.data.get(v_a).?;
        const sb = result.data.get(v_b).?;
        const sc = result.data.get(v_c).?;

        try expect(approxEq(f64, sa.degree, 0.25, eps));
        try expect(approxEq(f64, sb.degree, 0.5, eps));
        try expect(approxEq(f64, sc.degree, 0.25, eps));

        try expect(approxEq(f64, sa.closeness, 4.0 / 6.0, eps));
        try expect(approxEq(f64, sb.closeness, 0.5, eps));
        try expect(approxEq(f64, sc.closeness, 0.0, eps));

        try expect(approxEq(f64, sa.betweenness, 0.0, eps));
        try expect(approxEq(f64, sb.betweenness, 0.5, eps));
        try expect(approxEq(f64, sc.betweenness, 0.0, eps));
    }

    // Main test graph: all 5 vertices present; spot-check structural properties.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);
        var result = try graph.computeCentrality();
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 5);
        // Every vertex has non-zero closeness (all mutually reachable).
        var it = result.data.iterator();
        while (it.next()) |kv| try expect(kv.value_ptr.closeness > 0.0);
    }
}

test "has cycle" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.hasCycle());
    }

    // Empty graph: no cycle.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        try expect(!try graph.hasCycle());
    }

    // Linear chain [a,b,c,d]: no cycle.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const v_c = try graph.createVertexAssumeCapacity(.{});
        const v_d = try graph.createVertexAssumeCapacity(.{});
        const he = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(he, &.{ v_a, v_b, v_c, v_d });
        try graph.build();
        try expect(!try graph.hasCycle());
    }

    // Self-loop: single hyperedge [a,a] → pair (a,a).
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const he = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(he, &.{ v_a, v_a });
        try graph.build();
        try expect(try graph.hasCycle());
    }

    // Explicit cycle: [a,b,c,a] → pairs (a,b),(b,c),(c,a).
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const v_c = try graph.createVertexAssumeCapacity(.{});
        const he = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(he, &.{ v_a, v_b, v_c, v_a });
        try graph.build();
        try expect(try graph.hasCycle());
    }

    // Main test graph contains self-loops (e→e, c→c) and longer cycles.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);
        try expect(try graph.hasCycle());
    }
}

test "topological sort" {
    // Error: not built.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.topologicalSort());
    }

    // Cycle detected: main test graph has self-loops and longer cycles.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);
        try expectError(HypergraphZError.CycleDetected, graph.topologicalSort());
    }

    // Empty graph: empty result.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        const result = try graph.topologicalSort();
        defer graph.allocator.free(result);
        try expect(result.len == 0);
    }

    // Linear chain [a,b,c,d,e]: unique topological order a,b,c,d,e.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const a = try graph.createVertexAssumeCapacity(.{});
        const b = try graph.createVertexAssumeCapacity(.{});
        const c = try graph.createVertexAssumeCapacity(.{});
        const d = try graph.createVertexAssumeCapacity(.{});
        const e = try graph.createVertexAssumeCapacity(.{});
        const he = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(he, &.{ a, b, c, d, e });
        try graph.build();
        const result = try graph.topologicalSort();
        defer graph.allocator.free(result);
        try expectEqualSlices(HypergraphZId, &.{ a, b, c, d, e }, result);
    }

    // DAG with branching: h1=[a,b,c], h2=[a,d], h3=[b,e].
    // In-degrees: a=0, b=1(a), c=1(b), d=1(a), e=1(b).
    // a is processed first; b and d are unblocked next (insertion order: b before d).
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const a = try graph.createVertexAssumeCapacity(.{});
        const b = try graph.createVertexAssumeCapacity(.{});
        const c = try graph.createVertexAssumeCapacity(.{});
        const d = try graph.createVertexAssumeCapacity(.{});
        const e = try graph.createVertexAssumeCapacity(.{});
        const h1 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h1, &.{ a, b, c });
        const h2 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h2, &.{ a, d });
        const h3 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h3, &.{ b, e });
        try graph.build();
        const result = try graph.topologicalSort();
        defer graph.allocator.free(result);
        try expect(result.len == 5);
        // Build a position map and verify all directed-pair constraints.
        var pos = std.AutoHashMap(HypergraphZId, usize).init(graph.allocator);
        defer pos.deinit();
        for (result, 0..) |v, i| try pos.put(v, i);
        try expect(pos.get(a).? < pos.get(b).?); // a→b
        try expect(pos.get(b).? < pos.get(c).?); // b→c
        try expect(pos.get(a).? < pos.get(d).?); // a→d
        try expect(pos.get(b).? < pos.get(e).?); // b→e
    }
}

test "is connected" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.isConnected());
    }

    // Empty graph (no vertices) is vacuously connected.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        try expect(try graph.isConnected());
    }

    // Single vertex with no hyperedges.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try graph.createVertex(Vertex{});
        try graph.build();
        try expect(try graph.isConnected());
    }

    // Main test graph: all 5 vertices are weakly reachable from each other.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);
        try expect(try graph.isConnected());
    }

    // Adding an isolated vertex breaks connectivity.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);
        _ = try graph.createVertex(Vertex{});
        try expect(!try graph.isConnected());
    }
}

test "get connected components" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.getConnectedComponents());
    }

    // Empty graph: zero components.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        var result = try graph.getConnectedComponents();
        defer result.deinit(std.testing.allocator);
        try expect(result.data.items.len == 0);
    }

    // Single vertex: one component containing just that vertex.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v = try graph.createVertex(Vertex{});
        try graph.build();
        var result = try graph.getConnectedComponents();
        defer result.deinit(std.testing.allocator);
        try expect(result.data.items.len == 1);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{v}, result.data.items[0]);
    }

    // Main test graph: one component containing all 5 vertices.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);
        var result = try graph.getConnectedComponents();
        defer result.deinit(std.testing.allocator);
        try expect(result.data.items.len == 1);
        try expect(result.data.items[0].len == 5);
    }

    // Adding an isolated vertex produces a second component of size 1.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);
        const disconnected = try graph.createVertex(Vertex{});
        var result = try graph.getConnectedComponents();
        defer result.deinit(std.testing.allocator);
        try expect(result.data.items.len == 2);
        try expect(result.data.items[0].len == 5);
        try expect(result.data.items[1].len == 1);
        try expect(result.data.items[1][0] == disconnected);
    }
}
