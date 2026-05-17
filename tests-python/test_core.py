"""Core CRUD and lifecycle tests."""

import pytest

from hypergraphz import (
    HyperedgeNotFoundError,
    Hypergraph,
    NotBuiltError,
    VertexNotFoundError,
)


def test_create_and_destroy():
    g = Hypergraph()
    assert g.count_vertices() == 0
    assert g.count_hyperedges() == 0


def test_add_vertex():
    g = Hypergraph()
    vid = g.create_vertex({"x": 1})
    assert g.count_vertices() == 1
    assert g.get_vertex(vid) == {"x": 1}


def test_add_multiple_vertices():
    g = Hypergraph()
    ids = [g.create_vertex({"i": i}) for i in range(5)]
    assert g.count_vertices() == 5
    assert g.get_all_vertex_ids() == ids


def test_update_vertex():
    g = Hypergraph()
    vid = g.create_vertex({"x": 1})
    g.update_vertex(vid, {"x": 99})
    assert g.get_vertex(vid) == {"x": 99}


def test_delete_vertex():
    g = Hypergraph()
    vid = g.create_vertex({"x": 1})
    g.build()
    g.delete_vertex(vid)
    assert g.count_vertices() == 0
    with pytest.raises(VertexNotFoundError):
        g.get_vertex(vid)


def test_add_hyperedge():
    g = Hypergraph()
    eid = g.create_hyperedge({"label": "e"})
    assert g.count_hyperedges() == 1
    assert g.get_hyperedge(eid) == {"label": "e"}


def test_update_hyperedge():
    g = Hypergraph()
    eid = g.create_hyperedge({"label": "old"})
    g.update_hyperedge(eid, {"label": "new"})
    assert g.get_hyperedge(eid) == {"label": "new"}


def test_delete_hyperedge():
    g = Hypergraph()
    eid = g.create_hyperedge({"label": "e"})
    g.delete_hyperedge(eid)
    assert g.count_hyperedges() == 0
    with pytest.raises(HyperedgeNotFoundError):
        g.get_hyperedge(eid)


def test_connect_and_hyperedge_vertices():
    g = Hypergraph()
    va = g.create_vertex({"n": "a"})
    vb = g.create_vertex({"n": "b"})
    eid = g.create_hyperedge({})
    g.append_vertices(eid, [va, vb])
    assert g.get_hyperedge_vertices(eid) == [va, vb]


def test_vertex_hyperedges_requires_build():
    g = Hypergraph()
    va = g.create_vertex({})
    eid = g.create_hyperedge({})
    g.append_vertices(eid, [va])
    with pytest.raises(NotBuiltError):
        g.get_vertex_hyperedges(va)


def test_vertex_hyperedges_after_build():
    g = Hypergraph()
    va = g.create_vertex({})
    e1 = g.create_hyperedge({})
    e2 = g.create_hyperedge({})
    g.append_vertices(e1, [va])
    g.append_vertices(e2, [va])
    g.build()
    assert sorted(g.get_vertex_hyperedges(va)) == sorted([e1, e2])


def test_build_and_clear():
    g = Hypergraph()
    g.create_vertex({})
    g.build()
    g.clear()
    assert g.count_vertices() == 0
    assert g.count_hyperedges() == 0


def test_is_connected_simple(built_graph):
    assert built_graph.is_connected() is True


def test_shortest_path(built_graph):
    ids = built_graph.get_all_vertex_ids()
    va, _vb, vc = ids[0], ids[1], ids[2]
    path = built_graph.find_shortest_path(va, vc)
    assert path is not None
    assert path[0] == va
    assert path[-1] == vc


def test_shortest_path_no_path():
    g = Hypergraph()
    va = g.create_vertex({})
    vb = g.create_vertex({})
    g.build()
    assert g.find_shortest_path(va, vb) is None


def test_connected_components(built_graph):
    components = built_graph.get_connected_components()
    assert len(components) == 1
    assert len(components[0]) == 3


def test_connected_components_isolated():
    g = Hypergraph()
    va = g.create_vertex({})
    vb = g.create_vertex({})
    g.create_vertex({})
    eid = g.create_hyperedge({})
    g.append_vertices(eid, [va, vb])
    g.build()
    components = g.get_connected_components()
    assert len(components) == 2
    sizes = sorted(len(c) for c in components)
    assert sizes == [1, 2]


def test_cut_vertices():
    g = Hypergraph()
    va = g.create_vertex({})
    vb = g.create_vertex({})
    vc = g.create_vertex({})
    e1 = g.create_hyperedge({})
    e2 = g.create_hyperedge({})
    g.append_vertices(e1, [va, vb])
    g.append_vertices(e2, [vb, vc])
    g.build()
    assert g.find_cut_vertices() == [vb]


def test_neighborhood(built_graph):
    ids = built_graph.get_all_vertex_ids()
    vb = ids[1]
    neighbors = built_graph.get_vertex_neighborhood(vb)
    assert set(neighbors) == {ids[0], ids[2]}


def test_topological_sort():
    g = Hypergraph()
    va = g.create_vertex({})
    vb = g.create_vertex({})
    vc = g.create_vertex({})
    e1 = g.create_hyperedge({})
    e2 = g.create_hyperedge({})
    g.append_vertices(e1, [va, vb])
    g.append_vertices(e2, [vb, vc])
    g.build()
    order = g.topological_sort()
    assert order.index(va) < order.index(vb) < order.index(vc)
