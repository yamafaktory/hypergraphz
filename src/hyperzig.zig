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
            var hIter = self.hyperedges.iterator();
            while (hIter.next()) |kv| {
                kv.value_ptr.connections.deinit();
            }

            // Deinit vertex connections.
            var vIter = self.vertices.iterator();
            while (vIter.next()) |kv| {
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
        fn deleteHyperedge(self: *Self, id: Uuid, dropVertices: bool) HyperZigError!void {
            try self.checkIfHyperedgeExists(id);

            const hyperedge = self.hyperedges.getPtr(id).?;
            const vertices = hyperedge.connections.items;

            if (dropVertices) {
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
                // TODO: this is incorrect since the same vertex can appear multiple times in a hyperedge.
                const index = std.mem.indexOf(Uuid, hyperedge.connections.items, &.{id}).?;
                const oldId = hyperedge.connections.orderedRemove(index);
                assert(oldId == id);
            }

            // Release memory.
            vertex.connections.deinit();

            // Delete the hyperedge itself.
            const removed = self.vertices.orderedRemove(id);
            assert(removed);

            debug("vertex {} deleted", .{id});
        }

        /// Get all vertices of a hyperedge as a slice.
        fn getHyperedgeVertices(self: *Self, hyperedgeId: Uuid) HyperZigError![]Uuid {
            try self.checkIfHyperedgeExists(hyperedgeId);

            const hyperedge = self.hyperedges.getPtr(hyperedgeId).?;

            return hyperedge.connections.items;
        }

        /// Get all hyperedges of a vertex as a slice.
        fn getVertexHyperedges(self: *Self, vertexId: Uuid) HyperZigError![]Uuid {
            try self.checkIfVertexExists(vertexId);

            const vertex = self.vertices.getPtr(vertexId).?;

            return vertex.connections.keys();
        }

        /// Append a vertex to a hyperedge.
        fn appendVertexToHyperedge(self: *Self, hyperedgeId: Uuid, vertexId: Uuid) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedgeId);
            try self.checkIfVertexExists(vertexId);

            const hyperedge = self.hyperedges.getPtr(hyperedgeId).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Append vertex to hyperedge connections.
            try hyperedge.connections.append(vertexId);

            const vertex = self.vertices.getPtr(vertexId).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

            try vertex.connections.put(hyperedgeId, {});

            debug("vertex {} appended to hyperedge {}", .{
                vertexId,
                hyperedgeId,
            });
        }

        /// Prepend a vertex to a hyperedge.
        fn prependVertexToHyperedge(self: *Self, hyperedgeId: Uuid, vertexId: Uuid) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedgeId);
            try self.checkIfVertexExists(vertexId);

            const hyperedge = self.hyperedges.getPtr(hyperedgeId).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Prepend vertex to hyperedge connections.
            try hyperedge.connections.insertSlice(0, &.{vertexId});

            const vertex = self.vertices.getPtr(vertexId).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

            try vertex.connections.put(hyperedgeId, {});

            debug("vertex {} prepended to hyperedge {}", .{
                vertexId,
                hyperedgeId,
            });
        }

        /// Insert a vertex into a hyperedge at a given index.
        fn insertVertexIntoHyperedge(self: *Self, hyperedgeId: Uuid, vertexId: Uuid, index: usize) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedgeId);
            try self.checkIfVertexExists(vertexId);

            const hyperedge = self.hyperedges.getPtr(hyperedgeId).?;
            if (index > hyperedge.connections.items.len) {
                return HyperZigError.IndexOutOfBounds;
            }
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Insert vertex into hyperedge connections at given index.
            try hyperedge.connections.insert(index, vertexId);

            const vertex = self.vertices.getPtr(vertexId).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

            try vertex.connections.put(hyperedgeId, {});

            debug("vertex {} inserted into hyperedge {} at index {}", .{
                vertexId,
                hyperedgeId,
                index,
            });
        }

        /// Append vertices to a hyperedge.
        fn appendVerticesToHyperedge(self: *Self, hyperedgeId: Uuid, vertexIds: []const Uuid) HyperZigError!void {
            if (vertexIds.len == 0) {
                debug("no vertices to append to hyperedge {}, skipping", .{hyperedgeId});
                return;
            }

            try self.checkIfHyperedgeExists(hyperedgeId);
            for (vertexIds) |v| {
                try self.checkIfVertexExists(v);
            }

            const hyperedge = self.hyperedges.getPtr(hyperedgeId).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Append vertices to hyperedge connections.
            try hyperedge.connections.appendSlice(vertexIds);

            for (vertexIds) |id| {
                const vertex = self.vertices.getPtr(id).?;

                self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

                try vertex.connections.put(hyperedgeId, {});
            }

            debug("vertices appended to hyperedge {}", .{hyperedgeId});
        }

        /// Prepend vertices to a hyperedge.
        fn prependVerticesToHyperedge(self: *Self, hyperedgeId: Uuid, vertexIds: []const Uuid) HyperZigError!void {
            if (vertexIds.len == 0) {
                debug("no vertices to prepend to hyperedge {}, skipping", .{hyperedgeId});
                return;
            }

            try self.checkIfHyperedgeExists(hyperedgeId);
            for (vertexIds) |v| {
                try self.checkIfVertexExists(v);
            }

            const hyperedge = self.hyperedges.getPtr(hyperedgeId).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Prepend vertices to hyperedge connections.
            try hyperedge.connections.insertSlice(0, vertexIds);

            for (vertexIds) |id| {
                const vertex = self.vertices.getPtr(id).?;

                self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

                try vertex.connections.put(hyperedgeId, {});
            }

            debug("vertices prepended to hyperedge {}", .{hyperedgeId});
        }

        /// Insert vertices into a hyperedge at a given index.
        fn insertVerticesIntoHyperedge(self: *Self, hyperedgeId: Uuid, vertexIds: []const Uuid, index: usize) HyperZigError!void {
            if (vertexIds.len == 0) {
                debug("no vertices to insert into hyperedge {}, skipping", .{hyperedgeId});
                return;
            }

            try self.checkIfHyperedgeExists(hyperedgeId);
            for (vertexIds) |v| {
                try self.checkIfVertexExists(v);
            }

            const hyperedge = self.hyperedges.getPtr(hyperedgeId).?;
            if (index > hyperedge.connections.items.len) {
                return HyperZigError.IndexOutOfBounds;
            }
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Prepend vertices to hyperedge connections.
            try hyperedge.connections.insertSlice(index, vertexIds);

            for (vertexIds) |id| {
                const vertex = self.vertices.getPtr(id).?;

                self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

                try vertex.connections.put(hyperedgeId, {});
            }

            debug("vertices inserted into hyperedge {} at index {}", .{ hyperedgeId, index });
        }

        /// Delete a vertex from a hyperedge.
        fn deleteVertexFromHyperedge(self: *Self, hyperedgeId: Uuid, vertexId: Uuid) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedgeId);
            try self.checkIfVertexExists(vertexId);

            const hyperedge = self.hyperedges.getPtr(hyperedgeId).?;
            // TODO: this is incorrect since the same vertex can appear multiple times in a hyperedge.
            const index = std.mem.indexOf(Uuid, hyperedge.connections.items, &.{vertexId}).?;
            const oldId = hyperedge.connections.orderedRemove(index);
            assert(oldId == vertexId);

            const vertex = self.vertices.getPtr(vertexId).?;
            const removed = vertex.connections.orderedRemove(hyperedgeId);
            assert(removed);
            debug("vertice {} deleted from hyperedge {}", .{ vertexId, hyperedgeId });
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

    const hyperedgeId = try graph.createHyperedge(.{});

    try expectError(HyperZigError.HyperedgeNotFound, graph.getHyperedge(1));

    const hyperedge = try graph.getHyperedge(hyperedgeId);
    try expect(@TypeOf(hyperedge) == Hyperedge);
}

test "create and get vertex" {
    var graph = try scaffold();
    defer graph.deinit();

    const vertexId = try graph.createVertex(.{});

    try expectError(HyperZigError.VertexNotFound, graph.getVertex(1));

    const vertex = try graph.getVertex(vertexId);
    try expect(@TypeOf(vertex) == Vertex);
}

test "append vertex to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});
    try expect(hyperedgeId != 0);

    const firstVertexId = try graph.createVertex(.{});
    const secondVertexId = try graph.createVertex(.{});
    try expect(firstVertexId != 0);

    try expectError(HyperZigError.HyperedgeNotFound, graph.appendVertexToHyperedge(1, 1));

    try expectError(HyperZigError.VertexNotFound, graph.appendVertexToHyperedge(hyperedgeId, 1));

    try graph.appendVertexToHyperedge(hyperedgeId, firstVertexId);
    try graph.appendVertexToHyperedge(hyperedgeId, secondVertexId);
    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == 2);
    try expect(vertices[0] == firstVertexId);
    try expect(vertices[1] == secondVertexId);
}

test "prepend vertex to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});
    try expect(hyperedgeId != 0);

    const firstVertexId = try graph.createVertex(.{});
    const secondVertexId = try graph.createVertex(.{});
    try expect(firstVertexId != 0);

    try expectError(HyperZigError.HyperedgeNotFound, graph.prependVertexToHyperedge(1, 1));

    try expectError(HyperZigError.VertexNotFound, graph.prependVertexToHyperedge(hyperedgeId, 1));

    try graph.prependVertexToHyperedge(hyperedgeId, firstVertexId);
    try graph.prependVertexToHyperedge(hyperedgeId, secondVertexId);
    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == 2);
    try expect(vertices[0] == secondVertexId);
    try expect(vertices[1] == firstVertexId);
}

test "insert vertex into hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});
    try expect(hyperedgeId != 0);

    const firstVertexId = try graph.createVertex(.{});
    const secondVertexId = try graph.createVertex(.{});
    try expect(firstVertexId != 0);

    try expectError(HyperZigError.HyperedgeNotFound, graph.insertVertexIntoHyperedge(1, 1, 0));

    try expectError(HyperZigError.VertexNotFound, graph.insertVertexIntoHyperedge(hyperedgeId, 1, 0));

    try expectError(HyperZigError.IndexOutOfBounds, graph.insertVertexIntoHyperedge(hyperedgeId, firstVertexId, 10));

    try graph.insertVertexIntoHyperedge(hyperedgeId, firstVertexId, 0);
    try graph.insertVertexIntoHyperedge(hyperedgeId, secondVertexId, 0);
    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == 2);
    try expect(vertices[0] == secondVertexId);
    try expect(vertices[1] == firstVertexId);
}

test "get hyperedge vertices" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});

    const nbVertices = 10;
    for (0..nbVertices) |_| {
        const vertexId = try graph.createVertex(.{});
        try graph.appendVertexToHyperedge(hyperedgeId, vertexId);
    }

    try expectError(HyperZigError.HyperedgeNotFound, graph.getHyperedgeVertices(1));

    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == nbVertices);
}

test "append vertices to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});
    try expect(hyperedgeId != 0);

    // Create 10 vertices and store their ids.
    const nbVertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nbVertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try expectError(HyperZigError.HyperedgeNotFound, graph.appendVerticesToHyperedge(1, ids));

    const empty: []Uuid = &.{};
    const resultV = try graph.appendVerticesToHyperedge(hyperedgeId, empty);
    try expect(resultV == undefined);

    // Append first vertex, then the rest and check that appending works.
    try graph.appendVertexToHyperedge(hyperedgeId, ids[0]);
    try graph.appendVerticesToHyperedge(hyperedgeId, ids[1..nbVertices]);
    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == nbVertices);
    for (ids, 0..) |id, i| {
        try expect(vertices[i] == id);
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 1);
        try expect(hyperedges[0] == hyperedgeId);
    }
}

test "prepend vertices to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});
    try expect(hyperedgeId != 0);

    // Create 10 vertices and store their ids.
    const nbVertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nbVertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try expectError(HyperZigError.HyperedgeNotFound, graph.prependVerticesToHyperedge(1, ids));

    const empty: []Uuid = &.{};
    const resultV = try graph.prependVerticesToHyperedge(hyperedgeId, empty);
    try expect(resultV == undefined);

    // Prepend the last vertex, then the rest and check that prepending works.
    try graph.prependVertexToHyperedge(hyperedgeId, ids[nbVertices - 1]);
    try graph.prependVerticesToHyperedge(hyperedgeId, ids[0 .. nbVertices - 1]);
    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == nbVertices);
    for (ids, 0..) |id, i| {
        try expect(vertices[i] == id);
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 1);
        try expect(hyperedges[0] == hyperedgeId);
    }
}

test "insert vertices into hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});
    try expect(hyperedgeId != 0);

    // Create 10 vertices and store their ids.
    const nbVertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nbVertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try expectError(HyperZigError.HyperedgeNotFound, graph.insertVerticesIntoHyperedge(1, ids, 0));

    try expectError(HyperZigError.IndexOutOfBounds, graph.insertVerticesIntoHyperedge(hyperedgeId, ids, 10));

    const empty: []Uuid = &.{};
    const resultV = try graph.insertVerticesIntoHyperedge(hyperedgeId, empty, 0);
    try expect(resultV == undefined);

    // Insert the first vertex, then the rest and check that inserting works.
    try graph.insertVertexIntoHyperedge(hyperedgeId, ids[0], 0);
    try graph.insertVerticesIntoHyperedge(hyperedgeId, ids[1..nbVertices], 1);
    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == nbVertices);
    for (ids, 0..) |id, i| {
        try expect(vertices[i] == id);
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 1);
        try expect(hyperedges[0] == hyperedgeId);
    }
}

test "get vertex hyperedges" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});

    const vertexId = try graph.createVertex(.{});
    try graph.appendVertexToHyperedge(hyperedgeId, vertexId);

    try expectError(HyperZigError.VertexNotFound, graph.getVertexHyperedges(1));

    const hyperedges = try graph.getVertexHyperedges(vertexId);
    try expect(hyperedges.len == 1);
}

test "delete vertex from hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});

    const vertexId = try graph.createVertex(.{});
    try graph.appendVertexToHyperedge(hyperedgeId, vertexId);

    try graph.deleteVertexFromHyperedge(hyperedgeId, vertexId);
    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == 0);

    const hyperedges = try graph.getVertexHyperedges(vertexId);
    try expect(hyperedges.len == 0);
}

test "delete hyperedge only" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});

    // Create 10 vertices and store their ids.
    const nbVertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nbVertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try graph.appendVerticesToHyperedge(hyperedgeId, ids);

    try graph.deleteHyperedge(hyperedgeId, false);
    for (ids) |id| {
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 0);
    }

    try expectError(HyperZigError.HyperedgeNotFound, graph.getHyperedge(hyperedgeId));
}

test "delete hyperedge and vertices" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});

    // Create 10 vertices and store their ids.
    const nbVertices = 10;
    var arr = ArrayList(Uuid).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nbVertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try graph.appendVerticesToHyperedge(hyperedgeId, ids);

    try graph.deleteHyperedge(hyperedgeId, true);
    for (ids) |id| {
        try expectError(HyperZigError.VertexNotFound, graph.getVertex(id));
    }

    try expectError(HyperZigError.HyperedgeNotFound, graph.getHyperedge(hyperedgeId));
}

test "delete vertex" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});
    const vertexId = try graph.createVertex(.{});

    try graph.appendVertexToHyperedge(hyperedgeId, vertexId);
    try graph.deleteVertex(vertexId);
    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == 0);
    try expectError(HyperZigError.VertexNotFound, graph.getVertex(vertexId));
}
