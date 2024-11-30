//! HypergraphZ is a directed hypergraph implementation in Zig.
//! https://en.wikipedia.org/wiki/Hypergraph
//! Each hyperedge can contain zero, one (unary) or multiple vertices.
//! Each hyperedge can contain vertices directed to themselves one or more times.

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const AutoArrayHashMap = std.array_hash_map.AutoArrayHashMap;
const MemoryPool = std.heap.MemoryPool;
const MultiArrayList = std.MultiArrayList;
const PriorityQueue = std.PriorityQueue;
const assert = std.debug.assert;
const debug = std.log.debug;
const window = std.mem.window;

pub const HypergraphZId = u32;

/// HypergraphZ errors.
pub const HypergraphZError = (error{
    HyperedgeNotFound,
    IndexOutOfBounds,
    NoVerticesToInsert,
    NotEnoughHyperedgesProvided,
    VertexNotFound,
} || Allocator.Error);

/// Create a hypergraph with hyperedges and vertices as comptime types.
/// Both vertex and hyperedge must be struct types.
/// Every hyperedge must have a `weight` field of type `.Int`.
pub fn HypergraphZ(comptime H: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// The allocator used by the HypergraphZ instance.
        allocator: Allocator,
        /// A hashmap of hyperedges data and relations.
        hyperedges: AutoArrayHashMap(HypergraphZId, HyperedgeDataRelations),
        /// A memory pool for hyperedges data.
        hyperedges_pool: MemoryPool(H),
        /// A hashmap of vertices data and relations.
        vertices: AutoArrayHashMap(HypergraphZId, VertexDataRelations),
        /// A memory pool for vertices data.
        vertices_pool: MemoryPool(V),
        /// Internal counter for both the hyperedges and vertices ids.
        id_counter: HypergraphZId = 0,

        comptime {
            assert(@typeInfo(H) == .Struct);
            var weightFieldType: ?type = null;
            for (@typeInfo(H).Struct.fields) |*f| {
                if (std.mem.eql(u8, f.name, "weight")) {
                    weightFieldType = f.type;
                }
            }
            const isWeightInt = if (weightFieldType) |w| @typeInfo(w) == .Int else false;
            assert(isWeightInt);
            assert(@typeInfo(V) == .Struct);
        }

        /// Vertex representation with data and relations as an array hashmap.
        const VertexDataRelations = struct {
            data: *V,
            relations: AutoArrayHashMap(HypergraphZId, void),
        };

        /// Hyperedge representation with data and relations as an array list.
        const HyperedgeDataRelations = struct {
            data: *H,
            relations: ArrayList(HypergraphZId),
        };

        /// Configuration struct for the HypergraphZ instance.
        pub const HypergraphZConfig = struct {
            /// The initial capacity of the hyperedges array hashmap.
            hyperedges_capacity: ?usize = null,
            /// The initial capacity of the vertices array hashmap.
            vertices_capacity: ?usize = null,
        };

        /// Create a new HypergraphZ instance.
        pub fn init(allocator: Allocator, config: HypergraphZConfig) HypergraphZError!Self {
            // We use an array list for hyperedges and an array hashmap for vertices.
            // The hyperedges can't be a hashmap since a hyperedge can contain the same vertex multiple times.
            var h = AutoArrayHashMap(HypergraphZId, HyperedgeDataRelations).init(allocator);
            var v = AutoArrayHashMap(HypergraphZId, VertexDataRelations).init(allocator);

            // Memory pools for hyperedges and vertices.
            var h_pool = MemoryPool(H).init(allocator);
            var v_pool = MemoryPool(V).init(allocator);

            if (config.hyperedges_capacity) |c| {
                try h.ensureTotalCapacity(c);
                assert(h.capacity() >= c);
                h_pool = try MemoryPool(H).initPreheated(allocator, c);
            }

            if (config.vertices_capacity) |c| {
                try v.ensureTotalCapacity(c);
                assert(v.capacity() >= c);
                v_pool = try MemoryPool(V).initPreheated(allocator, c);
            }

            return .{ .allocator = allocator, .hyperedges = h, .vertices = v, .hyperedges_pool = h_pool, .vertices_pool = v_pool };
        }

        /// Deinit the HypergraphZ instance.
        pub fn deinit(self: *Self) void {
            // Deinit hyperedge relations.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |*kv| {
                kv.value_ptr.relations.deinit();
            }

            // Deinit vertex relations.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |*kv| {
                kv.value_ptr.relations.deinit();
            }

            // Finally deinit all entities and the struct itself.
            self.hyperedges.deinit();
            self.vertices.deinit();
            self.hyperedges_pool.deinit();
            self.vertices_pool.deinit();
            self.* = undefined;
        }

        /// Internal method to get an id.
        fn _getId(self: *Self) HypergraphZId {
            self.id_counter += 1;
            return self.id_counter;
        }

        /// Create a new hyperedge.
        pub fn createHyperedge(self: *Self, hyperedge: H) HypergraphZError!HypergraphZId {
            const id = self._getId();
            const h = try self.hyperedges_pool.create();
            h.* = hyperedge;
            try self.hyperedges.put(id, .{ .relations = ArrayList(HypergraphZId).init(self.allocator), .data = h });

            return id;
        }

        /// Create a new hyperedge assuming there is enough capacity.
        pub fn createHyperedgeAssumeCapacity(self: *Self, hyperedge: H) HypergraphZError!HypergraphZId {
            const id = self._getId();
            const h = try self.hyperedges_pool.create();
            h.* = hyperedge;
            self.hyperedges.putAssumeCapacity(id, .{ .relations = ArrayList(HypergraphZId).init(self.allocator), .data = h });

            return id;
        }

        /// Reserve capacity for the insertion of new hyperedges.
        pub fn reserveHyperedges(self: *Self, additional_capacity: usize) HypergraphZError!void {
            try self.hyperedges.ensureUnusedCapacity(additional_capacity);
        }

        /// Create a new vertex.
        pub fn createVertex(self: *Self, vertex: V) HypergraphZError!HypergraphZId {
            const id = self._getId();
            const v = try self.vertices_pool.create();
            v.* = vertex;
            try self.vertices.put(id, .{ .relations = AutoArrayHashMap(HypergraphZId, void).init(self.allocator), .data = v });

            return id;
        }

        /// Create a new vertex assuming there is enough capacity.
        pub fn createVertexAssumeCapacity(self: *Self, vertex: V) HypergraphZError!HypergraphZId {
            const id = self._getId();
            const v = try self.vertices_pool.create();
            v.* = vertex;
            self.vertices.putAssumeCapacity(id, .{ .relations = AutoArrayHashMap(HypergraphZId, void).init(self.allocator), .data = v });

            return id;
        }

        /// Reserve capacity for the insertion of new vertices.
        pub fn reserveVertices(self: *Self, additional_capacity: usize) HypergraphZError!void {
            try self.vertices.ensureUnusedCapacity(additional_capacity);
        }

        /// Count the number of hyperedges.
        pub fn countHyperedges(self: *Self) usize {
            return self.hyperedges.count();
        }

        /// Count the number of vertices.
        pub fn countVertices(self: *Self) usize {
            return self.vertices.count();
        }

        /// Check if an hyperedge exists.
        pub fn checkIfHyperedgeExists(self: *Self, id: HypergraphZId) HypergraphZError!void {
            if (!self.hyperedges.contains(id)) {
                debug("hyperedge {} not found", .{id});

                return HypergraphZError.HyperedgeNotFound;
            }
        }

        /// Check if a vertex exists.
        pub fn checkIfVertexExists(self: *Self, id: HypergraphZId) HypergraphZError!void {
            if (!self.vertices.contains(id)) {
                debug("vertex {} not found", .{id});

                return HypergraphZError.VertexNotFound;
            }
        }

        /// Get a hyperedge.
        pub fn getHyperedge(self: *Self, id: HypergraphZId) HypergraphZError!H {
            try self.checkIfHyperedgeExists(id);

            const hyperedge = self.hyperedges.get(id).?;

            return hyperedge.data.*;
        }

        /// Get a vertex.
        pub fn getVertex(self: *Self, id: HypergraphZId) HypergraphZError!V {
            try self.checkIfVertexExists(id);

            const hyperedge = self.vertices.get(id).?;

            return hyperedge.data.*;
        }

        /// Get all the hyperedges.
        pub fn getAllHyperedges(self: *Self) []HypergraphZId {
            return self.hyperedges.keys();
        }

        /// Get all the vertices.
        pub fn getAllVertices(self: *Self) []HypergraphZId {
            return self.vertices.keys();
        }

        /// Update a hyperedge.
        pub fn updateHyperedge(self: *Self, id: HypergraphZId, hyperedge: H) HypergraphZError!void {
            try self.checkIfHyperedgeExists(id);

            self.hyperedges.getPtr(id).?.data.* = hyperedge;
        }

        /// Update a vertex.
        pub fn updateVertex(self: *Self, id: HypergraphZId, vertex: V) HypergraphZError!void {
            try self.checkIfVertexExists(id);

            self.vertices.getPtr(id).?.data.* = vertex;
        }

        /// Get the indegree of a vertex.
        /// Note that a vertex can be directed to itself multiple times.
        /// https://en.wikipedia.org/wiki/Directed_graph#Indegree_and_outdegree
        pub fn getVertexIndegree(self: *Self, id: HypergraphZId) HypergraphZError!usize {
            try self.checkIfVertexExists(id);

            const vertex = self.vertices.get(id).?;
            var indegree: usize = 0;
            var it = vertex.relations.iterator();
            while (it.next()) |*kv| {
                const hyperedge = self.hyperedges.get(kv.key_ptr.*).?;
                if (hyperedge.relations.items.len > 0) {
                    // Use a window iterator over the hyperedge relations.
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |v| {
                        if (v[0] == id) {
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
        pub fn getVertexOutdegree(self: *Self, id: HypergraphZId) HypergraphZError!usize {
            try self.checkIfVertexExists(id);

            const vertex = self.vertices.get(id).?;
            var outdegree: usize = 0;
            var it = vertex.relations.iterator();
            while (it.next()) |*kv| {
                const hyperedge = self.hyperedges.get(kv.key_ptr.*).?;
                if (hyperedge.relations.items.len > 0) {
                    // Use a window iterator over the hyperedge relations.
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |v| {
                        if (v[1] == id) {
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
        pub const AdjacencyResult = struct {
            data: AutoArrayHashMap(HypergraphZId, ArrayList(HypergraphZId)),

            fn deinit(self: *AdjacencyResult) void {
                // Deinit the array lists.
                var it = self.data.iterator();
                while (it.next()) |*kv| {
                    kv.value_ptr.deinit();
                }

                self.data.deinit();
                self.* = undefined;
            }
        };
        /// Get the adjacents vertices connected to a vertex.
        /// The caller is responsible for freeing the result memory with `denit`.
        pub fn getVertexAdjacencyTo(self: *Self, id: HypergraphZId) HypergraphZError!AdjacencyResult {
            try self.checkIfVertexExists(id);

            // We don't need to release the memory here since the caller will do it.
            var adjacents = AutoArrayHashMap(HypergraphZId, ArrayList(HypergraphZId)).init(self.allocator);
            const vertex = self.vertices.get(id).?;
            var it = vertex.relations.iterator();
            while (it.next()) |*kv| {
                const hyperedge_id = kv.key_ptr.*;
                const hyperedge = self.hyperedges.get(hyperedge_id).?;
                if (hyperedge.relations.items.len > 0) {
                    // Use a window iterator over the hyperedge relations.
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |v| {
                        if (v[1] == id) {
                            const adjacent = v[0];
                            const result = try adjacents.getOrPut(hyperedge_id);
                            // Initialize if not found.
                            if (!result.found_existing) {
                                result.value_ptr.* = ArrayList(HypergraphZId).init(self.allocator);
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
        pub fn getVertexAdjacencyFrom(self: *Self, id: HypergraphZId) HypergraphZError!AdjacencyResult {
            try self.checkIfVertexExists(id);

            // We don't need to release the memory here since the caller will do it.
            var adjacents = AutoArrayHashMap(HypergraphZId, ArrayList(HypergraphZId)).init(self.allocator);
            const vertex = self.vertices.get(id).?;
            var it = vertex.relations.iterator();
            while (it.next()) |*kv| {
                const hyperedge_id = kv.key_ptr.*;
                const hyperedge = self.hyperedges.get(hyperedge_id).?;
                if (hyperedge.relations.items.len > 0) {
                    // Use a window iterator over the hyperedge relations.
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |v| {
                        if (v[0] == id) {
                            const adjacent = v[1];
                            const result = try adjacents.getOrPut(hyperedge_id);
                            // Initialize if not found.
                            if (!result.found_existing) {
                                result.value_ptr.* = ArrayList(HypergraphZId).init(self.allocator);
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
        pub fn deleteHyperedge(self: *Self, id: HypergraphZId, drop_vertices: bool) HypergraphZError!void {
            try self.checkIfHyperedgeExists(id);

            const hyperedge = self.hyperedges.getPtr(id).?;
            const vertices = hyperedge.relations.items;

            if (drop_vertices) {
                // Delete vertices.
                for (vertices) |v| {
                    const vertex = self.vertices.getPtr(v);
                    // A vertex can appear multiple times within a hyperedge and thus might already be deleted.
                    if (vertex) |ptr| {
                        // Remove from the vertices pool.
                        self.vertices_pool.destroy(@alignCast(ptr.data));

                        // Release memory.
                        ptr.relations.deinit();
                        const removed = self.vertices.orderedRemove(v);
                        assert(removed);
                    }
                }
            } else {
                // Delete the hyperedge from the vertex relations.
                for (vertices) |v| {
                    const vertex = self.vertices.getPtr(v);
                    // A vertex can appear multiple times within a hyperedge and thus might already be deleted.
                    if (vertex) |ptr| {
                        _ = ptr.relations.orderedRemove(id);
                    }
                }
            }

            // Remove from the hyperedges pool.
            self.hyperedges_pool.destroy(hyperedge.data);

            // Release memory.
            hyperedge.relations.deinit();

            // Delete the hyperedge itself.
            const removed = self.hyperedges.orderedRemove(id);
            assert(removed);

            debug("hyperedge {} deleted", .{id});
        }

        /// Delete a vertex.
        pub fn deleteVertex(self: *Self, id: HypergraphZId) HypergraphZError!void {
            try self.checkIfVertexExists(id);

            const vertex = self.vertices.getPtr(id).?;
            const hyperedges = vertex.relations.keys();
            for (hyperedges) |h| {
                const hyperedge = self.hyperedges.getPtr(h).?;
                // Delete the vertex from the hyperedge relations.
                // The same vertex can appear multiple times within a hyperedge.
                // Create a temporary list to store the relations without the vertex.
                var tmp = ArrayList(HypergraphZId).init(self.allocator);
                defer tmp.deinit();
                for (hyperedge.relations.items) |v| {
                    if (v != id) {
                        try tmp.append(v);
                    }
                }
                // Swap the temporary list with the hyperedge relations.
                std.mem.swap(ArrayList(HypergraphZId), &hyperedge.relations, &tmp);
            }

            // Remove from the vertices pool.
            self.vertices_pool.destroy(@alignCast(vertex.data));

            // Release memory.
            vertex.relations.deinit();

            // Delete the hyperedge itself.
            const removed = self.vertices.orderedRemove(id);
            assert(removed);

            debug("vertex {} deleted", .{id});
        }

        /// Get all vertices of a hyperedge as a slice.
        pub fn getHyperedgeVertices(self: *Self, hyperedge_id: HypergraphZId) HypergraphZError![]HypergraphZId {
            try self.checkIfHyperedgeExists(hyperedge_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;

            return hyperedge.relations.items;
        }

        /// Get all hyperedges of a vertex as a slice.
        pub fn getVertexHyperedges(self: *Self, vertex_id: HypergraphZId) HypergraphZError![]HypergraphZId {
            try self.checkIfVertexExists(vertex_id);

            const vertex = self.vertices.getPtr(vertex_id).?;

            return vertex.relations.keys();
        }

        /// Append a vertex to a hyperedge.
        pub fn appendVertexToHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_id: HypergraphZId) HypergraphZError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);
            try self.checkIfVertexExists(vertex_id);

            // Append vertex to hyperedge relations.
            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            try hyperedge.relations.append(vertex_id);

            // Add hyperedge to vertex relations.
            const vertex = self.vertices.getPtr(vertex_id).?;
            try vertex.relations.put(hyperedge_id, {});

            debug("vertex {} appended to hyperedge {}", .{
                vertex_id,
                hyperedge_id,
            });
        }

        /// Prepend a vertex to a hyperedge.
        pub fn prependVertexToHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_id: HypergraphZId) HypergraphZError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);
            try self.checkIfVertexExists(vertex_id);

            // Prepend vertex to hyperedge relations.
            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            try hyperedge.relations.insertSlice(0, &.{vertex_id});

            // Add hyperedge to vertex relations.
            const vertex = self.vertices.getPtr(vertex_id).?;
            try vertex.relations.put(hyperedge_id, {});

            debug("vertex {} prepended to hyperedge {}", .{
                vertex_id,
                hyperedge_id,
            });
        }

        /// Insert a vertex into a hyperedge at a given index.
        pub fn insertVertexIntoHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_id: HypergraphZId, index: usize) HypergraphZError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);
            try self.checkIfVertexExists(vertex_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            if (index > hyperedge.relations.items.len) {
                return HypergraphZError.IndexOutOfBounds;
            }

            // Insert vertex into hyperedge relations at given index.
            try hyperedge.relations.insert(index, vertex_id);

            const vertex = self.vertices.getPtr(vertex_id).?;
            try vertex.relations.put(hyperedge_id, {});

            debug("vertex {} inserted into hyperedge {} at index {}", .{
                vertex_id,
                hyperedge_id,
                index,
            });
        }

        /// Append vertices to a hyperedge.
        pub fn appendVerticesToHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_ids: []const HypergraphZId) HypergraphZError!void {
            if (vertex_ids.len == 0) {
                debug("no vertices to append to hyperedge {}, skipping", .{hyperedge_id});
                return;
            }

            try self.checkIfHyperedgeExists(hyperedge_id);
            for (vertex_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            // Append vertices to hyperedge relations.
            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            try hyperedge.relations.appendSlice(vertex_ids);

            for (vertex_ids) |id| {
                const vertex = self.vertices.getPtr(id).?;
                try vertex.relations.put(hyperedge_id, {});
            }

            debug("vertices appended to hyperedge {}", .{hyperedge_id});
        }

        /// Prepend vertices to a hyperedge.
        pub fn prependVerticesToHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertices_ids: []const HypergraphZId) HypergraphZError!void {
            if (vertices_ids.len == 0) {
                debug("no vertices to prepend to hyperedge {}, skipping", .{hyperedge_id});
                return;
            }

            try self.checkIfHyperedgeExists(hyperedge_id);
            for (vertices_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            // Prepend vertices to hyperedge relations.
            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            try hyperedge.relations.insertSlice(0, vertices_ids);

            for (vertices_ids) |id| {
                const vertex = self.vertices.getPtr(id).?;
                try vertex.relations.put(hyperedge_id, {});
            }

            debug("vertices prepended to hyperedge {}", .{hyperedge_id});
        }

        /// Insert vertices into a hyperedge at a given index.
        pub fn insertVerticesIntoHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertices_ids: []const HypergraphZId, index: usize) HypergraphZError!void {
            if (vertices_ids.len == 0) {
                debug("no vertices to insert into hyperedge {}, skipping", .{hyperedge_id});
                return HypergraphZError.NoVerticesToInsert;
            }

            try self.checkIfHyperedgeExists(hyperedge_id);
            for (vertices_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            if (index > hyperedge.relations.items.len) {
                return HypergraphZError.IndexOutOfBounds;
            }

            // Prepend vertices to hyperedge relations.
            try hyperedge.relations.insertSlice(index, vertices_ids);

            for (vertices_ids) |id| {
                const vertex = self.vertices.getPtr(id).?;
                try vertex.relations.put(hyperedge_id, {});
            }

            debug("vertices inserted into hyperedge {} at index {}", .{ hyperedge_id, index });
        }

        /// Delete a vertex from a hyperedge.
        pub fn deleteVertexFromHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_id: HypergraphZId) HypergraphZError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);
            try self.checkIfVertexExists(vertex_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;

            // The same vertex can appear multiple times within a hyperedge.
            // Create a temporary list to store the relations without the vertex.
            var tmp = ArrayList(HypergraphZId).init(self.allocator);
            defer tmp.deinit();
            for (hyperedge.relations.items) |v| {
                if (v != vertex_id) {
                    try tmp.append(v);
                }
            }
            // Swap the temporary list with the hyperedge relations.
            std.mem.swap(ArrayList(HypergraphZId), &hyperedge.relations, &tmp);

            const vertex = self.vertices.getPtr(vertex_id).?;
            const removed = vertex.relations.orderedRemove(hyperedge_id);
            assert(removed);
            debug("vertice {} deleted from hyperedge {}", .{ vertex_id, hyperedge_id });
        }

        /// Delete a vertex from a hyperedge at a given index.
        pub fn deleteVertexByIndexFromHyperedge(self: *Self, hyperedge_id: HypergraphZId, index: usize) HypergraphZError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            if (index > hyperedge.relations.items.len) {
                return HypergraphZError.IndexOutOfBounds;
            }

            const vertex_id = hyperedge.relations.orderedRemove(index);
            const vertex = self.vertices.getPtr(vertex_id).?;

            // Check if the same vertex appears again in this hyperedge.
            // If not, we can remove the hyperedge from the vertex relations.
            for (hyperedge.relations.items) |v| {
                if (v == vertex_id) {
                    break;
                }
            } else {
                const removed = vertex.relations.orderedRemove(hyperedge_id);
                assert(removed);
            }

            debug("vertice {} at index {} deleted from hyperedge {}", .{ vertex_id, index, hyperedge_id });
        }

        /// Get the intersections between multiple hyperedges.
        /// This method returns an owned slice which must be freed by the caller.
        pub fn getIntersections(self: *Self, hyperedges_ids: []const HypergraphZId) HypergraphZError![]const HypergraphZId {
            if (hyperedges_ids.len < 2) {
                debug("at least two hyperedges must be provided, skipping", .{});
                return HypergraphZError.NotEnoughHyperedgesProvided;
            }

            for (hyperedges_ids) |id| {
                try self.checkIfHyperedgeExists(id);
            }

            // We don't need to release the memory here since the caller will do it.
            var intersections = ArrayList(HypergraphZId).init(self.allocator);
            var matches = AutoArrayHashMap(HypergraphZId, usize).init(self.allocator);
            defer matches.deinit();

            for (hyperedges_ids) |id| {
                const hyperedge = self.hyperedges.getPtr(id).?;

                // Keep track of visited vertices since the same vertex can appear multiple times within a hyperedge.
                var visited = AutoArrayHashMap(HypergraphZId, void).init(self.allocator);
                defer visited.deinit();

                for (hyperedge.relations.items) |v| {
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
            from: HypergraphZId,
            weight: usize,
        };
        const CameFrom = AutoHashMap(HypergraphZId, ?Node);
        const Queue = PriorityQueue(HypergraphZId, *const CameFrom, compareNode);
        fn compareNode(map: *const CameFrom, n1: HypergraphZId, n2: HypergraphZId) std.math.Order {
            const node1 = map.get(n1).?;
            const node2 = map.get(n2).?;

            return std.math.order(node1.?.weight, node2.?.weight);
        }
        /// Struct containing the shortest path as a list of vertices.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const ShortestPathResult = struct {
            data: ?ArrayList(HypergraphZId),

            fn deinit(self: *ShortestPathResult) void {
                if (self.data) |d| d.deinit();
                self.* = undefined;
            }
        };
        /// Find the shortest path between two vertices using the A* algorithm.
        /// The caller is responsible for freeing the result memory with `deinit`.
        pub fn findShortestPath(self: *Self, from: HypergraphZId, to: HypergraphZId) HypergraphZError!ShortestPathResult {
            try self.checkIfVertexExists(from);
            try self.checkIfVertexExists(to);

            var arena = ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var came_from = CameFrom.init(arena.allocator());
            var cost_so_far = AutoHashMap(HypergraphZId, usize).init(arena.allocator());
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
                var adjacentsWithWeight = AutoArrayHashMap(HypergraphZId, usize).init(self.allocator);
                defer adjacentsWithWeight.deinit();
                var it = result.data.iterator();
                while (it.next()) |*kv| {
                    const hyperedge = self.hyperedges.get(kv.key_ptr.*).?;
                    const hWeight = hyperedge.data.weight;
                    for (kv.value_ptr.*.items) |v| {
                        try adjacentsWithWeight.put(v, hWeight);
                    }
                }

                // Apply A* on the adjacent vertices.
                var weighted_it = adjacentsWithWeight.iterator();
                while (weighted_it.next()) |*kv| {
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
            var visited = AutoArrayHashMap(HypergraphZId, HypergraphZId).init(self.allocator);
            defer visited.deinit();
            while (it.next()) |*kv| {
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
            var path = ArrayList(HypergraphZId).init(self.allocator);
            try path.append(to);
            while (true) {
                if (last == 0) break;
                try path.append(last.?);
                const next = visited.get(last.?);
                if (next == null or next == 0) break;
                last = next;
            }
            std.mem.reverse(HypergraphZId, path.items);

            debug("path found between {} and {}", .{ from, to });
            return .{ .data = path };
        }

        /// Reverse a hyperedge.
        pub fn reverseHyperedge(self: *Self, hyperedge_id: HypergraphZId) HypergraphZError!void {
            try self.checkIfHyperedgeExists(hyperedge_id);

            const hyperedge = self.hyperedges.getPtr(hyperedge_id).?;
            const tmp = try hyperedge.relations.toOwnedSlice();
            std.mem.reverse(HypergraphZId, tmp);
            hyperedge.relations = ArrayList(HypergraphZId).fromOwnedSlice(self.allocator, tmp);
            debug("hyperedge {} reversed", .{hyperedge_id});
        }

        /// Join two or more hyperedges into one.
        /// All the vertices are moved to the first hyperedge.
        pub fn joinHyperedges(self: *Self, hyperedges_ids: []const HypergraphZId) HypergraphZError!void {
            if (hyperedges_ids.len < 2) {
                debug("at least two hyperedges must be provided, skipping", .{});
                return HypergraphZError.NotEnoughHyperedgesProvided;
            }

            for (hyperedges_ids) |h| {
                try self.checkIfHyperedgeExists(h);
            }

            var first = self.hyperedges.getPtr(hyperedges_ids[0]).?;
            for (hyperedges_ids[1..]) |h| {
                const hyperedge = self.hyperedges.getPtr(h).?;
                const items = hyperedge.relations.items;

                // Move the vertices to the first hyperedge.
                try first.relations.appendSlice(items);

                // Delete the hyperedge from the vertex relations.
                const vertices = hyperedge.relations.items;
                for (vertices) |v| {
                    // We can't assert that the removal is truthy since a vertex can appear multiple times within a hyperedge.
                    const vertex = self.vertices.getPtr(v);
                    _ = vertex.?.relations.orderedRemove(h);
                }

                // Release memory.
                hyperedge.relations.deinit();

                // Delete the hyperedge itself.
                const removed = self.hyperedges.orderedRemove(h);
                assert(removed);
            }

            debug("hyperedges {any} joined into hyperedge {}", .{ hyperedges_ids, hyperedges_ids[0] });
        }

        /// Contract a hyperedge by merging its vertices into one.
        /// The resulting vertex will be the last vertex in the hyperedge.
        /// https://en.wikipedia.org/wiki/Edge_contraction
        pub fn contractHyperedge(self: *Self, id: HypergraphZId) HypergraphZError!void {
            try self.checkIfHyperedgeExists(id);

            // Get the deduped vertices of the hyperedge.
            const hyperedge = self.hyperedges.getPtr(id).?;
            var arena = ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var deduped = AutoHashMap(HypergraphZId, void).init(arena.allocator());
            const vertices = hyperedge.relations.items;
            for (vertices) |v| {
                try deduped.put(v, {});
            }

            const last = vertices[vertices.len - 1];

            // Get all vertices connecting to the ones from this hyperedge except the last one.
            var it = deduped.keyIterator();
            while (it.next()) |d| {
                var result = try self.getVertexAdjacencyTo(d.*);
                defer result.deinit();
                var it_h = result.data.iterator();
                while (it_h.next()) |*kv| {
                    var h = self.hyperedges.getPtr(kv.key_ptr.*).?;
                    for (h.relations.items, 0..) |v, i| {
                        // In each hyperedge, replace the current vertex with the last one.
                        if (v == d.*) {
                            h.relations.items[i] = last;
                            // If the next vertex is also the last one, remove it.
                            if (i + 1 < h.relations.items.len and h.relations.items[i + 1] == last) {
                                _ = h.relations.orderedRemove(i + 1);
                            }
                        }
                    }
                }

                // Delete the hyperedge from the vertex relations.
                const vertex = self.vertices.getPtr(d.*).?;
                const removed = vertex.relations.orderedRemove(id);
                assert(removed);
            }

            // Delete the hyperedge itself.
            hyperedge.relations.deinit();
            const removed = self.hyperedges.orderedRemove(id);
            assert(removed);
            debug("hyperedge {} contracted", .{id});
        }

        /// Clear the hypergraph.
        pub fn clear(self: *Self) void {
            self.hyperedges.clearAndFree();
            self.vertices.clearAndFree();
        }

        /// Struct containing the hyperedges as a hashset whose keys are
        /// hyperedge ids.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const HyperedgesResult = struct {
            data: AutoArrayHashMap(HypergraphZId, void),

            fn deinit(self: *HyperedgesResult) void {
                self.data.deinit();
                self.* = undefined;
            }
        };
        /// Get all the hyperedges connecting two vertices.
        /// This method returns an owned slice which must be freed by the caller.
        pub fn getHyperedgesConnecting(self: *Self, first_vertex_id: HypergraphZId, second_vertex_id: HypergraphZId) HypergraphZError!HyperedgesResult {
            try self.checkIfVertexExists(first_vertex_id);
            try self.checkIfVertexExists(second_vertex_id);

            const eq = first_vertex_id == second_vertex_id;
            const first_vertex = self.vertices.get(first_vertex_id).?;
            var it = first_vertex.relations.iterator();
            var deduped = AutoArrayHashMap(HypergraphZId, void).init(self.allocator);
            while (it.next()) |*kv| {
                const hyperedge = self.hyperedges.get(kv.key_ptr.*).?;
                var found_occurences: usize = 0;
                for (hyperedge.relations.items) |v| {
                    if (v == second_vertex_id) {
                        found_occurences += 1;
                    }
                }
                // We need to take care of potential self-loops.
                if ((eq and found_occurences > 1) or (!eq and found_occurences > 0)) {
                    try deduped.put(kv.key_ptr.*, {});
                }
            }

            return .{ .data = deduped };
        }

        /// Tuple struct containing a vertex id and its hyperedge id as an endpoint.
        pub const EndpointTuple = struct {
            hyperedge_id: HypergraphZId,
            vertex_id: HypergraphZId,
        };
        /// Struct containing the endpoints - initial and terminal - as two
        /// multi array lists of `EndpointTuple`.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const EndpointsResult = struct {
            allocator: Allocator,
            initial: MultiArrayList(EndpointTuple),
            terminal: MultiArrayList(EndpointTuple),

            fn init(allocator: Allocator) EndpointsResult {
                const initial = (MultiArrayList(EndpointTuple)){};
                const terminal = (MultiArrayList(EndpointTuple)){};

                return .{
                    .allocator = allocator,
                    .initial = initial,
                    .terminal = terminal,
                };
            }

            fn deinit(self: *EndpointsResult) void {
                self.initial.deinit(self.allocator);
                self.terminal.deinit(self.allocator);
                self.* = undefined;
            }
        };
        /// Get all the initial and terminal endpoints of all the hyperedges.
        pub fn getEndpoints(self: *Self) HypergraphZError!EndpointsResult {
            var result = EndpointsResult.init(self.allocator);
            var it = self.hyperedges.iterator();
            while (it.next()) |*kv| {
                const hyperedge = kv.value_ptr;
                if (hyperedge.relations.items.len == 0) continue;
                const hyperedge_id = kv.key_ptr.*;
                const vertices = hyperedge.relations.items;
                try result.initial.append(self.allocator, .{ .hyperedge_id = hyperedge_id, .vertex_id = vertices[0] });
                try result.terminal.append(self.allocator, .{ .hyperedge_id = hyperedge_id, .vertex_id = vertices[vertices.len - 1] });
            }

            debug("{} initial and {} terminal endpoints found", .{ result.initial.len, result.terminal.len });
            return result;
        }

        /// Get the orphan hyperedges.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub fn getOrphanHyperedges(self: *Self) HypergraphZError![]const HypergraphZId {
            var orphans = ArrayList(HypergraphZId).init(self.allocator);
            var it = self.hyperedges.iterator();
            while (it.next()) |*kv| {
                const vertices = kv.value_ptr.relations;
                if (vertices.items.len == 0) {
                    try orphans.append(kv.key_ptr.*);
                }
            }

            debug("{} orphan hyperedges found", .{orphans.items.len});
            return orphans.toOwnedSlice();
        }

        /// Get the orphan vertices.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub fn getOrphanVertices(self: *Self) HypergraphZError![]const HypergraphZId {
            var orphans = ArrayList(HypergraphZId).init(self.allocator);
            var it = self.vertices.iterator();
            while (it.next()) |*kv| {
                const hyperedges = kv.value_ptr.relations;
                if (hyperedges.count() == 0) {
                    try orphans.append(kv.key_ptr.*);
                }
            }

            debug("{} orphan vertices found", .{orphans.items.len});
            return orphans.toOwnedSlice();
        }
    };
}

const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const maxInt = std.math.maxInt;

const Hyperedge = struct { meow: bool = false, weight: usize = 1 };
const Vertex = struct { purr: bool = false };

fn scaffold() HypergraphZError!HypergraphZ(Hyperedge, Vertex) {
    std.testing.log_level = .debug;

    const graph = try HypergraphZ(
        Hyperedge,
        Vertex,
    ).init(std.testing.allocator, .{ .vertices_capacity = 5, .hyperedges_capacity = 3 });

    return graph;
}

const max_id = maxInt(HypergraphZId);

const Data = struct {
    v_a: HypergraphZId,
    v_b: HypergraphZId,
    v_c: HypergraphZId,
    v_d: HypergraphZId,
    v_e: HypergraphZId,
    h_a: HypergraphZId,
    h_b: HypergraphZId,
    h_c: HypergraphZId,
};
fn generateTestData(graph: *HypergraphZ(Hyperedge, Vertex)) !Data {
    const v_a = try graph.createVertexAssumeCapacity(.{});
    const v_b = try graph.createVertexAssumeCapacity(.{});
    const v_c = try graph.createVertexAssumeCapacity(.{});
    const v_d = try graph.createVertexAssumeCapacity(.{});
    const v_e = try graph.createVertexAssumeCapacity(.{});

    const h_a = try graph.createHyperedgeAssumeCapacity(.{});
    try graph.appendVerticesToHyperedge(h_a, &.{ v_a, v_b, v_c, v_d, v_e });
    const h_b = try graph.createHyperedgeAssumeCapacity(.{});
    try graph.appendVerticesToHyperedge(h_b, &.{ v_e, v_e, v_a });
    const h_c = try graph.createHyperedgeAssumeCapacity(.{});
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

// test "allocation failure" {
//     var failingAllocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
//     var graph = try HypergraphZ(
//         Hyperedge,
//         Vertex,
//     ).init(failingAllocator.allocator(), .{});
//     defer graph.deinit();
//
//     _ = try graph.createVertex(.{});
//     try expectError(HypergraphZError.OutOfMemory, graph.createHyperedge(.{}));
// }

test "create and get hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedge(max_id));

    const hyperedge = try graph.getHyperedge(hyperedge_id);
    try expect(@TypeOf(hyperedge) == Hyperedge);
}

test "create and get vertex" {
    var graph = try scaffold();
    defer graph.deinit();

    const vertex_id = try graph.createVertex(.{});

    try expectError(HypergraphZError.VertexNotFound, graph.getVertex(max_id));

    const vertex = try graph.getVertex(vertex_id);
    try expect(@TypeOf(vertex) == Vertex);
}

test "get all hyperedges" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    const hyperedges = graph.getAllHyperedges();
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.h_a, data.h_b, data.h_c }, hyperedges);
}

test "get all vertices" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    const vertices = graph.getAllVertices();
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_b, data.v_c, data.v_d, data.v_e }, vertices);
}

test "append vertex to hyperedge" {
    var graph = try scaffold();
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
    var graph = try scaffold();
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
    var graph = try scaffold();
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

test "get hyperedge vertices" {
    var graph = try scaffold();
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

test "append vertices to hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    try expect(hyperedge_id != 0);

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr = ArrayList(HypergraphZId).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try expectError(HypergraphZError.HyperedgeNotFound, graph.appendVerticesToHyperedge(max_id, ids));

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
    var arr = ArrayList(HypergraphZId).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    const ids = arr.items;

    try expectError(HypergraphZError.HyperedgeNotFound, graph.prependVerticesToHyperedge(max_id, ids));

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
    var arr = ArrayList(HypergraphZId).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
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

    try expectError(HypergraphZError.VertexNotFound, graph.getVertexHyperedges(max_id));

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

    try expectError(HypergraphZError.HyperedgeNotFound, graph.deleteVertexFromHyperedge(max_id, vertex_id));

    try expectError(HypergraphZError.VertexNotFound, graph.deleteVertexFromHyperedge(hyperedge_id, max_id));

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
    var arr = ArrayList(HypergraphZId).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    // Add the same vertex twice.
    try arr.append(arr.items[arr.items.len - 1]);
    const ids = arr.items;

    try graph.appendVerticesToHyperedge(hyperedge_id, ids);

    try graph.deleteHyperedge(hyperedge_id, false);
    for (ids) |id| {
        const hyperedges = try graph.getVertexHyperedges(id);
        try expect(hyperedges.len == 0);
    }

    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedge(hyperedge_id));
}

test "delete hyperedge and vertices" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    // Create 10 vertices and store their ids.
    const nb_vertices = 10;
    var arr = ArrayList(HypergraphZId).init(std.testing.allocator);
    defer arr.deinit();
    for (0..nb_vertices) |_| {
        const id = try graph.createVertex(.{});
        try arr.append(id);
    }
    // Add the same vertex twice.
    try arr.append(arr.items[arr.items.len - 1]);
    const ids = arr.items;

    try graph.appendVerticesToHyperedge(hyperedge_id, ids);

    try graph.deleteHyperedge(hyperedge_id, true);
    for (ids) |id| {
        try expectError(HypergraphZError.VertexNotFound, graph.getVertex(id));
    }

    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedge(hyperedge_id));
}

test "delete vertex" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});
    const vertex_id = try graph.createVertex(.{});

    // Insert the vertex twice.
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);
    try graph.appendVertexToHyperedge(hyperedge_id, vertex_id);

    try expectError(HypergraphZError.VertexNotFound, graph.deleteVertex(max_id));

    try graph.deleteVertex(vertex_id);
    const vertices = try graph.getHyperedgeVertices(hyperedge_id);
    try expect(vertices.len == 0);
    try expectError(HypergraphZError.VertexNotFound, graph.getVertex(vertex_id));
}

test "delete vertex by index from hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const hyperedge_id = try graph.createHyperedge(.{});

    // Create 10 vertices and store their ids.
    // Last two vertices are duplicated.
    const nb_vertices = 10;
    var arr = ArrayList(HypergraphZId).init(std.testing.allocator);
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

test "get vertex indegree" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.getVertexIndegree(max_id));

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

    try expectError(HypergraphZError.VertexNotFound, graph.getVertexOutdegree(max_id));

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

    try expectError(HypergraphZError.HyperedgeNotFound, graph.updateHyperedge(max_id, .{}));

    try graph.updateHyperedge(hyperedge_id, .{ .meow = true });
    const hyperedge = try graph.getHyperedge(hyperedge_id);
    try expect(@TypeOf(hyperedge) == Hyperedge);
    try expect(hyperedge.meow);
}

test "update vertex" {
    var graph = try scaffold();
    defer graph.deinit();

    const vertex_id = try graph.createVertex(.{});

    try expectError(HypergraphZError.VertexNotFound, graph.updateVertex(max_id, .{}));

    try graph.updateVertex(vertex_id, .{ .purr = true });
    const vertex = try graph.getVertex(vertex_id);
    try expect(@TypeOf(vertex) == Vertex);
    try expect(vertex.purr);
}

test "get intersections" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HypergraphZError.NotEnoughHyperedgesProvided, graph.getIntersections(&[_]HypergraphZId{1}));

    const hyperedges = [_]HypergraphZId{ data.h_a, data.h_b, data.h_c };
    const expected = [_]HypergraphZId{ data.v_e, data.v_a };
    const intersections = try graph.getIntersections(&hyperedges);
    defer graph.allocator.free(intersections);
    try std.testing.expectEqualSlices(HypergraphZId, &expected, intersections);
}

test "get vertex adjacency to" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.getVertexAdjacencyTo(max_id));

    {
        var result = try graph.getVertexAdjacencyTo(data.v_a);
        defer result.deinit();
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
        defer result.deinit();
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
        defer result.deinit();
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
        defer result.deinit();
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
        defer result.deinit();
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
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.getVertexAdjacencyFrom(max_id));

    {
        var result = try graph.getVertexAdjacencyFrom(data.v_a);
        defer result.deinit();
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
        defer result.deinit();
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
        defer result.deinit();
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
        defer result.deinit();
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
        defer result.deinit();
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

test "find shortest path" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.findShortestPath(max_id, data.v_a));
    try expectError(HypergraphZError.VertexNotFound, graph.findShortestPath(data.v_a, max_id));

    {
        var result = try graph.findShortestPath(data.v_a, data.v_e);
        defer result.deinit();

        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_d, data.v_e }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_b, data.v_e);
        defer result.deinit();

        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_b, data.v_c, data.v_e }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_d, data.v_a);
        defer result.deinit();

        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_d, data.v_e, data.v_a }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_c, data.v_b);
        defer result.deinit();

        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_c, data.v_d, data.v_b }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_d, data.v_b);
        defer result.deinit();
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_d, data.v_b }, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_c, data.v_c);
        defer result.deinit();
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{data.v_c}, result.data.?.items);
    }

    {
        var result = try graph.findShortestPath(data.v_e, data.v_e);
        defer result.deinit();
        try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{data.v_e}, result.data.?.items);
    }

    {
        const disconnected = try graph.createVertex(Vertex{});
        var result = try graph.findShortestPath(data.v_a, disconnected);
        defer result.deinit();
        try expect(result.data == null);
    }
}

test "reverse hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HypergraphZError.HyperedgeNotFound, graph.reverseHyperedge(max_id));

    try graph.reverseHyperedge(data.h_a);
    const vertices = try graph.getHyperedgeVertices(data.h_a);
    try expect(vertices.len == 5);
    try expect(vertices[0] == data.v_e);
    try expect(vertices[4] == data.v_a);
}

test "join hyperedges" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HypergraphZError.HyperedgeNotFound, graph.joinHyperedges(&[_]HypergraphZId{ max_id - 1, max_id }));
    try expectError(HypergraphZError.NotEnoughHyperedgesProvided, graph.joinHyperedges(&[_]HypergraphZId{data.h_a}));

    try graph.joinHyperedges(&[_]HypergraphZId{ data.h_a, data.h_c });
    const vertices = try graph.getHyperedgeVertices(data.h_a);
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{
        data.v_a, data.v_b, data.v_c, data.v_d, data.v_e,
        data.v_b, data.v_c, data.v_c, data.v_e, data.v_a,
        data.v_d, data.v_b,
    }, vertices);
    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedge(data.h_c));
}

test "contract hyperedge" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try graph.contractHyperedge(data.h_b);

    const h_a = try graph.getHyperedgeVertices(data.h_a);
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_a, data.v_b, data.v_c, data.v_d, data.v_a }, h_a);

    try expectError(HypergraphZError.HyperedgeNotFound, graph.getHyperedgeVertices(data.h_b));

    const h_c = try graph.getHyperedgeVertices(data.h_c);
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{ data.v_b, data.v_c, data.v_c, data.v_a, data.v_d, data.v_b }, h_c);
}

test "clear hypergraph" {
    var graph = try scaffold();
    defer graph.deinit();

    graph.clear();
    const hyperedges = graph.getAllHyperedges();
    const vertices = graph.getAllVertices();
    try expect(hyperedges.len == 0);
    try expect(vertices.len == 0);
}

test "get hyperedges connecting vertices" {
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    try expectError(HypergraphZError.VertexNotFound, graph.getHyperedgesConnecting(max_id, data.v_b));
    try expectError(HypergraphZError.VertexNotFound, graph.getHyperedgesConnecting(data.v_a, max_id));

    {
        var result = try graph.getHyperedgesConnecting(data.v_a, data.v_b);
        defer result.deinit();
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
        defer result.deinit();
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
        defer result.deinit();
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
        defer result.deinit();
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
        defer result.deinit();
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
    var graph = try scaffold();
    defer graph.deinit();

    const data = try generateTestData(&graph);

    var result = try graph.getEndpoints();
    defer result.deinit();

    const initial = result.initial.slice();
    try expect(initial.len == 3);
    for (initial.items(.vertex_id), initial.items(.hyperedge_id), 0..) |v, h, i| {
        if (i == 0) {
            try expect(data.v_a == v);
            try expect(data.h_a == h);
        } else if (i == 1) {
            try expect(data.v_e == v);
            try expect(data.h_b == h);
        } else if (i == 2) {
            try expect(data.v_b == v);
            try expect(data.h_c == h);
        }
    }

    const terminal = result.terminal.slice();
    try expect(terminal.len == 3);
    for (terminal.items(.vertex_id), terminal.items(.hyperedge_id), 0..) |v, h, i| {
        if (i == 0) {
            try expect(data.v_e == v);
            try expect(data.h_a == h);
        } else if (i == 1) {
            try expect(data.v_a == v);
            try expect(data.h_b == h);
        } else if (i == 2) {
            try expect(data.v_b == v);
            try expect(data.h_c == h);
        }
    }
}

test "get orphan hyperedges" {
    var graph = try scaffold();
    defer graph.deinit();

    _ = try generateTestData(&graph);

    const orphan = try graph.createHyperedge(.{});
    const orphans = try graph.getOrphanHyperedges();
    defer graph.allocator.free(orphans);
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{orphan}, orphans);
}

test "get orphan vertices" {
    var graph = try scaffold();
    defer graph.deinit();

    _ = try generateTestData(&graph);

    const orphan = try graph.createVertex(.{});
    const orphans = try graph.getOrphanVertices();
    defer graph.allocator.free(orphans);
    try expectEqualSlices(HypergraphZId, &[_]HypergraphZId{orphan}, orphans);
}

const builtin = @import("builtin");
pub fn panic(_: []const u8, _: ?*builtin.StackTrace) noreturn {
    // your implementation here
}

test "reserve hyperedges" {
    var graph = try HypergraphZ(
        Hyperedge,
        Vertex,
    ).init(std.testing.allocator, .{});
    defer graph.deinit();

    try expect(graph.countHyperedges() == 0);
    try expect(graph.hyperedges.capacity() == 0);
    // Put more than `linear_scan_max`.
    try graph.reserveHyperedges(20);
    for (0..20) |_| {
        _ = try graph.createHyperedgeAssumeCapacity(.{});
    }
    try expect(graph.hyperedges.capacity() == 20);
    // Calling `createHyperedgeAssumeCapacity` will panic but we can't test
    // it, see: https://github.com/ziglang/zig/issues/1356.
}

test "reserve vertices" {
    var graph = try HypergraphZ(
        Hyperedge,
        Vertex,
    ).init(std.testing.allocator, .{});
    defer graph.deinit();

    try expect(graph.countVertices() == 0);
    try expect(graph.vertices.capacity() == 0);
    // Put more than `linear_scan_max`.
    try graph.reserveVertices(20);
    for (0..20) |_| {
        _ = try graph.createVertexAssumeCapacity(.{});
    }
    try expect(graph.vertices.capacity() == 20);
    // Calling `createVertexAssumeCapacity` will panic but we can't test
    // it, see: https://github.com/ziglang/zig/issues/1356.
}
