# HypergraphZ - A Hypergraph Implementation in Zig

![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/yamafaktory/hypergraphz/ci.yml?branch=main&style=flat-square)

HypergraphZ is a directed hypergraph implementation in Zig (https://en.wikipedia.org/wiki/Hypergraph):

- Each hyperedge can contain zero, one (unary) or multiple vertices.
- Each hyperedge can contain vertices directed to themselves one or more times.

---

## For Python users

### Installation

```sh
pip install hypergraphz
# or with uv
uv add hypergraphz
```

Pre-built wheels are available for Linux (x86\_64, aarch64), macOS (x86\_64, arm64), and Windows (x86\_64).

### Quick start

```python
from hypergraphz import Hypergraph

g = Hypergraph()

# Add vertices and hyperedges
alice = g.add_vertex({"name": "alice", "age": 30})
bob   = g.add_vertex({"name": "bob",   "age": 25})
carol = g.add_vertex({"name": "carol", "age": 35})

collab = g.add_hyperedge({"type": "project"})
g.connect(collab, [alice, bob, carol])

# Build the reverse index before querying
g.build()

# Shortest path
path = g.shortest_path(alice, carol)

# Fluent query builders
active = (
    g.vertices()
     .where(lambda d: d["age"] > 28)
     .data()
)

# Structural algorithms
scores, _, _ = g.page_rank()
centrality    = g.centrality()
components    = g.connected_components()

# Sub-graph operations return independent Hypergraph objects
sub = g.vertex_induced_subgraph([alice, bob])
dual = g.dual()
```

### API summary

| Category | Methods |
|---|---|
| Lifecycle | `build()`, `clear()`, `save()`, `load()`, `clone()` |
| Vertices | `add_vertex()`, `get_vertex()`, `update_vertex()`, `delete_vertex()`, `vertex_count()`, `all_vertex_ids()` |
| Hyperedges | `add_hyperedge()`, `get_hyperedge()`, `update_hyperedge()`, `delete_hyperedge()`, `hyperedge_count()`, `all_hyperedge_ids()` |
| Relations | `connect()`, `prepend()`, `insert_vertex()`, `insert_many()`, `disconnect()`, `disconnect_at()` |
| Degree | `vertex_indegree()`, `vertex_outdegree()` |
| Queries | `hyperedge_vertices()`, `vertex_hyperedges()`, `neighborhood()`, `intersections()`, `hyperedges_connecting()`, `endpoints()`, `orphan_vertices()`, `orphan_hyperedges()` |
| Boolean | `is_connected()`, `is_reachable()`, `has_cycle()`, `is_k_uniform()` |
| Traversal | `shortest_path()`, `all_paths()`, `bfs()`, `dfs()`, `random_walk()` |
| Algorithms | `connected_components()`, `topological_sort()`, `cut_vertices()`, `centrality()`, `page_rank()`, `inclusions()`, `nestedness_profile()` |
| Matrices | `incidence_matrix()`, `incidence_matrix_coo()`, `laplacian()` |
| Sub-graphs | `dual()`, `k_skeleton()`, `vertex_induced_subgraph()`, `edge_induced_subgraph()`, `core()`, `expand_to_graph()`, `expand_to_star()`, `line_graph()`, `transitive_closure()` |
| Fluent builders | `vertices()` → `VertexQuery`, `hyperedges()` → `HyperedgeQuery` |

### Exceptions

All errors map to typed exceptions from `hypergraphz`:

| Exception | When raised |
|---|---|
| `NotBuiltError` | Query requires `build()` first |
| `VertexNotFoundError` | Vertex ID does not exist |
| `HyperedgeNotFoundError` | Hyperedge ID does not exist |
| `CycleDetectedError` | Operation requires a DAG |
| `NoPathError` | No directed path exists |
| `IndexOutOfBoundsError` | Insertion index out of range |
| `NotEnoughVerticesError` | Operation needs more vertices |

---

## For Zig users

### Zig version

HypergraphZ currently requires **Zig 0.17.0-dev.242+5d55999d2**.

### Usage

Add `hypergraphz` as a dependency to your `build.zig.zon`:

```sh
zig fetch --save https://github.com/yamafaktory/hypergraphz/archive/v0.1.0.tar.gz
```

Add `hypergraphz` as a dependency to your `build.zig`:

```zig
const hypergraphz = b.dependency("hypergraphz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("hypergraphz", hypergraphz.module("hypergraphz"));
```

### Example

`examples/coauthorship.zig` models a small research community as a directed hypergraph
where vertices are researchers and hyperedges are papers. The first listed author is
treated as the corresponding author, giving each hyperedge a natural direction.

```
zig build example
```

It walks through seventeen features of the library in sequence:

| Section                  | API                      | What it shows                                                |
| ------------------------ | ------------------------ | ------------------------------------------------------------ |
| Papers per researcher    | `getVertexHyperedges`    | reverse-index query                                          |
| Research communities     | `getConnectedComponents` | two isolated groups with no cross-group papers               |
| Betweenness centrality   | `computeCentrality`      | which researchers bridge the most collaboration paths        |
| Degrees of separation    | `findShortestPath`       | 1–3 hops within a community; unreachable across communities  |
| Dual: paper-centric view | `getDual`                | swap vertices ↔ hyperedges to see each researcher's papers   |
| Shared authorship        | `getIntersections`       | researchers present on every paper in a given set            |
| Seniority ordering       | `topologicalSort`        | hierarchy implied by the authorship direction                |
| Pairwise expansion       | `expandToGraph`          | 6 papers encode 11 directed pairs in a regular graph         |
| Spectral view            | `toLaplacian`            | normalized Laplacian; block-diagonal under disjoint groups   |
| PageRank                 | `computePageRank`        | citation-weighted stationary distribution; sums to 1         |
| Random walk              | `randomWalk`             | seeded weighted walk; stays inside the start's component     |
| Star expansion           | `expandToStar`           | bipartite (researcher ↔ paper) projection; 2-uniform         |
| Line graph               | `getLineGraph`           | papers as vertices, linked when they share an author         |
| K-core decomposition     | `getCore`                | (s, t)-core peeling; trims the lone-paper researcher         |
| Nestedness               | `getInclusions`          | strict-subset pairs across hyperedges; sized profile         |
| Co-author neighborhoods  | `getVertexNeighborhood`  | undirected co-occurrence neighbors across all hyperedges     |

---

## Documentation

The latest online documentation can be found [here](https://yamafaktory.github.io/hypergraphz/).
