const std = @import("std");
const h = @import("helpers.zig");

const HypergraphZId = h.HypergraphZId;
const HypergraphZError = h.HypergraphZError;
const Vertex = h.Vertex;
const expect = h.expect;
const expectEqualSlices = h.expectEqualSlices;
const expectError = h.expectError;
const max_id = h.max_id;

test "get hyperedge vertices" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    const nb_vertices = 10;
    for (0..nb_vertices) |_| {
        const vertex_id = try graph.createVertex(.{});
        try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);
    }

    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedgeVertices(max_id));

    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == nb_vertices);
}

test "get vertex hyperedges" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    const vertex_id = try graph.createVertex(.{});
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);

    try graph.build();

    try expectError(HypergraphZError.VertexNotFound, graph.getVertexHyperedges(max_id));

    const hyperedges = try graph.getVertexHyperedges(vertex_id);
    try expect(hyperedges.len == 1);
}

test "get vertex indegree" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.getVertexIndegree(max_id));

    try expect(try graph.getVertexIndegree(data.v_a) == 2);
    try expect(try graph.getVertexIndegree(data.v_b) == 2);
    try expect(try graph.getVertexIndegree(data.v_c) == 3);
    try expect(try graph.getVertexIndegree(data.v_d) == 2);
    try expect(try graph.getVertexIndegree(data.v_e) == 3);

    // Asymmetric graph: h = [v_a, v_b, v_c, v_b]
    // Pairs: [v_a,v_b], [v_b,v_c], [v_c,v_b]
    // Indegree: v_a=0, v_b=2, v_c=1
    var asymmetric = try h.scaffold();
    defer asymmetric.deinit();
    const he = try asymmetric.createHyperedge(.{});
    const v_a = try asymmetric.createVertex(.{});
    const v_b = try asymmetric.createVertex(.{});
    const v_c = try asymmetric.createVertex(.{});
    try asymmetric.appendVerticesToHyperedge(he, &.{ v_a, v_b, v_c, v_b });
    try asymmetric.build();
    try expect(try asymmetric.getVertexIndegree(v_a) == 0);
    try expect(try asymmetric.getVertexIndegree(v_b) == 2);
    try expect(try asymmetric.getVertexIndegree(v_c) == 1);
}

test "get vertex outdegree" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.getVertexOutdegree(max_id));

    try expect(try graph.getVertexOutdegree(data.v_a) == 2);
    try expect(try graph.getVertexOutdegree(data.v_b) == 2);
    try expect(try graph.getVertexOutdegree(data.v_c) == 3);
    try expect(try graph.getVertexOutdegree(data.v_d) == 2);
    try expect(try graph.getVertexOutdegree(data.v_e) == 3);

    // Asymmetric graph: h = [v_a, v_b, v_c, v_b]
    // Pairs: [v_a,v_b], [v_b,v_c], [v_c,v_b]
    // Outdegree: v_a=1, v_b=1, v_c=1 — add second hyperedge to break symmetry
    // h2 = [v_a, v_b]: pair [v_a,v_b]
    // Combined outdegree: v_a=2, v_b=1, v_c=1
    var asymmetric = try h.scaffold();
    defer asymmetric.deinit();
    const he = try asymmetric.createHyperedge(.{});
    const h2 = try asymmetric.createHyperedge(.{});
    const v_a = try asymmetric.createVertex(.{});
    const v_b = try asymmetric.createVertex(.{});
    const v_c = try asymmetric.createVertex(.{});
    try asymmetric.appendVerticesToHyperedge(he, &.{ v_a, v_b, v_c, v_b });
    try asymmetric.appendVerticesToHyperedge(h2, &.{ v_a, v_b });
    try asymmetric.build();
    try expect(try asymmetric.getVertexOutdegree(v_a) == 2);
    try expect(try asymmetric.getVertexOutdegree(v_b) == 1);
    try expect(try asymmetric.getVertexOutdegree(v_c) == 1);
}

test "get intersections" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.NotEnoughHyperedgesProvided, graph.getIntersections(&[_]HypergraphZId{1}));

    const hyperedges = [_]HypergraphZId{ data.h_a, data.h_b, data.h_c };
    const expected = [_]HypergraphZId{ data.v_e, data.v_a };
    const intersections = try graph.getIntersections(&hyperedges);
    defer graph.allocator.free(intersections);
    try expectEqualSlices(HypergraphZId, &expected, intersections);
}

test "get vertex adjacency to" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.getVertexAdjacencyTo(max_id));

    {
        var result = try graph.getVertexAdjacencyTo(data.v_a);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_b);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_e);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_e);
            }
            i += 1;
        }
    }

    {
        var result = try graph.getVertexAdjacencyTo(data.v_b);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_a);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_a);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_d);
            }
            i += 1;
        }
    }

    {
        var result = try graph.getVertexAdjacencyTo(data.v_c);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_a);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_b);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
                try expect(kv.value_ptr.*.items.len == 2);
                try expect(kv.value_ptr.*.items[0] == data.v_b);
                try expect(kv.value_ptr.*.items[1] == data.v_c);
            }
            i += 1;
        }
    }

    {
        var result = try graph.getVertexAdjacencyTo(data.v_d);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_a);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_c);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_a);
            }
            i += 1;
        }
    }

    {
        var result = try graph.getVertexAdjacencyTo(data.v_e);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 3);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_a);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_d);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_b);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_e);
            } else if (i == 2) {
                try expect(kv.key_ptr.* == data.h_c);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_c);
            }
            i += 1;
        }
    }
}

test "get vertex adjacency from" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.getVertexAdjacencyFrom(max_id));

    {
        var result = try graph.getVertexAdjacencyFrom(data.v_a);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_a);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_b);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_d);
            }
            i += 1;
        }
    }

    {
        var result = try graph.getVertexAdjacencyFrom(data.v_b);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_a);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_c);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_c);
            }
            i += 1;
        }
    }

    {
        var result = try graph.getVertexAdjacencyFrom(data.v_c);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_a);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_d);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
                try expect(kv.value_ptr.*.items.len == 2);
                try expect(kv.value_ptr.*.items[0] == data.v_c);
                try expect(kv.value_ptr.*.items[1] == data.v_e);
            }
            i += 1;
        }
    }

    {
        var result = try graph.getVertexAdjacencyFrom(data.v_d);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_a);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_e);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_b);
            }
            i += 1;
        }
    }

    {
        var result = try graph.getVertexAdjacencyFrom(data.v_e);
        defer result.deinit(std.testing.allocator);
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_b);
                try expect(kv.value_ptr.*.items.len == 2);
                try expect(kv.value_ptr.*.items[0] == data.v_e);
                try expect(kv.value_ptr.*.items[1] == data.v_a);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
                try expect(kv.value_ptr.*.items.len == 1);
                try expect(kv.value_ptr.*.items[0] == data.v_a);
            }
            i += 1;
        }
    }
}

test "get hyperedges connecting vertices" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.getHyperedgesConnecting(max_id, data.v_b));
    try expectError(HypergraphZError.VertexNotFound, graph.getHyperedgesConnecting(data.v_a, max_id));

    {
        var result = try graph.getHyperedgesConnecting(data.v_a, data.v_b);
        defer result.deinit(std.testing.allocator);
        var i: usize = 0;
        var it = result.data.iterator();
        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_a);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
            }
            i += 1;
        }
        try expect(i == 2);
    }

    {
        var result = try graph.getHyperedgesConnecting(data.v_b, data.v_b);
        defer result.deinit(std.testing.allocator);
        var i: usize = 0;
        var it = result.data.iterator();

        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_c);
            }
            i += 1;
        }
        try expect(i == 1);
    }

    {
        var result = try graph.getHyperedgesConnecting(data.v_b, data.v_c);
        defer result.deinit(std.testing.allocator);
        var i: usize = 0;
        var it = result.data.iterator();

        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_a);
            } else if (i == 1) {
                try expect(kv.key_ptr.* == data.h_c);
            }
            i += 1;
        }
        try expect(i == 2);
    }

    {
        var result = try graph.getHyperedgesConnecting(data.v_c, data.v_c);
        defer result.deinit(std.testing.allocator);
        var i: usize = 0;
        var it = result.data.iterator();

        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_c);
            }
            i += 1;
        }
        try expect(i == 1);
    }

    {
        var result = try graph.getHyperedgesConnecting(data.v_e, data.v_e);
        defer result.deinit(std.testing.allocator);
        var i: usize = 0;
        var it = result.data.iterator();

        while (it.next()) |*kv| {
            if (i == 0) {
                try expect(kv.key_ptr.* == data.h_b);
            }
            i += 1;
        }
        try expect(i == 1);
    }
}

test "get endpoints" {
    var graph = try h.scaffold();
    defer graph.deinit();

    const data = try h.generateTestData(&graph);

    var result = try graph.getEndpoints();
    defer result.deinit();

    const initial = result.initial.slice();
    try expect(initial.len == 3);
    for (initial.items(.vertex_id), initial.items(.hyperedge_id), 0..) |v, he, i| {
        if (i == 0) {
            try expect(data.v_a == v);
            try expect(data.h_a == he);
        } else if (i == 1) {
            try expect(data.v_e == v);
            try expect(data.h_b == he);
        } else if (i == 2) {
            try expect(data.v_b == v);
            try expect(data.h_c == he);
        }
    }

    const terminal = result.terminal.slice();
    try expect(terminal.len == 3);
    for (terminal.items(.vertex_id), terminal.items(.hyperedge_id), 0..) |v, he, i| {
        if (i == 0) {
            try expect(data.v_e == v);
            try expect(data.h_a == he);
        } else if (i == 1) {
            try expect(data.v_a == v);
            try expect(data.h_b == he);
        } else if (i == 2) {
            try expect(data.v_b == v);
            try expect(data.h_c == he);
        }
    }
}

test "get orphan hyperedges" {
    var graph = try h.scaffold();
    defer graph.deinit();

    _ = try h.generateTestData(&graph);

    const orphan = try graph.createHyperedge(.{});
    const orphans = try graph.getOrphanHyperedges();
    defer graph.allocator.free(orphans);
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{orphan}, orphans);
}

test "get orphan vertices" {
    var graph = try h.scaffold();
    defer graph.deinit();

    _ = try h.generateTestData(&graph);

    const orphan = try graph.createVertex(.{});
    const orphans = try graph.getOrphanVertices();
    defer graph.allocator.free(orphans);
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{orphan}, orphans);
}
