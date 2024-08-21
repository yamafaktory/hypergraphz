//! HyperZig is a directed hypergraph implementation in Zig.
//! https://en.wikipedia.org/wiki/Hypergraph
//! Each hyperedge can contain one (unary) or multiple vertices.
//! Each hyperedge can contain vertices directed to themselves one or more times.

const std = @import("std");
const uuid = @import("uuid");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const AutoArrayHashMap = std.array_hash_map.AutoArrayHashMap;
const PriorityQueue = std.PriorityQueue;
const Uuid = uuid.Uuid;
const assert = std.debug.assert;
const debug = std.log.debug;

/// HyperZig errors.
pub const HyperZigError = (error{
    HyperedgeNotFound,
    IndexOutOfBounds,
    NoVerticesToInsert,
    NotEnoughHyperedgesProvided,
    VertexNotFound,
} || Allocator.Error);

/// Create a hypergraph with hyperedges and vertices as comptime types.
/// Both vertex and hyperedge must be struct types.
/// Every hyperedge must have a `weight` field of type `.Int`.
pub fn HyperZig(comptime H: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// The allocator used by the HyperZig instance.
        allocator: Allocator,
        /// A hashmap of hyperedges.
        hyperedges: AutoArrayHashMap(Uuid, EntityArrayList(H)),
        /// A hashmap of vertices.
        vertices: AutoArrayHashMap(Uuid, EntityArrayHashMap(V)),

        comptime {
            assert(@typeInfo(H) == .Struct);
            var weightFieldType: ?type = null;
            for (@typeInfo(H).Struct.fields) |f| {
                if (std.mem.eql(u8, f.name, "weight")) {
                    weightFieldType = f.type;
                }
            }
            const isWeightInt = if (weightFieldType) |w| @typeInfo(w) == .Int else false;
            assert(isWeightInt);
            assert(@typeInfo(V) == .Struct);
        }

        /// Entity array hashmap type.
        fn EntityArrayHashMap(
            comptime D: type,
        ) type {
            return struct {
                data: D,
                connections: AutoArrayHashMap(Uuid, void),
            };
        }

        /// Entity array list type.
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
            // We use an array list for hyperedges and an array hashmap for vertices.
            // The hyperedges can't be a hashmap since a hyperedge can contain the same vertex multiple times.
            const h = AutoArrayHashMap(Uuid, EntityArrayList(H)).init(allocator);
            const v = AutoArrayHashMap(Uuid, EntityArrayHashMap(V)).init(allocator);

            return .{ .allocator = allocator, .hyperedges = h, .vertices = v };
        }

        /// Deinit the HyperZig instance.
        fn deinit(self: *Self) void {
            // Deinit hyperedge connections.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                kv.value_ptr.connections.deinit();
            }

            // Deinit vertex connections.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
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
        fn _initConnectionsIfEmpty(self: Self, entity: EntityUnion) void {
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

        /// Update a hyperedge.
        fn updateHyperedge(self: *Self, id: Uuid, hyperedge: H) HyperZigError!void {
            try self.checkIfHyperedgeExists(id);

            self.hyperedges.getPtr(id).?.data = hyperedge;
        }

        /// Update a vertex.
        fn updateVertex(self: *Self, id: Uuid, vertex: V) HyperZigError!void {
            try self.checkIfVertexExists(id);

            self.vertices.getPtr(id).?.data = vertex;
        }

        /// Get the indegree of a vertex.
        /// Note that a vertex can be directed to itself multiple times.
        /// https://en.wikipedia.org/wiki/Directed_graph#Indegree_and_outdegree
        fn getVertexIndegree(self: *Self, id: Uuid) HyperZigError!usize {
            try self.checkIfVertexExists(id);

            const vertex = self.vertices.get(id).?;
            var indegree: usize = 0;
            var it = vertex.connections.iterator();
            while (it.next()) |kv| {
                const hyperedge = self.hyperedges.get(kv.key_ptr.*).?;
                if (hyperedge.connections.items.len > 0) {
                    // Act as a window over the hyperedge connections.
                    // Skip the first element since it has an indegree of 0.
                    for (hyperedge.connections.items, 0..) |v, i| {
                        if (i == 0) {
                            continue;
                        }

                        if (v == id) {
                            indegree += 1;
                        }
                    }
                }
            }

            return indegree;
        }

        /// Get the indegree of a vertex.
        /// Note that a vertex can be directed to itself multiple times.
        /// https://en.wikipedia.org/wiki/Directed_graph#Indegree_and_outdegree
        fn getVertexOutdegree(self: *Self, id: Uuid) HyperZigError!usize {
            try self.checkIfVertexExists(id);

            const vertex = self.vertices.get(id).?;
            var outdegree: usize = 0;
            var it = vertex.connections.iterator();
            while (it.next()) |kv| {
                const hyperedge = self.hyperedges.get(kv.key_ptr.*).?;
                if (hyperedge.connections.items.len > 0) {
                    // Act as a window over the hyperedge connections.
                    // Skip the last element since it has an outdegree of 0.
                    const last = hyperedge.connections.items.len - 1;
                    for (hyperedge.connections.items, 0..) |v, i| {
                        if (i == last) {
                            break;
                        }

                        if (v == id) {
                            outdegree += 1;
                        }
                    }
                }
            }

            return outdegree;
        }

        /// Struct containing the adjacents vertices as a hashmap whose keys are
        /// hyperedge ids and values are an array of adjacent vertices.
        /// The caller is responsible for freeing the memory with `deinit`.
        const AdjacencyResult = struct {
            data: AutoArrayHashMap(Uuid, ArrayList(Uuid)),

            fn deinit(self: *AdjacencyResult) void {
                // Deinit the array lists.
                var it = self.data.iterator();
                while (it.next()) |kv| {
                    kv.value_ptr.deinit();
                }

                self.data.deinit();
                self.* = undefined;
            }
        };
        /// Get the adjacents vertices connected to a vertex.
        /// The caller is responsible for freeing the result memory with `denit`.
        fn getVertexAdjacencyTo(self: *Self, id: Uuid) HyperZigError!AdjacencyResult {
            try self.checkIfVertexExists(id);

            // We don't need to release the memory here since the caller will do it.
            var adjacents = AutoArrayHashMap(Uuid, ArrayList(Uuid)).init(self.allocator);
            const vertex = self.vertices.get(id).?;
            var it = vertex.connections.iterator();
            while (it.next()) |kv| {
                const hyperedge_id = kv.key_ptr.*;
                const hyperedge = self.hyperedges.get(hyperedge_id).?;
                if (hyperedge.connections.items.len > 0) {
                    // Act as a window over the hyperedge connections.
                    // Skip the first element since it has an indegree of 0.
                    for (hyperedge.connections.items, 0..) |v, i| {
                        if (i == 0) {
                            continue;
                        }

                        if (v == id) {
                            const adjacent = hyperedge.connections.items[i - 1];
                            const result = try adjacents.getOrPut(hyperedge_id);
                            // Initialize if not found.
                            if (!result.found_existing) {
                                result.value_ptr.* = ArrayList(Uuid).init(self.allocator);
                            }
                            try result.value_ptr.*.append(adjacent);
                            debug("adjacent vertex {} to vertex {} found in hyperedge {}", .{ adjacent, id, hyperedge_id });
                        }
                    }
                }
            }

            return .{ .data = adjacents };
        }

        /// Get the adjacents vertices connected from a vertex.
        /// The caller is responsible for freeing the result memory with `denit`.
        fn getVertexAdjacencyFrom(self: *Self, id: Uuid) HyperZigError!AdjacencyResult {
            try self.checkIfVertexExists(id);

            // We don't need to release the memory here since the caller will do it.
            var adjacents = AutoArrayHashMap(Uuid, ArrayList(Uuid)).init(self.allocator);
            const vertex = self.vertices.get(id).?;
            var it = vertex.connections.iterator();
            while (it.next()) |kv| {
                const hyperedge_id = kv.key_ptr.*;
                const hyperedge = self.hyperedges.get(hyperedge_id).?;
                if (hyperedge.connections.items.len > 0) {
                    // Act as a window over the hyperedge connections.
                    // Skip the last element since it has an outdegree of 0.
                    const last = hyperedge.connections.items.len - 1;
                    for (hyperedge.connections.items, 0..) |v, i| {
                        if (i == last) {
                            continue;
                        }

                        if (v == id) {
                            const adjacent = hyperedge.connections.items[i + 1];
                            const result = try adjacents.getOrPut(hyperedge_id);
                            // Initialize if not found.
                            if (!result.found_existing) {
                                result.value_ptr.* = ArrayList(Uuid).init(self.allocator);
                            }
                            try result.value_ptr.*.append(adjacent);
                            debug("adjacent vertex {} from vertex {} found in hyperedge {}", .{ adjacent, id, hyperedge_id });
                        }
                    }
                }
            }

            return .{ .data = adjacents };
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
            self._initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Append vertex to hyperedge connections.
            try hyperedge.connections.append(vertex_id);

            const vertex = self.vertices.getPtr(vertex_id).?;
            self._initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

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
            self._initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Prepend vertex to hyperedge connections.
            try hyperedge.connections.insertSlice(0, &.{vertex_id});

            const vertex = self.vertices.getPtr(vertex_id).?;
            self._initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

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
            self._initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Insert vertex into hyperedge connections at given index.
            try hyperedge.connections.insert(index, vertex_id);

            const vertex = self.vertices.getPtr(vertex_id).?;
            self._initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

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
            self._initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Append vertices to hyperedge connections.
            try hyperedge.connections.appendSlice(vertex_ids);

            for (vertex_ids) |id| {
                const vertex = self.vertices.getPtr(id).?;

                self._initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

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
            self._initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Prepend vertices to hyperedge connections.
            try hyperedge.connections.insertSlice(0, vertices_ids);

            for (vertices_ids) |id| {
                const vertex = self.vertices.getPtr(id).?;

                self._initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

                try vertex.connections.put(hyperedge_id, {});
            }

            debug("vertices prepended to hyperedge {}", .{hyperedge_id});
        }

        /// Insert vertices into a hyperedge at a given index.
        fn insertVerticesIntoHyperedge(self: *Self, hyperedge_id: Uuid, vertices_ids: []const Uuid, index: usize) HyperZigError!void {
            if (vertices_ids.len == 0) {
                debug("no vertices to insert into hyperedge {}, skipping", .{hyperedge_id});
                return HyperZigError.NoVerticesToInsert;
            }

            try self.checkIfHyperedgeExists(hyperedge_id);
            for (vertices_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            if (index > hyperedge.connections.items.len) {
                return HyperZigError.IndexOutOfBounds;
            }
            self._initConnectionsIfEmpty(EntityUnion{ .arrayList = hyperedge });

            // Prepend vertices to hyperedge connections.
            try hyperedge.connections.insertSlice(index, vertices_ids);

            for (vertices_ids) |id| {
                const vertex = self.vertices.getPtr(id).?;

                self._initConnectionsIfEmpty(EntityUnion{ .arrayHash = vertex });

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

            // Check if the same vertex appears again in this hyperedge.
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

        /// Get the intersections between multiple hyperedges.
        /// This method returns an owned slice which must be freed by the caller.
        fn getIntersections(self: *Self, hyperedges_ids: []const Uuid) HyperZigError![]const Uuid {
            if (hyperedges_ids.len < 2) {
                debug("at least two hyperedges must be provided, skipping", .{});
                return HyperZigError.NotEnoughHyperedgesProvided;
            }

            for (hyperedges_ids) |id| {
                try self.checkIfHyperedgeExists(id);
            }

            // We don't need to release the memory here since the caller will do it.
            var intersections = ArrayList(Uuid).init(self.allocator);
            var matches = AutoArrayHashMap(Uuid, usize).init(self.allocator);
            defer matches.deinit();

            for (hyperedges_ids) |id| {
                const hyperedge = self.hyperedges.getPtr(id).?;

                // Keep track of visited vertices since the same vertex can appear multiple times within a hyperedge.
                var visited = AutoArrayHashMap(Uuid, void).init(self.allocator);
                defer visited.deinit();

                for (hyperedge.connections.items) |v| {
                    if (visited.get(v) != null) {
                        continue;
                    }
                    const result = try matches.getOrPut(v);
                    try visited.put(v, {});
                    if (result.found_existing) {
                        result.value_ptr.* += 1;
                        if (result.value_ptr.* == hyperedges_ids.len) {
                            debug("intersection found at vertex {}", .{v});
                            try intersections.append(v);
                        }
                    } else {
                        // Initialize.
                        result.value_ptr.* = 1;
                    }
                }
            }

            return try intersections.toOwnedSlice();
        }

        const Node = struct {
            from: Uuid,
            weight: usize,
        };
        const CameFrom = AutoHashMap(Uuid, ?Node);
        const Queue = PriorityQueue(Uuid, *const CameFrom, compareNode);
        fn compareNode(map: *const CameFrom, n1: Uuid, n2: Uuid) std.math.Order {
            const node1 = map.get(n1).?;
            const node2 = map.get(n2).?;

            return std.math.order(node1.?.weight, node2.?.weight);
        }
        /// Struct containing the shortest path as a list of vertices.
        /// The caller is responsible for freeing the memory with `deinit`.
        const ShortestPathResult = struct {
            data: ?ArrayList(Uuid),

            fn deinit(self: *ShortestPathResult) void {
                if (self.data) |d| d.deinit();
                self.* = undefined;
            }
        };
        /// Find the shortest path between two vertices using the A* algorithm.
        /// The caller is responsible for freeing the result memory with `deinit`.
        fn findShortestPath(self: *Self, from: Uuid, to: Uuid) HyperZigError!ShortestPathResult {
            try self.checkIfVertexExists(from);
            try self.checkIfVertexExists(to);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var came_from = CameFrom.init(arena.allocator());
            var cost_so_far = std.AutoHashMap(Uuid, usize).init(arena.allocator());
            var frontier = Queue.init(arena.allocator(), &came_from);

            try came_from.put(from, null);
            try cost_so_far.put(from, 0);
            try frontier.add(from);

            while (frontier.count() != 0) {
                const current = frontier.remove();

                if (current == to) break;

                // Get adjacent vertices and their weights from the current hyperedge.
                var result = try self.getVertexAdjacencyFrom(current);
                defer result.deinit();
                var adjacentsWithWeight = AutoArrayHashMap(Uuid, usize).init(self.allocator);
                defer adjacentsWithWeight.deinit();
                var it = result.data.iterator();
                while (it.next()) |kv| {
                    const hyperedge = self.hyperedges.get(kv.key_ptr.*).?;
                    const hWeight = hyperedge.data.weight;
                    for (kv.value_ptr.*.items) |v| {
                        try adjacentsWithWeight.put(v, hWeight);
                    }
                }

                // Apply A* on the adjacent vertices.
                var weighted_it = adjacentsWithWeight.iterator();
                while (weighted_it.next()) |kv| {
                    const next = kv.key_ptr.*;
                    const new_cost = (cost_so_far.get(current) orelse 0) + kv.value_ptr.*;
                    if (!cost_so_far.contains(next) or new_cost < cost_so_far.get(next).?) {
                        try cost_so_far.put(next, new_cost);
                        try came_from.put(next, .{ .weight = kv.value_ptr.*, .from = current });
                        try frontier.add(next);
                    }
                }
            }

            var it = came_from.iterator();
            var visited = AutoArrayHashMap(Uuid, Uuid).init(self.allocator);
            defer visited.deinit();
            while (it.next()) |kv| {
                const node = kv.value_ptr.*;
                const origin = kv.key_ptr.*;
                const dest = if (node) |n| n.from else 0;
                try visited.put(origin, dest);
            }

            var last = visited.get(to);

            if (last == null) {
                debug("no path found between {} and {}", .{ from, to });
                return .{ .data = null };
            }

            // We iterate in reverse order.
            var path = ArrayList(Uuid).init(self.allocator);
            try path.append(to);
            while (true) {
                if (last == 0) break;
                try path.append(last.?);
                const next = visited.get(last.?);
                if (next == null or next == 0) break;
                last = next;
            }
            std.mem.reverse(Uuid, path.items);

            debug("path found between {} and {}", .{ from, to });
            return .{ .data = path };
        }
    };
}

const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const Hyperedge = struct { meow: bool = false, weight: usize = 1 };
const Vertex = struct { purr: bool = false };

fn scaffold() HyperZigError!HyperZig(Hyperedge, Vertex) {
    std.testing.log_level = .debug;

    const graph = HyperZig(
        Hyperedge,
        Vertex,
    ).init(std.testing.allocator);

    return graph;
}

const Data = struct {
    v_a: Uuid,
    v_b: Uuid,
    v_c: Uuid,
    v_d: Uuid,
    v_e: Uuid,
    h_a: Uuid,
    h_b: Uuid,
    h_c: Uuid,
};
fn generateTestData(graph: *HyperZig(Hyperedge, Vertex)) !Data {
    const v_a = try graph.createVertex(.{});
    const v_b = try graph.createVertex(.{});
    const v_c = try graph.createVertex(.{});
    const v_d = try graph.createVertex(.{});
    const v_e = try graph.createVertex(.{});

    const h_a = try graph.createHyperedge(.{});
    try graph.appendVerticesToHyperedge(h_a, &.{ v_a, v_b, v_c, v_d, v_e });
    const h_b = try graph.createHyperedge(.{});
    try graph.appendVerticesToHyperedge(h_b, &.{ v_e, v_e, v_a });
    const h_c = try graph.createHyperedge(.{});
    try graph.appendVerticesToHyperedge(h_c, &.{ v_b, v_c, v_c, v_e, v_a, v_d, v_b });

    return .{
        .v_a = v_a,
        .v_b = v_b,
        .v_c = v_c,
        .v_d = v_d,
        .v_e = v_e,
        .h_a = h_a,
        .h_b = h_b,
        .h_c = h_c,
    };
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

    try expectError(HyperZigError.NoVerticesToInsert, graph.insertVerticesIntoHyperedge(hyperedge_id, &.{}, 0));

    try expectError(HyperZigError.IndexOutOfBounds, graph.insertVerticesIntoHyperedge(hyperedge_id, ids, 10));

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

test "get vertex indegree" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HyperZigError.VertexNotFound, graph.getVertexIndegree(1));

    try expect(try graph.getVertexIndegree(data.v_a) == 2);
    try expect(try graph.getVertexIndegree(data.v_b) == 2);
    try expect(try graph.getVertexIndegree(data.v_c) == 3);
    try expect(try graph.getVertexIndegree(data.v_d) == 2);
    try expect(try graph.getVertexIndegree(data.v_e) == 3);
}

test "get vertex outdegree" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HyperZigError.VertexNotFound, graph.getVertexOutdegree(1));

    try expect(try graph.getVertexOutdegree(data.v_a) == 2);
    try expect(try graph.getVertexOutdegree(data.v_b) == 2);
    try expect(try graph.getVertexOutdegree(data.v_c) == 3);
    try expect(try graph.getVertexOutdegree(data.v_d) == 2);
    try expect(try graph.getVertexOutdegree(data.v_e) == 3);
}

test "update hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    try expectError(HyperZigError.HyperedgeNotFound, graph.updateHyperedge(1, .{}));

    try graph.updateHyperedge(hyperedge_id, .{ .meow = true });
    const hyperedge = try graph.getHyperedge(hyperedge_id);
    try expect(@TypeOf(hyperedge) == Hyperedge);
    try expect(hyperedge.meow);
}

test "update vertex" {
    var graph = try scaffold();
    defer graph.deinit();

    const vertex_id = try graph.createVertex(.{});

    try expectError(HyperZigError.VertexNotFound, graph.updateVertex(1, .{}));

    try graph.updateVertex(vertex_id, .{ .purr = true });
    const vertex = try graph.getVertex(vertex_id);
    try expect(@TypeOf(vertex) == Vertex);
    try expect(vertex.purr);
}

test "get intersections" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HyperZigError.NotEnoughHyperedgesProvided, graph.getIntersections(&[_]Uuid{1}));

    const hyperedges = [_]Uuid{ data.h_a, data.h_b, data.h_c };
    const expected = [_]Uuid{ data.v_e, data.v_a };
    const intersections = try graph.getIntersections(&hyperedges);
    defer graph.allocator.free(intersections);
    try std.testing.expectEqualSlices(Uuid, &expected, intersections);
}

test "get vertex adjacency to" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HyperZigError.VertexNotFound, graph.getVertexAdjacencyTo(1));

    {
        var result = try graph.getVertexAdjacencyTo(data.v_a);
        defer result.deinit();
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
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
        defer result.deinit();
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
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
        defer result.deinit();
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
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
        defer result.deinit();
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
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
        defer result.deinit();
        try expect(result.data.count() == 3);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
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
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HyperZigError.VertexNotFound, graph.getVertexAdjacencyFrom(1));

    {
        var result = try graph.getVertexAdjacencyFrom(data.v_a);
        defer result.deinit();
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
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
        defer result.deinit();
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
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
        defer result.deinit();
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
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
        defer result.deinit();
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
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
        defer result.deinit();
        try expect(result.data.count() == 2);
        var it = result.data.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
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

test "find shortest path" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HyperZigError.VertexNotFound, graph.findShortestPath(1, data.v_a));
    try expectError(HyperZigError.VertexNotFound, graph.findShortestPath(data.v_a, 1));

    {
        var result = try graph.findShortestPath(data.v_a, data.v_e);
        defer result.deinit();

        try expectEqualSlices(Uuid, &[_]Uuid{ data.v_a, data.v_d, data.v_e }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_b, data.v_e);
        defer result.deinit();

        try expectEqualSlices(Uuid, &[_]Uuid{ data.v_b, data.v_c, data.v_e }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_d, data.v_a);
        defer result.deinit();

        try expectEqualSlices(Uuid, &[_]Uuid{ data.v_d, data.v_e, data.v_a }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_c, data.v_b);
        defer result.deinit();

        try expectEqualSlices(Uuid, &[_]Uuid{ data.v_c, data.v_d, data.v_b }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_d, data.v_b);
        defer result.deinit();
        try expectEqualSlices(Uuid, &[_]Uuid{ data.v_d, data.v_b }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_c, data.v_c);
        defer result.deinit();
        try expectEqualSlices(Uuid, &[_]Uuid{data.v_c}, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_e, data.v_e);
        defer result.deinit();
        try expectEqualSlices(Uuid, &[_]Uuid{data.v_e}, result.data.?.items);
    }

    {
        const disconnected = try graph.createVertex(Vertex{});
        var result = try graph.findShortestPath(data.v_a, disconnected);
        defer result.deinit();
        try expect(result.data == null);
    }
}
