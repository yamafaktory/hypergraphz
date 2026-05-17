"""ctypes declarations for the HypergraphZ shared library.

This module is private. Users interact with Hypergraph in _graph.py instead.
"""

import ctypes
import pathlib
import sys

_here = pathlib.Path(__file__).parent

_NAMES = {
    "linux": "libhypergraphz.so",
    "darwin": "libhypergraphz.dylib",
    "win32": "hypergraphz.dll",
}

_lib_path = _here / _NAMES.get(sys.platform, "libhypergraphz.so")
if not _lib_path.exists():
    raise OSError(
        f"HypergraphZ native library not found at {_lib_path}. "
        "Run `zig build lib -Doptimize=ReleaseFast` then copy the output "
        "from zig-out/lib/ into python/hypergraphz/."
    )

lib = ctypes.CDLL(str(_lib_path))

# ── Types ──────────────────────────────────────────────────────────────────────

_Handle = ctypes.c_void_p
_Id = ctypes.c_uint32
_PId = ctypes.POINTER(_Id)
_PPId = ctypes.POINTER(_PId)
_PSize = ctypes.POINTER(ctypes.c_size_t)
_PPSize = ctypes.POINTER(ctypes.POINTER(ctypes.c_size_t))
_PDouble = ctypes.POINTER(ctypes.c_double)
_PPDouble = ctypes.POINTER(_PDouble)
_PUInt8 = ctypes.POINTER(ctypes.c_uint8)
_PPUInt8 = ctypes.POINTER(_PUInt8)
_PHandle = ctypes.POINTER(_Handle)

# ── Error ──────────────────────────────────────────────────────────────────────

lib.hgz_last_error.restype = ctypes.c_size_t
lib.hgz_last_error.argtypes = [ctypes.c_char_p, ctypes.c_size_t]

# ── Memory ─────────────────────────────────────────────────────────────────────

lib.hgz_free.restype = None
lib.hgz_free.argtypes = [ctypes.c_void_p]

# ── Lifecycle ──────────────────────────────────────────────────────────────────

lib.hgz_create.restype = _Handle
lib.hgz_create.argtypes = []

lib.hgz_destroy.restype = None
lib.hgz_destroy.argtypes = [_Handle]

lib.hgz_build.restype = ctypes.c_int
lib.hgz_build.argtypes = [_Handle]

lib.hgz_clear.restype = None
lib.hgz_clear.argtypes = [_Handle]

# ── Vertices ───────────────────────────────────────────────────────────────────

lib.hgz_add_vertex.restype = ctypes.c_int
lib.hgz_add_vertex.argtypes = [_Handle, ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(_Id)]

lib.hgz_delete_vertex.restype = ctypes.c_int
lib.hgz_delete_vertex.argtypes = [_Handle, _Id]

lib.hgz_update_vertex.restype = ctypes.c_int
lib.hgz_update_vertex.argtypes = [_Handle, _Id, ctypes.c_char_p, ctypes.c_size_t]

lib.hgz_get_vertex_json.restype = ctypes.c_int
lib.hgz_get_vertex_json.argtypes = [_Handle, _Id, ctypes.POINTER(ctypes.c_char_p), _PSize]

lib.hgz_vertex_count.restype = ctypes.c_size_t
lib.hgz_vertex_count.argtypes = [_Handle]

lib.hgz_get_all_vertex_ids.restype = ctypes.c_int
lib.hgz_get_all_vertex_ids.argtypes = [_Handle, _PPId, _PSize]

# ── Hyperedges ─────────────────────────────────────────────────────────────────

lib.hgz_add_hyperedge.restype = ctypes.c_int
lib.hgz_add_hyperedge.argtypes = [_Handle, ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(_Id)]

lib.hgz_delete_hyperedge.restype = ctypes.c_int
lib.hgz_delete_hyperedge.argtypes = [_Handle, _Id, ctypes.c_bool]

lib.hgz_update_hyperedge.restype = ctypes.c_int
lib.hgz_update_hyperedge.argtypes = [_Handle, _Id, ctypes.c_char_p, ctypes.c_size_t]

lib.hgz_get_hyperedge_json.restype = ctypes.c_int
lib.hgz_get_hyperedge_json.argtypes = [_Handle, _Id, ctypes.POINTER(ctypes.c_char_p), _PSize]

lib.hgz_hyperedge_count.restype = ctypes.c_size_t
lib.hgz_hyperedge_count.argtypes = [_Handle]

lib.hgz_get_all_hyperedge_ids.restype = ctypes.c_int
lib.hgz_get_all_hyperedge_ids.argtypes = [_Handle, _PPId, _PSize]

# ── Relations ──────────────────────────────────────────────────────────────────

lib.hgz_append_vertices.restype = ctypes.c_int
lib.hgz_append_vertices.argtypes = [_Handle, _Id, ctypes.POINTER(_Id), ctypes.c_size_t]

lib.hgz_get_hyperedge_vertex_ids.restype = ctypes.c_int
lib.hgz_get_hyperedge_vertex_ids.argtypes = [_Handle, _Id, _PPId, _PSize]

lib.hgz_get_vertex_hyperedge_ids.restype = ctypes.c_int
lib.hgz_get_vertex_hyperedge_ids.argtypes = [_Handle, _Id, _PPId, _PSize]

# ── Traversal ──────────────────────────────────────────────────────────────────

lib.hgz_find_shortest_path.restype = ctypes.c_int
lib.hgz_find_shortest_path.argtypes = [_Handle, _Id, _Id, _PPId, _PSize]

lib.hgz_is_connected.restype = ctypes.c_int
lib.hgz_is_connected.argtypes = [_Handle]

# ── Algorithms ─────────────────────────────────────────────────────────────────

lib.hgz_get_connected_components.restype = ctypes.c_int
lib.hgz_get_connected_components.argtypes = [
    _Handle,
    _PPId,
    ctypes.POINTER(ctypes.POINTER(ctypes.c_size_t)),
    _PSize,
]

lib.hgz_find_cut_vertices.restype = ctypes.c_int
lib.hgz_find_cut_vertices.argtypes = [_Handle, _PPId, _PSize]

lib.hgz_get_vertex_neighborhood.restype = ctypes.c_int
lib.hgz_get_vertex_neighborhood.argtypes = [_Handle, _Id, _PPId, _PSize]

lib.hgz_topological_sort.restype = ctypes.c_int
lib.hgz_topological_sort.argtypes = [_Handle, _PPId, _PSize]

# ── Degree ─────────────────────────────────────────────────────────────────────

lib.hgz_get_vertex_indegree.restype = ctypes.c_int
lib.hgz_get_vertex_indegree.argtypes = [_Handle, _Id, _PSize]

lib.hgz_get_vertex_outdegree.restype = ctypes.c_int
lib.hgz_get_vertex_outdegree.argtypes = [_Handle, _Id, _PSize]

# ── Boolean queries ─────────────────────────────────────────────────────────────

lib.hgz_is_reachable.restype = ctypes.c_int
lib.hgz_is_reachable.argtypes = [_Handle, _Id, _Id]

lib.hgz_has_cycle.restype = ctypes.c_int
lib.hgz_has_cycle.argtypes = [_Handle]

lib.hgz_is_k_uniform.restype = ctypes.c_int
lib.hgz_is_k_uniform.argtypes = [_Handle, ctypes.c_size_t]

# ── Extended traversal ─────────────────────────────────────────────────────────

lib.hgz_bfs.restype = ctypes.c_int
lib.hgz_bfs.argtypes = [_Handle, _Id, _PPId, _PSize]

lib.hgz_dfs.restype = ctypes.c_int
lib.hgz_dfs.argtypes = [_Handle, _Id, _PPId, _PSize]

lib.hgz_random_walk.restype = ctypes.c_int
lib.hgz_random_walk.argtypes = [_Handle, _Id, ctypes.c_size_t, _PPId, _PSize]

# ── Orphan queries ──────────────────────────────────────────────────────────────

lib.hgz_get_orphan_vertices.restype = ctypes.c_int
lib.hgz_get_orphan_vertices.argtypes = [_Handle, _PPId, _PSize]

lib.hgz_get_orphan_hyperedges.restype = ctypes.c_int
lib.hgz_get_orphan_hyperedges.argtypes = [_Handle, _PPId, _PSize]

# ── Set operations ─────────────────────────────────────────────────────────────

lib.hgz_get_intersections.restype = ctypes.c_int
lib.hgz_get_intersections.argtypes = [_Handle, ctypes.POINTER(_Id), ctypes.c_size_t, _PPId, _PSize]

lib.hgz_get_hyperedges_connecting.restype = ctypes.c_int
lib.hgz_get_hyperedges_connecting.argtypes = [_Handle, _Id, _Id, _PPId, _PSize]

# ── Endpoints ──────────────────────────────────────────────────────────────────

lib.hgz_get_endpoints.restype = ctypes.c_int
lib.hgz_get_endpoints.argtypes = [
    _Handle,
    _PPId,
    _PPId,
    _PSize,  # initial: he_ids, v_ids, count
    _PPId,
    _PPId,
    _PSize,  # terminal: he_ids, v_ids, count
]

# ── Relation mutations ─────────────────────────────────────────────────────────

lib.hgz_prepend_vertices.restype = ctypes.c_int
lib.hgz_prepend_vertices.argtypes = [_Handle, _Id, ctypes.POINTER(_Id), ctypes.c_size_t]

lib.hgz_insert_vertex.restype = ctypes.c_int
lib.hgz_insert_vertex.argtypes = [_Handle, _Id, _Id, ctypes.c_size_t]

lib.hgz_insert_vertices.restype = ctypes.c_int
lib.hgz_insert_vertices.argtypes = [
    _Handle,
    _Id,
    ctypes.POINTER(_Id),
    ctypes.c_size_t,
    ctypes.c_size_t,
]

lib.hgz_remove_vertex_from_hyperedge.restype = ctypes.c_int
lib.hgz_remove_vertex_from_hyperedge.argtypes = [_Handle, _Id, _Id]

lib.hgz_remove_vertex_at_index.restype = ctypes.c_int
lib.hgz_remove_vertex_at_index.argtypes = [_Handle, _Id, ctypes.c_size_t]

# ── Centrality and PageRank ────────────────────────────────────────────────────

lib.hgz_compute_centrality.restype = ctypes.c_int
lib.hgz_compute_centrality.argtypes = [_Handle, _PPId, _PPDouble, _PPDouble, _PPDouble, _PSize]

lib.hgz_compute_page_rank.restype = ctypes.c_int
lib.hgz_compute_page_rank.argtypes = [
    _Handle,
    ctypes.c_double,
    ctypes.c_size_t,
    ctypes.c_double,
    _PPId,
    _PPDouble,
    _PSize,
    _PSize,
    ctypes.POINTER(ctypes.c_bool),
]

# ── Structural analysis ────────────────────────────────────────────────────────

lib.hgz_get_inclusions.restype = ctypes.c_int
lib.hgz_get_inclusions.argtypes = [_Handle, _PPId, _PPId, _PSize]

lib.hgz_get_nestedness_profile.restype = ctypes.c_int
lib.hgz_get_nestedness_profile.argtypes = [_Handle, _PPSize, _PPSize, _PPSize, _PSize]

lib.hgz_incidence_matrix.restype = ctypes.c_int
lib.hgz_incidence_matrix.argtypes = [_Handle, _PPUInt8, _PPId, _PPId, _PSize, _PSize]

lib.hgz_incidence_matrix_coo.restype = ctypes.c_int
lib.hgz_incidence_matrix_coo.argtypes = [
    _Handle,
    _PPId,
    _PPId,  # row_indices, col_indices
    _PPId,
    _PPId,  # vertex_ids, hyperedge_ids
    _PSize,
    _PSize,
    _PSize,  # nnz, n_vertices, n_hyperedges
]

lib.hgz_laplacian.restype = ctypes.c_int
lib.hgz_laplacian.argtypes = [_Handle, ctypes.c_uint8, _PPDouble, _PPId, _PSize]

lib.hgz_find_all_paths.restype = ctypes.c_int
lib.hgz_find_all_paths.argtypes = [_Handle, _Id, _Id, _PPId, _PPSize, _PSize]

# ── Sub-graph operations ───────────────────────────────────────────────────────

lib.hgz_clone.restype = ctypes.c_int
lib.hgz_clone.argtypes = [_Handle, _PHandle]

lib.hgz_get_dual.restype = ctypes.c_int
lib.hgz_get_dual.argtypes = [_Handle, _PHandle]

lib.hgz_get_k_skeleton.restype = ctypes.c_int
lib.hgz_get_k_skeleton.argtypes = [_Handle, ctypes.c_size_t, _PHandle]

lib.hgz_expand_to_graph.restype = ctypes.c_int
lib.hgz_expand_to_graph.argtypes = [_Handle, _PHandle]

lib.hgz_expand_to_star.restype = ctypes.c_int
lib.hgz_expand_to_star.argtypes = [_Handle, _PHandle]

lib.hgz_get_line_graph.restype = ctypes.c_int
lib.hgz_get_line_graph.argtypes = [_Handle, _PHandle]

lib.hgz_get_vertex_induced_subhypergraph.restype = ctypes.c_int
lib.hgz_get_vertex_induced_subhypergraph.argtypes = [
    _Handle,
    ctypes.POINTER(_Id),
    ctypes.c_size_t,
    _PHandle,
]

lib.hgz_get_edge_induced_subhypergraph.restype = ctypes.c_int
lib.hgz_get_edge_induced_subhypergraph.argtypes = [
    _Handle,
    ctypes.POINTER(_Id),
    ctypes.c_size_t,
    _PHandle,
]

lib.hgz_get_core.restype = ctypes.c_int
lib.hgz_get_core.argtypes = [_Handle, ctypes.c_size_t, ctypes.c_size_t, _PHandle]

lib.hgz_get_transitive_closure.restype = ctypes.c_int
lib.hgz_get_transitive_closure.argtypes = [_Handle, _PHandle]

# ── Codec ──────────────────────────────────────────────────────────────────────

lib.hgz_save.restype = ctypes.c_int
lib.hgz_save.argtypes = [_Handle, ctypes.c_char_p]

lib.hgz_load.restype = ctypes.c_int
lib.hgz_load.argtypes = [ctypes.c_char_p, ctypes.POINTER(_Handle)]
