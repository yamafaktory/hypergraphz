"""Fluent query builder tests."""

import pytest

from hypergraphz import Hypergraph


@pytest.fixture
def labeled_graph() -> Hypergraph:
    g = Hypergraph()
    g.create_vertex({"name": "alice", "age": 30, "active": True})
    g.create_vertex({"name": "bob", "age": 25, "active": False})
    g.create_vertex({"name": "carol", "age": 35, "active": True})
    e = g.create_hyperedge({"type": "collab"})
    ids = g.get_all_vertex_ids()
    g.append_vertices(e, ids)
    g.build()
    return g


def test_vertices_all_ids(labeled_graph):
    ids = labeled_graph.vertices().ids()
    assert len(ids) == 3


def test_vertices_all_data(labeled_graph):
    data = labeled_graph.vertices().data()
    names = {d["name"] for d in data}
    assert names == {"alice", "bob", "carol"}


def test_vertices_where_filter(labeled_graph):
    data = labeled_graph.vertices().where(lambda d: d["active"]).data()
    assert len(data) == 2
    assert all(d["active"] for d in data)


def test_vertices_where_chained(labeled_graph):
    ids = labeled_graph.vertices().where(lambda d: d["active"]).where(lambda d: d["age"] > 30).ids()
    assert len(ids) == 1
    assert labeled_graph.get_vertex(ids[0])["name"] == "carol"


def test_vertices_limit(labeled_graph):
    ids = labeled_graph.vertices().limit(2).ids()
    assert len(ids) == 2


def test_vertices_neighbors(labeled_graph):
    alice_id = labeled_graph.vertices().where(lambda d: d["name"] == "alice").ids()[0]
    neighbor_ids = labeled_graph.vertices().__class__(labeled_graph, [alice_id]).neighbors().ids()
    assert len(neighbor_ids) == 2


def test_hyperedges_all_ids(labeled_graph):
    ids = labeled_graph.hyperedges().ids()
    assert len(ids) == 1


def test_hyperedges_where(labeled_graph):
    data = labeled_graph.hyperedges().where(lambda d: d["type"] == "collab").data()
    assert len(data) == 1
    assert data[0]["type"] == "collab"


def test_hyperedges_where_no_match(labeled_graph):
    ids = labeled_graph.hyperedges().where(lambda d: d["type"] == "missing").ids()
    assert ids == []


def test_hyperedges_containing(labeled_graph):
    vids = labeled_graph.vertices().where(lambda d: d["name"] == "alice").ids()
    assert len(vids) == 1
    eids = labeled_graph.hyperedges().containing(vids[0]).ids()
    assert len(eids) == 1


def test_hyperedges_limit(labeled_graph):
    g = Hypergraph()
    g.create_vertex({})
    e1 = g.create_hyperedge({"n": 1})
    e2 = g.create_hyperedge({"n": 2})
    g.create_hyperedge({"n": 3})
    g.build()
    ids = g.hyperedges().limit(2).ids()
    assert len(ids) == 2
    assert ids == [e1, e2]
