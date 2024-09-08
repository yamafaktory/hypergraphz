//! Benchmarks for HypergraphZ.

const std = @import("std");
const uuid = @import("uuid");
const hypergraphz = @import("hypergraphz.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const HypergraphZ = hypergraphz.HypergraphZ;
const Timer = std.time.Timer;
const Uuid = uuid.Uuid;
const comptimePrint = std.fmt.comptimePrint;
const fmtDuration = std.fmt.fmtDuration;
const getStdOut = std.io.getStdOut;
const Writer = std.fs.File.Writer;

const Hyperedge = struct { weight: usize = 1 };
const Vertex = struct {};

const Bench = struct {
    const Self = @This();

    graph: HypergraphZ(Hyperedge, Vertex),
    start: u64,
    stdout: Writer,
    timer: Timer,

    pub fn init(allocator: Allocator, stdout: Writer, comptime name: []const u8) !Self {
        const graph = try HypergraphZ(
            Hyperedge,
            Vertex,
        ).init(allocator, .{ .vertices_capacity = 1_000_000, .hyperedges_capacity = 1_000 });
        const msg = comptime comptimePrint("{s}...\n", .{name});
        try stdout.print(msg, .{});
        var timer = try Timer.start();

        return .{ .timer = timer, .start = timer.lap(), .stdout = stdout, .graph = graph };
    }

    pub fn end(self: *Self) !void {
        try self.stdout.print("Total duration: {}\n", .{fmtDuration(self.timer.read() - self.start)});
    }

    pub fn deinit(self: *Self) void {
        self.graph.deinit();
    }
};

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const stdout = getStdOut().writer();

    {
        var bench = try Bench.init(allocator, stdout, "generate 1_000 hyperedges with 1_000 vertices each atomically");
        for (0..1_000) |_| {
            const h = try bench.graph.createHyperedge(.{});
            for (0..1_000) |_| {
                const v = try bench.graph.createVertex(.{});
                try bench.graph.appendVertexToHyperedge(h, v);
            }
        }
        try bench.end();
        defer bench.deinit();
    }

    {
        var vertices = try ArrayList(Uuid).initCapacity(allocator, 1_000);
        defer vertices.deinit();
        var bench = try Bench.init(allocator, stdout, "generate 1_000 hyperedges with 1_000 vertices each in batches");
        for (0..1_000) |_| {
            vertices.clearRetainingCapacity();
            const h = bench.graph.createHyperedgeAssumeCapacity(.{});
            for (0..1_000) |_| {
                const id = bench.graph.createVertexAssumeCapacity(.{});
                try vertices.append(id);
            }
            try bench.graph.appendVerticesToHyperedge(h, vertices.items);
        }
        try bench.end();
        defer bench.deinit();
    }
}
