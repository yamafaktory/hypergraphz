//! Co-authorship network example.
//!
//! Models a small computer-science research community as a directed hypergraph:
//!   vertices   = researchers
//!   hyperedges = papers  (first listed author is the corresponding author,
//!                         which gives the hyperedge its natural direction)
//!
//! Two isolated communities are deliberately included so the output of
//! getConnectedComponents and findShortestPath is interesting.
//!
//! Run with:  zig build example

const std = @import("std");
const hg = @import("hypergraphz");

const HypergraphZId = hg.HypergraphZId;

// ── Domain types ─────────────────────────────────────────────────────────────

const Researcher = struct {
    name: []const u8,
};

/// weight = citation count (required by HypergraphZ for all hyperedge types).
const Paper = struct {
    title: []const u8,
    year: u16,
    weight: usize,
};

const Graph = hg.HypergraphZ(Paper, Researcher);

// ── Dual conversion helpers ───────────────────────────────────────────────────
// getDual swaps vertices ↔ hyperedges while keeping the same generic type.
// We carry names across by copying the string pointer.

fn paperToResearcher(p: Paper) Researcher {
    return .{ .name = p.title };
}

fn researcherToPaper(r: Researcher) Paper {
    return .{ .title = r.name, .year = 0, .weight = 1 };
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io_single: std.Io.Threaded = .init_single_threaded;
    defer io_single.deinit();
    const io = io_single.io();

    var g = try Graph.init(allocator, .{
        .vertices_capacity = 9,
        .hyperedges_capacity = 6,
    });
    defer g.deinit();

    // ── Build phase ───────────────────────────────────────────────────────────
    // Create all vertices and hyperedges first; build() is called once at the
    // end to construct the reverse index (vertex → papers) in a single pass.

    // Community A — systems researchers
    const alice = try g.createVertexAssumeCapacity(.{ .name = "Alice Chen" });
    const bob = try g.createVertexAssumeCapacity(.{ .name = "Bob Kumar" });
    const carol = try g.createVertexAssumeCapacity(.{ .name = "Carol Patel" });
    const dave = try g.createVertexAssumeCapacity(.{ .name = "Dave Martinez" });
    const eve = try g.createVertexAssumeCapacity(.{ .name = "Eve Johnson" });

    // Community B — ML researchers (no shared papers with community A)
    const frank = try g.createVertexAssumeCapacity(.{ .name = "Frank Lee" });
    const grace = try g.createVertexAssumeCapacity(.{ .name = "Grace Kim" });
    const henry = try g.createVertexAssumeCapacity(.{ .name = "Henry Okafor" });
    const iris = try g.createVertexAssumeCapacity(.{ .name = "Iris Wang" });

    // Papers — weight is the citation count
    const p1 = try g.createHyperedgeAssumeCapacity(.{ .title = "Distributed Consensus at Scale", .year = 2019, .weight = 142 });
    const p2 = try g.createHyperedgeAssumeCapacity(.{ .title = "Fault-Tolerant Replication", .year = 2020, .weight = 89 });
    const p3 = try g.createHyperedgeAssumeCapacity(.{ .title = "Scalable Distributed Joins", .year = 2021, .weight = 67 });
    const p4 = try g.createHyperedgeAssumeCapacity(.{ .title = "Neural Architecture Search", .year = 2020, .weight = 95 });
    const p5 = try g.createHyperedgeAssumeCapacity(.{ .title = "Optimization Landscapes", .year = 2021, .weight = 78 });
    const p6 = try g.createHyperedgeAssumeCapacity(.{ .title = "Hyperparameter Optimization", .year = 2022, .weight = 61 });

    // Authorship — append researchers in author-list order
    try g.appendVerticesToHyperedge(p1, &.{ alice, bob, carol }); // Community A
    try g.appendVerticesToHyperedge(p2, &.{ bob, carol, dave }); // Community A
    try g.appendVerticesToHyperedge(p3, &.{ alice, dave, eve }); // Community A
    try g.appendVerticesToHyperedge(p4, &.{ frank, grace, henry }); // Community B
    try g.appendVerticesToHyperedge(p5, &.{ grace, henry, iris }); // Community B
    try g.appendVerticesToHyperedge(p6, &.{ frank, iris }); // Community B

    // Build the reverse index once — switches the graph to query phase.
    try g.build();

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);

    // ── 1. Overview ───────────────────────────────────────────────────────────

    try w.interface.print("=== Co-authorship Network ===\n", .{});
    try w.interface.print("{} researchers, {} papers\n\n", .{ g.countVertices(), g.countHyperedges() });

    // ── 2. Papers per researcher ──────────────────────────────────────────────

    try w.interface.print("Papers per researcher\n", .{});
    for (g.getAllVertices()) |vid| {
        const r = try g.getVertex(vid);
        const papers = try g.getVertexHyperedges(vid);
        try w.interface.print("  {s:<16} {}\n", .{ r.name, papers.len });
    }
    try w.interface.print("\n", .{});

    // ── 3. Research communities ───────────────────────────────────────────────
    // Weakly-connected components reveal which researchers have ever shared a paper.

    try w.interface.print("Research communities\n", .{});
    var components = try g.getConnectedComponents();
    defer components.deinit(allocator);
    for (components.data.items, 1..) |component, i| {
        try w.interface.print("  Community {}:", .{i});
        for (component) |vid| {
            try w.interface.print(" {s}", .{(try g.getVertex(vid)).name});
        }
        try w.interface.print("\n", .{});
    }
    try w.interface.print("\n", .{});

    // ── 4. Betweenness centrality ─────────────────────────────────────────────
    // Researchers with high betweenness sit on many shortest collaboration paths —
    // they act as bridges between otherwise-distant colleagues.

    try w.interface.print("Betweenness centrality\n", .{});
    var centrality = try g.computeCentrality();
    defer centrality.deinit(allocator);

    const ScoreEntry = struct { vid: HypergraphZId, score: f64 };
    var scores: std.ArrayListUnmanaged(ScoreEntry) = .empty;
    defer scores.deinit(allocator);
    for (g.getAllVertices()) |vid| {
        try scores.append(allocator, .{ .vid = vid, .score = centrality.data.get(vid).?.betweenness });
    }
    std.mem.sort(ScoreEntry, scores.items, {}, struct {
        fn desc(_: void, a: ScoreEntry, b: ScoreEntry) bool {
            return a.score > b.score;
        }
    }.desc);
    for (scores.items) |entry| {
        try w.interface.print("  {s:<16} {d:.3}\n", .{ (try g.getVertex(entry.vid)).name, entry.score });
    }
    try w.interface.print("\n", .{});

    // ── 5. Degrees of separation ──────────────────────────────────────────────
    // findShortestPath follows directed edges (corresponding author → co-authors).
    // Researchers in different communities have no path between them.

    try w.interface.print("Degrees of separation\n", .{});
    const pairs = [_][2]HypergraphZId{
        .{ alice, dave }, // consecutive in p3                              → 1 hop
        .{ alice, carol }, // alice→bob (p1), bob→carol (p1)                → 2 hops
        .{ bob, eve }, // bob→carol (p1), carol→dave (p2), dave→eve (p3) → 3 hops
        .{ alice, frank }, // different community                            → unreachable
    };
    for (pairs) |pair| {
        const from = (try g.getVertex(pair[0])).name;
        const to = (try g.getVertex(pair[1])).name;
        var path = try g.findShortestPath(pair[0], pair[1]);
        defer path.deinit(allocator);
        if (path.data) |p| {
            try w.interface.print("  {s} → {s}: {} hop(s)\n", .{ from, to, p.items.len - 1 });
        } else {
            try w.interface.print("  {s} → {s}: unreachable (different community)\n", .{ from, to });
        }
    }
    try w.interface.print("\n", .{});

    // ── 6. Dual: paper-centric view ───────────────────────────────────────────
    // In the dual, vertices = papers and hyperedges = researchers.
    // Each researcher-hyperedge connects all the papers they co-authored,
    // making it easy to ask "which papers does person X link together?".

    try w.interface.print("Dual (paper-centric view)\n", .{});
    var dual = try g.getDual(paperToResearcher, researcherToPaper);
    defer dual.deinit();
    try dual.build();
    try w.interface.print("  {} paper-vertices, {} researcher-hyperedges\n\n", .{
        dual.countVertices(),
        dual.countHyperedges(),
    });
    // In the dual: hyperedge data is Paper type (carrying researcher name in .title),
    // and vertex data is Researcher type (carrying paper title in .name).
    for (dual.getAllHyperedges()) |hid| {
        const researcher_name = (try dual.getHyperedge(hid)).title;
        try w.interface.print("  {s}:", .{researcher_name});
        for (try dual.getHyperedgeVertices(hid)) |pvid| {
            try w.interface.print(" \"{s}\"", .{(try dual.getVertex(pvid)).name});
        }
        try w.interface.print("\n", .{});
    }

    // ── 7. Shared authorship ──────────────────────────────────────────────────
    // getIntersections finds vertices present in ALL given hyperedges — there is
    // no direct equivalent in a regular graph, where you would need a join.

    try w.interface.print("Shared authorship\n", .{});
    const shared = try g.getIntersections(&.{ p1, p2 });
    defer g.allocator.free(shared);
    try w.interface.print(
        "  Researchers on both \"{s}\" and \"{s}\":\n",
        .{ (try g.getHyperedge(p1)).title, (try g.getHyperedge(p2)).title },
    );
    for (shared) |vid| {
        try w.interface.print("    {s}\n", .{(try g.getVertex(vid)).name});
    }
    try w.interface.print("\n", .{});

    // ── 8. Authorship seniority ordering ──────────────────────────────────────
    // The directed structure (corresponding author → co-authors via consecutive
    // pairs) implies a partial order. topologicalSort makes it total.

    try w.interface.print("Authorship seniority ordering (topological)\n", .{});
    const order = try g.topologicalSort();
    defer g.allocator.free(order);
    for (order) |vid| {
        try w.interface.print("  {s}\n", .{(try g.getVertex(vid)).name});
    }
    try w.interface.print("\n", .{});

    // ── 9. Pairwise expansion ─────────────────────────────────────────────────
    // expandToGraph replaces each hyperedge [a, b, c] with consecutive pairs
    // (a,b) and (b,c). The jump in hyperedge count shows how much information
    // a hypergraph encodes that a regular directed graph cannot.

    try w.interface.print("Pairwise expansion\n", .{});
    var expanded = try g.expandToGraph();
    defer expanded.deinit();
    try expanded.build();
    try w.interface.print(
        "  {} papers → {} directed co-author pairs\n",
        .{ g.countHyperedges(), expanded.countHyperedges() },
    );

    try w.interface.flush();
}
