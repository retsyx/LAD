"""Shared immutable reference geometry for inspection and comparison.

The two consumers keep their established numerical formulas and connectivity
rules. Coordinates, expanded facets and welded edge incidence have one owner;
consumer-specific measurements and adjacency are prepared only when requested.
"""
from __future__ import annotations

from collections import OrderedDict
from functools import cached_property
import hashlib
from types import MappingProxyType

import numpy as np


_CACHE = OrderedDict()


def _readonly(values):
    values.setflags(write=False)
    return values


def geometry_digest(vertices, triangles):
    digest = hashlib.sha256()
    # Separate updates retain the existing identity without allocating a
    # concatenated copy of both complete coordinate/index buffers.
    digest.update(memoryview(np.ascontiguousarray(vertices)).cast("B"))
    digest.update(memoryview(np.ascontiguousarray(triangles)).cast("B"))
    return digest.hexdigest()


def triangle_ranges(ids):
    """Sorted original triangle IDs as inclusive [first, last] runs.

    Exact and compact: a whole or mostly contiguous scope needs a few runs
    instead of one entry per triangle.
    """
    values = np.unique(np.fromiter((int(value) for value in ids), dtype=np.int64))
    if not len(values):
        return []
    breaks = np.flatnonzero(np.diff(values) != 1)
    starts = np.concatenate(([values[0]], values[breaks + 1]))
    ends = np.concatenate((values[breaks], [values[-1]]))
    return np.stack((starts, ends), axis=1).tolist()


def expand_ranges(runs):
    return [value for first, last in runs for value in range(int(first), int(last) + 1)]


def reference(vertices, triangles):
    digest = geometry_digest(vertices, triangles)
    if digest in _CACHE:
        _CACHE.move_to_end(digest)
        return _CACHE[digest]
    value = ReferenceMesh(vertices, triangles, digest)
    _CACHE[digest] = value
    while len(_CACHE) > 1 and (len(_CACHE) > 4 or sum(len(v.triangles) for v in _CACHE.values()) > 250_000):
        _CACHE.popitem(last=False)
    return value


class ReferenceMesh:
    def __init__(self, vertices, triangles, digest):
        self.vertices = _readonly(np.array(vertices, dtype=float, copy=True))
        self.triangles = _readonly(np.array(triangles, dtype=np.int64, copy=True))
        self.digest = digest
        self.low = _readonly(self.vertices.min(axis=0))
        self.high = _readonly(self.vertices.max(axis=0))
        self.scale = float(np.linalg.norm(self.high - self.low))
        self._incidences = {}
        self.inspection = None
        self.comparison = None

    @cached_property
    def faces(self):
        return _readonly(self.vertices[self.triangles])

    @cached_property
    def centroids(self):
        return _readonly(self.faces.mean(axis=1))

    @cached_property
    def welding(self):
        return tuple(_readonly(value) for value in np.unique(
            self.vertices, axis=0, return_index=True, return_inverse=True))

    @cached_property
    def indexed(self):
        return _readonly(self.welding[2][self.triangles])

    def incidence(self, areas):
        active = areas > 0
        key = np.packbits(active).tobytes()
        if key not in self._incidences:
            self._incidences[key] = ReferenceIncidence(self.indexed, active)
        return self._incidences[key]


class ReferenceIncidence:
    def __init__(self, indexed, active):
        self.indexed = indexed
        self.active = _readonly(active)
        edges = {}
        for tid, face in enumerate(indexed):
            if not active[tid]:
                continue
            a, b, c = map(int, face)
            for first, second in ((a, b), (b, c), (c, a)):
                edge = (min(first, second), max(first, second))
                edges.setdefault(edge, []).append((tid, 1 if first < second else -1))
        self.edges = MappingProxyType({edge: tuple(uses) for edge, uses in edges.items()})

    @cached_property
    def connected(self):
        adjacency = [set() for _ in self.indexed]
        for uses in self.edges.values():
            first = uses[0][0]
            for tid, _ in uses[1:]:
                adjacency[first].add(tid)
                adjacency[tid].add(first)
        return tuple(frozenset(neighbors) for neighbors in adjacency)

    @cached_property
    def manifold(self):
        if all(len(uses) <= 2 for uses in self.edges.values()):
            return self.connected
        adjacency = [set() for _ in self.indexed]
        for uses in self.edges.values():
            if len(uses) == 2:
                first, second = uses[0][0], uses[1][0]
                adjacency[first].add(second)
                adjacency[second].add(first)
        return tuple(frozenset(neighbors) for neighbors in adjacency)

    @cached_property
    def triangle_edges(self):
        # Preserve each triangle's cyclic edge order, including shared edges
        # first encountered on another triangle, for stable query evidence.
        result = []
        for tid, face in enumerate(self.indexed):
            a, b, c = map(int, face)
            result.append(tuple((min(i, j), max(i, j)) for i, j in ((a, b), (b, c), (c, a)))
                          if self.active[tid] else ())
        return tuple(result)
