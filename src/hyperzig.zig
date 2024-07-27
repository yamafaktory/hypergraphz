//! HyperZig is a hypergraph implementation in Zig.

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

            // Add vertex to hyperedge connections.
            try hyperedge.connections.append(vertexId);
            debug("vertex {} added to hyperedge {}", .{
                vertexId,
                hyperedgeId,
            });

            const vertex = self.vertices.getPtr(vertexId).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

            try vertex.connections.put(hyperedgeId, {});
        }

        /// Append vertices to a hyperedge.
        fn appendVerticesToHyperedge(self: *Self, hyperedgeId: Uuid, vertexIds: []const Uuid) HyperZigError!void {
            if (vertexIds.len == 0) {
                debug("no vertices to add to hyperedge {}, skipping", .{hyperedgeId});
                return;
            }

            try self.checkIfHyperedgeExists(hyperedgeId);
            for (vertexIds) |v| {
                try self.checkIfVertexExists(v);
            }

            const hyperedge = self.hyperedges.getPtr(hyperedgeId).?;
            self.initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Add vertices to hyperedge connections.
            try hyperedge.connections.appendSlice(vertexIds);
            debug("vertices added to hyperedge {}", .{hyperedgeId});

            for (vertexIds) |id| {
                const vertex = self.vertices.getPtr(id).?;

                self.initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

                try vertex.connections.put(hyperedgeId, {});
            }
        }

        /// Delete a vertex from a hyperedge.
        fn deleteVertexFromHyperedge(self: *Self, hyperedgeId: Uuid, vertexId: Uuid) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedgeId);
            try self.checkIfVertexExists(vertexId);

            const hyperedge = self.hyperedges.getPtr(hyperedgeId).?;
            const index = std.mem.indexOf(Uuid, hyperedge.connections.items, &.{vertexId});
            if (index) |i| {
                const oldId = hyperedge.connections.orderedRemove(i);
                assert(oldId == vertexId);

                const vertex = self.vertices.getPtr(vertexId).?;
                const removed = vertex.connections.orderedRemove(hyperedgeId);
                assert(removed);
                debug("vertice {} deleted from hyperedge {}", .{ vertexId, hyperedgeId });
            }
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

    const result = graph.getHyperedge(1);
    try expectError(HyperZigError.HyperedgeNotFound, result);

    const hyperedge = try graph.getHyperedge(hyperedgeId);
    try expect(@TypeOf(hyperedge) == Hyperedge);
}

test "create and get vertex" {
    var graph = try scaffold();
    defer graph.deinit();

    const vertexId = try graph.createVertex(.{});

    const result = graph.getVertex(1);
    try expectError(HyperZigError.VertexNotFound, result);

    const vertex = try graph.getVertex(vertexId);
    try expect(@TypeOf(vertex) == Vertex);
}

test "add vertex to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});
    try expect(hyperedgeId != 0);

    const vertexId = try graph.createVertex(.{});
    try expect(vertexId != 0);

    const resultH = graph.appendVertexToHyperedge(1, 1);
    try expectError(HyperZigError.HyperedgeNotFound, resultH);

    const resultV = graph.appendVertexToHyperedge(hyperedgeId, 1);
    try expectError(HyperZigError.VertexNotFound, resultV);

    try graph.appendVertexToHyperedge(hyperedgeId, vertexId);
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

    const result = graph.getHyperedgeVertices(1);
    try expectError(HyperZigError.HyperedgeNotFound, result);

    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == nbVertices);
}

test "add vertices to hyperedge" {
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

    const resultH = graph.appendVerticesToHyperedge(1, ids);
    try expectError(HyperZigError.HyperedgeNotFound, resultH);

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

test "get vertex hyperedges" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});

    const vertexId = try graph.createVertex(.{});
    try graph.appendVertexToHyperedge(hyperedgeId, vertexId);

    const result = graph.getVertexHyperedges(1);
    try expectError(HyperZigError.VertexNotFound, result);

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

test "delete hyperedge" {
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

    const result = graph.getHyperedge(hyperedgeId);
    try expectError(HyperZigError.HyperedgeNotFound, result);
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
        const result = graph.getVertex(id);
        try expectError(HyperZigError.VertexNotFound, result);
    }

    const result = graph.getHyperedge(hyperedgeId);
    try expectError(HyperZigError.HyperedgeNotFound, result);
}
