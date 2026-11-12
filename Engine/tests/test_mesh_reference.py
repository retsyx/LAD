"""Shared source analysis without changing evidence or comparison semantics."""
import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mesh_reference
from mesh_compare import _reference
from mesh_tools import REFERENCE_ASSET, attach_reference
from mesh_inspect import _analysis
from test_mesh_inspect import box_context, context
from test_mesh_tools import WorkerCalls, box_mesh


class SharedReferenceTests(unittest.TestCase):
    def setUp(self):
        mesh_reference._CACHE.clear()

    def assert_shared(self, source, analysis):
        for attribute, key in (("vertices", "vertices"), ("triangles", "triangles"),
                               ("faces", "faces"), ("centroids", "centroids"),
                               ("unique", "welded_vertices"), ("indexed", "welded_triangles"),
                               ("edges", "edges")):
            self.assertIs(getattr(source, attribute), analysis[key], key)

    def test_discrepancy_worker_uses_one_reference_and_shared_manifold_graph(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = WorkerCalls(directory)
            _, opened, opened_folder = calls.call("open_reference", options={"units": "mm", "max_deviation": .03},
                                                  sourceAsset=box_mesh())
            reference = opened["payload"]["context"]
            revision = opened["payload"]["revision"]
            with mock.patch.object(mesh_reference, "ReferenceMesh", wraps=mesh_reference.ReferenceMesh) as construction:
                _, result, _ = calls.call("inspect", contextAsset=reference, revisionAsset=revision,
                                           queryAsset={"kind": "discrepancies"})
                self.assertEqual(construction.call_count, 1)
            self.assertEqual(result["status"], "partial")
            self.assertEqual(result["payload"]["source_selection"]["triangle_ids"], list(range(12)))
            # The published context carries metadata only; its arrays live in
            # the binary reference the worker staged beside it.
            reference = attach_reference(copy.deepcopy(reference), opened_folder, REFERENCE_ASSET)
            source, analysis = _reference(reference), _analysis(reference)
            self.assert_shared(source, analysis)
            self.assertIs(source.adjacency, analysis["adjacency"])

    def test_sharing_works_in_both_orders_without_mutating_the_source(self):
        for comparison_first in (False, True):
            with self.subTest(comparison_first=comparison_first):
                mesh_reference._CACHE.clear()
                reference = box_context()
                before = copy.deepcopy(reference)
                if comparison_first:
                    source, analysis = _reference(reference), _analysis(reference)
                else:
                    analysis, source = _analysis(reference), _reference(reference)
                self.assert_shared(source, analysis)
                self.assertEqual(reference, before)
                with self.assertRaises(ValueError):
                    source.vertices[0, 0] = 5
                with self.assertRaises(ValueError):
                    analysis["faces"][0, 0, 0] = 5
                with self.assertRaises(TypeError):
                    source.edges[(0, 1)] = ()
                with self.assertRaises(AttributeError):
                    analysis["adjacency"][0].add(100)

    def test_nonmanifold_barriers_and_degenerate_components_stay_distinct(self):
        reference = context([[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [2, 0, 0]],
                            [[0, 1, 2], [1, 0, 3], [0, 1, 4], [0, 1, 5]])
        source, analysis = _reference(reference), _analysis(reference)
        self.assert_shared(source, analysis)
        self.assertEqual(source.adjacency, ({1, 2}, {0}, {0}, set()))
        self.assertEqual(analysis["adjacency"], (set(), set(), set(), set()))
        self.assertEqual(source.components, [[0, 1, 2]])
        self.assertEqual(analysis["components"], [[0], [1], [2], [3]])
        self.assertEqual(analysis["degenerate_triangles"], [3])
        self.assertEqual(analysis["triangle_edges"][3], ())

    def test_numerical_formulas_and_geometry_identity_remain_exact(self):
        reference = context([[100.1, -3.4, 0.7], [101.2, -2.5, 2.8], [104.3, 4.9, 8.1],
                             [105.6, 1.2, -0.4]], [[0, 1, 2], [2, 1, 3]])
        source, analysis = _reference(reference), _analysis(reference)
        vertices, triangles = np.asarray(reference["vertices"], float), np.asarray(reference["triangles"], np.int64)
        expected_digest = hashlib.sha256(vertices.tobytes() + triangles.tobytes()).hexdigest()
        self.assertEqual(source.digest, expected_digest)
        self.assertEqual(analysis["geometry_hash"], expected_digest)
        faces = vertices[triangles]
        physical_cross = np.cross(faces[:, 1] - faces[:, 0], faces[:, 2] - faces[:, 0])
        physical_length = np.linalg.norm(physical_cross, axis=1)
        np.testing.assert_array_equal(source.areas, physical_length / 2)
        np.testing.assert_array_equal(source.normals, physical_cross / physical_length[:, None])
        scale = np.linalg.norm(vertices.max(axis=0) - vertices.min(axis=0))
        normalized = (vertices - vertices.min(axis=0)) / scale
        cross = np.cross(normalized[triangles[:, 1]] - normalized[triangles[:, 0]],
                         normalized[triangles[:, 2]] - normalized[triangles[:, 0]])
        length = np.linalg.norm(cross, axis=1)
        np.testing.assert_array_equal(analysis["areas"], length * scale * scale / 2)
        np.testing.assert_array_equal(analysis["normals"], cross / length[:, None])

    def test_same_context_metadata_cannot_reuse_changed_coordinates(self):
        reference = box_context()
        source, analysis = _reference(reference), _analysis(reference)
        reference["vertices"][0][0] = -.5
        changed_source, changed_analysis = _reference(reference), _analysis(reference)
        self.assert_shared(changed_source, changed_analysis)
        self.assertIsNot(source.vertices, changed_source.vertices)
        self.assertIsNot(analysis["edges"], changed_analysis["edges"])
        self.assertNotEqual(source.digest, changed_source.digest)
        self.assertEqual(source.vertices[0, 0], 0)


if __name__ == "__main__":
    unittest.main()
