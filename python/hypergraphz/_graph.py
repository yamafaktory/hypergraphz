from __future__ import annotations

import ctypes
import json
from pathlib import Path
from typing import TYPE_CHECKING

from . import _binding as _b
from ._errors import raise_for_code

if TYPE_CHECKING:
    from ._query import HyperedgeQuery, VertexQuery

_lib = _b.lib


def _safe_free(ptr: ctypes.POINTER, length: int) -> None:
    """Free a Zig-owned array only when length > 0.

    Zig's c_allocator returns undefined (not NULL) for zero-length allocations, so
    calling free() on such a pointer crashes. Any caller must guard via this function.
    """
    if length > 0:
        _lib.hgz_free(ptr)


def _read_ids(ptr: ctypes.POINTER, length: int) -> list[int]:
    """Copy a Zig-allocated ID array into a Python list, then free the Zig memory."""
    if length == 0:
        return []
    ids = list(ptr[:length])
    _lib.hgz_free(ptr)
    return ids


class Hypergraph:
    """High-level Python wrapper around the HypergraphZ Zig library.

    Lifecycle:
        g = Hypergraph()          # empty, build phase
        g = Hypergraph.load(path) # loaded, build phase
        g.build()                 # switch to query phase

    After build() all query operations are available. Mutations after build()
    maintain the reverse index incrementally.
    """

    def __init__(self) -> None:
        self._ptr = _lib.hgz_create()
        if not self._ptr:
            raise MemoryError("hgz_create returned null")

    def __del__(self) -> None:
        if self._ptr:
            _lib.hgz_destroy(self._ptr)
            self._ptr = None

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    def build(self) -> None:
        """Build the reverse index (vertex → hyperedges). Required before queries."""
        raise_for_code(_lib.hgz_build(self._ptr), _lib)

    def clear(self) -> None:
        """Remove all vertices and hyperedges, returning to build phase."""
        _lib.hgz_clear(self._ptr)

    def save(self, path: str | Path) -> None:
        """Persist the graph to a binary file (.hgpz format)."""
        raise_for_code(_lib.hgz_save(self._ptr, str(path).encode()), _lib)

    @classmethod
    def load(cls, path: str | Path) -> Hypergraph:
        """Load a graph from a binary file. Call build() before querying."""
        g = object.__new__(cls)
        g._ptr = None
        handle = ctypes.c_void_p()
        raise_for_code(
            _lib.hgz_load(str(path).encode(), ctypes.byref(handle)),
            _lib,
        )
        g._ptr = handle.value
        return g

    # ── Vertices ───────────────────────────────────────────────────────────────

    def add_vertex(self, data: dict) -> int:
        """Add a vertex with JSON-serialisable data. Returns the vertex ID."""
        raw = json.dumps(data).encode()
        out = _b._Id(0)
        raise_for_code(_lib.hgz_add_vertex(self._ptr, raw, len(raw), ctypes.byref(out)), _lib)
        return out.value

    def delete_vertex(self, vertex_id: int) -> None:
        raise_for_code(_lib.hgz_delete_vertex(self._ptr, vertex_id), _lib)

    def update_vertex(self, vertex_id: int, data: dict) -> None:
        raw = json.dumps(data).encode()
        raise_for_code(
            _lib.hgz_update_vertex(self._ptr, vertex_id, raw, len(raw)),
            _lib,
        )

    def get_vertex(self, vertex_id: int) -> dict:
        ptr = ctypes.c_char_p()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_vertex_json(self._ptr, vertex_id, ctypes.byref(ptr), ctypes.byref(length)),
            _lib,
        )
        return json.loads(ctypes.string_at(ptr, length.value))

    def vertex_count(self) -> int:
        return _lib.hgz_vertex_count(self._ptr)

    def all_vertex_ids(self) -> list[int]:
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_all_vertex_ids(self._ptr, ctypes.byref(ptr), ctypes.byref(length)),
            _lib,
        )
        return _read_ids(ptr, length.value)

    # ── Hyperedges ─────────────────────────────────────────────────────────────

    def add_hyperedge(self, data: dict) -> int:
        """Add a hyperedge with JSON-serialisable data. Returns the hyperedge ID."""
        raw = json.dumps(data).encode()
        out = _b._Id(0)
        raise_for_code(_lib.hgz_add_hyperedge(self._ptr, raw, len(raw), ctypes.byref(out)), _lib)
        return out.value

    def delete_hyperedge(self, hyperedge_id: int, *, drop_vertices: bool = False) -> None:
        raise_for_code(_lib.hgz_delete_hyperedge(self._ptr, hyperedge_id, drop_vertices), _lib)

    def update_hyperedge(self, hyperedge_id: int, data: dict) -> None:
        raw = json.dumps(data).encode()
        raise_for_code(
            _lib.hgz_update_hyperedge(self._ptr, hyperedge_id, raw, len(raw)),
            _lib,
        )

    def get_hyperedge(self, hyperedge_id: int) -> dict:
        ptr = ctypes.c_char_p()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_hyperedge_json(
                self._ptr, hyperedge_id, ctypes.byref(ptr), ctypes.byref(length)
            ),
            _lib,
        )
        return json.loads(ctypes.string_at(ptr, length.value))

    def hyperedge_count(self) -> int:
        return _lib.hgz_hyperedge_count(self._ptr)

    def all_hyperedge_ids(self) -> list[int]:
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_all_hyperedge_ids(self._ptr, ctypes.byref(ptr), ctypes.byref(length)),
            _lib,
        )
        return _read_ids(ptr, length.value)

    # ── Relations ──────────────────────────────────────────────────────────────

    def connect(self, hyperedge_id: int, vertex_ids: list[int]) -> None:
        """Append vertices to a hyperedge (ordered; duplicates allowed)."""
        arr = (_b._Id * len(vertex_ids))(*vertex_ids)
        raise_for_code(
            _lib.hgz_append_vertices(self._ptr, hyperedge_id, arr, len(vertex_ids)),
            _lib,
        )

    def hyperedge_vertices(self, hyperedge_id: int) -> list[int]:
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_hyperedge_vertex_ids(
                self._ptr, hyperedge_id, ctypes.byref(ptr), ctypes.byref(length)
            ),
            _lib,
        )
        return _read_ids(ptr, length.value)

    def vertex_hyperedges(self, vertex_id: int) -> list[int]:
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_vertex_hyperedge_ids(
                self._ptr, vertex_id, ctypes.byref(ptr), ctypes.byref(length)
            ),
            _lib,
        )
        return _read_ids(ptr, length.value)

    # ── Traversal ──────────────────────────────────────────────────────────────

    def shortest_path(self, from_id: int, to_id: int) -> list[int] | None:
        """Return the shortest directed path as a vertex ID list, or None if unreachable."""
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        code = _lib.hgz_find_shortest_path(
            self._ptr, from_id, to_id, ctypes.byref(ptr), ctypes.byref(length)
        )
        if code == -7:  # no_path
            return None
        raise_for_code(code, _lib)
        return _read_ids(ptr, length.value)

    def is_connected(self) -> bool:
        result = _lib.hgz_is_connected(self._ptr)
        if result < 0:
            raise_for_code(result, _lib)
        return bool(result)

    # ── Algorithms ─────────────────────────────────────────────────────────────

    def connected_components(self) -> list[list[int]]:
        """Return each weakly-connected component as a list of vertex IDs."""
        flat_ptr = _b._PId()
        sizes_ptr = ctypes.POINTER(ctypes.c_size_t)()
        count = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_connected_components(
                self._ptr,
                ctypes.byref(flat_ptr),
                ctypes.byref(sizes_ptr),
                ctypes.byref(count),
            ),
            _lib,
        )
        n = count.value
        sizes = list(sizes_ptr[:n]) if n > 0 else []
        _safe_free(sizes_ptr, n)
        total = sum(sizes)
        flat = list(flat_ptr[:total]) if total > 0 else []
        _safe_free(flat_ptr, total)
        components, offset = [], 0
        for size in sizes:
            components.append(flat[offset : offset + size])
            offset += size
        return components

    def cut_vertices(self) -> list[int]:
        """Return vertex IDs whose removal increases the number of connected components."""
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_find_cut_vertices(self._ptr, ctypes.byref(ptr), ctypes.byref(length)),
            _lib,
        )
        return _read_ids(ptr, length.value)

    def neighborhood(self, vertex_id: int) -> list[int]:
        """Return IDs of vertices sharing at least one hyperedge (clique-expansion adjacency)."""
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_vertex_neighborhood(
                self._ptr, vertex_id, ctypes.byref(ptr), ctypes.byref(length)
            ),
            _lib,
        )
        return _read_ids(ptr, length.value)

    def topological_sort(self) -> list[int]:
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_topological_sort(self._ptr, ctypes.byref(ptr), ctypes.byref(length)),
            _lib,
        )
        return _read_ids(ptr, length.value)

    # ── Degree ─────────────────────────────────────────────────────────────────

    def vertex_indegree(self, vertex_id: int) -> int:
        """Number of hyperedges in which this vertex appears as a non-first member."""
        out = ctypes.c_size_t(0)
        raise_for_code(_lib.hgz_get_vertex_indegree(self._ptr, vertex_id, ctypes.byref(out)), _lib)
        return out.value

    def vertex_outdegree(self, vertex_id: int) -> int:
        """Number of hyperedges in which this vertex appears as a non-last member."""
        out = ctypes.c_size_t(0)
        raise_for_code(_lib.hgz_get_vertex_outdegree(self._ptr, vertex_id, ctypes.byref(out)), _lib)
        return out.value

    # ── Boolean queries ────────────────────────────────────────────────────────

    def is_reachable(self, from_id: int, to_id: int) -> bool:
        """Return True if to_id is reachable from from_id via directed hyperedge pairs."""
        result = _lib.hgz_is_reachable(self._ptr, from_id, to_id)
        if result < 0:
            raise_for_code(result, _lib)
        return bool(result)

    def has_cycle(self) -> bool:
        """Return True if the directed hypergraph contains a cycle."""
        result = _lib.hgz_has_cycle(self._ptr)
        if result < 0:
            raise_for_code(result, _lib)
        return bool(result)

    def is_k_uniform(self, k: int) -> bool:
        """Return True if every hyperedge contains exactly k vertices."""
        result = _lib.hgz_is_k_uniform(self._ptr, k)
        if result < 0:
            raise_for_code(result, _lib)
        return bool(result)

    # ── Extended traversal ─────────────────────────────────────────────────────

    def bfs(self, start_id: int) -> list[int]:
        """Breadth-first search from start_id. Returns visited vertex IDs in BFS order."""
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_bfs(self._ptr, start_id, ctypes.byref(ptr), ctypes.byref(length)), _lib
        )
        return _read_ids(ptr, length.value)

    def dfs(self, start_id: int) -> list[int]:
        """Depth-first search from start_id. Returns visited vertex IDs in DFS order."""
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_dfs(self._ptr, start_id, ctypes.byref(ptr), ctypes.byref(length)), _lib
        )
        return _read_ids(ptr, length.value)

    def random_walk(self, start_id: int, steps: int) -> list[int]:
        """Random walk of `steps` steps. Returns vertex ID sequence of length steps+1."""
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_random_walk(
                self._ptr, start_id, steps, ctypes.byref(ptr), ctypes.byref(length)
            ),
            _lib,
        )
        return _read_ids(ptr, length.value)

    # ── Orphan queries ─────────────────────────────────────────────────────────

    def orphan_vertices(self) -> list[int]:
        """Return vertex IDs that belong to no hyperedge."""
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_orphan_vertices(self._ptr, ctypes.byref(ptr), ctypes.byref(length)), _lib
        )
        return _read_ids(ptr, length.value)

    def orphan_hyperedges(self) -> list[int]:
        """Return hyperedge IDs that contain no vertices."""
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_orphan_hyperedges(self._ptr, ctypes.byref(ptr), ctypes.byref(length)),
            _lib,
        )
        return _read_ids(ptr, length.value)

    # ── Set operations ─────────────────────────────────────────────────────────

    def intersections(self, hyperedge_ids: list[int]) -> list[int]:
        """Return vertex IDs present in ALL given hyperedges (requires ≥2 IDs)."""
        arr = (_b._Id * len(hyperedge_ids))(*hyperedge_ids)
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_intersections(
                self._ptr, arr, len(hyperedge_ids), ctypes.byref(ptr), ctypes.byref(length)
            ),
            _lib,
        )
        return _read_ids(ptr, length.value)

    def hyperedges_connecting(self, v1_id: int, v2_id: int) -> list[int]:
        """Return IDs of hyperedges that contain both v1_id and v2_id."""
        ptr = _b._PId()
        length = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_hyperedges_connecting(
                self._ptr, v1_id, v2_id, ctypes.byref(ptr), ctypes.byref(length)
            ),
            _lib,
        )
        return _read_ids(ptr, length.value)

    # ── Endpoints ──────────────────────────────────────────────────────────────

    def endpoints(
        self,
    ) -> tuple[list[tuple[int, int]], list[tuple[int, int]]]:
        """Return (initial, terminal) endpoint pairs as (hyperedge_id, vertex_id) tuples."""
        ihe_ptr = _b._PId()
        iv_ptr = _b._PId()
        in_ = ctypes.c_size_t(0)
        the_ptr = _b._PId()
        tv_ptr = _b._PId()
        tn = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_endpoints(
                self._ptr,
                ctypes.byref(ihe_ptr),
                ctypes.byref(iv_ptr),
                ctypes.byref(in_),
                ctypes.byref(the_ptr),
                ctypes.byref(tv_ptr),
                ctypes.byref(tn),
            ),
            _lib,
        )
        ni, nt = in_.value, tn.value
        initial = list(zip(list(ihe_ptr[:ni]), list(iv_ptr[:ni]), strict=False))
        terminal = list(zip(list(the_ptr[:nt]), list(tv_ptr[:nt]), strict=False))
        _safe_free(ihe_ptr, ni)
        _safe_free(iv_ptr, ni)
        _safe_free(the_ptr, nt)
        _safe_free(tv_ptr, nt)
        return initial, terminal

    # ── Relation mutations ─────────────────────────────────────────────────────

    def prepend(self, hyperedge_id: int, vertex_ids: list[int]) -> None:
        """Prepend vertices to the front of a hyperedge's relation list."""
        arr = (_b._Id * len(vertex_ids))(*vertex_ids)
        raise_for_code(
            _lib.hgz_prepend_vertices(self._ptr, hyperedge_id, arr, len(vertex_ids)), _lib
        )

    def insert_vertex(self, hyperedge_id: int, vertex_id: int, index: int) -> None:
        """Insert a single vertex at the given position in a hyperedge."""
        raise_for_code(_lib.hgz_insert_vertex(self._ptr, hyperedge_id, vertex_id, index), _lib)

    def insert_many(self, hyperedge_id: int, vertex_ids: list[int], index: int) -> None:
        """Insert multiple vertices at the given position in a hyperedge."""
        arr = (_b._Id * len(vertex_ids))(*vertex_ids)
        raise_for_code(
            _lib.hgz_insert_vertices(self._ptr, hyperedge_id, arr, len(vertex_ids), index), _lib
        )

    def disconnect(self, hyperedge_id: int, vertex_id: int) -> None:
        """Remove the first occurrence of vertex_id from hyperedge_id."""
        raise_for_code(
            _lib.hgz_remove_vertex_from_hyperedge(self._ptr, hyperedge_id, vertex_id), _lib
        )

    def disconnect_at(self, hyperedge_id: int, index: int) -> None:
        """Remove the vertex at the given index from hyperedge_id."""
        raise_for_code(_lib.hgz_remove_vertex_at_index(self._ptr, hyperedge_id, index), _lib)

    # ── Centrality and PageRank ────────────────────────────────────────────────

    def centrality(self) -> dict[int, dict[str, float]]:
        """Compute degree, closeness, and betweenness centrality for all vertices."""
        ids_ptr = _b._PId()
        deg_ptr = _b._PDouble()
        clo_ptr = _b._PDouble()
        bet_ptr = _b._PDouble()
        n = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_compute_centrality(
                self._ptr,
                ctypes.byref(ids_ptr),
                ctypes.byref(deg_ptr),
                ctypes.byref(clo_ptr),
                ctypes.byref(bet_ptr),
                ctypes.byref(n),
            ),
            _lib,
        )
        count = n.value
        result = {
            ids_ptr[i]: {
                "degree": deg_ptr[i],
                "closeness": clo_ptr[i],
                "betweenness": bet_ptr[i],
            }
            for i in range(count)
        }
        _safe_free(ids_ptr, count)
        _safe_free(deg_ptr, count)
        _safe_free(clo_ptr, count)
        _safe_free(bet_ptr, count)
        return result

    def page_rank(
        self,
        damping: float = 0.85,
        max_iterations: int = 100,
        tolerance: float = 1e-6,
    ) -> tuple[dict[int, float], int, bool]:
        """Compute PageRank scores. Returns (scores_by_id, iterations, converged)."""
        ids_ptr = _b._PId()
        scores_ptr = _b._PDouble()
        n = ctypes.c_size_t(0)
        iterations = ctypes.c_size_t(0)
        converged = ctypes.c_bool(False)
        raise_for_code(
            _lib.hgz_compute_page_rank(
                self._ptr,
                damping,
                max_iterations,
                tolerance,
                ctypes.byref(ids_ptr),
                ctypes.byref(scores_ptr),
                ctypes.byref(n),
                ctypes.byref(iterations),
                ctypes.byref(converged),
            ),
            _lib,
        )
        count = n.value
        scores = {ids_ptr[i]: scores_ptr[i] for i in range(count)}
        _safe_free(ids_ptr, count)
        _safe_free(scores_ptr, count)
        return scores, iterations.value, converged.value

    # ── Structural analysis ────────────────────────────────────────────────────

    def inclusions(self) -> list[tuple[int, int]]:
        """Return (subset_id, superset_id) pairs where one hyperedge's vertices ⊆ another's."""
        subsets_ptr = _b._PId()
        supersets_ptr = _b._PId()
        n = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_inclusions(
                self._ptr,
                ctypes.byref(subsets_ptr),
                ctypes.byref(supersets_ptr),
                ctypes.byref(n),
            ),
            _lib,
        )
        count = n.value
        result = list(zip(list(subsets_ptr[:count]), list(supersets_ptr[:count]), strict=False))
        _safe_free(subsets_ptr, count)
        _safe_free(supersets_ptr, count)
        return result

    def nestedness_profile(self) -> list[dict]:
        """Per-order nestedness profile: list of {size, included, total} dicts."""
        sizes_ptr = ctypes.POINTER(ctypes.c_size_t)()
        included_ptr = ctypes.POINTER(ctypes.c_size_t)()
        total_ptr = ctypes.POINTER(ctypes.c_size_t)()
        n = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_get_nestedness_profile(
                self._ptr,
                ctypes.byref(sizes_ptr),
                ctypes.byref(included_ptr),
                ctypes.byref(total_ptr),
                ctypes.byref(n),
            ),
            _lib,
        )
        count = n.value
        result = [
            {"size": sizes_ptr[i], "included": included_ptr[i], "total": total_ptr[i]}
            for i in range(count)
        ]
        _safe_free(sizes_ptr, count)
        _safe_free(included_ptr, count)
        _safe_free(total_ptr, count)
        return result

    def incidence_matrix(self) -> dict:
        """Dense incidence matrix (vertices × hyperedges).

        Returns {"data": list[list[int]], "vertex_ids": list[int], "hyperedge_ids": list[int]}.
        """
        data_ptr = _b._PUInt8()
        vertex_ids_ptr = _b._PId()
        hyperedge_ids_ptr = _b._PId()
        rows = ctypes.c_size_t(0)
        cols = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_incidence_matrix(
                self._ptr,
                ctypes.byref(data_ptr),
                ctypes.byref(vertex_ids_ptr),
                ctypes.byref(hyperedge_ids_ptr),
                ctypes.byref(rows),
                ctypes.byref(cols),
            ),
            _lib,
        )
        r, c = rows.value, cols.value
        data = [[data_ptr[i * c + j] for j in range(c)] for i in range(r)]
        vertex_ids = list(vertex_ids_ptr[:r])
        hyperedge_ids = list(hyperedge_ids_ptr[:c])
        _safe_free(data_ptr, r * c)
        _safe_free(vertex_ids_ptr, r)
        _safe_free(hyperedge_ids_ptr, c)
        return {"data": data, "vertex_ids": vertex_ids, "hyperedge_ids": hyperedge_ids}

    def incidence_matrix_coo(self) -> dict:
        """Sparse incidence matrix in COO format.

        Returns {"rows", "cols", "vertex_ids", "hyperedge_ids"} as lists.
        """
        row_ptr = _b._PId()
        col_ptr = _b._PId()
        vertex_ids_ptr = _b._PId()
        hyperedge_ids_ptr = _b._PId()
        nnz = ctypes.c_size_t(0)
        n_vertices = ctypes.c_size_t(0)
        n_hyperedges = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_incidence_matrix_coo(
                self._ptr,
                ctypes.byref(row_ptr),
                ctypes.byref(col_ptr),
                ctypes.byref(vertex_ids_ptr),
                ctypes.byref(hyperedge_ids_ptr),
                ctypes.byref(nnz),
                ctypes.byref(n_vertices),
                ctypes.byref(n_hyperedges),
            ),
            _lib,
        )
        nz = nnz.value
        nv, nhe = n_vertices.value, n_hyperedges.value
        result = {
            "rows": list(row_ptr[:nz]),
            "cols": list(col_ptr[:nz]),
            "vertex_ids": list(vertex_ids_ptr[:nv]),
            "hyperedge_ids": list(hyperedge_ids_ptr[:nhe]),
        }
        _safe_free(row_ptr, nz)
        _safe_free(col_ptr, nz)
        _safe_free(vertex_ids_ptr, nv)
        _safe_free(hyperedge_ids_ptr, nhe)
        return result

    def laplacian(self, normalized: bool = True) -> dict:
        """Dense Laplacian matrix (n×n, row-major).

        Returns {"data": list[list[float]], "vertex_ids": list[int]}.
        normalized=True uses the Zhou normalized variant; False gives unnormalized.
        """
        variant = ctypes.c_uint8(1 if normalized else 0)
        data_ptr = _b._PDouble()
        vertex_ids_ptr = _b._PId()
        n = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_laplacian(
                self._ptr,
                variant,
                ctypes.byref(data_ptr),
                ctypes.byref(vertex_ids_ptr),
                ctypes.byref(n),
            ),
            _lib,
        )
        size = n.value
        data = [[data_ptr[i * size + j] for j in range(size)] for i in range(size)]
        vertex_ids = list(vertex_ids_ptr[:size])
        _safe_free(data_ptr, size * size)
        _safe_free(vertex_ids_ptr, size)
        return {"data": data, "vertex_ids": vertex_ids}

    def all_paths(self, from_id: int, to_id: int) -> list[list[int]]:
        """Return all simple directed paths from from_id to to_id."""
        flat_ptr = _b._PId()
        sizes_ptr = ctypes.POINTER(ctypes.c_size_t)()
        count = ctypes.c_size_t(0)
        raise_for_code(
            _lib.hgz_find_all_paths(
                self._ptr,
                from_id,
                to_id,
                ctypes.byref(flat_ptr),
                ctypes.byref(sizes_ptr),
                ctypes.byref(count),
            ),
            _lib,
        )
        n = count.value
        sizes = list(sizes_ptr[:n]) if n > 0 else []
        _safe_free(sizes_ptr, n)
        total = sum(sizes)
        flat = list(flat_ptr[:total]) if total > 0 else []
        _safe_free(flat_ptr, total)
        paths: list[list[int]] = []
        offset = 0
        for size in sizes:
            paths.append(flat[offset : offset + size])
            offset += size
        return paths

    # ── Sub-graph operations ───────────────────────────────────────────────────

    def _wrap_handle(self, out_handle: ctypes.c_void_p) -> Hypergraph:
        g = object.__new__(Hypergraph)
        g._ptr = out_handle.value
        return g

    def clone(self) -> Hypergraph:
        """Return an independent deep copy of this graph."""
        out = ctypes.c_void_p()
        raise_for_code(_lib.hgz_clone(self._ptr, ctypes.byref(out)), _lib)
        return self._wrap_handle(out)

    def dual(self) -> Hypergraph:
        """Return the dual hypergraph (vertices ↔ hyperedges)."""
        out = ctypes.c_void_p()
        raise_for_code(_lib.hgz_get_dual(self._ptr, ctypes.byref(out)), _lib)
        return self._wrap_handle(out)

    def k_skeleton(self, k: int) -> Hypergraph:
        """Return all vertices and only hyperedges with at most k vertices."""
        out = ctypes.c_void_p()
        raise_for_code(_lib.hgz_get_k_skeleton(self._ptr, k, ctypes.byref(out)), _lib)
        return self._wrap_handle(out)

    def expand_to_graph(self) -> Hypergraph:
        """Expand to a simple directed graph via consecutive-pair edges."""
        out = ctypes.c_void_p()
        raise_for_code(_lib.hgz_expand_to_graph(self._ptr, ctypes.byref(out)), _lib)
        return self._wrap_handle(out)

    def expand_to_star(self) -> Hypergraph:
        """Expand each hyperedge to a star graph (hub + spoke edges)."""
        out = ctypes.c_void_p()
        raise_for_code(_lib.hgz_expand_to_star(self._ptr, ctypes.byref(out)), _lib)
        return self._wrap_handle(out)

    def line_graph(self) -> Hypergraph:
        """Return the line graph (hyperedges become vertices, sharing a vertex = edge)."""
        out = ctypes.c_void_p()
        raise_for_code(_lib.hgz_get_line_graph(self._ptr, ctypes.byref(out)), _lib)
        return self._wrap_handle(out)

    def vertex_induced_subgraph(self, vertex_ids: list[int]) -> Hypergraph:
        """Return the subhypergraph induced by the given vertex IDs."""
        arr = (_b._Id * len(vertex_ids))(*vertex_ids)
        out = ctypes.c_void_p()
        raise_for_code(
            _lib.hgz_get_vertex_induced_subhypergraph(
                self._ptr, arr, len(vertex_ids), ctypes.byref(out)
            ),
            _lib,
        )
        return self._wrap_handle(out)

    def edge_induced_subgraph(self, hyperedge_ids: list[int]) -> Hypergraph:
        """Return the subhypergraph induced by the given hyperedge IDs."""
        arr = (_b._Id * len(hyperedge_ids))(*hyperedge_ids)
        out = ctypes.c_void_p()
        raise_for_code(
            _lib.hgz_get_edge_induced_subhypergraph(
                self._ptr, arr, len(hyperedge_ids), ctypes.byref(out)
            ),
            _lib,
        )
        return self._wrap_handle(out)

    def core(self, s: int, t: int) -> Hypergraph:
        """Return the (s,t)-core: vertices with degree≥s, hyperedges with size≥t."""
        out = ctypes.c_void_p()
        raise_for_code(_lib.hgz_get_core(self._ptr, s, t, ctypes.byref(out)), _lib)
        return self._wrap_handle(out)

    def transitive_closure(self) -> Hypergraph:
        """Return the transitive closure as a hypergraph."""
        out = ctypes.c_void_p()
        raise_for_code(_lib.hgz_get_transitive_closure(self._ptr, ctypes.byref(out)), _lib)
        return self._wrap_handle(out)

    # ── Fluent query entry points ───────────────────────────────────────────────

    def vertices(self) -> VertexQuery:
        from ._query import VertexQuery

        return VertexQuery(self)

    def hyperedges(self) -> HyperedgeQuery:
        from ._query import HyperedgeQuery

        return HyperedgeQuery(self)
