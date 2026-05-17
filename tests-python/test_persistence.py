"""Save / load round-trip tests."""

import tempfile
from pathlib import Path

import pytest

from hypergraphz import Hypergraph


def _build_graph() -> tuple[Hypergraph, list[int], list[int]]:
    g = Hypergraph()
    va = g.create_vertex({"name": "a"})
    vb = g.create_vertex({"name": "b"})
    vc = g.create_vertex({"name": "c"})
    e1 = g.create_hyperedge({"label": "e1"})
    e2 = g.create_hyperedge({"label": "e2"})
    g.append_vertices(e1, [va, vb])
    g.append_vertices(e2, [vb, vc])
    g.build()
    return g, [va, vb, vc], [e1, e2]


def test_save_and_load_vertex_data():
    g, vids, _ = _build_graph()
    with tempfile.NamedTemporaryFile(suffix=".hgpz", delete=False) as f:
        path = Path(f.name)
    try:
        g.save(path)
        g2 = Hypergraph.load(path)
        g2.build()
        assert g2.count_vertices() == 3
        for vid in vids:
            assert g2.get_vertex(vid) == g.get_vertex(vid)
    finally:
        path.unlink(missing_ok=True)


def test_save_and_load_hyperedge_data():
    g, _, eids = _build_graph()
    with tempfile.NamedTemporaryFile(suffix=".hgpz", delete=False) as f:
        path = Path(f.name)
    try:
        g.save(path)
        g2 = Hypergraph.load(path)
        g2.build()
        assert g2.count_hyperedges() == 2
        for eid in eids:
            assert g2.get_hyperedge(eid) == g.get_hyperedge(eid)
    finally:
        path.unlink(missing_ok=True)


def test_save_and_load_relations():
    g, vids, eids = _build_graph()
    with tempfile.NamedTemporaryFile(suffix=".hgpz", delete=False) as f:
        path = Path(f.name)
    try:
        g.save(path)
        g2 = Hypergraph.load(path)
        g2.build()
        assert g2.get_hyperedge_vertices(eids[0]) == [vids[0], vids[1]]
        assert g2.get_hyperedge_vertices(eids[1]) == [vids[1], vids[2]]
    finally:
        path.unlink(missing_ok=True)


def test_save_and_load_connectivity():
    g, vids, _ = _build_graph()
    with tempfile.NamedTemporaryFile(suffix=".hgpz", delete=False) as f:
        path = Path(f.name)
    try:
        g.save(path)
        g2 = Hypergraph.load(path)
        g2.build()
        path2 = g2.find_shortest_path(vids[0], vids[2])
        assert path2 is not None
        assert path2[0] == vids[0]
        assert path2[-1] == vids[2]
    finally:
        path.unlink(missing_ok=True)


def test_load_missing_file():
    from hypergraphz import HypergraphZError

    with pytest.raises(HypergraphZError):
        Hypergraph.load("/nonexistent/path/graph.hgpz")
