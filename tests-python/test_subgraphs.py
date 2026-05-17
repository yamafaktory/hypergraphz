"""Tests for sub-graph operations: clone, get_dual, get_k_skeleton, expansions, and cores."""

import pytest

from hypergraphz import Hypergraph


@pytest.fixture
def triangle() -> tuple[Hypergraph, list[int], list[int]]:
    """Three vertices, two 2-uniform hyperedges."""
    g = Hypergraph()
    va = g.create_vertex({"n": "a"})
    vb = g.create_vertex({"n": "b"})
    vc = g.create_vertex({"n": "c"})
    e1 = g.create_hyperedge({"label": "e1"})
    e2 = g.create_hyperedge({"label": "e2"})
    g.append_vertices(e1, [va, vb])
    g.append_vertices(e2, [vb, vc])
    g.build()
    return g, [va, vb, vc], [e1, e2]


@pytest.fixture
def mixed() -> tuple[Hypergraph, list[int], list[int]]:
    """One 3-vertex and one 2-vertex hyperedge (non-uniform)."""
    g = Hypergraph()
    va = g.create_vertex({})
    vb = g.create_vertex({})
    vc = g.create_vertex({})
    e1 = g.create_hyperedge({})
    e2 = g.create_hyperedge({})
    g.append_vertices(e1, [va, vb, vc])
    g.append_vertices(e2, [va, vb])
    g.build()
    return g, [va, vb, vc], [e1, e2]


# ── Clone ──────────────────────────────────────────────────────────────────────


def test_clone_same_counts(triangle):
    g, vids, eids = triangle
    g2 = g.clone()
    assert g2.count_vertices() == g.count_vertices()
    assert g2.count_hyperedges() == g.count_hyperedges()


def test_clone_independent(triangle):
    g, vids, _ = triangle
    g2 = g.clone()
    g2.create_vertex({"extra": True})
    assert g.count_vertices() == 3
    assert g2.count_vertices() == 4


def test_clone_preserves_data(triangle):
    g, vids, _ = triangle
    g2 = g.clone()
    for vid in vids:
        assert g2.get_vertex(vid) == g.get_vertex(vid)


# ── Dual ───────────────────────────────────────────────────────────────────────


def test_dual_swaps_counts(triangle):
    g, vids, eids = triangle
    d = g.get_dual()
    assert d.count_vertices() == len(eids)
    assert d.count_hyperedges() == len(vids)


def test_dual_of_dual_same_structure(triangle):
    g, _, _ = triangle
    d = g.get_dual()
    d.build()
    dd = d.get_dual()
    assert dd.count_vertices() == g.count_vertices()
    assert dd.count_hyperedges() == g.count_hyperedges()


# ── K-skeleton ────────────────────────────────────────────────────────────────


def test_k_skeleton_filters_large_edges(mixed):
    g, vids, _ = mixed
    skel = g.get_k_skeleton(2)
    assert skel.count_vertices() == len(vids)
    assert skel.count_hyperedges() == 1


def test_k_skeleton_keeps_all_at_max(mixed):
    g, _, eids = mixed
    skel = g.get_k_skeleton(3)
    assert skel.count_hyperedges() == len(eids)


# ── Expand to graph ────────────────────────────────────────────────────────────


def test_expand_to_graph_is_graph(triangle):
    g, _, _ = triangle
    exp = g.expand_to_graph()
    assert exp.count_vertices() == g.count_vertices()
    all_eids = exp.get_all_hyperedge_ids()
    for eid in all_eids:
        assert len(exp.get_hyperedge_vertices(eid)) == 2


# ── Expand to star ─────────────────────────────────────────────────────────────


def test_expand_to_star_vertex_count(triangle):
    g, _, _ = triangle
    star = g.expand_to_star()
    assert star.count_vertices() > g.count_vertices()


def test_expand_to_star_all_edges_size_two(triangle):
    g, _, _ = triangle
    star = g.expand_to_star()
    for eid in star.get_all_hyperedge_ids():
        assert len(star.get_hyperedge_vertices(eid)) == 2


# ── Line graph ─────────────────────────────────────────────────────────────────


def test_line_graph_vertex_count(triangle):
    g, _, eids = triangle
    lg = g.get_line_graph()
    assert lg.count_vertices() == len(eids)


def test_line_graph_connected(triangle):
    g, _, _ = triangle
    lg = g.get_line_graph()
    lg.build()
    assert lg.is_connected() is True


# ── Vertex-induced subgraph ───────────────────────────────────────────────────


def test_vertex_induced_subset(triangle):
    g, vids, _ = triangle
    sub = g.get_vertex_induced_subhypergraph(vids[:2])
    assert sub.count_vertices() == 2
    assert sub.count_hyperedges() == 1


def test_vertex_induced_preserves_data(triangle):
    g, vids, _ = triangle
    sub = g.get_vertex_induced_subhypergraph(vids)
    for vid in vids:
        assert sub.get_vertex(vid) == g.get_vertex(vid)


# ── Edge-induced subgraph ─────────────────────────────────────────────────────


def test_edge_induced_subset(triangle):
    g, _, eids = triangle
    sub = g.get_edge_induced_subhypergraph([eids[0]])
    assert sub.count_hyperedges() == 1
    assert sub.count_vertices() == 2


def test_edge_induced_preserves_data(triangle):
    g, _, eids = triangle
    sub = g.get_edge_induced_subhypergraph(eids)
    for eid in eids:
        assert sub.get_hyperedge(eid) == g.get_hyperedge(eid)


# ── Core ───────────────────────────────────────────────────────────────────────


def test_core_basic(triangle):
    g, _, _ = triangle
    c = g.get_core(1, 2)
    assert c.count_vertices() <= g.count_vertices()
    assert c.count_hyperedges() <= g.count_hyperedges()


def test_core_empty_for_high_threshold(triangle):
    g, _, _ = triangle
    c = g.get_core(10, 10)
    assert c.count_vertices() == 0
    assert c.count_hyperedges() == 0


# ── Transitive closure ────────────────────────────────────────────────────────


def test_transitive_closure_preserves_vertices(triangle):
    g, vids, _ = triangle
    tc = g.get_transitive_closure()
    assert tc.count_vertices() == len(vids)


def test_transitive_closure_more_edges(triangle):
    g, _, eids = triangle
    tc = g.get_transitive_closure()
    assert tc.count_hyperedges() >= len(eids)
