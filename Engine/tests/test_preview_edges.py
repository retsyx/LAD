"""Rendered edge polylines must coincide with the native face triangulation."""
import math
from pathlib import Path
import sys
import unittest

import cadquery as cq

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import _preview_edge_polyline, make_preview


class PreviewEdgeTests(unittest.TestCase):
    def cylinder_with_distant_part(self, angle=360, located=False):
        cylinder = cq.Solid.makeCylinder(2.2, 3, angleDegrees=angle)
        if located:
            cylinder = cylinder.located(cq.Location((12, -7, 4), (0, 1, 0), 37))
        # Overall design bounds previously reduced these small circles to
        # about 24 analytic samples while their faces retained 84 mesh nodes.
        return cq.Compound.makeCompound([cylinder, cq.Solid.makeBox(1, 1, 1).translate((60, 40, 10))])

    def test_closed_boss_rims_share_every_native_face_boundary_point_and_have_no_seam(self):
        preview = make_preview(self.cylinder_with_distant_part())
        circles = [edge for edge in preview["topology"]["edges"] if edge["type"] == "CIRCLE"]
        self.assertEqual(len(circles), 2)
        mesh_points = self.owner_mesh_points(preview, 0)
        for edge in circles:
            with self.subTest(edge=edge["id"]):
                points = edge["polyline"]
                self.assertTrue(edge["closed"])
                self.assertEqual(points[0], points[-1], "Closed circles must include their final-to-first segment.")
                center, axis, radius = edge["center"], edge["axis"], edge["radius"]
                boundary = set()
                for point in mesh_points:
                    delta = [point[i] - center[i] for i in range(3)]
                    axial = sum(delta[i] * axis[i] for i in range(3))
                    radial = math.sqrt(sum((delta[i] - axial * axis[i]) ** 2 for i in range(3)))
                    if abs(axial) < 1e-7 and abs(radial - radius) < 1e-7:
                        boundary.add(self.key(point))
                self.assertGreater(len(boundary), 40, "The fixture must expose the old coarse-curve/fine-face mismatch.")
                self.assertEqual(set(map(self.key, points)), boundary,
                                 "A rim must follow every native polygon vertex, rather than cutting through finer cylinder faces.")
        self.assert_display_mapping(preview)

    def test_trimmed_arcs_keep_their_actual_open_endpoints_without_an_extra_closing_edge(self):
        shape = self.cylinder_with_distant_part(angle=120)
        preview = make_preview(shape)
        native = shape.Solids()[0].Edges()
        arcs = [edge for edge in preview["topology"]["edges"] if edge["type"] == "CIRCLE"]
        self.assertEqual(len(arcs), 2)
        for edge in arcs:
            points = edge["polyline"]
            source = native[edge["id"]["localIndex"]]
            self.assertFalse(edge["closed"])
            self.assertNotEqual(points[0], points[-1])
            actual = {self.key(points[0]), self.key(points[-1])}
            expected = {self.key(source.startPoint().toTuple()), self.key(source.endPoint().toTuple())}
            self.assertEqual(actual, expected, "Mesher orientation may reverse a polyline, but must retain the native trimmed endpoints.")
        self.assert_display_mapping(preview)

    def test_located_rotated_owner_uses_world_coordinates_and_retains_native_part_and_edge_order(self):
        shape = self.cylinder_with_distant_part(located=True)
        preview = make_preview(shape)
        expected_ids = [{"kind": "edge", "solidIndex": owner, "localIndex": index}
                        for owner, solid in enumerate(shape.Solids()) for index, _ in enumerate(solid.Edges())]
        self.assertEqual([edge["id"] for edge in preview["topology"]["edges"]], expected_ids)
        for edge in preview["topology"]["edges"]:
            mesh_points = self.owner_mesh_points(preview, edge["id"]["solidIndex"])
            native_points = set(map(self.key, mesh_points))
            self.assertTrue(set(map(self.key, edge["polyline"])) <= native_points,
                            "Located edge polygons must use the same world transform as their owner's mesh.")
        self.assert_display_mapping(preview)

    def test_missing_polygon_fallback_closes_only_native_closed_curves(self):
        closed = cq.Edge.makeCircle(2.2)
        opened = cq.Edge.makeCircle(2.2, angle1=15, angle2=135)
        closed_points = _preview_edge_polyline(closed, {}, 0.075)
        open_points = _preview_edge_polyline(opened, {}, 0.075)
        self.assertEqual(closed_points[0], closed_points[-1])
        self.assertNotEqual(open_points[0], open_points[-1])
        self.assertAlmostEqual(math.dist(open_points[0], opened.startPoint().toTuple()), 0, places=9)
        self.assertAlmostEqual(math.dist(open_points[-1], opened.endPoint().toTuple()), 0, places=9)

    def test_native_hash_collision_does_not_reuse_a_different_edges_polygon(self):
        wanted = cq.Edge.makeLine((0, 0, 0), (1, 0, 0))
        other = cq.Edge.makeLine((0, 1, 0), (1, 1, 0))
        exact = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]]
        polygons = {hash(wanted.wrapped): [(other.wrapped, [[99, 99, 99], [100, 100, 100]]),
                                           (wanted.wrapped, exact)]}
        self.assertIs(_preview_edge_polyline(wanted, polygons, 0.075), exact)

    def assert_display_mapping(self, preview):
        self.assertEqual(len(preview["edges"]), len(preview["edgeSolids"]))
        self.assertEqual(len(preview["edges"]), len(preview["edgeFeatures"]))
        expected = []
        for index, edge in enumerate(preview["topology"]["edges"]):
            pairs = list(zip(edge["polyline"], edge["polyline"][1:]))
            expected.extend((start + end, edge["id"]["solidIndex"], index) for start, end in pairs)
        self.assertEqual(list(zip(preview["edges"], preview["edgeSolids"], preview["edgeFeatures"])), expected)

    @staticmethod
    def key(point):
        return tuple(round(value, 7) for value in point)

    @staticmethod
    def owner_mesh_points(preview, owner):
        indices = {index for triangle, solid in zip(preview["triangles"], preview["triangleSolids"])
                   if solid == owner for index in triangle}
        return [preview["vertices"][index] for index in indices]


if __name__ == "__main__":
    unittest.main()
