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


def test_save_and_load_rich_payloads():
    """Non-trivial payloads (nested dict, unicode, numbers) survive the round-trip."""
    g = Hypergraph()
    v = g.create_vertex({"name": "héllo", "score": 3.14, "tags": ["a", "b"], "meta": {"x": 1}})
    e = g.create_hyperedge({"label": "ëdge", "weight": 42})
    g.append_vertices(e, [v])
    g.build()

    with tempfile.NamedTemporaryFile(suffix=".hgpz", delete=False) as f:
        path = Path(f.name)
    try:
        g.save(path)
        g2 = Hypergraph.load(path)
        g2.build()
        assert g2.get_vertex(v) == {
            "name": "héllo",
            "score": 3.14,
            "tags": ["a", "b"],
            "meta": {"x": 1},
        }
        assert g2.get_hyperedge(e) == {"label": "ëdge", "weight": 42}
    finally:
        path.unlink(missing_ok=True)


def test_mutate_after_load():
    """Loaded graph accepts mutations and re-persists correctly."""
    g, vids, eids = _build_graph()

    with tempfile.NamedTemporaryFile(suffix=".hgpz", delete=False) as f:
        path = Path(f.name)
    try:
        g.save(path)
        g2 = Hypergraph.load(path)
        g2.build()

        # Add a new vertex and connect it to the existing hyperedge.
        vd = g2.create_vertex({"name": "d"})
        g2.append_vertices(eids[1], [vd])

        assert g2.count_vertices() == 4
        assert vd in g2.get_hyperedge_vertices(eids[1])

        # Re-save and reload to confirm mutation survived persistence.
        g2.save(path)
        g3 = Hypergraph.load(path)
        g3.build()
        assert g3.count_vertices() == 4
        assert vd in g3.get_hyperedge_vertices(eids[1])
    finally:
        path.unlink(missing_ok=True)


def test_query_before_build_raises():
    """Loaded graph requires build() before queries — NotBuiltError otherwise."""
    from hypergraphz import NotBuiltError

    g, vids, _ = _build_graph()

    with tempfile.NamedTemporaryFile(suffix=".hgpz", delete=False) as f:
        path = Path(f.name)
    try:
        g.save(path)
        g2 = Hypergraph.load(path)
        with pytest.raises(NotBuiltError):
            g2.find_shortest_path(vids[0], vids[2])
    finally:
        path.unlink(missing_ok=True)


def test_save_to_invalid_path():
    """save() to a non-existent directory raises HypergraphZError."""
    from hypergraphz import HypergraphZError

    g, _, _ = _build_graph()
    with pytest.raises(HypergraphZError):
        g.save("/nonexistent/dir/graph.hgpz")
