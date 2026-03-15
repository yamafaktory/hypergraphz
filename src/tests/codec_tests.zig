const std = @import("std");
const h = @import("helpers.zig");

const HypergraphZ = h.HypergraphZ;
const HypergraphZId = h.HypergraphZId;
const HypergraphZError = h.HypergraphZError;
const Hyperedge = h.Hyperedge;
const Vertex = h.Vertex;
const Graph = h.Graph;
const expect = h.expect;
const expectError = h.expectError;

// Helpers for default codec wrappers.
fn serializeH(val: Hyperedge, writer: *std.Io.Writer) !void {
    try Graph.defaultSerialize(Hyperedge, val, writer);
}
fn serializeV(val: Vertex, writer: *std.Io.Writer) !void {
    try Graph.defaultSerialize(Vertex, val, writer);
}
fn deserializeH(reader: *std.Io.Reader) !Hyperedge {
    return Graph.defaultDeserialize(Hyperedge, reader);
}
fn deserializeV(reader: *std.Io.Reader) !Vertex {
    return Graph.defaultDeserialize(Vertex, reader);
}

test "codec: round-trip pointer-free types with default codec" {
    const alloc = std.testing.allocator;

    var graph = try Graph.init(alloc, .{});
    defer graph.deinit();

    const v_a = try graph.createVertex(.{ .purr = true });
    const v_b = try graph.createVertex(.{ .purr = false });
    const h_a = try graph.createHyperedge(.{ .meow = true, .weight = 42 });
    try graph.appendVerticesToHyperedge(h_a, &.{ v_a, v_b });
    try graph.build();

    // Serialize to buffer.
    var buf_w = std.Io.Writer.Allocating.init(alloc);
    defer buf_w.deinit();
    try graph.save(&buf_w.writer, serializeH, serializeV);
    const buf = buf_w.writer.buffer[0..buf_w.writer.end];

    // Deserialize from buffer.
    var r = std.Io.Reader.fixed(buf);
    var loaded = try Graph.load(alloc, &r, deserializeH, deserializeV);
    defer loaded.deinit();
    try loaded.build();

    try expect(loaded.vertices.count() == 2);
    try expect(loaded.hyperedges.count() == 1);

    // Payload values match.
    const lv_a = loaded.vertices.get(v_a).?.data.*;
    const lv_b = loaded.vertices.get(v_b).?.data.*;
    try expect(lv_a.purr == true);
    try expect(lv_b.purr == false);

    const lh_a = loaded.hyperedges.get(h_a).?.data.*;
    try expect(lh_a.meow == true);
    try expect(lh_a.weight == 42);
}

test "codec: round-trip type with pointer field using custom codec" {
    const alloc = std.testing.allocator;

    // SliceVertex owns heap data ([]const u8) so the default codec cannot be used;
    // a custom serialize/deserialize pair is required.
    const SliceVertex = struct { name: []const u8 };
    const FlatEdge = struct { weight: u32 };
    const NPGraph = HypergraphZ(FlatEdge, SliceVertex, .{});

    const serNPH = struct {
        fn f(val: FlatEdge, writer: *std.Io.Writer) !void {
            try NPGraph.defaultSerialize(FlatEdge, val, writer);
        }
    }.f;
    const serNPV = struct {
        fn f(val: SliceVertex, writer: *std.Io.Writer) !void {
            try writer.writeInt(u32, @intCast(val.name.len), .little);
            try writer.writeAll(val.name);
        }
    }.f;
    const deserNPH = struct {
        fn f(reader: *std.Io.Reader) !FlatEdge {
            return NPGraph.defaultDeserialize(FlatEdge, reader);
        }
    }.f;
    const deserNPV = struct {
        fn f(reader: *std.Io.Reader) !SliceVertex {
            const len = try reader.takeInt(u32, .little);
            const name_buf = try std.testing.allocator.alloc(u8, len);
            try reader.readSliceAll(name_buf);
            return .{ .name = name_buf };
        }
    }.f;

    var graph = try NPGraph.init(alloc, .{});
    defer graph.deinit();

    const v1 = try graph.createVertex(.{ .name = "hello" });
    const v2 = try graph.createVertex(.{ .name = "world" });
    const e1 = try graph.createHyperedge(.{ .weight = 7 });
    try graph.appendVerticesToHyperedge(e1, &.{ v1, v2 });
    try graph.build();

    var buf_w = std.Io.Writer.Allocating.init(alloc);
    defer buf_w.deinit();
    try graph.save(&buf_w.writer, serNPH, serNPV);
    const buf = buf_w.writer.buffer[0..buf_w.writer.end];

    var r = std.Io.Reader.fixed(buf);
    var loaded = try NPGraph.load(alloc, &r, deserNPH, deserNPV);
    try loaded.build();
    defer {
        // Free the heap-allocated name slices before deinit.
        var it = loaded.vertices.iterator();
        while (it.next()) |kv| {
            alloc.free(kv.value_ptr.data.name);
        }
        loaded.deinit();
    }

    try expect(loaded.vertices.count() == 2);
    try expect(loaded.hyperedges.count() == 1);

    const ln1 = loaded.vertices.get(v1).?.data.name;
    const ln2 = loaded.vertices.get(v2).?.data.name;
    try std.testing.expectEqualStrings("hello", ln1);
    try std.testing.expectEqualStrings("world", ln2);
    try expect(loaded.hyperedges.get(e1).?.data.weight == 7);
}

test "codec: empty graph" {
    const alloc = std.testing.allocator;

    var graph = try Graph.init(alloc, .{});
    defer graph.deinit();
    try graph.build();

    var buf_w = std.Io.Writer.Allocating.init(alloc);
    defer buf_w.deinit();
    try graph.save(&buf_w.writer, serializeH, serializeV);
    const buf = buf_w.writer.buffer[0..buf_w.writer.end];

    var r = std.Io.Reader.fixed(buf);
    var loaded = try Graph.load(alloc, &r, deserializeH, deserializeV);
    defer loaded.deinit();
    try loaded.build();

    try expect(loaded.vertices.count() == 0);
    try expect(loaded.hyperedges.count() == 0);
}

test "codec: load returns build-phase graph, queries work after build" {
    const alloc = std.testing.allocator;

    var graph = try Graph.init(alloc, .{});
    defer graph.deinit();

    const v_a = try graph.createVertex(.{});
    const v_b = try graph.createVertex(.{});
    const h_a = try graph.createHyperedge(.{});
    try graph.appendVerticesToHyperedge(h_a, &.{ v_a, v_b });
    try graph.build();

    var buf_w = std.Io.Writer.Allocating.init(alloc);
    defer buf_w.deinit();
    try graph.save(&buf_w.writer, serializeH, serializeV);
    const buf = buf_w.writer.buffer[0..buf_w.writer.end];

    var r = std.Io.Reader.fixed(buf);
    var loaded = try Graph.load(alloc, &r, deserializeH, deserializeV);
    defer loaded.deinit();

    // Before build(), query ops that require the reverse index must return NotBuilt.
    try expectError(HypergraphZError.NotBuilt, loaded.getVertexIndegree(v_b));

    try loaded.build();

    // After build(), queries work. v_b is the tail of pair (v_a, v_b) so indegree is 1.
    const degree = try loaded.getVertexIndegree(v_b);
    try expect(degree == 1);
}

test "codec: invalid magic" {
    const alloc = std.testing.allocator;

    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var r = std.Io.Reader.fixed(&garbage);
    try expectError(
        HypergraphZError.InvalidMagicNumber,
        Graph.load(alloc, &r, deserializeH, deserializeV),
    );
}

test "codec: unsupported version" {
    const alloc = std.testing.allocator;

    // Build a valid header but with version = 2.
    var graph = try Graph.init(alloc, .{});
    defer graph.deinit();
    try graph.build();

    var buf_w = std.Io.Writer.Allocating.init(alloc);
    defer buf_w.deinit();
    try graph.save(&buf_w.writer, serializeH, serializeV);

    // Patch version byte (offset 4 in the header).
    buf_w.writer.buffer[4] = 2;

    const buf = buf_w.writer.buffer[0..buf_w.writer.end];
    var r = std.Io.Reader.fixed(buf);
    try expectError(
        HypergraphZError.UnsupportedVersion,
        Graph.load(alloc, &r, deserializeH, deserializeV),
    );
}

test "codec: round-trip through a real file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var graph = try Graph.init(alloc, .{});
    defer graph.deinit();

    const v_a = try graph.createVertex(.{ .purr = true });
    const v_b = try graph.createVertex(.{ .purr = false });
    const h_a = try graph.createHyperedge(.{ .meow = true, .weight = 7 });
    try graph.appendVerticesToHyperedge(h_a, &.{ v_a, v_b });
    try graph.build();

    // Write to file.
    {
        const file = try tmp.dir.createFile(io, "graph.bin", .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        try graph.save(&fw.interface, serializeH, serializeV);
        try fw.interface.flush();
    }

    // Read from file.
    var loaded = loaded: {
        const file = try tmp.dir.openFile(io, "graph.bin", .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fr = file.reader(io, &buf);
        break :loaded try Graph.load(alloc, &fr.interface, deserializeH, deserializeV);
    };
    defer loaded.deinit();
    try loaded.build();

    try expect(loaded.vertices.count() == 2);
    try expect(loaded.hyperedges.count() == 1);
    try expect(loaded.vertices.get(v_a).?.data.purr == true);
    try expect(loaded.vertices.get(v_b).?.data.purr == false);
    try expect(loaded.hyperedges.get(h_a).?.data.meow == true);
    try expect(loaded.hyperedges.get(h_a).?.data.weight == 7);
}
