"""Tests for degree, boolean queries, traversal, orphans, set ops, mutations, and algorithms."""

import pytest

from hypergraphz import Hypergraph, IndexOutOfBoundsError


@pytest.fixture
def chain() -> tuple[Hypergraph, list[int], list[int]]:
    """Linear chain: va→vb via e1, vb→vc via e2."""
    g = Hypergraph()
    va = g.add_vertex({"n": "a"})
    vb = g.add_vertex({"n": "b"})
    vc = g.add_vertex({"n": "c"})
    e1 = g.add_hyperedge({"w": 1})
    e2 = g.add_hyperedge({"w": 1})
    g.connect(e1, [va, vb])
    g.connect(e2, [vb, vc])
    g.build()
    return g, [va, vb, vc], [e1, e2]


# ── Degree ────────────────────────────────────────────────────────────────────


def test_vertex_indegree(chain):
    g, vids, _ = chain
    va, vb, vc = vids
    assert g.vertex_indegree(va) == 0
    assert g.vertex_indegree(vb) == 1
    assert g.vertex_indegree(vc) == 1


def test_vertex_outdegree(chain):
    g, vids, _ = chain
    va, vb, vc = vids
    assert g.vertex_outdegree(va) == 1
    assert g.vertex_outdegree(vb) == 1
    assert g.vertex_outdegree(vc) == 0


# ── Boolean queries ───────────────────────────────────────────────────────────


def test_is_reachable_true(chain):
    g, vids, _ = chain
    assert g.is_reachable(vids[0], vids[2]) is True


def test_is_reachable_false(chain):
    g, vids, _ = chain
    assert g.is_reachable(vids[2], vids[0]) is False


def test_has_cycle_false(chain):
    assert chain[0].has_cycle() is False


def test_has_cycle_true():
    g = Hypergraph()
    va = g.add_vertex({})
    vb = g.add_vertex({})
    e1 = g.add_hyperedge({})
    e2 = g.add_hyperedge({})
    g.connect(e1, [va, vb])
    g.connect(e2, [vb, va])
    g.build()
    assert g.has_cycle() is True


def test_is_k_uniform_true(chain):
    assert chain[0].is_k_uniform(2) is True


def test_is_k_uniform_false(chain):
    assert chain[0].is_k_uniform(3) is False


# ── Traversal ─────────────────────────────────────────────────────────────────


def test_bfs_visits_all(chain):
    g, vids, _ = chain
    order = g.bfs(vids[0])
    assert set(order) == set(vids)
    assert order[0] == vids[0]


def test_dfs_visits_all(chain):
    g, vids, _ = chain
    order = g.dfs(vids[0])
    assert set(order) == set(vids)
    assert order[0] == vids[0]


def test_random_walk_length(chain):
    g, vids, _ = chain
    walk = g.random_walk(vids[0], 4)
    assert len(walk) == 5
    assert walk[0] == vids[0]


# ── Orphan queries ────────────────────────────────────────────────────────────


def test_orphan_vertices():
    g = Hypergraph()
    va = g.add_vertex({})
    vb = g.add_vertex({})
    e = g.add_hyperedge({})
    g.connect(e, [va])
    g.build()
    orphans = g.orphan_vertices()
    assert orphans == [vb]


def test_orphan_hyperedges():
    g = Hypergraph()
    g.add_vertex({})
    e1 = g.add_hyperedge({})
    e2 = g.add_hyperedge({})
    g.connect(e1, [g.all_vertex_ids()[0]])
    g.build()
    orphans = g.orphan_hyperedges()
    assert orphans == [e2]


# ── Set operations ────────────────────────────────────────────────────────────


def test_intersections(chain):
    g, vids, eids = chain
    common = g.intersections(eids)
    assert common == [vids[1]]


def test_hyperedges_connecting(chain):
    g, vids, eids = chain
    connecting = g.hyperedges_connecting(vids[0], vids[1])
    assert connecting == [eids[0]]


def test_hyperedges_connecting_none(chain):
    g, vids, _ = chain
    connecting = g.hyperedges_connecting(vids[0], vids[2])
    assert connecting == []


# ── Endpoints ─────────────────────────────────────────────────────────────────


def test_endpoints(chain):
    g, vids, eids = chain
    initial, terminal = g.endpoints()
    initial_vids = [v for _, v in initial]
    terminal_vids = [v for _, v in terminal]
    assert vids[0] in initial_vids
    assert vids[2] in terminal_vids


# ── Relation mutations ────────────────────────────────────────────────────────


def test_prepend():
    g = Hypergraph()
    va = g.add_vertex({})
    vb = g.add_vertex({})
    vc = g.add_vertex({})
    e = g.add_hyperedge({})
    g.connect(e, [vb, vc])
    g.prepend(e, [va])
    assert g.hyperedge_vertices(e) == [va, vb, vc]


def test_insert_vertex():
    g = Hypergraph()
    va = g.add_vertex({})
    vb = g.add_vertex({})
    vc = g.add_vertex({})
    e = g.add_hyperedge({})
    g.connect(e, [va, vc])
    g.insert_vertex(e, vb, 1)
    assert g.hyperedge_vertices(e) == [va, vb, vc]


def test_insert_many():
    g = Hypergraph()
    va = g.add_vertex({})
    vb = g.add_vertex({})
    vc = g.add_vertex({})
    vd = g.add_vertex({})
    e = g.add_hyperedge({})
    g.connect(e, [va, vd])
    g.insert_many(e, [vb, vc], 1)
    assert g.hyperedge_vertices(e) == [va, vb, vc, vd]


def test_disconnect():
    g = Hypergraph()
    va = g.add_vertex({})
    vb = g.add_vertex({})
    e = g.add_hyperedge({})
    g.connect(e, [va, vb])
    g.build()
    g.disconnect(e, va)
    assert g.hyperedge_vertices(e) == [vb]


def test_disconnect_at():
    g = Hypergraph()
    va = g.add_vertex({})
    vb = g.add_vertex({})
    e = g.add_hyperedge({})
    g.connect(e, [va, vb])
    g.build()
    g.disconnect_at(e, 0)
    assert g.hyperedge_vertices(e) == [vb]


def test_insert_vertex_out_of_bounds():
    g = Hypergraph()
    va = g.add_vertex({})
    vb = g.add_vertex({})
    e = g.add_hyperedge({})
    g.connect(e, [va])
    with pytest.raises(IndexOutOfBoundsError):
        g.insert_vertex(e, vb, 99)


# ── Centrality ────────────────────────────────────────────────────────────────


def test_centrality_keys(chain):
    g, vids, _ = chain
    result = g.centrality()
    assert set(result.keys()) == set(vids)
    for v in vids:
        assert "degree" in result[v]
        assert "closeness" in result[v]
        assert "betweenness" in result[v]


def test_centrality_degree_values(chain):
    g, vids, _ = chain
    result = g.centrality()
    assert result[vids[1]]["degree"] >= result[vids[0]]["degree"]


# ── PageRank ──────────────────────────────────────────────────────────────────


def test_page_rank_returns_all_vertices(chain):
    g, vids, _ = chain
    scores, iterations, converged = g.page_rank()
    assert set(scores.keys()) == set(vids)
    assert iterations > 0
    assert converged is True


def test_page_rank_scores_sum_to_one(chain):
    g, vids, _ = chain
    scores, _, _ = g.page_rank()
    total = sum(scores.values())
    assert abs(total - 1.0) < 1e-6


# ── Inclusions ────────────────────────────────────────────────────────────────


def test_inclusions_subset():
    g = Hypergraph()
    va = g.add_vertex({})
    vb = g.add_vertex({})
    e1 = g.add_hyperedge({})
    e2 = g.add_hyperedge({})
    g.connect(e1, [va])
    g.connect(e2, [va, vb])
    g.build()
    pairs = g.inclusions()
    assert (e1, e2) in pairs


def test_inclusions_empty_when_no_subset(chain):
    g, _, _ = chain
    pairs = g.inclusions()
    assert pairs == []


# ── Nestedness profile ────────────────────────────────────────────────────────


def test_nestedness_profile_structure(chain):
    g, _, _ = chain
    profile = g.nestedness_profile()
    assert isinstance(profile, list)
    for entry in profile:
        assert "size" in entry
        assert "included" in entry
        assert "total" in entry


# ── Incidence matrix ──────────────────────────────────────────────────────────


def test_incidence_matrix_shape(chain):
    g, vids, eids = chain
    m = g.incidence_matrix()
    assert len(m["vertex_ids"]) == len(vids)
    assert len(m["hyperedge_ids"]) == len(eids)
    assert len(m["data"]) == len(vids)
    assert len(m["data"][0]) == len(eids)


def test_incidence_matrix_values(chain):
    g, vids, eids = chain
    m = g.incidence_matrix()
    row_map = {v: i for i, v in enumerate(m["vertex_ids"])}
    col_map = {e: j for j, e in enumerate(m["hyperedge_ids"])}
    assert m["data"][row_map[vids[0]]][col_map[eids[0]]] == 1
    assert m["data"][row_map[vids[2]]][col_map[eids[0]]] == 0


def test_incidence_matrix_coo(chain):
    g, vids, eids = chain
    coo = g.incidence_matrix_coo()
    assert len(coo["rows"]) == len(coo["cols"])
    assert len(coo["vertex_ids"]) == len(vids)
    assert len(coo["hyperedge_ids"]) == len(eids)
    assert len(coo["rows"]) > 0


# ── Laplacian ─────────────────────────────────────────────────────────────────


def test_laplacian_shape(chain):
    g, vids, _ = chain
    lap = g.laplacian()
    n = len(vids)
    assert len(lap["vertex_ids"]) == n
    assert len(lap["data"]) == n
    assert len(lap["data"][0]) == n


def test_laplacian_unnormalized(chain):
    g, _, _ = chain
    lap = g.laplacian(normalized=False)
    assert isinstance(lap["data"], list)


# ── All paths ─────────────────────────────────────────────────────────────────


def test_all_paths_finds_path(chain):
    g, vids, _ = chain
    paths = g.all_paths(vids[0], vids[2])
    assert len(paths) >= 1
    for path in paths:
        assert path[0] == vids[0]
        assert path[-1] == vids[2]


def test_all_paths_no_path(chain):
    g, vids, _ = chain
    paths = g.all_paths(vids[2], vids[0])
    assert paths == []
