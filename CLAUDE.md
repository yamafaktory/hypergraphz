# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Zig

```bash
# Type-check everything (fast — no codegen)
zig build check

# Run all tests
zig build test --summary all

# Format all source files in-place
zig build fmt

# Check formatting without modifying (used by CI)
zig fmt --check src/ bench/ build.zig tests/ examples/

# Run the co-authorship example
zig build example

# Run benchmarks
zig build bench

# Build and deploy docs locally (output: zig-out/docs/)
zig build docs

# Build the shared library for Python bindings
zig build lib -Doptimize=ReleaseFast
```

**Required Zig version:** `0.17.0-dev.242+5d55999d2` (set in `build.zig.zon`).

`zig build test` currently exits non-zero due to an issue with the `--listen=-` IPC protocol and the debug-level test logging — all tests actually pass. Run the test binary directly to confirm: `./.zig-cache/o/<hash>/test`.

### Python (requires [uv](https://github.com/astral-sh/uv))

```bash
# Install / sync all dev dependencies
uv sync

# Build the shared library and copy it into the package, then sync
just install-py

# Run Python tests
uv run pytest tests-python/ -v

# Lint and format check
uv run ruff check python/ tests-python/
uv run ruff format --check python/ tests-python/

# Format in-place
uv run ruff format python/ tests-python/
uv run ruff check --fix python/ tests-python/

# Build a platform wheel locally (runs hatch_build.py, which compiles Zig)
just wheel

# Shortcuts
just install-py   # build lib + copy + uv sync
just test-py      # uv run pytest
just lint         # ruff check + format check
just fmt          # ruff format + fix in-place
```

## Architecture

The entire library lives in a single file: `src/hypergraphz.zig`. Everything else is consumer code (tests, bench, examples).

### The generic type

`HypergraphZ(H, V, options)` is a comptime-parametric type. `H` is the hyperedge payload struct, `V` is the vertex payload struct. Both must be structs; `H` must have an integer field named by `options.weight_field` (default `"weight"`) — this is enforced with a comptime `assert`. The returned type contains all methods as `pub fn`.

### Internal storage

Each vertex and hyperedge stores a `*T` pointer (from a `MemoryPool`) plus an `ArrayList(HypergraphZId)` of relations:
- **Hyperedge relations**: ordered list of vertex IDs (may contain duplicates; order defines direction via consecutive pairs).
- **Vertex relations**: unordered list of hyperedge IDs (the reverse index).

Both use `AutoArrayHashMap(HypergraphZId, DataRelations)` so that `getAllVertices()` / `getAllHyperedges()` return IDs in deterministic insertion order — which is why any function that emits a sorted/canonical result iterates the map rather than a separate list.

### Two-phase model

After `init`, the graph is in **build phase**: mutations write only to the forward index (hyperedge → vertices). The reverse index (vertex → hyperedges) does not exist yet. Any query that needs the reverse index returns `HypergraphZError.NotBuilt`.

Calling `build()` constructs the reverse index in a single pass and switches to **query phase**. Subsequent mutations maintain the reverse index incrementally. A second `build()` call is only needed after a large batch of insertions where incremental maintenance would be too expensive.

### Method sections (in source order)

| Section | What lives here |
|---|---|
| Core | `init`, `deinit`, `clone`, `build`, `clear`, `createVertex/Hyperedge`, `getVertex/Hyperedge`, `getAllVertices/Hyperedges`, `countVertices/Hyperedges` |
| Mutations | Append/prepend/insert/delete vertices in hyperedges; `deleteHyperedge`, `deleteVertex` |
| Queries | `getHyperedgeVertices`, `getVertexHyperedges`, degree/indegree, adjacency, intersections, union, shortest path endpoints, topological sort |
| Traversal | `findShortestPath`, BFS/DFS, `getAllPaths`, `isConnected`, `randomWalk`, `getTransitiveClosure` |
| Algorithms | `computeCentrality`, `computePageRank`, `getInclusions`, `getNestednessProfile`, `isKUniform`, `isHypergraph`, `getConnectedComponents`, `getVertexNeighborhood`, `isComplete`, `findCutVertices` |
| Projections | `getDual`, `getSubhypergraph` (by vertices or hyperedges), `getCore` (vertex-degree k-core), `getCore(s,t)` (bipartite s,t-core), `expandToGraph`, `expandToStar`, `getLineGraph`, `toIncidenceMatrix`, `toIncidenceMatrixCOO`, `toLaplacian` |
| Codec | `save` / `load` with custom serialize/deserialize callbacks; `defaultSerialize` / `defaultDeserialize` for pointer-free types |

### Directed semantics vs. clique-expansion semantics

This distinction is critical when adding new algorithms:

- **Directed / window-pair**: BFS, DFS, `findShortestPath`, `isConnected` — adjacency is defined by consecutive pairs in a hyperedge's relation list. `[a, b, c]` gives directed edges `a→b` and `b→c`.
- **Clique-expansion / undirected**: `getVertexNeighborhood`, `getConnectedComponents`, `computePageRank`, `toLaplacian`, `getInclusions`, `findCutVertices` — every pair of distinct vertices in a hyperedge is considered adjacent, regardless of order.

When adding a new algorithm, explicitly decide which semantics it uses and document it in the doc comment.

### `debugAt` convention

Use `debugAt(@src(), "message {}", .{arg})` (not `std.log.debug`) for all internal trace output. This emits under the `.hypergraphz` log scope and is gated by the `log_level` variable in non-test builds and by `std.testing.log_level` in test builds.

### Tests

Tests live in `tests/`, split by section name (e.g. `algorithms_tests.zig`, `projections_tests.zig`). `tests/root.zig` is the entry point that pulls them all in. `tests/helpers.zig` provides `scaffold()` (returns a fresh graph with capacity 5 vertices / 3 hyperedges), `generateTestData()`, and shared type aliases.

Every test function uses a fresh `h.scaffold()` per sub-case (wrapped in a block). The standard pattern: NotBuilt guard → empty graph → small constructed graphs that pin exact output. When adding a new algorithm, add its tests to the matching `*_tests.zig` file and register that file in `root.zig` if it's new.

### Docs and bench separation

`bench/main.zig` must **not** live in `src/` — the Zig doc generator bundles all `.zig` files co-located with the root source. Bench imports the library as a named module (`@import("hypergraphz")`), wired up via `build.zig`.

## Python bindings

The Python package lives in `python/hypergraphz/` and wraps the C ABI layer (`src/hgz_c_api.zig`) via ctypes. Three-layer structure:

- `_binding.py` — raw ctypes declarations for every exported C function
- `_graph.py` — `Hypergraph` class (high-level API; mirrors the Zig two-phase model)
- `_query.py` — `VertexQuery` / `HyperedgeQuery` fluent builders (`.where()`, `.neighbors()`, `.containing()`, `.limit()`, `.ids()`, `.data()`)
- `_errors.py` — exception hierarchy mapping Zig error codes to Python exceptions

The shared library (`libhypergraphz.so` / `.dylib` / `.dll`) must be placed inside `python/hypergraphz/` for `_binding.py` to find it. Use `just install-py` to build and copy it.

### Python API naming convention

**Python method names must be the exact `snake_case` conversion of the Zig method name.** No shortening, no dropping of verb prefixes, no invented names. Examples:

| Zig | Python |
|---|---|
| `appendVertices` | `append_vertices` |
| `findShortestPath` | `find_shortest_path` |
| `computeCentrality` | `compute_centrality` |
| `getVertexInducedSubhypergraph` | `get_vertex_induced_subhypergraph` |
| `deleteVertexFromHyperedge` | `delete_vertex_from_hyperedge` |

If a Zig method is renamed, the Python method must be renamed to match in the same commit. Never invent a Python name that doesn't trace directly to a Zig method name.

Python tests live in `tests-python/`, split across:
- `test_core.py` — lifecycle, CRUD, basic traversal
- `test_query.py` — fluent `VertexQuery` / `HyperedgeQuery`
- `test_persistence.py` — `save` / `load` round-trip
- `test_advanced.py` — degree, boolean queries, extended traversal, set ops, relation mutations, centrality, PageRank, inclusions, nestedness, matrix operations, all paths
- `test_subgraphs.py` — clone, dual, k-skeleton, expansions, cores, transitive closure

### Mutation requirements

These mutation methods require `build()` to have been called first (reverse index must exist): `delete_vertex`, `disconnect` (`hgz_remove_vertex_from_hyperedge`), `disconnect_at` (`hgz_remove_vertex_at_index`).

### Sub-graph lifecycle

Sub-graph operations (`dual`, `clone`, `k_skeleton`, etc.) return a new `Hypergraph` in build phase — call `build()` on the result before running queries on it.

### Zero-length allocation hazard

Zero-length array returns from the C layer carry undefined pointers (Zig `alloc(T, 0)` is undefined). The Python layer guards this via `_safe_free` / `_read_ids` — never call `hgz_free` on a result pointer when the corresponding length is 0.

### Release process

The wheel version is derived automatically from git tags via `hatch-vcs` — there is no version field to edit in `pyproject.toml`. To release:

```sh
just release 0.2.0
```

This checks that the working tree is clean, creates `v0.2.0`, and pushes both the commit and the tag. The release CI pipeline then builds wheels for all platforms and publishes to PyPI via OIDC (no API token needed). In development (no tag on the current commit) the version resolves to something like `0.1.0.dev5+gabcdef`.

### Packaging (uv + cibuildwheel)

`hatch_build.py` is a custom Hatch build hook that runs `zig build lib` automatically when `uv build` packages a wheel. `cibuildwheel` drives multi-platform wheel builds in CI. The release pipeline (`.github/workflows/release.yml`) triggers on `v*` tags, builds wheels for Linux x86_64, Linux aarch64, macOS x86_64, macOS arm64, and Windows x86_64, retags them to `py3-none-PLATFORM`, and publishes to PyPI via trusted publisher (OIDC — no API token needed).
