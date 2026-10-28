"""Fast extraction retains the installed CadQuery topology and preview contract."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import cadquery as cq
from OCP.BRep import BRep_Tool
from OCP.TopAbs import TopAbs_EDGE
from OCP.TopExp import TopExp
from OCP.TopTools import TopTools_IndexedMapOfShape

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


METHODS = {"Vertex": "Vertices", "Edge": "Edges", "Wire": "Wires", "Face": "Faces",
           "Shell": "Shells", "Solid": "Solids", "CompSolid": "CompSolids", "Compound": "Compounds"}


class PreviewNativeTraversalTests(unittest.TestCase):
    def assert_native_order(self, shape):
        for kind, method in METHODS.items():
            with self.subTest(kind=kind, shape=shape.ShapeType()):
                expected = getattr(shape, method)()
                actual = worker._shape_entities(shape, kind)
                self.assertEqual(len(actual), len(expected))
                for optimized, installed in zip(actual, expected):
                    self.assertIs(type(optimized), type(installed))
                    self.assertTrue(optimized.isEqual(installed),
                                    "Extraction must preserve native orientation, location and indexed feature order.")

    def test_topology_order_and_locations_match_installed_cadquery_for_nested_instances(self):
        box = cq.Solid.makeBox(2, 3, 4)
        cylinder = cq.Solid.makeCylinder(2, 5)
        located = cylinder.located(cq.Location((12, -7, 4), (0, 1, 0), 37))
        compound = cq.Compound.makeCompound([box, cq.Compound.makeCompound([cylinder, located])])
        for shape in [box, cylinder, located, compound, *compound.Faces()]:
            self.assert_native_order(shape)

    def test_singular_faces_skip_only_the_same_degenerate_edges_and_keep_closed_seams(self):
        for shape in [cq.Solid.makeSphere(3, angleDegrees1=-90, angleDegrees2=90), cq.Solid.makeCone(3, 0, 4)]:
            raw = TopTools_IndexedMapOfShape()
            TopExp.MapShapes_s(shape.wrapped, TopAbs_EDGE, raw)
            edges = worker._shape_entities(shape, "Edge")
            self.assertGreater(raw.Extent(), len(edges), "The fixture must include native degenerate pole edges.")
            self.assertTrue(all(not BRep_Tool.Degenerated_s(edge.wrapped) for edge in edges))
            self.assert_native_order(shape)
            for face in shape.Faces():
                self.assert_native_order(face)
        cylinder_edges = worker._shape_entities(cq.Solid.makeCylinder(2, 3), "Edge")
        self.assertEqual(sum(edge.IsClosed() for edge in cylinder_edges), 2,
                         "Both complete circular rims must survive traversal beside the seam edge.")

    def test_complete_preview_matches_installed_traversal_with_shared_boundaries_and_singularities(self):
        def fresh_shape():
            # Meshing can change CadQuery's subsequent triangulation-based
            # bounding box. Compare equally fresh inputs, as on a cold replay.
            return cq.Compound.makeCompound([
                cq.Solid.makeBox(2, 3, 4),
                cq.Solid.makeCylinder(2, 3).located(cq.Location((12, -7, 4), (0, 1, 0), 37)),
                cq.Solid.makeCone(2, 0, 3).translate((-8, 0, 0)),
                cq.Solid.makeSphere(2, angleDegrees1=-90, angleDegrees2=90).translate((0, 9, 0)),
            ])
        with patch.object(worker, "_shape_entities", side_effect=lambda owner, kind: getattr(owner, METHODS[kind])()):
            installed = worker.make_preview(fresh_shape())
        shape = fresh_shape()
        optimized = worker.make_preview(shape)
        self.assertEqual(optimized, installed,
                         "The extraction optimization must preserve complete mesh, normals, topology, metrics and display mappings.")
        for kind, key in [("Vertex", "vertices"), ("Edge", "edges"), ("Face", "faces")]:
            expected_ids = [worker.feature_id(kind.lower(), owner, index)
                            for owner, solid in enumerate(shape.Solids())
                            for index, _ in enumerate(getattr(solid, METHODS[kind])())]
            self.assertEqual([feature["id"] for feature in optimized["topology"][key]], expected_ids)
        displayed = []
        for index, edge in enumerate(optimized["topology"]["edges"]):
            points = edge["polyline"]
            if edge["closed"]:
                self.assertEqual(points[0], points[-1])
            displayed.extend((start + end, edge["id"]["solidIndex"], index)
                             for start, end in zip(points, points[1:]))
        self.assertEqual(list(zip(optimized["edges"], optimized["edgeSolids"], optimized["edgeFeatures"])), displayed)


if __name__ == "__main__":
    unittest.main()
