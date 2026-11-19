"""Check preview shading against an exact surface at rasterized positions."""
from collections import Counter
from pathlib import Path
import sys
import unittest
from unittest import mock

import cadquery as cq
import numpy as np
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge
from OCP.Geom import Geom_BezierCurve
from OCP.TColgp import TColgp_Array1OfPnt
from OCP.gp import gp_Pnt

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


LENGTH = 6
WIDTH = 18
HEIGHT = 4
RISE = 0.4
DEGREE = 14


class PreviewShadingTests(unittest.TestCase):
    @staticmethod
    def assembly():
        # The Bézier poles produce a straight-to-curved transition with
        # exact height z = HEIGHT + RISE * (x / LENGTH) ** DEGREE.
        poles = TColgp_Array1OfPnt(1, DEGREE + 1)
        for index in range(DEGREE + 1):
            height = HEIGHT + (RISE if index == DEGREE else 0)
            poles.SetValue(index + 1, gp_Pnt(LENGTH * index / DEGREE, 0, height))
        bend = cq.Edge(BRepBuilderAPI_MakeEdge(Geom_BezierCurve(poles)).Edge())
        corners = [(LENGTH, 0, HEIGHT + RISE), (LENGTH, 0, 0), (0, 0, 0), (0, 0, HEIGHT)]
        sides = [cq.Edge.makeLine(cq.Vector(*start), cq.Vector(*end))
                 for start, end in zip(corners, corners[1:])]
        wire = cq.Wire.assembleEdges([bend, *sides])
        part = cq.Solid.extrudeLinear(wire, [], cq.Vector(0, WIDTH, 0)).toNURBS()
        # The assembly's diagonal sets the positional display tolerance.
        distant = cq.Solid.makeBox(1, 1, 1).translate((90, 0, 0))
        return cq.Compound.makeCompound([part, distant])

    @staticmethod
    def exact_normals(x):
        slope = RISE * DEGREE / LENGTH * (x / LENGTH) ** (DEGREE - 1)
        normals = np.stack((-slope, np.zeros_like(slope), np.ones_like(slope)), axis=-1)
        return normals / np.linalg.norm(normals, axis=-1, keepdims=True)

    @staticmethod
    def triangles_of_face(preview, face_index):
        return np.asarray(preview['triangles'])[np.asarray(preview['triangleFaces']) == face_index]

    def bend_shading_error(self, preview, triangles):
        # Sample more than the centroids and midpoints and evaluate the exact
        # tangent at the triangle's physical x coordinate, independently of UV.
        weights = np.asarray([[a / 8, b / 8, (8 - a - b) / 8]
                              for a in range(9) for b in range(9 - a)])
        xyz = weights @ np.asarray(preview['vertices'])[triangles]
        normals = weights @ np.asarray(preview['normals'])[triangles]
        normals /= np.linalg.norm(normals, axis=-1, keepdims=True)
        x, y, _ = xyz.transpose(2, 0, 1)
        bend_interior = ((0.4 * LENGTH < x) & (x < 0.98 * LENGTH)
                         & (0.15 * WIDTH < y) & (y < 0.85 * WIDTH))
        cosines = np.sum(normals * self.exact_normals(x), axis=-1)
        return np.degrees(np.arccos(np.clip(cosines[bend_interior], -1, 1))).max()

    def boundary_segments(self, preview, triangles):
        incidence = Counter(tuple(sorted(edge)) for a, b, c in triangles
                            for edge in ((a, b), (b, c), (c, a)))
        self.assertTrue(all(count <= 2 for count in incidence.values()))
        points = preview['vertices']
        return {tuple(sorted((tuple(points[a]), tuple(points[b]))))
                for (a, b), count in incidence.items() if count == 1}

    def test_refines_lighting_at_the_bend_and_preserves_exact_geometry_and_trim(self):
        with mock.patch.object(worker, '_refine_preview_shading', lambda mesh, tolerance: None):
            baseline = worker.make_preview(self.assembly())
        refined = worker.make_preview(self.assembly())
        for key in ('bounds', 'volume', 'area', 'solids', 'faces', 'topology',
                    'edges', 'edgeSolids', 'edgeFeatures'):
            self.assertEqual(refined[key], baseline[key], key)

        faces = baseline['topology']['faces']
        bend = max(range(len(faces)), key=lambda index: faces[index]['center'][2])
        self.assertEqual(faces[bend]['type'], 'BSPLINE')
        baseline_triangles = self.triangles_of_face(baseline, bend)
        refined_triangles = self.triangles_of_face(refined, bend)
        self.assertGreater(len(refined_triangles), len(baseline_triangles))
        baseline_error = self.bend_shading_error(baseline, baseline_triangles)
        self.assertGreater(baseline_error, 3, 'The fixture must expose an interior shading error.')
        self.assertLess(self.bend_shading_error(refined, refined_triangles), 0.5 * baseline_error)
        self.assertEqual(self.boundary_segments(refined, refined_triangles),
                         self.boundary_segments(baseline, baseline_triangles))

        normals = np.asarray(refined['normals'])
        self.assertTrue(np.isfinite(normals).all())
        np.testing.assert_allclose(np.linalg.norm(normals, axis=1), 1, rtol=0, atol=1e-7)
        indices = np.unique(refined_triangles)
        x, _, z = np.asarray(refined['vertices'])[indices].T
        np.testing.assert_allclose(z, HEIGHT + RISE * (x / LENGTH) ** DEGREE, rtol=0, atol=1e-9)
        np.testing.assert_allclose(normals[indices], self.exact_normals(x), rtol=0, atol=1e-7)

    def test_exhausted_shading_budget_retains_the_original_preview(self):
        with mock.patch.object(worker, '_refine_preview_shading', lambda mesh, tolerance: None):
            baseline = worker.make_preview(self.assembly())
        with mock.patch.object(worker, 'MAX_PREVIEW_SHADING_SAMPLES', 0):
            exhausted = worker.make_preview(self.assembly())
        self.assertEqual(exhausted, baseline)

    def test_folded_child_does_not_discard_an_independent_safe_split(self):
        uv = np.asarray([(0, 0), (2, 0), (1, 0.01), (1, -0.01),
                         (5, 0), (7, 0), (6, 0.01), (6, -0.01)])
        xyz = np.column_stack((uv, np.zeros(len(uv))))
        normals = np.tile((0, 0, 1), (len(uv), 1))
        cells = np.asarray([(0, 1, 2), (1, 0, 3), (4, 5, 6), (5, 4, 7)])
        owners = {(0, 1): [0, 1], (4, 5): [2, 3]}
        # Both midpoint projections are near their chords. Only the first
        # crosses the opposite vertex of its narrow upper triangle in XYZ.
        proposed = {(0, 1): (1, 0.02, 0, 0, 0, 1), (4, 5): (6, 0, 0, 0, 0, 1)}
        result = worker._preview_shading_split(xyz, normals, uv, cells, proposed, owners, sign=1)
        self.assertIsNotNone(result)
        positions, directions, parameters, triangles = result
        np.testing.assert_array_equal(positions, np.vstack((xyz, (6, 0, 0))))
        np.testing.assert_array_equal(directions, np.vstack((normals, (0, 0, 1))))
        np.testing.assert_array_equal(parameters, np.vstack((uv, (6, 0))))
        self.assertCountEqual([tuple(cell) for cell in triangles],
                              [(0, 1, 2), (1, 0, 3), (4, 8, 6), (8, 5, 6), (5, 8, 7), (8, 4, 7)])
        self.assertEqual(self.boundary_segments({'vertices': positions}, triangles),
                         self.boundary_segments({'vertices': xyz}, cells))


if __name__ == '__main__':
    unittest.main()
