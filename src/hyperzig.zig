//! HyperZig is a directed hypergraph implementation in Zig.
//!
//! Each hyperedge can contain one (unary) or multiple vertices.
//! Each hyperedge can contain vertices directed to themselves one or more times.

const std = @import("std");
const uuid = @import("uuid");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoArrayHashMap = std.array_hash_map.AutoArrayHashMap;
const Uuid = uuid.Uuid;
const assert = std.debug.assert;
const debug = std.log.debug;

/// HyperZig errors.
pub const HyperZigError = (error{
    HyperedgeNotFound,
    VertexNotFound,
    IndexOutOfBounds,
} || Allocator.Error);

/// Create a hypergraph with hyperedges and vertices as comptime types.
/// Both vertex and hyperedge must be struct types.
pub fn HyperZig(comptime H: type, comptime V: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        hyperedges: AutoArrayHashMap(Uuid, EntityArrayList(H)),
        vertices: AutoArrayHashMap(Uuid, EntityArrayHashMap(V)),

        comptime {
            assert(@typeInfo(H) == .Struct);
            assert(@typeInfo(V) == .Struct);
        }

        fn EntityArrayHashMap(
            comptime D: type,
        ) type {
            return struct {
                data: D,
                connections: AutoArrayHashMap(Uuid, void),
            };
        }

        fn EntityArrayList(
            comptime D: type,
        ) type {
            return struct {
                data: D,
                connections: ArrayList(Uuid),
            };
        }

        /// Create a new HyperZig instance.
        fn init(allocator: Allocator) Self {
            const h = AutoArrayHashMap(Uuid, EntityArrayList(H)).init(allocator);
            const v = AutoArrayHashMap(Uuid, EntityArrayHashMap(V)).init(allocator);

            return .{ .allocator = allocator, .hyperedges = h, .vertices = v };
        }

        /// Deinit the HyperZig instance.
        fn deinit(self: *Self) void {
            // Deinit hyperedge connections.
            var h_iter = self.hyperedges.iterator();
            while (h_iter.next()) |kv| {
                kv.value_ptr.connections.deinit();
            }

            // Deinit vertex connections.
            var v_iter = self.vertices.iterator();
            while (v_iter.next()) |kv| {
                kv.value_ptr.connections.deinit();
            }

            // Finally deinit all entities and the struct itself.
            self.hyperedges.deinit();
            self.vertices.deinit();
            self.* = undefined;
        }

        const EntityTag = enum { arrayList, arrayHash };
        const EntityUnion = union(EntityTag) {
            arrayList: *EntityArrayList(H),
            arrayHash: *EntityArrayHashMap(V),
        };
        /// Internal method to initialize entity connections if necessary.
        fn initConnectionsIfEmpty(self: Self, entity: EntityUnion) void {
            switch (entity) {
                .arrayList => |a| {
                    if (a.connections.items.len == 0) {
                        a.connections = ArrayList(Uuid).init(self.allocator);
                    }
                },
                .arrayHash => |a| {
                    if (a.connections.count() == 0) {
                        a.connections = AutoArrayHashMap(Uuid, void).init(self.allocator);
                    }
                },
            }
        }

        /// Create a new hyperedge.
        fn createHyperedge(self: *Self, hyperedge: H) Allocator.Error!Uuid {
            const id = uuid.v7.new();
            try self.hyperedges.put(id, .{ .connections = undefined, .data = hyperedge });

            return id;
        }

        /// Create a new vertex.
        fn createVertex(self: *Self, vertex: V) Allocator.Error!Uuid {
            const id = uuid.v7.new();
            try self.vertices.put(id, .{ .connections = undefined, .data = vertex });

            return id;
        }

        /// Count the number of hyperedges.
        fn countHyperedges(self: *Self) usize {
            return self.hyperedges.count();
        }

        /// Count the number of vertices.
        fn countVertices(self: *Self) usize {
            return self.vertices.count();
        }

        /// Check if an hyperedge exists.
        fn checkIfHyperedgeExists(self: *Self, id: Uuid) HyperZigError!void {
            if (!self.hyperedges.contains(id)) {
                debug("hyperedge {} not found", .{id});

                return HyperZigError.HyperedgeNotFound;
            }
        }

        /// Check if a vertex exists.
        fn checkIfVertexExists(self: *Self, id: Uuid) HyperZigError!void {
            if (!self.vertices.contains(id)) {
                debug("vertex {} not found", .{id});

                return HyperZigError.VertexNotFound;
            }
        }

        /// Get a hyperedge.
        fn getHyperedge(self: *Self, id: Uuid) HyperZigError!H {
            try self.checkIfHyperedgeExists(id);

            const hyperedge = self.hyperedges.get(id).?;

            return hyperedge.data;
        }

        /// Get a vertex.
        fn getVertex(self: *Self, id: Uuid) HyperZigError!V {
            try self.checkIfVertexExists(id);

            const hyperedge = self.vertices.get(id).?;

            return hyperedge.data;
        }

        /// Delete a hyperedge.
        fn deleteHyperedge(self: *Self, id: Uuid, drop_vertices: bool) HyperZigError!void {
            try self.checkIfHyperedgeExists(id);

            const hyperedge = self.hyperedges.getPtr(id).?;
            const vertices = hyperedge.connections.items;

            if (drop_vertices) {
                // Delete vertices.
                for (vertices) |v| {
                    const vertex = self.vertices.getPtr(v).?;
                    // Release memory.
                    vertex.connections.deinit();
                    const removed = self.vertices.orderedRemove(v);
                    assert(removed);
                }
            } else {
                // Delete the hyperedge from the vertex connections.
                for (vertices) |v| {
                    const vertex = self.vertices.getPtr(v);
                    const removed = vertex.?.connections.orderedRemove(id);
                    assert(removed);
                }
            }

            // Release memory.
            hyperedge.connections.deinit();

            // Delete the hyperedge itself.
            const removed = self.hyperedges.orderedRemove(id);
            assert(removed);

            debug("hyperedge {} deleted", .{id});
        }

        /// Delete a vertex.
        fn deleteVertex(self: *Self, id: Uuid) HyperZigError!void {
            try self.checkIfVertexExists(id);

            const vertex = self.vertices.getPtr(id).?;
            const hyperedges = vertex.connections.keys();
            for (hyperedges) |h| {
                const hyperedge = self.hyperedges.getPtr(h).?;
                // Delete the vertex from the hyperedge connections.
                // The same vertex can appear multiple times within a hyperedge.
                // Create a temporary list to store the connections without the vertex.
                var tmp = ArrayList(Uuid).init(self.allocator);
                for (hyperedge.connections.items) |v| {
                    if (v != id) {
                        try tmp.append(v);
                    }
                }
                // Swap the temporary list with the hyperedge connections.
                std.mem.swap(ArrayList(Uuid), &hyperedge.connections, &tmp);
                // Release the temporary list.
                tmp.deinit();
            }

            // Release memory.
            vertex.connections.deinit();

            // Delete the hyperedge itself.
            const removed = self.vertices.orderedRemove(id);
            assert(removed);

            debug("vertex {} deleted", .{id});
        }

        /// Get all vertices of a hyperedge as a slice.
        fn getHyperedgeVertices(self: *Self, hyperedge_id: Uuid) HyperZigError![]Uuid {
            try self.checkIfHyperedgeExists(hyperedge_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;

            return hyperedge.connections.items;
        }

        /// Get all hyperedges of a vertex as a slice.
        fn getVertexHyperedges(self: *Self, vertex_id: Uuid) HyperZigError![]Uuid {
            try self.checkIfVertexExists(vertex_id);

            const vertex = self.vertices.getPtr(vertex_id).?;

            return vertex.connections.keys();
        }

        /// Append a vertex to a hyperedge.
        fn appendVertexToHyperedge(self: *Self, hyperedge_id: Uuid, vertex_id: Uuid) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);
            try self.checkIfVertexExists(vertex_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Append vertex to hyperedge connections.
            try hyperedge.connections.append(vertex_id);

            const vertex = self.vertices.getPtr(vertex_id).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

            try vertex.connections.put(hyperedge_id, {});

            debug("vertex {} appended to hyperedge {}", .{
                vertex_id,
                hyperedge_id,
            });
        }

        /// Prepend a vertex to a hyperedge.
        fn prependVertexToHyperedge(self: *Self, hyperedge_id: Uuid, vertex_id: Uuid) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);
            try self.checkIfVertexExists(vertex_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Prepend vertex to hyperedge connections.
            try hyperedge.connections.insertSlice(0, &.{vertex_id});

            const vertex = self.vertices.getPtr(vertex_id).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

            try vertex.connections.put(hyperedge_id, {});

            debug("vertex {} prepended to hyperedge {}", .{
                vertex_id,
                hyperedge_id,
            });
        }

        /// Insert a vertex into a hyperedge at a given index.
        fn insertVertexIntoHyperedge(self: *Self, hyperedge_id: Uuid, vertex_id: Uuid, index: usize) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);
            try self.checkIfVertexExists(vertex_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            if (index > hyperedge.connections.items.len) {
                return HyperZigError.IndexOutOfBounds;
            }
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Insert vertex into hyperedge connections at given index.
            try hyperedge.connections.insert(index, vertex_id);

            const vertex = self.vertices.getPtr(vertex_id).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

            try vertex.connections.put(hyperedge_id, {});

            debug("vertex {} inserted into hyperedge {} at index {}", .{
                vertex_id,
                hyperedge_id,
                index,
            });
        }

        /// Append vertices to a hyperedge.
        fn appendVerticesToHyperedge(self: *Self, hyperedge_id: Uuid, vertex_ids: []const Uuid) HyperZigError!void {
            if (vertex_ids.len == 0) {
                debug("no vertices to append to hyperedge {}, skipping", .{hyperedge_id});
                return;
            }

            try self.checkIfHyperedgeExists(hyperedge_id);
            for (vertex_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Append vertices to hyperedge connections.
            try hyperedge.connections.appendSlice(vertex_ids);

            for (vertex_ids) |id| {
                const vertex = self.vertices.getPtr(id).?;

                self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

                try vertex.connections.put(hyperedge_id, {});
            }

            debug("vertices appended to hyperedge {}", .{hyperedge_id});
        }

        /// Prepend vertices to a hyperedge.
        fn prependVerticesToHyperedge(self: *Self, hyperedge_id: Uuid, vertices_ids: []const Uuid) HyperZigError!void {
            if (vertices_ids.len == 0) {
                debug("no vertices to prepend to hyperedge {}, skipping", .{hyperedge_id});
                return;
            }

            try self.checkIfHyperedgeExists(hyperedge_id);
            for (vertices_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Prepend vertices to hyperedge connections.
            try hyperedge.connections.insertSlice(0, vertices_ids);

            for (vertices_ids) |id| {
                const vertex = self.vertices.getPtr(id).?;

                self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

                try vertex.connections.put(hyperedge_id, {});
            }

            debug("vertices prepended to hyperedge {}", .{hyperedge_id});
        }

        /// Insert vertices into a hyperedge at a given index.
        fn insertVerticesIntoHyperedge(self: *Self, hyperedge_id: Uuid, vertices_ids: []const Uuid, index: usize) HyperZigError!void {
            if (vertices_ids.len == 0) {
                debug("no vertices to insert into hyperedge {}, skipping", .{hyperedge_id});
                return;
            }

            try self.checkIfHyperedgeExists(hyperedge_id);
            for (vertices_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            if (index > hyperedge.connections.items.len) {
                return HyperZigError.IndexOutOfBounds;
            }
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Prepend vertices to hyperedge connections.
            try hyperedge.connections.insertSlice(index, vertices_ids);

            for (vertices_ids) |id| {
                const vertex = self.vertices.getPtr(id).?;

                self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

                try vertex.connections.put(hyperedge_id, {});
            }

            debug("vertices inserted into hyperedge {} at index {}", .{ hyperedge_id, index });
        }

        /// Delete a vertex from a hyperedge.
        fn deleteVertexFromHyperedge(self: *Self, hyperedge_id: Uuid, vertex_id: Uuid) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);
            try self.checkIfVertexExists(vertex_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;

            // The same vertex can appear multiple times within a hyperedge.
            // Create a temporary list to store the connections without the vertex.
            var tmp = ArrayList(Uuid).init(self.allocator);
            for (hyperedge.connections.items) |v| {
                if (v != vertex_id) {
                    try tmp.append(v);
                }
            }
            // Swap the temporary list with the hyperedge connections.
            std.mem.swap(ArrayList(Uuid), &hyperedge.connections, &tmp);
            // Release the temporary list.
            tmp.deinit();

            const vertex = self.vertices.getPtr(vertex_id).?;
            const removed = vertex.connections.orderedRemove(hyperedge_id);
            assert(removed);
            debug("vertice {} deleted from hyperedge {}", .{ vertex_id, hyperedge_id });
        }

        /// Delete a vertex from a hyperedge at a given index.
        fn deleteVertexByIndexFromHyperedge(self: *Self, hyperedge_id: Uuid, index: usize) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            if (index > hyperedge.connections.items.len) {
                return HyperZigError.IndexOutOfBounds;
            }

            const vertex_id = hyperedge.connections.orderedRemove(index);
            const vertex = self.vertices.getPtr(vertex_id).?;

            // Check that if the same vertex appears again in this hyperedge.
            // If not, we can remove the hyperedge from the vertex connections.
            for (hyperedge.connections.items) |v| {
                if (v == vertex_id) {
                    break;
                }
            } else {
                const removed = vertex.connections.orderedRemove(hyperedge_id);
                assert(removed);
            }

            debug("vertice {} at index {} deleted from hyperedge {}", .{ vertex_id, index, hyperedge_id });
        }
    };
}

const expect = std.testing.expect;
const expectError = std.testing.expectError;

const Hyperedge = struct {};
const Vertex = struct {};

fn scaffold() HyperZigError!HyperZig(Hyperedge, Vertex) {
    std.testing.log_level = .debug;

    const graph = HyperZig(
        Hyperedge,
        Vertex,
    ).init(std.testing.allocator);

    return graph;
}

test "create and get hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    try expectError(HyperZigError.HyperedgeNotFound, graph.getHyperedge(1));

    const hyperedge = try graph.getHyperedge(hyperedge_id);
    try expect(@TypeOf(hyperedge) == Hyperedge);
}

test "create and get vertex" {
    var graph = try scaffold();
    defer graph.deinit();

    const vertex_id = try graph.createVertex(.{});

    try expectError(HyperZigError.VertexNotFound, graph.getVertex(1));

    const vertex = try graph.getVertex(vertex_id);
    try expect(@TypeOf(vertex) == Vertex);
}

test "append vertex to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    const first_vertex_id = try graph.createVertex(.{});
    const second_vertex_id = try graph.createVertex(.{});
    try expect(first_vertex_id != 0);

    try expectError(HyperZigError.HyperedgeNotFound, graph.appendVertexToHyperedge(1, 1));

    try expectError(HyperZigError.VertexNotFound, graph.appendVertexToHyperedge(hyperedge_id, 1));

    try graph.appendVertexToHyperedge(hyperedge_id, first_vertex_id);
    try graph.appendVertexToHyperedge(hyperedge_id, second_vertex_id);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 2);
    try expect(vertices[0] == first_vertex_id);
    try expect(vertices[1] == second_vertex_id);
}

test "prepend vertex to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    const first_vertex_id = try graph.createVertex(.{});
    const second_vertex_id = try graph.createVertex(.{});
    try expect(first_vertex_id != 0);

    try expectError(HyperZigError.HyperedgeNotFound, graph.prependVertexToHyperedge(1, 1));

    try expectError(HyperZigError.VertexNotFound, graph.prependVertexToHyperedge(hyperedge_id, 1));

    try graph.prependVertexToHyperedge(hyperedge_id, first_vertex_id);
    try graph.prependVertexToHyperedge(hyperedge_id, second_vertex_id);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 2);
    try expect(vertices[0] == second_vertex_id);
    try expect(vertices[1] == first_vertex_id);
}

test "insert vertex into hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    const first_vertex_id = try graph.createVertex(.{});
    const second_vertex_id = try graph.createVertex(.{});
    try expect(first_vertex_id != 0);

    try expectError(HyperZigError.HyperedgeNotFound, graph.insertVertexIntoHyperedge(1, 1, 0));

    try expectError(HyperZigError.VertexNotFound, graph.insertVertexIntoHyperedge(hyperedge_id, 1, 0));

    try expectError(HyperZigError.IndexOutOfBounds, graph.insertVertexIntoHyperedge(hyperedge_id, first_vertex_id, 10));

    try graph.insertVertexIntoHyperedge(hyperedge_id, first_vertex_id, 0);
    try graph.insertVertexIntoHyperedge(hyperedge_id, second_vertex_id, 0);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 2);
    try expect(vertices[0] == second_vertex_id);
    try expect(vertices[1] == first_vertex_id);
}

test "get hyperedge vertices" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    const nb_vertices = 10;
    for (0..nb_vertices) |_| {
        const vertex_id = try graph.createVertex(.{});
        try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);
    }

    try expectError(HyperZigError.HyperedgeNotFound, graph.getHyperedgeVertices(1));

    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == nb_vertices);
}

test "append vertices to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try expectError(HyperZigError.HyperedgeNotFound, graph.appendVerticesToHyperedge(1, ids));

    try expect(try graph.appendVerticesToHyperedge(hyperedge_id, &.{}) == undefined);

    // Append first vertex, then the rest and check that appending works.
    try graph.appendVertexToHyperedge(hyperedge_id, ids[0]);
    try graph.appendVerticesToHyperedge(hyperedge_id, ids[1..nb_vertices]);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == nb_vertices);
    for (ids, 0..) |id, i| {
        try expect(vertices[i] == id);
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 1);
        try expect(hyperedges[0] == hyperedge_id);
    }
}

test "prepend vertices to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try expectError(HyperZigError.HyperedgeNotFound, graph.prependVerticesToHyperedge(1, ids));

    try expect(try graph.prependVerticesToHyperedge(hyperedge_id, &.{}) == undefined);

    // Prepend the last vertex, then the rest and check that prepending works.
    try graph.prependVertexToHyperedge(hyperedge_id, ids[nb_vertices - 1]);
    try graph.prependVerticesToHyperedge(hyperedge_id, ids[0 .. nb_vertices - 1]);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == nb_vertices);
    for (ids, 0..) |id, i| {
        try expect(vertices[i] == id);
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 1);
        try expect(hyperedges[0] == hyperedge_id);
    }
}

test "insert vertices into hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try expectError(HyperZigError.HyperedgeNotFound, graph.insertVerticesIntoHyperedge(1, ids, 0));

    try expectError(HyperZigError.IndexOutOfBounds, graph.insertVerticesIntoHyperedge(hyperedge_id, ids, 10));

    try expect(try graph.insertVerticesIntoHyperedge(hyperedge_id, &.{}, 0) == undefined);

    // Insert the first vertex, then the rest and check that inserting works.
    try graph.insertVertexIntoHyperedge(hyperedge_id, ids[0], 0);
    try graph.insertVerticesIntoHyperedge(hyperedge_id, ids[1..nb_vertices], 1);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == nb_vertices);
    for (ids, 0..) |id, i| {
        try expect(vertices[i] == id);
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 1);
        try expect(hyperedges[0] == hyperedge_id);
    }
}

test "get vertex hyperedges" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    const vertex_id = try graph.createVertex(.{});
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);

    try expectError(HyperZigError.VertexNotFound, graph.getVertexHyperedges(1));

    const hyperedges = try graph.getVertexHyperedges(vertex_id);
    try expect(hyperedges.len == 1);
}

test "count hyperedges" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(graph.countHyperedges() == 1);
    try graph.deleteHyperedge(hyperedge_id, false);
    try expect(graph.countHyperedges() == 0);
}

test "count vertices" {
    var graph = try scaffold();
    defer graph.deinit();

    const vertex_id = try graph.createVertex(.{});
    try expect(graph.countVertices() == 1);
    try graph.deleteVertex(vertex_id);
    try expect(graph.countVertices() == 0);
}

test "delete vertex from hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    const vertex_id = try graph.createVertex(.{});

    // Insert the vertex twice.
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);

    try expectError(HyperZigError.HyperedgeNotFound, graph.deleteVertexFromHyperedge(1, vertex_id));

    try expectError(HyperZigError.VertexNotFound, graph.deleteVertexFromHyperedge(hyperedge_id, 1));

    try graph.deleteVertexFromHyperedge(hyperedge_id, vertex_id);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 0);

    const hyperedges = try graph.getVertexHyperedges(vertex_id);
    try expect(hyperedges.len == 0);
}

test "delete hyperedge only" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try graph.appendVerticesToHyperedge(hyperedge_id, ids);

    try graph.deleteHyperedge(hyperedge_id, false);
    for (ids) |id| {
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 0);
    }

    try expectError(HyperZigError.HyperedgeNotFound, graph.getHyperedge(hyperedge_id));
}

test "delete hyperedge and vertices" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try graph.appendVerticesToHyperedge(hyperedge_id, ids);

    try graph.deleteHyperedge(hyperedge_id, true);
    for (ids) |id| {
        try expectError(HyperZigError.VertexNotFound, graph.getVertex(id));
    }

    try expectError(HyperZigError.HyperedgeNotFound, graph.getHyperedge(hyperedge_id));
}

test "delete vertex" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    const vertex_id = try graph.createVertex(.{});

    // Insert the vertex twice.
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);

    try expectError(HyperZigError.VertexNotFound, graph.deleteVertex(1));

    try graph.deleteVertex(vertex_id);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 0);
    try expectError(HyperZigError.VertexNotFound, graph.getVertex(vertex_id));
}

test "delete vertex by index from hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    // Create 10 vertices and store their ids.
    // Last two vertices are duplicated.
    const nb_vertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices, 0..) |_, i| {
        if (i == nb_vertices - 1) {
            try arr.append(arr.items[arr.items.len - 1]);
            continue;
        }
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    // Append vertices to the hyperedge.
    try graph.appendVerticesToHyperedge(hyperedge_id, ids);

    try expectError(HyperZigError.HyperedgeNotFound, graph.deleteVertexByIndexFromHyperedge(1, 0));

    // Delete the first vertex.
    // The hyperedge should be dropped from the connections.
    try graph.deleteVertexByIndexFromHyperedge(hyperedge_id, 0);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == nb_vertices - 1);
    for (ids[1..], 0..) |id, i| {
        try expect(vertices[i] == id);
    }
    const first_vertex_hyperedges = try graph.getVertexHyperedges(ids[0]);
    try expect(first_vertex_hyperedges.len == 0);

    // Delete the last vertex.
    // The hyperedge should not be dropped from the connections.
    try graph.deleteVertexByIndexFromHyperedge(hyperedge_id, nb_vertices - 2);
    const last_vertex_hyperedges = try graph.getVertexHyperedges(ids[nb_vertices - 3]);
    try expect(last_vertex_hyperedges.len == 1);
}
