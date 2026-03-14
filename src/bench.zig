//! Benchmarks for HypergraphZ.

const std = @import("std");
const hypergraphz = @import("hypergraphz.zig");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const GeneralPurposeAllocator = std.heap.DebugAllocator;
const HypergraphZ = hypergraphz.HypergraphZ;
const HypergraphZId = hypergraphz.HypergraphZId;
const comptimePrint = std.fmt.comptimePrint;

const Hyperedge = struct { weight: usize = 1 };
const Vertex = struct {};

const Bench = struct {
    const Self = @This();

    graph: HypergraphZ(Hyperedge, Vertex),
    io_single: std.Io.Threaded,
    lap_start: std.Io.Timestamp,

    pub fn init(allocator: Allocator, comptime name: []const u8, config: HypergraphZ(Hyperedge, Vertex).HypergraphZConfig) !Self {
        var io_single: std.Io.Threaded = .init_single_threaded;
        const io = io_single.io();

        var buf: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.print(comptimePrint("{s}...\n", .{name}), .{});
        try w.interface.flush();

        const graph = try HypergraphZ(Hyperedge, Vertex).init(allocator, config);
        const lap_start = std.Io.Timestamp.now(io, .awake);

        return .{
            .graph = graph,
            .io_single = io_single,
            .lap_start = lap_start,
        };
    }

    /// Reset the timer. Use this to exclude setup from the measured duration.
    pub fn resetTimer(self: *Self) void {
        self.lap_start = std.Io.Timestamp.now(self.io_single.io(), .awake);
    }

    pub fn end(self: *Self) !void {
        const io = self.io_single.io();
        const elapsed = self.lap_start.durationTo(std.Io.Timestamp.now(io, .awake));
        var buf: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);

        try w.interface.print("Total duration: {f}\n\n", .{elapsed});
        try w.interface.flush();
    }

    pub fn deinit(self: *Self) void {
        self.graph.deinit();
        self.io_single.deinit();
    }
};

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Bench 1: atomic insertions (build phase only, no reverse index overhead).
    {
        var bench: Bench = try .init(
            allocator,
            "generate 1_000 hyperedges with 1_000 vertices each atomically",
            .{ .vertices_capacity = 1_000_000, .hyperedges_capacity = 1_000 },
        );
        defer bench.deinit();
        for (0..1_000) |_| {
            const h = try bench.graph.createHyperedge(.{});
            try bench.graph.reserveHyperedgeVertices(h, 1_000);
            for (0..1_000) |_| {
                const v = try bench.graph.createVertex(.{});
                try bench.graph.appendVertexToHyperedge(h, v);
            }
        }
        try bench.end();
    }

    // Bench 2: batch insertions (build phase only, no reverse index overhead).
    {
        var vertices: ArrayListUnmanaged(HypergraphZId) = try .initCapacity(allocator, 1_000);
        defer vertices.deinit(allocator);
        var bench: Bench = try .init(
            allocator,
            "generate 1_000 hyperedges with 1_000 vertices each in batches",
            .{ .vertices_capacity = 1_000_000, .hyperedges_capacity = 1_000 },
        );
        defer bench.deinit();
        for (0..1_000) |_| {
            vertices.clearRetainingCapacity();
            const h = try bench.graph.createHyperedgeAssumeCapacity(.{});
            for (0..1_000) |_| {
                const id = try bench.graph.createVertexAssumeCapacity(.{});
                try vertices.append(allocator, id);
            }
            try bench.graph.appendVerticesToHyperedge(h, vertices.items);
        }
        try bench.end();
    }

    // Bench 3: indegree queries.
    // Graph: 100 shared vertices each added to 1_000 hyperedges.
    // Each query iterates 1_000 hyperedges x 99 window pairs.
    {
        var bench: Bench = try .init(
            allocator,
            "query indegree for 100 vertices each in 1_000 hyperedges",
            .{ .vertices_capacity = 100, .hyperedges_capacity = 1_000 },
        );
        defer bench.deinit();

        // Setup (not timed): create 100 shared vertices and 1_000 hyperedges.
        var shared: [100]HypergraphZId = undefined;
        for (&shared) |*v| v.* = try bench.graph.createVertexAssumeCapacity(.{});
        for (0..1_000) |_| {
            const h = try bench.graph.createHyperedgeAssumeCapacity(.{});
            try bench.graph.appendVerticesToHyperedge(h, &shared);
        }
        try bench.graph.build();
        bench.resetTimer();

        for (shared) |v| {
            _ = try bench.graph.getVertexIndegree(v);
        }
        try bench.end();
    }

    // Bench 4: shortest path on a chain graph.
    // Graph: 1_000 vertices connected as v_0 -> v_1 -> ... -> v_999.
    // Finds path from first to last vertex.
    {
        var bench: Bench = try .init(
            allocator,
            "find shortest path across a chain of 1_000 vertices",
            .{ .vertices_capacity = 1_000, .hyperedges_capacity = 999 },
        );
        defer bench.deinit();

        // Setup (not timed): build the chain.
        var chain: [1_000]HypergraphZId = undefined;
        for (&chain) |*v| v.* = try bench.graph.createVertexAssumeCapacity(.{});
        for (0..999) |i| {
            const h = try bench.graph.createHyperedgeAssumeCapacity(.{});
            try bench.graph.appendVerticesToHyperedge(h, &.{ chain[i], chain[i + 1] });
        }
        try bench.graph.build();
        bench.resetTimer();

        var result = try bench.graph.findShortestPath(chain[0], chain[999]);
        result.deinit(allocator);
        try bench.end();
    }

    // Bench 5: build() on 1_000 hyperedges with 1_000 vertices each.
    {
        var bench: Bench = try .init(
            allocator,
            "build reverse index for 1_000 hyperedges with 1_000 vertices each",
            .{ .vertices_capacity = 1_000_000, .hyperedges_capacity = 1_000 },
        );
        defer bench.deinit();
        // Setup (not timed): create all vertices and hyperedges.
        for (0..1_000) |_| {
            const h = try bench.graph.createHyperedgeAssumeCapacity(.{});
            for (0..1_000) |_| {
                const v = try bench.graph.createVertexAssumeCapacity(.{});
                try bench.graph.appendVerticesToHyperedge(h, &.{v});
            }
        }
        bench.resetTimer();
        try bench.graph.build();
        try bench.end();
    }
}
