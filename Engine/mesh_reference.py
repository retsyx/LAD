"""Shared immutable reference geometry for inspection and comparison.

The two consumers keep their established numerical formulas and connectivity
rules. Coordinates, expanded facets and welded edge incidence have one owner;
consumer-specific measurements and adjacency are prepared only when requested.
Record identities, connected components and point-to-triangle distances used
by several mesh modules are also defined once here.
"""
from __future__ import annotations

from collections import OrderedDict
from functools import cached_property
import hashlib
import json
from types import MappingProxyType

import numpy as np


_CACHE = OrderedDict()


def canonical(value):
    """Deterministic compact JSON bytes for records and their identities."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def canonical_digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def connected_components(indices, adjacency):
    """Sorted connected groups of indices, ordered by their smallest member."""
    remaining = set(int(index) for index in indices)
    groups = []
    while remaining:
        seed = min(remaining)
        remaining.remove(seed)
        stack, group = [seed], []
        while stack:
            current = stack.pop()
            group.append(current)
            for neighbor in adjacency[current]:
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    stack.append(neighbor)
        groups.append(sorted(group))
    return groups


def triangle_distances(point, faces, witnesses=True):
    """Squared distances from a point to each triangle of an (n, 3, 3) array.

    An interior plane projection competes with the closest point of every
    edge, which also covers degenerate triangles. With witnesses, also return
    each triangle's closest point and its barycentric weights.
    """
    a, b, c = faces[:, 0], faces[:, 1], faces[:, 2]
    ab, ac, ap = b - a, c - a, point - a
    d00 = np.einsum("ij,ij->i", ab, ab)
    d01 = np.einsum("ij,ij->i", ab, ac)
    d11 = np.einsum("ij,ij->i", ac, ac)
    d20 = np.einsum("ij,ij->i", ap, ab)
    d21 = np.einsum("ij,ij->i", ap, ac)
    denominator = d00 * d11 - d01 * d01
    v = np.divide(d11 * d20 - d01 * d21, denominator,
                  out=np.zeros_like(denominator), where=denominator > 0)
    w = np.divide(d00 * d21 - d01 * d20, denominator,
                  out=np.zeros_like(denominator), where=denominator > 0)
    points = a + v[:, None] * ab + w[:, None] * ac
    distances = np.einsum("ij,ij->i", points - point, points - point)
    outside = (denominator <= 0) | (v < 0) | (w < 0) | (v + w > 1)
    distances[outside | ~np.isfinite(v) | ~np.isfinite(w)] = np.inf
    bary = np.column_stack((1 - v - w, v, w)) if witnesses else None
    for i, j in ((0, 1), (1, 2), (2, 0)):
        edge = faces[:, j] - faces[:, i]
        length = np.einsum("ij,ij->i", edge, edge)
        t = np.divide(np.einsum("ij,ij->i", point - faces[:, i], edge), length,
                      out=np.zeros_like(length), where=length > 0)
        t = np.clip(t, 0, 1)
        q = faces[:, i] + t[:, None] * edge
        d = np.einsum("ij,ij->i", q - point, q - point)
        if not witnesses:
            distances = np.minimum(distances, d)
            continue
        mask = d < distances
        points[mask] = q[mask]
        distances[mask] = d[mask]
        bary[mask] = 0
        bary[mask, i] = 1 - t[mask]
        bary[mask, j] = t[mask]
    return (distances, points, bary) if witnesses else distances


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
