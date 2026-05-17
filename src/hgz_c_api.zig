//! C ABI layer for HypergraphZ.
//!
//! Exposes a flat, pointer-based API that Python can call via ctypes.
//! All arrays returned to callers are allocated with `std.heap.c_allocator`
//! (backed by libc malloc) so callers may free them with `hgz_free` or libc free().
//!
//! JSON pointers returned by hgz_get_*_json point into arena memory owned by the
//! Handle and are valid until the next mutation or hgz_destroy — do NOT free them.
//!
//! Error convention: 0 = success, negative = error code (see hgz_last_error).
//! Thread safety: each Handle must be owned by a single thread.

const std = @import("std");
const hg = @import("hypergraphz");

// ── Concrete graph type ───────────────────────────────────────────────────────

const Payload = struct {
    json: []const u8, // owned by Handle.json_arena
    weight: u64 = 1,
};

const Graph = hg.HypergraphZ(Payload, Payload, .{});
const alloc = std.heap.c_allocator;

// ── Handle ────────────────────────────────────────────────────────────────────

const Handle = struct {
    graph: Graph,
    json_arena: std.heap.ArenaAllocator,

    fn dupeJson(self: *Handle, ptr: [*]const u8, len: usize) error{OutOfMemory}![]const u8 {
        return self.json_arena.allocator().dupe(u8, ptr[0..len]);
    }
};

// ── Thread-local error buffer ─────────────────────────────────────────────────

threadlocal var err_buf: [512]u8 = undefined;
threadlocal var err_len: usize = 0;

fn setErr(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&err_buf, fmt, args) catch "error message too long";
    err_len = s.len;
}

export fn hgz_last_error(buf: [*]u8, buf_len: usize) usize {
    const n = @min(err_len, buf_len);
    @memcpy(buf[0..n], err_buf[0..n]);
    return err_len;
}

// ── Error codes ───────────────────────────────────────────────────────────────

const Err = enum(i32) {
    ok = 0,
    generic = -1,
    not_built = -2,
    vertex_not_found = -3,
    hyperedge_not_found = -4,
    cycle_detected = -5,
    out_of_memory = -6,
    no_path = -7,
    index_out_of_bounds = -8,
    not_enough_vertices = -9,
};

fn errCode(e: anyerror) i32 {
    setErr("{s}", .{@errorName(e)});
    return switch (e) {
        error.NotBuilt => @intFromEnum(Err.not_built),
        error.VertexNotFound => @intFromEnum(Err.vertex_not_found),
        error.HyperedgeNotFound => @intFromEnum(Err.hyperedge_not_found),
        error.CycleDetected => @intFromEnum(Err.cycle_detected),
        error.OutOfMemory => @intFromEnum(Err.out_of_memory),
        error.IndexOutOfBounds => @intFromEnum(Err.index_out_of_bounds),
        error.NoVerticesToInsert, error.NotEnoughVerticesProvided => @intFromEnum(Err.not_enough_vertices),
        else => @intFromEnum(Err.generic),
    };
}

// ── Memory management ─────────────────────────────────────────────────────────

/// Free a caller-owned array returned by any hgz_* function.
/// Equivalent to libc free().
export fn hgz_free(ptr: ?*anyopaque) void {
    std.c.free(ptr);
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

export fn hgz_create() ?*Handle {
    const h = alloc.create(Handle) catch return null;
    h.* = .{
        .graph = Graph.init(alloc, .{}) catch {
            alloc.destroy(h);
            return null;
        },
        .json_arena = std.heap.ArenaAllocator.init(alloc),
    };
    return h;
}

export fn hgz_destroy(h: *Handle) void {
    h.graph.deinit();
    h.json_arena.deinit();
    alloc.destroy(h);
}

export fn hgz_build(h: *Handle) i32 {
    h.graph.build() catch |e| return errCode(e);
    return 0;
}

export fn hgz_clear(h: *Handle) void {
    h.graph.clear();
    _ = h.json_arena.reset(.free_all);
}

// ── Vertices ──────────────────────────────────────────────────────────────────

export fn hgz_add_vertex(
    h: *Handle,
    json_ptr: [*]const u8,
    json_len: usize,
    out_id: *u32,
) i32 {
    const json = h.dupeJson(json_ptr, json_len) catch return errCode(error.OutOfMemory);
    const id = h.graph.createVertex(.{ .json = json }) catch |e| return errCode(e);
    out_id.* = id;
    return 0;
}

export fn hgz_delete_vertex(h: *Handle, id: u32) i32 {
    h.graph.deleteVertex(id) catch |e| return errCode(e);
    return 0;
}

export fn hgz_update_vertex(
    h: *Handle,
    id: u32,
    json_ptr: [*]const u8,
    json_len: usize,
) i32 {
    const json = h.dupeJson(json_ptr, json_len) catch return errCode(error.OutOfMemory);
    h.graph.updateVertex(id, .{ .json = json }) catch |e| return errCode(e);
    return 0;
}

/// The returned pointer is into arena memory. Do NOT free it.
/// It is valid until the next mutation on this vertex or hgz_destroy.
export fn hgz_get_vertex_json(
    h: *Handle,
    id: u32,
    out_ptr: *[*]const u8,
    out_len: *usize,
) i32 {
    const payload = h.graph.getVertex(id) catch |e| return errCode(e);
    out_ptr.* = payload.json.ptr;
    out_len.* = payload.json.len;
    return 0;
}

/// Create multiple vertices from a JSON array '[{...}, {...}, ...]'.
/// Returns a caller-owned array of IDs. Free with hgz_free.
export fn hgz_add_vertices(
    h: *Handle,
    json_ptr: [*]const u8,
    json_len: usize,
    out_ptr: *[*]u32,
    out_len: *usize,
) i32 {
    const json = json_ptr[0..json_len];
    const arena = h.json_arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, arena, json, .{}) catch return errCode(error.OutOfMemory);
    const items = parsed.value.array.items;

    const ids = alloc.alloc(u32, items.len) catch return errCode(error.OutOfMemory);
    for (items, 0..) |item, i| {
        const item_json = std.json.Stringify.valueAlloc(arena, item, .{}) catch {
            alloc.free(ids);
            return errCode(error.OutOfMemory);
        };
        ids[i] = h.graph.createVertex(.{ .json = item_json }) catch |e| {
            alloc.free(ids);
            return errCode(e);
        };
    }
    out_ptr.* = ids.ptr;
    out_len.* = ids.len;
    return 0;
}

export fn hgz_vertex_count(h: *Handle) usize {
    return h.graph.countVertices();
}

/// Returns a caller-owned array of vertex IDs. Free with hgz_free.
export fn hgz_get_all_vertex_ids(h: *Handle, out_ptr: *[*]u32, out_len: *usize) i32 {
    const ids = h.graph.getAllVertices();
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

// ── Hyperedges ────────────────────────────────────────────────────────────────

export fn hgz_add_hyperedge(
    h: *Handle,
    json_ptr: [*]const u8,
    json_len: usize,
    out_id: *u32,
) i32 {
    const json = h.dupeJson(json_ptr, json_len) catch return errCode(error.OutOfMemory);
    const id = h.graph.createHyperedge(.{ .json = json }) catch |e| return errCode(e);
    out_id.* = id;
    return 0;
}

/// Create multiple hyperedges from a JSON array '[{...}, {...}, ...]'.
/// Returns a caller-owned array of IDs. Free with hgz_free.
export fn hgz_add_hyperedges(
    h: *Handle,
    json_ptr: [*]const u8,
    json_len: usize,
    out_ptr: *[*]u32,
    out_len: *usize,
) i32 {
    const json = json_ptr[0..json_len];
    const arena = h.json_arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, arena, json, .{}) catch return errCode(error.OutOfMemory);
    const items = parsed.value.array.items;

    const ids = alloc.alloc(u32, items.len) catch return errCode(error.OutOfMemory);
    for (items, 0..) |item, i| {
        const item_json = std.json.Stringify.valueAlloc(arena, item, .{}) catch {
            alloc.free(ids);
            return errCode(error.OutOfMemory);
        };
        ids[i] = h.graph.createHyperedge(.{ .json = item_json }) catch |e| {
            alloc.free(ids);
            return errCode(e);
        };
    }
    out_ptr.* = ids.ptr;
    out_len.* = ids.len;
    return 0;
}

/// drop_vertices = true removes orphaned vertices along with the hyperedge.
export fn hgz_delete_hyperedge(h: *Handle, id: u32, drop_vertices: bool) i32 {
    h.graph.deleteHyperedge(id, drop_vertices) catch |e| return errCode(e);
    return 0;
}

export fn hgz_update_hyperedge(
    h: *Handle,
    id: u32,
    json_ptr: [*]const u8,
    json_len: usize,
) i32 {
    const json = h.dupeJson(json_ptr, json_len) catch return errCode(error.OutOfMemory);
    h.graph.updateHyperedge(id, .{ .json = json }) catch |e| return errCode(e);
    return 0;
}

/// The returned pointer is into arena memory. Do NOT free it.
export fn hgz_get_hyperedge_json(
    h: *Handle,
    id: u32,
    out_ptr: *[*]const u8,
    out_len: *usize,
) i32 {
    const payload = h.graph.getHyperedge(id) catch |e| return errCode(e);
    out_ptr.* = payload.json.ptr;
    out_len.* = payload.json.len;
    return 0;
}

export fn hgz_hyperedge_count(h: *Handle) usize {
    return h.graph.countHyperedges();
}

/// Returns a caller-owned array of hyperedge IDs. Free with hgz_free.
export fn hgz_get_all_hyperedge_ids(h: *Handle, out_ptr: *[*]u32, out_len: *usize) i32 {
    const ids = h.graph.getAllHyperedges();
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

// ── Relations ─────────────────────────────────────────────────────────────────

export fn hgz_append_vertices(
    h: *Handle,
    he_id: u32,
    ids_ptr: [*]const u32,
    ids_len: usize,
) i32 {
    h.graph.appendVerticesToHyperedge(he_id, ids_ptr[0..ids_len]) catch |e| return errCode(e);
    return 0;
}

/// Returns caller-owned array of vertex IDs in the hyperedge. Free with hgz_free.
export fn hgz_get_hyperedge_vertex_ids(
    h: *Handle,
    he_id: u32,
    out_ptr: *[*]u32,
    out_len: *usize,
) i32 {
    const ids = h.graph.getHyperedgeVertices(he_id) catch |e| return errCode(e);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

/// Returns caller-owned array of hyperedge IDs for a vertex. Free with hgz_free.
export fn hgz_get_vertex_hyperedge_ids(
    h: *Handle,
    v_id: u32,
    out_ptr: *[*]u32,
    out_len: *usize,
) i32 {
    const ids = h.graph.getVertexHyperedges(v_id) catch |e| return errCode(e);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

// ── Traversal ─────────────────────────────────────────────────────────────────

/// Returns Err.no_path (-7) when no path exists.
/// On success out_ptr is a caller-owned array of vertex IDs. Free with hgz_free.
export fn hgz_find_shortest_path(
    h: *Handle,
    from: u32,
    to: u32,
    out_ptr: *[*]u32,
    out_len: *usize,
) i32 {
    var result = h.graph.findShortestPath(from, to) catch |e| return errCode(e);
    defer result.deinit(alloc);
    if (result.data) |path| {
        const buf = alloc.dupe(u32, path.items) catch return errCode(error.OutOfMemory);
        out_ptr.* = buf.ptr;
        out_len.* = buf.len;
        return 0;
    }
    out_len.* = 0;
    return @intFromEnum(Err.no_path);
}

/// Returns 1 if connected, 0 if not, negative on error.
export fn hgz_is_connected(h: *Handle) i32 {
    const connected = h.graph.isConnected() catch |e| return errCode(e);
    return if (connected) 1 else 0;
}

// ── Algorithms ────────────────────────────────────────────────────────────────

/// Returns connected components as a flat ID array plus a sizes array.
/// Both out_flat and out_sizes are caller-owned. Free each with hgz_free.
/// Component i occupies out_flat[offset .. offset + out_sizes[i]].
export fn hgz_get_connected_components(
    h: *Handle,
    out_flat: *[*]u32,
    out_sizes: *[*]usize,
    out_count: *usize,
) i32 {
    var result = h.graph.getConnectedComponents() catch |e| return errCode(e);
    defer result.deinit(alloc);

    const count = result.data.items.len;
    var total: usize = 0;
    for (result.data.items) |comp| total += comp.len;

    const flat = alloc.alloc(u32, total) catch return errCode(error.OutOfMemory);
    const sizes = alloc.alloc(usize, count) catch {
        alloc.free(flat);
        return errCode(error.OutOfMemory);
    };

    var off: usize = 0;
    for (result.data.items, 0..) |comp, i| {
        @memcpy(flat[off .. off + comp.len], comp);
        sizes[i] = comp.len;
        off += comp.len;
    }

    out_flat.* = flat.ptr;
    out_sizes.* = sizes.ptr;
    out_count.* = count;
    return 0;
}

/// Returns caller-owned array of cut vertex IDs. Free with hgz_free.
export fn hgz_find_cut_vertices(h: *Handle, out_ptr: *[*]u32, out_len: *usize) i32 {
    const ids = h.graph.findCutVertices() catch |e| return errCode(e);
    defer alloc.free(ids);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

/// Returns caller-owned array of neighbour vertex IDs. Free with hgz_free.
export fn hgz_get_vertex_neighborhood(
    h: *Handle,
    v_id: u32,
    out_ptr: *[*]u32,
    out_len: *usize,
) i32 {
    const ids = h.graph.getVertexNeighborhood(v_id) catch |e| return errCode(e);
    defer alloc.free(ids);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

/// Returns caller-owned topological order array. Free with hgz_free.
export fn hgz_topological_sort(h: *Handle, out_ptr: *[*]u32, out_len: *usize) i32 {
    const ids = h.graph.topologicalSort() catch |e| return errCode(e);
    defer alloc.free(ids);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

// ── Degree ────────────────────────────────────────────────────────────────────

export fn hgz_get_vertex_indegree(h: *Handle, id: u32, out: *usize) i32 {
    out.* = h.graph.getVertexIndegree(id) catch |e| return errCode(e);
    return 0;
}

export fn hgz_get_vertex_outdegree(h: *Handle, id: u32, out: *usize) i32 {
    out.* = h.graph.getVertexOutdegree(id) catch |e| return errCode(e);
    return 0;
}

// ── Boolean queries ───────────────────────────────────────────────────────────

/// Returns 1 if reachable, 0 if not, negative on error.
export fn hgz_is_reachable(h: *Handle, from: u32, to: u32) i32 {
    const r = h.graph.isReachable(from, to) catch |e| return errCode(e);
    return if (r) 1 else 0;
}

/// Returns 1 if a directed cycle exists, 0 if not, negative on error.
export fn hgz_has_cycle(h: *Handle) i32 {
    const r = h.graph.hasCycle() catch |e| return errCode(e);
    return if (r) 1 else 0;
}

/// Returns 1 if every hyperedge has exactly k vertices (raw count), 0 if not.
export fn hgz_is_k_uniform(h: *Handle, k: usize) i32 {
    const r = h.graph.isKUniform(k) catch |e| return errCode(e);
    return if (r) 1 else 0;
}

// ── Traversal ─────────────────────────────────────────────────────────────────

/// Returns caller-owned BFS visit order. Free with hgz_free.
export fn hgz_bfs(h: *Handle, start: u32, out_ptr: *[*]u32, out_len: *usize) i32 {
    const ids = h.graph.breadthFirstSearch(start) catch |e| return errCode(e);
    defer alloc.free(ids);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

/// Returns caller-owned DFS visit order. Free with hgz_free.
export fn hgz_dfs(h: *Handle, start: u32, out_ptr: *[*]u32, out_len: *usize) i32 {
    const ids = h.graph.depthFirstSearch(start) catch |e| return errCode(e);
    defer alloc.free(ids);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

threadlocal var _rng_state: u64 = 0x9e3779b97f4a7c15;

/// Random walk of `steps` steps (undirected hypergraph semantics).
/// Returns a caller-owned array of length steps+1. Free with hgz_free.
export fn hgz_random_walk(
    h: *Handle,
    start: u32,
    steps: usize,
    out_ptr: *[*]u32,
    out_len: *usize,
) i32 {
    _rng_state ^= @as(u64, @intFromPtr(h));
    _rng_state *%= 6364136223846793005;
    _rng_state +%= 1442695040888963407;
    var prng = std.Random.DefaultPrng.init(_rng_state);
    const ids = h.graph.randomWalk(start, steps, prng.random()) catch |e| return errCode(e);
    defer alloc.free(ids);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

// ── Orphan queries ────────────────────────────────────────────────────────────

/// Returns caller-owned array of vertex IDs with no hyperedge memberships. Free with hgz_free.
export fn hgz_get_orphan_vertices(h: *Handle, out_ptr: *[*]u32, out_len: *usize) i32 {
    const ids = h.graph.getOrphanVertices() catch |e| return errCode(e);
    defer alloc.free(ids);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

/// Returns caller-owned array of hyperedge IDs containing no vertices. Free with hgz_free.
export fn hgz_get_orphan_hyperedges(h: *Handle, out_ptr: *[*]u32, out_len: *usize) i32 {
    const ids = h.graph.getOrphanHyperedges() catch |e| return errCode(e);
    defer alloc.free(ids);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

// ── Set operations ────────────────────────────────────────────────────────────

/// Vertices appearing in ALL given hyperedges. Requires ≥ 2 hyperedge IDs.
/// Returns caller-owned array. Free with hgz_free.
export fn hgz_get_intersections(
    h: *Handle,
    he_ids_ptr: [*]const u32,
    he_ids_len: usize,
    out_ptr: *[*]u32,
    out_len: *usize,
) i32 {
    const ids = h.graph.getIntersections(he_ids_ptr[0..he_ids_len]) catch |e| return errCode(e);
    defer alloc.free(ids);
    const buf = alloc.dupe(u32, ids) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

/// Hyperedges that connect two vertices. Returns caller-owned array. Free with hgz_free.
export fn hgz_get_hyperedges_connecting(
    h: *Handle,
    v1: u32,
    v2: u32,
    out_ptr: *[*]u32,
    out_len: *usize,
) i32 {
    var result = h.graph.getHyperedgesConnecting(v1, v2) catch |e| return errCode(e);
    defer result.deinit(alloc);
    const keys = result.data.keys();
    const buf = alloc.dupe(u32, keys) catch return errCode(error.OutOfMemory);
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return 0;
}

// ── Endpoints ─────────────────────────────────────────────────────────────────

/// Initial and terminal endpoints of all hyperedges as parallel id arrays.
/// All four returned pointers are caller-owned; free each with hgz_free.
export fn hgz_get_endpoints(
    h: *Handle,
    out_initial_he: *[*]u32,
    out_initial_v: *[*]u32,
    out_initial_n: *usize,
    out_terminal_he: *[*]u32,
    out_terminal_v: *[*]u32,
    out_terminal_n: *usize,
) i32 {
    var result = h.graph.getEndpoints() catch |e| return errCode(e);
    defer result.deinit();

    const ni = result.initial.len;
    const nt = result.terminal.len;

    const ihe = alloc.alloc(u32, ni) catch return errCode(error.OutOfMemory);
    const iv = alloc.alloc(u32, ni) catch {
        alloc.free(ihe);
        return errCode(error.OutOfMemory);
    };
    const the = alloc.alloc(u32, nt) catch {
        alloc.free(ihe);
        alloc.free(iv);
        return errCode(error.OutOfMemory);
    };
    const tv = alloc.alloc(u32, nt) catch {
        alloc.free(ihe);
        alloc.free(iv);
        alloc.free(the);
        return errCode(error.OutOfMemory);
    };

    @memcpy(ihe, result.initial.items(.hyperedge_id));
    @memcpy(iv, result.initial.items(.vertex_id));
    @memcpy(the, result.terminal.items(.hyperedge_id));
    @memcpy(tv, result.terminal.items(.vertex_id));

    out_initial_he.* = ihe.ptr;
    out_initial_v.* = iv.ptr;
    out_initial_n.* = ni;
    out_terminal_he.* = the.ptr;
    out_terminal_v.* = tv.ptr;
    out_terminal_n.* = nt;
    return 0;
}

// ── Relation mutations ────────────────────────────────────────────────────────

export fn hgz_prepend_vertices(
    h: *Handle,
    he_id: u32,
    ids_ptr: [*]const u32,
    ids_len: usize,
) i32 {
    h.graph.prependVerticesToHyperedge(he_id, ids_ptr[0..ids_len]) catch |e| return errCode(e);
    return 0;
}

export fn hgz_insert_vertex(h: *Handle, he_id: u32, v_id: u32, index: usize) i32 {
    h.graph.insertVertexIntoHyperedge(he_id, v_id, index) catch |e| return errCode(e);
    return 0;
}

export fn hgz_insert_vertices(
    h: *Handle,
    he_id: u32,
    ids_ptr: [*]const u32,
    ids_len: usize,
    index: usize,
) i32 {
    h.graph.insertVerticesIntoHyperedge(he_id, ids_ptr[0..ids_len], index) catch |e| return errCode(e);
    return 0;
}

export fn hgz_remove_vertex_from_hyperedge(h: *Handle, he_id: u32, v_id: u32) i32 {
    h.graph.deleteVertexFromHyperedge(he_id, v_id) catch |e| return errCode(e);
    return 0;
}

export fn hgz_remove_vertex_at_index(h: *Handle, he_id: u32, index: usize) i32 {
    h.graph.deleteVertexByIndexFromHyperedge(he_id, index) catch |e| return errCode(e);
    return 0;
}

// ── Algorithms ────────────────────────────────────────────────────────────────

/// Returns four parallel caller-owned arrays (ids, degree, closeness, betweenness).
/// Free each with hgz_free.
export fn hgz_compute_centrality(
    h: *Handle,
    out_ids: *[*]u32,
    out_degree: *[*]f64,
    out_closeness: *[*]f64,
    out_betweenness: *[*]f64,
    out_n: *usize,
) i32 {
    var result = h.graph.computeCentrality() catch |e| return errCode(e);
    defer result.deinit(alloc);

    const n = result.data.count();
    const ids = alloc.alloc(u32, n) catch return errCode(error.OutOfMemory);
    const deg = alloc.alloc(f64, n) catch {
        alloc.free(ids);
        return errCode(error.OutOfMemory);
    };
    const clo = alloc.alloc(f64, n) catch {
        alloc.free(ids);
        alloc.free(deg);
        return errCode(error.OutOfMemory);
    };
    const bet = alloc.alloc(f64, n) catch {
        alloc.free(ids);
        alloc.free(deg);
        alloc.free(clo);
        return errCode(error.OutOfMemory);
    };

    var i: usize = 0;
    var it = result.data.iterator();
    while (it.next()) |kv| : (i += 1) {
        ids[i] = kv.key_ptr.*;
        deg[i] = kv.value_ptr.degree;
        clo[i] = kv.value_ptr.closeness;
        bet[i] = kv.value_ptr.betweenness;
    }

    out_ids.* = ids.ptr;
    out_degree.* = deg.ptr;
    out_closeness.* = clo.ptr;
    out_betweenness.* = bet.ptr;
    out_n.* = n;
    return 0;
}

/// Returns two parallel caller-owned arrays (ids, scores) plus metadata.
/// Free ids and scores with hgz_free.
export fn hgz_compute_page_rank(
    h: *Handle,
    damping: f64,
    max_iterations: usize,
    tolerance: f64,
    out_ids: *[*]u32,
    out_scores: *[*]f64,
    out_n: *usize,
    out_iterations: *usize,
    out_converged: *bool,
) i32 {
    const opts = Graph.PageRankOptions{
        .damping = damping,
        .max_iterations = max_iterations,
        .tolerance = tolerance,
    };
    var result = h.graph.computePageRank(opts) catch |e| return errCode(e);
    defer result.deinit(alloc);

    const n = result.data.count();
    const ids = alloc.alloc(u32, n) catch return errCode(error.OutOfMemory);
    const scores = alloc.alloc(f64, n) catch {
        alloc.free(ids);
        return errCode(error.OutOfMemory);
    };

    var i: usize = 0;
    var it = result.data.iterator();
    while (it.next()) |kv| : (i += 1) {
        ids[i] = kv.key_ptr.*;
        scores[i] = kv.value_ptr.*;
    }

    out_ids.* = ids.ptr;
    out_scores.* = scores.ptr;
    out_n.* = n;
    out_iterations.* = result.iterations;
    out_converged.* = result.converged;
    return 0;
}

/// Returns two parallel caller-owned arrays (subset_ids, superset_ids). Free each with hgz_free.
export fn hgz_get_inclusions(
    h: *Handle,
    out_subsets: *[*]u32,
    out_supersets: *[*]u32,
    out_n: *usize,
) i32 {
    var result = h.graph.getInclusions() catch |e| return errCode(e);
    defer result.deinit(alloc);

    const n = result.data.len;
    const subsets = alloc.alloc(u32, n) catch return errCode(error.OutOfMemory);
    const supersets = alloc.alloc(u32, n) catch {
        alloc.free(subsets);
        return errCode(error.OutOfMemory);
    };

    for (result.data, 0..) |rel, i| {
        subsets[i] = rel.subset;
        supersets[i] = rel.superset;
    }

    out_subsets.* = subsets.ptr;
    out_supersets.* = supersets.ptr;
    out_n.* = n;
    return 0;
}

/// Per-order nestedness profile. Three parallel caller-owned arrays (sizes, included, total).
/// Free each with hgz_free.
export fn hgz_get_nestedness_profile(
    h: *Handle,
    out_sizes: *[*]usize,
    out_included: *[*]usize,
    out_total: *[*]usize,
    out_n: *usize,
) i32 {
    var result = h.graph.getNestednessProfile() catch |e| return errCode(e);
    defer result.deinit(alloc);

    const n = result.data.len;
    const sizes = alloc.alloc(usize, n) catch return errCode(error.OutOfMemory);
    const included = alloc.alloc(usize, n) catch {
        alloc.free(sizes);
        return errCode(error.OutOfMemory);
    };
    const total = alloc.alloc(usize, n) catch {
        alloc.free(sizes);
        alloc.free(included);
        return errCode(error.OutOfMemory);
    };

    for (result.data, 0..) |entry, i| {
        sizes[i] = entry.size;
        included[i] = entry.included;
        total[i] = entry.total;
    }

    out_sizes.* = sizes.ptr;
    out_included.* = included.ptr;
    out_total.* = total.ptr;
    out_n.* = n;
    return 0;
}

/// Dense incidence matrix. out_data (u8, row-major), out_vertex_ids, out_hyperedge_ids are
/// caller-owned; free each with hgz_free.
export fn hgz_incidence_matrix(
    h: *Handle,
    out_data: *[*]u8,
    out_vertex_ids: *[*]u32,
    out_hyperedge_ids: *[*]u32,
    out_rows: *usize,
    out_cols: *usize,
) i32 {
    const result = h.graph.toIncidenceMatrix(alloc) catch |e| return errCode(e);
    // Transfer ownership of the three alloc-owned slices to the caller.
    out_data.* = result.data.ptr;
    out_vertex_ids.* = result.vertex_ids.ptr;
    out_hyperedge_ids.* = result.hyperedge_ids.ptr;
    out_rows.* = result.rows;
    out_cols.* = result.cols;
    return 0;
}

/// Sparse incidence matrix (COO). Four caller-owned arrays; free each with hgz_free.
export fn hgz_incidence_matrix_coo(
    h: *Handle,
    out_row_indices: *[*]u32,
    out_col_indices: *[*]u32,
    out_vertex_ids: *[*]u32,
    out_hyperedge_ids: *[*]u32,
    out_nnz: *usize,
    out_n_vertices: *usize,
    out_n_hyperedges: *usize,
) i32 {
    var result = h.graph.toIncidenceMatrixCOO(alloc) catch |e| return errCode(e);

    const nnz = result.entries.len;
    const rows_buf = alloc.alloc(u32, nnz) catch {
        result.deinit(alloc);
        return errCode(error.OutOfMemory);
    };
    const cols_buf = alloc.alloc(u32, nnz) catch {
        alloc.free(rows_buf);
        result.deinit(alloc);
        return errCode(error.OutOfMemory);
    };

    for (result.entries, 0..) |entry, i| {
        rows_buf[i] = entry.row;
        cols_buf[i] = entry.col;
    }
    // Free the entries array; vertex_ids and hyperedge_ids are transferred to caller.
    alloc.free(result.entries);

    out_row_indices.* = rows_buf.ptr;
    out_col_indices.* = cols_buf.ptr;
    out_vertex_ids.* = result.vertex_ids.ptr;
    out_hyperedge_ids.* = result.hyperedge_ids.ptr;
    out_nnz.* = nnz;
    out_n_vertices.* = result.rows;
    out_n_hyperedges.* = result.cols;
    return 0;
}

/// Dense Laplacian (n×n, row-major f64). variant: 0=unnormalized, 1=normalized_zhou (default).
/// out_data and out_vertex_ids are caller-owned; free each with hgz_free.
export fn hgz_laplacian(
    h: *Handle,
    variant: u8,
    out_data: *[*]f64,
    out_vertex_ids: *[*]u32,
    out_n: *usize,
) i32 {
    const v: Graph.LaplacianVariant = if (variant == 0) .unnormalized else .normalized_zhou;
    const result = h.graph.toLaplacian(alloc, .{ .variant = v }) catch |e| return errCode(e);
    out_data.* = result.data.ptr;
    out_vertex_ids.* = result.vertex_ids.ptr;
    out_n.* = result.n;
    return 0;
}

/// All simple paths from `from` to `to`.
/// out_flat and out_sizes are caller-owned; free each with hgz_free.
export fn hgz_find_all_paths(
    h: *Handle,
    from: u32,
    to: u32,
    out_flat: *[*]u32,
    out_sizes: *[*]usize,
    out_count: *usize,
) i32 {
    var result = h.graph.findAllPaths(from, to) catch |e| return errCode(e);
    defer result.deinit(alloc);

    const count = result.data.items.len;
    var total: usize = 0;
    for (result.data.items) |path| total += path.len;

    const flat = alloc.alloc(u32, total) catch return errCode(error.OutOfMemory);
    const sizes = alloc.alloc(usize, count) catch {
        alloc.free(flat);
        return errCode(error.OutOfMemory);
    };

    var off: usize = 0;
    for (result.data.items, 0..) |path, i| {
        @memcpy(flat[off .. off + path.len], path);
        sizes[i] = path.len;
        off += path.len;
    }

    out_flat.* = flat.ptr;
    out_sizes.* = sizes.ptr;
    out_count.* = count;
    return 0;
}

// ── Sub-graph operations (return new Handle) ──────────────────────────────────

/// Identity payload pass-through (used for sub-graph callbacks where H = V = Payload).
fn identityPayload(p: Payload) Payload {
    return p;
}

fn pairToEmptyPayload(_: u32, _: u32) Payload {
    return .{ .json = "{}", .weight = 1 };
}

const empty_payload = Payload{ .json = "{}", .weight = 1 };

/// Wrap a newly-created Graph into a Handle, deep-copying all JSON strings into
/// the new handle's arena so it is independent of any source handle's arena.
fn wrapHandle(graph: Graph) !*Handle {
    const h = try alloc.create(Handle);
    h.* = .{
        .graph = graph,
        .json_arena = std.heap.ArenaAllocator.init(alloc),
    };
    const aa = h.json_arena.allocator();
    var it_v = h.graph.vertices.iterator();
    while (it_v.next()) |kv| {
        kv.value_ptr.data.json = aa.dupe(u8, kv.value_ptr.data.json) catch {
            h.json_arena.deinit();
            h.graph.deinit();
            alloc.destroy(h);
            return error.OutOfMemory;
        };
    }
    var it_he = h.graph.hyperedges.iterator();
    while (it_he.next()) |kv| {
        kv.value_ptr.data.json = aa.dupe(u8, kv.value_ptr.data.json) catch {
            h.json_arena.deinit();
            h.graph.deinit();
            alloc.destroy(h);
            return error.OutOfMemory;
        };
    }
    return h;
}

export fn hgz_clone(h: *Handle, out_handle: **Handle) i32 {
    const graph = h.graph.clone() catch |e| return errCode(e);
    out_handle.* = wrapHandle(graph) catch return errCode(error.OutOfMemory);
    return 0;
}

export fn hgz_get_dual(h: *Handle, out_handle: **Handle) i32 {
    const graph = h.graph.getDual(identityPayload, identityPayload) catch |e| return errCode(e);
    out_handle.* = wrapHandle(graph) catch return errCode(error.OutOfMemory);
    return 0;
}

/// Return all vertices and only hyperedges with raw vertex count ≤ k.
export fn hgz_get_k_skeleton(h: *Handle, k: usize, out_handle: **Handle) i32 {
    const graph = h.graph.getKSkeleton(k) catch |e| return errCode(e);
    out_handle.* = wrapHandle(graph) catch return errCode(error.OutOfMemory);
    return 0;
}

export fn hgz_expand_to_graph(h: *Handle, out_handle: **Handle) i32 {
    const graph = h.graph.expandToGraph() catch |e| return errCode(e);
    out_handle.* = wrapHandle(graph) catch return errCode(error.OutOfMemory);
    return 0;
}

export fn hgz_expand_to_star(h: *Handle, out_handle: **Handle) i32 {
    const graph = h.graph.expandToStar(identityPayload) catch |e| return errCode(e);
    out_handle.* = wrapHandle(graph) catch return errCode(error.OutOfMemory);
    return 0;
}

export fn hgz_get_line_graph(h: *Handle, out_handle: **Handle) i32 {
    const graph = h.graph.getLineGraph(identityPayload, empty_payload) catch |e| return errCode(e);
    out_handle.* = wrapHandle(graph) catch return errCode(error.OutOfMemory);
    return 0;
}

export fn hgz_get_vertex_induced_subhypergraph(
    h: *Handle,
    ids_ptr: [*]const u32,
    ids_len: usize,
    out_handle: **Handle,
) i32 {
    const graph = h.graph.getVertexInducedSubhypergraph(ids_ptr[0..ids_len]) catch |e| return errCode(e);
    out_handle.* = wrapHandle(graph) catch return errCode(error.OutOfMemory);
    return 0;
}

export fn hgz_get_edge_induced_subhypergraph(
    h: *Handle,
    ids_ptr: [*]const u32,
    ids_len: usize,
    out_handle: **Handle,
) i32 {
    const graph = h.graph.getEdgeInducedSubhypergraph(ids_ptr[0..ids_len]) catch |e| return errCode(e);
    out_handle.* = wrapHandle(graph) catch return errCode(error.OutOfMemory);
    return 0;
}

export fn hgz_get_core(h: *Handle, s: usize, t: usize, out_handle: **Handle) i32 {
    const graph = h.graph.getCore(s, t) catch |e| return errCode(e);
    out_handle.* = wrapHandle(graph) catch return errCode(error.OutOfMemory);
    return 0;
}

export fn hgz_get_transitive_closure(h: *Handle, out_handle: **Handle) i32 {
    const graph = h.graph.getTransitiveClosure(pairToEmptyPayload) catch |e| return errCode(e);
    out_handle.* = wrapHandle(graph) catch return errCode(error.OutOfMemory);
    return 0;
}

// ── Codec ─────────────────────────────────────────────────────────────────────

fn serializePayload(val: Payload, writer: *std.Io.Writer) !void {
    try writer.writeInt(u64, @intCast(val.json.len), .little);
    try writer.writeAll(val.json);
    try writer.writeInt(u64, val.weight, .little);
}

fn deserializePayload(reader: *std.Io.Reader) !Payload {
    const len = try reader.takeInt(u64, .little);
    const json = try alloc.alloc(u8, len);
    errdefer alloc.free(json);
    try reader.readSliceAll(json);
    const weight = try reader.takeInt(u64, .little);
    return .{ .json = json, .weight = weight };
}

export fn hgz_save(h: *Handle, path_ptr: [*:0]const u8) i32 {
    const path = std.mem.span(path_ptr);

    var buf_w = std.Io.Writer.Allocating.init(alloc);
    defer buf_w.deinit();
    h.graph.save(&buf_w.writer, serializePayload, serializePayload) catch |e| return errCode(e);

    const data = buf_w.writer.buffer[0..buf_w.writer.end];

    var io_single: std.Io.Threaded = .init_single_threaded;
    defer io_single.deinit();
    const io = io_single.io();
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |e| return errCode(e);
    return 0;
}

export fn hgz_load(path_ptr: [*:0]const u8, out_handle: **Handle) i32 {
    const path = std.mem.span(path_ptr);

    var io_single: std.Io.Threaded = .init_single_threaded;
    defer io_single.deinit();
    const io = io_single.io();

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |e| return errCode(e);
    defer alloc.free(data);

    var r = std.Io.Reader.fixed(data);

    const h = alloc.create(Handle) catch return errCode(error.OutOfMemory);
    h.json_arena = std.heap.ArenaAllocator.init(alloc);

    h.graph = Graph.load(alloc, &r, deserializePayload, deserializePayload) catch |e| {
        h.json_arena.deinit();
        alloc.destroy(h);
        return errCode(e);
    };

    // Transfer JSON strings from c_allocator (used by deserializePayload) into
    // the arena so they are freed en masse on hgz_destroy.
    inline for (.{ &h.graph.vertices, &h.graph.hyperedges }) |map| {
        var it = map.iterator();
        while (it.next()) |kv| {
            const old = kv.value_ptr.data.json;
            if (h.json_arena.allocator().dupe(u8, old)) |copy| {
                alloc.free(old);
                kv.value_ptr.data.json = copy;
            } else |_| {
                // OOM: leave the c_allocator slice; it leaks on destroy but
                // the graph is otherwise valid.
            }
        }
    }

    out_handle.* = h;
    return 0;
}
