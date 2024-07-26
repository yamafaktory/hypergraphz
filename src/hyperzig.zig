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
    HyperedgeAlreadyExists,
    HyperedgeNotFound,
    VertexAlreadyExists,
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

        fn init(allocator: Allocator) Self {
            const h = AutoArrayHashMap(Uuid, EntityArrayList(H)).init(allocator);
            const v = AutoArrayHashMap(Uuid, EntityArrayHashMap(V)).init(allocator);

            return .{ .allocator = allocator, .hyperedges = h, .vertices = v };
        }

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

        fn createHyperedge(self: *Self, hyperedge: H) Allocator.Error!Uuid {
            const id = uuid.v7.new();
            try self.hyperedges.put(id, .{ .connections = undefined, .data = hyperedge });

            return id;
        }

        fn createVertex(self: *Self, vertex: V) Allocator.Error!Uuid {
            const id = uuid.v7.new();
            try self.vertices.put(id, .{ .connections = undefined, .data = vertex });

            return id;
        }

        fn checkIfHyperedgeExists(self: *Self, id: Uuid) HyperZigError!void {
            if (!self.hyperedges.contains(id)) {
                debug("hyperedge {} not found", .{id});

                return HyperZigError.HyperedgeNotFound;
            }
        }

        fn checkIfVertexExists(self: *Self, id: Uuid) HyperZigError!void {
            if (!self.vertices.contains(id)) {
                debug("vertex {} not found", .{id});

                return HyperZigError.VertexNotFound;
            }
        }

        // Get all vertices of a hyperedge as an iterator.
        fn getHyperedgeVertices(self: *Self, hyperedgeId: Uuid) HyperZigError![]Uuid {
            try self.checkIfHyperedgeExists(hyperedgeId);

            const hyperedge = self.hyperedges.getPtr(hyperedgeId);
            if (hyperedge) |h| {
                return h.connections.items;
            } else {
                unreachable;
            }
        }

        // Get all hyperedges of a vertex as an iterator.
        fn getVertexHyperedges(self: *Self, vertexId: Uuid) HyperZigError![]Uuid {
            try self.checkIfVertexExists(vertexId);

            const vertex = self.vertices.getPtr(vertexId);
            if (vertex) |v| {
                return v.connections.keys();
            } else {
                unreachable;
            }
        }

        /// Add a vertex to a hyperedge.
        fn addVertexToHyperedge(self: *Self, hyperedgeId: Uuid, vertexId: Uuid) HyperZigError!void {
            try self.checkIfHyperedgeExists(hyperedgeId);
            try self.checkIfVertexExists(vertexId);

            const hyperedge = self.hyperedges.getPtr(hyperedgeId);
            if (hyperedge) |h| {
                // Initialize connections if empty.
                if (h.connections.items.len == 0) {
                    debug("hyperedge {} connections is empty, initializing", .{hyperedgeId});
                    h.connections = ArrayList(Uuid).init(self.allocator);
                }

                // Add vertex to hyperedge connections.
                try h.connections.append(vertexId);
                debug("vertex {} added to hyperedge {}", .{
                    vertexId,
                    hyperedgeId,
                });
            } else {
                unreachable;
            }

            const vertex = self.vertices.getPtr(vertexId);
            if (vertex) |v| {
                // Initialize connections if empty.
                if (v.connections.count() == 0) {
                    debug("vertex {} connections is empty, initializing", .{vertexId});
                    v.connections = AutoArrayHashMap(Uuid, void).init(self.allocator);
                }

                try v.connections.put(hyperedgeId, {});
            } else {
                unreachable;
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

test "add vertex to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});
    try expect(hyperedgeId != 0);

    const vertexId = try graph.createVertex(.{});
    try expect(vertexId != 0);

    const resultH = graph.addVertexToHyperedge(1, 1);
    try expectError(HyperZigError.HyperedgeNotFound, resultH);

    const resultV = graph.addVertexToHyperedge(hyperedgeId, 1);
    try expectError(HyperZigError.VertexNotFound, resultV);

    try graph.addVertexToHyperedge(hyperedgeId, vertexId);
}

test "get hyperedge vertices" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});

    const nbVertices = 10;
    for (0..nbVertices) |_| {
        const vertexId = try graph.createVertex(.{});
        try graph.addVertexToHyperedge(hyperedgeId, vertexId);
    }

    const result = graph.getHyperedgeVertices(1);
    try expectError(HyperZigError.HyperedgeNotFound, result);

    const vertices = try graph.getHyperedgeVertices(hyperedgeId);
    try expect(vertices.len == nbVertices);
}

test "get vertex hyperedges" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedgeId = try graph.createHyperedge(.{});

    const vertexId = try graph.createVertex(.{});
    try graph.addVertexToHyperedge(hyperedgeId, vertexId);

    const result = graph.getVertexHyperedges(1);
    try expectError(HyperZigError.VertexNotFound, result);

    const hyperedges = try graph.getVertexHyperedges(vertexId);
    try expect(hyperedges.len == 1);
}
