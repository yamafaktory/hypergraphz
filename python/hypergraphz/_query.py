from __future__ import annotations

from collections.abc import Callable
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ._graph import Hypergraph


class VertexQuery:
    """Fluent query builder for vertices."""

    def __init__(self, graph: Hypergraph, ids: list[int] | None = None) -> None:
        self._graph = graph
        self._ids: list[int] | None = ids
        self._predicates: list[Callable[[dict], bool]] = []
        self._limit_n: int | None = None

    def _resolve_ids(self) -> list[int]:
        return self._ids if self._ids is not None else self._graph.get_all_vertex_ids()

    def where(self, predicate: Callable[[dict], bool]) -> VertexQuery:
        """Filter vertices by a predicate applied to their data dict."""
        q = VertexQuery(self._graph, self._ids)
        q._predicates = self._predicates + [predicate]
        q._limit_n = self._limit_n
        return q

    def neighbors(self) -> VertexQuery:
        """Expand to all neighbors of the current vertex set (clique-expansion adjacency)."""
        seen: set[int] = set()
        for vid in self._resolve_ids():
            for nid in self._graph.get_vertex_neighborhood(vid):
                seen.add(nid)
        q = VertexQuery(self._graph, list(seen))
        q._predicates = list(self._predicates)
        q._limit_n = self._limit_n
        return q

    def limit(self, n: int) -> VertexQuery:
        q = VertexQuery(self._graph, self._ids)
        q._predicates = list(self._predicates)
        q._limit_n = n
        return q

    def _execute(self) -> list[int]:
        result: list[int] = []
        for vid in self._resolve_ids():
            if self._predicates:
                data = self._graph.get_vertex(vid)
                if not all(p(data) for p in self._predicates):
                    continue
            result.append(vid)
            if self._limit_n is not None and len(result) >= self._limit_n:
                break
        return result

    def ids(self) -> list[int]:
        """Return matched vertex IDs."""
        return self._execute()

    def data(self) -> list[dict]:
        """Return data dicts for matched vertices."""
        return [self._graph.get_vertex(vid) for vid in self._execute()]


class HyperedgeQuery:
    """Fluent query builder for hyperedges."""

    def __init__(self, graph: Hypergraph, ids: list[int] | None = None) -> None:
        self._graph = graph
        self._ids: list[int] | None = ids
        self._predicates: list[Callable[[dict], bool]] = []
        self._limit_n: int | None = None

    def _resolve_ids(self) -> list[int]:
        return self._ids if self._ids is not None else self._graph.get_all_hyperedge_ids()

    def where(self, predicate: Callable[[dict], bool]) -> HyperedgeQuery:
        """Filter hyperedges by a predicate applied to their data dict."""
        q = HyperedgeQuery(self._graph, self._ids)
        q._predicates = self._predicates + [predicate]
        q._limit_n = self._limit_n
        return q

    def containing(self, vertex_id: int) -> HyperedgeQuery:
        """Filter to hyperedges that contain the given vertex ID."""
        ids = [
            eid for eid in self._resolve_ids() if vertex_id in self._graph.get_hyperedge_vertices(eid)
        ]
        q = HyperedgeQuery(self._graph, ids)
        q._predicates = list(self._predicates)
        q._limit_n = self._limit_n
        return q

    def limit(self, n: int) -> HyperedgeQuery:
        q = HyperedgeQuery(self._graph, self._ids)
        q._predicates = list(self._predicates)
        q._limit_n = n
        return q

    def _execute(self) -> list[int]:
        result: list[int] = []
        for eid in self._resolve_ids():
            if self._predicates:
                data = self._graph.get_hyperedge(eid)
                if not all(p(data) for p in self._predicates):
                    continue
            result.append(eid)
            if self._limit_n is not None and len(result) >= self._limit_n:
                break
        return result

    def ids(self) -> list[int]:
        """Return matched hyperedge IDs."""
        return self._execute()

    def data(self) -> list[dict]:
        """Return data dicts for matched hyperedges."""
        return [self._graph.get_hyperedge(eid) for eid in self._execute()]
