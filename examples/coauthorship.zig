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

const Paper = struct {
    title: []const u8,
    year: u16,
    citations: usize,
};

// Use "citations" as the weight field for findShortestPath instead of the
// default "weight", which lets the Paper type use a domain-appropriate name.
const Graph = hg.HypergraphZ(Paper, Researcher, .{ .weight_field = "citations" });

// ── Dual conversion helpers ───────────────────────────────────────────────────
// getDual swaps vertices ↔ hyperedges while keeping the same generic type.
// We carry names across by copying the string pointer.

fn paperToResearcher(p: Paper) Researcher {
    return .{ .name = p.title };
}

fn researcherToPaper(r: Researcher) Paper {
    return .{ .title = r.name, .year = 0, .citations = 1 };
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
    const p1 = try g.createHyperedgeAssumeCapacity(.{ .title = "Distributed Consensus at Scale", .year = 2019, .citations = 142 });
    const p2 = try g.createHyperedgeAssumeCapacity(.{ .title = "Fault-Tolerant Replication", .year = 2020, .citations = 89 });
    const p3 = try g.createHyperedgeAssumeCapacity(.{ .title = "Scalable Distributed Joins", .year = 2021, .citations = 67 });
    const p4 = try g.createHyperedgeAssumeCapacity(.{ .title = "Neural Architecture Search", .year = 2020, .citations = 95 });
    const p5 = try g.createHyperedgeAssumeCapacity(.{ .title = "Optimization Landscapes", .year = 2021, .citations = 78 });
    const p6 = try g.createHyperedgeAssumeCapacity(.{ .title = "Hyperparameter Optimization", .year = 2022, .citations = 61 });

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
    var scores: std.ArrayList(ScoreEntry) = .empty;
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
    // findShortestPath follows directed hyperedges (corresponding author → co-authors).
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
        "  {} papers → {} directed co-author pairs\n\n",
        .{ g.countHyperedges(), expanded.countHyperedges() },
    );

    // ── 10. Spectral view ─────────────────────────────────────────────────────
    // The hypergraph Laplacian (Zhou et al. 2006; Feng et al. HGNN 2019) encodes
    // connectivity in an n×n matrix. With two disjoint communities the result
    // is block-diagonal: every cell linking a community-A researcher to a
    // community-B researcher is exactly zero. See `toLaplacian` docs for the
    // formula and references.

    try w.interface.print("Spectral view (normalized Laplacian)\n", .{});
    var lap = try g.toLaplacian(allocator, .{ .variant = .normalized_zhou });
    defer lap.deinit(allocator);

    // Header row: 2-letter prefix of each researcher's name, aligned over the columns.
    try w.interface.print("                ", .{});
    for (lap.vertex_ids) |vid| {
        const name = (try g.getVertex(vid)).name;
        try w.interface.print(" {s:>6}", .{name[0..@min(name.len, 2)]});
    }
    try w.interface.print("\n", .{});

    for (lap.vertex_ids, 0..) |vid, i| {
        const name = (try g.getVertex(vid)).name;
        try w.interface.print("  {s:<14}", .{name});
        for (0..lap.n) |j| {
            // Normalize tiny values (incl. IEEE signed zero) to +0 for readability.
            const v = lap.at(i, j);
            const shown: f64 = if (@abs(v) < 1e-12) 0.0 else v;
            try w.interface.print(" {d:6.2}", .{shown});
        }
        try w.interface.print("\n", .{});
    }
    try w.interface.print("\n", .{});

    // ── 11. PageRank ──────────────────────────────────────────────────────────
    // PageRank ranks researchers by stationary probability of the citation-
    // weighted random walk: each step picks an incident paper proportional to
    // its citation count, then a co-author uniformly. Highly-cited papers thus
    // pull mass toward their authors.

    try w.interface.print("PageRank (citation-weighted random walk)\n", .{});
    var pr = try g.computePageRank(.{});
    defer pr.deinit(allocator);

    const PrEntry = struct { vid: HypergraphZId, score: f64 };
    var prs: std.ArrayList(PrEntry) = .empty;
    defer prs.deinit(allocator);
    var pr_it = pr.data.iterator();
    while (pr_it.next()) |kv| try prs.append(allocator, .{ .vid = kv.key_ptr.*, .score = kv.value_ptr.* });
    std.mem.sort(PrEntry, prs.items, {}, struct {
        fn desc(_: void, a: PrEntry, b: PrEntry) bool {
            return a.score > b.score;
        }
    }.desc);
    for (prs.items) |entry| {
        try w.interface.print("  {s:<16} {d:.4}\n", .{ (try g.getVertex(entry.vid)).name, entry.score });
    }
    try w.interface.print("  ({} iterations, converged={})\n\n", .{ pr.iterations, pr.converged });

    // ── 12. Random walk ───────────────────────────────────────────────────────
    // A short walk from Alice. With a fixed seed the trace is deterministic.
    // Hops happen via co-authored papers, so the walk never crosses into the
    // ML community.

    try w.interface.print("Random walk from Alice (12 steps)\n", .{});
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const walk = try g.randomWalk(alice, 12, prng.random());
    defer allocator.free(walk);
    try w.interface.print("  ", .{});
    for (walk, 0..) |vid, i| {
        if (i > 0) try w.interface.print(" → ", .{});
        try w.interface.print("{s}", .{(try g.getVertex(vid)).name});
    }
    try w.interface.print("\n\n", .{});

    // ── 13. Star expansion ────────────────────────────────────────────────────
    // Each paper becomes a "hub" vertex connected to its authors. The result is
    // a 2-uniform bipartite graph: researchers ↔ papers. Useful for algorithms
    // that expect plain graphs while keeping hyperedge identity intact.

    try w.interface.print("Star expansion\n", .{});
    var star = try g.expandToStar(paperToResearcher);
    defer star.deinit();
    try star.build();
    try w.interface.print(
        "  {} researchers + {} papers → {} bipartite vertices, {} author-paper pairs\n\n",
        .{ g.countVertices(), g.countHyperedges(), star.countVertices(), star.countHyperedges() },
    );

    // ── 14. Line graph ────────────────────────────────────────────────────────
    // In the line graph, papers become vertices and two papers are linked iff
    // they share an author. Disjoint communities of authors give disjoint
    // components in the line graph too.

    try w.interface.print("Line graph (papers linked by shared authors)\n", .{});
    var line = try g.getLineGraph(
        paperToResearcher,
        .{ .title = "(co-authored)", .year = 0, .citations = 1 },
    );
    defer line.deinit();
    try line.build();
    try w.interface.print(
        "  {} papers → {} paper-pair links\n",
        .{ g.countHyperedges(), line.countHyperedges() },
    );
    var line_components = try line.getConnectedComponents();
    defer line_components.deinit(allocator);
    try w.interface.print("  {} components in the line graph\n\n", .{line_components.data.items.len});

    // ── 15. K-core decomposition ──────────────────────────────────────────────
    // The (s, t)-core peels vertices with fewer than `s` incident hyperedges
    // and hyperedges with fewer than `t` distinct vertices, iterating to a
    // fixed point. Eve has only one paper, so the (2, 2)-core peels her out;
    // the rest of the network — every other researcher has ≥ 2 co-authored
    // papers — survives intact.

    try w.interface.print("K-core decomposition\n", .{});
    var core22 = try g.getCore(2, 2);
    defer core22.deinit();
    try core22.build();
    try w.interface.print(
        "  Original:   {} researchers, {} papers\n",
        .{ g.countVertices(), g.countHyperedges() },
    );
    try w.interface.print(
        "  (2,2)-core: {} researchers, {} papers\n",
        .{ core22.countVertices(), core22.countHyperedges() },
    );
    try w.interface.print("  Peeled:    ", .{});
    var peeled_any = false;
    for (g.getAllVertices()) |vid| {
        core22.checkIfVertexExists(vid) catch {
            if (peeled_any) try w.interface.print(", ", .{});
            try w.interface.print("{s}", .{(try g.getVertex(vid)).name});
            peeled_any = true;
        };
    }
    if (!peeled_any) try w.interface.print("(none)", .{});
    try w.interface.print("\n\n", .{});

    // ── 16. Nestedness ────────────────────────────────────────────────────────
    // Inclusion / nestedness asks whether one hyperedge's distinct vertex set
    // is strictly contained in another's. Common in preprint→conference→
    // journal authorship chains, ecological niches, and ER drug combinations
    // (Hood, De Bacco & Schein, Nat. Commun. 2026, Fig. 5b). The co-authorship
    // dataset above is flat — every paper has at least one author no other
    // paper has — so we demonstrate on a small inline preprint-style chain.

    try w.interface.print("Nestedness\n", .{});
    var main_inc = try g.getInclusions();
    defer main_inc.deinit(allocator);
    try w.interface.print("  Co-authorship dataset: {} strict-subset pair(s)\n", .{main_inc.data.len});

    {
        var mini = try Graph.init(allocator, .{
            .vertices_capacity = 4,
            .hyperedges_capacity = 3,
        });
        defer mini.deinit();
        const a = try mini.createVertexAssumeCapacity(.{ .name = "Aria" });
        const b = try mini.createVertexAssumeCapacity(.{ .name = "Bo" });
        const c = try mini.createVertexAssumeCapacity(.{ .name = "Cy" });
        const d = try mini.createVertexAssumeCapacity(.{ .name = "Dee" });
        const draft = try mini.createHyperedgeAssumeCapacity(.{ .title = "Draft", .year = 2024, .citations = 1 });
        try mini.appendVerticesToHyperedge(draft, &.{ a, b });
        const conf = try mini.createHyperedgeAssumeCapacity(.{ .title = "Conference", .year = 2025, .citations = 1 });
        try mini.appendVerticesToHyperedge(conf, &.{ a, b, c });
        const journal = try mini.createHyperedgeAssumeCapacity(.{ .title = "Journal", .year = 2026, .citations = 1 });
        try mini.appendVerticesToHyperedge(journal, &.{ a, b, c, d });
        try mini.build();

        var inc = try mini.getInclusions();
        defer inc.deinit(allocator);
        try w.interface.print("  Synthetic chain (Draft ⊊ Conference ⊊ Journal): {} pair(s)\n", .{inc.data.len});
        for (inc.data) |rel| {
            const sub_t = (try mini.getHyperedge(rel.subset)).title;
            const sup_t = (try mini.getHyperedge(rel.superset)).title;
            try w.interface.print("    \"{s}\" ⊊ \"{s}\"\n", .{ sub_t, sup_t });
        }

        var prof = try mini.getNestednessProfile();
        defer prof.deinit(allocator);
        try w.interface.print("  Per-order profile:\n", .{});
        for (prof.data) |entry| {
            try w.interface.print("    size {}: {}/{} included\n", .{
                entry.size, entry.included, entry.total,
            });
        }
    }
    try w.interface.print("\n", .{});

    // ── 17. Co-author neighborhoods ───────────────────────────────────────────
    // getVertexNeighborhood returns the (undirected) set of vertices sharing
    // at least one hyperedge with the given vertex — here, every researcher's
    // direct collaborators across all their papers, regardless of author-list
    // position. Distinct from getVertexAdjacencyTo / getVertexAdjacencyFrom,
    // which follow the directed (corresponding-author → co-author) window pairs.

    try w.interface.print("Co-author neighborhoods\n", .{});
    for (g.getAllVertices()) |vid| {
        const name = (try g.getVertex(vid)).name;
        const ns = try g.getVertexNeighborhood(vid);
        defer allocator.free(ns);
        try w.interface.print("  {s:<16}", .{name});
        for (ns, 0..) |nid, i| {
            try w.interface.print("{s}{s}", .{
                if (i == 0) "" else ", ",
                (try g.getVertex(nid)).name,
            });
        }
        if (ns.len == 0) try w.interface.print("(none)", .{});
        try w.interface.print("\n", .{});
    }
    try w.interface.print("\n", .{});

    // ── 18. Cut vertices (articulation points) ────────────────────────────────
    // A cut vertex is a researcher whose removal would split the collaboration
    // network into disconnected components — a structural single point of failure.
    // findCutVertices uses clique-expansion adjacency: two researchers are
    // neighbours if they share any paper, regardless of author-list position.

    try w.interface.print("Cut vertices (articulation points)\n", .{});
    const cuts = try g.findCutVertices();
    defer allocator.free(cuts);
    if (cuts.len == 0) {
        try w.interface.print("  Main network: none — resilient to any single researcher departing\n", .{});
    } else {
        for (cuts) |vid| try w.interface.print("  {s}\n", .{(try g.getVertex(vid)).name});
    }

    // Synthetic chain: Ana – Bek – Cy – {Dan, Eli}.
    // Bek bridges Ana to the rest; Cy bridges {Ana, Bek} to {Dan, Eli}.
    {
        var chain_graph = try Graph.init(allocator, .{
            .vertices_capacity = 5,
            .hyperedges_capacity = 3,
        });
        defer chain_graph.deinit();
        const ana = try chain_graph.createVertexAssumeCapacity(.{ .name = "Ana" });
        const bek = try chain_graph.createVertexAssumeCapacity(.{ .name = "Bek" });
        const cy = try chain_graph.createVertexAssumeCapacity(.{ .name = "Cy" });
        const dan = try chain_graph.createVertexAssumeCapacity(.{ .name = "Dan" });
        const eli = try chain_graph.createVertexAssumeCapacity(.{ .name = "Eli" });
        const q1 = try chain_graph.createHyperedgeAssumeCapacity(.{ .title = "Ana-Bek collab", .year = 2022, .citations = 1 });
        try chain_graph.appendVerticesToHyperedge(q1, &.{ ana, bek });
        const q2 = try chain_graph.createHyperedgeAssumeCapacity(.{ .title = "Bek-Cy collab", .year = 2023, .citations = 1 });
        try chain_graph.appendVerticesToHyperedge(q2, &.{ bek, cy });
        const q3 = try chain_graph.createHyperedgeAssumeCapacity(.{ .title = "Cy-Dan-Eli collab", .year = 2024, .citations = 1 });
        try chain_graph.appendVerticesToHyperedge(q3, &.{ cy, dan, eli });
        try chain_graph.build();

        const chain_cuts = try chain_graph.findCutVertices();
        defer allocator.free(chain_cuts);
        try w.interface.print("  Synthetic chain (Ana-Bek-Cy-{{Dan,Eli}}): {} cut vertex(es):", .{chain_cuts.len});
        for (chain_cuts) |vid| try w.interface.print(" {s}", .{(try chain_graph.getVertex(vid)).name});
        try w.interface.print("\n", .{});
    }
    try w.interface.print("\n", .{});

    try w.interface.flush();
}
