//! HypergraphZ is a directed hypergraph implementation in Zig.
//! https://en.wikipedia.org/wiki/Hypergraph
//! Each hyperedge can contain zero, one (unary) or multiple vertices.
//! Each hyperedge can contain vertices directed to themselves one or more times.
//!
//! ## Two-phase design
//!
//! HypergraphZ uses a two-phase model to allow fast bulk construction of large graphs:
//!
//! - **Build phase** (default after `init`): insertion operations are fast because they only
//!   update the forward index (hyperedge → vertices). The reverse index (vertex → hyperedges)
//!   is not maintained. Query operations that require the reverse index return
//!   `HypergraphZError.NotBuilt`.
//! - **Query phase** (after calling `build()`): all operations are available. Subsequent
//!   mutations maintain the reverse index incrementally so `build()` need not be called again
//!   unless a large batch of insertions makes a full rebuild desirable.
//!
//! Call `build()` once after the initial bulk load, then query freely.

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const AutoArrayHashMapUnmanaged = std.array_hash_map.AutoArrayHashMapUnmanaged;
const MemoryPool = std.heap.MemoryPool;
const MultiArrayList = std.MultiArrayList;
const PriorityQueue = std.PriorityQueue;
const assert = std.debug.assert;
const debug = std.log.debug;
const window = std.mem.window;

pub const HypergraphZId = u32;

/// HypergraphZ errors.
pub const HypergraphZError = (error{
    CycleDetected,
    HyperedgeNotFound,
    IndexOutOfBounds,
    InvalidMagicNumber,
    NoVerticesToInsert,
    NotBuilt,
    NotEnoughHyperedgesProvided,
    NotEnoughVerticesProvided,
    UnsupportedVersion,
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
        hyperedges: AutoArrayHashMapUnmanaged(HypergraphZId, HyperedgeDataRelations),
        /// A memory pool for hyperedges data.
        hyperedges_pool: MemoryPool(H),
        /// A hashmap of vertices data and relations.
        vertices: AutoArrayHashMapUnmanaged(HypergraphZId, VertexDataRelations),
        /// A memory pool for vertices data.
        vertices_pool: MemoryPool(V),
        /// Internal counter for both the hyperedges and vertices ids.
        id_counter: HypergraphZId = 0,
        /// Whether the reverse index (vertex → hyperedges) has been built.
        /// Set to `true` by `build()`, reset to `false` by `clear()`.
        /// When `false`, insertion operations skip the reverse index for performance;
        /// query operations that require it return `HypergraphZError.NotBuilt`.
        is_built: bool = false,

        comptime {
            assert(@typeInfo(H) == .@"struct");
            var weightFieldType: ?type = null;
            for (@typeInfo(H).@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, "weight")) {
                    weightFieldType = f.type;
                }
            }
            const isWeightInt = if (weightFieldType) |w| @typeInfo(w) == .int else false;
            assert(isWeightInt);
            assert(@typeInfo(V) == .@"struct");
        }

        /// Vertex representation with data and relations as an array list.
        const VertexDataRelations = struct {
            data: *V,
            relations: ArrayListUnmanaged(HypergraphZId),
        };

        /// Hyperedge representation with data and relations as an array list.
        const HyperedgeDataRelations = struct {
            data: *H,
            relations: ArrayListUnmanaged(HypergraphZId),
        };

        /// Configuration struct for the HypergraphZ instance.
        pub const HypergraphZConfig = struct {
            /// The initial capacity of the hyperedges array hashmap.
            hyperedges_capacity: ?usize = null,
            /// The initial capacity of the vertices array hashmap.
            vertices_capacity: ?usize = null,
        };

        // ============================================================
        // Core
        // ============================================================

        /// Create a new HypergraphZ instance.
        pub fn init(allocator: Allocator, config: HypergraphZConfig) HypergraphZError!Self {
            // We use an array list for hyperedges and an array hashmap for vertices.
            // The hyperedges can't be a hashmap since a hyperedge can contain the same vertex multiple times.
            var h: AutoArrayHashMapUnmanaged(HypergraphZId, HyperedgeDataRelations) = .empty;
            var v: AutoArrayHashMapUnmanaged(HypergraphZId, VertexDataRelations) = .empty;

            // Memory pools for hyperedges and vertices.
            var h_pool: MemoryPool(H) = .empty;
            var v_pool: MemoryPool(V) = .empty;

            if (config.hyperedges_capacity) |c| {
                try h.ensureTotalCapacity(allocator, c);
                assert(h.capacity() >= c);
                h_pool = try MemoryPool(H).initCapacity(allocator, c);
            }

            if (config.vertices_capacity) |c| {
                try v.ensureTotalCapacity(allocator, c);
                assert(v.capacity() >= c);
                v_pool = try MemoryPool(V).initCapacity(allocator, c);
            }

            return .{
                .allocator = allocator,
                .hyperedges = h,
                .vertices = v,
                .hyperedges_pool = h_pool,
                .vertices_pool = v_pool,
            };
        }

        /// Deinit the HypergraphZ instance.
        pub fn deinit(self: *Self) void {
            // Deinit hyperedge relations.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |*kv| {
                kv.value_ptr.relations.deinit(self.allocator);
            }

            // Deinit vertex relations.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |*kv| {
                kv.value_ptr.relations.deinit(self.allocator);
            }

            // Finally deinit all entities and the struct itself.
            self.hyperedges.deinit(self.allocator);
            self.vertices.deinit(self.allocator);
            self.hyperedges_pool.deinit(self.allocator);
            self.vertices_pool.deinit(self.allocator);
            self.* = undefined;
        }

        /// Return a fully independent copy of the hypergraph.
        /// All vertex and hyperedge data is deep-copied into fresh pool entries,
        /// so the clone can be safely used and deinited independently of the original.
        /// The caller must call `build()` on the result and is responsible for calling `deinit()` on it.
        /// The source graph must have `build()` called before cloning.
        pub fn clone(self: *Self) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var copy = try Self.init(self.allocator, .{
                .vertices_capacity = self.vertices.count(),
                .hyperedges_capacity = self.hyperedges.count(),
            });
            errdefer copy.deinit();

            // Deep-copy vertices: fresh pool entry per vertex, relations rebuilt by build().
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                const new_data = try copy.vertices_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                try copy.vertices.put(self.allocator, kv.key_ptr.*, .{
                    .relations = .empty,
                    .data = new_data,
                });
                copy.id_counter = @max(copy.id_counter, kv.key_ptr.*);
            }

            // Deep-copy hyperedges: fresh pool entry + duplicated relations slice.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                const new_data = try copy.hyperedges_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                const owned = try self.allocator.dupe(HypergraphZId, kv.value_ptr.relations.items);
                try copy.hyperedges.put(self.allocator, kv.key_ptr.*, .{
                    .relations = ArrayListUnmanaged(HypergraphZId).fromOwnedSlice(owned),
                    .data = new_data,
                });
                copy.id_counter = @max(copy.id_counter, kv.key_ptr.*);
            }

            debug("clone: {} vertices, {} hyperedges", .{ copy.vertices.count(), copy.hyperedges.count() });
            return copy;
        }

        /// Clear the hypergraph.
        pub fn clear(self: *Self) void {
            self.hyperedges.clearAndFree(self.allocator);
            self.vertices.clearAndFree(self.allocator);
            self.is_built = false;
        }

        /// Build the reverse index (vertex → hyperedges) from the forward index.
        ///
        /// HypergraphZ uses a two-phase model:
        /// - **Build phase** (default after `init`): insertion operations are fast because
        ///   they only update the forward index (hyperedge → vertices). The reverse index
        ///   (vertex → hyperedges) is not maintained, so queries that traverse it are
        ///   unavailable and return `HypergraphZError.NotBuilt`.
        /// - **Query phase** (after `build()`): all operations are available. Subsequent
        ///   mutations maintain the reverse index incrementally, so `build()` need not be
        ///   called again unless a large batch of insertions makes a full rebuild desirable.
        ///
        /// `build()` scans all hyperedges once and constructs the complete reverse index.
        /// It is idempotent: calling it multiple times is safe and rebuilds from scratch
        /// each time.
        ///
        /// Typical usage for large graphs:
        /// ```zig
        /// // Fast build phase — no reverse-index overhead.
        /// for (raw_edges) |edge| {
        ///     const h = try graph.createHyperedge(edge.data);
        ///     try graph.appendVerticesToHyperedge(h, edge.vertices);
        /// }
        /// // Build reverse index once, then query freely.
        /// try graph.build();
        /// const degree = try graph.getVertexIndegree(some_vertex);
        /// ```
        pub fn build(self: *Self) HypergraphZError!void {
            // Clear any existing reverse index entries.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |*kv| {
                kv.value_ptr.relations.clearRetainingCapacity();
            }

            // Rebuild from the forward index.
            // A per-hyperedge seen-set deduplicates vertices that appear multiple times
            // in the same hyperedge in O(1) per occurrence, avoiding the O(d) scan that
            // _addVertexRelation would perform for every entry.
            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();
            var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |*kv| {
                const hyperedge_id = kv.key_ptr.*;
                seen.clearRetainingCapacity();
                for (kv.value_ptr.relations.items) |vertex_id| {
                    const gop = try seen.getOrPut(aa, vertex_id);
                    if (gop.found_existing) continue;
                    const vertex = self.vertices.getPtr(vertex_id).?;
                    try vertex.relations.append(self.allocator, hyperedge_id);
                }
            }

            self.is_built = true;

            debug("reverse index built: {} vertices, {} hyperedges", .{
                self.vertices.count(),
                self.hyperedges.count(),
            });
        }

        /// Internal method to get an id.
        fn _getId(self: *Self) HypergraphZId {
            self.id_counter += 1;

            return self.id_counter;
        }

        fn _hyperedgePtr(self: *Self, id: HypergraphZId) HypergraphZError!*HyperedgeDataRelations {
            return self.hyperedges.getPtr(id) orelse {
                debug("hyperedge {} not found", .{id});

                return HypergraphZError.HyperedgeNotFound;
            };
        }

        fn _vertexPtr(self: *Self, id: HypergraphZId) HypergraphZError!*VertexDataRelations {
            return self.vertices.getPtr(id) orelse {
                debug("vertex {} not found", .{id});

                return HypergraphZError.VertexNotFound;
            };
        }

        fn _addVertexRelation(self: *Self, vertex: *VertexDataRelations, hyperedge_id: HypergraphZId) !void {
            for (vertex.relations.items) |h| {
                if (h == hyperedge_id) return;
            }
            try vertex.relations.append(self.allocator, hyperedge_id);
        }

        fn _removeVertexRelation(vertex: *VertexDataRelations, hyperedge_id: HypergraphZId) bool {
            for (vertex.relations.items, 0..) |h, i| {
                if (h == hyperedge_id) {
                    _ = vertex.relations.orderedRemove(i);

                    return true;
                }
            }

            return false;
        }

        /// Create a new hyperedge.
        pub fn createHyperedge(self: *Self, hyperedge: H) HypergraphZError!HypergraphZId {
            const id = self._getId();
            const h = try self.hyperedges_pool.create(self.allocator);
            h.* = hyperedge;
            try self.hyperedges.put(self.allocator, id, .{ .relations = .empty, .data = h });

            return id;
        }

        /// Create a new hyperedge assuming there is enough capacity.
        pub fn createHyperedgeAssumeCapacity(self: *Self, hyperedge: H) HypergraphZError!HypergraphZId {
            const id = self._getId();
            const h = try self.hyperedges_pool.create(self.allocator);
            h.* = hyperedge;
            self.hyperedges.putAssumeCapacity(id, .{
                .relations = .empty,
                .data = h,
            });

            return id;
        }

        /// Reserve capacity for the insertion of new hyperedges.
        pub fn reserveHyperedges(self: *Self, additional_capacity: usize) HypergraphZError!void {
            try self.hyperedges.ensureUnusedCapacity(self.allocator, additional_capacity);
        }

        /// Create a new vertex.
        pub fn createVertex(self: *Self, vertex: V) HypergraphZError!HypergraphZId {
            const id = self._getId();
            const v = try self.vertices_pool.create(self.allocator);
            v.* = vertex;
            try self.vertices.put(self.allocator, id, .{
                .relations = .empty,
                .data = v,
            });

            return id;
        }

        /// Create a new vertex assuming there is enough capacity.
        pub fn createVertexAssumeCapacity(self: *Self, vertex: V) HypergraphZError!HypergraphZId {
            const id = self._getId();
            const v = try self.vertices_pool.create(self.allocator);
            v.* = vertex;
            self.vertices.putAssumeCapacity(id, .{
                .relations = .empty,
                .data = v,
            });

            return id;
        }

        /// Reserve capacity for the insertion of new vertices.
        pub fn reserveVertices(self: *Self, additional_capacity: usize) HypergraphZError!void {
            try self.vertices.ensureUnusedCapacity(self.allocator, additional_capacity);
        }

        /// Reserve capacity for additional vertices in a hyperedge.
        pub fn reserveHyperedgeVertices(self: *Self, hyperedge_id: HypergraphZId, additional: usize) HypergraphZError!void {
            const hyperedge = try self._hyperedgePtr(hyperedge_id);
            try hyperedge.relations.ensureUnusedCapacity(self.allocator, additional);
        }

        /// Count the number of hyperedges.
        pub fn countHyperedges(self: *Self) usize {
            return self.hyperedges.count();
        }

        /// Count the number of vertices.
        pub fn countVertices(self: *Self) usize {
            return self.vertices.count();
        }

        /// Check if a hyperedge exists.
        pub fn checkIfHyperedgeExists(self: *Self, id: HypergraphZId) HypergraphZError!void {
            _ = try self._hyperedgePtr(id);
        }

        /// Check if a vertex exists.
        pub fn checkIfVertexExists(self: *Self, id: HypergraphZId) HypergraphZError!void {
            _ = try self._vertexPtr(id);
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
        pub fn getAllHyperedges(self: *Self) []const HypergraphZId {
            return self.hyperedges.keys();
        }

        /// Get all the vertices.
        pub fn getAllVertices(self: *Self) []const HypergraphZId {
            return self.vertices.keys();
        }

        /// Update a hyperedge.
        pub fn updateHyperedge(self: *Self, id: HypergraphZId, hyperedge: H) HypergraphZError!void {
            const h = try self._hyperedgePtr(id);
            h.data.* = hyperedge;
        }

        /// Update a vertex.
        pub fn updateVertex(self: *Self, id: HypergraphZId, vertex: V) HypergraphZError!void {
            const v = try self._vertexPtr(id);
            v.data.* = vertex;
        }

        // ============================================================
        // Mutations
        // ============================================================

        /// Append a vertex to a hyperedge.
        /// In the build phase (before `build()` is called), only the forward index
        /// is updated for performance; the reverse index is populated lazily by `build()`.
        pub fn appendVertexToHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_id: HypergraphZId) HypergraphZError!void {
            const hyperedge = try self._hyperedgePtr(hyperedge_id);
            const vertex = try self._vertexPtr(vertex_id);

            // Append vertex to hyperedge relations.
            try hyperedge.relations.append(self.allocator, vertex_id);

            // Add hyperedge to vertex relations (skipped in build phase).
            if (self.is_built) try self._addVertexRelation(vertex, hyperedge_id);

            debug("vertex {} appended to hyperedge {}", .{
                vertex_id,
                hyperedge_id,
            });
        }

        /// Prepend a vertex to a hyperedge.
        /// In the build phase (before `build()` is called), only the forward index
        /// is updated for performance; the reverse index is populated lazily by `build()`.
        pub fn prependVertexToHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_id: HypergraphZId) HypergraphZError!void {
            const hyperedge = try self._hyperedgePtr(hyperedge_id);
            const vertex = try self._vertexPtr(vertex_id);

            // Prepend vertex to hyperedge relations.
            try hyperedge.relations.insertSlice(self.allocator, 0, &.{vertex_id});

            // Add hyperedge to vertex relations (skipped in build phase).
            if (self.is_built) try self._addVertexRelation(vertex, hyperedge_id);

            debug("vertex {} prepended to hyperedge {}", .{
                vertex_id,
                hyperedge_id,
            });
        }

        /// Insert a vertex into a hyperedge at a given index.
        /// In the build phase (before `build()` is called), only the forward index
        /// is updated for performance; the reverse index is populated lazily by `build()`.
        pub fn insertVertexIntoHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_id: HypergraphZId, index: usize) HypergraphZError!void {
            const hyperedge = try self._hyperedgePtr(hyperedge_id);
            const vertex = try self._vertexPtr(vertex_id);

            if (index > hyperedge.relations.items.len) {
                return HypergraphZError.IndexOutOfBounds;
            }

            // Insert vertex into hyperedge relations at given index.
            try hyperedge.relations.insert(self.allocator, index, vertex_id);

            // Add hyperedge to vertex relations (skipped in build phase).
            if (self.is_built) try self._addVertexRelation(vertex, hyperedge_id);

            debug("vertex {} inserted into hyperedge {} at index {}", .{
                vertex_id,
                hyperedge_id,
                index,
            });
        }

        /// Append vertices to a hyperedge.
        /// In the build phase (before `build()` is called), only the forward index
        /// is updated for performance; the reverse index is populated lazily by `build()`.
        pub fn appendVerticesToHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_ids: []const HypergraphZId) HypergraphZError!void {
            if (vertex_ids.len == 0) {
                debug("no vertices to append to hyperedge {}, skipping", .{hyperedge_id});

                return;
            }

            for (vertex_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            // Append vertices to hyperedge relations.
            const hyperedge = try self._hyperedgePtr(hyperedge_id);
            try hyperedge.relations.appendSlice(self.allocator, vertex_ids);

            // Add hyperedge to vertex relations (skipped in build phase).
            if (self.is_built) {
                for (vertex_ids) |id| {
                    const vertex = self.vertices.getPtr(id).?;
                    try self._addVertexRelation(vertex, hyperedge_id);
                }
            }

            debug("vertices appended to hyperedge {}", .{hyperedge_id});
        }

        /// Prepend vertices to a hyperedge.
        /// In the build phase (before `build()` is called), only the forward index
        /// is updated for performance; the reverse index is populated lazily by `build()`.
        pub fn prependVerticesToHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertices_ids: []const HypergraphZId) HypergraphZError!void {
            if (vertices_ids.len == 0) {
                debug("no vertices to prepend to hyperedge {}, skipping", .{hyperedge_id});

                return;
            }

            for (vertices_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            // Prepend vertices to hyperedge relations.
            const hyperedge = try self._hyperedgePtr(hyperedge_id);
            try hyperedge.relations.insertSlice(self.allocator, 0, vertices_ids);

            // Add hyperedge to vertex relations (skipped in build phase).
            if (self.is_built) {
                for (vertices_ids) |id| {
                    const vertex = self.vertices.getPtr(id).?;
                    try self._addVertexRelation(vertex, hyperedge_id);
                }
            }

            debug("vertices prepended to hyperedge {}", .{hyperedge_id});
        }

        /// Insert vertices into a hyperedge at a given index.
        /// In the build phase (before `build()` is called), only the forward index
        /// is updated for performance; the reverse index is populated lazily by `build()`.
        pub fn insertVerticesIntoHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertices_ids: []const HypergraphZId, index: usize) HypergraphZError!void {
            if (vertices_ids.len == 0) {
                debug("no vertices to insert into hyperedge {}, skipping", .{hyperedge_id});

                return HypergraphZError.NoVerticesToInsert;
            }

            for (vertices_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            const hyperedge = try self._hyperedgePtr(hyperedge_id);
            if (index > hyperedge.relations.items.len) {
                return HypergraphZError.IndexOutOfBounds;
            }

            // Insert vertices into hyperedge relations at given index.
            try hyperedge.relations.insertSlice(self.allocator, index, vertices_ids);

            // Add hyperedge to vertex relations (skipped in build phase).
            if (self.is_built) {
                for (vertices_ids) |id| {
                    const vertex = self.vertices.getPtr(id).?;
                    try self._addVertexRelation(vertex, hyperedge_id);
                }
            }

            debug("vertices inserted into hyperedge {} at index {}", .{ hyperedge_id, index });
        }

        /// Delete a vertex from a hyperedge.
        pub fn deleteVertexFromHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_id: HypergraphZId) HypergraphZError!void {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            const hyperedge = try self._hyperedgePtr(hyperedge_id);

            // The same vertex can appear multiple times within a hyperedge.
            // Create a temporary list to store the relations without the vertex.
            var tmp: ArrayListUnmanaged(HypergraphZId) = .empty;
            defer tmp.deinit(self.allocator);
            for (hyperedge.relations.items) |v| {
                if (v != vertex_id) {
                    try tmp.append(self.allocator, v);
                }
            }
            // Swap the temporary list with the hyperedge relations.
            std.mem.swap(ArrayListUnmanaged(HypergraphZId), &hyperedge.relations, &tmp);

            const vertex = try self._vertexPtr(vertex_id);
            const removed = _removeVertexRelation(vertex, hyperedge_id);
            assert(removed);
            debug("vertex {} deleted from hyperedge {}", .{ vertex_id, hyperedge_id });
        }

        /// Delete a vertex from a hyperedge at a given index.
        pub fn deleteVertexByIndexFromHyperedge(self: *Self, hyperedge_id: HypergraphZId, index: usize) HypergraphZError!void {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            const hyperedge = try self._hyperedgePtr(hyperedge_id);
            if (index >= hyperedge.relations.items.len) {
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
                const removed = _removeVertexRelation(vertex, hyperedge_id);
                assert(removed);
            }

            debug("vertex {} at index {} deleted from hyperedge {}", .{ vertex_id, index, hyperedge_id });
        }

        /// Delete a hyperedge.
        pub fn deleteHyperedge(self: *Self, id: HypergraphZId, drop_vertices: bool) HypergraphZError!void {
            const hyperedge = try self._hyperedgePtr(id);
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
                        ptr.relations.deinit(self.allocator);
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
                        _ = _removeVertexRelation(ptr, id);
                    }
                }
            }

            // Remove from the hyperedges pool.
            self.hyperedges_pool.destroy(hyperedge.data);

            // Release memory.
            hyperedge.relations.deinit(self.allocator);

            // Delete the hyperedge itself.
            const removed = self.hyperedges.orderedRemove(id);
            assert(removed);

            debug("hyperedge {} deleted", .{id});
        }

        /// Delete a vertex.
        pub fn deleteVertex(self: *Self, id: HypergraphZId) HypergraphZError!void {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            const vertex = try self._vertexPtr(id);
            const hyperedges = vertex.relations.items;
            for (hyperedges) |h| {
                const hyperedge = self.hyperedges.getPtr(h).?;
                // Delete the vertex from the hyperedge relations.
                // The same vertex can appear multiple times within a hyperedge.
                // Create a temporary list to store the relations without the vertex.
                var tmp: ArrayListUnmanaged(HypergraphZId) = .empty;
                defer tmp.deinit(self.allocator);
                for (hyperedge.relations.items) |v| {
                    if (v != id) {
                        try tmp.append(self.allocator, v);
                    }
                }
                // Swap the temporary list with the hyperedge relations.
                std.mem.swap(ArrayListUnmanaged(HypergraphZId), &hyperedge.relations, &tmp);
            }

            // Remove from the vertices pool.
            self.vertices_pool.destroy(@alignCast(vertex.data));

            // Release memory.
            vertex.relations.deinit(self.allocator);

            // Delete the vertex itself.
            const removed = self.vertices.orderedRemove(id);
            assert(removed);

            debug("vertex {} deleted", .{id});
        }

        /// Reverse a hyperedge.
        pub fn reverseHyperedge(self: *Self, hyperedge_id: HypergraphZId) HypergraphZError!void {
            const hyperedge = try self._hyperedgePtr(hyperedge_id);
            const tmp = try hyperedge.relations.toOwnedSlice(self.allocator);
            std.mem.reverse(HypergraphZId, tmp);
            hyperedge.relations = ArrayListUnmanaged(HypergraphZId).fromOwnedSlice(tmp);
            debug("hyperedge {} reversed", .{hyperedge_id});
        }

        /// Merge two or more hyperedges into one.
        /// All the vertices are moved to the first hyperedge.
        pub fn mergeHyperedges(self: *Self, hyperedges_ids: []const HypergraphZId) HypergraphZError!void {
            if (hyperedges_ids.len < 2) {
                debug("at least two hyperedges must be provided, skipping", .{});

                return HypergraphZError.NotEnoughHyperedgesProvided;
            }

            for (hyperedges_ids) |h| {
                try self.checkIfHyperedgeExists(h);
            }

            for (hyperedges_ids[1..]) |h| {
                // Re-fetch on every iteration: orderedRemove below shifts the hashmap's
                // internal array, which would invalidate a pointer cached outside the loop.
                const first = self.hyperedges.getPtr(hyperedges_ids[0]).?;
                const hyperedge = self.hyperedges.getPtr(h).?;
                const items = hyperedge.relations.items;

                // Move the vertices to the first hyperedge.
                try first.relations.appendSlice(self.allocator, items);

                // Delete the hyperedge from the vertex relations.
                const vertices = hyperedge.relations.items;
                for (vertices) |v| {
                    // We can't assert that the removal is truthy since a vertex can appear multiple times within a hyperedge.
                    const vertex = self.vertices.getPtr(v);
                    _ = _removeVertexRelation(vertex.?, h);
                }

                // Release memory.
                hyperedge.relations.deinit(self.allocator);

                // Delete the hyperedge itself.
                const removed = self.hyperedges.orderedRemove(h);
                assert(removed);
            }

            debug("hyperedges {any} merged into hyperedge {}", .{ hyperedges_ids, hyperedges_ids[0] });
        }

        /// Split a hyperedge into two at a given index.
        /// The original hyperedge retains the vertices `[0..at]`; a new hyperedge is
        /// created with the vertices `[at..]` and the provided data.
        /// Both halves must be non-empty: `at` must satisfy `1 <= at < len`.
        /// Vertices that appear exclusively in the second half are removed from the
        /// original hyperedge's reverse index; all second-half vertices are added to
        /// the new hyperedge's reverse index.
        /// Requires `build()` to have been called.
        /// Returns the id of the new hyperedge.
        pub fn splitHyperedge(self: *Self, id: HypergraphZId, at: usize, new_hyperedge_data: H) HypergraphZError!HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            // Validate and snapshot the tail vertices before any mutations.
            // (createHyperedge may resize self.hyperedges, invalidating prior pointers.)
            var tail: ArrayListUnmanaged(HypergraphZId) = .empty;
            var kept: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            {
                const h = try self._hyperedgePtr(id);

                if (at == 0 or at >= h.relations.items.len) return HypergraphZError.IndexOutOfBounds;

                try tail.appendSlice(aa, h.relations.items[at..]);
                for (h.relations.items[0..at]) |v| {
                    try kept.put(aa, v, {});
                }
            }

            // Create the new hyperedge — may resize self.hyperedges.
            const new_id = try self.createHyperedge(new_hyperedge_data);

            // Move tail vertices to the new hyperedge and update the reverse index.
            const new_h = self.hyperedges.getPtr(new_id).?;
            for (tail.items) |v| {
                try new_h.relations.append(self.allocator, v);
                const vertex = self.vertices.getPtr(v).?;
                if (!kept.contains(v)) {
                    _ = _removeVertexRelation(vertex, id);
                }
                try self._addVertexRelation(vertex, new_id);
            }

            // Truncate the original hyperedge to [0..at].
            self.hyperedges.getPtr(id).?.relations.shrinkRetainingCapacity(at);

            debug("hyperedge {} split at {} into hyperedge {}", .{ id, at, new_id });
            return new_id;
        }

        /// Contract a hyperedge by merging its vertices into one.
        /// The resulting vertex will be the last vertex in the hyperedge.
        /// https://en.wikipedia.org/wiki/Edge_contraction
        pub fn contractHyperedge(self: *Self, id: HypergraphZId) HypergraphZError!void {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            // Get the deduped vertices of the hyperedge.
            const hyperedge = try self._hyperedgePtr(id);
            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();
            var deduped: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            const vertices = hyperedge.relations.items;
            for (vertices) |v| {
                try deduped.put(arena_allocator, v, {});
            }

            const last = vertices[vertices.len - 1];

            // Get all vertices connecting to the ones from this hyperedge except the last one.
            var it = deduped.keyIterator();
            while (it.next()) |d| {
                var result = try self.getVertexAdjacencyTo(d.*);
                defer result.deinit(self.allocator);
                var it_h = result.data.iterator();
                while (it_h.next()) |*kv| {
                    var h = self.hyperedges.getPtr(kv.key_ptr.*).?;
                    // Use a while loop so that h.relations.items.len is re-evaluated
                    // each iteration — orderedRemove inside the loop shrinks the slice,
                    // and a captured for-range would read stale data on the last step.
                    var i: usize = 0;
                    while (i < h.relations.items.len) : (i += 1) {
                        // In each hyperedge, replace the current vertex with the last one.
                        if (h.relations.items[i] == d.*) {
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
                const removed = _removeVertexRelation(vertex, id);
                assert(removed);
            }

            // Delete the hyperedge itself.
            hyperedge.relations.deinit(self.allocator);
            const removed = self.hyperedges.orderedRemove(id);
            assert(removed);
            debug("hyperedge {} contracted", .{id});
        }

        /// Merge two or more vertices into one.
        /// All hyperedge membership and occurrences of the non-primary vertices are
        /// redirected to the first vertex in `vertex_ids` (the primary).
        /// Consecutive duplicate occurrences of the primary created by replacement
        /// are removed to keep hyperedge relations well-formed.
        /// The non-primary vertices are deleted after merging.
        /// Requires `build()` to have been called.
        pub fn mergeVertices(self: *Self, vertex_ids: []const HypergraphZId) HypergraphZError!void {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            if (vertex_ids.len < 2) return HypergraphZError.NotEnoughVerticesProvided;

            for (vertex_ids) |v| {
                try self.checkIfVertexExists(v);
            }

            const primary = vertex_ids[0];

            for (vertex_ids[1..]) |other| {
                if (other == primary) continue;

                const other_vertex = self.vertices.getPtr(other).?;
                for (other_vertex.relations.items) |h_id| {
                    const h = self.hyperedges.getPtr(h_id).?;

                    // Replace every occurrence of `other` with `primary`.
                    for (h.relations.items) |*v| {
                        if (v.* == other) v.* = primary;
                    }

                    // Remove consecutive primary→primary duplicates introduced by the replacement.
                    var i: usize = 0;
                    while (i + 1 < h.relations.items.len) {
                        if (h.relations.items[i] == primary and h.relations.items[i + 1] == primary) {
                            _ = h.relations.orderedRemove(i + 1);
                        } else {
                            i += 1;
                        }
                    }

                    // Ensure primary's reverse index includes this hyperedge.
                    try self._addVertexRelation(self.vertices.getPtr(primary).?, h_id);
                }

                // Delete `other`.
                const ov = self.vertices.getPtr(other).?;
                self.vertices_pool.destroy(@alignCast(ov.data));
                ov.relations.deinit(self.allocator);
                const removed = self.vertices.orderedRemove(other);
                assert(removed);
            }

            debug("vertices {any} merged into vertex {}", .{ vertex_ids, primary });
        }

        /// Split a vertex into two by redistributing a subset of its hyperedge memberships
        /// to a newly created vertex.
        /// All occurrences of `id` in each specified hyperedge are replaced with the new
        /// vertex id; the original vertex retains its remaining hyperedge memberships.
        /// `hyperedge_ids` must be non-empty and all ids must exist.
        /// If a specified hyperedge does not contain `id`, it is silently skipped.
        /// Requires `build()` to have been called.
        /// Returns the id of the new vertex.
        pub fn splitVertex(self: *Self, id: HypergraphZId, hyperedge_ids: []const HypergraphZId, new_vertex_data: V) HypergraphZError!HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            try self.checkIfVertexExists(id);
            if (hyperedge_ids.len == 0) return HypergraphZError.NotEnoughHyperedgesProvided;

            for (hyperedge_ids) |h_id| {
                try self.checkIfHyperedgeExists(h_id);
            }

            // Create the new vertex — may resize self.vertices, invalidating prior pointers.
            const new_id = try self.createVertex(new_vertex_data);

            for (hyperedge_ids) |h_id| {
                const h = self.hyperedges.getPtr(h_id).?;

                // Replace all occurrences of `id` with `new_id` in this hyperedge.
                var found = false;
                for (h.relations.items) |*v| {
                    if (v.* == id) {
                        v.* = new_id;
                        found = true;
                    }
                }

                if (found) {
                    _ = _removeVertexRelation(self.vertices.getPtr(id).?, h_id);
                    try self._addVertexRelation(self.vertices.getPtr(new_id).?, h_id);
                }
            }

            debug("vertex {} split into vertex {}", .{ id, new_id });
            return new_id;
        }

        // ============================================================
        // Queries
        // ============================================================

        /// Get all vertices of a hyperedge as a slice.
        pub fn getHyperedgeVertices(self: *Self, hyperedge_id: HypergraphZId) HypergraphZError![]const HypergraphZId {
            const hyperedge = try self._hyperedgePtr(hyperedge_id);

            return hyperedge.relations.items;
        }

        /// Get all hyperedges of a vertex as a slice.
        pub fn getVertexHyperedges(self: *Self, vertex_id: HypergraphZId) HypergraphZError![]const HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            const vertex = try self._vertexPtr(vertex_id);

            return vertex.relations.items;
        }

        /// Get the indegree of a vertex.
        /// Note that a vertex can be directed to itself multiple times.
        /// https://en.wikipedia.org/wiki/Directed_graph#Indegree_and_outdegree
        pub fn getVertexIndegree(self: *Self, id: HypergraphZId) HypergraphZError!usize {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            try self.checkIfVertexExists(id);

            const vertex = self.vertices.get(id).?;
            var indegree: usize = 0;
            for (vertex.relations.items) |hyperedge_id| {
                const hyperedge = self.hyperedges.get(hyperedge_id).?;
                if (hyperedge.relations.items.len > 0) {
                    // Use a window iterator over the hyperedge relations.
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |v| {
                        if (v[1] == id) {
                            indegree += 1;
                        }
                    }
                }
            }

            return indegree;
        }

        /// Get the outdegree of a vertex.
        /// Note that a vertex can be directed to itself multiple times.
        /// https://en.wikipedia.org/wiki/Directed_graph#Indegree_and_outdegree
        pub fn getVertexOutdegree(self: *Self, id: HypergraphZId) HypergraphZError!usize {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            try self.checkIfVertexExists(id);

            const vertex = self.vertices.get(id).?;
            var outdegree: usize = 0;
            for (vertex.relations.items) |hyperedge_id| {
                const hyperedge = self.hyperedges.get(hyperedge_id).?;
                if (hyperedge.relations.items.len > 0) {
                    // Use a window iterator over the hyperedge relations.
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |v| {
                        if (v[0] == id) {
                            outdegree += 1;
                        }
                    }
                }
            }

            return outdegree;
        }

        /// Struct containing adjacent vertices grouped by hyperedge.
        /// Keys are hyperedge ids; values are the list of adjacent vertices in that hyperedge.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const AdjacencyResult = struct {
            data: AutoArrayHashMapUnmanaged(HypergraphZId, ArrayListUnmanaged(HypergraphZId)),

            pub fn deinit(self: *AdjacencyResult, allocator: Allocator) void {
                // Deinit the array lists.
                var it = self.data.iterator();
                while (it.next()) |*kv| {
                    kv.value_ptr.deinit(allocator);
                }

                self.data.deinit(allocator);
                self.* = undefined;
            }
        };

        /// Return the in-neighbors of `id`: vertices with a direct edge pointing into `id`,
        /// grouped by hyperedge. Keys are hyperedge ids; values are the source vertices of
        /// pairs ending at `id` in that hyperedge.
        /// The caller is responsible for freeing the result memory with `deinit`.
        pub fn getVertexAdjacencyTo(self: *Self, id: HypergraphZId) HypergraphZError!AdjacencyResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            try self.checkIfVertexExists(id);

            // We don't need to release the memory here since the caller will do it.
            var adjacents: AutoArrayHashMapUnmanaged(HypergraphZId, ArrayListUnmanaged(HypergraphZId)) = .empty;
            const vertex = self.vertices.get(id).?;
            for (vertex.relations.items) |hyperedge_id| {
                const hyperedge = self.hyperedges.get(hyperedge_id).?;
                if (hyperedge.relations.items.len > 0) {
                    // Use a window iterator over the hyperedge relations.
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |v| {
                        if (v[1] == id) {
                            const adjacent = v[0];
                            const result = try adjacents.getOrPut(self.allocator, hyperedge_id);
                            // Initialize if not found.
                            if (!result.found_existing) {
                                result.value_ptr.* = .empty;
                            }
                            try result.value_ptr.*.append(self.allocator, adjacent);
                            debug("adjacent vertex {} to vertex {} found in hyperedge {}", .{ adjacent, id, hyperedge_id });
                        }
                    }
                }
            }

            return .{ .data = adjacents };
        }

        /// Return the out-neighbors of `id`: vertices directly reachable from `id`,
        /// grouped by hyperedge. Keys are hyperedge ids; values are the target vertices of
        /// pairs starting at `id` in that hyperedge.
        /// The caller is responsible for freeing the result memory with `deinit`.
        pub fn getVertexAdjacencyFrom(self: *Self, id: HypergraphZId) HypergraphZError!AdjacencyResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            try self.checkIfVertexExists(id);

            // We don't need to release the memory here since the caller will do it.
            var adjacents: AutoArrayHashMapUnmanaged(HypergraphZId, ArrayListUnmanaged(HypergraphZId)) = .empty;
            const vertex = self.vertices.get(id).?;
            for (vertex.relations.items) |hyperedge_id| {
                const hyperedge = self.hyperedges.get(hyperedge_id).?;
                if (hyperedge.relations.items.len > 0) {
                    // Use a window iterator over the hyperedge relations.
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |v| {
                        if (v[0] == id) {
                            const adjacent = v[1];
                            const result = try adjacents.getOrPut(self.allocator, hyperedge_id);
                            // Initialize if not found.
                            if (!result.found_existing) {
                                result.value_ptr.* = .empty;
                            }
                            try result.value_ptr.*.append(self.allocator, adjacent);
                            debug("adjacent vertex {} from vertex {} found in hyperedge {}", .{ adjacent, id, hyperedge_id });
                        }
                    }
                }
            }

            return .{ .data = adjacents };
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
            var intersections: ArrayListUnmanaged(HypergraphZId) = .empty;
            var matches: AutoArrayHashMapUnmanaged(HypergraphZId, usize) = .empty;
            defer matches.deinit(self.allocator);

            for (hyperedges_ids) |id| {
                const hyperedge = self.hyperedges.getPtr(id).?;

                // Keep track of visited vertices since the same vertex can appear multiple times within a hyperedge.
                var visited: AutoArrayHashMapUnmanaged(HypergraphZId, void) = .empty;
                defer visited.deinit(self.allocator);

                for (hyperedge.relations.items) |v| {
                    if (visited.get(v) != null) {
                        continue;
                    }
                    const result = try matches.getOrPut(self.allocator, v);
                    try visited.put(self.allocator, v, {});
                    if (result.found_existing) {
                        result.value_ptr.* += 1;
                        if (result.value_ptr.* == hyperedges_ids.len) {
                            debug("intersection found at vertex {}", .{v});
                            try intersections.append(self.allocator, v);
                        }
                    } else {
                        // Initialize.
                        result.value_ptr.* = 1;
                    }
                }
            }

            return try intersections.toOwnedSlice(self.allocator);
        }

        /// Struct containing the hyperedges as a hashset whose keys are
        /// hyperedge ids.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const HyperedgesResult = struct {
            data: AutoArrayHashMapUnmanaged(HypergraphZId, void),

            pub fn deinit(self: *HyperedgesResult, allocator: Allocator) void {
                self.data.deinit(allocator);
                self.* = undefined;
            }
        };

        /// Get all the hyperedges connecting two vertices.
        /// This method returns an owned slice which must be freed by the caller.
        pub fn getHyperedgesConnecting(self: *Self, first_vertex_id: HypergraphZId, second_vertex_id: HypergraphZId) HypergraphZError!HyperedgesResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            try self.checkIfVertexExists(first_vertex_id);
            try self.checkIfVertexExists(second_vertex_id);

            const eq = first_vertex_id == second_vertex_id;
            const first_vertex = self.vertices.get(first_vertex_id).?;
            var deduped: AutoArrayHashMapUnmanaged(HypergraphZId, void) = .empty;
            for (first_vertex.relations.items) |hyperedge_id| {
                const hyperedge = self.hyperedges.get(hyperedge_id).?;
                var found_occurences: usize = 0;
                for (hyperedge.relations.items) |v| {
                    if (v == second_vertex_id) {
                        found_occurences += 1;
                    }
                }
                // We need to take care of potential self-loops.
                if ((eq and found_occurences > 1) or (!eq and found_occurences > 0)) {
                    try deduped.put(self.allocator, hyperedge_id, {});
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

            pub fn deinit(self: *EndpointsResult) void {
                self.initial.deinit(self.allocator);
                self.terminal.deinit(self.allocator);
                self.* = undefined;
            }
        };

        /// Get all the initial and terminal endpoints of all the hyperedges.
        pub fn getEndpoints(self: *Self) HypergraphZError!EndpointsResult {
            var result: EndpointsResult = .init(self.allocator);
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
            var orphans: ArrayListUnmanaged(HypergraphZId) = .empty;
            var it = self.hyperedges.iterator();
            while (it.next()) |*kv| {
                const vertices = kv.value_ptr.relations;
                if (vertices.items.len == 0) {
                    try orphans.append(self.allocator, kv.key_ptr.*);
                }
            }

            debug("{} orphan hyperedges found", .{orphans.items.len});

            return orphans.toOwnedSlice(self.allocator);
        }

        /// Get the orphan vertices.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub fn getOrphanVertices(self: *Self) HypergraphZError![]const HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            var orphans: ArrayListUnmanaged(HypergraphZId) = .empty;
            var it = self.vertices.iterator();
            while (it.next()) |*kv| {
                const hyperedges = kv.value_ptr.relations;
                if (hyperedges.items.len == 0) {
                    try orphans.append(self.allocator, kv.key_ptr.*);
                }
            }

            debug("{} orphan vertices found", .{orphans.items.len});

            return orphans.toOwnedSlice(self.allocator);
        }

        // ============================================================
        // Traversal
        // ============================================================

        const Node = struct {
            from: HypergraphZId,
            weight: usize,
        };
        const CameFrom = AutoHashMapUnmanaged(HypergraphZId, ?Node);
        const Queue = PriorityQueue(HypergraphZId, *const CameFrom, compareNode);
        fn compareNode(map: *const CameFrom, n1: HypergraphZId, n2: HypergraphZId) std.math.Order {
            const w1: usize = if (map.get(n1)) |n| if (n) |e| e.weight else 0 else 0;
            const w2: usize = if (map.get(n2)) |n| if (n) |e| e.weight else 0 else 0;

            return std.math.order(w1, w2);
        }
        /// Struct containing the shortest path as a list of vertices.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const ShortestPathResult = struct {
            data: ?ArrayListUnmanaged(HypergraphZId),

            pub fn deinit(self: *ShortestPathResult, allocator: Allocator) void {
                if (self.data) |*d| d.deinit(allocator);
                self.* = undefined;
            }
        };

        /// Find the shortest path between two vertices using the A* algorithm.
        /// The caller is responsible for freeing the result memory with `deinit`.
        pub fn findShortestPath(self: *Self, from: HypergraphZId, to: HypergraphZId) HypergraphZError!ShortestPathResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            try self.checkIfVertexExists(from);
            try self.checkIfVertexExists(to);

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var came_from: CameFrom = .empty;
            var cost_so_far: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            var frontier: Queue = .initContext(&came_from);

            try came_from.put(arena_allocator, from, null);
            try cost_so_far.put(arena_allocator, from, 0);
            try frontier.push(arena_allocator, from);

            while (frontier.count() != 0) {
                const current = frontier.pop().?;

                if (current == to) break;

                // Inline adjacency traversal to avoid allocations per iteration.
                const current_cost = cost_so_far.get(current) orelse 0;
                const vertex = self.vertices.get(current).?;
                for (vertex.relations.items) |hyperedge_id| {
                    const hyperedge = self.hyperedges.get(hyperedge_id).?;
                    const weight = hyperedge.data.weight;
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |pair| {
                        if (pair[0] != current) continue;
                        const next = pair[1];
                        const new_cost = current_cost + weight;
                        const existing = cost_so_far.get(next);
                        if (existing == null or new_cost < existing.?) {
                            try cost_so_far.put(arena_allocator, next, new_cost);
                            try came_from.put(arena_allocator, next, .{
                                .weight = new_cost,
                                .from = current,
                            });
                            try frontier.push(arena_allocator, next);
                        }
                    }
                }
            }

            // Check if path was found.
            if (!came_from.contains(to)) {
                debug("no path found between {} and {}", .{ from, to });

                return .{ .data = null };
            }

            // Reconstruct path by walking came_from backward from `to`.
            var path: ArrayListUnmanaged(HypergraphZId) = .empty;
            try path.append(self.allocator, to);
            var cursor = to;
            while (came_from.get(cursor)) |entry| {
                if (entry) |e| {
                    try path.append(self.allocator, e.from);
                    cursor = e.from;
                } else break;
            }
            std.mem.reverse(HypergraphZId, path.items);

            debug("path found between {} and {}", .{ from, to });

            return .{ .data = path };
        }

        /// Perform a breadth-first search from a start vertex.
        /// Returns the visited vertices in BFS order.
        /// The caller is responsible for freeing the result with `graph.allocator.free(result)`.
        pub fn breadthFirstSearch(self: *Self, start: HypergraphZId) HypergraphZError![]const HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            try self.checkIfVertexExists(start);

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var visited: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var queue: ArrayListUnmanaged(HypergraphZId) = .empty;
            var result: ArrayListUnmanaged(HypergraphZId) = .empty;
            var head: usize = 0;

            try visited.put(arena_allocator, start, {});
            try queue.append(arena_allocator, start);
            try result.append(self.allocator, start);

            while (head < queue.items.len) {
                const current = queue.items[head];
                head += 1;
                const vertex = self.vertices.get(current).?;
                for (vertex.relations.items) |hyperedge_id| {
                    const hyperedge = self.hyperedges.get(hyperedge_id).?;
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |pair| {
                        if (pair[0] != current) continue;
                        const next = pair[1];
                        if (visited.contains(next)) continue;
                        try visited.put(arena_allocator, next, {});
                        try queue.append(arena_allocator, next);
                        try result.append(self.allocator, next);
                    }
                }
            }

            debug("BFS from {}: {} vertices visited", .{ start, result.items.len });

            return result.toOwnedSlice(self.allocator);
        }

        /// Perform a depth-first search from a start vertex.
        /// Returns the visited vertices in DFS order.
        /// The caller is responsible for freeing the result with `graph.allocator.free(result)`.
        pub fn depthFirstSearch(self: *Self, start: HypergraphZId) HypergraphZError![]const HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            try self.checkIfVertexExists(start);

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var visited: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var stack: ArrayListUnmanaged(HypergraphZId) = .empty;
            var neighbors: ArrayListUnmanaged(HypergraphZId) = .empty;
            var result: ArrayListUnmanaged(HypergraphZId) = .empty;

            try stack.append(arena_allocator, start);

            while (stack.items.len > 0) {
                const current = stack.pop().?;
                if (visited.contains(current)) continue;
                try visited.put(arena_allocator, current, {});
                try result.append(self.allocator, current);

                neighbors.clearRetainingCapacity();
                const vertex = self.vertices.get(current).?;
                for (vertex.relations.items) |hyperedge_id| {
                    const hyperedge = self.hyperedges.get(hyperedge_id).?;
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |pair| {
                        if (pair[0] != current) continue;
                        try neighbors.append(arena_allocator, pair[1]);
                    }
                }

                // Push in reverse so first-discovered is on top of the stack.
                var i = neighbors.items.len;
                while (i > 0) {
                    i -= 1;
                    try stack.append(arena_allocator, neighbors.items[i]);
                }
            }

            debug("DFS from {}: {} vertices visited", .{ start, result.items.len });

            return result.toOwnedSlice(self.allocator);
        }

        /// Struct containing all simple paths between two vertices.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const AllPathsResult = struct {
            data: ArrayListUnmanaged([]const HypergraphZId),

            pub fn deinit(self: *AllPathsResult, allocator: Allocator) void {
                for (self.data.items) |path| allocator.free(path);
                self.data.deinit(allocator);
                self.* = undefined;
            }
        };

        /// Find all simple paths between two vertices using an iterative DFS.
        /// A simple path visits no vertex more than once.
        /// The caller is responsible for freeing the result memory with `deinit`.
        pub fn findAllPaths(self: *Self, from: HypergraphZId, to: HypergraphZId) HypergraphZError!AllPathsResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            try self.checkIfVertexExists(from);
            try self.checkIfVertexExists(to);

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var result: AllPathsResult = .{ .data = .empty };

            const StackEntry = struct {
                vertex: HypergraphZId,
                path: ArrayListUnmanaged(HypergraphZId),
            };

            var stack: ArrayListUnmanaged(StackEntry) = .empty;
            var seen_neighbors: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;

            var initial_path: ArrayListUnmanaged(HypergraphZId) = .empty;
            try initial_path.append(arena_allocator, from);
            try stack.append(arena_allocator, .{ .vertex = from, .path = initial_path });

            while (stack.items.len > 0) {
                const entry = stack.pop().?;
                const current = entry.vertex;

                if (current == to) {
                    const owned = try self.allocator.dupe(HypergraphZId, entry.path.items);
                    try result.data.append(self.allocator, owned);
                    continue;
                }

                seen_neighbors.clearRetainingCapacity();
                const vertex = self.vertices.get(current).?;
                for (vertex.relations.items) |hyperedge_id| {
                    const hyperedge = self.hyperedges.get(hyperedge_id).?;
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |pair| {
                        if (pair[0] != current) continue;
                        const next = pair[1];
                        if (seen_neighbors.contains(next)) continue;
                        try seen_neighbors.put(arena_allocator, next, {});
                        var in_path = false;
                        for (entry.path.items) |v| {
                            if (v == next) {
                                in_path = true;
                                break;
                            }
                        }
                        if (in_path) continue;
                        var new_path = try entry.path.clone(arena_allocator);
                        try new_path.append(arena_allocator, next);
                        try stack.append(arena_allocator, .{ .vertex = next, .path = new_path });
                    }
                }
            }

            debug("findAllPaths from {} to {}: {} paths found", .{ from, to, result.data.items.len });

            return result;
        }

        /// Return true if there is a directed path from `from` to `to`.
        pub fn isReachable(self: *Self, from: HypergraphZId, to: HypergraphZId) HypergraphZError!bool {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            try self.checkIfVertexExists(from);
            try self.checkIfVertexExists(to);

            if (from == to) return true;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var visited: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var queue: ArrayListUnmanaged(HypergraphZId) = .empty;
            var head: usize = 0;

            try visited.put(arena_allocator, from, {});
            try queue.append(arena_allocator, from);

            while (head < queue.items.len) {
                const current = queue.items[head];
                head += 1;
                const vertex = self.vertices.get(current).?;
                for (vertex.relations.items) |hyperedge_id| {
                    const hyperedge = self.hyperedges.get(hyperedge_id).?;
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |pair| {
                        if (pair[0] != current) continue;
                        const next = pair[1];
                        if (next == to) {
                            debug("isReachable: {} -> {} true", .{ from, to });
                            return true;
                        }
                        if (visited.contains(next)) continue;
                        try visited.put(arena_allocator, next, {});
                        try queue.append(arena_allocator, next);
                    }
                }
            }

            debug("isReachable: {} -> {} false", .{ from, to });
            return false;
        }

        /// Return the strict transitive closure: a 2-uniform hypergraph where a
        /// hyperedge `[u, v]` exists for every pair where `v` is reachable from
        /// `u` via one or more directed hops. Self-loops `[u, u]` are included
        /// only when `u` lies on a cycle.
        /// `pairToHyperedge` produces the hyperedge data for each `(from, to)` pair.
        /// The caller must call `build()` on the result and is responsible for
        /// calling `deinit()` on it.
        ///
        /// Complexity: O(V * (V + E)). For dense or highly-connected graphs this
        /// may produce up to V² hyperedges. Consider calling on a subgraph or
        /// the k-skeleton if the full closure is too large.
        pub fn getTransitiveClosure(
            self: *Self,
            pairToHyperedge: fn (HypergraphZId, HypergraphZId) H,
        ) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var closure = try Self.init(self.allocator, .{
                .vertices_capacity = self.vertices.count(),
                .hyperedges_capacity = self.vertices.count(),
            });
            errdefer closure.deinit();

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            // Copy all vertices preserving their IDs.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                try closure.vertices.put(self.allocator, kv.key_ptr.*, .{
                    .relations = .empty,
                    .data = kv.value_ptr.data,
                });
                closure.id_counter = @max(closure.id_counter, kv.key_ptr.*);
            }

            var visited: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var queue: ArrayListUnmanaged(HypergraphZId) = .empty;

            // For each source vertex, BFS from its direct successors to find
            // all vertices reachable in >= 1 hop (strict transitive closure).
            var src_it = self.vertices.iterator();
            while (src_it.next()) |kv| {
                const src = kv.key_ptr.*;

                visited.clearRetainingCapacity();
                queue.clearRetainingCapacity();
                var head: usize = 0;

                // Seed with direct successors of src.
                const src_vertex = self.vertices.get(src).?;
                for (src_vertex.relations.items) |hyperedge_id| {
                    const hyperedge = self.hyperedges.get(hyperedge_id).?;
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |pair| {
                        if (pair[0] != src) continue;
                        const next = pair[1];
                        if (visited.contains(next)) continue;
                        try visited.put(arena_allocator, next, {});
                        try queue.append(arena_allocator, next);
                    }
                }

                // BFS to collect all transitively reachable vertices.
                while (head < queue.items.len) {
                    const current = queue.items[head];
                    head += 1;
                    const vertex = self.vertices.get(current).?;
                    for (vertex.relations.items) |hyperedge_id| {
                        const hyperedge = self.hyperedges.get(hyperedge_id).?;
                        var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                        while (wIt.next()) |pair| {
                            if (pair[0] != current) continue;
                            const next = pair[1];
                            if (visited.contains(next)) continue;
                            try visited.put(arena_allocator, next, {});
                            try queue.append(arena_allocator, next);
                        }
                    }
                }

                // Emit one 2-vertex hyperedge per reachable vertex.
                var reach_it = visited.keyIterator();
                while (reach_it.next()) |dst_ptr| {
                    const dst = dst_ptr.*;
                    const new_id = try closure.createHyperedge(pairToHyperedge(src, dst));
                    try closure.appendVertexToHyperedge(new_id, src);
                    try closure.appendVertexToHyperedge(new_id, dst);
                }
            }

            debug("getTransitiveClosure: {} vertices, {} hyperedges", .{
                closure.vertices.count(),
                closure.hyperedges.count(),
            });

            return closure;
        }

        // ============================================================
        // Algorithms
        // ============================================================

        /// Per-vertex centrality scores returned by `computeCentrality`.
        pub const CentralityResult = struct {
            /// Scores for a single vertex.
            pub const Scores = struct {
                /// Fraction of all directed window-pair endpoints that belong to
                /// this vertex. Normalized by `2 * (V - 1)`; range [0, 1].
                degree: f64,
                /// How quickly this vertex can reach all others.
                /// Wasserman-Faust normalization handles partial reachability:
                /// `reachable² / ((V - 1) * total_distance)`. Range [0, 1].
                closeness: f64,
                /// Fraction of shortest paths between other pairs that pass
                /// through this vertex. Normalized by `(V - 1) * (V - 2)` for
                /// directed graphs. Range [0, 1].
                betweenness: f64,
            };

            data: AutoArrayHashMapUnmanaged(HypergraphZId, Scores),

            pub fn deinit(self: *CentralityResult, allocator: Allocator) void {
                self.data.deinit(allocator);
                self.* = undefined;
            }
        };

        /// Compute degree, closeness and betweenness centrality for every vertex
        /// in a single pass. Closeness and betweenness share the O(V) BFS runs
        /// required by Brandes' algorithm; degree is accumulated during the same
        /// loop at negligible extra cost.
        ///
        /// Complexity: O(V * (V + E)).
        /// The caller is responsible for freeing the result memory with `deinit`.
        pub fn computeCentrality(self: *Self) HypergraphZError!CentralityResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            const n = self.vertices.count();

            var result: CentralityResult = .{ .data = .empty };
            errdefer result.deinit(self.allocator);

            // Initialise score entries for all vertices.
            var v_init = self.vertices.iterator();
            while (v_init.next()) |kv| {
                try result.data.put(self.allocator, kv.key_ptr.*, .{
                    .degree = 0.0,
                    .closeness = 0.0,
                    .betweenness = 0.0,
                });
            }

            if (n == 0) return result;

            // Degree centrality: count raw in/out window-pair endpoints per vertex.
            {
                var h_it = self.hyperedges.iterator();
                while (h_it.next()) |kv| {
                    var wIt = window(HypergraphZId, kv.value_ptr.relations.items, 2, 1);
                    while (wIt.next()) |pair| {
                        if (result.data.getPtr(pair[0])) |s| s.degree += 1.0;
                        if (result.data.getPtr(pair[1])) |s| s.degree += 1.0;
                    }
                }
                const denom = if (n > 1) 2.0 * @as(f64, @floatFromInt(n - 1)) else 1.0;
                var d_it = result.data.iterator();
                while (d_it.next()) |kv| kv.value_ptr.degree /= denom;
            }

            // Brandes' algorithm: shared BFS passes for closeness and betweenness.
            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var sigma: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            var dist: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            var delta: AutoHashMapUnmanaged(HypergraphZId, f64) = .empty;
            var pred: AutoHashMapUnmanaged(HypergraphZId, ArrayListUnmanaged(HypergraphZId)) = .empty;
            var bfs_stack: ArrayListUnmanaged(HypergraphZId) = .empty;
            var queue: ArrayListUnmanaged(HypergraphZId) = .empty;

            var src_it = self.vertices.iterator();
            while (src_it.next()) |kv| {
                const s = kv.key_ptr.*;

                // Reset per-source state, retaining allocated capacity in the arena.
                sigma.clearRetainingCapacity();
                dist.clearRetainingCapacity();
                delta.clearRetainingCapacity();
                {
                    var p_it = pred.iterator();
                    while (p_it.next()) |pkv| pkv.value_ptr.clearRetainingCapacity();
                    pred.clearRetainingCapacity();
                }
                bfs_stack.clearRetainingCapacity();
                queue.clearRetainingCapacity();
                var head: usize = 0;

                try sigma.put(arena_allocator, s, 1);
                try dist.put(arena_allocator, s, 0);
                try queue.append(arena_allocator, s);

                // BFS phase: compute shortest-path distances and counts.
                while (head < queue.items.len) {
                    const v = queue.items[head];
                    head += 1;
                    try bfs_stack.append(arena_allocator, v);

                    const v_dist = dist.get(v).?;
                    const v_sigma = sigma.get(v).?;

                    const vertex = self.vertices.get(v).?;
                    for (vertex.relations.items) |hyperedge_id| {
                        const hyperedge = self.hyperedges.get(hyperedge_id).?;
                        var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                        while (wIt.next()) |pair| {
                            if (pair[0] != v) continue;
                            const w = pair[1];
                            if (!dist.contains(w)) {
                                try dist.put(arena_allocator, w, v_dist + 1);
                                try queue.append(arena_allocator, w);
                            }
                            if (dist.get(w).? == v_dist + 1) {
                                try sigma.put(arena_allocator, w, (sigma.get(w) orelse 0) + v_sigma);
                                const pe = try pred.getOrPut(arena_allocator, w);
                                if (!pe.found_existing) pe.value_ptr.* = .empty;
                                try pe.value_ptr.append(arena_allocator, v);
                            }
                        }
                    }
                }

                // Initialise delta for all vertices reached from s.
                var dist_keys = dist.keyIterator();
                while (dist_keys.next()) |kp| try delta.put(arena_allocator, kp.*, 0.0);

                // Back-propagation phase: accumulate betweenness dependencies.
                var i = bfs_stack.items.len;
                while (i > 0) {
                    i -= 1;
                    const w = bfs_stack.items[i];
                    const w_sigma_f = @as(f64, @floatFromInt(sigma.get(w) orelse 1));
                    const w_delta = delta.get(w) orelse 0.0;
                    if (pred.get(w)) |preds| {
                        for (preds.items) |v| {
                            const v_sigma_f = @as(f64, @floatFromInt(sigma.get(v) orelse 1));
                            const cur = delta.get(v) orelse 0.0;
                            try delta.put(arena_allocator, v, cur + (v_sigma_f / w_sigma_f) * (1.0 + w_delta));
                        }
                    }
                    if (w != s) result.data.getPtr(w).?.betweenness += delta.get(w) orelse 0.0;
                }

                // Closeness: Wasserman-Faust normalization for partial reachability.
                var total_dist: usize = 0;
                var reachable: usize = 0;
                var d_iter = dist.iterator();
                while (d_iter.next()) |dkv| {
                    if (dkv.key_ptr.* == s) continue;
                    total_dist += dkv.value_ptr.*;
                    reachable += 1;
                }
                if (reachable > 0) {
                    const r = @as(f64, @floatFromInt(reachable));
                    const td = @as(f64, @floatFromInt(total_dist));
                    const nm1 = @as(f64, @floatFromInt(n - 1));
                    result.data.getPtr(s).?.closeness = (r * r) / (nm1 * td);
                }
            }

            // Normalise betweenness by (V-1)*(V-2) for directed graphs.
            if (n > 2) {
                const norm = @as(f64, @floatFromInt((n - 1) * (n - 2)));
                var b_it = result.data.iterator();
                while (b_it.next()) |kv| kv.value_ptr.betweenness /= norm;
            }

            debug("computeCentrality: {} vertices processed", .{n});
            return result;
        }

        /// Return true if the hypergraph contains at least one directed cycle.
        pub fn hasCycle(self: *Self) HypergraphZError!bool {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const VertexState = enum { in_stack, done };
            const StackEntry = struct { vertex: HypergraphZId, is_exit: bool };

            var state: AutoHashMapUnmanaged(HypergraphZId, VertexState) = .empty;
            var stack: ArrayListUnmanaged(StackEntry) = .empty;

            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                const seed = kv.key_ptr.*;
                if (state.contains(seed)) continue;

                try stack.append(arena_allocator, .{ .vertex = seed, .is_exit = false });

                while (stack.items.len > 0) {
                    const entry = stack.pop().?;

                    if (entry.is_exit) {
                        try state.put(arena_allocator, entry.vertex, .done);
                        continue;
                    }

                    if (state.get(entry.vertex)) |s| switch (s) {
                        .in_stack => {
                            debug("hasCycle: cycle detected at vertex {}", .{entry.vertex});
                            return true;
                        },
                        .done => continue,
                    };

                    try state.put(arena_allocator, entry.vertex, .in_stack);
                    try stack.append(arena_allocator, .{ .vertex = entry.vertex, .is_exit = true });

                    const vertex = self.vertices.get(entry.vertex).?;
                    for (vertex.relations.items) |hyperedge_id| {
                        const hyperedge = self.hyperedges.get(hyperedge_id).?;
                        var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                        while (wIt.next()) |pair| {
                            if (pair[0] != entry.vertex) continue;
                            try stack.append(arena_allocator, .{ .vertex = pair[1], .is_exit = false });
                        }
                    }
                }
            }

            debug("hasCycle: no cycle found", .{});
            return false;
        }

        /// Return a topological ordering of all vertices.
        /// Uses Kahn's algorithm (BFS-based), so vertices with equal rank appear in
        /// insertion order.
        /// Returns `HypergraphZError.CycleDetected` if the graph contains a cycle —
        /// there is no need to call `hasCycle` beforehand.
        /// The caller is responsible for freeing the returned slice with
        /// `graph.allocator.free(result)`.
        /// Requires `build()` to have been called.
        /// O(V + E) where E is the total number of directed pairs across all hyperedges.
        pub fn topologicalSort(self: *Self) HypergraphZError![]const HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            // Initialize in-degree to zero for every vertex (insertion order).
            var in_degree: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                try in_degree.put(aa, kv.key_ptr.*, 0);
            }

            // Count in-degrees from all directed pairs across all hyperedges.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                var wIt = window(HypergraphZId, kv.value_ptr.relations.items, 2, 1);
                while (wIt.next()) |pair| {
                    const entry = in_degree.getPtr(pair[1]).?;
                    entry.* += 1;
                }
            }

            // Seed the queue with all zero-in-degree vertices (in insertion order).
            var queue: ArrayListUnmanaged(HypergraphZId) = .empty;
            var id_it = self.vertices.iterator();
            while (id_it.next()) |kv| {
                if (in_degree.get(kv.key_ptr.*).? == 0) {
                    try queue.append(aa, kv.key_ptr.*);
                }
            }

            var result: ArrayListUnmanaged(HypergraphZId) = .empty;
            errdefer result.deinit(self.allocator);
            var head: usize = 0;

            while (head < queue.items.len) {
                const current = queue.items[head];
                head += 1;
                try result.append(self.allocator, current);

                // Decrement in-degree of each out-neighbor and enqueue newly unblocked ones.
                const vertex = self.vertices.get(current).?;
                for (vertex.relations.items) |h_id| {
                    const hyperedge = self.hyperedges.get(h_id).?;
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |pair| {
                        if (pair[0] != current) continue;
                        const entry = in_degree.getPtr(pair[1]).?;
                        entry.* -= 1;
                        if (entry.* == 0) {
                            try queue.append(aa, pair[1]);
                        }
                    }
                }
            }

            if (result.items.len < self.vertices.count()) {
                return HypergraphZError.CycleDetected;
            }

            debug("topologicalSort: ordered {} vertices", .{result.items.len});
            return try result.toOwnedSlice(self.allocator);
        }

        /// Return true if the hypergraph is weakly connected: every vertex is
        /// reachable from every other vertex when edge direction is ignored.
        /// An empty graph (no vertices) is considered connected.
        pub fn isConnected(self: *Self) HypergraphZError!bool {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            const count = self.vertices.count();
            if (count == 0) return true;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var visited: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var queue: ArrayListUnmanaged(HypergraphZId) = .empty;
            var head: usize = 0;

            var v_it = self.vertices.iterator();
            const start = v_it.next().?.key_ptr.*;
            try visited.put(arena_allocator, start, {});
            try queue.append(arena_allocator, start);

            while (head < queue.items.len) {
                const current = queue.items[head];
                head += 1;
                const vertex = self.vertices.get(current).?;
                for (vertex.relations.items) |hyperedge_id| {
                    const hyperedge = self.hyperedges.get(hyperedge_id).?;
                    var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                    while (wIt.next()) |pair| {
                        // Follow both directions: this is a weak-connectivity check.
                        const next = if (pair[0] == current) pair[1] else if (pair[1] == current) pair[0] else continue;
                        if (visited.contains(next)) continue;
                        try visited.put(arena_allocator, next, {});
                        try queue.append(arena_allocator, next);
                    }
                }
            }

            const connected = visited.count() == count;
            debug("isConnected: {}", .{connected});
            return connected;
        }

        /// Struct containing all weakly-connected components as slices of vertex IDs.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const ConnectedComponentsResult = struct {
            data: ArrayListUnmanaged([]const HypergraphZId),

            pub fn deinit(self: *ConnectedComponentsResult, allocator: Allocator) void {
                for (self.data.items) |component| allocator.free(component);
                self.data.deinit(allocator);
                self.* = undefined;
            }
        };

        /// Partition all vertices into weakly-connected components.
        /// Each component is a slice of vertex IDs reachable from each other
        /// when edge direction is ignored.
        /// The caller is responsible for freeing the result memory with `deinit`.
        pub fn getConnectedComponents(self: *Self) HypergraphZError!ConnectedComponentsResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var result: ConnectedComponentsResult = .{ .data = .empty };
            var visited: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var queue: ArrayListUnmanaged(HypergraphZId) = .empty;

            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                const seed = kv.key_ptr.*;
                if (visited.contains(seed)) continue;

                // BFS from seed (undirected) to collect one component.
                queue.clearRetainingCapacity();
                var head: usize = 0;
                var component: ArrayListUnmanaged(HypergraphZId) = .empty;

                try visited.put(arena_allocator, seed, {});
                try queue.append(arena_allocator, seed);
                try component.append(arena_allocator, seed);

                while (head < queue.items.len) {
                    const current = queue.items[head];
                    head += 1;
                    const vertex = self.vertices.get(current).?;
                    for (vertex.relations.items) |hyperedge_id| {
                        const hyperedge = self.hyperedges.get(hyperedge_id).?;
                        var wIt = window(HypergraphZId, hyperedge.relations.items, 2, 1);
                        while (wIt.next()) |pair| {
                            const next = if (pair[0] == current) pair[1] else if (pair[1] == current) pair[0] else continue;
                            if (visited.contains(next)) continue;
                            try visited.put(arena_allocator, next, {});
                            try queue.append(arena_allocator, next);
                            try component.append(arena_allocator, next);
                        }
                    }
                }

                const owned = try self.allocator.dupe(HypergraphZId, component.items);
                try result.data.append(self.allocator, owned);
            }

            debug("getConnectedComponents: {} components found", .{result.data.items.len});
            return result;
        }

        // ============================================================
        // Projections
        // ============================================================

        /// Return the dual hypergraph: hyperedges become vertices and vertices
        /// become hyperedges. The caller must call `build()` on the result and
        /// is responsible for calling `deinit()` on it.
        /// `hyperedgeToVertex` maps each original hyperedge's data to vertex data
        /// in the dual; `vertexToHyperedge` does the reverse.
        pub fn getDual(
            self: *Self,
            hyperedgeToVertex: fn (H) V,
            vertexToHyperedge: fn (V) H,
        ) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var dual = try Self.init(self.allocator, .{
                .vertices_capacity = self.hyperedges.count(),
                .hyperedges_capacity = self.vertices.count(),
            });
            errdefer dual.deinit();

            // Map old hyperedge ID -> new vertex ID in the dual.
            var id_map: AutoHashMapUnmanaged(HypergraphZId, HypergraphZId) = .empty;
            defer id_map.deinit(self.allocator);

            // Step 1: each original hyperedge becomes a vertex.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                const new_vertex_id = try dual.createVertexAssumeCapacity(
                    hyperedgeToVertex(kv.value_ptr.data.*),
                );
                try id_map.put(self.allocator, kv.key_ptr.*, new_vertex_id);
            }

            // Step 2: each original vertex becomes a hyperedge, connecting the
            // new vertices that correspond to hyperedges the original vertex
            // belonged to.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                const new_hyperedge_id = try dual.createHyperedgeAssumeCapacity(
                    vertexToHyperedge(kv.value_ptr.data.*),
                );
                for (kv.value_ptr.relations.items) |old_hyperedge_id| {
                    const new_vertex_id = id_map.get(old_hyperedge_id).?;
                    try dual.appendVertexToHyperedge(new_hyperedge_id, new_vertex_id);
                }
            }

            debug("getDual: {} vertices, {} hyperedges", .{
                dual.vertices.count(),
                dual.hyperedges.count(),
            });

            return dual;
        }

        /// Return the k-skeleton of the hypergraph: a new hypergraph containing
        /// all vertices and only the hyperedges whose raw vertex count is at
        /// most `k` (i.e. `hyperedge.relations.len <= k`).
        /// The caller must call `build()` on the result and is responsible for
        /// calling `deinit()` on it.
        pub fn getKSkeleton(self: *Self, k: usize) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var skeleton = try Self.init(self.allocator, .{
                .vertices_capacity = self.vertices.count(),
                .hyperedges_capacity = self.hyperedges.count(),
            });
            errdefer skeleton.deinit();

            // Copy all vertices preserving their IDs.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                try skeleton.vertices.put(self.allocator, kv.key_ptr.*, .{
                    .relations = .empty,
                    .data = kv.value_ptr.data,
                });
                skeleton.id_counter = @max(skeleton.id_counter, kv.key_ptr.*);
            }

            // Copy only hyperedges with raw vertex count <= k.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                if (kv.value_ptr.relations.items.len > k) continue;
                const owned = try self.allocator.dupe(
                    HypergraphZId,
                    kv.value_ptr.relations.items,
                );
                try skeleton.hyperedges.put(self.allocator, kv.key_ptr.*, .{
                    .relations = ArrayListUnmanaged(HypergraphZId).fromOwnedSlice(owned),
                    .data = kv.value_ptr.data,
                });
                skeleton.id_counter = @max(skeleton.id_counter, kv.key_ptr.*);
            }

            debug("getKSkeleton({}): {} vertices, {} hyperedges", .{
                k,
                skeleton.vertices.count(),
                skeleton.hyperedges.count(),
            });

            return skeleton;
        }

        /// Return the vertex-induced subhypergraph: a new hypergraph containing
        /// exactly the specified vertices and only the hyperedges whose entire
        /// vertex list is a subset of those vertices (strict).
        /// The caller must call `build()` on the result and is responsible for
        /// calling `deinit()` on it.
        pub fn getVertexInducedSubhypergraph(self: *Self, vertex_ids: []const HypergraphZId) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            for (vertex_ids) |id| try self.checkIfVertexExists(id);

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            // Build a lookup set from the requested vertex IDs.
            var vertex_set: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            for (vertex_ids) |id| try vertex_set.put(arena_allocator, id, {});

            var sub = try Self.init(self.allocator, .{
                .vertices_capacity = vertex_ids.len,
                .hyperedges_capacity = self.hyperedges.count(),
            });
            errdefer sub.deinit();

            // Copy the requested vertices preserving their IDs.
            for (vertex_ids) |id| {
                const kv = self.vertices.getEntry(id).?;
                try sub.vertices.put(self.allocator, id, .{
                    .relations = .empty,
                    .data = kv.value_ptr.data,
                });
                sub.id_counter = @max(sub.id_counter, id);
            }

            // Copy hyperedges whose every vertex is in the set.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                const relations = kv.value_ptr.relations.items;
                const all_in_set = for (relations) |v| {
                    if (!vertex_set.contains(v)) break false;
                } else true;
                if (!all_in_set) continue;
                const owned = try self.allocator.dupe(HypergraphZId, relations);
                try sub.hyperedges.put(self.allocator, kv.key_ptr.*, .{
                    .relations = ArrayListUnmanaged(HypergraphZId).fromOwnedSlice(owned),
                    .data = kv.value_ptr.data,
                });
                sub.id_counter = @max(sub.id_counter, kv.key_ptr.*);
            }

            debug("getVertexInducedSubhypergraph: {} vertices, {} hyperedges", .{
                sub.vertices.count(),
                sub.hyperedges.count(),
            });

            return sub;
        }

        /// Return the edge-induced subhypergraph: a new hypergraph containing
        /// exactly the specified hyperedges and only the vertices that appear
        /// in at least one of them.
        /// The caller must call `build()` on the result and is responsible for
        /// calling `deinit()` on it.
        pub fn getEdgeInducedSubhypergraph(self: *Self, hyperedge_ids: []const HypergraphZId) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            for (hyperedge_ids) |id| try self.checkIfHyperedgeExists(id);

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            // Collect unique vertices referenced by the requested hyperedges.
            var vertex_set: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            for (hyperedge_ids) |hid| {
                const hyperedge = self.hyperedges.get(hid).?;
                for (hyperedge.relations.items) |vid| {
                    try vertex_set.put(arena_allocator, vid, {});
                }
            }

            var sub = try Self.init(self.allocator, .{
                .vertices_capacity = vertex_set.count(),
                .hyperedges_capacity = hyperedge_ids.len,
            });
            errdefer sub.deinit();

            // Copy the referenced vertices preserving their IDs.
            var v_it = vertex_set.keyIterator();
            while (v_it.next()) |id_ptr| {
                const id = id_ptr.*;
                const kv = self.vertices.getEntry(id).?;
                try sub.vertices.put(self.allocator, id, .{
                    .relations = .empty,
                    .data = kv.value_ptr.data,
                });
                sub.id_counter = @max(sub.id_counter, id);
            }

            // Copy the requested hyperedges preserving their IDs.
            for (hyperedge_ids) |hid| {
                const kv = self.hyperedges.getEntry(hid).?;
                const owned = try self.allocator.dupe(HypergraphZId, kv.value_ptr.relations.items);
                try sub.hyperedges.put(self.allocator, hid, .{
                    .relations = ArrayListUnmanaged(HypergraphZId).fromOwnedSlice(owned),
                    .data = kv.value_ptr.data,
                });
                sub.id_counter = @max(sub.id_counter, hid);
            }

            debug("getEdgeInducedSubhypergraph: {} vertices, {} hyperedges", .{
                sub.vertices.count(),
                sub.hyperedges.count(),
            });

            return sub;
        }

        /// Return true if every hyperedge has exactly `k` vertices (raw count).
        /// An empty hyperedge set is vacuously true for any `k`.
        pub fn isKUniform(self: *Self, k: usize) HypergraphZError!bool {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                if (kv.value_ptr.relations.items.len != k) return false;
            }

            return true;
        }

        /// Decompose the hypergraph into a 2-uniform (plain directed) graph by
        /// replacing each hyperedge with its constituent directed pairs.
        /// Each window pair `(a, b)` becomes its own 2-vertex hyperedge,
        /// inheriting the original hyperedge's data. Duplicate pairs are kept.
        /// The caller must call `build()` on the result and is responsible for
        /// calling `deinit()` on it.
        pub fn expandToGraph(self: *Self) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var graph = try Self.init(self.allocator, .{
                .vertices_capacity = self.vertices.count(),
                .hyperedges_capacity = self.hyperedges.count(),
            });
            errdefer graph.deinit();

            // Copy all vertices preserving their IDs.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                try graph.vertices.put(self.allocator, kv.key_ptr.*, .{
                    .relations = .empty,
                    .data = kv.value_ptr.data,
                });
                graph.id_counter = @max(graph.id_counter, kv.key_ptr.*);
            }

            // Decompose each hyperedge into its window pairs.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                var wIt = window(HypergraphZId, kv.value_ptr.relations.items, 2, 1);
                while (wIt.next()) |pair| {
                    const new_id = try graph.createHyperedge(kv.value_ptr.data.*);
                    try graph.appendVertexToHyperedge(new_id, pair[0]);
                    try graph.appendVertexToHyperedge(new_id, pair[1]);
                }
            }

            debug("expandToGraph: {} vertices, {} hyperedges", .{
                graph.vertices.count(),
                graph.hyperedges.count(),
            });

            return graph;
        }

        // ============================================================
        // Codec
        // ============================================================

        /// Magic number for the binary format: bytes 'H','G','P','Z' as little-endian u32.
        const codec_magic: u32 = 0x5A504748;
        /// Current binary format version.
        const codec_version: u8 = 1;

        /// Asserts at comptime that T is pointer-free: no field (recursively) has type
        /// `.pointer`, which in Zig covers both raw pointers (`*T`) and slices (`[]T`).
        /// Pointer-free types are fully self-contained within `@sizeOf(T)` bytes and
        /// can be serialized by copying their raw memory.
        fn assertPointerFree(comptime T: type) void {
            inline for (std.meta.fields(T)) |field| {
                switch (@typeInfo(field.type)) {
                    .pointer => @compileError("defaultSerialize/defaultDeserialize: type '" ++
                        @typeName(T) ++ "' has pointer/slice field '" ++ field.name ++
                        "'; provide a custom codec"),
                    .@"struct" => assertPointerFree(field.type),
                    else => {},
                }
            }
        }

        /// Serialize a pointer-free value by writing its raw bytes (`@sizeOf(T)` bytes total).
        /// Pointer-free means no field (recursively) is a pointer or slice.
        /// Asserts this constraint at comptime; supply a custom codec for types that own heap data.
        pub fn defaultSerialize(comptime T: type, val: T, writer: *std.Io.Writer) !void {
            assertPointerFree(T);
            try writer.writeAll(std.mem.asBytes(&val));
        }

        /// Deserialize a pointer-free value by reading its raw bytes (`@sizeOf(T)` bytes total).
        /// Pointer-free means no field (recursively) is a pointer or slice.
        /// Asserts this constraint at comptime; supply a custom codec for types that own heap data.
        pub fn defaultDeserialize(comptime T: type, reader: *std.Io.Reader) !T {
            assertPointerFree(T);
            var buf: [@sizeOf(T)]u8 = undefined;
            try reader.readSliceAll(&buf);
            return std.mem.bytesToValue(T, &buf);
        }

        /// Save the hypergraph to `writer` using the supplied codec functions.
        ///
        /// `serializeH` is called as `serializeH(h_value, writer)` for each hyperedge payload.
        /// `serializeV` is called as `serializeV(v_value, writer)` for each vertex payload.
        /// All integers are written little-endian.
        pub fn save(
            self: *const Self,
            writer: *std.Io.Writer,
            comptime serializeH: anytype,
            comptime serializeV: anytype,
        ) !void {
            // Header.
            try writer.writeInt(u32, codec_magic, .little);
            try writer.writeByte(codec_version);
            try writer.writeInt(u32, self.id_counter, .little);
            try writer.writeInt(u32, @intCast(self.vertices.count()), .little);
            try writer.writeInt(u32, @intCast(self.hyperedges.count()), .little);

            // Vertices.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                try writer.writeInt(u32, kv.key_ptr.*, .little);
                var payload_w = std.Io.Writer.Allocating.init(self.allocator);
                defer payload_w.deinit();
                try serializeV(kv.value_ptr.data.*, &payload_w.writer);
                const payload = payload_w.writer.buffer[0..payload_w.writer.end];
                try writer.writeInt(u32, @intCast(payload.len), .little);
                try writer.writeAll(payload);
            }

            // Hyperedges.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                try writer.writeInt(u32, kv.key_ptr.*, .little);
                var payload_w = std.Io.Writer.Allocating.init(self.allocator);
                defer payload_w.deinit();
                try serializeH(kv.value_ptr.data.*, &payload_w.writer);
                const payload = payload_w.writer.buffer[0..payload_w.writer.end];
                try writer.writeInt(u32, @intCast(payload.len), .little);
                try writer.writeAll(payload);
                const vtx = kv.value_ptr.relations.items;
                try writer.writeInt(u32, @intCast(vtx.len), .little);
                for (vtx) |vid| {
                    try writer.writeInt(u32, vid, .little);
                }
            }
        }

        /// Load a hypergraph from `reader` using the supplied codec functions.
        ///
        /// `deserializeH` is called as `deserializeH(reader)` for each hyperedge payload.
        /// `deserializeV` is called as `deserializeV(reader)` for each vertex payload.
        /// The caller must call `build()` on the result before issuing queries.
        pub fn load(
            allocator: Allocator,
            reader: *std.Io.Reader,
            comptime deserializeH: anytype,
            comptime deserializeV: anytype,
        ) !Self {
            // Header.
            const magic = try reader.takeInt(u32, .little);

            if (magic != codec_magic) return HypergraphZError.InvalidMagicNumber;

            const version = try reader.takeByte();

            if (version != codec_version) return HypergraphZError.UnsupportedVersion;

            const id_counter = try reader.takeInt(u32, .little);
            const vertex_count = try reader.takeInt(u32, .little);
            const edge_count = try reader.takeInt(u32, .little);

            var graph = try Self.init(allocator, .{
                .vertices_capacity = vertex_count,
                .hyperedges_capacity = edge_count,
            });
            errdefer graph.deinit();
            graph.id_counter = id_counter;

            // Vertices.
            for (0..vertex_count) |_| {
                const vid = try reader.takeInt(u32, .little);
                const payload_len = try reader.takeInt(u32, .little);
                const payload_bytes = try allocator.alloc(u8, payload_len);
                defer allocator.free(payload_bytes);
                try reader.readSliceAll(payload_bytes);
                var payload_r = std.Io.Reader.fixed(payload_bytes);
                const data = try deserializeV(&payload_r);
                const new_data = try graph.vertices_pool.create(allocator);
                new_data.* = data;
                try graph.vertices.put(allocator, vid, .{
                    .relations = .empty,
                    .data = new_data,
                });
            }

            // Hyperedges.
            for (0..edge_count) |_| {
                const hid = try reader.takeInt(u32, .little);
                const payload_len = try reader.takeInt(u32, .little);
                const payload_bytes = try allocator.alloc(u8, payload_len);
                defer allocator.free(payload_bytes);
                try reader.readSliceAll(payload_bytes);
                var payload_r = std.Io.Reader.fixed(payload_bytes);
                const data = try deserializeH(&payload_r);
                const new_data = try graph.hyperedges_pool.create(allocator);
                new_data.* = data;
                const vtx_count = try reader.takeInt(u32, .little);
                var vtx_list: ArrayListUnmanaged(HypergraphZId) = .empty;
                try vtx_list.ensureTotalCapacity(allocator, vtx_count);
                for (0..vtx_count) |_| {
                    const vid = try reader.takeInt(u32, .little);
                    vtx_list.appendAssumeCapacity(vid);
                }
                try graph.hyperedges.put(allocator, hid, .{
                    .relations = vtx_list,
                    .data = new_data,
                });
            }

            return graph;
        }
    };
}

comptime {
    _ = @import("tests/core_tests.zig");
    _ = @import("tests/mutations_tests.zig");
    _ = @import("tests/queries_tests.zig");
    _ = @import("tests/traversal_tests.zig");
    _ = @import("tests/algorithms_tests.zig");
    _ = @import("tests/projections_tests.zig");
    _ = @import("tests/codec_tests.zig");
}
