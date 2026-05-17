import pytest

from hypergraphz import Hypergraph


@pytest.fixture
def empty_graph() -> Hypergraph:
    return Hypergraph()


@pytest.fixture
def built_graph() -> Hypergraph:
    """A small built graph: vertices a/b/c connected via two hyperedges."""
    g = Hypergraph()
    va = g.create_vertex({"name": "a", "score": 1})
    vb = g.create_vertex({"name": "b", "score": 2})
    vc = g.create_vertex({"name": "c", "score": 3})
    e1 = g.create_hyperedge({"label": "e1"})
    e2 = g.create_hyperedge({"label": "e2"})
    g.append_vertices(e1, [va, vb])
    g.append_vertices(e2, [vb, vc])
    g.build()
    return g
