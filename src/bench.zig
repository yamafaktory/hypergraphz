//! Benchmarks for HypergraphZ.

const std = @import("std");
const hypergraphz = @import("hypergraphz.zig");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const HypergraphZ = hypergraphz.HypergraphZ;
const HypergraphZId = hypergraphz.HypergraphZId;
const Timer = std.time.Timer;
const Writer = std.Io.Writer;
const comptimePrint = std.fmt.comptimePrint;

const Hyperedge = struct { weight: usize = 1 };
const Vertex = struct {};

const Bench = struct {
    const Self = @This();

    graph: HypergraphZ(Hyperedge, Vertex),
    start: u64,
    stdout: *Writer,
    timer: Timer,

    pub fn init(allocator: Allocator, comptime name: []const u8) !Self {
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        const graph = try HypergraphZ(
            Hyperedge,
            Vertex,
        ).init(allocator, .{ .vertices_capacity = 1_000_000, .hyperedges_capacity = 1_000 });
        const msg = comptime comptimePrint("{s}...\n", .{name});
        try stdout.print(msg, .{});
        try stdout.flush();
        var timer = try Timer.start();

        return .{ .timer = timer, .start = timer.lap(), .stdout = stdout, .graph = graph };
    }

    pub fn end(self: *Self) !void {
        try self.stdout.print("Total duration: {D}\n", .{self.timer.read() - self.start});
        try self.stdout.flush();
    }

    pub fn deinit(self: *Self) !void {
        self.graph.deinit();
    }
};

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    {
        var bench: Bench = try .init(allocator, "generate 1_000 hyperedges with 1_000 vertices each atomically");
        for (0..1_000) |_| {
            const h = try bench.graph.createHyperedge(.{});
            for (0..1_000) |_| {
                const v = try bench.graph.createVertex(.{});
                try bench.graph.appendVertexToHyperedge(h, v);
            }
        }
        try bench.end();
        defer {
            bench.deinit() catch |err| {
                std.debug.print("error during cleanup: {}", .{err});
            };
        }
    }

    {
        var vertices: ArrayListUnmanaged(HypergraphZId) = try .initCapacity(allocator, 1_000);
        defer vertices.deinit(allocator);
        var bench: Bench = try .init(allocator, "generate 1_000 hyperedges with 1_000 vertices each in batches");
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

        defer {
            bench.deinit() catch |err| {
                std.debug.print("error during cleanup: {}", .{err});
            };
        }
    }
}
