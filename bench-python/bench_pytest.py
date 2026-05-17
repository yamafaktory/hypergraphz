"""pytest-benchmark suite mirroring bench/main.zig."""

import pytest

from hypergraphz import Hypergraph


# ---------------------------------------------------------------------------
# Bench 1: atomic insertions (build phase, no reverse-index overhead)
# ---------------------------------------------------------------------------
def test_atomic_insertions(benchmark):
    def run():
        g = Hypergraph()
        for _ in range(1_000):
            h = g.create_hyperedge({})
            for _ in range(1_000):
                v = g.create_vertex({})
                g.append_vertices(h, [v])

    benchmark(run)


# ---------------------------------------------------------------------------
# Bench 2: batch insertions (build phase, no reverse-index overhead)
# ---------------------------------------------------------------------------
def test_batch_insertions(benchmark):
    def run():
        g = Hypergraph()
        for _ in range(1_000):
            h = g.create_hyperedge({})
            vertices = [g.create_vertex({}) for _ in range(1_000)]
            g.append_vertices(h, vertices)

    benchmark(run)


# ---------------------------------------------------------------------------
# Bench 1b: bulk insertions via create_hyperedges + create_vertices
# Single FFI call for all hyperedges, single FFI call per hyperedge for vertices
# (compare with test_atomic_insertions and test_batch_insertions above)
# ---------------------------------------------------------------------------
def test_bulk_insertions(benchmark):
    v_payloads = [{}] * 1_000
    h_payloads = [{}] * 1_000

    def run():
        g = Hypergraph()
        hyperedges = g.create_hyperedges(h_payloads)
        for h in hyperedges:
            vertices = g.create_vertices(v_payloads)
            g.append_vertices(h, vertices)

    benchmark(run)


# ---------------------------------------------------------------------------
# Bench 3: indegree queries — 100 shared vertices each in 1_000 hyperedges
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def indegree_graph():
    g = Hypergraph()
    shared = [g.create_vertex({}) for _ in range(100)]
    for _ in range(1_000):
        h = g.create_hyperedge({})
        g.append_vertices(h, shared)
    g.build()
    return g, shared


def test_indegree_queries(benchmark, indegree_graph):
    g, shared = indegree_graph

    def run():
        for v in shared:
            g.get_vertex_indegree(v)

    benchmark(run)


# ---------------------------------------------------------------------------
# Bench 4: shortest path across a chain of 1_000 vertices
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def chain_graph():
    g = Hypergraph()
    chain = [g.create_vertex({}) for _ in range(1_000)]
    for i in range(999):
        h = g.create_hyperedge({})
        g.append_vertices(h, [chain[i], chain[i + 1]])
    g.build()
    return g, chain


def test_find_shortest_path(benchmark, chain_graph):
    g, chain = chain_graph
    benchmark(g.find_shortest_path, chain[0], chain[999])


# ---------------------------------------------------------------------------
# Bench 5: find_cut_vertices on a chain of 1_000 vertices
# ---------------------------------------------------------------------------
def test_find_cut_vertices(benchmark, chain_graph):
    g, _ = chain_graph
    benchmark(g.find_cut_vertices)


# ---------------------------------------------------------------------------
# Bench 6: build() — reverse index for 1_000 hyperedges × 1_000 vertices
# ---------------------------------------------------------------------------
def test_build_reverse_index(benchmark):
    g = Hypergraph()
    for _ in range(1_000):
        h = g.create_hyperedge({})
        vertices = [g.create_vertex({}) for _ in range(1_000)]
        g.append_vertices(h, vertices)

    benchmark(g.build)
