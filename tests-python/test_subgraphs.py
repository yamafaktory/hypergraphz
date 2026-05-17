"""Tests for sub-graph operations: clone, dual, k_skeleton, expansions, and cores."""

import pytest

from hypergraphz import Hypergraph


@pytest.fixture
def triangle() -> tuple[Hypergraph, list[int], list[int]]:
    """Three vertices, two 2-uniform hyperedges."""
    g = Hypergraph()
    va = g.add_vertex({"n": "a"})
    vb = g.add_vertex({"n": "b"})
    vc = g.add_vertex({"n": "c"})
    e1 = g.add_hyperedge({"label": "e1"})
    e2 = g.add_hyperedge({"label": "e2"})
    g.connect(e1, [va, vb])
    g.connect(e2, [vb, vc])
    g.build()
    return g, [va, vb, vc], [e1, e2]


@pytest.fixture
def mixed() -> tuple[Hypergraph, list[int], list[int]]:
    """One 3-vertex and one 2-vertex hyperedge (non-uniform)."""
    g = Hypergraph()
    va = g.add_vertex({})
    vb = g.add_vertex({})
    vc = g.add_vertex({})
    e1 = g.add_hyperedge({})
    e2 = g.add_hyperedge({})
    g.connect(e1, [va, vb, vc])
    g.connect(e2, [va, vb])
    g.build()
    return g, [va, vb, vc], [e1, e2]


# ── Clone ──────────────────────────────────────────────────────────────────────


def test_clone_same_counts(triangle):
    g, vids, eids = triangle
    g2 = g.clone()
    assert g2.vertex_count() == g.vertex_count()
    assert g2.hyperedge_count() == g.hyperedge_count()


def test_clone_independent(triangle):
    g, vids, _ = triangle
    g2 = g.clone()
    g2.add_vertex({"extra": True})
    assert g.vertex_count() == 3
    assert g2.vertex_count() == 4


def test_clone_preserves_data(triangle):
    g, vids, _ = triangle
    g2 = g.clone()
    for vid in vids:
        assert g2.get_vertex(vid) == g.get_vertex(vid)


# ── Dual ───────────────────────────────────────────────────────────────────────


def test_dual_swaps_counts(triangle):
    g, vids, eids = triangle
    d = g.dual()
    assert d.vertex_count() == len(eids)
    assert d.hyperedge_count() == len(vids)


def test_dual_of_dual_same_structure(triangle):
    g, _, _ = triangle
    d = g.dual()
    d.build()
    dd = d.dual()
    assert dd.vertex_count() == g.vertex_count()
    assert dd.hyperedge_count() == g.hyperedge_count()


# ── K-skeleton ────────────────────────────────────────────────────────────────


def test_k_skeleton_filters_large_edges(mixed):
    g, vids, _ = mixed
    skel = g.k_skeleton(2)
    assert skel.vertex_count() == len(vids)
    assert skel.hyperedge_count() == 1


def test_k_skeleton_keeps_all_at_max(mixed):
    g, _, eids = mixed
    skel = g.k_skeleton(3)
    assert skel.hyperedge_count() == len(eids)


# ── Expand to graph ────────────────────────────────────────────────────────────


def test_expand_to_graph_is_graph(triangle):
    g, _, _ = triangle
    exp = g.expand_to_graph()
    assert exp.vertex_count() == g.vertex_count()
    all_eids = exp.all_hyperedge_ids()
    for eid in all_eids:
        assert len(exp.hyperedge_vertices(eid)) == 2


# ── Expand to star ─────────────────────────────────────────────────────────────


def test_expand_to_star_vertex_count(triangle):
    g, _, _ = triangle
    star = g.expand_to_star()
    assert star.vertex_count() > g.vertex_count()


def test_expand_to_star_all_edges_size_two(triangle):
    g, _, _ = triangle
    star = g.expand_to_star()
    for eid in star.all_hyperedge_ids():
        assert len(star.hyperedge_vertices(eid)) == 2


# ── Line graph ─────────────────────────────────────────────────────────────────


def test_line_graph_vertex_count(triangle):
    g, _, eids = triangle
    lg = g.line_graph()
    assert lg.vertex_count() == len(eids)


def test_line_graph_connected(triangle):
    g, _, _ = triangle
    lg = g.line_graph()
    lg.build()
    assert lg.is_connected() is True


# ── Vertex-induced subgraph ───────────────────────────────────────────────────


def test_vertex_induced_subset(triangle):
    g, vids, _ = triangle
    sub = g.vertex_induced_subgraph(vids[:2])
    assert sub.vertex_count() == 2
    assert sub.hyperedge_count() == 1


def test_vertex_induced_preserves_data(triangle):
    g, vids, _ = triangle
    sub = g.vertex_induced_subgraph(vids)
    for vid in vids:
        assert sub.get_vertex(vid) == g.get_vertex(vid)


# ── Edge-induced subgraph ─────────────────────────────────────────────────────


def test_edge_induced_subset(triangle):
    g, _, eids = triangle
    sub = g.edge_induced_subgraph([eids[0]])
    assert sub.hyperedge_count() == 1
    assert sub.vertex_count() == 2


def test_edge_induced_preserves_data(triangle):
    g, _, eids = triangle
    sub = g.edge_induced_subgraph(eids)
    for eid in eids:
        assert sub.get_hyperedge(eid) == g.get_hyperedge(eid)


# ── Core ───────────────────────────────────────────────────────────────────────


def test_core_basic(triangle):
    g, _, _ = triangle
    c = g.core(1, 2)
    assert c.vertex_count() <= g.vertex_count()
    assert c.hyperedge_count() <= g.hyperedge_count()


def test_core_empty_for_high_threshold(triangle):
    g, _, _ = triangle
    c = g.core(10, 10)
    assert c.vertex_count() == 0
    assert c.hyperedge_count() == 0


# ── Transitive closure ────────────────────────────────────────────────────────


def test_transitive_closure_preserves_vertices(triangle):
    g, vids, _ = triangle
    tc = g.transitive_closure()
    assert tc.vertex_count() == len(vids)


def test_transitive_closure_more_edges(triangle):
    g, _, eids = triangle
    tc = g.transitive_closure()
    assert tc.hyperedge_count() >= len(eids)
