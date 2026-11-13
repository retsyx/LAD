"""A selected planar face exports as an exact 2D DXF seen from outside."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


def plate():
    """A 60 x 40 x 5 plate with a hole, a slot, an edge notch and a spline cutout."""
    import cadquery as cq

    def prism(edges):
        face = cq.Face.makeFromWires(cq.Wire.assembleEdges(edges))
        return cq.Solid.extrudeLinear(face, cq.Vector(0, 0, 20)).translate((0, 0, -5))

    slot = cq.Workplane('XY').center(32, 12).slot2D(16, 6, 0).extrude(20).translate((0, 0, -5)).val()
    spline = prism([cq.Edge.makeSpline([cq.Vector(5, 5, 0), cq.Vector(10, 9, 0), cq.Vector(15, 5, 0)]),
                    cq.Edge.makeLine(cq.Vector(15, 5, 0), cq.Vector(5, 5, 0))])
    return (cq.Solid.makeBox(60, 40, 5)
            .cut(cq.Solid.makeCylinder(4, 20, cq.Vector(12, 20, -5)))
            .cut(slot)
            .cut(cq.Solid.makeCylinder(6, 20, cq.Vector(30, 40, -5)))
            .cut(spline))


def face_index(solid, normal):
    import cadquery as cq
    for index, face in enumerate(worker._shape_entities(solid, 'Face')):
        if face.geomType() == 'PLANE' and (face.normalAt() - cq.Vector(*normal)).Length < 1e-9:
            return index
    raise AssertionError(f'No planar face with normal {normal}')


class FaceDXFExportTests(unittest.TestCase):
    def export(self, folder, solids, feature, **fields):
        import cadquery as cq
        from OCP import BRepMesh
        worker.write_brep(cq.Compound.makeCompound(solids), folder / 'source.brep')
        original = (folder / 'source.brep').read_bytes()
        request = folder / 'request.json'
        request.write_text(json.dumps({'operation': 'dxf', 'brepAsset': 'source.brep', 'feature': feature, **fields}))
        with (mock.patch.object(worker, 'build_shape', side_effect=AssertionError('No replay')),
              mock.patch.object(worker, 'make_preview', side_effect=AssertionError('No preview')),
              mock.patch.object(worker, 'write_step', side_effect=AssertionError('No STEP')),
              mock.patch.object(BRepMesh, 'BRepMesh_IncrementalMesh', side_effect=AssertionError('No tessellation'))):
            report = worker.run(request, folder, 2)
        self.assertEqual(original, (folder / 'source.brep').read_bytes())
        self.assertNotIn('stepPath', report)
        self.assertFalse((folder / 'model.step').exists())
        return report

    def drawing(self, solids, solid_index, local_index, **fields):
        import ezdxf
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            feature = {'kind': 'face', 'solidIndex': solid_index, 'localIndex': local_index}
            report = self.export(folder, solids, feature, **fields)
            document = ezdxf.readfile(folder / 'face.dxf')
        self.assertEqual(report['entities'], len(document.modelspace()))
        self.assertEqual(document.header['$INSUNITS'], 4, 'LAD designs are in millimeters')
        return list(document.modelspace())

    def assert_closed_outline(self, entities):
        """Every open curve must meet another at both ends, so arc angles are right."""
        ends = []
        for entity in entities:
            self.assertIn(entity.dxftype(), ('LINE', 'ARC', 'CIRCLE', 'SPLINE'))
            if entity.dxftype() == 'LINE':
                ends += [entity.dxf.start, entity.dxf.end]
            elif entity.dxftype() == 'ARC':
                ends += [entity.start_point, entity.end_point]
            elif entity.dxftype() == 'SPLINE':
                curve = entity.construction_tool()
                ends += [curve.point(0), curve.point(curve.max_t)]
        for index, point in enumerate(ends):
            self.assertAlmostEqual(abs(point.z), 0, places=9)
            self.assertTrue(any(other != index and (point - match).magnitude < 1e-6
                                for other, match in enumerate(ends)), f'Open end at {point}')

    def assert_bounds(self, entities, minimum, maximum):
        from ezdxf import bbox
        extents = bbox.extents(entities)
        for actual, expected in zip(list(extents.extmin)[:2] + list(extents.extmax)[:2], minimum + maximum):
            self.assertAlmostEqual(actual, expected, places=6)

    def test_top_face_is_centered_on_its_centroid_with_analytic_curves(self):
        solid = plate()
        index = face_index(solid, (0, 0, 1))
        cx, cy, _ = worker._shape_entities(solid, 'Face')[index].Center().toTuple()
        self.assertGreater(abs(cx - 30) + abs(cy - 20), 0.1, 'The cutouts move the area centroid off the bounding-box center')
        entities = self.drawing([solid], 0, index)
        self.assertEqual({entity.dxftype() for entity in entities}, {'LINE', 'ARC', 'CIRCLE', 'SPLINE'})
        self.assert_closed_outline(entities)
        self.assert_bounds(entities, [-cx, -cy], [60 - cx, 40 - cy])
        circle = next(entity for entity in entities if entity.dxftype() == 'CIRCLE')
        self.assertAlmostEqual((circle.dxf.center - (12 - cx, 20 - cy, 0)).magnitude, 0, places=9)
        self.assertAlmostEqual(circle.dxf.radius, 4, places=9)
        notch = next(entity for entity in entities if entity.dxftype() == 'ARC' and abs(entity.dxf.radius - 6) < 1e-9)
        self.assertAlmostEqual((notch.dxf.center - (30 - cx, 40 - cy, 0)).magnitude, 0, places=9)
        # The notch is cut into the plate below the top boundary.
        self.assertLess(min(point.y for point in notch.flattening(0.01)), 40 - 6 - cy + 1e-6)

    def test_other_faces_are_drawn_from_outside_without_mirroring(self):
        solid = plate()
        index = face_index(solid, (0, 0, -1))
        cx, cy, _ = worker._shape_entities(solid, 'Face')[index].Center().toTuple()
        bottom = self.drawing([solid], 0, index)
        self.assert_closed_outline(bottom)
        # Seen from below with +X to the right, world +Y points down the page.
        self.assert_bounds(bottom, [-cx, cy - 40], [60 - cx, cy])
        circle = next(entity for entity in bottom if entity.dxftype() == 'CIRCLE')
        self.assertAlmostEqual((circle.dxf.center - (12 - cx, cy - 20, 0)).magnitude, 0, places=9)
        # Side faces stand upright: world +Z is the drawing's +Y.
        front = self.drawing([solid], 0, face_index(solid, (0, -1, 0)))
        self.assert_bounds(front, [-30, -2.5], [30, 2.5])
        right = self.drawing([solid], 0, face_index(solid, (1, 0, 0)))
        self.assert_bounds(right, [-20, -2.5], [20, 2.5])

    def test_oblique_and_posed_faces_keep_their_true_shape(self):
        import cadquery as cq
        box = cq.Solid.makeBox(10, 20, 3).rotate((0, 0, 0), (1, 2, 3), 37).translate((5, 6, 7))
        index = next(i for i, face in enumerate(worker._shape_entities(box, 'Face'))
                     if abs(face.Area() - 200) < 1e-6)
        entities = self.drawing([box], 0, index)
        self.assert_closed_outline(entities)
        lengths = sorted((entity.dxf.end - entity.dxf.start).magnitude for entity in entities)
        for actual, expected in zip(lengths, [10, 10, 20, 20]):
            self.assertAlmostEqual(actual, expected, places=9)
        from ezdxf.math import Vec3
        corners = [point for entity in entities for point in (entity.dxf.start, entity.dxf.end)]
        self.assertAlmostEqual(Vec3.sum(corners).magnitude / len(corners), 0, places=9,
                               msg='A rectangle is centered on its middle')

        solids = [cq.Solid.makeBox(1, 1, 1), plate()]
        top = face_index(solids[1], (0, 0, 1))
        cx, cy, _ = worker._shape_entities(solids[1], 'Face')[top].Center().toTuple()
        # A quarter turn about Z, then a translation, at the current assembly pose.
        pose = {'solid': 1, 'matrix': [0, -1, 0, 100, 1, 0, 0, -50, 0, 0, 1, 7, 0, 0, 0, 1]}
        posed = self.drawing(solids, 1, top, solidTransforms=[pose])
        self.assert_bounds(posed, [cy - 40, -cx], [cy, 60 - cx])
        circle = next(entity for entity in posed if entity.dxftype() == 'CIRCLE')
        self.assertAlmostEqual((circle.dxf.center - (cy - 20, 12 - cx, 0)).magnitude, 0, places=9)

    def test_curved_and_invalid_faces_fail_without_writing_a_drawing(self):
        import cadquery as cq
        solids = [cq.Solid.makeCylinder(5, 10)]
        curved = next(i for i, face in enumerate(worker._shape_entities(solids[0], 'Face')) if face.geomType() != 'PLANE')
        invalid = [({'kind': 'face', 'solidIndex': 0, 'localIndex': curved}, {}),
                   ({'kind': 'edge', 'solidIndex': 0, 'localIndex': 0}, {}),
                   ({'kind': 'face', 'solidIndex': 1, 'localIndex': 0}, {}),
                   ({'kind': 'face', 'solidIndex': 0, 'localIndex': 99}, {}),
                   ({'kind': 'face', 'solidIndex': -1, 'localIndex': 0}, {}),
                   ({'kind': 'face', 'solidIndex': True, 'localIndex': 0}, {}),
                   ({'kind': 'face', 'solidIndex': 0, 'localIndex': '0'}, {}),
                   ({'kind': 'face', 'solidIndex': 0}, {}),
                   (None, {}),
                   ({'kind': 'face', 'solidIndex': 0, 'localIndex': 0}, {'solidIndices': [0]})]
        for feature, fields in invalid:
            with self.subTest(feature=feature, fields=fields), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                with self.assertRaises(worker.ModelError):
                    self.export(folder, solids, feature, **fields)
                self.assertFalse((folder / 'face.dxf').exists())


if __name__ == '__main__':
    unittest.main()
