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

fn defaultHyperedgeToVertex(_: Hyperedge) Vertex {
    return .{};
}

fn defaultVertexToHyperedge(_: Vertex) Hyperedge {
    return .{};
}

test "expand to graph" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.expandToGraph());
    }

    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const data = try h.generateTestData(&graph);

        var expanded = try graph.expandToGraph();
        defer expanded.deinit();

        // All 5 vertices are preserved; hyperedges are the window pairs:
        // h_a(5 verts) → 4 pairs, h_b(3 verts) → 2 pairs, h_c(7 verts) → 6 pairs.
        try expect(expanded.countVertices() == 5);
        try expect(expanded.countHyperedges() == 12);

        try expanded.build();

        // Result is a plain directed graph.
        try expect(try expanded.isKUniform(2));

        // IDs: vertices kept as 1-5, new hyperedges start at 6.
        // h_a pairs → IDs 6,7,8,9; h_b pairs → 10,11; h_c pairs → 12..17.
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_b }, try expanded.getHyperedgeVertices(6));
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_d, data.v_e }, try expanded.getHyperedgeVertices(9));
        // h_b self-loop pair (v_e, v_e).
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_e, data.v_e }, try expanded.getHyperedgeVertices(10));
        // Inherited h_a data (weight=1).
        try expect((try expanded.getHyperedge(6)).weight == 1);
    }
}

test "is k-uniform" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.isKUniform(3));
    }

    // Empty hyperedge set is vacuously true for any k.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try graph.build();
        try expect(try graph.isKUniform(0));
        try expect(try graph.isKUniform(3));
    }

    // Main test graph has mixed sizes (3, 5, 7) — not uniform for any k.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        _ = try h.generateTestData(&graph);
        try expect(!try graph.isKUniform(3));
        try expect(!try graph.isKUniform(5));
    }

    // Hand-built 3-uniform graph: every hyperedge has exactly 3 vertices.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const v_a = try graph.createVertexAssumeCapacity(.{});
        const v_b = try graph.createVertexAssumeCapacity(.{});
        const v_c = try graph.createVertexAssumeCapacity(.{});
        const v_d = try graph.createVertexAssumeCapacity(.{});
        const h1 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h1, &.{ v_a, v_b, v_c });
        const h2 = try graph.createHyperedgeAssumeCapacity(.{});
        try graph.appendVerticesToHyperedge(h2, &.{ v_b, v_c, v_d });
        try graph.build();
        try expect(try graph.isKUniform(3));
        try expect(!try graph.isKUniform(2));
        try expect(!try graph.isKUniform(4));
    }
}

test "get vertex-induced subhypergraph" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.getVertexInducedSubhypergraph(&.{}));
    }

    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const data = try h.generateTestData(&graph);

        // Unknown vertex → VertexNotFound.
        try expectError(HypergraphZError.VertexNotFound, graph.getVertexInducedSubhypergraph(&.{max_id}));

        // Empty vertex set → empty subhypergraph.
        {
            var sub = try graph.getVertexInducedSubhypergraph(&.{});
            defer sub.deinit();
            try expect(sub.countVertices() == 0);
            try expect(sub.countHyperedges() == 0);
        }

        // {v_e, v_a}: only h_b = [v_e, v_e, v_a] has all vertices in the set.
        // h_a = [a,b,c,d,e] contains b,c,d → dropped.
        // h_c = [b,c,c,e,a,d,b] contains b,c,d → dropped.
        {
            var sub = try graph.getVertexInducedSubhypergraph(&.{ data.v_e, data.v_a });
            defer sub.deinit();
            try expect(sub.countVertices() == 2);
            try expect(sub.countHyperedges() == 1);
            try sub.build();
            const verts = try sub.getHyperedgeVertices(data.h_b);
            try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_e, data.v_e, data.v_a }, verts);
        }

        // All 5 vertices → all 3 hyperedges retained.
        {
            var sub = try graph.getVertexInducedSubhypergraph(
                &.{ data.v_a, data.v_b, data.v_c, data.v_d, data.v_e },
            );
            defer sub.deinit();
            try expect(sub.countVertices() == 5);
            try expect(sub.countHyperedges() == 3);
        }
    }
}

test "get hyperedge-induced subhypergraph" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.getEdgeInducedSubhypergraph(&.{}));
    }

    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const data = try h.generateTestData(&graph);

        // Unknown hyperedge → HyperedgeNotFound.
        try expectError(HypergraphZError.HyperedgeNotFound, graph.getEdgeInducedSubhypergraph(&.{max_id}));

        // Empty hyperedge set → no vertices, no hyperedges.
        {
            var sub = try graph.getEdgeInducedSubhypergraph(&.{});
            defer sub.deinit();
            try expect(sub.countVertices() == 0);
            try expect(sub.countHyperedges() == 0);
        }

        // {h_b} = [v_e, v_e, v_a] → 2 unique vertices (v_e, v_a), 1 hyperedge.
        {
            var sub = try graph.getEdgeInducedSubhypergraph(&.{data.h_b});
            defer sub.deinit();
            try expect(sub.countVertices() == 2);
            try expect(sub.countHyperedges() == 1);
            try sub.build();
            const verts = try sub.getHyperedgeVertices(data.h_b);
            try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_e, data.v_e, data.v_a }, verts);
        }

        // {h_a, h_b}: h_a uses all 5 vertices, h_b adds nothing new → 5 vertices, 2 hyperedges.
        {
            var sub = try graph.getEdgeInducedSubhypergraph(&.{ data.h_a, data.h_b });
            defer sub.deinit();
            try expect(sub.countVertices() == 5);
            try expect(sub.countHyperedges() == 2);
        }
    }
}

test "get k-skeleton" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.getKSkeleton(2));
    }

    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const data = try h.generateTestData(&graph);

        // k=2: no hyperedge has <= 2 vertices, all are filtered out.
        {
            var sk = try graph.getKSkeleton(2);
            defer sk.deinit();
            try expect(sk.countVertices() == 5);
            try expect(sk.countHyperedges() == 0);
        }

        // k=3: only h_b ([v_e,v_e,v_a], len=3) is retained.
        {
            var sk = try graph.getKSkeleton(3);
            defer sk.deinit();
            try sk.build();
            try expect(sk.countVertices() == 5);
            try expect(sk.countHyperedges() == 1);
            const verts = try sk.getHyperedgeVertices(data.h_b);
            try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_e, data.v_e, data.v_a }, verts);
        }

        // k=5: h_a (len=5) and h_b (len=3) are retained; h_c (len=7) is dropped.
        {
            var sk = try graph.getKSkeleton(5);
            defer sk.deinit();
            try sk.build();
            try expect(sk.countVertices() == 5);
            try expect(sk.countHyperedges() == 2);
            const a_verts = try sk.getHyperedgeVertices(data.h_a);
            try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_b, data.v_c, data.v_d, data.v_e }, a_verts);
        }

        // k=7: all three hyperedges are retained.
        {
            var sk = try graph.getKSkeleton(7);
            defer sk.deinit();
            try expect(sk.countVertices() == 5);
            try expect(sk.countHyperedges() == 3);
        }
    }
}

test "get dual" {
    // NotBuilt guard.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.getDual(defaultHyperedgeToVertex, defaultVertexToHyperedge));
    }

    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const data = try h.generateTestData(&graph);

        var dual = try graph.getDual(defaultHyperedgeToVertex, defaultVertexToHyperedge);
        defer dual.deinit();

        // Dual swaps vertices and hyperedges.
        try expect(dual.countVertices() == 3);
        try expect(dual.countHyperedges() == 5);

        // IDs: vertices 1-3 (one per original hyperedge, in h_a/h_b/h_c order),
        // hyperedges 4-8 (one per original vertex, in v_a..v_e order).
        const dv_ha: HypergraphZId = 1;
        const dv_hb: HypergraphZId = 2;
        const dv_hc: HypergraphZId = 3;
        const dh_va: HypergraphZId = 4; // v_a was in h_a, h_b, h_c
        const dh_vb: HypergraphZId = 5; // v_b was in h_a, h_c
        const dh_ve: HypergraphZId = 8; // v_e was in h_a, h_b, h_c

        try dual.build();

        // v_a belonged to h_a, h_b, h_c → dual hyperedge connects dv_ha, dv_hb, dv_hc.
        const va_verts = try dual.getHyperedgeVertices(dh_va);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ dv_ha, dv_hb, dv_hc }, va_verts);

        // v_b belonged to h_a, h_c → dual hyperedge connects dv_ha, dv_hc.
        const vb_verts = try dual.getHyperedgeVertices(dh_vb);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ dv_ha, dv_hc }, vb_verts);

        // v_e belonged to h_a, h_b, h_c → same as v_a.
        const ve_verts = try dual.getHyperedgeVertices(dh_ve);
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ dv_ha, dv_hb, dv_hc }, ve_verts);

        // Dual of dual recovers the original vertex/hyperedge counts.
        var double_dual = try dual.getDual(defaultHyperedgeToVertex, defaultVertexToHyperedge);
        defer double_dual.deinit();
        try expect(double_dual.countVertices() == graph.countVertices());
        try expect(double_dual.countHyperedges() == graph.countHyperedges());

        _ = data;
    }
}

test "projection results own their data independently" {
    var graph = try h.scaffold();
    const data = try h.generateTestData(&graph);

    var skeleton = try graph.getKSkeleton(7);
    defer skeleton.deinit();
    var v_sub = try graph.getVertexInducedSubhypergraph(
        &.{ data.v_a, data.v_b, data.v_c, data.v_d, data.v_e },
    );
    defer v_sub.deinit();
    var e_sub = try graph.getEdgeInducedSubhypergraph(&.{data.h_a});
    defer e_sub.deinit();
    var expanded = try graph.expandToGraph();
    defer expanded.deinit();

    // Mutating any result must not bleed into the parent.
    try skeleton.updateVertex(data.v_a, .{ .purr = true });
    try v_sub.updateVertex(data.v_a, .{ .purr = true });
    try e_sub.updateVertex(data.v_a, .{ .purr = true });
    try expanded.updateVertex(data.v_a, .{ .purr = true });
    try expect((try graph.getVertex(data.v_a)).purr == false);

    // Deinit'ing the parent must leave every result fully usable.
    graph.deinit();
    try expect((try skeleton.getVertex(data.v_a)).purr == true);
    try expect((try v_sub.getVertex(data.v_a)).purr == true);
    try expect((try e_sub.getVertex(data.v_a)).purr == true);
    try expect((try expanded.getVertex(data.v_a)).purr == true);
}

test "incidence matrix" {
    var graph = try h.scaffold();
    defer graph.deinit();

    // Empty graph: 0x0 matrix.
    {
        var m = try graph.toIncidenceMatrix(std.testing.allocator);
        defer m.deinit(std.testing.allocator);
        try expect(m.rows == 0);
        try expect(m.cols == 0);
        try expect(m.data.len == 0);
    }

    const data = try h.generateTestData(&graph);

    var m = try graph.toIncidenceMatrix(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    // 5 vertices, 3 hyperedges.
    try expect(m.rows == 5);
    try expect(m.cols == 3);
    try expectEqualSlices(
        HypergraphZId,
        &.{ data.v_a, data.v_b, data.v_c, data.v_d, data.v_e },
        m.vertex_ids,
    );
    try expectEqualSlices(
        HypergraphZId,
        &.{ data.h_a, data.h_b, data.h_c },
        m.hyperedge_ids,
    );

    // h_a contains all 5 vertices → column 0 is all 1s.
    for (0..5) |row| try expect(m.at(row, 0) == 1);

    // h_b contains v_e (twice) and v_a → column 1 has 1s only at v_a (row 0) and v_e (row 4).
    try expect(m.at(0, 1) == 1);
    try expect(m.at(1, 1) == 0);
    try expect(m.at(2, 1) == 0);
    try expect(m.at(3, 1) == 0);
    try expect(m.at(4, 1) == 1);

    // h_c contains v_b, v_c (twice), v_e, v_a, v_d, v_b (twice) → all 5 are present.
    for (0..5) |row| try expect(m.at(row, 2) == 1);
}

test "incidence matrix COO" {
    var graph = try h.scaffold();
    defer graph.deinit();

    // Empty graph: 0x0 with no entries.
    {
        var m = try graph.toIncidenceMatrixCOO(std.testing.allocator);
        defer m.deinit(std.testing.allocator);
        try expect(m.rows == 0);
        try expect(m.cols == 0);
        try expect(m.entries.len == 0);
    }

    const data = try h.generateTestData(&graph);
    _ = data;

    var m = try graph.toIncidenceMatrixCOO(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    try expect(m.rows == 5);
    try expect(m.cols == 3);

    // h_a (col 0): all 5 vertices → 5 entries.
    // h_b (col 1): {v_a, v_e} after dedup → 2 entries.
    // h_c (col 2): {v_b, v_c, v_e, v_a, v_d} after dedup → 5 entries.
    // Total: 12 entries.
    try expect(m.entries.len == 12);

    // Cross-check against the dense matrix: COO entries must exactly match
    // the set of 1-positions, and no duplicates may be emitted.
    var dense = try graph.toIncidenceMatrix(std.testing.allocator);
    defer dense.deinit(std.testing.allocator);
    var ones: usize = 0;
    for (dense.data) |b| ones += b;
    try expect(ones == m.entries.len);
    for (m.entries) |e| try expect(dense.at(e.row, e.col) == 1);
}
