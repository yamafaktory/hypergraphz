const std = @import("std");
const h = @import("helpers.zig");

const ArrayListUnmanaged = std.ArrayListUnmanaged;
const HypergraphZId = h.HypergraphZId;
const HypergraphZError = h.HypergraphZError;
const expect = h.expect;
const expectEqualSlices = h.expectEqualSlices;
const expectError = h.expectError;
const max_id = h.max_id;

test "append vertex to hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    const first_vertex_id = try graph.createVertex(.{});
    const second_vertex_id = try graph.createVertex(.{});
    try expect(first_vertex_id != 0);

    try expectError(HypergraphZError.HyperedgeNotFound, graph.appendVertexToHyperedge(max_id, max_id));

    try expectError(HypergraphZError.VertexNotFound, graph.appendVertexToHyperedge(hyperedge_id, max_id));

    try graph.appendVertexToHyperedge(hyperedge_id, first_vertex_id);
    try graph.appendVertexToHyperedge(hyperedge_id, second_vertex_id);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 2);
    try expect(vertices[0] == first_vertex_id);
    try expect(vertices[1] == second_vertex_id);
}

test "prepend vertex to hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    const first_vertex_id = try graph.createVertex(.{});
    const second_vertex_id = try graph.createVertex(.{});
    try expect(first_vertex_id != 0);

    try expectError(HypergraphZError.HyperedgeNotFound, graph.prependVertexToHyperedge(max_id, max_id));

    try expectError(HypergraphZError.VertexNotFound, graph.prependVertexToHyperedge(hyperedge_id, max_id));

    try graph.prependVertexToHyperedge(hyperedge_id, first_vertex_id);
    try graph.prependVertexToHyperedge(hyperedge_id, second_vertex_id);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 2);
    try expect(vertices[0] == second_vertex_id);
    try expect(vertices[1] == first_vertex_id);
}

test "insert vertex into hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    const first_vertex_id = try graph.createVertex(.{});
    const second_vertex_id = try graph.createVertex(.{});
    try expect(first_vertex_id != 0);

    try expectError(HypergraphZError.HyperedgeNotFound, graph.insertVertexIntoHyperedge(max_id, max_id, 0));

    try expectError(HypergraphZError.VertexNotFound, graph.insertVertexIntoHyperedge(hyperedge_id, max_id, 0));

    try expectError(HypergraphZError.IndexOutOfBounds, graph.insertVertexIntoHyperedge(hyperedge_id, first_vertex_id, 10));

    try graph.insertVertexIntoHyperedge(hyperedge_id, first_vertex_id, 0);
    try graph.insertVertexIntoHyperedge(hyperedge_id, second_vertex_id, 0);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 2);
    try expect(vertices[0] == second_vertex_id);
    try expect(vertices[1] == first_vertex_id);
}

test "append vertices to hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr: ArrayListUnmanaged(HypergraphZId) = .empty;
    defer arr.deinit(std.testing.allocator);
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(std.testing.allocator, id);
    }
    const ids = arr.items;

    try expectError(HypergraphZError.HyperedgeNotFound, graph.appendVerticesToHyperedge(max_id, ids));

    try expect(try graph.appendVerticesToHyperedge(hyperedge_id, &.{}) == undefined);

    // Append first vertex, then the rest and check that appending works.
    try graph.appendVertexToHyperedge(hyperedge_id, ids[0]);
    try graph.appendVerticesToHyperedge(hyperedge_id, ids[1..nb_vertices]);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == nb_vertices);
    try graph.build();
    for (ids, 0..) |id, i| {
        try expect(vertices[i] == id);
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 1);
        try expect(hyperedges[0] == hyperedge_id);
    }
}

test "prepend vertices to hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr: ArrayListUnmanaged(HypergraphZId) = .empty;
    defer arr.deinit(std.testing.allocator);
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(std.testing.allocator, id);
    }
    const ids = arr.items;

    try expectError(HypergraphZError.HyperedgeNotFound, graph.prependVerticesToHyperedge(max_id, ids));

    try expect(try graph.prependVerticesToHyperedge(hyperedge_id, &.{}) == undefined);

    // Prepend the last vertex, then the rest and check that prepending works.
    try graph.prependVertexToHyperedge(hyperedge_id, ids[nb_vertices - 1]);
    try graph.prependVerticesToHyperedge(hyperedge_id, ids[0 .. nb_vertices - 1]);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == nb_vertices);
    try graph.build();
    for (ids, 0..) |id, i| {
        try expect(vertices[i] == id);
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 1);
        try expect(hyperedges[0] == hyperedge_id);
    }
}

test "insert vertices into hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr: ArrayListUnmanaged(HypergraphZId) = .empty;
    defer arr.deinit(std.testing.allocator);
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(std.testing.allocator, id);
    }
    const ids = arr.items;

    try expectError(HypergraphZError.HyperedgeNotFound, graph.insertVerticesIntoHyperedge(max_id, ids, 0));

    try expectError(HypergraphZError.NoVerticesToInsert, graph.insertVerticesIntoHyperedge(hyperedge_id, &.{}, 0));

    try expectError(HypergraphZError.IndexOutOfBounds, graph.insertVerticesIntoHyperedge(hyperedge_id, ids, 10));

    // Insert the first vertex, then the rest and check that inserting works.
    try graph.insertVertexIntoHyperedge(hyperedge_id, ids[0], 0);
    try graph.insertVerticesIntoHyperedge(hyperedge_id, ids[1..nb_vertices], 1);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == nb_vertices);
    try graph.build();
    for (ids, 0..) |id, i| {
        try expect(vertices[i] == id);
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 1);
        try expect(hyperedges[0] == hyperedge_id);
    }
}

test "delete vertex from hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    const vertex_id = try graph.createVertex(.{});

    // Insert the vertex twice.
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);

    try graph.build();

    try expectError(HypergraphZError.HyperedgeNotFound, graph.deleteVertexFromHyperedge(max_id, vertex_id));

    try expectError(HypergraphZError.VertexNotFound, graph.deleteVertexFromHyperedge(hyperedge_id, max_id));

    try graph.deleteVertexFromHyperedge(hyperedge_id, vertex_id);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 0);

    const hyperedges = try graph.getVertexHyperedges(vertex_id);
    try expect(hyperedges.len == 0);
}

test "delete vertex by index from hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    // Create 10 vertices and store their ids.
    // Last two vertices are duplicated.
    const nb_vertices = 10;
    var arr: ArrayListUnmanaged(HypergraphZId) = .empty;
    defer arr.deinit(std.testing.allocator);
    for (0..nb_vertices, 0..) |_, i| {
        if (i == nb_vertices - 1) {
            try arr.append(std.testing.allocator, arr.items[arr.items.len - 1]);
            continue;
        }
        const id = try graph.createVertex(.{});
        try arr.append(std.testing.allocator, id);
    }
    const ids = arr.items;

    // Append vertices to the hyperedge.
    try graph.appendVerticesToHyperedge(hyperedge_id, ids);

    try graph.build();

    try expectError(HypergraphZError.HyperedgeNotFound, graph.deleteVertexByIndexFromHyperedge(max_id, 0));

    // Delete the first vertex.
    // The hyperedge should be dropped from the relations.
    try graph.deleteVertexByIndexFromHyperedge(hyperedge_id, 0);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == nb_vertices - 1);
    for (ids[1..], 0..) |id, i| {
        try expect(vertices[i] == id);
    }
    const first_vertex_hyperedges = try graph.getVertexHyperedges(ids[0]);
    try expect(first_vertex_hyperedges.len == 0);

    // Delete the last vertex.
    // The hyperedge should not be dropped from the relations.
    try graph.deleteVertexByIndexFromHyperedge(hyperedge_id, nb_vertices - 2);
    const last_vertex_hyperedges = try graph.getVertexHyperedges(ids[nb_vertices - 3]);
    try expect(last_vertex_hyperedges.len == 1);
}

test "delete hyperedge only" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr: ArrayListUnmanaged(HypergraphZId) = .empty;
    defer arr.deinit(std.testing.allocator);
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(std.testing.allocator, id);
    }
    // Add the same vertex twice.
    try arr.append(std.testing.allocator, arr.items[arr.items.len - 1]);
    const ids = arr.items;

    try graph.appendVerticesToHyperedge(hyperedge_id, ids);

    try graph.build();
    try graph.deleteHyperedge(hyperedge_id, false);
    for (ids) |id| {
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 0);
    }

    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedge(hyperedge_id));
}

test "delete hyperedge and vertices" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr: ArrayListUnmanaged(HypergraphZId) = .empty;
    defer arr.deinit(std.testing.allocator);
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(std.testing.allocator, id);
    }
    // Add the same vertex twice.
    try arr.append(std.testing.allocator, arr.items[arr.items.len - 1]);
    const ids = arr.items;

    try graph.appendVerticesToHyperedge(hyperedge_id, ids);

    try graph.deleteHyperedge(hyperedge_id, true);
    for (ids) |id| {
        try expectError(HypergraphZError.VertexNotFound, graph.getVertex(id));
    }

    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedge(hyperedge_id));
}

test "delete vertex" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    const vertex_id = try graph.createVertex(.{});

    // Insert the vertex twice.
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);

    try graph.build();

    try expectError(HypergraphZError.VertexNotFound, graph.deleteVertex(max_id));

    try graph.deleteVertex(vertex_id);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 0);
    try expectError(HypergraphZError.VertexNotFound, graph.getVertex(vertex_id));
}

test "reverse hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.HyperedgeNotFound, graph.reverseHyperedge(max_id));

    try graph.reverseHyperedge(data.h_a);
    const vertices = try graph.getHyperedgeVertices(data.h_a);
    try expect(vertices.len == 5);
    try expect(vertices[0] == data.v_e);
    try expect(vertices[4] == data.v_a);
}

test "merge hyperedges" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.HyperedgeNotFound, graph.mergeHyperedges(&[_]HypergraphZId{ max_id - 1, max_id }));
    try expectError(HypergraphZError.NotEnoughHyperedgesProvided, graph.mergeHyperedges(&[_]HypergraphZId{data.h_a}));

    try graph.mergeHyperedges(&[_]HypergraphZId{ data.h_a, data.h_c });
    const vertices = try graph.getHyperedgeVertices(data.h_a);
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{
        data.v_a, data.v_b, data.v_c, data.v_d, data.v_e,
        data.v_b, data.v_c, data.v_c, data.v_e, data.v_a,
        data.v_d, data.v_b,
    }, vertices);
    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedge(data.h_c));
}

test "split hyperedge" {
    // Error: not built.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        const he = try graph.createHyperedge(.{});
        try expectError(HypergraphZError.NotBuilt, graph.splitHyperedge(he, 1, .{}));
    }

    var graph = try h.scaffold();
    defer graph.deinit();
    const d = try h.generateTestData(&graph);

    // Error: hyperedge not found.
    try expectError(HypergraphZError.HyperedgeNotFound, graph.splitHyperedge(max_id, 1, .{}));

    // Error: at=0 or at>=len are out of bounds.
    try expectError(HypergraphZError.IndexOutOfBounds, graph.splitHyperedge(d.h_a, 0, .{}));
    try expectError(HypergraphZError.IndexOutOfBounds, graph.splitHyperedge(d.h_a, 5, .{}));

    // Split h_a=[a,b,c,d,e] at 2 → first=[a,b], new=[c,d,e].
    const new_h = try graph.splitHyperedge(d.h_a, 2, .{});

    const h_a_verts = try graph.getHyperedgeVertices(d.h_a);
    try expectEqualSlices(HypergraphZId, &.{ d.v_a, d.v_b }, h_a_verts);

    const new_h_verts = try graph.getHyperedgeVertices(new_h);
    try expectEqualSlices(HypergraphZId, &.{ d.v_c, d.v_d, d.v_e }, new_h_verts);

    // Reverse index: a and b stay in h_a; c, d, e move to new_h.
    const v_a_hyperedges = try graph.getVertexHyperedges(d.v_a);
    try expect(std.mem.indexOfScalar(HypergraphZId, v_a_hyperedges, d.h_a) != null);
    try expect(std.mem.indexOfScalar(HypergraphZId, v_a_hyperedges, new_h) == null);

    const v_c_hyperedges = try graph.getVertexHyperedges(d.v_c);
    try expect(std.mem.indexOfScalar(HypergraphZId, v_c_hyperedges, d.h_a) == null);
    try expect(std.mem.indexOfScalar(HypergraphZId, v_c_hyperedges, new_h) != null);

    // h_b and h_c are untouched.
    const h_b_verts = try graph.getHyperedgeVertices(d.h_b);
    try expectEqualSlices(HypergraphZId, &.{ d.v_e, d.v_e, d.v_a }, h_b_verts);
    const h_c_verts = try graph.getHyperedgeVertices(d.h_c);
    try expectEqualSlices(HypergraphZId, &.{ d.v_b, d.v_c, d.v_c, d.v_e, d.v_a, d.v_d, d.v_b }, h_c_verts);
}

test "contract hyperedge" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try graph.contractHyperedge(data.h_b);

    const h_a = try graph.getHyperedgeVertices(data.h_a);
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_b, data.v_c, data.v_d, data.v_a }, h_a);

    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedgeVertices(data.h_b));

    const h_c = try graph.getHyperedgeVertices(data.h_c);
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_b, data.v_c, data.v_c, data.v_a, data.v_d, data.v_b }, h_c);
}

test "clear hypergraph" {
    var graph = try h.scaffold();
    defer graph.deinit();

    graph.clear();
    const hyperedges = graph.getAllHyperedges();
    const vertices = graph.getAllVertices();
    try expect(hyperedges.len == 0);
    try expect(vertices.len == 0);
}

test "merge vertices" {
    // Error: not built.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.mergeVertices(&.{ 1, 2 }));
    }

    var graph = try h.scaffold();
    defer graph.deinit();
    const d = try h.generateTestData(&graph);

    // Error: fewer than two vertices.
    try expectError(HypergraphZError.NotEnoughVerticesProvided, graph.mergeVertices(&.{d.v_b}));

    // Error: vertex not found.
    try expectError(HypergraphZError.VertexNotFound, graph.mergeVertices(&.{ d.v_b, max_id }));

    // Merge v_c into v_b (primary = v_b).
    // h_a was [a,b,c,d,e] → replace c→b → [a,b,b,d,e] → dedup → [a,b,d,e]
    // h_c was [b,c,c,e,a,d,b] → replace c→b → [b,b,b,e,a,d,b] → dedup → [b,e,a,d,b]
    // h_b is [e,e,a] — unaffected (no c or b).
    try graph.mergeVertices(&.{ d.v_b, d.v_c });

    // v_c no longer exists.
    try expectError(HypergraphZError.VertexNotFound, graph.checkIfVertexExists(d.v_c));

    // Vertex count dropped from 5 to 4.
    try expect(graph.vertices.count() == 4);

    // h_a relations are now [a,b,d,e].
    const h_a_verts = try graph.getHyperedgeVertices(d.h_a);
    try expectEqualSlices(HypergraphZId, &.{ d.v_a, d.v_b, d.v_d, d.v_e }, h_a_verts);

    // h_b relations are unchanged.
    const h_b_verts = try graph.getHyperedgeVertices(d.h_b);
    try expectEqualSlices(HypergraphZId, &.{ d.v_e, d.v_e, d.v_a }, h_b_verts);

    // h_c relations are now [b,e,a,d,b].
    const h_c_verts = try graph.getHyperedgeVertices(d.h_c);
    try expectEqualSlices(HypergraphZId, &.{ d.v_b, d.v_e, d.v_a, d.v_d, d.v_b }, h_c_verts);

    // v_b's reverse index still contains h_a and h_c.
    const v_b_hyperedges = try graph.getVertexHyperedges(d.v_b);
    try expect(v_b_hyperedges.len == 2);
}

test "split vertex" {
    // Error: not built.
    {
        var graph = try h.scaffold();
        defer graph.deinit();
        try expectError(HypergraphZError.NotBuilt, graph.splitVertex(1, &.{2}, .{}));
    }

    var graph = try h.scaffold();
    defer graph.deinit();
    const d = try h.generateTestData(&graph);

    // Error: vertex not found.
    try expectError(HypergraphZError.VertexNotFound, graph.splitVertex(max_id, &.{d.h_a}, .{}));

    // Error: no hyperedges provided.
    try expectError(HypergraphZError.NotEnoughHyperedgesProvided, graph.splitVertex(d.v_a, &.{}, .{}));

    // Error: hyperedge not found.
    try expectError(HypergraphZError.HyperedgeNotFound, graph.splitVertex(d.v_a, &.{max_id}, .{}));

    // Split v_a: move h_b to a new vertex.
    // v_a is in h_a=[a,b,c,d,e], h_b=[e,e,a], h_c=[b,c,c,e,a,d,b].
    // After split: v_a keeps h_a and h_c; new_v gets h_b.
    // h_b=[e,e,a] → replace a→new_v → [e,e,new_v].
    const new_v = try graph.splitVertex(d.v_a, &.{d.h_b}, .{});

    // Vertex count increased from 5 to 6.
    try expect(graph.vertices.count() == 6);

    // h_b now contains new_v instead of v_a.
    const h_b_verts = try graph.getHyperedgeVertices(d.h_b);
    try expectEqualSlices(HypergraphZId, &.{ d.v_e, d.v_e, new_v }, h_b_verts);

    // h_a and h_c are unchanged.
    const h_a_verts = try graph.getHyperedgeVertices(d.h_a);
    try expectEqualSlices(HypergraphZId, &.{ d.v_a, d.v_b, d.v_c, d.v_d, d.v_e }, h_a_verts);
    const h_c_verts = try graph.getHyperedgeVertices(d.h_c);
    try expectEqualSlices(HypergraphZId, &.{ d.v_b, d.v_c, d.v_c, d.v_e, d.v_a, d.v_d, d.v_b }, h_c_verts);

    // Reverse index: v_a no longer has h_b; new_v has only h_b.
    const v_a_hyperedges = try graph.getVertexHyperedges(d.v_a);
    try expect(std.mem.indexOfScalar(HypergraphZId, v_a_hyperedges, d.h_b) == null);
    try expect(std.mem.indexOfScalar(HypergraphZId, v_a_hyperedges, d.h_a) != null);

    const new_v_hyperedges = try graph.getVertexHyperedges(new_v);
    try expectEqualSlices(HypergraphZId, &.{d.h_b}, new_v_hyperedges);
}
