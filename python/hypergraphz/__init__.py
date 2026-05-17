"""HypergraphZ — Python bindings for the HypergraphZ Zig library."""

from ._errors import (
    CycleDetectedError,
    HyperedgeNotFoundError,
    HypergraphZError,
    IndexOutOfBoundsError,
    NoPathError,
    NotBuiltError,
    NotEnoughVerticesError,
    VertexNotFoundError,
)
from ._graph import Hypergraph
from ._query import HyperedgeQuery, VertexQuery

__all__ = [
    "Hypergraph",
    "HyperedgeQuery",
    "VertexQuery",
    "HypergraphZError",
    "NotBuiltError",
    "VertexNotFoundError",
    "HyperedgeNotFoundError",
    "CycleDetectedError",
    "NoPathError",
    "IndexOutOfBoundsError",
    "NotEnoughVerticesError",
]
