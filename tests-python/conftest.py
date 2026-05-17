import pytest

from hypergraphz import Hypergraph


@pytest.fixture
def empty_graph() -> Hypergraph:
    return Hypergraph()


@pytest.fixture
def built_graph() -> Hypergraph:
    """A small built graph: vertices a/b/c connected via two hyperedges."""
    g = Hypergraph()
    va = g.add_vertex({"name": "a", "score": 1})
    vb = g.add_vertex({"name": "b", "score": 2})
    vc = g.add_vertex({"name": "c", "score": 3})
    e1 = g.add_hyperedge({"label": "e1"})
    e2 = g.add_hyperedge({"label": "e2"})
    g.connect(e1, [va, vb])
    g.connect(e2, [vb, vc])
    g.build()
    return g
