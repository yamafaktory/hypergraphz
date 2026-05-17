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

test "compute pagerank" {
    const approxEq = std.math.approxEqAbs;

    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.computePageRank(.{}));
    }

    // Empty graph: empty result, trivially "converged".
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        var pr = try graph.computePageRank(.{});
        defer pr.deinit(std.testing.allocator);
        try expect(pr.data.count() == 0);
        try expect(pr.converged);
    }

    // Single isolated vertex: it owns all the mass.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v = try graph.createVertexAssumeCapacity(.{});
        try graph.build();
        var pr = try graph.computePageRank(.{});
        defer pr.deinit(std.testing.allocator);
        try expect(approxEq(f64, pr.data.get(v).?, 1.0, 1e-6));
        try expect(pr.converged);
    }

    // Symmetric dyad: scores must be equal and sum to 1.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v1 = try graph.createVertexAssumeCapacity(.{});
        const v2 = try graph.createVertexAssumeCapacity(.{});
        const e = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e, &.{ v1, v2 });
        try graph.build();

        var pr = try graph.computePageRank(.{});
        defer pr.deinit(std.testing.allocator);
        const r1 = pr.data.get(v1).?;
        const r2 = pr.data.get(v2).?;
        try expect(approxEq(f64, r1, 0.5, 1e-6));
        try expect(approxEq(f64, r2, 0.5, 1e-6));
        try expect(approxEq(f64, r1 + r2, 1.0, 1e-9));
        try expect(pr.converged);
    }

    // Sum-to-one property on the full mixed-weight test graph.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);

        var pr = try graph.computePageRank(.{});
        defer pr.deinit(std.testing.allocator);
        try expect(pr.converged);

        var total: f64 = 0;
        var it = pr.data.iterator();
        while (it.next()) |kv| {
            try expect(kv.value_ptr.* > 0);
            total += kv.value_ptr.*;
        }
        try expect(approxEq(f64, total, 1.0, 1e-6));
    }

    // Star topology: a hub vertex shared by every hyperedge should outrank
    // any leaf that appears in only one hyperedge.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const hub = try graph.createVertexAssumeCapacity(.{});
        const leaf_a = try graph.createVertexAssumeCapacity(.{});
        const leaf_b = try graph.createVertexAssumeCapacity(.{});
        const leaf_c = try graph.createVertexAssumeCapacity(.{});
        const e1 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e1, &.{ hub, leaf_a });
        const e2 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e2, &.{ hub, leaf_b });
        const e3 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e3, &.{ hub, leaf_c });
        try graph.build();

        var pr = try graph.computePageRank(.{});
        defer pr.deinit(std.testing.allocator);

        const hub_score = pr.data.get(hub).?;
        try expect(hub_score > pr.data.get(leaf_a).?);
        try expect(hub_score > pr.data.get(leaf_b).?);
        try expect(hub_score > pr.data.get(leaf_c).?);
    }

    // Iteration cap: a tiny budget exits cleanly with `converged = false`.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);
        var pr = try graph.computePageRank(.{ .max_iterations = 1, .tolerance = 0 });
        defer pr.deinit(std.testing.allocator);
        try expect(!pr.converged);
        try expect(pr.iterations == 1);
    }
}

fn hasInclusion(slice: []const h.Graph.InclusionRelation, sub: HypergraphZId, sup: HypergraphZId) bool {
    for (slice) |rel| {
        if (rel.subset == sub and rel.superset == sup) return true;
    }
    return false;
}

test "get inclusions" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.getInclusions());
    }

    // Empty graph.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        var res = try graph.getInclusions();
        defer res.deinit(std.testing.allocator);
        try expect(res.data.len == 0);
    }

    // Disjoint hyperedges share no vertex → no inclusions.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v1 = try graph.createVertexAssumeCapacity(.{});
        const v2 = try graph.createVertexAssumeCapacity(.{});
        const v3 = try graph.createVertexAssumeCapacity(.{});
        const v4 = try graph.createVertexAssumeCapacity(.{});
        const e1 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e1, &.{ v1, v2 });
        const e2 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e2, &.{ v3, v4 });
        try graph.build();

        var res = try graph.getInclusions();
        defer res.deinit(std.testing.allocator);
        try expect(res.data.len == 0);
    }

    // Single strict inclusion: {v1, v2} ⊊ {v1, v2, v3}.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v1 = try graph.createVertexAssumeCapacity(.{});
        const v2 = try graph.createVertexAssumeCapacity(.{});
        const v3 = try graph.createVertexAssumeCapacity(.{});
        const small = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(small, &.{ v1, v2 });
        const large = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(large, &.{ v1, v2, v3 });
        try graph.build();

        var res = try graph.getInclusions();
        defer res.deinit(std.testing.allocator);
        try expect(res.data.len == 1);
        try expect(res.data[0].subset == small);
        try expect(res.data[0].superset == large);
    }

    // Identical distinct sets are NOT strict subsets and must be skipped.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v1 = try graph.createVertexAssumeCapacity(.{});
        const v2 = try graph.createVertexAssumeCapacity(.{});
        const e1 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e1, &.{ v1, v2 });
        const e2 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e2, &.{ v1, v2 });
        try graph.build();

        var res = try graph.getInclusions();
        defer res.deinit(std.testing.allocator);
        try expect(res.data.len == 0);
    }

    // Transitive chain: {v1,v2} ⊊ {v1,v2,v3} ⊊ {v1,v2,v3,v4}. All three
    // strict-subset pairs must be reported (the small ⊊ largest pair too).
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v1 = try graph.createVertexAssumeCapacity(.{});
        const v2 = try graph.createVertexAssumeCapacity(.{});
        const v3 = try graph.createVertexAssumeCapacity(.{});
        const v4 = try graph.createVertexAssumeCapacity(.{});
        const a = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(a, &.{ v1, v2 });
        const b = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(b, &.{ v1, v2, v3 });
        const c = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(c, &.{ v1, v2, v3, v4 });
        try graph.build();

        var res = try graph.getInclusions();
        defer res.deinit(std.testing.allocator);
        try expect(res.data.len == 3);
        try expect(hasInclusion(res.data, a, b));
        try expect(hasInclusion(res.data, a, c));
        try expect(hasInclusion(res.data, b, c));
    }

    // Multiplicity collapse: {v1, v1, v1} has distinct size 1, and is a
    // subset of {v1, v2}.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v1 = try graph.createVertexAssumeCapacity(.{});
        const v2 = try graph.createVertexAssumeCapacity(.{});
        const small = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(small, &.{ v1, v1, v1 });
        const large = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(large, &.{ v1, v2 });
        try graph.build();

        var res = try graph.getInclusions();
        defer res.deinit(std.testing.allocator);
        try expect(res.data.len == 1);
        try expect(res.data[0].subset == small);
        try expect(res.data[0].superset == large);
    }

    // Partial overlap (not subset): {v1, v2} and {v2, v3} share v2 but
    // neither is contained in the other.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v1 = try graph.createVertexAssumeCapacity(.{});
        const v2 = try graph.createVertexAssumeCapacity(.{});
        const v3 = try graph.createVertexAssumeCapacity(.{});
        const e1 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e1, &.{ v1, v2 });
        const e2 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e2, &.{ v2, v3 });
        try graph.build();

        var res = try graph.getInclusions();
        defer res.deinit(std.testing.allocator);
        try expect(res.data.len == 0);
    }
}

test "get nestedness profile" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.getNestednessProfile());
    }

    // Empty graph: empty profile.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        var prof = try graph.getNestednessProfile();
        defer prof.deinit(std.testing.allocator);
        try expect(prof.data.len == 0);
    }

    // Three sizes: 2, 3, 4. The size-2 and size-3 hyperedges are subsets of
    // the size-4 one. Profile must report:
    //   size=2 → included=1, total=1
    //   size=3 → included=1, total=1
    //   size=4 → included=0, total=1
    // and entries must be sorted by size ascending.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v1 = try graph.createVertexAssumeCapacity(.{});
        const v2 = try graph.createVertexAssumeCapacity(.{});
        const v3 = try graph.createVertexAssumeCapacity(.{});
        const v4 = try graph.createVertexAssumeCapacity(.{});
        const a = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(a, &.{ v1, v2 });
        const b = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(b, &.{ v1, v2, v3 });
        const c = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(c, &.{ v1, v2, v3, v4 });
        try graph.build();

        var prof = try graph.getNestednessProfile();
        defer prof.deinit(std.testing.allocator);

        try expect(prof.data.len == 3);
        try expect(prof.data[0].size == 2);
        try expect(prof.data[0].included == 1);
        try expect(prof.data[0].total == 1);
        try expect(prof.data[1].size == 3);
        try expect(prof.data[1].included == 1);
        try expect(prof.data[1].total == 1);
        try expect(prof.data[2].size == 4);
        try expect(prof.data[2].included == 0);
        try expect(prof.data[2].total == 1);
    }

    // A subset hyperedge that participates in two inclusion pairs is still
    // counted once in `included`. e1 = {v1, v2} sits inside both e2 = {v1, v2, v3}
    // and e3 = {v1, v2, v4}. Both inclusions exist, but for size=2 the
    // included count is 1 (e1), not 2.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v1 = try graph.createVertexAssumeCapacity(.{});
        const v2 = try graph.createVertexAssumeCapacity(.{});
        const v3 = try graph.createVertexAssumeCapacity(.{});
        const v4 = try graph.createVertexAssumeCapacity(.{});
        const e1 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e1, &.{ v1, v2 });
        const e2 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e2, &.{ v1, v2, v3 });
        const e3 = try graph.createHyperedgeAssumeCapacity(.{ .weight = 1 });
        try graph.appendVerticesToHyperedge(e3, &.{ v1, v2, v4 });
        try graph.build();

        var prof = try graph.getNestednessProfile();
        defer prof.deinit(std.testing.allocator);

        try expect(prof.data.len == 2);
        try expect(prof.data[0].size == 2);
        try expect(prof.data[0].included == 1);
        try expect(prof.data[0].total == 1);
        try expect(prof.data[1].size == 3);
        try expect(prof.data[1].included == 0);
        try expect(prof.data[1].total == 2);
    }
}

test "find cut vertices" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.findCutVertices());
    }

    // Empty graph: no cut vertices.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        const result = try graph.findCutVertices();
        defer std.testing.allocator.free(result);
        try expect(result.len == 0);
    }

    // Single vertex: no cut vertices.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try graph.createVertexAssumeCapacity(.{});
        try graph.build();
        const result = try graph.findCutVertices();
        defer std.testing.allocator.free(result);
        try expect(result.len == 0);
    }

    // Two vertices, one hyperedge: neither is a cut vertex.
    // Removing either vertex leaves a single-vertex graph (still 1 component).
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const he = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(he, &.{ v_a, v_b });
        try graph.build();
        const result = try graph.findCutVertices();
        defer std.testing.allocator.free(result);
        try expect(result.len == 0);
    }

    // Path v_a – v_b – v_c via two binary hyperedges: v_b is the only cut vertex.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const v_c = try graph.createVertexAssumeCapacity(.{});
        const h1 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h1, &.{ v_a, v_b });
        const h2 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h2, &.{ v_b, v_c });
        try graph.build();
        const result = try graph.findCutVertices();
        defer std.testing.allocator.free(result);
        try expect(result.len == 1);
        try expect(result[0] == v_b);
    }

    // Hyperedge {v_a, v_b, v_c}: clique-expansion makes all three mutually
    // adjacent, so no vertex is a cut vertex.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const v_c = try graph.createVertexAssumeCapacity(.{});
        const he = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(he, &.{ v_a, v_b, v_c });
        try graph.build();
        const result = try graph.findCutVertices();
        defer std.testing.allocator.free(result);
        try expect(result.len == 0);
        _ = .{ v_a, v_b, v_c };
    }

    // Star: center connected to three leaves via separate binary hyperedges.
    // Removing center leaves three isolated leaves → center is the only cut vertex.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const center = try graph.createVertexAssumeCapacity(.{});
        const l1 = try graph.createVertexAssumeCapacity(.{});
        const l2 = try graph.createVertexAssumeCapacity(.{});
        const l3 = try graph.createVertexAssumeCapacity(.{});
        const h1 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h1, &.{ center, l1 });
        const h2 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h2, &.{ center, l2 });
        const h3 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h3, &.{ center, l3 });
        try graph.build();
        const result = try graph.findCutVertices();
        defer std.testing.allocator.free(result);
        try expect(result.len == 1);
        try expect(result[0] == center);
    }

    // Triangle {v_a, v_b, v_c} bridged to tail v_c – v_d – v_e.
    // v_c separates the clique from {v_d, v_e}; v_d separates v_c from v_e.
    // Cut vertices: v_c and v_d, returned in insertion order.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const v_c = try graph.createVertexAssumeCapacity(.{});
        const v_d = try graph.createVertexAssumeCapacity(.{});
        const v_e = try graph.createVertexAssumeCapacity(.{});
        const h1 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h1, &.{ v_a, v_b, v_c });
        const h2 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h2, &.{ v_c, v_d });
        const h3 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h3, &.{ v_d, v_e });
        try graph.build();
        const result = try graph.findCutVertices();
        defer std.testing.allocator.free(result);
        try expect(result.len == 2);
        try expect(result[0] == v_c);
        try expect(result[1] == v_d);
        _ = .{ v_a, v_b };
    }

    // Multiple components: v_b is a cut vertex in {v_a, v_b, v_c};
    // the isolated fourth vertex contributes no cut vertices.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const v_c = try graph.createVertexAssumeCapacity(.{});
        _ = try graph.createVertexAssumeCapacity(.{}); // isolated
        const h1 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h1, &.{ v_a, v_b });
        const h2 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h2, &.{ v_b, v_c });
        try graph.build();
        const result = try graph.findCutVertices();
        defer std.testing.allocator.free(result);
        try expect(result.len == 1);
        try expect(result[0] == v_b);
    }
}
