//! Benchmarks for HyperZig.

const std = @import("std");
const HyperZig = @import("hyperzig.zig").HyperZig;

const Allocator = std.mem.Allocator;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const Timer = std.time.Timer;
const comptimePrint = std.fmt.comptimePrint;
const fmtDuration = std.fmt.fmtDuration;
const getStdOut = std.io.getStdOut;
const Writer = std.fs.File.Writer;

const Hyperedge = struct { weight: usize = 1 };
const Vertex = struct {};

const Bench = struct {
    const Self = @This();

    graph: HyperZig(Hyperedge, Vertex),
    start: u64,
    stdout: Writer,
    timer: Timer,

    pub fn init(allocator: Allocator, stdout: Writer, comptime name: []const u8) !Self {
        const graph = try HyperZig(
            Hyperedge,
            Vertex,
        ).init(allocator, .{});
        const msg = comptime comptimePrint("{s}...\n", .{name});
        try stdout.print(msg, .{});
        var timer = try Timer.start();

        return .{ .timer = timer, .start = timer.lap(), .stdout = stdout, .graph = graph };
    }

    pub fn deinit(self: *Self) !void {
        try self.stdout.print("Total duration: {s}\n", .{fmtDuration(self.timer.read() - self.start)});
        self.graph.deinit();
    }
};

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const stdout = getStdOut().writer();

    {
        var bench = try Bench.init(allocator, stdout, "generate 1_000 hyperedges with 1_000 vertices each");
        for (0..1_000) |_| {
            const h = try bench.graph.createHyperedge(.{});

            for (0..1_000) |_| {
                const v = try bench.graph.createVertex(.{});
                try bench.graph.appendVertexToHyperedge(h, v);
            }
        }
        try bench.deinit();
    }
}
