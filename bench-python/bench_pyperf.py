"""pyperf benchmark suite mirroring bench/main.zig.

Run:
    uv run python bench-python/bench_pyperf.py
    uv run python bench-python/bench_pyperf.py --fast   # quick pass
    uv run python bench-python/bench_pyperf.py -o results.json
    uv run python -m pyperf compare_to baseline.json results.json
"""

import pyperf

from hypergraphz import Hypergraph

runner = pyperf.Runner()


# ---------------------------------------------------------------------------
# Bench 1: atomic insertions (build phase, no reverse-index overhead)
# ---------------------------------------------------------------------------
def bench_atomic_insertions(loops):
    elapsed = pyperf.perf_counter()
    for _ in range(loops):
        g = Hypergraph()
        for _ in range(1_000):
            h = g.create_hyperedge({})
            for _ in range(1_000):
                v = g.create_vertex({})
                g.append_vertices(h, [v])
    return pyperf.perf_counter() - elapsed


runner.bench_time_func(
    "1_000 hyperedges × 1_000 vertices (atomic)",
    bench_atomic_insertions,
)


# ---------------------------------------------------------------------------
# Bench 2: batch insertions (build phase, no reverse-index overhead)
# ---------------------------------------------------------------------------
def bench_batch_insertions(loops):
    elapsed = pyperf.perf_counter()
    for _ in range(loops):
        g = Hypergraph()
        for _ in range(1_000):
            h = g.create_hyperedge({})
            vertices = [g.create_vertex({}) for _ in range(1_000)]
            g.append_vertices(h, vertices)
    return pyperf.perf_counter() - elapsed


runner.bench_time_func(
    "1_000 hyperedges × 1_000 vertices (batch)",
    bench_batch_insertions,
)


# ---------------------------------------------------------------------------
# Bench 1c: bulk insertions via create_hyperedges + create_vertices
# (compare with atomic and batch above to see FFI overhead eliminated)
# ---------------------------------------------------------------------------
_v_payloads = [{}] * 1_000
_h_payloads = [{}] * 1_000


def bench_bulk_insertions(loops):
    elapsed = pyperf.perf_counter()
    for _ in range(loops):
        g = Hypergraph()
        hyperedges = g.create_hyperedges(_h_payloads)
        for h in hyperedges:
            vertices = g.create_vertices(_v_payloads)
            g.append_vertices(h, vertices)
    return pyperf.perf_counter() - elapsed


runner.bench_time_func(
    "1_000 hyperedges × 1_000 vertices (bulk create_hyperedges + create_vertices)",
    bench_bulk_insertions,
)


# ---------------------------------------------------------------------------
# Bench 3: indegree queries — 100 shared vertices each in 1_000 hyperedges
# Setup is excluded from timing.
# ---------------------------------------------------------------------------
def _make_indegree_graph():
    g = Hypergraph()
    shared = [g.create_vertex({}) for _ in range(100)]
    for _ in range(1_000):
        h = g.create_hyperedge({})
        g.append_vertices(h, shared)
    g.build()
    return g, shared


_indegree_g, _shared_vertices = _make_indegree_graph()


def bench_indegree_queries(loops):
    g, shared = _indegree_g, _shared_vertices
    elapsed = pyperf.perf_counter()
    for _ in range(loops):
        for v in shared:
            g.get_vertex_indegree(v)
    return pyperf.perf_counter() - elapsed


runner.bench_time_func(
    "indegree for 100 vertices each in 1_000 hyperedges",
    bench_indegree_queries,
)


# ---------------------------------------------------------------------------
# Bench 4: shortest path across a chain of 1_000 vertices
# Setup is excluded from timing.
# ---------------------------------------------------------------------------
def _make_chain_graph():
    g = Hypergraph()
    chain = [g.create_vertex({}) for _ in range(1_000)]
    for i in range(999):
        h = g.create_hyperedge({})
        g.append_vertices(h, [chain[i], chain[i + 1]])
    g.build()
    return g, chain


_chain_g, _chain = _make_chain_graph()


def bench_find_shortest_path(loops):
    g, chain = _chain_g, _chain
    elapsed = pyperf.perf_counter()
    for _ in range(loops):
        g.find_shortest_path(chain[0], chain[999])
    return pyperf.perf_counter() - elapsed


runner.bench_time_func(
    "find_shortest_path across chain of 1_000 vertices",
    bench_find_shortest_path,
)


# ---------------------------------------------------------------------------
# Bench 5: find_cut_vertices on a chain of 1_000 vertices
# ---------------------------------------------------------------------------
def bench_find_cut_vertices(loops):
    g, _ = _chain_g, _chain
    elapsed = pyperf.perf_counter()
    for _ in range(loops):
        g.find_cut_vertices()
    return pyperf.perf_counter() - elapsed


runner.bench_time_func(
    "find_cut_vertices on chain of 1_000 vertices",
    bench_find_cut_vertices,
)


# ---------------------------------------------------------------------------
# Bench 6: build() — reverse index for 1_000 hyperedges × 1_000 vertices
# Setup is excluded from timing.
# ---------------------------------------------------------------------------
def _make_prebuild_graph():
    g = Hypergraph()
    for _ in range(1_000):
        h = g.create_hyperedge({})
        vertices = [g.create_vertex({}) for _ in range(1_000)]
        g.append_vertices(h, vertices)
    return g


def bench_build_reverse_index(loops):
    elapsed = pyperf.perf_counter()
    for _ in range(loops):
        g = _make_prebuild_graph()
        g.build()
    return pyperf.perf_counter() - elapsed


runner.bench_time_func(
    "build reverse index for 1_000 hyperedges × 1_000 vertices",
    bench_build_reverse_index,
)
