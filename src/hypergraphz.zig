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
//!
//! ## Debug logging
//!
//! HypergraphZ emits structured debug messages via `std.log` under the `.hypergraphz` scope.
//! Each message is automatically prefixed with the name of the function that produced it,
//! e.g. `[hypergraphz] (debug): [appendVertexToHyperedge] vertex 1 appended to hyperedge 3`.
//!
//! Debug messages are **silent by default**. To enable them, set the runtime log level
//! before your operations:
//!
//! ```zig
//! const hg = @import("hypergraphz");
//! hg.log_level = .debug;
//! ```
//!
//! In tests, verbosity is controlled separately via `std.testing.log_level` (set to `.debug`
//! by default in HypergraphZ's own test scaffold).

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const AutoArrayHashMap = std.array_hash_map.Auto;
const MemoryPool = std.heap.MemoryPool;
const MultiArrayList = std.MultiArrayList;
const PriorityQueue = std.PriorityQueue;
const assert = std.debug.assert;
const log = std.log.scoped(.hypergraphz);
const window = std.mem.window;

/// Runtime log level for HypergraphZ debug messages. Defaults to `.warn` (silent).
/// Set to `.debug` to enable per-operation trace output.
/// In test builds, `std.testing.log_level` controls verbosity independently.
pub var log_level: std.log.Level = .warn;

/// Emit a debug log line prefixed with the calling function's name.
/// In test builds: always forwards to std.log, gated by std.testing.log_level.
/// In non-test builds: gated by the `log_level` variable above.
/// Usage: debugAt(@src(), "message {}", .{arg});
/// Output: [hypergraphz] (debug): [functionName] message arg
inline fn debugAt(comptime src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    const emit = @import("builtin").is_test or
        @intFromEnum(std.log.Level.debug) <= @intFromEnum(log_level);
    if (emit) {
        log.debug("[" ++ src.fn_name ++ "] " ++ fmt, args);
    }
}

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

/// Options for `HypergraphZ`.
pub const HypergraphZOptions = struct {
    /// Name of the integer field on the hyperedge type used as the hyperedge weight
    /// in `findShortestPath`. Defaults to `"weight"`.
    weight_field: []const u8 = "weight",
};

/// Create a hypergraph with hyperedges and vertices as comptime types.
/// Both vertex and hyperedge must be struct types.
/// The hyperedge type must have an integer field whose name matches
/// `options.weight_field` (default `"weight"`).
pub fn HypergraphZ(comptime H: type, comptime V: type, comptime options: HypergraphZOptions) type {
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
        /// Whether the reverse index (vertex → hyperedges) has been built.
        /// Set to `true` by `build()`, reset to `false` by `clear()`.
        /// When `false`, insertion operations skip the reverse index for performance;
        /// query operations that require it return `HypergraphZError.NotBuilt`.
        is_built: bool = false,

        comptime {
            assert(@typeInfo(H) == .@"struct");
            var weightFieldType: ?type = null;
            for (@typeInfo(H).@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, options.weight_field)) {
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
            relations: ArrayList(HypergraphZId),
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

        // ============================================================
        // Core
        // ============================================================

        /// Create a new HypergraphZ instance.
        pub fn init(allocator: Allocator, config: HypergraphZConfig) HypergraphZError!Self {
            // We use an array list for hyperedges and an array hashmap for vertices.
            // The hyperedges can't be a hashmap since a hyperedge can contain the same vertex multiple times.
            var h: AutoArrayHashMap(HypergraphZId, HyperedgeDataRelations) = .empty;
            var v: AutoArrayHashMap(HypergraphZId, VertexDataRelations) = .empty;

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
                    .relations = ArrayList(HypergraphZId).fromOwnedSlice(owned),
                    .data = new_data,
                });
                copy.id_counter = @max(copy.id_counter, kv.key_ptr.*);
            }

            debugAt(@src(), "{} vertices, {} hyperedges", .{ copy.vertices.count(), copy.hyperedges.count() });
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
        /// for (raw_hyperedges) |hyperedge| {
        ///     const h = try graph.createHyperedge(hyperedge.data);
        ///     try graph.appendVerticesToHyperedge(h, hyperedge.vertices);
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

            debugAt(@src(), "reverse index built: {} vertices, {} hyperedges", .{
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
                debugAt(@src(), "hyperedge {} not found", .{id});

                return HypergraphZError.HyperedgeNotFound;
            };
        }

        fn _vertexPtr(self: *Self, id: HypergraphZId) HypergraphZError!*VertexDataRelations {
            return self.vertices.getPtr(id) orelse {
                debugAt(@src(), "vertex {} not found", .{id});

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

            debugAt(@src(), "vertex {} appended to hyperedge {}", .{
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

            debugAt(@src(), "vertex {} prepended to hyperedge {}", .{
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

            debugAt(@src(), "vertex {} inserted into hyperedge {} at index {}", .{
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
                debugAt(@src(), "no vertices to append to hyperedge {}, skipping", .{hyperedge_id});

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

            debugAt(@src(), "vertices appended to hyperedge {}", .{hyperedge_id});
        }

        /// Prepend vertices to a hyperedge.
        /// In the build phase (before `build()` is called), only the forward index
        /// is updated for performance; the reverse index is populated lazily by `build()`.
        pub fn prependVerticesToHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertices_ids: []const HypergraphZId) HypergraphZError!void {
            if (vertices_ids.len == 0) {
                debugAt(@src(), "no vertices to prepend to hyperedge {}, skipping", .{hyperedge_id});

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

            debugAt(@src(), "vertices prepended to hyperedge {}", .{hyperedge_id});
        }

        /// Insert vertices into a hyperedge at a given index.
        /// In the build phase (before `build()` is called), only the forward index
        /// is updated for performance; the reverse index is populated lazily by `build()`.
        pub fn insertVerticesIntoHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertices_ids: []const HypergraphZId, index: usize) HypergraphZError!void {
            if (vertices_ids.len == 0) {
                debugAt(@src(), "no vertices to insert into hyperedge {}, skipping", .{hyperedge_id});

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

            debugAt(@src(), "vertices inserted into hyperedge {} at index {}", .{ hyperedge_id, index });
        }

        /// Delete a vertex from a hyperedge.
        pub fn deleteVertexFromHyperedge(self: *Self, hyperedge_id: HypergraphZId, vertex_id: HypergraphZId) HypergraphZError!void {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            const hyperedge = try self._hyperedgePtr(hyperedge_id);

            // The same vertex can appear multiple times within a hyperedge.
            // Create a temporary list to store the relations without the vertex.
            var tmp: ArrayList(HypergraphZId) = .empty;
            defer tmp.deinit(self.allocator);
            for (hyperedge.relations.items) |v| {
                if (v != vertex_id) {
                    try tmp.append(self.allocator, v);
                }
            }
            // Swap the temporary list with the hyperedge relations.
            std.mem.swap(ArrayList(HypergraphZId), &hyperedge.relations, &tmp);

            const vertex = try self._vertexPtr(vertex_id);
            const removed = _removeVertexRelation(vertex, hyperedge_id);
            assert(removed);
            debugAt(@src(), "vertex {} deleted from hyperedge {}", .{ vertex_id, hyperedge_id });
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

            debugAt(@src(), "vertex {} at index {} deleted from hyperedge {}", .{ vertex_id, index, hyperedge_id });
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

            debugAt(@src(), "hyperedge {} deleted", .{id});
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
                var tmp: ArrayList(HypergraphZId) = .empty;
                defer tmp.deinit(self.allocator);
                for (hyperedge.relations.items) |v| {
                    if (v != id) {
                        try tmp.append(self.allocator, v);
                    }
                }
                // Swap the temporary list with the hyperedge relations.
                std.mem.swap(ArrayList(HypergraphZId), &hyperedge.relations, &tmp);
            }

            // Remove from the vertices pool.
            self.vertices_pool.destroy(@alignCast(vertex.data));

            // Release memory.
            vertex.relations.deinit(self.allocator);

            // Delete the vertex itself.
            const removed = self.vertices.orderedRemove(id);
            assert(removed);

            debugAt(@src(), "vertex {} deleted", .{id});
        }

        /// Reverse a hyperedge.
        pub fn reverseHyperedge(self: *Self, hyperedge_id: HypergraphZId) HypergraphZError!void {
            const hyperedge = try self._hyperedgePtr(hyperedge_id);
            const tmp = try hyperedge.relations.toOwnedSlice(self.allocator);
            std.mem.reverse(HypergraphZId, tmp);
            hyperedge.relations = ArrayList(HypergraphZId).fromOwnedSlice(tmp);
            debugAt(@src(), "hyperedge {} reversed", .{hyperedge_id});
        }

        /// Merge two or more hyperedges into one.
        /// All the vertices are moved to the first hyperedge.
        pub fn mergeHyperedges(self: *Self, hyperedges_ids: []const HypergraphZId) HypergraphZError!void {
            if (hyperedges_ids.len < 2) {
                debugAt(@src(), "at least two hyperedges must be provided, skipping", .{});

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

            debugAt(@src(), "hyperedges {any} merged into hyperedge {}", .{ hyperedges_ids, hyperedges_ids[0] });
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
            var tail: ArrayList(HypergraphZId) = .empty;
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

            debugAt(@src(), "hyperedge {} split at {} into hyperedge {}", .{ id, at, new_id });
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
            debugAt(@src(), "hyperedge {} contracted", .{id});
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

            debugAt(@src(), "vertices {any} merged into vertex {}", .{ vertex_ids, primary });
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

            debugAt(@src(), "vertex {} split into vertex {}", .{ id, new_id });
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
            data: AutoArrayHashMap(HypergraphZId, ArrayList(HypergraphZId)),

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

        /// Return the in-neighbors of `id`: vertices with a directed connection pointing into `id`,
        /// grouped by hyperedge. Keys are hyperedge ids; values are the source vertices of
        /// pairs ending at `id` in that hyperedge.
        /// The caller is responsible for freeing the result memory with `deinit`.
        pub fn getVertexAdjacencyTo(self: *Self, id: HypergraphZId) HypergraphZError!AdjacencyResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            try self.checkIfVertexExists(id);

            // We don't need to release the memory here since the caller will do it.
            var adjacents: AutoArrayHashMap(HypergraphZId, ArrayList(HypergraphZId)) = .empty;
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
                            debugAt(@src(), "adjacent vertex {} to vertex {} found in hyperedge {}", .{ adjacent, id, hyperedge_id });
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
            var adjacents: AutoArrayHashMap(HypergraphZId, ArrayList(HypergraphZId)) = .empty;
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
                            debugAt(@src(), "adjacent vertex {} from vertex {} found in hyperedge {}", .{ adjacent, id, hyperedge_id });
                        }
                    }
                }
            }

            return .{ .data = adjacents };
        }

        /// Return the (undirected) co-occurrence neighborhood of `vertex_id`:
        /// every distinct vertex that shares at least one hyperedge with it.
        /// `vertex_id` itself is excluded.
        ///
        /// This is the symmetric, hyperedge-aware counterpart to
        /// `getVertexAdjacencyTo` / `getVertexAdjacencyFrom`, which only
        /// follow consecutive `(a, b)` window pairs and so respect the
        /// directed semantics. Use this when "neighbor" means "co-appears in
        /// at least one hyperedge", regardless of position within it.
        ///
        /// The returned IDs are emitted in first-encounter order across the
        /// vertex's incident hyperedges. Vertex multiplicity within any one
        /// hyperedge is collapsed.
        ///
        /// Complexity: `O(Σ_{e ∋ v} |e|)`.
        /// The caller is responsible for freeing the result with
        /// `graph.allocator.free(result)`.
        pub fn getVertexNeighborhood(self: *Self, vertex_id: HypergraphZId) HypergraphZError![]const HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            try self.checkIfVertexExists(vertex_id);

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            // Pre-mark `vertex_id` so we don't have to special-case it on
            // every comparison inside the inner loop.
            try seen.put(aa, vertex_id, {});

            var out: ArrayList(HypergraphZId) = .empty;
            errdefer out.deinit(self.allocator);

            const vertex = self.vertices.get(vertex_id).?;
            for (vertex.relations.items) |hid| {
                const hyperedge = self.hyperedges.get(hid).?;
                for (hyperedge.relations.items) |vid| {
                    const gop = try seen.getOrPut(aa, vid);
                    if (gop.found_existing) continue;
                    try out.append(self.allocator, vid);
                }
            }

            const owned = try out.toOwnedSlice(self.allocator);
            debugAt(@src(), "vertex {}: {} neighbors", .{ vertex_id, owned.len });
            return owned;
        }

        /// Get the intersections between multiple hyperedges.
        /// This method returns an owned slice which must be freed by the caller.
        pub fn getIntersections(self: *Self, hyperedges_ids: []const HypergraphZId) HypergraphZError![]const HypergraphZId {
            if (hyperedges_ids.len < 2) {
                debugAt(@src(), "at least two hyperedges must be provided, skipping", .{});

                return HypergraphZError.NotEnoughHyperedgesProvided;
            }

            for (hyperedges_ids) |id| {
                try self.checkIfHyperedgeExists(id);
            }

            // We don't need to release the memory here since the caller will do it.
            var intersections: ArrayList(HypergraphZId) = .empty;
            var matches: AutoArrayHashMap(HypergraphZId, usize) = .empty;
            defer matches.deinit(self.allocator);

            for (hyperedges_ids) |id| {
                const hyperedge = self.hyperedges.getPtr(id).?;

                // Keep track of visited vertices since the same vertex can appear multiple times within a hyperedge.
                var visited: AutoArrayHashMap(HypergraphZId, void) = .empty;
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
                            debugAt(@src(), "intersection found at vertex {}", .{v});
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
            data: AutoArrayHashMap(HypergraphZId, void),

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
            var deduped: AutoArrayHashMap(HypergraphZId, void) = .empty;
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

            debugAt(@src(), "{} initial and {} terminal endpoints found", .{ result.initial.len, result.terminal.len });

            return result;
        }

        /// Get the orphan hyperedges.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub fn getOrphanHyperedges(self: *Self) HypergraphZError![]const HypergraphZId {
            var orphans: ArrayList(HypergraphZId) = .empty;
            var it = self.hyperedges.iterator();
            while (it.next()) |*kv| {
                const vertices = kv.value_ptr.relations;
                if (vertices.items.len == 0) {
                    try orphans.append(self.allocator, kv.key_ptr.*);
                }
            }

            debugAt(@src(), "{} orphan hyperedges found", .{orphans.items.len});

            return orphans.toOwnedSlice(self.allocator);
        }

        /// Get the orphan vertices.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub fn getOrphanVertices(self: *Self) HypergraphZError![]const HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            var orphans: ArrayList(HypergraphZId) = .empty;
            var it = self.vertices.iterator();
            while (it.next()) |*kv| {
                const hyperedges = kv.value_ptr.relations;
                if (hyperedges.items.len == 0) {
                    try orphans.append(self.allocator, kv.key_ptr.*);
                }
            }

            debugAt(@src(), "{} orphan vertices found", .{orphans.items.len});

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
            data: ?ArrayList(HypergraphZId),

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
                    const weight = @field(hyperedge.data.*, options.weight_field);
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
                debugAt(@src(), "no path found between {} and {}", .{ from, to });

                return .{ .data = null };
            }

            // Reconstruct path by walking came_from backward from `to`.
            var path: ArrayList(HypergraphZId) = .empty;
            try path.append(self.allocator, to);
            var cursor = to;
            while (came_from.get(cursor)) |entry| {
                if (entry) |e| {
                    try path.append(self.allocator, e.from);
                    cursor = e.from;
                } else break;
            }
            std.mem.reverse(HypergraphZId, path.items);

            debugAt(@src(), "path found between {} and {}", .{ from, to });

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
            var queue: ArrayList(HypergraphZId) = .empty;
            var result: ArrayList(HypergraphZId) = .empty;
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

            debugAt(@src(), "from {}: {} vertices visited", .{ start, result.items.len });

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
            var stack: ArrayList(HypergraphZId) = .empty;
            var neighbors: ArrayList(HypergraphZId) = .empty;
            var result: ArrayList(HypergraphZId) = .empty;

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

            debugAt(@src(), "from {}: {} vertices visited", .{ start, result.items.len });

            return result.toOwnedSlice(self.allocator);
        }

        /// Perform a random walk on the (undirected) hypergraph starting at `start`.
        /// At each step, pick an incident hyperedge `e` with probability proportional
        /// to its weight `w(e)`, then pick a vertex from `e` uniformly at random
        /// (matching the transition matrix `P = D_v⁻¹ H W D_e⁻¹ Hᵀ` underlying
        /// `computePageRank` and the spectral hypergraph Laplacian).
        ///
        /// Vertex multiplicity within a hyperedge is collapsed to a single occurrence
        /// before sampling, consistent with the convention used by `toIncidenceMatrix`
        /// and `toLaplacian`.
        ///
        /// Note: this walk is intentionally *not* the directed window-pair walk
        /// used by `breadthFirstSearch` / `depthFirstSearch`. See the wider
        /// undirected vs. directed discussion in `toLaplacian`'s docs.
        ///
        /// Returns a slice of length `steps + 1` containing the visited vertices,
        /// with `result[0] == start`. If a step lands on a vertex with no incident
        /// hyperedges (an isolated vertex; reachable mid-walk only if the start is
        /// itself isolated), the walk stays put for the remaining steps.
        ///
        /// The caller is responsible for freeing the result with
        /// `graph.allocator.free(result)`.
        pub fn randomWalk(
            self: *Self,
            start: HypergraphZId,
            steps: usize,
            random: std.Random,
        ) HypergraphZError![]const HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;
            try self.checkIfVertexExists(start);

            const path = try self.allocator.alloc(HypergraphZId, steps + 1);
            errdefer self.allocator.free(path);
            path[0] = start;

            // Scratch buffers reused across steps. `weights` and `cum_weights`
            // hold per-incident-hyperedge weights for proportional sampling;
            // `distinct` holds the deduplicated vertex list of a chosen hyperedge.
            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();
            var cum_weights: ArrayList(f64) = .empty;
            var distinct: ArrayList(HypergraphZId) = .empty;
            var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;

            var current = start;
            for (1..steps + 1) |i| {
                const vertex = self.vertices.get(current).?;
                const incident = vertex.relations.items;
                if (incident.len == 0) {
                    // Isolated vertex: stay put for the remainder of the walk.
                    path[i] = current;
                    continue;
                }

                // Weighted sampling among incident hyperedges by `w(e)`.
                cum_weights.clearRetainingCapacity();
                var total: f64 = 0;
                for (incident) |hid| {
                    const hyperedge = self.hyperedges.get(hid).?;
                    const w_int = @field(hyperedge.data.*, options.weight_field);
                    const w: f64 = @floatFromInt(w_int);
                    total += w;
                    try cum_weights.append(aa, total);
                }
                // `random.float(f64)` returns [0, 1); scale to [0, total).
                const r_h = random.float(f64) * total;
                var chosen_e_idx: usize = 0;
                for (cum_weights.items, 0..) |c, idx| {
                    if (r_h < c) {
                        chosen_e_idx = idx;
                        break;
                    }
                }
                const e = incident[chosen_e_idx];

                // Uniform sampling among the chosen hyperedge's distinct vertices.
                distinct.clearRetainingCapacity();
                seen.clearRetainingCapacity();
                const verts = self.hyperedges.get(e).?.relations.items;
                for (verts) |vid| {
                    const gop = try seen.getOrPut(aa, vid);
                    if (gop.found_existing) continue;
                    try distinct.append(aa, vid);
                }
                // `distinct.items.len > 0` is guaranteed: this hyperedge appears
                // in `current`'s incidence list, so it must contain at least
                // `current`.
                const v_idx = random.uintLessThan(usize, distinct.items.len);
                current = distinct.items[v_idx];
                path[i] = current;
            }

            debugAt(@src(), "from {}: {} steps", .{ start, steps });
            return path;
        }

        /// Struct containing all simple paths between two vertices.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const AllPathsResult = struct {
            data: ArrayList([]const HypergraphZId),

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
                path: ArrayList(HypergraphZId),
            };

            var stack: ArrayList(StackEntry) = .empty;
            var seen_neighbors: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;

            var initial_path: ArrayList(HypergraphZId) = .empty;
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

            debugAt(@src(), "from {} to {}: {} paths found", .{ from, to, result.data.items.len });

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
            var queue: ArrayList(HypergraphZId) = .empty;
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
                            debugAt(@src(), "{} -> {} true", .{ from, to });
                            return true;
                        }
                        if (visited.contains(next)) continue;
                        try visited.put(arena_allocator, next, {});
                        try queue.append(arena_allocator, next);
                    }
                }
            }

            debugAt(@src(), "{} -> {} false", .{ from, to });
            return false;
        }

        /// Return the strict transitive closure: a 2-uniform hypergraph where a
        /// hyperedge `[u, v]` exists for every pair where `v` is reachable from
        /// `u` via one or more directed hops. Self-loops `[u, u]` are included
        /// only when `u` lies on a cycle.
        /// `pairToHyperedge` produces the hyperedge data for each `(from, to)` pair.
        /// The result owns deep copies of all vertex and hyperedge data and may be
        /// safely mutated independently of the source.
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
                const new_data = try closure.vertices_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                try closure.vertices.put(self.allocator, kv.key_ptr.*, .{
                    .relations = .empty,
                    .data = new_data,
                });
                closure.id_counter = @max(closure.id_counter, kv.key_ptr.*);
            }

            var visited: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var queue: ArrayList(HypergraphZId) = .empty;

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

            debugAt(@src(), "{} vertices, {} hyperedges", .{
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

            data: AutoArrayHashMap(HypergraphZId, Scores),

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
            var pred: AutoHashMapUnmanaged(HypergraphZId, ArrayList(HypergraphZId)) = .empty;
            var bfs_stack: ArrayList(HypergraphZId) = .empty;
            var queue: ArrayList(HypergraphZId) = .empty;

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

            debugAt(@src(), "{} vertices processed", .{n});
            return result;
        }

        /// Options for `computePageRank`.
        ///
        /// Defaults match the original Brin–Page paper: damping `α = 0.85`,
        /// tolerance `1e-6` on the L1 distance between successive iterates,
        /// up to 100 iterations.
        pub const PageRankOptions = struct {
            /// Damping factor `α`. Probability that a walker follows the
            /// hypergraph at each step (vs. teleporting). Conventional range
            /// is `[0.7, 0.95]`.
            damping: f64 = 0.85,
            /// L1 convergence tolerance on `‖r_{k+1} − r_k‖₁`.
            tolerance: f64 = 1e-6,
            /// Hard cap on iterations. The result reports whether convergence
            /// was reached within this budget via `converged`.
            max_iterations: usize = 100,
        };

        /// Result of `computePageRank`. `data` maps each vertex id to its
        /// stationary probability under the lazy random walk; the scores sum
        /// to 1.0 (up to floating-point error). `iterations` is the number of
        /// power-iteration sweeps actually performed; `converged` indicates
        /// whether the L1 tolerance was met before the iteration cap.
        pub const PageRankResult = struct {
            data: AutoArrayHashMap(HypergraphZId, f64),
            iterations: usize,
            converged: bool,

            pub fn deinit(self: *PageRankResult, allocator: Allocator) void {
                self.data.deinit(allocator);
                self.* = undefined;
            }
        };

        /// Compute PageRank scores using power iteration on the hypergraph
        /// random-walk transition matrix
        ///
        ///   `P = D_v⁻¹ H W D_e⁻¹ Hᵀ`
        ///
        /// (the same walk as `randomWalk`), with damping factor `α` and a
        /// uniform teleport vector. The update rule is
        ///
        ///   `r_{k+1} = α · Pᵀ r_k + (1 − α) · 1/n  + α · dangling/n`
        ///
        /// where the last term redistributes mass from isolated vertices
        /// (`d(v) = 0`) uniformly — the standard sink-handling fix from
        /// Page–Brin.
        ///
        /// Implementation note: rather than form `Pᵀ r` directly (which is
        /// `O(n²)` per iteration), the inner loop uses a per-hyperedge
        /// reduction `S_e = Σ_{v ∈ e} r[v] / d(v)` and then distributes
        /// `α · w(e)/δ(e) · S_e` to each `u ∈ e`. Both passes run in
        /// `O(Σ |e|)`, i.e. proportional to the number of incidences.
        ///
        /// References:
        /// - Brin & Page, "The Anatomy of a Large-Scale Hypertextual Web
        ///   Search Engine", WWW7 1998:
        ///   http://infolab.stanford.edu/~backrub/google.html
        /// - Zhou, Huang & Schölkopf, "Learning with Hypergraphs", NeurIPS 2006.
        ///
        /// Hyperedges with `δ(e) = 0` (orphans) are skipped; vertex
        /// multiplicity within a hyperedge is collapsed to 0/1, matching the
        /// conventions of `toLaplacian` / `toIncidenceMatrix`.
        ///
        /// Complexity: `O(iterations · Σ |e|)`.
        /// The caller is responsible for freeing the result with `deinit`.
        pub fn computePageRank(
            self: *Self,
            opts: PageRankOptions,
        ) HypergraphZError!PageRankResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            const n = self.vertices.count();

            var result: PageRankResult = .{
                .data = .empty,
                .iterations = 0,
                .converged = true,
            };
            errdefer result.deinit(self.allocator);
            try result.data.ensureTotalCapacity(self.allocator, @intCast(n));

            if (n == 0) return result;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            const vertex_ids = self.vertices.keys();
            var vertex_index: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            try vertex_index.ensureTotalCapacity(aa, @intCast(n));
            for (vertex_ids, 0..) |vid, i| {
                vertex_index.putAssumeCapacity(vid, i);
            }

            // Per-hyperedge: weight + distinct vertex indices. Pre-compute once,
            // then walk each iteration. Skip orphan hyperedges (δ=0).
            const HData = struct {
                w: f64,
                verts: []usize,
            };
            var h_data: ArrayList(HData) = .empty;

            const degrees = try aa.alloc(f64, n);
            @memset(degrees, 0);

            var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                seen.clearRetainingCapacity();
                var distinct: ArrayList(usize) = .empty;
                for (kv.value_ptr.relations.items) |vid| {
                    const gop = try seen.getOrPut(aa, vid);
                    if (gop.found_existing) continue;
                    try distinct.append(aa, vertex_index.get(vid).?);
                }
                if (distinct.items.len == 0) continue;
                const w_int = @field(kv.value_ptr.data.*, options.weight_field);
                const w: f64 = @floatFromInt(w_int);
                for (distinct.items) |idx| degrees[idx] += w;
                try h_data.append(aa, .{
                    .w = w,
                    .verts = try distinct.toOwnedSlice(aa),
                });
            }

            // Power iteration buffers.
            const r = try aa.alloc(f64, n);
            const r_new = try aa.alloc(f64, n);
            const inv_n: f64 = 1.0 / @as(f64, @floatFromInt(n));
            @memset(r, inv_n);

            const teleport = (1.0 - opts.damping) * inv_n;

            var iter: usize = 0;
            var converged = false;
            while (iter < opts.max_iterations) : (iter += 1) {
                // Dangling mass: r[v] for vertices with no incident hyperedges
                // (degree 0). Redistributed uniformly across all vertices.
                var dangling: f64 = 0;
                for (0..n) |i| {
                    if (degrees[i] == 0) dangling += r[i];
                }
                const dangling_share = opts.damping * dangling * inv_n;
                @memset(r_new, teleport + dangling_share);

                // Per-hyperedge contribution: each `u ∈ e` receives
                // `α · w(e) / δ(e) · S_e` where `S_e = Σ_{v ∈ e} r[v] / d(v)`.
                for (h_data.items) |he| {
                    var S: f64 = 0;
                    for (he.verts) |v_idx| {
                        if (degrees[v_idx] > 0) S += r[v_idx] / degrees[v_idx];
                    }
                    const delta_f: f64 = @floatFromInt(he.verts.len);
                    const factor = opts.damping * he.w / delta_f * S;
                    for (he.verts) |u_idx| {
                        r_new[u_idx] += factor;
                    }
                }

                var diff: f64 = 0;
                for (r, r_new) |a, b| diff += @abs(a - b);
                @memcpy(r, r_new);
                if (diff < opts.tolerance) {
                    iter += 1;
                    converged = true;
                    break;
                }
            }

            for (vertex_ids, 0..) |vid, i| {
                result.data.putAssumeCapacity(vid, r[i]);
            }
            result.iterations = iter;
            result.converged = converged;

            debugAt(@src(), "{} iterations, converged={}", .{ iter, converged });
            return result;
        }

        /// One strict-subset relation between two hyperedges.
        ///
        /// `subset` is a hyperedge whose distinct vertex set is a strict
        /// subset of `superset`'s. "Strict" means `|distinct(subset)| <
        /// |distinct(superset)|`; identical sets are not reported.
        pub const InclusionRelation = struct {
            subset: HypergraphZId,
            superset: HypergraphZId,
        };

        /// Result of `getInclusions`. The caller is responsible for freeing
        /// the memory with `deinit`.
        pub const InclusionResult = struct {
            data: []InclusionRelation,

            pub fn deinit(self: *InclusionResult, allocator: Allocator) void {
                allocator.free(self.data);
                self.* = undefined;
            }
        };

        /// Find every pair of hyperedges `(small, large)` whose distinct vertex
        /// sets satisfy `distinct(small) ⊊ distinct(large)`.
        ///
        /// "Nestedness" — the prevalence of subset relations among hyperedges
        /// — is a recognized structural property of higher-order networks (see
        /// e.g. Mariani et al., "Nestedness in complex networks", Phys. Rep.
        /// 813, 2019; LaRock & Lambiotte, "Encapsulation structure and
        /// dynamics in hypergraphs", J. Phys. Complex. 4, 2023). It surfaces
        /// in ecological niches, legislative co-sponsorship, and ER drug
        /// combinations among other settings.
        ///
        /// Vertex multiplicity is collapsed to 0/1 before comparison, matching
        /// the convention used by `toIncidenceMatrix` and friends. Hyperedges
        /// with empty distinct sets are not considered (`∅ ⊆ X` is true for
        /// every `X` but is degenerate; including it would explode the output
        /// for orphan hyperedges).
        ///
        /// Algorithm: walk every vertex's incidence list and accumulate the
        /// pairwise intersection size `|distinct(a) ∩ distinct(b)|` into a
        /// hashmap keyed by the unordered pair (packed as a `u64`). For each
        /// recorded pair, `a ⊊ b` iff `|a ∩ b| = |a|` and `|a| < |b|`.
        ///
        /// Complexity: `O(Σ_v deg(v)²)` for the intersection accumulation,
        /// plus `O(P)` for the emit pass where `P` is the number of pairs of
        /// hyperedges sharing at least one vertex.
        ///
        /// The caller is responsible for freeing the result with `deinit`.
        pub fn getInclusions(self: *Self) HypergraphZError!InclusionResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            // Distinct-vertex count per hyperedge.
            var sizes: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            try sizes.ensureTotalCapacity(aa, @intCast(self.hyperedges.count()));
            var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                seen.clearRetainingCapacity();
                var count: usize = 0;
                for (kv.value_ptr.relations.items) |vid| {
                    const gop = try seen.getOrPut(aa, vid);
                    if (!gop.found_existing) count += 1;
                }
                sizes.putAssumeCapacity(kv.key_ptr.*, count);
            }

            // Pairwise intersection sizes via shared vertices. Each vertex's
            // incidence list is dedup'd by build(), so it lists each
            // containing hyperedge exactly once.
            var shared: AutoHashMapUnmanaged(u64, usize) = .empty;
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                const incident = kv.value_ptr.relations.items;
                for (incident, 0..) |a, i| {
                    for (incident[i + 1 ..]) |b| {
                        if (a == b) continue;
                        const lo: u64 = @min(a, b);
                        const hi: u64 = @max(a, b);
                        const key = (lo << 32) | hi;
                        const gop = try shared.getOrPut(aa, key);
                        if (gop.found_existing) {
                            gop.value_ptr.* += 1;
                        } else {
                            gop.value_ptr.* = 1;
                        }
                    }
                }
            }

            // Emit strict-subset pairs.
            var out: ArrayList(InclusionRelation) = .empty;
            var s_it = shared.iterator();
            while (s_it.next()) |kv| {
                const key = kv.key_ptr.*;
                const a: HypergraphZId = @intCast(key >> 32);
                const b: HypergraphZId = @intCast(key & 0xFFFFFFFF);
                const inter = kv.value_ptr.*;
                const size_a = sizes.get(a).?;
                const size_b = sizes.get(b).?;
                if (inter == size_a and size_a < size_b) {
                    try out.append(self.allocator, .{ .subset = a, .superset = b });
                } else if (inter == size_b and size_b < size_a) {
                    try out.append(self.allocator, .{ .subset = b, .superset = a });
                }
            }

            const owned = try out.toOwnedSlice(self.allocator);
            debugAt(@src(), "{} inclusion pairs", .{owned.len});
            return .{ .data = owned };
        }

        /// Per-order nestedness profile, sorted ascending by `size`.
        ///
        /// Each `Entry` reports, for hyperedges of one distinct size `d`:
        ///   - `total`: how many hyperedges have exactly `d` distinct vertices,
        ///   - `included`: how many of those are a strict subset of at least
        ///                 one larger hyperedge.
        ///
        /// Hyperedges with `size = 0` are skipped (see `getInclusions` for the
        /// rationale). Hyperedge sizes with no hyperedges are simply absent
        /// from the slice — there is no zero-padding.
        pub const NestednessProfile = struct {
            pub const Entry = struct {
                size: usize,
                included: usize,
                total: usize,
            };
            data: []Entry,

            pub fn deinit(self: *NestednessProfile, allocator: Allocator) void {
                allocator.free(self.data);
                self.* = undefined;
            }
        };

        /// Aggregate nestedness counts per distinct hyperedge size — the
        /// hypergraph analogue of the inclusion histogram in Hood, De Bacco
        /// & Schein, "Broad spectrum structure discovery in large-scale
        /// higher-order networks", Nat. Commun. 2026 (Fig. 5b). Use this to
        /// see at which orders subset structure concentrates.
        ///
        /// Internally calls `getInclusions`. The caller is responsible for
        /// freeing the result with `deinit`.
        pub fn getNestednessProfile(self: *Self) HypergraphZError!NestednessProfile {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            // Distinct-size of each hyperedge (recomputed locally — small,
            // and avoids leaking it from `getInclusions`).
            var sizes: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            try sizes.ensureTotalCapacity(aa, @intCast(self.hyperedges.count()));
            var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                seen.clearRetainingCapacity();
                var count: usize = 0;
                for (kv.value_ptr.relations.items) |vid| {
                    const gop = try seen.getOrPut(aa, vid);
                    if (!gop.found_existing) count += 1;
                }
                sizes.putAssumeCapacity(kv.key_ptr.*, count);
            }

            // Total hyperedge count per (non-zero) size.
            var total_by_size: AutoHashMapUnmanaged(usize, usize) = .empty;
            var sz_it = sizes.iterator();
            while (sz_it.next()) |kv| {
                if (kv.value_ptr.* == 0) continue;
                const gop = try total_by_size.getOrPut(aa, kv.value_ptr.*);
                if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
            }

            // Distinct-by-id "is subset of something" set.
            var inclusions = try self.getInclusions();
            defer inclusions.deinit(self.allocator);

            var subset_set: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            for (inclusions.data) |rel| try subset_set.put(aa, rel.subset, {});

            var included_by_size: AutoHashMapUnmanaged(usize, usize) = .empty;
            var sub_it = subset_set.keyIterator();
            while (sub_it.next()) |kp| {
                const sz = sizes.get(kp.*).?;
                const gop = try included_by_size.getOrPut(aa, sz);
                if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
            }

            var entries: ArrayList(NestednessProfile.Entry) = .empty;
            var t_it = total_by_size.iterator();
            while (t_it.next()) |kv| {
                const size = kv.key_ptr.*;
                try entries.append(self.allocator, .{
                    .size = size,
                    .included = included_by_size.get(size) orelse 0,
                    .total = kv.value_ptr.*,
                });
            }

            const owned = try entries.toOwnedSlice(self.allocator);
            std.mem.sort(NestednessProfile.Entry, owned, {}, struct {
                fn lt(_: void, x: NestednessProfile.Entry, y: NestednessProfile.Entry) bool {
                    return x.size < y.size;
                }
            }.lt);

            debugAt(@src(), "{} distinct sizes", .{owned.len});
            return .{ .data = owned };
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
            var stack: ArrayList(StackEntry) = .empty;

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
                            debugAt(@src(), "cycle detected at vertex {}", .{entry.vertex});
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

            debugAt(@src(), "no cycle found", .{});
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
            var queue: ArrayList(HypergraphZId) = .empty;
            var id_it = self.vertices.iterator();
            while (id_it.next()) |kv| {
                if (in_degree.get(kv.key_ptr.*).? == 0) {
                    try queue.append(aa, kv.key_ptr.*);
                }
            }

            var result: ArrayList(HypergraphZId) = .empty;
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

            debugAt(@src(), "ordered {} vertices", .{result.items.len});
            return try result.toOwnedSlice(self.allocator);
        }

        /// Return true if the hypergraph is weakly connected: every vertex is
        /// reachable from every other vertex when hyperedge direction is ignored.
        /// An empty graph (no vertices) is considered connected.
        pub fn isConnected(self: *Self) HypergraphZError!bool {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            const count = self.vertices.count();
            if (count == 0) return true;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var visited: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var queue: ArrayList(HypergraphZId) = .empty;
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
            debugAt(@src(), "{}", .{connected});
            return connected;
        }

        /// Struct containing all weakly-connected components as slices of vertex IDs.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const ConnectedComponentsResult = struct {
            data: ArrayList([]const HypergraphZId),

            pub fn deinit(self: *ConnectedComponentsResult, allocator: Allocator) void {
                for (self.data.items) |component| allocator.free(component);
                self.data.deinit(allocator);
                self.* = undefined;
            }
        };

        /// Partition all vertices into weakly-connected components.
        /// Each component is a slice of vertex IDs reachable from each other
        /// when hyperedge direction is ignored.
        /// The caller is responsible for freeing the result memory with `deinit`.
        pub fn getConnectedComponents(self: *Self) HypergraphZError!ConnectedComponentsResult {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var result: ConnectedComponentsResult = .{ .data = .empty };
            var visited: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var queue: ArrayList(HypergraphZId) = .empty;

            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                const seed = kv.key_ptr.*;
                if (visited.contains(seed)) continue;

                // BFS from seed (undirected) to collect one component.
                queue.clearRetainingCapacity();
                var head: usize = 0;
                var component: ArrayList(HypergraphZId) = .empty;

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

            debugAt(@src(), "{} components found", .{result.data.items.len});
            return result;
        }

        /// Return the set of cut vertices (articulation points): vertices whose
        /// removal would increase the number of (undirected) connected
        /// components. Equivalently, the `k = 1` case of the vertex separator
        /// concept formalized for hypergraphs in Hood, "Hypergraphs without
        /// Subgraphs of Given Connectivity", arXiv 2604.17038.
        ///
        /// Hyperedges are treated as undirected vertex sets — each hyperedge
        /// contributes a clique among its distinct vertices. This matches the
        /// standard hypergraph-connectivity definition (any two vertices in
        /// the same hyperedge are adjacent) used by `toLaplacian`,
        /// `computePageRank`, `getInclusions`, and `getVertexNeighborhood`.
        /// Note this differs from the directed window-pair semantics used by
        /// `breadthFirstSearch` / `depthFirstSearch` / `isConnected`, so a
        /// vertex listed in the middle of a long hyperedge is *not*
        /// automatically a cut vertex.
        ///
        /// Algorithm: classical Hopcroft–Tarjan DFS lowlink, run iteratively
        /// (the recursion depth on hypergraphs can exceed thread-stack
        /// limits on dense data). For a vertex `u`:
        ///   - if `u` is a DFS-tree root, it is a cut vertex iff it has ≥ 2
        ///     tree children;
        ///   - otherwise, it is a cut vertex iff some tree child `c`
        ///     satisfies `low(c) ≥ disc(u)`.
        /// The DFS is restarted on each unvisited vertex to handle multiple
        /// connected components.
        ///
        /// Reference: Hopcroft & Tarjan, "Efficient algorithms for graph
        /// manipulation", CACM 16(6), 1973. The hypergraph extension is
        /// straightforward via the clique-expansion adjacency.
        ///
        /// Complexity: `O(V + Σ_v deg(v)·max_e_size)` for neighborhood
        /// materialization, plus `O(V + neighborhood_total)` for the DFS.
        ///
        /// The caller is responsible for freeing the result with
        /// `graph.allocator.free(result)`.
        pub fn findCutVertices(self: *Self) HypergraphZError![]const HypergraphZId {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            const n = self.vertices.count();
            if (n == 0) return try self.allocator.alloc(HypergraphZId, 0);

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            // Pre-materialize each vertex's clique-expansion neighbor set
            // (deduplicated, excluding self). Done once so the iterative DFS
            // can index by frame.
            var nbrs: AutoHashMapUnmanaged(HypergraphZId, []HypergraphZId) = .empty;
            try nbrs.ensureTotalCapacity(aa, @intCast(n));
            {
                var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
                var v_it = self.vertices.iterator();
                while (v_it.next()) |kv| {
                    const vid = kv.key_ptr.*;
                    seen.clearRetainingCapacity();
                    try seen.put(aa, vid, {});
                    var list: ArrayList(HypergraphZId) = .empty;
                    for (kv.value_ptr.relations.items) |hid| {
                        const hyperedge = self.hyperedges.get(hid).?;
                        for (hyperedge.relations.items) |other| {
                            const gop = try seen.getOrPut(aa, other);
                            if (!gop.found_existing) try list.append(aa, other);
                        }
                    }
                    nbrs.putAssumeCapacity(vid, try list.toOwnedSlice(aa));
                }
            }

            var disc: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            var low: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            var parent: AutoHashMapUnmanaged(HypergraphZId, ?HypergraphZId) = .empty;
            var is_ap: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;

            const Frame = struct {
                v: HypergraphZId,
                neighbors: []const HypergraphZId,
                idx: usize,
                children: usize,
            };
            var stack: ArrayList(Frame) = .empty;

            var time: usize = 0;
            var roots = self.vertices.iterator();
            while (roots.next()) |kv| {
                const root = kv.key_ptr.*;
                if (disc.contains(root)) continue;

                try disc.put(aa, root, time);
                try low.put(aa, root, time);
                try parent.put(aa, root, null);
                time += 1;
                try stack.append(aa, .{
                    .v = root,
                    .neighbors = nbrs.get(root).?,
                    .idx = 0,
                    .children = 0,
                });

                while (stack.items.len > 0) {
                    const top = &stack.items[stack.items.len - 1];
                    if (top.idx >= top.neighbors.len) {
                        // Finalize this frame.
                        const v = top.v;
                        const v_parent_opt = parent.get(v).?;
                        const children = top.children;
                        _ = stack.pop();

                        if (v_parent_opt) |p| {
                            // Propagate low to parent and apply the non-root AP rule.
                            const v_low = low.get(v).?;
                            const p_low = low.get(p).?;
                            if (v_low < p_low) try low.put(aa, p, v_low);
                            const p_disc = disc.get(p).?;
                            // The rule fires only when `p` itself has a parent
                            // (root case is handled by the children-count test).
                            if (parent.get(p).? != null and v_low >= p_disc) {
                                try is_ap.put(aa, p, {});
                            }
                        } else if (children >= 2) {
                            // Root with ≥ 2 tree children is an articulation point.
                            try is_ap.put(aa, v, {});
                        }
                        continue;
                    }

                    const v = top.v;
                    const u = top.neighbors[top.idx];
                    top.idx += 1;

                    if (!disc.contains(u)) {
                        // Tree edge: descend.
                        try disc.put(aa, u, time);
                        try low.put(aa, u, time);
                        try parent.put(aa, u, v);
                        time += 1;
                        top.children += 1;
                        try stack.append(aa, .{
                            .v = u,
                            .neighbors = nbrs.get(u).?,
                            .idx = 0,
                            .children = 0,
                        });
                        continue;
                    }

                    // Already-discovered neighbor. Skip the tree edge back to
                    // our parent (in our deduplicated view there is at most
                    // one `v ↔ parent` adjacency); otherwise it's a back edge
                    // updating low.
                    if (parent.get(v).?) |p| {
                        if (u == p) continue;
                    }
                    const u_disc = disc.get(u).?;
                    const v_low = low.get(v).?;
                    if (u_disc < v_low) try low.put(aa, v, u_disc);
                }
            }

            // Emit articulation points in the canonical vertex iteration order
            // so callers get a deterministic result.
            var out: ArrayList(HypergraphZId) = .empty;
            errdefer out.deinit(self.allocator);
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                if (is_ap.contains(kv.key_ptr.*)) try out.append(self.allocator, kv.key_ptr.*);
            }
            const owned = try out.toOwnedSlice(self.allocator);
            debugAt(@src(), "{} cut vertices", .{owned.len});
            return owned;
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

            debugAt(@src(), "{} vertices, {} hyperedges", .{
                dual.vertices.count(),
                dual.hyperedges.count(),
            });

            return dual;
        }

        /// Return the k-skeleton of the hypergraph: a new hypergraph containing
        /// all vertices and only the hyperedges whose raw vertex count is at
        /// most `k` (i.e. `hyperedge.relations.len <= k`).
        /// The result owns deep copies of all vertex and hyperedge data and may be
        /// safely mutated independently of the source.
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
                const new_data = try skeleton.vertices_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                try skeleton.vertices.put(self.allocator, kv.key_ptr.*, .{
                    .relations = .empty,
                    .data = new_data,
                });
                skeleton.id_counter = @max(skeleton.id_counter, kv.key_ptr.*);
            }

            // Copy only hyperedges with raw vertex count <= k.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                if (kv.value_ptr.relations.items.len > k) continue;
                const new_data = try skeleton.hyperedges_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                const owned = try self.allocator.dupe(
                    HypergraphZId,
                    kv.value_ptr.relations.items,
                );
                try skeleton.hyperedges.put(self.allocator, kv.key_ptr.*, .{
                    .relations = ArrayList(HypergraphZId).fromOwnedSlice(owned),
                    .data = new_data,
                });
                skeleton.id_counter = @max(skeleton.id_counter, kv.key_ptr.*);
            }

            debugAt(@src(), "k={}: {} vertices, {} hyperedges", .{
                k,
                skeleton.vertices.count(),
                skeleton.hyperedges.count(),
            });

            return skeleton;
        }

        /// Return the `(s, t)`-core: the unique largest sub-hypergraph in which
        /// every vertex is incident to at least `s` (surviving) hyperedges and
        /// every hyperedge contains at least `t` distinct (surviving) vertices.
        ///
        /// This is the standard hypergraph generalization of the graph k-core
        /// (which is recovered by `getCore(k, 2)`). The result is well-defined:
        /// the peeling procedure converges to the same fixed point regardless
        /// of the order vertices and hyperedges are removed.
        ///
        /// Algorithm: iterative peeling. Initialize each vertex's degree as the
        /// number of distinct incident hyperedges and each hyperedge's size as
        /// its distinct vertex count. Repeatedly remove any vertex with degree
        /// `< s` (decrementing the size of every still-alive hyperedge that
        /// contained it) and any hyperedge with size `< t` (decrementing the
        /// degree of every still-alive distinct vertex it contained). Stop when
        /// neither queue can fire.
        ///
        /// Edge cases:
        /// - `s = 0` and `t = 0`: returns a deep copy of the full hypergraph.
        /// - `t = 1`: singleton hyperedges are kept (they otherwise vanish).
        /// - The result may be empty if no `(s, t)`-core exists.
        ///
        /// Reference: standard hypergraph core decomposition; see e.g. Sun, Liu,
        /// Wu, Du, "Fully Dynamic Approximation Algorithms for Distance-Based
        /// Hypergraph Core Decomposition" / classical formulations starting
        /// from Seidman 1983 in the graph case.
        ///
        /// IDs of surviving vertices and hyperedges are preserved. The result
        /// owns deep copies of all data; the caller must call `build()` on it
        /// and is responsible for calling `deinit()`.
        ///
        /// Complexity: `O(n + m + Σ |e|)` — each vertex–hyperedge incidence is
        /// visited a constant number of times across the whole peeling.
        pub fn getCore(self: *Self, s: usize, t: usize) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            // alive sets and live counts. Counts always reflect *surviving*
            // neighbors, never the original totals.
            var v_alive: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var v_deg: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            var h_alive: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var h_size: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            // Cache the distinct vertex set of each hyperedge so the peel loop
            // doesn't have to rebuild it when the hyperedge dies.
            var h_distinct: AutoHashMapUnmanaged(HypergraphZId, []HypergraphZId) = .empty;

            var v_init = self.vertices.iterator();
            while (v_init.next()) |kv| {
                try v_alive.put(aa, kv.key_ptr.*, {});
                // Reverse index is dedup'd by build(), so .relations.items.len
                // is already the count of distinct incident hyperedges.
                try v_deg.put(aa, kv.key_ptr.*, kv.value_ptr.relations.items.len);
            }

            var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            var h_init = self.hyperedges.iterator();
            while (h_init.next()) |kv| {
                seen.clearRetainingCapacity();
                var distinct: ArrayList(HypergraphZId) = .empty;
                for (kv.value_ptr.relations.items) |vid| {
                    const gop = try seen.getOrPut(aa, vid);
                    if (!gop.found_existing) try distinct.append(aa, vid);
                }
                const owned = try distinct.toOwnedSlice(aa);
                try h_distinct.put(aa, kv.key_ptr.*, owned);
                try h_alive.put(aa, kv.key_ptr.*, {});
                try h_size.put(aa, kv.key_ptr.*, owned.len);
            }

            // Worklists. `to_remove_*` may contain duplicate IDs; the alive
            // check at pop time deduplicates without an extra set.
            var to_remove_v: ArrayList(HypergraphZId) = .empty;
            var to_remove_h: ArrayList(HypergraphZId) = .empty;

            var v_seed = v_deg.iterator();
            while (v_seed.next()) |kv| {
                if (kv.value_ptr.* < s) try to_remove_v.append(aa, kv.key_ptr.*);
            }
            var h_seed = h_size.iterator();
            while (h_seed.next()) |kv| {
                if (kv.value_ptr.* < t) try to_remove_h.append(aa, kv.key_ptr.*);
            }

            while (to_remove_v.items.len > 0 or to_remove_h.items.len > 0) {
                if (to_remove_v.pop()) |vid| {
                    if (v_alive.contains(vid)) {
                        _ = v_alive.remove(vid);
                        const vertex = self.vertices.get(vid).?;
                        for (vertex.relations.items) |hid| {
                            if (!h_alive.contains(hid)) continue;
                            const sz = h_size.getPtr(hid).?;
                            sz.* -= 1;
                            if (sz.* < t) try to_remove_h.append(aa, hid);
                        }
                    }
                }
                if (to_remove_h.pop()) |hid| {
                    if (h_alive.contains(hid)) {
                        _ = h_alive.remove(hid);
                        const distinct = h_distinct.get(hid).?;
                        for (distinct) |vid| {
                            if (!v_alive.contains(vid)) continue;
                            const dg = v_deg.getPtr(vid).?;
                            dg.* -= 1;
                            if (dg.* < s) try to_remove_v.append(aa, vid);
                        }
                    }
                }
            }

            // Materialize the surviving sub-hypergraph, preserving IDs.
            var core = try Self.init(self.allocator, .{
                .vertices_capacity = v_alive.count(),
                .hyperedges_capacity = h_alive.count(),
            });
            errdefer core.deinit();

            var v_copy = self.vertices.iterator();
            while (v_copy.next()) |kv| {
                if (!v_alive.contains(kv.key_ptr.*)) continue;
                const new_data = try core.vertices_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                try core.vertices.put(self.allocator, kv.key_ptr.*, .{
                    .relations = .empty,
                    .data = new_data,
                });
                core.id_counter = @max(core.id_counter, kv.key_ptr.*);
            }

            var h_copy = self.hyperedges.iterator();
            while (h_copy.next()) |kv| {
                if (!h_alive.contains(kv.key_ptr.*)) continue;
                const new_data = try core.hyperedges_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                // Filter the original (multiplicity-preserving) vertex list
                // down to surviving vertices, keeping order.
                var relations: ArrayList(HypergraphZId) = .empty;
                for (kv.value_ptr.relations.items) |vid| {
                    if (v_alive.contains(vid)) try relations.append(self.allocator, vid);
                }
                try core.hyperedges.put(self.allocator, kv.key_ptr.*, .{
                    .relations = relations,
                    .data = new_data,
                });
                core.id_counter = @max(core.id_counter, kv.key_ptr.*);
            }

            debugAt(@src(), "core(s={}, t={}): {} vertices, {} hyperedges", .{
                s,
                t,
                core.vertices.count(),
                core.hyperedges.count(),
            });

            return core;
        }

        /// Return the vertex-induced subhypergraph: a new hypergraph containing
        /// exactly the specified vertices and only the hyperedges whose entire
        /// vertex list is a subset of those vertices (strict).
        /// The result owns deep copies of all vertex and hyperedge data and may be
        /// safely mutated independently of the source.
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
                const new_data = try sub.vertices_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                try sub.vertices.put(self.allocator, id, .{
                    .relations = .empty,
                    .data = new_data,
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
                const new_data = try sub.hyperedges_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                const owned = try self.allocator.dupe(HypergraphZId, relations);
                try sub.hyperedges.put(self.allocator, kv.key_ptr.*, .{
                    .relations = ArrayList(HypergraphZId).fromOwnedSlice(owned),
                    .data = new_data,
                });
                sub.id_counter = @max(sub.id_counter, kv.key_ptr.*);
            }

            debugAt(@src(), "{} vertices, {} hyperedges", .{
                sub.vertices.count(),
                sub.hyperedges.count(),
            });

            return sub;
        }

        /// Return the hyperedge-induced subhypergraph: a new hypergraph containing
        /// exactly the specified hyperedges and only the vertices that appear
        /// in at least one of them.
        /// The result owns deep copies of all vertex and hyperedge data and may be
        /// safely mutated independently of the source.
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
                const new_data = try sub.vertices_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                try sub.vertices.put(self.allocator, id, .{
                    .relations = .empty,
                    .data = new_data,
                });
                sub.id_counter = @max(sub.id_counter, id);
            }

            // Copy the requested hyperedges preserving their IDs.
            for (hyperedge_ids) |hid| {
                const kv = self.hyperedges.getEntry(hid).?;
                const new_data = try sub.hyperedges_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                const owned = try self.allocator.dupe(HypergraphZId, kv.value_ptr.relations.items);
                try sub.hyperedges.put(self.allocator, hid, .{
                    .relations = ArrayList(HypergraphZId).fromOwnedSlice(owned),
                    .data = new_data,
                });
                sub.id_counter = @max(sub.id_counter, hid);
            }

            debugAt(@src(), "{} vertices, {} hyperedges", .{
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
        /// The result owns deep copies of all vertex and hyperedge data and may be
        /// safely mutated independently of the source.
        /// The caller must call `build()` on the result and is responsible for
        /// calling `deinit()` on it.
        pub fn expandToGraph(self: *Self) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            // Each n-vertex hyperedge expands into (n - 1) pair-hyperedges.
            var hyperedge_count: usize = 0;
            var c_it = self.hyperedges.iterator();
            while (c_it.next()) |kv| {
                const n = kv.value_ptr.relations.items.len;
                if (n >= 2) hyperedge_count += n - 1;
            }

            var graph = try Self.init(self.allocator, .{
                .vertices_capacity = self.vertices.count(),
                .hyperedges_capacity = hyperedge_count,
            });
            errdefer graph.deinit();

            // Copy all vertices preserving their IDs.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                const new_data = try graph.vertices_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                try graph.vertices.put(self.allocator, kv.key_ptr.*, .{
                    .relations = .empty,
                    .data = new_data,
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

            debugAt(@src(), "{} vertices, {} hyperedges", .{
                graph.vertices.count(),
                graph.hyperedges.count(),
            });

            return graph;
        }

        /// Star (bipartite) expansion of the hypergraph.
        ///
        /// For each original hyperedge `e` a new "hub" vertex is created with
        /// data computed by `hyperedgeToVertex(e_data)`. Each original vertex
        /// `v ∈ e` is then connected to that hub via a 2-vertex hyperedge that
        /// inherits the original hyperedge's data. The result is bipartite
        /// between original vertices and hub vertices, and 2-uniform.
        ///
        /// Original vertex IDs are preserved; hub vertices and pair-hyperedges
        /// receive fresh IDs from a counter seeded above the maximum original
        /// id, so no collisions occur. Multiplicity within a hyperedge is
        /// collapsed: a vertex listed twice in the same hyperedge produces one
        /// pair-hyperedge to that hub, not two.
        ///
        /// This is the standard counterpart to `expandToGraph` (clique
        /// expansion). Star expansion preserves hyperedge identity (each
        /// hyperedge survives as a hub), at the cost of `O(Σ |e|)` new
        /// hyperedges and `m` new vertices. Clique expansion does the opposite.
        ///
        /// The result owns deep copies of all data and may be safely mutated
        /// independently of the source. The caller must call `build()` on the
        /// result and is responsible for calling `deinit()` on it.
        pub fn expandToStar(
            self: *Self,
            hyperedgeToVertex: fn (H) V,
        ) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            // Pre-count distinct (vertex, hyperedge) incidences for capacity sizing.
            var pair_count: usize = 0;
            {
                var arena: ArenaAllocator = .init(self.allocator);
                defer arena.deinit();
                const aa = arena.allocator();
                var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
                var h_it = self.hyperedges.iterator();
                while (h_it.next()) |kv| {
                    seen.clearRetainingCapacity();
                    for (kv.value_ptr.relations.items) |vid| {
                        const gop = try seen.getOrPut(aa, vid);
                        if (!gop.found_existing) pair_count += 1;
                    }
                }
            }

            var star = try Self.init(self.allocator, .{
                .vertices_capacity = self.vertices.count() + self.hyperedges.count(),
                .hyperedges_capacity = pair_count,
            });
            errdefer star.deinit();

            // Copy original vertices preserving their IDs. Also seed id_counter
            // above any original id (vertex *or* hyperedge) so newly minted hub
            // and pair-hyperedge IDs don't collide with retained vertex IDs.
            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                const new_data = try star.vertices_pool.create(self.allocator);
                new_data.* = kv.value_ptr.data.*;
                try star.vertices.put(self.allocator, kv.key_ptr.*, .{
                    .relations = .empty,
                    .data = new_data,
                });
                star.id_counter = @max(star.id_counter, kv.key_ptr.*);
            }
            var h_seed_it = self.hyperedges.iterator();
            while (h_seed_it.next()) |kv| {
                star.id_counter = @max(star.id_counter, kv.key_ptr.*);
            }

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();
            var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;

            // For each original hyperedge: create a hub vertex, then a 2-vertex
            // pair-hyperedge (member, hub) for every distinct member.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                const hub_id = try star.createVertex(hyperedgeToVertex(kv.value_ptr.data.*));
                seen.clearRetainingCapacity();
                for (kv.value_ptr.relations.items) |vid| {
                    const gop = try seen.getOrPut(aa, vid);
                    if (gop.found_existing) continue;
                    const new_eid = try star.createHyperedge(kv.value_ptr.data.*);
                    try star.appendVertexToHyperedge(new_eid, vid);
                    try star.appendVertexToHyperedge(new_eid, hub_id);
                }
            }

            debugAt(@src(), "{} vertices, {} hyperedges", .{
                star.vertices.count(),
                star.hyperedges.count(),
            });

            return star;
        }

        /// Line graph of the hypergraph.
        ///
        /// Each original hyperedge becomes a vertex of the line graph (with data
        /// produced by `hyperedgeToVertex`), and two such vertices are connected
        /// iff the corresponding original hyperedges share at least one
        /// (distinct) vertex. The connection is encoded as a 2-vertex hyperedge
        /// with data `default_hyperedge`, making the result 2-uniform.
        ///
        /// Self-loops (a hyperedge with itself) are not produced. Each
        /// unordered pair of intersecting hyperedges appears at most once,
        /// regardless of how many vertices they share.
        ///
        /// The line graph is the natural counterpart to `getDual`: the dual
        /// preserves the bipartite incidence structure (edges become vertices
        /// *and* vertices become edges, swapping roles), while the line graph
        /// projects onto hyperedge intersections only. Together they cover the
        /// two standard one-sided projections of a hypergraph.
        ///
        /// Reference: standard hypergraph line graph; see e.g. Bermond et al.,
        /// "Line graphs of hypergraphs I", Discrete Math. 18 (1977):
        /// https://doi.org/10.1016/0012-365X(77)90075-6
        ///
        /// Complexity: `O(Σ_v deg(v)²)` — each original vertex contributes
        /// pairs over its incident hyperedges.
        ///
        /// The caller must call `build()` on the result and is responsible for
        /// calling `deinit()` on it.
        pub fn getLineGraph(
            self: *Self,
            hyperedgeToVertex: fn (H) V,
            default_hyperedge: H,
        ) HypergraphZError!Self {
            if (!self.is_built) return HypergraphZError.NotBuilt;

            var line = try Self.init(self.allocator, .{
                .vertices_capacity = self.hyperedges.count(),
                .hyperedges_capacity = null,
            });
            errdefer line.deinit();

            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            // Old hyperedge id → new vertex id in the line graph.
            var hid_to_vid: AutoHashMapUnmanaged(HypergraphZId, HypergraphZId) = .empty;
            try hid_to_vid.ensureTotalCapacity(aa, @intCast(self.hyperedges.count()));

            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                const new_vid = try line.createVertex(hyperedgeToVertex(kv.value_ptr.data.*));
                hid_to_vid.putAssumeCapacity(kv.key_ptr.*, new_vid);
            }

            // Walk each original vertex's incident hyperedges; every pair of
            // distinct hyperedges in that list shares this vertex, so they
            // form a line-graph edge. Use an unordered-pair set keyed by
            // `(min<<32 | max)` to dedup pairs that share multiple vertices.
            var pair_seen: AutoHashMapUnmanaged(u64, void) = .empty;

            var v_it = self.vertices.iterator();
            while (v_it.next()) |kv| {
                const incident = kv.value_ptr.relations.items;
                for (incident, 0..) |a, i| {
                    for (incident[i + 1 ..]) |b| {
                        if (a == b) continue;
                        const lo: u64 = @min(a, b);
                        const hi: u64 = @max(a, b);
                        const key = (lo << 32) | hi;
                        const gop = try pair_seen.getOrPut(aa, key);
                        if (gop.found_existing) continue;

                        const new_eid = try line.createHyperedge(default_hyperedge);
                        try line.appendVertexToHyperedge(new_eid, hid_to_vid.get(a).?);
                        try line.appendVertexToHyperedge(new_eid, hid_to_vid.get(b).?);
                    }
                }
            }

            debugAt(@src(), "{} vertices, {} hyperedges", .{
                line.vertices.count(),
                line.hyperedges.count(),
            });

            return line;
        }

        /// Dense `n × m` incidence matrix where `n = countVertices()` and
        /// `m = countHyperedges()`. `at(row, col) == 1` iff that vertex appears
        /// in that hyperedge (multiplicity is collapsed to 0/1, matching the
        /// standard textbook formulation `H ∈ {0,1}^{n×m}`).
        /// Rows and columns are ordered by `getAllVertices()` and
        /// `getAllHyperedges()` respectively; the corresponding ID arrays
        /// are returned alongside so callers can map between row/column
        /// indices and graph IDs.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const IncidenceMatrix = struct {
            rows: usize,
            cols: usize,
            data: []u8,
            vertex_ids: []HypergraphZId,
            hyperedge_ids: []HypergraphZId,

            pub fn at(self: *const IncidenceMatrix, row: usize, col: usize) u8 {
                assert(row < self.rows);
                assert(col < self.cols);
                return self.data[row * self.cols + col];
            }

            pub fn deinit(self: *IncidenceMatrix, allocator: Allocator) void {
                allocator.free(self.data);
                allocator.free(self.vertex_ids);
                allocator.free(self.hyperedge_ids);
                self.* = undefined;
            }
        };

        /// Build the dense incidence matrix of the hypergraph.
        /// Complexity: O(n·m) for the allocation plus O(Σ|e|) for population.
        /// For very large or sparse hypergraphs this can be memory-heavy
        /// (n·m bytes); consider iterating `hyperedges` directly instead.
        pub fn toIncidenceMatrix(self: *Self, allocator: Allocator) HypergraphZError!IncidenceMatrix {
            const rows = self.vertices.count();
            const cols = self.hyperedges.count();

            const data = try allocator.alloc(u8, rows * cols);
            errdefer allocator.free(data);
            @memset(data, 0);

            const vertex_ids = try allocator.dupe(HypergraphZId, self.vertices.keys());
            errdefer allocator.free(vertex_ids);
            const hyperedge_ids = try allocator.dupe(HypergraphZId, self.hyperedges.keys());
            errdefer allocator.free(hyperedge_ids);

            // Vertex id → row index lookup. Arena-scoped: only needed during fill.
            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            var vertex_index: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            try vertex_index.ensureTotalCapacity(arena.allocator(), @intCast(rows));
            for (vertex_ids, 0..) |vid, row| {
                vertex_index.putAssumeCapacity(vid, row);
            }

            for (hyperedge_ids, 0..) |hid, col| {
                const hyperedge = self.hyperedges.getPtr(hid).?;
                for (hyperedge.relations.items) |vid| {
                    const row = vertex_index.get(vid).?;
                    data[row * cols + col] = 1;
                }
            }

            debugAt(@src(), "{}x{} incidence matrix built", .{ rows, cols });

            return .{
                .rows = rows,
                .cols = cols,
                .data = data,
                .vertex_ids = vertex_ids,
                .hyperedge_ids = hyperedge_ids,
            };
        }

        /// Sparse `n × m` incidence matrix in COO (Coordinate List) format.
        /// Each entry is a non-zero `(row, col)` pair; the value is implicitly 1
        /// since multiplicity is collapsed to 0/1, matching `H ∈ {0,1}^{n×m}`.
        /// Entries are emitted in column-major order: all entries for hyperedge 0
        /// come first (in vertex-id-of-first-occurrence order within that
        /// hyperedge), then hyperedge 1, etc.
        /// Rows and columns map to graph IDs via `vertex_ids` and `hyperedge_ids`.
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const IncidenceMatrixCOO = struct {
            rows: usize,
            cols: usize,
            entries: []Entry,
            vertex_ids: []HypergraphZId,
            hyperedge_ids: []HypergraphZId,

            pub const Entry = struct {
                row: u32,
                col: u32,
            };

            pub fn deinit(self: *IncidenceMatrixCOO, allocator: Allocator) void {
                allocator.free(self.entries);
                allocator.free(self.vertex_ids);
                allocator.free(self.hyperedge_ids);
                self.* = undefined;
            }
        };

        /// Build the sparse incidence matrix in COO format.
        /// Memory is O(nnz) where nnz is the total number of unique
        /// (vertex, hyperedge) incidences — far smaller than the dense form
        /// for typical hypergraphs. Use this when n·m would be prohibitive.
        pub fn toIncidenceMatrixCOO(self: *Self, allocator: Allocator) HypergraphZError!IncidenceMatrixCOO {
            const rows = self.vertices.count();
            const cols = self.hyperedges.count();

            const vertex_ids = try allocator.dupe(HypergraphZId, self.vertices.keys());
            errdefer allocator.free(vertex_ids);
            const hyperedge_ids = try allocator.dupe(HypergraphZId, self.hyperedges.keys());
            errdefer allocator.free(hyperedge_ids);

            // Vertex id → row index lookup, plus a per-hyperedge seen-set to
            // collapse duplicate vertices within a hyperedge to a single entry.
            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();
            var vertex_index: AutoHashMapUnmanaged(HypergraphZId, u32) = .empty;
            try vertex_index.ensureTotalCapacity(aa, @intCast(rows));
            for (vertex_ids, 0..) |vid, row| {
                vertex_index.putAssumeCapacity(vid, @intCast(row));
            }

            var entries: ArrayList(IncidenceMatrixCOO.Entry) = .empty;
            errdefer entries.deinit(allocator);

            var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;
            for (hyperedge_ids, 0..) |hid, col| {
                const hyperedge = self.hyperedges.getPtr(hid).?;
                seen.clearRetainingCapacity();
                for (hyperedge.relations.items) |vid| {
                    const gop = try seen.getOrPut(aa, vid);
                    if (gop.found_existing) continue;
                    try entries.append(allocator, .{
                        .row = vertex_index.get(vid).?,
                        .col = @intCast(col),
                    });
                }
            }

            const owned = try entries.toOwnedSlice(allocator);

            debugAt(@src(), "{}x{} COO matrix built with {} entries", .{ rows, cols, owned.len });

            return .{
                .rows = rows,
                .cols = cols,
                .entries = owned,
                .vertex_ids = vertex_ids,
                .hyperedge_ids = hyperedge_ids,
            };
        }

        /// Variants of the hypergraph Laplacian.
        ///
        /// References:
        /// - Zhou, Huang & Schölkopf, "Learning with Hypergraphs: Clustering,
        ///   Classification, and Embedding", NeurIPS 2006:
        ///   https://papers.nips.cc/paper/2006/hash/dff8e9c2ac33381546d96deea9922999-Abstract.html
        /// - Feng et al., "Hypergraph Neural Networks", AAAI 2019:
        ///   https://arxiv.org/abs/1809.09401
        pub const LaplacianVariant = enum {
            /// Unnormalized hypergraph Laplacian:
            ///   `L = D_v − H W D_e⁻¹ Hᵀ`
            /// where `D_v` is the diagonal vertex-degree matrix
            /// (`d(v) = Σ_{e ∋ v} w(e)`), `W` is the diagonal hyperedge-weight
            /// matrix, and `D_e` is the diagonal hyperedge-cardinality matrix
            /// (`δ(e) = |{v : v ∈ e}|`, multiplicity collapsed).
            /// Symmetric and positive semi-definite; rows sum to 0.
            unnormalized,

            /// Symmetric normalized Laplacian (Zhou 2006). Default for spectral
            /// hypergraph analysis and the form used by HGNN:
            ///   `L = I − D_v⁻¹ᐟ² H W D_e⁻¹ Hᵀ D_v⁻¹ᐟ²`
            /// Symmetric; eigenvalues lie in `[0, 2]`.
            normalized_zhou,
        };

        /// Options for `toLaplacian`.
        pub const LaplacianOptions = struct {
            variant: LaplacianVariant = .normalized_zhou,
        };

        /// Dense `n × n` hypergraph Laplacian, with `n = countVertices()`.
        /// Stored as row-major `f64`. Row/column index `i` maps to
        /// `vertex_ids[i]` (the order returned by `getAllVertices()`).
        ///
        /// Hyperedges are treated as undirected vertex sets: vertex multiplicity
        /// within a hyperedge is collapsed to 0/1, matching the textbook
        /// `H ∈ {0,1}^{n×m}` convention used by `toIncidenceMatrix`. Hyperedge
        /// direction (in the directed-hypergraph sense) is intentionally not
        /// considered here, since the Laplacian is defined for the undirected
        /// case in the standard literature.
        ///
        /// Hyperedge weights are read from the integer field named
        /// `options.weight_field` on the hyperedge payload (the same field used
        /// by `findShortestPath`) and cast to `f64`.
        ///
        /// The caller is responsible for freeing the memory with `deinit`.
        pub const LaplacianMatrix = struct {
            n: usize,
            data: []f64,
            vertex_ids: []HypergraphZId,
            variant: LaplacianVariant,

            pub fn at(self: *const LaplacianMatrix, row: usize, col: usize) f64 {
                assert(row < self.n);
                assert(col < self.n);
                return self.data[row * self.n + col];
            }

            pub fn deinit(self: *LaplacianMatrix, allocator: Allocator) void {
                allocator.free(self.data);
                allocator.free(self.vertex_ids);
                self.* = undefined;
            }
        };

        /// Build the hypergraph Laplacian.
        ///
        /// Definitions, with `H` the `n × m` incidence matrix
        /// (`H[v,e] = 1` iff `v ∈ e`, with multiplicity collapsed):
        ///
        /// - vertex degree:    `d(v) = Σ_{e ∋ v} w(e)`
        /// - hyperedge size:   `δ(e) = |{v : v ∈ e}|`
        /// - weight matrix:    `W   = diag(w(e_1), ..., w(e_m))`
        /// - degree matrices:  `D_v = diag(d(v_1), ...)`, `D_e = diag(δ(e_1), ...)`
        ///
        /// Variants (see `LaplacianVariant`):
        ///
        /// - `.unnormalized`:    `L = D_v − H W D_e⁻¹ Hᵀ`
        /// - `.normalized_zhou`: `L = I − D_v⁻¹ᐟ² H W D_e⁻¹ Hᵀ D_v⁻¹ᐟ²`
        ///
        /// Edge cases:
        ///
        /// - Empty hypergraph (no vertices): returns the trivial `0 × 0` matrix.
        /// - Hyperedges with `δ(e) = 0` (orphans): skipped — they contribute no
        ///   incidence rows to `H`, so the formulas remain well-defined.
        /// - Isolated vertices (`d(v) = 0`) under `.normalized_zhou`: the row
        ///   and column collapse to zero except for a `1` on the diagonal — the
        ///   standard convention to avoid `1/√0` from `D_v⁻¹ᐟ²`.
        ///
        /// Implementation note: instead of forming `H` explicitly we accumulate
        /// `S = H W D_e⁻¹ Hᵀ` block-by-block — each hyperedge contributes a
        /// `δ(e) × δ(e)` outer product of its indicator scaled by `w(e) / δ(e)`.
        ///
        /// Complexity: `O(n²)` memory plus `O(Σ |e|² + n²)` time. For very large
        /// or dense hypergraphs the dense `n × n` matrix can dominate; callers
        /// who only need top eigenvectors may prefer to drive a sparse solver
        /// from `toIncidenceMatrixCOO` directly.
        pub fn toLaplacian(
            self: *Self,
            allocator: Allocator,
            opts: LaplacianOptions,
        ) HypergraphZError!LaplacianMatrix {
            const n = self.vertices.count();

            const data = try allocator.alloc(f64, n * n);
            errdefer allocator.free(data);
            @memset(data, 0);

            const vertex_ids = try allocator.dupe(HypergraphZId, self.vertices.keys());
            errdefer allocator.free(vertex_ids);

            // Vertex id → row index lookup, plus a per-hyperedge dedup buffer.
            // Both arena-scoped: only needed during this call.
            var arena: ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            var vertex_index: AutoHashMapUnmanaged(HypergraphZId, usize) = .empty;
            try vertex_index.ensureTotalCapacity(aa, @intCast(n));
            for (vertex_ids, 0..) |vid, idx| {
                vertex_index.putAssumeCapacity(vid, idx);
            }

            // Vertex degrees `d(v) = Σ_{e ∋ v} w(e)` — accumulated alongside `S`.
            const degrees = try aa.alloc(f64, n);
            @memset(degrees, 0);

            // Per-hyperedge dedup state, reused across iterations.
            var distinct: ArrayList(usize) = .empty;
            var seen: AutoHashMapUnmanaged(HypergraphZId, void) = .empty;

            // Single pass: accumulate `S = H W D_e⁻¹ Hᵀ` directly into `data`
            // and the vertex degrees into `degrees`.
            var h_it = self.hyperedges.iterator();
            while (h_it.next()) |kv| {
                const w_int = @field(kv.value_ptr.data.*, options.weight_field);
                const w: f64 = @floatFromInt(w_int);

                distinct.clearRetainingCapacity();
                seen.clearRetainingCapacity();
                for (kv.value_ptr.relations.items) |vid| {
                    const gop = try seen.getOrPut(aa, vid);
                    if (gop.found_existing) continue;
                    try distinct.append(aa, vertex_index.get(vid).?);
                }
                const delta = distinct.items.len;
                if (delta == 0) continue;

                for (distinct.items) |i| degrees[i] += w;

                // `1_e 1_eᵀ` outer product scaled by `w(e) / δ(e)`.
                const block: f64 = w / @as(f64, @floatFromInt(delta));
                for (distinct.items) |i| {
                    for (distinct.items) |j| {
                        data[i * n + j] += block;
                    }
                }
            }

            // Convert `S` → `L` according to variant.
            switch (opts.variant) {
                .unnormalized => {
                    // L = D_v − S
                    for (0..n) |i| {
                        for (0..n) |j| {
                            data[i * n + j] = -data[i * n + j];
                        }
                        data[i * n + i] += degrees[i];
                    }
                },
                .normalized_zhou => {
                    // L = I − D_v⁻¹ᐟ² S D_v⁻¹ᐟ²
                    // For isolated vertex i (degrees[i] == 0) we set inv_sqrt[i] = 0,
                    // which zeroes row/col i of the scaled S; the `+= 1` on the
                    // diagonal then leaves an identity row, the standard convention.
                    const inv_sqrt = try aa.alloc(f64, n);
                    for (0..n) |i| {
                        inv_sqrt[i] = if (degrees[i] > 0)
                            1.0 / std.math.sqrt(degrees[i])
                        else
                            0.0;
                    }
                    for (0..n) |i| {
                        const ai = inv_sqrt[i];
                        for (0..n) |j| {
                            const idx = i * n + j;
                            data[idx] = -ai * data[idx] * inv_sqrt[j];
                        }
                        data[i * n + i] += 1.0;
                    }
                },
            }

            debugAt(@src(), "{}x{} Laplacian built ({s})", .{ n, n, @tagName(opts.variant) });

            return .{
                .n = n,
                .data = data,
                .vertex_ids = vertex_ids,
                .variant = opts.variant,
            };
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
            const hyperedge_count = try reader.takeInt(u32, .little);

            var graph = try Self.init(allocator, .{
                .vertices_capacity = vertex_count,
                .hyperedges_capacity = hyperedge_count,
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
            for (0..hyperedge_count) |_| {
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
                var vtx_list: ArrayList(HypergraphZId) = .empty;
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
